import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart' hide EmbeddingModel;
import 'package:flutter_gemma_example/services/graph_rag_service.dart';
import 'package:flutter_gemma_example/services/auth_token_service.dart';
import 'package:flutter_gemma_example/models/model.dart';
import 'package:flutter_gemma_example/models/embedding_model.dart'
    as app_models;
import 'package:flutter_gemma_example/graph_rag_index_screen.dart';
import 'package:flutter_gemma_example/graph_rag_chat_screen.dart';

/// Navigator that checks model installation and provides tab navigation
/// between Index Management and Chat screens
class GraphRAGNavigator extends StatefulWidget {
  const GraphRAGNavigator({super.key});

  @override
  State<GraphRAGNavigator> createState() => _GraphRAGNavigatorState();
}

class _GraphRAGNavigatorState extends State<GraphRAGNavigator>
    with SingleTickerProviderStateMixin {
  final GraphRAGService _service = GraphRAGService.instance;
  late TabController _tabController;

  // Model checking state
  bool _checkingModels = true;
  bool _inferenceModelReady = false;
  bool _embeddingModelReady = false;
  bool _isInitializing = false;
  String? _initError;
  String _statusMessage = 'Checking models...';

  // Model definitions
  static const _inferenceModel = Model.qwen25_1_5B_InstructCpu;
  static const _embeddingModel = app_models.EmbeddingModel.embeddingGemma512;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _checkModelsAndInitialize();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _checkModelsAndInitialize() async {
    setState(() {
      _checkingModels = true;
      _statusMessage = 'Checking installed models...';
    });

    try {
      // Check if already initialized
      if (_service.isInitialized) {
        setState(() {
          _inferenceModelReady = true;
          _embeddingModelReady = true;
          _checkingModels = false;
        });
        return;
      }

      // Check if inference model is installed
      final inferenceInstalled = await FlutterGemma.isModelInstalled(
        _inferenceModel.filename,
      );

      // Check if embedding model is installed
      final embeddingInstalled = await FlutterGemma.isModelInstalled(
        _embeddingModel.filename,
      );

      setState(() {
        _inferenceModelReady = inferenceInstalled;
        _embeddingModelReady = embeddingInstalled;
        _checkingModels = false;
      });

      // If both models are ready, auto-initialize
      if (inferenceInstalled && embeddingInstalled) {
        await _initializeWithExistingModels();
      }
    } catch (e) {
      setState(() {
        _checkingModels = false;
        _initError = 'Error checking models: $e';
      });
    }
  }

  Future<void> _initializeWithExistingModels() async {
    if (_isInitializing) return;

    setState(() {
      _isInitializing = true;
      _initError = null;
      _statusMessage = 'Loading inference model...';
    });

    try {
      // Even if model is installed, we need to "install" it to make it active
      final installer = FlutterGemma.installModel(
        modelType: _inferenceModel.modelType,
        fileType: _inferenceModel.fileType,
      );

      String? token;
      if (_inferenceModel.needsAuth) {
        token = await AuthTokenService.loadToken();
      }

      if (_inferenceModel.localModel) {
        await installer.fromAsset(_inferenceModel.url).install();
      } else {
        await installer.fromNetwork(_inferenceModel.url, token: token).install();
      }

      // Now get the active model
      final model = await FlutterGemma.getActiveModel(
        maxTokens: _inferenceModel.maxTokens,
        preferredBackend: PreferredBackend.cpu,
      );

      final chat = await model.createChat(
        temperature: 0.1,
        randomSeed: 1,
        topK: _inferenceModel.topK,
      );

      setState(() => _statusMessage = 'Loading embedding model...');

      // Same for embedding model - install to activate
      final embeddingInstaller = FlutterGemma.installEmbedder();
      String? embeddingToken;
      if (_embeddingModel.needsAuth) {
        embeddingToken = await AuthTokenService.loadToken();
      }
      
      await embeddingInstaller
          .modelFromNetwork(_embeddingModel.url, token: embeddingToken)
          .tokenizerFromNetwork(_embeddingModel.tokenizerUrl, token: embeddingToken)
          .install();

      // Now get the active embedder
      final embeddingModel = await FlutterGemma.getActiveEmbedder(
        preferredBackend: PreferredBackend.cpu,
      );

      setState(() => _statusMessage = 'Initializing GraphRAG...');

      // Initialize service
      await _service.initialize(
        chat: chat,
        embeddingModel: embeddingModel,
      );

      setState(() {
        _isInitializing = false;
        _statusMessage = '';
      });

      _showSnackBar('GraphRAG ready! 🎉');
    } catch (e) {
      setState(() {
        _isInitializing = false;
        _initError = e.toString();
      });
    }
  }

  Future<void> _downloadAndInitialize() async {
    // Both methods now use the same install flow, so just call initialize
    // The install process will download if needed or skip if already present
    await _initializeWithExistingModels();
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
    // Show setup screen if not ready
    if (_checkingModels || !_service.isInitialized) {
      return Scaffold(
        backgroundColor: const Color(0xFF0b2351),
        appBar: AppBar(
          title: const Text('GraphRAG'),
          backgroundColor: const Color(0xFF0b2351),
        ),
        body: _buildSetupView(),
      );
    }

    // Show tabbed interface when ready
    return Scaffold(
      backgroundColor: const Color(0xFF0b2351),
      appBar: AppBar(
        title: const Text('GraphRAG'),
        backgroundColor: const Color(0xFF0b2351),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.account_tree), text: 'Index'),
            Tab(icon: Icon(Icons.chat), text: 'Chat'),
          ],
          indicatorColor: Colors.orange,
          labelColor: Colors.orange,
          unselectedLabelColor: Colors.white54,
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          GraphRAGIndexScreen(),
          GraphRAGChatScreen(),
        ],
      ),
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

            // Model status cards
            _buildModelStatusCard(
              'Inference Model',
              _inferenceModel.displayName,
              _inferenceModel.size,
              _inferenceModelReady,
              Icons.smart_toy,
            ),
            const SizedBox(height: 12),
            _buildModelStatusCard(
              'Embedding Model',
              _embeddingModel.displayName,
              _embeddingModel.size,
              _embeddingModelReady,
              Icons.search,
            ),

            const SizedBox(height: 24),

            // Error display
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

            // Progress indicator
            if (_isInitializing || _checkingModels) ...[
              const CircularProgressIndicator(color: Colors.white),
              const SizedBox(height: 16),
              Text(
                _statusMessage,
                style: const TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
            ] else ...[
              // Action button
              if (_inferenceModelReady && _embeddingModelReady)
                ElevatedButton.icon(
                  onPressed: _initializeWithExistingModels,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Initialize GraphRAG'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 12),
                    backgroundColor: Colors.green,
                  ),
                )
              else
                ElevatedButton.icon(
                  onPressed: _downloadAndInitialize,
                  icon: const Icon(Icons.download),
                  label: Text(!_inferenceModelReady && !_embeddingModelReady
                      ? 'Download & Initialize'
                      : 'Download Missing & Initialize'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 12),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildModelStatusCard(
    String title,
    String modelName,
    String size,
    bool isReady,
    IconData icon,
  ) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1a3a5c),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isReady ? Colors.green : Colors.orange,
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            color: isReady ? Colors.green : Colors.orange,
            size: 32,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                  ),
                ),
                Text(
                  modelName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  size,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            isReady ? Icons.check_circle : Icons.download,
            color: isReady ? Colors.green : Colors.orange,
          ),
        ],
      ),
    );
  }
}
