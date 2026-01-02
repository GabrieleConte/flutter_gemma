import 'package:pigeon/pigeon.dart';
// Command to generate pigeon files: dart run pigeon --input pigeon.dart

enum PreferredBackend {
  unknown,
  cpu,
  gpu,
  gpuFloat16,
  gpuMixed,
  gpuFull,
  tpu,
}

// === GraphRAG Enums ===

enum PermissionType {
  contacts,
  calendar,
  notifications,
  photos,
  callLog,
  files,
}

enum PermissionStatus {
  granted,
  denied,
  restricted,
  notDetermined,
}

@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/pigeon.g.dart',
  kotlinOut: 'android/src/main/kotlin/dev/flutterberlin/flutter_gemma/PigeonInterface.g.kt',
  kotlinOptions: KotlinOptions(package: 'dev.flutterberlin.flutter_gemma'),
  swiftOut: 'ios/Classes/PigeonInterface.g.swift',
  swiftOptions: SwiftOptions(),
  dartPackageName: 'flutter_gemma',
))
@HostApi()
abstract class PlatformService {
  @async
  void createModel({
    required int maxTokens,
    required String modelPath,
    required List<int>? loraRanks,
    PreferredBackend? preferredBackend,
    // Add image support
    int? maxNumImages,
  });

  @async
  void closeModel();

  @async
  void createSession({
    required double temperature,
    required int randomSeed,
    required int topK,
    double? topP,
    String? loraPath,
    // Add option to enable vision modality
    bool? enableVisionModality,
  });

  @async
  void closeSession();

  @async
  int sizeInTokens(String prompt);

  @async
  void addQueryChunk(String prompt);

  // Add method for adding image
  @async
  void addImage(Uint8List imageBytes);

  @async
  String generateResponse();

  @async
  void generateResponseAsync();

  @async
  void stopGeneration();

  // === RAG Methods ===

  // RAG Embedding Methods
  @async
  void createEmbeddingModel({
    required String modelPath,
    required String tokenizerPath,
    PreferredBackend? preferredBackend,
  });

  @async
  void closeEmbeddingModel();

  @async
  List<double> generateEmbeddingFromModel(String text);

  @async
  List<Object?> generateEmbeddingsFromModel(List<String> texts);

  @async
  int getEmbeddingDimension();

  // RAG Vector Store Methods
  @async
  void initializeVectorStore(String databasePath);

  @async
  void addDocument({
    required String id,
    required String content,
    required List<double> embedding,
    String? metadata,
  });

  @async
  List<RetrievalResult> searchSimilar({
    required List<double> queryEmbedding,
    required int topK,
    double threshold = 0.0,
  });

  @async
  VectorStoreStats getVectorStoreStats();

  @async
  void clearVectorStore();

  @async
  void closeVectorStore();

  // === GraphRAG Graph Store Methods ===

  @async
  void initializeGraphStore(String databasePath);

  @async
  void addEntity({
    required String id,
    required String name,
    required String type,
    required List<double> embedding,
    String? description,
    String? metadata,
    required int lastModified,
  });

  @async
  void updateEntity({
    required String id,
    String? name,
    String? type,
    List<double>? embedding,
    String? description,
    String? metadata,
    int? lastModified,
  });

  @async
  void deleteEntity(String id);

  @async
  EntityResult? getEntity(String id);

  @async
  List<EntityResult> getEntitiesByType(String type);

  @async
  List<EntityWithEmbedding> getEntitiesWithEmbeddingsByType(String type);

  @async
  void addRelationship({
    required String id,
    required String sourceId,
    required String targetId,
    required String type,
    double weight = 1.0,
    String? metadata,
  });

  @async
  void deleteRelationship(String id);

  @async
  List<RelationshipResult> getRelationships(String entityId);

  @async
  void addCommunity({
    required String id,
    required int level,
    required String summary,
    required List<String> entityIds,
    required List<double> embedding,
    String? metadata,
  });

  @async
  void updateCommunitySummary({
    required String id,
    required String summary,
    required List<double> embedding,
  });

  @async
  List<CommunityResult> getCommunitiesByLevel(int level);

  @async
  List<EntityResult> getEntityNeighbors({
    required String entityId,
    int depth = 1,
    String? relationshipType,
  });

  @async
  List<EntityWithScoreResult> searchEntitiesBySimilarity({
    required List<double> queryEmbedding,
    required int topK,
    double threshold = 0.0,
    String? entityType,
  });

  @async
  List<CommunityWithScoreResult> searchCommunitiesBySimilarity({
    required List<double> queryEmbedding,
    required int topK,
    int? level,
  });

  @async
  GraphQueryResult executeGraphQuery(String query);

  @async
  GraphStats getGraphStats();

  @async
  void clearGraphStore();

  @async
  void closeGraphStore();

  // === System Data Connector Methods ===

  @async
  PermissionStatus checkPermission(PermissionType type);

  @async
  PermissionStatus requestPermission(PermissionType type);

  @async
  List<ContactResult> fetchContacts({
    int? sinceTimestamp,
    int? limit,
  });

  @async
  List<CalendarEventResult> fetchCalendarEvents({
    int? sinceTimestamp,
    int? startDate,
    int? endDate,
    int? limit,
  });

  @async
  List<PhotoResult> fetchPhotos({
    int? sinceTimestamp,
    int? limit,
    bool? includeLocation,
  });

  @async
  List<CallLogResult> fetchCallLog({
    int? sinceTimestamp,
    int? limit,
  });

  // === Document Methods ===

  /// Opens a document picker for the user to select files.
  /// Returns a list of documents the user selected.
  @async
  List<DocumentResult> pickDocuments({
    List<String>? allowedExtensions,
    bool? allowMultiple,
  });

  @async
  List<DocumentResult> fetchDocuments({
    int? sinceTimestamp,
    int? limit,
    List<String>? allowedExtensions,
  });

  @async
  String? readDocumentContent({
    required String documentId,
    int? maxLength,
  });

  // === Photo Thumbnail Methods ===

  @async
  Uint8List? getPhotoThumbnail({
    required String photoId,
    int? maxWidth,
    int? maxHeight,
  });

  // === MediaPipe Analysis Methods ===

  @async
  PhotoAnalysisResult analyzePhoto({
    required String photoId,
    required Uint8List imageBytes,
    bool? detectFaces,
    bool? detectObjects,
    bool? detectText,
  });

  // === Foreground Service Methods ===
  
  @async
  void startIndexingForegroundService();

  @async
  void stopIndexingForegroundService();

  @async
  void updateIndexingProgress({
    required double progress,
    required String phase,
    required int entities,
    required int relationships,
  });

  @async
  bool isIndexingServiceRunning();
}

// === RAG Data Classes ===

class RetrievalResult {
  final String id;
  final String content;
  final double similarity;
  final String? metadata;

  RetrievalResult({
    required this.id,
    required this.content,
    required this.similarity,
    this.metadata,
  });
}

class VectorStoreStats {
  final int documentCount;
  final int vectorDimension;

  VectorStoreStats({
    required this.documentCount,
    required this.vectorDimension,
  });
}

// === GraphRAG Data Classes ===

class EntityResult {
  final String id;
  final String name;
  final String type;
  final String? description;
  final String? metadata;
  final int lastModified;

  EntityResult({
    required this.id,
    required this.name,
    required this.type,
    this.description,
    this.metadata,
    required this.lastModified,
  });
}

/// Entity result with embedding included (for similarity calculations)
class EntityWithEmbedding {
  final String id;
  final String name;
  final String type;
  final String? description;
  final String? metadata;
  final int lastModified;
  final List<double> embedding;

  EntityWithEmbedding({
    required this.id,
    required this.name,
    required this.type,
    this.description,
    this.metadata,
    required this.lastModified,
    required this.embedding,
  });
}

class RelationshipResult {
  final String id;
  final String sourceId;
  final String targetId;
  final String type;
  final double weight;
  final String? metadata;

  RelationshipResult({
    required this.id,
    required this.sourceId,
    required this.targetId,
    required this.type,
    required this.weight,
    this.metadata,
  });
}

class CommunityResult {
  final String id;
  final int level;
  final String summary;
  final List<String?> entityIds;
  final String? metadata;

  CommunityResult({
    required this.id,
    required this.level,
    required this.summary,
    required this.entityIds,
    this.metadata,
  });
}

class GraphStats {
  final int entityCount;
  final int relationshipCount;
  final int communityCount;
  final int maxCommunityLevel;
  final int vectorDimension;

  GraphStats({
    required this.entityCount,
    required this.relationshipCount,
    required this.communityCount,
    required this.maxCommunityLevel,
    required this.vectorDimension,
  });
}

class ContactResult {
  final String id;
  final String? givenName;
  final String? familyName;
  final String? organizationName;
  final String? jobTitle;
  final List<String?> emailAddresses;
  final List<String?> phoneNumbers;
  final int lastModified;

  ContactResult({
    required this.id,
    this.givenName,
    this.familyName,
    this.organizationName,
    this.jobTitle,
    required this.emailAddresses,
    required this.phoneNumbers,
    required this.lastModified,
  });
}

class CalendarEventResult {
  final String id;
  final String title;
  final String? location;
  final String? notes;
  final int startDate;
  final int endDate;
  final List<String?> attendees;
  final int lastModified;

  CalendarEventResult({
    required this.id,
    required this.title,
    this.location,
    this.notes,
    required this.startDate,
    required this.endDate,
    required this.attendees,
    required this.lastModified,
  });
}

class GraphQueryResult {
  final List<EntityResult?> entities;
  final List<RelationshipResult?> relationships;

  GraphQueryResult({
    required this.entities,
    required this.relationships,
  });
}

class EntityWithScoreResult {
  final EntityResult entity;
  final double score;

  EntityWithScoreResult({
    required this.entity,
    required this.score,
  });
}

class CommunityWithScoreResult {
  final CommunityResult community;
  final double score;

  CommunityWithScoreResult({
    required this.community,
    required this.score,
  });
}
// === Photos & Call Log Data Classes ===

class PhotoResult {
  final String id;
  final String? filename;
  final int width;
  final int height;
  final int creationDate;
  final int modificationDate;
  final double? latitude;
  final double? longitude;
  final String? locationName;
  final int? duration; // For videos, in milliseconds
  final String mediaType; // 'image' or 'video'
  final String? mimeType;
  final int? fileSize;
  // Thumbnail bytes for analysis (optional, for efficiency)
  final Uint8List? thumbnailBytes;

  PhotoResult({
    required this.id,
    this.filename,
    required this.width,
    required this.height,
    required this.creationDate,
    required this.modificationDate,
    this.latitude,
    this.longitude,
    this.locationName,
    this.duration,
    required this.mediaType,
    this.mimeType,
    this.fileSize,
    this.thumbnailBytes,
  });
}

// === Document Data Classes ===

/// Document types supported for extraction
enum DocumentType {
  plainText,  // .txt
  markdown,   // .md
  pdf,        // .pdf
  rtf,        // .rtf
  html,       // .html
  other,
}

class DocumentResult {
  final String id;
  final String name;
  final String path;
  final DocumentType documentType;
  final String? mimeType;
  final int fileSize;
  final int createdDate;
  final int modifiedDate;
  final String? textPreview; // First N chars of content for quick display

  DocumentResult({
    required this.id,
    required this.name,
    required this.path,
    required this.documentType,
    this.mimeType,
    required this.fileSize,
    required this.createdDate,
    required this.modifiedDate,
    this.textPreview,
  });
}

enum CallType {
  incoming,
  outgoing,
  missed,
  rejected,
  blocked,
  voicemail,
  unknown,
}

class CallLogResult {
  final String id;
  final String? name; // Contact name if available
  final String phoneNumber;
  final CallType callType;
  final int timestamp; // When the call occurred
  final int duration; // In seconds
  final bool isRead;
  final String? geocodedLocation;

  CallLogResult({
    required this.id,
    this.name,
    required this.phoneNumber,
    required this.callType,
    required this.timestamp,
    required this.duration,
    required this.isRead,
    this.geocodedLocation,
  });
}

// === MediaPipe Analysis Results ===

class DetectedFace {
  final double x;
  final double y;
  final double width;
  final double height;
  final double confidence;
  final String? recognizedPerson; // If matched with contacts

  DetectedFace({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.confidence,
    this.recognizedPerson,
  });
}

class DetectedObject {
  final String label;
  final double confidence;
  final double x;
  final double y;
  final double width;
  final double height;

  DetectedObject({
    required this.label,
    required this.confidence,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });
}

class DetectedText {
  final String text;
  final double confidence;
  final double x;
  final double y;
  final double width;
  final double height;

  DetectedText({
    required this.text,
    required this.confidence,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });
}

class PhotoAnalysisResult {
  final String photoId;
  final List<DetectedFace?> faces;
  final List<DetectedObject?> objects;
  final List<DetectedText?> texts;
  final List<String?> labels; // Image classification labels
  final String? dominantColors;
  final bool isScreenshot;
  final bool hasText;

  PhotoAnalysisResult({
    required this.photoId,
    required this.faces,
    required this.objects,
    required this.texts,
    required this.labels,
    this.dominantColors,
    required this.isScreenshot,
    required this.hasText,
  });
}