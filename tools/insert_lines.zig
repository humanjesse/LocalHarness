// Insert Lines Tool - Inserts new content before a specific line in a file
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
                .name = try allocator.dupe(u8, "insert_lines"),
                .description = try allocator.dupe(u8, "Insert content before a specific line. Lines are 1-indexed. Use line N+1 to append at end."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "path": {
                    \\      "type": "string",
                    \\      "description": "Relative path to the file to edit"
                    \\    },
                    \\    "line_start": {
                    \\      "type": "integer",
                    \\      "description": "Line number to insert before (1-indexed, as shown in read_file output). Use N+1 to append to end of file."
                    \\    },
                    \\    "line_end": {
                    \\      "type": "integer",
                    \\      "description": "Must be equal to line_start (single insertion point)"
                    \\    },
                    \\    "new_content": {
                    \\      "type": "string",
                    \\      "description": "New content to insert. Can contain newlines to insert multiple lines."
                    \\    }
                    \\  },
                    \\  "required": ["path", "line_start", "line_end", "new_content"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "insert_lines",
            .description = "Insert lines in file",
            .risk_level = .high, // High risk - modifies files! Triggers preview in permission prompt
            .required_scopes = &.{.write_files},
            .validator = validate,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    _ = context;
    const start_time = std.time.milliTimestamp();

    // Parse arguments
    const Args = struct {
        path: []const u8,
        line_start: usize,
        line_end: usize,
        new_content: []const u8,
    };
    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{}) catch {
        return ToolResult.err(allocator, .parse_error, "Invalid JSON arguments", start_time);
    };
    defer parsed.deinit();

    // Validate line numbers
    if (parsed.value.line_start == 0) {
        return ToolResult.err(allocator, .validation_failed, "line_start must be >= 1 (lines are 1-indexed)", start_time);
    }

    if (parsed.value.line_start != parsed.value.line_end) {
        return ToolResult.err(allocator, .validation_failed, "line_start must equal line_end for insert_lines (single insertion point)", start_time);
    }

    // Read current file contents
    const file = std.fs.cwd().openFile(parsed.value.path, .{}) catch {
        const msg = try std.fmt.allocPrint(allocator, "File not found: {s}", .{parsed.value.path});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .not_found, msg, start_time);
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to read file: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .io_error, msg, start_time);
    };
    defer allocator.free(content);

    // Split content into lines
    var lines = std.ArrayListUnmanaged([]const u8){};
    defer lines.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        try lines.append(allocator, line);
    }

    const total_lines = lines.items.len;

    // Check if line number is in valid range
    // Allow line_start == total_lines + 1 for appending to end
    if (parsed.value.line_start > total_lines + 1) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "line_start ({d}) out of range (file has {d} lines, use {d} to append)",
            .{ parsed.value.line_start, total_lines, total_lines + 1 },
        );
        defer allocator.free(msg);
        return ToolResult.err(allocator, .validation_failed, msg, start_time);
    }

    // Build new file content
    var new_file_content = std.ArrayListUnmanaged(u8){};
    defer new_file_content.deinit(allocator);
    const writer = new_file_content.writer(allocator);

    // Write lines before the insertion point
    const insert_index = parsed.value.line_start - 1; // Convert to 0-indexed
    for (lines.items[0..@min(insert_index, lines.items.len)]) |line| {
        try writer.print("{s}\n", .{line});
    }

    // Write the new content
    try writer.writeAll(parsed.value.new_content);
    if (parsed.value.new_content.len > 0 and parsed.value.new_content[parsed.value.new_content.len - 1] != '\n') {
        try writer.writeByte('\n');
    }

    // Write lines after the insertion point
    if (insert_index < total_lines) {
        for (lines.items[insert_index..]) |line| {
            try writer.print("{s}\n", .{line});
        }
    }

    const final_content = try new_file_content.toOwnedSlice(allocator);
    defer allocator.free(final_content);

    // Write back to disk
    const write_file = std.fs.cwd().createFile(parsed.value.path, .{}) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to open file for writing: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .io_error, msg, start_time);
    };
    defer write_file.close();

    write_file.writeAll(final_content) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to write file: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .io_error, msg, start_time);
    };

    // Return success with details
    const position_desc = if (parsed.value.line_start == 1)
        "at beginning"
    else if (parsed.value.line_start > total_lines)
        "at end (append)"
    else
        try std.fmt.allocPrint(allocator, "before line {d}", .{parsed.value.line_start});
    defer if (parsed.value.line_start > 1 and parsed.value.line_start <= total_lines) allocator.free(position_desc);

    const success_msg = try std.fmt.allocPrint(
        allocator,
        "Successfully inserted content {s} in {s}",
        .{ position_desc, parsed.value.path },
    );
    defer allocator.free(success_msg);

    return ToolResult.ok(allocator, success_msg, start_time, null);
}

fn validate(allocator: std.mem.Allocator, arguments: []const u8) bool {
    const Args = struct {
        path: []const u8,
        line_start: usize,
        line_end: usize,
        new_content: []const u8,
    };
    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{}) catch return false;
    defer parsed.deinit();

    // Block absolute paths
    if (std.mem.startsWith(u8, parsed.value.path, "/")) return false;

    // Block directory traversal
    if (std.mem.indexOf(u8, parsed.value.path, "..") != null) return false;

    // Validate line numbers
    if (parsed.value.line_start == 0) return false;
    if (parsed.value.line_start != parsed.value.line_end) return false;

    return true;
}
