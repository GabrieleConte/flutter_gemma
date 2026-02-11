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

  /// Number of child entities (only meaningful for HUB nodes)
  final int childCount;

  GraphNode({
    required this.id,
    required this.name,
    required this.type,
    required this.position,
    this.childCount = 0,
  })  : velocity = Offset.zero,
        isDragging = false;

  Color get color {
    switch (type.toUpperCase()) {
      case 'SELF':
        return Colors.amber;
      case 'HUB':
        return Colors.indigo.shade300;
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
      case 'NOTE_CHUNK':
        return Colors.cyan.shade700;
      case 'DOCUMENT_CHUNK':
        return Colors.deepOrange.shade700;
      case 'PROJECT':
        return Colors.deepPurple;
      case 'TOPIC':
        return Colors.pinkAccent;
      case 'DATE':
        return Colors.brown;
      case 'ALARM':
        return Colors.redAccent;
      case 'EMAIL':
        return Colors.red.shade300;
      case 'PHONE':
        return Colors.lightGreen;
      default:
        return Colors.grey;
    }
  }

  IconData get icon {
    switch (type.toUpperCase()) {
      case 'SELF':
        return Icons.account_circle;
      case 'HUB':
        return Icons.hub;
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
      case 'NOTE_CHUNK':
        return Icons.note;
      case 'DOCUMENT_CHUNK':
        return Icons.article;
      case 'PROJECT':
        return Icons.folder;
      case 'TOPIC':
        return Icons.tag;
      case 'DATE':
        return Icons.calendar_today;
      case 'ALARM':
        return Icons.alarm;
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

  /// Role determines rest-length and rendering style
  final EdgeRole role;

  GraphEdge({
    required this.sourceId,
    required this.targetId,
    required this.type,
    this.weight = 1.0,
    this.role = EdgeRole.entityToEntity,
  });
}

/// Semantic role of an edge — controls spring rest-length and visual style
enum EdgeRole {
  /// Hub -> You (thick, medium length)
  hubToYou,

  /// Entity -> Hub (thin, short)
  entityToHub,

  /// Entity -> You direct (medium, no hub)
  entityToYou,

  /// Entity <-> Entity relationship (thin, subtle)
  entityToEntity,
}

/// Interactive graph visualizer with force-directed layout and hub routing
class GraphVisualizer extends StatefulWidget {
  final List<GraphEntity> entities;
  final List<GraphRelationship> relationships;
  final void Function(GraphEntity entity)? onEntityTap;

  /// Entity types with MORE than this many entities will route through a HUB
  /// node instead of connecting directly to "You". Set to 0 to always use hubs.
  final int hubThreshold;

  const GraphVisualizer({
    super.key,
    required this.entities,
    required this.relationships,
    this.onEntityTap,
    this.hubThreshold = 5,
  });

  @override
  State<GraphVisualizer> createState() => _GraphVisualizerState();
}

class _GraphVisualizerState extends State<GraphVisualizer>
    with TickerProviderStateMixin {
  late List<GraphNode> _nodes;
  late List<GraphEdge> _edges;
  late AnimationController _simulationController;

  /// Which node-pair keys are connected via an edge (for reducing repulsion)
  final Set<String> _connectedPairs = {};

  // Transformation state
  Offset _offset = Offset.zero;
  double _scale = 1.0;
  Offset? _lastFocalPoint;

  // Selected node
  String? _selectedNodeId;
  GraphNode? _draggedNode;

  // Virtual canvas size
  double _virtualCanvasSize = 2000.0;

  // --- Force simulation constants ---
  static const double _repulsionStrength = 8000.0;
  static const double _minDistance = 60.0;
  static const double _springStrength = 0.03;
  static const double _damping = 0.85;
  static const double _velocityThreshold = 0.2;
  static const double _centerGravity = 0.005;
  static const double _youCenterGravity = 0.02;
  int _simulationTick = 0;

  /// Rest-lengths per edge role
  static double _restLength(EdgeRole role) {
    switch (role) {
      case EdgeRole.hubToYou:
        return 200.0;
      case EdgeRole.entityToHub:
        return 130.0;
      case EdgeRole.entityToYou:
        return 160.0;
      case EdgeRole.entityToEntity:
        return 110.0;
    }
  }

  // --- Node sizing ---
  double _getNodeRadius(GraphNode node, {bool isSelected = false}) {
    final totalNodes = _nodes.length;
    final scaleFactor = (40.0 / totalNodes).clamp(0.6, 1.0);

    double baseRadius;
    switch (node.type.toUpperCase()) {
      case 'SELF':
        baseRadius = 30.0;
        break;
      case 'HUB':
        baseRadius = 20.0 + min(node.childCount * 0.5, 8.0);
        break;
      case 'PERSON':
        baseRadius = 14.0;
        break;
      case 'ALARM':
      case 'EVENT':
        baseRadius = 14.0;
        break;
      default:
        baseRadius = 11.0;
    }

    final r = baseRadius * scaleFactor;
    return isSelected ? r * 1.2 : r;
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

  // =====================================================================
  //  GRAPH INITIALIZATION — hub routing + radial initial placement
  // =====================================================================

  void _initializeGraph() {
    _simulationTick = 0;
    final random = Random(42);
    final totalEntities = widget.entities.length;
    _virtualCanvasSize = (1500.0 + totalEntities * 30).clamp(1500.0, 5000.0);
    final cx = _virtualCanvasSize / 2;
    final cy = _virtualCanvasSize / 2;

    // ---- 1. Build entity lookup ----
    final entityById = <String, GraphEntity>{};
    for (final e in widget.entities) {
      entityById[e.id] = e;
    }

    // ---- 2. Find hub entities and "You" entity ----
    final hubEntities = <String, GraphEntity>{};
    for (final e in widget.entities) {
      if (e.type == 'HUB') hubEntities[e.id] = e;
    }

    final youEntity = widget.entities.firstWhere(
      (e) => e.type == 'SELF',
      orElse: () => widget.entities.first,
    );

    // ---- 3. Determine hub children from ACTUAL relationships ----
    // Instead of guessing from type names, use the relationship data
    // to find which entities are connected to each hub.
    final hubChildren = <String, Set<String>>{}; // hubId -> set of child entity IDs
    for (final hubId in hubEntities.keys) {
      hubChildren[hubId] = <String>{};
    }
    for (final rel in widget.relationships) {
      final src = rel.sourceId;
      final tgt = rel.targetId;
      // If one side is a hub and the other is a normal entity, record it
      if (_isHub(src) && !_isHub(tgt) && !_isSelf(tgt) && hubChildren.containsKey(src)) {
        hubChildren[src]!.add(tgt);
      }
      if (_isHub(tgt) && !_isHub(src) && !_isSelf(src) && hubChildren.containsKey(tgt)) {
        hubChildren[tgt]!.add(src);
      }
    }

    // ---- 4. Decide which hubs are visible (children >= threshold) ----
    final visibleHubIds = <String>{};
    for (final entry in hubChildren.entries) {
      if (entry.value.length >= widget.hubThreshold) {
        visibleHubIds.add(entry.key);
      }
    }

    // Track which entities are routed through a visible hub
    final hubRoutedEntityIds = <String>{};
    for (final hubId in visibleHubIds) {
      hubRoutedEntityIds.addAll(hubChildren[hubId]!);
    }

    // ---- 5. Build visible entity set ----
    final visibleEntities = widget.entities.where((e) {
      if (e.type == 'HUB') return visibleHubIds.contains(e.id);
      return true;
    }).toList();

    // ---- 6. Radial initial placement ----
    final nodeMap = <String, GraphNode>{};
    final entityIdSet = visibleEntities.map((e) => e.id).toSet();

    // Place "You" at center
    nodeMap[youEntity.id] = GraphNode(
      id: youEntity.id,
      name: youEntity.name,
      type: youEntity.type,
      position: Offset(cx, cy),
    );

    // Place hub nodes in an inner ring around "You"
    final hubList = visibleHubIds.toList();
    const hubRingRadius = 250.0;
    for (var i = 0; i < hubList.length; i++) {
      final hubId = hubList[i];
      final hubEntity = hubEntities[hubId]!;
      final childCount = hubChildren[hubId]?.length ?? 0;
      final angle = (2 * pi * i) / hubList.length - pi / 2;
      nodeMap[hubId] = GraphNode(
        id: hubId,
        name: hubEntity.name,
        type: hubEntity.type,
        position: Offset(
          cx + cos(angle) * hubRingRadius,
          cy + sin(angle) * hubRingRadius,
        ),
        childCount: childCount,
      );
    }

    // Place hub-routed entities around their hub
    for (final hubId in hubList) {
      final children = hubChildren[hubId]!
          .where((id) => entityById.containsKey(id))
          .map((id) => entityById[id]!)
          .toList();
      final hubPos = nodeMap[hubId]!.position;
      final childRadius = 120.0 + min(children.length * 12.0, 400.0);
      for (var ci = 0; ci < children.length; ci++) {
        final child = children[ci];
        if (nodeMap.containsKey(child.id)) continue;
        final angle = ci * 2.39996; // golden angle
        final ringIndex = ci ~/ 10;
        final r = childRadius + ringIndex * 60.0;
        final jitter = (random.nextDouble() - 0.5) * 20;
        nodeMap[child.id] = GraphNode(
          id: child.id,
          name: child.name,
          type: child.type,
          position: Offset(
            hubPos.dx + cos(angle) * r + jitter,
            hubPos.dy + sin(angle) * r + jitter,
          ),
        );
      }
    }

    // Place non-hub entities in a ring around "You"
    // Transitive/metadata types should NOT link to You — they float
    // near the primary entities they're connected to via data-layer edges.
    const transitiveTypes = {
      'DATE', 'LOCATION', 'ORGANIZATION', 'EMAIL', 'PHONE',
      'TOPIC', 'PROJECT', 'NOTE_CHUNK', 'DOCUMENT_CHUNK',
    };
    final nonHubEntities = visibleEntities
        .where(
            (e) => !nodeMap.containsKey(e.id) && e.type != 'SELF' && e.type != 'HUB')
        .toList();
    final primaryNonHub = nonHubEntities
        .where((e) => !transitiveTypes.contains(e.type.toUpperCase()))
        .toList();
    final transitiveNonHub = nonHubEntities
        .where((e) => transitiveTypes.contains(e.type.toUpperCase()))
        .toList();

    // Primary entities: inner ring around You
    final directRingRadius = 180.0 + min(primaryNonHub.length * 15.0, 300.0);
    for (var i = 0; i < primaryNonHub.length; i++) {
      final e = primaryNonHub[i];
      final angle = i * 2.39996;
      final ringIndex = i ~/ 8;
      final r = directRingRadius + ringIndex * 50.0;
      final jitter = (random.nextDouble() - 0.5) * 20;
      nodeMap[e.id] = GraphNode(
        id: e.id,
        name: e.name,
        type: e.type,
        position: Offset(
          cx + cos(angle) * r + jitter,
          cy + sin(angle) * r + jitter,
        ),
      );
    }

    // Transitive entities: outer ring — spring forces pull them
    // towards whichever primary entities they're related to.
    final outerRingRadius = directRingRadius + 200.0;
    for (var i = 0; i < transitiveNonHub.length; i++) {
      final e = transitiveNonHub[i];
      final angle = i * 2.39996;
      final jitter = (random.nextDouble() - 0.5) * 30;
      nodeMap[e.id] = GraphNode(
        id: e.id,
        name: e.name,
        type: e.type,
        position: Offset(
          cx + cos(angle) * outerRingRadius + jitter,
          cy + sin(angle) * outerRingRadius + jitter,
        ),
      );
    }

    _nodes = nodeMap.values.toList();

    // ---- 7. Build edges ----
    _edges = [];
    _connectedPairs.clear();
    final addedEdges = <String>{};

    void addEdge(
        String src, String tgt, String type, double weight, EdgeRole role) {
      if (src == tgt) return;
      if (!entityIdSet.contains(src) || !entityIdSet.contains(tgt)) return;
      final key = src.compareTo(tgt) < 0 ? '$src|$tgt' : '$tgt|$src';
      if (addedEdges.contains(key)) return;
      addedEdges.add(key);
      _edges.add(GraphEdge(
        sourceId: src,
        targetId: tgt,
        type: type,
        weight: weight,
        role: role,
      ));
      _connectedPairs.add(key);
    }

    // 7a. Data-layer relationships (skip edges involving hidden hubs)
    for (final rel in widget.relationships) {
      if (!entityIdSet.contains(rel.sourceId) ||
          !entityIdSet.contains(rel.targetId)) {
        continue;
      }

      EdgeRole role;
      if ((_isHub(rel.sourceId) && _isSelf(rel.targetId)) ||
          (_isSelf(rel.sourceId) && _isHub(rel.targetId))) {
        role = EdgeRole.hubToYou;
      } else if (_isHub(rel.sourceId) || _isHub(rel.targetId)) {
        role = EdgeRole.entityToHub;
      } else if (_isSelf(rel.sourceId) || _isSelf(rel.targetId)) {
        role = EdgeRole.entityToYou;
      } else {
        role = EdgeRole.entityToEntity;
      }

      addEdge(rel.sourceId, rel.targetId, rel.type, rel.weight, role);
    }

    // 7b. Ensure every visible hub is connected to "You"
    for (final hubId in visibleHubIds) {
      addEdge(youEntity.id, hubId, 'HAS_DATA', 1.0, EdgeRole.hubToYou);
    }

    // 7c. Ensure hub-routed entities have edges to their hub
    for (final hubId in visibleHubIds) {
      for (final childId in hubChildren[hubId]!) {
        if (childId == youEntity.id) continue;
        if (!entityIdSet.contains(childId)) continue;
        addEdge(hubId, childId, 'CONTAINS', 0.6, EdgeRole.entityToHub);
      }
    }

    // 7d. Only PRIMARY non-hub entities connect directly to "You".
    //     Transitive entities (DATE, LOCATION, etc.) keep only their
    //     data-layer edges — no synthetic link to You.
    for (final e in primaryNonHub) {
      addEdge(youEntity.id, e.id, 'RELATED_TO', 0.4, EdgeRole.entityToYou);
    }

    // ---- 8. Initial view offset ----
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fitAllNodes();
    });
  }

  bool _isHub(String id) => id.startsWith('hub_');
  bool _isSelf(String id) => id == 'you_central_node';

  // =====================================================================
  //  FORCE-DIRECTED PHYSICS — Coulomb + Hooke + centering gravity
  // =====================================================================

  void _simulateStep() {
    if (_nodes.isEmpty) return;
    _simulationTick++;

    final virtualCenter =
        Offset(_virtualCanvasSize / 2, _virtualCanvasSize / 2);

    for (final node in _nodes) {
      if (node.isDragging) continue;

      var force = Offset.zero;

      // --- Coulomb repulsion from every other node ---
      for (final other in _nodes) {
        if (other.id == node.id) continue;

        final delta = node.position - other.position;
        final dist = max(delta.distance, 1.0);
        final effectiveDist = max(dist, _minDistance);

        // Reduce repulsion between connected nodes so edges can stay shorter
        final pairKey = node.id.compareTo(other.id) < 0
            ? '${node.id}|${other.id}'
            : '${other.id}|${node.id}';
        final connected = _connectedPairs.contains(pairKey);
        final repulsionScale = connected ? 0.3 : 1.0;

        final repulsion = (delta / effectiveDist) *
            (_repulsionStrength *
                repulsionScale /
                (effectiveDist * effectiveDist));
        force += repulsion;
      }

      // --- Hooke spring attraction along edges ---
      for (final edge in _edges) {
        GraphNode? other;
        if (edge.sourceId == node.id) {
          other = _nodeById(edge.targetId);
        } else if (edge.targetId == node.id) {
          other = _nodeById(edge.sourceId);
        }
        if (other == null) continue;

        final delta = other.position - node.position;
        final dist = delta.distance;
        if (dist < 0.1) continue;
        final rest = _restLength(edge.role);
        final displacement = dist - rest;
        final springForce =
            (delta / dist) * (_springStrength * displacement * edge.weight);
        force += springForce;
      }

      // --- Centering gravity ---
      final toCenter = virtualCenter - node.position;
      final gravity =
          node.type == 'SELF' ? _youCenterGravity : _centerGravity;
      force += toCenter * gravity;

      // --- Integrate velocity ---
      node.velocity = (node.velocity + force) * _damping;
      if (node.velocity.distance < _velocityThreshold) {
        node.velocity = Offset.zero;
      } else {
        node.position += node.velocity;
      }

      // Clamp to virtual canvas
      node.position = Offset(
        node.position.dx.clamp(50.0, _virtualCanvasSize - 50.0),
        node.position.dy.clamp(50.0, _virtualCanvasSize - 50.0),
      );
    }

    // --- Overlap resolution pass (only during initial settling) ---
    if (_simulationTick <= 120) {
      for (int i = 0; i < _nodes.length; i++) {
        for (int j = i + 1; j < _nodes.length; j++) {
          final a = _nodes[i];
          final b = _nodes[j];
          if (a.isDragging || b.isDragging) continue;
          final delta = a.position - b.position;
          final dist = max(delta.distance, 0.1);
          final rA = _getNodeRadius(a);
          final rB = _getNodeRadius(b);
          final minSep = rA + rB + 6.0;
          if (dist < minSep) {
            final push = (delta / dist) * ((minSep - dist) * 0.4);
            if (!a.isDragging) a.position += push;
            if (!b.isDragging) b.position -= push;
          }
        }
      }
    }

    setState(() {});
  }

  GraphNode? _nodeById(String id) {
    for (final n in _nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  // =====================================================================
  //  HIT TESTING
  // =====================================================================

  GraphNode? _findNodeAt(Offset position) {
    final transformed = (position - _offset) / _scale;
    for (final node in _nodes.reversed) {
      final r = _getNodeRadius(node);
      if ((node.position - transformed).distance < r + 8) {
        return node;
      }
    }
    return null;
  }

  // =====================================================================
  //  BUILD
  // =====================================================================

  @override
  Widget build(BuildContext context) {
    if (_nodes.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.account_tree, size: 64, color: Colors.white24),
            SizedBox(height: 16),
            Text('No entities to visualize',
                style: TextStyle(color: Colors.white54)),
            Text('Index some data first',
                style: TextStyle(color: Colors.white38, fontSize: 12)),
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
            final delta =
                details.focalPoint - (_lastFocalPoint ?? details.focalPoint);
            _draggedNode!.position += delta / _scale;
            _draggedNode!.velocity = Offset.zero;
          } else if (details.scale != 1.0) {
            _scale = (_scale * details.scale).clamp(0.3, 3.0);
          } else {
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
            Positioned(top: 8, left: 8, child: _buildLegend()),
            Positioned(bottom: 8, right: 8, child: _buildControls()),
            Positioned(top: 8, right: 8, child: _buildNodeCount()),
            if (_selectedNodeId != null)
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

  // =====================================================================
  //  UI HELPERS
  // =====================================================================

  Widget _buildLegend() {
    final types = _nodes.map((n) => n.type).toSet().toList()..sort();
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
          const Text('Entity Types',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold)),
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
                  Text(type,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 11)),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildNodeCount() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${widget.entities.length} entities total',
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
          Text('${_nodes.length} nodes, ${_edges.length} edges',
              style: const TextStyle(color: Colors.white54, fontSize: 11)),
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

  Widget _buildSelectedNodeInfo() {
    final node = _nodes.firstWhere(
      (n) => n.id == _selectedNodeId,
      orElse: () => _nodes.first,
    );
    final entity = widget.entities.firstWhere(
      (e) => e.id == _selectedNodeId,
      orElse: () => widget.entities.first,
    );
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
                child: Text(node.name,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis),
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
          Text('Type: ${node.type}',
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
          Text('Connections: $connections',
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
          if (entity.description != null &&
              entity.description!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              entity.description!.length > 100
                  ? '${entity.description!.substring(0, 100)}...'
                  : entity.description!,
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
          // Show key metadata per entity type
          ..._buildCompactMeta(entity, node),
        ],
      ),
    );
  }

  /// Return 1-2 lines of key metadata for the selected node.
  List<Widget> _buildCompactMeta(GraphEntity entity, GraphNode node) {
    final meta = entity.metadata;
    if (meta == null || meta.isEmpty) return [];

    String? line1;
    String? line2;

    switch (node.type.toUpperCase()) {
      case 'ALARM':
        final time = meta['time'];
        final date = meta['date'];
        final recurrence = meta['recurrence'];
        line1 = [if (date != null) date, if (time != null) 'at $time']
            .join(' ');
        if (recurrence != null) line2 = 'Repeats: $recurrence';
        break;
      case 'PERSON':
        final phones = meta['phoneNumbers'] ?? meta['telephoneNumber'];
        final org = meta['organizationName'] ?? meta['organization'];
        if (phones is List && phones.isNotEmpty) {
          line1 = '\u{1F4DE} ${phones.first}';
        } else if (phones != null) {
          line1 = '\u{1F4DE} $phones';
        }
        if (org != null) line2 = '\u{1F3E2} $org';
        break;
      case 'PHOTO':
        final date = meta['creationDate'];
        final dims = (meta['width'] != null && meta['height'] != null)
            ? '${meta['width']}\u00D7${meta['height']}'
            : null;
        if (date != null) line1 = '\u{1F4C5} $date';
        if (dims != null) line2 = '\u{1F4D0} $dims';
        break;
      case 'PHONE_CALL':
        final dir = meta['callDirection'] ?? meta['callType'];
        final num = meta['phoneNumber'];
        if (dir != null) line1 = '\u{1F4DE} ${dir.toString().toUpperCase()}';
        if (num != null) line2 = num.toString();
        break;
      case 'EVENT':
        final start = meta['startDate'];
        final recurrence = meta['recurrenceInfo'];
        if (start != null) line1 = '\u{1F4C5} $start';
        if (recurrence == 'recurrent') {
          line2 = '\u{1F501} ${meta['repeatFrequency'] ?? 'recurring'}';
        }
        break;
      case 'NOTE':
        final created = meta['dateCreated'];
        if (created != null) line1 = '\u{1F4C5} $created';
        break;
    }

    final widgets = <Widget>[];
    if (line1 != null && line1.isNotEmpty) {
      widgets.add(const SizedBox(height: 2));
      widgets.add(Text(line1,
          style: const TextStyle(color: Colors.white60, fontSize: 10),
          overflow: TextOverflow.ellipsis));
    }
    if (line2 != null && line2.isNotEmpty) {
      widgets.add(Text(line2,
          style: const TextStyle(color: Colors.white60, fontSize: 10),
          overflow: TextOverflow.ellipsis));
    }
    return widgets;
  }

  // =====================================================================
  //  VIEW TRANSFORMS
  // =====================================================================

  void _centerOnGraph() {
    if (_nodes.isEmpty) return;
    final size = context.size ?? const Size(400, 400);
    double sumX = 0, sumY = 0;
    for (final node in _nodes) {
      sumX += node.position.dx;
      sumY += node.position.dy;
    }
    final gcx = sumX / _nodes.length;
    final gcy = sumY / _nodes.length;
    setState(() {
      _scale = 1.0;
      _offset = Offset(
          size.width / 2 - gcx * _scale, size.height / 2 - gcy * _scale);
    });
  }

  void _fitAllNodes() {
    if (_nodes.isEmpty) return;
    final size = context.size ?? const Size(400, 400);
    double minX = double.infinity, maxX = double.negativeInfinity;
    double minY = double.infinity, maxY = double.negativeInfinity;
    for (final node in _nodes) {
      minX = min(minX, node.position.dx);
      maxX = max(maxX, node.position.dx);
      minY = min(minY, node.position.dy);
      maxY = max(maxY, node.position.dy);
    }
    final gw = maxX - minX + 100;
    final gh = maxY - minY + 100;
    final gcx = (minX + maxX) / 2;
    final gcy = (minY + maxY) / 2;
    final sx = (size.width - 80) / gw;
    final sy = (size.height - 120) / gh;
    final ns = min(sx, sy).clamp(0.3, 2.0);
    setState(() {
      _scale = ns;
      _offset = Offset(
          size.width / 2 - gcx * _scale, size.height / 2 - gcy * _scale);
    });
  }

  void _zoomAroundCenter(double factor) {
    final size = context.size ?? const Size(400, 400);
    final sc = Offset(size.width / 2, size.height / 2);
    final wp = (sc - _offset) / _scale;
    final ns = (_scale * factor).clamp(0.3, 3.0);
    setState(() {
      _scale = ns;
      _offset = sc - wp * ns;
    });
  }
}

// =======================================================================
//  CUSTOM PAINTER
// =======================================================================

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
    final edgePaint = Paint()..style = PaintingStyle.stroke;

    // ---- Draw edges ----
    for (final edge in edges) {
      final source = nodeMap[edge.sourceId];
      final target = nodeMap[edge.targetId];
      if (source == null || target == null) continue;

      final isSelected = selectedNodeId != null &&
          (edge.sourceId == selectedNodeId || edge.targetId == selectedNodeId);

      if (isSelected) {
        edgePaint
          ..color = Colors.white60
          ..strokeWidth = 2.5;
      } else {
        switch (edge.role) {
          case EdgeRole.hubToYou:
            edgePaint
              ..color = Colors.white38
              ..strokeWidth = 2.0;
            break;
          case EdgeRole.entityToHub:
            edgePaint
              ..color = const Color(0x29FFFFFF)
              ..strokeWidth = 1.0;
            break;
          case EdgeRole.entityToYou:
            edgePaint
              ..color = Colors.white24
              ..strokeWidth = 1.2;
            break;
          case EdgeRole.entityToEntity:
            edgePaint
              ..color = Colors.white12
              ..strokeWidth = 0.8;
            break;
        }
      }

      canvas.drawLine(source.position, target.position, edgePaint);
    }

    // ---- Draw nodes ----
    for (final node in nodes) {
      final isSelected = node.id == selectedNodeId;
      final radius = getNodeRadius(node, isSelected: isSelected);

      // Glow for "You" node
      if (node.type == 'SELF') {
        canvas.drawCircle(
          node.position,
          radius + 8,
          Paint()..color = Colors.amber.withValues(alpha: 0.15),
        );
        canvas.drawCircle(
          node.position,
          radius + 4,
          Paint()..color = Colors.amber.withValues(alpha: 0.25),
        );
      }

      // Hub ring outline
      if (node.type == 'HUB') {
        canvas.drawCircle(
          node.position,
          radius + 3,
          Paint()
            ..color = node.color.withValues(alpha: 0.3)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5,
        );
      }

      // Shadow
      canvas.drawCircle(
        node.position + const Offset(1.5, 1.5),
        radius,
        Paint()..color = Colors.black26,
      );

      // Fill
      canvas.drawCircle(
        node.position,
        radius,
        Paint()..color = node.color,
      );

      // Selection border
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

      // Label
      final fontSize = (radius * 0.55).clamp(8.0, 13.0);
      final label = node.name.length > 14
          ? '${node.name.substring(0, 14)}...'
          : node.name;
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: Colors.white,
            fontSize: isSelected ? fontSize + 1 : fontSize,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, node.position + Offset(-tp.width / 2, radius + 4));
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(_GraphPainter oldDelegate) => true;
}
