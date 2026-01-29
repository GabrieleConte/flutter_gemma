/// Model Cache Manager for GraphRAG
///
/// Provides caching functionality for LiteRT-LM models to enable
/// 5-10x faster reload times after initial model load.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Cache entry metadata
class CacheEntry {
  final String modelId;
  final String cachePath;
  final DateTime createdAt;
  final DateTime lastAccessedAt;
  final int sizeBytes;
  final String backendType;

  const CacheEntry({
    required this.modelId,
    required this.cachePath,
    required this.createdAt,
    required this.lastAccessedAt,
    required this.sizeBytes,
    required this.backendType,
  });

  Map<String, dynamic> toJson() => {
        'modelId': modelId,
        'cachePath': cachePath,
        'createdAt': createdAt.toIso8601String(),
        'lastAccessedAt': lastAccessedAt.toIso8601String(),
        'sizeBytes': sizeBytes,
        'backendType': backendType,
      };

  factory CacheEntry.fromJson(Map<String, dynamic> json) {
    return CacheEntry(
      modelId: json['modelId'] as String,
      cachePath: json['cachePath'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      lastAccessedAt: DateTime.parse(json['lastAccessedAt'] as String),
      sizeBytes: json['sizeBytes'] as int,
      backendType: json['backendType'] as String,
    );
  }

  CacheEntry copyWith({
    DateTime? lastAccessedAt,
    int? sizeBytes,
  }) {
    return CacheEntry(
      modelId: modelId,
      cachePath: cachePath,
      createdAt: createdAt,
      lastAccessedAt: lastAccessedAt ?? this.lastAccessedAt,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      backendType: backendType,
    );
  }
}

/// Cache statistics for monitoring
class CacheStats {
  final int totalEntries;
  final int totalSizeBytes;
  final int hitCount;
  final int missCount;
  final DateTime? oldestEntry;
  final DateTime? newestEntry;

  const CacheStats({
    required this.totalEntries,
    required this.totalSizeBytes,
    required this.hitCount,
    required this.missCount,
    this.oldestEntry,
    this.newestEntry,
  });

  double get hitRate =>
      hitCount + missCount > 0 ? hitCount / (hitCount + missCount) : 0.0;

  String get formattedSize {
    if (totalSizeBytes < 1024) return '$totalSizeBytes B';
    if (totalSizeBytes < 1024 * 1024) {
      return '${(totalSizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    if (totalSizeBytes < 1024 * 1024 * 1024) {
      return '${(totalSizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(totalSizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  String toString() => 'CacheStats(entries: $totalEntries, size: $formattedSize, '
      'hitRate: ${(hitRate * 100).toStringAsFixed(1)}%)';
}

/// Abstract cache manager interface for testability
abstract class ModelCacheManager {
  /// Get cache directory path for a model
  Future<String?> getCacheDirectory(String modelId);

  /// Check if cache exists for a model
  Future<bool> hasCache(String modelId);

  /// Clear cache for a specific model
  Future<void> clearCache(String modelId);

  /// Clear all cached models
  Future<void> clearAllCaches();

  /// Get cache statistics
  CacheStats getStats();

  /// Get all cached model IDs
  List<String> getCachedModelIds();
}

/// Production implementation of model cache manager
class LiteRTModelCacheManager implements ModelCacheManager {
  /// Custom cache directory (optional)
  final String? customCacheDirectory;

  /// Maximum cache size in bytes (default: 2GB)
  final int maxCacheSizeBytes;

  /// Maximum number of cached models (default: 5)
  final int maxCachedModels;

  /// Enable debug logging
  final bool enableLogging;

  /// Cached entries indexed by model ID
  final Map<String, CacheEntry> _entries = {};

  /// Cache hit/miss counters
  int _hitCount = 0;
  int _missCount = 0;

  /// Base cache directory (lazily initialized)
  String? _baseCacheDir;

  LiteRTModelCacheManager({
    this.customCacheDirectory,
    this.maxCacheSizeBytes = 2 * 1024 * 1024 * 1024, // 2GB
    this.maxCachedModels = 5,
    this.enableLogging = false,
  });

  @override
  Future<String?> getCacheDirectory(String modelId) async {
    // Check existing cache
    if (_entries.containsKey(modelId)) {
      _hitCount++;
      final entry = _entries[modelId]!;

      // Update last accessed time
      _entries[modelId] = entry.copyWith(lastAccessedAt: DateTime.now());

      if (enableLogging) {
        debugPrint('LiteRTModelCacheManager: Cache hit for $modelId');
      }

      // Verify cache directory still exists
      if (await Directory(entry.cachePath).exists()) {
        return entry.cachePath;
      } else {
        // Cache directory was deleted externally
        _entries.remove(modelId);
      }
    }

    _missCount++;

    // Create new cache directory
    final baseDir = await _getBaseCacheDirectory();
    if (baseDir == null) return null;

    // Ensure we don't exceed limits before creating new cache
    await _enforceLimit();

    final cacheDir = '$baseDir/$modelId';

    // Create the directory
    final dir = Directory(cacheDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    // Record the entry
    _entries[modelId] = CacheEntry(
      modelId: modelId,
      cachePath: cacheDir,
      createdAt: DateTime.now(),
      lastAccessedAt: DateTime.now(),
      sizeBytes: 0, // Will be updated when model loads
      backendType: 'unknown',
    );

    if (enableLogging) {
      debugPrint('LiteRTModelCacheManager: Created cache directory: $cacheDir');
    }

    return cacheDir;
  }

  @override
  Future<bool> hasCache(String modelId) async {
    if (!_entries.containsKey(modelId)) return false;

    final entry = _entries[modelId]!;
    final exists = await Directory(entry.cachePath).exists();

    if (!exists) {
      _entries.remove(modelId);
    }

    return exists;
  }

  @override
  Future<void> clearCache(String modelId) async {
    final entry = _entries.remove(modelId);
    if (entry == null) return;

    final dir = Directory(entry.cachePath);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      if (enableLogging) {
        debugPrint('LiteRTModelCacheManager: Cleared cache for $modelId');
      }
    }
  }

  @override
  Future<void> clearAllCaches() async {
    final baseDir = await _getBaseCacheDirectory();
    if (baseDir == null) return;

    final dir = Directory(baseDir);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      if (enableLogging) {
        debugPrint('LiteRTModelCacheManager: Cleared all caches');
      }
    }

    _entries.clear();
    _hitCount = 0;
    _missCount = 0;
  }

  @override
  CacheStats getStats() {
    final entries = _entries.values.toList();
    final totalSize = entries.fold<int>(0, (sum, e) => sum + e.sizeBytes);

    DateTime? oldest;
    DateTime? newest;

    for (final entry in entries) {
      if (oldest == null || entry.createdAt.isBefore(oldest)) {
        oldest = entry.createdAt;
      }
      if (newest == null || entry.createdAt.isAfter(newest)) {
        newest = entry.createdAt;
      }
    }

    return CacheStats(
      totalEntries: entries.length,
      totalSizeBytes: totalSize,
      hitCount: _hitCount,
      missCount: _missCount,
      oldestEntry: oldest,
      newestEntry: newest,
    );
  }

  @override
  List<String> getCachedModelIds() {
    return _entries.keys.toList();
  }

  /// Update cache size after model loads
  Future<void> updateCacheSize(String modelId) async {
    final entry = _entries[modelId];
    if (entry == null) return;

    final dir = Directory(entry.cachePath);
    if (!await dir.exists()) return;

    // Calculate directory size
    int totalSize = 0;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        totalSize += await entity.length();
      }
    }

    _entries[modelId] = entry.copyWith(sizeBytes: totalSize);

    if (enableLogging) {
      final sizeMB = (totalSize / (1024 * 1024)).toStringAsFixed(1);
      debugPrint('LiteRTModelCacheManager: Cache size for $modelId: $sizeMB MB');
    }

    // Check if we need to evict caches after size update
    await _enforceLimit();
  }

  /// Get or create base cache directory
  Future<String?> _getBaseCacheDirectory() async {
    if (_baseCacheDir != null) return _baseCacheDir;

    if (customCacheDirectory != null) {
      _baseCacheDir = customCacheDirectory;
      return _baseCacheDir;
    }

    try {
      if (Platform.isAndroid || Platform.isIOS) {
        final appDir = await getApplicationSupportDirectory();
        _baseCacheDir = '${appDir.path}/litert_cache';
      } else if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
        final appDir = await getApplicationSupportDirectory();
        _baseCacheDir = '${appDir.path}/litert_cache';
      } else {
        // Web - no file system caching
        return null;
      }

      // Ensure base directory exists
      final dir = Directory(_baseCacheDir!);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      return _baseCacheDir;
    } catch (e) {
      debugPrint('LiteRTModelCacheManager: Failed to get cache directory: $e');
      return null;
    }
  }

  /// Enforce cache limits by evicting oldest entries
  Future<void> _enforceLimit() async {
    // Enforce model count limit
    while (_entries.length > maxCachedModels) {
      await _evictOldest();
    }

    // Enforce size limit
    int totalSize = _entries.values.fold(0, (sum, e) => sum + e.sizeBytes);
    while (totalSize > maxCacheSizeBytes && _entries.isNotEmpty) {
      await _evictOldest();
      totalSize = _entries.values.fold(0, (sum, e) => sum + e.sizeBytes);
    }
  }

  /// Evict the least recently used cache entry
  Future<void> _evictOldest() async {
    if (_entries.isEmpty) return;

    // Find least recently accessed entry
    CacheEntry? oldest;
    String? oldestId;

    for (final entry in _entries.entries) {
      if (oldest == null ||
          entry.value.lastAccessedAt.isBefore(oldest.lastAccessedAt)) {
        oldest = entry.value;
        oldestId = entry.key;
      }
    }

    if (oldestId != null) {
      if (enableLogging) {
        debugPrint('LiteRTModelCacheManager: Evicting $oldestId (LRU)');
      }
      await clearCache(oldestId);
    }
  }
}

/// Mock cache manager for testing
class MockModelCacheManager implements ModelCacheManager {
  final Map<String, String> _caches = {};
  int hitCount = 0;
  int missCount = 0;

  @override
  Future<String?> getCacheDirectory(String modelId) async {
    if (_caches.containsKey(modelId)) {
      hitCount++;
      return _caches[modelId];
    }
    missCount++;
    final path = '/mock/cache/$modelId';
    _caches[modelId] = path;
    return path;
  }

  @override
  Future<bool> hasCache(String modelId) async {
    return _caches.containsKey(modelId);
  }

  @override
  Future<void> clearCache(String modelId) async {
    _caches.remove(modelId);
  }

  @override
  Future<void> clearAllCaches() async {
    _caches.clear();
    hitCount = 0;
    missCount = 0;
  }

  @override
  CacheStats getStats() {
    return CacheStats(
      totalEntries: _caches.length,
      totalSizeBytes: 0,
      hitCount: hitCount,
      missCount: missCount,
    );
  }

  @override
  List<String> getCachedModelIds() {
    return _caches.keys.toList();
  }
}

/// Cache manager that wraps another manager with warm-up support
class WarmUpCacheManager implements ModelCacheManager {
  final ModelCacheManager _delegate;
  final List<String> _warmUpModels;

  /// Whether warm-up has been completed
  bool _warmedUp = false;

  WarmUpCacheManager({
    required ModelCacheManager delegate,
    List<String>? warmUpModels,
  })  : _delegate = delegate,
        _warmUpModels = warmUpModels ?? [];

  /// Warm up caches for specified models
  /// Call this early in app lifecycle for faster first loads
  Future<void> warmUp() async {
    if (_warmedUp) return;

    for (final modelId in _warmUpModels) {
      await _delegate.getCacheDirectory(modelId);
    }

    _warmedUp = true;
  }

  @override
  Future<String?> getCacheDirectory(String modelId) {
    return _delegate.getCacheDirectory(modelId);
  }

  @override
  Future<bool> hasCache(String modelId) {
    return _delegate.hasCache(modelId);
  }

  @override
  Future<void> clearCache(String modelId) {
    return _delegate.clearCache(modelId);
  }

  @override
  Future<void> clearAllCaches() {
    _warmedUp = false;
    return _delegate.clearAllCaches();
  }

  @override
  CacheStats getStats() {
    return _delegate.getStats();
  }

  @override
  List<String> getCachedModelIds() {
    return _delegate.getCachedModelIds();
  }
}
