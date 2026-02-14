import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_example/services/graph_rag_service.dart';

/// Screen for managing user-created notes (list, edit, delete).
class NotesManagementScreen extends StatefulWidget {
  const NotesManagementScreen({super.key});

  @override
  State<NotesManagementScreen> createState() => _NotesManagementScreenState();
}

class _NotesManagementScreenState extends State<NotesManagementScreen> {
  final GraphRAGService _service = GraphRAGService.instance;

  List<GraphEntity> _notes = [];
  bool _loading = true;
  final Set<String> _deletingIds = {};
  bool _isIndexingNote = false;

  @override
  void initState() {
    super.initState();
    _loadNotes();
  }

  Future<void> _loadNotes() async {
    if (!_service.isInitialized) {
      setState(() => _loading = false);
      return;
    }

    setState(() => _loading = true);

    try {
      final notes = await _service.getNotes();
      setState(() {
        _notes = notes;
        _loading = false;
      });
    } catch (e) {
      debugPrint('Error loading notes: $e');
      setState(() => _loading = false);
    }
  }

  Future<void> _deleteNote(GraphEntity note) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a3a5c),
        title: const Text('Delete Note?',
            style: TextStyle(color: Colors.white)),
        content: Text(
          'Delete "${note.name}" and all its graph data?\n\n'
          'This will remove the note, its chunks, and clean up '
          'orphaned entities. This action cannot be undone.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _deletingIds.add(note.id));

    try {
      await _service.deleteNote(note.id);
      _showSnackBar('Note "${note.name}" deleted');
      await _loadNotes();
    } catch (e) {
      _showSnackBar('Error deleting note: $e', isError: true);
    } finally {
      setState(() => _deletingIds.remove(note.id));
    }
  }

  Future<void> _editNote(GraphEntity note) async {
    final meta = note.metadata ?? {};
    final fullContent =
        meta['fullContent'] as String? ?? note.description ?? '';
    final dateStr = meta['dateCreated'] as String?;
    final existingDate =
        dateStr != null ? DateTime.tryParse(dateStr) : null;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _EditNoteDialog(
        initialTitle: note.name,
        initialContent: fullContent,
        initialDate: existingDate ?? note.lastModified,
      ),
    );

    if (result == null) return;

    final newTitle = result['title'] as String;
    final newContent = result['content'] as String;
    final newDate = result['dateCreated'] as DateTime;

    if (newContent.isEmpty) return;

    _showSnackBar('Updating note...');

    try {
      await _service.updateNote(
        oldEntityId: note.id,
        title: newTitle,
        content: newContent,
        dateCreated: newDate,
      );
      _showSnackBar('Note updated successfully!');
      await _loadNotes();
    } catch (e) {
      _showSnackBar('Error updating note: $e', isError: true);
    }
  }

  Future<void> _addNote() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => const _AddNoteDialog(),
    );

    if (result == null || (result['content'] as String?)?.isEmpty == true) {
      return;
    }

    setState(() => _isIndexingNote = true);

    try {
      final title = (result['title'] as String?)?.isNotEmpty == true
          ? result['title'] as String
          : 'Note ${DateTime.now().toIso8601String().substring(0, 16)}';
      final content = result['content'] as String;
      final dateCreated = result['dateCreated'] as DateTime?;

      _showSnackBar('Indexing note "$title"...');

      await _service.indexNote(
        title: title,
        content: content,
        dateCreated: dateCreated,
        sourceApp: 'user_input',
      );

      _showSnackBar('Note indexed successfully!');
      await _loadNotes();
    } catch (e) {
      _showSnackBar('Error indexing note: $e', isError: true);
    } finally {
      setState(() => _isIndexingNote = false);
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

  String _formatDate(DateTime? date) {
    if (date == null) return '';
    return '${date.year}-${date.month.toString().padLeft(2, '0')}'
        '-${date.day.toString().padLeft(2, '0')}';
  }

  String _getDateFromEntity(GraphEntity note) {
    final meta = note.metadata ?? {};
    final dateStr = meta['dateCreated'] as String?;
    if (dateStr != null) {
      final dt = DateTime.tryParse(dateStr);
      if (dt != null) return _formatDate(dt);
    }
    return _formatDate(note.lastModified);
  }

  String _getPreview(GraphEntity note) {
    final meta = note.metadata ?? {};
    final fullContent = meta['fullContent'] as String?;
    final text = fullContent ?? note.description ?? '';
    if (text.length <= 120) return text;
    return '${text.substring(0, 120)}...';
  }

  int _getChunkCount(GraphEntity note) {
    final meta = note.metadata ?? {};
    final count = meta['chunkCount'];
    if (count is int) return count;
    if (count is String) return int.tryParse(count) ?? 1;
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 16),
            Text('Loading notes...',
                style: TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }

    final fab = FloatingActionButton(
      onPressed: _isIndexingNote ? null : _addNote,
      backgroundColor: _isIndexingNote ? Colors.grey : Colors.cyan,
      child: _isIndexingNote
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            )
          : const Icon(Icons.add, color: Colors.white),
    );

    if (_notes.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        floatingActionButton: fab,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.note_outlined,
                  size: 64, color: Colors.white.withValues(alpha: 0.3)),
              const SizedBox(height: 16),
              const Text(
                'No notes yet',
                style: TextStyle(
                    color: Colors.white70,
                    fontSize: 18,
                    fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 8),
              const Text(
                'Tap + to create your first note.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: fab,
      body: RefreshIndicator(
        onRefresh: _loadNotes,
        color: Colors.cyan,
        backgroundColor: const Color(0xFF1a3a5c),
        child: ListView.builder(
          padding: const EdgeInsets.all(8),
          itemCount: _notes.length,
          itemBuilder: (context, index) => _buildNoteCard(_notes[index]),
        ),
      ),
    );
  }

  Widget _buildNoteCard(GraphEntity note) {
    final isDeleting = _deletingIds.contains(note.id);
    final chunks = _getChunkCount(note);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: const Color(0xFF1a3a5c),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: isDeleting ? null : () => _editNote(note),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header: title + actions
              Row(
                children: [
                  const Icon(Icons.note, color: Colors.cyan, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      note.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (isDeleting)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.red),
                    )
                  else ...[
                    IconButton(
                      icon: const Icon(Icons.edit, size: 18),
                      color: Colors.cyan,
                      tooltip: 'Edit',
                      onPressed: () => _editNote(note),
                      constraints: const BoxConstraints(
                          minWidth: 36, minHeight: 36),
                      padding: EdgeInsets.zero,
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      color: Colors.red.shade300,
                      tooltip: 'Delete',
                      onPressed: () => _deleteNote(note),
                      constraints: const BoxConstraints(
                          minWidth: 36, minHeight: 36),
                      padding: EdgeInsets.zero,
                    ),
                  ],
                ],
              ),

              // Date + chunk count
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(Icons.calendar_today,
                      size: 12, color: Colors.white.withValues(alpha: 0.5)),
                  const SizedBox(width: 4),
                  Text(
                    _getDateFromEntity(note),
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 12),
                  ),
                  if (chunks > 1) ...[
                    const SizedBox(width: 12),
                    Icon(Icons.splitscreen,
                        size: 12,
                        color: Colors.white.withValues(alpha: 0.5)),
                    const SizedBox(width: 4),
                    Text(
                      '$chunks chunks',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 12),
                    ),
                  ],
                ],
              ),

              // Content preview
              const SizedBox(height: 8),
              Text(
                _getPreview(note),
                style: const TextStyle(color: Colors.white70, fontSize: 13),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Edit Note Dialog ──────────────────────────────────────────────────────

class _EditNoteDialog extends StatefulWidget {
  const _EditNoteDialog({
    required this.initialTitle,
    required this.initialContent,
    required this.initialDate,
  });

  final String initialTitle;
  final String initialContent;
  final DateTime initialDate;

  @override
  State<_EditNoteDialog> createState() => _EditNoteDialogState();
}

class _EditNoteDialogState extends State<_EditNoteDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _contentController;
  late DateTime _selectedDate;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.initialTitle);
    _contentController = TextEditingController(text: widget.initialContent);
    _selectedDate = widget.initialDate;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date != null) {
      setState(() => _selectedDate = date);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateStr =
        '${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2, '0')}-${_selectedDate.day.toString().padLeft(2, '0')}';

    return AlertDialog(
      backgroundColor: const Color(0xFF1a3a5c),
      title: const Text(
        'Edit Note',
        style: TextStyle(color: Colors.white),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _titleController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Title',
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
              InkWell(
                onTap: _pickDate,
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Creation Date',
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
              const SizedBox(height: 12),
              TextField(
                controller: _contentController,
                style: const TextStyle(color: Colors.white),
                maxLines: 10,
                minLines: 5,
                decoration: const InputDecoration(
                  labelText: 'Note content',
                  labelStyle: TextStyle(color: Colors.white54),
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
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            final title = _titleController.text.trim();
            final content = _contentController.text.trim();
            if (content.isEmpty) return;
            Navigator.pop(context, <String, dynamic>{
              'title':
                  title.isNotEmpty ? title : 'Note ${DateTime.now().toIso8601String().substring(0, 16)}',
              'content': content,
              'dateCreated': _selectedDate,
            });
          },
          style: TextButton.styleFrom(foregroundColor: Colors.cyan),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// ── Add Note Dialog ───────────────────────────────────────────────────────

class _AddNoteDialog extends StatefulWidget {
  const _AddNoteDialog();

  @override
  State<_AddNoteDialog> createState() => _AddNoteDialogState();
}

class _AddNoteDialogState extends State<_AddNoteDialog> {
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  DateTime _selectedDate = DateTime.now();

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date != null) {
      setState(() => _selectedDate = date);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateStr =
        '${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2, '0')}-${_selectedDate.day.toString().padLeft(2, '0')}';

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
            InkWell(
              onTap: _pickDate,
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Creation Date',
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
            Navigator.pop(context, <String, dynamic>{
              'title': _titleController.text.trim(),
              'content': _contentController.text.trim(),
              'dateCreated': _selectedDate,
            });
          },
          style: TextButton.styleFrom(foregroundColor: Colors.cyan),
          child: const Text('Index'),
        ),
      ],
    );
  }
}
