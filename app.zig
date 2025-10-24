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
const tool_executor_module = @import("tool_executor.zig");
const zvdb = @import("zvdb/src/zvdb.zig");
const embeddings_module = @import("embeddings.zig");
const IndexingQueue = @import("graphrag/indexing_queue.zig").IndexingQueue;
// TODO: Re-implement with LLM-based indexing
// const graphrag_indexer = @import("graphrag/indexer.zig");
const graphrag_query = @import("graphrag/query.zig");

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
    num_ctx: usize,
    num_predict: isize,
    // GraphRAG summaries that need to be freed after thread completes
    graphrag_summaries: [][]const u8,
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
    permission_response: ?permission.PermissionMode = null, // Set by UI, consumed by tool_executor
    // Tool execution state machine
    tool_executor: tool_executor_module.ToolExecutor,
    // Phase 1: Task management state
    state: AppState,
    app_context: AppContext,
    max_iterations: usize = 10, // Master loop iteration limit
    // Auto-scroll state (receipt printer mode)
    user_scrolled_away: bool = false, // Tracks if user manually scrolled during streaming
    // Graph RAG components
    vector_store: ?*zvdb.HNSW(f32) = null,
    embedder: ?*embeddings_module.EmbeddingsClient = null,
    indexing_queue: ?*IndexingQueue = null,

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

        // Initialize Graph RAG components if enabled
        var vector_store_opt: ?*zvdb.HNSW(f32) = null;
        var embedder_opt: ?*embeddings_module.EmbeddingsClient = null;
        var indexing_queue_opt: ?*IndexingQueue = null;

        if (config.graph_rag_enabled) {
            if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
                std.debug.print("[INIT] Graph RAG enabled, initializing vector store and embedder...\n", .{});
            }

            // Initialize vector store
            const vs = allocator.create(zvdb.HNSW(f32)) catch |err| blk: {
                std.debug.print("Warning: Failed to create vector store: {}\n", .{err});
                break :blk null;
            };

            if (vs) |store| {
                errdefer allocator.destroy(store);

                // Try to load existing index, fall back to creating new one
                store.* = zvdb.HNSW(f32).load(allocator, config.zvdb_path) catch |err| blk: {
                    if (err != error.FileNotFound) {
                        std.debug.print("Warning: Failed to load vector store from {s}: {}\n", .{ config.zvdb_path, err });
                    }
                    // Create new index (m=16, ef_construction=200)
                    break :blk zvdb.HNSW(f32).init(allocator, 16, 200);
                };

                vector_store_opt = store;

                if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
                    std.debug.print("[INIT] Vector store initialized successfully\n", .{});
                }

                // Initialize embeddings client
                const emb = allocator.create(embeddings_module.EmbeddingsClient) catch |err| blk: {
                    std.debug.print("Warning: Failed to create embeddings client: {}\n", .{err});
                    break :blk null;
                };

                if (emb) |client| {
                    client.* = embeddings_module.EmbeddingsClient.init(allocator, config.ollama_host);
                    embedder_opt = client;

                    if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
                        std.debug.print("[INIT] Embeddings client initialized (host: {s}, model: {s})\n", .{ config.ollama_host, config.embedding_model });
                    }

                    // Initialize background indexing infrastructure
                    const queue = allocator.create(IndexingQueue) catch |err| blk: {
                        std.debug.print("Warning: Failed to create indexing queue: {}\n", .{err});
                        break :blk null;
                    };

                    if (queue) |q| {
                        q.* = IndexingQueue.init(allocator);
                        indexing_queue_opt = q;

                        if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
                            std.debug.print("[INIT] Indexing queue initialized\n", .{});
                        }

                        // Note: We can't spawn the worker thread yet because app_context
                        // isn't initialized until after App.init() completes
                        // The thread will be spawned in fixContextPointers() instead
                    }
                } else {
                    // Failed to create embedder - clean up vector store
                    store.deinit();
                    allocator.destroy(store);
                    vector_store_opt = null;
                }
            }
        }


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
            .tool_executor = tool_executor_module.ToolExecutor.init(allocator),
            // Phase 1: Initialize state (session-ephemeral)
            .state = AppState.init(allocator),
            .app_context = undefined, // Will be fixed by caller after struct is in final location
            .vector_store = vector_store_opt,
            .embedder = embedder_opt,
            .indexing_queue = indexing_queue_opt,
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
            .ollama_client = &self.ollama_client,
            .vector_store = self.vector_store,
            .embedder = self.embedder,
            .indexing_queue = self.indexing_queue,
        };

        // No background worker thread - GraphRAG now runs sequentially after each response
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
            ctx.app.config.enable_thinking, // Use config setting
            ctx.format,
            if (ctx.tools.len > 0) ctx.tools else null, // Pass tools to model
            ctx.keep_alive,
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

    // Helper to detect read_file tool results
    fn isReadFileResult(content: []const u8) bool {
        return mem.indexOf(u8, content, "File: ") != null and
               mem.indexOf(u8, content, "Total lines:") != null;
    }

    // Helper to extract file path from read_file result
    fn extractFilePathFromResult(content: []const u8) ?[]const u8 {
        const file_prefix = "File: ";
        const start_idx = mem.indexOf(u8, content, file_prefix) orelse return null;
        const after_prefix = content[start_idx + file_prefix.len ..];

        const end_idx = mem.indexOf(u8, after_prefix, "\n") orelse return null;
        return after_prefix[0..end_idx];
    }

    // Compress message history by replacing read_file results with Graph RAG summaries
    // Tracks allocated summaries in the provided list so caller can free them
    fn compressMessageHistoryWithTracking(
        self: *App,
        messages: []const ollama.ChatMessage,
        allocated_summaries: *std.ArrayListUnmanaged([]const u8),
    ) ![]ollama.ChatMessage {
        // Skip compression if Graph RAG is disabled or not initialized
        if (!self.config.graph_rag_enabled or self.vector_store == null) {
            return try self.allocator.dupe(ollama.ChatMessage, messages);
        }

        var compressed = std.ArrayListUnmanaged(ollama.ChatMessage){};
        errdefer compressed.deinit(self.allocator);

        for (messages) |msg| {
            // Check if this is a tool result from read_file
            if (mem.eql(u8, msg.role, "tool") and isReadFileResult(msg.content)) {
                // Extract file path from content
                const file_path = extractFilePathFromResult(msg.content) orelse {
                    // Can't extract path, keep original
                    try compressed.append(self.allocator, msg);
                    continue;
                };

                // Check if file was indexed
                if (!self.state.wasFileIndexed(file_path)) {
                    // Not indexed, keep original
                    try compressed.append(self.allocator, msg);
                    continue;
                }

                // Try to generate Graph RAG summary
                const summary_opt = graphrag_query.summarizeFileForHistory(
                    self.allocator,
                    self.vector_store.?,
                    file_path,
                    self.config.max_chunks_in_history,
                ) catch |err| blk: {
                    // Fallback to simple summary on error
                    std.debug.print("Warning: Graph RAG summarization failed: {}\n", .{err});
                    break :blk graphrag_query.createFallbackSummary(self.allocator, file_path, msg.content) catch null;
                };

                if (summary_opt) |summary| {
                    // Track this allocation so caller can free it
                    try allocated_summaries.append(self.allocator, summary);

                    // Replace content with summary
                    var compressed_msg = msg;
                    compressed_msg.content = summary;
                    try compressed.append(self.allocator, compressed_msg);
                } else {
                    // Ultimate fallback: keep original
                    try compressed.append(self.allocator, msg);
                }
            } else {
                // Keep other messages as-is
                try compressed.append(self.allocator, msg);
            }
        }

        return compressed.toOwnedSlice(self.allocator);
    }

    // Internal method to start streaming with current message history
    fn startStreaming(self: *App, format: ?[]const u8) !void {
        // Set streaming flag FIRST - before any redraws
        // This ensures the status bar shows "AI is responding..." immediately
        self.streaming_active = true;

        // Reset tool call depth when starting a new user message
        // (This will be set correctly by continueStreaming for tool calls)

        // Prepare message history for Ollama with GraphRAG compression
        var ollama_messages = std.ArrayListUnmanaged(ollama.ChatMessage){};
        defer ollama_messages.deinit(self.allocator);

        // Track allocated summaries - will be transferred to thread context
        var allocated_summaries = std.ArrayListUnmanaged([]const u8){};

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

        // Apply GraphRAG compression to replace read_file results with summaries
        if (self.config.graph_rag_enabled and self.vector_store != null) {
            const compressed_messages = try self.compressMessageHistoryWithTracking(
                ollama_messages.items,
                &allocated_summaries,
            );
            defer self.allocator.free(compressed_messages);

            // Replace ollama_messages with compressed version
            ollama_messages.clearRetainingCapacity();
            try ollama_messages.appendSlice(self.allocator, compressed_messages);
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
        const summaries_slice = try allocated_summaries.toOwnedSlice(self.allocator);

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
            .num_ctx = self.config.num_ctx,
            .num_predict = self.config.num_predict,
            .graphrag_summaries = summaries_slice,
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

    // Process pending Graph RAG indexing in background (post-response)
    // User can press any key to skip and continue chatting
    fn processPendingIndexing(self: *App) !void {
        const total_files = self.state.pending_index_files.items.len;
        if (total_files == 0) return;

        // Show initial status
        const start_msg = try std.fmt.allocPrint(
            self.allocator,
            "📊 Indexing {d} pending file{s}... (press any key to skip)",
            .{ total_files, if (total_files == 1) "" else "s" },
        );
        defer self.allocator.free(start_msg);

        const start_processed = try markdown.processMarkdown(self.allocator, start_msg);
        try self.messages.append(self.allocator, .{
            .role = .system,
            .content = try self.allocator.dupe(u8, start_msg),
            .processed_content = start_processed,
            .thinking_expanded = false,
            .timestamp = std.time.milliTimestamp(),
        });

        // Redraw to show message
        if (!self.user_scrolled_away) {
            try self.maintainBottomAnchor();
        }
        _ = try message_renderer.redrawScreen(self);
        if (!self.user_scrolled_away) {
            self.updateCursorToBottom();
        }

        const indexed_count: usize = 0; // TODO: Will be used when LLM indexer is implemented
        var skipped_count: usize = 0;

        // Process each file in queue
        while (self.state.popPendingIndexFile()) |pending| {
            defer {
                self.allocator.free(pending.path);
                self.allocator.free(pending.content);
            }

            // Check for user input (non-blocking) - any key skips indexing
            var read_buffer: [128]u8 = undefined;
            const bytes_read = ui.c.read(ui.c.STDIN_FILENO, &read_buffer, read_buffer.len);
            if (bytes_read > 0) {
                // User pressed a key - stop indexing
                const remaining = self.state.pending_index_files.items.len;

                // Clear the queue
                for (self.state.pending_index_files.items) |remaining_file| {
                    self.allocator.free(remaining_file.path);
                    self.allocator.free(remaining_file.content);
                }
                self.state.pending_index_files.clearRetainingCapacity();

                const skip_msg = try std.fmt.allocPrint(
                    self.allocator,
                    "⏭️  Skipped indexing {d} remaining file{s}",
                    .{ remaining + 1, if (remaining + 1 == 1) "" else "s" },
                );
                const skip_processed = try markdown.processMarkdown(self.allocator, skip_msg);
                try self.messages.append(self.allocator, .{
                    .role = .system,
                    .content = skip_msg,
                    .processed_content = skip_processed,
                    .thinking_expanded = false,
                    .timestamp = std.time.milliTimestamp(),
                });

                // Redraw and return
                if (!self.user_scrolled_away) {
                    try self.maintainBottomAnchor();
                }
                _ = try message_renderer.redrawScreen(self);
                if (!self.user_scrolled_away) {
                    self.updateCursorToBottom();
                }

                return;
            }

            // Show progress for current file
            const progress_msg = try std.fmt.allocPrint(
                self.allocator,
                "  Indexing {s}...",
                .{pending.path},
            );
            defer self.allocator.free(progress_msg);

            const progress_processed = try markdown.processMarkdown(self.allocator, progress_msg);
            try self.messages.append(self.allocator, .{
                .role = .system,
                .content = try self.allocator.dupe(u8, progress_msg),
                .processed_content = progress_processed,
                .thinking_expanded = false,
                .timestamp = std.time.milliTimestamp(),
            });

            // Redraw to show progress
            if (!self.user_scrolled_away) {
                try self.maintainBottomAnchor();
            }
            _ = try message_renderer.redrawScreen(self);
            if (!self.user_scrolled_away) {
                self.updateCursorToBottom();
            }

            // TODO: Re-implement with LLM-based indexing
            // Perform indexing
            //if (self.vector_store != null and self.embedder != null) {
            //    const num_chunks = graphrag_indexer.indexFile(
            //        self.allocator,
            //        self.vector_store.?,
            //        self.embedder.?,
            //        pending.path,
            //        pending.content,
            //        self.config.embedding_model,
            //    ) catch |err| {
            //        // Indexing failed - show error and skip
            //        skipped_count += 1;
            //
            //        const error_msg = try std.fmt.allocPrint(
            //            self.allocator,
            //            "  ✗ Failed to index {s}: {}",
            //            .{ pending.path, err },
            //        );
            //        const error_processed = try markdown.processMarkdown(self.allocator, error_msg);
            //        try self.messages.append(self.allocator, .{
            //            .role = .system,
            //            .content = error_msg,
            //            .processed_content = error_processed,
            //            .thinking_expanded = false,
            //            .timestamp = std.time.milliTimestamp(),
            //        });
            //
            //        // Redraw and continue to next file
            //        if (!self.user_scrolled_away) {
            //            try self.maintainBottomAnchor();
            //        }
            //        _ = try message_renderer.redrawScreen(self);
            //        if (!self.user_scrolled_away) {
            //            self.updateCursorToBottom();
            //        }
            //
            //        continue;
            //    };
            //
            //    // Success - mark as indexed
            //    try self.state.markFileAsIndexed(pending.path);
            //    indexed_count += 1;
            //
            //    const success_msg = try std.fmt.allocPrint(
            //        self.allocator,
            //        "  ✓ Indexed {s} ({d} chunk{s})",
            //        .{ pending.path, num_chunks, if (num_chunks == 1) "" else "s" },
            //    );
            //    const success_processed = try markdown.processMarkdown(self.allocator, success_msg);
            //    try self.messages.append(self.allocator, .{
            //        .role = .system,
            //        .content = success_msg,
            //        .processed_content = success_processed,
            //        .thinking_expanded = false,
            //        .timestamp = std.time.milliTimestamp(),
            //    });
            //
            //    // Redraw to show success
            //    if (!self.user_scrolled_away) {
            //        try self.maintainBottomAnchor();
            //    }
            //    _ = try message_renderer.redrawScreen(self);
            //    if (!self.user_scrolled_away) {
            //        self.updateCursorToBottom();
            //    }
            //}
            if (self.vector_store != null and self.embedder != null) {
                // Temporary: skip indexing until LLM-based indexer is implemented
                skipped_count += 1;
            } else {
                skipped_count += 1;
            }
        }

        // Show completion summary
        const summary_msg = if (skipped_count > 0)
            try std.fmt.allocPrint(
                self.allocator,
                "✅ Indexing complete ({d} indexed, {d} skipped)",
                .{ indexed_count, skipped_count },
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "✅ Indexing complete ({d} file{s} indexed)",
                .{ indexed_count, if (indexed_count == 1) "" else "s" },
            );

        const summary_processed = try markdown.processMarkdown(self.allocator, summary_msg);
        try self.messages.append(self.allocator, .{
            .role = .system,
            .content = summary_msg,
            .processed_content = summary_processed,
            .thinking_expanded = false,
            .timestamp = std.time.milliTimestamp(),
        });

        // Final redraw
        if (!self.user_scrolled_away) {
            try self.maintainBottomAnchor();
        }
        _ = try message_renderer.redrawScreen(self);
        if (!self.user_scrolled_away) {
            self.updateCursorToBottom();
        }
    }

    pub fn deinit(self: *App) void {
        // Clean up indexing queue
        if (self.indexing_queue) |queue| {
            queue.deinit();
            self.allocator.destroy(queue);
        }

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

        // Clean up tool executor
        self.tool_executor.deinit();

        // Phase 1: Clean up state
        self.state.deinit();

        // Clean up Graph RAG components
        if (self.vector_store) |vs| {
            // Save index to disk before cleanup
            vs.save(self.config.zvdb_path) catch |err| {
                std.debug.print("Warning: Failed to save vector store: {}\n", .{err});
            };
            vs.deinit();
            self.allocator.destroy(vs);
        }

        if (self.embedder) |emb| {
            emb.deinit();
            self.allocator.destroy(emb);
        }
    }

    /// Progress callback context for GraphRAG indexing
    const IndexingProgressContext = struct {
        app: *App,
        current_message_idx: ?usize = null, // Track which message to update
        accumulated_content: std.ArrayListUnmanaged(u8) = .{},
    };

    /// Progress callback for GraphRAG indexing - updates UI with streaming content
    fn indexingProgressCallback(user_data: *anyopaque, update_type: @import("graphrag/llm_indexer.zig").ProgressUpdateType, message: []const u8) void {
        const ctx = @as(*IndexingProgressContext, @ptrCast(@alignCast(user_data)));

        // Accumulate the message content
        ctx.accumulated_content.appendSlice(ctx.app.allocator, message) catch return;

        // Find or create the progress message
        if (ctx.current_message_idx == null) {
            // Create new system message for this indexing progress
            const content = ctx.app.allocator.dupe(u8, ctx.accumulated_content.items) catch return;
            const processed = markdown.processMarkdown(ctx.app.allocator, content) catch return;

            ctx.app.messages.append(ctx.app.allocator, .{
                .role = .system,
                .content = content,
                .processed_content = processed,
                .thinking_expanded = false,
                .timestamp = std.time.milliTimestamp(),
            }) catch return;

            ctx.current_message_idx = ctx.app.messages.items.len - 1;
        } else {
            // Update existing message
            const idx = ctx.current_message_idx.?;
            var msg = &ctx.app.messages.items[idx];

            // Free old content
            ctx.app.allocator.free(msg.content);
            for (msg.processed_content.items) |*item| {
                item.deinit(ctx.app.allocator);
            }
            msg.processed_content.deinit(ctx.app.allocator);

            // Update with new content
            msg.content = ctx.app.allocator.dupe(u8, ctx.accumulated_content.items) catch return;
            msg.processed_content = markdown.processMarkdown(ctx.app.allocator, msg.content) catch return;
        }

        // Redraw screen to show progress
        if (!ctx.app.user_scrolled_away) {
            ctx.app.maintainBottomAnchor() catch return;
        }
        _ = message_renderer.redrawScreen(ctx.app) catch return;
        if (!ctx.app.user_scrolled_away) {
            ctx.app.updateCursorToBottom();
        }

        _ = update_type; // Unused for now, but available for future formatting
    }

    /// SECONDARY LOOP: Process all queued files for GraphRAG indexing
    ///
    /// This is the Graph RAG "secondary loop" that runs AFTER the main conversation
    /// turn completes. It processes files queued by read_file during tool execution.
    ///
    /// Flow:
    /// 1. Main loop: User asks question → LLM responds → Tools execute → read_file queues files
    /// 2. Main loop: Response completes (no more tool calls)
    /// 3. Secondary loop: THIS FUNCTION runs to process the queue
    /// 4. For each file: LLM analyzes → Creates graph → Embeds → Stores in vector DB
    /// 5. Return to idle state (waiting for next user message)
    ///
    /// This separation ensures:
    /// - Main loop stays responsive (no blocking during conversation)
    /// - Graph RAG processing is batched and efficient
    /// - User sees clear progress updates during indexing
    fn processQueuedFiles(self: *App) !void {
        if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
            std.debug.print("[GRAPHRAG] processQueuedFiles called\n", .{});
        }

        const queue = self.indexing_queue orelse {
            if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
                std.debug.print("[GRAPHRAG] No indexing queue available\n", .{});
            }
            return;
        };

        if (queue.isEmpty()) {
            if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
                std.debug.print("[GRAPHRAG] Queue is empty\n", .{});
            }
            return; // Nothing to process
        }

        const count = queue.size();
        const llm_indexer = @import("graphrag/llm_indexer.zig");

        // Show user we're indexing
        const indexing_msg = try std.fmt.allocPrint(
            self.allocator,
            "\n🔍 Indexing {d} file{s}...",
            .{ count, if (count == 1) "" else "s" },
        );
        const indexing_processed = try markdown.processMarkdown(self.allocator, indexing_msg);
        try self.messages.append(self.allocator, .{
            .role = .system,
            .content = indexing_msg,
            .processed_content = indexing_processed,
            .thinking_expanded = false,
            .timestamp = std.time.milliTimestamp(),
        });

        // Redraw to show indexing message
        if (!self.user_scrolled_away) {
            try self.maintainBottomAnchor();
        }
        _ = try message_renderer.redrawScreen(self);
        if (!self.user_scrolled_away) {
            self.updateCursorToBottom();
        }

        // Drain all tasks from queue
        const tasks = try queue.drainAll();
        defer {
            for (tasks) |*task| task.deinit();
            self.allocator.free(tasks);
        }

        // Process each file with main model
        for (tasks, 1..) |task, i| {
            const progress_msg = try std.fmt.allocPrint(
                self.allocator,
                "  [{d}/{d}] {s}\n",
                .{ i, tasks.len, task.file_path },
            );
            const progress_processed = try markdown.processMarkdown(self.allocator, progress_msg);
            try self.messages.append(self.allocator, .{
                .role = .system,
                .content = progress_msg,
                .processed_content = progress_processed,
                .thinking_expanded = false,
                .timestamp = std.time.milliTimestamp(),
            });

            // Redraw to show progress
            if (!self.user_scrolled_away) {
                try self.maintainBottomAnchor();
            }
            _ = try message_renderer.redrawScreen(self);
            if (!self.user_scrolled_away) {
                self.updateCursorToBottom();
            }

            // Set up progress context for streaming updates
            var progress_ctx = IndexingProgressContext{
                .app = self,
            };
            defer progress_ctx.accumulated_content.deinit(self.allocator);

            // Use main model for indexing with progress callback
            llm_indexer.indexFile(
                self.allocator,
                &self.ollama_client,
                self.config.model, // Use main model, not indexing_model
                &self.app_context,
                task.file_path,
                task.content,
                indexingProgressCallback,
                @ptrCast(&progress_ctx),
            ) catch |err| {
                const error_msg = try std.fmt.allocPrint(
                    self.allocator,
                    "    ⚠️  Indexing failed: {}",
                    .{err},
                );
                const error_processed = try markdown.processMarkdown(self.allocator, error_msg);
                try self.messages.append(self.allocator, .{
                    .role = .system,
                    .content = error_msg,
                    .processed_content = error_processed,
                    .thinking_expanded = false,
                    .timestamp = std.time.milliTimestamp(),
                });
                continue;
            };

            // Mark file as indexed in state
            self.state.markFileAsIndexed(task.file_path) catch |err| {
                if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
                    std.debug.print("[GRAPHRAG] Failed to mark file as indexed: {}\n", .{err});
                }
            };
        }

        // Show completion
        const complete_msg = try self.allocator.dupe(u8, "✓ Indexing complete\n");
        const complete_processed = try markdown.processMarkdown(self.allocator, complete_msg);
        try self.messages.append(self.allocator, .{
            .role = .system,
            .content = complete_msg,
            .processed_content = complete_processed,
            .thinking_expanded = false,
            .timestamp = std.time.milliTimestamp(),
        });

        // Final redraw
        if (!self.user_scrolled_away) {
            try self.maintainBottomAnchor();
        }
        _ = try message_renderer.redrawScreen(self);
        if (!self.user_scrolled_away) {
            self.updateCursorToBottom();
        }
    }

    pub fn run(self: *App, app_tui: *ui.Tui) !void {
        _ = app_tui; // Will be used later for editor integration

        // Buffers for accumulating stream data
        var thinking_accumulator = std.ArrayListUnmanaged(u8){};
        defer thinking_accumulator.deinit(self.allocator);
        var content_accumulator = std.ArrayListUnmanaged(u8){};
        defer content_accumulator.deinit(self.allocator);

        while (true) {
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
                                if (!self.user_scrolled_away) {
                                    try self.maintainBottomAnchor();
                                }
                                _ = try message_renderer.redrawScreen(self);
                                if (!self.user_scrolled_away) {
                                    self.updateCursorToBottom();
                                }
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

                                try self.messages.append(self.allocator, .{
                                    .role = .system,
                                    .content = display_content,
                                    .processed_content = display_processed,
                                    .thinking_expanded = false,
                                    .timestamp = std.time.milliTimestamp(),
                                });

                                // Receipt printer mode: auto-scroll to show tool results
                                if (!self.user_scrolled_away) {
                                    try self.maintainBottomAnchor();
                                }
                                _ = try message_renderer.redrawScreen(self);
                                if (!self.user_scrolled_away) {
                                    self.updateCursorToBottom();
                                }

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

                                // Receipt printer mode: auto-scroll to show tool result
                                if (!self.user_scrolled_away) {
                                    try self.maintainBottomAnchor();
                                }
                                _ = try message_renderer.redrawScreen(self);
                                if (!self.user_scrolled_away) {
                                    self.updateCursorToBottom();
                                }

                                // Tell executor to advance to next tool
                                self.tool_executor.advanceAfterExecution();
                            }
                        } else {
                            // Just redraw for other states
                            if (!self.user_scrolled_away) {
                                try self.maintainBottomAnchor();
                            }
                            _ = try message_renderer.redrawScreen(self);
                            if (!self.user_scrolled_away) {
                                self.updateCursorToBottom();
                            }
                        }
                    },

                    .iteration_complete => {
                        // All tools executed - increment iteration and continue streaming
                        self.state.iteration_count += 1;
                        self.tool_call_depth = 0; // Reset for next iteration

                        if (!self.user_scrolled_away) {
                            try self.maintainBottomAnchor();
                        }
                        _ = try message_renderer.redrawScreen(self);
                        if (!self.user_scrolled_away) {
                            self.updateCursorToBottom();
                        }

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
                            .role = .system,
                            .content = msg,
                            .processed_content = processed,
                            .thinking_expanded = false,
                            .timestamp = std.time.milliTimestamp(),
                        });

                        if (!self.user_scrolled_away) {
                            try self.maintainBottomAnchor();
                        }
                        _ = try message_renderer.redrawScreen(self);
                        if (!self.user_scrolled_away) {
                            self.updateCursorToBottom();
                        }
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
                                // Free GraphRAG summaries that were allocated during compression
                                for (ctx.graphrag_summaries) |summary| {
                                    self.allocator.free(summary);
                                }
                                self.allocator.free(ctx.graphrag_summaries);

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

                                // Start tool executor with new tool calls
                                self.tool_executor.startExecution(tool_calls);

                                // Re-lock mutex before continuing
                                self.stream_mutex.lock();
                            }
                        } else {
                            // No tool calls - response is complete
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

                            self.processQueuedFiles() catch |err| {
                                if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
                                    std.debug.print("[GRAPHRAG] Error in secondary loop: {}\n", .{err});
                                }
                            };

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
                }
                // Continue main loop immediately to check for more chunks or execute next tool
                // Small sleep to avoid busy-waiting and reduce CPU usage
                std.Thread.sleep(10 * std.time.ns_per_ms); // 10ms
            } else {
                // Normal blocking mode when not streaming

                // Process pending Graph RAG indexing during idle time (post-response)
                if (self.state.hasPendingIndexing()) {
                    try self.processPendingIndexing();
                }

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
