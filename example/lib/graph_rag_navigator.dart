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
  bool _visionModelReady = false;
  bool _isInitializing = false;
  String? _initError;
  String _statusMessage = 'Checking models...';

  // User-selected models
  late Model _selectedInferenceModel;
  late app_models.EmbeddingModel _selectedEmbeddingModel;
  String _token = '';

  /// Holds the Gemma3n E2B vision model from the previous visionModelFactory() call.
  /// Closed at the start of the NEXT call to force a fresh native Engine each
  /// photo — LiteRT-LM 0.9.x corrupts memory when reusing the same Engine
  /// across multiple Conversation create/destroy cycles.
  InferenceModel? _prevVisionModel;

  /// Get available inference models — restricted to gemma3n_2B_litertlm
  /// which supports both text generation and vision (image captioning).
  List<Model> get _availableInferenceModels {
    return [Model.gemma3n_2B_litertlm, Model.qwen35_0_8B, Model.qwen3_4B_thinking];
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

      // Check if Qwen3.5-0.8B mm is installed (vision captioning, CPU-compatible)
      final visionInstalled = await FlutterGemma.isModelInstalled(
        Model.qwen35_0_8B.filename,
      );

      setState(() {
        _inferenceModelReady = inferenceInstalled;
        _embeddingModelReady = embeddingInstalled;
        _visionModelReady = visionInstalled;
        _checkingModels = false;
      });

      // If all models are ready, auto-initialize
      if (inferenceInstalled && embeddingInstalled && visionInstalled) {
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
      // Main inference model is text-only; vision captioning is handled separately
      // by visionModelFactory (uses qwen35_0_8B which is CPU-compatible).
      // Do NOT pass supportImage here — vision encoder backend constraints vary per model.
      debugPrint('[GraphRAGNavigator] Creating native model (CPU backend, text-only)...');
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
        temperature: _selectedInferenceModel.temperature,
        randomSeed: 1,
        topK: _selectedInferenceModel.topK,
        supportsFunctionCalls: true,
        tools: extractionTools,
        modelType: _selectedInferenceModel.modelType,
      );
      debugPrint('[GraphRAGNavigator] Extraction chat created with ${extractionTools.length} tools');
      // Vision captioning is always handled by the dedicated FastVLM model.
      // We do NOT create a vision chat from the main model here.

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

      // ──────────────────────────────────────────────────────────────────────
      // Install Qwen3.5-0.8B mm as the vision-captioning model.
      // It is swapped in only during the photo-processing phase of indexing,
      // then swapped back out to keep the main inference model active.
      // Qwen3.5-0.8B mm vision encoder has no GPU backend constraint → CPU ok.
      // ──────────────────────────────────────────────────────────────────────
      setState(() => _statusMessage = 'Installing Qwen3.5-0.8B vision model...');
      await FlutterGemma.installModel(
        modelType: Model.qwen35_0_8B.modelType,
        fileType: Model.qwen35_0_8B.fileType,
      ).fromNetwork(Model.qwen35_0_8B.url).install();
      setState(() {
        _visionModelReady = true;
      });
      debugPrint('[GraphRAGNavigator] Qwen3.5-0.8B vision model installed ✅');

      // Re-activate main inference model spec so factories produce chats from it.
      if (_selectedInferenceModel.localModel) {
        await FlutterGemma.installModel(
          modelType: _selectedInferenceModel.modelType,
          fileType: _selectedInferenceModel.fileType,
        ).fromAsset(_selectedInferenceModel.url).install();
      } else {
        final token = _selectedInferenceModel.needsAuth && _token.isNotEmpty ? _token : null;
        await FlutterGemma.installModel(
          modelType: _selectedInferenceModel.modelType,
          fileType: _selectedInferenceModel.fileType,
        ).fromNetwork(_selectedInferenceModel.url, token: token).install();
      }
      debugPrint('[GraphRAGNavigator] Main model spec reactivated after vision model install ✅');

      setState(() => _statusMessage = 'Initializing GraphRAG...');

      // ──────────────────────────────────────────────────────────────────────
      // Closures provided to GraphRAGService:
      //
      // chatFactory           — recreates main chat if session goes stale
      // extractionChatFactory — recreates extraction chat on demand
      // visionModelFactory    — installs Gemma3n E2B as active spec and returns
      //                         a vision-capable InferenceChat
      // reactivateMainModel   — reinstalls main model as active spec after
      //                         vision captioning finishes
      // ──────────────────────────────────────────────────────────────────────

      // Capture mutable model references so closures don't capture stale this
      final capturedSelectedModel = _selectedInferenceModel;
      final capturedToken = _token;

      Future<InferenceChat> chatFactory() async {
        debugPrint('[GraphRAGNavigator] chatFactory: recreating model + chat...');
        final freshModel = await FlutterGemma.getActiveModel(
          maxTokens: capturedSelectedModel.maxTokens,
          preferredBackend: PreferredBackend.cpu,
        );
        final freshChat = await freshModel.createChat(
          temperature: capturedSelectedModel.temperature,
          randomSeed: 1,
          topK: capturedSelectedModel.topK,
          modelType: capturedSelectedModel.modelType,
        );
        debugPrint('[GraphRAGNavigator] chatFactory: model + chat recreated ✅');
        return freshChat;
      }

      Future<InferenceChat> extractionChatFactory() async {
        debugPrint('[GraphRAGNavigator] extractionChatFactory: recreating extraction chat...');
        final freshModel = await FlutterGemma.getActiveModel(
          maxTokens: capturedSelectedModel.maxTokens,
          preferredBackend: PreferredBackend.cpu,
        );
        final freshChat = await freshModel.createChat(
          temperature: capturedSelectedModel.temperature,
          randomSeed: 1,
          topK: capturedSelectedModel.topK,
          supportsFunctionCalls: true,
          tools: extractionTools,
          modelType: capturedSelectedModel.modelType,
        );
        debugPrint('[GraphRAGNavigator] extractionChatFactory: extraction chat recreated ✅');
        return freshChat;
      }

      /// Installs Qwen35 0.8B as the active model and returns a vision chat.
      Future<InferenceChat> visionModelFactory() async {
        // Close the previous model first to release the native engine.
        // LiteRT-LM 0.9.x crashes (SIGSEGV) when the same Engine handle is
        // reused for more than ~2 Conversation create/destroy cycles.
        final modelToClose = _prevVisionModel;
        _prevVisionModel = null;
        if (modelToClose != null) {
          try {
            await modelToClose.close();
          } catch (e) {
            debugPrint('[GraphRAGNavigator] Warning: error closing previous vision model: $e');
          }
        }

        debugPrint('[GraphRAGNavigator] visionModelFactory: installing Qwen35 0.8B...');
        await FlutterGemma.installModel(
          modelType: Model.qwen35_0_8B.modelType,
          fileType: Model.qwen35_0_8B.fileType,
        ).fromNetwork(Model.qwen35_0_8B.url).install();
        final visionModel = await FlutterGemma.getActiveModel(
          maxTokens: Model.qwen35_0_8B.maxTokens,
          // GPU is avoided: Backend.GPU() for vision (visionBackend in LiteRtLmEngine)
          // fails to lock the soft_tokens tensor buffer on emulators and many
          // real devices on LiteRT-LM 0.9.x. CPU is reliable across all hardware.
          // CPU is used: Qwen3.5-0.8B mm vision encoder has no GPU backend
          // constraint so it runs on CPU reliably across all hardware.
          preferredBackend: PreferredBackend.cpu,
          supportImage: true,
          maxNumImages: Model.qwen35_0_8B.maxNumImages,
        );
        _prevVisionModel = visionModel; // remember for cleanup on next call
        final visionChat = await visionModel.createChat(
          temperature: Model.qwen35_0_8B.temperature,
          randomSeed: 1,
          topK: Model.qwen35_0_8B.topK,
          supportImage: true,
          modelType: Model.qwen35_0_8B.modelType,
        );
        debugPrint('[GraphRAGNavigator] visionModelFactory: Qwen35 0.8B vision chat ready ✅');
        return visionChat;
      }

      /// Reinstalls the main inference model as the active spec so subsequent
      /// chatFactory / extractionChatFactory calls use the correct model.
      Future<void> reactivateMainModel() async {
        debugPrint('[GraphRAGNavigator] reactivateMainModel: reinstalling main model spec...');
        final token = capturedSelectedModel.needsAuth && capturedToken.isNotEmpty
            ? capturedToken
            : null;
        if (capturedSelectedModel.localModel) {
          await FlutterGemma.installModel(
            modelType: capturedSelectedModel.modelType,
            fileType: capturedSelectedModel.fileType,
          ).fromAsset(capturedSelectedModel.url).install();
        } else {
          await FlutterGemma.installModel(
            modelType: capturedSelectedModel.modelType,
            fileType: capturedSelectedModel.fileType,
          ).fromNetwork(capturedSelectedModel.url, token: token).install();
        }
        debugPrint('[GraphRAGNavigator] reactivateMainModel: main model spec restored ✅');
      }

      await _service.initialize(
        chat: chat,
        embeddingModel: embeddingModel,
        extractionChat: extractionChat,
        visionModelFactory: visionModelFactory,
        reactivateMainModelCallback: reactivateMainModel,
        chatFactory: chatFactory,
        extractionChatFactory: extractionChatFactory,
        maxTokens: _selectedInferenceModel.maxTokens,
      );

      setState(() {
        _isInitializing = false;
        _statusMessage = '';
      });

      _showSnackBar('GraphRAG ready');
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
            child: _inferenceModelReady && _embeddingModelReady && _visionModelReady
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
                    label: Text(!_inferenceModelReady || !_embeddingModelReady || !_visionModelReady
                        ? 'Download & Initialize'
                        : 'Initialize GraphRAG'),
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
    final visionInstalled = await FlutterGemma.isModelInstalled(
      Model.qwen35_0_8B.filename,
    );
    setState(() {
      _inferenceModelReady = inferenceInstalled;
      _embeddingModelReady = embeddingInstalled;
      _visionModelReady = visionInstalled;
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
