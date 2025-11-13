// Application logic - App struct and all related methods
const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const json = std.json;
const process = std.process;
const ui = @import("ui");
const markdown = @import("markdown");
const ollama = @import("ollama");
const llm_provider_module = @import("llm_provider");
const permission = @import("permission");
const tools_module = @import("tools");
const types = @import("types");
const state_module = @import("state");
const context_module = @import("context");
const config_module = @import("config");
const render = @import("render");
const message_renderer = @import("message_renderer");
const tool_executor_module = @import("tool_executor");
const zvdb = @import("zvdb");
const embeddings_module = @import("embeddings");
const embedder_interface = @import("embedder_interface");
const lmstudio = @import("lmstudio");
pub const agents_module = @import("agents"); // Re-export for agent_loader and agent_executor
const config_editor_state = @import("config_editor_state");
const config_editor_renderer = @import("config_editor_renderer");
const config_editor_input = @import("config_editor_input");
const agent_loader = @import("agent_loader");
const agent_builder_state = @import("agent_builder_state");
const agent_builder_renderer = @import("agent_builder_renderer");
const agent_builder_input = @import("agent_builder_input");
const help_state = @import("help_state");
const help_renderer = @import("help_renderer");
const help_input = @import("help_input");
const profile_ui_state = @import("profile_ui_state");
const profile_ui_renderer = @import("profile_ui_renderer");
const profile_ui_input = @import("profile_ui_input");
const conversation_db_module = @import("conversation_db");

// Re-export types for convenience
pub const Message = types.Message;
pub const ClickableArea = types.ClickableArea;
pub const StreamChunk = types.StreamChunk;
pub const Config = config_module.Config;
pub const AppState = state_module.AppState;
pub const AppContext = context_module.AppContext;

// Thread function context for background streaming
const StreamThreadContext = struct {
    allocator: mem.Allocator,
    app: *App,
    llm_provider: *llm_provider_module.LLMProvider,
    model: []const u8,
    messages: []ollama.ChatMessage,
    format: ?[]const u8,
    tools: []const ollama.Tool,
    keep_alive: []const u8,
    num_ctx: usize,
    num_predict: isize,
};

// Agent progress context for streaming sub-agent progress to UI
// Now uses unified ProgressDisplayContext from agents.zig
const ProgressDisplayContext = agents_module.ProgressDisplayContext;

// Finalize agent message with nice formatting when agent completes
// Now uses unified finalization from message_renderer
fn finalizeAgentMessage(ctx: *ProgressDisplayContext) !void {
    return message_renderer.finalizeProgressMessage(ctx);
}

// Progress callback for sub-agents (e.g., file curator) - streams to UI in real-time
fn agentProgressCallback(user_data: ?*anyopaque, update_type: agents_module.ProgressUpdateType, message: []const u8) void {
    const ctx = @as(*ProgressDisplayContext, @ptrCast(@alignCast(user_data orelse return)));
    const allocator = ctx.app.allocator;

    // Accumulate the message content based on type
    switch (update_type) {
        .thinking => {
            ctx.thinking_buffer.appendSlice(allocator, message) catch return;
        },
        .content => {
            ctx.content_buffer.appendSlice(allocator, message) catch return;
        },
        .complete => {
            // Agent finished - finalize the message with nice formatting
            if (!ctx.finalized and ctx.current_message_idx != null) {
                ctx.finalized = true;
                finalizeAgentMessage(ctx) catch return;
                return;  // finalizeAgentMessage handles redraw
            }
        },
        .iteration, .tool_call => {
            // Status updates - could log these or show in UI
            // For now, just continue accumulating
        },
        .embedding, .storage => {
            // Embedding/storage updates not used in current architecture
            // Just ignore for agent callbacks
        },
    }

    // Find or create the progress message
    if (ctx.current_message_idx == null) {
        // Capture start time if not already set
        if (ctx.start_time == 0) {
            ctx.start_time = std.time.milliTimestamp();
        }

        // Create new system message for this agent progress
        // Start with simple message, will be formatted nicely on completion
        const display_content = allocator.dupe(u8, "🤔 Analyzing...") catch return;
        const content_processed = markdown.processMarkdown(allocator, display_content) catch return;

        // Duplicate task name for message
        const task_name_copy = allocator.dupe(u8, ctx.task_name) catch return;

        ctx.app.messages.append(allocator, .{
            .role = .display_only_data,
            .content = display_content,
            .processed_content = content_processed,
            .thinking_content = null,
            .processed_thinking_content = null,
            .thinking_expanded = false,
            .timestamp = std.time.milliTimestamp(),
            // Agent analysis metadata (NEW - for streaming + collapsible display)
            .agent_analysis_name = task_name_copy,
            .agent_analysis_expanded = true,  // Expanded during streaming (shows content)
            .agent_analysis_completed = false,  // Not done yet (no collapse button)
            // Keep tool_execution_time for display (but not using tool collapse)
            .tool_call_expanded = false,
            .tool_name = null,
            .tool_success = null,
            .tool_execution_time = null,  // Will be set on completion
        }) catch return;

        ctx.current_message_idx = ctx.app.messages.items.len - 1;
    } else {
        // Update existing message with streaming content
        const idx = ctx.current_message_idx.?;
        var msg = &ctx.app.messages.items[idx];

        // Free old content
        allocator.free(msg.content);
        for (msg.processed_content.items) |*item| {
            item.deinit(allocator);
        }
        msg.processed_content.deinit(allocator);

        if (msg.thinking_content) |tc| allocator.free(tc);
        if (msg.processed_thinking_content) |*ptc| {
            for (ptc.items) |*item| {
                item.deinit(allocator);
            }
            ptc.deinit(allocator);
        }

        // During streaming, just show raw accumulated content (thinking + content)
        var combined = std.ArrayListUnmanaged(u8){};
        defer combined.deinit(allocator);

        if (ctx.thinking_buffer.items.len > 0) {
            combined.appendSlice(allocator, ctx.thinking_buffer.items) catch return;
            if (ctx.content_buffer.items.len > 0) {
                combined.appendSlice(allocator, "\n\n") catch return;
            }
        }
        if (ctx.content_buffer.items.len > 0) {
            combined.appendSlice(allocator, ctx.content_buffer.items) catch return;
        }

        const display_content = if (combined.items.len > 0)
            allocator.dupe(u8, combined.items) catch return
        else
            allocator.dupe(u8, "🤔 Analyzing...") catch return;

        msg.content = display_content;
        msg.processed_content = markdown.processMarkdown(allocator, display_content) catch return;
        msg.thinking_content = null;
        msg.processed_thinking_content = null;
    }

    // Redraw screen to show progress
    _ = message_renderer.redrawScreen(ctx.app) catch return;
    ctx.app.updateCursorToBottom();
}

// Define available tools for the model
fn createTools(allocator: mem.Allocator) ![]const ollama.Tool {
    return try tools_module.getOllamaTools(allocator);
}

// Incremental rendering support structures
pub const MessageRenderInfo = struct {
    message_index: usize,
    y_start: usize,           // Absolute Y position where message starts
    y_end: usize,             // Absolute Y position where message ends
    height: usize,            // Total lines this message occupies
    content_hash: u64,        // Hash of message content for change detection (includes expansion states)
};

/// Simplified render cache - just tracks terminal size for resize detection
pub const RenderCache = struct {
    last_terminal_width: u16 = 0,
    last_terminal_height: u16 = 0,

    pub fn init() RenderCache {
        return .{};
    }

    pub fn deinit(self: *RenderCache, allocator: mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};


pub const App = struct {
    allocator: mem.Allocator,
    config: Config,
    messages: std.ArrayListUnmanaged(Message),
    llm_provider: llm_provider_module.LLMProvider,
    input_buffer: std.ArrayListUnmanaged(u8),
    clickable_areas: std.ArrayListUnmanaged(ClickableArea),
    scroll_y: usize = 0,
    cursor_y: usize = 1,
    terminal_size: ui.TerminalSize,
    valid_cursor_positions: std.ArrayListUnmanaged(usize),
    // Resize handling state
    resize_in_progress: bool = false,
    saved_expansion_states: std.ArrayListUnmanaged(bool),
    last_resize_time: i64 = 0,
    // Streaming state
    streaming_active: bool = false,
    stream_mutex: std.Thread.Mutex = .{},
    stream_chunks: std.ArrayListUnmanaged(StreamChunk) = .{},
    stream_thread: ?std.Thread = null,
    stream_thread_ctx: ?*StreamThreadContext = null,
    // Available tools for the model
    tools: []const ollama.Tool,
    // Tool execution state
    pending_tool_calls: ?[]ollama.ToolCall = null,
    tool_call_depth: usize = 0,
    max_tool_depth: usize = 15, // Max tools per iteration (increased for agentic tasks)
    // Permission system
    permission_manager: permission.PermissionManager,
    permission_pending: bool = false,
    permission_response: ?permission.PermissionMode = null, // Set by UI, consumed by tool_executor
    // Tool execution state machine
    tool_executor: tool_executor_module.ToolExecutor,
    // Phase 1: Task management state
    state: AppState,
    app_context: AppContext,
    max_iterations: usize = 10, // Master loop iteration limit
    // Auto-scroll state (receipt printer mode) - removed, now always auto-scrolls
    // Vector DB components (kept for future semantic search)
    vector_store: ?*zvdb.HNSW(f32) = null,
    embedder: ?*embedder_interface.Embedder = null, // Generic interface - works with both Ollama and LM Studio
    // Config editor state (modal mode)
    config_editor: ?config_editor_state.ConfigEditorState = null,
    // Agent system
    agent_registry: agents_module.AgentRegistry,
    agent_loader: agent_loader.AgentLoader,
    agent_builder: ?agent_builder_state.AgentBuilderState = null,
    // Help viewer state (modal mode)
    help_viewer: ?help_state.HelpState = null,
    // Profile manager state (modal mode)
    profile_ui: ?profile_ui_state.ProfileUIState = null,
    // Conversation persistence
    conversation_db: ?conversation_db_module.ConversationDB = null,
    current_conversation_id: ?i64 = null,

    // Incremental rendering state
    render_cache: RenderCache = RenderCache.init(),

    pub fn init(allocator: mem.Allocator, config: Config) !App {
        const tools = try createTools(allocator);

        // Initialize permission manager
        var perm_manager = try permission.PermissionManager.init(allocator, ".", null); // No audit log by default
        const tool_metadata = try tools_module.getPermissionMetadata(allocator);
        defer allocator.free(tool_metadata);
        try perm_manager.registerTools(tool_metadata);

        // Load saved policies from disk
        config_module.loadPolicies(allocator, &perm_manager) catch |err| {
            // Log error but don't fail - just continue with default policies
            std.debug.print("Warning: Failed to load policies: {}\n", .{err});
        };

        // Vector database components reserved for future semantic search
        // Currently disabled - can be re-enabled for semantic code search
        const vector_store_opt: ?*zvdb.HNSW(f32) = null;
        const embedder_opt: ?*embedder_interface.Embedder = null;

        // Create LLM provider based on config
        const provider = try llm_provider_module.createProvider(config.provider, allocator, config);

        // Initialize agent system
        var agent_registry = agents_module.AgentRegistry.init(allocator);
        errdefer agent_registry.deinit();

        var loader = agent_loader.AgentLoader.init(allocator, &agent_registry);
        errdefer loader.deinit();

        // Load all agents (native + markdown)
        try loader.loadAllAgents();

        var app = App{
            .allocator = allocator,
            .config = config,
            .messages = .{},
            .llm_provider = provider,
            .input_buffer = .{},
            .clickable_areas = .{},
            .terminal_size = try ui.Tui.getTerminalSize(),
            .valid_cursor_positions = .{},
            .saved_expansion_states = .{},
            .tools = tools,
            .permission_manager = perm_manager,
            .tool_executor = tool_executor_module.ToolExecutor.init(allocator),
            // Phase 1: Initialize state (session-ephemeral)
            .state = AppState.init(allocator),
            .app_context = undefined, // Will be fixed by caller after struct is in final location
            .vector_store = vector_store_opt,
            .embedder = embedder_opt,
            .agent_registry = agent_registry,
            .agent_loader = loader,
            .agent_builder = null,
        };

        // Initialize conversation database
        const home_dir = std.posix.getenv("HOME") orelse ".";
        const config_dir = try std.fmt.allocPrint(allocator, "{s}/.config/localharness", .{home_dir});
        defer allocator.free(config_dir);

        // Ensure config directory exists
        std.fs.makeDirAbsolute(config_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const db_path = try std.fmt.allocPrint(allocator, "{s}/conversations.db", .{config_dir});
        defer allocator.free(db_path);

        // Initialize database - fail fast if this fails
        const conv_db = try conversation_db_module.ConversationDB.init(allocator, db_path);
        app.conversation_db = conv_db;

        // Create conversation immediately on startup
        const profile_name = "default"; // TODO: Get from profile manager
        const conv_id = try app.conversation_db.?.createConversation(profile_name);
        app.current_conversation_id = conv_id;
        std.debug.print("Created new conversation: {}\n", .{conv_id});

        // Add system prompt (Position 0 - stable)
        const system_prompt = "You are a helpful coding assistant.";
        const system_processed = try markdown.processMarkdown(allocator, system_prompt);
        try app.messages.append(allocator, .{
            .role = .system,
            .content = try allocator.dupe(u8, system_prompt),
            .processed_content = system_processed,
            .thinking_expanded = true,
            .timestamp = std.time.milliTimestamp(),
        });

        // Persist system message immediately
        try app.persistMessage(app.messages.items.len - 1);

        return app;
    }

    // Fix context pointers after App is in its final location
    // MUST be called immediately after init() in main.zig
    pub fn fixContextPointers(self: *App) void {
        self.app_context = .{
            .allocator = self.allocator,
            .config = &self.config,
            .state = &self.state,
            .llm_provider = &self.llm_provider,
            .vector_store = self.vector_store,
            .embedder = self.embedder,
            .agent_registry = &self.agent_registry,
        };
    }

    // Persist a message to the database immediately
    // Fails fast if database persistence fails
    fn persistMessage(self: *App, message_index: usize) !void {
        // Conversation ID must exist (created in init)
        const conv_id = self.current_conversation_id orelse return error.NoConversation;

        // Database must be initialized
        if (self.conversation_db) |*db| {
            // Save message - fail fast if this fails
            const message = &self.messages.items[message_index];
            _ = try db.saveMessage(conv_id, @intCast(message_index), message);
        } else {
            return error.DatabaseNotInitialized;
        }
    }

    // Check if viewport is currently at the bottom
    fn isViewportAtBottom(self: *App) bool {
        if (self.valid_cursor_positions.items.len == 0) return true;

        const last_position = self.valid_cursor_positions.items[self.valid_cursor_positions.items.len - 1];
        return self.cursor_y == last_position;
    }

    // Pre-calculate and apply scroll position to keep viewport anchored at bottom
    // This should be called BEFORE redrawScreen() to avoid flashing

    // Update cursor to track bottom position after redraw
    pub fn updateCursorToBottom(self: *App) void {
        if (self.valid_cursor_positions.items.len > 0) {
            self.cursor_y = self.valid_cursor_positions.items[self.valid_cursor_positions.items.len - 1];
        }
    }


    fn streamingThreadFn(ctx: *StreamThreadContext) void {
        // Callback that adds chunks to the queue
        const ChunkCallback = struct {
            fn callback(chunk_ctx: *StreamThreadContext, thinking_chunk: ?[]const u8, content_chunk: ?[]const u8, tool_calls_chunk: ?[]const ollama.ToolCall) void {
                chunk_ctx.app.stream_mutex.lock();
                defer chunk_ctx.app.stream_mutex.unlock();

                // Free tool_calls_chunk after processing (we take ownership from ollama.zig)
                defer if (tool_calls_chunk) |calls| {
                    for (calls) |call| {
                        if (call.id) |id| chunk_ctx.allocator.free(id);
                        if (call.type) |t| chunk_ctx.allocator.free(t);
                        chunk_ctx.allocator.free(call.function.name);
                        chunk_ctx.allocator.free(call.function.arguments);
                    }
                    chunk_ctx.allocator.free(calls);
                };

                // Create a chunk and add to queue
                const chunk = StreamChunk{
                    .thinking = if (thinking_chunk) |t| chunk_ctx.allocator.dupe(u8, t) catch null else null,
                    .content = if (content_chunk) |c| chunk_ctx.allocator.dupe(u8, c) catch null else null,
                    .done = false,
                };
                chunk_ctx.app.stream_chunks.append(chunk_ctx.allocator, chunk) catch return;

                // Store tool calls for execution after streaming completes
                if (tool_calls_chunk) |calls| {
                    // Duplicate the tool calls to keep them after streaming
                    const owned_calls = chunk_ctx.allocator.alloc(ollama.ToolCall, calls.len) catch return;
                    for (calls, 0..) |call, i| {
                        // Generate ID if not provided by model
                        const call_id = if (call.id) |id|
                            chunk_ctx.allocator.dupe(u8, id) catch return
                        else
                            std.fmt.allocPrint(chunk_ctx.allocator, "call_{d}", .{i}) catch return;

                        // Use "function" as default type if not provided
                        const call_type = if (call.type) |t|
                            chunk_ctx.allocator.dupe(u8, t) catch return
                        else
                            chunk_ctx.allocator.dupe(u8, "function") catch return;

                        owned_calls[i] = ollama.ToolCall{
                            .id = call_id,
                            .type = call_type,
                            .function = .{
                                .name = chunk_ctx.allocator.dupe(u8, call.function.name) catch return,
                                .arguments = chunk_ctx.allocator.dupe(u8, call.function.arguments) catch return,
                            },
                        };
                    }
                    chunk_ctx.app.pending_tool_calls = owned_calls;
                }
            }
        };

        // Get provider capabilities to check what's supported
        const caps = ctx.llm_provider.getCapabilities();

        // Only enable thinking if both config and provider support it
        const enable_thinking = ctx.app.config.enable_thinking and caps.supports_thinking;

        // Only pass keep_alive if provider supports it
        const keep_alive = if (caps.supports_keep_alive) ctx.keep_alive else null;

        // Run the streaming with retry logic for stale connections
        ctx.llm_provider.chatStream(
            ctx.model,
            ctx.messages,
            enable_thinking, // Capability-aware thinking mode
            ctx.format,
            if (ctx.tools.len > 0) ctx.tools else null, // Pass tools to model
            keep_alive, // Capability-aware keep_alive
            ctx.num_ctx,
            ctx.num_predict,
            null, // temperature - use model default for main chat
            null, // repeat_penalty - use model default for main chat
            ctx,
            ChunkCallback.callback,
        ) catch |err| {
            // Handle stale connection errors with retry
            if (err == error.EndOfStream or err == error.ConnectionResetByPeer) {
                // Send retry message to user
                ctx.app.stream_mutex.lock();
                const retry_msg = std.fmt.allocPrint(
                    ctx.allocator,
                    "Connection failed: {s} - Retrying...",
                    .{@errorName(err)},
                ) catch "Connection failed - Retrying...";
                const retry_chunk = StreamChunk{ .thinking = null, .content = retry_msg, .done = false };
                ctx.app.stream_chunks.append(ctx.allocator, retry_chunk) catch {};
                ctx.app.stream_mutex.unlock();

                // Note: Provider-level retry not implemented yet
                // Different providers may have different retry strategies

                // Small delay before retry
                std.Thread.sleep(100 * std.time.ns_per_ms);

                // Retry the request (reuse capability checks from above)
                ctx.llm_provider.chatStream(
                    ctx.model,
                    ctx.messages,
                    enable_thinking, // Use capability-aware value
                    ctx.format,
                    if (ctx.tools.len > 0) ctx.tools else null,
                    keep_alive, // Use capability-aware value
                    ctx.num_ctx,
                    ctx.num_predict,
                    null, // temperature - use model default for main chat
                    null, // repeat_penalty - use model default for main chat
                    ctx,
                    ChunkCallback.callback,
                ) catch |retry_err| {
                    // Second failure - report error to user
                    ctx.app.stream_mutex.lock();
                    const error_msg = std.fmt.allocPrint(
                        ctx.allocator,
                        "Failed to connect to Ollama: {s}",
                        .{@errorName(retry_err)},
                    ) catch "Failed to connect to Ollama";
                    const error_chunk = StreamChunk{ .thinking = null, .content = error_msg, .done = false };
                    ctx.app.stream_chunks.append(ctx.allocator, error_chunk) catch {};
                    ctx.app.stream_mutex.unlock();
                };
            } else {
                // Other errors - report directly to user
                ctx.app.stream_mutex.lock();
                const error_msg = std.fmt.allocPrint(
                    ctx.allocator,
                    "Connection error: {s}",
                    .{@errorName(err)},
                ) catch "Connection error occurred";
                const error_chunk = StreamChunk{ .thinking = null, .content = error_msg, .done = false };
                ctx.app.stream_chunks.append(ctx.allocator, error_chunk) catch {};
                ctx.app.stream_mutex.unlock();
            }
        };

        // ALWAYS add a "done" chunk, even if chatStream failed
        // This ensures streaming_active gets set to false
        ctx.app.stream_mutex.lock();
        defer ctx.app.stream_mutex.unlock();
        const done_chunk = StreamChunk{ .thinking = null, .content = null, .done = true };
        ctx.app.stream_chunks.append(ctx.allocator, done_chunk) catch return;
    }


    // Compress message history by replacing read_file results with Graph RAG summaries
    // REMOVED: GraphRAG compression no longer needed
    // Curator caching handles this better - instant cache hits for same conversation context

    // Internal method to start streaming with current message history
    fn startStreaming(self: *App, format: ?[]const u8) !void {
        // Set streaming flag FIRST - before any redraws
        // This ensures the status bar shows "AI is responding..." immediately
        self.streaming_active = true;

        // Reset tool call depth when starting a new user message
        // (This will be set correctly by continueStreaming for tool calls)

        // Copy messages to ollama_messages
        var ollama_messages = std.ArrayListUnmanaged(ollama.ChatMessage){};
        defer ollama_messages.deinit(self.allocator);

        for (self.messages.items) |msg| {
            // Skip display_only_data messages - they're UI-only notifications
            if (msg.role == .display_only_data) continue;

            const role_str = switch (msg.role) {
                .user => "user",
                .assistant => "assistant",
                .system => "system",
                .tool => "tool",
                .display_only_data => unreachable, // Already filtered above
            };
            try ollama_messages.append(self.allocator, .{
                .role = role_str,
                .content = msg.content,
                .tool_call_id = msg.tool_call_id,
                .tool_calls = msg.tool_calls,
            });
        }

        // DEBUG: Print what we're sending to the API
        if (std.posix.getenv("DEBUG_TOOLS")) |_| {
            std.debug.print("\n=== DEBUG: Sending {d} messages to API ===\n", .{ollama_messages.items.len});
            for (ollama_messages.items, 0..) |msg, i| {
                std.debug.print("[{d}] role={s}", .{i, msg.role});
                if (msg.tool_calls) |_| std.debug.print(" [HAS_TOOL_CALLS]", .{});
                if (msg.tool_call_id) |id| std.debug.print(" [tool_call_id={s}]", .{id});
                std.debug.print("\n", .{});

                const preview_len = @min(msg.content.len, 80);
                std.debug.print("    content: {s}{s}\n", .{
                    msg.content[0..preview_len],
                    if (msg.content.len > 80) "..." else "",
                });
            }
            std.debug.print("=== END DEBUG ===\n\n", .{});
        }

        // Create placeholder for assistant response (empty initially)
        const assistant_content = try self.allocator.dupe(u8, "");
        const assistant_processed = try markdown.processMarkdown(self.allocator, assistant_content);
        try self.messages.append(self.allocator, .{
            .role = .assistant,
            .content = assistant_content,
            .processed_content = assistant_processed,
            .thinking_content = null,
            .processed_thinking_content = null,
            .thinking_expanded = true,
            .timestamp = std.time.milliTimestamp(),
        });

        // Mark all dirty - new message changes layout
        // Removed dirty state tracking - rendering is now always automatic

        // Redraw to show empty placeholder (receipt printer mode)
        _ = try message_renderer.redrawScreen(self);
        self.updateCursorToBottom();

        // Prepare thread context
        const messages_slice = try ollama_messages.toOwnedSlice(self.allocator);

        const thread_ctx = try self.allocator.create(StreamThreadContext);
        thread_ctx.* = .{
            .allocator = self.allocator,
            .app = self,
            .llm_provider = &self.llm_provider,
            .model = self.config.model,
            .messages = messages_slice,
            .format = format,
            .tools = self.tools,
            .keep_alive = self.config.model_keep_alive,
            .num_ctx = self.config.num_ctx,
            .num_predict = self.config.num_predict,
        };

        // Start streaming in background thread
        self.stream_thread_ctx = thread_ctx;
        self.stream_thread = try std.Thread.spawn(.{}, streamingThreadFn, .{thread_ctx});
    }

    // Send a message and get streaming response from Ollama (non-blocking)
    pub fn sendMessage(self: *App, user_text: []const u8, format: ?[]const u8) !void {
        // Reset tool call depth for new user messages
        self.tool_call_depth = 0;

        // Phase 1: Reset iteration count for new user messages (master loop)
        self.state.iteration_count = 0;

        // Reset auto-scroll state - no longer needed, now always auto-scrolls

        // 1. Add user message
        const user_content = try self.allocator.dupe(u8, user_text);
        const user_processed = try markdown.processMarkdown(self.allocator, user_content);

        try self.messages.append(self.allocator, .{
            .role = .user,
            .content = user_content,
            .processed_content = user_processed,
            .thinking_expanded = true,
            .timestamp = std.time.milliTimestamp(),
        });

        // Persist user message immediately
        try self.persistMessage(self.messages.items.len - 1);

        // Mark all dirty - new message changes layout
        // Removed dirty state tracking - rendering is now always automatic

        // Show user message right away (receipt printer mode)
        _ = try message_renderer.redrawScreen(self);

        // 2. Start streaming
        try self.startStreaming(format);
    }

    // Helper function to show permission prompt (non-blocking)
    fn showPermissionPrompt(
        self: *App,
        tool_call: ollama.ToolCall,
        eval_result: permission.PolicyEngine.EvaluationResult,
    ) !void {
        // Create permission request message
        const prompt_text = try std.fmt.allocPrint(
            self.allocator,
            "Permission requested for tool: {s}",
            .{tool_call.function.name},
        );
        const prompt_processed = try markdown.processMarkdown(self.allocator, prompt_text);

        // Duplicate tool call for storage in message
        const stored_tool_call = ollama.ToolCall{
            .id = if (tool_call.id) |id| try self.allocator.dupe(u8, id) else null,
            .type = if (tool_call.type) |t| try self.allocator.dupe(u8, t) else null,
            .function = .{
                .name = try self.allocator.dupe(u8, tool_call.function.name),
                .arguments = try self.allocator.dupe(u8, tool_call.function.arguments),
            },
        };

        try self.messages.append(self.allocator, .{
            .role = .display_only_data,
            .content = prompt_text,
            .processed_content = prompt_processed,
            .thinking_expanded = false,
            .timestamp = std.time.milliTimestamp(),
            .permission_request = .{
                .tool_call = stored_tool_call,
                .eval_result = .{
                    .allowed = eval_result.allowed,
                    .reason = try self.allocator.dupe(u8, eval_result.reason),
                    .ask_user = eval_result.ask_user,
                    .show_preview = eval_result.show_preview,
                },
                .timestamp = std.time.milliTimestamp(),
            },
        });

        // Persist permission request immediately
        try self.persistMessage(self.messages.items.len - 1);

        // Set permission pending state (non-blocking - main loop will handle response)
        self.permission_pending = true;
        self.permission_response = null;
    }

    // Execute a tool call and return the result (Phase 1: passes AppContext)
    fn executeTool(self: *App, tool_call: ollama.ToolCall) !tools_module.ToolResult {
        // Populate conversation context for context-aware tools
        // Extract last 5 messages (or fewer if conversation is shorter)
        const start_idx = if (self.messages.items.len > 5)
            self.messages.items.len - 5
        else
            0;

        // IMPORTANT: Allocate a COPY of the messages slice to avoid use-after-free
        // During tool execution, self.messages may grow and reallocate its backing buffer
        // This would invalidate any slice pointing into the old buffer
        const messages_copy = try self.allocator.dupe(types.Message, self.messages.items[start_idx..]);
        self.app_context.recent_messages = messages_copy;
        defer self.allocator.free(messages_copy);

        // Set up agent progress streaming for sub-agents (like file curator)
        var agent_progress_ctx = ProgressDisplayContext{
            .app = self,
            .task_name = try self.allocator.dupe(u8, "Agent Analysis"), // Generic default (will be updated by run_agent tool)
            .task_icon = "🤔", // Default icon for file analysis
            .start_time = std.time.milliTimestamp(), // Start tracking execution time
        };
        defer agent_progress_ctx.thinking_buffer.deinit(self.allocator);
        defer agent_progress_ctx.content_buffer.deinit(self.allocator);
        defer self.allocator.free(agent_progress_ctx.task_name);

        self.app_context.agent_progress_callback = agentProgressCallback;
        self.app_context.agent_progress_user_data = &agent_progress_ctx;

        // Execute tool with conversation context and progress streaming
        const result = try tools_module.executeToolCall(self.allocator, tool_call, &self.app_context);

        // Note: Progress message is kept as permanent "Agent Analysis" message
        // It was already finalized by the progress callback when agent completed

        // Clear conversation context and progress callback after use
        self.app_context.recent_messages = null;
        self.app_context.agent_progress_callback = null;
        self.app_context.agent_progress_user_data = null;

        return result;
    }


    pub fn deinit(self: *App) void {
        // GraphRAG indexing queue removed - context queue handles async tasks now

        // Wait for streaming thread to finish if active
        if (self.stream_thread) |thread| {
            thread.join();
        }

        // Clean up thread context if it exists
        if (self.stream_thread_ctx) |ctx| {
            // Note: msg.role and msg.content are NOT owned by the context
            // They are pointers to existing message data, so we only free the array
            self.allocator.free(ctx.messages);

            self.allocator.destroy(ctx);
        }

        // Clean up stream chunks
        for (self.stream_chunks.items) |chunk| {
            if (chunk.thinking) |t| self.allocator.free(t);
            if (chunk.content) |c| self.allocator.free(c);
        }
        self.stream_chunks.deinit(self.allocator);

        for (self.messages.items) |*message| {
            self.allocator.free(message.content);
            for (message.processed_content.items) |*item| {
                item.deinit(self.allocator);
            }
            message.processed_content.deinit(self.allocator);

            // Clean up thinking content if present
            if (message.thinking_content) |thinking| {
                self.allocator.free(thinking);
            }
            if (message.processed_thinking_content) |*thinking_processed| {
                for (thinking_processed.items) |*item| {
                    item.deinit(self.allocator);
                }
                thinking_processed.deinit(self.allocator);
            }

            // Clean up tool calling fields
            if (message.tool_calls) |calls| {
                for (calls) |call| {
                    if (call.id) |id| self.allocator.free(id);
                    if (call.type) |call_type| self.allocator.free(call_type);
                    self.allocator.free(call.function.name);
                    self.allocator.free(call.function.arguments);
                }
                self.allocator.free(calls);
            }
            if (message.tool_call_id) |id| {
                self.allocator.free(id);
            }

            // Clean up permission request if present
            if (message.permission_request) |perm_req| {
                if (perm_req.tool_call.id) |id| self.allocator.free(id);
                if (perm_req.tool_call.type) |call_type| self.allocator.free(call_type);
                self.allocator.free(perm_req.tool_call.function.name);
                self.allocator.free(perm_req.tool_call.function.arguments);
                self.allocator.free(perm_req.eval_result.reason);
            }

            // Clean up tool execution metadata
            if (message.tool_name) |name| {
                self.allocator.free(name);
            }

            // Clean up agent analysis metadata
            if (message.agent_analysis_name) |name| {
                self.allocator.free(name);
            }
        }
        self.messages.deinit(self.allocator);
        self.llm_provider.deinit();
        self.input_buffer.deinit(self.allocator);
        self.clickable_areas.deinit(self.allocator);
        self.valid_cursor_positions.deinit(self.allocator);
        self.saved_expansion_states.deinit(self.allocator);

        // Clean up tools
        for (self.tools) |tool| {
            self.allocator.free(tool.function.name);
            self.allocator.free(tool.function.description);
            self.allocator.free(tool.function.parameters);
        }
        self.allocator.free(self.tools);

        // Clean up pending tool calls if any
        if (self.pending_tool_calls) |calls| {
            for (calls) |call| {
                if (call.id) |id| self.allocator.free(id);
                if (call.type) |call_type| self.allocator.free(call_type);
                self.allocator.free(call.function.name);
                self.allocator.free(call.function.arguments);
            }
            self.allocator.free(calls);
        }

        // Clean up permission manager
        self.permission_manager.deinit();

        // Clean up tool executor
        self.tool_executor.deinit();

        // Phase 1: Clean up state
        self.state.deinit();

        // Clean up Graph RAG components (session-only, not persisted)
        if (self.vector_store) |vs| {
            vs.deinit();
            self.allocator.destroy(vs);
        }

        if (self.embedder) |emb| {
            // Clean up the underlying client first
            switch (emb.*) {
                .ollama => |client| {
                    client.deinit();
                    self.allocator.destroy(client);
                },
                .lmstudio => |client| {
                    client.deinit();
                    self.allocator.destroy(client);
                },
            }
            // Then destroy the embedder wrapper
            self.allocator.destroy(emb);
        }

        // Clean up config editor if active
        if (self.config_editor) |*editor| {
            editor.deinit();
        }

        // Clean up agent builder if active
        if (self.agent_builder) |*builder| {
            builder.deinit();
        }

        // Clean up help viewer if active
        if (self.help_viewer) |*viewer| {
            viewer.deinit();
        }

        // Clean up profile UI if active
        if (self.profile_ui) |*profile_ui| {
            profile_ui.deinit();
        }

        // Clean up conversation database
        if (self.conversation_db) |*db| {
            db.deinit();
        }

        // Clean up agent system
        self.agent_loader.deinit();
        self.agent_registry.deinit();

        // Clean up incremental rendering state
        self.render_cache.deinit(self.allocator);

        // Clean up config (App owns it)
        self.config.deinit(self.allocator);
    }





    pub fn run(self: *App, app_tui: *ui.Tui) !void {
        _ = app_tui; // Will be used later for editor integration

        // Buffers for accumulating stream data
        var thinking_accumulator = std.ArrayListUnmanaged(u8){};
        defer thinking_accumulator.deinit(self.allocator);
        var content_accumulator = std.ArrayListUnmanaged(u8){};
        defer content_accumulator.deinit(self.allocator);

        while (true) {
            // CONFIG EDITOR MODE (modal - takes priority over normal app)
            if (self.config_editor) |*editor| {
                // Render editor (renderer will clear screen)
                var stdout_buffer: [8192]u8 = undefined;
                var buffered_writer = ui.BufferedStdoutWriter.init(&stdout_buffer);
                const writer = buffered_writer.writer();

                try config_editor_renderer.render(
                    editor,
                    writer,
                    self.terminal_size.width,
                    self.terminal_size.height,
                );
                try buffered_writer.flush();

                // Wait for input (blocking)
                var read_buffer: [128]u8 = undefined;
                const bytes_read = ui.c.read(ui.c.STDIN_FILENO, &read_buffer, read_buffer.len);

                if (bytes_read > 0) {
                    const input = read_buffer[0..@intCast(bytes_read)];
                    const result = try config_editor_input.handleInput(editor, input);

                    switch (result) {
                        .save_and_close => {
                            // Validate config before saving
                            editor.temp_config.validate() catch |err| {
                                std.debug.print("\n⚠ Config validation warning: {s}\n", .{@errorName(err)});
                                std.debug.print("   Saving anyway, but please review your settings.\n\n", .{});
                            };

                            // Check if profile name changed
                            const profile_manager = @import("profile_manager");
                            const original_profile = try profile_manager.getActiveProfileName(self.allocator);
                            defer self.allocator.free(original_profile);

                            var profile_changed = !std.mem.eql(u8, editor.profile_name, original_profile);

                            // If profile name changed, validate it
                            if (profile_changed) {
                                if (!profile_manager.validateProfileName(editor.profile_name)) {
                                    std.debug.print("\n⚠ Invalid profile name: '{s}'\n", .{editor.profile_name});
                                    std.debug.print("   Profile names must be alphanumeric with dashes/underscores only.\n", .{});
                                    std.debug.print("   Saving to original profile instead.\n\n", .{});
                                    // Revert to original profile name
                                    self.allocator.free(editor.profile_name);
                                    editor.profile_name = try self.allocator.dupe(u8, original_profile);
                                    profile_changed = false;
                                }
                            }

                            // Save based on whether name actually changed
                            if (profile_changed) {
                                // Save to new profile name
                                try profile_manager.saveProfile(self.allocator, editor.profile_name, editor.temp_config);

                                // Set as active profile
                                try profile_manager.setActiveProfileName(self.allocator, editor.profile_name);

                                std.debug.print("\n✓ Saved as new profile: {s}\n", .{editor.profile_name});
                            } else {
                                // Save to current profile
                                try profile_manager.saveProfile(self.allocator, editor.profile_name, editor.temp_config);

                                std.debug.print("\n✓ Saved profile: {s}\n", .{editor.profile_name});
                            }

                            // Apply changes to running config (transfer ownership)
                            self.config.deinit(self.allocator);
                            self.config = editor.temp_config;

                            // Re-initialize markdown and UI colors with new config
                            // CRITICAL: This must be done after config is replaced, since the old
                            // config strings were just freed and markdown.COLOR_INLINE_CODE_BG
                            // would be a dangling pointer otherwise
                            markdown.initColors(self.config.color_inline_code_bg);
                            ui.initUIColors(self.config.color_status);

                            // Recreate LLM provider with new config
                            self.llm_provider.deinit();
                            self.llm_provider = try llm_provider_module.createProvider(
                                self.config.provider,
                                self.allocator,
                                self.config,
                            );

                            // Close editor (but DON'T deinit temp_config - we transferred it to app.config!)
                            // Manually free only the editor's sections, fields, and profile_name
                            self.allocator.free(editor.profile_name);

                            for (editor.sections) |section| {
                                // Free section title (dynamically allocated)
                                self.allocator.free(section.title);

                                for (section.fields) |field| {
                                    if (field.edit_buffer) |buffer| {
                                        self.allocator.free(buffer);
                                    }
                                    // Free options array (allocated by listIdentifiers, etc.)
                                    if (field.options) |options| {
                                        self.allocator.free(options);
                                    }
                                }
                                self.allocator.free(section.fields);
                            }
                            self.allocator.free(editor.sections);
                            self.config_editor = null;
                        },
                        .cancel => {
                            // Discard changes and close editor
                            editor.deinit();
                            self.config_editor = null;
                        },
                        .redraw, .@"continue" => {},
                    }
                }

                continue; // Skip normal app logic - editor owns the screen
            }

            // AGENT BUILDER MODE (modal - similar to config editor)
            if (self.agent_builder) |*builder| {
                // Render builder
                var stdout_buffer: [8192]u8 = undefined;
                var buffered_writer = ui.BufferedStdoutWriter.init(&stdout_buffer);
                const writer = buffered_writer.writer();

                try agent_builder_renderer.render(
                    builder,
                    writer,
                    self.terminal_size.width,
                    self.terminal_size.height,
                );
                try buffered_writer.flush();

                // Wait for input (blocking)
                var read_buffer: [128]u8 = undefined;
                const bytes_read = ui.c.read(ui.c.STDIN_FILENO, &read_buffer, read_buffer.len);

                if (bytes_read > 0) {
                    const input = read_buffer[0..@intCast(bytes_read)];
                    const result = try agent_builder_input.handleInput(builder, input);

                    switch (result) {
                        .save_and_close => {
                            // Save agent
                            agent_builder_input.saveAgent(builder) catch |err| {
                                std.debug.print("Failed to save agent: {}\n", .{err});
                                // Show error to user (TODO: add error display)
                            };

                            // Close builder
                            builder.deinit();
                            self.agent_builder = null;

                            // Reload agents to include the new one
                            try self.agent_loader.loadAllAgents();
                        },
                        .cancel => {
                            // Close without saving
                            builder.deinit();
                            self.agent_builder = null;
                        },
                        .redraw, .@"continue" => {
                            // Just re-render next iteration
                        },
                    }
                }
                continue; // Skip normal app rendering
            }

            // HELP VIEWER MODE (modal - simple read-only display)
            if (self.help_viewer) |*viewer| {
                // Render help
                var stdout_buffer: [8192]u8 = undefined;
                var buffered_writer = ui.BufferedStdoutWriter.init(&stdout_buffer);
                const writer = buffered_writer.writer();

                try help_renderer.render(
                    viewer,
                    writer,
                    self.terminal_size.width,
                    self.terminal_size.height,
                );
                try buffered_writer.flush();

                // Wait for input (blocking)
                var read_buffer: [128]u8 = undefined;
                const bytes_read = ui.c.read(ui.c.STDIN_FILENO, &read_buffer, read_buffer.len);

                if (bytes_read > 0) {
                    const input = read_buffer[0..@intCast(bytes_read)];
                    // Calculate visible lines for scrolling
                    const visible_lines = self.terminal_size.height -| 6; // Account for borders and footer
                    const result = try help_input.handleInput(viewer, input, visible_lines);

                    switch (result) {
                        .close => {
                            // Close help viewer
                            viewer.deinit();
                            self.help_viewer = null;
                        },
                        .redraw, .@"continue" => {
                            // Just re-render next iteration
                        },
                    }
                }
                continue; // Skip normal app rendering
            }

            // PROFILE MANAGER MODE (modal - interactive profile management)
            if (self.profile_ui) |*profile_ui| {
                // Render profile UI
                var stdout_buffer: [8192]u8 = undefined;
                var buffered_writer = ui.BufferedStdoutWriter.init(&stdout_buffer);
                const writer = buffered_writer.writer();

                try profile_ui_renderer.render(
                    profile_ui,
                    writer,
                    self.terminal_size.width,
                    self.terminal_size.height,
                );
                try buffered_writer.flush();

                // Wait for input (blocking)
                var read_buffer: [128]u8 = undefined;
                const bytes_read = ui.c.read(ui.c.STDIN_FILENO, &read_buffer, read_buffer.len);

                if (bytes_read > 0) {
                    const input = read_buffer[0..@intCast(bytes_read)];
                    const result = try profile_ui_input.handleInput(profile_ui, self, input);

                    switch (result) {
                        .close, .profile_switched => {
                            // Close profile UI
                            profile_ui.deinit();
                            self.profile_ui = null;
                        },
                        .redraw, .@"continue" => {
                            // Just re-render next iteration
                        },
                    }
                }
                continue; // Skip normal app rendering
            }

            // Handle pending tool executions using state machine (async - doesn't block input)
            if (self.tool_executor.hasPendingWork()) {
                // Forward permission response from App to tool_executor if available
                if (self.permission_response) |response| {
                    self.tool_executor.setPermissionResponse(response);
                    self.permission_response = null;
                }

                // Advance the state machine
                const tick_result = try self.tool_executor.tick(
                    &self.permission_manager,
                    self.state.iteration_count,
                    self.max_iterations,
                );

                switch (tick_result) {
                    .no_action => {
                        // Nothing to do - waiting for user input or other event
                    },

                    .show_permission_prompt => {
                        // Tool executor needs to ask user for permission
                        if (self.tool_executor.getPendingPermissionTool()) |tool_call| {
                            if (self.tool_executor.getPendingPermissionEval()) |eval_result| {
                                try self.showPermissionPrompt(tool_call, eval_result);
                                self.permission_pending = true;
                                _ = try message_renderer.redrawScreen(self);
                                self.updateCursorToBottom();
                            }
                        }
                    },

                    .render_requested => {
                        // Tool executor is ready to execute current tool (if in executing state)
                        if (self.tool_executor.getCurrentState() == .executing) {
                            if (self.tool_executor.getCurrentToolCall()) |tool_call| {
                                const call_idx = self.tool_executor.current_index;

                                // Execute tool and get structured result
                                var result = self.executeTool(tool_call) catch |err| blk: {
                                    const msg = try std.fmt.allocPrint(self.allocator, "Runtime error: {}", .{err});
                                    defer self.allocator.free(msg);
                                    break :blk try tools_module.ToolResult.err(self.allocator, .internal_error, msg, std.time.milliTimestamp());
                                };
                                defer result.deinit(self.allocator);

                                // Create user-facing display message (FULL TRANSPARENCY)
                                const display_content = try result.formatDisplay(
                                    self.allocator,
                                    tool_call.function.name,
                                    tool_call.function.arguments,
                                );
                                const display_processed = try markdown.processMarkdown(self.allocator, display_content);

                                // Note: Agent thinking is shown in separate "Agent Analysis" message above
                                // No need to duplicate it in tool result

                                try self.messages.append(self.allocator, .{
                                    .role = .display_only_data,
                                    .content = display_content,
                                    .processed_content = display_processed,
                                    .thinking_content = null,  // Thinking shown separately
                                    .processed_thinking_content = null,
                                    .thinking_expanded = false,
                                    .timestamp = std.time.milliTimestamp(),
                                    // Tool execution metadata for collapsible display
                                    .tool_call_expanded = false,
                                    .tool_name = try self.allocator.dupe(u8, tool_call.function.name),
                                    .tool_success = result.success,
                                    .tool_execution_time = result.metadata.execution_time_ms,
                                });

                                // Persist tool execution display immediately
                                try self.persistMessage(self.messages.items.len - 1);

                                // Don't redraw yet - wait until tool result is also added
                                // to avoid double-redraw per tool (reduces flashing)

                                // Create model-facing result (JSON for LLM)
                                const tool_id_copy = if (tool_call.id) |id|
                                    try self.allocator.dupe(u8, id)
                                else
                                    try std.fmt.allocPrint(self.allocator, "call_{d}", .{call_idx});

                                const model_result = if (result.success and result.data != null)
                                    try self.allocator.dupe(u8, result.data.?)
                                else
                                    try result.toJSON(self.allocator);

                                const result_processed = try markdown.processMarkdown(self.allocator, model_result);

                                try self.messages.append(self.allocator, .{
                                    .role = .tool,
                                    .content = model_result,
                                    .processed_content = result_processed,
                                    .thinking_expanded = false,
                                    .timestamp = std.time.milliTimestamp(),
                                    .tool_call_id = tool_id_copy,
                                });

                                // Persist tool result immediately
                                try self.persistMessage(self.messages.items.len - 1);

                                // Now redraw once for both messages (display + tool result)
                                // Single redraw instead of two reduces flashing
                                _ = try message_renderer.redrawScreen(self);
                                self.updateCursorToBottom();

                                // Tell executor to advance to next tool
                                self.tool_executor.advanceAfterExecution();
                                
                                // DEBUG: Log state after advancing
                                if (std.posix.getenv("DEBUG_TOOLS")) |_| {
                                    std.debug.print("[TOOL_EXEC] After advance: state={s}, hasPending={}\n", .{
                                        @tagName(self.tool_executor.getCurrentState()),
                                        self.tool_executor.hasPendingWork(),
                                    });
                                }
                            }
                        } else if (self.tool_executor.getCurrentState() == .creating_denial_result) {
                            // User denied permission - create error result for LLM
                            if (self.tool_executor.getCurrentToolCall()) |tool_call| {
                                const call_idx = self.tool_executor.current_index;

                                // Create permission denied error result
                                var result = try tools_module.ToolResult.err(
                                    self.allocator,
                                    .permission_denied,
                                    "User denied permission for this operation",
                                    std.time.milliTimestamp(),
                                );
                                defer result.deinit(self.allocator);

                                // Create user-facing display message
                                const display_content = try result.formatDisplay(
                                    self.allocator,
                                    tool_call.function.name,
                                    tool_call.function.arguments,
                                );
                                const display_processed = try markdown.processMarkdown(self.allocator, display_content);

                                try self.messages.append(self.allocator, .{
                                    .role = .display_only_data,
                                    .content = display_content,
                                    .processed_content = display_processed,
                                    .thinking_content = null,
                                    .processed_thinking_content = null,
                                    .thinking_expanded = false,
                                    .timestamp = std.time.milliTimestamp(),
                                    .tool_call_expanded = false,
                                    .tool_name = try self.allocator.dupe(u8, tool_call.function.name),
                                    .tool_success = false,
                                    .tool_execution_time = result.metadata.execution_time_ms,
                                });

                                // Persist tool error display immediately
                                try self.persistMessage(self.messages.items.len - 1);

                                // Receipt printer mode: auto-scroll
                                _ = try message_renderer.redrawScreen(self);
                                self.updateCursorToBottom();

                                // Create model-facing result (JSON for LLM)
                                const tool_id_copy = if (tool_call.id) |id|
                                    try self.allocator.dupe(u8, id)
                                else
                                    try std.fmt.allocPrint(self.allocator, "call_{d}", .{call_idx});

                                const model_result = try result.toJSON(self.allocator);
                                const result_processed = try markdown.processMarkdown(self.allocator, model_result);

                                try self.messages.append(self.allocator, .{
                                    .role = .tool,
                                    .content = model_result,
                                    .processed_content = result_processed,
                                    .thinking_expanded = false,
                                    .timestamp = std.time.milliTimestamp(),
                                    .tool_call_id = tool_id_copy,
                                });

                                // Persist tool error result immediately
                                try self.persistMessage(self.messages.items.len - 1);

                                // Receipt printer mode: auto-scroll
                                _ = try message_renderer.redrawScreen(self);
                                self.updateCursorToBottom();

                                // Tell executor to advance to next tool
                                self.tool_executor.advanceAfterExecution();
                            }
                        } else {
                            // Just redraw for other states
                            _ = try message_renderer.redrawScreen(self);
                        }
                    },

                    .iteration_complete => {
                        // All tools executed - increment iteration and continue streaming
                        self.state.iteration_count += 1;
                        self.tool_call_depth = 0; // Reset for next iteration

                        _ = try message_renderer.redrawScreen(self);

                        // NOTE: Do NOT process Graph RAG queue here!
                        // Queue processing happens only when the entire conversation turn is done,
                        // not between tool iterations. See line ~1492 where we process after
                        // streaming completes with no tool calls.

                        try self.startStreaming(null);
                    },

                    .iteration_limit_reached => {
                        // Max iterations reached - stop master loop
                        const msg = try std.fmt.allocPrint(
                            self.allocator,
                            "⚠️  Reached maximum iteration limit ({d}). Stopping master loop to prevent infinite execution.",
                            .{self.max_iterations},
                        );
                        const processed = try markdown.processMarkdown(self.allocator, msg);
                        try self.messages.append(self.allocator, .{
                            .role = .display_only_data,
                            .content = msg,
                            .processed_content = processed,
                            .thinking_expanded = false,
                            .timestamp = std.time.milliTimestamp(),
                        });

                        // Persist error message immediately
                        try self.persistMessage(self.messages.items.len - 1);

                        _ = try message_renderer.redrawScreen(self);
                    },
                }
            }

            // Process stream chunks if streaming is active
            if (self.streaming_active) {
                self.stream_mutex.lock();

                var chunks_were_processed = false;

                // Process all pending chunks
                for (self.stream_chunks.items) |chunk| {
                    chunks_were_processed = true;
                    if (chunk.done) {
                        // Streaming complete - clean up
                        self.streaming_active = false;

                        thinking_accumulator.clearRetainingCapacity();
                        content_accumulator.clearRetainingCapacity();

                        // Auto-collapse thinking box when streaming finishes
                        if (self.messages.items.len > 0) {
                            self.messages.items[self.messages.items.len - 1].thinking_expanded = false;
                        }

                        // Wait for thread to finish and clean up context
                        if (self.stream_thread) |thread| {
                            self.stream_mutex.unlock();
                            thread.join();
                            self.stream_mutex.lock();
                            self.stream_thread = null;

                            // Free thread context and its data
                            if (self.stream_thread_ctx) |ctx| {
                                // Note: msg.role and msg.content are NOT owned by the context
                                // They are pointers to existing message data, so we only free the array
                                self.allocator.free(ctx.messages);
                                self.allocator.destroy(ctx);
                                self.stream_thread_ctx = null;
                            }
                        }

                        // Check if model requested tool calls
                        const tool_calls_to_execute = self.pending_tool_calls;
                        self.pending_tool_calls = null; // Clear pending calls

                        if (tool_calls_to_execute) |tool_calls| {
                            // Check recursion depth
                            if (self.tool_call_depth >= self.max_tool_depth) {
                                // Too many recursive tool calls - show error and stop
                                self.stream_mutex.unlock();

                                const error_msg = try self.allocator.dupe(u8, "Error: Maximum tool call depth reached. Stopping to prevent infinite loop.");
                                const error_processed = try markdown.processMarkdown(self.allocator, error_msg);
                                try self.messages.append(self.allocator, .{
                                    .role = .display_only_data,
                                    .content = error_msg,
                                    .processed_content = error_processed,
                                    .thinking_expanded = false,
                                    .timestamp = std.time.milliTimestamp(),
                                });

                                // Persist streaming error immediately
                                try self.persistMessage(self.messages.items.len - 1);

                                // Clean up tool calls
                                for (tool_calls) |call| {
                                    if (call.id) |id| self.allocator.free(id);
                                    if (call.type) |call_type| self.allocator.free(call_type);
                                    self.allocator.free(call.function.name);
                                    self.allocator.free(call.function.arguments);
                                }
                                self.allocator.free(tool_calls);

                                self.stream_mutex.lock();
                            } else {
                                self.stream_mutex.unlock();

                                // Increment depth
                                self.tool_call_depth += 1;

                                // Attach tool calls to the last assistant message
                                if (self.messages.items.len > 0) {
                                    var last_message = &self.messages.items[self.messages.items.len - 1];
                                    if (last_message.role == .assistant) {
                                        last_message.tool_calls = tool_calls;
                                    }
                                }

                                // Persist assistant message with tool_calls attached
                                try self.persistMessage(self.messages.items.len - 1);

                                // Update display to show tool call
                                _ = try message_renderer.redrawScreen(self);
                                self.updateCursorToBottom();

                                // Start tool executor with new tool calls
                                self.tool_executor.startExecution(tool_calls);

                                // Re-lock mutex before continuing
                                self.stream_mutex.lock();
                            }
                        } else {
                            // No tool calls - response is complete
                            // Persist completed assistant message
                            try self.persistMessage(self.messages.items.len - 1);

                            // ==========================================
                            // SECONDARY LOOP: Process Graph RAG queue
                            // ==========================================
                            // This is the ONLY place where Graph RAG indexing runs.
                            // It processes all files queued by read_file tool during the main loop.
                            // This ensures indexing happens AFTER the conversation turn is complete,
                            // keeping the main loop responsive to the user.
                            if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
                                std.debug.print("[GRAPHRAG] Main loop complete, starting secondary loop...\n", .{});
                            }

                            self.stream_mutex.unlock();

                            self.stream_mutex.lock();
                        }
                    } else {
                        // Accumulate chunks
                        if (chunk.thinking) |t| {
                            try thinking_accumulator.appendSlice(self.allocator, t);
                        }
                        if (chunk.content) |c| {
                            try content_accumulator.appendSlice(self.allocator, c);
                        }

                        // Update the last message
                        if (self.messages.items.len > 0) {
                            var last_message = &self.messages.items[self.messages.items.len - 1];

                            // Update thinking content if we have any
                            if (thinking_accumulator.items.len > 0) {
                                if (last_message.thinking_content) |old_thinking| {
                                    self.allocator.free(old_thinking);
                                }
                                if (last_message.processed_thinking_content) |*old_processed| {
                                    for (old_processed.items) |*item| {
                                        item.deinit(self.allocator);
                                    }
                                    old_processed.deinit(self.allocator);
                                }

                                last_message.thinking_content = try self.allocator.dupe(u8, thinking_accumulator.items);
                                last_message.processed_thinking_content = try markdown.processMarkdown(self.allocator, last_message.thinking_content.?);
                            }

                            // Update main content
                            self.allocator.free(last_message.content);
                            for (last_message.processed_content.items) |*item| {
                                item.deinit(self.allocator);
                            }
                            last_message.processed_content.deinit(self.allocator);

                            last_message.content = try self.allocator.dupe(u8, content_accumulator.items);

                            // DEBUG: Check content encoding
                            if (std.posix.getenv("DEBUG_LMSTUDIO") != null and last_message.content.len > 0) {
                                const preview_len = @min(100, last_message.content.len);
                                std.debug.print("\nDEBUG APP: Raw content ({d} bytes): {s}\n", .{last_message.content.len, last_message.content[0..preview_len]});

                                // Show hex dump of raw content
                                const hex_len = @min(100, last_message.content.len);
                                std.debug.print("DEBUG APP: Raw content hex: ", .{});
                                for (last_message.content[0..hex_len]) |byte| {
                                    std.debug.print("{x:0>2} ", .{byte});
                                }
                                std.debug.print("\n", .{});

                                // Check for ANSI escape codes
                                if (std.mem.indexOf(u8, last_message.content, "\x1b")) |idx| {
                                    std.debug.print("WARNING: Found ANSI escape code at position {d}!\n", .{idx});
                                }

                                // Check for high bytes (> 127) that might be problematic
                                for (last_message.content[0..@min(100, last_message.content.len)], 0..) |byte, i| {
                                    if (byte >= 128) {
                                        std.debug.print("DEBUG: High byte 0x{x:0>2} at position {d}\n", .{byte, i});
                                    }
                                }
                            }

                            last_message.processed_content = try markdown.processMarkdown(self.allocator, last_message.content);

                            // Removed dirty state tracking - rendering is now automatic

                            // DEBUG: Check if markdown processing worked
                            if (std.posix.getenv("DEBUG_LMSTUDIO") != null) {
                                std.debug.print("DEBUG APP: Processed markdown - got {d} items\n", .{last_message.processed_content.items.len});
                                if (last_message.processed_content.items.len > 0) {
                                    std.debug.print("DEBUG APP: First item type: {s}\n", .{@tagName(last_message.processed_content.items[0].tag)});

                                    // Check what's in the styled_text
                                    if (last_message.processed_content.items[0].tag == .styled_text) {
                                        const styled = last_message.processed_content.items[0].payload.styled_text;
                                        if (styled.len < 100) {
                                            std.debug.print("DEBUG APP: Styled text content: {s}\n", .{styled});
                                            // Show hex of first 50 bytes
                                            const hex_len = @min(50, styled.len);
                                            std.debug.print("DEBUG APP: Hex: ", .{});
                                            for (styled[0..hex_len]) |byte| {
                                                std.debug.print("{x:0>2} ", .{byte});
                                            }
                                            std.debug.print("\n", .{});
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Free the chunk's data
                    if (chunk.thinking) |t| self.allocator.free(t);
                    if (chunk.content) |c| self.allocator.free(c);
                }

                // Clear processed chunks
                self.stream_chunks.clearRetainingCapacity();
                self.stream_mutex.unlock();

                // Only render when chunks arrive (avoid busy loop)
                if (chunks_were_processed) {
                    // Update scroll position to keep content in view
                    // (Needed when streaming ends - done chunk sets streaming_active=false,
                    //  collapses thinking, and changes message hash/height)

                    _ = try message_renderer.redrawScreen(self);

                    // Update cursor to bottom after redraw

                    // Input handling happens after this block - no continue/skip!
                    // This allows scroll wheel to work immediately
                }
            }

            // Main render section - runs when NOT streaming or when streaming but no chunks
            // During streaming, we skip this to avoid double-render
            if (!self.streaming_active) {
                // Handle resize signals (main content always expanded, no special handling needed)
                if (ui.resize_pending) {
                    ui.resize_pending = false;
                }

                self.terminal_size = try ui.Tui.getTerminalSize();
                var stdout_buffer: [8192]u8 = undefined;
                var buffered_writer = ui.BufferedStdoutWriter.init(&stdout_buffer);
                const writer = buffered_writer.writer();

                // Calculate input field height once for this render
                const input_field_height = try message_renderer.calculateInputFieldHeight(self);

                // Move cursor to home WITHOUT clearing - prevents flicker
                try writer.writeAll("\x1b[H");
                self.clickable_areas.clearRetainingCapacity();
                self.valid_cursor_positions.clearRetainingCapacity();

                var absolute_y: usize = 1;
                for (self.messages.items, 0..) |_, i| {
                    const message = &self.messages.items[i];

                    // Skip tool JSON if hidden by config
                    if (message.role == .tool and !self.config.show_tool_json) continue;

                    // Skip empty system messages (hot context placeholder before first update)
                    if (message.role == .system and message.content.len == 0) continue;

                    // Draw message (handles both thinking and content)
                    try message_renderer.drawMessage(self, writer, message, i, &absolute_y, input_field_height);
                }

                // Position cursor after last message content to clear any leftover content
                const screen_y_for_clear = if (absolute_y > self.scroll_y)
                    (absolute_y - self.scroll_y) + 1
                else
                    1;

                // Only clear if there's space between content and input field
                // input_field_height includes separator, +1 for taskbar
                const input_area_start = if (self.terminal_size.height > input_field_height + 1)
                    self.terminal_size.height - input_field_height
                else
                    1;
                if (screen_y_for_clear < input_area_start) {
                    try writer.print("\x1b[{d};1H\x1b[J", .{screen_y_for_clear});
                }

                // Draw input field at the bottom (3 rows before status)
                try message_renderer.drawInputField(self, writer);
                try ui.drawTaskbar(self, writer);
                try buffered_writer.flush();
            }

            // If streaming is active OR tools are executing, don't block - continue main loop to process chunks/tools
            if (self.streaming_active or self.tool_executor.hasPendingWork()) {
                // Read input non-blocking
                var read_buffer: [128]u8 = undefined;
                const bytes_read = ui.c.read(ui.c.STDIN_FILENO, &read_buffer, read_buffer.len);
                if (bytes_read > 0) {
                    const input = read_buffer[0..@intCast(bytes_read)];
                    var should_redraw = false;
                    if (try ui.handleInput(self, input, &should_redraw)) {
                        return;
                    }
                    // Check if we need to redraw (e.g., after toggling settings)
                    if (should_redraw) {
                        _ = try message_renderer.redrawScreen(self);
                    }
                }
                // Continue main loop immediately to check for more chunks or execute next tool
                // Small sleep to avoid busy-waiting and reduce CPU usage
                std.Thread.sleep(10 * std.time.ns_per_ms); // 10ms
            } else {
                // Normal blocking mode when not streaming

                var should_redraw = false;
                while (!should_redraw) {
                    // Check for resize signal before blocking on input
                    if (ui.resize_pending) {
                        should_redraw = true;
                        break;
                    }

                    // Check for resize completion timeout
                    if (self.resize_in_progress) {
                        const now = std.time.milliTimestamp();
                        if (now - self.last_resize_time > 200) {
                            should_redraw = true;
                            break;
                        }
                    }

                    var read_buffer: [128]u8 = undefined;
                    const bytes_read = ui.c.read(ui.c.STDIN_FILENO, &read_buffer, read_buffer.len);
                    if (bytes_read <= 0) {
                        // Check again after read timeout/interrupt
                        if (ui.resize_pending) {
                            should_redraw = true;
                            break;
                        }
                        // Also check resize timeout after read returns
                        if (self.resize_in_progress) {
                            const now = std.time.milliTimestamp();
                            if (now - self.last_resize_time > 200) {
                                should_redraw = true;
                                break;
                            }
                        }
                        continue;
                    }
                    const input = read_buffer[0..@intCast(bytes_read)];
                    if (try ui.handleInput(self, input, &should_redraw)) {
                        return;
                    }
                }
            }

            // View height accounts for input field + status bar (dynamic based on input length)
            // Adjust viewport to keep cursor in view
            const input_field_height = message_renderer.calculateInputFieldHeight(self) catch 2; // fallback to minimum
            const view_height = if (self.terminal_size.height > input_field_height + 1)
                self.terminal_size.height - input_field_height - 1
            else
                1;
            if (self.cursor_y < self.scroll_y + 1) {
                self.scroll_y = if (self.cursor_y > 0) self.cursor_y - 1 else 0;
            }
            if (self.cursor_y > self.scroll_y + view_height) {
                self.scroll_y = self.cursor_y - view_height;
            }
        }
    }
};
