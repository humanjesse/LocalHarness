// Write File Tool - Creates or overwrites a file with given content
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
                .name = try allocator.dupe(u8, "write_file"),
                .description = try allocator.dupe(u8, "Creates a new file or completely overwrites an existing file with the provided content. Use this to create new files from scratch. For editing existing files, prefer edit_file instead. WARNING: This will overwrite the entire file if it already exists."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "path": {
                    \\      "type": "string",
                    \\      "description": "The relative path where the file should be created or overwritten"
                    \\    },
                    \\    "content": {
                    \\      "type": "string",
                    \\      "description": "The complete content to write to the file"
                    \\    }
                    \\  },
                    \\  "required": ["path", "content"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "write_file",
            .description = "Create or overwrite file with content",
            .risk_level = .high, // High risk - creates/modifies files! Triggers preview in permission prompt
            .required_scopes = &.{.write_files},
            .validator = validate,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    _ = context; // Phase 2+: Will be used for graph RAG integration
    const start_time = std.time.milliTimestamp();

    // Parse arguments
    const Args = struct {
        path: []const u8,
        content: []const u8,
    };
    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{}) catch {
        return ToolResult.err(allocator, .parse_error, "Invalid JSON arguments", start_time);
    };
    defer parsed.deinit();

    // Create parent directory if it doesn't exist
    if (std.fs.path.dirname(parsed.value.path)) |dir_path| {
        std.fs.cwd().makePath(dir_path) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to create parent directory: {}", .{err});
            defer allocator.free(msg);
            return ToolResult.err(allocator, .io_error, msg, start_time);
        };
    }

    // Create/overwrite the file
    const file = std.fs.cwd().createFile(parsed.value.path, .{}) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to create file: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .io_error, msg, start_time);
    };
    defer file.close();

    // Write content to file
    file.writeAll(parsed.value.content) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to write to file: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .io_error, msg, start_time);
    };

    // Return success with details
    const success_msg = try std.fmt.allocPrint(
        allocator,
        "Successfully wrote {d} bytes to {s}",
        .{ parsed.value.content.len, parsed.value.path },
    );
    defer allocator.free(success_msg);

    return ToolResult.ok(allocator, success_msg, start_time, null);
}

fn validate(allocator: std.mem.Allocator, arguments: []const u8) bool {
    const Args = struct {
        path: []const u8,
        content: []const u8,
    };
    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{}) catch return false;
    defer parsed.deinit();

    // Block absolute paths
    if (std.mem.startsWith(u8, parsed.value.path, "/")) return false;

    // Block directory traversal
    if (std.mem.indexOf(u8, parsed.value.path, "..") != null) return false;

    // Block empty paths
    if (parsed.value.path.len == 0) return false;

    return true;
}
