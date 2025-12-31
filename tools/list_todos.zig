// List Todos Tool - Lists all current todos with status
const std = @import("std");
const ollama = @import("ollama");
const permission = @import("permission");
const context_module = @import("context");
const tools_module = @import("../tools.zig");

const AppContext = context_module.AppContext;
const ToolDefinition = tools_module.ToolDefinition;
const ToolResult = tools_module.ToolResult;

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "list_todos"),
                .description = try allocator.dupe(u8, "List all todos with their IDs and statuses."),
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
            .name = "list_todos",
            .description = "List all todos",
            .risk_level = .safe,
            .required_scopes = &.{.todo_management},
            .validator = null,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    _ = arguments;
    const start_time = std.time.milliTimestamp();

    const todos = context.state.getTodos();
    if (todos.len == 0) {
        // Return empty JSON array
        const msg = try allocator.dupe(u8, "[]");
        defer allocator.free(msg);
        return ToolResult.ok(allocator, msg, start_time, null);
    }

    // Build JSON array: [{"todo_id": "todo_1", "status": "pending", "content": "..."}, ...]
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "[");
    for (todos, 0..) |todo, i| {
        if (i > 0) try result.appendSlice(allocator, ",");

        const status_str = switch (todo.status) {
            .pending => "pending",
            .in_progress => "in_progress",
            .completed => "completed",
        };

        // Escape content for JSON
        var escaped_content = std.ArrayListUnmanaged(u8){};
        defer escaped_content.deinit(allocator);
        for (todo.content) |c| {
            switch (c) {
                '"' => try escaped_content.appendSlice(allocator, "\\\""),
                '\\' => try escaped_content.appendSlice(allocator, "\\\\"),
                '\n' => try escaped_content.appendSlice(allocator, "\\n"),
                '\r' => try escaped_content.appendSlice(allocator, "\\r"),
                '\t' => try escaped_content.appendSlice(allocator, "\\t"),
                else => try escaped_content.append(allocator, c),
            }
        }

        const todo_json = try std.fmt.allocPrint(
            allocator,
            "{{\"todo_id\":\"{s}\",\"status\":\"{s}\",\"content\":\"{s}\"}}",
            .{ todo.id, status_str, escaped_content.items },
        );
        defer allocator.free(todo_json);
        try result.appendSlice(allocator, todo_json);
    }
    try result.appendSlice(allocator, "]");

    const result_str = try result.toOwnedSlice(allocator);
    defer allocator.free(result_str);
    return ToolResult.ok(allocator, result_str, start_time, null);
}
