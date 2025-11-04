// Read Lines Tool - Reads specific line ranges from files (no GraphRAG indexing)
const std = @import("std");
const ollama = @import("ollama");
const permission = @import("permission");
const context_module = @import("context");
const tools_module = @import("../tools.zig");
const tracking = @import("tracking");

const AppContext = context_module.AppContext;
const ToolDefinition = tools_module.ToolDefinition;
const ToolResult = tools_module.ToolResult;

// Maximum line range to prevent abuse (suggest read_file for larger ranges)
const MAX_LINE_RANGE = 500;

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "read_lines"),
                .description = try allocator.dupe(u8, "Read specific line ranges from a file for quick inspection. Use this for targeted edits when you know the line numbers, following error messages to specific locations, checking specific functions without full file indexing, or quick spot checks of file sections. Does NOT trigger GraphRAG indexing (fast, instant response). For full file analysis and indexing, use read_file instead."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "path": {
                    \\      "type": "string",
                    \\      "description": "The relative path to the file from the project root"
                    \\    },
                    \\    "start_line": {
                    \\      "type": "integer",
                    \\      "description": "First line number to read (1-indexed, inclusive)"
                    \\    },
                    \\    "end_line": {
                    \\      "type": "integer",
                    \\      "description": "Last line number to read (1-indexed, inclusive)"
                    \\    }
                    \\  },
                    \\  "required": ["path", "start_line", "end_line"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "read_lines",
            .description = "Read specific line ranges from file",
            .risk_level = .low, // Low risk - read-only, no expensive side effects
            .required_scopes = &.{.read_files},
            .validator = validate,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    const start_time = std.time.milliTimestamp();

    // Parse arguments
    const Args = struct {
        path: []const u8,
        start_line: usize,
        end_line: usize,
    };
    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{}) catch {
        return ToolResult.err(allocator, .parse_error, "Invalid JSON arguments", start_time);
    };
    defer parsed.deinit();

    // Validate line numbers
    if (parsed.value.start_line == 0) {
        return ToolResult.err(allocator, .validation_failed, "start_line must be >= 1 (lines are 1-indexed)", start_time);
    }

    if (parsed.value.start_line > parsed.value.end_line) {
        return ToolResult.err(allocator, .validation_failed, "start_line must be <= end_line", start_time);
    }

    // Check line range limit
    const requested_lines = parsed.value.end_line - parsed.value.start_line + 1;
    if (requested_lines > MAX_LINE_RANGE) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "Requested {d} lines. Maximum range is {d} lines. For larger ranges, use read_file to get full context and GraphRAG indexing.",
            .{ requested_lines, MAX_LINE_RANGE },
        );
        defer allocator.free(msg);
        return ToolResult.err(allocator, .validation_failed, msg, start_time);
    }

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

    // Split content into lines
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var lines = std.ArrayListUnmanaged([]const u8){};
    defer lines.deinit(allocator);

    while (line_iter.next()) |line| {
        try lines.append(allocator, line);
    }

    const total_lines = lines.items.len;

    // Handle empty file
    if (total_lines == 0) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "File: {s}\nFile is empty (0 lines)",
            .{parsed.value.path},
        );
        defer allocator.free(msg);
        return ToolResult.ok(allocator, msg, start_time, null);
    }

    // Validate line range is within file bounds
    if (parsed.value.end_line > total_lines) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "Line {d} out of range (file has {d} line{s})",
            .{ parsed.value.end_line, total_lines, if (total_lines == 1) "" else "s" },
        );
        defer allocator.free(msg);
        return ToolResult.err(allocator, .validation_failed, msg, start_time);
    }

    // Format output with line numbers (matching read_file style)
    var formatted_output = std.ArrayListUnmanaged(u8){};
    defer formatted_output.deinit(allocator);
    const writer = formatted_output.writer(allocator);

    // Wrap in code fence for proper formatting
    try writer.writeAll("```\n");

    // Write header
    try writer.print("File: {s} (lines {d}-{d})\n", .{ parsed.value.path, parsed.value.start_line, parsed.value.end_line });
    try writer.print("Total lines in file: {d}\n", .{total_lines});
    try writer.print("Showing: {d} line{s}\n", .{ requested_lines, if (requested_lines == 1) "" else "s" });
    try writer.writeAll("Content:\n");

    // Write numbered lines for requested range
    // Lines are 1-indexed, so convert to 0-indexed for array access
    const start_idx = parsed.value.start_line - 1;
    const end_idx = parsed.value.end_line - 1;

    for (lines.items[start_idx .. end_idx + 1], start_idx..) |line, idx| {
        try writer.print("{d}: {s}\n", .{ idx + 1, line });
    }

    // Write footer notes
    try writer.writeAll("\nNotes: Lines are 1-indexed. ");
    if (requested_lines < total_lines) {
        try writer.print("Showing {d} of {d} total lines. ", .{ requested_lines, total_lines });
    }
    try writer.writeAll("Use read_file to index full file for GraphRAG.\n");
    try writer.writeAll("```");

    const formatted = try formatted_output.toOwnedSlice(allocator);
    defer allocator.free(formatted);

    // Track line-range read in context tracker (for hot context injection)
    if (context.context_tracker) |tracker| {
        tracker.trackFileRead(
            parsed.value.path,
            content,
            .lines,
            .{ .start = parsed.value.start_line, .end = parsed.value.end_line },
        ) catch |err| {
            if (std.posix.getenv("DEBUG_CONTEXT")) |_| {
                std.debug.print("[CONTEXT] Failed to track line read: {}\n", .{err});
            }
        };
    }

    // NOTE: Intentionally NOT doing the following:
    // - NOT queuing for GraphRAG indexing (fast, exploration-focused)
    // - NOT marking file as "read" for edit_file (require full context for edits)

    return ToolResult.ok(allocator, formatted, start_time, null);
}

fn validate(allocator: std.mem.Allocator, arguments: []const u8) bool {
    const Args = struct {
        path: []const u8,
        start_line: usize,
        end_line: usize,
    };
    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{}) catch return false;
    defer parsed.deinit();

    // Block absolute paths
    if (std.mem.startsWith(u8, parsed.value.path, "/")) return false;

    // Block directory traversal
    if (std.mem.indexOf(u8, parsed.value.path, "..") != null) return false;

    // Block empty paths
    if (parsed.value.path.len == 0) return false;

    // Validate line numbers
    if (parsed.value.start_line == 0) return false;
    if (parsed.value.start_line > parsed.value.end_line) return false;

    // Validate line range
    const requested_lines = parsed.value.end_line - parsed.value.start_line + 1;
    if (requested_lines > MAX_LINE_RANGE) return false;

    return true;
}
