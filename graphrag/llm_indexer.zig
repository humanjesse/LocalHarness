// LLM-based file indexer - Uses tool calling to build knowledge graphs
const std = @import("std");
const ollama = @import("../ollama.zig");
const llm_provider_module = @import("../llm_provider.zig");
const context_module = @import("../context.zig");
const indexing_tools = @import("indexing_tools.zig");
const indexing_tool_registry = @import("indexing_tool_registry.zig");
const GraphBuilder = @import("graph_builder.zig").GraphBuilder;
const zvdb = @import("../zvdb/src/zvdb.zig");

const AppContext = context_module.AppContext;

fn isDebugEnabled() bool {
    return std.posix.getenv("DEBUG_GRAPHRAG") != null;
}

/// Format nodes as a clean bullet list for prompts
/// Caller must free the returned string
fn formatNodesForPrompt(allocator: std.mem.Allocator, graph_builder: *const GraphBuilder) ![]const u8 {
    if (graph_builder.getNodeCount() == 0) {
        return try allocator.dupe(u8, "(no nodes created yet)");
    }

    var buffer = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer buffer.deinit(allocator);

    var iter = graph_builder.nodes.iterator();
    while (iter.next()) |entry| {
        const node = entry.value_ptr.*;

        // Format: "- {type}:{name} (lines {start}-{end}): {summary}"
        try buffer.appendSlice(allocator, "- ");
        try buffer.appendSlice(allocator, node.node_type.toString());
        try buffer.appendSlice(allocator, ":");
        try buffer.appendSlice(allocator, node.name);

        if (node.start_line) |start| {
            if (node.end_line) |end| {
                const line_info = try std.fmt.allocPrint(allocator, " (lines {d}-{d})", .{start, end});
                defer allocator.free(line_info);
                try buffer.appendSlice(allocator, line_info);
            }
        }

        try buffer.appendSlice(allocator, ": ");
        try buffer.appendSlice(allocator, node.summary);
        try buffer.appendSlice(allocator, "\n");
    }

    return try buffer.toOwnedSlice(allocator);
}

/// System prompt that guides the LLM to analyze files and build knowledge graphs
const INDEXING_SYSTEM_PROMPT =
    \\Extract entities FAST. Call create_node for every function/struct/concept you see - do NOT deliberate.
    \\Work quickly: scan file, call tools immediately. Short summaries only.
;

// Use unified types from agents module (no duplication!)
const agents = @import("../agents.zig");
const ProgressCallback = agents.ProgressCallback;
const ProgressUpdateType = agents.ProgressUpdateType;

/// Context for streaming callback
const StreamContext = struct {
    allocator: std.mem.Allocator,
    tool_calls: std.ArrayListUnmanaged(ollama.ToolCall),
    content_buffer: std.ArrayListUnmanaged(u8),
    // Optional progress callback
    progress_callback: ?ProgressCallback = null,
    progress_user_data: ?*anyopaque = null,
};

/// Callback for streaming LLM response
fn streamCallback(
    ctx: *StreamContext,
    thinking_chunk: ?[]const u8,
    content_chunk: ?[]const u8,
    tool_calls_chunk: ?[]const ollama.ToolCall,
) void {
    if (isDebugEnabled()) {
        if (thinking_chunk) |t| {
            std.debug.print("[INDEXER CALLBACK] Thinking chunk: {s}\n", .{t[0..@min(100, t.len)]});
        } else {
            std.debug.print("[INDEXER CALLBACK] No thinking chunk\n", .{});
        }
        if (content_chunk) |c| {
            std.debug.print("[INDEXER CALLBACK] Content chunk: {s}\n", .{c[0..@min(100, c.len)]});
        }
        if (tool_calls_chunk) |calls| {
            std.debug.print("[INDEXER CALLBACK] Tool calls chunk: {d} calls\n", .{calls.len});
        }
    }

    // Notify progress callback if set
    if (ctx.progress_callback) |callback| {
        if (thinking_chunk) |chunk| {
            callback(ctx.progress_user_data.?, .thinking, chunk);
        }
        if (content_chunk) |chunk| {
            callback(ctx.progress_user_data.?, .content, chunk);
        }
    }

    // Collect content chunks (for debugging)
    if (content_chunk) |chunk| {
        ctx.content_buffer.appendSlice(ctx.allocator, chunk) catch |err| {
            if (isDebugEnabled()) {
                std.debug.print("[INDEXER] Error appending content chunk: {}\n", .{err});
            }
        };
    }

    // Collect tool calls
    if (tool_calls_chunk) |calls| {
        for (calls) |call| {
            // Notify progress callback about tool call
            if (ctx.progress_callback) |callback| {
                const msg = std.fmt.allocPrint(ctx.allocator, "Calling {s}...", .{call.function.name}) catch continue;
                defer ctx.allocator.free(msg);
                callback(ctx.progress_user_data.?, .tool_call, msg);
            }

            // Deep copy the tool call
            const copied_call = ollama.ToolCall{
                .id = if (call.id) |id| ctx.allocator.dupe(u8, id) catch continue else null,
                .type = if (call.type) |t| ctx.allocator.dupe(u8, t) catch continue else null,
                .function = .{
                    .name = ctx.allocator.dupe(u8, call.function.name) catch continue,
                    .arguments = ctx.allocator.dupe(u8, call.function.arguments) catch continue,
                },
            };

            ctx.tool_calls.append(ctx.allocator, copied_call) catch |err| {
                if (isDebugEnabled()) {
                    std.debug.print("[INDEXER] Error appending tool call: {}\n", .{err});
                }
            };
        }
    }
}

/// Main indexing function - analyzes a file and stores its knowledge graph
/// Simple approach: just like the main loop
pub fn indexFile(
    allocator: std.mem.Allocator,
    llm_provider: *llm_provider_module.LLMProvider,
    indexing_model: []const u8,
    app_context: *const AppContext,
    file_path: []const u8,
    content: []const u8,
    progress_callback: ?ProgressCallback,
    progress_user_data: ?*anyopaque,
) !void {
    if (isDebugEnabled()) {
        std.debug.print("[INDEXER] Starting indexing for: {s} ({d} bytes)\n", .{ file_path, content.len });
    }

    // Build phase 1 user message: nodes only
    const user_prompt = try std.fmt.allocPrint(
        allocator,
        \\Use the create_node tool to create nodes for this file.
        \\
        \\File:
        \\{s}
    ,
        .{content},
    );
    // NOTE: Do NOT defer free user_prompt here - ownership transferred to messages

    // Get indexing tools from registry
    const tools = try indexing_tool_registry.getIndexingTools(allocator);
    defer {
        for (tools) |tool| {
            allocator.free(tool.function.name);
            allocator.free(tool.function.description);
            allocator.free(tool.function.parameters);
        }
        allocator.free(tools);
    }

    if (isDebugEnabled()) {
        std.debug.print("[INDEXER] Tools: {d}\n", .{tools.len});
    }

    // Initialize graph builder
    var graph_builder = GraphBuilder.init(allocator);
    defer graph_builder.deinit();

    var indexing_ctx = indexing_tool_registry.IndexingContext{
        .graph_builder = &graph_builder,
        .file_path = file_path,
        .stats = .{},
    };

    // Message history for iterations
    var messages = std.ArrayListUnmanaged(ollama.ChatMessage){};
    defer {
        for (messages.items) |msg| {
            allocator.free(msg.role);
            allocator.free(msg.content);
            if (msg.tool_call_id) |id| allocator.free(id);
            if (msg.tool_calls) |calls| {
                for (calls) |call| {
                    if (call.id) |cid| allocator.free(cid);
                    if (call.type) |t| allocator.free(t);
                    allocator.free(call.function.name);
                    allocator.free(call.function.arguments);
                }
                allocator.free(calls);
            }
        }
        messages.deinit(allocator);
    }

    // Add initial messages
    try messages.append(allocator, .{
        .role = try allocator.dupe(u8, "system"),
        .content = try allocator.dupe(u8, INDEXING_SYSTEM_PROMPT),
    });
    try messages.append(allocator, .{
        .role = try allocator.dupe(u8, "user"),
        .content = user_prompt, // Transfer ownership
    });

    // Notify progress
    if (progress_callback) |callback| {
        callback(progress_user_data.?, .thinking, "Analyzing file...");
    }

    // Iteration loop (max 2 iterations)
    const max_iterations: usize = 2;
    var current_iteration: usize = 0;

    while (current_iteration < max_iterations) : (current_iteration += 1) {
        if (isDebugEnabled()) {
            std.debug.print("[INDEXER] === Iteration {d}/{d} ===\n", .{ current_iteration + 1, max_iterations });
        }

        // Set up streaming context for this iteration
        var stream_ctx = StreamContext{
            .allocator = allocator,
            .tool_calls = .{},
            .content_buffer = .{},
            .progress_callback = progress_callback,
            .progress_user_data = progress_user_data,
        };
        defer {
            // Note: We move tool_calls to message history, so don't free them here
            stream_ctx.tool_calls.deinit(allocator);
            stream_ctx.content_buffer.deinit(allocator);
        }

        // Call LLM with current message history
        if (isDebugEnabled()) {
            std.debug.print("\n[INDEXER] ===== ITERATION {d} CALL =====\n", .{current_iteration + 1});
            std.debug.print("[INDEXER] Model: {s}\n", .{indexing_model});
            std.debug.print("[INDEXER] Messages: {d}\n", .{messages.items.len});
            for (messages.items, 0..) |msg, i| {
                std.debug.print("  [{d}] role={s}, content_len={d}", .{ i, msg.role, msg.content.len });
                if (msg.tool_calls) |tc| std.debug.print(", tool_calls={d}", .{tc.len});
                if (msg.tool_call_id) |_| std.debug.print(", has_tool_call_id", .{});
                std.debug.print("\n", .{});
                if (i < 2) { // Show first 2 messages in full
                    std.debug.print("      Content: {s}\n", .{msg.content[0..@min(200, msg.content.len)]});
                }
            }
            std.debug.print("[INDEXER] Think: {s}\n", .{if (app_context.config.enable_thinking) "true" else "false"});
            std.debug.print("[INDEXER] Format: null\n", .{});
            std.debug.print("[INDEXER] Tools.len: {d}\n", .{tools.len});
            std.debug.print("[INDEXER] Tools being passed: {s}\n", .{if (tools.len > 0) "YES" else "NO"});
            std.debug.print("[INDEXER] ===== END CALL INFO =====\n\n", .{});
        }

        // Get provider capabilities to check what's supported
        const caps = llm_provider.getCapabilities();

        // Enable thinking if provider supports it (beneficial for entity extraction reasoning)
        const enable_thinking = caps.supports_thinking;

        // Only pass keep_alive if provider supports it
        const keep_alive = if (caps.supports_keep_alive) app_context.config.model_keep_alive else null;

        llm_provider.chatStream(
            indexing_model,
            messages.items,
            enable_thinking, // Capability-aware thinking mode
            null,
            if (tools.len > 0) tools else null,
            keep_alive, // Capability-aware keep_alive
            app_context.config.num_ctx,
            10240, // Increased from 8192 - give model room to think and call tools naturally
            0.1, // temperature=0.1 - very focused, deterministic extraction
            1.3, // repeat_penalty=1.3 - penalize repetitive deliberation phrases (default: 1.1)
            &stream_ctx,
            streamCallback,
        ) catch |err| {
            if (isDebugEnabled()) {
                std.debug.print("[INDEXER] LLM call failed on iteration {d}: {}\n", .{ current_iteration, err });
            }
            return err;
        };

        const num_tool_calls = stream_ctx.tool_calls.items.len;

        if (isDebugEnabled()) {
            std.debug.print("[INDEXER] Iteration {d}: LLM returned {d} tool calls\n", .{ current_iteration + 1, num_tool_calls });
        }

        // If no tool calls on first iteration, that's an error
        if (current_iteration == 0 and num_tool_calls == 0) {
            if (isDebugEnabled()) {
                std.debug.print("[INDEXER] ERROR: No tool calls on first iteration\n", .{});
            }
            return error.NoToolCallsGenerated;
        }

        // If no tool calls on later iterations, we're done
        if (num_tool_calls == 0) {
            if (isDebugEnabled()) {
                std.debug.print("[INDEXER] No more tool calls - done\n", .{});
            }
            break;
        }

        // Add assistant message with tool calls to history
        const assistant_content = if (stream_ctx.content_buffer.items.len > 0)
            try allocator.dupe(u8, stream_ctx.content_buffer.items)
        else
            try allocator.dupe(u8, "");

        // Move tool calls to message history (transfer ownership)
        const tool_calls_owned = try stream_ctx.tool_calls.toOwnedSlice(allocator);

        try messages.append(allocator, .{
            .role = try allocator.dupe(u8, "assistant"),
            .content = assistant_content,
            .tool_calls = tool_calls_owned,
        });

        // Execute all tool calls and collect results
        for (tool_calls_owned, 0..) |call, idx| {
            // Execute tool using registry
            var result = indexing_tool_registry.executeIndexingToolCall(
                allocator,
                call,
                &indexing_ctx,
            ) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Tool execution failed: {}", .{err});
                defer allocator.free(msg);
                var error_result = try indexing_tool_registry.IndexingToolResult.err(allocator, msg);
                defer error_result.deinit(allocator);

                // Still add error result to history
                const tool_id = if (call.id) |id|
                    try allocator.dupe(u8, id)
                else
                    try std.fmt.allocPrint(allocator, "call_{d}", .{idx});

                const result_json = try error_result.toJSON(allocator);
                try messages.append(allocator, .{
                    .role = try allocator.dupe(u8, "tool"),
                    .content = result_json,
                    .tool_call_id = tool_id,
                });
                continue;
            };
            defer result.deinit(allocator);

            // Generate tool_call_id
            const tool_id = if (call.id) |id|
                try allocator.dupe(u8, id)
            else
                try std.fmt.allocPrint(allocator, "call_{d}", .{idx});

            // Convert result to JSON for LLM
            const result_json = try result.toJSON(allocator);

            // Add tool result to message history
            try messages.append(allocator, .{
                .role = try allocator.dupe(u8, "tool"),
                .content = result_json,
                .tool_call_id = tool_id,
            });

            // Notify progress callback
            if (progress_callback) |callback| {
                callback(progress_user_data.?, .tool_call, result.message);
            }

            if (isDebugEnabled()) {
                std.debug.print("[INDEXER] Tool result: {s}\n", .{result.message});
            }
        }

        // Show iteration summary
        if (progress_callback) |callback| {
            const summary = try std.fmt.allocPrint(
                allocator,
                "Iteration {d} complete: {d} nodes, {d} edges, {d} errors",
                .{ current_iteration + 1, indexing_ctx.stats.nodes_created, indexing_ctx.stats.edges_created, indexing_ctx.stats.errors },
            );
            defer allocator.free(summary);
            callback(progress_user_data.?, .content, summary);
        }

        if (isDebugEnabled()) {
            std.debug.print("[INDEXER] Iteration {d} stats: {d} nodes, {d} edges, {d} errors\n", .{
                current_iteration + 1,
                indexing_ctx.stats.nodes_created,
                indexing_ctx.stats.edges_created,
                indexing_ctx.stats.errors,
            });
        }

        // After iteration 1: condense message history and inject edge creation prompt
        if (current_iteration == 0 and num_tool_calls > 0) {
            if (isDebugEnabled()) {
                std.debug.print("[INDEXER] Condensing message history before iteration 2\n", .{});
                std.debug.print("[INDEXER] Current message count: {d}\n", .{messages.items.len});
            }

            // Extract the original file content from the first user message (index 1)
            const original_file_content = messages.items[1].content;

            // Format the nodes created in iteration 1
            const formatted_nodes = try formatNodesForPrompt(allocator, &graph_builder);
            defer allocator.free(formatted_nodes);

            // Build condensed user prompt with file content + node list
            const condensed_prompt = try std.fmt.allocPrint(
                allocator,
                \\{s}
                \\
                \\Nodes created:
                \\{s}
            ,
                .{original_file_content, formatted_nodes},
            );

            // Build edge creation prompt - focus only on create_edge tool
            const edge_prompt = try std.fmt.allocPrint(
                allocator,
                \\Use create_edge to establish relationships: which functions call which, what imports what, and how concepts relate.
            ,
                .{},
            );

            // Free old messages (except system and first user which we're keeping content from)
            // We need to free messages[2..] (assistant + tool results)
            for (messages.items[2..]) |msg| {
                allocator.free(msg.role);
                allocator.free(msg.content);
                if (msg.tool_call_id) |id| allocator.free(id);
                if (msg.tool_calls) |calls| {
                    for (calls) |call| {
                        if (call.id) |cid| allocator.free(cid);
                        if (call.type) |t| allocator.free(t);
                        allocator.free(call.function.name);
                        allocator.free(call.function.arguments);
                    }
                    allocator.free(calls);
                }
            }

            // Rebuild messages array with condensed context
            // Keep system message (index 0), replace user message content, discard rest
            allocator.free(messages.items[1].content); // Free old user content
            messages.items[1].content = condensed_prompt; // Replace with condensed version

            // Shrink array to just [system, condensed_user]
            messages.shrinkRetainingCapacity(2);

            // Add assistant acknowledgment (required to maintain user/assistant alternation)
            try messages.append(allocator, .{
                .role = try allocator.dupe(u8, "assistant"),
                .content = try allocator.dupe(u8, "Nodes created."),
            });

            // Add edge creation prompt as new user message
            try messages.append(allocator, .{
                .role = try allocator.dupe(u8, "user"),
                .content = edge_prompt,
            });

            if (isDebugEnabled()) {
                std.debug.print("[INDEXER] Condensed message count: {d}\n", .{messages.items.len});
                std.debug.print("[INDEXER] Added edge creation prompt for iteration 2\n", .{});
            }
        }
    }

    // Validate we created nodes
    if (graph_builder.getNodeCount() == 0) {
        if (isDebugEnabled()) {
            std.debug.print("[INDEXER] ERROR: No nodes created after {d} iterations\n", .{current_iteration});
        }
        return error.NoNodesCreated;
    }

    // Final graph summary
    if (isDebugEnabled()) {
        std.debug.print("[INDEXER] Final graph: {d} nodes, {d} edges\n", .{
            indexing_ctx.stats.nodes_created,
            indexing_ctx.stats.edges_created,
        });
        graph_builder.printSummary();
    }

    // Store graph in vector database
    try storeGraphInVectorDB(allocator, app_context, &graph_builder, file_path, progress_callback, progress_user_data);

    if (isDebugEnabled()) {
        std.debug.print("[INDEXER] Successfully indexed {s}: {d} nodes, {d} edges in {d} iterations\n", .{
            file_path,
            indexing_ctx.stats.nodes_created,
            indexing_ctx.stats.edges_created,
            current_iteration,
        });
    }

    // Emit completion event for UI finalization (unified with agent system)
    if (progress_callback) |callback| {
        callback(progress_user_data.?, .complete, "");
    }
}

/// Store the built graph in the vector database
fn storeGraphInVectorDB(
    allocator: std.mem.Allocator,
    app_context: *const AppContext,
    graph_builder: *GraphBuilder,
    file_path: []const u8,
    progress_callback: ?ProgressCallback,
    progress_user_data: ?*anyopaque,
) !void {
    const vector_store = app_context.vector_store orelse return error.VectorStoreNotInitialized;
    const embedder = app_context.embedder orelse return error.EmbedderNotInitialized;

    if (isDebugEnabled()) {
        std.debug.print("[INDEXER] Embedding and storing {d} nodes...\n", .{graph_builder.getNodeCount()});
    }

    // Notify about embedding phase
    if (progress_callback) |callback| {
        const msg = try std.fmt.allocPrint(allocator, "Creating embeddings for {d} nodes...", .{graph_builder.getNodeCount()});
        defer allocator.free(msg);
        callback(progress_user_data.?, .embedding, msg);
    }

    // Collect all node summaries for batch embedding
    var summaries = try std.ArrayList([]const u8).initCapacity(allocator, graph_builder.getNodeCount());
    defer summaries.deinit(allocator);

    var node_iter = graph_builder.nodes.iterator();
    while (node_iter.next()) |entry| {
        const node = entry.value_ptr.*;
        try summaries.append(allocator, node.summary);
    }

    // Batch embed all summaries
    const embeddings = try embedder.*.embedBatch(app_context.config.embedding_model, summaries.items);
    defer {
        for (embeddings) |embedding| {
            allocator.free(embedding);
        }
        allocator.free(embeddings);
    }

    if (isDebugEnabled()) {
        std.debug.print("[INDEXER] Generated {d} embeddings\n", .{embeddings.len});
    }

    // Notify about storage phase
    if (progress_callback) |callback| {
        const msg = try std.fmt.allocPrint(allocator, "Storing {d} nodes in vector database...", .{embeddings.len});
        defer allocator.free(msg);
        callback(progress_user_data.?, .storage, msg);
    }

    // Create mapping from node name to zvdb external ID
    var node_id_map = std.StringHashMap(u64).init(allocator);
    defer node_id_map.deinit();

    // Insert nodes into vector store with metadata
    node_iter = graph_builder.nodes.iterator();
    var i: usize = 0;
    while (node_iter.next()) |entry| : (i += 1) {
        const name = entry.key_ptr.*;
        const node = entry.value_ptr.*;
        const embedding = embeddings[i];

        // Create metadata structure
        var metadata = try zvdb.NodeMetadata.init(allocator, node.node_type.toString(), file_path);
        errdefer metadata.deinit(allocator);

        // Add attributes
        try metadata.setAttribute(allocator, "name", .{ .string = try allocator.dupe(u8, name) });
        try metadata.setAttribute(allocator, "is_public", .{ .bool = node.is_public });
        try metadata.setAttribute(allocator, "summary", .{ .string = try allocator.dupe(u8, node.summary) });

        // Insert into vector store and track external ID
        const external_id = try vector_store.*.insertWithMetadata(embedding, null, metadata);
        try node_id_map.put(name, external_id);
    }

    if (isDebugEnabled()) {
        std.debug.print("[INDEXER] Stored {d} nodes in vector database\n", .{i});
    }

    // Store edges in vector database
    var edges_stored: usize = 0;
    for (graph_builder.edges.items) |edge| {
        // Map node names to external IDs
        const from_id = node_id_map.get(edge.from_node) orelse {
            if (isDebugEnabled()) {
                std.debug.print("[INDEXER] Warning: Could not find external ID for from_node '{s}'\n", .{edge.from_node});
            }
            continue;
        };
        const to_id = node_id_map.get(edge.to_node) orelse {
            if (isDebugEnabled()) {
                std.debug.print("[INDEXER] Warning: Could not find external ID for to_node '{s}'\n", .{edge.to_node});
            }
            continue;
        };

        // Add edge to vector store
        vector_store.*.addEdge(from_id, to_id, edge.relationship.toString(), edge.weight) catch |err| {
            if (isDebugEnabled()) {
                std.debug.print("[INDEXER] Failed to add edge {s} -> {s}: {}\n", .{ edge.from_node, edge.to_node, err });
            }
            continue;
        };
        edges_stored += 1;
    }

    if (isDebugEnabled()) {
        std.debug.print("[INDEXER] Stored {d} edges in vector database\n", .{edges_stored});
    }
}
