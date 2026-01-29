/// GraphRAG Backend Selection and Configuration
///
/// This module provides automatic backend selection based on device capabilities
/// and configuration options for LiteRT-LM integration.
library;

import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

import '../pigeon.g.dart';

/// Backend options for GraphRAG operations
///
/// The backend affects:
/// - Entity extraction inference speed
/// - Embedding generation speed
/// - Query response time
/// - Context window size (NPU has reduced context)
enum GraphRAGBackend {
  /// Automatic selection based on device capabilities
  /// Priority: NPU > GPU > CPU
  auto,

  /// Force CPU backend
  /// - Available on all platforms
  /// - Slowest but most compatible
  /// - Full context window support
  cpu,

  /// Force GPU backend
  /// - Available on all platforms
  /// - 7-8x faster prefill than CPU
  /// - Full context window support
  gpu,

  /// Force NPU backend (Android only)
  /// - Requires physical device with Qualcomm/MediaTek/Tensor chipset
  /// - 24x faster prefill than CPU
  /// - Reduced context window (1280 vs 4096)
  /// - LiteRT-LM Early Access Program required
  npu,
}

/// Converts GraphRAGBackend to platform PreferredBackend
PreferredBackend toPreferredBackend(GraphRAGBackend backend) {
  return switch (backend) {
    GraphRAGBackend.auto => PreferredBackend.gpu, // Default to GPU for auto
    GraphRAGBackend.cpu => PreferredBackend.cpu,
    GraphRAGBackend.gpu => PreferredBackend.gpu,
    GraphRAGBackend.npu => PreferredBackend.npu,
  };
}

/// Extended configuration for GraphRAG with LiteRT-LM features
class GraphRAGExtendedConfig {
  /// Preferred backend for inference
  /// Use [GraphRAGBackend.auto] for automatic selection based on device
  final GraphRAGBackend preferredBackend;

  /// Enable native function calling for structured extraction
  /// Requires FunctionGemma or Gemma-3n models with .litertlm format
  /// Falls back to prompt-based extraction if unavailable
  final bool enableFunctionCalling;

  /// Maximum context tokens to use
  /// Will be clamped to backend-specific limits
  /// NPU: max 1280, CPU/GPU: max 4096
  final int maxContextTokens;

  /// Enable model caching for faster reloads
  /// First load: ~10s, subsequent loads: ~1-2s
  final bool enableCacheDir;

  /// Cache directory path (optional)
  /// If null, uses default app support directory
  final String? cacheDirectoryPath;

  /// Enable NPU detection in auto mode
  /// Set to false if you don't have Early Access Program access
  final bool enableNPUDetection;

  /// Log performance metrics for debugging
  final bool enablePerformanceLogging;

  const GraphRAGExtendedConfig({
    this.preferredBackend = GraphRAGBackend.auto,
    this.enableFunctionCalling = true,
    this.maxContextTokens = 4096,
    this.enableCacheDir = true,
    this.cacheDirectoryPath,
    this.enableNPUDetection = false, // Off by default - requires Early Access
    this.enablePerformanceLogging = false,
  });

  /// Create config optimized for speed (NPU/GPU preferred)
  factory GraphRAGExtendedConfig.performance() {
    return const GraphRAGExtendedConfig(
      preferredBackend: GraphRAGBackend.auto,
      enableFunctionCalling: true,
      enableCacheDir: true,
      enableNPUDetection: true,
    );
  }

  /// Create config optimized for compatibility (CPU, all features)
  factory GraphRAGExtendedConfig.compatible() {
    return const GraphRAGExtendedConfig(
      preferredBackend: GraphRAGBackend.cpu,
      enableFunctionCalling: false,
      maxContextTokens: 4096,
      enableCacheDir: true,
      enableNPUDetection: false,
    );
  }

  /// Create config for emulator testing
  factory GraphRAGExtendedConfig.emulator() {
    return const GraphRAGExtendedConfig(
      preferredBackend: GraphRAGBackend.cpu,
      enableFunctionCalling: true,
      maxContextTokens: 4096,
      enableCacheDir: true,
      enableNPUDetection: false, // NPU not available on emulator
      enablePerformanceLogging: true,
    );
  }

  GraphRAGExtendedConfig copyWith({
    GraphRAGBackend? preferredBackend,
    bool? enableFunctionCalling,
    int? maxContextTokens,
    bool? enableCacheDir,
    String? cacheDirectoryPath,
    bool? enableNPUDetection,
    bool? enablePerformanceLogging,
  }) {
    return GraphRAGExtendedConfig(
      preferredBackend: preferredBackend ?? this.preferredBackend,
      enableFunctionCalling: enableFunctionCalling ?? this.enableFunctionCalling,
      maxContextTokens: maxContextTokens ?? this.maxContextTokens,
      enableCacheDir: enableCacheDir ?? this.enableCacheDir,
      cacheDirectoryPath: cacheDirectoryPath ?? this.cacheDirectoryPath,
      enableNPUDetection: enableNPUDetection ?? this.enableNPUDetection,
      enablePerformanceLogging: enablePerformanceLogging ?? this.enablePerformanceLogging,
    );
  }
}

/// Abstract interface for device info - allows mocking in tests
abstract class DeviceInfoProvider {
  Future<bool> isPhysicalDevice();
  Future<String> getModel();
  Future<String> getHardware();
  Future<String> getBoard();
  Future<String> getManufacturer();
  Future<int> getSdkInt();
}

/// Real implementation using device_info_plus
class RealDeviceInfoProvider implements DeviceInfoProvider {
  final DeviceInfoPlugin _plugin;
  AndroidDeviceInfo? _cachedAndroidInfo;

  RealDeviceInfoProvider([DeviceInfoPlugin? plugin])
      : _plugin = plugin ?? DeviceInfoPlugin();

  Future<AndroidDeviceInfo> _getAndroidInfo() async {
    return _cachedAndroidInfo ??= await _plugin.androidInfo;
  }

  @override
  Future<bool> isPhysicalDevice() async {
    if (!Platform.isAndroid) return true;
    return (await _getAndroidInfo()).isPhysicalDevice;
  }

  @override
  Future<String> getModel() async {
    if (!Platform.isAndroid) return '';
    return (await _getAndroidInfo()).model;
  }

  @override
  Future<String> getHardware() async {
    if (!Platform.isAndroid) return '';
    return (await _getAndroidInfo()).hardware;
  }

  @override
  Future<String> getBoard() async {
    if (!Platform.isAndroid) return '';
    return (await _getAndroidInfo()).board;
  }

  @override
  Future<String> getManufacturer() async {
    if (!Platform.isAndroid) return '';
    return (await _getAndroidInfo()).manufacturer;
  }

  @override
  Future<int> getSdkInt() async {
    if (!Platform.isAndroid) return 0;
    return (await _getAndroidInfo()).version.sdkInt;
  }
}

/// Detects optimal backend based on device capabilities
///
/// Supports cascading fallback: NPU -> GPU -> CPU
class DeviceCapabilityDetector {
  final DeviceInfoProvider _deviceInfo;
  
  /// If true, use device info provider for platform detection instead of dart:io
  /// This allows testing Android behavior on non-Android platforms
  final bool _useProviderForPlatformCheck;

  /// Cached detection result
  GraphRAGBackend? _cachedBackend;

  /// Known NPU-capable device patterns
  /// These devices have specialized AI hardware supported by LiteRT-LM
  static const _npuCapableModelPatterns = [
    // Samsung Galaxy S25 series (Snapdragon 8 Elite)
    'sm-s931', 'sm-s936', 'sm-s938', 's25',
    // Samsung Galaxy S24 series (Snapdragon 8 Gen 3 / Exynos 2400)
    'sm-s921', 'sm-s926', 'sm-s928', 's24',
    // Google Pixel 9 series (Tensor G4)
    'pixel 9',
    // Google Pixel 8 series (Tensor G3)
    'pixel 8',
  ];

  /// Known NPU-capable chipset patterns
  static const _npuCapableChipsets = [
    'snapdragon 8 gen 3',
    'snapdragon 8 elite',
    'exynos 2400',
    'tensor g4',
    'tensor g3',
    'dimensity 9300',
    'dimensity 9400',
  ];

  DeviceCapabilityDetector([DeviceInfoProvider? deviceInfo])
      : _deviceInfo = deviceInfo ?? RealDeviceInfoProvider(),
        _useProviderForPlatformCheck = deviceInfo != null;

  /// Create with custom device info provider (for testing)
  /// When using a custom provider, platform checks use the provider data
  factory DeviceCapabilityDetector.withProvider(DeviceInfoProvider provider) {
    return DeviceCapabilityDetector(provider);
  }

  /// Detect optimal backend for the current device
  ///
  /// Returns [GraphRAGBackend.npu] for physical devices with NPU support,
  /// [GraphRAGBackend.gpu] for most devices, or [GraphRAGBackend.cpu] as fallback.
  ///
  /// Set [enableNPU] to false if you don't have LiteRT-LM Early Access.
  Future<GraphRAGBackend> detectOptimalBackend({
    bool enableNPU = false,
  }) async {
    // Return cached result if available
    if (_cachedBackend != null) {
      return _cachedBackend!;
    }

    // When using custom provider (testing), assume Android platform behavior
    final isAndroidPlatform = _useProviderForPlatformCheck || Platform.isAndroid;
    
    if (isAndroidPlatform) {
      // Check for NPU support if enabled
      if (enableNPU && await _isNPUCapable()) {
        _cachedBackend = GraphRAGBackend.npu;
        return GraphRAGBackend.npu;
      }

      // GPU is generally faster than CPU on Android
      _cachedBackend = GraphRAGBackend.gpu;
      return GraphRAGBackend.gpu;
    }

    // Desktop platforms: GPU preferred
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      _cachedBackend = GraphRAGBackend.gpu;
      return GraphRAGBackend.gpu;
    }

    // Fallback to CPU
    _cachedBackend = GraphRAGBackend.cpu;
    return GraphRAGBackend.cpu;
  }

  /// Check if device has NPU hardware
  ///
  /// Returns true for devices known to have NPU support with LiteRT-LM.
  /// Note: Actual NPU availability depends on Early Access Program enrollment.
  Future<bool> _isNPUCapable() async {
    // Must be physical device
    if (!await _deviceInfo.isPhysicalDevice()) {
      return false;
    }

    final model = (await _deviceInfo.getModel()).toLowerCase();
    final hardware = (await _deviceInfo.getHardware()).toLowerCase();
    final board = (await _deviceInfo.getBoard()).toLowerCase();

    // Check device model patterns
    for (final pattern in _npuCapableModelPatterns) {
      if (model.contains(pattern)) {
        return true;
      }
    }

    // Check chipset/hardware patterns
    for (final chipset in _npuCapableChipsets) {
      if (hardware.contains(chipset) || board.contains(chipset)) {
        return true;
      }
    }

    return false;
  }

  /// Check if running on an emulator
  Future<bool> isEmulator() async {
    final isAndroidPlatform = _useProviderForPlatformCheck || Platform.isAndroid;
    if (isAndroidPlatform) {
      return !await _deviceInfo.isPhysicalDevice();
    }
    // For non-Android platforms, assume physical device
    return false;
  }

  /// Get device info for debugging
  Future<Map<String, dynamic>> getDeviceInfo() async {
    final isAndroidPlatform = _useProviderForPlatformCheck || Platform.isAndroid;
    if (isAndroidPlatform) {
      return {
        'model': await _deviceInfo.getModel(),
        'manufacturer': await _deviceInfo.getManufacturer(),
        'hardware': await _deviceInfo.getHardware(),
        'board': await _deviceInfo.getBoard(),
        'isPhysicalDevice': await _deviceInfo.isPhysicalDevice(),
        'sdkInt': await _deviceInfo.getSdkInt(),
        'npuCapable': await _isNPUCapable(),
      };
    }

    return {'platform': Platform.operatingSystem};
  }

  /// Clear cached detection results
  void clearCache() {
    _cachedBackend = null;
  }
}

/// Result of backend initialization attempt
class BackendInitResult {
  final PreferredBackend backend;
  final bool success;
  final String? errorMessage;
  final List<PreferredBackend> attemptedBackends;

  const BackendInitResult({
    required this.backend,
    required this.success,
    this.errorMessage,
    this.attemptedBackends = const [],
  });

  @override
  String toString() {
    if (success) {
      return 'BackendInitResult(backend: $backend, success: true)';
    }
    return 'BackendInitResult(backend: $backend, success: false, error: $errorMessage, attempted: $attemptedBackends)';
  }
}

/// Handles cascading backend fallback: NPU -> GPU -> CPU
///
/// Attempts to initialize with the preferred backend, falling back
/// to less capable backends on error.
class BackendFallbackManager {
  final DeviceCapabilityDetector _detector;
  final bool _enablePerformanceLogging;

  BackendFallbackManager({
    DeviceCapabilityDetector? detector,
    bool enablePerformanceLogging = false,
  })  : _detector = detector ?? DeviceCapabilityDetector(),
        _enablePerformanceLogging = enablePerformanceLogging;

  /// Get ordered list of backends to try based on preference
  List<PreferredBackend> _getBackendFallbackOrder(GraphRAGBackend preferred) {
    return switch (preferred) {
      GraphRAGBackend.npu => [
          PreferredBackend.npu,
          PreferredBackend.gpu,
          PreferredBackend.cpu,
        ],
      GraphRAGBackend.gpu => [
          PreferredBackend.gpu,
          PreferredBackend.cpu,
        ],
      GraphRAGBackend.cpu => [
          PreferredBackend.cpu,
        ],
      GraphRAGBackend.auto => [
          PreferredBackend.gpu,
          PreferredBackend.cpu,
        ],
    };
  }

  /// Initialize backend with cascading fallback
  ///
  /// [preferredBackend] - The desired backend
  /// [initCallback] - Function that attempts to initialize with a backend.
  ///                  Returns true on success, throws on failure.
  /// [enableNPU] - Whether NPU detection is enabled
  ///
  /// Returns the successfully initialized backend and attempt history.
  Future<BackendInitResult> initializeWithFallback({
    required GraphRAGBackend preferredBackend,
    required Future<bool> Function(PreferredBackend backend) initCallback,
    bool enableNPU = false,
  }) async {
    // Resolve 'auto' to actual backend
    final resolvedBackend = preferredBackend == GraphRAGBackend.auto
        ? await _detector.detectOptimalBackend(enableNPU: enableNPU)
        : preferredBackend;

    final fallbackOrder = _getBackendFallbackOrder(resolvedBackend);
    final attemptedBackends = <PreferredBackend>[];
    String? lastError;

    for (final backend in fallbackOrder) {
      attemptedBackends.add(backend);

      try {
        if (_enablePerformanceLogging) {
          debugPrint('BackendFallbackManager: Attempting $backend...');
        }

        final success = await initCallback(backend);

        if (success) {
          if (_enablePerformanceLogging) {
            debugPrint('BackendFallbackManager: Successfully initialized $backend');
            if (attemptedBackends.length > 1) {
              debugPrint(
                  'BackendFallbackManager: Fallback chain: ${attemptedBackends.join(" -> ")}');
            }
          }

          return BackendInitResult(
            backend: backend,
            success: true,
            attemptedBackends: attemptedBackends,
          );
        }
      } catch (e) {
        lastError = e.toString();
        if (_enablePerformanceLogging) {
          debugPrint(
              'BackendFallbackManager: $backend failed: $lastError, trying next...');
        }
        // Continue to next backend in fallback order
      }
    }

    // All backends failed
    return BackendInitResult(
      backend: PreferredBackend.cpu,
      success: false,
      errorMessage: 'All backends failed. Last error: $lastError',
      attemptedBackends: attemptedBackends,
    );
  }
}

/// Manages context window sizes based on backend and model
class ContextWindowManager {
  /// Context window limits per backend and model
  /// NPU currently has reduced context due to hardware constraints
  static const _contextLimits = <PreferredBackend, Map<String, int>>{
    PreferredBackend.cpu: {
      'gemma3-1b': 4096,
      'gemma-3n-e2b': 4096,
      'gemma-3n-e4b': 4096,
      'functiongemma': 1024,
      'default': 4096,
    },
    PreferredBackend.gpu: {
      'gemma3-1b': 4096,
      'gemma-3n-e2b': 4096,
      'gemma-3n-e4b': 4096,
      'functiongemma': 1024,
      'default': 4096,
    },
    PreferredBackend.npu: {
      'gemma3-1b': 1280,
      'gemma-3n-e2b': 1280,
      'gemma-3n-e4b': 1280,
      'functiongemma': 1024,
      'default': 1280,
    },
  };

  /// Get optimal context size for the given backend and model
  ///
  /// [backend] - The inference backend
  /// [modelId] - Model identifier (e.g., 'gemma3-1b')
  /// [requestedSize] - Desired context size (will be clamped to limit)
  static int getOptimalContextSize({
    required PreferredBackend backend,
    String? modelId,
    int requestedSize = 4096,
  }) {
    final limits =
        _contextLimits[backend] ?? _contextLimits[PreferredBackend.cpu]!;
    final maxForModel = limits[modelId?.toLowerCase()] ?? limits['default']!;

    // Return minimum of requested and maximum allowed
    return requestedSize < maxForModel ? requestedSize : maxForModel;
  }

  /// Get optimal chunk size for document processing
  ///
  /// Reserves ~30% of context for system prompt + output generation
  static int getOptimalChunkSize(int contextSize) {
    return (contextSize * 0.7).toInt();
  }

  /// Get maximum chunks that fit in context
  ///
  /// [contextSize] - Available context tokens
  /// [avgChunkTokens] - Average tokens per chunk
  /// [reserveForPrompt] - Tokens to reserve for system prompt/query
  static int getMaxChunks({
    required int contextSize,
    int avgChunkTokens = 200,
    int reserveForPrompt = 500,
  }) {
    final available = contextSize - reserveForPrompt;
    if (available <= 0) return 0;
    return (available / avgChunkTokens).floor();
  }

  /// Check if context size is sufficient for global query
  ///
  /// Global queries require more context for map-reduce operations
  static bool isSufficientForGlobalQuery(int contextSize) {
    // Global queries need at least 2048 tokens for effective map-reduce
    return contextSize >= 2048;
  }
}
