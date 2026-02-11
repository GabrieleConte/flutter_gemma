# GraphRAG Module — Technical Reference

> **Graph-based Retrieval-Augmented Generation for on-device personal knowledge graphs**

This module implements a complete **GraphRAG** pipeline — from raw personal data ingestion to LLM-powered question answering — running entirely on-device via LiteRT-LM. It follows and extends the methodology described in *"From Local to Global: A GraphRAG Approach to Query-Focused Summarization"* (Edge et al., 2024), adapting it to the constraints of mobile/on-device inference (limited context windows, single-session LLMs, constrained memory).

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Knowledge Graph Schema](#knowledge-graph-schema)
3. [Indexing Pipeline](#indexing-pipeline)
   - [Phase 0 — Central Node Initialization](#phase-0--central-node-initialization)
   - [Phase 1 — Data Ingestion & Entity Extraction](#phase-1--data-ingestion--entity-extraction)
   - [Phase 1.5 — Template & Co-mention Link Prediction](#phase-15--template--co-mention-link-prediction)
   - [Phase 1.6 — Embedding Similarity Link Prediction](#phase-16--embedding-similarity-link-prediction)
   - [Phase 2 — Community Detection (Leiden Algorithm)](#phase-2--community-detection-leiden-algorithm)
   - [Phase 3 — Community Summarization](#phase-3--community-summarization)
4. [Query Engines](#query-engines)
   - [Local Query Engine (Embedding + N-hop Traversal)](#local-query-engine)
   - [Global Query Engine (Map-Reduce over Communities)](#global-query-engine)
5. [Entity Extraction in Detail](#entity-extraction-in-detail)
6. [Link Prediction in Detail](#link-prediction-in-detail)
7. [Token Budget Management](#token-budget-management)
8. [Backend Selection & Fallback](#backend-selection--fallback)
9. [Model Cache Management](#model-cache-management)
10. [Module Structure](#module-structure)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        GraphRAG Facade                          │
│  (graph_rag.dart — unified API for all operations)              │
└──────────────┬────────────────────────┬─────────────────────────┘
               │                        │
   ┌───────────▼───────────┐  ┌────────▼─────────────────────┐
   │  BackgroundIndexing   │  │     Query Engines             │
   │  Service              │  │  ┌─────────────────────────┐  │
   │                       │  │  │ Local (GraphRAGQuery)    │  │
   │  • Data Connectors    │  │  │ Embedding + N-hop        │  │
   │  • Entity Extraction  │  │  └─────────────────────────┘  │
   │  • Link Prediction    │  │  ┌─────────────────────────┐  │
   │  • Community Detection│  │  │ Global (Map-Reduce)      │  │
   │  • Summarization      │  │  │ Community summaries      │  │
   └───────────┬───────────┘  │  └─────────────────────────┘  │
               │              └────────────────────────────────┘
   ┌───────────▼───────────┐
   │   NativeGraphRepository │
   │   (SQLite via Pigeon)   │
   │   + Embedding storage   │
   └─────────────────────────┘
```

The system is organized around a star-shaped personal knowledge graph centered on a "**You**" node. Data flows from system APIs (Contacts, Calendar, Photos, Call Log, Documents) and user input (Notes, Alarms) through an extraction pipeline into the graph, where community detection groups related entities, and query engines retrieve relevant context for LLM-powered answers.

---

## Knowledge Graph Schema

### Entity Types

| Type | Description | Source |
|------|-------------|--------|
| `SELF` | Central "You" node | Auto-created |
| `HUB` | Data family grouping nodes (e.g., "My Contacts") | Auto-created per data source |
| `PERSON` | People from contacts, calendar attendees, call log | Contacts, Calendar, Call Log |
| `ORGANIZATION` | Companies, institutions | Contacts (organization field) |
| `LOCATION` | Places, addresses, venues | Calendar (location), Photos (GPS) |
| `EVENT` | Calendar events, meetings | Calendar |
| `PHOTO` | Photographs | Photos library |
| `PHONE_CALL` | Call log entries | Call Log |
| `DOCUMENT` | Files and documents | Document picker / Drive |
| `DOCUMENT_CHUNK` | Chunks of long documents | Document chunking pipeline |
| `NOTE` | User-created notes | User input |
| `NOTE_CHUNK` | Chunks of long notes | Note chunking pipeline |
| `ALARM` | User-created alarms | User input |
| `DATE` | Temporal nodes for transitive connections | Extracted from events/calls |
| `TOPIC` | Semantic topics | LLM extraction |
| `PROJECT` | Projects, work items | LLM extraction |
| `EMAIL` | Email addresses | Contacts |
| `PHONE` | Phone numbers | Contacts |

### Graph Topology: Hub Routing

Rather than connecting every entity directly to "You" (which would create a noisy star graph), the system uses a **two-hop hub routing** architecture:

```
You ──HAS_DATA──▶ Hub:My Contacts ──KNOWS──▶ Person:Alice
You ──HAS_DATA──▶ Hub:My Calendar ──HAS_EVENT──▶ Event:Meeting
You ──HAS_DATA──▶ Hub:My Photos ──HAS_PHOTO──▶ Photo:sunset.jpg
```

Hub nodes are typed `HUB` and are **excluded from query retrieval** to avoid noisy, highly-connected nodes polluting results. They serve purely as structural connectors for graph traversal and community detection.

### Relationship Types

The module defines a comprehensive set of relationship types:

- **Ownership/Membership**: `WORKS_AT`, `WORKS_FOR`, `PART_OF`, `OWNS`
- **Social**: `KNOWS`, `COLLEAGUE_OF`, `CONTACT_OF`, `FAMILY_MEMBER`, `FRIEND`
- **Attendance**: `ATTENDED_BY`, `ATTENDS`
- **Spatial**: `LOCATED_IN`, `TAKEN_AT`
- **Temporal**: `OCCURS_ON`, `OCCURRED_ON`, `SET_FOR`, `SCHEDULED_FOR`, `CREATED_ON`, `MODIFIED_ON`
- **Communication**: `CALLED`, `RECEIVED_CALL_FROM`
- **Content**: `MENTIONED_IN`, `PICTURED_IN`, `CREATED_BY`
- **Predicted**: `RELATED_TO` (embedding similarity), `SIMILAR_TO`
- **Hub routing**: `HAS_DATA`, `HAS_EVENT`, `HAS_PHOTO`, `MADE_CALL`, `WROTE_NOTE`, `SET_ALARM`, `OWNS_DOCUMENT`

---

## Indexing Pipeline

The `BackgroundIndexingService` orchestrates the full indexing pipeline through six sequential phases. It runs as an Android foreground service to survive app backgrounding, and emits real-time `IndexingProgress` events on a broadcast stream.

### Phase 0 — Central Node Initialization

Creates the `You` (type `SELF`) central node if it doesn't exist. This node acts as the anchor for all personal data in the graph and receives an embedding vector generated from a descriptive text prompt.

### Phase 1 — Data Ingestion & Entity Extraction

Data flows from registered `DataConnector` instances through the `ConnectorManager`:

| Connector | Data Type | Permission |
|-----------|-----------|------------|
| `ContactsConnector` | Contacts | `contacts` |
| `CalendarConnector` | Calendar Events | `calendar` |
| `PhotosConnector` | Photos | `photos` |
| `CallLogConnector` | Phone Calls | `callLog` |
| `DocumentsConnector` | Files | `files` |
| `GoogleSuiteConnector` | GMail, Drive, GCal, GContacts | OAuth2 |

**Incremental sync**: Each connector tracks its last sync timestamp via `SharedPreferences`. Subsequent runs only fetch items modified after the last sync. If the graph is empty (≤1 entity), a full fetch is forced regardless.

**Extraction strategy**: The system uses two extraction paths:

1. **Direct extraction** (fast, deterministic, no LLM) — for structured data types:
   - Contacts → `PERSON` + `ORGANIZATION` entities with structured metadata
   - Calendar Events → `EVENT` + attendee `PERSON` + `LOCATION` entities
   - Photos → `PHOTO` entity with location/date metadata
   - Phone Calls → `PHONE_CALL` + contact `PERSON` entities
   - Alarms → `ALARM` entity with recurrence metadata
   - Documents → `DOCUMENT` entity with file metadata

2. **LLM extraction** (slower, semantic) — for free-text data:
   - Notes, unstructured documents
   - Falls back to prompt-based JSON extraction

3. **Native function calling** (when available):
   - Uses LiteRT-LM's structured output via `ToolDefinition` schema
   - `AdaptiveEntityExtractor` tries function calling first, falls back to JSON parsing

**Vision-enhanced extraction**: When `enableImageCaptioning` is true and a vision LLM is available, photos are processed through a vision model to generate descriptive captions before entity extraction, yielding richer semantic content (people, objects, scenes, activities).

**Entity deduplication**: Entity IDs are deterministically generated from `name + type` using a normalized hash. Conflicts are resolved with timestamp-wins: newer entities overwrite older ones.

**Batched processing**: Items are processed in configurable batches (default: 10) with inter-batch delays (default: 100ms) to avoid blocking the UI thread. The pipeline supports pause/resume/cancel semantics.

### Phase 1.5 — Template & Co-mention Link Prediction

After all entities are extracted, the `LinkPredictor` creates relationships through three mechanisms:

#### Template-Based Inference (deterministic)
Applies structural rules based on data type:
- Contact with organization → `WORKS_AT` relationship
- Calendar event with location → `LOCATED_IN`
- Calendar event attendees → `ATTENDED_BY`
- Phone call with contact → `CALLED` / `RECEIVED_CALL_FROM`
- Events with dates → `OCCURS_ON` (enables transitive temporal queries)

#### Co-mention Detection
Scans all extraction results for entities that co-occur across multiple data sources:
- If entity A and entity B are extracted from ≥ `minCoOccurrenceCount` (default: 2) different source items, a `MENTIONED_WITH` relationship is created with configurable weight.

#### Colleague Inference
Queries the graph for people sharing the same organization and creates `COLLEAGUE_OF` relationships between them.

### Phase 1.6 — Embedding Similarity Link Prediction

The `EmbeddingSimilarityLinkPredictor` discovers implicit relationships through a multi-step pipeline:

1. **Candidate discovery**: Retrieve all entities with embeddings and compute pairwise cosine similarity. Pairs exceeding the threshold (default: 0.75 for cross-type, 0.65 for same-type) become candidates.

2. **LLM validation chain** (3 steps per candidate pair):
   - **Step 1 — Categorization**: The LLM classifies the relationship type (e.g., `RELATED_TO`, `WORKS_WITH`, `KNOWS`).
   - **Step 2 — Plausibility validation**: The LLM answers YES/NO on whether the relationship is plausible.
   - **Step 3 — Confidence scoring**: The LLM assigns a confidence score (0.0-1.0).

3. **Relationship creation**: Validated pairs with sufficient confidence are stored as `RELATED_TO` relationships.

When structured LLM callbacks are available, Step 1 uses a `validate_relationship` tool definition for structured output.

### Phase 2 — Community Detection (Leiden Algorithm)

The module implements the **Leiden algorithm** for community detection, an improvement over Louvain that guarantees well-connected communities.

> Reference: Traag, V.A., Waltman, L. & van Eck, N.J. *From Louvain to Leiden: guaranteeing well-connected communities.* Scientific Reports 9, 5233 (2019).

#### Algorithm Phases

The Leiden algorithm runs hierarchically over the graph (excluding `DATE` and `HUB` entity types):

**Phase 1 — Local Moving (shared with Louvain)**:
Each node is considered for movement to a neighboring community. The modularity gain $\Delta Q$ of moving node $i$ from community $C_1$ to community $C_2$ is computed as:

$$\Delta Q = \frac{k_{i,C_2}}{m} - \gamma \cdot \frac{\Sigma_{C_2} \cdot k_i}{m^2}$$

where:
- $k_{i,C_2}$ = sum of edge weights from node $i$ to community $C_2$
- $\Sigma_{C_2}$ = sum of degrees of nodes in $C_2$
- $k_i$ = degree of node $i$
- $m$ = total edge weight in the graph
- $\gamma$ = resolution parameter (default: 1.0; higher = smaller communities)

Nodes are processed in random order. A node moves to the community with the largest positive $\Delta Q$ exceeding `minImprovement` (default: 0.001). Iteration continues until no node improves.

**Phase 2 — Refinement (Leiden-specific)**:
This phase ensures communities are *well-connected*, which is the key improvement over Louvain:

1. For each community, check if it forms a single connected component (via BFS).
2. If a community is disconnected, its smaller components are merged into the most strongly connected neighboring community.
3. For well-connected communities, local refinement tries moving each node to a random neighboring community, accepting moves that improve modularity weighted by the gamma parameter:
   $$\Delta Q_{refined} = \Delta Q \cdot \gamma_{refinement}$$

**Phase 3 — Aggregation**:
Communities become super-nodes in a new aggregated graph. Edge weights between super-nodes are the sums of original inter-community edge weights. This aggregated graph is fed back to Phase 1 recursively.

**Hierarchy**: The algorithm recurses up to `maxDepth` levels (default: 2), producing a hierarchical community structure:
- Level 0: Finest granularity (many small communities)
- Level 1: Intermediate (communities of communities)
- Level 2+: Coarsest (root-level thematic groups)

Parent-child relationships are tracked between levels.

#### Configuration

```dart
CommunityDetectionConfig(
  resolution: 1.0,      // Higher → smaller communities
  gamma: 1.0,           // Refinement phase granularity
  minImprovement: 0.001, // Convergence threshold
  maxIterations: 100,    // Per-phase iteration cap
  maxDepth: 2,           // Hierarchy depth
  minCommunitySize: 2,   // Prune singleton communities
  randomSeed: null,      // For reproducibility
)
```

### Phase 3 — Community Summarization

The `CommunitySummarizer` generates natural-language summaries for each detected community using the LLM. It operates in two modes:

**Leaf communities** (no children): The summarizer builds a prompt listing:
- Entity names and truncated descriptions (max 100 chars each, max 15 entities)
- Relationships between entities (max 20 relationships)
- Asks the LLM to produce a factual 1-2 paragraph summary grounded only in the provided information

**Parent communities** (have children): Uses a hierarchical prompt that combines child community summaries, asking the LLM to produce a unified thematic summary.

Each summary is stored with an embedding vector for similarity search during global queries.

**Model lifecycle optimization**: The pipeline supports `onExtractionPhaseComplete` and `onBeforeSummarization` callbacks, enabling the application to deallocate the extraction model after Phase 1.6 completes (freeing GPU/NPU memory) and re-allocate the main LLM before summarization begins.

---

## Query Engines

### Local Query Engine

The `GraphRAGQueryEngine` implements a **4-step retrieval pipeline** optimized for specific, focused questions:

#### Step 1 — Embedding Similarity Search

The query text is embedded, then compared against all entity embeddings using cosine similarity:

$$\text{similarity}(q, e) = \frac{q \cdot e}{\|q\| \cdot \|e\|}$$

The top-K entities (default: 4) exceeding the similarity threshold (default: 0.5) become **seed entities**. Hub-type entities are filtered out. Simultaneously, the top-1 most similar community is retrieved.

#### Step 2 — N-hop Graph Traversal

From each seed entity, the engine traverses outgoing relationships up to `maxHops` depth (default: 1). Neighbor entities are collected, their embeddings batch-fetched, and similarity to the query computed. Hub entities are excluded from traversal results.

#### Step 3 — Relationship Fetching

All relationships connecting the retrieved entity set are fetched. Filtering removes:
- Hub-originating relationships (`HAS_EVENT`, `HAS_DATA`, etc.)
- Auto-generated `RELATED_TO` links (embedding similarity predictions that could add noise)
- Relationships where either endpoint is outside the retrieved set

#### Step 4 — Token-Budget-Aware Context Construction

The engine constructs a formatted context string within a strict token budget (default: `maxContextTokens × 0.9`). Token estimation uses the ~4 characters/token heuristic.

**Entity formatting**: Each entity type has a specialized formatter:
- `PERSON`: Name, job title, email, phone
- `EVENT`: Title, date range, recurrence pattern, description
- `PHOTO`: Filename, creation date
- `PHONE_CALL`: Direction, contact, timestamp, duration
- `ALARM`: Label, time, recurrence
- `NOTE`/`NOTE_CHUNK`: Title, creation date, content preview
- `DOCUMENT`/`DOCUMENT_CHUNK`: Name, type, content preview

Each entity's outgoing relationships are rendered inline:
```
Alice (Person) — Software Engineer
  → works at → Google (Organization)
  → attended by → Team Meeting (Calendar Event)
```

**Priority-based trimming**: When the budget is exceeded, entities are discarded in order:
1. Hop entities with the lowest similarity scores
2. Seed entities with the lowest similarity scores
3. Hard-cap truncation of the remaining context string

**Community context**: Community summaries are included only when entity tokens consume less than `communityDropThreshold` (default: 70%) of the total budget, preventing community text from crowding out entity-level detail.

**Context-excluded types**: `DATE` entities are excluded from the LLM context (their temporal information is already conveyed through relationship labels like "→ occurs on → March 15, 2025"), but they are kept in the graph for transitive traversal.

#### Answer Generation

When an `llmCallback` is provided, the engine generates a grounded answer using a carefully crafted system prompt:

```
You are a helpful personal assistant. The user's personal knowledge graph
has been searched and the most relevant information is provided below.
[...]
- Answer based ONLY on the context provided. Do not use external knowledge.
- Be specific: use names, dates, and details from the entities.
[...]
```

The query engine supports both synchronous (`queryWithAnswer`) and streaming (`queryWithAnswerStreaming`) answer generation.

### Global Query Engine

The `GlobalQueryEngine` implements the **map-reduce approach** from the GraphRAG paper for broad "sensemaking" queries. This is the recommended engine for questions like "What are the main themes in my contacts?" or "How are my events connected?"

#### Selection Phase (extension over the original paper)

Instead of processing all communities at a given level (which would be expensive with limited context windows), the engine first selects the **top-3 most relevant communities** using embedding similarity between the query and community summaries:

1. Embed the query and all community summaries
2. Compute cosine similarity for each community
3. Select top-3 by similarity score

This optimization dramatically reduces the number of LLM calls in the map phase.

#### Map Phase

For each selected community, a targeted prompt is sent to the LLM:

```
Answer ONLY using this summary. Do NOT add external information.
Summary: [community summary, truncated to 1500 chars]
Question: [user query]
Answer in 1-2 sentences using ONLY the summary. If insufficient, say "Not enough information.":
```

Each answer receives a base helpfulness score of 90 (since communities were pre-selected by relevance).

#### Reduce Phase

1. Filter community answers by minimum helpfulness score (default: 20)
2. Sort by helpfulness descending
3. Select answers fitting within the context token limit (default: 4000 tokens)
4. Synthesize a final answer with a grounded prompt:

```
Combine these contexts to answer. Use ONLY information provided.
Context 1: [answer 1, truncated to 400 chars]
Context 2: [answer 2]
[...]
Question: [user query]
Rules:
- Use ONLY the contexts above
- 2-3 sentences maximum
- If contexts don't answer, say so
```

#### Automatic Level Selection

The `queryWithAutoLevel` method uses query heuristics to select the optimal community level:

| Query Type | Indicators | Selected Level |
|------------|-----------|----------------|
| Broad/overview | "main themes", "overall", "summary" | Level 0 (root) |
| Thematic | "how do", "relationship between", "connection" | Middle level |
| Specific | "who is", "what is", "details about" | Highest available level |
| Default | — | Level 1 |

#### Streaming Mode

The `StreamingGlobalQueryEngine` wraps the global engine with `GlobalQueryProgress` events, reporting:
- Starting/community count discovery
- Per-community map phase progress
- Filtering results
- Streaming tokens during reduce phase
- Final timing metadata

---

## Entity Extraction in Detail

### Extraction Architecture

The module provides a three-tier extraction hierarchy:

```
EntityExtractor (abstract interface)
├── LLMEntityExtractor         — prompt-based JSON extraction
├── NativeFunctionExtractor    — LiteRT-LM function calling
├── AdaptiveEntityExtractor    — tries native, falls back to prompt
└── DirectEntityExtractor      — deterministic, no LLM (structured data)
    └── VisionEntityExtractor  — vision LLM + direct extraction (photos)
```

### DirectEntityExtractor (Structured Data)

Converts structured data (contacts, events, calls, photos, alarms) directly into entities and relationships without LLM calls. This is the fast path for the majority of personal data:

- **Contact** → 1 `PERSON` entity + optional `ORGANIZATION` entity + `WORKS_AT` relationship
- **Calendar Event** → 1 `EVENT` entity + `PERSON` entities for attendees + optional `LOCATION`
- **Photo** → 1 `PHOTO` entity with GPS location and creation date metadata
- **Phone Call** → 1 `PHONE_CALL` entity + 1 `PERSON` entity + directional call relationship
- **Alarm** → 1 `ALARM` entity with recurrence metadata (single/recurring, frequency, days)
- **Note** → Chunked into `NOTE` + `NOTE_CHUNK` entities with `NEXT_CHUNK` relationships

### NativeFunctionExtractor

Leverages LiteRT-LM's native function calling for structured output. Defines an `extract_entities_and_relationships` tool with JSON Schema:

```json
{
  "entities": [{"name": "...", "type": "PERSON|ORG|...", "description": "..."}],
  "relationships": [{"source": "...", "target": "...", "type": "WORKS_AT|..."}]
}
```

Falls back to JSON parsing if the model doesn't produce a valid function call response.

### AdaptiveEntityExtractor

The default extractor when function calling is enabled:
1. Tries `NativeFunctionExtractor` first
2. If it fails or returns zero entities, retries with `LLMEntityExtractor` (JSON prompt)
3. Merges results and deduplicates entities by normalized name

---

## Link Prediction in Detail

### Hub Architecture

The personal knowledge graph uses a **You → Hub → Entity** routing pattern:

```
You ──HAS_DATA──▶ Hub:My Contacts ──KNOWS──▶ Person:Alice
                                   ──KNOWS──▶ Person:Bob
You ──HAS_DATA──▶ Hub:My Calendar ──HAS_EVENT──▶ Event:Standup
```

Hubs are created lazily per data source type. Each hub gets an embedding from its display name (e.g., "My Contacts"). Hub entities are typed `HUB` and are filtered from query retrieval to prevent them from dominating results.

### Embedding Similarity Link Prediction

The `EmbeddingSimilarityLinkPredictor` implements a 3-step LLM validation chain:

1. **Categorize**: "What relationship type would best describe how these entities might be connected?"
2. **Validate**: "Is there ANY reasonable way these entities could be connected? Answer YES/NO."
3. **Score**: "Rate confidence from 0.0 to 1.0."

Special handling for person-person pairs: uses a dedicated prompt that classifies as `FAMILY`, `COLLEAGUE`, `FRIEND`, or `NONE`.

---

## Token Budget Management

The query engine enforces strict token budgets to work within on-device LLM constraints:

| Component | Budget Control |
|-----------|---------------|
| Context window | `maxContextTokens` (default: 4096) |
| Context budget | `contextBudgetRatio` × max (default: 0.9 = 3686 tokens) |
| Community drop | Entity tokens > `communityDropThreshold` × budget → drop community |
| Prompt truncation | Smart truncation preserving question markers at end |
| Per-entity limits | Descriptions: 150-200 char max; metadata keys filtered |

Token estimation: `(text.length / 4).ceil()` — empirically calibrated for Gemma-family models.

---

## Backend Selection & Fallback

The `DeviceCapabilityDetector` and `BackendFallbackManager` implement cascading backend selection:

```
NPU (24× faster prefill, 1280 context) 
  → GPU (7-8× faster prefill, 4096 context) 
    → CPU (baseline, 4096 context)
```

NPU detection checks for Qualcomm/MediaTek/Google Tensor chipsets on Android. The `ContextWindowManager` automatically clamps context sizes based on the active backend.

---

## Model Cache Management

The `LiteRTModelCacheManager` provides disk-based caching for LiteRT-LM models:

- **First load**: ~10s (model loading + initialization)
- **Subsequent loads**: ~1-2s (5-10× speedup from cache)
- **LRU eviction**: Configurable max cache size (default: 2GB) and max entries (default: 5)
- **Stats tracking**: Hit/miss rates, total cache size, oldest/newest entries

---

## Module Structure

```
lib/rag/
├── graph_rag.dart                    # Main facade (GraphRAG class + factory)
├── graph_rag_config.dart             # Backend selection, device detection, config
├── embedding_models.dart             # Embedding model definitions
├── connectors/
│   ├── data_connector.dart           # System data connectors (Contacts, Calendar, ...)
│   └── google_suite_connector.dart   # Google Suite OAuth integration
├── graph/
│   ├── graph_repository.dart         # Graph storage abstraction (NativeGraphRepository)
│   ├── entity_extractor.dart         # LLM-based entity extraction + prompts
│   ├── native_function_extractor.dart # Function calling extraction
│   ├── background_indexing.dart      # Full indexing pipeline orchestration
│   ├── community_detection.dart      # Leiden algorithm + community summarizer
│   ├── link_prediction.dart          # Template, co-mention, embedding similarity
│   ├── graphrag_query_engine.dart    # Local query engine (embedding + N-hop)
│   ├── global_query_engine.dart      # Global query engine (map-reduce)
│   ├── cache_manager.dart            # Model cache management
│   └── graph_rag_exports.dart        # Public API barrel file
├── utils/
│   └── math_utils.dart               # Cosine similarity, vector operations
└── models/
    └── payloads.dart                 # Data transfer objects
```
