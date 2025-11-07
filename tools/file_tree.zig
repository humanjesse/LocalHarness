// File Tree Tool - Lists all files in project directory
const std = @import("std");
const ollama = @import("ollama");
const permission = @import("permission");
const context_module = @import("context");
const tools_module = @import("../tools.zig");
const tree = @import("tree");

const AppContext = context_module.AppContext;
const ToolDefinition = tools_module.ToolDefinition;
const ToolResult = tools_module.ToolResult;

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "get_file_tree"),
                .description = try allocator.dupe(u8, "Returns a JSON array listing file paths recursively in a directory tree. Respects .gitignore patterns and filters build artifacts. Use this to explore project structure, then use read_file for actual code. For single directory listing with metadata, use ls instead."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "path": {
                    \\      "type": "string",
                    \\      "description": "Directory path to scan (default: '.' for current directory)"
                    \\    },
                    \\    "max_depth": {
                    \\      "type": "integer",
                    \\      "description": "Maximum directory depth to traverse (default: 10, min: 1, max: 20)"
                    \\    }
                    \\  },
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
            .validator = validate,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    _ = context; // Phase 1: not used yet (will trigger graph indexing in Phase 2)
    const start_time = std.time.milliTimestamp();

    // Parse arguments with defaults
    const Args = struct {
        path: ?[]const u8 = null,
        max_depth: ?usize = null,
    };

    const args_to_parse = if (arguments.len == 0 or std.mem.eql(u8, arguments, "{}"))
        "{}"
    else
        arguments;

    const parsed = std.json.parseFromSlice(Args, allocator, args_to_parse, .{}) catch {
        return ToolResult.err(allocator, .parse_error, "Invalid JSON arguments", start_time);
    };
    defer parsed.deinit();

    const args = parsed.value;
    const path = args.path orelse ".";
    const max_depth = if (args.max_depth) |d| @min(@max(d, 1), 20) else 10;

    const tree_json = tree.generateTree(allocator, path, max_depth) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to generate file tree: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .io_error, msg, start_time);
    };
    defer allocator.free(tree_json);

    return ToolResult.ok(allocator, tree_json, start_time, null);
}

fn validate(allocator: std.mem.Allocator, arguments: []const u8) bool {
    // Empty arguments are valid (all defaults)
    if (arguments.len == 0 or std.mem.eql(u8, arguments, "{}")) {
        return true;
    }

    const Args = struct {
        path: ?[]const u8 = null,
        max_depth: ?usize = null,
    };

    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{}) catch return false;
    defer parsed.deinit();

    const args = parsed.value;

    // Validate path if provided (same security checks as ls tool)
    if (args.path) |p| {
        // Block absolute paths
        if (std.mem.startsWith(u8, p, "/")) return false;
        // Block directory traversal
        if (std.mem.indexOf(u8, p, "..") != null) return false;
    }

    // Validate max_depth if provided
    if (args.max_depth) |d| {
        if (d == 0 or d > 20) return false;
    }

    return true;
}
