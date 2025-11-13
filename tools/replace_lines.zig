// Replace Lines Tool - Replaces specific line ranges in a file
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
                .name = try allocator.dupe(u8, "replace_lines"),
                .description = try allocator.dupe(u8, "Replaces specific line ranges in a file. WORKFLOW: First call read_file to see the file with line numbers (e.g. '1: foo', '2: bar'). Then call replace_lines specifying which lines to replace. EXAMPLE: If read_file shows '1: hello' and you want to change it to 'goodbye', use {\"path\":\"file.txt\",\"line_start\":1,\"line_end\":1,\"new_content\":\"goodbye\"}. To replace multiple lines, set line_end higher. To add lines, include newlines in new_content (e.g. \"hello\\ngoodbye\" replaces line 1 with 2 lines)."),
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
                    \\      "description": "First line number to replace (1-indexed, as shown in read_file output)"
                    \\    },
                    \\    "line_end": {
                    \\      "type": "integer",
                    \\      "description": "Last line number to replace (inclusive, 1-indexed)"
                    \\    },
                    \\    "new_content": {
                    \\      "type": "string",
                    \\      "description": "New content to replace the specified lines with"
                    \\    }
                    \\  },
                    \\  "required": ["path", "line_start", "line_end", "new_content"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "replace_lines",
            .description = "Replace lines in file",
            .risk_level = .high, // High risk - modifies files! Triggers preview in permission prompt
            .required_scopes = &.{.write_files},
            .validator = validate,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, arguments: []const u8, _: *AppContext) !ToolResult {
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

    if (parsed.value.line_start > parsed.value.line_end) {
        return ToolResult.err(allocator, .validation_failed, "line_start must be <= line_end", start_time);
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

    // Check if line numbers are in range
    if (parsed.value.line_end > total_lines) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "line_end ({d}) out of range (file has {d} lines)",
            .{ parsed.value.line_end, total_lines },
        );
        defer allocator.free(msg);
        return ToolResult.err(allocator, .validation_failed, msg, start_time);
    }

    // Build new file content
    var new_file_content = std.ArrayListUnmanaged(u8){};
    defer new_file_content.deinit(allocator);
    const writer = new_file_content.writer(allocator);

    // Write lines before the edit range
    for (lines.items[0 .. parsed.value.line_start - 1]) |line| {
        try writer.print("{s}\n", .{line});
    }

    // Write the new content
    try writer.writeAll(parsed.value.new_content);
    if (parsed.value.new_content.len > 0 and parsed.value.new_content[parsed.value.new_content.len - 1] != '\n') {
        try writer.writeByte('\n');
    }

    // Write lines after the edit range
    if (parsed.value.line_end < total_lines) {
        for (lines.items[parsed.value.line_end..]) |line| {
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
    const lines_replaced = parsed.value.line_end - parsed.value.line_start + 1;
    const success_msg = try std.fmt.allocPrint(
        allocator,
        "Successfully replaced {d} line(s) ({d}-{d}) in {s}",
        .{ lines_replaced, parsed.value.line_start, parsed.value.line_end, parsed.value.path },
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
    if (parsed.value.line_start > parsed.value.line_end) return false;

    return true;
}
