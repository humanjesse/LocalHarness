// Compress conversation segment - replaces multiple messages with compressed summary
const std = @import("std");
const mem = std.mem;
const ToolResult = @import("../tools.zig").ToolResult;
const ollama = @import("ollama");
const permission = @import("permission");
const AppContext = @import("context").AppContext;
const types = @import("types");
const compression = @import("compression");

/// Tool definition for Ollama
pub fn getDefinition(allocator: std.mem.Allocator) !@import("../tools.zig").ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "compress_conversation_segment"),
                .description = try allocator.dupe(u8, "Compress a range of user/assistant messages into a single summary. Replaces multiple messages with one compressed message. Will fail if messages are protected."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "start_index": {
                    \\      "type": "integer",
                    \\      "description": "Starting message index (inclusive, 0-based)"
                    \\    },
                    \\    "end_index": {
                    \\      "type": "integer",
                    \\      "description": "Ending message index (inclusive, 0-based)"
                    \\    },
                    \\    "summary": {
                    \\      "type": "string",
                    \\      "description": "Compressed summary that preserves key information from the segment"
                    \\    }
                    \\  },
                    \\  "required": ["start_index", "end_index", "summary"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "compress_conversation_segment",
            .description = "Compresses multiple conversation messages into a single summary",
            .risk_level = .high,
            .required_scopes = &.{.write_files}, // Modifies conversation heavily
        },
        .execute = execute,
    };
}

/// Arguments for the tool
const Args = struct {
    start_index: usize,
    end_index: usize,
    summary: []const u8,
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

    // Validate indices
    if (args.start_index > args.end_index) {
        const error_msg = try std.fmt.allocPrint(
            allocator,
            "Invalid range: start_index ({}) > end_index ({})",
            .{ args.start_index, args.end_index },
        );
        return ToolResult.err(allocator, .validation_failed, error_msg, start_time);
    }

    if (args.end_index >= messages.items.len) {
        const error_msg = try std.fmt.allocPrint(
            allocator,
            "end_index ({}) out of range (total messages: {})",
            .{ args.end_index, messages.items.len },
        );
        return ToolResult.err(allocator, .validation_failed, error_msg, start_time);
    }

    // Check if messages in range are protected (last 5 user+assistant)
    const protected = try identifyProtectedMessages(allocator, messages.items);
    defer allocator.free(protected);

    var messages_to_compress: usize = 0;
    for (args.start_index..args.end_index + 1) |i| {
        if (protected[i]) {
            const error_msg = try std.fmt.allocPrint(
                allocator,
                "Cannot compress: Message at index {} is protected (last 5 user/assistant messages)",
                .{i},
            );
            return ToolResult.err(allocator, .validation_failed, error_msg, start_time);
        }
        messages_to_compress += 1;
    }

    // Create compressed summary message
    const compressed_content = try std.fmt.allocPrint(
        allocator,
        "💭 [Compressed Segment: messages {}-{}]\n{s}",
        .{ args.start_index, args.end_index, args.summary },
    );

    // Replace first message with summary
    allocator.free(messages.items[args.start_index].content);
    messages.items[args.start_index].processed_content.deinit(allocator);
    if (messages.items[args.start_index].thinking_content) |tc| {
        allocator.free(tc);
    }

    messages.items[args.start_index].content = compressed_content;
    messages.items[args.start_index].processed_content = .{}; // Empty processed content (will be reprocessed later)
    messages.items[args.start_index].role = .system; // Mark as system message
    messages.items[args.start_index].thinking_content = null;

    // Remove subsequent messages in the range
    // Always remove at start_index + 1 since orderedRemove shifts the array
    const messages_to_remove = args.end_index - args.start_index;
    var removed_count: usize = 0;
    while (removed_count < messages_to_remove) : (removed_count += 1) {
        const remove_idx = args.start_index + 1;

        // Free message content
        allocator.free(messages.items[remove_idx].content);
        messages.items[remove_idx].processed_content.deinit(allocator);
        if (messages.items[remove_idx].thinking_content) |tc| {
            allocator.free(tc);
        }

        // Remove from array (shifts everything down)
        _ = messages.orderedRemove(remove_idx);
    }

    // Calculate tokens saved
    const tokens_saved = estimateTokensSaved(messages_to_compress, args.summary.len);

    // Return success
    const result = try std.fmt.allocPrint(
        allocator,
        "{{\"status\":\"success\",\"messages_compressed\":{},\"start_index\":{},\"summary_length\":{},\"estimated_tokens_saved\":{}}}",
        .{ messages_to_compress, args.start_index, args.summary.len, tokens_saved },
    );

    return ToolResult.ok(allocator, result, start_time, null);
}

/// Identify which messages should be protected from compression
/// Protects the last 5 user+assistant conversation messages
fn identifyProtectedMessages(
    allocator: mem.Allocator,
    messages: []const types.Message,
) ![]bool {
    var protected = try allocator.alloc(bool, messages.len);
    @memset(protected, false);

    // Walk backward, protect last 5 user+assistant messages
    var conversation_count: usize = 0;
    const target_protected = 5;

    var i = messages.len;
    while (i > 0 and conversation_count < target_protected) {
        i -= 1;
        const msg = messages[i];

        if (msg.role == .user or msg.role == .assistant) {
            protected[i] = true;
            conversation_count += 1;
        }
    }

    return protected;
}

/// Estimate tokens saved by compression
fn estimateTokensSaved(messages_compressed: usize, summary_length: usize) usize {
    // Assume average message is ~200 tokens
    // Summary uses ~4 chars per token heuristic
    const original_tokens = messages_compressed * 200;
    const summary_tokens = summary_length / 4;

    if (original_tokens > summary_tokens) {
        return original_tokens - summary_tokens;
    }
    return 0;
}
