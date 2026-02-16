package dev.flutterberlin.flutter_gemma_example

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Register test-data MethodChannel for the Settings tab buttons
        TestDataService(this, flutterEngine)
    }
}
