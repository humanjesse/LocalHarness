// Update Todo Tool - Updates todo status by ID
const std = @import("std");
const ollama = @import("ollama");
const permission = @import("permission");
const context_module = @import("context");
const state_module = @import("state");
const tools_module = @import("../tools.zig");

const AppContext = context_module.AppContext;
const TodoStatus = state_module.TodoStatus;
const ToolDefinition = tools_module.ToolDefinition;
const ToolResult = tools_module.ToolResult;

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "update_todo"),
                .description = try allocator.dupe(u8, "Update a todo's status by its todo_id."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "todo_id": {
                    \\      "type": "string",
                    \\      "description": "The todo_id returned from add_todo (e.g., 'todo_1'). REQUIRED - do not use null."
                    \\    },
                    \\    "status": {
                    \\      "type": "string",
                    \\      "enum": ["pending", "in_progress", "completed"],
                    \\      "description": "New status"
                    \\    }
                    \\  },
                    \\  "required": ["todo_id", "status"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "update_todo",
            .description = "Update todo status",
            .risk_level = .safe,
            .required_scopes = &.{.todo_management},
            .validator = null,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    const start_time = std.time.milliTimestamp();

    const Args = struct {
        todo_id: []const u8,
        status: []const u8,
    };
    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{}) catch {
        const msg = try std.fmt.allocPrint(
            allocator,
            "Invalid JSON arguments. Expected {{\"todo_id\": \"todo_X\", \"status\": \"<status>\"}}, received: {s}. The 'todo_id' must be a STRING from add_todo or list_todos, not null.",
            .{arguments},
        );
        defer allocator.free(msg);
        return ToolResult.err(allocator, .parse_error, msg, start_time);
    };
    defer parsed.deinit();

    // Validate todo_id is not empty
    if (parsed.value.todo_id.len == 0) {
        return ToolResult.err(allocator, .validation_failed, "todo_id cannot be empty. Use the todo_id from add_todo (e.g., 'todo_1')", start_time);
    }

    const new_status: TodoStatus = blk: {
        if (std.mem.eql(u8, parsed.value.status, "pending")) break :blk .pending;
        if (std.mem.eql(u8, parsed.value.status, "in_progress")) break :blk .in_progress;
        if (std.mem.eql(u8, parsed.value.status, "completed")) break :blk .completed;
        return ToolResult.err(allocator, .validation_failed, "Invalid status. Must be 'pending', 'in_progress', or 'completed'", start_time);
    };

    context.state.updateTodo(parsed.value.todo_id, new_status) catch |err| {
        if (err == error.TodoNotFound) {
            const msg = try std.fmt.allocPrint(allocator, "Todo '{s}' not found. Use list_todos to see available todo IDs.", .{parsed.value.todo_id});
            defer allocator.free(msg);
            return ToolResult.err(allocator, .not_found, msg, start_time);
        }
        const msg = try std.fmt.allocPrint(allocator, "Failed to update todo: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .internal_error, msg, start_time);
    };

    // Return JSON confirmation with todo_id and new status
    const result_msg = try std.fmt.allocPrint(allocator, "{{\"todo_id\":\"{s}\",\"status\":\"{s}\"}}", .{ parsed.value.todo_id, parsed.value.status });
    defer allocator.free(result_msg);
    return ToolResult.ok(allocator, result_msg, start_time, null);
}
