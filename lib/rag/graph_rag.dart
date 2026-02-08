import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/tool.dart';
import '../pigeon.g.dart';
import 'connectors/data_connector.dart';
import 'connectors/google_suite_connector.dart';
import 'graph/graph_repository.dart';
import 'graph/entity_extractor.dart';
import 'graph/community_detection.dart';
import 'graph/cypher_parser.dart';
import 'graph/hybrid_query_engine.dart';
import 'graph/global_query_engine.dart';
import 'graph/background_indexing.dart';
import 'graph/link_prediction.dart';
import 'graph/cache_manager.dart';
import 'graph_rag_config.dart';

/// Configuration for GraphRAG
class GraphRAGConfig {
  /// Path to the graph database file
  final String databasePath;
  
  /// Configuration for hybrid queries
  final HybridQueryConfig queryConfig;
  
  /// Configuration for entity extraction
  final EntityExtractionConfig extractionConfig;
  
  /// Configuration for community detection
  final CommunityDetectionConfig communityConfig;
  
  /// Configuration for background indexing
  final IndexingConfig indexingConfig;
  
  /// Extended configuration for LiteRT-LM integration
  final GraphRAGExtendedConfig extendedConfig;
  
  /// Whether to auto-start indexing on initialization
  final bool autoIndex;

  GraphRAGConfig({
    required this.databasePath,
    HybridQueryConfig? queryConfig,
    EntityExtractionConfig? extractionConfig,
    CommunityDetectionConfig? communityConfig,
    IndexingConfig? indexingConfig,
    GraphRAGExtendedConfig? extendedConfig,
    this.autoIndex = false,
  })  : queryConfig = queryConfig ?? HybridQueryConfig(),
        extractionConfig = extractionConfig ?? EntityExtractionConfig(),
        communityConfig = communityConfig ?? CommunityDetectionConfig(),
        indexingConfig = indexingConfig ?? IndexingConfig(),
        extendedConfig = extendedConfig ?? const GraphRAGExtendedConfig();
}

/// Main facade for GraphRAG functionality
/// 
/// This class provides a unified interface for:
/// - Managing data connectors (system APIs, Google Suite)
/// - Building and querying the knowledge graph
/// - Running background indexing
/// - Executing hybrid queries (Cypher + semantic)
/// - Automatic backend selection (NPU/GPU/CPU) with fallback
class GraphRAG {
  final GraphRAGConfig _config;
  final PlatformService _platform;
  final Future<String> Function(String prompt) _llmCallback;
  final Future<List<double>> Function(String text) _embeddingCallback;
  final Future<String> Function(String prompt, Uint8List imageBytes)? _visionLlmCallback;
  
  /// Optional callback for entity extraction with tool support
  /// If provided, enables structured function calling for extraction
  final Future<String> Function(String prompt, {List<Tool>? tools})? _extractionLlmCallback;
  
  /// Callback to notify when extraction phase is complete (can deallocate extraction model)
  final Future<void> Function()? _onExtractionPhaseComplete;
  
  /// Callback to prepare main LLM before summarization (can reallocate if needed)
  final Future<void> Function()? _onBeforeSummarization;
  
  late final NativeGraphRepository _repository;
  late final ConnectorManager _connectorManager;
  late final EntityExtractor _extractor;
  late final HybridQueryEngine _queryEngine;
  late final BackgroundIndexingService _indexingService;
  
  /// Cache manager for model caching (5-10x faster reloads)
  late final ModelCacheManager _cacheManager;
  
  /// Device capability detector for backend selection
  late final DeviceCapabilityDetector _deviceDetector;
  
  /// Backend fallback manager
  late final BackendFallbackManager _fallbackManager;
  
  /// Currently active backend
  PreferredBackend? _activeBackend;
  
  bool _initialized = false;

  GraphRAG({
    required GraphRAGConfig config,
    required PlatformService platform,
    required Future<String> Function(String prompt) llmCallback,
    required Future<List<double>> Function(String text) embeddingCallback,
    Future<String> Function(String prompt, Uint8List imageBytes)? visionLlmCallback,
    Future<String> Function(String prompt, {List<Tool>? tools})? extractionLlmCallback,
    Future<void> Function()? onExtractionPhaseComplete,
    Future<void> Function()? onBeforeSummarization,
    DeviceCapabilityDetector? deviceDetector,
    ModelCacheManager? cacheManager,
  })  : _config = config,
        _platform = platform,
        _llmCallback = llmCallback,
        _embeddingCallback = embeddingCallback,
        _visionLlmCallback = visionLlmCallback,
        _extractionLlmCallback = extractionLlmCallback,
        _onExtractionPhaseComplete = onExtractionPhaseComplete,
        _onBeforeSummarization = onBeforeSummarization {
    // Initialize capability detector (can be mocked for testing)
    _deviceDetector = deviceDetector ?? DeviceCapabilityDetector();
    
    // Initialize cache manager
    _cacheManager = cacheManager ?? 
        (config.extendedConfig.enableCacheDir 
            ? LiteRTModelCacheManager(
                customCacheDirectory: config.extendedConfig.cacheDirectoryPath,
                enableLogging: config.extendedConfig.enablePerformanceLogging,
              )
            : MockModelCacheManager());
    
    // Initialize fallback manager
    _fallbackManager = BackendFallbackManager(
      detector: _deviceDetector,
      enablePerformanceLogging: config.extendedConfig.enablePerformanceLogging,
    );
  }

  /// Whether GraphRAG is initialized
  bool get isInitialized => _initialized;
  
  /// Currently active backend after initialization
  PreferredBackend? get activeBackend => _activeBackend;
  
  /// Cache manager for model caching
  ModelCacheManager get cacheManager => _cacheManager;
  
  /// Device capability detector
  DeviceCapabilityDetector get deviceDetector => _deviceDetector;

  /// Access to the graph repository
  GraphRepository get repository {
    _checkInitialized();
    return _repository;
  }

  /// Access to the connector manager
  ConnectorManager get connectors {
    _checkInitialized();
    return _connectorManager;
  }

  /// Access to the query engine
  HybridQueryEngine get queryEngine {
    _checkInitialized();
    return _queryEngine;
  }

  /// Access to the indexing service
  BackgroundIndexingService get indexing {
    _checkInitialized();
    return _indexingService;
  }

  /// Stream of indexing progress
  Stream<IndexingProgress> get indexingProgress {
    _checkInitialized();
    return _indexingService.progressStream;
  }

  /// Current indexing status
  IndexingProgress get indexingStatus {
    _checkInitialized();
    return _indexingService.progress;
  }

  /// Initialize GraphRAG
  Future<void> initialize() async {
    if (_initialized) return;

    // Initialize graph repository
    _repository = NativeGraphRepository(_platform);
    await _repository.initialize(_config.databasePath);

    // Setup connector manager with system connectors
    _connectorManager = ConnectorManager();
    _connectorManager.registerConnector(
      ContactsConnector(_platform),
    );
    _connectorManager.registerConnector(
      CalendarConnector(_platform),
    );
    _connectorManager.registerConnector(
      PhotosConnector(_platform),
    );
    _connectorManager.registerConnector(
      CallLogConnector(_platform),
    );
    _connectorManager.registerConnector(
      DocumentsConnector(_platform),
    );

    // Setup entity extractor with optional native function calling
    final extendedConfig = _config.extendedConfig;
    final extractionCallback = _extractionLlmCallback;
    if (extendedConfig.enableFunctionCalling && extractionCallback != null) {
      // Use adaptive extractor with proper tool support
      _extractor = AdaptiveEntityExtractor(
        llmCallback: (prompt, {tools}) => extractionCallback(
          prompt,
          tools: tools?.cast<Tool>(),
        ),
        embeddingCallback: _embeddingCallback,
        enableFunctionCalling: true,
        config: _config.extractionConfig,
        enableLogging: extendedConfig.enablePerformanceLogging,
      );
      if (extendedConfig.enablePerformanceLogging) {
        debugPrint('[GraphRAG] Using AdaptiveEntityExtractor with tool support');
      }
    } else if (extendedConfig.enableFunctionCalling) {
      // Function calling enabled but no extraction callback - use LLM with fallback
      _extractor = AdaptiveEntityExtractor(
        llmCallback: (prompt, {tools}) => _llmCallback(prompt),
        embeddingCallback: _embeddingCallback,
        enableFunctionCalling: false, // Disable native, use JSON extraction
        config: _config.extractionConfig,
        enableLogging: extendedConfig.enablePerformanceLogging,
      );
      if (extendedConfig.enablePerformanceLogging) {
        debugPrint('[GraphRAG] Using AdaptiveEntityExtractor without tool support (no extractionLlmCallback)');
      }
    } else {
      // Use standard LLM extractor
      _extractor = LLMEntityExtractor(
        llmCallback: _llmCallback,
        embeddingCallback: _embeddingCallback,
        config: _config.extractionConfig,
      );
      if (extendedConfig.enablePerformanceLogging) {
        debugPrint('[GraphRAG] Using LLMEntityExtractor');
      }
    }

    // Setup query engine with LLM for local answer generation
    _queryEngine = HybridQueryEngine(
      repository: _repository,
      embeddingCallback: _embeddingCallback,
      llmCallback: _llmCallback,
      config: _config.queryConfig,
    );

    // Setup indexing service
    _indexingService = BackgroundIndexingService(
      repository: _repository,
      extractor: _extractor,
      connectorManager: _connectorManager,
      llmCallback: _llmCallback,
      embeddingCallback: _embeddingCallback,
      visionLlmCallback: _visionLlmCallback,
      structuredLlmCallback: _extractionLlmCallback,
      onExtractionPhaseComplete: _onExtractionPhaseComplete,
      onBeforeSummarization: _onBeforeSummarization,
      config: _config.indexingConfig,
    );

    _initialized = true;

    // Auto-start indexing if configured
    if (_config.autoIndex) {
      await startIndexing();
    }
  }
  
  /// Initialize with backend selection and fallback
  /// 
  /// This method attempts to initialize with the preferred backend,
  /// falling back to less capable backends on error.
  /// 
  /// Returns the [BackendInitResult] with the successfully initialized
  /// backend and any fallback attempts.
  Future<BackendInitResult> initializeWithBackendFallback({
    Future<bool> Function(PreferredBackend backend)? backendInitCallback,
  }) async {
    // First do standard initialization
    await initialize();
    
    // If no backend callback provided, just detect optimal backend
    if (backendInitCallback == null) {
      final optimal = await _deviceDetector.detectOptimalBackend(
        enableNPU: _config.extendedConfig.enableNPUDetection,
      );
      _activeBackend = toPreferredBackend(optimal);
      return BackendInitResult(
        backend: _activeBackend!,
        success: true,
        attemptedBackends: [_activeBackend!],
      );
    }
    
    // Use fallback manager for backend initialization
    final result = await _fallbackManager.initializeWithFallback(
      preferredBackend: _config.extendedConfig.preferredBackend,
      initCallback: backendInitCallback,
      enableNPU: _config.extendedConfig.enableNPUDetection,
    );
    
    if (result.success) {
      _activeBackend = result.backend;
    }
    
    return result;
  }
  
  /// Get optimal context size for current backend
  int getOptimalContextSize({String? modelId}) {
    final backend = _activeBackend ?? PreferredBackend.gpu;
    return ContextWindowManager.getOptimalContextSize(
      backend: backend,
      modelId: modelId,
      requestedSize: _config.extendedConfig.maxContextTokens,
    );
  }
  
  /// Check if the current backend supports global queries
  /// 
  /// Global queries require more context for map-reduce operations.
  /// NPU backend has reduced context and may not support complex global queries.
  bool supportsGlobalQueries() {
    final contextSize = getOptimalContextSize();
    return ContextWindowManager.isSufficientForGlobalQuery(contextSize);
  }

  /// Close GraphRAG and release resources
  Future<void> close() async {
    if (!_initialized) return;

    _indexingService.dispose();
    await _repository.close();
    _initialized = false;
  }

  // === Connector Management ===

  /// Register a Google Suite connector
  void registerGoogleConnector(GoogleSuiteConfig config) {
    _checkInitialized();
    
    _connectorManager.registerConnector(
      GoogleContactsConnector(config),
    );
    _connectorManager.registerConnector(
      GoogleCalendarConnector(config),
    );
    _connectorManager.registerConnector(
      GoogleDriveConnector(config),
    );
    _connectorManager.registerConnector(
      GmailConnector(config),
    );
  }

  /// Check permissions for all connectors
  Future<Map<String, Map<DataPermissionType, DataPermissionStatus>>> 
      checkPermissions() async {
    _checkInitialized();
    return await _connectorManager.checkAllPermissions();
  }

  /// Request permissions for a specific data type
  Future<Map<DataPermissionType, DataPermissionStatus>> 
      requestPermissions(String dataType) async {
    _checkInitialized();
    return await _connectorManager.requestPermissions(dataType);
  }

  // === Indexing ===

  /// Start background indexing
  /// Set [useForegroundService] to true to keep indexing alive when app is backgrounded (Android only)
  Future<void> startIndexing({
    bool fullReindex = false,
    bool useForegroundService = true,
  }) async {
    _checkInitialized();
    await _indexingService.startIndexing(
      fullReindex: fullReindex,
      useForegroundService: useForegroundService,
    );
  }

  /// Pause indexing
  void pauseIndexing() {
    _checkInitialized();
    _indexingService.pauseIndexing();
  }

  /// Resume indexing
  Future<void> resumeIndexing() async {
    _checkInitialized();
    await _indexingService.resumeIndexing();
  }

  /// Cancel indexing
  Future<void> cancelIndexing() async {
    _checkInitialized();
    await _indexingService.cancelIndexing();
  }

  /// Wait for indexing to complete
  Future<void> waitForIndexing() async {
    _checkInitialized();
    await _indexingService.waitForCompletion();
  }

  // === Querying ===

  /// Execute a query (natural language or Cypher)
  Future<HybridQueryResult> query(
    String query, {
    String? cypherQuery,
    List<String>? entityTypes,
  }) async {
    _checkInitialized();
    return await _queryEngine.query(
      query,
      cypherQuery: cypherQuery,
      entityTypes: entityTypes,
    );
  }
  
  /// Execute a local query with answer generation
  /// Returns retrieval results plus a generated answer based on top entities
  Future<HybridQueryResult> queryWithAnswer(
    String query, {
    String? cypherQuery,
    List<String>? entityTypes,
  }) async {
    _checkInitialized();
    return await _queryEngine.queryWithAnswer(
      query,
      cypherQuery: cypherQuery,
      entityTypes: entityTypes,
    );
  }
  
  /// Stream a local query answer
  /// Yields tokens as they are generated
  Stream<String> queryWithAnswerStreaming(
    String query, {
    String? cypherQuery,
    List<String>? entityTypes,
    required Stream<String> Function(String prompt) llmStreamCallback,
  }) async* {
    _checkInitialized();
    yield* _queryEngine.queryWithAnswerStreaming(
      query,
      cypherQuery: cypherQuery,
      entityTypes: entityTypes,
      llmStreamCallback: llmStreamCallback,
    );
  }

  /// Build a query fluently
  HybridQueryBuilder buildQuery() {
    _checkInitialized();
    return HybridQueryBuilder();
  }

  /// Execute a Cypher query directly
  Future<List<Map<String, dynamic>>> cypherQuery(String cypher) async {
    _checkInitialized();
    final executor = CypherQueryExecutor(_repository);
    return await executor.execute(cypher);
  }

  /// Search entities by similarity
  Future<List<ScoredEntity>> searchEntities(
    String query, {
    int topK = 10,
    String? entityType,
  }) async {
    _checkInitialized();
    
    final embedding = await _embeddingCallback(query);
    return await _repository.searchEntitiesBySimilarity(
      embedding,
      topK: topK,
      entityType: entityType,
    );
  }

  /// Search communities by similarity
  Future<List<ScoredCommunity>> searchCommunities(
    String query, {
    int topK = 5,
    int? level,
  }) async {
    _checkInitialized();
    
    final embedding = await _embeddingCallback(query);
    return await _repository.searchCommunitiesBySimilarity(
      embedding,
      topK: topK,
      level: level,
    );
  }

  /// Execute a global query using the GraphRAG paper's map-reduce approach
  /// 
  /// This is the recommended method for "sensemaking" queries that require
  /// understanding across the entire dataset, such as:
  /// - "What are the main themes in my contacts?"
  /// - "How are my events connected?"
  /// - "Who are the most important people in my network?"
  /// 
  /// The method works by:
  /// 1. MAP: Each community summary generates a partial answer with helpfulness score
  /// 2. REDUCE: Top-scored answers are combined into a final comprehensive answer
  Future<GlobalQueryResult> globalQuery(
    String query, {
    int communityLevel = 1,
    int maxCommunityAnswers = 10,
    int minHelpfulnessScore = 20,
    String responseType = 'multiple paragraphs',
  }) async {
    _checkInitialized();
    
    final engine = GlobalQueryEngine(
      repository: _repository,
      llmCallback: _llmCallback,
      embeddingCallback: _embeddingCallback,
      config: GlobalQueryConfig(
        communityLevel: communityLevel,
        maxCommunityAnswers: maxCommunityAnswers,
        minHelpfulnessScore: minHelpfulnessScore,
        responseType: responseType,
      ),
    );
    
    return await engine.query(query);
  }
  
  /// Execute a global query with automatic community level selection
  /// 
  /// This automatically selects the appropriate community level based on
  /// the query type:
  /// - Broad/overview questions → root communities (level 0)
  /// - Thematic questions → intermediate level (level 1)
  /// - Specific questions → lower levels (level 2+)
  Future<GlobalQueryResult> globalQueryAuto(
    String query, {
    int maxCommunityAnswers = 10,
    int minHelpfulnessScore = 20,
    String responseType = 'multiple paragraphs',
  }) async {
    _checkInitialized();
    
    final engine = GlobalQueryEngine(
      repository: _repository,
      llmCallback: _llmCallback,
      embeddingCallback: _embeddingCallback,
      config: GlobalQueryConfig(
        maxCommunityAnswers: maxCommunityAnswers,
        minHelpfulnessScore: minHelpfulnessScore,
        responseType: responseType,
      ),
    );
    
    return await engine.queryWithAutoLevel(query);
  }

  /// Execute a streaming global query with automatic level selection
  /// 
  /// This yields progress events during execution, providing real-time
  /// feedback including:
  /// - Community processing progress
  /// - Streaming tokens for the final answer (if llmStreamCallback provided)
  Stream<GlobalQueryProgress> globalQueryAutoStreaming(
    String query, {
    int maxCommunityAnswers = 10,
    int minHelpfulnessScore = 20,
    String responseType = 'multiple paragraphs',
    Stream<String> Function(String prompt)? llmStreamCallback,
  }) {
    _checkInitialized();
    
    final engine = StreamingGlobalQueryEngine(
      repository: _repository,
      llmCallback: _llmCallback,
      llmStreamCallback: llmStreamCallback,
      embeddingCallback: _embeddingCallback,
      config: GlobalQueryConfig(
        maxCommunityAnswers: maxCommunityAnswers,
        minHelpfulnessScore: minHelpfulnessScore,
        responseType: responseType,
      ),
    );
    
    return engine.queryWithAutoLevelStreaming(query);
  }

  /// Get context string for RAG augmentation
  Future<String> getContext(String query) async {
    _checkInitialized();
    
    final result = await _queryEngine.query(query);
    return result.contextString;
  }

  // === Graph Operations ===

  /// Add an entity to the graph
  Future<void> addEntity(GraphEntity entity) async {
    _checkInitialized();
    await _repository.addEntity(entity);
  }

  /// Get an entity by ID
  Future<GraphEntity?> getEntity(String id) async {
    _checkInitialized();
    return await _repository.getEntity(id);
  }

  /// Get entities by type
  Future<List<GraphEntity>> getEntitiesByType(String type) async {
    _checkInitialized();
    return await _repository.getEntitiesByType(type);
  }

  /// Add a relationship
  Future<void> addRelationship(GraphRelationship relationship) async {
    _checkInitialized();
    await _repository.addRelationship(relationship);
  }

  /// Get relationships for an entity
  Future<List<GraphRelationship>> getRelationships(String entityId) async {
    _checkInitialized();
    return await _repository.getRelationships(entityId);
  }

  /// Get entity neighbors
  Future<List<GraphEntity>> getNeighbors(
    String entityId, {
    int depth = 1,
    String? relationshipType,
  }) async {
    _checkInitialized();
    return await _repository.getEntityNeighbors(
      entityId,
      depth: depth,
      relationshipType: relationshipType,
    );
  }

  /// Get graph statistics
  Future<GraphStatistics> getStats() async {
    _checkInitialized();
    return await _repository.getStats();
  }

  /// Clear the entire graph
  /// Also resets connector sync times so next indexing fetches all data
  Future<void> clearGraph() async {
    _checkInitialized();
    await _repository.clear();
    // Reset connector sync times so next "Start" fetches all data
    await _connectorManager.resetSyncState();
  }

  // === Entity Extraction ===

  /// Extract entities from text
  Future<ExtractionResult> extractEntities(
    String text, {
    required String sourceId,
    String sourceType = 'text',
  }) async {
    _checkInitialized();
    return await _extractor.extractFromText(
      text,
      sourceId: sourceId,
      sourceType: sourceType,
    );
  }

  /// Extract entities from structured data
  Future<ExtractionResult> extractFromData(
    Map<String, dynamic> data, {
    required String sourceId,
    required String sourceType,
  }) async {
    _checkInitialized();
    return await _extractor.extractFromStructured(
      data,
      sourceId: sourceId,
      sourceType: sourceType,
    );
  }

  // === Document Content Indexing ===
  
  /// Index a single document by extracting entities and relationships
  /// This is the recommended method for indexing user-selected documents
  Future<void> indexDocumentContent({
    required String documentId,
    required String name,
    required String content,
    String? mimeType,
  }) async {
    _checkInitialized();
    
    if (content.isEmpty) {
      return;
    }
    
    // Create source ID based on document
    final sourceId = 'document_$documentId';
    
    // Extract entities from document content
    final extraction = await _extractor.extractFromText(
      content,
      sourceId: sourceId,
      sourceType: 'DOCUMENT',
    );
    
    // Generate entity ID for document
    String normalizeId(String name, String type) {
      final normalized = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_');
      final typePrefix = type.isNotEmpty ? '${type.toLowerCase()}_' : '';
      return '$typePrefix$normalized';
    }
    
    final now = DateTime.now();
    
    // Add extracted entities to graph
    for (final entity in extraction.entities) {
      final embedding = await _embeddingCallback(
        '${entity.name} ${entity.description ?? ""}',
      );
      
      final graphEntity = GraphEntity(
        id: normalizeId(entity.name, entity.type),
        name: entity.name,
        type: entity.type,
        description: entity.description,
        embedding: embedding,
        metadata: {'sourceId': sourceId},
        lastModified: now,
      );
      
      // Try to add, if it fails (duplicate), update instead
      try {
        await _repository.addEntity(graphEntity);
      } catch (_) {
        await _repository.updateEntity(
          graphEntity.id,
          name: graphEntity.name,
          type: graphEntity.type,
          embedding: embedding,
          description: graphEntity.description,
          metadata: graphEntity.metadata,
          lastModified: now,
        );
      }
    }
    
    // Add relationships
    for (final rel in extraction.relationships) {
      final graphRelationship = GraphRelationship(
        id: '${normalizeId(rel.sourceEntity, '')}_${rel.type.toLowerCase()}_${normalizeId(rel.targetEntity, '')}',
        sourceId: normalizeId(rel.sourceEntity, ''),
        targetId: normalizeId(rel.targetEntity, ''),
        type: rel.type,
        weight: rel.weight,
        metadata: {'description': rel.description},
      );
      
      // Try to add relationship, ignore if it already exists
      try {
        await _repository.addRelationship(graphRelationship);
      } catch (_) {
        // Relationship already exists, that's fine
      }
    }
    
    // Create co-occurrence relationships between all entities from the same document
    // This ensures entities extracted from the same file are connected
    final extractedEntityIds = extraction.entities
        .map((e) => normalizeId(e.name, e.type))
        .toList();
    
    for (var i = 0; i < extractedEntityIds.length; i++) {
      for (var j = i + 1; j < extractedEntityIds.length; j++) {
        final coOccurRel = GraphRelationship(
          id: '${extractedEntityIds[i]}_co_occurs_${extractedEntityIds[j]}',
          sourceId: extractedEntityIds[i],
          targetId: extractedEntityIds[j],
          type: 'CO_OCCURS_IN',
          weight: 0.5, // Lower weight than explicit relationships
          metadata: {'sourceDocument': name, 'sourceId': sourceId},
        );
        try {
          await _repository.addRelationship(coOccurRel);
        } catch (_) {
          // Relationship already exists
        }
      }
    }
    
    // Create document entity and link to "You"
    final documentEmbedding = await _embeddingCallback(
      '$name ${content.length > 200 ? content.substring(0, 200) : content}',
    );
    
    final documentEntity = GraphEntity(
      id: normalizeId(name, 'DOCUMENT'),
      name: name,
      type: 'DOCUMENT',
      description: content.length > 500 ? '${content.substring(0, 500)}...' : content,
      embedding: documentEmbedding,
      metadata: {
        'sourceId': sourceId,
        'mimeType': mimeType ?? 'text/plain',
        'documentId': documentId,
      },
      lastModified: now,
    );
    
    try {
      await _repository.addEntity(documentEntity);
    } catch (_) {
      await _repository.updateEntity(
        documentEntity.id,
        name: documentEntity.name,
        type: documentEntity.type,
        embedding: documentEmbedding,
        description: documentEntity.description,
        metadata: documentEntity.metadata,
        lastModified: now,
      );
    }
    
    // Link document to "You" (the user's SELF entity)
    // Use YouEntity.id for consistency with the rest of the codebase
    const youId = YouEntity.id; // 'you_central_node'
    final youEntity = await _repository.getEntity(youId);
    if (youEntity == null) {
      // Create "You" entity using the YouEntity helper for consistency
      final youEmbedding = await _embeddingCallback('You - personal user self');
      final you = YouEntity.create(embedding: youEmbedding);
      await _repository.addEntity(you);
    }
    
    // Create relationship: You -> HAS_DOCUMENT -> Document
    final documentRel = GraphRelationship(
      id: '${youId}_has_document_${documentEntity.id}',
      sourceId: youId,
      targetId: documentEntity.id,
      type: YouRelationshipTypes.ownsDocument,
      weight: 1.0,
      metadata: {},
    );
    try {
      await _repository.addRelationship(documentRel);
    } catch (_) {
      // Relationship already exists
    }
  }

  // === Note Content Indexing ===

  /// Split text into chunks of approximately [maxChunkSize] characters.
  /// Splits on paragraph boundaries first, then sentence boundaries,
  /// then hard-splits as a last resort.
  static List<String> _splitIntoChunks(String text, {int maxChunkSize = 2500}) {
    if (text.length <= maxChunkSize) {
      return [text];
    }

    final chunks = <String>[];

    // Split on paragraph boundaries
    final paragraphs = text.split('\n\n');
    var currentChunk = StringBuffer();

    for (final paragraph in paragraphs) {
      // If adding this paragraph would exceed the limit
      if (currentChunk.length + paragraph.length + 2 > maxChunkSize) {
        // Save current chunk if it has content
        if (currentChunk.isNotEmpty) {
          chunks.add(currentChunk.toString().trim());
          currentChunk = StringBuffer();
        }

        // If the paragraph itself is too long, split by sentences
        if (paragraph.length > maxChunkSize) {
          final sentenceChunks = _splitBySentences(paragraph, maxChunkSize);
          for (var i = 0; i < sentenceChunks.length - 1; i++) {
            chunks.add(sentenceChunks[i].trim());
          }
          currentChunk.write(sentenceChunks.last);
        } else {
          currentChunk.write(paragraph);
        }
      } else {
        if (currentChunk.isNotEmpty) {
          currentChunk.write('\n\n');
        }
        currentChunk.write(paragraph);
      }
    }

    if (currentChunk.isNotEmpty) {
      chunks.add(currentChunk.toString().trim());
    }

    return chunks.where((c) => c.isNotEmpty).toList();
  }

  /// Split a single large paragraph by sentence boundaries.
  /// Falls back to hard-splitting if individual sentences exceed limit.
  static List<String> _splitBySentences(String text, int maxChunkSize) {
    final chunks = <String>[];
    final sentences = RegExp(r'(?<=[.!?])\s+').allMatches(text);

    var lastEnd = 0;
    var currentChunk = StringBuffer();

    for (final match in sentences) {
      final sentence = text.substring(lastEnd, match.end);
      if (currentChunk.length + sentence.length > maxChunkSize) {
        if (currentChunk.isNotEmpty) {
          chunks.add(currentChunk.toString().trim());
          currentChunk = StringBuffer();
        }
        if (sentence.length > maxChunkSize) {
          for (var i = 0; i < sentence.length; i += maxChunkSize) {
            final end = (i + maxChunkSize).clamp(0, sentence.length);
            chunks.add(sentence.substring(i, end).trim());
          }
        } else {
          currentChunk.write(sentence);
        }
      } else {
        currentChunk.write(sentence);
      }
      lastEnd = match.end;
    }

    if (lastEnd < text.length) {
      final remainder = text.substring(lastEnd);
      if (currentChunk.length + remainder.length > maxChunkSize) {
        if (currentChunk.isNotEmpty) {
          chunks.add(currentChunk.toString().trim());
        }
        chunks.add(remainder.trim());
      } else {
        currentChunk.write(remainder);
      }
    }

    if (currentChunk.isNotEmpty) {
      chunks.add(currentChunk.toString().trim());
    }

    return chunks.where((c) => c.isNotEmpty).toList();
  }

  /// Index a note by extracting entities and relationships, with chunking
  /// for long notes.
  ///
  /// Short notes (<= 2500 chars) are processed as a single entity.
  /// Longer notes are split into chunks, each processed for entity extraction,
  /// with NEXT_CHUNK sequential links and PART_OF links to the parent NOTE.
  Future<void> indexNoteContent({
    required String noteId,
    required String title,
    required String content,
  }) async {
    _checkInitialized();

    if (content.isEmpty) {
      return;
    }

    String normalizeId(String name, String type) {
      final normalized =
          name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_');
      final typePrefix = type.isNotEmpty ? '${type.toLowerCase()}_' : '';
      return '$typePrefix$normalized';
    }

    final now = DateTime.now();
    final sourceId = 'note_$noteId';

    // Split content into chunks
    final chunks = _splitIntoChunks(content);
    debugPrint(
        '[GraphRAG] Note "$title": ${content.length} chars -> ${chunks.length} chunk(s)');

    // Collect all extracted entity IDs across all chunks (for co-occurrence)
    final allExtractedEntityIds = <String>[];

    // Process each chunk for entity extraction
    for (var chunkIndex = 0; chunkIndex < chunks.length; chunkIndex++) {
      final chunkContent = chunks[chunkIndex];
      final chunkSourceId = '${sourceId}_chunk_$chunkIndex';

      final extraction = await _extractor.extractFromText(
        chunkContent,
        sourceId: chunkSourceId,
        sourceType: 'NOTE',
      );

      // Add extracted entities
      for (final entity in extraction.entities) {
        final embedding = await _embeddingCallback(
          '${entity.name} ${entity.description ?? ""}',
        );

        final graphEntity = GraphEntity(
          id: normalizeId(entity.name, entity.type),
          name: entity.name,
          type: entity.type,
          description: entity.description,
          embedding: embedding,
          metadata: {'sourceId': chunkSourceId},
          lastModified: now,
        );

        try {
          await _repository.addEntity(graphEntity);
        } catch (_) {
          await _repository.updateEntity(
            graphEntity.id,
            name: graphEntity.name,
            type: graphEntity.type,
            embedding: embedding,
            description: graphEntity.description,
            metadata: graphEntity.metadata,
            lastModified: now,
          );
        }

        allExtractedEntityIds.add(graphEntity.id);
      }

      // Add extracted relationships
      for (final rel in extraction.relationships) {
        final graphRelationship = GraphRelationship(
          id: '${normalizeId(rel.sourceEntity, '')}_${rel.type.toLowerCase()}_${normalizeId(rel.targetEntity, '')}',
          sourceId: normalizeId(rel.sourceEntity, ''),
          targetId: normalizeId(rel.targetEntity, ''),
          type: rel.type,
          weight: rel.weight,
          metadata: {'description': rel.description},
        );

        try {
          await _repository.addRelationship(graphRelationship);
        } catch (_) {}
      }
    }

    // Create co-occurrence relationships between all entities across chunks
    final uniqueEntityIds = allExtractedEntityIds.toSet().toList();
    for (var i = 0; i < uniqueEntityIds.length; i++) {
      for (var j = i + 1; j < uniqueEntityIds.length; j++) {
        final coOccurRel = GraphRelationship(
          id: '${uniqueEntityIds[i]}_co_occurs_${uniqueEntityIds[j]}',
          sourceId: uniqueEntityIds[i],
          targetId: uniqueEntityIds[j],
          type: 'CO_OCCURS_IN',
          weight: 0.5,
          metadata: {'sourceNote': title, 'sourceId': sourceId},
        );
        try {
          await _repository.addRelationship(coOccurRel);
        } catch (_) {}
      }
    }

    // --- Create parent NOTE entity ---
    final noteEntityId = normalizeId(title, 'NOTE');
    final noteEmbedding = await _embeddingCallback(
      '$title ${content.length > 200 ? content.substring(0, 200) : content}',
    );

    final noteEntity = GraphEntity(
      id: noteEntityId,
      name: title,
      type: 'NOTE',
      description: content.length > 500
          ? '${content.substring(0, 500)}...'
          : content,
      embedding: noteEmbedding,
      metadata: {
        'sourceId': sourceId,
        'noteId': noteId,
        'chunkCount': chunks.length,
        'totalLength': content.length,
      },
      lastModified: now,
    );

    try {
      await _repository.addEntity(noteEntity);
    } catch (_) {
      await _repository.updateEntity(
        noteEntity.id,
        name: noteEntity.name,
        type: noteEntity.type,
        embedding: noteEmbedding,
        description: noteEntity.description,
        metadata: noteEntity.metadata,
        lastModified: now,
      );
    }

    // --- Create chunk entities and link them (only if multiple chunks) ---
    if (chunks.length > 1) {
      String? previousChunkId;

      for (var chunkIndex = 0; chunkIndex < chunks.length; chunkIndex++) {
        final chunkContent = chunks[chunkIndex];
        final chunkId = '${noteEntityId}_chunk_$chunkIndex';

        final chunkEmbedding = await _embeddingCallback(
          chunkContent.length > 200
              ? chunkContent.substring(0, 200)
              : chunkContent,
        );

        final chunkEntity = GraphEntity(
          id: chunkId,
          name: '$title (part ${chunkIndex + 1}/${chunks.length})',
          type: 'NOTE_CHUNK',
          description: chunkContent.length > 500
              ? '${chunkContent.substring(0, 500)}...'
              : chunkContent,
          embedding: chunkEmbedding,
          metadata: {
            'sourceId': sourceId,
            'chunkIndex': chunkIndex,
            'totalChunks': chunks.length,
            'parentNoteId': noteEntityId,
          },
          lastModified: now,
        );

        try {
          await _repository.addEntity(chunkEntity);
        } catch (_) {
          await _repository.updateEntity(
            chunkEntity.id,
            name: chunkEntity.name,
            type: chunkEntity.type,
            embedding: chunkEmbedding,
            description: chunkEntity.description,
            metadata: chunkEntity.metadata,
            lastModified: now,
          );
        }

        // PART_OF: chunk -> parent note
        final partOfRel = GraphRelationship(
          id: '${chunkId}_part_of_$noteEntityId',
          sourceId: chunkId,
          targetId: noteEntityId,
          type: 'PART_OF',
          weight: 1.0,
          metadata: {'chunkIndex': chunkIndex},
        );
        try {
          await _repository.addRelationship(partOfRel);
        } catch (_) {}

        // NEXT_CHUNK: previousChunk -> currentChunk
        if (previousChunkId != null) {
          final nextChunkRel = GraphRelationship(
            id: '${previousChunkId}_next_chunk_$chunkId',
            sourceId: previousChunkId,
            targetId: chunkId,
            type: 'NEXT_CHUNK',
            weight: 1.0,
            metadata: {},
          );
          try {
            await _repository.addRelationship(nextChunkRel);
          } catch (_) {}
        }

        previousChunkId = chunkId;
      }
    }

    // --- Link to You node via hub pattern ---
    const youId = YouEntity.id;
    final youEntity = await _repository.getEntity(youId);
    if (youEntity == null) {
      final youEmbedding =
          await _embeddingCallback('You - personal user self');
      final you = YouEntity.create(embedding: youEmbedding);
      await _repository.addEntity(you);
    }

    // Ensure hub entity exists: You -> HAS_DATA -> My Notes
    final hubId = DataHubEntity.idFor(DataSourceTypes.note);
    final existingHub = await _repository.getEntity(hubId);
    if (existingHub == null) {
      final hubEmbedding = await _embeddingCallback(
        DataHubEntity.nameFor(DataSourceTypes.note),
      );
      await _repository.addEntity(
        DataHubEntity.create(DataSourceTypes.note, embedding: hubEmbedding),
      );

      final hubRel = GraphRelationship(
        id: '${youId}_${YouRelationshipTypes.hasData}_$hubId',
        sourceId: youId,
        targetId: hubId,
        type: YouRelationshipTypes.hasData,
        weight: 1.0,
        metadata: {},
      );
      try {
        await _repository.addRelationship(hubRel);
      } catch (_) {}
    }

    // Link note to hub: My Notes Hub -> WROTE_NOTE -> Note
    final noteHubRel = GraphRelationship(
      id: '${hubId}_${YouRelationshipTypes.wroteNote}_$noteEntityId',
      sourceId: hubId,
      targetId: noteEntityId,
      type: YouRelationshipTypes.wroteNote,
      weight: 1.0,
      metadata: {},
    );
    try {
      await _repository.addRelationship(noteHubRel);
    } catch (_) {}

    debugPrint('[GraphRAG] Indexed note "$title": ${chunks.length} chunk(s), '
        '${uniqueEntityIds.length} extracted entities');
  }

  // === Community Detection ===

  /// Run community detection on current graph
  Future<CommunityDetectionResult> detectCommunities() async {
    _checkInitialized();
    
    // Get all entities and relationships
    final entities = <GraphEntity>[];
    final relationships = <GraphRelationship>[];
    
    for (final type in EntityTypes.all) {
      entities.addAll(await _repository.getEntitiesByType(type));
    }
    
    for (final entity in entities) {
      relationships.addAll(await _repository.getRelationships(entity.id));
    }
    
    final detector = LeidenCommunityDetector(
      config: _config.communityConfig,
    );
    
    return await detector.detectCommunities(entities, relationships);
  }

  /// Get communities at a specific level
  Future<List<GraphCommunity>> getCommunitiesByLevel(int level) async {
    _checkInitialized();
    return await _repository.getCommunitiesByLevel(level);
  }

  void _checkInitialized() {
    if (!_initialized) {
      throw StateError(
        'GraphRAG not initialized. Call initialize() first.',
      );
    }
  }
}

/// Factory for creating GraphRAG instances
class GraphRAGFactory {
  /// Create a GraphRAG instance with default configuration
  static GraphRAG create({
    required String databasePath,
    required PlatformService platform,
    required Future<String> Function(String prompt) llmCallback,
    required Future<List<double>> Function(String text) embeddingCallback,
    Future<String> Function(String prompt, Uint8List imageBytes)? visionLlmCallback,
    Future<String> Function(String prompt, {List<Tool>? tools})? extractionLlmCallback,
    Future<void> Function()? onExtractionPhaseComplete,
    Future<void> Function()? onBeforeSummarization,
    bool autoIndex = false,
  }) {
    return GraphRAG(
      config: GraphRAGConfig(
        databasePath: databasePath,
        autoIndex: autoIndex,
      ),
      platform: platform,
      llmCallback: llmCallback,
      embeddingCallback: embeddingCallback,
      visionLlmCallback: visionLlmCallback,
      extractionLlmCallback: extractionLlmCallback,
      onExtractionPhaseComplete: onExtractionPhaseComplete,
      onBeforeSummarization: onBeforeSummarization,
    );
  }

  /// Create a GraphRAG instance with custom configuration
  static GraphRAG createWithConfig({
    required GraphRAGConfig config,
    required PlatformService platform,
    required Future<String> Function(String prompt) llmCallback,
    required Future<List<double>> Function(String text) embeddingCallback,
    Future<String> Function(String prompt, Uint8List imageBytes)? visionLlmCallback,
    Future<String> Function(String prompt, {List<Tool>? tools})? extractionLlmCallback,
    Future<void> Function()? onExtractionPhaseComplete,
    Future<void> Function()? onBeforeSummarization,
  }) {
    return GraphRAG(
      config: config,
      platform: platform,
      llmCallback: llmCallback,
      embeddingCallback: embeddingCallback,
      visionLlmCallback: visionLlmCallback,
      extractionLlmCallback: extractionLlmCallback,
      onExtractionPhaseComplete: onExtractionPhaseComplete,
      onBeforeSummarization: onBeforeSummarization,
    );
  }
}

/// Extension for convenient query building
extension GraphRAGQueryExtension on GraphRAG {
  /// Find people who work at an organization
  Future<List<GraphEntity>> findPeopleAt(String organization) async {
    final result = await query(
      'people at $organization',
      cypherQuery: '''
MATCH (p:PERSON)-[:WORKS_AT]->(o:ORGANIZATION)
WHERE o.name CONTAINS "$organization"
RETURN p
LIMIT 20
''',
    );
    return result.entities.map((e) => e.entity).toList();
  }

  /// Find events involving a person
  Future<List<GraphEntity>> findEventsFor(String personName) async {
    final result = await query(
      'events with $personName',
      cypherQuery: '''
MATCH (e:EVENT)-[:ATTENDED_BY]->(p:PERSON)
WHERE p.name CONTAINS "$personName"
RETURN e
LIMIT 20
''',
    );
    return result.entities
        .where((e) => e.entity.type == 'EVENT')
        .map((e) => e.entity)
        .toList();
  }

  /// Find people who know a specific person
  Future<List<GraphEntity>> findConnectionsOf(String personName) async {
    final result = await query(
      'who knows $personName',
      cypherQuery: '''
MATCH (p:PERSON)-[:KNOWS|COLLEAGUE_OF]-(target:PERSON)
WHERE target.name CONTAINS "$personName"
RETURN p
LIMIT 20
''',
    );
    return result.entities
        .where((e) => e.entity.type == 'PERSON')
        .map((e) => e.entity)
        .toList();
  }
}

/// Extension for RAG integration
extension GraphRAGIntegration on GraphRAG {
  /// Get augmented prompt with graph context
  Future<String> augmentPrompt(String userQuery, {
    String promptTemplate = '''Based on the following context from your personal knowledge graph, answer the user's question.

Context:
{context}

User Question: {query}

Answer:''',
  }) async {
    final context = await getContext(userQuery);
    
    return promptTemplate
        .replaceAll('{context}', context)
        .replaceAll('{query}', userQuery);
  }

  /// Stream augmented response using LLM
  Stream<String> streamAugmentedResponse(
    String userQuery,
    Stream<String> Function(String prompt) llmStream,
  ) async* {
    final augmentedPrompt = await augmentPrompt(userQuery);
    yield* llmStream(augmentedPrompt);
  }
}
