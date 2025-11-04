// Application context for tool execution
const std = @import("std");
const state_module = @import("state");
const config_module = @import("config");
const zvdb = @import("zvdb");
const embedder_interface = @import("embedder_interface");
const llm_provider_module = @import("llm_provider");
const types = @import("types");
const agents_module = @import("agents");
const ProgressUpdateType = agents_module.ProgressUpdateType;

// Context management
const tracking = @import("tracking");

pub const AppContext = struct{
    allocator: std.mem.Allocator,
    config: *const config_module.Config,
    state: *state_module.AppState,
    llm_provider: *llm_provider_module.LLMProvider,

    // Vector DB components (kept for future semantic search)
    vector_store: ?*zvdb.HNSW(f32) = null,
    embedder: ?*embedder_interface.Embedder = null, // Generic interface - works with both Ollama and LM Studio

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

    // Context management (Phase 1)
    context_tracker: ?*tracking.ContextTracker = null,

    // Mutable messages list for compression tools
    // Allows compression agent tools to modify conversation history
    messages_list: ?*anyopaque = null, // *std.ArrayListUnmanaged(Message) - using anyopaque to avoid circular import
};
