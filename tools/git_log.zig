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
                .name = try allocator.dupe(u8, "git_log"),
                .description = try allocator.dupe(u8, "Shows git commit history with commit hashes and messages. Defaults to showing the last 10 commits."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "count": {
                    \\      "type": "integer",
                    \\      "description": "Number of commits to show (default: 10)"
                    \\    }
                    \\  },
                    \\  "required": []
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "git_log",
            .description = "View git commit history",
            .risk_level = .safe,
            .required_scopes = &.{.read_files},
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
        count: ?i32 = null,
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
    const count = args.count orelse 10;

    // Validate count is positive
    if (count <= 0) {
        const msg = try allocator.dupe(u8, "Count must be a positive integer");
        defer allocator.free(msg);
        return ToolResult.err(allocator, .validation_failed, msg, start_time);
    }

    // Build git log command with count limit
    const count_arg = try std.fmt.allocPrint(allocator, "-{d}", .{count});
    defer allocator.free(count_arg);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "log", count_arg, "--oneline", "--decorate" },
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
                    try std.fmt.allocPrint(allocator, "git log failed: {s}", .{result.stderr})
                else
                    try allocator.dupe(u8, "git log failed (not a git repository or no commits?)");
                defer allocator.free(msg);
                return ToolResult.err(allocator, .io_error, msg, start_time);
            }
        },
        else => {
            const msg = try allocator.dupe(u8, "git log terminated abnormally");
            defer allocator.free(msg);
            return ToolResult.err(allocator, .io_error, msg, start_time);
        },
    }

    // Format output
    const formatted = if (result.stdout.len == 0)
        try allocator.dupe(u8, "No commits found")
    else
        try std.fmt.allocPrint(allocator, "```\n{s}```", .{result.stdout});
    defer allocator.free(formatted);

    return ToolResult.ok(allocator, formatted, start_time, null);
}
