// Read File Tool - Reads and returns file contents
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
                .name = try allocator.dupe(u8, "read_file"),
                .description = try allocator.dupe(u8, "Reads and returns the complete contents of a specific file. ONLY use this when the user explicitly asks to see, read, or analyze a specific file's contents. DO NOT automatically read multiple files - use get_file_tree first to see what files exist."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "path": {
                    \\      "type": "string",
                    \\      "description": "The relative path to the file from the project root"
                    \\    }
                    \\  },
                    \\  "required": ["path"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "read_file",
            .description = "Read file contents",
            .risk_level = .medium,
            .required_scopes = &.{.read_files},
            .validator = validate,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    const start_time = std.time.milliTimestamp();

    // Handle empty arguments "{}" gracefully
    if (arguments.len == 0 or std.mem.eql(u8, arguments, "{}")) {
        return ToolResult.err(allocator, .validation_failed, "read_file requires a 'path' argument", start_time);
    }

    const Args = struct { path: []const u8 };
    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{}) catch {
        return ToolResult.err(allocator, .parse_error, "Invalid JSON arguments", start_time);
    };
    defer parsed.deinit();

    // Read the file
    const file = std.fs.cwd().openFile(parsed.value.path, .{}) catch {
        const msg = try std.fmt.allocPrint(allocator, "File not found: {s}", .{parsed.value.path});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .not_found, msg, start_time);
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "IO error reading file: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .io_error, msg, start_time);
    };
    defer allocator.free(content);

    // Format content with clear header, numbered lines, and footer notes
    var formatted_output = std.ArrayListUnmanaged(u8){};
    defer formatted_output.deinit(allocator);
    const writer = formatted_output.writer(allocator);

    // Count total lines
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var lines = std.ArrayListUnmanaged([]const u8){};
    defer lines.deinit(allocator);

    while (line_iter.next()) |line| {
        try lines.append(allocator, line);
    }

    const total_lines = lines.items.len;

    // Wrap in code fence for proper formatting in both markdown and LLM
    try writer.writeAll("```\n");

    // Write header
    try writer.print("File: {s}\n", .{parsed.value.path});
    try writer.print("Total lines: {d}\n", .{total_lines});
    try writer.writeAll("Content:\n");

    // Write numbered lines
    for (lines.items, 0..) |line, idx| {
        try writer.print("{d}: {s}\n", .{ idx + 1, line });
    }

    // Write footer notes
    try writer.writeAll("\nNotes: Lines are 1-indexed. Empty lines are preserved.\n");
    try writer.writeAll("```");

    const formatted = try formatted_output.toOwnedSlice(allocator);

    // Phase 2+: Trigger AST parsing here
    // if (context.graph) |graph| {
    //     _ = try context.parser.?.parseFile(parsed.value.path, content, graph, ...);
    // }

    // Mark file as read for edit_file requirement
    try context.state.markFileAsRead(parsed.value.path);

    return ToolResult.ok(allocator, formatted, start_time);
}

fn validate(allocator: std.mem.Allocator, arguments: []const u8) bool {
    const Args = struct { path: []const u8 };
    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{}) catch return false;
    defer parsed.deinit();

    // Check path is not absolute
    if (std.mem.startsWith(u8, parsed.value.path, "/")) return false;

    // Check path doesn't escape with ..
    if (std.mem.indexOf(u8, parsed.value.path, "..") != null) return false;

    return true;
}
