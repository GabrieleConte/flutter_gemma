import 'dart:async';

import '../../pigeon.g.dart';

/// Represents a graph entity with optional embedding for similarity search
class GraphEntity {
  final String id;
  final String name;
  final String type;
  final List<double>? embedding;
  final String? description;
  final Map<String, dynamic>? metadata;
  final DateTime lastModified;

  GraphEntity({
    required this.id,
    required this.name,
    required this.type,
    this.embedding,
    this.description,
    this.metadata,
    required this.lastModified,
  });

  /// Create from EntityResult - note: embedding is stored separately
  factory GraphEntity.fromEntityResult(EntityResult result, {List<double>? embedding}) {
    return GraphEntity(
      id: result.id,
      name: result.name,
      type: result.type,
      embedding: embedding,
      description: result.description,
      metadata: result.metadata != null
          ? _parseMetadataJson(result.metadata!)
          : null,
      lastModified: DateTime.fromMillisecondsSinceEpoch(result.lastModified),
    );
  }

  /// Create from EntityWithEmbedding - includes embedding from native layer
  factory GraphEntity.fromEntityWithEmbedding(EntityWithEmbedding result) {
    return GraphEntity(
      id: result.id,
      name: result.name,
      type: result.type,
      embedding: result.embedding,
      description: result.description,
      metadata: result.metadata != null
          ? _parseMetadataJson(result.metadata!)
          : null,
      lastModified: DateTime.fromMillisecondsSinceEpoch(result.lastModified),
    );
  }

  @override
  String toString() =>
      'GraphEntity(id: $id, name: $name, type: $type, description: $description)';
}

/// Represents a relationship between two entities
class GraphRelationship {
  final String id;
  final String sourceId;
  final String targetId;
  final String type;
  final double weight;
  final Map<String, dynamic>? metadata;

  GraphRelationship({
    required this.id,
    required this.sourceId,
    required this.targetId,
    required this.type,
    this.weight = 1.0,
    this.metadata,
  });

  factory GraphRelationship.fromRelationshipResult(RelationshipResult result) {
    return GraphRelationship(
      id: result.id,
      sourceId: result.sourceId,
      targetId: result.targetId,
      type: result.type,
      weight: result.weight,
      metadata: result.metadata != null
          ? _parseMetadataJson(result.metadata!)
          : null,
    );
  }

  @override
  String toString() =>
      'GraphRelationship(id: $id, source: $sourceId -> target: $targetId, type: $type, weight: $weight)';
}

/// Represents a community of entities with a summary
class GraphCommunity {
  final String id;
  final int level;
  final String summary;
  final List<String> entityIds;
  final List<double>? embedding;
  final Map<String, dynamic>? metadata;
  
  /// Child community IDs for hierarchical summarization
  List<String>? get childCommunityIds {
    final children = metadata?['childCommunityIds'];
    if (children is List) {
      return children.whereType<String>().toList();
    }
    return null;
  }

  GraphCommunity({
    required this.id,
    required this.level,
    required this.summary,
    required this.entityIds,
    this.embedding,
    this.metadata,
  });

  /// Create from CommunityResult - note: embedding is stored separately
  factory GraphCommunity.fromCommunityResult(CommunityResult result, {List<double>? embedding}) {
    return GraphCommunity(
      id: result.id,
      level: result.level,
      summary: result.summary,
      // Filter out nulls and cast to non-nullable list
      entityIds: result.entityIds.whereType<String>().toList(),
      embedding: embedding,
      metadata: result.metadata != null
          ? _parseMetadataJson(result.metadata!)
          : null,
    );
  }

  @override
  String toString() =>
      'GraphCommunity(id: $id, level: $level, entities: ${entityIds.length})';
}

/// Search result with similarity score
class ScoredEntity {
  final GraphEntity entity;
  final double score;

  ScoredEntity({required this.entity, required this.score});

  factory ScoredEntity.fromEntityWithScoreResult(EntityWithScoreResult result) {
    return ScoredEntity(
      entity: GraphEntity.fromEntityResult(result.entity),
      score: result.score,
    );
  }
}

/// Community search result with similarity score
class ScoredCommunity {
  final GraphCommunity community;
  final double score;

  ScoredCommunity({required this.community, required this.score});

  factory ScoredCommunity.fromCommunityWithScoreResult(
      CommunityWithScoreResult result) {
    return ScoredCommunity(
      community: GraphCommunity.fromCommunityResult(result.community),
      score: result.score,
    );
  }
}

/// Graph statistics
class GraphStatistics {
  final int entityCount;
  final int relationshipCount;
  final int communityCount;

  GraphStatistics({
    required this.entityCount,
    required this.relationshipCount,
    required this.communityCount,
  });

  factory GraphStatistics.fromGraphStats(GraphStats stats) {
    return GraphStatistics(
      entityCount: stats.entityCount,
      relationshipCount: stats.relationshipCount,
      communityCount: stats.communityCount,
    );
  }
}

/// Repository interface for graph operations
abstract class GraphRepository {
  /// Initialize the graph store with the given database path
  Future<void> initialize(String databasePath);

  /// Close the graph store and release resources
  Future<void> close();

  /// Clear all data from the graph store
  Future<void> clear();

  // Entity operations
  Future<void> addEntity(GraphEntity entity);
  Future<void> updateEntity(String id, {
    String? name,
    String? type,
    List<double>? embedding,
    String? description,
    Map<String, dynamic>? metadata,
    DateTime? lastModified,
  });
  Future<void> deleteEntity(String id);
  Future<GraphEntity?> getEntity(String id);
  Future<List<GraphEntity>> getEntitiesByType(String type);
  /// Get entities with embeddings (for similarity calculations)
  Future<List<GraphEntity>> getEntitiesWithEmbeddingsByType(String type);

  // Relationship operations
  Future<void> addRelationship(GraphRelationship relationship);
  Future<void> deleteRelationship(String id);
  Future<List<GraphRelationship>> getRelationships(String entityId);

  // Community operations
  Future<void> addCommunity(GraphCommunity community);
  Future<void> updateCommunitySummary(
      String id, String summary, List<double> embedding);
  Future<List<GraphCommunity>> getCommunitiesByLevel(int level);

  // Graph traversal
  Future<List<GraphEntity>> getEntityNeighbors(
    String entityId, {
    int depth = 1,
    String? relationshipType,
  });

  // Similarity search
  Future<List<ScoredEntity>> searchEntitiesBySimilarity(
    List<double> queryEmbedding, {
    int topK = 10,
    double threshold = 0.0,
    String? entityType,
  });
  Future<List<ScoredCommunity>> searchCommunitiesBySimilarity(
    List<double> queryEmbedding, {
    int topK = 10,
    int? level,
  });

  // Query execution
  Future<GraphQueryResult> executeQuery(String cypherQuery);

  // Statistics
  Future<GraphStatistics> getStats();
}

/// Native implementation of GraphRepository using Pigeon
class NativeGraphRepository implements GraphRepository {
  final PlatformService _platform;
  bool _isInitialized = false;

  NativeGraphRepository(this._platform);

  @override
  Future<void> initialize(String databasePath) async {
    await _platform.initializeGraphStore(databasePath);
    _isInitialized = true;
  }

  @override
  Future<void> close() async {
    await _platform.closeGraphStore();
    _isInitialized = false;
  }

  @override
  Future<void> clear() async {
    _checkInitialized();
    await _platform.clearGraphStore();
  }

  @override
  Future<void> addEntity(GraphEntity entity) async {
    _checkInitialized();
    await _platform.addEntity(
      id: entity.id,
      name: entity.name,
      type: entity.type,
      embedding: entity.embedding ?? [],
      description: entity.description,
      metadata: entity.metadata != null ? _encodeMetadataJson(entity.metadata!) : null,
      lastModified: entity.lastModified.millisecondsSinceEpoch,
    );
  }

  @override
  Future<void> updateEntity(
    String id, {
    String? name,
    String? type,
    List<double>? embedding,
    String? description,
    Map<String, dynamic>? metadata,
    DateTime? lastModified,
  }) async {
    _checkInitialized();
    await _platform.updateEntity(
      id: id,
      name: name,
      type: type,
      embedding: embedding,
      description: description,
      metadata: metadata != null ? _encodeMetadataJson(metadata) : null,
      lastModified: lastModified?.millisecondsSinceEpoch,
    );
  }

  @override
  Future<void> deleteEntity(String id) async {
    _checkInitialized();
    await _platform.deleteEntity(id);
  }

  @override
  Future<GraphEntity?> getEntity(String id) async {
    _checkInitialized();
    final result = await _platform.getEntity(id);
    return result != null ? GraphEntity.fromEntityResult(result) : null;
  }

  @override
  Future<List<GraphEntity>> getEntitiesByType(String type) async {
    _checkInitialized();
    final results = await _platform.getEntitiesByType(type);
    return results.map((r) => GraphEntity.fromEntityResult(r)).toList();
  }

  @override
  Future<List<GraphEntity>> getEntitiesWithEmbeddingsByType(String type) async {
    _checkInitialized();
    final results = await _platform.getEntitiesWithEmbeddingsByType(type);
    return results.map((r) => GraphEntity.fromEntityWithEmbedding(r)).toList();
  }

  @override
  Future<void> addRelationship(GraphRelationship relationship) async {
    _checkInitialized();
    await _platform.addRelationship(
      id: relationship.id,
      sourceId: relationship.sourceId,
      targetId: relationship.targetId,
      type: relationship.type,
      weight: relationship.weight,
      metadata: relationship.metadata != null
          ? _encodeMetadataJson(relationship.metadata!)
          : null,
    );
  }

  @override
  Future<void> deleteRelationship(String id) async {
    _checkInitialized();
    await _platform.deleteRelationship(id);
  }

  @override
  Future<List<GraphRelationship>> getRelationships(String entityId) async {
    _checkInitialized();
    final results = await _platform.getRelationships(entityId);
    return results
        .map((r) => GraphRelationship.fromRelationshipResult(r))
        .toList();
  }

  @override
  Future<void> addCommunity(GraphCommunity community) async {
    _checkInitialized();
    await _platform.addCommunity(
      id: community.id,
      level: community.level,
      summary: community.summary,
      entityIds: community.entityIds,
      embedding: community.embedding ?? [],
      metadata: community.metadata != null
          ? _encodeMetadataJson(community.metadata!)
          : null,
    );
  }

  @override
  Future<void> updateCommunitySummary(
    String id,
    String summary,
    List<double> embedding,
  ) async {
    _checkInitialized();
    await _platform.updateCommunitySummary(
      id: id,
      summary: summary,
      embedding: embedding,
    );
  }

  @override
  Future<List<GraphCommunity>> getCommunitiesByLevel(int level) async {
    _checkInitialized();
    final results = await _platform.getCommunitiesByLevel(level);
    return results.map((r) => GraphCommunity.fromCommunityResult(r)).toList();
  }

  @override
  Future<List<GraphEntity>> getEntityNeighbors(
    String entityId, {
    int depth = 1,
    String? relationshipType,
  }) async {
    _checkInitialized();
    final results = await _platform.getEntityNeighbors(
      entityId: entityId,
      depth: depth,
      relationshipType: relationshipType,
    );
    return results.map((r) => GraphEntity.fromEntityResult(r)).toList();
  }

  @override
  Future<List<ScoredEntity>> searchEntitiesBySimilarity(
    List<double> queryEmbedding, {
    int topK = 10,
    double threshold = 0.0,
    String? entityType,
  }) async {
    _checkInitialized();
    final results = await _platform.searchEntitiesBySimilarity(
      queryEmbedding: queryEmbedding,
      topK: topK,
      threshold: threshold,
      entityType: entityType,
    );
    return results.map((r) => ScoredEntity.fromEntityWithScoreResult(r)).toList();
  }

  @override
  Future<List<ScoredCommunity>> searchCommunitiesBySimilarity(
    List<double> queryEmbedding, {
    int topK = 10,
    int? level,
  }) async {
    _checkInitialized();
    final results = await _platform.searchCommunitiesBySimilarity(
      queryEmbedding: queryEmbedding,
      topK: topK,
      level: level,
    );
    return results
        .map((r) => ScoredCommunity.fromCommunityWithScoreResult(r))
        .toList();
  }

  @override
  Future<GraphQueryResult> executeQuery(String cypherQuery) async {
    _checkInitialized();
    return await _platform.executeGraphQuery(cypherQuery);
  }

  @override
  Future<GraphStatistics> getStats() async {
    _checkInitialized();
    final stats = await _platform.getGraphStats();
    return GraphStatistics.fromGraphStats(stats);
  }

  void _checkInitialized() {
    if (!_isInitialized) {
      throw StateError('Graph repository not initialized. Call initialize() first.');
    }
  }
}

// Helper functions for JSON metadata
Map<String, dynamic> _parseMetadataJson(String json) {
  // Simple JSON parsing - in production use dart:convert
  try {
    // Using basic pattern matching for simple JSON
    final result = <String, dynamic>{};
    if (json.startsWith('{') && json.endsWith('}')) {
      final content = json.substring(1, json.length - 1);
      if (content.isEmpty) return result;
      
      // This is a simplified parser - for production, use jsonDecode
      final pairs = _splitJsonPairs(content);
      for (final pair in pairs) {
        final colonIdx = pair.indexOf(':');
        if (colonIdx > 0) {
          final key = pair.substring(0, colonIdx).trim();
          final value = pair.substring(colonIdx + 1).trim();
          
          // Remove quotes from key
          final cleanKey = key.startsWith('"') && key.endsWith('"')
              ? key.substring(1, key.length - 1)
              : key;
          
          // Parse value
          result[cleanKey] = _parseJsonValue(value);
        }
      }
    }
    return result;
  } catch (e) {
    return <String, dynamic>{'_raw': json};
  }
}

List<String> _splitJsonPairs(String content) {
  final pairs = <String>[];
  var depth = 0;
  var start = 0;
  var inString = false;
  
  for (var i = 0; i < content.length; i++) {
    final char = content[i];
    
    if (char == '"' && (i == 0 || content[i - 1] != '\\')) {
      inString = !inString;
    } else if (!inString) {
      if (char == '{' || char == '[') {
        depth++;
      } else if (char == '}' || char == ']') {
        depth--;
      } else if (char == ',' && depth == 0) {
        pairs.add(content.substring(start, i).trim());
        start = i + 1;
      }
    }
  }
  
  if (start < content.length) {
    pairs.add(content.substring(start).trim());
  }
  
  return pairs;
}

dynamic _parseJsonValue(String value) {
  if (value.startsWith('"') && value.endsWith('"')) {
    return value.substring(1, value.length - 1);
  } else if (value == 'true') {
    return true;
  } else if (value == 'false') {
    return false;
  } else if (value == 'null') {
    return null;
  } else if (value.startsWith('[') && value.endsWith(']')) {
    // Array - simplified parsing
    return <dynamic>[];
  } else if (value.startsWith('{') && value.endsWith('}')) {
    // Object - recursive parsing
    return _parseMetadataJson(value);
  } else {
    // Try number
    final numValue = num.tryParse(value);
    return numValue ?? value;
  }
}

String _encodeMetadataJson(Map<String, dynamic> metadata) {
  final pairs = metadata.entries.map((e) {
    final key = '"${e.key}"';
    final value = _encodeJsonValue(e.value);
    return '$key:$value';
  });
  return '{${pairs.join(',')}}';
}

String _encodeJsonValue(dynamic value) {
  if (value == null) {
    return 'null';
  } else if (value is String) {
    return '"${value.replaceAll('"', '\\"')}"';
  } else if (value is bool) {
    return value.toString();
  } else if (value is num) {
    return value.toString();
  } else if (value is List) {
    final items = value.map((v) => _encodeJsonValue(v)).join(',');
    return '[$items]';
  } else if (value is Map<String, dynamic>) {
    return _encodeMetadataJson(value);
  } else {
    return '"$value"';
  }
}
