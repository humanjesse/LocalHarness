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
                .name = try allocator.dupe(u8, "git_commit"),
                .description = try allocator.dupe(u8, "Create a git commit with a message. Optionally amend the last commit."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "message": {
                    \\      "type": "string",
                    \\      "description": "Commit message"
                    \\    },
                    \\    "amend": {
                    \\      "type": "boolean",
                    \\      "description": "If true, amends the last commit instead of creating a new one"
                    \\    }
                    \\  },
                    \\  "required": ["message"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "git_commit",
            .description = "Create git commit",
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
        message: []const u8,
        amend: ?bool = null,
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

    // Validate message is not empty
    if (args.message.len == 0) {
        const msg = try allocator.dupe(u8, "Commit message cannot be empty");
        defer allocator.free(msg);
        return ToolResult.err(allocator, .validation_failed, msg, start_time);
    }

    // Build git commit command
    var argv = try std.ArrayList([]const u8).initCapacity(allocator, 5);
    defer argv.deinit(allocator);

    try argv.append(allocator, "git");
    try argv.append(allocator, "commit");

    if (args.amend orelse false) {
        try argv.append(allocator, "--amend");
    }

    try argv.append(allocator, "-m");
    try argv.append(allocator, args.message);

    // Execute git commit
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
                    try std.fmt.allocPrint(allocator, "git commit failed: {s}", .{result.stderr})
                else
                    try allocator.dupe(u8, "git commit failed (nothing to commit?)");
                defer allocator.free(msg);
                return ToolResult.err(allocator, .io_error, msg, start_time);
            }
        },
        else => {
            const msg = try allocator.dupe(u8, "git commit terminated abnormally");
            defer allocator.free(msg);
            return ToolResult.err(allocator, .io_error, msg, start_time);
        },
    }

    // Format success message with commit output
    const formatted = if (result.stdout.len > 0)
        try std.fmt.allocPrint(allocator, "Commit successful:\n```\n{s}```", .{result.stdout})
    else
        try allocator.dupe(u8, "Commit created successfully");
    defer allocator.free(formatted);

    return ToolResult.ok(allocator, formatted, start_time, null);
}
