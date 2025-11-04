// Verify compression target - checks if compression target has been achieved
const std = @import("std");
const mem = std.mem;
const ToolResult = @import("../tools.zig").ToolResult;
const ollama = @import("ollama");
const permission = @import("permission");
const AppContext = @import("context").AppContext;
const compression = @import("compression");
const types = @import("types");

/// Tool definition for Ollama
pub fn getDefinition(allocator: std.mem.Allocator) !@import("../tools.zig").ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "verify_compression_target"),
                .description = try allocator.dupe(u8, "Check current token usage and verify if compression target has been achieved. Returns current tokens, target tokens, and whether more compression is needed."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {},
                    \\  "required": []
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "verify_compression_target",
            .description = "Reads current token usage and compression target (read-only)",
            .risk_level = .low,
            .required_scopes = &.{},
        },
        .execute = execute,
    };
}

/// Execute the tool
fn execute(
    allocator: std.mem.Allocator,
    arguments: []const u8,
    context: *AppContext,
) !ToolResult {
    const start_time = std.time.milliTimestamp();
    _ = arguments; // No arguments needed

    // Get messages list
    const messages = @as(*std.ArrayListUnmanaged(types.Message), @ptrCast(@alignCast(context.messages_list orelse {
        const error_msg = try allocator.dupe(u8, "Messages list not available");
        return ToolResult.err(allocator, .internal_error, error_msg, start_time);
    })));

    // Calculate current token usage
    var current_tokens: usize = 0;
    for (messages.items) |msg| {
        if (msg.role != .display_only_data) {
            current_tokens += compression.TokenTracker.estimateMessageTokens(msg.content);
        }
    }

    // Get configuration
    const max_context_tokens = context.config.num_ctx;

    // Calculate targets
    const trigger_threshold_pct: f32 = 0.70;
    const target_usage_pct: f32 = 0.40;

    const trigger_tokens = @as(usize, @intFromFloat(
        @as(f32, @floatFromInt(max_context_tokens)) * trigger_threshold_pct,
    ));

    const target_tokens = @as(usize, @intFromFloat(
        @as(f32, @floatFromInt(max_context_tokens)) * target_usage_pct,
    ));

    // Calculate percentages
    const current_usage_pct = @as(f32, @floatFromInt(current_tokens)) /
        @as(f32, @floatFromInt(max_context_tokens)) * 100.0;

    const target_usage_pct_display = target_usage_pct * 100.0;

    // Determine if target achieved
    const target_achieved = current_tokens <= target_tokens;
    const tokens_over_target = if (current_tokens > target_tokens)
        current_tokens - target_tokens
    else
        0;

    // Calculate compression progress
    const tokens_saved_from_trigger = if (trigger_tokens > current_tokens)
        trigger_tokens - current_tokens
    else
        0;

    const compression_ratio = if (trigger_tokens > 0)
        @as(f32, @floatFromInt(tokens_saved_from_trigger)) /
            @as(f32, @floatFromInt(trigger_tokens)) * 100.0
    else
        0.0;

    // Build result JSON
    const result = try std.fmt.allocPrint(
        allocator,
        \\{{
        \\  "current_tokens": {},
        \\  "target_tokens": {},
        \\  "max_context_tokens": {},
        \\  "trigger_threshold_tokens": {},
        \\  "current_usage_percent": {d:.1},
        \\  "target_usage_percent": {d:.1},
        \\  "target_achieved": {},
        \\  "tokens_over_target": {},
        \\  "tokens_saved_from_trigger": {},
        \\  "compression_progress_percent": {d:.1},
        \\  "recommendation": "{s}",
        \\  "total_messages": {}
        \\}}
    ,
        .{
            current_tokens,
            target_tokens,
            max_context_tokens,
            trigger_tokens,
            current_usage_pct,
            target_usage_pct_display,
            target_achieved,
            tokens_over_target,
            tokens_saved_from_trigger,
            compression_ratio,
            if (target_achieved)
                "Target achieved! Compression complete."
            else if (tokens_over_target > 5000)
                "Significant compression still needed. Focus on large tool results first."
            else if (tokens_over_target > 1000)
                "Close to target. Compress a few more conversation segments."
            else
                "Very close to target. One more compression should do it.",
            messages.items.len,
        },
    );

    return ToolResult.ok(allocator, result, start_time, null);
}
