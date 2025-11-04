// Compression system - hybrid metadata + LLM compression for message history
const std = @import("std");
const mem = std.mem;
const tracking = @import("tracking");
const compression = @import("compression");
const agents_module = @import("agents");

/// Statistics about compression operation
pub const CompressionStats = struct {
    tool_results_compressed: usize = 0,
    user_messages_compressed: usize = 0,
    assistant_messages_compressed: usize = 0,
    display_data_deleted: usize = 0,
    messages_protected: usize = 0,
    total_messages_processed: usize = 0,
    original_message_count: usize = 0,
    compressed_message_count: usize = 0,
};



/// Check if debug context logging is enabled
fn isDebugEnabled() bool {
    return std.posix.getenv("DEBUG_CONTEXT") != null;
}

/// Print debug message if DEBUG_CONTEXT is set
fn debugPrint(comptime fmt: []const u8, args: anytype) void {
    if (isDebugEnabled()) {
        std.debug.print("[COMPRESSOR] " ++ fmt, args);
    }
}

/// Main compression function - implements hybrid compression strategy
/// Compresses messages in-place, modifying the content field
/// Protected messages (last 5 user+assistant) are never modified
pub fn compressMessageHistory(
    allocator: mem.Allocator,
    messages: anytype, // Will be []Message from app.zig
    tracker: *tracking.ContextTracker,
    token_tracker: *compression.TokenTracker,
    config: compression.CompressionConfig,
    llm_provider: anytype,
) !CompressionStats {
    
    debugPrint("Starting compression...\n", .{});
    debugPrint("  Original messages: {d}\n", .{messages.len});
    debugPrint("  Original tokens: {d}\n", .{token_tracker.estimated_tokens_used});
    debugPrint("  Target tokens: {d}\n", .{token_tracker.getTargetTokens(config)});
    
    var stats = CompressionStats{
        .total_messages_processed = messages.len,
        .original_message_count = messages.len,
        .compressed_message_count = 0, // Will count non-deleted messages
    };
    
    const original_tokens = token_tracker.estimated_tokens_used;
    const target_tokens = token_tracker.getTargetTokens(config);
    
    // Step 1: Identify protected messages (last 5 user+assistant)
    const protected = try identifyProtectedMessages(allocator, messages);
    defer allocator.free(protected);
    
    for (protected) |is_protected| {
        if (is_protected) stats.messages_protected += 1;
    }
    
    // Step 2: Compress messages in priority order
    var current_tokens = original_tokens;
    
    for (messages, 0..) |*msg, idx| {
        // CRITICAL: Never compress positions 0-1 (system prompt + hot context)
        // These must remain stable for KV cache optimization
        if (idx <= 1) {
            stats.compressed_message_count += 1;
            stats.messages_protected += 1;
            continue;
        }

        if (protected[idx]) {
            // Protected - keep as-is
            stats.compressed_message_count += 1;
            continue;
        }
        
        // Compress based on message type
        const compressed_content = switch (msg.role) {
            .tool => blk: {
                stats.tool_results_compressed += 1;
                break :blk try compressToolMessage(allocator, msg, tracker);
            },
            .user => blk: {
                stats.user_messages_compressed += 1;
                break :blk try compressUserMessage(allocator, msg, llm_provider);
            },
            .assistant => blk: {
                stats.assistant_messages_compressed += 1;
                break :blk try compressAssistantMessage(allocator, msg, llm_provider);
            },
            .display_only_data => {
                stats.display_data_deleted += 1;
                continue; // Skip - don't compress
            },
            .system => {
                // Keep system messages as-is
                stats.compressed_message_count += 1;
                continue;
            },
        };
        
        // Replace message content
        allocator.free(msg.content);
        msg.content = compressed_content;
        
        // Update processed_content (leave unchanged for now - markdown processing handled elsewhere)
        // Note: In production, would need to re-process markdown here
        
        stats.compressed_message_count += 1;
        
        // Estimate current token usage
        current_tokens = estimateCurrentTokens(messages);
        
        debugPrint("  Current tokens: {d} / target: {d}\n", .{current_tokens, target_tokens});
        
        // Check if reached target
        if (current_tokens <= target_tokens) {
            debugPrint("  Reached target tokens!\n", .{});
            // Keep remaining messages as-is
            var remaining = idx + 1;
            while (remaining < messages.len) : (remaining += 1) {
                if (messages[remaining].role != .display_only_data) {
                    stats.compressed_message_count += 1;
                }
            }
            break;
        }
    }
    
    const compressed_tokens = current_tokens;
    const ratio = @as(f32, @floatFromInt(compressed_tokens)) / 
                  @as(f32, @floatFromInt(original_tokens));
    
    debugPrint("\n=== Compression Complete ===\n", .{});
    debugPrint("  Messages: {d} → {d}\n", .{stats.original_message_count, stats.compressed_message_count});
    debugPrint("  Tokens: {d} → {d}\n", .{original_tokens, compressed_tokens});
    debugPrint("  Reduction: {d:.1}%\n", .{(1.0 - ratio) * 100.0});
    debugPrint("  Stats:\n", .{});
    debugPrint("    Tool results compressed: {d}\n", .{stats.tool_results_compressed});
    debugPrint("    User messages compressed: {d}\n", .{stats.user_messages_compressed});
    debugPrint("    Assistant messages compressed: {d}\n", .{stats.assistant_messages_compressed});
    debugPrint("    Display data deleted: {d}\n", .{stats.display_data_deleted});
    debugPrint("    Messages protected: {d}\n", .{stats.messages_protected});
    debugPrint("============================\n\n", .{});
    
    if (compressed_tokens > target_tokens) {
        debugPrint("WARNING: Could not reach target tokens ({d} > {d})\n", 
            .{compressed_tokens, target_tokens});
    }
    
    return stats;
}

/// Estimate current token usage for messages
fn estimateCurrentTokens(messages: anytype) usize {
    var total: usize = 0;
    for (messages) |msg| {
        if (msg.role != .display_only_data) {
            total += compression.TokenTracker.estimateMessageTokens(msg.content);
        }
    }
    return total;
}

/// Identify which messages should be protected from compression
/// Protects the last 5 user+assistant conversation messages
fn identifyProtectedMessages(
    allocator: mem.Allocator,
    messages: anytype,
) ![]bool {
    debugPrint("Identifying protected messages (last 5 user+assistant)...\n", .{});
    
    var protected = try allocator.alloc(bool, messages.len);
    @memset(protected, false);
    
    // Walk backward, protect last 5 user+assistant messages
    var conversation_count: usize = 0;
    const target_protected = 5;
    
    var i = messages.len;
    while (i > 0 and conversation_count < target_protected) {
        i -= 1;
        const msg = messages[i];
        
        // Check if message is user or assistant role
        const is_conversation = (msg.role == .user or msg.role == .assistant);
        
        if (is_conversation) {
            protected[i] = true;
            conversation_count += 1;
            debugPrint("  Protected message {d} (role={s}, count={d}/5)\n", 
                .{i, @tagName(msg.role), conversation_count});
        }
    }
    
    debugPrint("Total protected: {d} messages\n", .{conversation_count});
    return protected;
}

/// Compress tool messages using tracked metadata
fn compressToolMessage(
    allocator: mem.Allocator,
    tool_message: anytype,
    tracker: *tracking.ContextTracker,
) ![]const u8 {
    debugPrint("Compressing tool message...\n", .{});
    
    // Detect tool type from content
    if (isReadFileTool(tool_message.content)) {
        debugPrint("  Detected read_file tool\n", .{});
        return compressReadFileTool(allocator, tool_message, tracker);
    }
    
    if (isWriteFileTool(tool_message.content)) {
        debugPrint("  Detected write_file tool\n", .{});
        return compressWriteTool(allocator, tool_message, tracker);
    }
    
    debugPrint("  Using generic tool compression\n", .{});
    return compressGenericTool(allocator, tool_message);
}

/// Check if tool message is a read_file result
fn isReadFileTool(content: []const u8) bool {
    return std.mem.indexOf(u8, content, "\"file_path\"") != null and
           std.mem.indexOf(u8, content, "\"content\"") != null;
}

/// Check if tool message is a write/insert/replace file result
fn isWriteFileTool(content: []const u8) bool {
    return std.mem.indexOf(u8, content, "write_file") != null or
           std.mem.indexOf(u8, content, "insert_lines") != null or
           std.mem.indexOf(u8, content, "replace_lines") != null;
}

/// Compress read_file tool result using curator cache
fn compressReadFileTool(
    allocator: mem.Allocator,
    tool_message: anytype,
    tracker: *tracking.ContextTracker,
) ![]const u8 {
    // Try to parse JSON to extract file_path
    const ToolResult = struct {
        file_path: []const u8,
        content: []const u8,
    };
    
    const parsed = std.json.parseFromSlice(
        ToolResult,
        allocator,
        tool_message.content,
        .{},
    ) catch {
        debugPrint("  Failed to parse tool JSON, using generic compression\n", .{});
        return compressGenericTool(allocator, tool_message);
    };
    defer parsed.deinit();
    
    const file_path = parsed.value.file_path;
    const line_count = std.mem.count(u8, parsed.value.content, "\n") + 1;
    
    // Check for curator cache
    if (tracker.read_files.get(file_path)) |file_tracker| {
        if (file_tracker.curated_result) |cache| {
            debugPrint("  Found curator cache for {s}\n", .{file_path});
            
            return std.fmt.allocPrint(
                allocator,
                "📄 [Compressed] Read {s} ({d} lines, hash:{x})\n" ++
                "• Curator Summary: {s}\n" ++
                "• Full content cached and available",
                .{
                    file_path,
                    line_count,
                    file_tracker.original_hash,
                    cache.summary,
                }
            );
        }
    }
    
    // No cache, basic compression
    debugPrint("  No curator cache for {s}, using basic summary\n", .{file_path});
    return std.fmt.allocPrint(
        allocator,
        "📄 [Compressed] Read {s} ({d} lines)",
        .{file_path, line_count}
    );
}

/// Compress write_file/insert_lines/replace_lines tool result using modification tracker
fn compressWriteTool(
    allocator: mem.Allocator,
    tool_message: anytype,
    tracker: *tracking.ContextTracker,
) ![]const u8 {
    // Try to parse to get file_path
    const ToolResult = struct {
        file_path: []const u8,
    };
    
    const parsed = std.json.parseFromSlice(
        ToolResult,
        allocator,
        tool_message.content,
        .{},
    ) catch return compressGenericTool(allocator, tool_message);
    defer parsed.deinit();
    
    const file_path = parsed.value.file_path;
    
    // Find modification in tracker
    for (tracker.recent_modifications.items) |mod| {
        if (std.mem.eql(u8, mod.file_path, file_path)) {
            const time_ago = @divFloor(
                std.time.milliTimestamp() - mod.timestamp,
                60000  // Convert to minutes
            );
            
            const mod_type = switch (mod.modification_type) {
                .created => "Created",
                .modified => "Modified",
                .deleted => "Deleted",
            };
            
            var summary_list = std.ArrayListUnmanaged(u8){};
            errdefer summary_list.deinit(allocator);
            const writer = summary_list.writer(allocator);
            
            try writer.print("✏️ [Compressed] {s} {s} ({d} min ago)", 
                .{mod_type, file_path, time_ago});
            
            // TODO: Add todo relationship when available in RecentModification
            // if (mod.related_todo_id) |todo_id| {
            //     try writer.print("\n• Related to todo: '{s}'", .{todo_id});
            // }
            
            return summary_list.toOwnedSlice(allocator);
        }
    }
    
    // Fallback if not found in tracker
    return compressGenericTool(allocator, tool_message);
}

/// Generic tool compression fallback
fn compressGenericTool(
    allocator: mem.Allocator,
    tool_message: anytype,
) ![]const u8 {
    _ = tool_message;
    return std.fmt.allocPrint(
        allocator,
        "🔧 [Compressed] Tool executed successfully",
        .{}
    );
}

/// Compress user message using LLM summarization
/// Target: ~50 tokens (preserves key questions and intent)
fn compressUserMessage(
    allocator: mem.Allocator,
    user_message: anytype,
    llm_provider: anytype,
) ![]const u8 {
    debugPrint("Compressing user message (target: 50 tokens)...\n", .{});

    // Build compression prompt
    const prompt = try std.fmt.allocPrint(
        allocator,
        "Compress this user message to 1-2 sentences (max 50 tokens). " ++
        "Preserve: main question/request, key technical details, intent.\n\n" ++
        "Original message:\n{s}\n\n" ++
        "Compressed version:",
        .{user_message.content}
    );
    defer allocator.free(prompt);

    // Try LLM compression first
    const compressed = callLLMForCompression(
        allocator,
        llm_provider,
        prompt,
        60,  // max_tokens (slightly over target for safety)
    ) catch |err| {
        debugPrint("  LLM compression failed: {}, using fallback\n", .{err});
        return fallbackCompressMessage(allocator, user_message.content, 50);
    };
    defer allocator.free(compressed);

    // Prefix with compression marker
    const final_content = try std.fmt.allocPrint(
        allocator,
        "💬 [Compressed] {s}",
        .{std.mem.trim(u8, compressed, " \n\t")}
    );

    debugPrint("  Compressed: {d} → ~{d} chars\n", .{user_message.content.len, final_content.len});
    return final_content;
}

/// Compress assistant message using LLM summarization
/// Target: ~200 tokens (preserves key explanations and decisions)
fn compressAssistantMessage(
    allocator: mem.Allocator,
    assistant_message: anytype,
    llm_provider: anytype,
) ![]const u8 {
    debugPrint("Compressing assistant message (target: 200 tokens)...\n", .{});

    // Build compression prompt
    const prompt = try std.fmt.allocPrint(
        allocator,
        "Compress this assistant response to 2-3 sentences (max 200 tokens). " ++
        "Preserve: key explanations, code changes, decisions, technical details.\n\n" ++
        "Original response:\n{s}\n\n" ++
        "Compressed version:",
        .{assistant_message.content}
    );
    defer allocator.free(prompt);

    // Try LLM compression first
    const compressed = callLLMForCompression(
        allocator,
        llm_provider,
        prompt,
        250,  // max_tokens (slightly over target for safety)
    ) catch |err| {
        debugPrint("  LLM compression failed: {}, using fallback\n", .{err});
        return fallbackCompressMessage(allocator, assistant_message.content, 200);
    };
    defer allocator.free(compressed);

    // Prefix with compression marker
    const final_content = try std.fmt.allocPrint(
        allocator,
        "💬 [Compressed] {s}",
        .{std.mem.trim(u8, compressed, " \n\t")}
    );

    debugPrint("  Compressed: {d} → ~{d} chars\n", .{assistant_message.content.len, final_content.len});
    return final_content;
}

/// Call LLM for compression with low temperature
fn callLLMForCompression(
    allocator: mem.Allocator,
    llm_provider: anytype,
    prompt: []const u8,
    max_tokens: usize,
) ![]const u8 {
    // Build messages array for LLM call
    var messages = std.ArrayListUnmanaged(struct {
        role: []const u8,
        content: []const u8,
    }){};
    defer messages.deinit(allocator);
    
    try messages.append(allocator, .{
        .role = "user",
        .content = prompt,
    });
    
    // Call LLM with low temperature for consistent compression
    const result = try llm_provider.chat(
        allocator,
        messages.items,
        .{
            .temperature = 0.3,  // Low temp for consistency
            .max_tokens = @as(i32, @intCast(max_tokens)),
            .stream = false,
        }
    );
    
    return result;
}

/// Fallback compression: simple truncation if LLM fails
fn fallbackCompressMessage(
    allocator: mem.Allocator,
    content: []const u8,
    target_tokens: usize,
) ![]const u8 {
    debugPrint("  Using fallback truncation compression\n", .{});

    // 4 chars ≈ 1 token
    const target_chars = target_tokens * 4;
    const truncated = if (content.len > target_chars)
        content[0..target_chars]
    else
        content;

    return std.fmt.allocPrint(
        allocator,
        "💬 [Compressed/Truncated] {s}...",
        .{truncated}
    );
}

/// Agent-based compression - uses compression agent with tools
/// This is the main entry point for intelligent compression
pub fn compressWithAgent(
    allocator: mem.Allocator,
    messages: anytype, // *std.ArrayListUnmanaged(Message) from app.zig
    _: *tracking.ContextTracker,
    token_tracker: *compression.TokenTracker,
    config: compression.CompressionConfig,
    llm_provider: anytype,
    app_config: anytype,
    agent_registry: anytype,
) !CompressionStats {
    debugPrint("Starting agent-based compression...\n", .{});

    const start_time = std.time.milliTimestamp();
    const original_tokens = token_tracker.estimated_tokens_used;
    const target_tokens = token_tracker.getTargetTokens(config);

    // Build task description for agent
    const task = try std.fmt.allocPrint(
        allocator,
        "Compress this conversation to reduce token usage.\n\n" ++
            "Current state:\n" ++
            "- Total messages: {d}\n" ++
            "- Current tokens: {d}\n" ++
            "- Target tokens: {d}\n" ++
            "- Reduction needed: {d} tokens\n\n" ++
            "Use your tools to analyze the conversation and perform compressions. " ++
            "Start with tool results (biggest wins), then compress conversation segments if needed. " ++
            "Work iteratively and verify progress.",
        .{
            messages.items.len,
            original_tokens,
            target_tokens,
            if (original_tokens > target_tokens) original_tokens - target_tokens else 0,
        },
    );
    defer allocator.free(task);

    // Look up compression agent
    const agent_def = agent_registry.get("compression_agent") orelse {
        debugPrint("ERROR: compression_agent not found in registry\n", .{});
        return error.CompressionAgentNotFound;
    };

    // Build agent context properly using the imported agents_module
    const agent_context = agents_module.AgentContext{
        .allocator = allocator,
        .llm_provider = llm_provider,
        .config = app_config,
        .capabilities = agent_def.capabilities,
        .system_prompt = agent_def.system_prompt,
        .vector_store = null,
        .embedder = null,
        .recent_messages = null,
        .messages_list = @as(?*anyopaque, messages), // Pass messages for compression tools
    };

    // Run compression agent
    var result = agent_def.execute(
        allocator,
        agent_context,
        task,
        null, // No progress callback for now
        null, // No user data
    ) catch |err| {
        debugPrint("ERROR: Compression agent execution failed: {}\n", .{err});
        return error.CompressionAgentFailed;
    };
    defer result.deinit(allocator);

    // Calculate final statistics
    const end_time = std.time.milliTimestamp();
    const final_tokens = estimateCurrentTokens(messages.items);
    const tokens_saved = if (original_tokens > final_tokens)
        original_tokens - final_tokens
    else
        0;

    debugPrint("\n=== Agent-Based Compression Complete ===\n", .{});
    debugPrint("  Original tokens: {d}\n", .{original_tokens});
    debugPrint("  Final tokens: {d}\n", .{final_tokens});
    debugPrint("  Tokens saved: {d}\n", .{tokens_saved});
    debugPrint("  Reduction: {d:.1}%\n", .{
        if (original_tokens > 0)
            @as(f32, @floatFromInt(tokens_saved)) / @as(f32, @floatFromInt(original_tokens)) * 100.0
        else
            0.0
    });
    debugPrint("  Agent iterations: {d}\n", .{result.stats.iterations_used});
    debugPrint("  Agent tool calls: {d}\n", .{result.stats.tool_calls_made});
    debugPrint("  Execution time: {d}ms\n", .{end_time - start_time});
    debugPrint("  Target achieved: {}\n", .{final_tokens <= target_tokens});
    debugPrint("========================================\n\n", .{});

    // Return statistics
    return CompressionStats{
        .tool_results_compressed = result.stats.tool_calls_made, // Approximate
        .user_messages_compressed = 0, // Agent handles this internally
        .assistant_messages_compressed = 0, // Agent handles this internally
        .display_data_deleted = 0,
        .messages_protected = 5, // Last 5 user+assistant are always protected
        .total_messages_processed = messages.items.len,
        .original_message_count = messages.items.len, // May have changed
        .compressed_message_count = messages.items.len,
    };
}
