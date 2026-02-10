import 'dart:async';

import 'entity_extractor.dart';
import 'graph_repository.dart';

/// Configuration for the GraphRAG query engine
class GraphRAGQueryConfig {
  /// Number of top entities from embedding similarity search
  final int topK;

  /// Maximum hop depth for graph traversal from seed entities
  final int maxHops;

  /// Minimum similarity threshold for embedding search
  final double similarityThreshold;

  /// Maximum context window tokens for the LLM
  final int maxContextTokens;

  /// Fraction of maxContextTokens to use as budget (0-1)
  final double contextBudgetRatio;

  /// Include top community context in results
  final bool includeCommunityContext;

  /// Entity types considered "hub" nodes – too generic, excluded from both
  /// seed retrieval results and hop traversal neighbours.
  final Set<String> hubEntityTypes;

  /// Default hub entity types that are excluded from retrieval.
  static const Set<String> defaultHubEntityTypes = {
    EntityTypes.hub
  };

  GraphRAGQueryConfig({
    this.topK = 4,
    this.maxHops = 1,
    this.similarityThreshold = 0.5,
    this.maxContextTokens = 4096,
    this.contextBudgetRatio = 0.9,
    this.includeCommunityContext = true,
    Set<String>? hubEntityTypes,
  }) : hubEntityTypes = hubEntityTypes ?? defaultHubEntityTypes;
}

/// Result from a GraphRAG query with optional generated answer
class GraphRAGQueryResult {
  /// Retrieved entities with relevance scores
  final List<GraphRAGScoredEntity> entities;

  /// Related community summaries
  final List<GraphRAGScoredCommunity> communities;

  /// Combined context string for LLM (token-budget-aware)
  final String contextString;

  /// Query metadata
  final GraphRAGQueryMetadata metadata;

  /// Generated answer from local retrieval (if answer generation was requested)
  final String? generatedAnswer;

  GraphRAGQueryResult({
    required this.entities,
    required this.communities,
    required this.contextString,
    required this.metadata,
    this.generatedAnswer,
  });

  /// Create a copy with a generated answer
  GraphRAGQueryResult withAnswer(String answer) {
    return GraphRAGQueryResult(
      entities: entities,
      communities: communities,
      contextString: contextString,
      metadata: metadata,
      generatedAnswer: answer,
    );
  }
}

/// Entity with query relevance score
class GraphRAGScoredEntity {
  final GraphEntity entity;
  final double score;

  /// 'embedding' for seed entities, 'graph_traversal' for 1-hop neighbors
  final String source;

  GraphRAGScoredEntity({
    required this.entity,
    required this.score,
    required this.source,
  });
}

/// Community with query relevance score
class GraphRAGScoredCommunity {
  final GraphCommunity community;
  final double score;

  GraphRAGScoredCommunity({
    required this.community,
    required this.score,
  });
}

/// Query metadata
class GraphRAGQueryMetadata {
  final String originalQuery;
  final List<double>? queryEmbedding;
  final int seedEntitiesCount;
  final int hopEntitiesCount;
  final int totalEntitiesBeforeBudget;
  final int totalEntitiesAfterBudget;
  final int tokenBudget;
  final int estimatedTokensUsed;
  final Duration executionTime;

  GraphRAGQueryMetadata({
    required this.originalQuery,
    this.queryEmbedding,
    required this.seedEntitiesCount,
    required this.hopEntitiesCount,
    required this.totalEntitiesBeforeBudget,
    required this.totalEntitiesAfterBudget,
    required this.tokenBudget,
    required this.estimatedTokensUsed,
    required this.executionTime,
  });
}

/// GraphRAG query engine: embedding similarity + N-hop graph traversal
/// with token-budget-aware context construction.
///
/// Hub entity types (e.g. DATE, EMAIL, PHONE …) are excluded from both
/// seed retrieval and hop expansion to avoid noisy, highly-connected nodes.
///
/// Retrieval steps:
/// 1. Embedding similarity → top-K seed entities + top-1 community
/// 2. N-hop graph traversal from each seed entity → neighbor entities
/// 3. Token-budget-aware context construction (90% of context window)
///
/// When the token budget is exceeded, entities are discarded in order:
///   a) Hop nodes with lowest scores
///   b) Seed nodes with lowest scores
///   c) Truncate remaining context text
class GraphRAGQueryEngine {
  final GraphRepository repository;
  final Future<List<double>> Function(String text) embeddingCallback;
  final Future<String> Function(String prompt)? llmCallback;
  final GraphRAGQueryConfig config;

  GraphRAGQueryEngine({
    required this.repository,
    required this.embeddingCallback,
    this.llmCallback,
    GraphRAGQueryConfig? config,
  }) : config = config ?? GraphRAGQueryConfig();

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Resolve effective config, applying per-query overrides if provided.
  GraphRAGQueryConfig _effectiveConfig({int? topK, int? maxHops}) {
    if (topK == null && maxHops == null) return config;
    return GraphRAGQueryConfig(
      topK: topK ?? config.topK,
      maxHops: maxHops ?? config.maxHops,
      similarityThreshold: config.similarityThreshold,
      maxContextTokens: config.maxContextTokens,
      contextBudgetRatio: config.contextBudgetRatio,
      includeCommunityContext: config.includeCommunityContext,
      hubEntityTypes: config.hubEntityTypes,
    );
  }

  /// Execute a query and optionally generate an LLM answer
  Future<GraphRAGQueryResult> queryWithAnswer(
    String query, {
    List<String>? entityTypes,
    int? topK,
    int? maxHops,
  }) async {
    final result = await this.query(query, entityTypes: entityTypes, topK: topK, maxHops: maxHops);

    if (llmCallback == null) return result;

    final answer = await _generateLocalAnswer(query, result);
    return result.withAnswer(answer);
  }

  /// Stream tokens while generating a local answer
  Stream<String> queryWithAnswerStreaming(
    String query, {
    List<String>? entityTypes,
    int? topK,
    int? maxHops,
    required Stream<String> Function(String prompt) llmStreamCallback,
  }) async* {
    final result = await this.query(query, entityTypes: entityTypes, topK: topK, maxHops: maxHops);

    if (result.entities.isEmpty) {
      yield "I couldn't find relevant information to answer your question.";
      return;
    }

    // Use the token-budget-aware context string built during retrieval
    final prompt = '''Answer ONLY using the information below. Do NOT add external knowledge.

${result.contextString}

Question: $query

Rules:
- Use ONLY entities/context above
- If insufficient data, say so

Answer:''';

    await for (final token in llmStreamCallback(prompt)) {
      yield token;
    }
  }

  /// Execute a GraphRAG query (embedding similarity + N-hop traversal)
  Future<GraphRAGQueryResult> query(
    String query, {
    List<String>? entityTypes,
    int? topK,
    int? maxHops,
  }) async {
    final stopwatch = Stopwatch()..start();
    final effective = _effectiveConfig(topK: topK, maxHops: maxHops);

    // --- Step 1: Embedding similarity search ---
    final queryEmbedding = await embeddingCallback(query);

    final embeddingResults = await repository.searchEntitiesBySimilarity(
      queryEmbedding,
      topK: effective.topK,
      threshold: effective.similarityThreshold,
      entityType: entityTypes?.firstOrNull,
    );

    // Seed entities with their similarity scores (exclude hub types)
    final seedEntities = <String, GraphRAGScoredEntity>{};
    for (final result in embeddingResults) {
      if (effective.hubEntityTypes.contains(result.entity.type)) continue;
      seedEntities[result.entity.id] = GraphRAGScoredEntity(
        entity: result.entity,
        score: result.score,
        source: 'embedding',
      );
    }

    // Top-1 community
    final communityResults = <GraphRAGScoredCommunity>[];
    if (effective.includeCommunityContext) {
      final comResults = await repository.searchCommunitiesBySimilarity(
        queryEmbedding,
        topK: 1,
      );
      for (final c in comResults) {
        communityResults.add(GraphRAGScoredCommunity(
          community: c.community,
          score: c.score,
        ));
      }
    }

    // --- Step 2: Graph traversal from each seed entity (up to maxHops) ---
    final hopEntities = <String, GraphRAGScoredEntity>{};

    for (final seed in seedEntities.values) {
      final neighbors = await repository.getEntityNeighbors(
        seed.entity.id,
        depth: effective.maxHops,
      );
      for (final neighbor in neighbors) {
        // Skip if already a seed entity
        if (seedEntities.containsKey(neighbor.id)) continue;

        // Skip hub entity types
        if (effective.hubEntityTypes.contains(neighbor.type)) continue;

        // Deduplicate: keep highest score
        final existing = hopEntities[neighbor.id];
        if (existing == null || seed.score > existing.score) {
          hopEntities[neighbor.id] = GraphRAGScoredEntity(
            entity: neighbor,
            score: seed.score, // inherit parent seed score
            source: 'graph_traversal',
          );
        }
      }
    }

    final seedCount = seedEntities.length;
    final hopCount = hopEntities.length;
    final totalBeforeBudget = seedCount + hopCount;

    // --- Step 3: Token-budget-aware context construction ---
    final tokenBudget =
        (effective.maxContextTokens * effective.contextBudgetRatio).toInt();

    // Sort hop entities by score descending for trimming
    final sortedHops = hopEntities.values.toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    // Sort seed entities by score descending for trimming
    final sortedSeeds = seedEntities.values.toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    // Apply budget with priority-based trimming
    final budgetResult = _applyTokenBudget(
      seeds: sortedSeeds,
      hops: sortedHops,
      communities: communityResults,
      tokenBudget: tokenBudget,
    );

    stopwatch.stop();

    return GraphRAGQueryResult(
      entities: budgetResult.entities,
      communities: budgetResult.communities,
      contextString: budgetResult.contextString,
      metadata: GraphRAGQueryMetadata(
        originalQuery: query,
        queryEmbedding: queryEmbedding,
        seedEntitiesCount: seedCount,
        hopEntitiesCount: hopCount,
        totalEntitiesBeforeBudget: totalBeforeBudget,
        totalEntitiesAfterBudget: budgetResult.entities.length,
        tokenBudget: tokenBudget,
        estimatedTokensUsed: budgetResult.estimatedTokens,
        executionTime: stopwatch.elapsed,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Estimate number of tokens for a text string.
  /// Uses ~4 characters per token heuristic (matches codebase convention).
  int _estimateTokens(String text) => (text.length / 4).ceil();

  /// Format a single entity for the context string, including relevant metadata.
  String _formatEntity(GraphRAGScoredEntity scored) {
    final e = scored.entity;
    final buf = StringBuffer();
    buf.write('**${e.name}** (${e.type})');
    if (e.description != null && e.description!.isNotEmpty) {
      buf.write('\n${e.description}');
    }
    // Append useful metadata fields
    final meta = e.metadata;
    if (meta != null && meta.isNotEmpty) {
      final parts = <String>[];
      for (final key in meta.keys) {
        final value = meta[key];
        if (value == null) continue;
        // Skip internal/technical keys
        if (_skipMetadataKeys.contains(key)) continue;
        // Skip empty lists/strings
        if (value is String && value.isEmpty) continue;
        if (value is List && value.isEmpty) continue;
        // Format lists nicely; prettify date-like strings
        final display = value is List
            ? value.join(', ')
            : _formatMetadataValue(value);
        parts.add('$key: $display');
      }
      if (parts.isNotEmpty) {
        buf.write('\n${parts.join(' | ')}');
      }
    }
    buf.writeln();
    return buf.toString();
  }

  /// Metadata keys to exclude from LLM context (internal identifiers, etc.)
  static const _skipMetadataKeys = {
    'sourceId',
    'source_app',
    'path',
    'width',
    'height',
    'mediaType',
    'fileSize',
    'documentType',
    'chunkIndex',
    'chunkCount',
    'totalLength',
    'mimeType',
    'documentId',
    'noteId',
    'alarmId',
    'callId',
  };

  /// Month names for human-readable date formatting.
  static const _months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  /// Format a metadata value, converting ISO-8601 dates to human-readable form.
  static String _formatMetadataValue(dynamic value) {
    if (value is! String) return '$value';
    // Try to parse ISO-8601 date/datetime strings
    final dt = DateTime.tryParse(value);
    if (dt == null) return value;
    final month = _months[dt.month - 1];
    final day = dt.day;
    final year = dt.year;
    // Include time only when it's not midnight (00:00)
    if (dt.hour == 0 && dt.minute == 0) {
      return '$month $day, $year';
    }
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$month $day, $year at $hour:$minute';
  }

  /// Apply token budget with priority-based trimming.
  ///
  /// Discard order:
  ///   1. Hop nodes with lowest scores
  ///   2. Seed nodes with lowest scores
  ///   3. Truncate remaining context text
  _BudgetResult _applyTokenBudget({
    required List<GraphRAGScoredEntity> seeds,
    required List<GraphRAGScoredEntity> hops,
    required List<GraphRAGScoredCommunity> communities,
    required int tokenBudget,
  }) {
    // Pre-compute header tokens
    const entityHeader = '=== Relevant Entities ===\n\n';
    const communityHeader = '\n=== Community Context ===\n\n';
    int runningTokens = _estimateTokens(entityHeader);

    // Reserve space for community context if present
    int communityTokens = 0;
    String communityText = '';
    final survivingCommunities = <GraphRAGScoredCommunity>[];

    if (communities.isNotEmpty) {
      final c = communities.first;
      final cText = '**Community at Level ${c.community.level}:**\n'
          '${c.community.summary}\n';
      communityTokens =
          _estimateTokens(communityHeader) + _estimateTokens(cText);
      communityText = cText;
    }

    // Budget available for entities (reserve community space)
    int entityBudget = tokenBudget - communityTokens;
    if (entityBudget < 0) entityBudget = 0;

    // --- Phase 1: Try to fit all entities (seeds first, then hops) ---
    final allEntities = <GraphRAGScoredEntity>[];
    final entityTexts = <String>[];

    // Add seeds
    for (final seed in seeds) {
      final text = _formatEntity(seed);
      final tokens = _estimateTokens(text);
      if (runningTokens + tokens <= entityBudget) {
        allEntities.add(seed);
        entityTexts.add(text);
        runningTokens += tokens;
      }
    }

    // Add hops (already sorted desc by score)
    for (final hop in hops) {
      final text = _formatEntity(hop);
      final tokens = _estimateTokens(text);
      if (runningTokens + tokens <= entityBudget) {
        allEntities.add(hop);
        entityTexts.add(text);
        runningTokens += tokens;
      }
      // If budget exceeded, remaining hops are silently discarded (lowest scores)
    }

    // If we still exceeded budget (shouldn't happen with above logic,
    // but as safety), trim from the end (hops first, then seeds).
    while (runningTokens > entityBudget && allEntities.isNotEmpty) {
      // Remove last entity (lowest priority: hops were added last)
      final removed = entityTexts.removeLast();
      allEntities.removeLast();
      runningTokens -= _estimateTokens(removed);
    }

    // Include community if fits
    if (communityTokens > 0 &&
        runningTokens + communityTokens <= tokenBudget) {
      survivingCommunities.addAll(communities);
      runningTokens += communityTokens;
    }

    // Sort final entities by score descending for presentation
    allEntities.sort((a, b) => b.score.compareTo(a.score));

    // --- Build context string ---
    final buf = StringBuffer();
    if (allEntities.isNotEmpty) {
      buf.write(entityHeader);
      for (final scored in allEntities) {
        buf.write(_formatEntity(scored));
      }
    }
    if (survivingCommunities.isNotEmpty) {
      buf.write(communityHeader);
      buf.write(communityText);
    }

    String contextString = buf.toString();

    // Phase 3 safety: hard-cap the context string length
    final maxChars = tokenBudget * 4; // inverse of token estimate
    if (contextString.length > maxChars) {
      contextString = '${contextString.substring(0, maxChars)}…';
    }

    return _BudgetResult(
      entities: allEntities,
      communities: survivingCommunities,
      contextString: contextString,
      estimatedTokens: _estimateTokens(contextString),
    );
  }

  /// Generate a focused answer from local retrieval results.
  Future<String> _generateLocalAnswer(
    String query,
    GraphRAGQueryResult result,
  ) async {
    if (llmCallback == null) {
      return 'Answer generation not available.';
    }

    if (result.entities.isEmpty) {
      return "I couldn't find relevant information to answer your question.";
    }

    final shortQuery =
        query.length > 100 ? '${query.substring(0, 100)}...' : query;

    // Use the token-budget-aware context string built during retrieval
    final prompt =
        '''Answer ONLY using this data. Do NOT add external information.

${result.contextString}

Q: $shortQuery

Answer using ONLY the data above. If insufficient, say "No relevant data found.":''';

    try {
      final response = await llmCallback!(prompt);
      return response.trim();
    } catch (e) {
      return 'Unable to generate an answer: $e';
    }
  }
}

/// Internal result of token-budget trimming
class _BudgetResult {
  final List<GraphRAGScoredEntity> entities;
  final List<GraphRAGScoredCommunity> communities;
  final String contextString;
  final int estimatedTokens;

  _BudgetResult({
    required this.entities,
    required this.communities,
    required this.contextString,
    required this.estimatedTokens,
  });
}

/// Extension methods for query results
extension GraphRAGQueryResultExtension on GraphRAGQueryResult {
  /// Get all unique entity IDs
  Set<String> get entityIds => entities.map((e) => e.entity.id).toSet();

  /// Get entities by type
  List<GraphRAGScoredEntity> entitiesByType(String type) =>
      entities.where((e) => e.entity.type == type).toList();

  /// Get top N entities
  List<GraphRAGScoredEntity> topEntities(int n) => entities.take(n).toList();

  /// Check if query found any results
  bool get hasResults => entities.isNotEmpty || communities.isNotEmpty;

  /// Get entity by name (case-insensitive)
  GraphRAGScoredEntity? findEntity(String name) {
    final lowerName = name.toLowerCase();
    return entities.cast<GraphRAGScoredEntity?>().firstWhere(
          (e) => e?.entity.name.toLowerCase() == lowerName,
          orElse: () => null,
        );
  }

  /// Get only seed entities (from embedding similarity)
  List<GraphRAGScoredEntity> get seedEntities =>
      entities.where((e) => e.source == 'embedding').toList();

  /// Get only hop entities (from graph traversal)
  List<GraphRAGScoredEntity> get hopEntities =>
      entities.where((e) => e.source == 'graph_traversal').toList();
}
