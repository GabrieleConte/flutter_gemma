import 'dart:async';

import '../utils/math_utils.dart';
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

  /// Community context is dropped when entity tokens alone exceed this
  /// fraction of the total token budget (0-1). Prevents community context
  /// from crowding out entity information.
  final double communityDropThreshold;

  /// Include top community context in results
  final bool includeCommunityContext;

  /// Entity types considered "hub" nodes – too generic, excluded from both
  /// seed retrieval results and hop traversal neighbours.
  /// HUB nodes are still used as pass-through during graph traversal
  /// (edges through them are followed) but they are excluded from the
  /// final result set and LLM context.
  final Set<String> hubEntityTypes;

  /// Default hub entity types that are excluded from retrieval.
  static const Set<String> defaultHubEntityTypes = {EntityTypes.hub};

  /// Score boost multiplier for personal entity types (NOTE, PHOTO, ALARM,
  /// PERSON, PHONE_CALL). Applied to both seed and hop similarity scores
  /// so personal data floats above noisy document chunks.
  final double personalEntityBoost;

  /// Entity types considered "personal" – receive [personalEntityBoost].
  static const Set<String> personalEntityTypes = {
    EntityTypes.note,
    EntityTypes.photo,
    EntityTypes.alarm,
    EntityTypes.person,
    EntityTypes.phoneCall,
  };

  GraphRAGQueryConfig({
    this.topK = 4,
    this.maxHops = 1,
    this.similarityThreshold = 0.5,
    this.maxContextTokens = 4096,
    this.contextBudgetRatio = 0.9,
    this.communityDropThreshold = 0.7,
    this.includeCommunityContext = false,
    this.personalEntityBoost = 1.1,
    Set<String>? hubEntityTypes,
  }) : hubEntityTypes = hubEntityTypes ?? defaultHubEntityTypes;
}

/// Result from a GraphRAG query with optional generated answer
class GraphRAGQueryResult {
  /// Retrieved entities with relevance scores
  final List<GraphRAGScoredEntity> entities;

  /// Retrieved relationships connecting entities in the context
  final List<GraphRelationship> relationships;

  /// Related community summaries
  final List<GraphRAGScoredCommunity> communities;

  /// Combined context string for LLM (token-budget-aware)
  final String contextString;

  /// Query metadata
  final GraphRAGQueryMetadata metadata;

  /// Generated answer from local retrieval (if answer generation was requested)
  final String? generatedAnswer;

  /// The full prompt sent to the LLM (system + context + question).
  /// Populated only when answer generation is performed.
  final String? fullPrompt;

  GraphRAGQueryResult({
    required this.entities,
    this.relationships = const [],
    required this.communities,
    required this.contextString,
    required this.metadata,
    this.generatedAnswer,
    this.fullPrompt,
  });

  /// Create a copy with a generated answer and optionally the full prompt.
  GraphRAGQueryResult withAnswer(String answer, {String? fullPrompt}) {
    return GraphRAGQueryResult(
      entities: entities,
      relationships: relationships,
      communities: communities,
      contextString: contextString,
      metadata: metadata,
      generatedAnswer: answer,
      fullPrompt: fullPrompt,
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
  final int relationshipsCount;
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
    this.relationshipsCount = 0,
    required this.tokenBudget,
    required this.estimatedTokensUsed,
    required this.executionTime,
  });
}

/// GraphRAG query engine: embedding similarity + N-hop graph traversal
/// with relationship-aware, token-budget-aware context construction.
///
/// Hub entity types (e.g. HUB) are excluded from both seed retrieval and
/// hop expansion to avoid noisy, highly-connected nodes. DATE entities are
/// kept in the graph for traversal but excluded from the LLM context since
/// their information is already conveyed through relationships.
///
/// Retrieval steps:
/// 1. Embedding similarity → top-K seed entities + top-1 community
/// 2. N-hop graph traversal from each seed entity → neighbor entities
/// 3. Fetch relationships connecting retrieved entities
/// 4. Token-budget-aware context construction with relationship grouping
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
      communityDropThreshold: config.communityDropThreshold,
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
    final result = await this
        .query(query, entityTypes: entityTypes, topK: topK, maxHops: maxHops);

    if (llmCallback == null) return result;

    final prompt = _buildAnswerPrompt(query, result.contextString);
    final answer = await _generateLocalAnswer(query, result);
    return result.withAnswer(answer, fullPrompt: prompt);
  }

  /// Stream tokens while generating a local answer
  Stream<String> queryWithAnswerStreaming(
    String query, {
    List<String>? entityTypes,
    int? topK,
    int? maxHops,
    required Stream<String> Function(String prompt) llmStreamCallback,
  }) async* {
    final result = await this
        .query(query, entityTypes: entityTypes, topK: topK, maxHops: maxHops);

    if (result.entities.isEmpty) {
      yield "I couldn't find relevant information to answer your question.";
      return;
    }

    final prompt = _buildAnswerPrompt(query, result.contextString);

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
    // Personal entity types receive a configurable score boost so they
    // float above noisy document chunks in the ranking.
    final seedEntities = <String, GraphRAGScoredEntity>{};
    for (final result in embeddingResults) {
      if (effective.hubEntityTypes.contains(result.entity.type)) continue;
      final boost = GraphRAGQueryConfig.personalEntityTypes
              .contains(result.entity.type)
          ? effective.personalEntityBoost
          : 1.0;
      seedEntities[result.entity.id] = GraphRAGScoredEntity(
        entity: result.entity,
        score: result.score * boost,
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
    // Collect all unique neighbor IDs first, then batch-fetch embeddings.
    // HUB nodes are used as pass-through: we follow edges through them
    // to reach entities on the other side, but exclude HUBs themselves
    // from the result set.
    final neighborIdSet = <String>{};
    final neighborEntities = <String, GraphEntity>{};

    for (final seed in seedEntities.values) {
      final neighbors = await repository.getEntityNeighbors(
        seed.entity.id,
        depth: effective.maxHops,
      );

      // Collect direct neighbors and pass-through HUB neighbors
      final hubIds = <String>[];
      for (final neighbor in neighbors) {
        if (seedEntities.containsKey(neighbor.id)) continue;
        if (effective.hubEntityTypes.contains(neighbor.type)) {
          // HUB node: remember for pass-through expansion
          hubIds.add(neighbor.id);
          continue;
        }
        neighborIdSet.add(neighbor.id);
        neighborEntities[neighbor.id] = neighbor;
      }

      // Pass-through: expand HUB neighbors one more hop to reach
      // entities on the other side of the hub (e.g. hub_notes → note_X)
      for (final hubId in hubIds) {
        final hubNeighbors = await repository.getEntityNeighbors(
          hubId,
          depth: 1,
        );
        for (final hn in hubNeighbors) {
          if (seedEntities.containsKey(hn.id)) continue;
          if (effective.hubEntityTypes.contains(hn.type)) continue;
          if (hn.id == seed.entity.id) continue; // skip back-link
          neighborIdSet.add(hn.id);
          neighborEntities[hn.id] = hn;
        }
      }
    }

    // Batch-fetch embeddings for all hop candidates and compute similarity
    final hopEntities = <String, GraphRAGScoredEntity>{};
    if (neighborIdSet.isNotEmpty) {
      final entitiesWithEmbeddings = await repository
          .getEntitiesWithEmbeddingsByIds(neighborIdSet.toList());
      final embeddingMap = <String, List<double>>{};
      for (final e in entitiesWithEmbeddings) {
        if (e.embedding != null) {
          embeddingMap[e.id] = e.embedding!;
        }
      }

      for (final id in neighborIdSet) {
        final embedding = embeddingMap[id];
        if (embedding == null) continue; // skip entities without embeddings

        final similarity =
            MathUtils.cosineSimilarity(queryEmbedding, embedding);
        final boost = GraphRAGQueryConfig.personalEntityTypes
                .contains(neighborEntities[id]!.type)
            ? effective.personalEntityBoost
            : 1.0;
        hopEntities[id] = GraphRAGScoredEntity(
          entity: neighborEntities[id]!,
          score: similarity * boost,
          source: 'graph_traversal',
        );
      }
    }

    final seedCount = seedEntities.length;
    final hopCount = hopEntities.length;
    final totalBeforeBudget = seedCount + hopCount;

    // --- Step 3: Fetch relationships connecting retrieved entities ---
    final allEntityIds = <String>{
      ...seedEntities.keys,
      ...hopEntities.keys,
    };
    final allEntityMap = <String, GraphEntity>{
      for (final e in seedEntities.values) e.entity.id: e.entity,
      for (final e in hopEntities.values) e.entity.id: e.entity,
    };
    final contextRelationships =
        await _fetchContextRelationships(allEntityIds, allEntityMap);

    // --- Step 4: Token-budget-aware context construction ---
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
      relationships: contextRelationships,
      entityMap: allEntityMap,
      communities: communityResults,
      tokenBudget: tokenBudget,
      communityDropThreshold: effective.communityDropThreshold,
    );

    stopwatch.stop();

    return GraphRAGQueryResult(
      entities: budgetResult.entities,
      relationships: contextRelationships,
      communities: budgetResult.communities,
      contextString: budgetResult.contextString,
      metadata: GraphRAGQueryMetadata(
        originalQuery: query,
        queryEmbedding: queryEmbedding,
        seedEntitiesCount: seedCount,
        hopEntitiesCount: hopCount,
        totalEntitiesBeforeBudget: totalBeforeBudget,
        totalEntitiesAfterBudget: budgetResult.entities.length,
        relationshipsCount: contextRelationships.length,
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

  /// Fetch relationships between retrieved entities, filtering out noise.
  ///
  /// Keeps relationships where both endpoints are in the retrieved entity set.
  /// Excludes HUB-originating relationships (HAS_EVENT, HAS_DATA, etc.)
  /// and auto-generated RELATED_TO links (embedding similarity predictions).
  Future<List<GraphRelationship>> _fetchContextRelationships(
    Set<String> entityIds,
    Map<String, GraphEntity> entityMap,
  ) async {
    final seen = <String>{};
    final result = <GraphRelationship>[];

    for (final id in entityIds) {
      final rels = await repository.getRelationships(id);
      for (final rel in rels) {
        // Deduplicate (relationships appear from both endpoints)
        if (seen.contains(rel.id)) continue;
        seen.add(rel.id);

        // Both endpoints must be in retrieved set
        if (!entityIds.contains(rel.sourceId) ||
            !entityIds.contains(rel.targetId)) {
          continue;
        }

        // Skip hub-originating relationships
        final sourceType = entityMap[rel.sourceId]?.type;
        final targetType = entityMap[rel.targetId]?.type;
        if (sourceType == EntityTypes.hub || targetType == EntityTypes.hub) {
          continue;
        }

        // Skip auto-generated RELATED_TO (embedding similarity predictions)
        if (rel.type == RelationshipTypes.relatedTo) continue;

        result.add(rel);
      }
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Entity type display names (human-readable labels)
  // ---------------------------------------------------------------------------

  /// Human-readable labels for entity types shown in context.
  static const _entityTypeLabels = {
    EntityTypes.person: 'Person',
    EntityTypes.organization: 'Organization',
    EntityTypes.location: 'Location',
    EntityTypes.event: 'Calendar Event',
    EntityTypes.date: 'Date',
    EntityTypes.project: 'Project',
    EntityTypes.document: 'Document',
    EntityTypes.email: 'Email',
    EntityTypes.phone: 'Phone',
    EntityTypes.skill: 'Skill',
    EntityTypes.topic: 'Topic',
    EntityTypes.note: 'Note',
    EntityTypes.noteChunk: 'Note Excerpt',
    EntityTypes.phoneCall: 'Phone Call',
    EntityTypes.alarm: 'Alarm',
    EntityTypes.photo: 'Photo',
  };

  /// Get human-readable label for an entity type, with fallback.
  static String _entityTypeLabel(String type) =>
      _entityTypeLabels[type] ?? type;

  // ---------------------------------------------------------------------------
  // Relationship type human-readable labels
  // ---------------------------------------------------------------------------

  /// Human-readable relationship descriptions for context rendering.
  static const _relationshipLabels = {
    RelationshipTypes.worksAt: 'works at',
    RelationshipTypes.worksFor: 'works for',
    RelationshipTypes.colleagueOf: 'colleague of',
    RelationshipTypes.knows: 'knows',
    RelationshipTypes.attendedBy: 'attended by',
    RelationshipTypes.locatedIn: 'located in',
    RelationshipTypes.partOf: 'part of',
    RelationshipTypes.createdBy: 'created by',
    RelationshipTypes.ownedBy: 'owned by',
    RelationshipTypes.mentionedIn: 'mentioned in',
    RelationshipTypes.relatedTo: 'related to',
    RelationshipTypes.hasSkill: 'has skill',
    RelationshipTypes.interestedIn: 'interested in',
    RelationshipTypes.contactOf: 'contact of',
    RelationshipTypes.scheduledFor: 'scheduled for',
    RelationshipTypes.calledContact: 'called',
    RelationshipTypes.receivedCallFrom: 'received call from',
    RelationshipTypes.takenAt: 'taken at',
    RelationshipTypes.takenOn: 'taken on',
    RelationshipTypes.picturedIn: 'pictured in',
    RelationshipTypes.createdOn: 'created on',
    RelationshipTypes.modifiedOn: 'modified on',
    RelationshipTypes.setFor: 'set for',
    RelationshipTypes.recurringOn: 'recurring on',
    RelationshipTypes.occursOn: 'occurs on',
    RelationshipTypes.occurredOn: 'occurred on',
  };

  /// Get human-readable label for a relationship type, with fallback.
  static String _relationshipLabel(String type) =>
      _relationshipLabels[type] ?? type.toLowerCase().replaceAll('_', ' ');

  // ---------------------------------------------------------------------------
  // Entity formatting — type-specific, human-readable context for the LLM
  // ---------------------------------------------------------------------------

  /// Entity types that are purely structural (graph connectivity nodes)
  /// and should not appear as standalone entries in the LLM context.
  /// They are still used during graph traversal and their information is
  /// conveyed through relationship labels instead.
  static const _contextExcludedTypes = {EntityTypes.date};

  /// Format a single entity for the context string using type-specific
  /// formatting for optimal LLM comprehension.
  String _formatEntity(
    GraphRAGScoredEntity scored, {
    List<_ResolvedRelationship>? outgoing,
  }) {
    final e = scored.entity;
    final buf = StringBuffer();

    // --- Type-specific formatting ---
    switch (e.type) {
      case EntityTypes.person:
        _formatPerson(buf, e);
      case EntityTypes.event:
        _formatEvent(buf, e);
      case EntityTypes.photo:
        _formatPhoto(buf, e);
      case EntityTypes.phoneCall:
        _formatPhoneCall(buf, e);
      case EntityTypes.alarm:
        _formatAlarm(buf, e);
      case EntityTypes.note:
        _formatNote(buf, e);
      case EntityTypes.noteChunk:
        _formatNoteChunk(buf, e);
      case EntityTypes.document:
        _formatDocument(buf, e);
      case EntityTypes.documentChunk:
        _formatDocumentChunk(buf, e);
      default:
        // Generic formatting for ORGANIZATION, LOCATION, SKILL, TOPIC, etc.
        _formatGeneric(buf, e);
    }

    // --- Append outgoing relationships ---
    if (outgoing != null && outgoing.isNotEmpty) {
      for (final rel in outgoing) {
        final label = _relationshipLabel(rel.type);
        final targetLabel = _entityTypeLabel(rel.targetType);
        buf.writeln('  → $label → ${rel.targetName} ($targetLabel)');
      }
    }

    buf.writeln();
    return buf.toString();
  }

  /// Format PERSON entity: name, job, contact info.
  void _formatPerson(StringBuffer buf, GraphEntity e) {
    buf.write('${e.name} (${_entityTypeLabel(e.type)})');
    final meta = e.metadata;
    if (e.description != null && e.description!.isNotEmpty) {
      buf.write(' — ${e.description}');
    } else if (meta != null && meta['jobTitle'] != null) {
      buf.write(' — ${meta['jobTitle']}');
    }
    buf.writeln();
    if (meta != null) {
      final parts = <String>[];
      final emails = meta['emails'];
      if (emails is List && emails.isNotEmpty) {
        parts.add('email: ${emails.join(', ')}');
      }
      // Support both plural 'phones' (list) and singular 'phoneNumber' (string)
      final phones = meta['phones'];
      final phoneNumber = meta['phoneNumber'];
      if (phones is List && phones.isNotEmpty) {
        parts.add('phone: ${phones.join(', ')}');
      } else if (phoneNumber is String && phoneNumber.isNotEmpty) {
        parts.add('phone: $phoneNumber');
      }
      if (parts.isNotEmpty) buf.writeln('  ${parts.join(' | ')}');
    }
  }

  /// Format EVENT entity: title, date range, recurrence, description.
  void _formatEvent(StringBuffer buf, GraphEntity e) {
    buf.write('${e.name} (${_entityTypeLabel(e.type)})');
    final meta = e.metadata;
    if (meta != null) {
      final startDate = _formatDateTimeValue(meta['startDate']);
      final endDate = _formatDateTimeValue(meta['endDate']);
      if (startDate != null) {
        buf.write(' — $startDate');
        if (endDate != null && endDate != startDate) buf.write(' to $endDate');
      }
      final recurrence = meta['recurrenceInfo']?.toString();
      if (recurrence == 'recurrent') {
        final freq = meta['repeatFrequency']?.toString();
        final on = meta['on']?.toString();
        final recParts = <String>[];
        if (freq != null) recParts.add(freq);
        if (on != null) recParts.add('on $on');
        if (recParts.isNotEmpty) buf.write(' (${recParts.join(', ')})');
      }
    }
    buf.writeln();
    if (e.description != null && e.description!.isNotEmpty) {
      // Truncate long event descriptions (e.g. holiday boilerplate)
      final desc = e.description!.length > 150
          ? '${e.description!.substring(0, 150)}…'
          : e.description!;
      buf.writeln('  $desc');
    }
  }

  /// Format PHOTO entity: filename, human-readable date.
  void _formatPhoto(StringBuffer buf, GraphEntity e) {
    buf.write('${e.name} (${_entityTypeLabel(e.type)})');
    final meta = e.metadata;
    if (meta != null) {
      final dateStr = _formatDateTimeValue(meta['creationDate']);
      if (dateStr != null) buf.write(' — taken on $dateStr');
    }
    final desc = e.description;
    if (desc != null && desc.isNotEmpty) {
      buf.write(' — $desc');
    }
    buf.writeln();
  }

  /// Format PHONE_CALL entity: call direction, contact, timestamp, duration.
  void _formatPhoneCall(StringBuffer buf, GraphEntity e) {
    buf.write('${e.name} (${_entityTypeLabel(e.type)})');
    final meta = e.metadata;
    if (meta != null) {
      final direction = meta['callDirection']?.toString();
      if (direction != null) buf.write(' [$direction]');
      final dateStr =
          _formatDateTimeValue(meta['timestamp'] ?? meta['startTime']);
      if (dateStr != null) buf.write(' — $dateStr');
      final duration = meta['duration']?.toString();
      if (duration != null && duration.isNotEmpty) {
        buf.write(', ${_formatDuration(duration)}');
      }
    }
    buf.writeln();
  }

  /// Format ALARM entity: label, time, recurrence from metadata fields.
  ///
  /// Reads metadata directly for consistent output across indexing paths
  /// (DirectEntityExtractor stores `recurrenceType`, `repeatFrequency`, `on`,
  /// `date`, `time`, `label`; `indexAlarmContent` stores `recurrence`,
  /// `date`, `time`). Falls back to `e.description` when metadata is absent.
  void _formatAlarm(StringBuffer buf, GraphEntity e) {
    buf.write('${e.name} (${_entityTypeLabel(e.type)})');
    final meta = e.metadata;
    if (meta != null) {
      final time = meta['time']?.toString();
      final isRecurrent = meta['recurrenceType'] == 'recurrent' ||
          meta['recurrence']?.toString().isNotEmpty == true;

      if (isRecurrent) {
        // Recurrent alarm: show time + frequency + days
        final freq = meta['repeatFrequency']?.toString() ??
            meta['recurrence']?.toString();
        final on = meta['on']?.toString();
        final parts = <String>[];
        if (time != null) parts.add(time);
        if (freq != null) parts.add(freq);
        if (on != null) parts.add('on $on');
        if (parts.isNotEmpty) buf.write(' — ${parts.join(', ')}');
      } else {
        // Single-occurrence alarm: show time + date
        final date = _formatDateTimeValue(meta['date']);
        final parts = <String>[];
        if (time != null) parts.add(time);
        if (date != null) parts.add('on $date');
        if (parts.isNotEmpty) buf.write(' — ${parts.join(' ')}');
      }
    } else if (e.description != null && e.description!.isNotEmpty) {
      buf.write(' — ${e.description}');
    }
    buf.writeln();
  }

  /// Format NOTE entity: title, creation date, content preview.
  /// Uses fullContent from metadata when available and when it fits within
  /// the configured token budget; otherwise falls back to the description.
  void _formatNote(StringBuffer buf, GraphEntity e) {
    buf.write('${e.name} (${_entityTypeLabel(e.type)})');
    final meta = e.metadata;
    if (meta != null) {
      final dateStr = _formatDateTimeValue(meta['dateCreated']);
      if (dateStr != null) buf.write(' — created $dateStr');
    }
    buf.writeln();
    // Prefer fullContent when available and fits within half the token budget
    final fullContent = meta?['fullContent'];
    final maxNoteChars = config.maxContextTokens * 2; // ~half budget in chars
    if (fullContent is String &&
        fullContent.isNotEmpty &&
        fullContent.length <= maxNoteChars) {
      buf.writeln('  $fullContent');
    } else if (e.description != null && e.description!.isNotEmpty) {
      buf.writeln('  ${e.description}');
    }
  }

  /// Format NOTE_CHUNK entity: title (part X/Y) + content preview.
  void _formatNoteChunk(StringBuffer buf, GraphEntity e) {
    buf.write('${e.name} (${_entityTypeLabel(e.type)})');
    buf.writeln();
    if (e.description != null && e.description!.isNotEmpty) {
      final preview = e.description!.length > 200
          ? '${e.description!.substring(0, 200)}…'
          : e.description!;
      buf.writeln('  $preview');
    }
  }

  /// Format DOCUMENT entity: name, type, dates.
  void _formatDocument(StringBuffer buf, GraphEntity e) {
    buf.write('${e.name} (${_entityTypeLabel(e.type)})');
    if (e.description != null && e.description!.isNotEmpty) {
      final preview = e.description!.length > 200
          ? '${e.description!.substring(0, 200)}…'
          : e.description!;
      buf.write(' — $preview');
    }
    buf.writeln();
  }

  /// Format DOCUMENT_CHUNK entity: title (part X/Y) + content preview.
  void _formatDocumentChunk(StringBuffer buf, GraphEntity e) {
    buf.write('${e.name} (${_entityTypeLabel(e.type)})');
    buf.writeln();
    if (e.description != null && e.description!.isNotEmpty) {
      final preview = e.description!.length > 200
          ? '${e.description!.substring(0, 200)}…'
          : e.description!;
      buf.writeln('  $preview');
    }
  }

  /// Generic formatting for entity types without specialized formatting.
  void _formatGeneric(StringBuffer buf, GraphEntity e) {
    buf.write('${e.name} (${_entityTypeLabel(e.type)})');
    if (e.description != null && e.description!.isNotEmpty) {
      buf.write(' — ${e.description}');
    }
    buf.writeln();
    // Show non-skipped metadata for generic types
    final meta = e.metadata;
    if (meta != null && meta.isNotEmpty) {
      final parts = <String>[];
      for (final key in meta.keys) {
        final value = meta[key];
        if (value == null) continue;
        if (_skipMetadataKeys.contains(key)) continue;
        if (value is String && value.isEmpty) continue;
        if (value is List && value.isEmpty) continue;
        final display =
            value is List ? value.join(', ') : _formatMetadataValue(value);
        parts.add('${_humanizeKey(key)}: $display');
      }
      if (parts.isNotEmpty) {
        buf.writeln('  ${parts.join(' | ')}');
      }
    }
  }

  /// Metadata keys to exclude from LLM context (internal identifiers, etc.)
  static const _skipMetadataKeys = {
    'sourceId',
    'source_app',
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
    'parentNoteId',
    'recurrenceType',
    'recurrence',
    'predictionMethod',
  };

  /// Month names for human-readable date formatting.
  static const _months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  /// Parse a dynamic value (ISO-8601 string, epoch millis string, int, or
  /// DateTime) into a human-readable date/time string.
  ///
  /// Handles the real data patterns found in the graph:
  /// - ISO-8601: `"2025-02-14T01:00:00.000"`
  /// - Epoch millis as string: `"1770670730000"`
  /// - Epoch millis as int: `1770670730000`
  /// - Date-only: `"2025-02-14"`
  static String? _formatDateTimeValue(dynamic value) {
    if (value == null) return null;
    final dt = _parseDateTimeValue(value);
    if (dt == null) return null;
    final month = _months[dt.month - 1];
    final day = dt.day;
    final year = dt.year;
    if (dt.hour == 0 && dt.minute == 0) {
      return '$month $day, $year';
    }
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$month $day, $year at $hour:$minute';
  }

  /// Parse a dynamic value into a DateTime, supporting ISO-8601, epoch millis
  /// (as int or numeric string), and DateTime objects.
  static DateTime? _parseDateTimeValue(dynamic value) {
    if (value is DateTime) return value;
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is! String) return null;
    // Try epoch millis (numeric string > 1e9)
    final asInt = int.tryParse(value);
    if (asInt != null && asInt > 1000000000) {
      // Distinguish seconds vs milliseconds
      if (asInt > 1e12) {
        return DateTime.fromMillisecondsSinceEpoch(asInt);
      }
      return DateTime.fromMillisecondsSinceEpoch(asInt * 1000);
    }
    // Try ISO-8601
    final iso = DateTime.tryParse(value);
    if (iso != null) return iso;
    // Try DD-Mon-YYYY (e.g. "14-Jun-2025", "01-Jan-2025")
    return _parseDDMonYYYY(value);
  }

  /// Month abbreviation lookup for DD-Mon-YYYY parsing.
  static const _monthAbbreviations = {
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };

  /// Parse a date in DD-Mon-YYYY format (e.g. "14-Jun-2025").
  static DateTime? _parseDDMonYYYY(String value) {
    final match = RegExp(r'^(\d{1,2})-(\w{3})-(\d{4})$').firstMatch(value);
    if (match == null) return null;
    final day = int.tryParse(match.group(1)!);
    final monthStr = match.group(2)!.toLowerCase();
    final year = int.tryParse(match.group(3)!);
    final month = _monthAbbreviations[monthStr];
    if (day == null || month == null || year == null) return null;
    return DateTime(year, month, day);
  }

  /// Format a metadata value, converting dates and timestamps to
  /// human-readable form.
  static String _formatMetadataValue(dynamic value) {
    if (value is! String) return '$value';
    // Try date parsing (handles ISO-8601 and epoch millis strings)
    final formatted = _formatDateTimeValue(value);
    if (formatted != null) return formatted;
    return value;
  }

  /// Convert a camelCase metadata key to a human-readable label.
  static String _humanizeKey(String key) {
    // Insert space before uppercase letters and lowercase the result
    final spaced = key.replaceAllMapped(
        RegExp(r'[A-Z]'), (m) => ' ${m[0]!.toLowerCase()}');
    // Capitalize first letter
    return spaced[0].toUpperCase() + spaced.substring(1);
  }

  /// Format a duration value (seconds string) to a human-readable form.
  /// If the value is already human-readable (e.g. "0h, 35min, 10sec"),
  /// returns it as-is.
  static String _formatDuration(String durationStr) {
    final seconds = int.tryParse(durationStr);
    if (seconds == null) return durationStr;
    if (seconds < 60) return '${seconds}s';
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;
    if (minutes < 60) {
      return remainingSeconds > 0
          ? '${minutes}m ${remainingSeconds}s'
          : '${minutes}m';
    }
    final hours = minutes ~/ 60;
    final remainingMinutes = minutes % 60;
    return remainingMinutes > 0
        ? '${hours}h ${remainingMinutes}m'
        : '${hours}h';
  }

  /// Apply token budget with priority-based trimming and relationship-aware
  /// context construction.
  ///
  /// Discard order:
  ///   1. Hop nodes with lowest scores
  ///   2. Seed nodes with lowest scores
  ///   3. Truncate remaining context text
  ///
  /// Community context is included only when entity tokens alone stay
  /// below [communityDropThreshold] of the total [tokenBudget].
  _BudgetResult _applyTokenBudget({
    required List<GraphRAGScoredEntity> seeds,
    required List<GraphRAGScoredEntity> hops,
    required List<GraphRelationship> relationships,
    required Map<String, GraphEntity> entityMap,
    required List<GraphRAGScoredCommunity> communities,
    required int tokenBudget,
    required double communityDropThreshold,
  }) {
    // Pre-compute header tokens
    const entityHeader = '=== Retrieved Knowledge ===\n\n';
    const communityHeader = '\n=== Background Context ===\n\n';
    int runningTokens = _estimateTokens(entityHeader);

    // Pre-compute community text for later
    int communityTokens = 0;
    String communityText = '';

    if (communities.isNotEmpty) {
      final c = communities.first;
      final cText = '${c.community.summary}\n';
      communityTokens =
          _estimateTokens(communityHeader) + _estimateTokens(cText);
      communityText = cText;
    }

    // Build relationship lookup: entityId → list of outgoing relationships
    // resolved with target entity names for rendering.
    final outgoingRels = <String, List<_ResolvedRelationship>>{};
    for (final rel in relationships) {
      final targetEntity = entityMap[rel.targetId];
      final sourceEntity = entityMap[rel.sourceId];
      if (targetEntity == null || sourceEntity == null) continue;

      // Skip relationships pointing TO date entities (already in entity text)
      // but keep relationships FROM date entities (rare but valid)
      if (targetEntity.type == EntityTypes.date) continue;

      outgoingRels.putIfAbsent(rel.sourceId, () => []).add(
            _ResolvedRelationship(
              type: rel.type,
              targetName: targetEntity.name,
              targetType: targetEntity.type,
            ),
          );
    }

    // --- Phase 1: Fit entities using full budget ---
    final allEntities = <GraphRAGScoredEntity>[];
    final entityTexts = <String>[];

    // Add seeds (skip DATE entities from context — they are structural)
    for (final seed in seeds) {
      if (_contextExcludedTypes.contains(seed.entity.type)) continue;
      final text = _formatEntity(seed, outgoing: outgoingRels[seed.entity.id]);
      final tokens = _estimateTokens(text);
      if (runningTokens + tokens <= tokenBudget) {
        allEntities.add(seed);
        entityTexts.add(text);
        runningTokens += tokens;
      }
    }

    // Add hops (already sorted desc by score, skip DATE entities)
    for (final hop in hops) {
      if (_contextExcludedTypes.contains(hop.entity.type)) continue;
      final text = _formatEntity(hop, outgoing: outgoingRels[hop.entity.id]);
      final tokens = _estimateTokens(text);
      if (runningTokens + tokens <= tokenBudget) {
        allEntities.add(hop);
        entityTexts.add(text);
        runningTokens += tokens;
      }
      // If budget exceeded, remaining hops are silently discarded (lowest scores)
    }

    // Safety: trim from the end if still over budget
    while (runningTokens > tokenBudget && allEntities.isNotEmpty) {
      final removed = entityTexts.removeLast();
      allEntities.removeLast();
      runningTokens -= _estimateTokens(removed);
    }

    // --- Phase 2: Conditionally include community context ---
    // Drop community when entity tokens alone exceed the threshold
    final survivingCommunities = <GraphRAGScoredCommunity>[];
    final entityTokenRatio = runningTokens / tokenBudget;

    if (communityTokens > 0 &&
        entityTokenRatio <= communityDropThreshold &&
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
        buf.write(
            _formatEntity(scored, outgoing: outgoingRels[scored.entity.id]));
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

  // ---------------------------------------------------------------------------
  // LLM Prompt Construction
  // ---------------------------------------------------------------------------

  /// System prompt for the personal assistant answering from graph context.
  /// Build the system prompt, injecting the current date for temporal
  /// reasoning. Made a method (not a const) so it can include dynamic data.
  static String _buildSystemPrompt() {
    final now = DateTime.now();
    final todayStr =
        '${_months[now.month - 1]} ${now.day}, ${now.year}';
    // Day-of-week name
    const dayNames = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    final dayOfWeek = dayNames[now.weekday - 1];

    return '''You are a helpful personal assistant. The user's personal knowledge graph has been searched and the most relevant information is provided below.
Today is $dayOfWeek, $todayStr.

The context includes entities (people, events, photos, notes, calls, locations, documents) and the relationships connecting them (shown as "→ relationship → target").

Instructions:
- Answer based ONLY on the context provided. Do not use external knowledge.
- Be specific: use names, dates, and details from the entities.
- Use the relationships to connect information (e.g., who attended an event, where a photo was taken, when a call happened).
- If dates in the context are close to the dates mentioned in the question, use them. Make reasonable inferences from the available data rather than refusing.
- Use today's date to resolve relative time references like "yesterday", "last week", "last Friday". Check if entity dates match the referenced time period.
- Call direction: [outgoing] means YOU (the user) called the person. [incoming] means the person called YOU.
- Be conversational and concise.''';
  }

  /// Build the full prompt for answer generation.
  String _buildAnswerPrompt(String query, String contextString) {
    final systemPrompt = _buildSystemPrompt();
    return '''$systemPrompt

Context:
$contextString

User question: $query

Answer:''';
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

    final prompt = _buildAnswerPrompt(query, result.contextString);

    try {
      final response = await llmCallback!(prompt);
      return response.trim();
    } catch (e) {
      return 'Unable to generate an answer: $e';
    }
  }

  /// Build and return the full prompt for a query (public for batch usage).
  Future<String> buildPrompt(String query, {
    List<String>? entityTypes,
    int? topK,
    int? maxHops,
  }) async {
    final result = await this
        .query(query, entityTypes: entityTypes, topK: topK, maxHops: maxHops);
    return _buildAnswerPrompt(query, result.contextString);
  }
}

/// Resolved relationship with target entity name for context rendering.
class _ResolvedRelationship {
  final String type;
  final String targetName;
  final String targetType;

  _ResolvedRelationship({
    required this.type,
    required this.targetName,
    required this.targetType,
  });
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
