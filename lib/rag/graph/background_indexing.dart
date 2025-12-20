import 'dart:async';

import '../connectors/data_connector.dart';
import 'graph_repository.dart';
import 'entity_extractor.dart';
import 'community_detection.dart';

/// Indexing job status
enum IndexingStatus {
  idle,
  running,
  paused,
  completed,
  failed,
  cancelled,
}

/// Progress information for indexing
class IndexingProgress {
  final IndexingStatus status;
  final String currentPhase;
  final int processedItems;
  final int totalItems;
  final int extractedEntities;
  final int extractedRelationships;
  final int detectedCommunities;
  final DateTime? startTime;
  final DateTime? endTime;
  final String? errorMessage;

  IndexingProgress({
    required this.status,
    required this.currentPhase,
    this.processedItems = 0,
    this.totalItems = 0,
    this.extractedEntities = 0,
    this.extractedRelationships = 0,
    this.detectedCommunities = 0,
    this.startTime,
    this.endTime,
    this.errorMessage,
  });

  double get progress => totalItems > 0 ? processedItems / totalItems : 0.0;

  Duration? get elapsed => startTime != null
      ? (endTime ?? DateTime.now()).difference(startTime!)
      : null;

  IndexingProgress copyWith({
    IndexingStatus? status,
    String? currentPhase,
    int? processedItems,
    int? totalItems,
    int? extractedEntities,
    int? extractedRelationships,
    int? detectedCommunities,
    DateTime? startTime,
    DateTime? endTime,
    String? errorMessage,
  }) {
    return IndexingProgress(
      status: status ?? this.status,
      currentPhase: currentPhase ?? this.currentPhase,
      processedItems: processedItems ?? this.processedItems,
      totalItems: totalItems ?? this.totalItems,
      extractedEntities: extractedEntities ?? this.extractedEntities,
      extractedRelationships: extractedRelationships ?? this.extractedRelationships,
      detectedCommunities: detectedCommunities ?? this.detectedCommunities,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

/// Configuration for background indexing
class IndexingConfig {
  /// Batch size for processing items
  final int batchSize;
  
  /// Delay between batches (to avoid blocking)
  final Duration batchDelay;
  
  /// Whether to automatically detect communities
  final bool detectCommunities;
  
  /// Maximum community hierarchy depth
  final int maxCommunityDepth;
  
  /// Whether to generate community summaries
  final bool generateSummaries;
  
  /// Whether to perform incremental indexing
  final bool incrementalIndexing;
  
  /// Interval for periodic re-indexing
  final Duration? reindexInterval;

  IndexingConfig({
    this.batchSize = 10,
    this.batchDelay = const Duration(milliseconds: 100),
    this.detectCommunities = true,
    this.maxCommunityDepth = 2,
    this.generateSummaries = true,
    this.incrementalIndexing = true,
    this.reindexInterval,
  });
}

/// Background indexing service for GraphRAG
class BackgroundIndexingService {
  final GraphRepository repository;
  final EntityExtractor extractor;
  final ConnectorManager connectorManager;
  final IndexingConfig config;
  
  late final LouvainCommunityDetector _communityDetector;
  late final CommunitySummarizer? _summarizer;
  
  IndexingProgress _progress = IndexingProgress(
    status: IndexingStatus.idle,
    currentPhase: 'Idle',
  );
  
  final _progressController = StreamController<IndexingProgress>.broadcast();
  Timer? _reindexTimer;
  bool _cancelRequested = false;
  Completer<void>? _currentJob;

  BackgroundIndexingService({
    required this.repository,
    required this.extractor,
    required this.connectorManager,
    required Future<String> Function(String prompt) llmCallback,
    required Future<List<double>> Function(String text) embeddingCallback,
    IndexingConfig? config,
  }) : config = config ?? IndexingConfig() {
    _communityDetector = LouvainCommunityDetector(
      config: CommunityDetectionConfig(maxDepth: this.config.maxCommunityDepth),
    );
    
    if (this.config.generateSummaries) {
      _summarizer = CommunitySummarizer(
        llmCallback: llmCallback,
        embeddingCallback: embeddingCallback,
      );
    }
    
    // Setup periodic reindexing if configured
    if (this.config.reindexInterval != null) {
      _reindexTimer = Timer.periodic(
        this.config.reindexInterval!,
        (_) => startIndexing(fullReindex: false),
      );
    }
  }

  /// Stream of progress updates
  Stream<IndexingProgress> get progressStream => _progressController.stream;

  /// Current indexing progress
  IndexingProgress get progress => _progress;

  /// Whether indexing is currently running
  bool get isRunning => _progress.status == IndexingStatus.running;

  /// Start indexing process
  Future<void> startIndexing({bool fullReindex = false}) async {
    if (isRunning) {
      throw StateError('Indexing is already running');
    }

    _cancelRequested = false;
    _currentJob = Completer<void>();

    try {
      _updateProgress(_progress.copyWith(
        status: IndexingStatus.running,
        currentPhase: 'Starting',
        startTime: DateTime.now(),
        processedItems: 0,
        totalItems: 0,
        extractedEntities: 0,
        extractedRelationships: 0,
        detectedCommunities: 0,
        errorMessage: null,
      ));

      // Phase 1: Fetch data from connectors
      await _fetchDataPhase(fullReindex);
      if (_cancelRequested) return;

      // Phase 2: Detect communities
      if (config.detectCommunities) {
        await _detectCommunitiesPhase();
        if (_cancelRequested) return;
      }

      // Phase 3: Generate community summaries
      if (config.generateSummaries && _summarizer != null) {
        await _generateSummariesPhase();
      }

      _updateProgress(_progress.copyWith(
        status: IndexingStatus.completed,
        currentPhase: 'Completed',
        endTime: DateTime.now(),
      ));
    } catch (e) {
      _updateProgress(_progress.copyWith(
        status: IndexingStatus.failed,
        currentPhase: 'Failed',
        errorMessage: e.toString(),
        endTime: DateTime.now(),
      ));
      rethrow;
    } finally {
      _currentJob?.complete();
      _currentJob = null;
    }
  }

  /// Pause indexing (if running)
  void pauseIndexing() {
    if (_progress.status == IndexingStatus.running) {
      _updateProgress(_progress.copyWith(
        status: IndexingStatus.paused,
        currentPhase: 'Paused',
      ));
    }
  }

  /// Resume indexing (if paused)
  Future<void> resumeIndexing() async {
    if (_progress.status == IndexingStatus.paused) {
      _updateProgress(_progress.copyWith(
        status: IndexingStatus.running,
        currentPhase: 'Resuming',
      ));
      // Resume from where we left off
      // This is simplified - full implementation would track exact position
    }
  }

  /// Cancel indexing
  void cancelIndexing() {
    _cancelRequested = true;
    _updateProgress(_progress.copyWith(
      status: IndexingStatus.cancelled,
      currentPhase: 'Cancelled',
      endTime: DateTime.now(),
    ));
  }

  /// Wait for current indexing job to complete
  Future<void> waitForCompletion() async {
    await _currentJob?.future;
  }

  /// Phase 1: Fetch and process data from connectors
  Future<void> _fetchDataPhase(bool fullReindex) async {
    _updateProgress(_progress.copyWith(
      currentPhase: 'Fetching data',
    ));

    final allData = await connectorManager.fetchAllAvailable(
      incrementalSync: !fullReindex && config.incrementalIndexing,
    );

    // Calculate total items
    final totalItems = allData.values.fold<int>(
      0,
      (sum, list) => sum + list.length,
    );

    _updateProgress(_progress.copyWith(totalItems: totalItems));

    // Process each connector's data
    for (final entry in allData.entries) {
      final dataType = entry.key;
      final items = entry.value;

      _updateProgress(_progress.copyWith(
        currentPhase: 'Processing $dataType',
      ));

      // Process in batches
      for (var i = 0; i < items.length; i += config.batchSize) {
        if (_cancelRequested) return;
        
        // Wait if paused
        while (_progress.status == IndexingStatus.paused) {
          await Future.delayed(const Duration(milliseconds: 500));
          if (_cancelRequested) return;
        }

        final batch = items.skip(i).take(config.batchSize).toList();
        await _processBatch(batch, dataType);

        _updateProgress(_progress.copyWith(
          processedItems: _progress.processedItems + batch.length,
        ));

        // Yield to allow other operations
        await Future.delayed(config.batchDelay);
      }
    }
  }

  /// Process a batch of items
  Future<void> _processBatch(List<dynamic> items, String dataType) async {
    for (final item in items) {
      try {
        // Convert item to map for extraction
        final itemMap = _itemToMap(item, dataType);
        final sourceId = _getItemId(item, dataType);

        // Extract entities and relationships using LLM
        final extraction = await extractor.extractFromStructured(
          itemMap,
          sourceId: sourceId,
          sourceType: dataType,
        );

        // Add extracted entities to graph
        for (final entity in extraction.entities) {
          final embedding = await extractor.generateEmbedding(
            '${entity.name} ${entity.description ?? ""}',
          );

          final graphEntity = GraphEntity(
            id: _generateEntityId(entity.name, entity.type),
            name: entity.name,
            type: entity.type,
            embedding: embedding,
            description: entity.description,
            metadata: entity.attributes,
            lastModified: DateTime.now(),
          );

          // Check for existing entity (timestamp-wins conflict resolution)
          final existing = await repository.getEntity(graphEntity.id);
          if (existing == null) {
            await repository.addEntity(graphEntity);
          } else if (graphEntity.lastModified.isAfter(existing.lastModified)) {
            await repository.updateEntity(
              graphEntity.id,
              name: graphEntity.name,
              type: graphEntity.type,
              embedding: graphEntity.embedding,
              description: graphEntity.description,
              metadata: graphEntity.metadata,
              lastModified: graphEntity.lastModified,
            );
          }
        }

        // Add extracted relationships
        for (final rel in extraction.relationships) {
          final sourceEntityId = _generateEntityId(rel.sourceEntity, '');
          final targetEntityId = _generateEntityId(rel.targetEntity, '');

          final relationship = GraphRelationship(
            id: '${sourceEntityId}_${rel.type}_$targetEntityId',
            sourceId: sourceEntityId,
            targetId: targetEntityId,
            type: rel.type,
            weight: rel.weight,
            metadata: rel.description != null
                ? {'description': rel.description}
                : null,
          );

          try {
            await repository.addRelationship(relationship);
          } catch (e) {
            // Relationship might already exist or entities might not exist
          }
        }

        _updateProgress(_progress.copyWith(
          extractedEntities: _progress.extractedEntities + extraction.entities.length,
          extractedRelationships: _progress.extractedRelationships + extraction.relationships.length,
        ));
      } catch (e) {
        // Log error but continue processing - errors are silently ignored
        // to allow batch processing to continue
        assert(() {
          // ignore: avoid_print
          print('Error processing item: $e');
          return true;
        }());
      }
    }
  }

  /// Phase 2: Detect communities
  Future<void> _detectCommunitiesPhase() async {
    _updateProgress(_progress.copyWith(
      currentPhase: 'Detecting communities',
    ));

    // Get all entities and relationships
    final entities = <GraphEntity>[];
    final relationships = <GraphRelationship>[];

    // Load all entities (simplified - in production, use pagination)
    for (final type in ['PERSON', 'ORGANIZATION', 'EVENT', 'LOCATION']) {
      final typeEntities = await repository.getEntitiesByType(type);
      entities.addAll(typeEntities);
    }

    // Load relationships for each entity
    for (final entity in entities) {
      final rels = await repository.getRelationships(entity.id);
      relationships.addAll(rels);
    }

    // Run community detection
    final result = await _communityDetector.detectCommunities(
      entities,
      relationships,
    );

    // Store communities
    for (final community in result.communities) {
      final graphCommunity = GraphCommunity(
        id: community.id,
        level: community.level,
        summary: '', // Will be generated in next phase
        entityIds: community.entityIds.toList(),
        embedding: null,
        metadata: {'modularity': community.modularity},
      );

      await repository.addCommunity(graphCommunity);
    }

    _updateProgress(_progress.copyWith(
      detectedCommunities: result.communities.length,
    ));
  }

  /// Phase 3: Generate community summaries
  Future<void> _generateSummariesPhase() async {
    if (_summarizer == null) return;

    _updateProgress(_progress.copyWith(
      currentPhase: 'Generating community summaries',
    ));

    // Get all entities for reference
    final entities = <GraphEntity>[];
    final relationships = <GraphRelationship>[];
    
    for (final type in ['PERSON', 'ORGANIZATION', 'EVENT', 'LOCATION']) {
      entities.addAll(await repository.getEntitiesByType(type));
    }
    
    for (final entity in entities) {
      relationships.addAll(await repository.getRelationships(entity.id));
    }

    // Generate summaries for each level
    for (var level = 0; level <= config.maxCommunityDepth; level++) {
      if (_cancelRequested) return;

      final communities = await repository.getCommunitiesByLevel(level);

      for (final community in communities) {
        if (_cancelRequested) return;

        final detectedCommunity = DetectedCommunity(
          id: community.id,
          level: community.level,
          entityIds: community.entityIds.toSet(),
          modularity: 0.0,
        );

        final summary = await _summarizer.summarize(
          detectedCommunity,
          entities,
          relationships,
        );

        await repository.updateCommunitySummary(
          community.id,
          summary.summary,
          summary.embedding,
        );
      }
    }
  }

  /// Convert item to map for extraction
  Map<String, dynamic> _itemToMap(dynamic item, String dataType) {
    if (item is Map<String, dynamic>) return item;
    
    if (item is Contact) {
      return {
        'id': item.id,
        'fullName': item.fullName,
        'givenName': item.givenName,
        'familyName': item.familyName,
        'organizationName': item.organizationName,
        'jobTitle': item.jobTitle,
        'emailAddresses': item.emailAddresses,
        'phoneNumbers': item.phoneNumbers,
      };
    }
    
    if (item is CalendarEvent) {
      return {
        'id': item.id,
        'title': item.title,
        'location': item.location,
        'notes': item.notes,
        'startDate': item.startDate.toIso8601String(),
        'endDate': item.endDate.toIso8601String(),
        'attendees': item.attendees,
      };
    }
    
    return {'_raw': item.toString()};
  }

  /// Get item ID
  String _getItemId(dynamic item, String dataType) {
    if (item is Map<String, dynamic>) {
      return item['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString();
    }
    if (item is Contact) return item.id;
    if (item is CalendarEvent) return item.id;
    return DateTime.now().millisecondsSinceEpoch.toString();
  }

  /// Generate entity ID from name and type
  String _generateEntityId(String name, String type) {
    final normalized = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_');
    final typePrefix = type.isNotEmpty ? '${type.toLowerCase()}_' : '';
    return '$typePrefix$normalized';
  }

  /// Update progress and notify listeners
  void _updateProgress(IndexingProgress progress) {
    _progress = progress;
    _progressController.add(progress);
  }

  /// Dispose resources
  void dispose() {
    _reindexTimer?.cancel();
    _progressController.close();
  }
}

/// Extension for monitoring indexing service
extension IndexingServiceMonitoring on BackgroundIndexingService {
  /// Get human-readable status
  String get statusText {
    switch (progress.status) {
      case IndexingStatus.idle:
        return 'Ready to index';
      case IndexingStatus.running:
        return '${progress.currentPhase} (${(progress.progress * 100).toStringAsFixed(1)}%)';
      case IndexingStatus.paused:
        return 'Paused';
      case IndexingStatus.completed:
        return 'Completed (${progress.extractedEntities} entities, ${progress.detectedCommunities} communities)';
      case IndexingStatus.failed:
        return 'Failed: ${progress.errorMessage}';
      case IndexingStatus.cancelled:
        return 'Cancelled';
    }
  }

  /// Get estimated time remaining
  Duration? get estimatedTimeRemaining {
    if (!isRunning || progress.elapsed == null || progress.progress <= 0) {
      return null;
    }
    
    final elapsed = progress.elapsed!;
    final rate = progress.progress / elapsed.inMilliseconds;
    final remaining = (1 - progress.progress) / rate;
    
    return Duration(milliseconds: remaining.toInt());
  }
}
