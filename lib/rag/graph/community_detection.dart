import 'dart:async';
import 'dart:math';

import 'graph_repository.dart';
import 'entity_extractor.dart';

/// Configuration for community detection
class CommunityDetectionConfig {
  /// Resolution parameter for Leiden (higher = smaller communities)
  final double resolution;
  
  /// Gamma parameter for refinement phase (controls community granularity)
  final double gamma;
  
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
    this.gamma = 1.0,
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

/// Leiden algorithm for community detection
/// 
/// This implements the Leiden method for community detection, which improves upon
/// Louvain by adding a refinement phase that guarantees well-connected communities.
/// Reference: Traag, V.A., Waltman, L. & van Eck, N.J. From Louvain to Leiden.
/// Sci Rep 9, 5233 (2019). https://doi.org/10.1038/s41598-019-41695-z
/// 
/// Algorithm phases:
/// 1. Local moving: Move nodes to neighboring communities to maximize modularity
/// 2. Refinement: Within each community, create refined sub-partitions ensuring connectivity
/// 3. Aggregation: Build a new graph with refined communities as nodes
/// 4. Repeat until no improvement
class LeidenCommunityDetector {
  final CommunityDetectionConfig config;
  final Random _random;

  LeidenCommunityDetector({CommunityDetectionConfig? config})
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
    
    // Run hierarchical Leiden
    final hierarchy = await _runLeiden(graph, 0);
    
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

  /// Build graph structure for Leiden
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

  /// Run Leiden algorithm recursively
  /// nodeToEntityIds maps graph node IDs to original entity IDs (for aggregated levels)
  Future<List<List<DetectedCommunity>>> _runLeiden(
    _Graph graph,
    int currentLevel, {
    Map<String, Set<String>>? nodeToEntityIds,
  }) async {
    if (currentLevel >= config.maxDepth) {
      return [];
    }
    
    // At level 0, each node IS an entity
    // At higher levels, nodes are community IDs that represent multiple entities
    nodeToEntityIds ??= {
      for (final nodeId in graph.nodes.keys) nodeId: {nodeId}
    };

    // Phase 1: Local moving phase (same as Louvain)
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

    // Phase 2: Refinement phase (Leiden-specific)
    // This phase ensures communities are well-connected by refining partitions
    _refineCommunities(graph);
    
    // Extract communities at this level with proper entity ID mapping
    final communities = _extractCommunities(graph, currentLevel, nodeToEntityIds);
    
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
    
    // Build mapping from new community IDs to original entity IDs for next level
    final nextLevelNodeToEntityIds = <String, Set<String>>{};
    for (final community in validCommunities) {
      nextLevelNodeToEntityIds[community.id] = community.entityIds;
    }
    
    // Phase 3: Aggregation phase - build aggregated graph
    final aggregatedGraph = _aggregateGraph(graph, validCommunities);
    
    // Recursive call for next level with updated entity mapping
    final nextLevels = await _runLeiden(
      aggregatedGraph, 
      currentLevel + 1,
      nodeToEntityIds: nextLevelNodeToEntityIds,
    );
    
    // Update parent-child relationships between levels
    if (nextLevels.isNotEmpty) {
      final parentLevel = nextLevels.first;
      _updateParentChildRelationships(validCommunities, parentLevel);
    }
    
    return [validCommunities, ...nextLevels];
  }
  
  /// Leiden refinement phase: refine communities to ensure well-connectedness
  /// This is the key difference from Louvain - nodes can only move to
  /// well-connected communities, preventing poorly connected communities
  void _refineCommunities(_Graph graph) {
    // Group nodes by their current community
    final communityNodes = <String, List<String>>{};
    for (final entry in graph.nodes.entries) {
      communityNodes.putIfAbsent(entry.value.community, () => []);
      communityNodes[entry.value.community]!.add(entry.key);
    }
    
    // For each community, check connectivity and potentially split
    for (final entry in communityNodes.entries) {
      final communityId = entry.key;
      final nodes = entry.value;
      
      if (nodes.length <= 1) continue;
      
      // Create subgraph of this community to check connectivity
      final subgraphNodes = nodes.toSet();
      
      // Find connected components within this community
      final components = _findConnectedComponents(graph, subgraphNodes);
      
      if (components.length > 1) {
        // Community is not well-connected - refine by merging small components
        // with neighboring communities or keeping them as separate refined communities
        _refineDisconnectedCommunity(graph, communityId, components);
      } else {
        // Community is well-connected - apply local refinement
        // Try to move each node to a random well-connected neighboring community
        _applyLocalRefinement(graph, nodes);
      }
    }
  }
  
  /// Find connected components within a set of nodes
  List<Set<String>> _findConnectedComponents(_Graph graph, Set<String> nodeSubset) {
    final visited = <String>{};
    final components = <Set<String>>[];
    
    for (final startNode in nodeSubset) {
      if (visited.contains(startNode)) continue;
      
      // BFS to find component
      final component = <String>{};
      final queue = [startNode];
      
      while (queue.isNotEmpty) {
        final node = queue.removeAt(0);
        if (visited.contains(node)) continue;
        
        visited.add(node);
        component.add(node);
        
        // Add unvisited neighbors that are in the subset
        final neighbors = _getNeighbors(graph, node);
        for (final neighbor in neighbors) {
          if (nodeSubset.contains(neighbor) && !visited.contains(neighbor)) {
            queue.add(neighbor);
          }
        }
      }
      
      if (component.isNotEmpty) {
        components.add(component);
      }
    }
    
    return components;
  }
  
  /// Handle disconnected community by merging small components with neighbors
  void _refineDisconnectedCommunity(
    _Graph graph, 
    String originalCommunityId, 
    List<Set<String>> components,
  ) {
    // Sort components by size (largest first)
    components.sort((a, b) => b.length.compareTo(a.length));
    
    // Keep the largest component with the original community
    // For smaller components, try to merge with neighboring communities
    for (var i = 1; i < components.length; i++) {
      final smallComponent = components[i];
      
      for (final nodeId in smallComponent) {
        final node = graph.nodes[nodeId]!;
        
        // Find neighboring communities outside this component
        final neighbors = _getNeighbors(graph, nodeId);
        final neighborCommunities = <String, double>{};
        
        for (final neighbor in neighbors) {
          if (smallComponent.contains(neighbor)) continue;
          
          final neighborComm = graph.nodes[neighbor]!.community;
          final edgeWeight = graph.edges
              .where((e) => e.source == nodeId && e.target == neighbor)
              .fold(0.0, (sum, e) => sum + e.weight);
          
          neighborCommunities[neighborComm] = 
              (neighborCommunities[neighborComm] ?? 0.0) + edgeWeight;
        }
        
        // Move to the most connected neighboring community
        if (neighborCommunities.isNotEmpty) {
          final bestComm = neighborCommunities.entries
              .reduce((a, b) => a.value > b.value ? a : b)
              .key;
          node.community = bestComm;
        }
      }
    }
  }
  
  /// Apply local refinement to a well-connected community
  /// Nodes may move to random neighboring well-connected communities
  void _applyLocalRefinement(_Graph graph, List<String> communityNodes) {
    // Shuffle for randomness
    final nodes = List<String>.from(communityNodes);
    nodes.shuffle(_random);
    
    for (final nodeId in nodes) {
      final node = graph.nodes[nodeId]!;
      final currentCommunity = node.community;
      
      // Get neighboring communities
      final neighbors = _getNeighbors(graph, nodeId);
      final neighborCommunities = neighbors
          .map((n) => graph.nodes[n]!.community)
          .where((c) => c != currentCommunity)
          .toSet()
          .toList();
      
      if (neighborCommunities.isEmpty) continue;
      
      // Pick a random neighboring community
      final candidateCommunity = neighborCommunities[_random.nextInt(neighborCommunities.length)];
      
      // Check if moving improves modularity (with gamma factor for Leiden)
      final gain = _modularityGainWithGamma(
        graph, nodeId, currentCommunity, candidateCommunity);
      
      if (gain > config.minImprovement) {
        node.community = candidateCommunity;
      }
    }
  }
  
  /// Calculate modularity gain with gamma parameter (Leiden-specific)
  double _modularityGainWithGamma(
    _Graph graph,
    String nodeId,
    String fromCommunity,
    String toCommunity,
  ) {
    // Use gamma to adjust the resolution in refinement phase
    final baseGain = _modularityGain(graph, nodeId, fromCommunity, toCommunity);
    return baseGain * config.gamma;
  }
  
  /// Update parent-child relationships between two levels of communities
  void _updateParentChildRelationships(
    List<DetectedCommunity> childLevel,
    List<DetectedCommunity> parentLevel,
  ) {
    // For each parent community, find which child communities it contains
    for (var i = 0; i < parentLevel.length; i++) {
      final parent = parentLevel[i];
      final childIds = <String>[];
      
      for (final child in childLevel) {
        // Check if child's entities are subset of parent's entities
        if (child.entityIds.every((e) => parent.entityIds.contains(e))) {
          childIds.add(child.id);
        }
      }
      
      // Update parent with child IDs
      parentLevel[i] = DetectedCommunity(
        id: parent.id,
        level: parent.level,
        entityIds: parent.entityIds,
        modularity: parent.modularity,
        parentCommunityId: parent.parentCommunityId,
        childCommunityIds: childIds,
      );
      
      // Update children with parent ID
      for (var j = 0; j < childLevel.length; j++) {
        if (childIds.contains(childLevel[j].id)) {
          childLevel[j] = DetectedCommunity(
            id: childLevel[j].id,
            level: childLevel[j].level,
            entityIds: childLevel[j].entityIds,
            modularity: childLevel[j].modularity,
            parentCommunityId: parent.id,
            childCommunityIds: childLevel[j].childCommunityIds,
          );
        }
      }
    }
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
  /// nodeToEntityIds maps graph node IDs to original entity IDs
  List<DetectedCommunity> _extractCommunities(
    _Graph graph, 
    int level,
    Map<String, Set<String>> nodeToEntityIds,
  ) {
    final communityNodes = <String, Set<String>>{};
    
    for (final entry in graph.nodes.entries) {
      final communityId = entry.value.community;
      communityNodes.putIfAbsent(communityId, () => {});
      
      // Map graph node to original entity IDs
      final originalEntityIds = nodeToEntityIds[entry.key] ?? {entry.key};
      communityNodes[communityId]!.addAll(originalEntityIds);
    }
    
    return communityNodes.entries.map((entry) {
      return DetectedCommunity(
        id: 'community_${level}_${entry.key}',
        level: level,
        entityIds: entry.value,  // Now contains original entity IDs
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

  /// Maximum entities to include in a summary prompt to avoid token overflow
  static const int _maxEntitiesInPrompt = 15;
  
  /// Maximum relationships to include in a summary prompt
  static const int _maxRelationshipsInPrompt = 20;
  
  /// Maximum characters per entity description
  static const int _maxDescriptionLength = 100;

  /// Generate summary for a community
  Future<CommunitySummary> summarize(
    DetectedCommunity community,
    List<GraphEntity> entities,
    List<GraphRelationship> relationships,
  ) async {
    // Get entities in this community
    var communityEntities = entities
        .where((e) => community.entityIds.contains(e.id))
        .toList();
    
    // Get relationships between entities in this community
    var communityRelationships = relationships
        .where((r) => 
            community.entityIds.contains(r.sourceId) &&
            community.entityIds.contains(r.targetId))
        .toList();
    
    // Limit entities and relationships to prevent token overflow
    // The LLM has limited context (1024 tokens), so we truncate large communities
    if (communityEntities.length > _maxEntitiesInPrompt) {
      print('[CommunitySummarizer] Truncating ${communityEntities.length} entities to $_maxEntitiesInPrompt');
      communityEntities = communityEntities.take(_maxEntitiesInPrompt).toList();
    }
    if (communityRelationships.length > _maxRelationshipsInPrompt) {
      print('[CommunitySummarizer] Truncating ${communityRelationships.length} relationships to $_maxRelationshipsInPrompt');
      communityRelationships = communityRelationships.take(_maxRelationshipsInPrompt).toList();
    }
    
    // Build prompt with truncated descriptions to prevent token overflow
    final entityNames = communityEntities.map((e) => e.name).toList();
    final entityDescriptions = communityEntities
        .map((e) {
          final desc = e.description ?? '';
          // Strip HTML tags and truncate long descriptions
          final cleanDesc = desc
              .replaceAll(RegExp(r'<[^>]*>'), '') // Remove HTML tags
              .replaceAll(RegExp(r'-apple-system[^;]*;'), '') // Remove CSS font families
              .replaceAll(RegExp(r'\s+'), ' ') // Normalize whitespace
              .trim();
          if (cleanDesc.length > _maxDescriptionLength) {
            return '${cleanDesc.substring(0, _maxDescriptionLength)}...';
          }
          return cleanDesc;
        })
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
    
    // Truncate summary for embedding if too long
    // EmbeddingGemma 256 has max ~256 tokens, roughly 4 chars per token = ~1024 chars
    final summaryForEmbedding = summary.length > 800 
        ? summary.substring(0, 800).trim() 
        : summary;
    final embedding = await embeddingCallback(summaryForEmbedding);
    
    return CommunitySummary(
      communityId: community.id,
      summary: summary,
      embedding: embedding,
      entityCount: communityEntities.length,
      relationshipCount: communityRelationships.length,
    );
  }

  /// Generate a hierarchical summary for higher-level communities
  /// This summarizes child community summaries instead of raw entities
  /// Following the GraphRAG paper approach for multi-level summarization
  Future<CommunitySummary> summarizeHierarchical(
    DetectedCommunity community,
    List<CommunitySummary> childSummaries,
  ) async {
    if (childSummaries.isEmpty) {
      // No children, return empty summary
      return CommunitySummary(
        communityId: community.id,
        summary: 'Empty community with no sub-communities.',
        embedding: List.filled(768, 0.0),
        entityCount: community.entityIds.length,
        relationshipCount: 0,
      );
    }

    final childSummaryTexts = childSummaries.map((s) => s.summary).toList();
    
    final prompt = ExtractionPrompts.hierarchicalCommunitySummaryPrompt(
      childSummaryTexts,
      community.level,
    );
    
    final summary = await llmCallback(prompt);
    
    // Truncate summary for embedding if too long
    final summaryForEmbedding = summary.length > 800 
        ? summary.substring(0, 800).trim() 
        : summary;
    final embedding = await embeddingCallback(summaryForEmbedding);
    
    // Count entities and relationships from children
    final totalEntities = childSummaries.fold(0, (sum, s) => sum + s.entityCount);
    final totalRelationships = childSummaries.fold(0, (sum, s) => sum + s.relationshipCount);
    
    return CommunitySummary(
      communityId: community.id,
      summary: summary,
      embedding: embedding,
      entityCount: totalEntities,
      relationshipCount: totalRelationships,
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

  /// Generate hierarchical summaries for all communities level by level
  /// Level 0 (leaf) communities are summarized from entities
  /// Higher levels are summarized from their child community summaries
  Future<List<CommunitySummary>> summarizeAllHierarchical(
    List<DetectedCommunity> communities,
    List<GraphEntity> entities,
    List<GraphRelationship> relationships, {
    void Function(int completed, int total)? onProgress,
  }) async {
    final summaries = <CommunitySummary>[];
    final summaryById = <String, CommunitySummary>{};
    
    // Group communities by level
    final communityByLevel = <int, List<DetectedCommunity>>{};
    var maxLevel = 0;
    for (final community in communities) {
      communityByLevel.putIfAbsent(community.level, () => []).add(community);
      if (community.level > maxLevel) maxLevel = community.level;
    }
    
    var completed = 0;
    final total = communities.length;
    
    // Process level by level, starting from lowest (most granular)
    for (var level = maxLevel; level >= 0; level--) {
      final levelCommunities = communityByLevel[level] ?? [];
      
      for (final community in levelCommunities) {
        CommunitySummary summary;
        
        if (level == maxLevel) {
          // Lowest level: summarize from entities
          summary = await summarize(community, entities, relationships);
        } else {
          // Higher level: summarize from child summaries
          final childIds = community.childCommunityIds ?? [];
          final childSummaries = childIds
              .map((id) => summaryById[id])
              .whereType<CommunitySummary>()
              .toList();
          
          if (childSummaries.isEmpty) {
            // No child summaries found, fall back to entity-based summary
            summary = await summarize(community, entities, relationships);
          } else {
            summary = await summarizeHierarchical(community, childSummaries);
          }
        }
        
        summaries.add(summary);
        summaryById[community.id] = summary;
        
        completed++;
        onProgress?.call(completed, total);
      }
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
