import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma/rag/graph/global_query_engine.dart' as global;
import 'package:flutter_gemma_example/services/graph_rag_service.dart';

/// Screen for querying the knowledge graph with local and global queries
class GraphRAGChatScreen extends StatefulWidget {
  const GraphRAGChatScreen({super.key});

  @override
  State<GraphRAGChatScreen> createState() => _GraphRAGChatScreenState();
}

class _GraphRAGChatScreenState extends State<GraphRAGChatScreen> {
  final GraphRAGService _service = GraphRAGService.instance;
  final TextEditingController _queryController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  // Query results
  final List<_QueryResult> _queryHistory = [];
  bool _isQuerying = false;
  bool _useGlobalQuery = false;

  // Streaming global query state
  String? _streamingProgress;
  String _streamingAnswer = '';
  int? _currentCommunity;
  int? _totalCommunities;

  @override
  void dispose() {
    _queryController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _executeQuery() async {
    final query = _queryController.text.trim();
    if (query.isEmpty) return;

    setState(() {
      _isQuerying = true;
      _streamingProgress = null;
      _streamingAnswer = '';
      _currentCommunity = null;
      _totalCommunities = null;
    });

    try {
      if (_useGlobalQuery) {
        // Use streaming global query for real-time feedback
        int? usefulAnswers;
        int? communityLevel;
        Duration? mapPhaseDuration;
        Duration? reducePhaseDuration;
        Duration? totalDuration;

        await for (final progress in _service.globalQueryAutoStreaming(query)) {
          setState(() {
            _streamingProgress = progress.message;
            _currentCommunity = progress.currentCommunity;
            _totalCommunities = progress.totalCommunities;

            if (progress.token != null) {
              _streamingAnswer += progress.token!;
            }
            if (progress.partialResponse != null &&
                progress.phase == global.GlobalQueryPhase.completed) {
              _streamingAnswer = progress.partialResponse!;
            }

            usefulAnswers = progress.usefulAnswers ?? usefulAnswers;
            communityLevel = progress.communityLevel ?? communityLevel;
            mapPhaseDuration = progress.mapPhaseDuration ?? mapPhaseDuration;
            reducePhaseDuration =
                progress.reducePhaseDuration ?? reducePhaseDuration;
            totalDuration = progress.totalDuration ?? totalDuration;
          });
        }

        setState(() {
          _queryHistory.insert(
              0,
              _QueryResult(
                query: query,
                entities: [],
                communities: [],
                contextString: _streamingAnswer,
                timestamp: DateTime.now(),
                isGlobalQuery: true,
                globalQueryMetadata: global.QueryMetadata(
                  originalQuery: query,
                  communityLevel: communityLevel ?? 0,
                  mapPhaseDuration: mapPhaseDuration ?? Duration.zero,
                  reducePhaseDuration: reducePhaseDuration ?? Duration.zero,
                  totalDuration: totalDuration ?? Duration.zero,
                ),
                communityAnswersUsed: usefulAnswers ?? 0,
              ));
          _isQuerying = false;
          _streamingProgress = null;
          _streamingAnswer = '';
        });
      } else {
        // Local query with answer generation
        final result = await _service.queryWithAnswer(query);

        setState(() {
          _queryHistory.insert(
              0,
              _QueryResult(
                query: query,
                entities: result.entities,
                communities: result.communities,
                contextString: result.contextString,
                timestamp: DateTime.now(),
                generatedAnswer: result.generatedAnswer,
              ));
          _isQuerying = false;
        });
      }

      _queryController.clear();
    } catch (e) {
      setState(() {
        _isQuerying = false;
        _streamingProgress = null;
        _streamingAnswer = '';
      });
      _showSnackBar('Query error: $e', isError: true);
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

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildQuerySection(),
        Expanded(child: _buildQueryResults()),
      ],
    );
  }

  Widget _buildQuerySection() {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        children: [
          // Global Query Toggle
          Row(
            children: [
              Switch(
                value: _useGlobalQuery,
                onChanged: (value) => setState(() => _useGlobalQuery = value),
                activeTrackColor: Colors.purple.withValues(alpha: 0.5),
                activeThumbColor: Colors.purple,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _useGlobalQuery
                      ? '🌐 Global Query (Map-Reduce over communities)'
                      : '🔍 Local Query (Entity similarity search)',
                  style: TextStyle(
                    fontSize: 12,
                    color:
                        _useGlobalQuery ? Colors.purple[200] : Colors.white70,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Query Input Row
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _queryController,
                  decoration: InputDecoration(
                    hintText: _useGlobalQuery
                        ? 'Ask broad questions like "What are the main themes?"...'
                        : 'Ask about your contacts or events...',
                    hintStyle: const TextStyle(color: Colors.white54),
                    filled: true,
                    fillColor: _useGlobalQuery
                        ? const Color(0xFF2d1a5c)
                        : const Color(0xFF1a3a5c),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                  ),
                  style: const TextStyle(color: Colors.white),
                  onSubmitted: (_) => _executeQuery(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _isQuerying ? null : _executeQuery,
                icon: _isQuerying
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Icon(
                        _useGlobalQuery ? Icons.public : Icons.search,
                        color: Colors.white,
                      ),
                style: IconButton.styleFrom(
                  backgroundColor:
                      _useGlobalQuery ? Colors.purple : Colors.blue,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildQueryResults() {
    // Show streaming progress if global query is running
    if (_isQuerying &&
        _useGlobalQuery &&
        (_streamingProgress != null || _streamingAnswer.isNotEmpty)) {
      return Column(
        children: [
          // Streaming progress card
          Expanded(
            child: Card(
              color: const Color(0xFF2d1a5c),
              margin: const EdgeInsets.all(8),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.purple)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _streamingProgress ?? 'Processing...',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_currentCommunity != null &&
                        _totalCommunities != null) ...[
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: _currentCommunity! / _totalCommunities!,
                        backgroundColor: Colors.white24,
                        valueColor:
                            const AlwaysStoppedAnimation<Color>(Colors.purple),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Community $_currentCommunity of $_totalCommunities',
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12),
                      ),
                    ],
                    if (_streamingAnswer.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      const Divider(color: Colors.white24),
                      const SizedBox(height: 8),
                      const Text(
                        'Response:',
                        style: TextStyle(
                          color: Colors.purple,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _streamingAnswer,
                        style: const TextStyle(color: Colors.white),
                      ),
                      const Text(
                        '▌',
                        style: TextStyle(color: Colors.purple),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          // Show history below
          Expanded(
            child: _queryHistory.isEmpty
                ? const SizedBox.shrink()
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(8),
                    itemCount: _queryHistory.length,
                    itemBuilder: (context, index) {
                      final result = _queryHistory[index];
                      return _QueryResultCard(result: result);
                    },
                  ),
          ),
        ],
      );
    }

    if (_queryHistory.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _useGlobalQuery ? Icons.public : Icons.search,
              size: 48,
              color: Colors.white24,
            ),
            const SizedBox(height: 16),
            const Text(
              'No queries yet',
              style: TextStyle(color: Colors.white54),
            ),
            Text(
              _useGlobalQuery
                  ? 'Try: "What are the main themes in my data?"'
                  : 'Try: "Who do I know?" or "What events do I have?"',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(8),
      itemCount: _queryHistory.length,
      itemBuilder: (context, index) {
        final result = _queryHistory[index];
        return _QueryResultCard(result: result);
      },
    );
  }
}

// Helper classes

class _QueryResult {
  final String query;
  final List<ScoredQueryEntity> entities;
  final List<ScoredQueryCommunity> communities;
  final String contextString;
  final DateTime timestamp;
  final bool isGlobalQuery;
  final global.QueryMetadata? globalQueryMetadata;
  final int communityAnswersUsed;
  
  /// Generated answer (for local queries with answer generation)
  final String? generatedAnswer;

  _QueryResult({
    required this.query,
    required this.entities,
    required this.communities,
    required this.contextString,
    required this.timestamp,
    this.isGlobalQuery = false,
    this.globalQueryMetadata,
    this.communityAnswersUsed = 0,
    this.generatedAnswer,
  });
}

class _QueryResultCard extends StatelessWidget {
  const _QueryResultCard({required this.result});

  final _QueryResult result;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: result.isGlobalQuery
          ? const Color(0xFF2d1a5c)
          : const Color(0xFF1a3a5c),
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        title: Row(
          children: [
            if (result.isGlobalQuery) ...[
              const Icon(Icons.public, size: 16, color: Colors.purple),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                result.query,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        subtitle: Text(
          result.isGlobalQuery
              ? 'Global Query (Level ${result.globalQueryMetadata?.communityLevel ?? 0}, ${result.communityAnswersUsed} communities used)'
              : '${result.entities.length} entities found',
          style: const TextStyle(fontSize: 12, color: Colors.white70),
        ),
        initiallyExpanded: true,
        children: [
          // === ANSWER SECTION (both local and global) ===
          if (result.isGlobalQuery && result.contextString.isNotEmpty)
            _buildAnswerSection(
              title: 'Global Answer',
              answer: result.contextString,
              color: Colors.purple,
            ),
          if (!result.isGlobalQuery && result.generatedAnswer != null && result.generatedAnswer!.isNotEmpty)
            _buildAnswerSection(
              title: 'Answer',
              answer: result.generatedAnswer!,
              color: Colors.blue,
            ),
          
          // === RELEVANT SOURCES SECTION ===
          if (result.entities.isNotEmpty || result.communities.isNotEmpty)
            _buildRelevantSourcesSection(),
          
          // === METADATA SECTION ===
          if (result.isGlobalQuery && result.globalQueryMetadata != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(
                'Map: ${result.globalQueryMetadata!.mapPhaseDuration.inMilliseconds}ms | '
                'Reduce: ${result.globalQueryMetadata!.reducePhaseDuration.inMilliseconds}ms | '
                'Total: ${result.globalQueryMetadata!.totalDuration.inMilliseconds}ms',
                style: const TextStyle(fontSize: 10, color: Colors.white54),
              ),
            ),
        ],
      ),
    );
  }
  
  Widget _buildAnswerSection({
    required String title,
    required String answer,
    required Color color,
  }) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome, size: 14, color: color),
              const SizedBox(width: 6),
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: color,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withValues(alpha: 0.3)),
            ),
            child: Text(
              answer,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildRelevantSourcesSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.source, size: 14, color: Colors.white70),
              SizedBox(width: 6),
              Text(
                'Relevant Sources',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.white70,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Top 3 entities as chips
          if (result.entities.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: result.entities.take(3).map((scored) {
                return _EntityChip(
                  entity: scored.entity,
                  score: scored.score,
                );
              }).toList(),
            ),
          // Community if available
          if (result.communities.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.purple.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.purple.withValues(alpha: 0.4)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.group_work, size: 14, color: Colors.purple),
                  const SizedBox(width: 6),
                  Text(
                    'Community L${result.communities.first.community.level}',
                    style: const TextStyle(
                      color: Colors.purple,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (result.communities.first.community.summary.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        '• ${_truncate(result.communities.first.community.summary, 50)}',
                        style: const TextStyle(color: Colors.white54, fontSize: 11),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
  
  String _truncate(String text, int maxLength) {
    if (text.length <= maxLength) return text;
    return '${text.substring(0, maxLength)}...';
  }
}

class _EntityChip extends StatelessWidget {
  final GraphEntity entity;
  final double score;

  const _EntityChip({
    required this.entity,
    required this.score,
  });

  @override
  Widget build(BuildContext context) {
    final typeColor = _getTypeColor(entity.type);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: typeColor.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: typeColor.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: typeColor,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              entity.type.substring(0, entity.type.length.clamp(0, 3)).toUpperCase(),
              style: const TextStyle(
                fontSize: 8,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(
              entity.name,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Colors.white,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '${(score * 100).toStringAsFixed(0)}%',
            style: TextStyle(
              fontSize: 10,
              color: typeColor,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Color _getTypeColor(String type) {
    switch (type.toUpperCase()) {
      case 'PERSON':
        return Colors.blue;
      case 'ORGANIZATION':
        return Colors.green;
      case 'EVENT':
        return Colors.orange;
      case 'LOCATION':
        return Colors.purple;
      case 'PHONE':
        return Colors.teal;
      case 'EMAIL':
        return Colors.red;
      case 'DATE':
      case 'TIME':
        return Colors.amber;
      default:
        return Colors.blueGrey;
    }
  }
}
