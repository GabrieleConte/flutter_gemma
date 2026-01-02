import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';

/// A node in the graph visualization
class GraphNode {
  final String id;
  final String name;
  final String type;
  Offset position;
  Offset velocity;
  bool isDragging;

  /// For cluster nodes: the entity IDs contained in this cluster
  final List<String>? clusterEntityIds;

  /// Whether this node can be clicked to expand (for collapsed clusters)
  final bool isCluster;

  GraphNode({
    required this.id,
    required this.name,
    required this.type,
    required this.position,
    this.clusterEntityIds,
    bool? isCluster,
  })  : isCluster = isCluster ??
            (clusterEntityIds != null && clusterEntityIds.isNotEmpty),
        velocity = Offset.zero,
        isDragging = false;

  Color get color {
    if (isCluster) return Colors.blueGrey;

    switch (type.toUpperCase()) {
      case 'SELF':
        return Colors.amber; // "You" central node - golden
      case 'HUB':
        return Colors.indigo.shade300; // Hub nodes - indigo
      case 'PERSON':
        return Colors.blue;
      case 'ORGANIZATION':
        return Colors.green;
      case 'EVENT':
        return Colors.orange;
      case 'LOCATION':
        return Colors.purple;
      case 'PHOTO':
        return Colors.pink.shade300;
      case 'PHONE_CALL':
        return Colors.teal;
      case 'DOCUMENT':
        return Colors.deepOrange;
      case 'NOTE':
        return Colors.cyan;
      case 'PROJECT':
        return Colors.deepPurple;
      case 'TOPIC':
        return Colors.pinkAccent;
      case 'DATE':
        return Colors.brown;
      case 'EMAIL':
        return Colors.red.shade300;
      case 'PHONE':
        return Colors.lightGreen;
      default:
        return Colors.grey;
    }
  }

  IconData get icon {
    if (isCluster) return Icons.workspaces;

    switch (type.toUpperCase()) {
      case 'SELF':
        return Icons.account_circle; // "You" central node
      case 'HUB':
        return Icons.hub; // Hub node
      case 'PERSON':
        return Icons.person;
      case 'ORGANIZATION':
        return Icons.business;
      case 'EVENT':
        return Icons.event;
      case 'LOCATION':
        return Icons.location_on;
      case 'PHOTO':
        return Icons.photo;
      case 'PHONE_CALL':
        return Icons.phone;
      case 'DOCUMENT':
        return Icons.description;
      case 'NOTE':
        return Icons.note;
      case 'PROJECT':
        return Icons.folder;
      case 'TOPIC':
        return Icons.tag;
      case 'DATE':
        return Icons.calendar_today;
      case 'EMAIL':
        return Icons.email;
      case 'PHONE':
        return Icons.phone_android;
      default:
        return Icons.circle;
    }
  }
}

/// An edge in the graph visualization
class GraphEdge {
  final String sourceId;
  final String targetId;
  final String type;
  final double weight;

  GraphEdge({
    required this.sourceId,
    required this.targetId,
    required this.type,
    this.weight = 1.0,
  });
}

/// A cluster of related entities
class GraphCluster {
  final String id;
  final String name;
  final List<GraphEntity> entities;
  final String dominantType;
  bool isExpanded;

  GraphCluster({
    required this.id,
    required this.name,
    required this.entities,
    required this.dominantType,
    this.isExpanded = false,
  });

  int get size => entities.length;
}

/// Interactive graph visualizer with force-directed layout and clustering
class GraphVisualizer extends StatefulWidget {
  final List<GraphEntity> entities;
  final List<GraphRelationship> relationships;
  final void Function(GraphEntity entity)? onEntityTap;

  /// Threshold for clustering - types with more than this many nodes will be clustered
  final int clusterThreshold;

  /// Whether to enable clustering mode
  final bool enableClustering;

  const GraphVisualizer({
    super.key,
    required this.entities,
    required this.relationships,
    this.onEntityTap,
    this.clusterThreshold = 10,
    this.enableClustering = true,
  });

  @override
  State<GraphVisualizer> createState() => _GraphVisualizerState();
}

class _GraphVisualizerState extends State<GraphVisualizer>
    with TickerProviderStateMixin {
  late List<GraphNode> _nodes;
  late List<GraphEdge> _edges;
  late AnimationController _simulationController;

  // Clustering state
  Map<String, GraphCluster> _clusters = {};
  final Set<String> _expandedClusters = {};

  // Track which entities came from which cluster (for cloud grouping)
  final Map<String, String> _entitySourceCluster = {};

  // Track cluster center positions when expanded
  final Map<String, Offset> _expandedClusterCenters = {};

  // Transformation state
  Offset _offset = Offset.zero;
  double _scale = 1.0;
  Offset? _lastFocalPoint;

  // Selected node
  String? _selectedNodeId;
  GraphNode? _draggedNode;

  // Force simulation parameters
  static const double _repulsionStrength = 5000.0;
  static const double _attractionStrength = 0.01;
  static const double _centeringStrength = 0.01;
  static const double _damping = 0.9;
  static const double _minDistance = 50.0;

  // Virtual canvas size - much larger than screen for panning
  double _virtualCanvasSize = 2000.0;

  // Dynamic node sizing based on total entities
  double _getNodeRadius(GraphNode node, {bool isSelected = false}) {
    final totalNodes = _nodes.length;

    // Base size reduction when many nodes visible
    double scaleFactor = 1.0;
    if (totalNodes > 30) {
      scaleFactor = 30 / totalNodes; // Scale down proportionally
      scaleFactor = scaleFactor.clamp(0.5, 1.0); // Min 50% of original size
    }

    // Type-based sizing
    double baseRadius;
    switch (node.type) {
      case 'SELF':
        baseRadius = 28.0; // "You" is largest
        break;
      case 'HUB':
        baseRadius = 22.0; // Hubs are medium-large
        break;
      case 'PERSON':
        baseRadius = 16.0;
        break;
      case 'EVENT':
      case 'ORGANIZATION':
        baseRadius = 14.0;
        break;
      default:
        baseRadius = 12.0; // Other types are smaller
    }

    // Is this a cluster node?
    if (node.clusterEntityIds != null && node.clusterEntityIds!.isNotEmpty) {
      baseRadius = 24.0; // Cluster nodes are large
    }

    final scaledRadius = baseRadius * scaleFactor;
    return isSelected ? scaledRadius * 1.2 : scaledRadius;
  }

  @override
  void initState() {
    super.initState();
    _initializeGraph();
    _simulationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..addListener(_simulateStep);
    _simulationController.repeat();
  }

  @override
  void didUpdateWidget(GraphVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entities != widget.entities ||
        oldWidget.relationships != widget.relationships) {
      _initializeGraph();
    }
  }

  @override
  void dispose() {
    _simulationController.dispose();
    super.dispose();
  }

  void _initializeGraph() {
    final random = Random(42);
    // Use virtual canvas center for positioning
    final centerX = _virtualCanvasSize / 2;
    final centerY = _virtualCanvasSize / 2;

    if (widget.enableClustering) {
      _initializeWithClustering(random, centerX, centerY);
    } else {
      _initializeWithoutClustering(random, centerX, centerY);
    }

    // Set initial offset to center the virtual canvas in the view
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final size = context.size ?? const Size(400, 400);
        setState(() {
          // Center the virtual canvas center in the screen
          _offset = Offset(
            size.width / 2 - (_virtualCanvasSize / 2) * _scale,
            size.height / 2 - (_virtualCanvasSize / 2) * _scale,
          );
        });
      }
    });
  }

  void _initializeWithClustering(
      Random random, double centerX, double centerY) {
    // Dynamically size virtual canvas based on entity count
    final totalEntities = widget.entities.length;
    _virtualCanvasSize = (1500.0 + totalEntities * 30).clamp(1500.0, 5000.0);

    // Group entities by type
    final entitiesByType = <String, List<GraphEntity>>{};
    for (final entity in widget.entities) {
      entitiesByType.putIfAbsent(entity.type, () => []);
      entitiesByType[entity.type]!.add(entity);
    }

    // Create clusters for types that exceed threshold
    _clusters = {};
    final clusteredEntityIds = <String>{};
    final unclustered = <GraphEntity>[];
    // Track which entities come from expanded clusters
    final expandedClusterEntities = <String, List<GraphEntity>>{};

    for (final entry in entitiesByType.entries) {
      final type = entry.key;
      final entities = entry.value;

      // Always show "You" node and don't cluster types with few entities
      if (type == 'SELF' || entities.length <= widget.clusterThreshold) {
        unclustered.addAll(entities);
      } else {
        // Check if this cluster is expanded
        final clusterId = 'cluster_$type';
        if (_expandedClusters.contains(clusterId)) {
          // Track these entities as coming from this expanded cluster
          expandedClusterEntities[clusterId] = entities;
          for (final e in entities) {
            _entitySourceCluster[e.id] = clusterId;
          }
          // Keep cluster as a hub node even when expanded
          _clusters[clusterId] = GraphCluster(
            id: clusterId,
            name: type, // Just type name, not count
            entities: entities,
            dominantType: type,
            isExpanded: true,
          );
        } else {
          // Create cluster node (collapsed)
          _clusters[clusterId] = GraphCluster(
            id: clusterId,
            name: '$type (${entities.length})',
            entities: entities,
            dominantType: type,
            isExpanded: false,
          );
          clusteredEntityIds.addAll(entities.map((e) => e.id));
        }
      }
    }

    // Create nodes for unclustered entities (not from expanded clusters)
    final visibleEntityIds = <String>{};
    _nodes = [];

    for (final entity in unclustered) {
      visibleEntityIds.add(entity.id);
      _nodes.add(GraphNode(
        id: entity.id,
        name: entity.name,
        type: entity.type,
        position: Offset(
          centerX + (random.nextDouble() - 0.5) * 300,
          centerY + (random.nextDouble() - 0.5) * 300,
        ),
      ));
    }

    // Create nodes for expanded cluster entities - position in a cloud around saved center
    for (final entry in expandedClusterEntities.entries) {
      final clusterId = entry.key;
      final entities = entry.value;
      final clusterCenter =
          _expandedClusterCenters[clusterId] ?? Offset(centerX, centerY);

      // Position entities in a circular cloud around the cluster center
      // Scale very aggressively for large clusters - hub will be at center
      final count = entities.length;
      // Much larger base radius to leave room for hub at center
      final baseRadius = 150.0 + (count * 25).clamp(0, 1500).toDouble();
      // Fewer entities per ring with larger spacing
      final entitiesPerRing = count > 40 ? 12 : (count > 20 ? 10 : 8);
      final ringSpacing =
          80.0 + (count > 40 ? 60.0 : (count > 20 ? 40.0 : 20.0));

      for (var i = 0; i < entities.length; i++) {
        final entity = entities[i];
        visibleEntityIds.add(entity.id);

        // Use golden angle for even distribution around circle
        final angle = i * 2.39996; // Golden angle in radians (~137.5 degrees)
        final ringIndex = i ~/ entitiesPerRing;
        final radius = baseRadius + (ringIndex * ringSpacing);
        final jitter = (random.nextDouble() - 0.5) * 30;

        _nodes.add(GraphNode(
          id: entity.id,
          name: entity.name,
          type: entity.type,
          position: Offset(
            clusterCenter.dx + cos(angle) * radius + jitter,
            clusterCenter.dy + sin(angle) * radius + jitter,
          ),
        ));
      }
    }

    // Add cluster nodes (both collapsed and expanded as hubs)
    for (final cluster in _clusters.values) {
      // For expanded clusters, position at saved center
      final position =
          cluster.isExpanded && _expandedClusterCenters.containsKey(cluster.id)
              ? _expandedClusterCenters[cluster.id]!
              : Offset(
                  centerX + (random.nextDouble() - 0.5) * 300,
                  centerY + (random.nextDouble() - 0.5) * 300,
                );

      _nodes.add(GraphNode(
        id: cluster.id,
        name: cluster.name,
        type: cluster.isExpanded
            ? 'HUB'
            : cluster.dominantType, // Mark expanded as HUB
        position: position,
        clusterEntityIds: cluster.isExpanded
            ? null
            : cluster.entities.map((e) => e.id).toList(),
        isCluster: !cluster.isExpanded, // Only clickable to expand if collapsed
      ));
    }

    // Create edges - connect to cluster if entity is clustered
    _edges = [];
    for (final rel in widget.relationships) {
      String sourceId = rel.sourceId;
      String targetId = rel.targetId;

      // Redirect edges to cluster nodes if source/target is clustered
      if (clusteredEntityIds.contains(sourceId)) {
        final cluster = _clusters.values.firstWhere(
          (c) => c.entities.any((e) => e.id == sourceId),
          orElse: () => _clusters.values.first,
        );
        sourceId = cluster.id;
      }
      if (clusteredEntityIds.contains(targetId)) {
        final cluster = _clusters.values.firstWhere(
          (c) => c.entities.any((e) => e.id == targetId),
          orElse: () => _clusters.values.first,
        );
        targetId = cluster.id;
      }

      // Only add edge if both endpoints are visible
      final sourceVisible = visibleEntityIds.contains(sourceId) ||
          _clusters.containsKey(sourceId);
      final targetVisible = visibleEntityIds.contains(targetId) ||
          _clusters.containsKey(targetId);

      if (sourceVisible && targetVisible && sourceId != targetId) {
        // Avoid duplicate edges
        final edgeExists = _edges.any(
          (e) =>
              (e.sourceId == sourceId && e.targetId == targetId) ||
              (e.sourceId == targetId && e.targetId == sourceId),
        );
        if (!edgeExists) {
          _edges.add(GraphEdge(
            sourceId: sourceId,
            targetId: targetId,
            type: rel.type,
            weight: rel.weight,
          ));
        }
      }
    }

    // Ensure clusters and expanded cluster entities connect to "You" via hub representation
    // Find the "You" node
    final youNode = _nodes.firstWhere(
      (n) => n.type == 'SELF',
      orElse: () => _nodes.first,
    );

    // Connect UNCLUSTERED entities directly to "You"
    // These are entities that didn't get grouped into a cluster
    for (final entity in unclustered) {
      // Skip "You" itself
      if (entity.type == 'SELF') continue;
      
      // Check if this entity already has an edge to "You" from relationships
      final alreadyConnected = _edges.any(
        (e) =>
            (e.sourceId == entity.id && e.targetId == youNode.id) ||
            (e.sourceId == youNode.id && e.targetId == entity.id),
      );
      
      if (!alreadyConnected) {
        _edges.add(GraphEdge(
          sourceId: youNode.id,
          targetId: entity.id,
          type: 'RELATED_TO',
          weight: 0.4,
        ));
      }
    }

    // For collapsed clusters, create edge from cluster to "You"
    for (final cluster in _clusters.values) {
      final edgeExists = _edges.any(
        (e) =>
            (e.sourceId == cluster.id && e.targetId == youNode.id) ||
            (e.sourceId == youNode.id && e.targetId == cluster.id),
      );
      if (!edgeExists) {
        _edges.add(GraphEdge(
          sourceId: youNode.id,
          targetId: cluster.id,
          type: 'CONTAINS',
          weight: 0.5,
        ));
      }
    }

    // For expanded clusters: connect cluster hub to "You" (no edges to individual entities)
    for (final clusterId in _expandedClusters) {
      // Connect cluster hub to "You"
      final hubEdgeExists = _edges.any(
        (e) =>
            (e.sourceId == clusterId && e.targetId == youNode.id) ||
            (e.sourceId == youNode.id && e.targetId == clusterId),
      );
      if (!hubEdgeExists) {
        _edges.add(GraphEdge(
          sourceId: youNode.id,
          targetId: clusterId,
          type: 'CONTAINS',
          weight: 0.7,
        ));
      }
      // Entities in the cloud are NOT connected to hub - they just orbit around it
    }
  }

  void _initializeWithoutClustering(
      Random random, double centerX, double centerY) {
    // Dynamically size virtual canvas based on entity count
    final totalEntities = widget.entities.length;
    _virtualCanvasSize = (1500.0 + totalEntities * 30).clamp(1500.0, 5000.0);

    final entityIds = widget.entities.map((e) => e.id).toSet();

    _nodes = widget.entities.map((entity) {
      return GraphNode(
        id: entity.id,
        name: entity.name,
        type: entity.type,
        position: Offset(
          centerX + (random.nextDouble() - 0.5) * 300,
          centerY + (random.nextDouble() - 0.5) * 300,
        ),
      );
    }).toList();

    // Only include edges where both nodes exist
    _edges = widget.relationships
        .where((r) =>
            entityIds.contains(r.sourceId) && entityIds.contains(r.targetId))
        .map((rel) => GraphEdge(
              sourceId: rel.sourceId,
              targetId: rel.targetId,
              type: rel.type,
              weight: rel.weight,
            ))
        .toList();

    // Connect all entities to "You" if not already connected
    final youNode = _nodes.firstWhere(
      (n) => n.type == 'SELF',
      orElse: () => _nodes.first,
    );

    for (final entity in widget.entities) {
      // Skip "You" itself
      if (entity.type == 'SELF') continue;

      // Check if this entity already has an edge to "You"
      final alreadyConnected = _edges.any(
        (e) =>
            (e.sourceId == entity.id && e.targetId == youNode.id) ||
            (e.sourceId == youNode.id && e.targetId == entity.id),
      );

      if (!alreadyConnected) {
        _edges.add(GraphEdge(
          sourceId: youNode.id,
          targetId: entity.id,
          type: 'RELATED_TO',
          weight: 0.4,
        ));
      }
    }
  }

  void _toggleCluster(String clusterId) {
    setState(() {
      if (_expandedClusters.contains(clusterId)) {
        // Collapsing: remove center position tracking
        _expandedClusters.remove(clusterId);
        _expandedClusterCenters.remove(clusterId);
        // Clear entity source cluster mapping for this cluster
        _entitySourceCluster.removeWhere((_, v) => v == clusterId);
      } else {
        // Expanding: save current cluster node position as center
        final clusterNode = _nodes.firstWhere(
          (n) => n.id == clusterId,
          orElse: () => _nodes.first,
        );
        _expandedClusterCenters[clusterId] = clusterNode.position;
        _expandedClusters.add(clusterId);
      }
      _initializeGraph();

      // Auto-fit view after cluster expansion/collapse with a slight delay
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) _fitAllNodes();
      });
    });
  }

  void _simulateStep() {
    if (_nodes.isEmpty) return;

    final size = context.size ?? const Size(400, 400);
    final center = Offset(size.width / 2, size.height / 2);

    // Adaptive parameters based on node count - more nodes = faster settling
    final nodeCount = _nodes.length;
    final adaptiveDamping =
        nodeCount > 30 ? 0.8 : (nodeCount > 15 ? 0.85 : _damping);
    final velocityThreshold =
        nodeCount > 30 ? 0.5 : (nodeCount > 15 ? 0.3 : 0.1);
    final forceScale = nodeCount > 30 ? 0.5 : (nodeCount > 15 ? 0.7 : 1.0);

    // Calculate forces for each node
    for (final node in _nodes) {
      if (node.isDragging) continue;

      var force = Offset.zero;

      // Repulsion from other nodes
      for (final other in _nodes) {
        if (other.id == node.id) continue;

        final delta = node.position - other.position;
        final distance = max(delta.distance, 1.0); // Avoid division by zero

        // Check if same cluster
        final nodeCluster = _entitySourceCluster[node.id];
        final otherCluster = _entitySourceCluster[other.id];
        final sameCluster = nodeCluster != null && nodeCluster == otherCluster;

        // Check if other node is the hub of this node's cluster
        final otherIsMyHub = nodeCluster != null && other.id == nodeCluster;
        // Check if this node is an entity and other is its cluster hub
        final iAmEntityOtherIsHub = otherIsMyHub;

        if (iAmEntityOtherIsHub) {
          // Entity must stay away from its hub - strong repulsion at close range
          const hubMinDistance = 80.0;
          if (distance < hubMinDistance) {
            final overlap = hubMinDistance - distance;
            final pushStrength = overlap * 0.15; // Strong push away from hub
            final pushDir =
                delta.distance > 0.1 ? delta / distance : const Offset(1, 0);
            force += pushDir * pushStrength;
          }
        } else if (sameCluster) {
          // Cloud behavior: push when overlapping - larger minimum distance
          const cloudMinDistance = 70.0;
          if (distance < cloudMinDistance) {
            final overlap = cloudMinDistance - distance;
            // Stronger push to keep entities apart
            final pushStrength = overlap * 0.12 * forceScale;
            final pushDir =
                delta.distance > 0.1 ? delta / distance : const Offset(1, 0);
            force += pushDir * pushStrength;
          }
        } else {
          // Normal repulsion for different clusters
          final effectiveDistance = max(distance, _minDistance);
          final repulsion = delta /
              effectiveDistance *
              (_repulsionStrength / (effectiveDistance * effectiveDistance));
          force += repulsion * forceScale;
        }
      }

      // Extra attraction to cluster center for entities from expanded clusters
      final sourceCluster = _entitySourceCluster[node.id];
      if (sourceCluster != null &&
          _expandedClusterCenters.containsKey(sourceCluster)) {
        final clusterCenter = _expandedClusterCenters[sourceCluster]!;
        final toClusterCenter = clusterCenter - node.position;
        final distToCenter = toClusterCenter.distance;
        // Weaker center pull with many nodes - just enough to keep cloud coherent
        final attractionStrength =
            (0.015 + (distToCenter > 100 ? 0.02 : 0)) * forceScale;
        force += toClusterCenter * attractionStrength;
      }

      // Cluster hub nodes should stay at the dynamic center of their cloud
      // This is the PRIMARY force for expanded cluster hubs
      if (node.id.startsWith('cluster_') &&
          _expandedClusters.contains(node.id)) {
        // Calculate dynamic center of all entities in this cluster
        final clusterEntityNodes = _nodes
            .where(
              (n) => _entitySourceCluster[n.id] == node.id,
            )
            .toList();

        if (clusterEntityNodes.isNotEmpty) {
          // Calculate centroid of all cluster entities
          double sumX = 0, sumY = 0;
          for (final entityNode in clusterEntityNodes) {
            sumX += entityNode.position.dx;
            sumY += entityNode.position.dy;
          }
          final centroid = Offset(
            sumX / clusterEntityNodes.length,
            sumY / clusterEntityNodes.length,
          );

          // Strong but smooth attraction to centroid (allows dragging)
          final toCentroid = centroid - node.position;
          force += toCentroid * 0.5; // Very strong pull toward center

          // Update saved center
          _expandedClusterCenters[node.id] = centroid;
        }
      }

      // Hub nodes should stay closer to center (where "You" is)
      // But NOT expanded cluster hubs - they follow their cloud
      if (node.type == 'HUB' && !_expandedClusters.contains(node.id)) {
        final toCenter = center - node.position;
        force += toCenter * 0.02 * forceScale;
      }

      // Attraction along edges
      for (final edge in _edges) {
        GraphNode? other;
        if (edge.sourceId == node.id) {
          other = _nodes.where((n) => n.id == edge.targetId).firstOrNull;
        } else if (edge.targetId == node.id) {
          other = _nodes.where((n) => n.id == edge.sourceId).firstOrNull;
        }

        if (other != null) {
          final delta = other.position - node.position;
          final attraction =
              delta * _attractionStrength * edge.weight * forceScale;
          force += attraction;
        }
      }

      // Centering force - pull towards virtual center, not screen center
      // This keeps the graph coherent in virtual space
      final virtualCenter =
          Offset(_virtualCanvasSize / 2, _virtualCanvasSize / 2);
      final toVirtualCenter = virtualCenter - node.position;
      force += toVirtualCenter * _centeringStrength * forceScale * 0.5;

      // Update velocity and position with adaptive damping
      node.velocity = (node.velocity + force) * adaptiveDamping;

      // Adaptive velocity threshold - higher with more nodes
      if (node.velocity.distance < velocityThreshold) {
        node.velocity = Offset.zero;
      } else {
        node.position += node.velocity;
      }

      // Keep within virtual canvas bounds (much larger than screen)
      node.position = Offset(
        node.position.dx.clamp(50, _virtualCanvasSize - 50),
        node.position.dy.clamp(50, _virtualCanvasSize - 50),
      );
    }

    setState(() {});
  }

  GraphNode? _findNodeAt(Offset position) {
    final transformedPosition = (position - _offset) / _scale;

    for (final node in _nodes.reversed) {
      final distance = (node.position - transformedPosition).distance;
      if (distance < 25) {
        return node;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_nodes.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.account_tree, size: 64, color: Colors.white24),
            SizedBox(height: 16),
            Text(
              'No entities to visualize',
              style: TextStyle(color: Colors.white54),
            ),
            Text(
              'Index some data first',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
        ),
      );
    }

    return GestureDetector(
      onScaleStart: (details) {
        _lastFocalPoint = details.focalPoint;
        final node = _findNodeAt(details.localFocalPoint);
        if (node != null) {
          _draggedNode = node;
          node.isDragging = true;
        }
      },
      onScaleUpdate: (details) {
        setState(() {
          if (_draggedNode != null) {
            // Drag node
            final delta =
                details.focalPoint - (_lastFocalPoint ?? details.focalPoint);
            _draggedNode!.position += delta / _scale;
            _draggedNode!.velocity = Offset.zero;
          } else if (details.scale != 1.0) {
            // Zoom
            _scale = (_scale * details.scale).clamp(0.3, 3.0);
          } else {
            // Pan
            final delta =
                details.focalPoint - (_lastFocalPoint ?? details.focalPoint);
            _offset += delta;
          }
          _lastFocalPoint = details.focalPoint;
        });
      },
      onScaleEnd: (details) {
        if (_draggedNode != null) {
          _draggedNode!.isDragging = false;
          _draggedNode = null;
        }
        _lastFocalPoint = null;
      },
      onTapUp: (details) {
        final node = _findNodeAt(details.localPosition);
        if (node != null) {
          // Check if this is a cluster node
          if (node.isCluster) {
            _toggleCluster(node.id);
            return;
          }

          setState(() => _selectedNodeId = node.id);
          final entity = widget.entities.firstWhere(
            (e) => e.id == node.id,
            orElse: () => widget.entities.first,
          );
          widget.onEntityTap?.call(entity);
        } else {
          setState(() => _selectedNodeId = null);
        }
      },
      child: Container(
        color: const Color(0xFF0a1929),
        child: Stack(
          children: [
            // Graph canvas
            CustomPaint(
              painter: _GraphPainter(
                nodes: _nodes,
                edges: _edges,
                offset: _offset,
                scale: _scale,
                selectedNodeId: _selectedNodeId,
                getNodeRadius: _getNodeRadius,
              ),
              size: Size.infinite,
            ),

            // Legend
            Positioned(
              top: 8,
              left: 8,
              child: _buildLegend(),
            ),

            // Controls
            Positioned(
              bottom: 8,
              right: 8,
              child: _buildControls(),
            ),

            // Node count indicator
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${widget.entities.length} entities total',
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    Text(
                      '${_nodes.length} nodes, ${_edges.length} edges shown',
                      style:
                          const TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                    if (_clusters.isNotEmpty)
                      Text(
                        '${_clusters.length} clusters (tap to expand)',
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 10),
                      ),
                  ],
                ),
              ),
            ),

            // Selected node info
            if (_selectedNodeId != null &&
                !_selectedNodeId!.startsWith('cluster_'))
              Positioned(
                bottom: 8,
                left: 8,
                right: 80,
                child: _buildSelectedNodeInfo(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLegend() {
    final types = _nodes.map((n) => n.type).toSet().toList();

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Entity Types',
            style: TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          ...types.map((type) {
            final node = _nodes.firstWhere((n) => n.type == type);
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: node.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    type,
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildControls() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton.small(
          heroTag: 'zoom_in',
          onPressed: () => _zoomAroundCenter(1.2),
          backgroundColor: Colors.white24,
          child: const Icon(Icons.add, color: Colors.white),
        ),
        const SizedBox(height: 8),
        FloatingActionButton.small(
          heroTag: 'zoom_out',
          onPressed: () => _zoomAroundCenter(1 / 1.2),
          backgroundColor: Colors.white24,
          child: const Icon(Icons.remove, color: Colors.white),
        ),
        const SizedBox(height: 8),
        FloatingActionButton.small(
          heroTag: 'fit_all',
          onPressed: _fitAllNodes,
          backgroundColor: Colors.white24,
          tooltip: 'Fit all nodes',
          child: const Icon(Icons.fit_screen, color: Colors.white),
        ),
        const SizedBox(height: 8),
        FloatingActionButton.small(
          heroTag: 'reset',
          onPressed: _centerOnGraph,
          backgroundColor: Colors.white24,
          tooltip: 'Center view',
          child: const Icon(Icons.center_focus_strong, color: Colors.white),
        ),
      ],
    );
  }

  void _centerOnGraph() {
    if (_nodes.isEmpty) return;

    final size = context.size ?? const Size(400, 400);

    // Find center of all nodes
    double sumX = 0, sumY = 0;
    for (final node in _nodes) {
      sumX += node.position.dx;
      sumY += node.position.dy;
    }
    final graphCenterX = sumX / _nodes.length;
    final graphCenterY = sumY / _nodes.length;

    setState(() {
      _scale = 1.0;
      _offset = Offset(
        size.width / 2 - graphCenterX * _scale,
        size.height / 2 - graphCenterY * _scale,
      );
    });
  }

  void _fitAllNodes() {
    if (_nodes.isEmpty) return;

    final size = context.size ?? const Size(400, 400);

    // Find bounding box of all nodes
    double minX = double.infinity, maxX = double.negativeInfinity;
    double minY = double.infinity, maxY = double.negativeInfinity;

    for (final node in _nodes) {
      minX = min(minX, node.position.dx);
      maxX = max(maxX, node.position.dx);
      minY = min(minY, node.position.dy);
      maxY = max(maxY, node.position.dy);
    }

    final graphWidth = maxX - minX + 100; // Add padding
    final graphHeight = maxY - minY + 100;
    final graphCenterX = (minX + maxX) / 2;
    final graphCenterY = (minY + maxY) / 2;

    // Calculate scale to fit all nodes with some padding
    final scaleX = (size.width - 100) / graphWidth;
    final scaleY = (size.height - 150) / graphHeight;
    final newScale = min(scaleX, scaleY).clamp(0.3, 2.0);

    setState(() {
      _scale = newScale;
      _offset = Offset(
        size.width / 2 - graphCenterX * _scale,
        size.height / 2 - graphCenterY * _scale,
      );
    });
  }

  void _zoomAroundCenter(double factor) {
    final size = context.size ?? const Size(400, 400);
    final screenCenter = Offset(size.width / 2, size.height / 2);

    // Find the world point at screen center before zoom
    final worldPointAtCenter = (screenCenter - _offset) / _scale;

    // Apply zoom
    final newScale = (_scale * factor).clamp(0.3, 3.0);

    // Adjust offset so the same world point stays at screen center
    final newOffset = screenCenter - worldPointAtCenter * newScale;

    setState(() {
      _scale = newScale;
      _offset = newOffset;
    });
  }

  Widget _buildSelectedNodeInfo() {
    final node = _nodes.firstWhere((n) => n.id == _selectedNodeId);
    final entity = widget.entities.firstWhere((e) => e.id == _selectedNodeId);

    // Count connections
    final connections = _edges
        .where((e) =>
            e.sourceId == _selectedNodeId || e.targetId == _selectedNodeId)
        .length;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: node.color, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(node.icon, color: node.color, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  node.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white54, size: 18),
                onPressed: () => setState(() => _selectedNodeId = null),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Type: ${node.type}',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          Text(
            'Connections: $connections',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          if (entity.description != null && entity.description!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              entity.description!.length > 100
                  ? '${entity.description!.substring(0, 100)}...'
                  : entity.description!,
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}

class _GraphPainter extends CustomPainter {
  final List<GraphNode> nodes;
  final List<GraphEdge> edges;
  final Offset offset;
  final double scale;
  final String? selectedNodeId;
  final double Function(GraphNode node, {bool isSelected}) getNodeRadius;

  _GraphPainter({
    required this.nodes,
    required this.edges,
    required this.offset,
    required this.scale,
    required this.getNodeRadius,
    this.selectedNodeId,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(scale);

    final nodeMap = {for (var n in nodes) n.id: n};

    // Draw edges
    final edgePaint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    for (final edge in edges) {
      final source = nodeMap[edge.sourceId];
      final target = nodeMap[edge.targetId];

      if (source != null && target != null) {
        // Highlight edges connected to selected node
        if (selectedNodeId != null &&
            (edge.sourceId == selectedNodeId ||
                edge.targetId == selectedNodeId)) {
          edgePaint.color = Colors.white60;
          edgePaint.strokeWidth = 2.0;
        } else {
          edgePaint.color = Colors.white24;
          edgePaint.strokeWidth = 1.0;
        }

        canvas.drawLine(source.position, target.position, edgePaint);
      }
    }

    // Draw nodes
    for (final node in nodes) {
      final isSelected = node.id == selectedNodeId;
      final radius = getNodeRadius(node, isSelected: isSelected);

      // Node shadow
      canvas.drawCircle(
        node.position + const Offset(2, 2),
        radius,
        Paint()..color = Colors.black38,
      );

      // Node fill
      canvas.drawCircle(
        node.position,
        radius,
        Paint()..color = node.color,
      );

      // Node border (if selected)
      if (isSelected) {
        canvas.drawCircle(
          node.position,
          radius + 3,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }

      // Node label - adjust font size based on node size
      final fontSize = (radius * 0.5).clamp(8.0, 12.0);
      final textPainter = TextPainter(
        text: TextSpan(
          text: node.name.length > 10
              ? '${node.name.substring(0, 10)}...'
              : node.name,
          style: TextStyle(
            color: Colors.white,
            fontSize: isSelected ? fontSize + 1 : fontSize,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      textPainter.paint(
        canvas,
        node.position + Offset(-textPainter.width / 2, radius + 4),
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(_GraphPainter oldDelegate) => true;
}
