/// GraphRAG - Graph-based Retrieval Augmented Generation for flutter_gemma
///
/// This library provides a comprehensive GraphRAG implementation including:
/// - Knowledge graph construction from system APIs (Contacts, Calendar)
/// - Google Suite integration (with OAuth)
/// - LLM-based entity extraction
/// - Community detection using Louvain algorithm
/// - Hybrid query engine (Cypher DSL + embedding similarity)
/// - Background indexing with progress monitoring
///
/// Example usage:
/// ```dart
/// final graphRag = GraphRAGFactory.create(
///   databasePath: '/path/to/graph.db',
///   platform: PlatformService(),
///   llmCallback: (prompt) async => await llm.generate(prompt),
///   embeddingCallback: (text) async => await embedder.embed(text),
///   autoIndex: true,
/// );
///
/// await graphRag.initialize();
///
/// // Query the knowledge graph
/// final result = await graphRag.query('Who do I know at Google?');
/// print(result.contextString);
///
/// // Use for RAG augmentation
/// final augmented = await graphRag.augmentPrompt('Tell me about my meetings this week');
/// final response = await llm.generate(augmented);
/// ```
library graph_rag;

// Main facade
export '../graph_rag.dart';

// Graph repository
export 'graph_repository.dart'
    show
        GraphEntity,
        GraphRelationship,
        GraphCommunity,
        ScoredEntity,
        ScoredCommunity,
        GraphStatistics,
        GraphRepository,
        NativeGraphRepository;

// Data connectors
export '../connectors/data_connector.dart'
    show
        DataPermissionStatus,
        DataPermissionType,
        Contact,
        CalendarEvent,
        PhoneCall,
        PhoneCallType,
        Photo,
        PhotoAnalysis,
        FaceInfo,
        ObjectInfo,
        TextInfo,
        ConnectorConfig,
        DataConnector,
        ContactsConnector,
        CalendarConnector,
        PhotosConnector,
        CallLogConnector,
        ConnectorManager,
        PermissionDeniedException;

export '../connectors/google_suite_connector.dart'
    show
        GoogleOAuthToken,
        GoogleScopes,
        GoogleOAuthHandler,
        GoogleSuiteConfig,
        GoogleContact,
        GoogleCalendarEvent,
        GoogleDriveFile,
        GmailMessage,
        GoogleSuiteConnector,
        GoogleContactsConnector,
        GoogleCalendarConnector,
        GoogleDriveConnector,
        GmailConnector;

// Entity extraction
export 'entity_extractor.dart'
    show
        ExtractionResult,
        ExtractedEntity,
        ExtractedRelationship,
        EntityTypes,
        RelationshipTypes,
        EntityExtractionConfig,
        EntityExtractor,
        ExtractionPrompts,
        LLMEntityExtractor,
        EntityMerger;

// Community detection
export 'community_detection.dart'
    show
        CommunityDetectionConfig,
        DetectedCommunity,
        CommunityDetectionResult,
        LouvainCommunityDetector,
        CommunitySummarizer,
        CommunitySummary;

// Cypher parser
export 'cypher_parser.dart'
    show
        CypherParser,
        CypherQueryExecutor,
        CypherParseException,
        ParsedCypherQuery,
        NodePattern,
        RelationshipPattern,
        PathPattern,
        WhereCondition,
        ComparisonCondition,
        AndCondition,
        OrCondition,
        NotCondition,
        ReturnItem,
        OrderByItem;

// Hybrid query engine
export 'hybrid_query_engine.dart'
    show
        HybridQueryConfig,
        HybridQueryResult,
        ScoredQueryEntity,
        ScoredQueryCommunity,
        QueryMetadata,
        HybridQueryEngine,
        HybridQueryBuilder,
        HybridQueryResultExtension;

// Global query engine (GraphRAG paper map-reduce approach)
export 'global_query_engine.dart'
    show
        GlobalQueryConfig,
        CommunityAnswer,
        GlobalQueryResult,
        GlobalQueryEngine;

// Background indexing
export 'background_indexing.dart'
    show
        IndexingStatus,
        IndexingProgress,
        IndexingConfig,
        BackgroundIndexingService;
// Link prediction
export 'link_prediction.dart'
    show
        DataSourceTypes,
        YouEntity,
        YouRelationshipTypes,
        LinkPredictionConfig,
        PredictedLink,
        LinkPredictor,
        LinkPredictorBatch;