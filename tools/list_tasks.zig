// List Tasks Tool - Lists all current tasks with status
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
                .name = try allocator.dupe(u8, "list_tasks"),
                .description = try allocator.dupe(u8, "List all tasks. Example call: {} returns [{\"task_id\": \"task_1\", \"status\": \"pending\", \"content\": \"Fix bug\"}, {\"task_id\": \"task_2\", \"status\": \"completed\", \"content\": \"Write tests\"}]"),
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
            .name = "list_tasks",
            .description = "List all tasks",
            .risk_level = .safe,
            .required_scopes = &.{.task_management},
            .validator = null,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    _ = arguments;
    const start_time = std.time.milliTimestamp();

    const tasks = context.state.getTasks();
    if (tasks.len == 0) {
        // Return empty JSON array
        const msg = try allocator.dupe(u8, "[]");
        defer allocator.free(msg);
        return ToolResult.ok(allocator, msg, start_time, null);
    }

    // Build JSON array: [{"task_id": "task_1", "status": "pending", "content": "..."}, ...]
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "[");
    for (tasks, 0..) |task, i| {
        if (i > 0) try result.appendSlice(allocator, ",");

        const status_str = switch (task.status) {
            .pending => "pending",
            .in_progress => "in_progress",
            .completed => "completed",
        };

        // Escape content for JSON
        var escaped_content = std.ArrayListUnmanaged(u8){};
        defer escaped_content.deinit(allocator);
        for (task.content) |c| {
            switch (c) {
                '"' => try escaped_content.appendSlice(allocator, "\\\""),
                '\\' => try escaped_content.appendSlice(allocator, "\\\\"),
                '\n' => try escaped_content.appendSlice(allocator, "\\n"),
                '\r' => try escaped_content.appendSlice(allocator, "\\r"),
                '\t' => try escaped_content.appendSlice(allocator, "\\t"),
                else => try escaped_content.append(allocator, c),
            }
        }

        const task_json = try std.fmt.allocPrint(
            allocator,
            "{{\"task_id\":\"{s}\",\"status\":\"{s}\",\"content\":\"{s}\"}}",
            .{ task.id, status_str, escaped_content.items },
        );
        defer allocator.free(task_json);
        try result.appendSlice(allocator, task_json);
    }
    try result.appendSlice(allocator, "]");

    const result_str = try result.toOwnedSlice(allocator);
    defer allocator.free(result_str);
    return ToolResult.ok(allocator, result_str, start_time, null);
}
