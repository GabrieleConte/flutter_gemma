import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart' hide EmbeddingModel;
import 'package:flutter_gemma/flutter_gemma_interface.dart' show EmbeddingModel;
import 'package:flutter_gemma/rag/graph/global_query_engine.dart';
import 'package:path_provider/path_provider.dart';

/// Simple async mutex to serialize access to the single native LLM session.
///
/// The Android/iOS plugin maintains exactly ONE native session; multiple
/// [InferenceChat] instances (or even the same one called concurrently) will
/// clobber each other's session state because [clearHistory] closes and
/// re-creates the native session.  This lock ensures only one LLM operation
/// (extraction, summarization, user query, …) runs at a time.
class _AsyncMutex {
  Completer<void>? _completer;

  Future<void> acquire() async {
    while (_completer != null) {
      await _completer!.future;
    }
    _completer = Completer<void>();
  }

  void release() {
    final c = _completer;
    _completer = null;
    c?.complete();
  }
}

/// Service for managing GraphRAG operations in the example app
class GraphRAGService {
  GraphRAGService._();
  
  static GraphRAGService? _instance;
  static GraphRAGService get instance => _instance ??= GraphRAGService._();
  
  GraphRAG? _graphRag;
  bool _isInitialized = false;
  String? _error;

  /// Maximum tokens the model supports (input + output).
  int _maxTokens = 4096;
  
  // LLM and embedding callbacks
  InferenceChat? _chat;
  InferenceChat? _extractionChat;
  InferenceChat? _visionChat;
  EmbeddingModel? _embeddingModel;
  
  /// Factory callback to recreate the main chat when the underlying model/session
  /// becomes stale ("Model is closed").  Provided by the navigator which knows
  /// the model parameters.
  Future<InferenceChat> Function()? _chatFactory;
  
  /// Factory callback to recreate the extraction chat on demand.
  /// Used when the extraction chat was released after the indexing pipeline
  /// completed but the user then adds a note, document, or alarm.
  Future<InferenceChat> Function()? _extractionChatFactory;
  
  /// Mutex that serializes every LLM call through the single native session.
  final _AsyncMutex _llmLock = _AsyncMutex();

  /// Notifier that is `true` whenever the LLM is busy with an ad-hoc
  /// operation (note/alarm indexing, note update/delete). The chat screen
  /// listens to this to disable input.
  final ValueNotifier<bool> llmBusy = ValueNotifier<bool>(false);
  
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

  /// Initialize the GraphRAG service with LLM and embedding model.
  ///
  /// [chat] - The main chat model for text generation (no tools).
  /// [embeddingModel] - The embedding model for semantic search.
  /// [extractionChat] - Optional chat model for entity extraction with tool support.
  ///                    If provided and supportsFunctionCalls is true, enables
  ///                    structured function calling for entity extraction.
  /// [visionChat] - Optional vision-capable chat for image captioning.
  /// [chatFactory] - Factory callback to recreate the main chat if the underlying
  ///                 model/session becomes stale ("Model is closed").  If null,
  ///                 stale-model errors will propagate as-is.
  /// [extractionChatFactory] - Factory callback to recreate the extraction chat
  ///                          on demand after it was released post-indexing.
  Future<void> initialize({
    required InferenceChat chat,
    required EmbeddingModel embeddingModel,
    InferenceChat? extractionChat,
    InferenceChat? visionChat,
    bool enableImageCaptioning = false,
    Future<InferenceChat> Function()? chatFactory,
    Future<InferenceChat> Function()? extractionChatFactory,
    int maxTokens = 4096,
  }) async {
    if (_isInitialized) {
      debugPrint('[GraphRAGService] Already initialized — disposing before reinitialize');
      await dispose();
    }
    
    try {
      debugPrint('[GraphRAGService] Initializing...');
      _chat = chat;
      _extractionChat = extractionChat;
      _visionChat = visionChat;
      _embeddingModel = embeddingModel;
      _chatFactory = chatFactory;
      _extractionChatFactory = extractionChatFactory;
      _maxTokens = maxTokens;
      
      // Get database path
      final directory = await getApplicationDocumentsDirectory();
      final dbPath = '${directory.path}/graph_rag.db';
      debugPrint('[GraphRAGService] Database path: $dbPath');
      
      // Determine vision callback based on whether vision chat is provided
      Future<String> Function(String, Uint8List)? visionCallback;
      if (visionChat != null && enableImageCaptioning) {
        visionCallback = _generateVisionResponse;
        debugPrint('[GraphRAGService] Vision LLM enabled for image captioning');
      }
      
      // Determine extraction callback for structured function calling
      Future<String> Function(String, {List<Tool>? tools})? extractionCallback;
      if (extractionChat != null && extractionChat.supportsFunctionCalls) {
        extractionCallback = _generateExtractionResponse;
        debugPrint('[GraphRAGService] Extraction LLM enabled with function calling support');
      } else if (chat.supportsFunctionCalls) {
        // Use main chat for extraction if it supports function calls
        _extractionChat = chat;
        extractionCallback = _generateExtractionResponse;
        debugPrint('[GraphRAGService] Using main chat for extraction (supports function calls)');
      }
      
      // Create GraphRAG config – clamp context tokens to the model's limit
      // so the query engine never builds a prompt larger than maxTokens.
      // Both queryConfig and extendedConfig carry maxContextTokens because
      // the query engine reads from queryConfig while other subsystems
      // read from extendedConfig.
      final config = GraphRAGConfig(
        databasePath: dbPath,
        queryConfig: GraphRAGQueryConfig(
          maxContextTokens: maxTokens,
          similarityThreshold: 0
        ),
        indexingConfig: IndexingConfig(
          enableImageCaptioning: enableImageCaptioning && visionChat != null,
          calendarNameFilter: {'RUVA'},
        ),
        extendedConfig: GraphRAGExtendedConfig(
          enableFunctionCalling: extractionCallback != null,
          enablePerformanceLogging: true,
          maxContextTokens: maxTokens,
        ),
        autoIndex: false,
      );
      
      // Create GraphRAG instance with lifecycle callbacks
      _graphRag = GraphRAGFactory.createWithConfig(
        config: config,
        platform: PlatformService(),
        llmCallback: _generateLLMResponse,
        embeddingCallback: _generateEmbedding,
        visionLlmCallback: visionCallback,
        extractionLlmCallback: extractionCallback,
        onExtractionPhaseComplete: _handleExtractionPhaseComplete,
        onBeforeSummarization: _handleBeforeSummarization,
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
  
  /// Called when extraction phase is complete - deallocate extraction model to free memory
  Future<void> _handleExtractionPhaseComplete() async {
    debugPrint('[GraphRAGService] Extraction phase complete');
    // Extraction chat can be released; the main chat handles summarization & queries.
    _extractionChat = null;
    debugPrint('[GraphRAGService] Extraction chat released ✅');
  }
  
  /// Called before summarization - ensure main LLM is ready
  Future<void> _handleBeforeSummarization() async {
    debugPrint('[GraphRAGService] Preparing for summarization...');
    
    // Check if main chat is still working
    if (_chat == null && _chatFactory != null) {
      debugPrint('[GraphRAGService] Main chat not available, recreating...');
      try {
        _chat = await _chatFactory!();
        debugPrint('[GraphRAGService] Main chat recreated ✅');
      } catch (e) {
        debugPrint('[GraphRAGService] Error recreating main chat: $e');
        rethrow;
      }
    }
  }
  
  /// Attempt to clear the chat history, recreating the model+chat if the
  /// underlying native model/session has gone stale ("Model is closed").
  ///
  /// Throws if recovery is impossible (no chatFactory, or factory itself fails).
  Future<void> _clearHistoryOrRecreate() async {
    try {
      await _chat!.clearHistory();
    } on StateError catch (e) {
      if (e.message.contains('Model is closed') && _chatFactory != null) {
        debugPrint('[GraphRAGService] ⚠️  Chat model is stale — recreating via chatFactory...');
        _chat = await _chatFactory!();
        // The factory creates a fresh model+session, so history is already clear.
        debugPrint('[GraphRAGService] ✅ Chat recreated successfully');
      } else {
        rethrow;
      }
    }
  }
  
  /// Generate vision LLM response using the vision chat model
  Future<String> _generateVisionResponse(String prompt, Uint8List imageBytes) async {
    if (_visionChat == null) {
      throw StateError('Vision chat model not initialized');
    }
    
    debugPrint('[GraphRAGService] Generating vision response for prompt (${prompt.length} chars)');
    
    // Clear history before each call
    await _visionChat!.clearHistory();
    
    // Add query with image
    await _visionChat!.addQuery(Message.withImage(
      text: prompt,
      imageBytes: imageBytes,
      isUser: true,
    ));
    
    final response = await _visionChat!.generateChatResponse();
    
    String responseText = '';
    if (response is TextResponse) {
      responseText = response.token;
    }
    
    debugPrint('[GraphRAGService] Vision response: ${responseText.substring(0, responseText.length.clamp(0, 100))}...');
    return responseText;
  }
  
  /// Generate extraction LLM response with tool support for structured entity extraction.
  /// Uses the dedicated [_extractionChat] instance, serialized by [_llmLock].
  Future<String> _generateExtractionResponse(String prompt, {List<Tool>? tools}) async {
    if (_extractionChat == null) {
      if (_extractionChatFactory != null) {
        debugPrint('[GraphRAGService] Extraction chat not available, recreating via factory...');
        _extractionChat = await _extractionChatFactory!();
        debugPrint('[GraphRAGService] Extraction chat recreated via factory ✅');
      } else {
        throw StateError('Extraction chat model not initialized and no factory available');
      }
    }
    
    debugPrint('[GraphRAGService] Generating extraction response with tools: ${tools?.map((t) => t.name).join(", ") ?? "none"}');
    
    await _llmLock.acquire();
    try {
      // Clear history before each extraction to avoid context window overflow
      await _extractionChat!.clearHistory();
      
      // Add prompt and generate response
      // The tools are already configured on the InferenceChat instance
      await _extractionChat!.addQuery(Message(text: prompt, isUser: true));
      final response = await _extractionChat!.generateChatResponse();
      
      // Extract text from ModelResponse
      String responseText = '';
      if (response is TextResponse) {
        responseText = response.token;
      } else if (response is FunctionCallResponse) {
        // If we get a function call response, convert it to JSON string for parsing
        responseText = '{"name": "${response.name}", "parameters": ${jsonEncode(response.args)}}';
        debugPrint('[GraphRAGService] Got function call: ${response.name}');
      }
      
      debugPrint('[GraphRAGService] Extraction response: ${responseText.substring(0, responseText.length.clamp(0, 150))}...');
      return responseText;
    } finally {
      _llmLock.release();
    }
  }
  
  /// Generate LLM response using the single chat model, serialized by [_llmLock].
  /// Each call is stateless: history is cleared before the prompt is sent.
  Future<String> _generateLLMResponse(String prompt) async {
    if (_chat == null) {
      throw StateError('Chat model not initialized');
    }
    
    // Truncate prompt if too long
    // Reserve ~500 tokens for output, use the rest for input.
    // ~4 chars per token heuristic.
    final maxPromptChars = (_maxTokens - 500) * 4;
    String truncatedPrompt = prompt;
    if (prompt.length > maxPromptChars) {
      // Smart truncation: try to preserve the question part at the end
      // Most prompts have context first, question last
      final questionMarkers = ['Question:', 'Query:', 'User question:', '\n\nQuestion', 'Answer:', 'Your JSON:'];
      String? preservedEnd;
      for (final marker in questionMarkers) {
        final markerIndex = prompt.lastIndexOf(marker);
        if (markerIndex > 0 && markerIndex > prompt.length - 500) {
          // Found question marker near the end, preserve it
          preservedEnd = prompt.substring(markerIndex);
          break;
        }
      }
      
      if (preservedEnd != null) {
        // Keep beginning context and question, truncate middle
        final availableForContext = maxPromptChars - preservedEnd.length - 50; // 50 for truncation notice
        if (availableForContext > 100) {
          truncatedPrompt = '${prompt.substring(0, availableForContext)}\n[...]\n$preservedEnd';
        } else {
          truncatedPrompt = '${prompt.substring(0, maxPromptChars)}...';
        }
      } else {
        truncatedPrompt = '${prompt.substring(0, maxPromptChars)}...';
      }
      debugPrint('[GraphRAGService] Truncated prompt from ${prompt.length} to ${truncatedPrompt.length} chars');
    }
    
    debugPrint('[GraphRAGService] Generating LLM response for prompt (${truncatedPrompt.length} chars)');
    
    await _llmLock.acquire();
    try {
      // Clear history before each call — each prompt is independent
      await _clearHistoryOrRecreate();
      
      // Add prompt and generate response
      await _chat!.addQuery(Message(text: truncatedPrompt, isUser: true));
      final response = await _chat!.generateChatResponse();
      
      // Extract text from ModelResponse
      String responseText = '';
      if (response is TextResponse) {
        responseText = response.token;
      }
      
      debugPrint('[GraphRAGService] LLM response: ${responseText.substring(0, responseText.length.clamp(0, 100))}...');
      return responseText;
    } finally {
      _llmLock.release();
    }
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
  
  /// Request permissions for all data connectors (sequentially to avoid conflicts)
  Future<Map<DataPermissionType, DataPermissionStatus>> requestPermissions() async {
    _checkInitialized();
    // Request permissions sequentially to avoid "Can request only one set at a time" error
    final results = <DataPermissionType, DataPermissionStatus>{};
    
    // Contacts
    final contactsResult = await _graphRag!.requestPermissions('contacts');
    results.addAll(contactsResult);
    await Future.delayed(const Duration(milliseconds: 500));
    
    // Calendar
    final calendarResult = await _graphRag!.requestPermissions('calendar');
    results.addAll(calendarResult);
    await Future.delayed(const Duration(milliseconds: 500));
    
    // Photos
    final photosResult = await _graphRag!.requestPermissions('photos');
    results.addAll(photosResult);
    await Future.delayed(const Duration(milliseconds: 500));
    
    // Call Log (note: may be restricted on iOS)
    try {
      final callLogResult = await _graphRag!.requestPermissions('callLog');
      results.addAll(callLogResult);
      await Future.delayed(const Duration(milliseconds: 500));
    } catch (e) {
      debugPrint('[GraphRAGService] Call log permission request failed: $e');
    }
    
    // Documents (files)
    try {
      final documentsResult = await _graphRag!.requestPermissions('documents');
      results.addAll(documentsResult);
    } catch (e) {
      debugPrint('[GraphRAGService] Documents permission request failed: $e');
    }
    
    return results;
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
  
  /// Detect and remove entities whose source data has been deleted from the
  /// device, then clean up orphan nodes.
  Future<PruningResult> pruneDeletedData() async {
    _checkInitialized();
    debugPrint('[GraphRAGService] Pruning deleted data');
    final result = await _graphRag!.pruneDeletedData();
    debugPrint('[GraphRAGService] Pruning result: $result');
    return result;
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
  Future<GraphRAGQueryResult> query(
    String naturalLanguageQuery, {
    List<String>? entityTypes,
    int? topK,
    int? maxHops,
  }) async {
    _checkInitialized();
    debugPrint('[GraphRAGService] Query: "$naturalLanguageQuery"');
    
    final result = await _graphRag!.query(
      naturalLanguageQuery,
      entityTypes: entityTypes,
      topK: topK,
      maxHops: maxHops,
    );
    
    debugPrint('[GraphRAGService] Query returned ${result.entities.length} entities, ${result.communities.length} communities');
    return result;
  }
  
  /// Query the knowledge graph with generated answer
  Future<GraphRAGQueryResult> queryWithAnswer(
    String naturalLanguageQuery, {
    List<String>? entityTypes,
    int? topK,
    int? maxHops,
  }) async {
    _checkInitialized();
    debugPrint('[GraphRAGService] Query with answer: "$naturalLanguageQuery"');
    
    final result = await _graphRag!.queryWithAnswer(
      naturalLanguageQuery,
      entityTypes: entityTypes,
      topK: topK,
      maxHops: maxHops,
    );
    
    debugPrint('[GraphRAGService] Query returned ${result.entities.length} entities, answer: ${result.generatedAnswer?.substring(0, result.generatedAnswer!.length.clamp(0, 50)) ?? "none"}...');
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
  
  /// Execute a streaming global query with progress updates.
  ///
  /// Serialized through [_llmLock] per-prompt so only one LLM call is
  /// active at a time.
  Stream<GlobalQueryProgress> globalQueryAutoStreaming(String query) {
    _checkInitialized();
    debugPrint('[GraphRAGService] Streaming global query: "$query"');
    
    // Create streaming LLM callback — acquires mutex for the duration of
    // each individual prompt→response exchange.
    Stream<String> llmStreamCallback(String prompt) async* {
      await _llmLock.acquire();
      try {
        await _chat!.clearHistory();
        await _chat!.addQuery(Message(text: prompt));
        
        await for (final response in _chat!.generateChatResponseAsync()) {
          if (response is TextResponse) {
            yield response.token;
          }
        }
      } finally {
        _llmLock.release();
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
    int topK = 6,
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
  /// Fetches entities of all known types including the "You" central node
  Future<List<GraphEntity>> getAllEntities() async {
    _checkInitialized();
    // Include all entity types that may exist in the graph
    final entityTypes = [
      'SELF',           // "You" central node
      'PERSON',         // People from contacts, calendar, photos
      'ORGANIZATION',   // Companies, organizations
      'EVENT',          // Calendar events
      'LOCATION',       // Places, addresses
      'PHOTO',          // Photos
      'PHONE_CALL',     // Phone calls
      'DOCUMENT',       // Documents
      'NOTE',           // Notes
      'NOTE_CHUNK',     // Note chunks (parts of long notes)
      'DOCUMENT_CHUNK', // Document chunks (parts of long documents)
      'PROJECT',        // Projects, folders
      'TOPIC',          // Topics, tags
      'DATE',           // Dates
      'ALARM',          // Alarms
      'EMAIL',          // Email addresses
      'PHONE',          // Phone numbers
      'HUB',            // Hub nodes (grouping by data type)
    ];
    final entities = <GraphEntity>[];
    
    for (final type in entityTypes) {
      final typeEntities = await _graphRag!.getEntitiesByType(type);
      if (typeEntities.isNotEmpty) {
        debugPrint('[GraphRAGService] Type "$type": ${typeEntities.length} entities');
      }
      entities.addAll(typeEntities);
    }
    
    debugPrint('[GraphRAGService] Retrieved ${entities.length} total entities across ${entityTypes.length} types');
    
    // Log entity breakdown for debugging
    final typeCounts = <String, int>{};
    for (final entity in entities) {
      typeCounts[entity.type] = (typeCounts[entity.type] ?? 0) + 1;
    }
    debugPrint('[GraphRAGService] Entity breakdown: $typeCounts');
    
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
  
  /// Open a document picker for user to select files to index.
  /// This is the recommended way to get documents on Android 10+ and iOS.
  /// Returns the list of selected documents.
  Future<List<Document>> pickDocuments({bool allowMultiple = true}) async {
    _checkInitialized();
    
    final documentsConnector = _graphRag!.connectors.getConnector('documents');
    if (documentsConnector == null) {
      throw StateError('Documents connector not found');
    }
    
    // Cast to DocumentsConnector to access pickDocuments
    final connector = documentsConnector as DocumentsConnector;
    final documents = await connector.pickDocuments(allowMultiple: allowMultiple);
    
    debugPrint('[GraphRAGService] User selected ${documents.length} documents');
    return documents;
  }
  
  /// Index specific documents from a list (e.g., from pickDocuments)
  /// This bypasses the automatic fetch and indexes only the provided documents
  Future<void> indexDocuments(List<Document> documents) async {
    _checkInitialized();
    
    if (documents.isEmpty) {
      debugPrint('[GraphRAGService] No documents to index');
      return;
    }
    
    debugPrint('[GraphRAGService] Indexing ${documents.length} selected documents...');
    
    // Get the documents connector
    final documentsConnector = _graphRag!.connectors.getConnector('documents');
    if (documentsConnector == null) {
      throw StateError('Documents connector not found');
    }
    
    final connector = documentsConnector as DocumentsConnector;
    
    // Read and index each document
    for (final doc in documents) {
      try {
        final content = await connector.readContent(doc.id);
        if (content != null && content.isNotEmpty) {
          debugPrint('[GraphRAGService] Indexing document: ${doc.name} (${content.length} chars)');
          
          // Index the document through the indexing service
          await _graphRag!.indexDocumentContent(
            documentId: doc.id,
            name: doc.name,
            content: content,
            mimeType: doc.mimeType,
            creationDate: doc.createdDate,
            path: doc.path,
          );
        } else {
          debugPrint('[GraphRAGService] Skipping empty document: ${doc.name}');
        }
      } catch (e) {
        debugPrint('[GraphRAGService] Error indexing document ${doc.name}: $e');
      }
    }
    
    debugPrint('[GraphRAGService] Finished indexing selected documents');
  }

  /// Index a user-typed note.
  ///
  /// The note content is split into chunks if it exceeds the LLM extraction
  /// limit. Each chunk gets entity extraction, and chunks are linked with
  /// NEXT_CHUNK relationships.
  Future<void> indexNote({
    required String title,
    required String content,
    DateTime? dateCreated,
    DateTime? dateModified,
    String? sourceApp,
  }) async {
    _checkInitialized();

    if (content.isEmpty) {
      debugPrint('[GraphRAGService] Empty note content, skipping');
      return;
    }

    llmBusy.value = true;
    try {
      debugPrint(
          '[GraphRAGService] Indexing note: "$title" (${content.length} chars)');

      final noteId =
          '${title.hashCode}_${DateTime.now().millisecondsSinceEpoch}';

      await _graphRag!.indexNoteContent(
        noteId: noteId,
        title: title,
        content: content,
        dateCreated: dateCreated,
        dateModified: dateModified,
        sourceApp: sourceApp,
      );

      debugPrint('[GraphRAGService] Note "$title" indexed successfully');
    } finally {
      llmBusy.value = false;
    }
  }

  /// Index a user-created alarm into the knowledge graph.
  Future<void> indexAlarm({
    required String label,
    required DateTime dateTime,
    String? recurrence,
  }) async {
    _checkInitialized();

    llmBusy.value = true;
    try {
      debugPrint('[GraphRAGService] Indexing alarm: "$label"');

      final alarmId =
          '${label.hashCode}_${DateTime.now().millisecondsSinceEpoch}';

      await _graphRag!.indexAlarmContent(
        alarmId: alarmId,
        label: label,
        dateTime: dateTime,
        recurrence: recurrence,
        sourceApp: 'user_input',
      );

      debugPrint('[GraphRAGService] Alarm "$label" indexed successfully');
    } finally {
      llmBusy.value = false;
    }
  }

  /// Get all user-created notes from the graph.
  ///
  /// Returns NOTE entities sorted by last modified date (newest first).
  Future<List<GraphEntity>> getNotes() async {
    _checkInitialized();

    final notes = await _graphRag!.getEntitiesByType('NOTE');

    // Filter to only user-created notes (have sourceApp or 'user_input' pattern)
    // and sort by lastModified descending
    notes.sort((a, b) => b.lastModified.compareTo(a.lastModified));

    debugPrint('[GraphRAGService] Retrieved ${notes.length} notes');
    return notes;
  }

  /// Delete a user-created note and all its associated graph data.
  ///
  /// This cascades: NOTE_CHUNK entities, orphaned extracted entities,
  /// and community updates.
  Future<void> deleteNote(String noteEntityId) async {
    _checkInitialized();

    llmBusy.value = true;
    try {
      debugPrint('[GraphRAGService] Deleting note: "$noteEntityId"');
      await _graphRag!.deleteNote(noteEntityId);
      debugPrint('[GraphRAGService] Note "$noteEntityId" deleted successfully');
    } finally {
      llmBusy.value = false;
    }
  }

  /// Update a user-created note by deleting the old one and re-indexing.
  ///
  /// This is a delete + create operation because entity extraction
  /// must be re-run on the new content.
  Future<void> updateNote({
    required String oldEntityId,
    required String title,
    required String content,
    DateTime? dateCreated,
  }) async {
    _checkInitialized();

    llmBusy.value = true;
    try {
      debugPrint(
          '[GraphRAGService] Updating note: "$oldEntityId" -> "$title"');

      // 1. Delete old note and its graph data
      await _graphRag!.deleteNote(oldEntityId);

      // 2. Re-index with new content (call internal — llmBusy already set)
      final noteId =
          '${title.hashCode}_${DateTime.now().millisecondsSinceEpoch}';

      await _graphRag!.indexNoteContent(
        noteId: noteId,
        title: title,
        content: content,
        dateCreated: dateCreated,
        dateModified: DateTime.now(),
        sourceApp: 'user_input',
      );

      debugPrint('[GraphRAGService] Note updated successfully');
    } finally {
      llmBusy.value = false;
    }
  }

  /// Dispose resources
  Future<void> dispose() async {
    if (_graphRag != null) {
      await _graphRag!.close();
      _graphRag = null;
    }
    _chat = null;
    _extractionChat = null;
    _visionChat = null;
    _embeddingModel = null;
    _chatFactory = null;
    _extractionChatFactory = null;
    _isInitialized = false;
    _error = null;
    debugPrint('[GraphRAGService] Disposed');
  }

  /// Close only the graph store (keeps LLM and embedding models alive).
  ///
  /// Use this together with [reopenGraph] to replace the underlying database
  /// file without recreating the expensive inference models.
  Future<void> closeGraph() async {
    _checkInitialized();
    await _graphRag!.close();
    debugPrint('[GraphRAGService] Graph store closed (models still alive)');
  }

  /// Re-open the graph store after [closeGraph] (e.g. after DB file swap).
  ///
  /// This re-creates the native graph repository, connectors, extractors,
  /// query engine, and indexing service — but reuses the existing LLM and
  /// embedding model instances.
  Future<void> reopenGraph() async {
    if (_graphRag == null) {
      throw StateError('GraphRAGService: _graphRag is null, cannot reopen');
    }
    await _graphRag!.initialize();
    debugPrint('[GraphRAGService] Graph store reopened');
  }
  
  void _checkInitialized() {
    if (!_isInitialized || _graphRag == null) {
      throw StateError('GraphRAGService not initialized. Call initialize() first.');
    }
  }
}
