# GraphRAG Example App

> **Interactive demo of the flutter_gemma GraphRAG pipeline — personal knowledge graph construction, visualization, and querying, running entirely on-device.**

This section of the example app demonstrates the full GraphRAG functionality: ingesting personal data from system APIs, building a knowledge graph, visualizing it interactively, and querying it with both local (entity-focused) and global (map-reduce) query engines.

---

## Table of Contents

1. [Screen Architecture](#screen-architecture)
2. [Model Setup & Initialization](#model-setup--initialization)
3. [Index Management Screen](#index-management-screen)
4. [Chat / Query Screen](#chat--query-screen)
5. [Graph Visualizer](#graph-visualizer)
6. [Settings Tab](#settings-tab)
7. [Service Layer](#service-layer)
8. [File Reference](#file-reference)

---

## Screen Architecture

The GraphRAG section is organized as a tabbed interface via `GraphRAGNavigator`:

```
GraphRAGNavigator
├── [Tab 0] GraphRAGIndexScreen   — Index management, stats, permissions, graph visualization
├── [Tab 1] GraphRAGChatScreen    — Local & global query interface with result inspection
└── [Tab 2] Settings              — Model selection, token configuration, re-initialization
```

On first launch, the navigator shows a **setup view** that checks whether the required models are installed, downloads them if needed, and initializes the `GraphRAGService` singleton.

---

## Model Setup & Initialization

### Required Models

| Model | Purpose | Format |
|-------|---------|--------|
| **Gemma 3n 2B** | Text generation, entity extraction (function calling), community summarization, query answering | `.litertlm` |
| **Embedding Gemma 512** | 512-dimensional embeddings for entity/query similarity search | TFLite + SentencePiece |

### Initialization Flow

1. **Check installation**: The navigator checks if both models are already installed via `FlutterGemma.isModelInstalled()`.
2. **Load/download models**: If not installed, triggers download from network (optionally using a Kaggle/HuggingFace auth token). If installed, activates them.
3. **Create chat sessions**:
   - **Main chat** (`temperature: 0.7`): Used for community summarization, answer generation, global query reduce phase.
   - **Extraction chat** (`temperature: 0.0`, with `ExtractionTools` + `LinkValidationTools`): Used for structured entity extraction via native function calling and link validation. Released after indexing completes to free memory.
   - **Vision chat** (optional, when GPU is available): Used for photo captioning during indexing.
4. **Initialize `GraphRAGService`**: Passes all chat instances, embedding model, and lifecycle callbacks (model deallocation/reallocation) to the service.

### Auth Token

A Kaggle/HuggingFace token can be entered in the setup UI and is persisted via `AuthTokenService` (backed by `SharedPreferences`). The token is used for model downloads from authenticated repositories.

---

## Index Management Screen

**File**: `graph_rag_index_screen.dart`

This screen provides two views (toggled via a `SegmentedButton`):

### Stats & Index View

#### Graph Statistics Card
Displays the current knowledge graph state:
- **Entities**: Total number of nodes in the graph
- **Relationships**: Total number of edges
- **Communities**: Number of detected communities

#### Permissions Card
Shows and manages system data access permissions:
- **Contacts** — access to device contacts
- **Calendar** — access to calendar events
- **Photos** — access to photo library
- **Call Log** — access to phone call history (Android only; shown as "Restricted" on iOS)
- **Files** — access to documents

Each permission is displayed as a chip with color-coded status (green = granted, red = denied, gray = not determined). A "Request All Permissions" button triggers sequential permission requests.

#### Indexing Card
Controls for the background indexing pipeline:

- **Start (Incremental)**: Fetches only new/modified data since the last index run. If the graph is empty, automatically forces a full fetch.
- **Full Reindex**: Clears sync timestamps and re-fetches all data from scratch.
- **Add Note**: Opens a dialog to create a text note with title and content. The note is chunked if long, entities are extracted, and it's indexed into the graph. Supports structured extraction with the extraction chat.
- **Add Alarm**: Opens a dialog to create an alarm with:
  - Label (required)
  - Date and time picker
  - Recurrence options: None, Daily, Weekly (with day selection), Weekdays, Weekends
  - The alarm is indexed into the graph and optionally launches the system clock app (Android) with pre-filled data via `AndroidIntent`.
- **Select Files**: Opens a native document picker (`DocumentsConnector.pickDocuments`) allowing multi-file selection. Selected files are read, chunked, and indexed with embedding generation.
- **Clear Graph**: Deletes all entities, relationships, and communities from the database. Resets connector sync timestamps so the next indexing run starts fresh. Requires confirmation dialog.

#### Indexing Progress
When indexing is running, the card displays:
- Current phase (e.g., "Processing CONTACT", "Detecting communities", "Generating summaries")
- Progress bar with percentage
- Counters: processed/total items, extracted entities, unique stored, relationships, predicted links, communities
- Elapsed time
- Error messages (if failed)

### Graph Visualization View

Switches to the interactive `GraphVisualizer` widget (see [Graph Visualizer](#graph-visualizer)). Tapping an entity node opens a bottom sheet with detailed entity information.

#### Entity Details Bottom Sheet
Shows comprehensive entity information based on type:
- **All entities**: Name, type (color-coded badge), ID, description, last modified date
- **Person**: Job title, organization, email addresses, phone numbers
- **Event**: Start/end dates, location, attendees, recurrence info
- **Photo**: Creation date, location, file info
- **Phone Call**: Direction, duration, contact, timestamp
- **Alarm**: Time, recurrence pattern, days
- **Note/Document**: Content preview, creation date, source app
- **Hub**: Data source type, child count
- Raw metadata (expandable, for debugging)

---

## Chat / Query Screen

**File**: `graph_rag_chat_screen.dart`

The chat screen provides two query modes and displays results in an expandable card-based history.

### Local Query Mode (default)

Uses the `GraphRAGQueryEngine` (embedding similarity + N-hop graph traversal):

**Controls**:
- **Top-K slider** (1-20, default 4): Number of seed entities retrieved by embedding similarity
- **Max Hops slider** (0-3, default 1): Graph traversal depth from seed entities

**Result Display** (`_QueryResultCard`):
- **Generated Answer**: The LLM-generated answer grounded in the retrieved context, displayed in a highlighted blue card
- **Retrieval Metadata**: Seed entities count, hop entities count, total entities (before/after budget trimming), relationships, token usage, execution time
- **Retrieved Entities**: Expandable list split into:
  - *Seed entities* (from embedding similarity) — shown with blue "embedding" badge
  - *Hop entities* (from graph traversal) — shown with green "graph_traversal" badge
  - Each entity row shows: type badge (color-coded), name, source indicator, similarity score
- **Community Context**: If a relevant community was included, its summary is shown
- **Raw Context**: Expandable section showing the full token-budget-aware context string sent to the LLM

### Global Query Mode

Uses the `StreamingGlobalQueryEngine` (map-reduce over community summaries):

**Toggle**: A switch toggles between "Local Query" and "Global Query (Map-Reduce over communities)"

**Streaming Progress**: During execution, a progress card shows:
- Current phase message (e.g., "Processing community 2 of 3")
- Progress bar for community processing
- Streaming response tokens with cursor indicator

**Result Display**:
- **Global Answer**: The synthesized answer from the reduce phase
- **Metadata**: Community level, map phase duration, reduce phase duration, total duration, number of community answers used

### Indexing Lock

When indexing is running, the chat screen is disabled. An orange banner with a spinner is shown: "Indexing in progress — chat is unavailable while the LLM is busy." This prevents concurrent LLM access (the plugin maintains a single native session).

---

## Graph Visualizer

**File**: `widgets/graph_visualizer.dart`

An interactive, force-directed graph visualization rendered on a `CustomPainter` canvas with gesture support.

### Features

- **Force-directed layout**: Implements a spring-electrical model:
  - **Repulsion**: Coulomb-like force between all node pairs ($F = k / d^2$, reduced for connected pairs)
  - **Spring attraction**: Hooke-like force along edges with role-dependent rest lengths
  - **Center gravity**: Weak pull toward canvas center, stronger for the "You" node
  - **Damping**: Velocity decay (0.85) for convergence
  - **Simulation**: Runs via `AnimationController`, auto-stops when all velocities drop below threshold

- **Hub routing**: Entity types with more than `hubThreshold` (default: 5) entities are routed through hub nodes instead of connecting directly to "You":
  ```
  You ─── Hub:My Contacts ─── Person:Alice
                           ─── Person:Bob
                           ─── Person:Charlie
  ```
  Hub nodes display a count badge showing the number of child entities.

- **Visual encoding**:
  - **Node size**: "You" node is largest, Hubs are medium-large, entities are small
  - **Node color**: Determined by entity type (Person=blue, Event=green, Location=red, Photo=pink, etc.)
  - **Node icon**: Type-specific icons (person, event, location, photo, phone, document, alarm, etc.)
  - **Edge style**: Varies by role (hub-to-you = thick, entity-to-hub = thin, entity-to-entity = subtle dotted)
  - **Selection**: Tapped nodes are highlighted with a glow ring and yellow border

- **Interactions**:
  - **Pan & zoom**: Two-finger pinch/spread and drag gestures via `GestureDetector`
  - **Node dragging**: Long-press and drag to reposition nodes (pins them in place)
  - **Tap**: Select a node to highlight it and trigger the `onEntityTap` callback
  - **Initial layout**: Radial placement around "You" node, grouped by type

---

## Settings Tab

The third tab in the navigator allows changing configuration after initialization:

- **Inference model selector**: Dropdown showing available inference models (currently restricted to Gemma 3n 2B LiteRT-LM)
- **Embedding model selector**: Dropdown showing available embedding models (EmbeddingGemma 512)
- **Auth token input**: Text field for Kaggle/HuggingFace token, with save button
- **Re-initialize button**: Triggers full service re-initialization with newly selected models

---

## Service Layer

**File**: `services/graph_rag_service.dart`

The `GraphRAGService` is a singleton that wraps the `GraphRAG` facade and manages all LLM/embedding interactions.

### Key Responsibilities

- **LLM session serialization**: An `_AsyncMutex` ensures only one LLM call runs at a time, since the native plugin maintains a single session. Concurrent calls (extraction, summarization, query) are queued.

- **Prompt truncation**: Prompts exceeding ~2500 characters are smart-truncated, preserving question markers at the end to ensure the model sees the query even when context is cut.

- **Model lifecycle management**:
  - `_handleExtractionPhaseComplete()`: Releases the extraction chat after indexing to free memory
  - `_handleBeforeSummarization()`: Recreates the main chat if it was disposed
  - `chatFactory` / `extractionChatFactory`: Factory callbacks that recreate model sessions on-demand when they go stale ("Model is closed" errors)

- **Stale model recovery**: If the native model session is closed (e.g., after Android kills the process), the service catches `StateError` and uses the factory callback to recreate the session transparently.

### Exposed APIs

| Method | Description |
|--------|-------------|
| `initialize()` | Set up GraphRAG with models and callbacks |
| `startIndexing()` | Start background indexing (incremental or full) |
| `query()` | Local query (retrieval only) |
| `queryWithAnswer()` | Local query + LLM answer generation |
| `globalQuery()` | Global map-reduce query |
| `globalQueryAuto()` | Global query with auto level selection |
| `globalQueryAutoStreaming()` | Streaming global query with progress events |
| `indexNote()` | Index a user-typed note |
| `indexAlarm()` | Index a user-created alarm |
| `pickDocuments()` | Open native file picker |
| `indexDocuments()` | Index selected documents |
| `clearGraph()` | Delete all graph data |
| `getAllEntities()` | Fetch all entities for visualization |
| `getAllRelationships()` | Fetch all relationships for visualization |
| `checkPermissions()` | Check system data permissions |
| `requestPermissions()` | Request all system data permissions |

---

## File Reference

```
example/lib/
├── graph_rag_navigator.dart         # Tab navigator, model setup, initialization
├── graph_rag_index_screen.dart      # Index management, stats, permissions, entity details
├── graph_rag_chat_screen.dart       # Local & global query interface, result cards
├── graph_rag_screen.dart            # Standalone version (all-in-one, legacy)
├── services/
│   ├── graph_rag_service.dart       # GraphRAG service singleton, LLM orchestration
│   └── auth_token_service.dart      # Token persistence (SharedPreferences)
├── widgets/
│   └── graph_visualizer.dart        # Force-directed graph visualization
└── models/
    ├── model.dart                   # Inference model definitions
    └── embedding_model.dart         # Embedding model definitions
```
