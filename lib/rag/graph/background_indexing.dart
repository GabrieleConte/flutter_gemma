import 'dart:async';
import 'dart:typed_data';

import '../../pigeon.g.dart';
import '../../core/tool.dart';
import '../connectors/data_connector.dart';
import 'graph_repository.dart';
import 'entity_extractor.dart';
import 'community_detection.dart';
import 'community_maintenance.dart';
import 'graph_pruning.dart';
import 'link_prediction.dart';

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
  final int uniqueEntitiesStored;
  final int extractedRelationships;
  final int predictedLinks;
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
    this.uniqueEntitiesStored = 0,
    this.extractedRelationships = 0,
    this.predictedLinks = 0,
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
    int? uniqueEntitiesStored,
    int? extractedRelationships,
    int? predictedLinks,
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
      uniqueEntitiesStored: uniqueEntitiesStored ?? this.uniqueEntitiesStored,
      extractedRelationships:
          extractedRelationships ?? this.extractedRelationships,
      predictedLinks: predictedLinks ?? this.predictedLinks,
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

  /// Whether to enable link prediction (template-based + co-mention)
  final bool enableLinkPrediction;

  /// Link prediction configuration
  final LinkPredictionConfig? linkPredictionConfig;

  /// Whether to enable image captioning using vision LLM
  /// When enabled, photos will be analyzed using the vision model to
  /// generate descriptive captions for richer entity extraction
  final bool enableImageCaptioning;

  /// When non-null, only calendar events whose calendar display name is in
  /// this set will be indexed. Matching is case-insensitive.
  /// For example: `{'My calendar'}` to index only the user's primary calendar.
  /// When null, events from all calendars are indexed.
  final Set<String>? calendarNameFilter;

  IndexingConfig({
    this.batchSize = 10,
    this.batchDelay = const Duration(milliseconds: 100),
    this.detectCommunities = true,
    this.maxCommunityDepth = 2,
    this.generateSummaries = true,
    this.incrementalIndexing = true,
    this.reindexInterval,
    this.enableLinkPrediction = true,
    this.linkPredictionConfig,
    this.enableImageCaptioning = false,
    this.calendarNameFilter,
  });
}

/// Background indexing service for GraphRAG
class BackgroundIndexingService {
  final GraphRepository repository;
  final EntityExtractor extractor;
  final ConnectorManager connectorManager;
  final IndexingConfig config;

  /// Callback to notify when extraction phase is complete (can deallocate extraction model)
  final Future<void> Function()? onExtractionPhaseComplete;

  /// Callback to prepare main LLM before summarization (can reallocate if needed)
  final Future<void> Function()? onBeforeSummarization;

  late final LeidenCommunityDetector _communityDetector;
  late final CommunitySummarizer? _summarizer;
  late final LinkPredictor? _linkPredictor;
  late final EmbeddingSimilarityLinkPredictor? _embeddingSimilarityPredictor;
  late final DirectEntityExtractor _directExtractor;
  late final Future<List<double>> Function(String text) _embeddingCallback;
  late final Future<String> Function(String prompt) _llmCallback;
  late final Future<String> Function(String prompt, Uint8List imageBytes)?
      _visionLlmCallback;
  late final Future<void> Function({
    required String documentId,
    required String name,
    required String content,
    String? mimeType,
  })? _documentIndexCallback;
  final PlatformService _platform = PlatformService();

  /// Data types that should use direct extraction (no LLM)
  static const _structuredDataTypes = {
    'CONTACT',
    'CONTACTS',
    'CALENDAR',
    'CALENDAR_EVENT',
    'EVENT',
    'PHOTO',
    'PHOTOS',
    'PHONE_CALL',
    'PHONE_CALLS',
    'CALL',
    'CALLS',
    'CALLLOG',
    'DOCUMENT',
    'DOCUMENTS',
    'ALARM',
    'ALARMS',
    'NOTE',
    'NOTES',
  };

  /// Normalize connector data-type strings to canonical forms used in switch
  /// statements throughout the pipeline (entity extraction, link prediction,
  /// hub linking, incremental-skip).
  static const _dataTypeAliases = {
    'CALLLOG': 'PHONE_CALL',
  };

  /// Return the canonical data-type string for [raw].
  static String _normalizeDataType(String raw) {
    final upper = raw.toUpperCase();
    return _dataTypeAliases[upper] ?? raw;
  }

  IndexingProgress _progress = IndexingProgress(
    status: IndexingStatus.idle,
    currentPhase: 'Idle',
  );

  final _progressController = StreamController<IndexingProgress>.broadcast();
  Timer? _reindexTimer;
  bool _cancelRequested = false;
  Completer<void>? _currentJob;
  bool _useForegroundService = true;

  // Accumulate extractions for co-mention detection
  final List<ExtractionResult> _batchExtractions = [];

  BackgroundIndexingService({
    required this.repository,
    required this.extractor,
    required this.connectorManager,
    required Future<String> Function(String prompt) llmCallback,
    required Future<List<double>> Function(String text) embeddingCallback,
    Future<String> Function(String prompt, Uint8List imageBytes)?
        visionLlmCallback,

    /// Optional structured LLM callback that supports function calling tools
    /// Used for link validation to get structured relationship types
    Future<String> Function(String prompt, {List<Tool>? tools})?
        structuredLlmCallback,

    /// Callback to index a document's full content (read + chunk + embed).
    /// When provided, documents are processed by reading their content and
    /// calling this callback instead of the generic metadata-only extraction.
    Future<void> Function({
      required String documentId,
      required String name,
      required String content,
      String? mimeType,
    })? documentIndexCallback,
    this.onExtractionPhaseComplete,
    this.onBeforeSummarization,
    IndexingConfig? config,
  }) : config = config ?? IndexingConfig() {
    _documentIndexCallback = documentIndexCallback;
    _llmCallback = llmCallback;
    _embeddingCallback = embeddingCallback;
    _visionLlmCallback = visionLlmCallback;

    // Initialize direct extractor for structured data (no LLM)
    _directExtractor = DirectEntityExtractor(
      embeddingCallback: embeddingCallback,
    );

    _communityDetector = LeidenCommunityDetector(
      config: CommunityDetectionConfig(maxDepth: this.config.maxCommunityDepth),
    );

    if (this.config.generateSummaries) {
      _summarizer = CommunitySummarizer(
        llmCallback: llmCallback,
        embeddingCallback: embeddingCallback,
      );
    }

    // Initialize link predictor if enabled
    if (this.config.enableLinkPrediction) {
      _linkPredictor = LinkPredictor(
        repository: repository,
        config: this.config.linkPredictionConfig,
      );

      // Initialize embedding similarity predictor
      final linkConfig =
          this.config.linkPredictionConfig ?? LinkPredictionConfig();
      if (linkConfig.enableEmbeddingSimilarityLinks) {
        _embeddingSimilarityPredictor = EmbeddingSimilarityLinkPredictor(
          repository: repository,
          llmCallback: llmCallback,
          structuredLlmCallback: structuredLlmCallback,
          config: linkConfig,
        );
      }
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
  /// Set [useForegroundService] to true to keep indexing alive when app is backgrounded
  Future<void> startIndexing(
      {bool fullReindex = false, bool useForegroundService = true}) async {
    if (isRunning) {
      throw StateError('Indexing is already running');
    }

    _cancelRequested = false;
    _currentJob = Completer<void>();
    _useForegroundService = useForegroundService;

    try {
      // Start foreground service for background execution
      if (_useForegroundService) {
        try {
          await _platform.startIndexingForegroundService();
        } catch (e) {
          print('[BackgroundIndexing] Failed to start foreground service: $e');
          // Continue without foreground service
        }
      }

      _updateProgress(_progress.copyWith(
        status: IndexingStatus.running,
        currentPhase: 'Starting',
        startTime: DateTime.now(),
        processedItems: 0,
        totalItems: 0,
        extractedEntities: 0,
        uniqueEntitiesStored: 0,
        extractedRelationships: 0,
        predictedLinks: 0,
        detectedCommunities: 0,
        errorMessage: null,
      ));

      // Clear batch extractions for new indexing run
      _batchExtractions.clear();

      // Phase 0: Initialize "You" central node
      if (config.enableLinkPrediction && _linkPredictor != null) {
        await _initializeYouNodePhase();
        if (_cancelRequested) return;
      }

      // Phase 1: Fetch data from connectors
      await _fetchDataPhase(fullReindex);
      if (_cancelRequested) return;

      // Phase 1.1: Prune stale entities (deleted from device)
      await _pruneStaleEntitiesPhase();
      if (_cancelRequested) return;

      // Phase 1.5: Link prediction (after entity extraction)
      if (config.enableLinkPrediction && _linkPredictor != null) {
        await _linkPredictionPhase();
        if (_cancelRequested) return;
      }

      // Phase 1.6: Embedding similarity link prediction
      if (config.enableLinkPrediction &&
          _embeddingSimilarityPredictor != null) {
        await _embeddingSimilarityPhase();
        if (_cancelRequested) return;
      }

      // Notify that extraction phase is complete (extraction model can be deallocated)
      if (onExtractionPhaseComplete != null) {
        print(
            '[BackgroundIndexing] Extraction phases complete, notifying for model cleanup');
        await onExtractionPhaseComplete!();
      }

      // Phase 2: Detect communities
      if (config.detectCommunities) {
        await _detectCommunitiesPhase();
        if (_cancelRequested) return;
      }

      // Phase 3: Generate community summaries
      if (config.generateSummaries && _summarizer != null) {
        // Notify before summarization (main LLM may need reallocation)
        if (onBeforeSummarization != null) {
          print(
              '[BackgroundIndexing] Preparing for summarization, notifying for model readiness');
          await onBeforeSummarization!();
        }
        await _generateSummariesPhase();
      }

      _updateProgress(_progress.copyWith(
        status: IndexingStatus.completed,
        currentPhase: 'Completed',
        endTime: DateTime.now(),
      ));
      print('[BackgroundIndexing] Indexing completed successfully');

      // Stop foreground service
      if (_useForegroundService) {
        try {
          await _platform.stopIndexingForegroundService();
        } catch (e) {
          print('[BackgroundIndexing] Failed to stop foreground service: $e');
        }
      }
    } catch (e, stack) {
      print('[BackgroundIndexing] Indexing failed with error: $e');
      print('[BackgroundIndexing] Stack trace: $stack');
      _updateProgress(_progress.copyWith(
        status: IndexingStatus.failed,
        currentPhase: 'Failed',
        errorMessage: e.toString(),
        endTime: DateTime.now(),
      ));

      // Stop foreground service on failure too
      if (_useForegroundService) {
        try {
          await _platform.stopIndexingForegroundService();
        } catch (_) {}
      }
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
  Future<void> cancelIndexing() async {
    _cancelRequested = true;
    _updateProgress(_progress.copyWith(
      status: IndexingStatus.cancelled,
      currentPhase: 'Cancelled',
      endTime: DateTime.now(),
    ));

    // Stop foreground service
    if (_useForegroundService) {
      try {
        await _platform.stopIndexingForegroundService();
      } catch (_) {}
    }
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

    // Check if we should force full fetch:
    // If doing incremental sync but graph is empty (or only has "You" node),
    // force a full fetch since there's nothing to increment from
    var effectiveFullReindex = fullReindex;
    if (!fullReindex && config.incrementalIndexing) {
      final stats = await repository.getStats();
      // If only 0 or 1 entity (just "You" node), force full reindex
      if (stats.entityCount <= 1) {
        print(
            '[BackgroundIndexing] Graph is empty, forcing full fetch instead of incremental');
        effectiveFullReindex = true;
        // Reset sync times so all data is fetched
        await connectorManager.resetSyncState();
      }
    }

    final allData = await connectorManager.fetchAllAvailable(
      incrementalSync: !effectiveFullReindex && config.incrementalIndexing,
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
  Future<void> _processBatch(List<dynamic> items, String rawDataType) async {
    // Normalize the connector data-type (e.g. 'callLog' → 'PHONE_CALL')
    // so that all downstream switch statements match correctly.
    final dataType = _normalizeDataType(rawDataType);

    for (final item in items) {
      try {
        // Convert item to map for extraction
        final itemMap = _itemToMap(item, dataType);
        final sourceId = _getItemId(item, dataType);

        // Skip if primary entity already exists (incremental indexing optimization)
        // This avoids re-extracting and re-processing unchanged items
        // Since iOS doesn't provide modification timestamps for contacts,
        // we check if the entity exists and skip if so
        final primaryEntityId = _getPrimaryEntityId(itemMap, dataType);
        if (primaryEntityId != null) {
          final existing = await repository.getEntity(primaryEntityId);
          if (existing != null) {
            // Entity already indexed, skip processing
            assert(() {
              print(
                  '[BackgroundIndexing] Skipping already indexed: $primaryEntityId');
              return true;
            }());
            continue;
          }
        }

        // --- Document special path ---
        // When a documentIndexCallback is provided, documents are processed
        // by reading their full content and delegating to GraphRAG's
        // indexDocumentContent (chunking + embedding), exactly like the
        // "Select files" manual flow.
        final isDocument = dataType.toUpperCase() == 'DOCUMENT' ||
            dataType.toUpperCase() == 'DOCUMENTS';
        if (isDocument && _documentIndexCallback != null && item is Document) {
          try {
            final documentsConnector = connectorManager
                .getConnector('documents') as DocumentsConnector?;
            if (documentsConnector != null) {
              final content = await documentsConnector.readContent(item.id);
              if (content != null && content.isNotEmpty) {
                assert(() {
                  print(
                      '[BackgroundIndexing] Indexing document content: ${item.name} (${content.length} chars)');
                  return true;
                }());
                await _documentIndexCallback(
                  documentId: item.id,
                  name: item.name,
                  content: content,
                  mimeType: item.mimeType,
                );
              } else {
                assert(() {
                  print(
                      '[BackgroundIndexing] Skipping empty document: ${item.name}');
                  return true;
                }());
              }
            }
          } catch (e) {
            assert(() {
              print(
                  '[BackgroundIndexing] Error indexing document ${item.name}: $e');
              return true;
            }());
          }
          // Document fully handled by the callback – skip generic extraction
          continue;
        }

        // Choose extraction method based on data type
        // Use direct extraction for structured data (fast, no LLM)
        // Use LLM extraction for free-text data (notes, documents)
        ExtractionResult extraction;
        final isStructuredData =
            _structuredDataTypes.contains(dataType.toUpperCase());
        final isPhotoWithCaptioning = (dataType.toUpperCase() == 'PHOTO' ||
                dataType.toUpperCase() == 'PHOTOS') &&
            config.enableImageCaptioning &&
            _visionLlmCallback != null;

        if (isPhotoWithCaptioning) {
          // Vision-enhanced photo extraction with image captioning
          extraction =
              await _extractPhotoWithVision(itemMap, item, sourceId, dataType);
        } else if (isStructuredData) {
          // Fast path: direct extraction without LLM
          extraction = await _directExtractor.extractFromStructured(
            itemMap,
            sourceId: sourceId,
            sourceType: dataType,
          );
          assert(() {
            print(
                '[BackgroundIndexing] Direct extraction: ${extraction.entities.length} entities, ${extraction.relationships.length} relationships from $dataType item');
            return true;
          }());
        } else {
          // Slow path: LLM-based extraction for free text
          extraction = await extractor.extractFromStructured(
            itemMap,
            sourceId: sourceId,
            sourceType: dataType,
          );
          assert(() {
            print(
                '[BackgroundIndexing] LLM extraction: ${extraction.entities.length} entities, ${extraction.relationships.length} relationships from $dataType item');
            return true;
          }());
        }

        // Track unique entities stored
        var uniqueStored = 0;

        // Add extracted entities to graph
        for (final entity in extraction.entities) {
          // Include date info in embedding text for better temporal matching
          final attrs = entity.attributes;
          final dateAttr = attrs?['creationDate'] ??
              attrs?['timestamp'] ??
              attrs?['dateCreated'] ??
              attrs?['startDate'] ??
              attrs?['date'];
          // Convert date to human-readable format with day-of-week
          String dateInfo = '';
          if (dateAttr != null) {
            final dt = _parseDateForEmbedding(dateAttr);
            if (dt != null) {
              const dayNames = [
                'Monday', 'Tuesday', 'Wednesday', 'Thursday',
                'Friday', 'Saturday', 'Sunday',
              ];
              const months = [
                'January', 'February', 'March', 'April', 'May', 'June',
                'July', 'August', 'September', 'October', 'November', 'December',
              ];
              final dayName = dayNames[dt.weekday - 1];
              final month = months[dt.month - 1];
              dateInfo = ' Date: $dayName, $month ${dt.day}, ${dt.year}';
            } else {
              dateInfo = ' Date: $dateAttr';
            }
          }
          final embedding = await _embeddingCallback(
            '${entity.name} ${entity.description ?? ""}$dateInfo',
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
            uniqueStored++;
            assert(() {
              print(
                  '[BackgroundIndexing] Added entity: ${entity.name} (${entity.type})');
              return true;
            }());
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
            assert(() {
              print('[BackgroundIndexing] Updated entity: ${entity.name}');
              return true;
            }());
          }
        }

        // Build a map of entity names to their IDs for relationship creation
        final entityNameToId = <String, String>{};
        for (final entity in extraction.entities) {
          final entityId = _generateEntityId(entity.name, entity.type);
          // Store both exact name and lowercase version for matching
          entityNameToId[entity.name] = entityId;
          entityNameToId[entity.name.toLowerCase()] = entityId;
        }

        // Add extracted relationships
        for (final rel in extraction.relationships) {
          // Try to find actual entity IDs by matching names
          String? sourceEntityId = entityNameToId[rel.sourceEntity] ??
              entityNameToId[rel.sourceEntity.toLowerCase()];
          String? targetEntityId = entityNameToId[rel.targetEntity] ??
              entityNameToId[rel.targetEntity.toLowerCase()];

          // If we can't find the entities in this extraction, try generating IDs
          // with common type prefixes
          if (sourceEntityId == null) {
            for (final type in [
              'PERSON',
              'ORGANIZATION',
              'LOCATION',
              'EVENT',
              ''
            ]) {
              final candidateId = _generateEntityId(rel.sourceEntity, type);
              final exists = await repository.getEntity(candidateId);
              if (exists != null) {
                sourceEntityId = candidateId;
                break;
              }
            }
          }
          if (targetEntityId == null) {
            for (final type in [
              'PERSON',
              'ORGANIZATION',
              'LOCATION',
              'EVENT',
              ''
            ]) {
              final candidateId = _generateEntityId(rel.targetEntity, type);
              final exists = await repository.getEntity(candidateId);
              if (exists != null) {
                targetEntityId = candidateId;
                break;
              }
            }
          }

          // Skip if we still can't find valid entity IDs
          if (sourceEntityId == null || targetEntityId == null) {
            assert(() {
              print(
                  '[BackgroundIndexing] Skipping relationship: could not find entity IDs for ${rel.sourceEntity} -> ${rel.targetEntity}');
              return true;
            }());
            continue;
          }

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
            assert(() {
              print(
                  '[BackgroundIndexing] Added relationship: ${rel.sourceEntity} -[${rel.type}]-> ${rel.targetEntity}');
              return true;
            }());
          } catch (e) {
            // Relationship might already exist or entities might not exist
            assert(() {
              print('[BackgroundIndexing] Relationship error: $e');
              return true;
            }());
          }
        }

        _updateProgress(_progress.copyWith(
          extractedEntities:
              _progress.extractedEntities + extraction.entities.length,
          uniqueEntitiesStored: _progress.uniqueEntitiesStored + uniqueStored,
          extractedRelationships: _progress.extractedRelationships +
              extraction.relationships.length,
        ));

        // Accumulate extraction for co-mention detection
        if (config.enableLinkPrediction) {
          _batchExtractions.add(extraction);
        }

        // Create "You" links for primary entity of this item
        if (config.enableLinkPrediction && _linkPredictor != null) {
          await _createYouLinksForItem(itemMap, dataType, extraction);

          // Also run template-based inference for this item
          await _applyTemplateInference(itemMap, dataType);
        }
      } catch (e) {
        // Log error but continue processing - errors are silently ignored
        // to allow batch processing to continue
        assert(() {
          // ignore: avoid_print
          print('[BackgroundIndexing] Error processing item: $e');
          return true;
        }());
      }
    }
  }

  /// Extract photo with vision-based captioning
  /// Uses the vision LLM to generate a caption, then extracts entities from it
  Future<ExtractionResult> _extractPhotoWithVision(
    Map<String, dynamic> itemMap,
    dynamic item,
    String sourceId,
    String dataType,
  ) async {
    // First, try to get thumbnail bytes from the photo
    Uint8List? imageBytes;

    if (item is Photo && item.id.isNotEmpty) {
      // Try to fetch thumbnail from platform
      try {
        imageBytes = await _platform.getPhotoThumbnail(
          photoId: item.id,
          maxWidth: 512,
          maxHeight: 512,
        );
      } catch (e) {
        assert(() {
          print('[BackgroundIndexing] Could not get photo thumbnail: $e');
          return true;
        }());
      }
    }

    // If we couldn't get image bytes, fall back to direct extraction
    if (imageBytes == null || imageBytes.isEmpty) {
      final extraction = await _directExtractor.extractFromStructured(
        itemMap,
        sourceId: sourceId,
        sourceType: dataType,
      );
      assert(() {
        print(
            '[BackgroundIndexing] Vision fallback - no image bytes, using direct extraction');
        return true;
      }());
      return extraction;
    }

    // Create vision extractor and extract entities
    final visionExtractor = VisionEntityExtractor(
      visionLlmCallback: _visionLlmCallback!,
      llmCallback: _llmCallback,
      embeddingCallback: _embeddingCallback,
    );

    final extraction = await visionExtractor.extractFromPhoto(
      itemMap,
      imageBytes,
      sourceId: sourceId,
      sourceType: dataType,
    );

    assert(() {
      print(
          '[BackgroundIndexing] Vision extraction: ${extraction.entities.length} entities from photo with captioning');
      return true;
    }());

    return extraction;
  }

  /// Phase 0: Initialize the "You" central node
  Future<void> _initializeYouNodePhase() async {
    _updateProgress(_progress.copyWith(
      currentPhase: 'Creating central node',
    ));

    print('[BackgroundIndexing] Creating "You" central node');
    await _linkPredictor!.ensureYouEntityExists(
      embeddingCallback: _embeddingCallback,
    );
  }

  /// Create links from "You" to the primary entity of an item
  Future<void> _createYouLinksForItem(
    Map<String, dynamic> itemMap,
    String dataType,
    ExtractionResult extraction,
  ) async {
    if (_linkPredictor == null) return;

    // Determine the primary entity based on data type
    String? primaryEntityId;

    switch (dataType.toUpperCase()) {
      case 'CONTACT':
      case 'CONTACTS':
        // Link "You" -> Person
        final name = itemMap['fullName'] ?? itemMap['name'];
        if (name != null && name.toString().isNotEmpty) {
          primaryEntityId = _generateEntityId(name.toString(), 'PERSON');
        }
        break;

      case 'CALENDAR':
      case 'CALENDAR_EVENT':
      case 'EVENT':
        // Link "You" -> Event
        final title = itemMap['title'] ?? itemMap['summary'];
        if (title != null && title.toString().isNotEmpty) {
          primaryEntityId = _generateEntityId(title.toString(), 'EVENT');
        }
        break;

      case 'DOCUMENT':
      case 'DOCUMENTS':
      case 'DRIVE':
        // Link "You" -> Document
        final name = itemMap['name'] ?? itemMap['title'];
        if (name != null && name.toString().isNotEmpty) {
          primaryEntityId = _generateEntityId(name.toString(), 'DOCUMENT');
        }
        break;

      case 'PHOTO':
      case 'PHOTOS':
        // Link "You" -> Photo
        // Use filename as entity name (matches DirectEntityExtractor which uses
        // filename ?? name as the photo entity name)
        final photoName =
            itemMap['filename'] ?? itemMap['name'] ?? itemMap['id'];
        if (photoName != null && photoName.toString().isNotEmpty) {
          primaryEntityId = _generateEntityId(photoName.toString(), 'PHOTO');
        }
        break;

      case 'PHONE_CALL':
      case 'PHONE_CALLS':
      case 'CALL':
      case 'CALLS':
        // Link "You" -> the person called (not the call itself)
        final contactName = itemMap['contactName'] ?? itemMap['name'];
        if (contactName != null && contactName.toString().isNotEmpty) {
          primaryEntityId = _generateEntityId(contactName.toString(), 'PERSON');
        }
        break;

      case 'NOTE':
      case 'NOTES':
        // Link "You" -> Note
        final title = itemMap['title'] ?? itemMap['name'];
        if (title != null && title.toString().isNotEmpty) {
          primaryEntityId = _generateEntityId(title.toString(), 'NOTE');
        }
        break;

      case 'ALARM':
      case 'ALARMS':
        // Link "You" -> Alarm
        final label = itemMap['label']?.toString() ??
            itemMap['title']?.toString() ??
            'Alarm';
        final recurrenceType =
            itemMap['recurrenceType']?.toString() ?? 'single-occurrence';
        final isRecurrent = recurrenceType == 'recurrent';
        final alarmName =
            isRecurrent ? 'Recurring alarm: $label' : 'Alarm: $label';
        primaryEntityId = _generateEntityId(alarmName, 'ALARM');
        break;
    }

    // Create the hub link if we have a primary entity
    // This connects: Hub -> Entity, and ensures Hub -> You exists
    if (primaryEntityId != null) {
      final hubLink = await _linkPredictor.linkToHub(
        entityId: primaryEntityId,
        dataSourceType: dataType,
        embeddingCallback: _embeddingCallback,
      );

      if (hubLink != null) {
        try {
          await repository.addRelationship(hubLink.toRelationship());
          _updateProgress(_progress.copyWith(
            predictedLinks: _progress.predictedLinks + 1,
          ));
          assert(() {
            print('[BackgroundIndexing] Added hub link to $primaryEntityId');
            return true;
          }());
        } catch (e) {
          // Link might already exist
          assert(() {
            print('[BackgroundIndexing] Hub link error: $e');
            return true;
          }());
        }
      }
    }
  }

  /// Apply template-based inference for an item
  /// Creates deterministic links based on structured data fields
  Future<void> _applyTemplateInference(
    Map<String, dynamic> itemMap,
    String dataType,
  ) async {
    if (_linkPredictor == null) return;

    final templateLinks = _linkPredictor.inferFromStructured(itemMap, dataType);

    if (templateLinks.isEmpty) return;

    var stored = 0;
    for (final link in templateLinks) {
      try {
        // Check if both entities exist before creating the relationship
        final source = await repository.getEntity(link.sourceEntityId);
        final target = await repository.getEntity(link.targetEntityId);

        if (source != null && target != null) {
          await repository.addRelationship(link.toRelationship());
          stored++;
        }
      } catch (e) {
        // Link might already exist, ignore
      }
    }

    if (stored > 0) {
      _updateProgress(_progress.copyWith(
        predictedLinks: _progress.predictedLinks + stored,
      ));
      assert(() {
        print(
            '[BackgroundIndexing] Applied $stored template-based links for $dataType');
        return true;
      }());
    }
  }

  /// Phase 1.5: Link prediction (template-based + co-mention)
  Future<void> _linkPredictionPhase() async {
    if (_linkPredictor == null) return;

    _updateProgress(_progress.copyWith(
      currentPhase: 'Predicting links',
    ));

    print('[BackgroundIndexing] Starting link prediction phase');
    print(
        '[BackgroundIndexing] Processing ${_batchExtractions.length} extractions for co-mention detection');

    // 1. Detect co-mentions across all extractions
    final coMentionLinks = await _linkPredictor.detectCoMentions(
      extractions: _batchExtractions,
    );
    print(
        '[BackgroundIndexing] Detected ${coMentionLinks.length} co-mention links');

    // 2. Store co-mention links
    var storedCoMentions = 0;
    for (final link in coMentionLinks) {
      try {
        // Check if both entities exist
        final source = await repository.getEntity(link.sourceEntityId);
        final target = await repository.getEntity(link.targetEntityId);

        if (source != null && target != null) {
          await repository.addRelationship(link.toRelationship());
          storedCoMentions++;
        }
      } catch (e) {
        // Link might already exist
      }
    }
    print('[BackgroundIndexing] Stored $storedCoMentions co-mention links');

    // 3. Infer colleague relationships from shared organizations
    final colleagueLinks = await _linkPredictor.inferColleagueRelationships();
    print(
        '[BackgroundIndexing] Inferred ${colleagueLinks.length} colleague relationships');

    var storedColleagues = 0;
    for (final link in colleagueLinks) {
      try {
        await repository.addRelationship(link.toRelationship());
        storedColleagues++;
      } catch (e) {
        // Link might already exist
      }
    }
    print('[BackgroundIndexing] Stored $storedColleagues colleague links');

    _updateProgress(_progress.copyWith(
      predictedLinks:
          _progress.predictedLinks + storedCoMentions + storedColleagues,
    ));

    print('[BackgroundIndexing] Link prediction phase complete');
  }

  /// Phase 1.6: Embedding similarity-based link prediction
  Future<void> _embeddingSimilarityPhase() async {
    if (_embeddingSimilarityPredictor == null) return;

    _updateProgress(_progress.copyWith(
      currentPhase: 'Finding similar entities',
    ));

    print('[BackgroundIndexing] Starting embedding similarity phase');

    // 1. Find candidate pairs based on embedding similarity
    final candidates = await _embeddingSimilarityPredictor.findCandidates();

    if (candidates.isEmpty) {
      print('[BackgroundIndexing] No embedding similarity candidates found');
      return;
    }

    _updateProgress(_progress.copyWith(
      currentPhase: 'Validating similar pairs',
    ));

    // 2. Validate candidates with LLM chain and create links
    final validatedLinks =
        await _embeddingSimilarityPredictor.validateAndCreateLinks(candidates);

    // 3. Store validated links
    var storedLinks = 0;
    for (final link in validatedLinks) {
      try {
        await repository.addRelationship(link.toRelationship());
        storedLinks++;
      } catch (e) {
        // Link might already exist
      }
    }

    _updateProgress(_progress.copyWith(
      predictedLinks: _progress.predictedLinks + storedLinks,
    ));

    print(
        '[BackgroundIndexing] Embedding similarity phase complete: $storedLinks links created');
  }

  /// Phase 2: Detect communities
  Future<void> _detectCommunitiesPhase() async {
    _updateProgress(_progress.copyWith(
      currentPhase: 'Detecting communities',
    ));

    print('[BackgroundIndexing] Starting community detection phase');

    // Get all entities and relationships
    final entities = <GraphEntity>[];
    final relationships = <GraphRelationship>[];

    // Load all entities (simplified - in production, use pagination)
    // Include SELF type for the "You" central node, plus all EntityTypes except DATE and HUB
    final communityEntityTypes = [
      'SELF',
      ...EntityTypes.all
          .where((t) => t != EntityTypes.date && t != EntityTypes.hub)
    ];
    for (final type in communityEntityTypes) {
      final typeEntities = await repository.getEntitiesByType(type);
      entities.addAll(typeEntities);
      if (typeEntities.isNotEmpty) {
        print(
            '[BackgroundIndexing] Loaded ${typeEntities.length} $type entities');
      }
    }

    print(
        '[BackgroundIndexing] Total entities for community detection: ${entities.length}');

    // Load relationships for each entity
    for (final entity in entities) {
      final rels = await repository.getRelationships(entity.id);
      relationships.addAll(rels);
    }

    print(
        '[BackgroundIndexing] Total relationships for community detection: ${relationships.length}');

    // Run community detection
    final result = await _communityDetector.detectCommunities(
      entities,
      relationships,
    );

    print(
        '[BackgroundIndexing] Detected ${result.communities.length} communities');

    // Build set of valid entity IDs for validation
    final validEntityIds = entities.map((e) => e.id).toSet();
    print('[BackgroundIndexing] Valid entity IDs: ${validEntityIds.length}');

    // Snapshot existing communities so we can diff and skip unchanged ones.
    // This avoids wiping summaries that are still valid and saves expensive
    // LLM calls in Phase 3.
    final existingByCanonical = <String, GraphCommunity>{};
    for (var level = config.maxCommunityDepth; level >= 0; level--) {
      final existing = await repository.getCommunitiesByLevel(level);
      for (final c in existing) {
        final key = CommunityMaintainer.canonicalKey(c.entityIds);
        existingByCanonical[key] = c;
      }
    }

    // Store communities — only new/changed ones
    var storedCount = 0;
    var unchangedCount = 0;
    final matchedOldIds = <String>{};

    for (final community in result.communities) {
      // Filter entity IDs to only include ones that exist in the database
      final validCommunityEntityIds = community.entityIds
          .where((id) => validEntityIds.contains(id))
          .toList();

      if (validCommunityEntityIds.isEmpty) {
        print(
            '[BackgroundIndexing] Skipping community ${community.id} - no valid entity IDs');
        continue;
      }

      if (validCommunityEntityIds.length != community.entityIds.length) {
        print(
            '[BackgroundIndexing] Community ${community.id} filtered from ${community.entityIds.length} to ${validCommunityEntityIds.length} entity IDs');
      }

      // Check if an existing community has the same entity set and a
      // valid summary — if so, skip the overwrite to preserve it.
      final canonicalKey =
          CommunityMaintainer.canonicalKey(validCommunityEntityIds);
      final existing = existingByCanonical[canonicalKey];

      if (existing != null && existing.summary.isNotEmpty) {
        // Entity set unchanged and summary already exists — skip.
        matchedOldIds.add(existing.id);
        unchangedCount++;
        continue;
      }

      // Include child community IDs in metadata for hierarchical summarization
      final metadata = <String, dynamic>{
        'modularity': community.modularity,
      };
      if (community.childCommunityIds != null &&
          community.childCommunityIds!.isNotEmpty) {
        metadata['childCommunityIds'] = community.childCommunityIds;
      }
      if (community.parentCommunityId != null) {
        metadata['parentCommunityId'] = community.parentCommunityId;
      }

      final graphCommunity = GraphCommunity(
        id: community.id,
        level: community.level,
        summary: '', // Will be generated in next phase
        entityIds: validCommunityEntityIds,
        embedding: null,
        metadata: metadata,
      );

      try {
        await repository.addCommunity(graphCommunity);
        storedCount++;
      } catch (e) {
        print(
            '[BackgroundIndexing] Failed to store community ${community.id}: $e');
      }
    }

    // Delete orphan communities — old rows whose entity-set no longer
    // matches any detected community.
    var deletedCount = 0;
    for (final oldCommunity in existingByCanonical.values) {
      if (!matchedOldIds.contains(oldCommunity.id)) {
        try {
          await repository.deleteCommunity(oldCommunity.id);
          deletedCount++;
        } catch (e) {
          print(
              '[BackgroundIndexing] Failed to delete orphan community ${oldCommunity.id}: $e');
        }
      }
    }

    print('[BackgroundIndexing] Communities: $storedCount stored, '
        '$unchangedCount unchanged (kept), $deletedCount orphans deleted');

    _updateProgress(_progress.copyWith(
      detectedCommunities: result.communities.length,
    ));
  }

  /// Phase 3: Generate community summaries (hierarchical approach from GraphRAG paper)
  ///
  /// Following the paper methodology:
  /// - Lowest level (most granular): summarize from entities and relationships
  /// - Higher levels: summarize from child community summaries
  Future<void> _generateSummariesPhase() async {
    if (_summarizer == null) return;

    _updateProgress(_progress.copyWith(
      currentPhase: 'Generating community summaries',
    ));

    // Get all entities and relationships for reference
    // Use the same broad type list as community detection to avoid empty summaries
    final entities = <GraphEntity>[];
    final relationships = <GraphRelationship>[];

    final summaryEntityTypes = [
      'SELF',
      ...EntityTypes.all
          .where((t) => t != EntityTypes.date && t != EntityTypes.hub)
    ];
    for (final type in summaryEntityTypes) {
      entities.addAll(await repository.getEntitiesByType(type));
    }

    for (final entity in entities) {
      relationships.addAll(await repository.getRelationships(entity.id));
    }

    // Find the maximum level (most granular)
    var maxLevel = 0;
    for (var level = 0; level <= config.maxCommunityDepth; level++) {
      final communities = await repository.getCommunitiesByLevel(level);
      if (communities.isNotEmpty) {
        maxLevel = level;
      }
    }

    // Store generated summaries for hierarchical aggregation
    final summaryByCommId = <String, CommunitySummary>{};

    // Generate summaries level by level, from most granular to root
    // This allows higher levels to aggregate from child summaries
    for (var level = maxLevel; level >= 0; level--) {
      if (_cancelRequested) return;

      final communities = await repository.getCommunitiesByLevel(level);
      print(
          '[BackgroundIndexing] Generating summaries for level $level (${communities.length} communities)');

      for (final community in communities) {
        if (_cancelRequested) return;

        // Skip communities that already have a valid summary (preserved
        // during the diff-based Phase 2 because their entity set was
        // unchanged). This avoids redundant LLM calls on re-index.
        if (community.summary.isNotEmpty) {
          print(
              '[BackgroundIndexing] Skipping summary for ${community.id} — already valid');
          continue;
        }

        final detectedCommunity = DetectedCommunity(
          id: community.id,
          level: community.level,
          entityIds: community.entityIds.toSet(),
          modularity: 0.0,
          childCommunityIds: community.childCommunityIds,
        );

        CommunitySummary summary;

        if (level == maxLevel) {
          // Most granular level: summarize from entities
          summary = await _summarizer.summarize(
            detectedCommunity,
            entities,
            relationships,
          );
        } else {
          // Higher level: try to aggregate from child summaries
          final childIds = community.childCommunityIds ?? [];
          final childSummaries = childIds
              .map((id) => summaryByCommId[id])
              .whereType<CommunitySummary>()
              .toList();

          if (childSummaries.isNotEmpty) {
            // Use hierarchical summarization
            summary = await _summarizer.summarizeHierarchical(
              detectedCommunity,
              childSummaries,
            );
            print(
                '[BackgroundIndexing] Generated hierarchical summary for ${community.id} from ${childSummaries.length} children');
          } else {
            // Fallback to entity-based summary
            summary = await _summarizer.summarize(
              detectedCommunity,
              entities,
              relationships,
            );
          }
        }

        // Store for potential use by parent communities
        summaryByCommId[community.id] = summary;

        await repository.updateCommunitySummary(
          community.id,
          summary.summary,
          summary.embedding,
        );
      }
    }

    print(
        '[BackgroundIndexing] Generated summaries for ${summaryByCommId.length} communities');
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
        'sourceApp': 'system_contacts',
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
        'recurrenceRule': item.recurrenceRule,
        'isRecurring': item.isRecurring,
        'calendarName': item.calendarName,
        'sourceApp': 'system_calendar',
      };
    }

    if (item is Photo) {
      return {
        'id': item.id,
        'filename': item.filename,
        'width': item.width,
        'height': item.height,
        'creationDate': item.creationDate.millisecondsSinceEpoch,
        'modificationDate': item.modificationDate.millisecondsSinceEpoch,
        'latitude': item.latitude,
        'longitude': item.longitude,
        'locationName': item.locationName,
        'mediaType': item.mediaType,
        'sourceApp': 'system_photos',
      };
    }

    if (item is PhoneCall) {
      // Compute start/end times from timestamp + duration
      final startDt = item.timestamp;
      final endDt = startDt.add(item.duration);
      final date =
          '${startDt.year}-${startDt.month.toString().padLeft(2, '0')}-${startDt.day.toString().padLeft(2, '0')}';
      final startTime =
          '${startDt.hour.toString().padLeft(2, '0')}:${startDt.minute.toString().padLeft(2, '0')}';
      final endTime =
          '${endDt.hour.toString().padLeft(2, '0')}:${endDt.minute.toString().padLeft(2, '0')}';

      return {
        'id': item.id,
        'contactName': item.contactName,
        'phoneNumber': item.phoneNumber,
        'callType': item.callType.toString().split('.').last,
        'callDirection': item.callType.toString().split('.').last,
        'timestamp': item.timestamp.millisecondsSinceEpoch,
        'duration': item.duration.inSeconds,
        'date': date,
        'startTime': startTime,
        'endTime': endTime,
        'sourceApp': 'system_calls',
      };
    }

    if (item is Document) {
      return {
        'id': item.id,
        'name': item.name,
        'path': item.path,
        'documentType': item.documentType.toString(),
        'mimeType': item.mimeType,
        'fileSize': item.fileSize,
        'createdDate': item.createdDate.millisecondsSinceEpoch,
        'modifiedDate': item.modifiedDate.millisecondsSinceEpoch,
        'textPreview': item.textPreview,
        'sourceApp': 'system_documents',
      };
    }

    return {'_raw': item.toString()};
  }

  /// Get item ID
  String _getItemId(dynamic item, String dataType) {
    if (item is Map<String, dynamic>) {
      return item['id']?.toString() ??
          DateTime.now().millisecondsSinceEpoch.toString();
    }
    if (item is Contact) return item.id;
    if (item is CalendarEvent) return item.id;
    if (item is Photo) return item.id;
    if (item is PhoneCall) return item.id;
    if (item is Document) return item.id;
    return DateTime.now().millisecondsSinceEpoch.toString();
  }

  /// Parse a dynamic date value (ISO-8601 or epoch millis) into DateTime.
  /// Used for embedding text generation to create human-readable dates.
  static DateTime? _parseDateForEmbedding(dynamic value) {
    if (value is DateTime) return value;
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is! String) return null;
    // Try epoch millis (numeric string)
    final asInt = int.tryParse(value);
    if (asInt != null && asInt > 1000000000) {
      if (asInt > 1e12.toInt()) {
        return DateTime.fromMillisecondsSinceEpoch(asInt);
      }
      return DateTime.fromMillisecondsSinceEpoch(asInt * 1000);
    }
    // Try ISO-8601
    return DateTime.tryParse(value);
  }

  /// Generate entity ID from name and type
  String _generateEntityId(String name, String type) {
    final normalized = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_');
    final typePrefix = type.isNotEmpty ? '${type.toLowerCase()}_' : '';
    return '$typePrefix$normalized';
  }

  /// Get the primary entity ID for an item based on its data type
  /// Used for incremental indexing to skip already-indexed items
  String? _getPrimaryEntityId(Map<String, dynamic> itemMap, String dataType) {
    switch (dataType.toUpperCase()) {
      case 'CONTACT':
      case 'CONTACTS':
        final name = itemMap['fullName'] ?? itemMap['name'];
        if (name != null && name.toString().isNotEmpty) {
          return _generateEntityId(name.toString(), 'PERSON');
        }
        break;
      case 'CALENDAR':
      case 'CALENDAR_EVENT':
        final title = itemMap['title'];
        if (title != null && title.toString().isNotEmpty) {
          return _generateEntityId(title.toString(), 'EVENT');
        }
        break;
      case 'PHOTO':
      case 'PHOTOS':
        // Use filename as entity name (matches DirectEntityExtractor)
        final photoName =
            itemMap['filename'] ?? itemMap['name'] ?? itemMap['id'];
        if (photoName != null && photoName.toString().isNotEmpty) {
          return _generateEntityId(photoName.toString(), 'PHOTO');
        }
        break;
      case 'PHONE_CALL':
      case 'PHONE_CALLS':
        // Entity extractor names calls "Call with <contact> on <date> <time>"
        final contactName = itemMap['contactName'] ?? itemMap['name'];
        final phoneNumber = itemMap['phoneNumber'] ?? itemMap['number'];
        final callId = itemMap['id']?.toString() ?? '';
        // Reconstruct date+time suffix to match entity extractor
        String dateSuffix = '';
        final ts = itemMap['timestamp'] ?? itemMap['date'];
        final startTime = itemMap['startTime'];
        if (ts != null) {
          final millis = ts is int ? ts : int.tryParse(ts.toString());
          if (millis != null) {
            final dt = DateTime.fromMillisecondsSinceEpoch(millis);
            final dateStr = '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
            dateSuffix = ' on $dateStr';
          }
        }
        if (startTime != null) {
          dateSuffix = '$dateSuffix $startTime';
        }
        if (contactName != null && contactName.toString().isNotEmpty) {
          return _generateEntityId('Call with $contactName$dateSuffix', 'PHONE_CALL');
        } else if (phoneNumber != null && phoneNumber.toString().isNotEmpty) {
          return _generateEntityId('Call $phoneNumber$dateSuffix', 'PHONE_CALL');
        } else if (callId.isNotEmpty) {
          return _generateEntityId('Call $callId$dateSuffix', 'PHONE_CALL');
        }
        break;
      case 'NOTE':
      case 'NOTES':
        final title = itemMap['title'];
        if (title != null && title.toString().isNotEmpty) {
          return _generateEntityId(title.toString(), 'NOTE');
        }
        break;
      case 'DOCUMENT':
      case 'DOCUMENTS':
        final name = itemMap['name'] ?? itemMap['title'];
        if (name != null && name.toString().isNotEmpty) {
          return _generateEntityId(name.toString(), 'DOCUMENT');
        }
        break;
      case 'ALARM':
      case 'ALARMS':
        // Entity extractor names alarms "Alarm: <label>" or "Recurring alarm: <label>"
        final label = itemMap['label']?.toString() ??
            itemMap['title']?.toString() ??
            'Alarm';
        final recurrenceType =
            itemMap['recurrenceType']?.toString() ?? 'single-occurrence';
        final isRecurrent = recurrenceType == 'recurrent';
        final alarmName =
            isRecurrent ? 'Recurring alarm: $label' : 'Alarm: $label';
        return _generateEntityId(alarmName, 'ALARM');
    }
    return null;
  }

  /// Detect and remove entities whose source data has been deleted from
  /// the device, then clean up any orphan nodes left behind.
  Future<void> _pruneStaleEntitiesPhase() async {
    _updateProgress(_progress.copyWith(
      currentPhase: 'Pruning deleted data',
    ));

    final pruner = GraphPruner(
      repository: repository,
      connectorManager: connectorManager,
    );

    final result = await pruner.prune();

    if (result.totalRemoved > 0) {
      print(
          '[BackgroundIndexing] Pruning removed '
          '${result.removedStaleEntities.length} stale + '
          '${result.removedOrphanEntities.length} orphan entities');

      // Update communities affected by the deleted entities.
      // Pass summarizer: null because Phase 2 will re-run full Leiden and
      // Phase 3 will regenerate summaries — no point wasting LLM calls here.
      final allDeletedIds = [
        ...result.removedStaleEntities,
        ...result.removedOrphanEntities,
      ];

      final maintainer = CommunityMaintainer(
        repository: repository,
        summarizer: null,
        communityConfig: CommunityDetectionConfig(
          maxDepth: config.maxCommunityDepth,
        ),
      );

      final maintenance = await maintainer.onEntitiesDeleted(allDeletedIds);
      if (maintenance.totalAffected > 0) {
        print(
            '[BackgroundIndexing] Community maintenance after pruning: $maintenance');
      }
    }
  }

  /// Update progress and notify listeners
  void _updateProgress(IndexingProgress progress) {
    _progress = progress;
    _progressController.add(progress);

    // Update notification progress if foreground service is running
    if (_useForegroundService && progress.status == IndexingStatus.running) {
      _platform
          .updateIndexingProgress(
            progress: progress.progress,
            phase: progress.currentPhase,
            entities: progress.extractedEntities,
            relationships: progress.extractedRelationships,
          )
          .catchError((_) {}); // Ignore errors
    }
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
