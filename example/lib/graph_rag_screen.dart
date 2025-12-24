import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart' hide EmbeddingModel;
import 'package:flutter_gemma/rag/graph/global_query_engine.dart' as global;
import 'package:flutter_gemma_example/services/graph_rag_service.dart';
import 'package:flutter_gemma_example/services/auth_token_service.dart';
import 'package:flutter_gemma_example/models/model.dart';
import 'package:flutter_gemma_example/models/embedding_model.dart' as app_models;

/// Screen for demonstrating GraphRAG capabilities
class GraphRAGScreen extends StatefulWidget {
  const GraphRAGScreen({super.key});

  @override
  State<GraphRAGScreen> createState() => _GraphRAGScreenState();
}

class _GraphRAGScreenState extends State<GraphRAGScreen> {
  final GraphRAGService _service = GraphRAGService.instance;
  final TextEditingController _queryController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  
  // State
  bool _isInitializing = false;
  bool _modelsReady = false;
  String? _initError;
  GraphStatistics? _stats;
  Map<DataPermissionType, DataPermissionStatus>? _permissions;
  
  // Query results
  final List<_QueryResult> _queryHistory = [];
  bool _isQuerying = false;
  bool _useGlobalQuery = false;  // Toggle for GraphRAG paper's map-reduce approach
  
  // Streaming global query state
  String? _streamingProgress;
  String _streamingAnswer = '';
  int? _currentCommunity;
  int? _totalCommunities;
  
  // Indexing
  StreamSubscription<IndexingProgress>? _progressSubscription;
  IndexingProgress? _indexingProgress;
  
  @override
  void initState() {
    super.initState();
    _checkInitialization();
  }
  
  @override
  void dispose() {
    _queryController.dispose();
    _scrollController.dispose();
    _progressSubscription?.cancel();
    super.dispose();
  }
  
  Future<void> _checkInitialization() async {
    if (_service.isInitialized) {
      await _loadStats();
      await _checkPermissions();
      _subscribeToProgress();
      setState(() => _modelsReady = true);
    }
  }
  
  Future<void> _initializeModels() async {
    if (_isInitializing) return;
    
    setState(() {
      _isInitializing = true;
      _initError = null;
    });
    
    try {
      // Step 1: Initialize inference model
      _showSnackBar('Installing inference model...');
      
      const inferenceModel = Model.qwen25_1_5B_InstructCpu;
      final installer = FlutterGemma.installModel(
        modelType: inferenceModel.modelType,
        fileType: inferenceModel.fileType,
      );
      
      if (inferenceModel.localModel) {
        await installer.fromAsset(inferenceModel.url).install();
      } else {
        String? token;
        if (inferenceModel.needsAuth) {
          token = await AuthTokenService.loadToken();
        }
        await installer.fromNetwork(inferenceModel.url, token: token).install();
      }
      
      // Use CPU backend for emulator compatibility (GPU not supported on most emulators)
      final model = await FlutterGemma.getActiveModel(
        maxTokens: inferenceModel.maxTokens,
        preferredBackend: PreferredBackend.cpu,
      );
      
      final chat = await model.createChat(
        temperature: 0.1,
        randomSeed: 1,
        topK: inferenceModel.topK,
      );
      
      _showSnackBar('Inference model ready ✅');
      
      // Step 2: Initialize embedding model
      _showSnackBar('Installing embedding model...');
      
      // Use EmbeddingGemma (2048D embeddings)
      const embeddingModelDef = app_models.EmbeddingModel.embeddingGemma512;
      final embeddingInstaller = FlutterGemma.installEmbedder();
      String? embeddingToken;
      if (embeddingModelDef.needsAuth) {
        embeddingToken = await AuthTokenService.loadToken();
      }
      await embeddingInstaller.modelFromNetwork(embeddingModelDef.url, token: embeddingToken)
          .tokenizerFromNetwork(embeddingModelDef.tokenizerUrl, token: embeddingToken)
          .install();
      
      final embeddingModel = await FlutterGemma.getActiveEmbedder(
        preferredBackend: PreferredBackend.cpu,
      );
      
      _showSnackBar('Embedding model ready ✅');
      
      // Step 3: Initialize GraphRAG service
      _showSnackBar('Initializing GraphRAG...');
      
      await _service.initialize(
        chat: chat,
        embeddingModel: embeddingModel,
      );
      
      // Subscribe to indexing progress
      _subscribeToProgress();
      
      // Load stats and permissions
      await _loadStats();
      await _checkPermissions();
      
      setState(() {
        _modelsReady = true;
        _isInitializing = false;
      });
      
      _showSnackBar('GraphRAG initialized successfully! 🎉');
    } catch (e) {
      setState(() {
        _initError = e.toString();
        _isInitializing = false;
      });
      _showSnackBar('Error: $e', isError: true);
    }
  }
  
  void _subscribeToProgress() {
    _progressSubscription?.cancel();
    _progressSubscription = _service.progressStream?.listen((progress) {
      setState(() => _indexingProgress = progress);
      
      if (progress.status == IndexingStatus.completed) {
        _loadStats();
        _showSnackBar('Indexing completed! 🎉');
      } else if (progress.status == IndexingStatus.failed) {
        _showSnackBar('Indexing failed: ${progress.errorMessage}', isError: true);
      }
    });
  }
  
  Future<void> _loadStats() async {
    if (!_service.isInitialized) return;
    
    try {
      final stats = await _service.getStats();
      setState(() => _stats = stats);
    } catch (e) {
      debugPrint('Error loading stats: $e');
    }
  }
  
  Future<void> _checkPermissions() async {
    if (!_service.isInitialized) return;
    
    try {
      final permissions = await _service.checkPermissions();
      setState(() => _permissions = permissions);
    } catch (e) {
      debugPrint('Error checking permissions: $e');
    }
  }
  
  Future<void> _requestPermissions() async {
    try {
      final permissions = await _service.requestPermissions();
      setState(() => _permissions = permissions);
      
      final granted = permissions.values.every(
        (s) => s == DataPermissionStatus.granted
      );
      
      if (granted) {
        _showSnackBar('All permissions granted ✅');
      } else {
        _showSnackBar('Some permissions were denied', isError: true);
      }
    } catch (e) {
      _showSnackBar('Error requesting permissions: $e', isError: true);
    }
  }
  
  Future<bool> _requestNotificationPermission() async {
    try {
      // Request notification permission (needed for Android 13+ foreground service)
      final platform = PlatformService();
      final status = await platform.requestPermission(PermissionType.notifications);
      if (status != PermissionStatus.granted) {
        _showSnackBar('Notification permission needed for background indexing', isError: true);
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('Error requesting notification permission: $e');
      // Continue anyway - notification might work without explicit permission on older Android
      return true;
    }
  }
  
  Future<void> _startIndexing({bool fullReindex = false}) async {
    try {
      // Request notification permission first
      await _requestNotificationPermission();
      
      await _service.startIndexing(fullReindex: fullReindex);
      _showSnackBar('Indexing started...');
    } catch (e) {
      _showSnackBar('Error: $e', isError: true);
    }
  }
  
  Future<void> _executeQuery() async {
    final query = _queryController.text.trim();
    if (query.isEmpty) return;
    
    setState(() {
      _isQuerying = true;
      _streamingProgress = null;
      _streamingAnswer = '';
      _currentCommunity = null;
      _totalCommunities = null;
    });
    
    try {
      if (_useGlobalQuery) {
        // Use streaming global query for real-time feedback
        int? usefulAnswers;
        int? communityLevel;
        Duration? mapPhaseDuration;
        Duration? reducePhaseDuration;
        Duration? totalDuration;
        
        await for (final progress in _service.globalQueryAutoStreaming(query)) {
          setState(() {
            _streamingProgress = progress.message;
            _currentCommunity = progress.currentCommunity;
            _totalCommunities = progress.totalCommunities;
            
            if (progress.token != null) {
              _streamingAnswer += progress.token!;
            }
            if (progress.partialResponse != null && progress.phase == global.GlobalQueryPhase.completed) {
              _streamingAnswer = progress.partialResponse!;
            }
            
            usefulAnswers = progress.usefulAnswers ?? usefulAnswers;
            communityLevel = progress.communityLevel ?? communityLevel;
            mapPhaseDuration = progress.mapPhaseDuration ?? mapPhaseDuration;
            reducePhaseDuration = progress.reducePhaseDuration ?? reducePhaseDuration;
            totalDuration = progress.totalDuration ?? totalDuration;
          });
        }
        
        setState(() {
          _queryHistory.insert(0, _QueryResult(
            query: query,
            entities: [],
            communities: [],
            contextString: _streamingAnswer,
            timestamp: DateTime.now(),
            isGlobalQuery: true,
            globalQueryMetadata: global.QueryMetadata(
              originalQuery: query,
              communityLevel: communityLevel ?? 0,
              mapPhaseDuration: mapPhaseDuration ?? Duration.zero,
              reducePhaseDuration: reducePhaseDuration ?? Duration.zero,
              totalDuration: totalDuration ?? Duration.zero,
            ),
            communityAnswersUsed: usefulAnswers ?? 0,
          ));
          _isQuerying = false;
          _streamingProgress = null;
          _streamingAnswer = '';
        });
      } else {
        // Standard local/hybrid query
        final result = await _service.query(query);
        
        setState(() {
          _queryHistory.insert(0, _QueryResult(
            query: query,
            entities: result.entities,
            communities: result.communities,
            contextString: result.contextString,
            timestamp: DateTime.now(),
          ));
          _isQuerying = false;
        });
      }
      
      _queryController.clear();
    } catch (e) {
      setState(() {
        _isQuerying = false;
        _streamingProgress = null;
        _streamingAnswer = '';
      });
      _showSnackBar('Query error: $e', isError: true);
    }
  }
  
  Future<void> _clearGraph() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Graph?'),
        content: const Text('This will delete all indexed data. This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    
    if (confirmed == true) {
      try {
        await _service.clearGraph();
        await _loadStats();
        _showSnackBar('Graph cleared');
      } catch (e) {
        _showSnackBar('Error: $e', isError: true);
      }
    }
  }
  
  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
        duration: Duration(seconds: isError ? 4 : 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0b2351),
      appBar: AppBar(
        title: const Text('GraphRAG'),
        backgroundColor: const Color(0xFF0b2351),
        actions: [
          if (_modelsReady)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _loadStats,
              tooltip: 'Refresh Stats',
            ),
        ],
      ),
      body: _buildBody(),
    );
  }
  
  Widget _buildBody() {
    if (!_modelsReady) {
      return _buildSetupView();
    }
    
    // Check if all permissions are granted
    final allPermissionsGranted = _permissions != null &&
        _permissions!.values.every((s) => s == DataPermissionStatus.granted);
    
    return Column(
      children: [
        _buildStatsCard(),
        // Only show permissions card if not all permissions are granted
        if (!allPermissionsGranted) _buildPermissionsCard(),
        _buildIndexingCard(),
        const Divider(color: Colors.white24),
        _buildQuerySection(),
        Expanded(child: _buildQueryResults()),
      ],
    );
  }
  
  Widget _buildSetupView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.account_tree,
              size: 80,
              color: Colors.white54,
            ),
            const SizedBox(height: 24),
            const Text(
              'GraphRAG Setup',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'GraphRAG builds a personal knowledge graph from your contacts and calendar, enabling intelligent queries about your data.',
              style: TextStyle(fontSize: 16, color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            if (_initError != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _initError!,
                  style: const TextStyle(color: Colors.red),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (_isInitializing)
              const Column(
                children: [
                  CircularProgressIndicator(color: Colors.white),
                  SizedBox(height: 16),
                  Text(
                    'Initializing models...\nThis may take a few minutes.',
                    style: TextStyle(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                ],
              )
            else
              ElevatedButton.icon(
                onPressed: _initializeModels,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Initialize GraphRAG'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildStatsCard() {
    return Card(
      margin: const EdgeInsets.all(8),
      color: const Color(0xFF1a3a5c),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _StatItem(
              icon: Icons.person,
              label: 'Entities',
              value: '${_stats?.entityCount ?? 0}',
            ),
            _StatItem(
              icon: Icons.link,
              label: 'Relationships',
              value: '${_stats?.relationshipCount ?? 0}',
            ),
            _StatItem(
              icon: Icons.groups,
              label: 'Communities',
              value: '${_stats?.communityCount ?? 0}',
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildPermissionsCard() {
    final contactsGranted = _permissions?[DataPermissionType.contacts] == DataPermissionStatus.granted;
    final calendarGranted = _permissions?[DataPermissionType.calendar] == DataPermissionStatus.granted;
    
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      color: const Color(0xFF1a3a5c),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Permissions',
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _PermissionChip(
                  label: 'Contacts',
                  granted: contactsGranted,
                ),
                const SizedBox(width: 8),
                _PermissionChip(
                  label: 'Calendar',
                  granted: calendarGranted,
                ),
                const Spacer(),
                TextButton(
                  onPressed: _requestPermissions,
                  child: const Text('Request'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildIndexingCard() {
    final progress = _indexingProgress;
    final isRunning = progress?.status == IndexingStatus.running;
    final isPaused = progress?.status == IndexingStatus.paused;
    
    return Card(
      margin: const EdgeInsets.all(8),
      color: const Color(0xFF1a3a5c),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Indexing',
                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                ),
                const Spacer(),
                if (isRunning || isPaused) ...[
                  IconButton(
                    icon: Icon(isPaused ? Icons.play_arrow : Icons.pause),
                    onPressed: isPaused ? _service.resumeIndexing : _service.pauseIndexing,
                    iconSize: 20,
                  ),
                  IconButton(
                    icon: const Icon(Icons.stop),
                    onPressed: () async {
                      await _service.cancelIndexing();
                    },
                    iconSize: 20,
                  ),
                ] else ...[
                  TextButton(
                    onPressed: () => _startIndexing(),
                    child: const Text('Start'),
                  ),
                  TextButton(
                    onPressed: () => _startIndexing(fullReindex: true),
                    child: const Text('Full Reindex'),
                  ),
                ],
              ],
            ),
            if (progress != null && (isRunning || isPaused)) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: progress.progress,
                backgroundColor: Colors.white24,
              ),
              const SizedBox(height: 4),
              Text(
                '${progress.currentPhase} - ${(progress.progress * 100).toStringAsFixed(0)}%',
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
              Text(
                'Entities: ${progress.extractedEntities}, Relationships: ${progress.extractedRelationships}',
                style: const TextStyle(fontSize: 12, color: Colors.white54),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _clearGraph,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Clear Graph'),
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildQuerySection() {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        children: [
          // Global Query Toggle
          Row(
            children: [
              Switch(
                value: _useGlobalQuery,
                onChanged: (value) => setState(() => _useGlobalQuery = value),
                activeThumbColor: Colors.purple,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _useGlobalQuery 
                      ? '🌐 Global Query (Map-Reduce over communities)'
                      : '🔍 Local Query (Entity similarity search)',
                  style: TextStyle(
                    fontSize: 12,
                    color: _useGlobalQuery ? Colors.purple[200] : Colors.white70,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Query Input Row
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _queryController,
                  decoration: InputDecoration(
                    hintText: _useGlobalQuery 
                        ? 'Ask broad questions like "What are the main themes?"...'
                        : 'Ask about your contacts or events...',
                    hintStyle: const TextStyle(color: Colors.white54),
                    filled: true,
                    fillColor: _useGlobalQuery 
                        ? const Color(0xFF2d1a5c) 
                        : const Color(0xFF1a3a5c),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                  style: const TextStyle(color: Colors.white),
                  onSubmitted: (_) => _executeQuery(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _isQuerying ? null : _executeQuery,
                icon: _isQuerying 
                    ? const SizedBox(
                        width: 24, 
                        height: 24, 
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)
                      )
                    : Icon(
                        _useGlobalQuery ? Icons.public : Icons.search,
                        color: Colors.white,  // Always white on colored background
                      ),
                style: IconButton.styleFrom(
                  backgroundColor: _useGlobalQuery ? Colors.purple : Colors.blue,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
  
  Widget _buildQueryResults() {
    // Show streaming progress if global query is running
    if (_isQuerying && _useGlobalQuery && (_streamingProgress != null || _streamingAnswer.isNotEmpty)) {
      return Column(
        children: [
          // Streaming progress card - make it flexible to handle long responses
          Expanded(
            child: Card(
              color: const Color(0xFF2d1a5c),
              margin: const EdgeInsets.all(8),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const SizedBox(
                          width: 16, 
                          height: 16, 
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.purple)
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _streamingProgress ?? 'Processing...',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_currentCommunity != null && _totalCommunities != null) ...[
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: _currentCommunity! / _totalCommunities!,
                        backgroundColor: Colors.white24,
                        valueColor: const AlwaysStoppedAnimation<Color>(Colors.purple),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Community $_currentCommunity of $_totalCommunities',
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                    if (_streamingAnswer.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      const Divider(color: Colors.white24),
                      const SizedBox(height: 8),
                      const Text(
                        'Response:',
                        style: TextStyle(
                          color: Colors.purple,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _streamingAnswer,
                        style: const TextStyle(color: Colors.white),
                      ),
                      // Blinking cursor effect
                      const Text(
                        '▌',
                        style: TextStyle(color: Colors.purple),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          // Show history below
          Expanded(
            child: _queryHistory.isEmpty
                ? const SizedBox.shrink()
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(8),
                    itemCount: _queryHistory.length,
                    itemBuilder: (context, index) {
                      final result = _queryHistory[index];
                      return _QueryResultCard(result: result);
                    },
                  ),
          ),
        ],
      );
    }
    
    if (_queryHistory.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search, size: 48, color: Colors.white24),
            SizedBox(height: 16),
            Text(
              'No queries yet',
              style: TextStyle(color: Colors.white54),
            ),
            Text(
              'Try: "Who do I know?" or "What events do I have?"',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
        ),
      );
    }
    
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(8),
      itemCount: _queryHistory.length,
      itemBuilder: (context, index) {
        final result = _queryHistory[index];
        return _QueryResultCard(result: result);
      },
    );
  }
}

// Helper widgets

class _StatItem extends StatelessWidget {
  const _StatItem({
    required this.icon,
    required this.label,
    required this.value,
  });
  
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: Colors.blue, size: 24),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: Colors.white70),
        ),
      ],
    );
  }
}

class _PermissionChip extends StatelessWidget {
  const _PermissionChip({
    required this.label,
    required this.granted,
  });
  
  final String label;
  final bool granted;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(
        granted ? Icons.check_circle : Icons.cancel,
        color: granted ? Colors.green : Colors.red,
        size: 18,
      ),
      label: Text(label),
      backgroundColor: const Color(0xFF0b2351),
    );
  }
}

class _QueryResult {
  final String query;
  final List<ScoredQueryEntity> entities;
  final List<ScoredQueryCommunity> communities;
  final String contextString;
  final DateTime timestamp;
  final bool isGlobalQuery;
  final global.QueryMetadata? globalQueryMetadata;
  final int communityAnswersUsed;
  
  _QueryResult({
    required this.query,
    required this.entities,
    required this.communities,
    required this.contextString,
    required this.timestamp,
    this.isGlobalQuery = false,
    this.globalQueryMetadata,
    this.communityAnswersUsed = 0,
  });
}

class _QueryResultCard extends StatelessWidget {
  const _QueryResultCard({required this.result});
  
  final _QueryResult result;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: result.isGlobalQuery ? const Color(0xFF2d1a5c) : const Color(0xFF1a3a5c),
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        title: Row(
          children: [
            if (result.isGlobalQuery) ...[
              const Icon(Icons.public, size: 16, color: Colors.purple),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                result.query,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        subtitle: Text(
          result.isGlobalQuery
              ? 'Global Query (Level ${result.globalQueryMetadata?.communityLevel ?? 0}, ${result.communityAnswersUsed} communities used)'
              : '${result.entities.length} entities, ${result.communities.length} communities',
          style: const TextStyle(fontSize: 12, color: Colors.white70),
        ),
        children: [
          if (result.isGlobalQuery && result.contextString.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Global Answer:',
                    style: TextStyle(fontWeight: FontWeight.bold, color: Colors.purple),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    result.contextString,
                    style: const TextStyle(color: Colors.white),
                  ),
                  if (result.globalQueryMetadata != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      'Map phase: ${result.globalQueryMetadata!.mapPhaseDuration.inMilliseconds}ms | '
                      'Reduce phase: ${result.globalQueryMetadata!.reducePhaseDuration.inMilliseconds}ms | '
                      'Total: ${result.globalQueryMetadata!.totalDuration.inMilliseconds}ms',
                      style: const TextStyle(fontSize: 10, color: Colors.white54),
                    ),
                  ],
                ],
              ),
            ),
          if (!result.isGlobalQuery && result.entities.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Entities:',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  ...result.entities.take(5).map((e) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: _getTypeColor(e.entity.type),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            e.entity.type,
                            style: const TextStyle(fontSize: 10, color: Colors.white),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            e.entity.name,
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                        Text(
                          '${(e.score * 100).toStringAsFixed(0)}%',
                          style: const TextStyle(fontSize: 12, color: Colors.white54),
                        ),
                      ],
                    ),
                  )),
                ],
              ),
            ),
          // Only show Context section for non-global queries (for global queries it's the same as the response)
          if (!result.isGlobalQuery && result.contextString.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Context:',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      result.contextString.length > 500
                          ? '${result.contextString.substring(0, 500)}...'
                          : result.contextString,
                      style: const TextStyle(fontSize: 12, color: Colors.white70),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
  
  Color _getTypeColor(String type) {
    switch (type.toUpperCase()) {
      case 'PERSON':
        return Colors.blue;
      case 'ORGANIZATION':
        return Colors.green;
      case 'EVENT':
        return Colors.orange;
      case 'LOCATION':
        return Colors.purple;
      default:
        return Colors.grey;
    }
  }
}
