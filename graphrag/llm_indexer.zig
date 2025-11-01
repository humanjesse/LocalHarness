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

/// Escape string for JSON (handle quotes, backslashes, newlines)
/// Caller must free the returned string
fn escapeJSONString(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var escaped = try std.ArrayList(u8).initCapacity(allocator, input.len);
    defer escaped.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '"' => try escaped.appendSlice(allocator, "\\\""),
            '\\' => try escaped.appendSlice(allocator, "\\\\"),
            '\n' => try escaped.appendSlice(allocator, "\\n"),
            '\r' => try escaped.appendSlice(allocator, "\\r"),
            '\t' => try escaped.appendSlice(allocator, "\\t"),
            else => try escaped.append(allocator, c),
        }
    }

    return try escaped.toOwnedSlice(allocator);
}

/// Format nodes as JSON array for Phase 2 prompt
/// Returns properly escaped JSON with zero ambiguity
/// Caller must free the returned string
fn formatNodesAsJSON(allocator: std.mem.Allocator, graph_builder: *const GraphBuilder) ![]const u8 {
    if (graph_builder.getNodeCount() == 0) {
        return try allocator.dupe(u8, "[]");
    }

    var json = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer json.deinit(allocator);
    const writer = json.writer(allocator);

    try writer.writeAll("[\n");

    var iter = graph_builder.nodes.iterator();
    var first = true;
    while (iter.next()) |entry| {
        const node = entry.value_ptr.*;

        if (!first) try writer.writeAll(",\n");
        first = false;

        try writer.writeAll("  {\n");

        // Escape name for JSON
        const escaped_name = try escapeJSONString(allocator, node.name);
        defer allocator.free(escaped_name);
        try writer.print("    \"name\": \"{s}\",\n", .{escaped_name});

        try writer.print("    \"type\": \"{s}\",\n", .{node.node_type.toString()});

        // Escape summary for JSON
        const escaped_summary = try escapeJSONString(allocator, node.summary);
        defer allocator.free(escaped_summary);
        try writer.print("    \"summary\": \"{s}\",\n", .{escaped_summary});

        // Lines (can be null)
        if (node.start_line) |start| {
            if (node.end_line) |end| {
                try writer.print("    \"lines\": {{\"start\": {d}, \"end\": {d}}},\n", .{start, end});
            } else {
                try writer.writeAll("    \"lines\": null,\n");
            }
        } else {
            try writer.writeAll("    \"lines\": null,\n");
        }

        try writer.print("    \"is_public\": {s}\n", .{if (node.is_public) "true" else "false"});
        try writer.writeAll("  }");
    }

    try writer.writeAll("\n]");

    return try json.toOwnedSlice(allocator);
}

/// Clean up and free all messages in the array
fn freeMessages(allocator: std.mem.Allocator, messages: *std.ArrayListUnmanaged(ollama.ChatMessage)) void {
    for (messages.items) |msg| {
        allocator.free(msg.role);
        allocator.free(msg.content);
        if (msg.tool_calls) |calls| {
            for (calls) |call| {
                if (call.id) |id| allocator.free(id);
                if (call.type) |t| allocator.free(t);
                allocator.free(call.function.name);
                allocator.free(call.function.arguments);
            }
            allocator.free(calls);
        }
        if (msg.tool_call_id) |id| allocator.free(id);
    }
    messages.clearRetainingCapacity();
}

/// System prompt for Phase 1: Node Extraction Agent
/// This agent focuses ONLY on identifying and creating entity nodes
const NODE_EXTRACTION_SYSTEM_PROMPT =
    \\You are a node extraction specialist. Your job is to identify entities in code and create nodes using the create_node tool.
    \\
    \\VALID NODE TYPES (use exactly these):
    \\• function - Functions, methods, procedures
    \\• struct - Data structures, classes, types
    \\• section - Documentation sections, chapters
    \\• concept - Abstract concepts, ideas, patterns
    \\
    \\GUIDELINES:
    \\1. Use the create_node tool for each entity you find
    \\2. Keep summaries concise (1-2 sentences max per node)
    \\3. Work through the file systematically to extract all significant entities
    \\4. Focus only on creating nodes - edges will be handled by a separate agent
    \\5. Continue until you've identified all meaningful entities, then stop
    \\
    \\Take your time and be thorough - there's no rush.
;

/// System prompt for Phase 2: Edge Creation Agent
/// This agent focuses ONLY on mapping relationships between existing nodes
const EDGE_CREATION_SYSTEM_PROMPT =
    \\You are a relationship mapping specialist. Your job is to identify relationships between nodes and create edges using the create_edge tool.
    \\
    \\VALID RELATIONSHIP TYPES (use exactly these):
    \\• calls - Function/method invocations
    \\• imports - Import/dependency relationships
    \\• references - Variable/type references
    \\• relates_to - Conceptual connections
    \\
    \\GUIDELINES:
    \\1. Use the create_edge tool for each relationship you identify
    \\2. Only create edges between nodes that exist in the provided node list
    \\3. Avoid creating duplicate edges - each unique relationship should appear only once
    \\4. Work through the relationships systematically to map all meaningful connections
    \\5. Continue until you've identified all significant relationships, then stop
    \\
    \\Take your time and be thorough - there's no rush.
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
        defer {
            // Free the received tool calls array and its contents
            // (ownership was transferred from LM Studio)
            for (calls) |call| {
                if (call.id) |id| ctx.allocator.free(id);
                if (call.type) |t| ctx.allocator.free(t);
                ctx.allocator.free(call.function.name);
                ctx.allocator.free(call.function.arguments);
            }
            ctx.allocator.free(calls);
        }

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
        std.debug.print("[INDEXER] Configuration:\n", .{});
        std.debug.print("  - Indexing model: {s}\n", .{indexing_model});
        std.debug.print("  - Embedding model: {s}\n", .{app_context.config.embedding_model});
        std.debug.print("  - Provider: {s}\n", .{app_context.config.provider});
    }

    // ========================================================================
    // PHASE 1: NODE EXTRACTION
    // ========================================================================

    // User prompt for Phase 1 - focused on node extraction only
    const node_prompt = try std.fmt.allocPrint(
        allocator,
        \\Please analyze this file and create nodes for the significant entities you find.
        \\
        \\Available node_type values:
        \\• "function" - for functions, methods, procedures
        \\• "struct" - for data structures, classes, types
        \\• "section" - for documentation sections, chapters
        \\• "concept" - for abstract concepts, ideas, patterns, systems
        \\
        \\Use the create_node tool for each entity. Work through the file carefully and extract all meaningful entities.
        \\
        \\File content:
        \\{s}
    ,
        .{content},
    );
    // NOTE: Do NOT defer free node_prompt here - ownership transferred to messages

    // Get node extraction tools from registry (only create_node)
    const node_tools = try indexing_tool_registry.getNodeExtractionTools(allocator);
    defer {
        for (node_tools) |tool| {
            allocator.free(tool.function.name);
            allocator.free(tool.function.description);
            allocator.free(tool.function.parameters);
        }
        allocator.free(node_tools);
    }

    if (isDebugEnabled()) {
        std.debug.print("[INDEXER] Phase 1 tools: {d}\n", .{node_tools.len});
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

    // Add initial messages for Phase 1
    try messages.append(allocator, .{
        .role = try allocator.dupe(u8, "system"),
        .content = try allocator.dupe(u8, NODE_EXTRACTION_SYSTEM_PROMPT),
    });
    try messages.append(allocator, .{
        .role = try allocator.dupe(u8, "user"),
        .content = node_prompt, // Transfer ownership
    });

    // Notify progress for Phase 1
    if (progress_callback) |callback| {
        callback(progress_user_data.?, .thinking, "Phase 1: Extracting entities...");
    }

    // Phase 1 iteration loop - node extraction with 2-empty-iteration completion
    const max_iterations: usize = app_context.config.indexing_max_iterations;
    var phase1_iteration: usize = 0;
    var consecutive_empty_iterations: usize = 0; // Track model completion signals

    while (phase1_iteration < max_iterations) : (phase1_iteration += 1) {
        if (isDebugEnabled()) {
            std.debug.print("[INDEXER] === PHASE 1 Iteration {d}/{d} ===\n", .{ phase1_iteration + 1, max_iterations });
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
            std.debug.print("\n[INDEXER] ===== PHASE 1 ITERATION {d} CALL =====\n", .{phase1_iteration + 1});
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
            std.debug.print("[INDEXER] Tools.len: {d}\n", .{node_tools.len});
            std.debug.print("[INDEXER] Tools being passed: {s}\n", .{if (node_tools.len > 0) "YES" else "NO"});
            std.debug.print("[INDEXER] ===== END CALL INFO =====\n\n", .{});
        }

        // Get provider capabilities to check what's supported
        const caps = llm_provider.getCapabilities();

        // Enable thinking if both config and provider support it (separate from main chat)
        const enable_thinking = app_context.config.indexing_enable_thinking and caps.supports_thinking;

        // Only pass keep_alive if provider supports it
        const keep_alive = if (caps.supports_keep_alive) app_context.config.model_keep_alive else null;

        // Use explicit defaults for indexing parameters to ensure reliable tool calling
        // These values work well for both Ollama and LM Studio
        const indexing_temp = app_context.config.indexing_temperature orelse 0.1; // Focused, deterministic
        const indexing_tokens = app_context.config.indexing_num_predict orelse 10240; // Enough for tool calls
        const indexing_penalty = app_context.config.indexing_repeat_penalty orelse 1.3; // Reduce verbosity

        llm_provider.chatStream(
            indexing_model,
            messages.items,
            enable_thinking, // Capability-aware thinking mode
            null,
            if (node_tools.len > 0) node_tools else null,
            keep_alive, // Capability-aware keep_alive
            app_context.config.num_ctx,
            indexing_tokens,
            indexing_temp,
            indexing_penalty,
            &stream_ctx,
            streamCallback,
        ) catch |err| {
            if (isDebugEnabled()) {
                std.debug.print("[INDEXER] Phase 1 LLM call failed on iteration {d}: {}\n", .{ phase1_iteration, err });
            }
            return err;
        };

        const num_tool_calls = stream_ctx.tool_calls.items.len;

        if (isDebugEnabled()) {
            std.debug.print("[INDEXER] Phase 1 Iteration {d}: LLM returned {d} tool calls\n", .{ phase1_iteration + 1, num_tool_calls });
        }

        // If no tool calls on first iteration, that's an error
        if (phase1_iteration == 0 and num_tool_calls == 0) {
            if (isDebugEnabled()) {
                std.debug.print("[INDEXER] ERROR: No tool calls on first Phase 1 iteration\n", .{});
            }
            return error.NoToolCallsGenerated;
        }

        // Track consecutive empty iterations to detect model completion
        if (num_tool_calls == 0) {
            consecutive_empty_iterations += 1;

            if (isDebugEnabled()) {
                std.debug.print("[INDEXER] Phase 1: No tool calls this iteration (consecutive: {d})\n", .{consecutive_empty_iterations});
            }

            // Model signals completion with 2 consecutive empty iterations
            // (1 empty = might be thinking, 2 empty = definitely done)
            if (consecutive_empty_iterations >= 2) {
                if (isDebugEnabled()) {
                    std.debug.print("[INDEXER] Phase 1: Model signaled completion - done with node extraction\n", .{});
                }
                break;
            }

            // One empty iteration - give model another chance
            continue;
        } else {
            // Got tool calls - reset counter
            consecutive_empty_iterations = 0;
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

        // Show Phase 1 iteration summary
        if (progress_callback) |callback| {
            const summary = try std.fmt.allocPrint(
                allocator,
                "Phase 1 Iteration {d} complete: {d} nodes created",
                .{ phase1_iteration + 1, indexing_ctx.stats.nodes_created },
            );
            defer allocator.free(summary);
            callback(progress_user_data.?, .content, summary);
        }

        if (isDebugEnabled()) {
            std.debug.print("[INDEXER] Phase 1 Iteration {d} stats: {d} nodes, {d} errors\n", .{
                phase1_iteration + 1,
                indexing_ctx.stats.nodes_created,
                indexing_ctx.stats.errors,
            });
        }

    }

    // End of Phase 1 - validate we created nodes
    if (graph_builder.getNodeCount() == 0) {
        if (isDebugEnabled()) {
            std.debug.print("[INDEXER] ERROR: No nodes created after {d} Phase 1 iterations\n", .{phase1_iteration});
        }
        return error.NoNodesCreated;
    }

    if (isDebugEnabled()) {
        std.debug.print("[INDEXER] Phase 1 complete: {d} nodes created in {d} iterations\n", .{
            graph_builder.getNodeCount(),
            phase1_iteration,
        });
    }

    // Notify Phase 1 completion
    if (progress_callback) |callback| {
        const msg = try std.fmt.allocPrint(allocator, "Phase 1 complete: {d} nodes extracted", .{graph_builder.getNodeCount()});
        defer allocator.free(msg);
        callback(progress_user_data.?, .content, msg);
    }

    // ========================================================================
    // PHASE 2: EDGE CREATION (Fresh Context)
    // ========================================================================

    // Clear Phase 1 conversation - Phase 2 needs fresh context
    if (isDebugEnabled()) {
        std.debug.print("[INDEXER] Clearing Phase 1 context ({d} messages)\n", .{messages.items.len});
    }
    freeMessages(allocator, &messages);

    // Format nodes as JSON for Phase 2 prompt
    const nodes_json = try formatNodesAsJSON(allocator, &graph_builder);
    defer allocator.free(nodes_json);

    const edge_prompt = try std.fmt.allocPrint(
        allocator,
        \\Please map relationships between the entities extracted from: {s}
        \\
        \\EXTRACTED ENTITIES (JSON):
        \\{s}
        \\
        \\ORIGINAL DOCUMENT (for reference):
        \\```
        \\{s}
        \\```
        \\
        \\Use the create_edge tool to connect related entities. Make sure to use the exact "name" field from the JSON above for from_node and to_node.
        \\
        \\Available relationship types: "calls", "imports", "references", "relates_to"
        \\
        \\Work through the entities systematically and identify all meaningful relationships.
    ,
        .{ file_path, nodes_json, content },
    );
    // NOTE: Do NOT defer free edge_prompt here - ownership transferred to messages

    // Get edge creation tools from registry (only create_edge)
    const edge_tools = try indexing_tool_registry.getEdgeCreationTools(allocator);
    defer {
        for (edge_tools) |tool| {
            allocator.free(tool.function.name);
            allocator.free(tool.function.description);
            allocator.free(tool.function.parameters);
        }
        allocator.free(edge_tools);
    }

    if (isDebugEnabled()) {
        std.debug.print("[INDEXER] Phase 2 tools: {d}\n", .{edge_tools.len});
    }

    // Build fresh Phase 2 context (Phase 1 history cleared)
    try messages.append(allocator, .{
        .role = try allocator.dupe(u8, "system"),
        .content = try allocator.dupe(u8, EDGE_CREATION_SYSTEM_PROMPT),
    });
    try messages.append(allocator, .{
        .role = try allocator.dupe(u8, "user"),
        .content = edge_prompt, // Transfer ownership
    });

    if (isDebugEnabled()) {
        std.debug.print("[INDEXER] Phase 2 context built: {d} messages\n", .{messages.items.len});
        std.debug.print("[INDEXER]   - System: {d} chars\n", .{messages.items[0].content.len});
        std.debug.print("[INDEXER]   - User prompt: {d} chars\n", .{messages.items[1].content.len});
        std.debug.print("[INDEXER]   - Nodes in context: {d}\n", .{graph_builder.getNodeCount()});
    }

    // Notify progress for Phase 2
    if (progress_callback) |callback| {
        callback(progress_user_data.?, .thinking, "Phase 2: Mapping relationships...");
    }

    // Phase 2 iteration loop - edge creation with 2-empty-iteration completion
    var phase2_iteration: usize = 0;
    consecutive_empty_iterations = 0; // Reset for Phase 2

    while (phase2_iteration < max_iterations) : (phase2_iteration += 1) {
        if (isDebugEnabled()) {
            std.debug.print("[INDEXER] === PHASE 2 Iteration {d}/{d} ===\n", .{ phase2_iteration + 1, max_iterations });
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
            std.debug.print("\n[INDEXER] ===== PHASE 2 ITERATION {d} CALL =====\n", .{phase2_iteration + 1});
            std.debug.print("[INDEXER] Model: {s}\n", .{indexing_model});
            std.debug.print("[INDEXER] Messages: {d}\n", .{messages.items.len});
            std.debug.print("[INDEXER] Tools.len: {d}\n", .{edge_tools.len});
            std.debug.print("[INDEXER] Tools being passed: {s}\n", .{if (edge_tools.len > 0) "YES" else "NO"});
            std.debug.print("[INDEXER] ===== END CALL INFO =====\n\n", .{});
        }

        // Get provider capabilities (same as Phase 1)
        const caps = llm_provider.getCapabilities();
        const enable_thinking = app_context.config.indexing_enable_thinking and caps.supports_thinking;
        const keep_alive = if (caps.supports_keep_alive) app_context.config.model_keep_alive else null;

        // Use same indexing parameters as Phase 1
        const indexing_temp = app_context.config.indexing_temperature orelse 0.1;
        const indexing_tokens = app_context.config.indexing_num_predict orelse 10240;
        const indexing_penalty = app_context.config.indexing_repeat_penalty orelse 1.3;

        llm_provider.chatStream(
            indexing_model,
            messages.items,
            enable_thinking,
            null,
            if (edge_tools.len > 0) edge_tools else null,
            keep_alive,
            app_context.config.num_ctx,
            indexing_tokens,
            indexing_temp,
            indexing_penalty,
            &stream_ctx,
            streamCallback,
        ) catch |err| {
            if (isDebugEnabled()) {
                std.debug.print("[INDEXER] Phase 2 LLM call failed on iteration {d}: {}\n", .{ phase2_iteration, err });
            }
            return err;
        };

        const num_tool_calls = stream_ctx.tool_calls.items.len;

        if (isDebugEnabled()) {
            std.debug.print("[INDEXER] Phase 2 Iteration {d}: LLM returned {d} tool calls\n", .{ phase2_iteration + 1, num_tool_calls });
        }

        // Track consecutive empty iterations to detect model completion
        if (num_tool_calls == 0) {
            consecutive_empty_iterations += 1;

            if (isDebugEnabled()) {
                std.debug.print("[INDEXER] Phase 2: No tool calls this iteration (consecutive: {d})\n", .{consecutive_empty_iterations});
            }

            // Model signals completion with 2 consecutive empty iterations
            if (consecutive_empty_iterations >= 2) {
                if (isDebugEnabled()) {
                    std.debug.print("[INDEXER] Phase 2: Model signaled completion - done with edge creation\n", .{});
                }
                break;
            }

            // One empty iteration - give model another chance
            continue;
        } else {
            // Got tool calls - reset counter
            consecutive_empty_iterations = 0;
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

        // Show Phase 2 iteration summary
        if (progress_callback) |callback| {
            const summary = try std.fmt.allocPrint(
                allocator,
                "Phase 2 Iteration {d} complete: {d} edges created",
                .{ phase2_iteration + 1, indexing_ctx.stats.edges_created },
            );
            defer allocator.free(summary);
            callback(progress_user_data.?, .content, summary);
        }

        if (isDebugEnabled()) {
            std.debug.print("[INDEXER] Phase 2 Iteration {d} stats: {d} edges, {d} errors\n", .{
                phase2_iteration + 1,
                indexing_ctx.stats.edges_created,
                indexing_ctx.stats.errors,
            });
        }

    }

    // End of Phase 2
    if (isDebugEnabled()) {
        std.debug.print("[INDEXER] Phase 2 complete: {d} edges created in {d} iterations\n", .{
            graph_builder.getEdgeCount(),
            phase2_iteration,
        });
    }

    // Notify Phase 2 completion
    if (progress_callback) |callback| {
        const msg = try std.fmt.allocPrint(allocator, "Phase 2 complete: {d} edges mapped", .{graph_builder.getEdgeCount()});
        defer allocator.free(msg);
        callback(progress_user_data.?, .content, msg);
    }

    // ========================================================================
    // FINAL VALIDATION AND STORAGE
    // ========================================================================

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
        std.debug.print("[INDEXER] Successfully indexed {s}: {d} nodes, {d} edges (Phase 1: {d} iterations, Phase 2: {d} iterations)\n", .{
            file_path,
            indexing_ctx.stats.nodes_created,
            indexing_ctx.stats.edges_created,
            phase1_iteration,
            phase2_iteration,
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

        // Add attributes (setAttribute clones values internally, no need to dupe)
        try metadata.setAttribute(allocator, "name", .{ .string = name });
        try metadata.setAttribute(allocator, "is_public", .{ .bool = node.is_public });
        try metadata.setAttribute(allocator, "summary", .{ .string = node.summary });

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
