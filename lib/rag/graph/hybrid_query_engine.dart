import 'dart:async';

import 'graph_repository.dart';
import 'cypher_parser.dart';

/// Configuration for hybrid query engine
class HybridQueryConfig {
  /// Weight for Cypher results in fusion (0-1)
  final double cypherWeight;
  
  /// Weight for embedding similarity results in fusion (0-1)
  final double embeddingWeight;
  
  /// Weight for community results in fusion (0-1)
  final double communityWeight;
  
  /// Number of top results from each source
  final int topK;
  
  /// Minimum similarity threshold for embedding search
  final double similarityThreshold;
  
  /// RRF constant for reciprocal rank fusion
  final double rrfK;
  
  /// Include community context in results
  final bool includeCommunityContext;
  
  /// Maximum community level to search
  final int maxCommunityLevel;

  HybridQueryConfig({
    this.cypherWeight = 0.4,
    this.embeddingWeight = 0.4,
    this.communityWeight = 0.2,
    this.topK = 10,
    this.similarityThreshold = 0.5,
    this.rrfK = 60.0,
    this.includeCommunityContext = true,
    this.maxCommunityLevel = 2,
  });
}

/// Result from hybrid query with optional generated answer
class HybridQueryResult {
  /// Retrieved entities with relevance scores
  final List<ScoredQueryEntity> entities;
  
  /// Related community summaries
  final List<ScoredQueryCommunity> communities;
  
  /// Cypher query results (if applicable)
  final List<Map<String, dynamic>>? cypherResults;
  
  /// Combined context string for LLM
  final String contextString;
  
  /// Query metadata
  final QueryMetadata metadata;
  
  /// Generated answer from local retrieval (if answer generation was requested)
  final String? generatedAnswer;

  HybridQueryResult({
    required this.entities,
    required this.communities,
    this.cypherResults,
    required this.contextString,
    required this.metadata,
    this.generatedAnswer,
  });
  
  /// Create a copy with a generated answer
  HybridQueryResult withAnswer(String answer) {
    return HybridQueryResult(
      entities: entities,
      communities: communities,
      cypherResults: cypherResults,
      contextString: contextString,
      metadata: metadata,
      generatedAnswer: answer,
    );
  }
}

/// Entity with query relevance score
class ScoredQueryEntity {
  final GraphEntity entity;
  final double score;
  final String source; // 'cypher', 'embedding', 'community'

  ScoredQueryEntity({
    required this.entity,
    required this.score,
    required this.source,
  });
}

/// Community with query relevance score
class ScoredQueryCommunity {
  final GraphCommunity community;
  final double score;

  ScoredQueryCommunity({
    required this.community,
    required this.score,
  });
}

/// Query metadata
class QueryMetadata {
  final String originalQuery;
  final String? cypherQuery;
  final List<double>? queryEmbedding;
  final int totalEntitiesSearched;
  final int totalCommunitiesSearched;
  final Duration executionTime;

  QueryMetadata({
    required this.originalQuery,
    this.cypherQuery,
    this.queryEmbedding,
    required this.totalEntitiesSearched,
    required this.totalCommunitiesSearched,
    required this.executionTime,
  });
}

/// Hybrid query engine combining Cypher and embedding-based retrieval
class HybridQueryEngine {
  final GraphRepository repository;
  final Future<List<double>> Function(String text) embeddingCallback;
  final Future<String> Function(String prompt)? llmCallback;
  final HybridQueryConfig config;
  
  late final CypherQueryExecutor _cypherExecutor;

  HybridQueryEngine({
    required this.repository,
    required this.embeddingCallback,
    this.llmCallback,
    HybridQueryConfig? config,
  }) : config = config ?? HybridQueryConfig() {
    _cypherExecutor = CypherQueryExecutor(repository);
  }

  /// Execute a hybrid query with optional answer generation
  ///
  /// If [generateAnswer] is true and an LLM callback is available,
  /// generates a focused answer based on retrieved entities.
  Future<HybridQueryResult> queryWithAnswer(
    String query, {
    String? cypherQuery,
    List<String>? entityTypes,
  }) async {
    // First, get the retrieval results
    final result = await this.query(query, cypherQuery: cypherQuery, entityTypes: entityTypes);
    
    // If no LLM callback, return results without answer
    if (llmCallback == null) {
      return result;
    }
    
    // Generate answer from retrieved entities
    final answer = await _generateLocalAnswer(query, result);
    return result.withAnswer(answer);
  }
  
  /// Generate a focused answer from local retrieval results
  Future<String> _generateLocalAnswer(String query, HybridQueryResult result) async {
    if (llmCallback == null) {
      return "Answer generation not available.";
    }
    
    if (result.entities.isEmpty) {
      return "I couldn't find relevant information to answer your question.";
    }
    
    // Build context from top 3 entities (keep very short for token limit)
    final topEntities = result.entities.take(3).toList();
    final entityContext = topEntities.map((scored) {
      final e = scored.entity;
      // Truncate description to 50 chars max
      String desc = '';
      if (e.description != null && e.description!.isNotEmpty) {
        final cleanDesc = e.description!.length > 50 
            ? '${e.description!.substring(0, 50)}...'
            : e.description!;
        desc = ': $cleanDesc';
      }
      return '- ${e.name} (${e.type})$desc';
    }).join('\n');
    
    // Truncate query if too long
    final shortQuery = query.length > 100 ? '${query.substring(0, 100)}...' : query;
    
    // Grounded prompt - only use provided data, no hallucination
    final prompt = '''Answer ONLY using this data. Do NOT add external information.

Data:
$entityContext

Q: $shortQuery

Answer in 1 sentence using ONLY the data above. If insufficient, say "No relevant data found.":''';

    try {
      final response = await llmCallback!(prompt);
      return response.trim();
    } catch (e) {
      return "Unable to generate an answer: $e";
    }
  }
  
  /// Stream tokens while generating a local answer
  Stream<String> queryWithAnswerStreaming(
    String query, {
    String? cypherQuery,
    List<String>? entityTypes,
    required Stream<String> Function(String prompt) llmStreamCallback,
  }) async* {
    // First, get the retrieval results
    final result = await this.query(query, cypherQuery: cypherQuery, entityTypes: entityTypes);
    
    if (result.entities.isEmpty) {
      yield "I couldn't find relevant information to answer your question.";
      return;
    }
    
    // Build context from top entities
    final topEntities = result.entities.take(5).toList();
    final entityContext = topEntities.map((scored) {
      final e = scored.entity;
      final desc = e.description != null && e.description!.isNotEmpty
          ? ': ${e.description}'
          : '';
      return '- ${e.name} (${e.type})$desc';
    }).join('\n');
    
    final communityContext = result.communities.isNotEmpty
        ? '\n\nContext:\n${result.communities.first.community.summary}'
        : '';
    
    final prompt = '''Answer ONLY using the information below. Do NOT add external knowledge.

Entities:
$entityContext$communityContext

Question: $query

Rules:
- Use ONLY entities/context above
- 1-2 sentences maximum
- If insufficient data, say so

Answer:''';

    // Stream the response
    await for (final token in llmStreamCallback(prompt)) {
      yield token;
    }
  }

  /// Execute a hybrid query
  /// 
  /// [query] - Natural language query or Cypher query
  /// [cypherQuery] - Optional explicit Cypher query
  /// [entityTypes] - Optional filter for entity types
  Future<HybridQueryResult> query(
    String query, {
    String? cypherQuery,
    List<String>? entityTypes,
  }) async {
    final stopwatch = Stopwatch()..start();
    
    // Detect if query is Cypher
    final isCypher = _isCypherQuery(query);
    final effectiveCypherQuery = cypherQuery ?? (isCypher ? query : null);
    
    // Get query embedding for semantic search
    final queryEmbedding = await embeddingCallback(query);
    
    // Collect results from different sources
    final entityScores = <String, _ScoreAccumulator>{};
    final communityResults = <ScoredQueryCommunity>[];
    List<Map<String, dynamic>>? cypherResults;
    
    // 1. Execute Cypher query if provided
    if (effectiveCypherQuery != null) {
      try {
        cypherResults = await _cypherExecutor.execute(effectiveCypherQuery);
        
        // Extract entities from Cypher results
        for (var rank = 0; rank < cypherResults.length; rank++) {
          final result = cypherResults[rank];
          
          // Look for entity IDs in result
          for (final value in result.values) {
            if (value is Map<String, dynamic> && value.containsKey('id')) {
              final entityId = value['id'] as String;
              final rrfScore = _rrfScore(rank);
              
              entityScores.putIfAbsent(entityId, () => _ScoreAccumulator());
              entityScores[entityId]!.addScore(
                'cypher',
                rrfScore * config.cypherWeight,
              );
            }
          }
        }
      } catch (e) {
        // Cypher query failed, continue with other methods
      }
    }
    
    // 2. Embedding similarity search for entities
    final embeddingResults = await repository.searchEntitiesBySimilarity(
      queryEmbedding,
      topK: config.topK,
      threshold: config.similarityThreshold,
      entityType: entityTypes?.firstOrNull,
    );
    
    for (var rank = 0; rank < embeddingResults.length; rank++) {
      final result = embeddingResults[rank];
      final rrfScore = _rrfScore(rank);
      
      entityScores.putIfAbsent(result.entity.id, () => _ScoreAccumulator());
      entityScores[result.entity.id]!.addScore(
        'embedding',
        rrfScore * config.embeddingWeight,
      );
      entityScores[result.entity.id]!.entity = result.entity;
    }
    
    // 3. Community search
    if (config.includeCommunityContext) {
      for (var level = 0; level <= config.maxCommunityLevel; level++) {
        final levelResults = await repository.searchCommunitiesBySimilarity(
          queryEmbedding,
          topK: config.topK ~/ 2,
          level: level,
        );
        
        for (var rank = 0; rank < levelResults.length; rank++) {
          final result = levelResults[rank];
          final rrfScore = _rrfScore(rank);
          
          communityResults.add(ScoredQueryCommunity(
            community: result.community,
            score: rrfScore * config.communityWeight * (1 - level * 0.2),
          ));
          
          // Boost entities in this community
          for (final entityId in result.community.entityIds) {
            entityScores.putIfAbsent(entityId, () => _ScoreAccumulator());
            entityScores[entityId]!.addScore(
              'community',
              rrfScore * config.communityWeight * 0.5,
            );
          }
        }
      }
    }
    
    // 4. Fetch missing entities and build final results
    final scoredEntities = <ScoredQueryEntity>[];
    
    for (final entry in entityScores.entries) {
      var entity = entry.value.entity;
      
      // Fetch entity if not already loaded
      if (entity == null) {
        entity = await repository.getEntity(entry.key);
        if (entity == null) continue;
      }
      
      scoredEntities.add(ScoredQueryEntity(
        entity: entity,
        score: entry.value.totalScore,
        source: entry.value.primarySource,
      ));
    }
    
    // Sort by score
    scoredEntities.sort((a, b) => b.score.compareTo(a.score));
    communityResults.sort((a, b) => b.score.compareTo(a.score));
    
    // Apply final topK limit
    final finalEntities = scoredEntities.take(config.topK).toList();
    final finalCommunities = communityResults.take(config.topK ~/ 2).toList();
    
    stopwatch.stop();
    
    // Build context string
    final contextString = _buildContextString(
      finalEntities,
      finalCommunities,
    );
    
    return HybridQueryResult(
      entities: finalEntities,
      communities: finalCommunities,
      cypherResults: cypherResults,
      contextString: contextString,
      metadata: QueryMetadata(
        originalQuery: query,
        cypherQuery: effectiveCypherQuery,
        queryEmbedding: queryEmbedding,
        totalEntitiesSearched: entityScores.length,
        totalCommunitiesSearched: communityResults.length,
        executionTime: stopwatch.elapsed,
      ),
    );
  }

  /// Check if query looks like Cypher
  bool _isCypherQuery(String query) {
    final upperQuery = query.toUpperCase().trim();
    return upperQuery.startsWith('MATCH') ||
           upperQuery.startsWith('RETURN') ||
           upperQuery.contains('WHERE') && upperQuery.contains('MATCH');
  }

  /// Calculate RRF (Reciprocal Rank Fusion) score
  double _rrfScore(int rank) {
    return 1.0 / (config.rrfK + rank);
  }

  /// Build context string for LLM
  String _buildContextString(
    List<ScoredQueryEntity> entities,
    List<ScoredQueryCommunity> communities,
  ) {
    final buffer = StringBuffer();
    
    // Add entity information
    if (entities.isNotEmpty) {
      buffer.writeln('=== Relevant Entities ===\n');
      
      for (final scored in entities) {
        final entity = scored.entity;
        buffer.writeln('**${entity.name}** (${entity.type})');
        if (entity.description != null && entity.description!.isNotEmpty) {
          buffer.writeln(entity.description);
        }
        buffer.writeln();
      }
    }
    
    // Add community context
    if (communities.isNotEmpty) {
      buffer.writeln('=== Community Context ===\n');
      
      for (final scored in communities) {
        final community = scored.community;
        buffer.writeln('**Community at Level ${community.level}:**');
        buffer.writeln(community.summary);
        buffer.writeln();
      }
    }
    
    return buffer.toString();
  }

  /// Generate Cypher query from natural language using patterns
  /// This is a simplified heuristic-based approach
  String? generateCypherFromNL(String query) {
    final lowerQuery = query.toLowerCase();
    
    // Pattern: "who knows X" -> find relationships to person X
    final knowsPattern = RegExp(r'who knows (\w+)', caseSensitive: false);
    var match = knowsPattern.firstMatch(query);
    if (match != null) {
      final name = match.group(1)!;
      return '''
MATCH (p:PERSON)-[:KNOWS|COLLEAGUE_OF]->(target:PERSON {name: "$name"})
RETURN p
LIMIT 10
''';
    }
    
    // Pattern: "events with X" -> find events involving person X
    final eventsPattern = RegExp(r'events? (?:with|involving) (\w+)', caseSensitive: false);
    match = eventsPattern.firstMatch(query);
    if (match != null) {
      final name = match.group(1)!;
      return '''
MATCH (e:EVENT)-[:ATTENDED_BY]->(p:PERSON)
WHERE p.name CONTAINS "$name"
RETURN e, p
LIMIT 10
''';
    }
    
    // Pattern: "people at X" -> find people at organization
    final peopleAtPattern = RegExp(r'people (?:at|from) (\w+)', caseSensitive: false);
    match = peopleAtPattern.firstMatch(query);
    if (match != null) {
      final org = match.group(1)!;
      return '''
MATCH (p:PERSON)-[:WORKS_AT]->(o:ORGANIZATION)
WHERE o.name CONTAINS "$org"
RETURN p, o
LIMIT 10
''';
    }
    
    // Pattern: "contacts from X" -> find contacts from location/org
    final contactsFromPattern = RegExp(r'contacts? from (\w+)', caseSensitive: false);
    match = contactsFromPattern.firstMatch(query);
    if (match != null) {
      final place = match.group(1)!;
      return '''
MATCH (p:PERSON)-[:LOCATED_IN|WORKS_AT]->(loc)
WHERE loc.name CONTAINS "$place"
RETURN p
LIMIT 10
''';
    }
    
    // Pattern: entity type queries
    if (lowerQuery.contains('all people') || lowerQuery.contains('list people')) {
      return '''
MATCH (p:PERSON)
RETURN p
LIMIT 20
''';
    }
    
    if (lowerQuery.contains('all events') || lowerQuery.contains('list events')) {
      return '''
MATCH (e:EVENT)
RETURN e
ORDER BY e.startDate DESC
LIMIT 20
''';
    }
    
    if (lowerQuery.contains('all organizations') || lowerQuery.contains('list organizations')) {
      return '''
MATCH (o:ORGANIZATION)
RETURN o
LIMIT 20
''';
    }
    
    // No pattern matched
    return null;
  }
}

/// Helper class to accumulate scores from multiple sources
class _ScoreAccumulator {
  final Map<String, double> _scores = {};
  GraphEntity? entity;

  void addScore(String source, double score) {
    _scores[source] = (_scores[source] ?? 0) + score;
  }

  double get totalScore => _scores.values.fold(0.0, (a, b) => a + b);

  String get primarySource {
    if (_scores.isEmpty) return 'unknown';
    return _scores.entries
        .reduce((a, b) => a.value > b.value ? a : b)
        .key;
  }
}

/// Query builder for constructing hybrid queries programmatically
class HybridQueryBuilder {
  String? _naturalLanguageQuery;
  String? _cypherQuery;
  List<String>? _entityTypes;
  double? _similarityThreshold;
  int? _topK;
  bool _includeCommunities = true;

  /// Set natural language query
  HybridQueryBuilder query(String query) {
    _naturalLanguageQuery = query;
    return this;
  }

  /// Set explicit Cypher query
  HybridQueryBuilder cypher(String cypher) {
    _cypherQuery = cypher;
    return this;
  }

  /// Filter by entity types
  HybridQueryBuilder types(List<String> types) {
    _entityTypes = types;
    return this;
  }

  /// Set similarity threshold
  HybridQueryBuilder threshold(double threshold) {
    _similarityThreshold = threshold;
    return this;
  }

  /// Set number of results
  HybridQueryBuilder limit(int limit) {
    _topK = limit;
    return this;
  }

  /// Include/exclude community context
  HybridQueryBuilder withCommunities(bool include) {
    _includeCommunities = include;
    return this;
  }

  /// Execute the query
  Future<HybridQueryResult> execute(HybridQueryEngine engine) async {
    if (_naturalLanguageQuery == null) {
      throw StateError('Query is required');
    }

    // Create modified config if needed
    HybridQueryConfig? customConfig;
    if (_similarityThreshold != null || _topK != null || !_includeCommunities) {
      customConfig = HybridQueryConfig(
        similarityThreshold: _similarityThreshold ?? engine.config.similarityThreshold,
        topK: _topK ?? engine.config.topK,
        includeCommunityContext: _includeCommunities,
      );
    }

    // Use a temporary engine with custom config if needed
    final effectiveEngine = customConfig != null
        ? HybridQueryEngine(
            repository: engine.repository,
            embeddingCallback: engine.embeddingCallback,
            config: customConfig,
          )
        : engine;

    return effectiveEngine.query(
      _naturalLanguageQuery!,
      cypherQuery: _cypherQuery,
      entityTypes: _entityTypes,
    );
  }
}

/// Extension methods for query results
extension HybridQueryResultExtension on HybridQueryResult {
  /// Get all unique entity IDs
  Set<String> get entityIds => entities.map((e) => e.entity.id).toSet();

  /// Get entities by type
  List<ScoredQueryEntity> entitiesByType(String type) =>
      entities.where((e) => e.entity.type == type).toList();

  /// Get top N entities
  List<ScoredQueryEntity> topEntities(int n) => entities.take(n).toList();

  /// Check if query found any results
  bool get hasResults => entities.isNotEmpty || communities.isNotEmpty;

  /// Get entity by name (case-insensitive)
  ScoredQueryEntity? findEntity(String name) {
    final lowerName = name.toLowerCase();
    return entities.cast<ScoredQueryEntity?>().firstWhere(
      (e) => e?.entity.name.toLowerCase() == lowerName,
      orElse: () => null,
    );
  }
}
