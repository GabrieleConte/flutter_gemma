import 'package:flutter/foundation.dart';

import 'graph_repository.dart';
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
/// 2. **Entity additions**: uses incremental community assignment — finds the
///    new entity's neighbors, assigns it to the community with the most
///    neighbor connections, and only regenerates that community's summary.
///    Full Leiden is only run by the indexing pipeline (Phase 2).
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
  /// outside of the main indexing pipeline (notes, alarms, single documents).
  ///
  /// Uses **incremental community assignment** instead of re-running full
  /// Leiden detection. For each new entity we:
  /// 1. Look up its neighbors via relationships.
  /// 2. Find which existing communities those neighbors belong to.
  /// 3. Assign the new entity to the community with the most neighbor votes.
  /// 4. Only regenerate the summary for the affected community.
  ///
  /// This avoids the non-deterministic Leiden shuffle that would reshuffle
  /// unrelated large communities (e.g. PDF chunks) and trigger unnecessary
  /// LLM summarization calls.
  ///
  /// Use [duringIndexing] = true to skip this (Phase 2 of the indexing pipeline
  /// already rebuilds all communities via full Leiden).
  Future<CommunityMaintenanceResult> onEntitiesAdded(
    List<String> newEntityIds, {
    bool duringIndexing = false,
  }) async {
    if (duringIndexing || newEntityIds.isEmpty) {
      return CommunityMaintenanceResult();
    }

    debugPrint(
        '[CommunityMaintainer] Processing ${newEntityIds.length} added entities (incremental)');

    final updatedCommunityIds = <String>{};
    final createdCommunityIds = <String>[];
    final newEntitySet = newEntityIds.toSet();

    for (final entityId in newEntityIds) {
      // 1. Get this entity's relationships to find its neighbors.
      final relationships = await repository.getRelationships(entityId);
      final neighborIds = <String>{};
      for (final rel in relationships) {
        if (rel.sourceId == entityId) {
          neighborIds.add(rel.targetId);
        } else {
          neighborIds.add(rel.sourceId);
        }
      }
      // Exclude other new entities from neighbor lookup (they don't have
      // communities yet either).
      neighborIds.removeAll(newEntitySet);

      // 2. Vote: for each neighbor, find its level-0 communities and tally.
      final communityVotes = <String, int>{};
      final communitiesById = <String, GraphCommunity>{};

      for (final neighborId in neighborIds) {
        final neighborCommunities =
            await repository.getCommunitiesForEntity(neighborId);
        for (final c in neighborCommunities) {
          if (c.level == 0) {
            communityVotes[c.id] = (communityVotes[c.id] ?? 0) + 1;
            communitiesById[c.id] = c;
          }
        }
      }

      if (communityVotes.isNotEmpty) {
        // 3a. Assign to the community with the most neighbor connections.
        final bestCommunityId = communityVotes.entries
            .reduce((a, b) => a.value >= b.value ? a : b)
            .key;
        final bestCommunity = communitiesById[bestCommunityId]!;

        // Add entity to the community's member list if not already present.
        if (!bestCommunity.entityIds.contains(entityId)) {
          final updatedEntityIds = [...bestCommunity.entityIds, entityId];
          final updatedCommunity = GraphCommunity(
            id: bestCommunity.id,
            level: bestCommunity.level,
            summary: bestCommunity.summary,
            entityIds: updatedEntityIds,
            embedding: bestCommunity.embedding,
            metadata: bestCommunity.metadata,
          );
          await repository.addCommunity(updatedCommunity);
          updatedCommunityIds.add(bestCommunity.id);
          debugPrint(
              '[CommunityMaintainer] Added $entityId to existing community '
              '${bestCommunity.id} (${communityVotes[bestCommunityId]} neighbor votes)');
        }

        // Also propagate to level-1+ parent communities that contain
        // the best level-0 community's entities.
        await _propagateToParentCommunities(entityId, bestCommunityId,
            updatedCommunityIds);
      } else {
        // 3b. No neighbors have communities — create a new singleton community.
        final newCommunityId = 'community_0_$entityId';
        final newCommunity = GraphCommunity(
          id: newCommunityId,
          level: 0,
          summary: '',
          entityIds: [entityId],
          embedding: null,
          metadata: {'modularity': 0.0},
        );
        await repository.addCommunity(newCommunity);
        createdCommunityIds.add(newCommunityId);
        updatedCommunityIds.add(newCommunityId);
        debugPrint(
            '[CommunityMaintainer] Created new community $newCommunityId '
            'for isolated entity $entityId');
      }
    }

    // 4. Regenerate summaries only for communities that actually changed.
    if (summarizer != null && updatedCommunityIds.isNotEmpty) {
      await _regenerateSummariesForAll(updatedCommunityIds.toList());
    }

    debugPrint(
        '[CommunityMaintainer] Addition maintenance complete: '
        '${updatedCommunityIds.length} updated, '
        '${createdCommunityIds.length} new communities created');

    return CommunityMaintenanceResult(
      updatedCommunities: updatedCommunityIds.toList(),
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

  /// Propagate a newly-assigned entity to parent communities (level 1+).
  ///
  /// Finds any higher-level community that contains the given level-0
  /// community's ID in its child list or whose entity set overlaps with that
  /// community, then adds the entity there as well.
  Future<void> _propagateToParentCommunities(
    String entityId,
    String level0CommunityId,
    Set<String> updatedCommunityIds,
  ) async {
    for (var level = 1; level <= communityConfig.maxDepth; level++) {
      final levelCommunities = await repository.getCommunitiesByLevel(level);
      for (final parent in levelCommunities) {
        // Check if this parent community already contains the level-0
        // community's entities (i.e. it's a parent in the hierarchy).
        final childIds = parent.childCommunityIds;
        final isParent = (childIds != null &&
                childIds.contains(level0CommunityId)) ||
            parent.entityIds.any((id) =>
                id == entityId); // already there

        // Alternative: check overlap with the level-0 community members.
        if (!isParent) {
          // Get the level-0 community to check membership overlap.
          final level0Communities =
              await repository.getCommunitiesByLevel(0);
          final level0 =
              level0Communities.where((c) => c.id == level0CommunityId);
          if (level0.isNotEmpty) {
            final level0EntitySet = level0.first.entityIds.toSet();
            // If the parent contains any of the level-0 community's entities,
            // the new entity probably belongs there too.
            if (parent.entityIds.any((id) => level0EntitySet.contains(id))) {
              if (!parent.entityIds.contains(entityId)) {
                final updatedEntityIds = [...parent.entityIds, entityId];
                final updatedParent = GraphCommunity(
                  id: parent.id,
                  level: parent.level,
                  summary: parent.summary,
                  entityIds: updatedEntityIds,
                  embedding: parent.embedding,
                  metadata: parent.metadata,
                );
                await repository.addCommunity(updatedParent);
                updatedCommunityIds.add(parent.id);
                debugPrint(
                    '[CommunityMaintainer] Propagated $entityId to '
                    'parent community ${parent.id} (level $level)');
              }
            }
          }
        }
      }
    }
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
