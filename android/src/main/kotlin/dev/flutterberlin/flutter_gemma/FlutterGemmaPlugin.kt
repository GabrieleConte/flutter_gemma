package dev.flutterberlin.flutter_gemma

import android.app.Activity
import android.content.Context
import java.io.File
import java.io.FileOutputStream

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*

/** FlutterGemmaPlugin */
class FlutterGemmaPlugin: FlutterPlugin, ActivityAware {
  /// The MethodChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
  private lateinit var eventChannel: EventChannel
  private lateinit var bundledChannel: MethodChannel
  private lateinit var context: Context
  private var service: PlatformServiceImpl? = null

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

  // ActivityAware implementation for permission handling
  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    service?.setActivity(binding.activity)
  }

  override fun onDetachedFromActivityForConfigChanges() {
    service?.setActivity(null)
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    service?.setActivity(binding.activity)
  }

  override fun onDetachedFromActivity() {
    service?.setActivity(null)
  }
}

private class PlatformServiceImpl(
  val context: Context
) : PlatformService, EventChannel.StreamHandler {
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

  fun setActivity(activity: Activity?) {
    this.activity = activity
    systemDataConnector?.setActivity(activity)
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
        graphStore?.close()
        graphStore = GraphStore(context)
        graphStore!!.initialize(databasePath)
        callback(Result.success(Unit))
      } catch (e: Exception) {
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
        val entity = graphStore?.getEntity(id)
          ?: throw IllegalStateException("Graph store not initialized")
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
}