// Edit File Tool - Makes targeted edits using exact string replacement
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
                .name = try allocator.dupe(u8, "edit_file"),
                .description = try allocator.dupe(u8, "Makes targeted edits to an existing file by replacing exact string matches. You MUST use read_file first to see the current contents. Provide the exact old_string to be replaced (including whitespace) and the new_string to replace it with. The old_string must be unique unless you set replace_all=true."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "path": {
                    \\      "type": "string",
                    \\      "description": "Relative path to the file to edit"
                    \\    },
                    \\    "old_string": {
                    \\      "type": "string",
                    \\      "description": "Exact string to find and replace (must match exactly including whitespace)"
                    \\    },
                    \\    "new_string": {
                    \\      "type": "string",
                    \\      "description": "New string to replace with"
                    \\    },
                    \\    "replace_all": {
                    \\      "type": "boolean",
                    \\      "description": "If true, replace all occurrences. If false (default), old_string must be unique in the file."
                    \\    }
                    \\  },
                    \\  "required": ["path", "old_string", "new_string"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "edit_file",
            .description = "Edit file with exact string replacement",
            .risk_level = .high, // High risk - modifies files! Triggers preview in permission prompt
            .required_scopes = &.{.write_files},
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
        old_string: []const u8,
        new_string: []const u8,
        replace_all: bool = false,
    };
    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{}) catch {
        return ToolResult.err(allocator, .parse_error, "Invalid JSON arguments", start_time);
    };
    defer parsed.deinit();

    // SAFETY: Check if file was read first (read-first requirement)
    if (!context.state.wasFileRead(parsed.value.path)) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "You must use read_file on '{s}' before editing it",
            .{parsed.value.path},
        );
        defer allocator.free(msg);
        return ToolResult.err(allocator, .permission_denied, msg, start_time);
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

    // Count occurrences of old_string
    const count = std.mem.count(u8, content, parsed.value.old_string);

    if (count == 0) {
        return ToolResult.err(allocator, .not_found, "String not found in file", start_time);
    }

    if (count > 1 and !parsed.value.replace_all) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "String appears {d} times - not unique! Provide more context or set replace_all=true",
            .{count},
        );
        defer allocator.free(msg);
        return ToolResult.err(allocator, .validation_failed, msg, start_time);
    }

    // Perform the replacement
    const new_content = try std.mem.replaceOwned(
        u8,
        allocator,
        content,
        parsed.value.old_string,
        parsed.value.new_string,
    );
    defer allocator.free(new_content);

    // Write back to disk
    const write_file = std.fs.cwd().createFile(parsed.value.path, .{}) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to open file for writing: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .io_error, msg, start_time);
    };
    defer write_file.close();

    write_file.writeAll(new_content) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to write file: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .io_error, msg, start_time);
    };

    // Return success with details
    const success_msg = try std.fmt.allocPrint(
        allocator,
        "Successfully replaced {d} occurrence(s) in {s}",
        .{ count, parsed.value.path },
    );
    defer allocator.free(success_msg);

    return ToolResult.ok(allocator, success_msg, start_time);
}

fn validate(allocator: std.mem.Allocator, arguments: []const u8) bool {
    const Args = struct {
        path: []const u8,
        old_string: []const u8,
        new_string: []const u8,
        replace_all: bool = false,
    };
    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{}) catch return false;
    defer parsed.deinit();

    // Block absolute paths
    if (std.mem.startsWith(u8, parsed.value.path, "/")) return false;

    // Block directory traversal
    if (std.mem.indexOf(u8, parsed.value.path, "..") != null) return false;

    // Must have actual changes (old and new can't be the same)
    if (std.mem.eql(u8, parsed.value.old_string, parsed.value.new_string)) return false;

    return true;
}
