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
                .name = try allocator.dupe(u8, "git_stash"),
                .description = try allocator.dupe(u8, "Manage git stashes: save changes, restore them, or view stash list."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "action": {
                    \\      "type": "string",
                    \\      "enum": ["save", "pop", "list", "apply", "drop", "clear"],
                    \\      "description": "Action: save (stash changes), pop (restore and remove), list (show stashes), apply (restore without removing), drop (delete stash), clear (delete all)"
                    \\    },
                    \\    "message": {
                    \\      "type": "string",
                    \\      "description": "Optional message for save action"
                    \\    },
                    \\    "index": {
                    \\      "type": "integer",
                    \\      "description": "Stash index for apply/drop actions (e.g., 0 for stash@{0})"
                    \\    }
                    \\  },
                    \\  "required": ["action"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "git_stash",
            .description = "Manage git stashes",
            .risk_level = .medium,
            .required_scopes = &.{.write_files},
            .validator = null,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    _ = context;
    const start_time = std.time.milliTimestamp();

    // Parse arguments
    const Args = struct {
        action: []const u8,
        message: ?[]const u8 = null,
        index: ?i32 = null,
    };

    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Invalid JSON arguments: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .parse_error, msg, start_time);
    };
    defer parsed.deinit();

    const args = parsed.value;

    // Validate action
    const is_save = std.mem.eql(u8, args.action, "save");
    const is_pop = std.mem.eql(u8, args.action, "pop");
    const is_list = std.mem.eql(u8, args.action, "list");
    const is_apply = std.mem.eql(u8, args.action, "apply");
    const is_drop = std.mem.eql(u8, args.action, "drop");
    const is_clear = std.mem.eql(u8, args.action, "clear");

    if (!is_save and !is_pop and !is_list and !is_apply and !is_drop and !is_clear) {
        const msg = try std.fmt.allocPrint(allocator, "Invalid action: {s}. Must be 'save', 'pop', 'list', 'apply', 'drop', or 'clear'", .{args.action});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .validation_failed, msg, start_time);
    }

    // Build git stash command
    var argv = try std.ArrayList([]const u8).initCapacity(allocator, 5);
    defer argv.deinit(allocator);

    try argv.append(allocator, "git");
    try argv.append(allocator, "stash");

    if (is_save) {
        try argv.append(allocator, "push");
        if (args.message) |msg| {
            try argv.append(allocator, "-m");
            try argv.append(allocator, msg);
        }
    } else if (is_pop) {
        try argv.append(allocator, "pop");
    } else if (is_list) {
        try argv.append(allocator, "list");
    } else if (is_apply) {
        try argv.append(allocator, "apply");
        if (args.index) |idx| {
            const stash_ref = try std.fmt.allocPrint(allocator, "stash@{{{d}}}", .{idx});
            defer allocator.free(stash_ref);
            try argv.append(allocator, stash_ref);
        }
    } else if (is_drop) {
        try argv.append(allocator, "drop");
        if (args.index) |idx| {
            const stash_ref = try std.fmt.allocPrint(allocator, "stash@{{{d}}}", .{idx});
            defer allocator.free(stash_ref);
            try argv.append(allocator, stash_ref);
        }
    } else if (is_clear) {
        try argv.append(allocator, "clear");
    }

    // Execute git stash
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
    }) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to execute git command: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .io_error, msg, start_time);
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Check exit code
    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                const msg = if (result.stderr.len > 0)
                    try std.fmt.allocPrint(allocator, "git stash failed: {s}", .{result.stderr})
                else
                    try allocator.dupe(u8, "git stash failed");
                defer allocator.free(msg);
                return ToolResult.err(allocator, .io_error, msg, start_time);
            }
        },
        else => {
            const msg = try allocator.dupe(u8, "git stash terminated abnormally");
            defer allocator.free(msg);
            return ToolResult.err(allocator, .io_error, msg, start_time);
        },
    }

    // Format output
    const formatted = if (is_list and result.stdout.len > 0)
        try std.fmt.allocPrint(allocator, "Stashes:\n```\n{s}```", .{result.stdout})
    else if (result.stdout.len > 0)
        try std.fmt.allocPrint(allocator, "{s}", .{result.stdout})
    else if (is_save)
        try allocator.dupe(u8, "Changes stashed successfully")
    else if (is_pop)
        try allocator.dupe(u8, "Stash popped successfully")
    else if (is_clear)
        try allocator.dupe(u8, "All stashes cleared")
    else
        try allocator.dupe(u8, "Stash operation completed");
    defer allocator.free(formatted);

    return ToolResult.ok(allocator, formatted, start_time, null);
}
