// Agent System - Core abstractions for isolated LLM sub-tasks
const std = @import("std");
const ollama = @import("ollama.zig");
const config_module = @import("config.zig");
const tools_module = @import("tools.zig");
const zvdb = @import("zvdb/src/zvdb.zig");
const embeddings_module = @import("embeddings.zig");

/// Progress update callback function type (shared with GraphRAG)
pub const ProgressCallback = *const fn (user_data: ?*anyopaque, update_type: ProgressUpdateType, message: []const u8) void;

/// Types of progress updates during agent execution
pub const ProgressUpdateType = enum {
    thinking,   // Agent LLM is thinking
    content,    // Agent LLM produced text content
    tool_call,  // Agent made a tool call
    iteration,  // Agent starting new iteration
    complete,   // Agent finished
};

/// Agent capability and resource limits
pub const AgentCapabilities = struct {
    /// Which tools this agent is allowed to use (by name)
    allowed_tools: []const []const u8,

    /// Maximum iterations before agent must terminate
    max_iterations: usize,

    /// Override model (use different/smaller model than main app)
    model_override: ?[]const u8 = null,

    /// Temperature for LLM sampling (0.0 = deterministic, 1.0 = creative)
    temperature: f32 = 0.7,

    /// Context window size override
    num_ctx: ?usize = null,

    /// Max tokens to predict (-1 = unlimited, positive = limit)
    num_predict: isize = -1,

    /// Enable extended thinking for this agent
    enable_thinking: bool = false,
};

/// Execution context provided to agents (controlled subset of AppContext)
pub const AgentContext = struct {
    allocator: std.mem.Allocator,
    ollama_client: *ollama.OllamaClient,
    config: *const config_module.Config,
    capabilities: AgentCapabilities,

    // Optional resources - only provided if agent needs them
    vector_store: ?*zvdb.HNSW(f32) = null,
    embedder: ?*embeddings_module.EmbeddingsClient = null,

    // Optional conversation history for context-aware agents
    // Contains recent messages from main conversation to help agents
    // understand what the user is asking about
    recent_messages: ?[]const @import("types.zig").Message = null,
};

/// Statistics about agent execution
pub const AgentStats = struct {
    iterations_used: usize,
    tool_calls_made: usize,
    tokens_used: usize = 0,
    execution_time_ms: i64,
};

/// Result returned by agent execution
pub const AgentResult = struct {
    success: bool,

    /// Main result data (JSON string or plain text)
    data: ?[]const u8,

    /// Structured metadata (optional, parsed JSON)
    metadata: ?std.json.Value = null,

    /// Error message if success = false
    error_message: ?[]const u8 = null,

    /// Execution statistics
    stats: AgentStats,

    /// Helper to create success result
    pub fn ok(allocator: std.mem.Allocator, data: []const u8, stats: AgentStats) !AgentResult {
        return .{
            .success = true,
            .data = try allocator.dupe(u8, data),
            .error_message = null,
            .stats = stats,
        };
    }

    /// Helper to create error result
    pub fn err(allocator: std.mem.Allocator, error_msg: []const u8, stats: AgentStats) !AgentResult {
        return .{
            .success = false,
            .data = null,
            .error_message = try allocator.dupe(u8, error_msg),
            .stats = stats,
        };
    }

    /// Free all owned memory
    pub fn deinit(self: *AgentResult, allocator: std.mem.Allocator) void {
        if (self.data) |data| {
            allocator.free(data);
        }
        if (self.error_message) |msg| {
            allocator.free(msg);
        }
        if (self.metadata) |_| {
            // metadata is a std.json.Value, we'll handle this in agent_executor
            // when we actually parse JSON
        }
    }
};

/// Agent definition - describes what the agent does and how to run it
pub const AgentDefinition = struct {
    /// Unique name for this agent
    name: []const u8,

    /// Human-readable description
    description: []const u8,

    /// System prompt that guides the agent's behavior
    system_prompt: []const u8,

    /// Capabilities and resource limits
    capabilities: AgentCapabilities,

    /// Main execution function
    /// - allocator: Memory allocator
    /// - context: Execution context with resources
    /// - task: Task description/input for the agent
    /// - progress_callback: Optional callback for progress updates
    /// - callback_user_data: User data passed to progress callback
    execute: *const fn (
        allocator: std.mem.Allocator,
        context: AgentContext,
        task: []const u8,
        progress_callback: ?ProgressCallback,
        callback_user_data: ?*anyopaque,
    ) anyerror!AgentResult,
};

/// Agent registry for looking up agents by name
pub const AgentRegistry = struct {
    allocator: std.mem.Allocator,
    agents: std.StringHashMapUnmanaged(AgentDefinition),

    pub fn init(allocator: std.mem.Allocator) AgentRegistry {
        return .{
            .allocator = allocator,
            .agents = .{},
        };
    }

    pub fn deinit(self: *AgentRegistry) void {
        self.agents.deinit(self.allocator);
    }

    /// Register an agent
    pub fn register(self: *AgentRegistry, definition: AgentDefinition) !void {
        try self.agents.put(self.allocator, definition.name, definition);
    }

    /// Get an agent by name
    pub fn get(self: *const AgentRegistry, name: []const u8) ?AgentDefinition {
        return self.agents.get(name);
    }

    /// Check if agent exists
    pub fn has(self: *const AgentRegistry, name: []const u8) bool {
        return self.agents.contains(name);
    }
};
