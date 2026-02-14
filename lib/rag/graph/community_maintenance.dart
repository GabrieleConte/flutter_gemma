import 'dart:async';

import 'package:flutter/foundation.dart';

import 'graph_repository.dart';
import 'entity_extractor.dart';
import 'community_detection.dart';

/// Result of a community maintenance operation.
class CommunityMaintenanceResult {
  /// Community IDs that had their summaries regenerated.
  final List<String> regeneratedCommunities;

  /// Community IDs that were deleted because they became empty.
  final List<String> deletedCommunities;

  /// Community IDs that were created or updated for newly added entities.
  final List<String> updatedCommunities;

  CommunityMaintenanceResult({
    this.regeneratedCommunities = const [],
    this.deletedCommunities = const [],
    this.updatedCommunities = const [],
  });

  int get totalAffected =>
      regeneratedCommunities.length +
      deletedCommunities.length +
      updatedCommunities.length;

  @override
  String toString() =>
      'CommunityMaintenanceResult(regenerated: ${regeneratedCommunities.length}, '
      'deleted: ${deletedCommunities.length}, '
      'updated: ${updatedCommunities.length})';
}

/// Maintains community coherence when the graph topology changes.
///
/// Handles two scenarios:
/// 1. **Entity deletions**: removes entities from their communities, deletes
///    empty communities, and regenerates summaries for affected ones.
/// 2. **Entity additions**: re-runs Leiden community detection on the full
///    graph (or local subgraph) and reconciles the result with the existing
///    communities in the database.
class CommunityMaintainer {
  final GraphRepository repository;
  final CommunitySummarizer? summarizer;
  final CommunityDetectionConfig communityConfig;

  CommunityMaintainer({
    required this.repository,
    this.summarizer,
    CommunityDetectionConfig? communityConfig,
  }) : communityConfig = communityConfig ?? CommunityDetectionConfig();

  // ---------------------------------------------------------------------------
  // Entity Deletion
  // ---------------------------------------------------------------------------

  /// Update communities after entities have been deleted from the graph.
  ///
  /// For each deleted entity:
  /// 1. Find communities it belonged to.
  /// 2. Re-save the community without that entity (or delete if empty).
  /// 3. Regenerate the summary for affected non-empty communities.
  Future<CommunityMaintenanceResult> onEntitiesDeleted(
    List<String> deletedEntityIds,
  ) async {
    if (deletedEntityIds.isEmpty) {
      return CommunityMaintenanceResult();
    }

    debugPrint(
        '[CommunityMaintainer] Processing ${deletedEntityIds.length} deleted entities');

    // Collect all affected community IDs (unique).
    final affectedCommunities = <String, GraphCommunity>{};

    for (final entityId in deletedEntityIds) {
      final communities = await repository.getCommunitiesForEntity(entityId);
      for (final community in communities) {
        affectedCommunities[community.id] = community;
      }
    }

    if (affectedCommunities.isEmpty) {
      debugPrint(
          '[CommunityMaintainer] No communities affected by deletions');
      return CommunityMaintenanceResult();
    }

    debugPrint(
        '[CommunityMaintainer] ${affectedCommunities.length} communities affected');

    final deletedCommunityIds = <String>[];
    final regeneratedCommunityIds = <String>[];
    final deletedEntitySet = deletedEntityIds.toSet();

    for (final community in affectedCommunities.values) {
      // Remove deleted entities from the community's entity list.
      final remainingEntityIds = community.entityIds
          .where((id) => !deletedEntitySet.contains(id))
          .toList();

      if (remainingEntityIds.isEmpty) {
        // Community has no remaining members — delete it.
        await repository.deleteCommunity(community.id);
        deletedCommunityIds.add(community.id);
        debugPrint(
            '[CommunityMaintainer] Deleted empty community ${community.id}');
      } else {
        // Re-save community with the remaining entity list.
        final updatedCommunity = GraphCommunity(
          id: community.id,
          level: community.level,
          summary: community.summary,
          entityIds: remainingEntityIds,
          embedding: community.embedding,
          metadata: community.metadata,
        );
        await repository.addCommunity(updatedCommunity);

        // Regenerate the summary if a summarizer is available.
        if (summarizer != null) {
          await _regenerateSummary(updatedCommunity);
        }
        regeneratedCommunityIds.add(community.id);
      }
    }

    debugPrint(
        '[CommunityMaintainer] Deletion maintenance complete: '
        '${deletedCommunityIds.length} deleted, '
        '${regeneratedCommunityIds.length} regenerated');

    return CommunityMaintenanceResult(
      deletedCommunities: deletedCommunityIds,
      regeneratedCommunities: regeneratedCommunityIds,
    );
  }

  // ---------------------------------------------------------------------------
  // Entity Addition (post-indexing — individual notes/alarms/documents)
  // ---------------------------------------------------------------------------

  /// Update communities after new entities have been added to the graph
  /// outside of the main indexing pipeline.
  ///
  /// This runs full Leiden community detection and reconciles results with the
  /// existing communities stored in the database.
  ///
  /// Use [duringIndexing] = true to skip this (Phase 2 of the indexing pipeline
  /// already rebuilds all communities).
  Future<CommunityMaintenanceResult> onEntitiesAdded(
    List<String> newEntityIds, {
    bool duringIndexing = false,
  }) async {
    if (duringIndexing || newEntityIds.isEmpty) {
      return CommunityMaintenanceResult();
    }

    debugPrint(
        '[CommunityMaintainer] Processing ${newEntityIds.length} added entities');

    // Perform full community detection on the current graph state.
    final result = await _detectCommunitiesFromGraph();
    if (result == null) {
      return CommunityMaintenanceResult();
    }

    // Reconcile: overwrite stored communities with the new detection result.
    final updatedCommunityIds = <String>[];
    final validEntityIds = await _getAllEntityIds();

    for (final community in result.communities) {
      // Filter to only valid (existing) entity IDs.
      final validCommunityEntityIds = community.entityIds
          .where((id) => validEntityIds.contains(id))
          .toList();

      if (validCommunityEntityIds.isEmpty) continue;

      final metadata = <String, dynamic>{
        'modularity': community.modularity,
      };
      if (community.childCommunityIds != null &&
          community.childCommunityIds!.isNotEmpty) {
        metadata['childCommunityIds'] = community.childCommunityIds;
      }
      if (community.parentCommunityId != null) {
        metadata['parentCommunityId'] = community.parentCommunityId;
      }

      final graphCommunity = GraphCommunity(
        id: community.id,
        level: community.level,
        summary: '', // Will be regenerated below.
        entityIds: validCommunityEntityIds,
        embedding: null,
        metadata: metadata,
      );

      try {
        await repository.addCommunity(graphCommunity);
        updatedCommunityIds.add(community.id);
      } catch (e) {
        debugPrint(
            '[CommunityMaintainer] Failed to store community ${community.id}: $e');
      }
    }

    // Regenerate summaries for updated communities.
    if (summarizer != null) {
      await _regenerateSummariesForAll(updatedCommunityIds);
    }

    debugPrint(
        '[CommunityMaintainer] Addition maintenance complete: '
        '${updatedCommunityIds.length} communities updated');

    return CommunityMaintenanceResult(
      updatedCommunities: updatedCommunityIds,
    );
  }

  // ---------------------------------------------------------------------------
  // Re-indexing — new entities discovered during data re-fetch
  // ---------------------------------------------------------------------------

  /// Called after the full indexing pipeline's community detection phase
  /// (Phase 2) has already run and stored communities. This regenerates
  /// summaries for all communities to incorporate any new/changed entities.
  ///
  /// This is lighter than [onEntitiesAdded] because community *structure*
  /// has already been computed by Phase 2 — we only need summaries.
  Future<CommunityMaintenanceResult> refreshSummaries() async {
    if (summarizer == null) {
      return CommunityMaintenanceResult();
    }

    debugPrint('[CommunityMaintainer] Refreshing all community summaries');

    final regenerated = <String>[];
    final maxLevel = communityConfig.maxDepth;

    for (var level = maxLevel; level >= 0; level--) {
      final communities = await repository.getCommunitiesByLevel(level);
      for (final community in communities) {
        await _regenerateSummary(community);
        regenerated.add(community.id);
      }
    }

    debugPrint(
        '[CommunityMaintainer] Refreshed ${regenerated.length} community summaries');

    return CommunityMaintenanceResult(
      regeneratedCommunities: regenerated,
    );
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Run Leiden community detection on the full current graph.
  Future<CommunityDetectionResult?> _detectCommunitiesFromGraph() async {
    final entities = <GraphEntity>[];
    final relationships = <GraphRelationship>[];

    // Load all entities that participate in community detection
    // (same filter as BackgroundIndexingService._detectCommunitiesPhase).
    final communityEntityTypes = [
      'SELF',
      ...EntityTypes.all
          .where((t) => t != EntityTypes.date && t != EntityTypes.hub),
    ];

    for (final type in communityEntityTypes) {
      entities.addAll(await repository.getEntitiesByType(type));
    }

    if (entities.isEmpty) {
      debugPrint('[CommunityMaintainer] No entities for community detection');
      return null;
    }

    for (final entity in entities) {
      relationships.addAll(await repository.getRelationships(entity.id));
    }

    final detector = LeidenCommunityDetector(config: communityConfig);
    return await detector.detectCommunities(entities, relationships);
  }

  /// Collect all valid entity IDs currently in the graph.
  Future<Set<String>> _getAllEntityIds() async {
    final ids = <String>{};
    final allTypes = [
      'SELF',
      ...EntityTypes.all,
    ];
    for (final type in allTypes) {
      final entities = await repository.getEntitiesByType(type);
      ids.addAll(entities.map((e) => e.id));
    }
    return ids;
  }

  /// Regenerate the summary for a single community.
  Future<void> _regenerateSummary(GraphCommunity community) async {
    if (summarizer == null) return;

    try {
      // Fetch full entity and relationship data for this community.
      final entities = <GraphEntity>[];
      final relationships = <GraphRelationship>[];

      for (final entityId in community.entityIds) {
        final entity = await repository.getEntity(entityId);
        if (entity != null) {
          entities.add(entity);
          relationships.addAll(await repository.getRelationships(entityId));
        }
      }

      if (entities.isEmpty) return;

      final detectedCommunity = DetectedCommunity(
        id: community.id,
        level: community.level,
        entityIds: community.entityIds.toSet(),
        modularity: 0.0,
        childCommunityIds: community.childCommunityIds,
      );

      final summary = await summarizer!.summarize(
        detectedCommunity,
        entities,
        relationships,
      );

      await repository.updateCommunitySummary(
        community.id,
        summary.summary,
        summary.embedding,
      );
    } catch (e) {
      debugPrint(
          '[CommunityMaintainer] Failed to regenerate summary for ${community.id}: $e');
    }
  }

  /// Regenerate summaries for a list of community IDs (hierarchical, bottom-up).
  Future<void> _regenerateSummariesForAll(List<String> communityIds) async {
    if (summarizer == null || communityIds.isEmpty) return;

    // Fetch all communities involved and sort by level (highest = most granular first).
    final communitiesToSummarize = <GraphCommunity>[];
    final maxLevel = communityConfig.maxDepth;

    for (var level = maxLevel; level >= 0; level--) {
      final levelCommunities = await repository.getCommunitiesByLevel(level);
      for (final c in levelCommunities) {
        if (communityIds.contains(c.id)) {
          communitiesToSummarize.add(c);
        }
      }
    }

    for (final community in communitiesToSummarize) {
      await _regenerateSummary(community);
    }
  }
}
