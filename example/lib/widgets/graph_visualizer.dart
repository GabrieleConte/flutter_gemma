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
  
  /// Whether this is a cluster node
  bool get isCluster => clusterEntityIds != null && clusterEntityIds!.isNotEmpty;

  GraphNode({
    required this.id,
    required this.name,
    required this.type,
    required this.position,
    this.clusterEntityIds,
  })  : velocity = Offset.zero,
        isDragging = false;

  Color get color {
    if (isCluster) return Colors.blueGrey;
    
    switch (type.toUpperCase()) {
      case 'SELF':
        return Colors.amber; // "You" central node - golden
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
    this.clusterThreshold = 20,
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
    const centerX = 200.0;
    const centerY = 200.0;

    if (widget.enableClustering) {
      _initializeWithClustering(random, centerX, centerY);
    } else {
      _initializeWithoutClustering(random, centerX, centerY);
    }
  }
  
  void _initializeWithClustering(Random random, double centerX, double centerY) {
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
          // Show all entities from expanded cluster
          unclustered.addAll(entities);
        } else {
          // Create cluster node
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
    
    // Create nodes for unclustered entities
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
    
    // Add cluster nodes
    for (final cluster in _clusters.values) {
      _nodes.add(GraphNode(
        id: cluster.id,
        name: cluster.name,
        type: cluster.dominantType,
        position: Offset(
          centerX + (random.nextDouble() - 0.5) * 300,
          centerY + (random.nextDouble() - 0.5) * 300,
        ),
        clusterEntityIds: cluster.entities.map((e) => e.id).toList(),
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
      final sourceVisible = visibleEntityIds.contains(sourceId) || _clusters.containsKey(sourceId);
      final targetVisible = visibleEntityIds.contains(targetId) || _clusters.containsKey(targetId);
      
      if (sourceVisible && targetVisible && sourceId != targetId) {
        // Avoid duplicate edges
        final edgeExists = _edges.any(
          (e) => (e.sourceId == sourceId && e.targetId == targetId) ||
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
  }
  
  void _initializeWithoutClustering(Random random, double centerX, double centerY) {
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
  }
  
  void _toggleCluster(String clusterId) {
    setState(() {
      if (_expandedClusters.contains(clusterId)) {
        _expandedClusters.remove(clusterId);
      } else {
        _expandedClusters.add(clusterId);
      }
      _initializeGraph();
    });
  }

  void _simulateStep() {
    if (_nodes.isEmpty) return;

    final size = context.size ?? const Size(400, 400);
    final center = Offset(size.width / 2, size.height / 2);

    // Calculate forces for each node
    for (final node in _nodes) {
      if (node.isDragging) continue;

      var force = Offset.zero;

      // Repulsion from other nodes
      for (final other in _nodes) {
        if (other.id == node.id) continue;

        final delta = node.position - other.position;
        final distance = max(delta.distance, _minDistance);
        final repulsion =
            delta / distance * (_repulsionStrength / (distance * distance));
        force += repulsion;
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
          final attraction = delta * _attractionStrength * edge.weight;
          force += attraction;
        }
      }

      // Centering force
      final toCenter = center - node.position;
      force += toCenter * _centeringStrength;

      // Update velocity and position
      node.velocity = (node.velocity + force) * _damping;
      node.position += node.velocity;

      // Keep within bounds
      node.position = Offset(
        node.position.dx.clamp(50, size.width - 50),
        node.position.dy.clamp(50, size.height - 50),
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
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    Text(
                      '${_nodes.length} nodes, ${_edges.length} edges shown',
                      style: const TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                    if (_clusters.isNotEmpty)
                      Text(
                        '${_clusters.length} clusters (tap to expand)',
                        style: const TextStyle(color: Colors.white38, fontSize: 10),
                      ),
                  ],
                ),
              ),
            ),

            // Selected node info
            if (_selectedNodeId != null && !_selectedNodeId!.startsWith('cluster_'))
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
          onPressed: () =>
              setState(() => _scale = (_scale * 1.2).clamp(0.3, 3.0)),
          backgroundColor: Colors.white24,
          child: const Icon(Icons.add, color: Colors.white),
        ),
        const SizedBox(height: 8),
        FloatingActionButton.small(
          heroTag: 'zoom_out',
          onPressed: () =>
              setState(() => _scale = (_scale / 1.2).clamp(0.3, 3.0)),
          backgroundColor: Colors.white24,
          child: const Icon(Icons.remove, color: Colors.white),
        ),
        const SizedBox(height: 8),
        FloatingActionButton.small(
          heroTag: 'reset',
          onPressed: () => setState(() {
            _scale = 1.0;
            _offset = Offset.zero;
          }),
          backgroundColor: Colors.white24,
          child: const Icon(Icons.center_focus_strong, color: Colors.white),
        ),
      ],
    );
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

  _GraphPainter({
    required this.nodes,
    required this.edges,
    required this.offset,
    required this.scale,
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
      final radius = isSelected ? 22.0 : 18.0;

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

      // Node label
      final textPainter = TextPainter(
        text: TextSpan(
          text: node.name.length > 10
              ? '${node.name.substring(0, 10)}...'
              : node.name,
          style: TextStyle(
            color: Colors.white,
            fontSize: isSelected ? 11 : 9,
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
