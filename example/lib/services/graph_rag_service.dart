import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart' hide EmbeddingModel;
import 'package:flutter_gemma/flutter_gemma_interface.dart' show EmbeddingModel;
import 'package:flutter_gemma/rag/graph/global_query_engine.dart';
import 'package:path_provider/path_provider.dart';

/// Service for managing GraphRAG operations in the example app
class GraphRAGService {
  GraphRAGService._();
  
  static GraphRAGService? _instance;
  static GraphRAGService get instance => _instance ??= GraphRAGService._();
  
  GraphRAG? _graphRag;
  bool _isInitialized = false;
  String? _error;
  
  // LLM and embedding callbacks
  InferenceChat? _chat;
  EmbeddingModel? _embeddingModel;
  
  /// Whether the service is initialized
  bool get isInitialized => _isInitialized;
  
  /// Current error message if any
  String? get error => _error;
  
  /// The GraphRAG instance
  GraphRAG? get graphRag => _graphRag;
  
  /// Stream of indexing progress updates
  Stream<IndexingProgress>? get progressStream => 
      _isInitialized ? _graphRag?.indexingProgress : null;
  
  /// Current indexing progress
  IndexingProgress? get currentProgress => 
      _isInitialized ? _graphRag?.indexingStatus : null;
  
  /// Whether indexing is currently running
  bool get isIndexing => 
      currentProgress?.status == IndexingStatus.running;

  /// Initialize the GraphRAG service with LLM and embedding model
  Future<void> initialize({
    required InferenceChat chat,
    required EmbeddingModel embeddingModel,
  }) async {
    if (_isInitialized) {
      debugPrint('[GraphRAGService] Already initialized');
      return;
    }
    
    try {
      debugPrint('[GraphRAGService] Initializing...');
      _chat = chat;
      _embeddingModel = embeddingModel;
      
      // Get database path
      final directory = await getApplicationDocumentsDirectory();
      final dbPath = '${directory.path}/graph_rag.db';
      debugPrint('[GraphRAGService] Database path: $dbPath');
      
      // Create GraphRAG instance
      _graphRag = GraphRAGFactory.create(
        databasePath: dbPath,
        platform: PlatformService(),
        llmCallback: _generateLLMResponse,
        embeddingCallback: _generateEmbedding,
        autoIndex: false, // We'll control indexing manually
      );
      
      await _graphRag!.initialize();
      debugPrint('[GraphRAGService] GraphRAG initialized');
      
      _isInitialized = true;
      _error = null;
      debugPrint('[GraphRAGService] Initialization complete ✅');
    } catch (e, stack) {
      _error = e.toString();
      debugPrint('[GraphRAGService] Initialization failed: $e');
      debugPrint('[GraphRAGService] Stack: $stack');
      rethrow;
    }
  }
  
  /// Generate LLM response using the chat model
  /// For entity extraction, we clear history before each call to avoid context overflow
  Future<String> _generateLLMResponse(String prompt) async {
    if (_chat == null) {
      throw StateError('Chat model not initialized');
    }
    
    // Truncate prompt if too long (rough estimate: ~4 chars per token, leave room for output)
    // With maxTokens=1024, reserve ~300 tokens for output, so ~724 tokens * 4 = ~2900 chars
    const maxPromptChars = 2900;
    String truncatedPrompt = prompt;
    if (prompt.length > maxPromptChars) {
      truncatedPrompt = '${prompt.substring(0, maxPromptChars)}...[truncated]';
      debugPrint('[GraphRAGService] Truncated prompt from ${prompt.length} to $maxPromptChars chars');
    }
    
    debugPrint('[GraphRAGService] Generating LLM response for prompt (${truncatedPrompt.length} chars)');
    
    // Clear history before each extraction to avoid context window overflow
    // Entity extraction should be stateless - each prompt is independent
    await _chat!.clearHistory();
    
    // Add prompt and generate response
    await _chat!.addQuery(Message(text: truncatedPrompt));
    final response = await _chat!.generateChatResponse();
    
    // Extract text from ModelResponse
    String responseText = '';
    if (response is TextResponse) {
      responseText = response.token;
    }
    
    debugPrint('[GraphRAGService] LLM response: ${responseText.substring(0, responseText.length.clamp(0, 100))}...');
    return responseText;
  }
  
  /// Generate embedding using the embedding model
  Future<List<double>> _generateEmbedding(String text) async {
    if (_embeddingModel == null) {
      throw StateError('Embedding model not initialized');
    }
    
    debugPrint('[GraphRAGService] Generating embedding for: "${text.substring(0, text.length.clamp(0, 50))}..."');
    final embedding = await _embeddingModel!.generateEmbedding(text);
    debugPrint('[GraphRAGService] Embedding generated: ${embedding.length} dimensions');
    return embedding;
  }
  
  /// Check permissions for system data (returns flattened map for UI convenience)
  Future<Map<DataPermissionType, DataPermissionStatus>> checkPermissions() async {
    _checkInitialized();
    final allPermissions = await _graphRag!.checkPermissions();
    
    // Flatten the nested map for simpler UI handling
    final result = <DataPermissionType, DataPermissionStatus>{};
    for (final entry in allPermissions.values) {
      result.addAll(entry);
    }
    return result;
  }
  
  /// Request permissions for contacts and calendar (sequentially to avoid conflicts)
  Future<Map<DataPermissionType, DataPermissionStatus>> requestPermissions() async {
    _checkInitialized();
    // Request permissions sequentially to avoid "Can request only one set at a time" error
    final contactsResult = await _graphRag!.requestPermissions('contacts');
    // Small delay to allow system to process
    await Future.delayed(const Duration(milliseconds: 500));
    final calendarResult = await _graphRag!.requestPermissions('calendar');
    
    // Merge results
    return {...contactsResult, ...calendarResult};
  }
  
  /// Start indexing system data
  /// Set [useForegroundService] to true to keep indexing alive when app is backgrounded
  Future<void> startIndexing({
    bool fullReindex = false,
    bool useForegroundService = true,
  }) async {
    _checkInitialized();
    debugPrint('[GraphRAGService] Starting indexing (fullReindex: $fullReindex, foreground: $useForegroundService)');
    await _graphRag!.startIndexing(
      fullReindex: fullReindex,
      useForegroundService: useForegroundService,
    );
  }
  
  /// Pause indexing
  void pauseIndexing() {
    _checkInitialized();
    _graphRag!.pauseIndexing();
  }
  
  /// Resume indexing
  void resumeIndexing() {
    _checkInitialized();
    _graphRag!.resumeIndexing();
  }
  
  /// Cancel indexing
  Future<void> cancelIndexing() async {
    _checkInitialized();
    await _graphRag!.cancelIndexing();
  }
  
  /// Query the knowledge graph
  Future<HybridQueryResult> query(
    String naturalLanguageQuery, {
    String? cypherQuery,
    List<String>? entityTypes,
  }) async {
    _checkInitialized();
    debugPrint('[GraphRAGService] Query: "$naturalLanguageQuery"');
    
    final result = await _graphRag!.query(
      naturalLanguageQuery,
      cypherQuery: cypherQuery,
      entityTypes: entityTypes,
    );
    
    debugPrint('[GraphRAGService] Query returned ${result.entities.length} entities, ${result.communities.length} communities');
    return result;
  }
  
  /// Execute a global query using the GraphRAG paper's map-reduce approach
  /// 
  /// This is recommended for broad "sensemaking" queries like:
  /// - "What are the main themes in my contacts?"
  /// - "Who are the most important people?"
  /// - "How are my events connected?"
  Future<GlobalQueryResult> globalQuery(
    String query, {
    int communityLevel = 1,
    int maxCommunityAnswers = 10,
    int minHelpfulnessScore = 20,
  }) async {
    _checkInitialized();
    debugPrint('[GraphRAGService] Global query: "$query" (level: $communityLevel)');
    
    final result = await _graphRag!.globalQuery(
      query,
      communityLevel: communityLevel,
      maxCommunityAnswers: maxCommunityAnswers,
      minHelpfulnessScore: minHelpfulnessScore,
    );
    
    debugPrint('[GraphRAGService] Global query completed: ${result.communityAnswers.length} community answers used');
    return result;
  }
  
  /// Execute a global query with automatic community level selection
  Future<GlobalQueryResult> globalQueryAuto(String query) async {
    _checkInitialized();
    debugPrint('[GraphRAGService] Auto global query: "$query"');
    
    final result = await _graphRag!.globalQueryAuto(query);
    
    debugPrint('[GraphRAGService] Auto global query completed at level ${result.metadata.communityLevel}');
    return result;
  }
  
  /// Execute a streaming global query with progress updates
  /// 
  /// This provides real-time feedback during the query:
  /// - Shows which community is being processed
  /// - Streams the final answer token by token
  Stream<GlobalQueryProgress> globalQueryAutoStreaming(String query) {
    _checkInitialized();
    debugPrint('[GraphRAGService] Streaming global query: "$query"');
    
    // Create streaming LLM callback if chat supports it
    Stream<String> llmStreamCallback(String prompt) async* {
      await _chat!.clearHistory();
      await _chat!.addQuery(Message(text: prompt));
      
      await for (final response in _chat!.generateChatResponseAsync()) {
        if (response is TextResponse) {
          yield response.token;
        }
      }
    }
    
    return _graphRag!.globalQueryAutoStreaming(
      query,
      llmStreamCallback: llmStreamCallback,
    );
  }
  
  /// Get context string for RAG augmentation
  Future<String> getContext(String query) async {
    _checkInitialized();
    return await _graphRag!.getContext(query);
  }
  
  /// Get graph statistics
  Future<GraphStatistics> getStats() async {
    _checkInitialized();
    return await _graphRag!.getStats();
  }
  
  /// Search entities by similarity
  Future<List<ScoredEntity>> searchEntities(
    String query, {
    int topK = 10,
    String? entityType,
  }) async {
    _checkInitialized();
    return await _graphRag!.searchEntities(
      query,
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
    return await _graphRag!.searchCommunities(
      query,
      topK: topK,
      level: level,
    );
  }
  
  /// Clear all graph data
  Future<void> clearGraph() async {
    _checkInitialized();
    await _graphRag!.clearGraph();
    debugPrint('[GraphRAGService] Graph cleared');
  }
  
  /// Get all entities for visualization
  /// Fetches entities of all known types
  Future<List<GraphEntity>> getAllEntities() async {
    _checkInitialized();
    final entityTypes = ['PERSON', 'ORGANIZATION', 'EVENT', 'LOCATION'];
    final entities = <GraphEntity>[];
    
    for (final type in entityTypes) {
      final typeEntities = await _graphRag!.getEntitiesByType(type);
      entities.addAll(typeEntities);
    }
    
    debugPrint('[GraphRAGService] Retrieved ${entities.length} total entities');
    return entities;
  }
  
  /// Get all relationships for a list of entities
  /// Used for graph visualization
  Future<List<GraphRelationship>> getAllRelationships(List<GraphEntity> entities) async {
    _checkInitialized();
    final relationships = <GraphRelationship>[];
    final seenIds = <String>{};
    
    for (final entity in entities) {
      final entityRelationships = await _graphRag!.getRelationships(entity.id);
      for (final rel in entityRelationships) {
        if (!seenIds.contains(rel.id)) {
          seenIds.add(rel.id);
          relationships.add(rel);
        }
      }
    }
    
    debugPrint('[GraphRAGService] Retrieved ${relationships.length} relationships');
    return relationships;
  }
  
  /// Dispose resources
  Future<void> dispose() async {
    if (_graphRag != null) {
      await _graphRag!.close();
      _graphRag = null;
    }
    _chat = null;
    _embeddingModel = null;
    _isInitialized = false;
    _error = null;
    debugPrint('[GraphRAGService] Disposed');
  }
  
  void _checkInitialized() {
    if (!_isInitialized || _graphRag == null) {
      throw StateError('GraphRAGService not initialized. Call initialize() first.');
    }
  }
}
