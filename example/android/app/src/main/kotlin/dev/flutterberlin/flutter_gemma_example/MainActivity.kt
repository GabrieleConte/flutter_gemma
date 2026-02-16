package dev.flutterberlin.flutter_gemma_example

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private lateinit var testDataService: TestDataService

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Register test-data MethodChannel for the Settings tab buttons
        testDataService = TestDataService(this, flutterEngine)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (::testDataService.isInitialized) {
            testDataService.onPermissionsResult(requestCode, grantResults)
        }
    }
}
