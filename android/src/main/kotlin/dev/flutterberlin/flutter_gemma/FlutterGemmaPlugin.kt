package dev.flutterberlin.flutter_gemma

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.util.Log
import java.io.File
import java.io.FileOutputStream

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.*

/** FlutterGemmaPlugin */
class FlutterGemmaPlugin: FlutterPlugin, ActivityAware, 
    PluginRegistry.RequestPermissionsResultListener,
    PluginRegistry.ActivityResultListener {
  /// The MethodChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
  private lateinit var eventChannel: EventChannel
  private lateinit var bundledChannel: MethodChannel
  private lateinit var context: Context
  private var service: PlatformServiceImpl? = null
  private var activityBinding: ActivityPluginBinding? = null

  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    context = flutterPluginBinding.applicationContext
    service = PlatformServiceImpl(context)
    eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "flutter_gemma_stream")
    eventChannel.setStreamHandler(service)
    PlatformService.setUp(flutterPluginBinding.binaryMessenger, service)

    // Setup bundled assets channel
    bundledChannel = MethodChannel(flutterPluginBinding.binaryMessenger, "flutter_gemma_bundled")
    bundledChannel.setMethodCallHandler { call, result ->
      when (call.method) {
        "copyAssetToFile" -> {
          try {
            val assetPath = call.argument<String>("assetPath")!!
            val destPath = call.argument<String>("destPath")!!
            copyAssetToFile(assetPath, destPath)
            result.success("success")
          } catch (e: Exception) {
            result.error("COPY_ERROR", e.message, null)
          }
        }
        else -> result.notImplemented()
      }
    }
  }

  private fun copyAssetToFile(assetPath: String, destPath: String) {
    val inputStream = context.assets.open(assetPath)
    val outputFile = File(destPath)
    outputFile.parentFile?.mkdirs()
    val outputStream = FileOutputStream(outputFile)

    inputStream.use { input ->
      outputStream.use { output ->
        input.copyTo(output, bufferSize = 8192)
      }
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    eventChannel.setStreamHandler(null)
    bundledChannel.setMethodCallHandler(null)
    service = null
  }

  // RequestPermissionsResultListener - forward permission results to service
  override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
    return service?.onRequestPermissionsResult(requestCode, permissions, grantResults) ?: false
  }

  // ActivityResultListener - forward activity results to service
  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
    return service?.onActivityResult(requestCode, resultCode, data) ?: false
  }

  // ActivityAware implementation for permission handling
  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activityBinding = binding
    binding.addRequestPermissionsResultListener(this)
    binding.addActivityResultListener(this)
    service?.setActivity(binding.activity)
  }

  override fun onDetachedFromActivityForConfigChanges() {
    activityBinding?.removeRequestPermissionsResultListener(this)
    activityBinding?.removeActivityResultListener(this)
    activityBinding = null
    service?.setActivity(null)
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    activityBinding = binding
    binding.addRequestPermissionsResultListener(this)
    binding.addActivityResultListener(this)
    service?.setActivity(binding.activity)
  }

  override fun onDetachedFromActivity() {
    activityBinding?.removeRequestPermissionsResultListener(this)
    activityBinding?.removeActivityResultListener(this)
    activityBinding = null
    service?.setActivity(null)
  }
}

private class PlatformServiceImpl(
  val context: Context
) : PlatformService, EventChannel.StreamHandler {
  private val TAG = "PlatformServiceImpl"
  private val scope = CoroutineScope(Dispatchers.IO)
  private var eventSink: EventChannel.EventSink? = null
  private var inferenceModel: InferenceModel? = null
  private var session: InferenceModelSession? = null
  private var activity: Activity? = null
  
  // RAG components
  private var embeddingModel: EmbeddingModel? = null
  private var vectorStore: VectorStore? = null

  // GraphRAG components
  private var graphStore: GraphStore? = null
  private var systemDataConnector: SystemDataConnector? = null

  // Document picker callback
  companion object {
    const val REQUEST_CODE_PICK_DOCUMENTS = 2001
  }
  private var pendingDocumentPickerCallback: ((Result<List<DocumentResult>>) -> Unit)? = null

  fun setActivity(activity: Activity?) {
    this.activity = activity
    systemDataConnector?.setActivity(activity)
  }

  // Forward permission results to SystemDataConnector
  fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
    return systemDataConnector?.onRequestPermissionsResult(requestCode, permissions, grantResults) ?: false
  }

  // Handle activity results (document picker)
  fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
    if (requestCode == REQUEST_CODE_PICK_DOCUMENTS) {
      Log.d(TAG, "Document picker result: resultCode=$resultCode")
      val callback = pendingDocumentPickerCallback
      pendingDocumentPickerCallback = null
      
      if (callback == null) {
        Log.w(TAG, "No pending callback for document picker")
        return true
      }

      if (resultCode != Activity.RESULT_OK || data == null) {
        callback(Result.success(emptyList()))
        return true
      }

      scope.launch {
        try {
          val documents = mutableListOf<DocumentResult>()
          
          // Handle single or multiple selection
          val clipData = data.clipData
          if (clipData != null) {
            // Multiple files selected
            for (i in 0 until clipData.itemCount) {
              val uri = clipData.getItemAt(i).uri
              val doc = processDocumentUri(uri)
              if (doc != null) documents.add(doc)
            }
          } else {
            // Single file selected
            val uri = data.data
            if (uri != null) {
              val doc = processDocumentUri(uri)
              if (doc != null) documents.add(doc)
            }
          }

          Log.d(TAG, "Processed ${documents.size} documents from picker")
          callback(Result.success(documents))
        } catch (e: Exception) {
          Log.e(TAG, "Error processing picked documents: ${e.message}")
          callback(Result.failure(e))
        }
      }
      return true
    }
    return false
  }

  private fun processDocumentUri(uri: android.net.Uri): DocumentResult? {
    val contentResolver = context.contentResolver
    
    // Take persistent permission for the URI
    try {
      val takeFlags = Intent.FLAG_GRANT_READ_URI_PERMISSION
      contentResolver.takePersistableUriPermission(uri, takeFlags)
    } catch (e: Exception) {
      Log.w(TAG, "Could not take persistable permission for $uri: ${e.message}")
    }

    // Query document metadata
    val cursor = contentResolver.query(uri, null, null, null, null)
    cursor?.use {
      if (it.moveToFirst()) {
        val nameIndex = it.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
        val sizeIndex = it.getColumnIndex(android.provider.OpenableColumns.SIZE)
        
        val name = if (nameIndex >= 0) it.getString(nameIndex) else uri.lastPathSegment ?: "Unknown"
        val size = if (sizeIndex >= 0) it.getLong(sizeIndex) else 0L
        val mimeType = contentResolver.getType(uri)
        
        val extension = name.substringAfterLast('.', "").lowercase()
        val docType = when {
          mimeType?.contains("text/plain") == true || extension == "txt" -> DocumentType.PLAIN_TEXT
          mimeType?.contains("text/markdown") == true || extension == "md" -> DocumentType.MARKDOWN
          mimeType?.contains("pdf") == true || extension == "pdf" -> DocumentType.PDF
          mimeType?.contains("rtf") == true || extension == "rtf" -> DocumentType.RTF
          mimeType?.contains("html") == true || extension in listOf("html", "htm") -> DocumentType.HTML
          else -> DocumentType.OTHER
        }

        // Read text preview for text-based documents
        var textPreview: String? = null
        if (docType in listOf(DocumentType.PLAIN_TEXT, DocumentType.MARKDOWN, DocumentType.HTML)) {
          try {
            contentResolver.openInputStream(uri)?.use { inputStream ->
              textPreview = inputStream.bufferedReader().readText().take(500)
            }
          } catch (e: Exception) {
            Log.w(TAG, "Could not read preview for $name: ${e.message}")
          }
        }

        return DocumentResult(
          id = uri.toString(),  // Use URI as ID for content resolver access
          name = name,
          path = uri.toString(),
          documentType = docType,
          mimeType = mimeType,
          fileSize = size,
          createdDate = System.currentTimeMillis(),
          modifiedDate = System.currentTimeMillis(),
          textPreview = textPreview
        )
      }
    }
    return null
  }

  override fun createModel(
    maxTokens: Long,
    modelPath: String,
    loraRanks: List<Long>?,
    preferredBackend: PreferredBackend?,
    maxNumImages: Long?,
    callback: (Result<Unit>) -> Unit
  ) {
    scope.launch {
      try {
        val backendEnum = preferredBackend?.let {
          PreferredBackendEnum.values()[it.ordinal]
        }
        val config = InferenceModelConfig(
          modelPath,
          maxTokens.toInt(),
          loraRanks?.map { it.toInt() },
          backendEnum,
          maxNumImages?.toInt()
        )
        if (config != inferenceModel?.config) {
          inferenceModel?.close()
          inferenceModel = InferenceModel(context, config)
        }
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun closeModel(callback: (Result<Unit>) -> Unit) {
    try {
      inferenceModel?.close()
      inferenceModel = null
      callback(Result.success(Unit))
    } catch (e: Exception) {
      callback(Result.failure(e))
    }
  }

  override fun createSession(
    temperature: Double,
    randomSeed: Long,
    topK: Long,
    topP: Double?,
    loraPath: String?,
    enableVisionModality: Boolean?,
    callback: (Result<Unit>) -> Unit
  ) {
    scope.launch {
      try {
        val model = inferenceModel ?: throw IllegalStateException("Inference model is not created")
        val config = InferenceSessionConfig(
          temperature.toFloat(),
          randomSeed.toInt(),
          topK.toInt(),
          topP?.toFloat(),
          loraPath,
          enableVisionModality
        )
        session?.close()
        session = model.createSession(config)
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun closeSession(callback: (Result<Unit>) -> Unit) {
    try {
      session?.close()
      session = null
      callback(Result.success(Unit))
    } catch (e: Exception) {
      callback(Result.failure(e))
    }
  }

  override fun sizeInTokens(prompt: String, callback: (Result<Long>) -> Unit) {
    scope.launch {
      try {
        val size = session?.sizeInTokens(prompt) ?: throw IllegalStateException("Session not created")
        callback(Result.success(size.toLong()))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun addQueryChunk(prompt: String, callback: (Result<Unit>) -> Unit) {
    scope.launch {
      try {
        session?.addQueryChunk(prompt) ?: throw IllegalStateException("Session not created")
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun addImage(imageBytes: ByteArray, callback: (Result<Unit>) -> Unit) {
    scope.launch {
      try {
        session?.addImage(imageBytes) ?: throw IllegalStateException("Session not created")
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun generateResponse(callback: (Result<String>) -> Unit) {
    scope.launch {
      try {
        val result = session?.generateResponse() ?: throw IllegalStateException("Session not created")
        callback(Result.success(result))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun generateResponseAsync(callback: (Result<Unit>) -> Unit) {
    scope.launch {
      try {
        session?.generateResponseAsync() ?: throw IllegalStateException("Session not created")
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun stopGeneration(callback: (Result<Unit>) -> Unit) {
    scope.launch {
      try {
        session?.stopGeneration() ?: throw IllegalStateException("Session not created")
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
    eventSink = events
    val model = inferenceModel ?: return

    scope.launch {
      launch {
        model.partialResults.collect { (text, done) ->
          val payload = mapOf("partialResult" to text, "done" to done)
          withContext(Dispatchers.Main) {
            events?.success(payload)
            if (done) {
              events?.endOfStream()
            }
          }
        }
      }

      launch {
        model.errors.collect { error ->
          withContext(Dispatchers.Main) {
            events?.error("ERROR", error.message, null)
          }
        }
      }
    }
  }

  override fun onCancel(arguments: Any?) {
    eventSink = null
  }

  // === RAG Methods Implementation ===

  override fun createEmbeddingModel(
    modelPath: String,
    tokenizerPath: String,
    preferredBackend: PreferredBackend?,
    callback: (Result<Unit>) -> Unit
  ) {
    scope.launch {
      try {
        embeddingModel?.close()

        // Convert PreferredBackend to useGPU boolean
        val useGPU = when (preferredBackend) {
          PreferredBackend.GPU, PreferredBackend.GPU_FLOAT16,
          PreferredBackend.GPU_MIXED, PreferredBackend.GPU_FULL -> true
          else -> false
        }

        embeddingModel = EmbeddingModel(context, modelPath, tokenizerPath, useGPU)
        embeddingModel!!.initialize()
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun closeEmbeddingModel(callback: (Result<Unit>) -> Unit) {
    try {
      embeddingModel?.close()
      embeddingModel = null
      callback(Result.success(Unit))
    } catch (e: Exception) {
      callback(Result.failure(e))
    }
  }

  override fun generateEmbeddingFromModel(text: String, callback: (Result<List<Double>>) -> Unit) {
    scope.launch {
      try {
        val embedding = embeddingModel?.embed(text)
          ?: throw IllegalStateException("Embedding model not initialized. Call createEmbeddingModel first.")
        callback(Result.success(embedding))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun generateEmbeddingsFromModel(texts: List<String>, callback: (Result<List<Any?>>) -> Unit) {
    scope.launch {
      try {
        if (embeddingModel == null) {
          throw IllegalStateException("Embedding model not initialized. Call createEmbeddingModel first.")
        }

        val embeddings = mutableListOf<List<Double>>()
        for (text in texts) {
          val embedding = embeddingModel!!.embed(text)
          embeddings.add(embedding)
        }
        // Convert to List<Any?> for pigeon compatibility (deep cast on Dart side)
        callback(Result.success(embeddings as List<Any?>))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun getEmbeddingDimension(callback: (Result<Long>) -> Unit) {
    scope.launch {
      try {
        if (embeddingModel == null) {
          throw IllegalStateException("Embedding model not initialized. Call createEmbeddingModel first.")
        }

        // Generate a small test embedding to get dimension
        val testEmbedding = embeddingModel!!.embed("test")
        val dimension = testEmbedding.size.toLong()
        callback(Result.success(dimension))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun initializeVectorStore(databasePath: String, callback: (Result<Unit>) -> Unit) {
    scope.launch {
      try {
        vectorStore = null
        vectorStore = VectorStore(context)
        vectorStore!!.initialize(databasePath)
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun addDocument(
    id: String,
    content: String,
    embedding: List<Double>,
    metadata: String?,
    callback: (Result<Unit>) -> Unit
  ) {
    scope.launch {
      try {
        vectorStore?.addDocument(id, content, embedding, metadata)
          ?: throw IllegalStateException("Vector store not initialized")
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun searchSimilar(
    queryEmbedding: List<Double>,
    topK: Long,
    threshold: Double,
    callback: (Result<List<RetrievalResult>>) -> Unit
  ) {
    scope.launch {
      try {
        val results = vectorStore?.searchSimilar(queryEmbedding, topK.toInt(), threshold)
          ?: throw IllegalStateException("Vector store not initialized")
        callback(Result.success(results))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun getVectorStoreStats(callback: (Result<VectorStoreStats>) -> Unit) {
    scope.launch {
      try {
        val stats = vectorStore?.getStats()
          ?: throw IllegalStateException("Vector store not initialized")
        callback(Result.success(stats))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun clearVectorStore(callback: (Result<Unit>) -> Unit) {
    scope.launch {
      try {
        vectorStore?.clear()
          ?: throw IllegalStateException("Vector store not initialized")
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun closeVectorStore(callback: (Result<Unit>) -> Unit) {
    try {
      vectorStore?.close()
      vectorStore = null
      callback(Result.success(Unit))
    } catch (e: Exception) {
      callback(Result.failure(e))
    }
  }

  // === GraphRAG Graph Store Methods ===

  override fun initializeGraphStore(databasePath: String, callback: (Result<Unit>) -> Unit) {
    scope.launch {
      try {
        Log.d(TAG, "initializeGraphStore called with path: $databasePath")
        graphStore?.close()
        graphStore = GraphStore(context)
        graphStore!!.initialize(databasePath)
        Log.d(TAG, "GraphStore initialized successfully")
        callback(Result.success(Unit))
      } catch (e: Exception) {
        Log.e(TAG, "initializeGraphStore failed: ${e.message}")
        callback(Result.failure(e))
      }
    }
  }

  override fun addEntity(
    id: String,
    name: String,
    type: String,
    embedding: List<Double>,
    description: String?,
    metadata: String?,
    lastModified: Long,
    callback: (Result<Unit>) -> Unit
  ) {
    scope.launch {
      try {
        graphStore?.addEntity(id, name, type, embedding, description, metadata, lastModified)
          ?: throw IllegalStateException("Graph store not initialized")
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun updateEntity(
    id: String,
    name: String?,
    type: String?,
    embedding: List<Double>?,
    description: String?,
    metadata: String?,
    lastModified: Long?,
    callback: (Result<Unit>) -> Unit
  ) {
    scope.launch {
      try {
        graphStore?.updateEntity(id, name, type, embedding, description, metadata, lastModified)
          ?: throw IllegalStateException("Graph store not initialized")
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun deleteEntity(id: String, callback: (Result<Unit>) -> Unit) {
    scope.launch {
      try {
        graphStore?.deleteEntity(id)
          ?: throw IllegalStateException("Graph store not initialized")
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun getEntity(id: String, callback: (Result<EntityResult?>) -> Unit) {
    scope.launch {
      try {
        val store = graphStore
          ?: throw IllegalStateException("Graph store not initialized")
        val entity = store.getEntity(id)
        callback(Result.success(entity))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun getEntitiesByType(type: String, callback: (Result<List<EntityResult>>) -> Unit) {
    scope.launch {
      try {
        val entities = graphStore?.getEntitiesByType(type)
          ?: throw IllegalStateException("Graph store not initialized")
        callback(Result.success(entities))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun getEntitiesWithEmbeddingsByType(type: String, callback: (Result<List<EntityWithEmbedding>>) -> Unit) {
    scope.launch {
      try {
        val entities = graphStore?.getEntitiesWithEmbeddingsByType(type)
          ?: throw IllegalStateException("Graph store not initialized")
        callback(Result.success(entities))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun addRelationship(
    id: String,
    sourceId: String,
    targetId: String,
    type: String,
    weight: Double,
    metadata: String?,
    callback: (Result<Unit>) -> Unit
  ) {
    scope.launch {
      try {
        graphStore?.addRelationship(id, sourceId, targetId, type, weight, metadata)
          ?: throw IllegalStateException("Graph store not initialized")
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun deleteRelationship(id: String, callback: (Result<Unit>) -> Unit) {
    scope.launch {
      try {
        graphStore?.deleteRelationship(id)
          ?: throw IllegalStateException("Graph store not initialized")
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun getRelationships(entityId: String, callback: (Result<List<RelationshipResult>>) -> Unit) {
    scope.launch {
      try {
        val relationships = graphStore?.getRelationships(entityId)
          ?: throw IllegalStateException("Graph store not initialized")
        callback(Result.success(relationships))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun addCommunity(
    id: String,
    level: Long,
    summary: String,
    entityIds: List<String>,
    embedding: List<Double>,
    metadata: String?,
    callback: (Result<Unit>) -> Unit
  ) {
    scope.launch {
      try {
        graphStore?.addCommunity(id, level, summary, entityIds, embedding, metadata)
          ?: throw IllegalStateException("Graph store not initialized")
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun updateCommunitySummary(
    id: String,
    summary: String,
    embedding: List<Double>,
    callback: (Result<Unit>) -> Unit
  ) {
    scope.launch {
      try {
        graphStore?.updateCommunitySummary(id, summary, embedding)
          ?: throw IllegalStateException("Graph store not initialized")
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun getCommunitiesByLevel(level: Long, callback: (Result<List<CommunityResult>>) -> Unit) {
    scope.launch {
      try {
        val communities = graphStore?.getCommunitiesByLevel(level)
          ?: throw IllegalStateException("Graph store not initialized")
        callback(Result.success(communities))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun getEntityNeighbors(
    entityId: String,
    depth: Long,
    relationshipType: String?,
    callback: (Result<List<EntityResult>>) -> Unit
  ) {
    scope.launch {
      try {
        val neighbors = graphStore?.getEntityNeighbors(entityId, depth.toInt(), relationshipType)
          ?: throw IllegalStateException("Graph store not initialized")
        callback(Result.success(neighbors))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun searchEntitiesBySimilarity(
    queryEmbedding: List<Double>,
    topK: Long,
    threshold: Double,
    entityType: String?,
    callback: (Result<List<EntityWithScoreResult>>) -> Unit
  ) {
    scope.launch {
      try {
        val results = graphStore?.searchEntitiesBySimilarity(queryEmbedding, topK.toInt(), threshold, entityType)
          ?: throw IllegalStateException("Graph store not initialized")
        callback(Result.success(results))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun searchCommunitiesBySimilarity(
    queryEmbedding: List<Double>,
    topK: Long,
    level: Long?,
    callback: (Result<List<CommunityWithScoreResult>>) -> Unit
  ) {
    scope.launch {
      try {
        val results = graphStore?.searchCommunitiesBySimilarity(queryEmbedding, topK.toInt(), level)
          ?: throw IllegalStateException("Graph store not initialized")
        callback(Result.success(results))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun executeGraphQuery(query: String, callback: (Result<GraphQueryResult>) -> Unit) {
    scope.launch {
      try {
        // TODO: Implement Cypher DSL parser
        // For now, return empty result
        callback(Result.success(GraphQueryResult(entities = emptyList(), relationships = emptyList())))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun getGraphStats(callback: (Result<GraphStats>) -> Unit) {
    scope.launch {
      try {
        val stats = graphStore?.getStats()
          ?: throw IllegalStateException("Graph store not initialized")
        callback(Result.success(stats))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun clearGraphStore(callback: (Result<Unit>) -> Unit) {
    scope.launch {
      try {
        graphStore?.clear()
          ?: throw IllegalStateException("Graph store not initialized")
        callback(Result.success(Unit))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun closeGraphStore(callback: (Result<Unit>) -> Unit) {
    try {
      graphStore?.close()
      graphStore = null
      callback(Result.success(Unit))
    } catch (e: Exception) {
      callback(Result.failure(e))
    }
  }

  // === System Data Connector Methods ===

  override fun checkPermission(type: PermissionType, callback: (Result<PermissionStatus>) -> Unit) {
    try {
      if (systemDataConnector == null) {
        systemDataConnector = SystemDataConnector(context, activity)
      }
      val status = systemDataConnector!!.checkPermission(type)
      callback(Result.success(status))
    } catch (e: Exception) {
      callback(Result.failure(e))
    }
  }

  override fun requestPermission(type: PermissionType, callback: (Result<PermissionStatus>) -> Unit) {
    try {
      if (systemDataConnector == null) {
        systemDataConnector = SystemDataConnector(context, activity)
      }
      systemDataConnector!!.requestPermission(type) { status ->
        callback(Result.success(status))
      }
    } catch (e: Exception) {
      callback(Result.failure(e))
    }
  }

  override fun fetchContacts(sinceTimestamp: Long?, limit: Long?, callback: (Result<List<ContactResult>>) -> Unit) {
    scope.launch {
      try {
        if (systemDataConnector == null) {
          systemDataConnector = SystemDataConnector(context, activity)
        }
        val contacts = systemDataConnector!!.fetchContacts(sinceTimestamp, limit)
        callback(Result.success(contacts))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun fetchCalendarEvents(
    sinceTimestamp: Long?,
    startDate: Long?,
    endDate: Long?,
    limit: Long?,
    callback: (Result<List<CalendarEventResult>>) -> Unit
  ) {
    scope.launch {
      try {
        if (systemDataConnector == null) {
          systemDataConnector = SystemDataConnector(context, activity)
        }
        val events = systemDataConnector!!.fetchCalendarEvents(sinceTimestamp, startDate, endDate, limit)
        callback(Result.success(events))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun fetchPhotos(
    sinceTimestamp: Long?,
    limit: Long?,
    includeLocation: Boolean?,
    callback: (Result<List<PhotoResult>>) -> Unit
  ) {
    scope.launch {
      try {
        if (systemDataConnector == null) {
          systemDataConnector = SystemDataConnector(context, activity)
        }
        val photos = systemDataConnector!!.fetchPhotos(sinceTimestamp, limit, includeLocation)
        callback(Result.success(photos))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun fetchCallLog(
    sinceTimestamp: Long?,
    limit: Long?,
    callback: (Result<List<CallLogResult>>) -> Unit
  ) {
    scope.launch {
      try {
        if (systemDataConnector == null) {
          systemDataConnector = SystemDataConnector(context, activity)
        }
        val calls = systemDataConnector!!.fetchCallLog(sinceTimestamp, limit)
        callback(Result.success(calls))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun pickDocuments(
    allowedExtensions: List<String>?,
    allowMultiple: Boolean?,
    callback: (Result<List<DocumentResult>>) -> Unit
  ) {
    Log.d(TAG, "pickDocuments called, allowedExtensions=$allowedExtensions, allowMultiple=$allowMultiple")
    
    val currentActivity = activity
    if (currentActivity == null) {
      callback(Result.failure(IllegalStateException("No activity attached")))
      return
    }

    // Store callback for when picker returns
    pendingDocumentPickerCallback = callback

    // Build MIME types from extensions
    val mimeTypes = (allowedExtensions ?: listOf("txt", "md", "pdf", "rtf", "html")).mapNotNull { ext ->
      when (ext.lowercase()) {
        "txt" -> "text/plain"
        "md", "markdown" -> "text/markdown"
        "pdf" -> "application/pdf"
        "rtf" -> "application/rtf"
        "html", "htm" -> "text/html"
        "*" -> "*/*"
        else -> null
      }
    }.ifEmpty { listOf("*/*") }.toTypedArray()

    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
      addCategory(Intent.CATEGORY_OPENABLE)
      type = "*/*"
      putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes)
      if (allowMultiple == true) {
        putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
      }
      // Request persistent access
      addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
      addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
    }

    try {
      currentActivity.startActivityForResult(intent, REQUEST_CODE_PICK_DOCUMENTS)
    } catch (e: Exception) {
      Log.e(TAG, "Failed to launch document picker: ${e.message}")
      pendingDocumentPickerCallback = null
      callback(Result.failure(e))
    }
  }

  override fun fetchDocuments(
    sinceTimestamp: Long?,
    limit: Long?,
    allowedExtensions: List<String>?,
    callback: (Result<List<DocumentResult>>) -> Unit
  ) {
    scope.launch {
      try {
        if (systemDataConnector == null) {
          systemDataConnector = SystemDataConnector(context, activity)
        }
        val documents = systemDataConnector!!.fetchDocuments(sinceTimestamp, limit, allowedExtensions)
        callback(Result.success(documents))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun readDocumentContent(
    documentId: String,
    maxLength: Long?,
    callback: (Result<String?>) -> Unit
  ) {
    scope.launch {
      try {
        val max = maxLength?.toInt() ?: Int.MAX_VALUE
        
        // Check if documentId is a content:// URI (from document picker)
        if (documentId.startsWith("content://")) {
          val uri = android.net.Uri.parse(documentId)
          val mimeType = context.contentResolver.getType(uri)
          
          // Extract PDF content using raw parsing
          if (mimeType?.contains("pdf") == true) {
            Log.d(TAG, "Extracting text from PDF via content URI")
            val content = context.contentResolver.openInputStream(uri)?.use { inputStream ->
              extractTextFromPdfBytes(inputStream.readBytes(), max)
            }
            if (content != null && content.isNotEmpty()) {
              Log.d(TAG, "Extracted ${content.length} chars from PDF")
              callback(Result.success(content))
            } else {
              Log.w(TAG, "No text content extracted from PDF")
              callback(Result.success(null))
            }
            return@launch
          }
          
          val content = context.contentResolver.openInputStream(uri)?.use { inputStream ->
            val text = inputStream.bufferedReader().readText()
            if (text.length > max) text.take(max) else text
          }
          callback(Result.success(content))
          return@launch
        }
        
        // Fall back to SystemDataConnector for file-based IDs
        if (systemDataConnector == null) {
          systemDataConnector = SystemDataConnector(context, activity)
        }
        val content = systemDataConnector!!.readDocumentContent(documentId, maxLength)
        callback(Result.success(content))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  override fun getPhotoThumbnail(
    photoId: String,
    maxWidth: Long?,
    maxHeight: Long?,
    callback: (Result<ByteArray?>) -> Unit
  ) {
    scope.launch {
      try {
        if (systemDataConnector == null) {
          systemDataConnector = SystemDataConnector(context, activity)
        }
        val thumbnail = systemDataConnector!!.getPhotoThumbnail(photoId, maxWidth, maxHeight)
        callback(Result.success(thumbnail))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  // MediaPipe photo analysis
  private var mediaPipeAnalyzer: MediaPipeAnalyzer? = null

  override fun analyzePhoto(
    photoId: String,
    imageBytes: ByteArray,
    detectFaces: Boolean?,
    detectObjects: Boolean?,
    detectText: Boolean?,
    callback: (Result<PhotoAnalysisResult>) -> Unit
  ) {
    scope.launch {
      try {
        if (mediaPipeAnalyzer == null) {
          mediaPipeAnalyzer = MediaPipeAnalyzer(context)
          mediaPipeAnalyzer!!.initialize()
        }
        
        val result = mediaPipeAnalyzer!!.analyzePhoto(
          photoId = photoId,
          imageBytes = imageBytes,
          detectFaces = detectFaces ?: true,
          detectObjects = detectObjects ?: true,
          detectText = detectText ?: false
        )
        callback(Result.success(result))
      } catch (e: Exception) {
        callback(Result.failure(e))
      }
    }
  }

  // === Foreground Service Methods ===

  override fun startIndexingForegroundService(callback: (Result<Unit>) -> Unit) {
    try {
      IndexingForegroundService.startService(context)
      callback(Result.success(Unit))
    } catch (e: Exception) {
      callback(Result.failure(e))
    }
  }

  override fun stopIndexingForegroundService(callback: (Result<Unit>) -> Unit) {
    try {
      IndexingForegroundService.stopService(context)
      callback(Result.success(Unit))
    } catch (e: Exception) {
      callback(Result.failure(e))
    }
  }

  override fun updateIndexingProgress(
    progress: Double,
    phase: String,
    entities: Long,
    relationships: Long,
    callback: (Result<Unit>) -> Unit
  ) {
    try {
      IndexingForegroundService.updateProgress(
        context,
        progress.toFloat(),
        phase,
        entities.toInt(),
        relationships.toInt()
      )
      callback(Result.success(Unit))
    } catch (e: Exception) {
      callback(Result.failure(e))
    }
  }

  override fun isIndexingServiceRunning(callback: (Result<Boolean>) -> Unit) {
    try {
      callback(Result.success(IndexingForegroundService.isRunning()))
    } catch (e: Exception) {
      callback(Result.failure(e))
    }
  }

  // PdfBox initialization flag
  private var pdfBoxInitialized = false
  
  /**
   * Initialize PdfBox-Android library.
   * Must be called before using PDF extraction.
   */
  private fun initPdfBox() {
    if (!pdfBoxInitialized) {
      try {
        com.tom_roush.pdfbox.android.PDFBoxResourceLoader.init(context)
        pdfBoxInitialized = true
        Log.d(TAG, "PdfBox-Android initialized successfully")
      } catch (e: Exception) {
        Log.e(TAG, "Failed to initialize PdfBox-Android: ${e.message}")
      }
    }
  }

  /**
   * Extract text from PDF using PdfBox-Android library.
   * This properly handles compressed streams, CIDFonts, and ToUnicode CMaps.
   */
  private fun extractTextFromPdfBytes(bytes: ByteArray, maxLength: Int): String? {
    try {
      initPdfBox()
      
      Log.d(TAG, "Extracting text from PDF using PdfBox-Android (${bytes.size} bytes)")
      
      val inputStream = java.io.ByteArrayInputStream(bytes)
      val document = com.tom_roush.pdfbox.pdmodel.PDDocument.load(inputStream)
      
      try {
        val stripper = com.tom_roush.pdfbox.text.PDFTextStripper()
        stripper.sortByPosition = true
        
        val text = stripper.getText(document)
        val trimmedText = text.trim()
        
        if (trimmedText.isEmpty()) {
          Log.w(TAG, "PdfBox extracted empty text (PDF may be image-only)")
          return null
        }
        
        Log.d(TAG, "PdfBox extracted ${trimmedText.length} characters from PDF")
        
        // Truncate if needed
        val result = if (trimmedText.length > maxLength) {
          trimmedText.take(maxLength)
        } else {
          trimmedText
        }
        
        return result
      } finally {
        document.close()
      }
    } catch (e: Exception) {
      Log.e(TAG, "PdfBox extraction failed: ${e.message}", e)
      return null
    }
  }
}