// File Tree Tool - Lists all files in project directory
const std = @import("std");
const ollama = @import("../ollama.zig");
const permission = @import("../permission.zig");
const context_module = @import("../context.zig");
const tools_module = @import("../tools.zig");
const tree = @import("tree.zig");

const AppContext = context_module.AppContext;
const ToolDefinition = tools_module.ToolDefinition;
const ToolResult = tools_module.ToolResult;

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "get_file_tree"),
                .description = try allocator.dupe(u8, "Returns a JSON array listing ALL file paths in the project directory tree. This shows ONLY filenames and paths, NOT file contents. Use this first to see what files exist, then use read_file if you need to see actual code."),
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
            .name = "get_file_tree",
            .description = "List all files in project",
            .risk_level = .safe,
            .required_scopes = &.{.read_files},
            .validator = null,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    _ = arguments; // No arguments needed
    _ = context; // Phase 1: not used yet (will trigger graph indexing in Phase 2)
    const start_time = std.time.milliTimestamp();

    const tree_json = tree.generateTree(allocator, ".") catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to generate file tree: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .io_error, msg, start_time);
    };
    defer allocator.free(tree_json);

    return ToolResult.ok(allocator, tree_json, start_time, null);
}
