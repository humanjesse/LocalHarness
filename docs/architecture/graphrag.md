# GraphRAG Architecture

Secondary agentic loop that builds knowledge graphs from read files to compress conversation history.

## Overview

**Problem:** Large files consume massive context windows when referenced multiple times in conversation history.

**Solution:** Build knowledge graphs in background, replace full file content with semantic summaries (90%+ compression).

## Two-Loop Architecture

```
┌─────────────────────────────────────────┐
│         MAIN LOOP (Primary)             │
│  User → LLM → read_file → Response      │
│                    ↓                    │
│              Queue for indexing         │
└─────────────────────────────────────────┘
                     ↓
┌─────────────────────────────────────────┐
│      SECONDARY LOOP (Background)        │
│  Process Queue → LLM Indexer → Graph    │
│                         ↓               │
│                   Vector DB             │
└─────────────────────────────────────────┘
                     ↓
         Later references use summaries
```

**Key Design:**
- Main loop returns immediately (non-blocking)
- Secondary loop runs after response completes
- Files indexed once, compressed forever

## Components

### 1. Indexing Queue (`graphrag/indexing_queue.zig`)
- Simple FIFO queue of files to index
- Populated by `read_file` tool calls
- Drained by secondary loop

### 2. LLM Indexer (`graphrag/llm_indexer.zig`)
**Two-phase agentic workflow with independent contexts:**

**Phase 1: Node Extraction**
- Agent receives: System prompt + document
- Task: Extract ALL entities (functions, structs, sections, concepts)
- Iterates until completion (2 empty iterations signal done)
- Tools: `create_node`

**Phase 2: Edge Creation (Fresh Context)**
- Phase 1 history cleared - agent receives fresh context
- Agent receives: System prompt + extracted nodes + document (for reference)
- Task: Map relationships between entities
- Iterates until completion
- Tools: `create_edge`

**Why separate contexts?**
- Each phase has focused, tailored context
- 30-40% token savings for Phase 2
- No confusion from mixing entity extraction + relationship mapping
- Better scalability for large documents

**Model:** `llama3.1:8b` (configurable via `indexing_model`)

### 3. Graph Builder (`graphrag/graph_builder.zig`)
In-memory graph construction during indexing:
- Validates edges reference existing nodes
- Idempotent operations (duplicates ignored)
- Prepares for vector DB storage

### 4. Embeddings (`embedder_interface.zig`)
Unified embeddings interface with full provider support:

**Provider Support:**
- **Ollama**: Uses `/api/embed` endpoint
- **LM Studio**: Uses OpenAI-compatible `/v1/embeddings` endpoint
- Provider-aware: automatically uses configured provider

**Model Name Format (IMPORTANT):**
- **Ollama format**: `nomic-embed-text` (short name)
- **LM Studio format**: `text-embedding-nomic-embed-text-v1.5` (OpenAI-style with prefix)
- **Validation**: App validates format matches provider at startup

**Reliability Features:**
- Retry logic for transient connection failures
- Error response parsing with helpful messages
- Runtime validation before indexing
- Debug support via `DEBUG_EMBEDDINGS=1`

**Performance:**
- Batch embedding generation for efficiency
- Cosine similarity for retrieval
- Connection pooling and reuse

### 5. Vector Database (`zvdb/`)
Custom HNSW implementation:
- Fast approximate nearest neighbor search
- Rich metadata (node types, file paths, descriptions)
- Typed edges between entities
- Persistence: `.localharness/graphrag.zvdb`

### 6. Query Engine (`graphrag/query.zig`)
`summarizeFileForHistory()` retrieves compressed summaries:
- Ranks entities by importance (public > private, functions > sections)
- Returns top-K chunks (default: 5)
- Includes relationships for context
- Fallback to simple preview if not indexed

## Data Flow

```
1. User: "What does config.zig do?"
   ↓
2. LLM calls read_file("config.zig")
   ↓
3. Tool executes:
   - Read file (344 lines)
   - Format with line numbers
   - Queue file path + content
   - Return full content immediately
   ↓
4. LLM responds with full context
   ↓
5. Response complete, trigger secondary loop
   ↓
6. processQueuedFiles() runs:
   - For each queued file:
     a. Call LLM indexer with file content
     b. LLM creates nodes (iteration 1)
     c. LLM creates edges (iteration 2)
     d. Generate embeddings
     e. Store in vector DB
     f. Mark file as indexed
   ↓
7. User: "Update the model setting"
   ↓
8. compressHistoryWithGraphRAG():
   - Check if config.zig was indexed
   - Call summarizeFileForHistory()
   - Replace 344 lines with ~5 entity summaries
   - LLM sees compressed context
```

## Compression Example

**Before (344 lines):**
```
1→  pub const Config = struct {
2→      model: []const u8 = "llama3.2",
3→      ollama_host: []const u8 = "http://localhost:11434",
...
344→  };
```

**After (5 entities):**
```
### Config (struct) [public]
Application configuration
Relationships: imports ConfigFile

### loadConfigFromFile (function) [public]
Loads config from JSON
Relationships: returns Config

### model (field) [public]
Ollama model name
...
```

**Result:** ~95% token reduction while preserving semantic meaning.

## Integration Points

### Read File Tool (`tools/read_file.zig`)
```zig
// After reading file
if (context.indexing_queue) |queue| {
    queue.enqueue(file_path, content);
}
```

### App Main Loop (`app.zig`)
```zig
// After response completes
if (!has_more_tool_calls) {
    processQueuedFiles();
}
```

### History Compression (`app.zig`)
```zig
// Before sending to LLM
for (messages) |msg| {
    if (msg.tool_result and state.wasFileIndexed(file)) {
        compressed = summarizeFileForHistory(file);
        // Use compressed instead of full content
    }
}
```

## Configuration

Enable in `~/.config/localharness/config.json` or via `/config` command:
```json
{
  "graph_rag_enabled": true,
  "embedding_model": "nomic-embed-text",
  "indexing_model": "llama3.1:8b",
  "max_chunks_in_history": 5,
  "zvdb_path": ".localharness/graphrag.zvdb"
}
```

**Provider Support:**
- Both Ollama and LM Studio are supported for embeddings
- Set `provider: "ollama"` or `provider: "lmstudio"` to choose
- Embedding and indexing models work with both providers

**Model Name Formats:**
- **Ollama**: `"embedding_model": "nomic-embed-text"`
- **LM Studio**: `"embedding_model": "text-embedding-nomic-embed-text-v1.5"`
- App validates format at startup

## Performance

**First read:**
- Returns immediately with full content
- Queues for background indexing

**Indexing (background):**
- ~5-10s per file (depends on size, model speed)
- Non-blocking, happens after response

**Later references:**
- Instant retrieval from vector DB
- 90-95% token reduction
- Semantic meaning preserved

## Benefits

1. **Context window efficiency:** Fit 10x more files in history
2. **Semantic preservation:** Relationships maintained
3. **Non-blocking:** Main loop stays fast
4. **Progressive:** Works without GraphRAG enabled

## Limitations

- Requires two separate models (main + indexing + embedding)
- First read doesn't benefit (full content returned)
- Vector DB grows with indexed files (~1-5MB per file)
- Only compresses files marked as indexed
- LM Studio users must: download BERT model, load in UI, use `text-embedding-` prefix
- Phase 1 context not passed to Phase 2 (independent contexts for efficiency)

## See Also

- [Features Guide](../user-guide/features.md#graphrag-context-compression)
- [Configuration Guide](../user-guide/configuration.md#graphrag-settings)
- [Architecture Overview](overview.md#graphrag-architecture-implemented)
