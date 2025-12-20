export 'flutter_gemma_interface.dart';
export 'model_file_manager_interface.dart';
export 'pigeon.g.dart'; // Export generated types like PreferredBackend, ModelFileType, etc.
export 'core/message.dart';
export 'core/model.dart'; // Export ModelType and other model-related classes
export 'core/model_response.dart';
export 'core/function_call_parser.dart';
export 'core/tool.dart';
export 'core/chat.dart';
export 'core/model_management/cancel_token.dart';

// Export image processing utilities to prevent AI image corruption
export 'core/image_processor.dart';
export 'core/image_tokenizer.dart' hide ModelType;
export 'core/vision_encoder_validator.dart';
export 'core/image_error_handler.dart';
export 'core/multimodal_image_handler.dart';

// Export migration utilities (optional, user must call explicitly)
export 'core/migration/legacy_preferences_migrator.dart';

// Export Modern API
export 'core/api/flutter_gemma.dart';
export 'core/api/inference_installation_builder.dart';
export 'core/api/embedding_installation_builder.dart';

// Export Model Specs (needed for advanced use cases)
export 'mobile/flutter_gemma_mobile.dart'
    show
        // Model specifications
        InferenceModelSpec,
        EmbeddingModelSpec,
        ModelSpec,
        ModelFile,
        // Download progress
        DownloadProgress,
        // Storage info
        StorageStats,
        OrphanedFileInfo,
        // Model management types
        ModelManagementType,
        // Exceptions
        ModelStorageException;

// ModelReplacePolicy is already exported from model_file_manager_interface.dart

// Export RAG components
export 'rag/embedding_models.dart';

// Export GraphRAG components
export 'rag/graph_rag.dart';
export 'rag/graph/graph_repository.dart';
export 'rag/connectors/data_connector.dart';
export 'rag/connectors/google_suite_connector.dart';
export 'rag/graph/entity_extractor.dart';
export 'rag/graph/community_detection.dart';
export 'rag/graph/cypher_parser.dart';
export 'rag/graph/hybrid_query_engine.dart';
export 'rag/graph/background_indexing.dart';

