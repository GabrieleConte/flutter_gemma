import 'dart:async';

import '../../pigeon.g.dart';
import '../connectors/data_connector.dart';
import 'graph_repository.dart';
import 'entity_extractor.dart';
import 'community_detection.dart';
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
      extractedRelationships: extractedRelationships ?? this.extractedRelationships,
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
  late final LinkPredictor? _linkPredictor;
  late final Future<List<double>> Function(String text) _embeddingCallback;
  final PlatformService _platform = PlatformService();
  
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
    IndexingConfig? config,
  }) : config = config ?? IndexingConfig() {
    _embeddingCallback = embeddingCallback;
    
    _communityDetector = LouvainCommunityDetector(
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
  Future<void> startIndexing({bool fullReindex = false, bool useForegroundService = true}) async {
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
      
      // Phase 1.5: Link prediction (after entity extraction)
      if (config.enableLinkPrediction && _linkPredictor != null) {
        await _linkPredictionPhase();
        if (_cancelRequested) return;
      }

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
        
        // Debug: Log extraction results
        assert(() {
          print('[BackgroundIndexing] Extracted ${extraction.entities.length} entities, ${extraction.relationships.length} relationships from $dataType item');
          return true;
        }());

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
            assert(() {
              print('[BackgroundIndexing] Added entity: ${entity.name} (${entity.type})');
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
          String? sourceEntityId = entityNameToId[rel.sourceEntity] 
              ?? entityNameToId[rel.sourceEntity.toLowerCase()];
          String? targetEntityId = entityNameToId[rel.targetEntity]
              ?? entityNameToId[rel.targetEntity.toLowerCase()];
          
          // If we can't find the entities in this extraction, try generating IDs
          // with common type prefixes
          if (sourceEntityId == null) {
            for (final type in ['PERSON', 'ORGANIZATION', 'LOCATION', 'EVENT', '']) {
              final candidateId = _generateEntityId(rel.sourceEntity, type);
              final exists = await repository.getEntity(candidateId);
              if (exists != null) {
                sourceEntityId = candidateId;
                break;
              }
            }
          }
          if (targetEntityId == null) {
            for (final type in ['PERSON', 'ORGANIZATION', 'LOCATION', 'EVENT', '']) {
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
              print('[BackgroundIndexing] Skipping relationship: could not find entity IDs for ${rel.sourceEntity} -> ${rel.targetEntity}');
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
              print('[BackgroundIndexing] Added relationship: ${rel.sourceEntity} -[${rel.type}]-> ${rel.targetEntity}');
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
          extractedEntities: _progress.extractedEntities + extraction.entities.length,
          extractedRelationships: _progress.extractedRelationships + extraction.relationships.length,
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
        final id = itemMap['id'] ?? itemMap['name'];
        if (id != null && id.toString().isNotEmpty) {
          primaryEntityId = _generateEntityId(id.toString(), 'PHOTO');
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
    }
    
    // Create the "You" link if we have a primary entity
    if (primaryEntityId != null) {
      final youLink = await _linkPredictor.linkToYou(
        entityId: primaryEntityId,
        dataSourceType: dataType,
      );
      
      if (youLink != null) {
        try {
          await repository.addRelationship(youLink.toRelationship());
          _updateProgress(_progress.copyWith(
            predictedLinks: _progress.predictedLinks + 1,
          ));
          assert(() {
            print('[BackgroundIndexing] Added "You" link to $primaryEntityId');
            return true;
          }());
        } catch (e) {
          // Link might already exist
          assert(() {
            print('[BackgroundIndexing] "You" link error: $e');
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
        print('[BackgroundIndexing] Applied $stored template-based links for $dataType');
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
    print('[BackgroundIndexing] Processing ${_batchExtractions.length} extractions for co-mention detection');
    
    // 1. Detect co-mentions across all extractions
    final coMentionLinks = await _linkPredictor.detectCoMentions(
      extractions: _batchExtractions,
    );
    print('[BackgroundIndexing] Detected ${coMentionLinks.length} co-mention links');
    
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
    print('[BackgroundIndexing] Inferred ${colleagueLinks.length} colleague relationships');
    
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
      predictedLinks: _progress.predictedLinks + storedCoMentions + storedColleagues,
    ));
    
    print('[BackgroundIndexing] Link prediction phase complete');
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
    // Include SELF type for the "You" central node, plus all data types
    for (final type in ['SELF', 'PERSON', 'ORGANIZATION', 'EVENT', 'LOCATION', 'DOCUMENT', 'PHOTO', 'NOTE', 'TOPIC', 'PROJECT']) {
      final typeEntities = await repository.getEntitiesByType(type);
      entities.addAll(typeEntities);
      if (typeEntities.isNotEmpty) {
        print('[BackgroundIndexing] Loaded ${typeEntities.length} $type entities');
      }
    }
    
    print('[BackgroundIndexing] Total entities for community detection: ${entities.length}');

    // Load relationships for each entity
    for (final entity in entities) {
      final rels = await repository.getRelationships(entity.id);
      relationships.addAll(rels);
    }
    
    print('[BackgroundIndexing] Total relationships for community detection: ${relationships.length}');

    // Run community detection
    final result = await _communityDetector.detectCommunities(
      entities,
      relationships,
    );
    
    print('[BackgroundIndexing] Detected ${result.communities.length} communities');
    
    // Build set of valid entity IDs for validation
    final validEntityIds = entities.map((e) => e.id).toSet();
    print('[BackgroundIndexing] Valid entity IDs: ${validEntityIds.length}');

    // Store communities
    var storedCount = 0;
    for (final community in result.communities) {
      // Filter entity IDs to only include ones that exist in the database
      final validCommunityEntityIds = community.entityIds
          .where((id) => validEntityIds.contains(id))
          .toList();
      
      if (validCommunityEntityIds.isEmpty) {
        print('[BackgroundIndexing] Skipping community ${community.id} - no valid entity IDs');
        continue;
      }
      
      if (validCommunityEntityIds.length != community.entityIds.length) {
        print('[BackgroundIndexing] Community ${community.id} filtered from ${community.entityIds.length} to ${validCommunityEntityIds.length} entity IDs');
      }
      
      // Include child community IDs in metadata for hierarchical summarization
      final metadata = <String, dynamic>{
        'modularity': community.modularity,
      };
      if (community.childCommunityIds != null && community.childCommunityIds!.isNotEmpty) {
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
        print('[BackgroundIndexing] Failed to store community ${community.id}: $e');
      }
    }
    
    print('[BackgroundIndexing] Successfully stored $storedCount communities');

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
    final entities = <GraphEntity>[];
    final relationships = <GraphRelationship>[];
    
    for (final type in ['PERSON', 'ORGANIZATION', 'EVENT', 'LOCATION']) {
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
      print('[BackgroundIndexing] Generating summaries for level $level (${communities.length} communities)');

      for (final community in communities) {
        if (_cancelRequested) return;

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
            print('[BackgroundIndexing] Generated hierarchical summary for ${community.id} from ${childSummaries.length} children');
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
    
    print('[BackgroundIndexing] Generated summaries for ${summaryByCommId.length} communities');
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
    
    // Update notification progress if foreground service is running
    if (_useForegroundService && progress.status == IndexingStatus.running) {
      _platform.updateIndexingProgress(
        progress: progress.progress,
        phase: progress.currentPhase,
        entities: progress.extractedEntities,
        relationships: progress.extractedRelationships,
      ).catchError((_) {}); // Ignore errors
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
