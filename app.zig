// Application logic - App struct and all related methods
const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const json = std.json;
const process = std.process;
const ui = @import("ui.zig");
const markdown = @import("markdown.zig");
const ollama = @import("ollama.zig");
const permission = @import("permission.zig");
const tools_module = @import("tools.zig");
const types = @import("types.zig");
const state_module = @import("state.zig");
const context_module = @import("context.zig");
const config_module = @import("config.zig");
const render = @import("render.zig");
const message_renderer = @import("message_renderer.zig");

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
    ollama_client: *ollama.OllamaClient,
    model: []const u8,
    messages: []ollama.ChatMessage,
    format: ?[]const u8,
    tools: []const ollama.Tool,
    keep_alive: []const u8,
};

// Define available tools for the model
fn createTools(allocator: mem.Allocator) ![]const ollama.Tool {
    return try tools_module.getOllamaTools(allocator);
}



pub const App = struct {
    allocator: mem.Allocator,
    config: Config,
    messages: std.ArrayListUnmanaged(Message),
    ollama_client: ollama.OllamaClient,
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
    pending_permission_tool: ?ollama.ToolCall = null,
    pending_permission_eval: ?permission.PolicyEngine.EvaluationResult = null,
    permission_response: ?permission.PermissionMode = null,
    // Tool execution state for async permission handling
    pending_tool_execution: ?struct {
        tool_calls: []ollama.ToolCall,
        current_index: usize,
    } = null,
    // Phase 1: Task management state
    state: AppState,
    app_context: AppContext,
    max_iterations: usize = 10, // Master loop iteration limit
    // Auto-scroll state (receipt printer mode)
    user_scrolled_away: bool = false, // Tracks if user manually scrolled during streaming

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

        var app = App{
            .allocator = allocator,
            .config = config,
            .messages = .{},
            .ollama_client = ollama.OllamaClient.init(allocator, config.ollama_host, config.ollama_endpoint),
            .input_buffer = .{},
            .clickable_areas = .{},
            .terminal_size = try ui.Tui.getTerminalSize(),
            .valid_cursor_positions = .{},
            .saved_expansion_states = .{},
            .tools = tools,
            .permission_manager = perm_manager,
            // Phase 1: Initialize state (session-ephemeral)
            .state = AppState.init(allocator),
            .app_context = undefined, // Will be fixed by caller after struct is in final location
        };

        // Add system prompt
        const system_prompt = "You are a helpful coding assistant.";
        const system_processed = try markdown.processMarkdown(allocator, system_prompt);
        try app.messages.append(allocator, .{
            .role = .system,
            .content = try allocator.dupe(u8, system_prompt),
            .processed_content = system_processed,
            .thinking_expanded = true,
            .timestamp = std.time.milliTimestamp(),
        });

        return app;
    }

    // Fix context pointers after App is in its final location
    // MUST be called immediately after init() in main.zig
    pub fn fixContextPointers(self: *App) void {
        self.app_context = .{
            .allocator = self.allocator,
            .config = &self.config,
            .state = &self.state,
        };
    }


    // Check if viewport is currently at the bottom
    fn isViewportAtBottom(self: *App) bool {
        if (self.valid_cursor_positions.items.len == 0) return true;

        const last_position = self.valid_cursor_positions.items[self.valid_cursor_positions.items.len - 1];
        return self.cursor_y == last_position;
    }

    // Pre-calculate and apply scroll position to keep viewport anchored at bottom
    // This should be called BEFORE redrawScreen() to avoid flashing
    fn maintainBottomAnchor(self: *App) !void {
        if (self.valid_cursor_positions.items.len == 0) return;

        // Calculate total content height
        const total_content_height = try message_renderer.calculateContentHeight(self);
        const view_height = self.terminal_size.height - 4;

        // Anchor viewport to bottom
        if (total_content_height > view_height) {
            self.scroll_y = total_content_height - view_height;
        } else {
            self.scroll_y = 0;
        }
    }

    // Update cursor to track bottom position after redraw
    fn updateCursorToBottom(self: *App) void {
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

        // Run the streaming with retry logic for stale connections
        ctx.ollama_client.chatStream(
            ctx.model,
            ctx.messages,
            true, // Enable thinking
            ctx.format,
            if (ctx.tools.len > 0) ctx.tools else null, // Pass tools to model
            ctx.keep_alive,
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

                // Recreate HTTP client to clear stale connection pool
                ctx.ollama_client.client.deinit();
                ctx.ollama_client.client = std.http.Client{ .allocator = ctx.allocator };

                // Small delay before retry
                std.Thread.sleep(100 * std.time.ns_per_ms);

                // Retry the request
                ctx.ollama_client.chatStream(
                    ctx.model,
                    ctx.messages,
                    true,
                    ctx.format,
                    if (ctx.tools.len > 0) ctx.tools else null,
                    ctx.keep_alive,
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

    // Internal method to start streaming with current message history
    fn startStreaming(self: *App, format: ?[]const u8) !void {
        // Set streaming flag FIRST - before any redraws
        // This ensures the status bar shows "AI is responding..." immediately
        self.streaming_active = true;

        // Reset tool call depth when starting a new user message
        // (This will be set correctly by continueStreaming for tool calls)

        // Prepare message history for Ollama
        var ollama_messages = std.ArrayListUnmanaged(ollama.ChatMessage){};
        defer ollama_messages.deinit(self.allocator);

        for (self.messages.items) |msg| {
            // Skip system messages when sending to API (they're for display only)
            // Only include the initial system message if it exists and is first
            if (msg.role == .system) {
                // Allow system message only if it's the first message (initial prompt)
                const is_first = self.messages.items.len > 0 and
                                @intFromPtr(&self.messages.items[0]) == @intFromPtr(&msg);
                if (!is_first) continue;
            }

            const role_str = switch (msg.role) {
                .user => "user",
                .assistant => "assistant",
                .system => "system",
                .tool => "tool",
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

        // Redraw to show empty placeholder (receipt printer mode)
        if (!self.user_scrolled_away) {
            try self.maintainBottomAnchor();
        }
        _ = try message_renderer.redrawScreen(self);
        if (!self.user_scrolled_away) {
            self.updateCursorToBottom();
        }

        // Prepare thread context
        const messages_slice = try ollama_messages.toOwnedSlice(self.allocator);

        const thread_ctx = try self.allocator.create(StreamThreadContext);
        thread_ctx.* = .{
            .allocator = self.allocator,
            .app = self,
            .ollama_client = &self.ollama_client,
            .model = self.config.model,
            .messages = messages_slice,
            .format = format,
            .tools = self.tools,
            .keep_alive = self.config.model_keep_alive,
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

        // Reset auto-scroll state - re-enable receipt printer mode for new response
        self.user_scrolled_away = false;

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

        // Show user message right away (receipt printer mode)
        if (!self.user_scrolled_away) {
            try self.maintainBottomAnchor();
        }
        _ = try message_renderer.redrawScreen(self);
        if (!self.user_scrolled_away) {
            self.updateCursorToBottom();
        }

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
            .role = .system,
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

        // Set permission pending state (non-blocking - main loop will handle response)
        self.permission_pending = true;
        self.permission_response = null;
    }

    // Execute a tool call and return the result (Phase 1: passes AppContext)
    fn executeTool(self: *App, tool_call: ollama.ToolCall) !tools_module.ToolResult {
        return try tools_module.executeToolCall(self.allocator, tool_call, &self.app_context);
    }

    pub fn deinit(self: *App) void {
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
        }
        self.messages.deinit(self.allocator);
        self.ollama_client.deinit();
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

        // Clean up pending permission tool if any
        if (self.pending_permission_tool) |call| {
            if (call.id) |id| self.allocator.free(id);
            if (call.type) |call_type| self.allocator.free(call_type);
            self.allocator.free(call.function.name);
            self.allocator.free(call.function.arguments);
        }

        // Phase 1: Clean up state
        self.state.deinit();
    }

    pub fn run(self: *App, app_tui: *ui.Tui) !void {
        _ = app_tui; // Will be used later for editor integration

        // Buffers for accumulating stream data
        var thinking_accumulator = std.ArrayListUnmanaged(u8){};
        defer thinking_accumulator.deinit(self.allocator);
        var content_accumulator = std.ArrayListUnmanaged(u8){};
        defer content_accumulator.deinit(self.allocator);

        while (true) {
            // Handle pending tool executions (async - doesn't block input)
            if (self.pending_tool_execution) |*pending| {
                // Check if waiting for permission response
                if (self.permission_pending) {
                    // Permission prompt is shown, wait for user response
                    // Input handler will set permission_response when user presses A/S/R/D
                    if (self.permission_response) |_| {
                        // Permission granted or denied - clear pending state
                        self.permission_pending = false;

                        // Handle response and continue tool execution
                        // (The actual execution will happen in next iteration with response set)
                    }
                    // Continue main loop to allow input processing
                } else if (pending.current_index < pending.tool_calls.len) {
                    // Execute next tool in the list
                    const tool_call = pending.tool_calls[pending.current_index];
                    const call_idx = pending.current_index;

                    // Get metadata
                    const metadata = self.permission_manager.registry.getMetadata(tool_call.function.name);

                    if (metadata) |meta| {
                        // Validate arguments
                        const valid = self.permission_manager.registry.validateArguments(
                            tool_call.function.name,
                            tool_call.function.arguments,
                        ) catch false;

                        if (!valid) {
                            try self.permission_manager.audit_logger.log(
                                tool_call.function.name,
                                tool_call.function.arguments,
                                .failed_validation,
                                "Invalid arguments",
                                false,
                            );
                            // Skip this tool, move to next
                            pending.current_index += 1;
                            continue;
                        }

                        // Check session grants
                        const has_session_grant = self.permission_manager.session_state.hasGrant(
                            tool_call.function.name,
                            meta.required_scopes[0],
                        ) != null;

                        var should_execute = false;
                        var user_choice: ?permission.PermissionMode = null;

                        if (has_session_grant) {
                            // Auto-approve with session grant
                            should_execute = true;
                            try self.permission_manager.audit_logger.log(
                                tool_call.function.name,
                                tool_call.function.arguments,
                                .auto_approved,
                                "Session grant active",
                                false,
                            );
                        } else {
                            // Evaluate policy
                            const eval_result = self.permission_manager.policy_engine.evaluate(
                                tool_call.function.name,
                                tool_call.function.arguments,
                                meta,
                            ) catch {
                                // Policy evaluation failed - skip
                                pending.current_index += 1;
                                continue;
                            };

                            if (eval_result.allowed and !eval_result.ask_user) {
                                // Auto-approve
                                should_execute = true;
                                try self.permission_manager.audit_logger.log(
                                    tool_call.function.name,
                                    tool_call.function.arguments,
                                    .auto_approved,
                                    eval_result.reason,
                                    false,
                                );
                            } else if (!eval_result.allowed and !eval_result.ask_user) {
                                // Auto-deny
                                try self.permission_manager.audit_logger.log(
                                    tool_call.function.name,
                                    tool_call.function.arguments,
                                    .denied_by_policy,
                                    eval_result.reason,
                                    false,
                                );
                                pending.current_index += 1;
                                continue;
                            } else {
                                // Need to ask user
                                if (self.permission_response == null) {
                                    // First time - show prompt
                                    try self.showPermissionPrompt(tool_call, eval_result);
                                    if (!self.user_scrolled_away) {
                                        try self.maintainBottomAnchor();
                                    }
                                    _ = try message_renderer.redrawScreen(self);
                                    if (!self.user_scrolled_away) {
                                        self.updateCursorToBottom();
                                    }
                                    // Wait for response in next loop iteration
                                    continue;
                                } else {
                                    // Response received
                                    user_choice = self.permission_response;
                                    self.permission_response = null; // Clear for next time

                                    if (user_choice == null or user_choice.? == .deny) {
                                        // Denied
                                        try self.permission_manager.audit_logger.log(
                                            tool_call.function.name,
                                            tool_call.function.arguments,
                                            .denied_by_user,
                                            "User denied permission",
                                            false,
                                        );
                                        pending.current_index += 1;
                                        continue;
                                    }

                                    // Handle user choice
                                    switch (user_choice.?) {
                                        .allow_once => {},
                                        .always_allow => {
                                            // Save policy
                                            var path_patterns: []const []const u8 = undefined;
                                            if (meta.required_scopes[0] == .read_files or meta.required_scopes[0] == .write_files) {
                                                var patterns = try self.allocator.alloc([]const u8, 1);
                                                patterns[0] = try self.allocator.dupe(u8, "*");
                                                path_patterns = patterns;
                                            } else {
                                                path_patterns = try self.allocator.alloc([]const u8, 0);
                                            }

                                            const deny_patterns = try self.allocator.alloc([]const u8, 0);

                                            try self.permission_manager.policy_engine.addPolicy(.{
                                                .scope = meta.required_scopes[0],
                                                .mode = .always_allow,
                                                .path_patterns = path_patterns,
                                                .deny_patterns = deny_patterns,
                                            });

                                            config_module.savePolicies(self.allocator, &self.permission_manager) catch |err| {
                                                std.debug.print("Warning: Failed to save policies: {}\n", .{err});
                                            };
                                        },
                                        .ask_each_time => {
                                            // Add session grant
                                            try self.permission_manager.session_state.addGrant(.{
                                                .tool_name = tool_call.function.name,
                                                .granted_at = std.time.milliTimestamp(),
                                                .scope = meta.required_scopes[0],
                                            });
                                        },
                                        .deny => unreachable,
                                    }

                                    should_execute = true;
                                    try self.permission_manager.audit_logger.log(
                                        tool_call.function.name,
                                        tool_call.function.arguments,
                                        .user_approved,
                                        eval_result.reason,
                                        true,
                                    );
                                }
                            }
                        }

                        // Execute if approved
                        if (should_execute) {
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

                            try self.messages.append(self.allocator, .{
                                .role = .system,
                                .content = display_content,
                                .processed_content = display_processed,
                                .thinking_expanded = false,
                                .timestamp = std.time.milliTimestamp(),
                            });

                            // Receipt printer mode: auto-scroll to show tool results
                            // UNLESS user has manually scrolled away
                            if (!self.user_scrolled_away) {
                                try self.maintainBottomAnchor();
                            }

                            // Redraw to show the display message
                            _ = try message_renderer.redrawScreen(self);

                            if (!self.user_scrolled_away) {
                                self.updateCursorToBottom();
                            }

                            // Create model-facing result (JSON for LLM)
                            const tool_id_copy = if (tool_call.id) |id|
                                try self.allocator.dupe(u8, id)
                            else
                                try std.fmt.allocPrint(self.allocator, "call_{d}", .{call_idx});

                            // For success: send unwrapped data directly (e.g., {"id": 1})
                            // For errors: send full ToolResult for structured error handling
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

                            // Receipt printer mode: auto-scroll to show tool result
                            // UNLESS user has manually scrolled away
                            if (!self.user_scrolled_away) {
                                try self.maintainBottomAnchor();
                            }

                            _ = try message_renderer.redrawScreen(self);

                            if (!self.user_scrolled_away) {
                                self.updateCursorToBottom();
                            }

                            // Move to next tool
                            pending.current_index += 1;
                        }
                    } else {
                        // Tool not registered
                        try self.permission_manager.audit_logger.log(
                            tool_call.function.name,
                            tool_call.function.arguments,
                            .failed_validation,
                            "Tool not registered",
                            false,
                        );
                        pending.current_index += 1;
                    }
                } else {
                    // All tools executed - check iteration limit before continuing
                    self.state.iteration_count += 1;

                    // Reset tool call depth for next iteration (allows fresh tool calls)
                    self.tool_call_depth = 0;

                    if (self.state.iteration_count >= self.max_iterations) {
                        // Max iterations reached - stop loop
                        const msg = try std.fmt.allocPrint(
                            self.allocator,
                            "⚠️  Reached maximum iteration limit ({d}). Stopping master loop to prevent infinite execution.",
                            .{self.max_iterations},
                        );
                        const processed = try markdown.processMarkdown(self.allocator, msg);
                        try self.messages.append(self.allocator, .{
                            .role = .system,
                            .content = msg,
                            .processed_content = processed,
                            .thinking_expanded = false,
                            .timestamp = std.time.milliTimestamp(),
                        });

                        self.pending_tool_execution = null;
                        if (!self.user_scrolled_away) {
                            try self.maintainBottomAnchor();
                        }
                        _ = try message_renderer.redrawScreen(self);
                        if (!self.user_scrolled_away) {
                            self.updateCursorToBottom();
                        }
                    } else {
                        // Continue conversation - inject task context and restart streaming
                        self.pending_tool_execution = null;
                        if (!self.user_scrolled_away) {
                            try self.maintainBottomAnchor();
                        }
                        _ = try message_renderer.redrawScreen(self);
                        if (!self.user_scrolled_away) {
                            self.updateCursorToBottom();
                        }

                        try self.startStreaming(null);
                    }
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
                                    .role = .system,
                                    .content = error_msg,
                                    .processed_content = error_processed,
                                    .thinking_expanded = false,
                                    .timestamp = std.time.milliTimestamp(),
                                });

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

                                // Store tool calls for execution in main loop (non-blocking)
                                self.pending_tool_execution = .{
                                    .tool_calls = tool_calls,
                                    .current_index = 0,
                                };

                                // Don't execute here - will be handled in main loop
                                self.stream_mutex.lock();
                            }
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
                            last_message.processed_content = try markdown.processMarkdown(self.allocator, last_message.content);
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
                    // Receipt printer mode: always auto-scroll to show new content
                    // UNLESS user has manually scrolled away
                    if (!self.user_scrolled_away) {
                        try self.maintainBottomAnchor();
                    }

                    // Render with correct scroll position already set
                    _ = try message_renderer.redrawScreen(self);

                    // Always update cursor to bottom during streaming (unless user scrolled away)
                    if (!self.user_scrolled_away) {
                        self.updateCursorToBottom();
                    }

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
                // Move cursor to home WITHOUT clearing - prevents flicker
                try writer.writeAll("\x1b[H");
                self.clickable_areas.clearRetainingCapacity();
                self.valid_cursor_positions.clearRetainingCapacity();

                var absolute_y: usize = 1;
                for (self.messages.items, 0..) |_, i| {
                    const message = &self.messages.items[i];
                    // Draw message (handles both thinking and content)
                    try message_renderer.drawMessage(self, writer, message, i, &absolute_y);
                }

                // Position cursor after last message content to clear any leftover content
                const screen_y_for_clear = if (absolute_y > self.scroll_y)
                    (absolute_y - self.scroll_y) + 1
                else
                    1;

                // Only clear if there's space between content and input field
                if (screen_y_for_clear < self.terminal_size.height - 2) {
                    try writer.print("\x1b[{d};1H\x1b[J", .{screen_y_for_clear});
                }

                // Draw input field at the bottom (3 rows before status)
                try message_renderer.drawInputField(self, writer);
                try ui.drawTaskbar(self, writer);
                try buffered_writer.flush();
            }

            // If streaming is active OR tools are executing, don't block - continue main loop to process chunks/tools
            if (self.streaming_active or self.pending_tool_execution != null) {
                // Read input non-blocking
                var read_buffer: [128]u8 = undefined;
                const bytes_read = ui.c.read(ui.c.STDIN_FILENO, &read_buffer, read_buffer.len);
                if (bytes_read > 0) {
                    const input = read_buffer[0..@intCast(bytes_read)];
                    var should_redraw = false;
                    if (try ui.handleInput(self, input, &should_redraw)) {
                        return;
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

            // View height accounts for input field + status bar: total height - 4 rows
            // Adjust viewport to keep cursor in view
            const view_height = self.terminal_size.height - 4;
            if (self.cursor_y < self.scroll_y + 1) {
                self.scroll_y = if (self.cursor_y > 0) self.cursor_y - 1 else 0;
            }
            if (self.cursor_y > self.scroll_y + view_height) {
                self.scroll_y = self.cursor_y - view_height;
            }
        }
    }
};
