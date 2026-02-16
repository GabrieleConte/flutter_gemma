import 'package:flutter/services.dart';

/// Dart wrapper around the native [TestDataService] MethodChannel.
///
/// Provides two operations used by the Settings tab:
///
/// 1. [resetTestGraph] — replaces the GraphRAG SQLite database with a
///    pre-built snapshot bundled as a Flutter asset.
///
/// 2. [uploadTestData] — populates Android content providers (Calendar,
///    Contacts, CallLog) and shared-storage directories with the
///    knowledge-base test files bundled as Flutter assets.
class TestDataService {
  static const _channel = MethodChannel('test_data_channel');

  /// Replace the running GraphRAG database with the bundled test snapshot.
  ///
  /// **Important:** The caller must close the GraphStore *before* calling
  /// this method and re-initialize it *after*.
  static Future<void> resetTestGraph() async {
    await _channel.invokeMethod<void>('resetTestGraph');
  }

  /// Upload all knowledge-base test data into the device.
  ///
  /// Returns a map with counts per data type:
  /// ```
  /// { "images": 15, "documents": 9, "events": 15,
  ///   "recurrentEvents": 5, "contacts": 2, "calls": 6 }
  /// ```
  static Future<Map<String, int>> uploadTestData() async {
    final result = await _channel.invokeMapMethod<String, dynamic>('uploadTestData');
    if (result == null) return {};
    return result.map((key, value) => MapEntry(key, value as int));
  }
}
