// List Directory Tool - Single directory listing with metadata and sorting
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
                .name = try allocator.dupe(u8, "ls"),
                .description = try allocator.dupe(u8, "List directory contents with metadata. Supports sorting and hidden file filtering."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "path": {
                    \\      "type": "string",
                    \\      "description": "Directory path to list (default: current directory '.')"
                    \\    },
                    \\    "show_hidden": {
                    \\      "type": "boolean",
                    \\      "description": "Include hidden files/directories starting with '.' (default: false)"
                    \\    },
                    \\    "sort_by": {
                    \\      "type": "string",
                    \\      "enum": ["name", "size", "modified"],
                    \\      "description": "Sort entries by: 'name' (default), 'size', or 'modified' time"
                    \\    },
                    \\    "reverse": {
                    \\      "type": "boolean",
                    \\      "description": "Reverse the sort order (default: false)"
                    \\    },
                    \\    "max_entries": {
                    \\      "type": "integer",
                    \\      "description": "Maximum entries to return (default: 500, max: 1000)"
                    \\    }
                    \\  },
                    \\  "required": []
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "ls",
            .description = "List directory contents with metadata",
            .risk_level = .low,
            .required_scopes = &.{.read_files},
            .validator = validate,
        },
        .execute = execute,
    };
}

const DirEntry = struct {
    name: []const u8,
    kind: std.fs.File.Kind,
    size: u64,
    mtime: i128, // nanoseconds since epoch
};

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    _ = context;
    const start_time = std.time.milliTimestamp();

    // Parse arguments with defaults
    const Args = struct {
        path: ?[]const u8 = null,
        show_hidden: ?bool = null,
        sort_by: ?[]const u8 = null,
        reverse: ?bool = null,
        max_entries: ?usize = null,
    };

    // Handle empty arguments
    const args_to_parse = if (arguments.len == 0 or std.mem.eql(u8, arguments, "{}"))
        "{}"
    else
        arguments;

    const parsed = std.json.parseFromSlice(Args, allocator, args_to_parse, .{}) catch {
        return ToolResult.err(allocator, .parse_error, "Invalid JSON arguments", start_time);
    };
    defer parsed.deinit();

    const args = parsed.value;

    // Apply defaults
    const path = args.path orelse ".";
    const show_hidden = args.show_hidden orelse false;
    const sort_by = args.sort_by orelse "name";
    const reverse = args.reverse orelse false;
    const max_entries = if (args.max_entries) |m| @min(m, 1000) else 500;

    // Validate sort_by
    if (!std.mem.eql(u8, sort_by, "name") and
        !std.mem.eql(u8, sort_by, "size") and
        !std.mem.eql(u8, sort_by, "modified"))
    {
        return ToolResult.err(allocator, .validation_failed, "sort_by must be 'name', 'size', or 'modified'", start_time);
    }

    // Open directory
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch {
        const msg = try std.fmt.allocPrint(allocator, "Directory not found or cannot be opened: {s}", .{path});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .not_found, msg, start_time);
    };
    defer dir.close();

    // Collect entries
    var entries = std.ArrayListUnmanaged(DirEntry){};
    defer {
        for (entries.items) |entry| {
            allocator.free(entry.name);
        }
        entries.deinit(allocator);
    }

    var iter = dir.iterate();
    var total_size: u64 = 0;
    var file_count: usize = 0;
    var dir_count: usize = 0;

    while (try iter.next()) |entry| {
        // Skip hidden files if requested
        if (!show_hidden and entry.name.len > 0 and entry.name[0] == '.') {
            continue;
        }

        // Get file stats
        const stat = dir.statFile(entry.name) catch |err| {
            // Skip files we can't stat
            if (std.posix.getenv("DEBUG_TOOLS")) |_| {
                std.debug.print("[ls] Failed to stat {s}: {}\n", .{ entry.name, err });
            }
            continue;
        };

        const size = stat.size;
        const mtime = stat.mtime;

        // Track totals
        if (entry.kind == .file) {
            total_size += size;
            file_count += 1;
        } else if (entry.kind == .directory) {
            dir_count += 1;
        }

        // Store entry
        try entries.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .kind = entry.kind,
            .size = size,
            .mtime = mtime,
        });

        // Check limit
        if (entries.items.len >= max_entries) {
            break;
        }
    }

    // Sort entries
    const SortContext = struct {
        sort_by_field: []const u8,
        reverse_order: bool,

        pub fn lessThan(ctx: @This(), a: DirEntry, b: DirEntry) bool {
            const result = if (std.mem.eql(u8, ctx.sort_by_field, "size"))
                a.size < b.size
            else if (std.mem.eql(u8, ctx.sort_by_field, "modified"))
                a.mtime < b.mtime
            else
                std.mem.lessThan(u8, a.name, b.name);

            return if (ctx.reverse_order) !result else result;
        }
    };

    const sort_context = SortContext{
        .sort_by_field = sort_by,
        .reverse_order = reverse,
    };

    std.mem.sort(DirEntry, entries.items, sort_context, SortContext.lessThan);

    // Format output
    const formatted = try formatOutput(allocator, path, entries.items, total_size, file_count, dir_count, sort_by, reverse, max_entries);
    defer allocator.free(formatted);
    return ToolResult.ok(allocator, formatted, start_time, null);
}

fn formatOutput(
    allocator: std.mem.Allocator,
    path: []const u8,
    entries: []const DirEntry,
    total_size: u64,
    file_count: usize,
    dir_count: usize,
    sort_by: []const u8,
    reverse: bool,
    max_entries: usize,
) ![]const u8 {
    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    // Wrap in code fence
    try writer.writeAll("```\n");

    // Header
    try writer.print("Directory: {s}\n", .{path});
    try writer.print("Sorted by: {s} ({s})\n", .{ sort_by, if (reverse) "descending" else "ascending" });
    try writer.print("Total: {d} entries ({d} files, {d} directories)\n", .{ entries.len, file_count, dir_count });
    if (file_count > 0) {
        const total_size_str = try formatSize(allocator, total_size);
        defer allocator.free(total_size_str);
        try writer.print("Total size: {s}\n", .{total_size_str});
    }
    try writer.writeAll("\n");

    // Table header
    try writer.writeAll("Type  Size        Modified              Name\n");
    try writer.writeAll("----  ----------  -------------------   --------------------\n");

    // Entries
    for (entries) |entry| {
        // Type
        const type_str = switch (entry.kind) {
            .file => "FILE",
            .directory => "DIR ",
            .sym_link => "LINK",
            else => "?   ",
        };
        try writer.print("{s}  ", .{type_str});

        // Size
        if (entry.kind == .file) {
            const size_str = try formatSize(allocator, entry.size);
            defer allocator.free(size_str);
            try writer.print("{s: <10}  ", .{size_str});
        } else {
            try writer.writeAll("-           ");
        }

        // Modified time
        const timestamp_ns: i128 = entry.mtime;
        const timestamp: i64 = @intCast(@divFloor(timestamp_ns, std.time.ns_per_s));
        const datetime = formatTimestamp(timestamp);
        try writer.print("{s}   ", .{datetime});

        // Name (add trailing / for directories)
        if (entry.kind == .directory) {
            try writer.print("{s}/\n", .{entry.name});
        } else {
            try writer.print("{s}\n", .{entry.name});
        }
    }

    // Footer
    if (entries.len >= max_entries) {
        try writer.print("\n⚠️  Result limit ({d}) reached! Some entries may be omitted.\n", .{max_entries});
    }

    try writer.writeAll("```");

    return try output.toOwnedSlice(allocator);
}

fn formatSize(allocator: std.mem.Allocator, size: u64) ![]const u8 {
    if (size < 1024) {
        return try std.fmt.allocPrint(allocator, "{d} B", .{size});
    } else if (size < 1024 * 1024) {
        const kb = @as(f64, @floatFromInt(size)) / 1024.0;
        return try std.fmt.allocPrint(allocator, "{d:.1} KB", .{kb});
    } else if (size < 1024 * 1024 * 1024) {
        const mb = @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0);
        return try std.fmt.allocPrint(allocator, "{d:.1} MB", .{mb});
    } else {
        const gb = @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0 * 1024.0);
        return try std.fmt.allocPrint(allocator, "{d:.1} GB", .{gb});
    }
}

fn formatTimestamp(timestamp: i64) [19]u8 {
    // Convert Unix timestamp to datetime string
    // Format: YYYY-MM-DD HH:MM:SS
    const epoch_seconds = @as(u64, @intCast(timestamp));
    const seconds_per_day = 86400;
    const days_since_epoch = epoch_seconds / seconds_per_day;
    const seconds_today = epoch_seconds % seconds_per_day;

    // Calculate date (simplified - assumes Unix epoch 1970-01-01)
    const days_per_year = 365;
    const year = 1970 + days_since_epoch / days_per_year;
    const day_of_year = days_since_epoch % days_per_year;
    const month = @min(12, 1 + day_of_year / 30);
    const day = @min(31, 1 + day_of_year % 30);

    // Calculate time
    const hour = seconds_today / 3600;
    const minute = (seconds_today % 3600) / 60;
    const second = seconds_today % 60;

    var result: [19]u8 = undefined;
    _ = std.fmt.bufPrint(&result, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year, month, day, hour, minute, second,
    }) catch unreachable;

    return result;
}

fn validate(allocator: std.mem.Allocator, arguments: []const u8) bool {
    // Empty arguments are valid (all defaults)
    if (arguments.len == 0 or std.mem.eql(u8, arguments, "{}")) {
        return true;
    }

    const Args = struct {
        path: ?[]const u8 = null,
        show_hidden: ?bool = null,
        sort_by: ?[]const u8 = null,
        reverse: ?bool = null,
        max_entries: ?usize = null,
    };

    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{}) catch return false;
    defer parsed.deinit();

    const args = parsed.value;

    // Validate path if provided
    if (args.path) |p| {
        // Block absolute paths
        if (std.mem.startsWith(u8, p, "/")) return false;
        // Block directory traversal
        if (std.mem.indexOf(u8, p, "..") != null) return false;
    }

    // Validate sort_by if provided
    if (args.sort_by) |sb| {
        if (!std.mem.eql(u8, sb, "name") and
            !std.mem.eql(u8, sb, "size") and
            !std.mem.eql(u8, sb, "modified"))
        {
            return false;
        }
    }

    // Validate max_entries if provided
    if (args.max_entries) |m| {
        if (m == 0 or m > 1000) return false;
    }

    return true;
}
