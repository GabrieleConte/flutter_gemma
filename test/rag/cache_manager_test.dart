import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gemma/rag/graph/cache_manager.dart';

void main() {
  group('MockModelCacheManager', () {
    late MockModelCacheManager cacheManager;

    setUp(() {
      cacheManager = MockModelCacheManager();
    });

    test('returns cache path for new model', () async {
      final path = await cacheManager.getCacheDirectory('test-model');

      expect(path, equals('/mock/cache/test-model'));
      expect(cacheManager.missCount, equals(1));
    });

    test('returns cached path for existing model', () async {
      await cacheManager.getCacheDirectory('test-model');
      final path = await cacheManager.getCacheDirectory('test-model');

      expect(path, equals('/mock/cache/test-model'));
      expect(cacheManager.hitCount, equals(1));
      expect(cacheManager.missCount, equals(1));
    });

    test('hasCache returns false for new model', () async {
      final has = await cacheManager.hasCache('unknown');

      expect(has, isFalse);
    });

    test('hasCache returns true after getting directory', () async {
      await cacheManager.getCacheDirectory('test-model');
      final has = await cacheManager.hasCache('test-model');

      expect(has, isTrue);
    });

    test('clearCache removes model', () async {
      await cacheManager.getCacheDirectory('test-model');
      await cacheManager.clearCache('test-model');
      final has = await cacheManager.hasCache('test-model');

      expect(has, isFalse);
    });

    test('clearAllCaches removes all models', () async {
      await cacheManager.getCacheDirectory('model1');
      await cacheManager.getCacheDirectory('model2');
      await cacheManager.clearAllCaches();

      final models = cacheManager.getCachedModelIds();
      expect(models, isEmpty);
    });

    test('getStats returns correct statistics', () async {
      await cacheManager.getCacheDirectory('model1');
      await cacheManager.getCacheDirectory('model1');
      await cacheManager.getCacheDirectory('model2');

      final stats = cacheManager.getStats();

      expect(stats.totalEntries, equals(2));
      expect(stats.hitCount, equals(1));
      expect(stats.missCount, equals(2));
    });

    test('getCachedModelIds returns all models', () async {
      await cacheManager.getCacheDirectory('model1');
      await cacheManager.getCacheDirectory('model2');
      await cacheManager.getCacheDirectory('model3');

      final models = cacheManager.getCachedModelIds();

      expect(models, containsAll(['model1', 'model2', 'model3']));
    });
  });

  group('CacheStats', () {
    test('hitRate calculates correctly', () {
      const stats = CacheStats(
        totalEntries: 5,
        totalSizeBytes: 1000,
        hitCount: 8,
        missCount: 2,
      );

      expect(stats.hitRate, equals(0.8));
    });

    test('hitRate returns 0 when no accesses', () {
      const stats = CacheStats(
        totalEntries: 0,
        totalSizeBytes: 0,
        hitCount: 0,
        missCount: 0,
      );

      expect(stats.hitRate, equals(0.0));
    });

    test('formattedSize formats bytes correctly', () {
      expect(
        const CacheStats(
          totalEntries: 0,
          totalSizeBytes: 500,
          hitCount: 0,
          missCount: 0,
        ).formattedSize,
        equals('500 B'),
      );
    });

    test('formattedSize formats kilobytes correctly', () {
      expect(
        const CacheStats(
          totalEntries: 0,
          totalSizeBytes: 5120, // 5 KB
          hitCount: 0,
          missCount: 0,
        ).formattedSize,
        equals('5.0 KB'),
      );
    });

    test('formattedSize formats megabytes correctly', () {
      expect(
        const CacheStats(
          totalEntries: 0,
          totalSizeBytes: 5242880, // 5 MB
          hitCount: 0,
          missCount: 0,
        ).formattedSize,
        equals('5.0 MB'),
      );
    });

    test('formattedSize formats gigabytes correctly', () {
      expect(
        const CacheStats(
          totalEntries: 0,
          totalSizeBytes: 2147483648, // 2 GB
          hitCount: 0,
          missCount: 0,
        ).formattedSize,
        equals('2.00 GB'),
      );
    });

    test('toString includes relevant info', () {
      const stats = CacheStats(
        totalEntries: 5,
        totalSizeBytes: 1048576,
        hitCount: 80,
        missCount: 20,
      );

      final str = stats.toString();

      expect(str, contains('entries: 5'));
      expect(str, contains('1.0 MB'));
      expect(str, contains('80.0%'));
    });
  });

  group('CacheEntry', () {
    test('toJson and fromJson roundtrip', () {
      final entry = CacheEntry(
        modelId: 'test-model',
        cachePath: '/cache/test-model',
        createdAt: DateTime(2024, 1, 1, 12, 0),
        lastAccessedAt: DateTime(2024, 1, 2, 12, 0),
        sizeBytes: 1024,
        backendType: 'gpu',
      );

      final json = entry.toJson();
      final restored = CacheEntry.fromJson(json);

      expect(restored.modelId, equals(entry.modelId));
      expect(restored.cachePath, equals(entry.cachePath));
      expect(restored.sizeBytes, equals(entry.sizeBytes));
      expect(restored.backendType, equals(entry.backendType));
    });

    test('copyWith updates specified fields', () {
      final entry = CacheEntry(
        modelId: 'test-model',
        cachePath: '/cache/test-model',
        createdAt: DateTime(2024, 1, 1),
        lastAccessedAt: DateTime(2024, 1, 1),
        sizeBytes: 1024,
        backendType: 'gpu',
      );

      final updated = entry.copyWith(
        lastAccessedAt: DateTime(2024, 2, 1),
        sizeBytes: 2048,
      );

      expect(updated.modelId, equals('test-model'));
      expect(updated.sizeBytes, equals(2048));
      expect(updated.lastAccessedAt, equals(DateTime(2024, 2, 1)));
    });
  });

  group('WarmUpCacheManager', () {
    test('warmUp creates directories for specified models', () async {
      final delegate = MockModelCacheManager();
      final manager = WarmUpCacheManager(
        delegate: delegate,
        warmUpModels: ['model1', 'model2'],
      );

      await manager.warmUp();

      expect(await manager.hasCache('model1'), isTrue);
      expect(await manager.hasCache('model2'), isTrue);
    });

    test('warmUp only runs once', () async {
      final delegate = MockModelCacheManager();
      final manager = WarmUpCacheManager(
        delegate: delegate,
        warmUpModels: ['model1'],
      );

      await manager.warmUp();
      await manager.warmUp(); // Second call

      // Should still only have 1 miss (one getCacheDirectory call)
      expect(delegate.missCount, equals(1));
    });

    test('delegates getCacheDirectory to underlying manager', () async {
      final delegate = MockModelCacheManager();
      final manager = WarmUpCacheManager(delegate: delegate);

      final path = await manager.getCacheDirectory('test');

      expect(path, equals('/mock/cache/test'));
    });

    test('clearAllCaches resets warmUp state', () async {
      final delegate = MockModelCacheManager();
      final manager = WarmUpCacheManager(
        delegate: delegate,
        warmUpModels: ['model1'],
      );

      await manager.warmUp();
      final missCountAfterFirstWarmUp = delegate.missCount;
      
      await manager.clearAllCaches();
      // Note: clearAllCaches on MockModelCacheManager resets counters
      
      await manager.warmUp(); // Should work again
      
      // After clear, warmUp should run again causing another miss
      expect(missCountAfterFirstWarmUp, equals(1));
      expect(delegate.missCount, equals(1)); // Reset by clearAllCaches, then +1
    });
  });
}
