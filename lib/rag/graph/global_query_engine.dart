import 'dart:async';
import 'dart:math';

import 'graph_repository.dart';
import '../utils/math_utils.dart';

/// Progress event types for streaming global queries
enum GlobalQueryPhase {
  /// Starting the query, discovering levels
  starting,
  /// Processing community in map phase
  mapPhase,
  /// Filtering and sorting community answers
  filtering,
  /// Generating final answer in reduce phase
  reducePhase,
  /// Final answer token being streamed
  streaming,
  /// Query completed
  completed,
}

/// Progress event for streaming global queries
class GlobalQueryProgress {
  /// Current phase of the query
  final GlobalQueryPhase phase;
  
  /// Human-readable message about current progress
  final String message;
  
  /// Current community being processed (map phase)
  final int? currentCommunity;
  
  /// Total communities to process (map phase)
  final int? totalCommunities;
  
  /// Streaming token (reduce phase)
  final String? token;
  
  /// Full accumulated response so far
  final String? partialResponse;
  
  /// Selected community level
  final int? communityLevel;
  
  /// Number of useful community answers found
  final int? usefulAnswers;
  
  /// Map phase duration (available after map phase completes)
  final Duration? mapPhaseDuration;
  
  /// Reduce phase duration (available after completion)
  final Duration? reducePhaseDuration;
  
  /// Total duration (available after completion)
  final Duration? totalDuration;

  GlobalQueryProgress({
    required this.phase,
    required this.message,
    this.currentCommunity,
    this.totalCommunities,
    this.token,
    this.partialResponse,
    this.communityLevel,
    this.usefulAnswers,
    this.mapPhaseDuration,
    this.reducePhaseDuration,
    this.totalDuration,
  });
}

/// Configuration for global query engine (GraphRAG paper approach)
class GlobalQueryConfig {
  /// Community level to use for queries (0 = root, higher = more granular)
  final int communityLevel;
  
  /// Maximum number of community answers in reduce phase
  final int maxCommunityAnswers;
  
  /// Minimum helpfulness score to include answer (0-100)
  final int minHelpfulnessScore;
  
  /// Token limit for final context window
  final int contextTokenLimit;
  
  /// Response type (e.g., "multiple paragraphs", "single paragraph", "list")
  final String responseType;

  GlobalQueryConfig({
    this.communityLevel = 1,
    this.maxCommunityAnswers = 10,
    this.minHelpfulnessScore = 20,
    this.contextTokenLimit = 4000,
    this.responseType = 'multiple paragraphs',
  });
}

/// Partial answer from a community (map phase result)
class CommunityAnswer {
  final String communityId;
  final String summary;
  final String answer;
  final int helpfulnessScore;
  final int level;

  CommunityAnswer({
    required this.communityId,
    required this.summary,
    required this.answer,
    required this.helpfulnessScore,
    required this.level,
  });
  
  /// Approximate token count (rough: 4 chars per token)
  int get approximateTokens => (answer.length / 4).ceil();
}

/// Final global answer result
class GlobalQueryResult {
  /// The synthesized global answer
  final String answer;
  
  /// Community answers used in synthesis (sorted by helpfulness)
  final List<CommunityAnswer> communityAnswers;
  
  /// Total communities processed in map phase
  final int totalCommunitiesProcessed;
  
  /// Communities filtered out (score < minimum)
  final int communitiesFiltered;
  
  /// Query metadata
  final QueryMetadata metadata;

  GlobalQueryResult({
    required this.answer,
    required this.communityAnswers,
    required this.totalCommunitiesProcessed,
    required this.communitiesFiltered,
    required this.metadata,
  });
}

/// Query metadata
class QueryMetadata {
  final String originalQuery;
  final int communityLevel;
  final Duration mapPhaseDuration;
  final Duration reducePhaseDuration;
  final Duration totalDuration;

  QueryMetadata({
    required this.originalQuery,
    required this.communityLevel,
    required this.mapPhaseDuration,
    required this.reducePhaseDuration,
    required this.totalDuration,
  });
}

/// Global query engine implementing the GraphRAG paper's map-reduce approach
/// 
/// This follows the methodology from "From Local to Global: A GraphRAG Approach
/// to Query-Focused Summarization" (Edge et al., 2024):
/// 
/// 1. **Selection Phase**: Use embedding similarity to select top-k most relevant communities
/// 2. **Map Phase**: For each selected community summary, generate a partial answer
/// 3. **Reduce Phase**: Synthesize final answer from partial answers
class GlobalQueryEngine {
  final GraphRepository repository;
  final Future<String> Function(String prompt) llmCallback;
  final Future<List<double>> Function(String text) embeddingCallback;
  final GlobalQueryConfig config;

  GlobalQueryEngine({
    required this.repository,
    required this.llmCallback,
    required this.embeddingCallback,
    GlobalQueryConfig? config,
  }) : config = config ?? GlobalQueryConfig();
  
  /// Select top-k communities most relevant to query using embedding similarity
  Future<List<GraphCommunity>> _selectTopCommunitiesByEmbedding(
    String query,
    List<GraphCommunity> communities,
    {int topK = 3}
  ) async {
    // Truncate query if needed (embedding model: 512 tokens max ~1800 chars safe limit)
    final maxChars = 1800;
    final truncatedQuery = query.length > maxChars 
        ? query.substring(0, maxChars) 
        : query;
    
    // Get query embedding
    final queryEmbedding = await embeddingCallback(truncatedQuery);
    if (queryEmbedding.isEmpty) {
      print('[GlobalQueryEngine] Failed to generate query embedding, using all communities');
      return communities.take(topK).toList();
    }
    
    // Calculate similarity scores for each community
    final scoredCommunities = <({GraphCommunity community, double similarity})>[];
    
    for (final community in communities) {
      if (community.summary.isEmpty) continue;
      
      // Truncate summary to fit embedding model (512 tokens ~1800 chars safe)
      final truncatedSummary = community.summary.length > maxChars
          ? community.summary.substring(0, maxChars)
          : community.summary;
      
      // Get embedding for community summary
      final summaryEmbedding = await embeddingCallback(truncatedSummary);
      if (summaryEmbedding.isEmpty) continue;
      
      // Calculate cosine similarity
      final similarity = MathUtils.cosineSimilarity(queryEmbedding, summaryEmbedding);
      scoredCommunities.add((community: community, similarity: similarity));
    }
    
    // Sort by similarity descending and take top-k
    scoredCommunities.sort((a, b) => b.similarity.compareTo(a.similarity));
    final topCommunities = scoredCommunities.take(topK).map((s) => s.community).toList();
    
    print('[GlobalQueryEngine] Selected ${topCommunities.length} most relevant communities (top $topK)');
    for (var i = 0; i < topCommunities.length; i++) {
      final score = scoredCommunities[i].similarity;
      print('[GlobalQueryEngine]   ${i+1}. Similarity: ${(score * 100).toStringAsFixed(1)}%');
    }
    
    return topCommunities;
  }

  /// Execute a global query using map-reduce over community summaries
  /// 
  /// This is the main entry point for GraphRAG-style global queries that
  /// require understanding across the entire corpus.
  Future<GlobalQueryResult> query(String userQuery) async {
    final totalStopwatch = Stopwatch()..start();
    
    // Get all communities at the configured level
    final communities = await repository.getCommunitiesByLevel(config.communityLevel);
    
    // Debug: log community info
    print('[GlobalQueryEngine] Querying with level ${config.communityLevel}');
    print('[GlobalQueryEngine] Found ${communities.length} communities at level ${config.communityLevel}');
    
    if (communities.isEmpty) {
      // Try lower levels if configured level is empty
      for (var level = config.communityLevel - 1; level >= 0; level--) {
        final lowerCommunities = await repository.getCommunitiesByLevel(level);
        print('[GlobalQueryEngine] Found ${lowerCommunities.length} communities at level $level');
        if (lowerCommunities.isNotEmpty) {
          return _executeQuery(userQuery, lowerCommunities, level, totalStopwatch);
        }
      }
      
      // No communities at any level
      print('[GlobalQueryEngine] No communities found at any level - indexing may not have been run');
      return GlobalQueryResult(
        answer: "I don't have enough information to answer this question. The knowledge graph hasn't been indexed yet.",
        communityAnswers: [],
        totalCommunitiesProcessed: 0,
        communitiesFiltered: 0,
        metadata: QueryMetadata(
          originalQuery: userQuery,
          communityLevel: config.communityLevel,
          mapPhaseDuration: Duration.zero,
          reducePhaseDuration: Duration.zero,
          totalDuration: totalStopwatch.elapsed,
        ),
      );
    }
    
    return _executeQuery(userQuery, communities, config.communityLevel, totalStopwatch);
  }
  
  Future<GlobalQueryResult> _executeQuery(
    String userQuery,
    List<GraphCommunity> communities,
    int level,
    Stopwatch totalStopwatch,
  ) async {
    // === SELECTION PHASE ===
    // Select top 3 most relevant communities using embedding similarity
    print('[GlobalQueryEngine] Selecting top 3 communities from ${communities.length} using embedding similarity');
    final selectedCommunities = await _selectTopCommunitiesByEmbedding(
      userQuery, 
      communities,
      topK: 3,
    );
    
    if (selectedCommunities.isEmpty) {
      print('[GlobalQueryEngine] No communities selected');
      return GlobalQueryResult(
        answer: 'No relevant information found in the knowledge graph.',
        communityAnswers: [],
        totalCommunitiesProcessed: 0,
        communitiesFiltered: communities.length,
        metadata: QueryMetadata(
          originalQuery: userQuery,
          communityLevel: level,
          mapPhaseDuration: Duration.zero,
          reducePhaseDuration: Duration.zero,
          totalDuration: totalStopwatch.elapsed,
        ),
      );
    }
    
    final mapStopwatch = Stopwatch()..start();
    
    // === MAP PHASE ===
    // Process only the top 3 selected communities
    final communityAnswers = <CommunityAnswer>[];
    
    print('[GlobalQueryEngine] Starting map phase with ${selectedCommunities.length} selected communities');
    var failedCommunities = 0;
    
    for (var i = 0; i < selectedCommunities.length; i++) {
      final community = selectedCommunities[i];
      if (community.summary.isEmpty) {
        continue;
      }
      
      final answer = await _generateCommunityAnswer(userQuery, community);
      if (answer != null) {
        communityAnswers.add(answer);
        print('[GlobalQueryEngine] Community ${i + 1}/${selectedCommunities.length}: generated answer');
      } else {
        failedCommunities++;
        print('[GlobalQueryEngine] Community ${i + 1}/${selectedCommunities.length}: failed to generate answer');
      }
    }
    
    mapStopwatch.stop();
    
    print('[GlobalQueryEngine] Map phase complete: ${communityAnswers.length} answers, $failedCommunities failed');
    
    // Filter by minimum helpfulness score
    final filteredAnswers = communityAnswers
        .where((a) => a.helpfulnessScore >= config.minHelpfulnessScore)
        .toList();
    
    print('[GlobalQueryEngine] After filtering (min score ${config.minHelpfulnessScore}): ${filteredAnswers.length} answers');
    
    // Sort by helpfulness descending
    filteredAnswers.sort((a, b) => b.helpfulnessScore.compareTo(a.helpfulnessScore));
    
    final reduceStopwatch = Stopwatch()..start();
    
    // === REDUCE PHASE ===
    // Select top answers that fit in context window
    final selectedAnswers = <CommunityAnswer>[];
    var totalTokens = 0;
    
    for (final answer in filteredAnswers) {
      if (selectedAnswers.length >= config.maxCommunityAnswers) break;
      if (totalTokens + answer.approximateTokens > config.contextTokenLimit) break;
      
      selectedAnswers.add(answer);
      totalTokens += answer.approximateTokens;
    }
    
    // Generate final global answer
    final globalAnswer = await _generateGlobalAnswer(userQuery, selectedAnswers);
    
    reduceStopwatch.stop();
    totalStopwatch.stop();
    
    return GlobalQueryResult(
      answer: globalAnswer,
      communityAnswers: selectedAnswers,
      totalCommunitiesProcessed: communities.length,
      communitiesFiltered: communityAnswers.length - filteredAnswers.length,
      metadata: QueryMetadata(
        originalQuery: userQuery,
        communityLevel: level,
        mapPhaseDuration: mapStopwatch.elapsed,
        reducePhaseDuration: reduceStopwatch.elapsed,
        totalDuration: totalStopwatch.elapsed,
      ),
    );
  }

  /// Map phase: Generate partial answer from a single community
  Future<CommunityAnswer?> _generateCommunityAnswer(
    String query,
    GraphCommunity community,
  ) async {
    if (community.summary.isEmpty) return null;
    
    // Truncate summary to prevent token overflow
    // Target: ~1500 chars (~375 tokens) for summary + ~300 chars for prompt = ~675 tokens total
    // This leaves room for output (~300 tokens) within 1024 limit
    final maxSummaryChars = 1500;
    final truncatedSummary = community.summary.length > maxSummaryChars
        ? '${community.summary.substring(0, maxSummaryChars)}...'
        : community.summary;
    
    final prompt = '''Based on this summary, answer the question.

Summary:
$truncatedSummary

Question: $query

Provide a brief answer (2-3 sentences):
''';

    try {
      final response = await llmCallback(prompt);
      
      // Since we selected by embedding similarity, assign high base score
      // All selected communities are relevant (score >= 85)
      final baseScore = 90;
      
      return CommunityAnswer(
        communityId: community.id,
        summary: community.summary,
        answer: response.trim(),
        helpfulnessScore: baseScore,
        level: community.level,
      );
    } catch (e) {
      print('[GlobalQueryEngine] Error generating answer for community: $e');
      return null;
    }
  }

  /// Reduce phase: Synthesize global answer from community answers
  Future<String> _generateGlobalAnswer(
    String query,
    List<CommunityAnswer> communityAnswers,
  ) async {
    if (communityAnswers.isEmpty) {
      return 'No relevant information found in the knowledge graph.';
    }
    
    // Build context from community answers - truncate each answer
    final maxAnswerChars = 400; // ~100 tokens per answer
    final answersContext = communityAnswers.asMap().entries.map((entry) {
      final idx = entry.key + 1;
      final answer = entry.value;
      final truncated = answer.answer.length > maxAnswerChars
          ? '${answer.answer.substring(0, maxAnswerChars)}...'
          : answer.answer;
      return 'Context $idx: $truncated';
    }).join('\n\n');
    
    // Simplified prompt to reduce token count
    final prompt = '''Synthesize these contexts to answer the question.

$answersContext

Question: $query

Provide a comprehensive answer:
''';

    return await llmCallback(prompt);
  }
  
  /// Query with automatic level selection based on query type
  /// 
  /// For broad/global questions, uses higher levels (C0, C1)
  /// For specific questions, uses lower levels (C2, C3)
  Future<GlobalQueryResult> queryWithAutoLevel(String userQuery) async {
    // Simple heuristic: broad questions use higher levels
    final lowerQuery = userQuery.toLowerCase();
    
    // First, discover available community levels
    final availableLevels = await _discoverAvailableLevels();
    
    if (availableLevels.isEmpty) {
      // No communities, run query anyway (will return "no information" response)
      return query(userQuery);
    }
    
    final maxAvailableLevel = availableLevels.reduce(max);
    
    int selectedLevel;
    if (_isBroadQuery(lowerQuery)) {
      // Global sensemaking questions - use root or high-level communities (C0)
      // These questions want the "big picture" view
      selectedLevel = 0;
    } else if (_isThematicQuery(lowerQuery)) {
      // Thematic questions - use intermediate level (middle of hierarchy)
      // These questions want grouped themes but more detail than root
      selectedLevel = (maxAvailableLevel / 2).ceil();
    } else if (_isSpecificQuery(lowerQuery)) {
      // Specific entity/detail questions - use most granular level
      selectedLevel = maxAvailableLevel;
    } else {
      // Default: use level 1 if available, else 0
      selectedLevel = min(1, maxAvailableLevel);
    }
    
    // Clamp to available levels
    selectedLevel = selectedLevel.clamp(0, maxAvailableLevel);
    
    // Create engine with selected level
    final levelConfig = GlobalQueryConfig(
      communityLevel: selectedLevel,
      maxCommunityAnswers: config.maxCommunityAnswers,
      minHelpfulnessScore: config.minHelpfulnessScore,
      contextTokenLimit: config.contextTokenLimit,
      responseType: config.responseType,
    );
    
    final levelEngine = GlobalQueryEngine(
      repository: repository,
      llmCallback: llmCallback,
      embeddingCallback: embeddingCallback,
      config: levelConfig,
    );
    
    return levelEngine.query(userQuery);
  }
  
  /// Discover which community levels have data
  Future<List<int>> _discoverAvailableLevels() async {
    final levels = <int>[];
    for (var level = 0; level <= 5; level++) {
      final communities = await repository.getCommunitiesByLevel(level);
      if (communities.isNotEmpty) {
        levels.add(level);
      } else if (levels.isNotEmpty) {
        // Stop once we hit an empty level after finding some
        break;
      }
    }
    return levels;
  }
  
  bool _isBroadQuery(String query) {
    final broadIndicators = [
      'main themes',
      'overall',
      'general',
      'summary',
      'overview',
      'what are the',
      'key trends',
      'major',
      'common patterns',
      'most important',
      'all ',
      'everything',
      'entire',
      'whole',
    ];
    return broadIndicators.any((indicator) => query.contains(indicator));
  }
  
  bool _isThematicQuery(String query) {
    final thematicIndicators = [
      'how do',
      'why do',
      'what causes',
      'relationship between',
      'connection',
      'impact of',
      'effect of',
      'related to',
      'associated with',
      'theme',
      'topic',
      'category',
    ];
    return thematicIndicators.any((indicator) => query.contains(indicator));
  }
  
  bool _isSpecificQuery(String query) {
    final specificIndicators = [
      'who is',
      'what is',
      'where is',
      'when did',
      'which ',
      'specific',
      'particular',
      'exactly',
      'details about',
      'tell me about',
      'info on',
      'information about',
    ];
    return specificIndicators.any((indicator) => query.contains(indicator));
  }
}

/// Streaming global query engine that emits progress events
/// 
/// This provides real-time feedback during global queries, which can take
/// a while since they process multiple communities sequentially.
class StreamingGlobalQueryEngine {
  final GraphRepository repository;
  final Future<String> Function(String prompt) llmCallback;
  final Stream<String> Function(String prompt)? llmStreamCallback;
  final Future<List<double>> Function(String text) embeddingCallback;
  final GlobalQueryConfig config;

  StreamingGlobalQueryEngine({
    required this.repository,
    required this.llmCallback,
    this.llmStreamCallback,
    required this.embeddingCallback,
    GlobalQueryConfig? config,
  }) : config = config ?? GlobalQueryConfig();

  /// Execute a streaming global query with automatic level selection
  /// 
  /// Yields progress events during execution, including streaming tokens
  /// for the final answer.
  Stream<GlobalQueryProgress> queryWithAutoLevelStreaming(String userQuery) async* {
    final totalStopwatch = Stopwatch()..start();
    final mapStopwatch = Stopwatch();
    
    yield GlobalQueryProgress(
      phase: GlobalQueryPhase.starting,
      message: 'Analyzing query...',
    );
    
    final lowerQuery = userQuery.toLowerCase();
    
    // Discover available community levels
    final availableLevels = <int>[];
    for (var level = 0; level <= 5; level++) {
      final communities = await repository.getCommunitiesByLevel(level);
      if (communities.isNotEmpty) {
        availableLevels.add(level);
      } else if (availableLevels.isNotEmpty) {
        break;
      }
    }
    
    if (availableLevels.isEmpty) {
      yield GlobalQueryProgress(
        phase: GlobalQueryPhase.completed,
        message: 'No indexed data found',
        partialResponse: "I don't have enough information to answer this question. The knowledge graph hasn't been indexed yet.",
      );
      return;
    }
    
    final maxAvailableLevel = availableLevels.reduce(max);
    
    // Select level based on query type
    int selectedLevel;
    if (_isBroadQuery(lowerQuery)) {
      selectedLevel = 0;
    } else if (_isThematicQuery(lowerQuery)) {
      selectedLevel = (maxAvailableLevel / 2).ceil();
    } else if (_isSpecificQuery(lowerQuery)) {
      selectedLevel = maxAvailableLevel;
    } else {
      selectedLevel = min(1, maxAvailableLevel);
    }
    selectedLevel = selectedLevel.clamp(0, maxAvailableLevel);
    
    yield GlobalQueryProgress(
      phase: GlobalQueryPhase.starting,
      message: 'Using community level $selectedLevel',
      communityLevel: selectedLevel,
    );
    
    // Get communities at selected level
    final communities = await repository.getCommunitiesByLevel(selectedLevel);
    
    yield GlobalQueryProgress(
      phase: GlobalQueryPhase.starting,
      message: 'Selecting top 3 most relevant communities from ${communities.length}...',
      communityLevel: selectedLevel,
      totalCommunities: communities.length,
    );
    
    // === SELECTION PHASE ===
    final selectedCommunities = await _selectTopCommunitiesByEmbedding(
      userQuery,
      communities,
      topK: 3,
    );
    
    if (selectedCommunities.isEmpty) {
      yield GlobalQueryProgress(
        phase: GlobalQueryPhase.completed,
        message: 'No relevant communities found',
        partialResponse: 'No relevant information found in the knowledge graph.',
      );
      return;
    }
    
    yield GlobalQueryProgress(
      phase: GlobalQueryPhase.mapPhase,
      message: 'Processing ${selectedCommunities.length} selected communities...',
      communityLevel: selectedLevel,
      totalCommunities: selectedCommunities.length,
    );
    
    // === MAP PHASE ===
    mapStopwatch.start();
    final communityAnswers = <CommunityAnswer>[];
    
    for (var i = 0; i < selectedCommunities.length; i++) {
      final community = selectedCommunities[i];
      
      yield GlobalQueryProgress(
        phase: GlobalQueryPhase.mapPhase,
        message: 'Analyzing community ${i + 1}/${selectedCommunities.length}...',
        currentCommunity: i + 1,
        totalCommunities: communities.length,
        communityLevel: selectedLevel,
      );
      
      final answer = await _generateCommunityAnswer(userQuery, community);
      if (answer != null) {
        communityAnswers.add(answer);
      }
    }
    
    // === FILTER PHASE ===
    mapStopwatch.stop();
    final reduceStopwatch = Stopwatch()..start();
    
    yield GlobalQueryProgress(
      phase: GlobalQueryPhase.filtering,
      message: 'Found ${communityAnswers.length} relevant communities',
      usefulAnswers: communityAnswers.length,
      communityLevel: selectedLevel,
      mapPhaseDuration: mapStopwatch.elapsed,
    );
    
    // Filter by minimum helpfulness score
    final filteredAnswers = communityAnswers
        .where((a) => a.helpfulnessScore >= config.minHelpfulnessScore)
        .toList();
    
    // Sort by helpfulness descending
    filteredAnswers.sort((a, b) => b.helpfulnessScore.compareTo(a.helpfulnessScore));
    
    // Select top answers that fit in context window
    final selectedAnswers = <CommunityAnswer>[];
    var totalTokens = 0;
    
    for (final answer in filteredAnswers) {
      if (selectedAnswers.length >= config.maxCommunityAnswers) break;
      if (totalTokens + answer.approximateTokens > config.contextTokenLimit) break;
      
      selectedAnswers.add(answer);
      totalTokens += answer.approximateTokens;
    }
    
    yield GlobalQueryProgress(
      phase: GlobalQueryPhase.filtering,
      message: 'Using ${selectedAnswers.length} community answers',
      usefulAnswers: selectedAnswers.length,
      communityLevel: selectedLevel,
      mapPhaseDuration: mapStopwatch.elapsed,
    );
    
    // === REDUCE PHASE ===
    if (selectedAnswers.isEmpty) {
      reduceStopwatch.stop();
      totalStopwatch.stop();
      yield GlobalQueryProgress(
        phase: GlobalQueryPhase.completed,
        message: 'Query completed',
        partialResponse: "I don't have enough relevant information to answer this question based on the available data.",
        communityLevel: selectedLevel,
        usefulAnswers: 0,
        mapPhaseDuration: mapStopwatch.elapsed,
        reducePhaseDuration: reduceStopwatch.elapsed,
        totalDuration: totalStopwatch.elapsed,
      );
      return;
    }
    
    yield GlobalQueryProgress(
      phase: GlobalQueryPhase.reducePhase,
      message: 'Synthesizing final answer...',
      usefulAnswers: selectedAnswers.length,
      communityLevel: selectedLevel,
      mapPhaseDuration: mapStopwatch.elapsed,
    );
    
    // Generate final answer - stream if callback available
    final prompt = _buildReducePrompt(userQuery, selectedAnswers);
    
    if (llmStreamCallback != null) {
      // Stream the final answer
      final buffer = StringBuffer();
      await for (final token in llmStreamCallback!(prompt)) {
        buffer.write(token);
        yield GlobalQueryProgress(
          phase: GlobalQueryPhase.streaming,
          message: 'Generating response...',
          token: token,
          partialResponse: buffer.toString(),
          usefulAnswers: selectedAnswers.length,
          communityLevel: selectedLevel,
          mapPhaseDuration: mapStopwatch.elapsed,
        );
      }
      
      reduceStopwatch.stop();
      totalStopwatch.stop();
      yield GlobalQueryProgress(
        phase: GlobalQueryPhase.completed,
        message: 'Query completed',
        partialResponse: buffer.toString(),
        usefulAnswers: selectedAnswers.length,
        communityLevel: selectedLevel,
        mapPhaseDuration: mapStopwatch.elapsed,
        reducePhaseDuration: reduceStopwatch.elapsed,
        totalDuration: totalStopwatch.elapsed,
      );
    } else {
      // Non-streaming fallback
      final answer = await llmCallback(prompt);
      
      reduceStopwatch.stop();
      totalStopwatch.stop();
      yield GlobalQueryProgress(
        phase: GlobalQueryPhase.completed,
        message: 'Query completed',
        partialResponse: answer,
        usefulAnswers: selectedAnswers.length,
        communityLevel: selectedLevel,
        mapPhaseDuration: mapStopwatch.elapsed,
        reducePhaseDuration: reduceStopwatch.elapsed,
        totalDuration: totalStopwatch.elapsed,
      );
    }
  }
  
  String _buildReducePrompt(String query, List<CommunityAnswer> communityAnswers) {
    // Build context from community answers - truncate each answer
    final maxAnswerChars = 400; // ~100 tokens per answer
    final answersContext = communityAnswers.asMap().entries.map((entry) {
      final idx = entry.key + 1;
      final answer = entry.value;
      final truncated = answer.answer.length > maxAnswerChars
          ? '${answer.answer.substring(0, maxAnswerChars)}...'
          : answer.answer;
      return 'Context $idx: $truncated';
    }).join('\n\n');
    
    // Simplified prompt to reduce token count
    return '''Synthesize these contexts to answer the question.

$answersContext

Question: $query

Provide a comprehensive answer:
''';
  }
  
  Future<CommunityAnswer?> _generateCommunityAnswer(
    String query,
    GraphCommunity community,
  ) async {
    if (community.summary.isEmpty) return null;
    
    // Truncate summary to prevent token overflow
    final maxSummaryChars = 1500;
    final truncatedSummary = community.summary.length > maxSummaryChars
        ? '${community.summary.substring(0, maxSummaryChars)}...'
        : community.summary;
    
    final prompt = '''Based on this summary, answer the question.

Summary:
$truncatedSummary

Question: $query

Provide a brief answer (2-3 sentences):
''';

    try {
      final response = await llmCallback(prompt);
      
      // Since we selected by embedding similarity, assign high base score
      final baseScore = 90;
      
      return CommunityAnswer(
        communityId: community.id,
        summary: community.summary,
        answer: response.trim(),
        helpfulnessScore: baseScore,
        level: community.level,
      );
    } catch (e) {
      return null;
    }
  }
  
  bool _isBroadQuery(String query) {
    final broadIndicators = [
      'main themes', 'overall', 'general', 'summary', 'overview',
      'what are the', 'key trends', 'major', 'common patterns',
      'most important', 'all ', 'everything', 'entire', 'whole',
    ];
    return broadIndicators.any((indicator) => query.contains(indicator));
  }
  
  bool _isThematicQuery(String query) {
    final thematicIndicators = [
      'how do', 'why do', 'what causes', 'relationship between',
      'connection', 'impact of', 'effect of', 'related to',
      'associated with', 'theme', 'topic', 'category',
    ];
    return thematicIndicators.any((indicator) => query.contains(indicator));
  }
  
  bool _isSpecificQuery(String query) {
    final specificIndicators = [
      'who is', 'what is', 'where is', 'when did', 'which ',
      'specific', 'particular', 'exactly', 'details about',
      'tell me about', 'info on', 'information about',
    ];
    return specificIndicators.any((indicator) => query.contains(indicator));
  }
  
  /// Select top-k communities most relevant to query using embedding similarity
  Future<List<GraphCommunity>> _selectTopCommunitiesByEmbedding(
    String query,
    List<GraphCommunity> communities,
    {int topK = 3}
  ) async {
    // Truncate query if needed (embedding model: 512 tokens max ~1800 chars safe limit)
    final maxChars = 1800;
    final truncatedQuery = query.length > maxChars 
        ? query.substring(0, maxChars) 
        : query;
    
    final queryEmbedding = await embeddingCallback(truncatedQuery);
    if (queryEmbedding.isEmpty) {
      return communities.take(topK).toList();
    }
    
    final scoredCommunities = <({GraphCommunity community, double similarity})>[];
    
    for (final community in communities) {
      if (community.summary.isEmpty) continue;
      
      // Truncate summary to fit embedding model (512 tokens ~1800 chars safe)
      final truncatedSummary = community.summary.length > maxChars
          ? community.summary.substring(0, maxChars)
          : community.summary;
      
      final summaryEmbedding = await embeddingCallback(truncatedSummary);
      if (summaryEmbedding.isEmpty) continue;
      
      final similarity = MathUtils.cosineSimilarity(queryEmbedding, summaryEmbedding);
      scoredCommunities.add((community: community, similarity: similarity));
    }
    
    scoredCommunities.sort((a, b) => b.similarity.compareTo(a.similarity));
    return scoredCommunities.take(topK).map((s) => s.community).toList();
  }
}