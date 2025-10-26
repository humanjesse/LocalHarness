// Add Task Tool - Adds a new task to the task list
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
                .name = try allocator.dupe(u8, "add_task"),
                .description = try allocator.dupe(u8, "Create a new task. Returns a task_id (e.g., 'task_3') that you MUST use in update_task calls. Example: {\"content\": \"Fix authentication bug\"} returns {\"task_id\": \"task_1\"}"),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "content": {
                    \\      "type": "string",
                    \\      "description": "Description of the task to add"
                    \\    }
                    \\  },
                    \\  "required": ["content"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "add_task",
            .description = "Add task to list",
            .risk_level = .safe,
            .required_scopes = &.{.task_management},
            .validator = null,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    const start_time = std.time.milliTimestamp();

    const Args = struct { content: []const u8 };
    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{}) catch {
        return ToolResult.err(allocator, .parse_error, "Invalid JSON arguments", start_time);
    };
    defer parsed.deinit();

    const task_id = context.state.addTask(parsed.value.content) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to add task: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .internal_error, msg, start_time);
    };

    // Return JSON with string ID: {"task_id": "task_1"}
    const result_msg = try std.fmt.allocPrint(allocator, "{{\"task_id\": \"{s}\"}}", .{task_id});
    defer allocator.free(result_msg);
    return ToolResult.ok(allocator, result_msg, start_time, null);
}
