import Flutter
import UIKit

@available(iOS 13.0, *)
public class FlutterGemmaPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
      let platformService = PlatformServiceImpl()
      PlatformServiceSetup.setUp(binaryMessenger: registrar.messenger(), api: platformService)

      let eventChannel = FlutterEventChannel(
        name: "flutter_gemma_stream", binaryMessenger: registrar.messenger())
      eventChannel.setStreamHandler(platformService)

      // Bundled resources method channel
      let bundledChannel = FlutterMethodChannel(
        name: "flutter_gemma_bundled",
        binaryMessenger: registrar.messenger())
      bundledChannel.setMethodCallHandler { (call, result) in
        if call.method == "getBundledResourcePath" {
          guard let args = call.arguments as? [String: Any],
                let resourceName = args["resourceName"] as? String else {
            result(FlutterError(code: "INVALID_ARGS",
                               message: "resourceName is required",
                               details: nil))
            return
          }

          // Split resourceName into name and extension
          let components = resourceName.split(separator: ".")
          let name = String(components[0])
          let ext = components.count > 1 ? String(components[1]) : ""

          // Get path from Bundle.main
          if let path = Bundle.main.path(forResource: name, ofType: ext) {
            result(path)
          } else {
            result(FlutterError(code: "NOT_FOUND",
                               message: "Resource not found in bundle: \(resourceName)",
                               details: nil))
          }
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
  }
}

class PlatformServiceImpl : NSObject, PlatformService, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?
    private var model: InferenceModel?
    private var session: InferenceSession?

    // Embedding-related properties
    private var embeddingWrapper: GemmaEmbeddingWrapper?

    // VectorStore property
    private var vectorStore: VectorStore?

    // GraphStore property
    private var graphStore: GraphStore?

    // SystemDataConnector property
    private var systemDataConnector: SystemDataConnector?

    func createModel(
        maxTokens: Int64,
        modelPath: String,
        loraRanks: [Int64]?,
        preferredBackend: PreferredBackend?,
        maxNumImages: Int64?,
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                self.model = try InferenceModel(
                    modelPath: modelPath,
                    maxTokens: Int(maxTokens),
                    supportedLoraRanks: loraRanks?.map(Int.init),
                    maxNumImages: Int(maxNumImages ?? 0)
                )
                DispatchQueue.main.async {
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func closeModel(completion: @escaping (Result<Void, any Error>) -> Void) {
        model = nil
        completion(.success(()))
    }

    func createSession(
        temperature: Double,
        randomSeed: Int64,
        topK: Int64,
        topP: Double?,
        loraPath: String?,
        enableVisionModality: Bool?,
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        guard let inference = model?.inference else {
            completion(.failure(PigeonError(code: "Inference model not created", message: nil, details: nil)))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let newSession = try InferenceSession(
                    inference: inference,
                    temperature: Float(temperature),
                    randomSeed: Int(randomSeed),
                    topk: Int(topK),
                    topP: topP,
                    loraPath: loraPath,
                    enableVisionModality: enableVisionModality ?? false
                )
                DispatchQueue.main.async {
                    self.session = newSession
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func closeSession(completion: @escaping (Result<Void, any Error>) -> Void) {
        session = nil
        completion(.success(()))
    }

    func sizeInTokens(prompt: String, completion: @escaping (Result<Int64, any Error>) -> Void) {
        guard let session = session else {
            completion(.failure(PigeonError(code: "Session not created", message: nil, details: nil)))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let tokenCount = try session.sizeInTokens(prompt: prompt)
                DispatchQueue.main.async { completion(.success(Int64(tokenCount))) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func addQueryChunk(prompt: String, completion: @escaping (Result<Void, any Error>) -> Void) {
        guard let session = session else {
            completion(.failure(PigeonError(code: "Session not created", message: nil, details: nil)))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try session.addQueryChunk(prompt: prompt)
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // Add method for adding image
    func addImage(imageBytes: FlutterStandardTypedData, completion: @escaping (Result<Void, any Error>) -> Void) {
        guard let session = session else {
            completion(.failure(PigeonError(code: "Session not created", message: nil, details: nil)))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let uiImage = UIImage(data: imageBytes.data) else {
                    DispatchQueue.main.async {
                        completion(.failure(PigeonError(code: "Invalid image data", message: "Could not create UIImage from data", details: nil)))
                    }
                    return
                }

                guard let cgImage = uiImage.cgImage else {
                    DispatchQueue.main.async {
                        completion(.failure(PigeonError(code: "Invalid image format", message: "Could not get CGImage from UIImage", details: nil)))
                    }
                    return
                }

                try session.addImage(image: cgImage)

                DispatchQueue.main.async {
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func generateResponse(completion: @escaping (Result<String, any Error>) -> Void) {
        guard let session = session else {
            completion(.failure(PigeonError(code: "Session not created", message: nil, details: nil)))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let response = try session.generateResponse()
                DispatchQueue.main.async { completion(.success(response)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    @available(iOS 13.0, *)
    func generateResponseAsync(completion: @escaping (Result<Void, any Error>) -> Void) {
        print("[PLUGIN LOG] generateResponseAsync called")
        guard let session = session, let eventSink = eventSink else {
            print("[PLUGIN LOG] Session or eventSink not created")
            completion(.failure(PigeonError(code: "Session or eventSink not created", message: nil, details: nil)))
            return
        }
        
        print("[PLUGIN LOG] Session and eventSink available, starting generation")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                print("[PLUGIN LOG] Getting async stream from session")
                let stream = try session.generateResponseAsync()
                print("[PLUGIN LOG] Got stream, starting Task")
                Task.detached { [weak self] in
                    guard let self = self else { 
                        print("[PLUGIN LOG] Self is nil in Task")
                        return 
                    }
                    do {
                        print("[PLUGIN LOG] Starting to iterate over stream")
                        var tokenCount = 0
                        for try await token in stream {
                            tokenCount += 1
                            print("[PLUGIN LOG] Got token #\(tokenCount): '\(token)'")
                            DispatchQueue.main.async {
                                print("[PLUGIN LOG] Sending token to Flutter via eventSink")
                                eventSink(["partialResult": token, "done": false])
                                print("[PLUGIN LOG] Token sent to Flutter")
                            }
                        }
                        print("[PLUGIN LOG] Stream finished after \(tokenCount) tokens")
                        DispatchQueue.main.async {
                            print("[PLUGIN LOG] Sending FlutterEndOfEventStream")
                            eventSink(FlutterEndOfEventStream)
                            print("[PLUGIN LOG] FlutterEndOfEventStream sent")
                        }
                    } catch {
                        print("[PLUGIN LOG] Error in stream iteration: \(error)")
                        DispatchQueue.main.async {
                            eventSink(FlutterError(code: "ERROR", message: error.localizedDescription, details: nil))
                        }
                    }
                }
                DispatchQueue.main.async {
                    print("[PLUGIN LOG] Completing with success")
                    completion(.success(()))
                }
            } catch {
                print("[PLUGIN LOG] Error creating stream: \(error)")
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func stopGeneration(completion: @escaping (Result<Void, any Error>) -> Void) {
        completion(.failure(PigeonError(
            code: "stop_not_supported", 
            message: "Stop generation is not supported on iOS platform yet", 
            details: nil
        )))
    }

    // MARK: - RAG Methods (iOS Implementation)
    
    func createEmbeddingModel(modelPath: String, tokenizerPath: String, preferredBackend: PreferredBackend?, completion: @escaping (Result<Void, Error>) -> Void) {
        print("[PLUGIN] Creating embedding model")
        print("[PLUGIN] Model path: \(modelPath)")
        print("[PLUGIN] Tokenizer path: \(tokenizerPath)")
        print("[PLUGIN] Preferred backend: \(String(describing: preferredBackend))")

        // Convert PreferredBackend to useGPU boolean
        let useGPU = preferredBackend == .gpu || preferredBackend == .gpuFloat16 || preferredBackend == .gpuMixed || preferredBackend == .gpuFull

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Create embedding wrapper instance (like Android GemmaEmbeddingModel)
                self.embeddingWrapper = try GemmaEmbeddingWrapper(
                    modelPath: modelPath,
                    tokenizerPath: tokenizerPath,
                    useGPU: useGPU
                )

                // Initialize the wrapper
                try self.embeddingWrapper?.initialize()

                DispatchQueue.main.async {
                    print("[PLUGIN] Embedding wrapper created successfully")
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Failed to create embedding model: \(error)")
                    completion(.failure(PigeonError(
                        code: "EmbeddingCreationFailed",
                        message: "Failed to create embedding model: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }
    
    func closeEmbeddingModel(completion: @escaping (Result<Void, Error>) -> Void) {
        print("[PLUGIN] Closing embedding model")

        DispatchQueue.global(qos: .userInitiated).async {
            // Close and release embedding wrapper
            self.embeddingWrapper?.close()
            self.embeddingWrapper = nil

            DispatchQueue.main.async {
                print("[PLUGIN] Embedding model closed successfully")
                completion(.success(()))
            }
        }
    }
    
    func generateEmbeddingFromModel(text: String, completion: @escaping (Result<[Double], Error>) -> Void) {
        print("[PLUGIN] Generating embedding for text: \(text)")

        guard let embeddingWrapper = embeddingWrapper else {
            completion(.failure(PigeonError(
                code: "EmbeddingModelNotInitialized",
                message: "Embedding model not initialized. Call createEmbeddingModel first.",
                details: nil
            )))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // ⚠️ FIX: Use embedDirect to avoid double prefix
                // embedDirect() only adds prefix once (in cached tokens)
                let doubleEmbeddings = try embeddingWrapper.embedDirect(text: text)

                DispatchQueue.main.async {
                    print("[PLUGIN] Generated embedding with \(doubleEmbeddings.count) dimensions")
                    completion(.success(doubleEmbeddings))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Failed to generate embedding: \(error)")
                    completion(.failure(PigeonError(
                        code: "EmbeddingGenerationFailed",
                        message: "Failed to generate embedding: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }

    func generateEmbeddingsFromModel(texts: [String], completion: @escaping (Result<[Any?], Error>) -> Void) {
        print("[PLUGIN] Generating embeddings for \(texts.count) texts")

        guard let embeddingWrapper = embeddingWrapper else {
            completion(.failure(PigeonError(
                code: "EmbeddingModelNotInitialized",
                message: "Embedding model not initialized. Call createEmbeddingModel first.",
                details: nil
            )))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var embeddings: [[Double]] = []
                for text in texts {
                    // ⚠️ FIX: Use embedDirect to avoid double prefix
                    let embedding = try embeddingWrapper.embedDirect(text: text)
                    embeddings.append(embedding)
                }

                DispatchQueue.main.async {
                    print("[PLUGIN] Generated \(embeddings.count) embeddings")
                    // Convert to [Any?] for pigeon compatibility (deep cast on Dart side)
                    completion(.success(embeddings as [Any?]))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Failed to generate embeddings: \(error)")
                    completion(.failure(PigeonError(
                        code: "EmbeddingGenerationFailed",
                        message: "Failed to generate embeddings: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }

    func getEmbeddingDimension(completion: @escaping (Result<Int64, Error>) -> Void) {
        print("[PLUGIN] Getting embedding dimension")

        guard let embeddingWrapper = embeddingWrapper else {
            completion(.failure(PigeonError(
                code: "EmbeddingModelNotInitialized",
                message: "Embedding model not initialized. Call createEmbeddingModel first.",
                details: nil
            )))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Generate a small test embedding to get dimension
                // ⚠️ FIX: Use embedDirect to avoid double prefix
                let testEmbedding = try embeddingWrapper.embedDirect(text: "test")
                let dimension = Int64(testEmbedding.count)

                DispatchQueue.main.async {
                    print("[PLUGIN] Embedding dimension: \(dimension)")
                    completion(.success(dimension))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Failed to get embedding dimension: \(error)")
                    completion(.failure(PigeonError(
                        code: "EmbeddingDimensionFailed",
                        message: "Failed to get embedding dimension: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }
    
    // MARK: - RAG VectorStore Methods (iOS Implementation)

    func initializeVectorStore(databasePath: String, completion: @escaping (Result<Void, Error>) -> Void) {
        print("[PLUGIN] Initializing vector store at: \(databasePath)")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Create new VectorStore instance
                self.vectorStore = VectorStore()

                // Initialize with database path
                try self.vectorStore?.initialize(databasePath: databasePath)

                DispatchQueue.main.async {
                    print("[PLUGIN] Vector store initialized successfully")
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Failed to initialize vector store: \(error)")
                    completion(.failure(PigeonError(
                        code: "VectorStoreInitFailed",
                        message: "Failed to initialize vector store: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }

    func addDocument(id: String, content: String, embedding: [Double], metadata: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        print("[PLUGIN] Adding document: \(id)")

        guard let vectorStore = vectorStore else {
            completion(.failure(PigeonError(
                code: "VectorStoreNotInitialized",
                message: "Vector store not initialized. Call initializeVectorStore first.",
                details: nil
            )))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try vectorStore.addDocument(
                    id: id,
                    content: content,
                    embedding: embedding,
                    metadata: metadata
                )

                DispatchQueue.main.async {
                    print("[PLUGIN] Document added successfully")
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Failed to add document: \(error)")
                    completion(.failure(PigeonError(
                        code: "AddDocumentFailed",
                        message: "Failed to add document: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }

    func searchSimilar(queryEmbedding: [Double], topK: Int64, threshold: Double, completion: @escaping (Result<[RetrievalResult], Error>) -> Void) {
        print("[PLUGIN] Searching similar documents (topK: \(topK), threshold: \(threshold))")

        guard let vectorStore = vectorStore else {
            completion(.failure(PigeonError(
                code: "VectorStoreNotInitialized",
                message: "Vector store not initialized. Call initializeVectorStore first.",
                details: nil
            )))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let results = try vectorStore.searchSimilar(
                    queryEmbedding: queryEmbedding,
                    topK: Int(topK),
                    threshold: threshold
                )

                DispatchQueue.main.async {
                    print("[PLUGIN] Found \(results.count) similar documents")
                    completion(.success(results))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Search failed: \(error)")
                    completion(.failure(PigeonError(
                        code: "SearchFailed",
                        message: "Search failed: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }

    func getVectorStoreStats(completion: @escaping (Result<VectorStoreStats, Error>) -> Void) {
        print("[PLUGIN] Getting vector store stats")

        guard let vectorStore = vectorStore else {
            completion(.failure(PigeonError(
                code: "VectorStoreNotInitialized",
                message: "Vector store not initialized. Call initializeVectorStore first.",
                details: nil
            )))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let stats = try vectorStore.getStats()

                DispatchQueue.main.async {
                    print("[PLUGIN] Vector store stats: \(stats.documentCount) documents, \(stats.vectorDimension)D")
                    completion(.success(stats))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Failed to get stats: \(error)")
                    completion(.failure(PigeonError(
                        code: "GetStatsFailed",
                        message: "Failed to get stats: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }

    func clearVectorStore(completion: @escaping (Result<Void, Error>) -> Void) {
        print("[PLUGIN] Clearing vector store")

        guard let vectorStore = vectorStore else {
            completion(.failure(PigeonError(
                code: "VectorStoreNotInitialized",
                message: "Vector store not initialized. Call initializeVectorStore first.",
                details: nil
            )))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try vectorStore.clear()

                DispatchQueue.main.async {
                    print("[PLUGIN] Vector store cleared successfully")
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Failed to clear vector store: \(error)")
                    completion(.failure(PigeonError(
                        code: "ClearFailed",
                        message: "Failed to clear vector store: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }

    func closeVectorStore(completion: @escaping (Result<Void, Error>) -> Void) {
        print("[PLUGIN] Closing vector store")

        DispatchQueue.global(qos: .userInitiated).async {
            self.vectorStore?.close()
            self.vectorStore = nil

            DispatchQueue.main.async {
                print("[PLUGIN] Vector store closed successfully")
                completion(.success(()))
            }
        }
    }

    // MARK: - GraphRAG Graph Store Methods

    func initializeGraphStore(databasePath: String, completion: @escaping (Result<Void, Error>) -> Void) {
        print("[PLUGIN] Initializing graph store at: \(databasePath)")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                self.graphStore = GraphStore()
                try self.graphStore?.initialize(databasePath: databasePath)

                DispatchQueue.main.async {
                    print("[PLUGIN] Graph store initialized successfully")
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Failed to initialize graph store: \(error)")
                    completion(.failure(PigeonError(
                        code: "GraphStoreInitFailed",
                        message: "Failed to initialize graph store: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }

    func addEntity(
        id: String,
        name: String,
        type: String,
        embedding: [Double],
        description: String?,
        metadata: String?,
        lastModified: Int64,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        print("[PLUGIN] Adding entity: \(id)")

        guard let graphStore = graphStore else {
            completion(.failure(PigeonError(
                code: "GraphStoreNotInitialized",
                message: "Graph store not initialized. Call initializeGraphStore first.",
                details: nil
            )))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try graphStore.addEntity(
                    id: id,
                    name: name,
                    type: type,
                    embedding: embedding,
                    description: description,
                    metadata: metadata,
                    lastModified: Int(lastModified)
                )

                DispatchQueue.main.async {
                    print("[PLUGIN] Entity added successfully")
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Failed to add entity: \(error)")
                    completion(.failure(PigeonError(
                        code: "AddEntityFailed",
                        message: "Failed to add entity: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }

    func updateEntity(
        id: String,
        name: String?,
        type: String?,
        embedding: [Double]?,
        description: String?,
        metadata: String?,
        lastModified: Int64?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        print("[PLUGIN] Updating entity: \(id)")

        guard let graphStore = graphStore else {
            completion(.failure(PigeonError(
                code: "GraphStoreNotInitialized",
                message: "Graph store not initialized. Call initializeGraphStore first.",
                details: nil
            )))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try graphStore.updateEntity(
                    id: id,
                    name: name,
                    type: type,
                    embedding: embedding,
                    description: description,
                    metadata: metadata,
                    lastModified: lastModified != nil ? Int(lastModified!) : nil
                )

                DispatchQueue.main.async {
                    print("[PLUGIN] Entity updated successfully")
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Failed to update entity: \(error)")
                    completion(.failure(PigeonError(
                        code: "UpdateEntityFailed",
                        message: "Failed to update entity: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }

    func deleteEntity(id: String, completion: @escaping (Result<Void, Error>) -> Void) {
        print("[PLUGIN] Deleting entity: \(id)")

        guard let graphStore = graphStore else {
            completion(.failure(PigeonError(
                code: "GraphStoreNotInitialized",
                message: "Graph store not initialized. Call initializeGraphStore first.",
                details: nil
            )))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try graphStore.deleteEntity(id: id)

                DispatchQueue.main.async {
                    print("[PLUGIN] Entity deleted successfully")
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Failed to delete entity: \(error)")
                    completion(.failure(PigeonError(
                        code: "DeleteEntityFailed",
                        message: "Failed to delete entity: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }

    func getEntity(id: String, completion: @escaping (Result<EntityResult?, Error>) -> Void) {
        print("[PLUGIN] Getting entity: \(id)")

        guard let graphStore = graphStore else {
            completion(.failure(PigeonError(
                code: "GraphStoreNotInitialized",
                message: "Graph store not initialized. Call initializeGraphStore first.",
                details: nil
            )))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let entity = try graphStore.getEntity(id: id)

                DispatchQueue.main.async {
                    completion(.success(entity))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Failed to get entity: \(error)")
                    completion(.failure(PigeonError(
                        code: "GetEntityFailed",
                        message: "Failed to get entity: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }

    func getEntitiesByType(type: String, completion: @escaping (Result<[EntityResult], Error>) -> Void) {
        print("[PLUGIN] Getting entities by type: \(type)")

        guard let graphStore = graphStore else {
            completion(.failure(PigeonError(
                code: "GraphStoreNotInitialized",
                message: "Graph store not initialized. Call initializeGraphStore first.",
                details: nil
            )))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let entities = try graphStore.getEntitiesByType(type: type)

                DispatchQueue.main.async {
                    print("[PLUGIN] Found \(entities.count) entities")
                    completion(.success(entities))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Failed to get entities: \(error)")
                    completion(.failure(PigeonError(
                        code: "GetEntitiesFailed",
                        message: "Failed to get entities: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }

    func addRelationship(
        id: String,
        sourceId: String,
        targetId: String,
        type: String,
        weight: Double,
        metadata: String?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        print("[PLUGIN] Adding relationship: \(id)")

        guard let graphStore = graphStore else {
            completion(.failure(PigeonError(
                code: "GraphStoreNotInitialized",
                message: "Graph store not initialized. Call initializeGraphStore first.",
                details: nil
            )))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try graphStore.addRelationship(
                    id: id,
                    sourceId: sourceId,
                    targetId: targetId,
                    type: type,
                    weight: weight,
                    metadata: metadata
                )

                DispatchQueue.main.async {
                    print("[PLUGIN] Relationship added successfully")
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Failed to add relationship: \(error)")
                    completion(.failure(PigeonError(
                        code: "AddRelationshipFailed",
                        message: "Failed to add relationship: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }

    func deleteRelationship(id: String, completion: @escaping (Result<Void, Error>) -> Void) {
        print("[PLUGIN] Deleting relationship: \(id)")

        guard let graphStore = graphStore else {
            completion(.failure(PigeonError(
                code: "GraphStoreNotInitialized",
                message: "Graph store not initialized. Call initializeGraphStore first.",
                details: nil
            )))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try graphStore.deleteRelationship(id: id)

                DispatchQueue.main.async {
                    print("[PLUGIN] Relationship deleted successfully")
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Failed to delete relationship: \(error)")
                    completion(.failure(PigeonError(
                        code: "DeleteRelationshipFailed",
                        message: "Failed to delete relationship: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }

    func getRelationships(entityId: String, completion: @escaping (Result<[RelationshipResult], Error>) -> Void) {
        print("[PLUGIN] Getting relationships for entity: \(entityId)")

        guard let graphStore = graphStore else {
            completion(.failure(PigeonError(
                code: "GraphStoreNotInitialized",
                message: "Graph store not initialized. Call initializeGraphStore first.",
                details: nil
            )))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let relationships = try graphStore.getRelationships(entityId: entityId)

                DispatchQueue.main.async {
                    print("[PLUGIN] Found \(relationships.count) relationships")
                    completion(.success(relationships))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Failed to get relationships: \(error)")
                    completion(.failure(PigeonError(
                        code: "GetRelationshipsFailed",
                        message: "Failed to get relationships: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }

    func addCommunity(
        id: String,
        level: Int64,
        summary: String,
        entityIds: [String],
        embedding: [Double],
        metadata: String?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        print("[PLUGIN] Adding community: \(id)")

        guard let graphStore = graphStore else {
            completion(.failure(PigeonError(
                code: "GraphStoreNotInitialized",
                message: "Graph store not initialized. Call initializeGraphStore first.",
                details: nil
            )))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try graphStore.addCommunity(
                    id: id,
                    level: Int(level),
                    summary: summary,
                    entityIds: entityIds,
                    embedding: embedding,
                    metadata: metadata
                )

                DispatchQueue.main.async {
                    print("[PLUGIN] Community added successfully")
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Failed to add community: \(error)")
                    completion(.failure(PigeonError(
                        code: "AddCommunityFailed",
                        message: "Failed to add community: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }

    func updateCommunitySummary(
        id: String,
        summary: String,
        embedding: [Double],
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        print("[PLUGIN] Updating community summary: \(id)")

        guard let graphStore = graphStore else {
            completion(.failure(PigeonError(
                code: "GraphStoreNotInitialized",
                message: "Graph store not initialized. Call initializeGraphStore first.",
                details: nil
            )))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try graphStore.updateCommunitySummary(id: id, summary: summary, embedding: embedding)

                DispatchQueue.main.async {
                    print("[PLUGIN] Community summary updated successfully")
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Failed to update community summary: \(error)")
                    completion(.failure(PigeonError(
                        code: "UpdateCommunitySummaryFailed",
                        message: "Failed to update community summary: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }

    func getCommunitiesByLevel(level: Int64, completion: @escaping (Result<[CommunityResult], Error>) -> Void) {
        print("[PLUGIN] Getting communities by level: \(level)")

        guard let graphStore = graphStore else {
            completion(.failure(PigeonError(
                code: "GraphStoreNotInitialized",
                message: "Graph store not initialized. Call initializeGraphStore first.",
                details: nil
            )))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let communities = try graphStore.getCommunitiesByLevel(level: Int(level))

                DispatchQueue.main.async {
                    print("[PLUGIN] Found \(communities.count) communities")
                    completion(.success(communities))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Failed to get communities: \(error)")
                    completion(.failure(PigeonError(
                        code: "GetCommunitiesFailed",
                        message: "Failed to get communities: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }

    func getEntityNeighbors(
        entityId: String,
        depth: Int64,
        relationshipType: String?,
        completion: @escaping (Result<[EntityResult], Error>) -> Void
    ) {
        print("[PLUGIN] Getting neighbors for entity: \(entityId) (depth: \(depth))")

        guard let graphStore = graphStore else {
            completion(.failure(PigeonError(
                code: "GraphStoreNotInitialized",
                message: "Graph store not initialized. Call initializeGraphStore first.",
                details: nil
            )))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let neighbors = try graphStore.getEntityNeighbors(
                    entityId: entityId,
                    depth: Int(depth),
                    relationshipType: relationshipType
                )

                DispatchQueue.main.async {
                    print("[PLUGIN] Found \(neighbors.count) neighbors")
                    completion(.success(neighbors))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Failed to get neighbors: \(error)")
                    completion(.failure(PigeonError(
                        code: "GetNeighborsFailed",
                        message: "Failed to get neighbors: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }

    func searchEntitiesBySimilarity(
        queryEmbedding: [Double],
        topK: Int64,
        threshold: Double,
        entityType: String?,
        completion: @escaping (Result<[EntityWithScoreResult], Error>) -> Void
    ) {
        print("[PLUGIN] Searching entities by similarity (topK: \(topK), threshold: \(threshold))")

        guard let graphStore = graphStore else {
            completion(.failure(PigeonError(
                code: "GraphStoreNotInitialized",
                message: "Graph store not initialized. Call initializeGraphStore first.",
                details: nil
            )))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let results = try graphStore.searchEntitiesBySimilarity(
                    queryEmbedding: queryEmbedding,
                    topK: Int(topK),
                    threshold: threshold,
                    entityType: entityType
                )

                DispatchQueue.main.async {
                    print("[PLUGIN] Found \(results.count) similar entities")
                    completion(.success(results))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Search failed: \(error)")
                    completion(.failure(PigeonError(
                        code: "SearchEntitiesFailed",
                        message: "Search failed: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }

    func searchCommunitiesBySimilarity(
        queryEmbedding: [Double],
        topK: Int64,
        level: Int64?,
        completion: @escaping (Result<[CommunityWithScoreResult], Error>) -> Void
    ) {
        print("[PLUGIN] Searching communities by similarity (topK: \(topK))")

        guard let graphStore = graphStore else {
            completion(.failure(PigeonError(
                code: "GraphStoreNotInitialized",
                message: "Graph store not initialized. Call initializeGraphStore first.",
                details: nil
            )))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let results = try graphStore.searchCommunitiesBySimilarity(
                    queryEmbedding: queryEmbedding,
                    topK: Int(topK),
                    level: level != nil ? Int(level!) : nil
                )

                DispatchQueue.main.async {
                    print("[PLUGIN] Found \(results.count) similar communities")
                    completion(.success(results))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Search failed: \(error)")
                    completion(.failure(PigeonError(
                        code: "SearchCommunitiesFailed",
                        message: "Search failed: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }

    func executeGraphQuery(query: String, completion: @escaping (Result<GraphQueryResult, Error>) -> Void) {
        print("[PLUGIN] Executing graph query: \(query)")

        // TODO: Implement Cypher DSL parser
        // For now, return empty result
        completion(.success(GraphQueryResult(entities: [], relationships: [])))
    }

    func getGraphStats(completion: @escaping (Result<GraphStats, Error>) -> Void) {
        print("[PLUGIN] Getting graph store stats")

        guard let graphStore = graphStore else {
            completion(.failure(PigeonError(
                code: "GraphStoreNotInitialized",
                message: "Graph store not initialized. Call initializeGraphStore first.",
                details: nil
            )))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let stats = try graphStore.getStats()

                DispatchQueue.main.async {
                    print("[PLUGIN] Graph stats: \(stats.entityCount) entities, \(stats.relationshipCount) relationships")
                    completion(.success(stats))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Failed to get stats: \(error)")
                    completion(.failure(PigeonError(
                        code: "GetStatsFailed",
                        message: "Failed to get stats: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }

    func clearGraphStore(completion: @escaping (Result<Void, Error>) -> Void) {
        print("[PLUGIN] Clearing graph store")

        guard let graphStore = graphStore else {
            completion(.failure(PigeonError(
                code: "GraphStoreNotInitialized",
                message: "Graph store not initialized. Call initializeGraphStore first.",
                details: nil
            )))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try graphStore.clear()

                DispatchQueue.main.async {
                    print("[PLUGIN] Graph store cleared successfully")
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Failed to clear graph store: \(error)")
                    completion(.failure(PigeonError(
                        code: "ClearGraphStoreFailed",
                        message: "Failed to clear graph store: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }

    func closeGraphStore(completion: @escaping (Result<Void, Error>) -> Void) {
        print("[PLUGIN] Closing graph store")

        DispatchQueue.global(qos: .userInitiated).async {
            self.graphStore?.close()
            self.graphStore = nil

            DispatchQueue.main.async {
                print("[PLUGIN] Graph store closed successfully")
                completion(.success(()))
            }
        }
    }

    // MARK: - System Data Connector Methods

    func checkPermission(type: PermissionType, completion: @escaping (Result<PermissionStatus, Error>) -> Void) {
        print("[PLUGIN] Checking permission: \(type)")

        if systemDataConnector == nil {
            systemDataConnector = SystemDataConnector()
        }

        let status = systemDataConnector!.checkPermission(type: type)
        completion(.success(status))
    }

    func requestPermission(type: PermissionType, completion: @escaping (Result<PermissionStatus, Error>) -> Void) {
        print("[PLUGIN] Requesting permission: \(type)")

        if systemDataConnector == nil {
            systemDataConnector = SystemDataConnector()
        }

        systemDataConnector!.requestPermission(type: type) { status in
            completion(.success(status))
        }
    }

    func fetchContacts(sinceTimestamp: Int64?, limit: Int64?, completion: @escaping (Result<[ContactResult], Error>) -> Void) {
        print("[PLUGIN] Fetching contacts (since: \(String(describing: sinceTimestamp)), limit: \(String(describing: limit)))")

        if systemDataConnector == nil {
            systemDataConnector = SystemDataConnector()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let contacts = try self.systemDataConnector!.fetchContacts(
                    sinceTimestamp: sinceTimestamp != nil ? Int(sinceTimestamp!) : nil,
                    limit: limit != nil ? Int(limit!) : nil
                )

                DispatchQueue.main.async {
                    print("[PLUGIN] Fetched \(contacts.count) contacts")
                    completion(.success(contacts))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Failed to fetch contacts: \(error)")
                    completion(.failure(PigeonError(
                        code: "FetchContactsFailed",
                        message: "Failed to fetch contacts: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }

    func fetchCalendarEvents(
        sinceTimestamp: Int64?,
        startDate: Int64?,
        endDate: Int64?,
        limit: Int64?,
        completion: @escaping (Result<[CalendarEventResult], Error>) -> Void
    ) {
        print("[PLUGIN] Fetching calendar events")

        if systemDataConnector == nil {
            systemDataConnector = SystemDataConnector()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let events = try self.systemDataConnector!.fetchCalendarEvents(
                    sinceTimestamp: sinceTimestamp != nil ? Int(sinceTimestamp!) : nil,
                    startDate: startDate != nil ? Int(startDate!) : nil,
                    endDate: endDate != nil ? Int(endDate!) : nil,
                    limit: limit != nil ? Int(limit!) : nil
                )

                DispatchQueue.main.async {
                    print("[PLUGIN] Fetched \(events.count) calendar events")
                    completion(.success(events))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Failed to fetch calendar events: \(error)")
                    completion(.failure(PigeonError(
                        code: "FetchCalendarEventsFailed",
                        message: "Failed to fetch calendar events: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }

    func fetchPhotos(
        sinceTimestamp: Int64?,
        limit: Int64?,
        includeLocation: Bool?,
        completion: @escaping (Result<[PhotoResult], Error>) -> Void
    ) {
        print("[PLUGIN] Fetching photos (since: \(String(describing: sinceTimestamp)), limit: \(String(describing: limit)))")

        if systemDataConnector == nil {
            systemDataConnector = SystemDataConnector()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let photos = try self.systemDataConnector!.fetchPhotos(
                    sinceTimestamp: sinceTimestamp != nil ? Int(sinceTimestamp!) : nil,
                    limit: limit != nil ? Int(limit!) : nil,
                    includeLocation: includeLocation
                )

                DispatchQueue.main.async {
                    print("[PLUGIN] Fetched \(photos.count) photos")
                    completion(.success(photos))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Failed to fetch photos: \(error)")
                    completion(.failure(PigeonError(
                        code: "FetchPhotosFailed",
                        message: "Failed to fetch photos: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }

    func fetchCallLog(
        sinceTimestamp: Int64?,
        limit: Int64?,
        completion: @escaping (Result<[CallLogResult], Error>) -> Void
    ) {
        print("[PLUGIN] Fetching call log - Note: iOS does not provide access to system call history")

        if systemDataConnector == nil {
            systemDataConnector = SystemDataConnector()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let calls = try self.systemDataConnector!.fetchCallLog(
                    sinceTimestamp: sinceTimestamp != nil ? Int(sinceTimestamp!) : nil,
                    limit: limit != nil ? Int(limit!) : nil
                )

                DispatchQueue.main.async {
                    print("[PLUGIN] Fetched \(calls.count) call log entries (iOS: always empty)")
                    completion(.success(calls))
                }
            } catch {
                DispatchQueue.main.async {
                    print("[PLUGIN] Failed to fetch call log: \(error)")
                    completion(.failure(PigeonError(
                        code: "FetchCallLogFailed",
                        message: "Failed to fetch call log: \(error.localizedDescription)",
                        details: nil
                    )))
                }
            }
        }
    }

    func analyzePhoto(
        photoId: String,
        imageBytes: FlutterStandardTypedData,
        detectFaces: Bool?,
        detectObjects: Bool?,
        detectText: Bool?,
        completion: @escaping (Result<PhotoAnalysisResult, Error>) -> Void
    ) {
        print("[PLUGIN] Analyzing photo: \(photoId)")

        // iOS implementation would use Vision framework for face/object detection
        // For now, return empty analysis result
        // TODO: Implement Vision framework integration
        
        let result = PhotoAnalysisResult(
            photoId: photoId,
            faces: [],
            objects: [],
            texts: [],
            labels: [],
            dominantColors: nil,
            isScreenshot: false,
            hasText: false
        )
        
        completion(.success(result))
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}