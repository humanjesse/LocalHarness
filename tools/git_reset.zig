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
                .name = try allocator.dupe(u8, "git_reset"),
                .description = try allocator.dupe(u8, "Reset current HEAD to specified state. WARNING: 'hard' mode discards all changes permanently. Use 'soft' or 'mixed' to preserve changes."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "mode": {
                    \\      "type": "string",
                    \\      "enum": ["soft", "mixed", "hard"],
                    \\      "description": "Reset mode: soft (keep changes staged), mixed (keep changes unstaged), hard (DISCARD all changes)"
                    \\    },
                    \\    "target": {
                    \\      "type": "string",
                    \\      "description": "Target commit (e.g., 'HEAD~1', commit hash, 'origin/main'). Default: HEAD"
                    \\    },
                    \\    "file_path": {
                    \\      "type": "string",
                    \\      "description": "If provided, unstages only this file (mode is ignored)"
                    \\    }
                    \\  },
                    \\  "required": []
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "git_reset",
            .description = "Reset changes (WARNING: can be destructive)",
            .risk_level = .high,
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
        mode: ?[]const u8 = null,
        target: ?[]const u8 = null,
        file_path: ?[]const u8 = null,
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

    // If file_path is provided, it's a simple unstage operation
    const is_file_reset = args.file_path != null;

    // Otherwise validate mode
    var mode_flag: ?[]const u8 = null;
    if (!is_file_reset) {
        if (args.mode) |mode| {
            const is_soft = std.mem.eql(u8, mode, "soft");
            const is_mixed = std.mem.eql(u8, mode, "mixed");
            const is_hard = std.mem.eql(u8, mode, "hard");

            if (!is_soft and !is_mixed and !is_hard) {
                const msg = try std.fmt.allocPrint(allocator, "Invalid mode: {s}. Must be 'soft', 'mixed', or 'hard'", .{mode});
                defer allocator.free(msg);
                return ToolResult.err(allocator, .validation_failed, msg, start_time);
            }

            if (is_soft) {
                mode_flag = "--soft";
            } else if (is_mixed) {
                mode_flag = "--mixed";
            } else if (is_hard) {
                mode_flag = "--hard";
            }
        } else {
            // Default to mixed if no mode specified
            mode_flag = "--mixed";
        }
    }

    // Build git reset command
    var argv = try std.ArrayList([]const u8).initCapacity(allocator, 5);
    defer argv.deinit(allocator);

    try argv.append(allocator, "git");
    try argv.append(allocator, "reset");

    if (is_file_reset) {
        // File unstaging: git reset HEAD <file>
        try argv.append(allocator, "HEAD");
        try argv.append(allocator, args.file_path.?);
    } else {
        // Commit reset
        if (mode_flag) |flag| {
            try argv.append(allocator, flag);
        }
        if (args.target) |target| {
            try argv.append(allocator, target);
        }
    }

    // Execute git reset
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
                    try std.fmt.allocPrint(allocator, "git reset failed: {s}", .{result.stderr})
                else
                    try allocator.dupe(u8, "git reset failed");
                defer allocator.free(msg);
                return ToolResult.err(allocator, .io_error, msg, start_time);
            }
        },
        else => {
            const msg = try allocator.dupe(u8, "git reset terminated abnormally");
            defer allocator.free(msg);
            return ToolResult.err(allocator, .io_error, msg, start_time);
        },
    }

    // Format success message
    const formatted = if (is_file_reset)
        try std.fmt.allocPrint(allocator, "Unstaged file: {s}", .{args.file_path.?})
    else if (args.mode) |mode|
        try std.fmt.allocPrint(allocator, "Reset successful (mode: {s})", .{mode})
    else
        try allocator.dupe(u8, "Reset successful");
    defer allocator.free(formatted);

    return ToolResult.ok(allocator, formatted, start_time, null);
}
