// Application context for tool execution
const std = @import("std");
const state_module = @import("state.zig");
const config_module = @import("config.zig");
const zvdb = @import("zvdb/src/zvdb.zig");
const embedder_interface = @import("embedder_interface.zig");
const ollama = @import("ollama.zig");
const llm_provider_module = @import("llm_provider.zig");
const types = @import("types.zig");
const IndexingQueue = @import("graphrag/indexing_queue.zig").IndexingQueue;
const agents_module = @import("agents.zig");
const ProgressUpdateType = agents_module.ProgressUpdateType;

pub const AppContext = struct {
    allocator: std.mem.Allocator,
    config: *const config_module.Config,
    state: *state_module.AppState,
    llm_provider: *llm_provider_module.LLMProvider,

    // Graph RAG components (optional - initialized if graph_rag_enabled)
    vector_store: ?*zvdb.HNSW(f32) = null,
    embedder: ?*embedder_interface.Embedder = null, // Generic interface - works with both Ollama and LM Studio
    indexing_queue: ?*IndexingQueue = null,

    // Agent system (optional - only present if agents enabled)
    agent_registry: ?*agents_module.AgentRegistry = null,

    // Recent conversation messages for context-aware tools
    // Populated before tool execution, null otherwise
    // Tools can use this to understand what the user is asking about
    recent_messages: ?[]const types.Message = null,

    // Agent progress callback for real-time streaming
    // Set by app.zig before executing agent-powered tools
    // Allows sub-agents (like file curator) to stream progress to UI
    agent_progress_callback: ?*const fn (?*anyopaque, ProgressUpdateType, []const u8) void = null,
    agent_progress_user_data: ?*anyopaque = null,
};
