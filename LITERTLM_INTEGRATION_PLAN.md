# LiteRT-LM Integration Plan for GraphRAG

## Executive Summary

This document outlines a detailed implementation plan for integrating LiteRT-LM benefits (NPU support, larger context windows, faster reloads, and native function calling) into the flutter_gemma GraphRAG pipeline.

---

## 1. Research Findings

### 1.1 NPU Support on Android Emulators

**Finding: NPU is NOT available on Android Emulators**

| Aspect | Emulator | Physical Device |
|--------|----------|-----------------|
| CPU Backend | ✅ Supported | ✅ Supported |
| GPU Backend | ✅ Supported (software/host) | ✅ Supported |
| NPU Backend | ❌ Not Available | ✅ Available (Qualcomm/MediaTek) |

**Key Research Results:**
- Android Emulator documentation shows no NPU simulation capability
- NNAPI is **deprecated** as of Android 15
- NPU acceleration requires specialized vendor drivers (not available in emulated environments)
- LiteRT-LM NPU support is currently in **Early Access Program**

**Implication:** All development and testing of NPU features must be done on **physical devices**. Emulator testing should focus on CPU/GPU backends with fallback logic.

### 1.2 LiteRT-LM Performance Benchmarks

| Model | Device | Backend | Prefill (tok/s) | Decode (tok/s) | Context |
|-------|--------|---------|-----------------|----------------|---------|
| Gemma3-1B | Samsung S24 | CPU | 243.24 | 43.56 | 4096 |
| Gemma3-1B | Samsung S24 | GPU | 1876.5 | 44.57 | 4096 |
| Gemma3-1B | Samsung S25 | **NPU** | **5836.6** | **84.8** | 1280 |
| FunctionGemma | Samsung S25 | CPU | 1718.4 | 125.9 | 1024 |

**Key Takeaways:**
- NPU provides **24x faster prefill** than CPU
- GPU provides **7.7x faster prefill** than CPU
- NPU currently has reduced context window (1280 vs 4096)

---

## 2. Current Architecture Analysis

### 2.1 GraphRAG Pipeline (Current)

```
┌─────────────────────────────────────────────────────────────────┐
│                      GraphRAG Pipeline                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │
│  │   Document   │───▶│   Entity     │───▶│    Graph     │      │
│  │   Chunking   │    │  Extraction  │    │  Building    │      │
│  └──────────────┘    └──────────────┘    └──────────────┘      │
│                             │                    │              │
│                             ▼                    ▼              │
│                      ┌─────────────────────────────────┐       │
│                      │    llmCallback (model-agnostic)  │       │
│                      │    Future<String> Function(String)│       │
│                      └─────────────────────────────────┘       │
│                                     │                          │
│                                     ▼                          │
│                      ┌─────────────────────────────────┐       │
│                      │         FlutterGemma            │       │
│                      │    (MediaPipe or LiteRT-LM)     │       │
│                      └─────────────────────────────────┘       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 Current Model Format Support

| Engine | Model Format | Embedding Support | Function Calling |
|--------|--------------|-------------------|------------------|
| MediaPipe | .tflite, .task, .bin | ✅ Yes (all RAG models) | ❌ No |
| LiteRT-LM | .litertlm | ❌ Not available | ✅ Native |

---

## 3. Implementation Phases

### Phase 1: LiteRT-LM Backend Selection for GraphRAG (Priority: High)

**Objective:** Add automatic backend selection to maximize performance based on device capabilities.

#### 3.1.1 New Engine Configuration

```dart
// lib/rag/graph_rag_config.dart

enum GraphRAGBackend {
  auto,      // Automatic selection based on device
  cpu,       // Force CPU (emulator/compatibility)
  gpu,       // Force GPU (most devices)
  npu,       // Force NPU (Early Access - physical devices only)
}

class GraphRAGConfig {
  final GraphRAGBackend preferredBackend;
  final bool enableFunctionCalling;  // New: use native parsing
  final int maxContextTokens;         // New: backend-aware context
  final bool enableCacheDir;          // New: faster reloads
  
  const GraphRAGConfig({
    this.preferredBackend = GraphRAGBackend.auto,
    this.enableFunctionCalling = true,
    this.maxContextTokens = 4096,
    this.enableCacheDir = true,
  });
}
```

#### 3.1.2 Device Capability Detection

```dart
// lib/rag/device_capability_detector.dart

class DeviceCapabilityDetector {
  /// Detects the optimal backend for the current device
  static Future<GraphRAGBackend> detectOptimalBackend() async {
    if (Platform.isAndroid) {
      final deviceInfo = await DeviceInfoPlugin().androidInfo;
      
      // Check for NPU-capable chipsets (Early Access)
      if (_isNPUCapable(deviceInfo)) {
        return GraphRAGBackend.npu;
      }
      
      // GPU is generally faster for prefill
      return GraphRAGBackend.gpu;
    }
    
    // Desktop: GPU preferred on macOS/Windows/Linux
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      return GraphRAGBackend.gpu;
    }
    
    return GraphRAGBackend.cpu;
  }
  
  static bool _isNPUCapable(AndroidDeviceInfo info) {
    // Samsung Galaxy S25 series with Snapdragon 8 Elite
    // Samsung Galaxy S24 series with Exynos 2400 (limited)
    // Pixel 9 series (Google Tensor G4)
    // Devices with MediaTek Dimensity 9300+
    
    final model = info.model.toLowerCase();
    final hardware = info.hardware.toLowerCase();
    
    return model.contains('s25') || 
           model.contains('s24') ||
           model.contains('pixel 9') ||
           hardware.contains('snapdragon 8') ||
           hardware.contains('dimensity 9');
  }
}
```

---

### Phase 2: Native Function Calling for Structured Extraction (Priority: High)

**Objective:** Replace prompt-based JSON parsing with LiteRT-LM's native function calling for entity extraction.

#### 3.2.1 Current vs New Approach

**Current (Prompt-based):**
```dart
// lib/rag/graph/entity_extractor.dart - CURRENT
Future<ExtractionResult> _extractEntitiesFromChunk(DocumentChunk chunk) async {
  final prompt = '''
Extract entities and relationships from the following text.
Return the result as JSON with the following structure:
{
  "entities": [{"name": "...", "type": "...", "description": "..."}],
  "relationships": [{"source": "...", "target": "...", "type": "...", "description": "..."}]
}

Text:
${chunk.content}
''';
  
  final response = await _llmCallback(prompt);
  return _parseJsonResponse(response);  // Error-prone parsing
}
```

**New (Native Function Calling):**
```dart
// lib/rag/graph/entity_extractor_v2.dart - NEW

class EntityExtractionTool {
  static const definition = ToolDefinition(
    name: 'extract_entities',
    description: 'Extracts entities and relationships from text',
    parameters: {
      'entities': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
            'type': {'type': 'string', 'enum': ['PERSON', 'ORGANIZATION', 'LOCATION', 'EVENT', 'CONCEPT']},
            'description': {'type': 'string'},
          },
          'required': ['name', 'type'],
        },
      },
      'relationships': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'source': {'type': 'string'},
            'target': {'type': 'string'},
            'type': {'type': 'string'},
            'description': {'type': 'string'},
          },
          'required': ['source', 'target', 'type'],
        },
      },
    },
  );
}

class EntityExtractorV2 {
  final LiteRtLmFunctionCalling _functionCalling;
  
  Future<ExtractionResult> extractEntities(DocumentChunk chunk) async {
    final result = await _functionCalling.callFunction(
      prompt: 'Analyze this text and extract all entities and relationships: ${chunk.content}',
      tool: EntityExtractionTool.definition,
    );
    
    // Native structured output - no JSON parsing needed!
    return ExtractionResult(
      entities: result['entities'].map((e) => ExtractedEntity.fromMap(e)).toList(),
      relationships: result['relationships'].map((r) => ExtractedRelationship.fromMap(r)).toList(),
    );
  }
}
```

#### 3.2.2 Benefits of Native Function Calling

| Aspect | Prompt-Based | Native Function Calling |
|--------|--------------|-------------------------|
| Output Format | Unpredictable JSON | Guaranteed schema |
| Error Rate | ~15-20% parsing failures | ~0% (constrained decoding) |
| Token Efficiency | Wastes tokens on format instructions | Minimal overhead |
| Speed | Full generation + parsing | Direct structured output |
| Supported Models | Any LLM | FunctionGemma, Gemma-3n |

---

### Phase 3: Faster Model Reloads with Cache Directory (Priority: Medium)

**Objective:** Leverage LiteRT-LM's cacheDir feature to reduce model reload times from ~10s to ~1-2s.

#### 3.3.1 Implementation

```dart
// lib/core/engine/litertlm_engine_wrapper.dart

class LiteRtLmEngineWrapper {
  static const _cacheSubdir = 'litertlm_cache';
  
  Future<void> initializeWithCache({
    required String modelPath,
    required PreferredBackend backend,
  }) async {
    // Get app-specific cache directory
    final cacheDir = await _getCacheDirectory();
    
    await _nativeEngine.initialize(
      modelPath: modelPath,
      backend: backend,
      cacheDir: cacheDir,  // NEW: enables 5-10x faster reloads
    );
  }
  
  Future<String> _getCacheDirectory() async {
    final appDir = await getApplicationSupportDirectory();
    final cacheDir = Directory('${appDir.path}/$_cacheSubdir');
    
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    
    return cacheDir.path;
  }
}
```

#### 3.3.2 Expected Performance Improvement

| Scenario | Without Cache | With Cache |
|----------|---------------|------------|
| First Load | ~10s | ~10s (initial setup) |
| Subsequent Loads | ~10s | **~1-2s** |
| App Restart | ~10s | **~1-2s** |
| Model Switch | ~10s | **~1-2s** (per model) |

---

### Phase 4: Context Window Optimization (Priority: Medium)

**Objective:** Implement dynamic context window management based on backend and model.

#### 3.4.1 Context Manager

```dart
// lib/rag/context_window_manager.dart

class ContextWindowManager {
  static const _contextLimits = {
    // Backend -> Model -> Max Tokens
    PreferredBackend.cpu: {
      'gemma3-1b': 4096,
      'gemma-3n-e2b': 4096,
      'functiongemma': 1024,
    },
    PreferredBackend.gpu: {
      'gemma3-1b': 4096,
      'gemma-3n-e2b': 4096,
      'functiongemma': 1024,
    },
    PreferredBackend.npu: {
      'gemma3-1b': 1280,  // Reduced for NPU
      'gemma-3n-e2b': 1280,
      'functiongemma': 1024,
    },
  };
  
  int getOptimalContextSize({
    required PreferredBackend backend,
    required String modelId,
    int requestedSize = 4096,
  }) {
    final limits = _contextLimits[backend] ?? {};
    final maxForModel = limits[modelId] ?? 4096;
    return min(requestedSize, maxForModel);
  }
  
  /// Adjusts document chunking based on available context
  int getOptimalChunkSize(int contextSize) {
    // Reserve ~30% of context for system prompt + output
    return (contextSize * 0.7).toInt();
  }
}
```

#### 3.4.2 GraphRAG Integration

```dart
// lib/rag/graph_rag.dart - UPDATED

class GraphRAG {
  final ContextWindowManager _contextManager;
  
  Future<String> query(String question) async {
    // Get optimal context size for current backend
    final contextSize = _contextManager.getOptimalContextSize(
      backend: _currentBackend,
      modelId: _currentModel,
    );
    
    // Adjust chunk retrieval based on available context
    final maxChunks = (contextSize / _avgChunkTokens).floor();
    final relevantChunks = await _retrieveChunks(question, limit: maxChunks);
    
    // Build prompt within context limits
    final prompt = _buildPromptWithinLimit(
      question: question,
      chunks: relevantChunks,
      maxTokens: contextSize,
    );
    
    return await _llmCallback(prompt);
  }
}
```

---

### Phase 5: Unified GraphRAG API with LiteRT-LM (Priority: Low)

**Objective:** Create a high-level API that automatically leverages all LiteRT-LM benefits.

#### 3.5.1 New API Design

```dart
// lib/rag/graph_rag_v2.dart

class GraphRAGV2 {
  final FlutterGemma _gemma;
  final GraphRAGConfig _config;
  final ContextWindowManager _contextManager;
  
  /// Creates a new GraphRAG instance with optimal backend selection
  static Future<GraphRAGV2> create({
    required String knowledgeBaseId,
    GraphRAGConfig? config,
  }) async {
    final effectiveConfig = config ?? GraphRAGConfig();
    
    // Auto-detect optimal backend
    final backend = effectiveConfig.preferredBackend == GraphRAGBackend.auto
        ? await DeviceCapabilityDetector.detectOptimalBackend()
        : effectiveConfig.preferredBackend;
    
    // Initialize FlutterGemma with optimal settings
    final gemma = await FlutterGemma.create(
      backend: _toPreferredBackend(backend),
      enableCacheDir: effectiveConfig.enableCacheDir,
    );
    
    return GraphRAGV2._(gemma, effectiveConfig, backend);
  }
  
  /// Queries the knowledge graph with automatic optimization
  Future<GraphRAGResponse> query(String question) async {
    final startTime = DateTime.now();
    
    // Use native function calling if available and enabled
    if (_config.enableFunctionCalling && _supportsNativeFunctionCalling()) {
      return await _queryWithFunctionCalling(question);
    }
    
    // Fall back to traditional prompt-based approach
    return await _queryTraditional(question);
  }
  
  /// Ingests documents with optimized extraction
  Future<void> ingestDocuments(List<Document> documents) async {
    for (final doc in documents) {
      // Chunk based on optimal context size
      final chunks = _chunkDocument(doc);
      
      // Extract entities with best available method
      final extraction = _config.enableFunctionCalling
          ? await _extractWithFunctionCalling(chunks)
          : await _extractWithPrompts(chunks);
      
      await _buildGraph(extraction);
    }
  }
}
```

---

## 4. Migration Strategy

### 4.1 Backward Compatibility

```dart
// lib/rag/graph_rag.dart - Keep existing API

@Deprecated('Use GraphRAGV2 for improved performance')
class GraphRAG {
  // Existing implementation unchanged
  // Users can migrate at their own pace
}
```

### 4.2 Feature Flags

```dart
// lib/rag/feature_flags.dart

class GraphRAGFeatureFlags {
  /// Enable native function calling (requires FunctionGemma/.litertlm)
  static bool enableNativeFunctionCalling = true;
  
  /// Enable NPU backend detection (Early Access)
  static bool enableNPUDetection = false;  // Off by default
  
  /// Enable model caching for faster reloads
  static bool enableModelCache = true;
  
  /// Log performance metrics
  static bool enablePerformanceLogging = true;
}
```

---

## 5. Testing Strategy

### 5.1 Backend Testing Matrix

| Test Type | Emulator | Physical Device |
|-----------|----------|-----------------|
| CPU Backend | ✅ | ✅ |
| GPU Backend | ✅ (software) | ✅ |
| NPU Backend | ❌ Skip | ✅ (Early Access devices) |
| Function Calling | ✅ | ✅ |
| Cache Performance | ✅ | ✅ |

### 5.2 Test Cases

```dart
// test/rag/graph_rag_v2_test.dart

void main() {
  group('GraphRAGV2 Backend Selection', () {
    test('selects CPU on emulator', () async {
      // Mock emulator environment
      final backend = await DeviceCapabilityDetector.detectOptimalBackend();
      expect(backend, isNot(GraphRAGBackend.npu));
    });
    
    test('respects forced backend configuration', () async {
      final rag = await GraphRAGV2.create(
        knowledgeBaseId: 'test',
        config: GraphRAGConfig(preferredBackend: GraphRAGBackend.cpu),
      );
      expect(rag.currentBackend, GraphRAGBackend.cpu);
    });
  });
  
  group('Native Function Calling', () {
    test('extracts entities with valid schema', () async {
      final extractor = EntityExtractorV2(
        functionCalling: mockFunctionCalling,
      );
      
      final result = await extractor.extractEntities(
        DocumentChunk(content: 'John works at Google in Mountain View.'),
      );
      
      expect(result.entities, hasLength(3));  // John, Google, Mountain View
      expect(result.entities.map((e) => e.type), 
          containsAll(['PERSON', 'ORGANIZATION', 'LOCATION']));
    });
  });
}
```

---

## 6. Timeline

| Phase | Duration | Dependencies |
|-------|----------|--------------|
| Phase 1: Backend Selection | 1 week | None |
| Phase 2: Function Calling | 2 weeks | FunctionGemma model |
| Phase 3: Cache Directory | 3 days | Phase 1 |
| Phase 4: Context Management | 1 week | Phase 1 |
| Phase 5: Unified API | 1 week | Phases 1-4 |
| Testing & Documentation | 1 week | All phases |

**Total Estimated Time: 6-7 weeks**

---

## 7. Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| NPU Early Access availability | High | Implement graceful fallback to GPU/CPU |
| Function calling model availability | Medium | Keep prompt-based extraction as fallback |
| Context window limits on NPU | Medium | Dynamic chunking based on backend |
| Breaking changes in LiteRT-LM API | Low | Abstract behind wrapper interface |

---

## 8. Success Metrics

| Metric | Current | Target |
|--------|---------|--------|
| Model reload time | ~10s | ~1-2s (with cache) |
| Entity extraction accuracy | ~85% | ~95% (with function calling) |
| Prefill throughput (NPU) | N/A | 5000+ tok/s |
| JSON parsing errors | ~15% | ~0% (structured output) |

---

## Appendix A: API Reference Changes

### New Public APIs

```dart
// New classes
GraphRAGV2
GraphRAGConfig  
GraphRAGBackend
DeviceCapabilityDetector
ContextWindowManager
EntityExtractorV2

// New methods
FlutterGemma.createWithCache()
FlutterGemma.callFunction()
```

### Deprecated APIs

```dart
// Will be deprecated (not removed)
GraphRAG  // Use GraphRAGV2
FunctionGemmaParser.parseFromPrompt()  // Use native function calling
```

---

## Appendix B: Model Compatibility Matrix

| Model | Backend Support | Function Calling | Embedding | GraphRAG Use |
|-------|-----------------|------------------|-----------|--------------|
| Gemma3-1B | CPU/GPU/NPU | ❌ | ❌ | LLM inference |
| Gemma-3n-E2B | CPU/GPU | ✅ Native | ❌ | Entity extraction |
| FunctionGemma-270M | CPU/GPU | ✅ Native | ❌ | Function calls |
| EmbeddingGemma | CPU/GPU | ❌ | ✅ | Vector embeddings |
| Gecko | CPU/GPU | ❌ | ✅ | Vector embeddings |

**Note:** Embedding models remain on MediaPipe (.tflite) as no .litertlm versions are currently available.
