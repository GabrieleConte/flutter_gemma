import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_example/services/graph_rag_service.dart';
import 'package:flutter_gemma_example/widgets/graph_visualizer.dart';

/// Screen for managing the knowledge graph index and visualizing the graph
class GraphRAGIndexScreen extends StatefulWidget {
  const GraphRAGIndexScreen({super.key});

  @override
  State<GraphRAGIndexScreen> createState() => _GraphRAGIndexScreenState();
}

class _GraphRAGIndexScreenState extends State<GraphRAGIndexScreen> {
  final GraphRAGService _service = GraphRAGService.instance;

  // Stats and permissions
  GraphStatistics? _stats;
  Map<DataPermissionType, DataPermissionStatus>? _permissions;

  // Indexing progress
  StreamSubscription<IndexingProgress>? _progressSubscription;
  IndexingProgress? _indexingProgress;

  // Graph data for visualization
  List<GraphEntity> _entities = [];
  List<GraphRelationship> _relationships = [];
  bool _loadingGraph = false;

  // View mode: 'stats' or 'graph'
  String _viewMode = 'stats';

  @override
  void initState() {
    super.initState();
    _loadData();
    _subscribeToProgress();
  }

  @override
  void dispose() {
    _progressSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadData() async {
    await _loadStats();
    await _checkPermissions();
    await _loadGraphData();
  }

  void _subscribeToProgress() {
    _progressSubscription?.cancel();
    _progressSubscription = _service.progressStream?.listen((progress) {
      setState(() => _indexingProgress = progress);

      if (progress.status == IndexingStatus.completed) {
        _loadStats();
        _loadGraphData();
        _showSnackBar('Indexing completed! 🎉');
      } else if (progress.status == IndexingStatus.failed) {
        _showSnackBar('Indexing failed: ${progress.errorMessage}',
            isError: true);
      }
    });
  }

  Future<void> _loadStats() async {
    if (!_service.isInitialized) return;

    try {
      final stats = await _service.getStats();
      setState(() => _stats = stats);
    } catch (e) {
      debugPrint('Error loading stats: $e');
    }
  }

  Future<void> _checkPermissions() async {
    if (!_service.isInitialized) return;

    try {
      final permissions = await _service.checkPermissions();
      setState(() => _permissions = permissions);
    } catch (e) {
      debugPrint('Error checking permissions: $e');
    }
  }

  Future<void> _loadGraphData() async {
    if (!_service.isInitialized) return;

    setState(() => _loadingGraph = true);

    try {
      final entities = await _service.getAllEntities();
      final relationships = await _service.getAllRelationships(entities);

      setState(() {
        _entities = entities;
        _relationships = relationships;
        _loadingGraph = false;
      });
    } catch (e) {
      debugPrint('Error loading graph data: $e');
      setState(() => _loadingGraph = false);
    }
  }

  Future<void> _requestPermissions() async {
    try {
      final permissions = await _service.requestPermissions();
      setState(() => _permissions = permissions);

      final granted =
          permissions.values.every((s) => s == DataPermissionStatus.granted);

      if (granted) {
        _showSnackBar('All permissions granted ✅');
      } else {
        _showSnackBar('Some permissions were denied', isError: true);
      }
    } catch (e) {
      _showSnackBar('Error requesting permissions: $e', isError: true);
    }
  }

  Future<bool> _requestNotificationPermission() async {
    try {
      final platform = PlatformService();
      final status =
          await platform.requestPermission(PermissionType.notifications);
      if (status != PermissionStatus.granted) {
        _showSnackBar('Notification permission needed for background indexing',
            isError: true);
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('Error requesting notification permission: $e');
      return true;
    }
  }

  Future<void> _startIndexing({bool fullReindex = false}) async {
    try {
      await _requestNotificationPermission();
      await _service.startIndexing(fullReindex: fullReindex);
      _showSnackBar('Indexing started...');
    } catch (e) {
      _showSnackBar('Error: $e', isError: true);
    }
  }

  Future<void> _clearGraph() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Graph?'),
        content: const Text(
            'This will delete all indexed data. This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Clear'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _service.clearGraph();
        await _loadStats();
        setState(() {
          _entities = [];
          _relationships = [];
        });
        _showSnackBar('Graph cleared');
      } catch (e) {
        _showSnackBar('Error: $e', isError: true);
      }
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
        duration: Duration(seconds: isError ? 4 : 2),
      ),
    );
  }

  void _showEntityDetails(GraphEntity entity) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1a3a5c),
      builder: (context) => _buildEntityDetailsSheet(entity),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // View mode toggle
        _buildViewToggle(),

        // Content based on view mode
        Expanded(
          child: _viewMode == 'stats' ? _buildStatsView() : _buildGraphView(),
        ),
      ],
    );
  }

  Widget _buildViewToggle() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'stats',
                  label: Text('Stats & Index'),
                  icon: Icon(Icons.analytics),
                ),
                ButtonSegment(
                  value: 'graph',
                  label: Text('Visualize'),
                  icon: Icon(Icons.bubble_chart),
                ),
              ],
              selected: {_viewMode},
              onSelectionChanged: (selection) {
                setState(() => _viewMode = selection.first);
                if (_viewMode == 'graph' && _entities.isEmpty) {
                  _loadGraphData();
                }
              },
              style: ButtonStyle(
                backgroundColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.selected)) {
                    return Colors.orange;
                  }
                  return const Color(0xFF1a3a5c);
                }),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadData,
            tooltip: 'Refresh',
          ),
        ],
      ),
    );
  }

  Widget _buildStatsView() {
    final allPermissionsGranted = _permissions != null &&
        _permissions!.values.every((s) => s == DataPermissionStatus.granted);

    return SingleChildScrollView(
      child: Column(
        children: [
          _buildStatsCard(),
          if (!allPermissionsGranted) _buildPermissionsCard(),
          _buildIndexingCard(),
        ],
      ),
    );
  }

  Widget _buildGraphView() {
    if (_loadingGraph) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 16),
            Text(
              'Loading graph data...',
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ),
      );
    }

    return GraphVisualizer(
      entities: _entities,
      relationships: _relationships,
      onEntityTap: _showEntityDetails,
      enableClustering: true,
      clusterThreshold: 20,
    );
  }

  Widget _buildStatsCard() {
    return Card(
      margin: const EdgeInsets.all(8),
      color: const Color(0xFF1a3a5c),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _StatItem(
              icon: Icons.person,
              label: 'Entities',
              value: '${_stats?.entityCount ?? 0}',
            ),
            _StatItem(
              icon: Icons.link,
              label: 'Relationships',
              value: '${_stats?.relationshipCount ?? 0}',
            ),
            _StatItem(
              icon: Icons.groups,
              label: 'Communities',
              value: '${_stats?.communityCount ?? 0}',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPermissionsCard() {
    final contactsGranted = _permissions?[DataPermissionType.contacts] ==
        DataPermissionStatus.granted;
    final calendarGranted = _permissions?[DataPermissionType.calendar] ==
        DataPermissionStatus.granted;
    final photosGranted = _permissions?[DataPermissionType.photos] ==
        DataPermissionStatus.granted;
    final callLogGranted = _permissions?[DataPermissionType.callLog] ==
        DataPermissionStatus.granted;
    final callLogRestricted = _permissions?[DataPermissionType.callLog] ==
        DataPermissionStatus.restricted;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      color: const Color(0xFF1a3a5c),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Permissions',
                  style:
                      TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _requestPermissions,
                  child: const Text('Request All'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _PermissionChip(
                  label: 'Contacts',
                  granted: contactsGranted,
                ),
                _PermissionChip(
                  label: 'Calendar',
                  granted: calendarGranted,
                ),
                _PermissionChip(
                  label: 'Photos',
                  granted: photosGranted,
                ),
                _PermissionChip(
                  label: 'Call Log',
                  granted: callLogGranted,
                  restricted: callLogRestricted,
                ),
              ],
            ),
            if (callLogRestricted)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Note: Call log is not available on iOS',
                  style: TextStyle(fontSize: 11, color: Colors.white54, fontStyle: FontStyle.italic),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildIndexingCard() {
    final progress = _indexingProgress;
    final isRunning = progress?.status == IndexingStatus.running;
    final isPaused = progress?.status == IndexingStatus.paused;

    return Card(
      margin: const EdgeInsets.all(8),
      color: const Color(0xFF1a3a5c),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Indexing',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.white),
                ),
                const Spacer(),
                if (isRunning || isPaused) ...[
                  IconButton(
                    icon: Icon(isPaused ? Icons.play_arrow : Icons.pause),
                    onPressed: isPaused
                        ? _service.resumeIndexing
                        : _service.pauseIndexing,
                    iconSize: 20,
                  ),
                  IconButton(
                    icon: const Icon(Icons.stop),
                    onPressed: () async {
                      await _service.cancelIndexing();
                    },
                    iconSize: 20,
                  ),
                ] else ...[
                  TextButton(
                    onPressed: () => _startIndexing(),
                    child: const Text('Start'),
                  ),
                  TextButton(
                    onPressed: () => _startIndexing(fullReindex: true),
                    child: const Text('Full Reindex'),
                  ),
                ],
              ],
            ),
            if (progress != null && (isRunning || isPaused)) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: progress.progress,
                backgroundColor: Colors.white24,
              ),
              const SizedBox(height: 4),
              Text(
                '${progress.currentPhase} - ${(progress.progress * 100).toStringAsFixed(0)}%',
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
              Text(
                'Entities: ${progress.extractedEntities} extracted → ${progress.uniqueEntitiesStored} stored',
                style: const TextStyle(fontSize: 12, color: Colors.white54),
              ),
              Text(
                'Relationships: ${progress.extractedRelationships}',
                style: const TextStyle(fontSize: 12, color: Colors.white54),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _clearGraph,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Clear Graph'),
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEntityDetailsSheet(GraphEntity entity) {
    // Find connected entities
    final connectedRelationships = _relationships
        .where((r) => r.sourceId == entity.id || r.targetId == entity.id)
        .toList();

    final connectedEntityIds = connectedRelationships
        .map((r) => r.sourceId == entity.id ? r.targetId : r.sourceId)
        .toSet();

    final connectedEntities =
        _entities.where((e) => connectedEntityIds.contains(e.id)).toList();

    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _getTypeColor(entity.type),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  entity.type,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  entity.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          if (entity.description != null && entity.description!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              entity.description!,
              style: const TextStyle(color: Colors.white70),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            'Connected to ${connectedEntities.length} entities:',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          if (connectedEntities.isEmpty)
            const Text(
              'No connections',
              style: TextStyle(color: Colors.white54),
            )
          else
            SizedBox(
              height: 120,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: connectedEntities.take(10).length,
                itemBuilder: (context, index) {
                  final connected = connectedEntities[index];
                  return Card(
                    color: const Color(0xFF0b2351),
                    margin: const EdgeInsets.only(right: 8),
                    child: Container(
                      width: 120,
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 2),
                            decoration: BoxDecoration(
                              color: _getTypeColor(connected.type),
                              borderRadius: BorderRadius.circular(2),
                            ),
                            child: Text(
                              connected.type,
                              style: const TextStyle(
                                  fontSize: 9, color: Colors.white),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            connected.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const Spacer(),
                          // Show relationship type
                          ...connectedRelationships
                              .where((r) =>
                                  (r.sourceId == entity.id &&
                                      r.targetId == connected.id) ||
                                  (r.targetId == entity.id &&
                                      r.sourceId == connected.id))
                              .take(1)
                              .map((r) => Text(
                                    r.type,
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 10,
                                    ),
                                  )),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Color _getTypeColor(String type) {
    switch (type.toUpperCase()) {
      case 'SELF':
        return Colors.amber; // Golden color for "You" node
      case 'PERSON':
        return Colors.blue;
      case 'ORGANIZATION':
        return Colors.green;
      case 'EVENT':
        return Colors.orange;
      case 'LOCATION':
        return Colors.purple;
      case 'PHOTO':
        return Colors.pink;
      case 'PHONE_CALL':
        return Colors.teal;
      case 'DOCUMENT':
        return Colors.brown;
      case 'NOTE':
        return Colors.cyan;
      case 'PROJECT':
        return Colors.indigo;
      case 'TOPIC':
        return Colors.lime;
      case 'DATE':
        return Colors.deepOrange;
      case 'EMAIL':
        return Colors.lightBlue;
      case 'PHONE':
        return Colors.deepPurple;
      default:
        return Colors.grey;
    }
  }
}

// Helper widgets

class _StatItem extends StatelessWidget {
  const _StatItem({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: Colors.blue, size: 24),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: Colors.white70),
        ),
      ],
    );
  }
}

class _PermissionChip extends StatelessWidget {
  const _PermissionChip({
    required this.label,
    required this.granted,
    this.restricted = false,
  });

  final String label;
  final bool granted;
  final bool restricted;

  @override
  Widget build(BuildContext context) {
    final IconData icon;
    final Color color;
    
    if (restricted) {
      icon = Icons.block;
      color = Colors.grey;
    } else if (granted) {
      icon = Icons.check_circle;
      color = Colors.green;
    } else {
      icon = Icons.cancel;
      color = Colors.red;
    }
    
    return Chip(
      avatar: Icon(icon, color: color, size: 18),
      label: Text(label),
      backgroundColor: const Color(0xFF0b2351),
    );
  }
}
