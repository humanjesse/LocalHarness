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
                .name = try allocator.dupe(u8, "git_branch"),
                .description = try allocator.dupe(u8, "Manage git branches: list all branches, create new branch, or delete a branch."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "action": {
                    \\      "type": "string",
                    \\      "enum": ["list", "create", "delete"],
                    \\      "description": "Action to perform: list (show all branches), create (new branch), delete (remove branch)"
                    \\    },
                    \\    "branch_name": {
                    \\      "type": "string",
                    \\      "description": "Branch name (required for create/delete actions)"
                    \\    },
                    \\    "force": {
                    \\      "type": "boolean",
                    \\      "description": "Force delete branch even if not merged (uses -D instead of -d)"
                    \\    }
                    \\  },
                    \\  "required": ["action"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "git_branch",
            .description = "Manage git branches",
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
        branch_name: ?[]const u8 = null,
        force: ?bool = null,
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
    const is_list = std.mem.eql(u8, args.action, "list");
    const is_create = std.mem.eql(u8, args.action, "create");
    const is_delete = std.mem.eql(u8, args.action, "delete");

    if (!is_list and !is_create and !is_delete) {
        const msg = try std.fmt.allocPrint(allocator, "Invalid action: {s}. Must be 'list', 'create', or 'delete'", .{args.action});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .validation_failed, msg, start_time);
    }

    // Validate branch_name is provided for create/delete
    if ((is_create or is_delete) and args.branch_name == null) {
        const msg = try allocator.dupe(u8, "branch_name is required for create/delete actions");
        defer allocator.free(msg);
        return ToolResult.err(allocator, .validation_failed, msg, start_time);
    }

    // Build git branch command
    var argv = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    defer argv.deinit(allocator);

    try argv.append(allocator, "git");
    try argv.append(allocator, "branch");

    if (is_delete) {
        const force_delete = args.force orelse false;
        if (force_delete) {
            try argv.append(allocator, "-D");
        } else {
            try argv.append(allocator, "-d");
        }
        try argv.append(allocator, args.branch_name.?);
    } else if (is_create) {
        try argv.append(allocator, args.branch_name.?);
    }
    // For list, no additional args needed

    // Execute git branch
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
                    try std.fmt.allocPrint(allocator, "git branch failed: {s}", .{result.stderr})
                else
                    try allocator.dupe(u8, "git branch failed");
                defer allocator.free(msg);
                return ToolResult.err(allocator, .io_error, msg, start_time);
            }
        },
        else => {
            const msg = try allocator.dupe(u8, "git branch terminated abnormally");
            defer allocator.free(msg);
            return ToolResult.err(allocator, .io_error, msg, start_time);
        },
    }

    // Format output based on action
    const formatted = if (is_list and result.stdout.len > 0)
        try std.fmt.allocPrint(allocator, "Branches:\n```\n{s}```", .{result.stdout})
    else if (is_create)
        try std.fmt.allocPrint(allocator, "Created branch: {s}", .{args.branch_name.?})
    else if (is_delete)
        try std.fmt.allocPrint(allocator, "Deleted branch: {s}", .{args.branch_name.?})
    else
        try allocator.dupe(u8, "Branch operation completed");
    defer allocator.free(formatted);

    return ToolResult.ok(allocator, formatted, start_time, null);
}
