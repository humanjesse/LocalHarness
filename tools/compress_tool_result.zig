// Compress tool result - applies metadata-based compression to a tool message
const std = @import("std");
const mem = std.mem;
const ToolResult = @import("../tools.zig").ToolResult;
const ollama = @import("ollama");
const permission = @import("permission");
const AppContext = @import("context").AppContext;
const tracking = @import("tracking");
const types = @import("types");

/// Tool definition for Ollama
pub fn getDefinition(allocator: std.mem.Allocator) !@import("../tools.zig").ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "compress_tool_result"),
                .description = try allocator.dupe(u8, "Compress a tool result message using tracked metadata. Strategies: 'use_curator_cache' for read_file, 'use_modification_metadata' for write operations, 'generic' for others."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "message_index": {
                    \\      "type": "integer",
                    \\      "description": "Index of the tool message to compress (0-based)"
                    \\    },
                    \\    "strategy": {
                    \\      "type": "string",
                    \\      "enum": ["use_curator_cache", "use_modification_metadata", "generic"],
                    \\      "description": "Compression strategy to use"
                    \\    }
                    \\  },
                    \\  "required": ["message_index", "strategy"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "compress_tool_result",
            .description = "Compresses a tool result message in conversation history",
            .risk_level = .medium,
            .required_scopes = &.{.write_files}, // Modifies conversation state
        },
        .execute = execute,
    };
}

/// Arguments for the tool
const Args = struct {
    message_index: usize,
    strategy: []const u8,
};

/// Execute the tool
fn execute(
    allocator: std.mem.Allocator,
    arguments: []const u8,
    context: *AppContext,
) !ToolResult {
    const start_time = std.time.milliTimestamp();

    // Parse arguments
    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{}) catch |err| {
        const error_msg = try std.fmt.allocPrint(
            allocator,
            "Failed to parse arguments: {}",
            .{err},
        );
        return ToolResult.err(allocator, .parse_error, error_msg, start_time);
    };
    defer parsed.deinit();

    const args = parsed.value;

    // Get messages list
    const messages = @as(*std.ArrayListUnmanaged(types.Message), @ptrCast(@alignCast(context.messages_list orelse {
        const error_msg = try allocator.dupe(u8, "Messages list not available");
        return ToolResult.err(allocator, .internal_error, error_msg, start_time);
    })));

    const tracker = context.context_tracker orelse {
        const error_msg = try allocator.dupe(u8, "Context tracker not available");
        return ToolResult.err(allocator, .internal_error, error_msg, start_time);
    };

    // Validate message index
    if (args.message_index >= messages.items.len) {
        const error_msg = try std.fmt.allocPrint(
            allocator,
            "Message index {} out of range (total messages: {})",
            .{ args.message_index, messages.items.len },
        );
        return ToolResult.err(allocator, .validation_failed, error_msg, start_time);
    }

    const message = &messages.items[args.message_index];

    // Verify it's a tool message
    if (message.role != .tool) {
        const error_msg = try std.fmt.allocPrint(
            allocator,
            "Message at index {} is not a tool message (role: {s})",
            .{ args.message_index, @tagName(message.role) },
        );
        return ToolResult.err(allocator, .validation_failed, error_msg, start_time);
    }

    // Apply compression based on strategy
    const compressed_content = if (mem.eql(u8, args.strategy, "use_curator_cache"))
        try compressWithCuratorCache(allocator, message.content, tracker)
    else if (mem.eql(u8, args.strategy, "use_modification_metadata"))
        try compressWithModificationMetadata(allocator, message.content, tracker)
    else if (mem.eql(u8, args.strategy, "generic"))
        try allocator.dupe(u8, "🔧 [Compressed] Tool executed successfully")
    else {
        const error_msg = try std.fmt.allocPrint(
            allocator,
            "Unknown strategy: {s}",
            .{args.strategy},
        );
        return ToolResult.err(allocator, .validation_failed, error_msg, start_time);
    };

    // Replace message content
    allocator.free(message.content);
    message.content = compressed_content;

    // Update processed_content (reprocess markdown)
    message.processed_content.deinit(allocator);
    message.processed_content = .{}; // Empty processed content (will be reprocessed later)

    // Return success with compression info
    const result = try std.fmt.allocPrint(
        allocator,
        "{{\"status\":\"success\",\"message_index\":{},\"strategy\":\"{s}\",\"compressed_length\":{}}}",
        .{ args.message_index, args.strategy, compressed_content.len },
    );
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}

/// Compress using curator cache (for read_file tool results)
fn compressWithCuratorCache(
    allocator: mem.Allocator,
    tool_content: []const u8,
    tracker: *tracking.ContextTracker,
) ![]const u8 {
    // Try to parse JSON to extract file_path
    const ToolResultParsed = struct {
        file_path: []const u8,
        content: []const u8,
    };

    const parsed = std.json.parseFromSlice(
        ToolResultParsed,
        allocator,
        tool_content,
        .{},
    ) catch {
        // Can't parse, use generic compression
        return try allocator.dupe(u8, "📄 [Compressed] File read result (parsing failed)");
    };
    defer parsed.deinit();

    const file_path = parsed.value.file_path;
    const line_count = std.mem.count(u8, parsed.value.content, "\n") + 1;

    // Check for curator cache
    if (tracker.read_files.get(file_path)) |file_tracker| {
        if (file_tracker.curated_result) |cache| {
            // Truncate summary to prevent bloat
            const summary_preview = if (cache.summary.len > 200)
                cache.summary[0..200]
            else
                cache.summary;

            return std.fmt.allocPrint(
                allocator,
                "📄 [Compressed] Read {s} ({d} lines, hash:{x})\n" ++
                    "• Curator Summary: {s}{s}\n" ++
                    "• Full content cached and available",
                .{
                    file_path,
                    line_count,
                    file_tracker.original_hash,
                    summary_preview,
                    if (cache.summary.len > 200) "..." else "",
                },
            );
        }
    }

    // No cache, basic compression
    return std.fmt.allocPrint(
        allocator,
        "📄 [Compressed] Read {s} ({d} lines)",
        .{ file_path, line_count },
    );
}

/// Compress using modification metadata (for write_file tool results)
fn compressWithModificationMetadata(
    allocator: mem.Allocator,
    tool_content: []const u8,
    tracker: *tracking.ContextTracker,
) ![]const u8 {
    // Try to parse to get file_path
    const ToolResultParsed = struct {
        file_path: []const u8,
    };

    const parsed = std.json.parseFromSlice(
        ToolResultParsed,
        allocator,
        tool_content,
        .{},
    ) catch {
        return try allocator.dupe(u8, "✏️ [Compressed] File modification (parsing failed)");
    };
    defer parsed.deinit();

    const file_path = parsed.value.file_path;

    // Find modification in tracker
    for (tracker.recent_modifications.items) |mod| {
        if (std.mem.eql(u8, mod.file_path, file_path)) {
            const time_ago = @divFloor(
                std.time.milliTimestamp() - mod.timestamp,
                60000, // Convert to minutes
            );

            const mod_type = switch (mod.modification_type) {
                .created => "Created",
                .modified => "Modified",
                .deleted => "Deleted",
            };

            var summary_list = std.ArrayListUnmanaged(u8){};
            errdefer summary_list.deinit(allocator);
            const writer = summary_list.writer(allocator);

            try writer.print("✏️ [Compressed] {s} {s} ({d} min ago)", .{ mod_type, file_path, time_ago });

            if (mod.related_todo) |todo_id| {
                try writer.print("\n• Related to todo: '{s}'", .{todo_id});
            }

            return summary_list.toOwnedSlice(allocator);
        }
    }

    // Fallback if not found in tracker
    return std.fmt.allocPrint(
        allocator,
        "✏️ [Compressed] Modified {s}",
        .{file_path},
    );
}
