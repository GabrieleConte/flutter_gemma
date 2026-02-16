import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart' hide EmbeddingModel;
import 'package:flutter_gemma/rag/graph/link_prediction.dart' show LinkValidationTools;
import 'package:flutter_gemma_example/services/graph_rag_service.dart';
import 'package:flutter_gemma_example/services/auth_token_service.dart';
import 'package:flutter_gemma_example/models/model.dart';
import 'package:flutter_gemma_example/models/embedding_model.dart'
    as app_models;
import 'package:flutter_gemma_example/graph_rag_index_screen.dart';
import 'package:flutter_gemma_example/graph_rag_chat_screen.dart';
import 'package:flutter_gemma_example/notes_management_screen.dart';
import 'package:flutter_gemma_example/services/test_data_service.dart';
import 'package:url_launcher/url_launcher.dart';

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
  final TextEditingController _tokenController = TextEditingController();

  // Model checking state
  bool _checkingModels = true;
  bool _inferenceModelReady = false;
  bool _embeddingModelReady = false;
  bool _isInitializing = false;
  String? _initError;
  String _statusMessage = 'Checking models...';

  // Test data button states
  bool _isResettingGraph = false;
  bool _isUploadingTestData = false;

  // User-selected models
  late Model _selectedInferenceModel;
  late app_models.EmbeddingModel _selectedEmbeddingModel;
  String _token = '';

  /// Get available inference models — restricted to gemma3n_2B_litertlm
  /// which supports both text generation and vision (image captioning).
  List<Model> get _availableInferenceModels {
    return [Model.gemma3n_2B_litertlm];
  }

  /// Get available embedding models
  List<app_models.EmbeddingModel> get _availableEmbeddingModels {
    return app_models.EmbeddingModel.values.toList();
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    // Set default — only gemma3n_2B_litertlm is available for GraphRAG
    _selectedInferenceModel = _availableInferenceModels.isNotEmpty
        ? _availableInferenceModels.first
        : Model.gemma3n_2B_litertlm;
    _selectedEmbeddingModel = _availableEmbeddingModels.isNotEmpty
        ? _availableEmbeddingModels.first
        : app_models.EmbeddingModel.embeddingGemma512;
    _loadSavedToken();
    _checkModelsAndInitialize();
  }

  Future<void> _loadSavedToken() async {
    final savedToken = await AuthTokenService.loadToken();
    if (savedToken != null && savedToken.isNotEmpty) {
      setState(() {
        _token = savedToken;
        _tokenController.text = savedToken;
      });
    }
  }

  Future<void> _saveToken(String token) async {
    await AuthTokenService.saveToken(token);
    setState(() => _token = token);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _tokenController.dispose();
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

      // Check if inference model is installed (used for both main LLM and extraction)
      final inferenceInstalled = await FlutterGemma.isModelInstalled(
        _selectedInferenceModel.filename,
      );

      // Check if embedding model is installed
      final embeddingInstalled = await FlutterGemma.isModelInstalled(
        _selectedEmbeddingModel.filename,
      );

      setState(() {
        _inferenceModelReady = inferenceInstalled;
        _embeddingModelReady = embeddingInstalled;
        _checkingModels = false;
      });

      // If all models are ready, auto-initialize
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
      _statusMessage = 'Loading inference model (${_selectedInferenceModel.displayName})...';
    });

    try {
      // Even if model is installed, we need to "install" it to make it active
      final installer = FlutterGemma.installModel(
        modelType: _selectedInferenceModel.modelType,
        fileType: _selectedInferenceModel.fileType,
      );

      final token = _selectedInferenceModel.needsAuth && _token.isNotEmpty ? _token : null;

      if (_selectedInferenceModel.localModel) {
        await installer.fromAsset(_selectedInferenceModel.url).install();
      } else {
        await installer.fromNetwork(_selectedInferenceModel.url, token: token).install();
      }
      /*
      // Try GPU first (required for vision encoder), fall back to CPU if unavailable
      InferenceModel model;
      bool gpuAvailable = true;

      try {

        setState(() => _statusMessage = 'Loading model with GPU...');
        model = await FlutterGemma.getActiveModel(
          maxTokens: _selectedInferenceModel.maxTokens,
          preferredBackend: _selectedInferenceModel.preferredBackend,
          supportImage: _selectedInferenceModel.supportImage,
          maxNumImages: _selectedInferenceModel.maxNumImages,
        );

        debugPrint('[GraphRAGNavigator] Model loaded with GPU + vision support');
      } catch (e) {
        debugPrint('[GraphRAGNavigator] GPU init failed ($e), falling back to CPU (no vision)');
        gpuAvailable = false;
        setState(() => _statusMessage = 'GPU unavailable, loading model with CPU...');
        model = await FlutterGemma.getActiveModel(
          maxTokens: _selectedInferenceModel.maxTokens,
          preferredBackend: PreferredBackend.cpu,
        );
        debugPrint('[GraphRAGNavigator] Model loaded with CPU (image captioning disabled)');
      }
        */
      const gpuAvailable = false; // Force CPU for now since vision encoder is not fully stable yet
      debugPrint('[GraphRAGNavigator] Creating native model (CPU backend)...');
      final model = await FlutterGemma.getActiveModel(
          maxTokens: _selectedInferenceModel.maxTokens,
          preferredBackend: PreferredBackend.cpu,
      );
      debugPrint('[GraphRAGNavigator] Native model created successfully');

      // Create main chat for text generation (no tools)
      debugPrint('[GraphRAGNavigator] Creating main chat...');
      final chat = await model.createChat(
        temperature: _selectedInferenceModel.temperature,
        randomSeed: 1,
        topK: _selectedInferenceModel.topK,
        modelType: _selectedInferenceModel.modelType,
      );
      debugPrint('[GraphRAGNavigator] Main chat created');
      
      // Create extraction chat from same model with tool support
      setState(() => _statusMessage = 'Creating extraction chat with tools...');
      
      debugPrint('[GraphRAGNavigator] Creating extraction chat with tools from same model');
      final extractionTools = <Tool>[
        ExtractionTools.extractAll,
        ...LinkValidationTools.all,
      ];
      final extractionChat = await model.createChat(
        temperature: 0.0,
        randomSeed: 1,
        topK: _selectedInferenceModel.topK,
        supportsFunctionCalls: true,
        tools: extractionTools,
        modelType: _selectedInferenceModel.modelType,
      );
      debugPrint('[GraphRAGNavigator] Extraction chat created with ${extractionTools.length} tools');

      // Vision chat only if GPU is available (vision encoder requires GPU)
      InferenceChat? visionChat;
      if (gpuAvailable && _selectedInferenceModel.supportImage) {
        setState(() => _statusMessage = 'Creating vision chat for image captioning...');
        visionChat = await model.createChat(
          temperature: 0.3,
          randomSeed: 1,
          topK: _selectedInferenceModel.topK,
          supportImage: true,
          modelType: _selectedInferenceModel.modelType,
        );
        debugPrint('[GraphRAGNavigator] Vision chat created for image captioning');
      } else {
        debugPrint('[GraphRAGNavigator] Vision chat skipped (GPU not available or model does not support images)');
      }

      setState(() => _statusMessage = 'Loading embedding model...');

      // Same for embedding model - install to activate
      final embeddingInstaller = FlutterGemma.installEmbedder();
      final embeddingToken = _selectedEmbeddingModel.needsAuth && _token.isNotEmpty ? _token : null;
      
      await embeddingInstaller
          .modelFromNetwork(_selectedEmbeddingModel.url, token: embeddingToken)
          .tokenizerFromNetwork(_selectedEmbeddingModel.tokenizerUrl, token: embeddingToken)
          .install();

      // Now get the active embedder
      final embeddingModel = await FlutterGemma.getActiveEmbedder(
        preferredBackend: PreferredBackend.cpu,
      );

      setState(() => _statusMessage = 'Initializing GraphRAG...');

      // Initialize service — enable image captioning only if vision chat is available
      final enableCaptioning = visionChat != null;
      
      // Provide a factory that can recreate the model+chat from scratch
      // if the native model/session goes stale ("Model is closed").
      Future<InferenceChat> chatFactory() async {
        debugPrint('[GraphRAGNavigator] chatFactory: recreating model + chat...');
        final freshModel = await FlutterGemma.getActiveModel(
          maxTokens: _selectedInferenceModel.maxTokens,
          preferredBackend: PreferredBackend.cpu,
        );
        final freshChat = await freshModel.createChat(
          temperature: _selectedInferenceModel.temperature,
          randomSeed: 1,
          topK: _selectedInferenceModel.topK,
          modelType: _selectedInferenceModel.modelType,
        );
        debugPrint('[GraphRAGNavigator] chatFactory: model + chat recreated ✅');
        return freshChat;
      }
      
      // Factory to recreate the extraction chat on demand (e.g. after indexing
      // pipeline released it, but user then adds a note/document/alarm).
      Future<InferenceChat> extractionChatFactory() async {
        debugPrint('[GraphRAGNavigator] extractionChatFactory: recreating extraction chat...');
        final freshModel = await FlutterGemma.getActiveModel(
          maxTokens: _selectedInferenceModel.maxTokens,
          preferredBackend: PreferredBackend.cpu,
        );
        final freshChat = await freshModel.createChat(
          temperature: 0.0,
          randomSeed: 1,
          topK: _selectedInferenceModel.topK,
          supportsFunctionCalls: true,
          tools: extractionTools,
          modelType: _selectedInferenceModel.modelType,
        );
        debugPrint('[GraphRAGNavigator] extractionChatFactory: extraction chat recreated ✅');
        return freshChat;
      }
      
      await _service.initialize(
        chat: chat,
        embeddingModel: embeddingModel,
        extractionChat: extractionChat,
        visionChat: visionChat,
        enableImageCaptioning: enableCaptioning,
        chatFactory: chatFactory,
        extractionChatFactory: extractionChatFactory,
        maxTokens: _selectedInferenceModel.maxTokens,
      );

      setState(() {
        _isInitializing = false;
        _statusMessage = '';
      });

      final modeLabel = enableCaptioning ? 'with image captioning' : 'text-only (no GPU)';
      _showSnackBar('GraphRAG ready $modeLabel! 🎉');
    } catch (e, stackTrace) {
      debugPrint('[GraphRAGNavigator] Initialization failed: $e\n$stackTrace');
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
            Tab(icon: Icon(Icons.note), text: 'Notes'),
            Tab(icon: Icon(Icons.settings), text: 'Settings'),
          ],
          indicatorColor: Colors.orange,
          labelColor: Colors.orange,
          unselectedLabelColor: Colors.white54,
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          const GraphRAGIndexScreen(),
          const GraphRAGChatScreen(),
          const NotesManagementScreen(),
          _buildSettingsTab(),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Test Data Handlers
  // ---------------------------------------------------------------------------

  Future<void> _handleResetTestGraph() async {
    if (_isResettingGraph) return;
    setState(() {
      _isResettingGraph = true;
      _initError = null;
    });

    try {
      // 1. Close only the graph store (models stay alive)
      debugPrint('[GraphRAGNavigator] Closing graph store for DB reset...');
      await _service.closeGraph();

      // 2. Replace the DB file with the bundled test snapshot
      debugPrint('[GraphRAGNavigator] Replacing DB file...');
      await TestDataService.resetTestGraph();

      // 3. Reopen the graph store on the new file
      debugPrint('[GraphRAGNavigator] Reopening graph store...');
      await _service.reopenGraph();

      debugPrint('[GraphRAGNavigator] Graph reset complete ✅');
      _showSnackBar('Test graph restored successfully!');
    } catch (e, stack) {
      debugPrint('[GraphRAGNavigator] Reset failed: $e\n$stack');
      setState(() => _initError = 'Reset failed: $e');
      _showSnackBar('Reset failed: $e', isError: true);
    } finally {
      setState(() => _isResettingGraph = false);
    }
  }

  Future<void> _handleUploadTestData() async {
    if (_isUploadingTestData) return;
    setState(() {
      _isUploadingTestData = true;
      _initError = null;
    });

    try {
      debugPrint('[GraphRAGNavigator] Requesting permissions for test data upload...');
      try {
        await _service.requestPermissions();
      } catch (e) {
        debugPrint('[GraphRAGNavigator] Permission request warning: $e');
        // Continue anyway — some permissions may already be granted
      }

      debugPrint('[GraphRAGNavigator] Uploading test data...');
      final counts = await TestDataService.uploadTestData();

      final summary = [
        if ((counts['images'] ?? 0) > 0) '${counts['images']} images',
        if ((counts['documents'] ?? 0) > 0) '${counts['documents']} docs',
        if ((counts['events'] ?? 0) > 0) '${counts['events']} events',
        if ((counts['recurrentEvents'] ?? 0) > 0)
          '${counts['recurrentEvents']} recurring',
        if ((counts['contacts'] ?? 0) > 0) '${counts['contacts']} contacts',
        if ((counts['calls'] ?? 0) > 0) '${counts['calls']} calls',
      ].join(', ');

      debugPrint('[GraphRAGNavigator] Upload complete: $summary');
      _showSnackBar('Test data uploaded: $summary');
    } catch (e, stack) {
      debugPrint('[GraphRAGNavigator] Upload failed: $e\n$stack');
      setState(() => _initError = 'Upload failed: $e');
      _showSnackBar('Upload failed: $e', isError: true);
    } finally {
      setState(() => _isUploadingTestData = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Test Data Section UI (used inside Settings tab)
  // ---------------------------------------------------------------------------

  Widget _buildTestDataSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1a3a5c),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(Icons.science, color: Colors.orange, size: 22),
              SizedBox(width: 8),
              Text(
                'Test Data',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Load pre-built test data for development and evaluation.',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 16),

          // --- Reset test graph button ---
          ElevatedButton.icon(
            onPressed: (_isResettingGraph || !_service.isInitialized)
                ? null
                : _handleResetTestGraph,
            icon: _isResettingGraph
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.restore),
            label: Text(_isResettingGraph
                ? 'Resetting...'
                : 'Reset test graph'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.deepOrange,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Replaces the current graph database with a pre-built test snapshot.',
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),

          const SizedBox(height: 16),

          // --- Upload test data button ---
          ElevatedButton.icon(
            onPressed: _isUploadingTestData ? null : _handleUploadTestData,
            icon: _isUploadingTestData
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.upload_file),
            label: Text(_isUploadingTestData
                ? 'Uploading...'
                : 'Upload test data'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.indigo,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Pushes images, documents, calendar events, contacts, and call log '
            'entries into the device for the indexing pipeline to discover.',
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ],
      ),
    );
  }

  /// Settings tab that allows changing models after initialization
  Widget _buildSettingsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(
            child: Icon(
              Icons.settings,
              size: 60,
              color: Colors.white54,
            ),
          ),
          const SizedBox(height: 16),
          const Center(
            child: Text(
              'Model Settings',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Center(
            child: Text(
              'Change models and reinitialize GraphRAG',
              style: TextStyle(fontSize: 14, color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 24),
          _buildModelSelectionContent(),
          const SizedBox(height: 32),
          _buildTestDataSection(),
        ],
      ),
    );
  }

  Widget _buildSetupView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(
            child: Icon(
              Icons.account_tree,
              size: 80,
              color: Colors.white54,
            ),
          ),
          const SizedBox(height: 24),
          const Center(
            child: Text(
              'GraphRAG Setup',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Center(
            child: Text(
              'GraphRAG builds a personal knowledge graph from your phone local data, enabling intelligent queries about your data.',
              style: TextStyle(fontSize: 16, color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 24),
          _buildModelSelectionContent(),
        ],
      ),
    );
  }

  /// Shared content for model selection used in both setup and settings
  Widget _buildModelSelectionContent() {
    final needsToken = _selectedInferenceModel.needsAuth ||
        _selectedEmbeddingModel.needsAuth;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Token input (shown when any selected model needs auth)
        if (needsToken) ...[  
          _buildTokenInput(),
          const SizedBox(height: 24),
        ],

        // LLM model selector
        _buildModelSelector<Model>(
            title: 'Inference Model (LLM)',
            icon: Icons.smart_toy,
            models: _availableInferenceModels,
            selected: _selectedInferenceModel,
            isReady: _inferenceModelReady,
            onChanged: (model) {
              if (model != null) {
                setState(() => _selectedInferenceModel = model);
                _recheckModels();
              }
            },
            displayName: (m) => '${m.displayName} (${m.size})',
            subtitle: 'Only function-call capable models are shown',
        ),
        const SizedBox(height: 12),

        // Embedding model selector
        _buildModelSelector<app_models.EmbeddingModel>(
          title: 'Embedding Model',
          icon: Icons.search,
          models: _availableEmbeddingModels,
          selected: _selectedEmbeddingModel,
          isReady: _embeddingModelReady,
          onChanged: (model) {
            if (model != null) {
              setState(() => _selectedEmbeddingModel = model);
              _recheckModels();
            }
          },
          displayName: (m) => '${m.displayName} (${m.size})',
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
          const Center(child: CircularProgressIndicator(color: Colors.white)),
          const SizedBox(height: 16),
          Text(
            _statusMessage,
            style: const TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
        ] else ...[
          // Action button
          Center(
            child: _inferenceModelReady && _embeddingModelReady
                ? ElevatedButton.icon(
                    onPressed: _initializeWithExistingModels,
                    icon: const Icon(Icons.play_arrow),
                    label: Text(_service.isInitialized ? 'Reinitialize GraphRAG' : 'Initialize GraphRAG'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 12),
                      backgroundColor: Colors.green,
                    ),
                  )
                : ElevatedButton.icon(
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
          ),
        ],
      ],
    );
  }

  /// Re-check if newly selected models are already installed
  Future<void> _recheckModels() async {
    final inferenceInstalled = await FlutterGemma.isModelInstalled(
      _selectedInferenceModel.filename,
    );
    final embeddingInstalled = await FlutterGemma.isModelInstalled(
      _selectedEmbeddingModel.filename,
    );
    setState(() {
      _inferenceModelReady = inferenceInstalled;
      _embeddingModelReady = embeddingInstalled;
    });
  }

  Widget _buildTokenInput() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1a3a5c),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'HuggingFace Access Token',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tokenController,
            obscureText: true,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Paste your Hugging Face access token here',
              hintStyle: const TextStyle(color: Colors.white60),
              border: const OutlineInputBorder(
                borderSide: BorderSide(color: Colors.white30),
              ),
              enabledBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: Colors.white30),
              ),
              focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: Colors.blue),
              ),
              filled: true,
              fillColor: const Color(0xFF2a4a6c),
              suffixIcon: IconButton(
                icon: const Icon(Icons.save, color: Colors.white),
                onPressed: () async {
                  final token = _tokenController.text.trim();
                  if (token.isNotEmpty) {
                    await _saveToken(token);
                    if (mounted) {
                      _showSnackBar('Access Token saved successfully!');
                    }
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          RichText(
            text: TextSpan(
              style: const TextStyle(color: Colors.white, fontSize: 12),
              children: [
                const TextSpan(
                  text: 'To create an access token, please visit ',
                ),
                TextSpan(
                  text: 'https://huggingface.co/settings/tokens',
                  style: TextStyle(
                    color: Colors.blue[300],
                    decoration: TextDecoration.underline,
                  ),
                  recognizer: TapGestureRecognizer()
                    ..onTap = () async {
                      final uri = Uri.parse('https://huggingface.co/settings/tokens');
                      if (await canLaunchUrl(uri)) {
                        await launchUrl(uri);
                      }
                    },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModelSelector<T>({
    required String title,
    required IconData icon,
    required List<T> models,
    required T selected,
    required bool isReady,
    required ValueChanged<T?> onChanged,
    required String Function(T) displayName,
    String? subtitle,
  }) {
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: isReady ? Colors.green : Colors.orange, size: 24),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              const Spacer(),
              Icon(
                isReady ? Icons.check_circle : Icons.download,
                color: isReady ? Colors.green : Colors.orange,
                size: 20,
              ),
            ],
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<T>(
            initialValue: selected,
            dropdownColor: const Color(0xFF1a3a5c),
            style: const TextStyle(color: Colors.white, fontSize: 13),
            isExpanded: true,
            decoration: const InputDecoration(
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              border: OutlineInputBorder(
                borderSide: BorderSide(color: Colors.white30),
              ),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Colors.white30),
              ),
              focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Colors.blue),
              ),
              filled: true,
              fillColor: Color(0xFF2a4a6c),
            ),
            items: models.map((m) {
              return DropdownMenuItem<T>(
                value: m,
                child: Text(
                  displayName(m),
                  overflow: TextOverflow.ellipsis,
                ),
              );
            }).toList(),
            onChanged: onChanged,
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}
