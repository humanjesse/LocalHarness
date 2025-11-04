// Get compression metadata - provides tracked context for compression agent
const std = @import("std");
const mem = std.mem;
const ToolResult = @import("../tools.zig").ToolResult;
const ollama = @import("ollama");
const permission = @import("permission");
const AppContext = @import("context").AppContext;
const tracking = @import("tracking");
const compression = @import("compression");
const types = @import("types");

/// Tool definition for Ollama
pub fn getDefinition(allocator: std.mem.Allocator) !@import("../tools.zig").ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "get_compression_metadata"),
                .description = try allocator.dupe(u8, "Get tracked metadata about the conversation for compression planning. Returns file reads, modifications, todos, and message statistics."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "include_details": {
                    \\      "type": "boolean",
                    \\      "description": "Whether to include detailed information (curator summaries, modification descriptions). Default: false"
                    \\    }
                    \\  },
                    \\  "required": []
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "get_compression_metadata",
            .description = "Reads tracked metadata about conversation context (read-only)",
            .risk_level = .low,
            .required_scopes = &.{},
        },
        .execute = execute,
    };
}

/// Arguments for the tool
const Args = struct {
    include_details: bool = false,
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

    // Get context tracker
    const tracker = context.context_tracker orelse {
        const error_msg = try allocator.dupe(u8, "Context tracker not available");
        return ToolResult.err(allocator, .internal_error, error_msg, start_time);
    };

    // Build metadata JSON
    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    try writer.writeAll("{\n");

    // 1. Files read
    try writer.writeAll("  \"files_read\": [\n");
    {
        var iter = tracker.read_files.iterator();
        var first = true;
        while (iter.next()) |entry| {
            if (!first) try writer.writeAll(",\n");
            first = false;

            const file_path = entry.key_ptr.*;
            const file_tracker = entry.value_ptr.*;

            try writer.writeAll("    {\n");
            try writer.print("      \"path\": \"{s}\",\n", .{file_path});
            try writer.print("      \"hash\": {},\n", .{file_tracker.original_hash});
            try writer.print("      \"timestamp\": {},\n", .{file_tracker.last_read_time});

            if (file_tracker.curated_result) |cache| {
                try writer.writeAll("      \"curator_cache_available\": true,\n");
                try writer.print("      \"cache_conversation_hash\": {},\n", .{cache.conversation_hash});

                if (args.include_details) {
                    // Truncate summary to prevent overwhelming agent
                    const summary_preview = if (cache.summary.len > 200)
                        cache.summary[0..200]
                    else
                        cache.summary;
                    try writer.print("      \"summary\": \"{s}{s}\"\n", .{
                        summary_preview,
                        if (cache.summary.len > 200) "..." else "",
                    });
                } else {
                    try writer.print("      \"summary_length\": {}\n", .{cache.summary.len});
                }
            } else {
                try writer.writeAll("      \"curator_cache_available\": false\n");
            }

            try writer.writeAll("    }");
        }
    }
    try writer.writeAll("\n  ],\n");

    // 2. Recent modifications
    try writer.print("  \"recent_modifications\": [\n", .{});
    {
        const mods = tracker.recent_modifications.items;
        for (mods, 0..) |mod, i| {
            if (i > 0) try writer.writeAll(",\n");

            try writer.writeAll("    {\n");
            try writer.print("      \"path\": \"{s}\",\n", .{mod.file_path});
            try writer.print("      \"type\": \"{s}\",\n", .{@tagName(mod.modification_type)});
            try writer.print("      \"timestamp\": {}", .{mod.timestamp});

            if (mod.summary) |summary| {
                if (args.include_details) {
                    const summary_preview = if (summary.len > 100)
                        summary[0..100]
                    else
                        summary;
                    try writer.print(",\n      \"summary\": \"{s}{s}\"", .{
                        summary_preview,
                        if (summary.len > 100) "..." else "",
                    });
                }
            }

            if (mod.related_todo) |todo_id| {
                try writer.print(",\n      \"related_todo\": \"{s}\"", .{todo_id});
            }

            try writer.writeAll("\n    }");
        }
    }
    try writer.writeAll("\n  ],\n");

    // 3. Todo context
    try writer.writeAll("  \"todo_context\": {\n");
    if (tracker.todo_context.active_todo_id) |todo_id| {
        try writer.print("    \"active_todo\": \"{s}\",\n", .{todo_id});

        try writer.writeAll("    \"files_touched\": [");
        var file_iter = tracker.todo_context.files_touched_for_todo.keyIterator();
        var first = true;
        while (file_iter.next()) |path| {
            if (!first) try writer.writeAll(", ");
            first = false;
            try writer.print("\"{s}\"", .{path.*});
        }
        try writer.writeAll("]\n");
    } else {
        try writer.writeAll("    \"active_todo\": null,\n");
        try writer.writeAll("    \"files_touched\": []\n");
    }
    try writer.writeAll("  },\n");

    // 4. Message statistics
    try writer.writeAll("  \"message_statistics\": {\n");
    if (context.messages_list) |messages_ptr| {
        const messages = @as(*std.ArrayListUnmanaged(types.Message), @ptrCast(@alignCast(messages_ptr)));
        var user_count: usize = 0;
        var assistant_count: usize = 0;
        var tool_count: usize = 0;
        var system_count: usize = 0;
        var display_count: usize = 0;
        var total_estimated_tokens: usize = 0;

        for (messages.items) |msg| {
            switch (msg.role) {
                .user => user_count += 1,
                .assistant => assistant_count += 1,
                .tool => tool_count += 1,
                .system => system_count += 1,
                .display_only_data => display_count += 1,
            }
            total_estimated_tokens += compression.TokenTracker.estimateMessageTokens(msg.content);
        }

        try writer.print("    \"total_messages\": {},\n", .{messages.items.len});
        try writer.print("    \"user_messages\": {},\n", .{user_count});
        try writer.print("    \"assistant_messages\": {},\n", .{assistant_count});
        try writer.print("    \"tool_messages\": {},\n", .{tool_count});
        try writer.print("    \"system_messages\": {},\n", .{system_count});
        try writer.print("    \"display_only_messages\": {},\n", .{display_count});
        try writer.print("    \"estimated_total_tokens\": {}\n", .{total_estimated_tokens});
    } else {
        try writer.writeAll("    \"error\": \"Messages list not available\"\n");
    }
    try writer.writeAll("  }\n");

    try writer.writeAll("}\n");

    const result = try output.toOwnedSlice(allocator);
    defer allocator.free(result);
    return ToolResult.ok(allocator, result, start_time, null);
}
