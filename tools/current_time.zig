// Current Time Tool - Returns current date and time
const std = @import("std");
const ollama = @import("../ollama.zig");
const permission = @import("../permission.zig");
const context_module = @import("../context.zig");
const tools_module = @import("../tools.zig");

const AppContext = context_module.AppContext;
const ToolDefinition = tools_module.ToolDefinition;
const ToolResult = tools_module.ToolResult;

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "get_current_time"),
                .description = try allocator.dupe(u8, "Returns the current date and time in ISO 8601 format. Use this when you need to know what time it is, what day it is, or to provide time-aware responses."),
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
            .name = "get_current_time",
            .description = "Get current date and time",
            .risk_level = .safe,
            .required_scopes = &.{.system_info},
            .validator = null,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    _ = arguments; // No arguments needed
    _ = context; // Phase 1: not used
    const start_time = std.time.milliTimestamp();

    // Get current timestamp
    const timestamp = std.time.milliTimestamp();
    const seconds = @divTrunc(timestamp, 1000);

    // Convert to epoch seconds and format as ISO 8601
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const day_seconds = epoch_seconds.getDaySeconds();
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    // Format: YYYY-MM-DDTHH:MM:SSZ
    const result = try std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time);
}
