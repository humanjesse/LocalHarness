// Update Task Tool - Updates task status by ID
const std = @import("std");
const ollama = @import("../ollama.zig");
const permission = @import("../permission.zig");
const context_module = @import("../context.zig");
const state_module = @import("../state.zig");
const tools_module = @import("../tools.zig");

const AppContext = context_module.AppContext;
const TaskStatus = state_module.TaskStatus;
const ToolDefinition = tools_module.ToolDefinition;
const ToolResult = tools_module.ToolResult;

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "update_task"),
                .description = try allocator.dupe(u8, "Update task status using the task_id returned from add_task. Example: {\"task_id\": \"task_1\", \"status\": \"completed\"} returns {\"task_id\": \"task_1\", \"status\": \"completed\"}"),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "task_id": {
                    \\      "type": "string",
                    \\      "description": "The task_id returned from add_task (e.g., 'task_1'). REQUIRED - do not use null."
                    \\    },
                    \\    "status": {
                    \\      "type": "string",
                    \\      "enum": ["pending", "in_progress", "completed"],
                    \\      "description": "New status"
                    \\    }
                    \\  },
                    \\  "required": ["task_id", "status"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "update_task",
            .description = "Update task status",
            .risk_level = .safe,
            .required_scopes = &.{.task_management},
            .validator = null,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    const start_time = std.time.milliTimestamp();

    const Args = struct {
        task_id: []const u8,
        status: []const u8,
    };
    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{}) catch {
        const msg = try std.fmt.allocPrint(
            allocator,
            "Invalid JSON arguments. Expected {{\"task_id\": \"task_X\", \"status\": \"<status>\"}}, received: {s}. The 'task_id' must be a STRING from add_task or list_tasks, not null.",
            .{arguments},
        );
        defer allocator.free(msg);
        return ToolResult.err(allocator, .parse_error, msg, start_time);
    };
    defer parsed.deinit();

    // Validate task_id is not empty
    if (parsed.value.task_id.len == 0) {
        return ToolResult.err(allocator, .validation_failed, "task_id cannot be empty. Use the task_id from add_task (e.g., 'task_1')", start_time);
    }

    const new_status: TaskStatus = blk: {
        if (std.mem.eql(u8, parsed.value.status, "pending")) break :blk .pending;
        if (std.mem.eql(u8, parsed.value.status, "in_progress")) break :blk .in_progress;
        if (std.mem.eql(u8, parsed.value.status, "completed")) break :blk .completed;
        return ToolResult.err(allocator, .validation_failed, "Invalid status. Must be 'pending', 'in_progress', or 'completed'", start_time);
    };

    context.state.updateTask(parsed.value.task_id, new_status) catch |err| {
        if (err == error.TaskNotFound) {
            const msg = try std.fmt.allocPrint(allocator, "Task '{s}' not found. Use list_tasks to see available task IDs.", .{parsed.value.task_id});
            defer allocator.free(msg);
            return ToolResult.err(allocator, .not_found, msg, start_time);
        }
        const msg = try std.fmt.allocPrint(allocator, "Failed to update task: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .internal_error, msg, start_time);
    };

    // Return JSON confirmation with task_id and new status
    const result_msg = try std.fmt.allocPrint(allocator, "{{\"task_id\":\"{s}\",\"status\":\"{s}\"}}", .{ parsed.value.task_id, parsed.value.status });
    defer allocator.free(result_msg);
    return ToolResult.ok(allocator, result_msg, start_time, null);
}
