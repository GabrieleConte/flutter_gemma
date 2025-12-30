import 'dart:async';

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
  
  /// Whether to auto-start indexing on initialization
  final bool autoIndex;

  GraphRAGConfig({
    required this.databasePath,
    HybridQueryConfig? queryConfig,
    EntityExtractionConfig? extractionConfig,
    CommunityDetectionConfig? communityConfig,
    IndexingConfig? indexingConfig,
    this.autoIndex = false,
  })  : queryConfig = queryConfig ?? HybridQueryConfig(),
        extractionConfig = extractionConfig ?? EntityExtractionConfig(),
        communityConfig = communityConfig ?? CommunityDetectionConfig(),
        indexingConfig = indexingConfig ?? IndexingConfig();
}

/// Main facade for GraphRAG functionality
/// 
/// This class provides a unified interface for:
/// - Managing data connectors (system APIs, Google Suite)
/// - Building and querying the knowledge graph
/// - Running background indexing
/// - Executing hybrid queries (Cypher + semantic)
class GraphRAG {
  final GraphRAGConfig _config;
  final PlatformService _platform;
  final Future<String> Function(String prompt) _llmCallback;
  final Future<List<double>> Function(String text) _embeddingCallback;
  
  late final NativeGraphRepository _repository;
  late final ConnectorManager _connectorManager;
  late final LLMEntityExtractor _extractor;
  late final HybridQueryEngine _queryEngine;
  late final BackgroundIndexingService _indexingService;
  
  bool _initialized = false;

  GraphRAG({
    required GraphRAGConfig config,
    required PlatformService platform,
    required Future<String> Function(String prompt) llmCallback,
    required Future<List<double>> Function(String text) embeddingCallback,
  })  : _config = config,
        _platform = platform,
        _llmCallback = llmCallback,
        _embeddingCallback = embeddingCallback;

  /// Whether GraphRAG is initialized
  bool get isInitialized => _initialized;

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

    // Setup entity extractor
    _extractor = LLMEntityExtractor(
      llmCallback: _llmCallback,
      embeddingCallback: _embeddingCallback,
      config: _config.extractionConfig,
    );

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
      config: _config.indexingConfig,
    );

    _initialized = true;

    // Auto-start indexing if configured
    if (_config.autoIndex) {
      await startIndexing();
    }
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
    
    final detector = LouvainCommunityDetector(
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
    );
  }

  /// Create a GraphRAG instance with custom configuration
  static GraphRAG createWithConfig({
    required GraphRAGConfig config,
    required PlatformService platform,
    required Future<String> Function(String prompt) llmCallback,
    required Future<List<double>> Function(String text) embeddingCallback,
  }) {
    return GraphRAG(
      config: config,
      platform: platform,
      llmCallback: llmCallback,
      embeddingCallback: embeddingCallback,
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
