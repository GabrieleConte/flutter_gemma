import 'dart:async';
import 'dart:math';

import 'graph_repository.dart';

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
/// 1. **Map Phase**: For each community summary at the selected level, generate
///    a partial answer and helpfulness score (0-100)
/// 2. **Reduce Phase**: Sort answers by helpfulness, select top answers that fit
///    in context window, and synthesize a final global answer
class GlobalQueryEngine {
  final GraphRepository repository;
  final Future<String> Function(String prompt) llmCallback;
  final GlobalQueryConfig config;

  GlobalQueryEngine({
    required this.repository,
    required this.llmCallback,
    GlobalQueryConfig? config,
  }) : config = config ?? GlobalQueryConfig();

  /// Execute a global query using map-reduce over community summaries
  /// 
  /// This is the main entry point for GraphRAG-style global queries that
  /// require understanding across the entire corpus.
  Future<GlobalQueryResult> query(String userQuery) async {
    final totalStopwatch = Stopwatch()..start();
    final mapStopwatch = Stopwatch();
    
    // Get all communities at the configured level
    final communities = await repository.getCommunitiesByLevel(config.communityLevel);
    
    if (communities.isEmpty) {
      // Try lower levels if configured level is empty
      for (var level = config.communityLevel - 1; level >= 0; level--) {
        final lowerCommunities = await repository.getCommunitiesByLevel(level);
        if (lowerCommunities.isNotEmpty) {
          return _executeQuery(userQuery, lowerCommunities, level, totalStopwatch);
        }
      }
      
      // No communities at any level
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
    final mapStopwatch = Stopwatch()..start();
    
    // === MAP PHASE ===
    // Process each community SEQUENTIALLY to generate partial answers
    // NOTE: We must process sequentially because the native LLM engine 
    // doesn't support concurrent inference calls - parallel calls cause crashes
    final communityAnswers = <CommunityAnswer>[];
    
    for (final community in communities) {
      final answer = await _generateCommunityAnswer(userQuery, community);
      if (answer != null) {
        communityAnswers.add(answer);
      }
    }
    
    mapStopwatch.stop();
    
    // Filter by minimum helpfulness score
    final filteredAnswers = communityAnswers
        .where((a) => a.helpfulnessScore >= config.minHelpfulnessScore)
        .toList();
    
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
    
    final prompt = '''---Role---
You are a helpful assistant responding to questions about data in the provided community summary.

---Goal---
Generate a response to the question based ONLY on the community summary provided below.
Also provide a helpfulness score from 0-100 indicating how relevant and useful your answer is for the question.

If the community summary does not contain information relevant to the question, respond with score 0.

---Community Summary---
${community.summary}

---Question---
$query

---Response Format---
First, output a helpfulness score on its own line: SCORE: <number from 0-100>
Then provide your answer based on the community summary.

Response:''';

    try {
      final response = await llmCallback(prompt);
      
      // Parse score and answer
      final scoreMatch = RegExp(r'SCORE:\s*(\d+)').firstMatch(response);
      final score = scoreMatch != null 
          ? int.tryParse(scoreMatch.group(1) ?? '0') ?? 0
          : 0;
      
      // Extract answer (everything after SCORE line)
      var answer = response;
      if (scoreMatch != null) {
        answer = response.substring(scoreMatch.end).trim();
      }
      
      // Clamp score to valid range
      final clampedScore = score.clamp(0, 100);
      
      return CommunityAnswer(
        communityId: community.id,
        summary: community.summary,
        answer: answer,
        helpfulnessScore: clampedScore,
        level: community.level,
      );
    } catch (e) {
      // Skip failed community processing
      return null;
    }
  }

  /// Reduce phase: Synthesize global answer from community answers
  Future<String> _generateGlobalAnswer(
    String query,
    List<CommunityAnswer> communityAnswers,
  ) async {
    if (communityAnswers.isEmpty) {
      return "I don't have enough relevant information to answer this question based on the available data.";
    }
    
    // Build context from community answers
    final answersContext = communityAnswers.asMap().entries.map((entry) {
      final idx = entry.key + 1;
      final answer = entry.value;
      return '''--- Report $idx (Helpfulness: ${answer.helpfulnessScore}/100) ---
${answer.answer}
''';
    }).join('\n');
    
    final prompt = '''---Role---
You are a helpful assistant responding to questions about a dataset by synthesizing perspectives from multiple analyst reports.

---Goal---
Generate a response of ${config.responseType} that responds to the user's question, summarizing all the reports from multiple analysts who focused on different parts of the dataset.

If you don't know the answer or the reports don't contain relevant information, say so. Do not make anything up.

The final response should:
1. Remove irrelevant information from the reports
2. Merge the cleaned information into a comprehensive answer
3. Provide explanations of key points and implications
4. Reference the report numbers when citing specific information, e.g., [Report 1, 3]

Do not mention "analysts" or "reports" in a way that's visible to the end user - just synthesize the information naturally.

---Analyst Reports---
$answersContext

---Question---
$query

---Target Response Format---
${config.responseType}

Response:''';

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
