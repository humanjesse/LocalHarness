// Application context for tool execution
const std = @import("std");
const state_module = @import("state.zig");
const config_module = @import("config.zig");
const zvdb = @import("zvdb/src/zvdb.zig");
const embeddings = @import("embeddings.zig");
const ollama = @import("ollama.zig");
const types = @import("types.zig");
const IndexingQueue = @import("graphrag/indexing_queue.zig").IndexingQueue;

pub const AppContext = struct {
    allocator: std.mem.Allocator,
    config: *const config_module.Config,
    state: *state_module.AppState,
    ollama_client: *ollama.OllamaClient,

    // Graph RAG components (optional - initialized if graph_rag_enabled)
    vector_store: ?*zvdb.HNSW(f32) = null,
    embedder: ?*embeddings.EmbeddingsClient = null,
    indexing_queue: ?*IndexingQueue = null,

    // Recent conversation messages for context-aware tools
    // Populated before tool execution, null otherwise
    // Tools can use this to understand what the user is asking about
    recent_messages: ?[]const types.Message = null,
};
