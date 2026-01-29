import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gemma/rag/graph_rag_config.dart';
import 'package:flutter_gemma/pigeon.g.dart';

/// Mock device info provider for testing
class MockDeviceInfoProvider implements DeviceInfoProvider {
  final bool _isPhysical;
  final String _model;
  final String _hardware;
  final String _board;
  final String _manufacturer;
  final int _sdkInt;

  MockDeviceInfoProvider({
    bool isPhysicalDevice = true,
    String model = 'Generic Device',
    String hardware = 'generic',
    String board = 'generic',
    String manufacturer = 'Generic',
    int sdkInt = 34,
  })  : _isPhysical = isPhysicalDevice,
        _model = model,
        _hardware = hardware,
        _board = board,
        _manufacturer = manufacturer,
        _sdkInt = sdkInt;

  /// Factory for Samsung Galaxy S25 (Snapdragon 8 Elite - NPU capable)
  factory MockDeviceInfoProvider.galaxyS25() => MockDeviceInfoProvider(
        isPhysicalDevice: true,
        model: 'SM-S931B',
        hardware: 'qcom',
        board: 'kona',
        manufacturer: 'samsung',
        sdkInt: 35,
      );

  /// Factory for Pixel 9 (Tensor G4 - NPU capable)
  factory MockDeviceInfoProvider.pixel9() => MockDeviceInfoProvider(
        isPhysicalDevice: true,
        model: 'Pixel 9 Pro',
        hardware: 'tensor g4',
        board: 'zuma',
        manufacturer: 'Google',
        sdkInt: 35,
      );

  /// Factory for emulator
  factory MockDeviceInfoProvider.emulator() => MockDeviceInfoProvider(
        isPhysicalDevice: false,
        model: 'sdk_gphone64_x86_64',
        hardware: 'ranchu',
        board: 'goldfish_x86_64',
        manufacturer: 'Google',
        sdkInt: 34,
      );

  /// Factory for older device without NPU
  factory MockDeviceInfoProvider.olderDevice() => MockDeviceInfoProvider(
        isPhysicalDevice: true,
        model: 'Pixel 5',
        hardware: 'redfin',
        board: 'redfin',
        manufacturer: 'Google',
        sdkInt: 33,
      );

  @override
  Future<bool> isPhysicalDevice() async => _isPhysical;

  @override
  Future<String> getModel() async => _model;

  @override
  Future<String> getHardware() async => _hardware;

  @override
  Future<String> getBoard() async => _board;

  @override
  Future<String> getManufacturer() async => _manufacturer;

  @override
  Future<int> getSdkInt() async => _sdkInt;
}

void main() {
  group('DeviceCapabilityDetector', () {
    test('detects NPU capability on Galaxy S25', () async {
      final detector = DeviceCapabilityDetector.withProvider(
        MockDeviceInfoProvider.galaxyS25(),
      );

      final backend =
          await detector.detectOptimalBackend(enableNPU: true);

      expect(backend, equals(GraphRAGBackend.npu));
    });

    test('detects NPU capability on Pixel 9', () async {
      final detector = DeviceCapabilityDetector.withProvider(
        MockDeviceInfoProvider.pixel9(),
      );

      final backend =
          await detector.detectOptimalBackend(enableNPU: true);

      expect(backend, equals(GraphRAGBackend.npu));
    });

    test('returns GPU for emulator even when NPU enabled', () async {
      final detector = DeviceCapabilityDetector.withProvider(
        MockDeviceInfoProvider.emulator(),
      );

      final backend =
          await detector.detectOptimalBackend(enableNPU: true);

      // Emulator should get GPU since NPU not available
      expect(backend, equals(GraphRAGBackend.gpu));
    });

    test('returns GPU when NPU detection disabled', () async {
      final detector = DeviceCapabilityDetector.withProvider(
        MockDeviceInfoProvider.galaxyS25(),
      );

      final backend =
          await detector.detectOptimalBackend(enableNPU: false);

      expect(backend, equals(GraphRAGBackend.gpu));
    });

    test('returns GPU for older device without NPU', () async {
      final detector = DeviceCapabilityDetector.withProvider(
        MockDeviceInfoProvider.olderDevice(),
      );

      final backend =
          await detector.detectOptimalBackend(enableNPU: true);

      expect(backend, equals(GraphRAGBackend.gpu));
    });

    test('caches detection result', () async {
      final detector = DeviceCapabilityDetector.withProvider(
        MockDeviceInfoProvider.galaxyS25(),
      );

      // First call
      final backend1 =
          await detector.detectOptimalBackend(enableNPU: true);

      // Second call should return cached result
      final backend2 =
          await detector.detectOptimalBackend(enableNPU: true);

      expect(backend1, equals(backend2));
      expect(backend1, equals(GraphRAGBackend.npu));
    });

    test('clearCache resets cached result', () async {
      final mockProvider = MockDeviceInfoProvider.galaxyS25();
      final detector = DeviceCapabilityDetector.withProvider(mockProvider);

      await detector.detectOptimalBackend(enableNPU: true);
      detector.clearCache();

      // After clear, should detect again
      final backend =
          await detector.detectOptimalBackend(enableNPU: false);

      expect(backend, equals(GraphRAGBackend.gpu));
    });

    test('isEmulator returns true for emulator', () async {
      final detector = DeviceCapabilityDetector.withProvider(
        MockDeviceInfoProvider.emulator(),
      );

      expect(await detector.isEmulator(), isTrue);
    });

    test('isEmulator returns false for physical device', () async {
      final detector = DeviceCapabilityDetector.withProvider(
        MockDeviceInfoProvider.galaxyS25(),
      );

      expect(await detector.isEmulator(), isFalse);
    });

    test('getDeviceInfo returns device information', () async {
      final detector = DeviceCapabilityDetector.withProvider(
        MockDeviceInfoProvider.pixel9(),
      );

      final info = await detector.getDeviceInfo();

      expect(info['model'], equals('Pixel 9 Pro'));
      expect(info['manufacturer'], equals('Google'));
      expect(info['isPhysicalDevice'], isTrue);
    });
  });

  group('BackendFallbackManager', () {
    test('succeeds with first backend when available', () async {
      final detector = DeviceCapabilityDetector.withProvider(
        MockDeviceInfoProvider.galaxyS25(),
      );
      final manager = BackendFallbackManager(detector: detector);

      final result = await manager.initializeWithFallback(
        preferredBackend: GraphRAGBackend.npu,
        initCallback: (backend) async {
          // All backends succeed
          return true;
        },
        enableNPU: true,
      );

      expect(result.success, isTrue);
      expect(result.backend, equals(PreferredBackend.npu));
      expect(result.attemptedBackends.length, equals(1));
    });

    test('falls back to GPU when NPU fails', () async {
      final detector = DeviceCapabilityDetector.withProvider(
        MockDeviceInfoProvider.galaxyS25(),
      );
      final manager = BackendFallbackManager(detector: detector);

      final result = await manager.initializeWithFallback(
        preferredBackend: GraphRAGBackend.npu,
        initCallback: (backend) async {
          if (backend == PreferredBackend.npu) {
            throw Exception('NPU not available');
          }
          return true;
        },
        enableNPU: true,
      );

      expect(result.success, isTrue);
      expect(result.backend, equals(PreferredBackend.gpu));
      expect(result.attemptedBackends,
          containsAll([PreferredBackend.npu, PreferredBackend.gpu]));
    });

    test('falls back to CPU when GPU also fails', () async {
      final detector = DeviceCapabilityDetector.withProvider(
        MockDeviceInfoProvider.galaxyS25(),
      );
      final manager = BackendFallbackManager(detector: detector);

      final result = await manager.initializeWithFallback(
        preferredBackend: GraphRAGBackend.npu,
        initCallback: (backend) async {
          if (backend == PreferredBackend.npu ||
              backend == PreferredBackend.gpu) {
            throw Exception('Backend not available');
          }
          return true;
        },
        enableNPU: true,
      );

      expect(result.success, isTrue);
      expect(result.backend, equals(PreferredBackend.cpu));
      expect(result.attemptedBackends.length, equals(3));
    });

    test('returns failure when all backends fail', () async {
      final detector = DeviceCapabilityDetector.withProvider(
        MockDeviceInfoProvider.galaxyS25(),
      );
      final manager = BackendFallbackManager(detector: detector);

      final result = await manager.initializeWithFallback(
        preferredBackend: GraphRAGBackend.auto,
        initCallback: (backend) async {
          throw Exception('All backends fail');
        },
      );

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('All backends failed'));
      expect(result.attemptedBackends.isNotEmpty, isTrue);
    });

    test('auto mode resolves to GPU for emulator', () async {
      final detector = DeviceCapabilityDetector.withProvider(
        MockDeviceInfoProvider.emulator(),
      );
      final manager = BackendFallbackManager(detector: detector);

      final result = await manager.initializeWithFallback(
        preferredBackend: GraphRAGBackend.auto,
        initCallback: (backend) async => true,
        enableNPU: true,
      );

      expect(result.success, isTrue);
      expect(result.backend, equals(PreferredBackend.gpu));
    });
  });

  group('ContextWindowManager', () {
    test('returns full context for CPU backend', () {
      final size = ContextWindowManager.getOptimalContextSize(
        backend: PreferredBackend.cpu,
        requestedSize: 4096,
      );

      expect(size, equals(4096));
    });

    test('returns reduced context for NPU backend', () {
      final size = ContextWindowManager.getOptimalContextSize(
        backend: PreferredBackend.npu,
        requestedSize: 4096,
      );

      expect(size, equals(1280)); // NPU limit
    });

    test('clamps to model-specific limits', () {
      final size = ContextWindowManager.getOptimalContextSize(
        backend: PreferredBackend.cpu,
        modelId: 'functiongemma',
        requestedSize: 4096,
      );

      expect(size, equals(1024)); // FunctionGemma limit
    });

    test('respects requested size when smaller than limit', () {
      final size = ContextWindowManager.getOptimalContextSize(
        backend: PreferredBackend.cpu,
        requestedSize: 2048,
      );

      expect(size, equals(2048));
    });

    test('calculates optimal chunk size', () {
      final chunkSize = ContextWindowManager.getOptimalChunkSize(4096);

      // Should be ~70% of context
      expect(chunkSize, equals((4096 * 0.7).toInt()));
    });

    test('calculates max chunks correctly', () {
      final maxChunks = ContextWindowManager.getMaxChunks(
        contextSize: 4096,
        avgChunkTokens: 200,
        reserveForPrompt: 500,
      );

      // (4096 - 500) / 200 = 17
      expect(maxChunks, equals(17));
    });

    test('reports NPU insufficient for global queries', () {
      final sufficient = ContextWindowManager.isSufficientForGlobalQuery(1280);

      expect(sufficient, isFalse);
    });

    test('reports CPU sufficient for global queries', () {
      final sufficient = ContextWindowManager.isSufficientForGlobalQuery(4096);

      expect(sufficient, isTrue);
    });
  });

  group('GraphRAGExtendedConfig', () {
    test('default config has sensible defaults', () {
      const config = GraphRAGExtendedConfig();

      expect(config.preferredBackend, equals(GraphRAGBackend.auto));
      expect(config.enableFunctionCalling, isTrue);
      expect(config.maxContextTokens, equals(4096));
      expect(config.enableCacheDir, isTrue);
      expect(config.enableNPUDetection, isFalse); // Off by default
    });

    test('performance config enables NPU', () {
      final config = GraphRAGExtendedConfig.performance();

      expect(config.enableNPUDetection, isTrue);
      expect(config.enableCacheDir, isTrue);
    });

    test('compatible config uses CPU', () {
      final config = GraphRAGExtendedConfig.compatible();

      expect(config.preferredBackend, equals(GraphRAGBackend.cpu));
      expect(config.enableFunctionCalling, isFalse);
      expect(config.enableNPUDetection, isFalse);
    });

    test('emulator config disables NPU detection', () {
      final config = GraphRAGExtendedConfig.emulator();

      expect(config.preferredBackend, equals(GraphRAGBackend.cpu));
      expect(config.enableNPUDetection, isFalse);
      expect(config.enablePerformanceLogging, isTrue);
    });

    test('copyWith preserves other values', () {
      const original = GraphRAGExtendedConfig(
        preferredBackend: GraphRAGBackend.gpu,
        enableFunctionCalling: true,
        maxContextTokens: 2048,
      );

      final copied = original.copyWith(maxContextTokens: 4096);

      expect(copied.preferredBackend, equals(GraphRAGBackend.gpu));
      expect(copied.enableFunctionCalling, isTrue);
      expect(copied.maxContextTokens, equals(4096));
    });
  });

  group('toPreferredBackend conversion', () {
    test('converts auto to GPU', () {
      expect(
          toPreferredBackend(GraphRAGBackend.auto), equals(PreferredBackend.gpu));
    });

    test('converts cpu to CPU', () {
      expect(
          toPreferredBackend(GraphRAGBackend.cpu), equals(PreferredBackend.cpu));
    });

    test('converts gpu to GPU', () {
      expect(
          toPreferredBackend(GraphRAGBackend.gpu), equals(PreferredBackend.gpu));
    });

    test('converts npu to NPU', () {
      expect(
          toPreferredBackend(GraphRAGBackend.npu), equals(PreferredBackend.npu));
    });
  });
}
