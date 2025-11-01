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
                .name = try allocator.dupe(u8, "git_push"),
                .description = try allocator.dupe(u8, "Push commits to remote repository. Use force=true with caution (uses --force-with-lease for safety)."),
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
                    \\      "description": "Branch name to push (default: current branch)"
                    \\    },
                    \\    "force": {
                    \\      "type": "boolean",
                    \\      "description": "Force push using --force-with-lease (safer than --force, prevents overwriting others' work)"
                    \\    },
                    \\    "set_upstream": {
                    \\      "type": "boolean",
                    \\      "description": "Set upstream tracking branch (adds -u flag)"
                    \\    }
                    \\  },
                    \\  "required": []
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "git_push",
            .description = "Push to remote repository",
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
        force: ?bool = null,
        set_upstream: ?bool = null,
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

    // Build git push command
    var argv = try std.ArrayList([]const u8).initCapacity(allocator, 6);
    defer argv.deinit(allocator);

    try argv.append(allocator, "git");
    try argv.append(allocator, "push");

    if (args.set_upstream orelse false) {
        try argv.append(allocator, "-u");
    }

    if (args.force orelse false) {
        try argv.append(allocator, "--force-with-lease");
    }

    const remote = args.remote orelse "origin";
    try argv.append(allocator, remote);

    if (args.branch) |branch| {
        try argv.append(allocator, branch);
    }

    // Execute git push
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
                    try std.fmt.allocPrint(allocator, "git push failed: {s}", .{result.stderr})
                else
                    try allocator.dupe(u8, "git push failed (authentication? network?)");
                defer allocator.free(msg);
                return ToolResult.err(allocator, .io_error, msg, start_time);
            }
        },
        else => {
            const msg = try allocator.dupe(u8, "git push terminated abnormally");
            defer allocator.free(msg);
            return ToolResult.err(allocator, .io_error, msg, start_time);
        },
    }

    // Format success message
    const output = if (result.stderr.len > 0) result.stderr else result.stdout;
    const formatted = if (output.len > 0)
        try std.fmt.allocPrint(allocator, "Push successful:\n```\n{s}```", .{output})
    else
        try std.fmt.allocPrint(allocator, "Pushed to {s} successfully", .{remote});
    defer allocator.free(formatted);

    return ToolResult.ok(allocator, formatted, start_time, null);
}
