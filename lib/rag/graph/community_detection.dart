import 'dart:async';
import 'dart:math';

import 'graph_repository.dart';
import 'entity_extractor.dart';

/// Configuration for community detection
class CommunityDetectionConfig {
  /// Resolution parameter for Louvain (higher = smaller communities)
  final double resolution;
  
  /// Minimum improvement to continue optimization
  final double minImprovement;
  
  /// Maximum iterations per phase
  final int maxIterations;
  
  /// Maximum hierarchy depth
  final int maxDepth;
  
  /// Minimum community size to keep
  final int minCommunitySize;
  
  /// Random seed for reproducibility
  final int? randomSeed;

  CommunityDetectionConfig({
    this.resolution = 1.0,
    this.minImprovement = 0.001,
    this.maxIterations = 100,
    this.maxDepth = 2,
    this.minCommunitySize = 2,
    this.randomSeed,
  });
}

/// Represents a detected community
class DetectedCommunity {
  final String id;
  final int level;
  final Set<String> entityIds;
  final double modularity;
  final String? parentCommunityId;
  final List<String>? childCommunityIds;

  DetectedCommunity({
    required this.id,
    required this.level,
    required this.entityIds,
    required this.modularity,
    this.parentCommunityId,
    this.childCommunityIds,
  });

  int get size => entityIds.length;
}

/// Result of community detection
class CommunityDetectionResult {
  final List<DetectedCommunity> communities;
  final Map<String, String> entityToCommunity;
  final double overallModularity;
  final int hierarchyDepth;

  CommunityDetectionResult({
    required this.communities,
    required this.entityToCommunity,
    required this.overallModularity,
    required this.hierarchyDepth,
  });

  /// Get communities at a specific level
  List<DetectedCommunity> getLevel(int level) {
    return communities.where((c) => c.level == level).toList();
  }
}

/// Louvain algorithm for community detection
/// 
/// This implements the Louvain method for community detection:
/// 1. Assign each node to its own community
/// 2. For each node, calculate modularity gain from moving to neighbor's community
/// 3. Move node to community with maximum gain (if positive)
/// 4. Repeat until no improvement
/// 5. Build a new graph with communities as nodes
/// 6. Repeat process on new graph
class LouvainCommunityDetector {
  final CommunityDetectionConfig config;
  final Random _random;

  LouvainCommunityDetector({CommunityDetectionConfig? config})
      : config = config ?? CommunityDetectionConfig(),
        _random = config?.randomSeed != null 
            ? Random(config!.randomSeed) 
            : Random();

  /// Detect communities in the graph
  Future<CommunityDetectionResult> detectCommunities(
    List<GraphEntity> entities,
    List<GraphRelationship> relationships,
  ) async {
    if (entities.isEmpty) {
      return CommunityDetectionResult(
        communities: [],
        entityToCommunity: {},
        overallModularity: 0.0,
        hierarchyDepth: 0,
      );
    }

    // Build adjacency structure
    final graph = _buildGraph(entities, relationships);
    
    // Run hierarchical Louvain
    final hierarchy = await _runLouvain(graph, 0);
    
    // Flatten results
    final allCommunities = <DetectedCommunity>[];
    final entityToCommunity = <String, String>{};
    
    for (final level in hierarchy) {
      allCommunities.addAll(level);
      
      // Map entities to their communities at this level
      for (final community in level) {
        for (final entityId in community.entityIds) {
          if (!entityToCommunity.containsKey(entityId)) {
            entityToCommunity[entityId] = community.id;
          }
        }
      }
    }
    
    return CommunityDetectionResult(
      communities: allCommunities,
      entityToCommunity: entityToCommunity,
      overallModularity: _calculateModularity(graph, allCommunities.last.entityIds.first),
      hierarchyDepth: hierarchy.length,
    );
  }

  /// Build graph structure for Louvain
  _Graph _buildGraph(
    List<GraphEntity> entities,
    List<GraphRelationship> relationships,
  ) {
    final nodes = <String, _Node>{};
    final edges = <_Edge>[];
    
    // Create nodes
    for (final entity in entities) {
      nodes[entity.id] = _Node(
        id: entity.id,
        weight: 1.0,
        community: entity.id, // Each node starts in its own community
      );
    }
    
    // Create edges
    for (final rel in relationships) {
      if (nodes.containsKey(rel.sourceId) && nodes.containsKey(rel.targetId)) {
        edges.add(_Edge(
          source: rel.sourceId,
          target: rel.targetId,
          weight: rel.weight,
        ));
        
        // Add reverse edge for undirected graph
        edges.add(_Edge(
          source: rel.targetId,
          target: rel.sourceId,
          weight: rel.weight,
        ));
      }
    }
    
    return _Graph(
      nodes: nodes,
      edges: edges,
      totalWeight: edges.fold(0.0, (sum, e) => sum + e.weight),
    );
  }

  /// Run Louvain algorithm recursively
  Future<List<List<DetectedCommunity>>> _runLouvain(
    _Graph graph,
    int currentLevel,
  ) async {
    if (currentLevel >= config.maxDepth) {
      return [];
    }

    // Phase 1: Local optimization
    var improved = true;
    var iteration = 0;
    
    while (improved && iteration < config.maxIterations) {
      improved = false;
      
      // Shuffle nodes for random order
      final nodeIds = graph.nodes.keys.toList();
      nodeIds.shuffle(_random);
      
      for (final nodeId in nodeIds) {
        final node = graph.nodes[nodeId]!;
        final currentCommunity = node.community;
        
        // Find best community to move to
        var bestCommunity = currentCommunity;
        var bestGain = 0.0;
        
        final neighbors = _getNeighbors(graph, nodeId);
        final neighborCommunities = neighbors
            .map((n) => graph.nodes[n]!.community)
            .toSet();
        
        for (final community in neighborCommunities) {
          if (community == currentCommunity) continue;
          
          final gain = _modularityGain(
            graph, nodeId, currentCommunity, community);
          
          if (gain > bestGain + config.minImprovement) {
            bestGain = gain;
            bestCommunity = community;
          }
        }
        
        // Move node if improvement found
        if (bestCommunity != currentCommunity) {
          node.community = bestCommunity;
          improved = true;
        }
      }
      
      iteration++;
    }
    
    // Extract communities at this level
    final communities = _extractCommunities(graph, currentLevel);
    
    if (communities.length == graph.nodes.length || communities.length <= 1) {
      // No aggregation possible
      return [communities];
    }
    
    // Filter out small communities
    final validCommunities = communities
        .where((c) => c.size >= config.minCommunitySize)
        .toList();
    
    if (validCommunities.isEmpty) {
      return [communities];
    }
    
    // Phase 2: Build aggregated graph
    final aggregatedGraph = _aggregateGraph(graph, validCommunities);
    
    // Recursive call for next level
    final nextLevels = await _runLouvain(aggregatedGraph, currentLevel + 1);
    
    return [validCommunities, ...nextLevels];
  }

  /// Calculate modularity gain from moving a node to a new community
  // ignore: unused_element
  double _modularityGain(
    _Graph graph,
    String nodeId,
    String fromCommunity, // Used in algorithm design, kept for clarity
    String toCommunity,
  ) {
    if (graph.totalWeight == 0) return 0.0;
    
    final ki = _getNodeDegree(graph, nodeId);
    final m2 = graph.totalWeight;
    
    // Sum of weights of edges from node to toCommunity
    var kiIn = 0.0;
    for (final edge in graph.edges) {
      if (edge.source == nodeId) {
        final targetCommunity = graph.nodes[edge.target]!.community;
        if (targetCommunity == toCommunity) {
          kiIn += edge.weight;
        }
      }
    }
    
    // Sum of degrees in toCommunity
    var sigmaTot = 0.0;
    for (final n in graph.nodes.values) {
      if (n.community == toCommunity && n.id != nodeId) {
        sigmaTot += _getNodeDegree(graph, n.id);
      }
    }
    
    // Modularity gain formula
    final gain = kiIn / m2 - 
        config.resolution * (sigmaTot * ki) / (m2 * m2);
    
    return gain;
  }

  /// Get degree (sum of edge weights) for a node
  double _getNodeDegree(_Graph graph, String nodeId) {
    return graph.edges
        .where((e) => e.source == nodeId)
        .fold(0.0, (sum, e) => sum + e.weight);
  }

  /// Get neighbor node IDs
  Set<String> _getNeighbors(_Graph graph, String nodeId) {
    return graph.edges
        .where((e) => e.source == nodeId)
        .map((e) => e.target)
        .toSet();
  }

  /// Calculate overall modularity
  double _calculateModularity(_Graph graph, String _) {
    if (graph.totalWeight == 0) return 0.0;
    
    final m2 = graph.totalWeight;
    var q = 0.0;
    
    // Group nodes by community
    final communities = <String, List<String>>{};
    for (final entry in graph.nodes.entries) {
      communities.putIfAbsent(entry.value.community, () => []);
      communities[entry.value.community]!.add(entry.key);
    }
    
    // Calculate modularity
    for (final communityNodes in communities.values) {
      for (final i in communityNodes) {
        for (final j in communityNodes) {
          // Get edge weight between i and j
          final aij = graph.edges
              .where((e) => e.source == i && e.target == j)
              .fold(0.0, (sum, e) => sum + e.weight);
          
          final ki = _getNodeDegree(graph, i);
          final kj = _getNodeDegree(graph, j);
          
          q += aij - config.resolution * (ki * kj) / m2;
        }
      }
    }
    
    return q / m2;
  }

  /// Extract communities from current partition
  List<DetectedCommunity> _extractCommunities(_Graph graph, int level) {
    final communityNodes = <String, Set<String>>{};
    
    for (final entry in graph.nodes.entries) {
      communityNodes.putIfAbsent(entry.value.community, () => {});
      communityNodes[entry.value.community]!.add(entry.key);
    }
    
    return communityNodes.entries.map((entry) {
      return DetectedCommunity(
        id: 'community_${level}_${entry.key}',
        level: level,
        entityIds: entry.value,
        modularity: 0.0, // Could calculate individual modularity
      );
    }).toList();
  }

  /// Aggregate graph for next level
  _Graph _aggregateGraph(
    _Graph graph,
    List<DetectedCommunity> communities,
  ) {
    final nodes = <String, _Node>{};
    final edges = <_Edge>[];
    
    // Create super-nodes for each community
    for (final community in communities) {
      nodes[community.id] = _Node(
        id: community.id,
        weight: community.size.toDouble(),
        community: community.id,
      );
    }
    
    // Create mapping from old nodes to communities
    final nodeToCommunity = <String, String>{};
    for (final community in communities) {
      for (final nodeId in community.entityIds) {
        nodeToCommunity[nodeId] = community.id;
      }
    }
    
    // Aggregate edges
    final edgeWeights = <String, double>{};
    for (final edge in graph.edges) {
      final sourceCommunity = nodeToCommunity[edge.source];
      final targetCommunity = nodeToCommunity[edge.target];
      
      if (sourceCommunity == null || targetCommunity == null) continue;
      if (sourceCommunity == targetCommunity) continue;
      
      final edgeKey = '${sourceCommunity}_$targetCommunity';
      edgeWeights[edgeKey] = (edgeWeights[edgeKey] ?? 0.0) + edge.weight;
    }
    
    for (final entry in edgeWeights.entries) {
      final parts = entry.key.split('_');
      if (parts.length >= 2) {
        edges.add(_Edge(
          source: parts.sublist(0, parts.length ~/ 2).join('_'),
          target: parts.sublist(parts.length ~/ 2).join('_'),
          weight: entry.value,
        ));
      }
    }
    
    return _Graph(
      nodes: nodes,
      edges: edges,
      totalWeight: edges.fold(0.0, (sum, e) => sum + e.weight),
    );
  }
}

/// Internal graph representation
class _Graph {
  final Map<String, _Node> nodes;
  final List<_Edge> edges;
  final double totalWeight;

  _Graph({
    required this.nodes,
    required this.edges,
    required this.totalWeight,
  });
}

/// Internal node representation
class _Node {
  final String id;
  final double weight;
  String community;

  _Node({
    required this.id,
    required this.weight,
    required this.community,
  });
}

/// Internal edge representation
class _Edge {
  final String source;
  final String target;
  final double weight;

  _Edge({
    required this.source,
    required this.target,
    required this.weight,
  });
}

/// Community summarizer using LLM
class CommunitySummarizer {
  final Future<String> Function(String prompt) llmCallback;
  final Future<List<double>> Function(String text) embeddingCallback;

  CommunitySummarizer({
    required this.llmCallback,
    required this.embeddingCallback,
  });

  /// Generate summary for a community
  Future<CommunitySummary> summarize(
    DetectedCommunity community,
    List<GraphEntity> entities,
    List<GraphRelationship> relationships,
  ) async {
    // Get entities in this community
    final communityEntities = entities
        .where((e) => community.entityIds.contains(e.id))
        .toList();
    
    // Get relationships between entities in this community
    final communityRelationships = relationships
        .where((r) => 
            community.entityIds.contains(r.sourceId) &&
            community.entityIds.contains(r.targetId))
        .toList();
    
    // Build prompt
    final entityNames = communityEntities.map((e) => e.name).toList();
    final entityDescriptions = communityEntities
        .map((e) => e.description ?? '')
        .toList();
    final relationshipStrings = communityRelationships
        .map((r) {
          final source = communityEntities
              .firstWhere((e) => e.id == r.sourceId, orElse: () => communityEntities.first)
              .name;
          final target = communityEntities
              .firstWhere((e) => e.id == r.targetId, orElse: () => communityEntities.first)
              .name;
          return '$source ${r.type} $target';
        })
        .toList();
    
    final prompt = ExtractionPrompts.communitySummaryPrompt(
      entityNames,
      entityDescriptions,
      relationshipStrings,
    );
    
    final summary = await llmCallback(prompt);
    final embedding = await embeddingCallback(summary);
    
    return CommunitySummary(
      communityId: community.id,
      summary: summary,
      embedding: embedding,
      entityCount: communityEntities.length,
      relationshipCount: communityRelationships.length,
    );
  }

  /// Generate summaries for all communities
  Future<List<CommunitySummary>> summarizeAll(
    List<DetectedCommunity> communities,
    List<GraphEntity> entities,
    List<GraphRelationship> relationships, {
    void Function(int completed, int total)? onProgress,
  }) async {
    final summaries = <CommunitySummary>[];
    
    for (var i = 0; i < communities.length; i++) {
      final summary = await summarize(
        communities[i],
        entities,
        relationships,
      );
      summaries.add(summary);
      onProgress?.call(i + 1, communities.length);
    }
    
    return summaries;
  }
}

/// Community summary result
class CommunitySummary {
  final String communityId;
  final String summary;
  final List<double> embedding;
  final int entityCount;
  final int relationshipCount;

  CommunitySummary({
    required this.communityId,
    required this.summary,
    required this.embedding,
    required this.entityCount,
    required this.relationshipCount,
  });
}
