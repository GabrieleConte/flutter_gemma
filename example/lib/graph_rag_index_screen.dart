import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_example/services/graph_rag_service.dart';
import 'package:flutter_gemma_example/widgets/graph_visualizer.dart';
import 'package:android_intent_plus/android_intent.dart';

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

  bool _isPickingDocuments = false;

  bool _isIndexingNote = false;

  bool _isIndexingAlarm = false;

  Future<void> _addNote() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => const _AddNoteDialog(),
    );

    if (result == null || result['content']?.isEmpty == true) {
      return;
    }

    setState(() => _isIndexingNote = true);

    try {
      final title = result['title']?.isNotEmpty == true
          ? result['title']!
          : 'Note ${DateTime.now().toIso8601String().substring(0, 16)}';
      final content = result['content']!;

      _showSnackBar('Indexing note "$title"...');

      await _service.indexNote(title: title, content: content);

      await _loadStats();
      await _loadGraphData();

      _showSnackBar('Note indexed successfully!');
    } catch (e) {
      _showSnackBar('Error indexing note: $e', isError: true);
    } finally {
      setState(() => _isIndexingNote = false);
    }
  }

  Future<void> _addAlarm() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => const _AddAlarmDialog(),
    );

    if (result == null || result['label']?.toString().isEmpty == true) {
      return;
    }

    setState(() => _isIndexingAlarm = true);

    try {
      final label = result['label'] as String;
      final dateTime = result['dateTime'] as DateTime;
      final recurrence = result['recurrence'] as String?;

      _showSnackBar('Indexing alarm "$label"...');

      await _service.indexAlarm(
        label: label,
        dateTime: dateTime,
        recurrence: recurrence,
      );

      await _loadStats();
      await _loadGraphData();

      _showSnackBar('Alarm indexed successfully!');

      // Open system clock app with pre-filled alarm data
      await _launchSystemAlarm(label, dateTime);
    } catch (e) {
      _showSnackBar('Error indexing alarm: $e', isError: true);
    } finally {
      setState(() => _isIndexingAlarm = false);
    }
  }

  /// Launch the system clock/alarm app with pre-filled data.
  Future<void> _launchSystemAlarm(String label, DateTime dateTime) async {
    try {
      if (Platform.isAndroid) {
        final intent = AndroidIntent(
          action: 'android.intent.action.SET_ALARM',
          arguments: <String, dynamic>{
            'android.intent.extra.alarm.MESSAGE': label,
            'android.intent.extra.alarm.HOUR': dateTime.hour,
            'android.intent.extra.alarm.MINUTES': dateTime.minute,
            'android.intent.extra.alarm.SKIP_UI': false,
          },
        );
        await intent.launch();
      } else {
        _showSnackBar('Alarm indexed. Set it in your Clock app too!');
      }
    } catch (e) {
      debugPrint('[GraphRAGIndexScreen] Could not launch clock app: $e');
      _showSnackBar('Alarm indexed. Set it in your Clock app too!');
    }
  }

  Future<void> _pickAndIndexDocuments() async {
    if (_isPickingDocuments) return;
    
    setState(() => _isPickingDocuments = true);
    
    try {
      _showSnackBar('Opening file picker...');
      
      // Pick documents using the native picker
      final documents = await _service.pickDocuments(allowMultiple: true);
      
      if (documents.isEmpty) {
        _showSnackBar('No documents selected');
        return;
      }
      
      _showSnackBar('Indexing ${documents.length} documents...');
      
      // Index selected documents
      await _service.indexDocuments(documents);
      
      // Reload stats and graph
      await _loadStats();
      await _loadGraphData();
      
      _showSnackBar('${documents.length} documents indexed! 🎉');
    } catch (e) {
      _showSnackBar('Error: $e', isError: true);
    } finally {
      setState(() => _isPickingDocuments = false);
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
      hubThreshold: 5,
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
    final filesGranted = _permissions?[DataPermissionType.files] ==
        DataPermissionStatus.granted;

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
                _PermissionChip(
                  label: 'Documents',
                  granted: filesGranted,
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
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                TextButton.icon(
                  onPressed: _isPickingDocuments ? null : _pickAndIndexDocuments,
                  icon: _isPickingDocuments
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white70,
                        ),
                      )
                    : const Icon(Icons.file_open, size: 18),
                  label: Text(_isPickingDocuments ? 'Selecting...' : 'Select Files'),
                  style: TextButton.styleFrom(foregroundColor: Colors.lightBlue),
                ),
                TextButton.icon(
                  onPressed: _isIndexingNote ? null : _addNote,
                  icon: _isIndexingNote
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white70,
                        ),
                      )
                    : const Icon(Icons.note_add, size: 18),
                  label: Text(_isIndexingNote ? 'Indexing...' : 'Add Note'),
                  style: TextButton.styleFrom(foregroundColor: Colors.cyan),
                ),
                TextButton.icon(
                  onPressed: _isIndexingAlarm ? null : _addAlarm,
                  icon: _isIndexingAlarm
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white70,
                        ),
                      )
                    : const Icon(Icons.alarm_add, size: 18),
                  label: Text(_isIndexingAlarm ? 'Indexing...' : 'Create Alarm'),
                  style: TextButton.styleFrom(foregroundColor: Colors.amber),
                ),
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
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          // Compact metadata summary per entity type
          ..._buildMetadataSummary(entity),
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
      case 'NOTE_CHUNK':
        return Colors.cyan.shade700;
      case 'DOCUMENT_CHUNK':
        return Colors.deepOrange.shade700;
      case 'PROJECT':
        return Colors.indigo;
      case 'TOPIC':
        return Colors.lime;
      case 'DATE':
        return Colors.deepOrange;
      case 'ALARM':
        return Colors.redAccent;
      case 'EMAIL':
        return Colors.lightBlue;
      case 'PHONE':
        return Colors.deepPurple;
      default:
        return Colors.grey;
    }
  }

  /// Build a compact metadata summary for an entity based on its type.
  List<Widget> _buildMetadataSummary(GraphEntity entity) {
    final meta = entity.metadata;
    if (meta == null || meta.isEmpty) return [];

    final rows = <_MetaRow>[];
    switch (entity.type.toUpperCase()) {
      case 'PERSON':
        _addMeta(rows, Icons.phone, 'Phone', meta['phoneNumbers'] ?? meta['telephoneNumber']);
        _addMeta(rows, Icons.email, 'Email', meta['emails'] ?? meta['emailAddresses']);
        _addMeta(rows, Icons.business, 'Organization', meta['organizationName'] ?? meta['organization']);
        _addMeta(rows, Icons.badge, 'Job', meta['jobTitle']);
        _addMeta(rows, Icons.apps, 'Source', meta['source_app'] ?? meta['sourceApp']);
        break;
      case 'EVENT':
        _addMeta(rows, Icons.calendar_today, 'Start', _formatTs(meta['startDate']));
        _addMeta(rows, Icons.calendar_today, 'End', _formatTs(meta['endDate']));
        _addMeta(rows, Icons.repeat, 'Recurrence', meta['recurrenceInfo'] == 'recurrent'
            ? '${meta['repeatFrequency'] ?? 'recurring'}${meta['on'] != null ? ' on ${meta['on']}' : ''}'
            : null);
        _addMeta(rows, Icons.location_on, 'Location', meta['location']);
        _addMeta(rows, Icons.apps, 'Source', meta['source_app'] ?? meta['sourceApp']);
        break;
      case 'ALARM':
        _addMeta(rows, Icons.access_time, 'Time', meta['time']);
        _addMeta(rows, Icons.calendar_today, 'Date', meta['date']);
        _addMeta(rows, Icons.repeat, 'Repeat', meta['recurrence']);
        _addMeta(rows, Icons.apps, 'Source', meta['sourceApp']);
        break;
      case 'PHOTO':
        _addMeta(rows, Icons.calendar_today, 'Taken', meta['creationDate']);
        if (meta['width'] != null && meta['height'] != null) {
          rows.add(_MetaRow(Icons.aspect_ratio, 'Size', '${meta['width']}×${meta['height']}'));
        }
        _addMeta(rows, Icons.location_on, 'Location', meta['locationName'] ?? meta['location']);
        _addMeta(rows, Icons.image, 'Type', meta['mediaType']);
        _addMeta(rows, Icons.folder, 'Path', meta['path'] ?? meta['filePath']);
        _addMeta(rows, Icons.apps, 'Source', meta['source_app'] ?? meta['sourceApp']);
        break;
      case 'PHONE_CALL':
        _addMeta(rows, Icons.call_made, 'Direction', meta['callDirection'] ?? meta['callType']);
        _addMeta(rows, Icons.phone, 'Number', meta['phoneNumber']);
        _addMeta(rows, Icons.timer, 'Duration', meta['duration']?.toString());
        _addMeta(rows, Icons.calendar_today, 'Date', meta['date']);
        _addMeta(rows, Icons.access_time, 'Time', meta['startTime']);
        _addMeta(rows, Icons.apps, 'Source', meta['source_app'] ?? meta['sourceApp']);
        break;
      case 'NOTE':
        _addMeta(rows, Icons.calendar_today, 'Created', meta['dateCreated']);
        _addMeta(rows, Icons.edit_calendar, 'Modified', meta['dateModified']);
        if (meta['chunkCount'] != null) {
          rows.add(_MetaRow(Icons.splitscreen, 'Chunks', meta['chunkCount'].toString()));
        }
        _addMeta(rows, Icons.apps, 'Source', meta['sourceApp']);
        break;
      case 'DOCUMENT':
        _addMeta(rows, Icons.description, 'Type', meta['mimeType']);
        if (meta['fileSize'] != null) {
          rows.add(_MetaRow(Icons.storage, 'Size', _formatFileSize(meta['fileSize'])));
        }
        _addMeta(rows, Icons.calendar_today, 'Created', _formatTs(meta['createdDate']));
        _addMeta(rows, Icons.apps, 'Source', meta['source_app'] ?? meta['sourceApp']);
        break;
    }

    if (rows.isEmpty) return [];

    return [
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: rows
              .map((r) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Icon(r.icon, color: Colors.white38, size: 14),
                        const SizedBox(width: 6),
                        Text('${r.label}: ',
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 12)),
                        Expanded(
                          child: Text(r.value,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 12),
                              overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                  ))
              .toList(),
        ),
      ),
    ];
  }

  void _addMeta(List<_MetaRow> rows, IconData icon, String label, dynamic value) {
    if (value == null) return;
    final str = value is List ? value.join(', ') : value.toString();
    if (str.isEmpty) return;
    rows.add(_MetaRow(icon, label, str));
  }

  String _formatTs(dynamic ts) {
    if (ts == null) return '';
    if (ts is int) {
      final dt = DateTime.fromMillisecondsSinceEpoch(ts);
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return ts.toString();
  }

  String _formatFileSize(dynamic bytes) {
    if (bytes == null) return '';
    final b = bytes is int ? bytes : int.tryParse(bytes.toString()) ?? 0;
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _MetaRow {
  final IconData icon;
  final String label;
  final String value;
  const _MetaRow(this.icon, this.label, this.value);
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

class _AddNoteDialog extends StatefulWidget {
  const _AddNoteDialog();

  @override
  State<_AddNoteDialog> createState() => _AddNoteDialogState();
}

class _AddNoteDialogState extends State<_AddNoteDialog> {
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1a3a5c),
      title: const Text(
        'Add Note',
        style: TextStyle(color: Colors.white),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _titleController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Title (optional)',
                labelStyle: TextStyle(color: Colors.white54),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.cyan),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _contentController,
              style: const TextStyle(color: Colors.white),
              maxLines: 8,
              minLines: 4,
              decoration: const InputDecoration(
                labelText: 'Note content',
                labelStyle: TextStyle(color: Colors.white54),
                hintText: 'Type your note here...',
                hintStyle: TextStyle(color: Colors.white24),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.cyan),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            if (_contentController.text.trim().isEmpty) return;
            Navigator.pop(context, {
              'title': _titleController.text.trim(),
              'content': _contentController.text.trim(),
            });
          },
          style: TextButton.styleFrom(foregroundColor: Colors.cyan),
          child: const Text('Index'),
        ),
      ],
    );
  }
}

class _AddAlarmDialog extends StatefulWidget {
  const _AddAlarmDialog();

  @override
  State<_AddAlarmDialog> createState() => _AddAlarmDialogState();
}

class _AddAlarmDialogState extends State<_AddAlarmDialog> {
  final _labelController = TextEditingController();
  DateTime _selectedDate = DateTime.now();
  TimeOfDay _selectedTime = TimeOfDay.now();
  String? _selectedRecurrence;

  static const _recurrenceOptions = [
    null, // None
    'daily',
    'weekdays',
    'weekends',
    'weekly',
    'monthly',
  ];

  static const _recurrenceLabels = {
    null: 'None',
    'daily': 'Daily',
    'weekdays': 'Weekdays (Mon-Fri)',
    'weekends': 'Weekends (Sat-Sun)',
    'weekly': 'Weekly',
    'monthly': 'Monthly',
  };

  @override
  void dispose() {
    _labelController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
    );
    if (date != null) {
      setState(() => _selectedDate = date);
    }
  }

  Future<void> _pickTime() async {
    final time = await showTimePicker(
      context: context,
      initialTime: _selectedTime,
    );
    if (time != null) {
      setState(() => _selectedTime = time);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateStr =
        '${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2, '0')}-${_selectedDate.day.toString().padLeft(2, '0')}';
    final timeStr =
        '${_selectedTime.hour.toString().padLeft(2, '0')}:${_selectedTime.minute.toString().padLeft(2, '0')}';

    return AlertDialog(
      backgroundColor: const Color(0xFF1a3a5c),
      title: const Text(
        'Create Alarm',
        style: TextStyle(color: Colors.white),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _labelController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Alarm label',
                labelStyle: TextStyle(color: Colors.white54),
                hintText: 'e.g. Wake up, Take medicine...',
                hintStyle: TextStyle(color: Colors.white24),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.amber),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: _pickDate,
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Date',
                        labelStyle: TextStyle(color: Colors.white54),
                        enabledBorder: UnderlineInputBorder(
                          borderSide: BorderSide(color: Colors.white24),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.calendar_today,
                              color: Colors.white70, size: 16),
                          const SizedBox(width: 8),
                          Text(dateStr,
                              style: const TextStyle(color: Colors.white)),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: InkWell(
                    onTap: _pickTime,
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Time',
                        labelStyle: TextStyle(color: Colors.white54),
                        enabledBorder: UnderlineInputBorder(
                          borderSide: BorderSide(color: Colors.white24),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.access_time,
                              color: Colors.white70, size: 16),
                          const SizedBox(width: 8),
                          Text(timeStr,
                              style: const TextStyle(color: Colors.white)),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String?>(
              initialValue: _selectedRecurrence,
              dropdownColor: const Color(0xFF1a3a5c),
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Repeat',
                labelStyle: TextStyle(color: Colors.white54),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24),
                ),
              ),
              items: _recurrenceOptions.map((option) {
                return DropdownMenuItem<String?>(
                  value: option,
                  child: Text(_recurrenceLabels[option] ?? 'None'),
                );
              }).toList(),
              onChanged: (value) {
                setState(() => _selectedRecurrence = value);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            if (_labelController.text.trim().isEmpty) return;
            final alarmDateTime = DateTime(
              _selectedDate.year,
              _selectedDate.month,
              _selectedDate.day,
              _selectedTime.hour,
              _selectedTime.minute,
            );
            Navigator.pop(context, {
              'label': _labelController.text.trim(),
              'dateTime': alarmDateTime,
              'recurrence': _selectedRecurrence,
            });
          },
          style: TextButton.styleFrom(foregroundColor: Colors.amber),
          child: const Text('Create'),
        ),
      ],
    );
  }
}
