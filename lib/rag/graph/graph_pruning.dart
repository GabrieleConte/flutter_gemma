import 'package:flutter/foundation.dart';

import '../connectors/data_connector.dart';
import 'graph_repository.dart';

/// Result of a graph pruning operation.
class PruningResult {
  /// Entity IDs that were removed because their source data no longer exists.
  final List<String> removedStaleEntities;

  /// Entity IDs that were removed because they had no relationships.
  final List<String> removedOrphanEntities;

  const PruningResult({
    this.removedStaleEntities = const [],
    this.removedOrphanEntities = const [],
  });

  int get totalRemoved =>
      removedStaleEntities.length + removedOrphanEntities.length;

  @override
  String toString() =>
      'PruningResult(stale: ${removedStaleEntities.length}, '
      'orphans: ${removedOrphanEntities.length})';
}

/// Handles detection and removal of stale graph entities whose source data
/// has been deleted from the device, and cleanup of orphan nodes with no
/// relationships.
///
/// ## Stale entity detection
///
/// For each data source (contacts, calendar, photos, call log, documents),
/// a full fetch is performed to build the set of item IDs currently on the
/// device.  The corresponding entity IDs in the graph are computed using
/// the same deterministic formula used during indexing.  Any graph entity
/// whose ID is **not** in the current set is considered stale and deleted.
///
/// Native [GraphRepository.deleteEntity] already cascades deletions to
/// relationships and entity_communities rows.
///
/// ## Orphan node cleanup
///
/// After stale removals (or independently), orphan entities — nodes with
/// zero relationships — are detected and removed.  Structural nodes
/// (`SELF`, `HUB`) are always preserved.  The cleanup runs recursively
/// until no new orphans are found, since removing a node may leave its
/// ex-neighbours orphaned.
class GraphPruner {
  final GraphRepository repository;
  final ConnectorManager connectorManager;

  /// Entity types that are never pruned even if orphaned.
  static const _protectedTypes = {'SELF', 'HUB'};

  /// Mapping from connector `dataType` to the graph entity type it produces
  /// and a function that extracts the "name" used to build the entity ID.
  static const _connectorEntityTypeMap = {
    'contacts': 'PERSON',
    'calendar': 'EVENT',
    'photos': 'PHOTO',
    'callLog': 'PHONE_CALL',
    'documents': 'DOCUMENT',
  };

  GraphPruner({
    required this.repository,
    required this.connectorManager,
  });

  // ─── public API ────────────────────────────────────────────────────

  /// Run full pruning: stale entity removal + orphan cleanup.
  ///
  /// Returns a [PruningResult] summarising what was removed.
  Future<PruningResult> prune() async {
    final stale = await pruneStaleEntities();
    final orphans = await cleanupOrphanNodes();
    return PruningResult(
      removedStaleEntities: stale,
      removedOrphanEntities: orphans,
    );
  }

  /// Detect and remove graph entities whose source data no longer exists
  /// on the device.
  ///
  /// A full (non-incremental) fetch is performed per connector to build the
  /// current set of source items.  Graph entities of the corresponding type
  /// that do **not** map to any current source item are deleted.
  Future<List<String>> pruneStaleEntities() async {
    final removed = <String>[];

    for (final entry in _connectorEntityTypeMap.entries) {
      final connectorType = entry.key;
      final graphEntityType = entry.value;

      final connector = connectorManager.getConnector(connectorType);
      if (connector == null) continue;

      // Skip connectors without permission
      try {
        if (!await connector.hasRequiredPermissions()) continue;
      } catch (_) {
        continue;
      }

      try {
        final stale = await _pruneForDataSource(
          connector: connector,
          graphEntityType: graphEntityType,
        );
        removed.addAll(stale);
      } catch (e) {
        debugPrint('[GraphPruner] Error pruning $connectorType: $e');
      }
    }

    if (removed.isNotEmpty) {
      debugPrint('[GraphPruner] Removed ${removed.length} stale entities');
    }

    return removed;
  }

  /// Remove entities that have no relationships, excluding protected types.
  ///
  /// Runs recursively: removing a node may leave its former neighbours
  /// orphaned too, so we repeat until the graph is stable.
  Future<List<String>> cleanupOrphanNodes() async {
    final allRemoved = <String>[];

    // Iterate until no more orphans are found (fixed-point).
    while (true) {
      final orphans = await _findOrphanEntities();
      if (orphans.isEmpty) break;

      for (final entity in orphans) {
        try {
          await repository.deleteEntity(entity.id);
          allRemoved.add(entity.id);
        } catch (e) {
          debugPrint(
              '[GraphPruner] Error deleting orphan ${entity.id}: $e');
        }
      }

      debugPrint(
          '[GraphPruner] Removed ${orphans.length} orphan nodes, '
          'checking for new orphans…');
    }

    if (allRemoved.isNotEmpty) {
      debugPrint(
          '[GraphPruner] Orphan cleanup complete: '
          '${allRemoved.length} nodes removed');
    }

    return allRemoved;
  }

  // ─── private helpers ───────────────────────────────────────────────

  /// Prune stale entities for a single data source.
  Future<List<String>> _pruneForDataSource({
    required DataConnector connector,
    required String graphEntityType,
  }) async {
    // Full fetch (no `since` filter) to get every item currently on device.
    final currentItems = await connector.fetch();

    // Build the set of entity IDs that *should* exist.
    final currentEntityIds = <String>{};
    for (final item in currentItems) {
      final id = _computeEntityId(item, connector.dataType, graphEntityType);
      if (id != null) currentEntityIds.add(id);
    }

    // Get all graph entities of this type.
    final graphEntities =
        await repository.getEntitiesByType(graphEntityType);

    // Find stale: in graph but not in current device data.
    final staleIds = <String>[];
    for (final entity in graphEntities) {
      if (!currentEntityIds.contains(entity.id)) {
        staleIds.add(entity.id);
      }
    }

    // Delete stale entities (cascades to relationships via native layer).
    for (final id in staleIds) {
      try {
        await repository.deleteEntity(id);
        assert(() {
          debugPrint(
              '[GraphPruner] Deleted stale $graphEntityType: $id');
          return true;
        }());
      } catch (e) {
        debugPrint('[GraphPruner] Error deleting $id: $e');
      }
    }

    // Also prune child chunks for documents.
    if (graphEntityType == 'DOCUMENT' && staleIds.isNotEmpty) {
      await _pruneDocumentChunks(staleIds);
    }

    return staleIds;
  }

  /// Remove DOCUMENT_CHUNK entities whose parent document was deleted.
  Future<void> _pruneDocumentChunks(List<String> deletedDocumentIds) async {
    final chunks =
        await repository.getEntitiesByType('DOCUMENT_CHUNK');

    for (final chunk in chunks) {
      final parentId = chunk.metadata?['parentDocumentId']?.toString() ??
          chunk.metadata?['sourceId']?.toString();
      if (parentId != null && deletedDocumentIds.contains(parentId)) {
        try {
          await repository.deleteEntity(chunk.id);
          assert(() {
            debugPrint(
                '[GraphPruner] Deleted orphan chunk: ${chunk.id}');
            return true;
          }());
        } catch (e) {
          debugPrint(
              '[GraphPruner] Error deleting chunk ${chunk.id}: $e');
        }
      }
    }
  }

  /// Compute the expected graph entity ID for a source item, using the same
  /// deterministic formula as [BackgroundIndexingService._getPrimaryEntityId].
  String? _computeEntityId(
    dynamic item,
    String connectorDataType,
    String graphEntityType,
  ) {
    String? name;

    switch (connectorDataType) {
      case 'contacts':
        if (item is Contact) {
          name = item.fullName;
        } else if (item is Map<String, dynamic>) {
          name = (item['fullName'] ?? item['name'])?.toString();
        }
        break;
      case 'calendar':
        if (item is CalendarEvent) {
          name = item.title;
        } else if (item is Map<String, dynamic>) {
          name = item['title']?.toString();
        }
        break;
      case 'photos':
        if (item is Photo) {
          name = item.filename ?? item.id;
        } else if (item is Map<String, dynamic>) {
          name = (item['filename'] ?? item['name'] ?? item['id'])?.toString();
        }
        break;
      case 'callLog':
        if (item is PhoneCall) {
          if (item.contactName != null && item.contactName!.isNotEmpty) {
            name = 'Call with ${item.contactName}';
          } else if (item.phoneNumber.isNotEmpty) {
            name = 'Call ${item.phoneNumber}';
          } else {
            name = 'Call ${item.id}';
          }
        } else if (item is Map<String, dynamic>) {
          final contactName = item['contactName'] ?? item['name'];
          final phoneNumber = item['phoneNumber'] ?? item['number'];
          final callId = item['id']?.toString() ?? '';
          if (contactName != null &&
              contactName.toString().isNotEmpty) {
            name = 'Call with $contactName';
          } else if (phoneNumber != null &&
              phoneNumber.toString().isNotEmpty) {
            name = 'Call $phoneNumber';
          } else if (callId.isNotEmpty) {
            name = 'Call $callId';
          }
        }
        break;
      case 'documents':
        if (item is Document) {
          name = item.name;
        } else if (item is Map<String, dynamic>) {
          name = (item['name'] ?? item['title'])?.toString();
        }
        break;
    }

    if (name == null || name.isEmpty) return null;
    return _generateEntityId(name, graphEntityType);
  }

  /// Deterministic entity ID — must match
  /// [BackgroundIndexingService._generateEntityId].
  String _generateEntityId(String name, String type) {
    final normalized =
        name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_');
    final typePrefix =
        type.isNotEmpty ? '${type.toLowerCase()}_' : '';
    return '$typePrefix$normalized';
  }

  /// Find all non-protected entities that have zero relationships.
  Future<List<GraphEntity>> _findOrphanEntities() async {
    final orphans = <GraphEntity>[];

    // Entity types that may become orphaned.
    const candidateTypes = [
      'PERSON',
      'EVENT',
      'PHOTO',
      'PHONE_CALL',
      'DOCUMENT',
      'DOCUMENT_CHUNK',
      'NOTE',
      'NOTE_CHUNK',
      'ALARM',
      'DATE',
      'LOCATION',
      'PHONE',
      'EMAIL',
      'ORGANIZATION',
      'PROJECT',
      'TOPIC',
    ];

    for (final type in candidateTypes) {
      final entities = await repository.getEntitiesByType(type);
      for (final entity in entities) {
        if (_protectedTypes.contains(entity.type.toUpperCase())) continue;

        final rels = await repository.getRelationships(entity.id);
        if (rels.isEmpty) {
          orphans.add(entity);
        }
      }
    }

    return orphans;
  }
}
