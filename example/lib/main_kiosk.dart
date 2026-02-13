import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_example/graph_rag_navigator.dart';

/// Kiosk-mode entry point for the GraphRAG demo.
///
/// Build & run:
///   flutter run -t lib/main_kiosk.dart
///   flutter build apk -t lib/main_kiosk.dart
///
/// This locks the app into a single-purpose kiosk:
///  - Portrait-only orientation
///  - Immersive sticky fullscreen (status bar + nav bar hidden)
///  - Back button blocked via PopScope
///  - Android Lock Task Mode (screen pinning) via MethodChannel
///
/// For fully unattended kiosk (no confirmation dialog), provision the device
/// as Device Owner before first launch:
///   adb shell dpm set-device-owner \
///     dev.flutterberlin.flutter_gemma_example/.KioskDeviceAdminReceiver
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock orientation to portrait
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  // Hide status bar and navigation bar (immersive sticky)
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  // Initialize Flutter Gemma
  await FlutterGemma.initialize(
    webStorageMode: WebStorageMode.cacheApi,
  );

  runApp(const KioskApp());
}

class KioskApp extends StatefulWidget {
  const KioskApp({super.key});

  @override
  State<KioskApp> createState() => _KioskAppState();
}

class _KioskAppState extends State<KioskApp> with WidgetsBindingObserver {
  static const _kioskChannel = MethodChannel('kiosk_mode');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Start lock task after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) => _startLockTask());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Re-apply immersive mode whenever the app resumes (e.g. after a system
  /// dialog briefly shows the bars).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  Future<void> _startLockTask() async {
    try {
      await _kioskChannel.invokeMethod('startLockTask');
      debugPrint('[Kiosk] Lock task started');
    } catch (e) {
      // Lock task may fail on emulators or non-provisioned devices
      debugPrint('[Kiosk] Lock task failed (expected on emulator): $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EpisTwin',
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: Colors.white),
          bodyMedium: TextStyle(color: Colors.white),
        ),
      ),
      themeMode: ThemeMode.dark,
      debugShowCheckedModeBanner: false,
      home: const PopScope(
        canPop: false,
        child: SafeArea(child: GraphRAGNavigator()),
      ),
    );
  }
}
