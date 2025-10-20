# Master Loop + Graph RAG Implementation Plan

**Version:** 1.2
**Date:** 2025-10-19
**Status:** Phase 1 Complete ✅ | Phase 2+ In Planning
**Goal:** Transform ZodoLlama into an agentic coding assistant with Claude Code-inspired architecture

---

## Executive Summary

This plan details the implementation of a 5-layer architecture that will enable ZodoLlama to become a fully agentic coding assistant. The core innovation is a **Graph RAG system** that combines:
- **Structural graph** of code relationships (functions, imports, calls)
- **Vector embeddings** for semantic search
- **Master loop** for autonomous multi-step task execution

**Key Technical Decisions:**
- **Parser:** Tree-sitter (unified API, multi-language support)
- **Embeddings:** embeddinggemma via Ollama API (1.8k token limit for safety margin)
- **Vector Store:** zvdb (Zig native)
- **Storage:** Session-ephemeral (in-memory, resets on app close)
- **Indexing Strategy:** Lazy parsing (file nodes at startup, full parse on `read_file`)
- **Global State:** Context parameter pattern (clean, thread-safe)
- **Threading:** Master loop runs in main thread (Phase 1 simplicity)

---

## Architecture Overview

### Layer Stack (Claude Code Inspired)

```
┌─────────────────────────────────────────────────────────────┐
│  🧠 L5: Reasoning Agent (Master Loop)                       │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ • Plans multi-step tasks                               │ │
│  │ • Decides when to search, read, analyze                │ │
│  │ • Iterates until task complete                         │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  🗺️  L4: Context Graph (Graph RAG)                          │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ Graph Store          Vector Store                      │ │
│  │ ┌───────────┐       ┌────────────┐                     │ │
│  │ │ Files     │       │ Embeddings │                     │ │
│  │ │ Functions │  <──> │ (zvdb)     │                     │ │
│  │ │ Imports   │       │            │                     │ │
│  │ │ Calls     │       └────────────┘                     │ │
│  │ └───────────┘                                           │ │
│  │ Query Engine: Hybrid (structural + semantic)           │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  💬 L3: Chat Memory (Conversation Context)                  │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ • Message history (user, assistant, tool)              │ │
│  │ • Tool call tracking                                   │ │
│  │ • Context assembly for prompts                         │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  💾 L2: Indexer (Code Parser + Embedder)                    │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ Tree-sitter Parser → AST → Graph Nodes                 │ │
│  │ embeddinggemma (Ollama) → Vectors                      │ │
│  │ Triggered by: file_tree (startup), read_file (lazy)   │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  🧰 L1: Tool APIs (File, Search, Time)                      │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ • get_file_tree (triggers indexing)                    │ │
│  │ • read_file (AST parse + embed)                        │ │
│  │ • search_codebase (NEW - graph + vector query)         │ │
│  │ • get_current_time                                     │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

---

## Component Specifications

### 1. Context Graph (L4)

**File:** `context_graph.zig`

**Responsibilities:**
- Maintain in-memory graph of code entities and relationships
- Provide query interface for structural searches
- Coordinate with vector store for semantic searches

**Data Structures:**

```zig
pub const NodeType = enum {
    file,
    function,
    class,
    struct_type,
    import,
    variable,
};

pub const Node = struct {
    id: u64,                    // Unique identifier
    type: NodeType,
    name: []const u8,           // Function name, file path, etc.
    file_path: []const u8,      // Source file
    line_start: usize,
    line_end: usize,
    content_hash: u64,          // For change detection
    embedding_id: ?u64,         // Reference to vector store
};

pub const EdgeType = enum {
    calls,              // function A calls function B
    imports,            // file A imports file B
    defines,            // file A defines function B
    references,         // function A references variable B
    inherits,           // class A inherits class B
};

pub const Edge = struct {
    from: u64,          // Node ID
    to: u64,            // Node ID
    type: EdgeType,
};

pub const ContextGraph = struct {
    allocator: std.mem.Allocator,
    nodes: std.AutoHashMapUnmanaged(u64, Node),
    edges: std.ArrayListUnmanaged(Edge),
    file_index: std.StringHashMapUnmanaged(u64),  // path -> node_id
    next_id: u64,

    pub fn init(allocator: std.mem.Allocator) ContextGraph;
    pub fn deinit(self: *ContextGraph) void;

    // Graph construction
    pub fn addNode(self: *ContextGraph, node: Node) !u64;
    pub fn addEdge(self: *ContextGraph, edge: Edge) !void;
    pub fn removeNode(self: *ContextGraph, id: u64) void;

    // Structural queries
    pub fn findNodesByType(self: *ContextGraph, node_type: NodeType) ![]const u64;
    pub fn findNodeByName(self: *ContextGraph, name: []const u8) ?u64;
    pub fn getCallersOf(self: *ContextGraph, node_id: u64) ![]const u64;
    pub fn getCalleesOf(self: *ContextGraph, node_id: u64) ![]const u64;
    pub fn getNodesInFile(self: *ContextGraph, file_path: []const u8) ![]const u64;

    // Graph traversal (for context assembly)
    pub fn getNeighborsWithinDistance(
        self: *ContextGraph,
        start_id: u64,
        max_hops: usize
    ) ![]const u64;
};
```

**Implementation Notes:**
- Use `u64` node IDs (cheap to copy, easy to hash)
- Adjacency list representation for edges (optimal for code graphs)
- File index for quick lookups by path

---

### 2. Vector Store (L4)

**File:** `vector_store.zig`

**Responsibilities:**
- Wrap zvdb for vector storage and similarity search
- Map between node IDs and embeddings
- Provide semantic search interface

**Data Structures:**

```zig
pub const VectorStore = struct {
    allocator: std.mem.Allocator,
    hnsw: zvdb.HNSW,           // zvdb HNSW index
    node_mapping: std.AutoHashMapUnmanaged(u64, u64), // node_id -> vector_id

    pub fn init(allocator: std.mem.Allocator, dimension: usize) !VectorStore;
    pub fn deinit(self: *VectorStore) void;

    // Add embedding for a node
    pub fn addEmbedding(
        self: *VectorStore,
        node_id: u64,
        embedding: []const f32
    ) !void;

    // Semantic search
    pub fn search(
        self: *VectorStore,
        query_embedding: []const f32,
        k: usize
    ) ![]SearchResult;

    // Remove embedding
    pub fn removeEmbedding(self: *VectorStore, node_id: u64) void;
};

pub const SearchResult = struct {
    node_id: u64,
    distance: f32,      // Cosine distance or L2
};
```

**Integration with zvdb:**
- Use HNSW index from https://github.com/allisoneer/zvdb/blob/main/src/hnsw.zig
- May need modifications in future sessions (noted for later)
- Embedding dimension: Check embeddinggemma specs (likely 768 or 1024)

---

### 3. Embeddings Generator (L2)

**File:** `embeddings.zig`

**Responsibilities:**
- Interface to Ollama's `/api/embeddings` endpoint
- Generate embeddings for code chunks
- Handle batching if needed

**API Design:**

```zig
pub const EmbeddingsClient = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,
    base_url: []const u8,
    model: []const u8,  // "embeddinggemma"

    pub fn init(
        allocator: std.mem.Allocator,
        base_url: []const u8,
        model: []const u8
    ) EmbeddingsClient;

    pub fn deinit(self: *EmbeddingsClient) void;

    // Generate embedding for a single text
    pub fn embed(
        self: *EmbeddingsClient,
        text: []const u8
    ) ![]f32;

    // Batch embeddings (if supported by API)
    pub fn embedBatch(
        self: *EmbeddingsClient,
        texts: []const []const u8
    ) ![][]f32;
};
```

**Ollama Embeddings API Reference:**
```bash
POST http://localhost:11434/api/embeddings
{
  "model": "embeddinggemma",
  "prompt": "code text here"
}

Response:
{
  "embedding": [0.123, 0.456, ...]
}
```

**Embedding Strategy (1.8k token limit):**
- **Functions < 1.8k tokens:** Embed full function body (including signature)
- **Functions > 1.8k tokens:** Embed signature + first 1600 tokens + last 200 tokens
- **Files:** First 1800 tokens or structure summary
- **Classes/Structs:** Definition + public methods (truncate if > 1.8k)

**Note:** Using 1.8k instead of full 2k for safety margin with embeddinggemma

---

### 4. Code Parser (L2)

**File:** `code_parser.zig`

**Responsibilities:**
- Use Tree-sitter to parse source code into AST
- Extract entities (functions, classes, imports)
- Identify relationships (calls, references)
- Generate graph nodes and edges

**API Design:**

```zig
pub const ParserLanguage = enum {
    zig,
    python,
    javascript,
    typescript,
    // Extensible for more languages
};

pub const CodeParser = struct {
    allocator: std.mem.Allocator,
    // Tree-sitter parsers (lazy-loaded per language)
    parsers: std.EnumArray(ParserLanguage, ?*TreeSitter.Parser),

    pub fn init(allocator: std.mem.Allocator) !CodeParser;
    pub fn deinit(self: *CodeParser) void;

    // Parse file and extract graph elements
    pub fn parseFile(
        self: *CodeParser,
        file_path: []const u8,
        content: []const u8,
        graph: *ContextGraph,
        embedder: *EmbeddingsClient,
        vector_store: *VectorStore
    ) !ParseResult;
};

pub const ParseResult = struct {
    nodes_created: usize,
    edges_created: usize,
    embeddings_generated: usize,
    language: ParserLanguage,
};
```

**Tree-sitter Integration Steps:**
1. Detect language from file extension
2. Parse file → AST
3. Walk AST to find:
   - Function definitions → create `function` nodes
   - Import statements → create `import` edges
   - Function calls → create `calls` edges
   - Class/struct definitions → create `class`/`struct_type` nodes
4. For each node:
   - Generate embedding via `embeddings.zig`
   - Store in `vector_store.zig`
   - Add to `context_graph.zig`

**Language Priority:**
1. **Zig** (Phase 1 MVP)
2. Python, JavaScript, TypeScript (Phase 2+)

---

### 5. Search Tool (L1)

**File:** `search.zig` (new tool in `tools.zig`)

**Tool Definition:**

```json
{
  "type": "function",
  "function": {
    "name": "search_codebase",
    "description": "Search the codebase using semantic or structural queries. Use this to find functions, files, or code patterns before reading files. Requires the codebase to be indexed first.",
    "parameters": {
      "type": "object",
      "properties": {
        "query": {
          "type": "string",
          "description": "Search query (e.g., 'authentication logic', 'scroll handling', 'database connections')"
        },
        "search_type": {
          "type": "string",
          "enum": ["semantic", "structural", "hybrid"],
          "description": "semantic: vector similarity, structural: graph traversal, hybrid: combine both",
          "default": "hybrid"
        },
        "limit": {
          "type": "integer",
          "description": "Maximum number of results to return",
          "default": 5
        }
      },
      "required": ["query"]
    }
  }
}
```

**Implementation:**

```zig
// In search.zig
pub fn executeSearch(
    allocator: std.mem.Allocator,
    graph: *ContextGraph,
    vector_store: *VectorStore,
    embedder: *EmbeddingsClient,
    query: []const u8,
    search_type: SearchType,
    limit: usize
) ![]SearchResult;

pub const SearchType = enum { semantic, structural, hybrid };

pub const SearchResult = struct {
    node_id: u64,
    file_path: []const u8,
    name: []const u8,
    line_start: usize,
    score: f32,          // Relevance score
    snippet: []const u8, // Code snippet
};
```

**Search Algorithm (Hybrid Mode):**
1. **Semantic component:**
   - Embed query with `embeddinggemma`
   - Vector search in `vector_store`
   - Get top K candidates (score by cosine similarity)

2. **Structural component:**
   - Parse query for keywords (function names, file patterns)
   - Graph search by name matching
   - Get top K candidates

3. **Fusion:**
   - Combine results with weighted scoring
   - Re-rank by relevance
   - Return top `limit` results

**Permission Level:** `medium` (requires indexing to be complete)

---

### 6. Master Loop (L5)

**File:** `master_loop.zig`

**Responsibilities:**
- Orchestrate iterative model interactions
- Maintain conversation history
- Automatically execute tool calls until task completion
- Detect when to stop (no tool calls in response)

**Data Structures:**

```zig
pub const MasterLoop = struct {
    allocator: std.mem.Allocator,
    ollama_client: *ollama.OllamaClient,
    context_graph: *ContextGraph,
    vector_store: *VectorStore,
    embedder: *EmbeddingsClient,
    message_history: std.ArrayListUnmanaged(ollama.ChatMessage),
    max_iterations: usize,  // Safety limit (e.g., 10)

    pub fn init(
        allocator: std.mem.Allocator,
        ollama_client: *ollama.OllamaClient,
        context_graph: *ContextGraph,
        vector_store: *VectorStore,
        embedder: *EmbeddingsClient
    ) MasterLoop;

    pub fn deinit(self: *MasterLoop) void;

    // Main loop entry point
    pub fn executeTask(
        self: *MasterLoop,
        user_message: []const u8,
        ui_callback: *const fn (chunk: []const u8) void
    ) !void;
};
```

**Loop Algorithm:**

```
1. Add user message to history

2. Loop (max 10 iterations):
   a. Call Ollama API with:
      - message_history
      - tools (get_file_tree, read_file, search_codebase, get_current_time)
      - stream=true

   b. Collect response:
      - If content: stream to UI via callback
      - If tool_calls: extract tool calls

   c. Add assistant message to history

   d. If NO tool_calls:
      → Task complete, break

   e. For each tool_call:
      - Display to user: "🔧 Using tool: {tool_name}"

      - Execute tool (with permission system)

      - If permission denied:
          → Result = "Permission denied for {tool_name}"
          → Add to history (so model can adapt)

      - If tool execution fails (error):
          → Result = "Error: {error_message}"
          → Add to history (so model can try alternative)

      - If tool succeeds:
          → Result = tool output
          → Add to history

      - If tool is read_file (Phase 2+):
          → Trigger background AST parsing
          → Generate embeddings
          → Update context_graph

      - Memory: Tool result is part of history (freed when history is freed)

   f. Continue loop

3. Return control to UI

4. Free message history (includes all tool results)
```

**Error Handling:**
- Permission denials → added to history as tool result
- Tool execution errors → added to history as error message
- Model can see errors and adapt strategy (e.g., try different file, different approach)
- Max iteration limit prevents infinite loops

**Key Differences from Current Flow:**
- **Current:** Single request/response
- **New:** App maintains history, loops until model stops requesting tools

**Integration with Permission System:**
- Tool execution still goes through `permission.zig`
- Session grants carry across loop iterations
- User can deny tool calls mid-loop

---

## Implementation Phases

### Phase 1: Master Loop Foundation (Week 1) ✅ COMPLETED

**Goal:** Operational task management system with master loop iteration control

**Status:** ✅ Complete (2025-10-19)

**What Was Built:**
- Task management tools (add_task, list_tasks, update_task)
- Session-ephemeral state system (AppState with task list)
- AppContext pattern for future graph RAG
- Master loop with iteration tracking and limits (max 10)
- Automatic task context injection
- Enhanced system prompt with task workflow guidelines

**Tasks:**
1. **Define `AppContext` in `main.zig`**
   - Context struct to hold future graph/vectors/parser
   - Phase 1: all fields are `null` (not implemented yet)

2. **Refactor tool signatures to use context parameter**
   - Update `ToolExecuteFn` signature to accept `*AppContext`
   - Update all 3 existing tools: `get_file_tree`, `read_file`, `get_current_time`
   - Tools ignore context in Phase 1 (placeholder for future)

3. **Create `master_loop.zig`**
   - Implement iterative loop structure (runs in main thread)
   - Message history management
   - Tool call detection and execution
   - Error handling (permissions, tool failures)
   - UI feedback ("🔧 Using tool: X")

4. **Add system prompt for agentic behavior**
   - Instruct model to use tools autonomously
   - Encourage multi-step reasoning
   - Reference existing 3 tools only

5. **Integrate with `main.zig`**
   - Create `AppContext` instance
   - Replace single API call with master loop
   - Wire up streaming callback

**Success Criteria:**
- User asks: "What files are in this directory?"
  - Model autonomously calls `get_file_tree`
  - Responds with formatted list

- User asks: "Read ui.zig and count the lines"
  - Model calls `read_file("ui.zig")`
  - Analyzes content and responds with count

- User asks: "What time is it and what files exist?"
  - Model calls both `get_current_time` AND `get_file_tree`
  - Synthesizes both results

- Permission denial: Model receives error in history, adapts response

**Deliverables (Actual Implementation):**
- ✅ `TaskStatus`, `Task`, `AppState`, `AppContext` structs in `main.zig`
- ✅ All tools refactored to accept `*AppContext` parameter
- ✅ Master loop integrated into `main.zig` (no separate file needed)
- ✅ Three new task management tools in `tools.zig`
- ✅ Iteration tracking with configurable limits
- ✅ `injectTaskContext()` helper for automatic progress updates
- ✅ Enhanced system prompt with task workflow examples
- ✅ Build succeeds, architecture ready for Phase 2

**Key Differences from Original Plan:**
- Added task management tools (not originally planned, but provides immediate value)
- Master loop logic embedded in existing `main.zig` (simpler than separate file)
- AppContext uses pointers to App fields (cleaner than separate state storage)

---

### Phase 2: Graph Construction (Week 2-3)

**Goal:** Build in-memory code graph with lazy parsing strategy

**Tasks:**
1. **Create `context_graph.zig`**
   - Implement Node, Edge, ContextGraph structs
   - Graph construction methods
   - Structural query methods (find by name, get callers/callees)

2. **Create `code_parser.zig`**
   - Integrate Tree-sitter Zig bindings (research C FFI approach)
   - Implement Zig language parser
   - Extract functions, structs, imports, calls
   - Generate nodes and edges

3. **Modify startup flow in `main.zig`**
   - Initialize `ContextGraph`, `CodeParser` (in `AppContext`)
   - Auto-call `get_file_tree` on app start
   - **Lightweight indexing:** Create file nodes only (no parsing yet)
   - Show progress:
     ```
     📁 Indexed 10 files (ready)
     ```
   - Takes < 1 second

4. **Hook `read_file` tool**
   - Check if file already parsed (via graph)
   - If not parsed:
     - Trigger AST parsing (Tree-sitter)
     - Extract functions → create function nodes
     - Extract calls → create call edges
     - Extract imports → create import edges
     - Add all to graph
   - Return file content to model (as usual)
   - Parsing happens before tool result is returned

**Success Criteria:**
- App starts quickly (< 1 sec) with file nodes only
- When model calls `read_file("ui.zig")`:
  - File is parsed automatically
  - Graph now contains ~18 function nodes from ui.zig
  - Tool returns content successfully
- Graph can answer: "What functions are defined in ui.zig?"
- Subsequent reads of same file skip parsing (cached)

**Deliverables:**
- `context_graph.zig`
- `code_parser.zig` (Zig support only)
- Modified `tools.zig` (read_file hook with context access)
- Modified `main.zig` (initialize graph, lightweight file indexing)
- Updated `AppContext` with graph and parser

**Dependencies:**
- Tree-sitter Zig bindings: Research C FFI approach
- Tree-sitter grammar: https://github.com/tree-sitter/tree-sitter-zig
- Build system: Update `build.zig` to link Tree-sitter

---

### Phase 3: Search Tool (Week 4)

**Goal:** Add structural search using the graph (no embeddings yet)

**Tasks:**
1. **Create `search.zig` (structural mode only)**
   - Tool definition for `search_codebase`
   - Structural search: name matching, file pattern matching
   - Query graph for functions, files
   - Return results with file:line references

2. **Add to tool registry**
   - Register `search_codebase` in `tools.zig`
   - Permission level: `safe` (read-only)
   - Uses `AppContext.graph` for queries

3. **Update system prompt**
   - Add `search_codebase` to available tools
   - Encourage model to search before reading

**Success Criteria:**
- User asks: "Where is scroll handling?"
- Model autonomously:
  1. Calls `search_codebase("scroll", "structural")`
  2. Gets results: `ui.zig:handleScroll`, `ui.zig:scrollViewport`
  3. Calls `read_file("ui.zig")` if needed
  4. Synthesizes answer with references

**Deliverables:**
- `search.zig` (structural search only)
- Updated `tools.zig` (new tool registration)
- Updated system prompt
- Test cases

**Note:** Semantic search (embeddings) deferred to Phase 4

---

### Phase 4: Vector Embeddings (Week 5-6)

**Goal:** Add semantic search capabilities

**Tasks:**
1. **Create `embeddings.zig`**
   - Implement Ollama `/api/embeddings` client
   - Support embeddinggemma model (1.8k token chunks)
   - Error handling for API failures
   - Truncation strategy for large functions

2. **Create `vector_store.zig`**
   - Integrate zvdb HNSW index
   - Node ID mapping (graph node → vector ID)
   - Similarity search (cosine distance)

3. **Modify `code_parser.zig`**
   - After creating function nodes, generate embeddings
   - Chunk text to 1.8k tokens max
   - Store embeddings in vector_store
   - Link embedding_id in graph nodes

4. **Add semantic mode to `search.zig`**
   - Embed query text
   - Vector similarity search
   - Return top K results

5. **Add embedding config to `config.json`**
   ```json
   {
     "embedding_model": "embeddinggemma",
     "embedding_dimension": 768,
     "embedding_max_tokens": 1800
   }
   ```

**Success Criteria:**
- User asks: "Find authentication code"
- Model calls `search_codebase("authentication code", "semantic")`
- Returns: `validateUser()`, `checkAuth()`, `loginHandler()`
- Results are semantically relevant (not just keyword matches)
- Queries complete in < 200ms

**Deliverables:**
- `embeddings.zig`
- `vector_store.zig`
- Modified `code_parser.zig` (embedding generation)
- Enhanced `search.zig` (semantic mode)
- zvdb integration (may require modifications)

**Dependencies:**
- zvdb: https://github.com/allisoneer/zvdb/blob/main/src/hnsw.zig
- embeddinggemma: `ollama pull embeddinggemma`
- Verify embedding dimension with test API call

---

### Phase 5: Graph RAG Fusion (Week 7-8)

**Goal:** Combine graph + vector search for optimal context retrieval

**Tasks:**
1. **Enhance `search.zig`**
   - Implement hybrid search algorithm
   - Weighted fusion of structural + semantic results
   - Re-ranking by combined score

2. **Context Assembly**
   - For each search result, gather surrounding context:
     - Callers/callees (graph traversal)
     - Related functions (vector similarity)
     - Import dependencies
   - Format for LLM consumption

3. **Smart Context Injection**
   - Before model call, inject relevant context into system prompt
   - Format:
     ```
     [Code Context]
     File: ui.zig
     Function: handleScroll (lines 234-267)
     Callers: handleMouseEvent, processInput
     Related: scrollViewport, updateCursor

     [Code]
     pub fn handleScroll(...) { ... }
     ```

4. **Performance Optimization**
   - Cache embeddings (avoid regenerating)
   - Lazy parsing (only parse files as needed)
   - Limit context size to fit token budget

**Success Criteria:**
- User asks: "How does markdown rendering work?"
- Master loop:
  1. Searches semantically: finds `renderMarkdown()` in `markdown.zig`
  2. Graph traversal: finds callers in `ui.zig`
  3. Assembles context with all related functions
  4. Model provides comprehensive answer with accurate references

**Deliverables:**
- Enhanced `search.zig` (hybrid mode)
- Context assembly utilities
- Performance metrics (indexing time, query time)

---

### Phase 6: Multi-Language Support (Week 9+)

**Goal:** Extend parser to Python, JavaScript, TypeScript

**Tasks:**
1. Add Tree-sitter grammars for each language
2. Language-specific AST walking logic
3. Test on multi-language codebases

**Deferred to Post-MVP**

---

## Data Flow Diagrams

### Startup Flow

```
App Start
   ↓
Initialize Components
   • ContextGraph
   • VectorStore
   • EmbeddingsClient
   • CodeParser
   ↓
Auto-call get_file_tree
   ↓
For each file in tree:
   ↓
   Determine if code file (extension check)
   ↓
   If code file (.zig, .py, .js, etc.):
      ↓
      Create file node in graph
      - node.type = file
      - node.name = file path
      - NO AST parsing
      - NO embeddings
   ↓
   If non-code file: skip
   ↓
Display: "📁 Indexed X files (ready)"
   ↓
Ready for chat (startup took < 1 second)
```

### Tool Call Flow (read_file)

```
Model calls read_file("ui.zig")
   ↓
Permission check (existing system)
   ↓
Execute read_file
   ↓
   Read file content
   ↓
   Check if already parsed (via graph)
   ↓
   If not parsed:
      ↓
      CodeParser.parseFile()
         ↓
         Tree-sitter → AST
         ↓
         Extract functions → Nodes
         ↓
         Extract calls → Edges
         ↓
         For each function:
            ↓
            Generate embedding
            ↓
            Store in VectorStore
            ↓
         Add to ContextGraph
   ↓
Return file content to model
   ↓
Master loop adds tool result to history
   ↓
Continue loop
```

### Search Flow (search_codebase)

```
Model calls search_codebase("scroll logic", "hybrid")
   ↓
Permission check
   ↓
Generate query embedding
   ↓
Parallel search:
   ┌─────────────────┬────────────────────┐
   ↓                 ↓                    ↓
Vector Search    Graph Search      Keyword Search
   ↓                 ↓                    ↓
Top K by         Top K by           Top K by
similarity       name match         grep
   └─────────────────┴────────────────────┘
                     ↓
              Fusion & Re-rank
                     ↓
          Assemble context for each result
          (callers, callees, file location)
                     ↓
          Return JSON results to model
                     ↓
          Master loop continues
```

---

## Integration Points with Existing Code

### 1. `main.zig`

**Changes Required:**

```zig
// Add imports
const master_loop = @import("master_loop.zig");
const context_graph = @import("context_graph.zig");
const embeddings = @import("embeddings.zig");
const vector_store = @import("vector_store.zig");
const code_parser = @import("code_parser.zig");

// In main() initialization:
var graph = context_graph.ContextGraph.init(allocator);
defer graph.deinit();

var vectors = try vector_store.VectorStore.init(allocator, 768);
defer vectors.deinit();

var embedder = embeddings.EmbeddingsClient.init(
    allocator,
    config.ollama_host,
    "embeddinggemma"
);
defer embedder.deinit();

var parser = try code_parser.CodeParser.init(allocator);
defer parser.deinit();

// Auto-index on startup
try autoIndexCodebase(&graph, &vectors, &embedder, &parser);

// Replace current chat loop with:
var loop = master_loop.MasterLoop.init(
    allocator,
    &ollama_client,
    &graph,
    &vectors,
    &embedder
);
defer loop.deinit();

// When user sends message:
try loop.executeTask(user_input, uiStreamCallback);
```

### 2. `tools.zig`

**Add new tool:**

```zig
fn searchCodebaseTool(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "search_codebase"),
                .description = try allocator.dupe(u8,
                    "Search the codebase using semantic or structural queries. " ++
                    "Use this to find functions, files, or code patterns before reading files."
                ),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "query": {"type": "string"},
                    \\    "search_type": {
                    \\      "type": "string",
                    \\      "enum": ["semantic", "structural", "hybrid"],
                    \\      "default": "hybrid"
                    \\    },
                    \\    "limit": {"type": "integer", "default": 5}
                    \\  },
                    \\  "required": ["query"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "search_codebase",
            .description = "Search code semantically or structurally",
            .risk_level = .safe,
            .required_scopes = &.{.read_files},
            .validator = null,
        },
        .execute = executeSearchCodebase,
    };
}

// Execute function needs access to graph/vectors
// Will need to pass context via closure or global state
```

**Hook read_file:**

```zig
fn executeReadFile(allocator: std.mem.Allocator, arguments: []const u8) ![]const u8 {
    // ... existing read logic ...

    // NEW: Trigger parsing if not already parsed
    if (!graph.hasFile(parsed.value.path)) {
        _ = try parser.parseFile(
            parsed.value.path,
            content,
            graph,
            embedder,
            vector_store
        );
    }

    return content;
}
```

**Solution:** Context parameter pattern (Option B)

```zig
// Updated tool signature
pub const ToolExecuteFn = *const fn (
    allocator: std.mem.Allocator,
    arguments: []const u8,
    context: *AppContext,  // NEW
) anyerror![]const u8;

// AppContext defined in main.zig
pub const AppContext = struct {
    allocator: std.mem.Allocator,
    config: *const Config,

    // Phase 1: null (not implemented)
    // Phase 2+: populated
    graph: ?*ContextGraph = null,
    vector_store: ?*VectorStore = null,
    embedder: ?*EmbeddingsClient = null,
    parser: ?*CodeParser = null,
};

// read_file implementation (Phase 2+)
fn executeReadFile(
    allocator: std.mem.Allocator,
    arguments: []const u8,
    context: *AppContext,
) ![]const u8 {
    // ... existing read logic ...

    // Phase 2: Trigger parsing if graph available
    if (context.graph) |graph| {
        if (!graph.hasFile(file_path)) {
            _ = try context.parser.?.parseFile(
                file_path,
                content,
                graph,
                context.embedder,  // null in Phase 2-3, present in Phase 4+
                context.vector_store,  // null in Phase 2-3, present in Phase 4+
            );
        }
    }

    return content;
}
```

### 3. `ollama.zig`

**No major changes required** - already supports:
- Tool calls in messages
- Streaming with tool_calls callback
- Message history

**Minor enhancement:**
- May need to adjust timeout for longer master loop iterations

### 4. `permission.zig`

**No changes required** - existing system works perfectly:
- Tools still go through permission checks
- Session grants persist across master loop iterations
- Audit logging captures all tool calls

---

## System Prompt Design

**Critical for agentic behavior:**

```
You are an expert coding assistant with access to a codebase through tools.

Available tools:
- get_file_tree: Lists all files in the project
- search_codebase: Search for functions, patterns, or concepts semantically
- read_file: Read a specific file's contents
- get_current_time: Get current timestamp

Guidelines:
1. Before reading files, use search_codebase to find relevant code
2. Use get_file_tree to understand project structure
3. Break complex tasks into steps:
   - Search for relevant code
   - Read specific files
   - Analyze and synthesize
4. Reference code with file:line format (e.g., "ui.zig:234")
5. When asked "where is X", use search_codebase first
6. Continue using tools until you have enough context to answer fully

The codebase is indexed with:
- Function-level understanding
- Import and call relationships
- Semantic embeddings for similarity search

Use search_codebase with:
- semantic: "authentication logic", "error handling patterns"
- structural: specific function names, file patterns
- hybrid (default): combines both approaches
```

---

## Configuration Updates

### `~/.config/zodollama/config.json`

**New fields:**

```json
{
  "model": "llama3.2",
  "ollama_host": "http://localhost:11434",
  "editor": ["nvim"],
  "scroll_lines": 3,

  // NEW: Graph RAG settings
  "embedding_model": "embeddinggemma",
  "embedding_dimension": 768,
  "auto_index_on_startup": true,
  "index_progress_ui": true,
  "max_master_loop_iterations": 10,

  // Search settings
  "default_search_type": "hybrid",
  "search_result_limit": 5,

  // Parser settings
  "supported_languages": ["zig", "python", "javascript"],
  "max_file_size_kb": 1024
}
```

---

## Testing Strategy

### Unit Tests

**`context_graph_test.zig`:**
- Node creation/deletion
- Edge creation/query
- Graph traversal (callers, callees)

**`vector_store_test.zig`:**
- Add/remove embeddings
- Similarity search accuracy
- zvdb integration

**`code_parser_test.zig`:**
- Parse simple Zig file
- Extract functions correctly
- Detect function calls
- Handle syntax errors gracefully

**`embeddings_test.zig`:**
- Generate embedding for text
- Verify dimension
- Handle API errors

### Integration Tests

**`master_loop_test.zig`:**
- Single iteration (no tools)
- Multi-iteration with tool calls
- Loop termination
- Max iteration limit

**`search_integration_test.zig`:**
- Index small test project
- Semantic search returns relevant results
- Structural search finds exact matches
- Hybrid combines both

### End-to-End Tests

**Test Codebase:** Small 5-file Zig project with:
- `main.zig` (entry point)
- `auth.zig` (authentication functions)
- `db.zig` (database calls)
- `utils.zig` (utilities)
- `test.zig` (tests)

**Test Scenarios:**

1. **Semantic Search:**
   - Query: "authentication logic"
   - Expected: `auth.zig:validateUser`, `auth.zig:checkToken`

2. **Structural Search:**
   - Query: "database connections"
   - Expected: `db.zig:connect`, `db.zig:close`

3. **Master Loop:**
   - User: "How does user login work?"
   - Expected flow:
     1. search_codebase("login")
     2. read_file("auth.zig")
     3. search_codebase("database user")
     4. read_file("db.zig")
     5. Synthesize answer

4. **Graph Traversal:**
   - Query: "What calls validateUser?"
   - Expected: Graph query returns `main.zig:handleLogin`

---

## Performance Targets

### Indexing Performance

| Codebase Size | Files | Functions | Index Time | Memory |
|---------------|-------|-----------|------------|--------|
| Small (ZodoLlama) | ~10 | ~200 | < 5 sec | < 50 MB |
| Medium | ~100 | ~2000 | < 30 sec | < 200 MB |
| Large | ~1000 | ~20000 | < 5 min | < 1 GB |

### Query Performance

| Operation | Target Latency |
|-----------|----------------|
| Semantic search (k=5) | < 100 ms |
| Graph traversal (2 hops) | < 50 ms |
| Hybrid search | < 200 ms |
| Embedding generation | < 500 ms |

### Master Loop

| Metric | Target |
|--------|--------|
| Iteration latency (no tools) | < 2 sec |
| Iteration latency (1 tool) | < 5 sec |
| Max iterations before timeout | 10 |

---

## Risk Assessment & Mitigations

### Risk 1: zvdb Integration Complexity

**Likelihood:** Medium
**Impact:** High
**Mitigation:**
- Phase 2 (graph only) can proceed without vectors
- Can swap zvdb for simpler solution if needed
- Prototype zvdb integration early in Phase 3

### Risk 2: Tree-sitter Zig Bindings

**Likelihood:** Medium
**Impact:** High
**Mitigation:**
- Research existing Zig bindings before Phase 2
- Fallback: Use C FFI directly
- Start with single language (Zig) to prove concept

### Risk 3: Embedding API Latency

**Likelihood:** Low
**Impact:** Medium
**Mitigation:**
- Batch embedding requests
- Show progress during indexing
- Cache embeddings aggressively

### Risk 4: Context Window Overflow

**Likelihood:** Medium
**Impact:** Medium
**Mitigation:**
- Limit search results (top K)
- Smart context assembly (only relevant neighbors)
- Summarize large files instead of full content

### Risk 5: Master Loop Infinite Loops

**Likelihood:** Medium
**Impact:** High
**Mitigation:**
- Hard limit on iterations (10)
- Detect cycles in tool calls (same tool, same args)
- User can interrupt with Ctrl+C

---

## Success Metrics

### Phase 1 Success (Master Loop)
- [ ] Model autonomously uses multiple tools
- [ ] Loop terminates correctly
- [ ] User can deny tools mid-loop
- [ ] At least 3 working multi-step examples

### Phase 2 Success (Graph)
- [ ] Graph built for ZodoLlama codebase
- [ ] Structural queries work (find callers, callees)
- [ ] Indexing completes in < 5 seconds
- [ ] Memory usage < 50 MB

### Phase 3 Success (Embeddings)
- [ ] Embeddings generated for all functions
- [ ] Semantic search returns relevant results
- [ ] Integration with embeddinggemma stable
- [ ] Query latency < 100 ms

### Phase 4 Success (Graph RAG Fusion)
- [ ] Hybrid search outperforms single-mode
- [ ] Context assembly provides relevant code
- [ ] Model answers complex questions accurately
- [ ] Demo: "How does X work?" queries

---

## Dependencies & Prerequisites

### External Libraries

1. **Tree-sitter**
   - Zig bindings: TBD (research needed)
   - Grammars: tree-sitter-zig, tree-sitter-python, etc.
   - Installation: `build.zig` integration

2. **zvdb**
   - Source: https://github.com/allisoneer/zvdb
   - Integration: Add as dependency or vendor
   - Potential modifications: May need to adapt API

3. **embeddinggemma**
   - Requires: Ollama running locally
   - Installation: `ollama pull embeddinggemma`
   - API: Standard Ollama embeddings endpoint

### Build System Updates

**`build.zig` changes:**
- Add Tree-sitter dependencies
- Link zvdb
- Possibly use C FFI for Tree-sitter

---

## Open Questions

### 1. Tree-sitter Integration
**Q:** Best way to use Tree-sitter in Zig?
**Options:**
- A) Use existing Zig bindings (if available)
- B) C FFI directly
- C) Write minimal wrapper

**Decision needed:** Phase 2 start

### 2. Global State for Context Graph ✅ RESOLVED
**Q:** How to pass graph/vectors/parser to tool execution functions?
**Decision:** Option C - Refactor tool signatures to accept context parameter

**Rationale:**
- Clean and explicit (idiomatic Zig)
- Thread-safe by design
- Easy to test (can mock context)
- Scales well as more components are added

**Implementation:**
- Define `AppContext` struct in `main.zig` (Phase 1)
- Update `ToolExecuteFn` signature to accept `*AppContext`
- Refactor 3 existing tools in Phase 1
- All future tools automatically get context access

### 3. Embedding Caching
**Q:** Where to cache embeddings between sessions?
**Options:**
- A) Don't cache (regenerate each session)
- B) Cache in `~/.config/zodollama/embeddings/`
- C) Defer to future persistence phase

**Decision needed:** Phase 3

### 4. Context Size Limits
**Q:** How much context to inject per query?
**Options:**
- A) Fixed limit (e.g., top 5 results, 2000 tokens)
- B) Dynamic based on model context window
- C) User configurable

**Decision needed:** Phase 4

---

## Future Enhancements (Post-MVP)

### Persistence
- Save graph + vectors to disk
- Incremental updates (only changed files)
- Fast startup with cached index

### Multi-Project Support
- Switch between indexed projects
- Per-project configuration
- Project detection (git root)

### Advanced Search
- Regex support in structural search
- Type-aware search (find all functions returning X)
- Cross-file dependency analysis

### Editing Tools
- `write_file` tool
- `edit_code` tool (line-based edits)
- Diff preview before applying

### Test Generation
- Analyze function → generate test
- Coverage-guided test suggestions

### Code Intelligence
- Auto-complete suggestions
- Refactoring operations
- Dead code detection

---

## Appendices

### A. Ollama API Reference

**Chat Endpoint:**
```bash
POST /api/chat
{
  "model": "llama3.2",
  "messages": [...],
  "tools": [...],
  "stream": true
}
```

**Embeddings Endpoint:**
```bash
POST /api/embeddings
{
  "model": "embeddinggemma",
  "prompt": "text to embed"
}

Response:
{
  "embedding": [float array]
}
```

### B. embeddinggemma Specs

- **Dimension:** 768 (verify with initial API test)
- **Max tokens:** 2048 (verified)
- **Safe limit:** 1800 tokens (10% safety margin)
- **Similarity metric:** Cosine similarity (normalized)
- **Truncation strategy:** For functions > 1.8k tokens:
  - Signature + first 1600 tokens + last 200 tokens
  - Preserves function definition and conclusion

### C. File Size Limits

| Component | Limit | Rationale |
|-----------|-------|-----------|
| read_file | 10 MB | Existing limit in tools.zig |
| Parser input | 1 MB | Prevent Tree-sitter memory issues |
| Embedding text | 1800 tokens | Safe limit for embeddinggemma (2k max) |
| Search results | 5 items | Prevent context overflow |
| Master loop iterations | 10 | Prevent infinite loops |

### D. Graph Size Estimates

**ZodoLlama (10 files, ~5000 LOC):**
- Nodes: ~200 (files + functions)
- Edges: ~500 (calls + imports)
- Memory: ~10 MB (graph) + ~10 MB (vectors) = 20 MB

**Medium Project (100 files, ~50k LOC):**
- Nodes: ~2000
- Edges: ~5000
- Memory: ~100 MB (graph) + ~100 MB (vectors) = 200 MB

---

## Glossary

- **AST:** Abstract Syntax Tree - tree representation of code structure
- **Graph RAG:** Retrieval-Augmented Generation using knowledge graphs
- **HNSW:** Hierarchical Navigable Small World - efficient vector search algorithm
- **Master Loop:** Iterative LLM invocation pattern for agentic behavior
- **Node:** Entity in code graph (file, function, class)
- **Edge:** Relationship between nodes (calls, imports)
- **Embedding:** Vector representation of text for semantic search
- **zvdb:** Zig vector database library
- **Tree-sitter:** Incremental parsing library with multi-language support

---

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-10-19 | Planning Session | Initial formalized plan |
| 1.1 | 2025-10-19 | Refinement Session | Updated with refined decisions: context parameter pattern, lazy parsing strategy, 1.8k token limit, error handling in master loop, Phase 1 focus on existing tools only |
| 1.2 | 2025-10-19 | Phase 1 Implementation | ✅ Phase 1 Complete: Task management, master loop, AppContext pattern, iteration limits, system prompt |

---

## Approval & Next Steps

**Plan Status:** Phase 1 ✅ Complete | Phase 2+ Ready to Begin

**Confirmed Decisions:**
1. ✅ Context parameter pattern (Option B) for global state
2. ✅ Session-ephemeral MVP (no disk persistence)
3. ✅ Lazy parsing (file nodes at startup, full parse on read_file)
4. ✅ 1.8k token limit for embeddings
5. ✅ Master loop runs in main thread (Phase 1)
6. ✅ Keep permission UX simple (existing system)
7. ✅ Show tool usage messages to user ("🔧 Using tool: X")
8. ✅ Add errors to history (so model can adapt)

**Updated Phase Structure:**
- **Phase 1 (Week 1):** ✅ Master loop + task management + context pattern
- **Phase 2 (Week 2-3):** Graph construction with lazy parsing (NEXT)
- **Phase 3 (Week 4):** Search tool (structural mode)
- **Phase 4 (Week 5-6):** Vector embeddings (semantic search)
- **Phase 5 (Week 7-8):** Hybrid search fusion
- **Phase 6 (Week 9+):** Multi-language support

**Phase 1 Achievements:**
- ✅ Task management system operational (add/list/update tasks)
- ✅ Master loop with iteration tracking
- ✅ AppContext pattern established
- ✅ All tools accept context parameter
- ✅ System prompt with task workflow
- ✅ Build succeeds, ready for Phase 2

**Next Session (Phase 2):**
- Create `context_graph.zig` with Node/Edge structures
- Create `code_parser.zig` with Tree-sitter integration
- Implement lazy parsing (file nodes at startup, full parse on read_file)
- Populate `context.graph` field in AppContext

**Memory Management Notes:**
- Tool results are part of message history
- History is freed when loop completes
- Each message (user, assistant, tool) owns its allocations
- Master loop cleanup frees entire history at end

---

**End of Plan Document**
