// Get Working Directory Tool - Returns current working directory path
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
                .name = try allocator.dupe(u8, "get_working_directory"),
                .description = try allocator.dupe(u8, "Returns the absolute path of the current working directory. Use this when you need to know where you are in the filesystem or to provide context about the current location."),
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
            .name = "get_working_directory",
            .description = "Get current working directory path",
            .risk_level = .safe,
            .required_scopes = &.{.system_info},
            .validator = null,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    _ = arguments; // No arguments needed
    _ = context; // Not used
    const start_time = std.time.milliTimestamp();

    // Get the absolute path of the current working directory
    const cwd_path = std.fs.cwd().realpathAlloc(allocator, ".") catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to get working directory: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .io_error, msg, start_time);
    };
    defer allocator.free(cwd_path);

    // Format the result
    const result = try std.fmt.allocPrint(allocator, "Current working directory: {s}", .{cwd_path});
    defer allocator.free(result);

    return ToolResult.ok(allocator, result, start_time, null);
}
