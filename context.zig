// Application context for tool execution
// Phase 1: Provides config and state access
// Phase 2+: Will include graph RAG, vector store, embeddings, code parser
const std = @import("std");
const state_module = @import("state.zig");
const config_module = @import("config.zig");

pub const AppContext = struct {
    allocator: std.mem.Allocator,
    config: *const config_module.Config,
    state: *state_module.AppState,

    // Future (Phase 2+): Graph RAG components
    // graph: ?*ContextGraph = null,
    // vector_store: ?*VectorStore = null,
    // embedder: ?*EmbeddingsClient = null,
    // parser: ?*CodeParser = null,
};
