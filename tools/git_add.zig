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
                .name = try allocator.dupe(u8, "git_add"),
                .description = try allocator.dupe(u8, "Stage files for commit. Can stage specific files/patterns or all changes."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "files": {
                    \\      "type": "string",
                    \\      "description": "File path or pattern to stage (e.g., 'file.txt', '*.js', 'src/')"
                    \\    },
                    \\    "all": {
                    \\      "type": "boolean",
                    \\      "description": "If true, stages all changes (git add .)"
                    \\    }
                    \\  },
                    \\  "required": []
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "git_add",
            .description = "Stage files for commit",
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
        files: ?[]const u8 = null,
        all: ?bool = null,
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

    // Validate: must provide either files or all
    const use_all = args.all orelse false;
    if (!use_all and args.files == null) {
        const msg = try allocator.dupe(u8, "Must provide either 'files' or set 'all' to true");
        defer allocator.free(msg);
        return ToolResult.err(allocator, .validation_failed, msg, start_time);
    }

    // Build git add command
    var argv = try std.ArrayList([]const u8).initCapacity(allocator, 3);
    defer argv.deinit(allocator);

    try argv.append(allocator, "git");
    try argv.append(allocator, "add");

    if (use_all) {
        try argv.append(allocator, ".");
    } else if (args.files) |files| {
        try argv.append(allocator, files);
    }

    // Execute git add
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
                    try std.fmt.allocPrint(allocator, "git add failed: {s}", .{result.stderr})
                else
                    try allocator.dupe(u8, "git add failed");
                defer allocator.free(msg);
                return ToolResult.err(allocator, .io_error, msg, start_time);
            }
        },
        else => {
            const msg = try allocator.dupe(u8, "git add terminated abnormally");
            defer allocator.free(msg);
            return ToolResult.err(allocator, .io_error, msg, start_time);
        },
    }

    // Format success message
    const formatted = if (use_all)
        try allocator.dupe(u8, "Successfully staged all changes")
    else if (args.files) |files|
        try std.fmt.allocPrint(allocator, "Successfully staged: {s}", .{files})
    else
        try allocator.dupe(u8, "Files staged successfully");
    defer allocator.free(formatted);

    return ToolResult.ok(allocator, formatted, start_time, null);
}
