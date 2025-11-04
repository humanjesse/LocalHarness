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
                .name = try allocator.dupe(u8, "git_pull"),
                .description = try allocator.dupe(u8, "Pull changes from remote repository. Optionally rebase instead of merge."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "remote": {
                    \\      "type": "string",
                    \\      "description": "Remote name (default: 'origin')"
                    \\    },
                    \\    "branch": {
                    \\      "type": "string",
                    \\      "description": "Branch name to pull from (default: tracking branch)"
                    \\    },
                    \\    "rebase": {
                    \\      "type": "boolean",
                    \\      "description": "Use rebase instead of merge (git pull --rebase)"
                    \\    }
                    \\  },
                    \\  "required": []
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "git_pull",
            .description = "Pull from remote repository",
            .risk_level = .high,
            .required_scopes = &.{ .network_access, .write_files },
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
        remote: ?[]const u8 = null,
        branch: ?[]const u8 = null,
        rebase: ?bool = null,
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

    // Build git pull command
    var argv = try std.ArrayList([]const u8).initCapacity(allocator, 5);
    defer argv.deinit(allocator);

    try argv.append(allocator, "git");
    try argv.append(allocator, "pull");

    if (args.rebase orelse false) {
        try argv.append(allocator, "--rebase");
    }

    if (args.remote) |remote| {
        try argv.append(allocator, remote);
        if (args.branch) |branch| {
            try argv.append(allocator, branch);
        }
    }

    // Execute git pull
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
                    try std.fmt.allocPrint(allocator, "git pull failed: {s}", .{result.stderr})
                else
                    try allocator.dupe(u8, "git pull failed (merge conflict? authentication?)");
                defer allocator.free(msg);
                return ToolResult.err(allocator, .io_error, msg, start_time);
            }
        },
        else => {
            const msg = try allocator.dupe(u8, "git pull terminated abnormally");
            defer allocator.free(msg);
            return ToolResult.err(allocator, .io_error, msg, start_time);
        },
    }

    // Format success message
    const output = if (result.stdout.len > 0) result.stdout else result.stderr;
    const formatted = if (output.len > 0)
        try std.fmt.allocPrint(allocator, "Pull successful:\n```\n{s}```", .{output})
    else
        try allocator.dupe(u8, "Pull completed successfully");
    defer allocator.free(formatted);

    return ToolResult.ok(allocator, formatted, start_time, null);
}
