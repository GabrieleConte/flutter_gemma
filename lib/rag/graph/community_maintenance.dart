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
  /// **Important:** The native `deleteEntity()` cascade-deletes the
  /// `entity_communities` mapping rows, so `getCommunitiesForEntity()` will
  /// return nothing for already-deleted entities. We therefore scan all
  /// communities and check membership by inspecting `entityIds` directly.
  ///
  /// For each affected community:
  /// 1. Remove deleted entity IDs from its member list.
  /// 2. Delete the community if it becomes empty.
  /// 3. Re-save and regenerate the summary otherwise.
  Future<CommunityMaintenanceResult> onEntitiesDeleted(
    List<String> deletedEntityIds,
  ) async {
    if (deletedEntityIds.isEmpty) {
      return CommunityMaintenanceResult();
    }

    debugPrint(
        '[CommunityMaintainer] Processing ${deletedEntityIds.length} deleted entities');

    final deletedEntitySet = deletedEntityIds.toSet();

    // Scan all communities across all levels to find those that reference
    // any of the deleted entity IDs. We cannot rely on
    // getCommunitiesForEntity() because the entity_communities mapping rows
    // are already cascade-deleted by the native deleteEntity().
    final affectedCommunities = <String, GraphCommunity>{};

    for (var level = communityConfig.maxDepth; level >= 0; level--) {
      final communities = await repository.getCommunitiesByLevel(level);
      for (final community in communities) {
        if (community.entityIds.any((id) => deletedEntitySet.contains(id))) {
          affectedCommunities[community.id] = community;
        }
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
  /// This runs full Leiden community detection, then **diffs** the result
  /// against the existing communities stored in the database so that only
  /// actually-changed communities incur expensive LLM summary regeneration.
  ///
  /// Specifically:
  /// - Communities whose entity-set is identical to an existing record (and
  ///   already have a non-empty summary) are **skipped** — zero LLM calls.
  /// - New / changed communities are saved and summarized.
  /// - Old community rows that no longer correspond to any detected community
  ///   are **deleted** to prevent unbounded growth.
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

    // 1. Snapshot existing communities indexed by canonical entity set.
    final existingByCanonical = await _snapshotExistingCommunities();

    // 2. Run full Leiden on the current graph state.
    final result = await _detectCommunitiesFromGraph();
    if (result == null) {
      return CommunityMaintenanceResult();
    }

    // 3. Diff old vs new by comparing sorted entity sets.
    final validEntityIds = await _getAllEntityIds();
    final updatedCommunityIds = <String>[];
    final unchangedCount = <String>[];
    final matchedOldIds = <String>{};

    for (final community in result.communities) {
      // Filter to only valid (existing) entity IDs.
      final validCommunityEntityIds = community.entityIds
          .where((id) => validEntityIds.contains(id))
          .toList();

      if (validCommunityEntityIds.isEmpty) continue;

      final key = canonicalKey(validCommunityEntityIds);
      final existing = existingByCanonical[key];

      if (existing != null && existing.summary.isNotEmpty) {
        // Community entity-set unchanged and already has a valid summary —
        // no need to re-save or re-summarize.
        matchedOldIds.add(existing.id);
        unchangedCount.add(existing.id);
        continue;
      }

      // New or changed community — save and mark for summarization.
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

    // 4. Delete orphan communities — old rows whose entity-set no longer
    //    matches any detected community.
    final deletedCommunityIds = <String>[];
    for (final oldCommunity in existingByCanonical.values) {
      if (!matchedOldIds.contains(oldCommunity.id)) {
        await repository.deleteCommunity(oldCommunity.id);
        deletedCommunityIds.add(oldCommunity.id);
      }
    }

    // 5. Only regenerate summaries for actually changed / new communities.
    if (summarizer != null && updatedCommunityIds.isNotEmpty) {
      await _regenerateSummariesForAll(updatedCommunityIds);
    }

    debugPrint(
        '[CommunityMaintainer] Addition maintenance complete: '
        '${updatedCommunityIds.length} updated, '
        '${unchangedCount.length} unchanged (skipped), '
        '${deletedCommunityIds.length} orphans deleted');

    return CommunityMaintenanceResult(
      updatedCommunities: updatedCommunityIds,
      deletedCommunities: deletedCommunityIds,
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

  /// Snapshot all existing communities indexed by their canonical entity-set
  /// key (sorted, comma-joined entity IDs).
  ///
  /// This allows O(1) lookup to check whether a detected community's
  /// membership matches an already-stored community.
  Future<Map<String, GraphCommunity>> _snapshotExistingCommunities() async {
    final snapshot = <String, GraphCommunity>{};
    for (var level = communityConfig.maxDepth; level >= 0; level--) {
      final communities = await repository.getCommunitiesByLevel(level);
      for (final c in communities) {
        final key = canonicalKey(c.entityIds);
        snapshot[key] = c;
      }
    }
    return snapshot;
  }

  /// Canonical key for a community: sorted entity IDs joined by commas.
  ///
  /// Two communities with the same entity set produce the same key regardless
  /// of the order in which entity IDs were stored.
  ///
  /// Public so that callers (e.g. [BackgroundIndexingService]) can reuse the
  /// same canonical-key logic for their own diff comparisons.
  static String canonicalKey(List<String> entityIds) {
    final sorted = List<String>.from(entityIds)..sort();
    return sorted.join(',');
  }

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
