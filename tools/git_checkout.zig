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
                .name = try allocator.dupe(u8, "git_checkout"),
                .description = try allocator.dupe(u8, "Switch to a branch (optionally creating it) or restore a file from HEAD."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "branch": {
                    \\      "type": "string",
                    \\      "description": "Branch name to switch to"
                    \\    },
                    \\    "create": {
                    \\      "type": "boolean",
                    \\      "description": "If true, creates the branch before switching (git checkout -b)"
                    \\    },
                    \\    "file_path": {
                    \\      "type": "string",
                    \\      "description": "File path to restore from HEAD (discards local changes to that file)"
                    \\    }
                    \\  },
                    \\  "required": []
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "git_checkout",
            .description = "Switch branches or restore files",
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
        branch: ?[]const u8 = null,
        create: ?bool = null,
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

    // Validate: must provide either branch or file_path, but not both
    const has_branch = args.branch != null;
    const has_file = args.file_path != null;

    if (!has_branch and !has_file) {
        const msg = try allocator.dupe(u8, "Must provide either 'branch' or 'file_path'");
        defer allocator.free(msg);
        return ToolResult.err(allocator, .validation_failed, msg, start_time);
    }

    if (has_branch and has_file) {
        const msg = try allocator.dupe(u8, "Cannot provide both 'branch' and 'file_path' - use one or the other");
        defer allocator.free(msg);
        return ToolResult.err(allocator, .validation_failed, msg, start_time);
    }

    // Build git checkout command
    var argv = try std.ArrayList([]const u8).initCapacity(allocator, 5);
    defer argv.deinit(allocator);

    try argv.append(allocator, "git");
    try argv.append(allocator, "checkout");

    if (has_branch) {
        const should_create = args.create orelse false;
        if (should_create) {
            try argv.append(allocator, "-b");
        }
        try argv.append(allocator, args.branch.?);
    } else if (has_file) {
        try argv.append(allocator, "--");
        try argv.append(allocator, args.file_path.?);
    }

    // Execute git checkout
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
                    try std.fmt.allocPrint(allocator, "git checkout failed: {s}", .{result.stderr})
                else
                    try allocator.dupe(u8, "git checkout failed");
                defer allocator.free(msg);
                return ToolResult.err(allocator, .io_error, msg, start_time);
            }
        },
        else => {
            const msg = try allocator.dupe(u8, "git checkout terminated abnormally");
            defer allocator.free(msg);
            return ToolResult.err(allocator, .io_error, msg, start_time);
        },
    }

    // Format success message
    const formatted = if (has_branch and args.create orelse false)
        try std.fmt.allocPrint(allocator, "Created and switched to branch: {s}", .{args.branch.?})
    else if (has_branch)
        try std.fmt.allocPrint(allocator, "Switched to branch: {s}", .{args.branch.?})
    else if (has_file)
        try std.fmt.allocPrint(allocator, "Restored file from HEAD: {s}", .{args.file_path.?})
    else
        try allocator.dupe(u8, "Checkout completed successfully");
    defer allocator.free(formatted);

    return ToolResult.ok(allocator, formatted, start_time, null);
}
