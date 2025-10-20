// Grep Search Tool - Recursively search files with .gitignore awareness
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
                .name = try allocator.dupe(u8, "grep_search"),
                .description = try allocator.dupe(u8, "Search files for text pattern. Simple patterns do substring search (e.g., 'zigmark' finds '**ZigMark**'). Use * for wildcards (e.g., 'fn*init'). Always case-insensitive, respects .gitignore, and skips binary files."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "pattern": {
                    \\      "type": "string",
                    \\      "description": "Text to search for (supports * wildcards, e.g., 'fn*init')"
                    \\    },
                    \\    "file_filter": {
                    \\      "type": "string",
                    \\      "description": "Optional: limit to files matching glob (e.g., '*.zig', '**/*.md')"
                    \\    }
                    \\  },
                    \\  "required": ["pattern"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "grep_search",
            .description = "Search files in project",
            .risk_level = .safe, // Auto-approve like get_file_tree
            .required_scopes = &.{.read_files},
            .validator = validate,
        },
        .execute = execute,
    };
}

const SearchResult = struct {
    file_path: []const u8,
    line_number: usize,
    line_content: []const u8,
};

const SearchContext = struct {
    allocator: std.mem.Allocator,
    pattern: []const u8,
    smart_case: bool,
    max_results: usize,
    file_filter: ?[]const u8,
    gitignore_patterns: std.ArrayListUnmanaged([]const u8),
    results: std.ArrayListUnmanaged(SearchResult),
    files_searched: usize,
    files_skipped: usize,
    current_path: std.ArrayListUnmanaged(u8),
};

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    _ = context;
    const start_time = std.time.milliTimestamp();

    // Parse arguments
    const Args = struct {
        pattern: []const u8,
        file_filter: ?[]const u8 = null,
    };

    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{}) catch {
        return ToolResult.err(allocator, .parse_error, "Invalid JSON arguments", start_time);
    };
    defer parsed.deinit();

    const args = parsed.value;

    // Validate pattern
    if (args.pattern.len == 0) {
        return ToolResult.err(allocator, .validation_failed, "Pattern cannot be empty", start_time);
    }

    // Always use case-insensitive search
    // This ensures searches work regardless of the case used in the pattern
    // e.g., searching for "potato", "Potato", or "POTATO" will all find any case variation
    const smart_case = true;

    // Initialize search context
    var search_ctx = SearchContext{
        .allocator = allocator,
        .pattern = args.pattern,
        .smart_case = smart_case,
        .max_results = 100, // Internal default
        .file_filter = args.file_filter,
        .gitignore_patterns = .{},
        .results = .{},
        .files_searched = 0,
        .files_skipped = 0,
        .current_path = .{},
    };
    defer {
        for (search_ctx.gitignore_patterns.items) |pattern| {
            allocator.free(pattern);
        }
        search_ctx.gitignore_patterns.deinit(allocator);
        for (search_ctx.results.items) |result| {
            allocator.free(result.file_path);
            allocator.free(result.line_content);
        }
        search_ctx.results.deinit(allocator);
        search_ctx.current_path.deinit(allocator);
    }

    // Always load .gitignore patterns
    loadGitignore(&search_ctx) catch {
        // Continue without gitignore if it fails to load
    };

    // Start recursive search from current directory
    const cwd = std.fs.cwd();
    searchDirectory(&search_ctx, cwd, ".") catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Search failed: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .io_error, msg, start_time);
    };

    // Format results
    const formatted = try formatResults(&search_ctx, args);
    return ToolResult.ok(allocator, formatted, start_time);
}

fn loadGitignore(ctx: *SearchContext) !void {
    const file = std.fs.cwd().openFile(".gitignore", .{}) catch {
        return; // No .gitignore file, continue without it
    };
    defer file.close();

    const content = try file.readToEndAlloc(ctx.allocator, 1024 * 1024); // 1MB max
    defer ctx.allocator.free(content);

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Skip empty lines and comments
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Store pattern
        const pattern = try ctx.allocator.dupe(u8, trimmed);
        try ctx.gitignore_patterns.append(ctx.allocator, pattern);
    }
}

fn searchDirectory(ctx: *SearchContext, dir: std.fs.Dir, rel_path: []const u8) !void {
    // Check if we've hit max results
    if (ctx.results.items.len >= ctx.max_results) return;

    var iter_dir = dir.openDir(rel_path, .{ .iterate = true }) catch {
        // Skip directories we can't open
        return;
    };
    defer iter_dir.close();

    var iter = iter_dir.iterate();
    while (try iter.next()) |entry| {
        // Check max results again
        if (ctx.results.items.len >= ctx.max_results) return;

        // Build full path
        const entry_path = if (std.mem.eql(u8, rel_path, "."))
            try ctx.allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ rel_path, entry.name });
        defer ctx.allocator.free(entry_path);

        // Check if ignored
        if (isIgnored(ctx, entry_path)) {
            ctx.files_skipped += 1;
            continue;
        }

        switch (entry.kind) {
            .directory => {
                // Skip hidden directories
                if (entry.name[0] == '.') {
                    ctx.files_skipped += 1;
                    continue;
                }

                // Recurse into directory
                try searchDirectory(ctx, dir, entry_path);
            },
            .file => {
                // Check file filter
                if (ctx.file_filter) |filter| {
                    if (!matchesGlob(entry_path, filter)) {
                        ctx.files_skipped += 1;
                        continue;
                    }
                }

                // Search the file
                try searchFile(ctx, dir, entry_path);
            },
            else => {}, // Skip other types (symlinks, etc.)
        }
    }
}

fn searchFile(ctx: *SearchContext, dir: std.fs.Dir, path: []const u8) !void {
    const file = dir.openFile(path, .{}) catch {
        ctx.files_skipped += 1;
        return; // Skip files we can't open
    };
    defer file.close();

    // Read file content
    const content = file.readToEndAlloc(ctx.allocator, 10 * 1024 * 1024) catch {
        ctx.files_skipped += 1;
        return; // Skip files we can't read or that are too large
    };
    defer ctx.allocator.free(content);

    // Check for binary content
    if (isBinary(content)) {
        ctx.files_skipped += 1;
        return;
    }

    ctx.files_searched += 1;

    // Search line by line
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var line_num: usize = 1;
    while (line_iter.next()) |line| : (line_num += 1) {
        if (ctx.results.items.len >= ctx.max_results) return;

        if (matchesPattern(ctx, line)) {
            // Store result
            const result = SearchResult{
                .file_path = try ctx.allocator.dupe(u8, path),
                .line_number = line_num,
                .line_content = try ctx.allocator.dupe(u8, line),
            };
            try ctx.results.append(ctx.allocator, result);
        }
    }
}

fn matchesPattern(ctx: *SearchContext, line: []const u8) bool {
    // Detect if pattern contains wildcards
    const has_wildcard = std.mem.indexOf(u8, ctx.pattern, "*") != null;

    if (has_wildcard) {
        // Pattern has * wildcards - use wildcard matching
        return matchesWildcard(line, ctx.pattern, ctx.smart_case);
    } else {
        // Simple pattern - do substring search
        if (ctx.smart_case) {
            return indexOfIgnoreCase(line, ctx.pattern) != null;
        } else {
            return std.mem.indexOf(u8, line, ctx.pattern) != null;
        }
    }
}

fn matchesWildcard(text: []const u8, pattern: []const u8, case_insensitive: bool) bool {
    // Simple wildcard matching with * support
    var text_idx: usize = 0;
    var pat_idx: usize = 0;

    while (pat_idx < pattern.len and text_idx < text.len) {
        if (pattern[pat_idx] == '*') {
            // Try matching rest of pattern at each position
            pat_idx += 1;
            if (pat_idx == pattern.len) return true; // Trailing * matches everything

            while (text_idx < text.len) {
                if (matchesWildcard(text[text_idx..], pattern[pat_idx..], case_insensitive)) {
                    return true;
                }
                text_idx += 1;
            }
            return false;
        } else {
            const pat_char = if (case_insensitive) std.ascii.toLower(pattern[pat_idx]) else pattern[pat_idx];
            const text_char = if (case_insensitive) std.ascii.toLower(text[text_idx]) else text[text_idx];

            if (pat_char != text_char) return false;

            pat_idx += 1;
            text_idx += 1;
        }
    }

    // Handle remaining pattern
    while (pat_idx < pattern.len and pattern[pat_idx] == '*') {
        pat_idx += 1;
    }

    return pat_idx == pattern.len and text_idx == text.len;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(c) != std.ascii.toLower(haystack[i + j])) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return null;
}

fn isIgnored(ctx: *SearchContext, path: []const u8) bool {
    for (ctx.gitignore_patterns.items) |pattern| {
        if (matchesGitignorePattern(path, pattern)) {
            return true;
        }
    }
    return false;
}

fn matchesGitignorePattern(path: []const u8, pattern: []const u8) bool {
    // Handle directory patterns (ending with /)
    if (std.mem.endsWith(u8, pattern, "/")) {
        const dir_pattern = pattern[0 .. pattern.len - 1];
        return std.mem.startsWith(u8, path, dir_pattern);
    }

    // Handle recursive directory patterns (**/foo)
    if (std.mem.startsWith(u8, pattern, "**/")) {
        const suffix = pattern[3..];
        return std.mem.endsWith(u8, path, suffix) or std.mem.indexOf(u8, path, suffix) != null;
    }

    // Handle extension patterns (*.ext)
    if (std.mem.startsWith(u8, pattern, "*.")) {
        return std.mem.endsWith(u8, path, pattern[1..]);
    }

    // Exact filename match (anywhere in path)
    if (std.mem.indexOf(u8, path, pattern) != null) {
        return true;
    }

    return false;
}

fn matchesGlob(path: []const u8, glob: []const u8) bool {
    // Simple glob matching for file filtering

    // Match all files
    if (std.mem.eql(u8, glob, "*")) return true;

    // Extension matching (*.ext)
    if (std.mem.startsWith(u8, glob, "*.")) {
        return std.mem.endsWith(u8, path, glob[1..]);
    }

    // Recursive extension matching (**/*.ext)
    if (std.mem.startsWith(u8, glob, "**/*.")) {
        const ext = glob[4..];
        return std.mem.endsWith(u8, path, ext);
    }

    // Directory prefix matching (dir/**)
    if (std.mem.endsWith(u8, glob, "/**")) {
        const prefix = glob[0 .. glob.len - 3];
        return std.mem.startsWith(u8, path, prefix);
    }

    // Exact match
    return std.mem.eql(u8, path, glob);
}

fn isBinary(content: []const u8) bool {
    // Check first 512 bytes for null bytes
    const check_len = @min(content.len, 512);
    for (content[0..check_len]) |byte| {
        if (byte == 0) return true;
    }
    return false;
}

fn formatResults(ctx: *SearchContext, args: anytype) ![]const u8 {
    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(ctx.allocator);
    const writer = output.writer(ctx.allocator);

    // Wrap in code fence
    try writer.writeAll("```\n");

    // Header
    try writer.print("Search: \"{s}\"", .{args.pattern});
    if (ctx.file_filter) |filter| {
        try writer.print(" in {s} files", .{filter});
    }
    if (ctx.smart_case) {
        try writer.writeAll(" (case-insensitive)");
    } else {
        try writer.writeAll(" (case-sensitive)");
    }
    try writer.writeAll("\n\n");

    if (ctx.results.items.len == 0) {
        try writer.writeAll("No matches found.\n");
    } else {
        // Group results by file
        var current_file: ?[]const u8 = null;
        for (ctx.results.items) |result| {
            if (current_file == null or !std.mem.eql(u8, current_file.?, result.file_path)) {
                if (current_file != null) {
                    try writer.writeAll("\n");
                }
                try writer.print("File: {s}\n", .{result.file_path});
                current_file = result.file_path;
            }

            try writer.print("  {d}: {s}\n", .{ result.line_number, result.line_content });
        }
    }

    // Summary
    try writer.writeAll("\n");
    try writer.print("Summary: {d} match", .{ctx.results.items.len});
    if (ctx.results.items.len != 1) try writer.writeAll("es");

    // Count unique files
    var file_count: usize = 0;
    var last_file: ?[]const u8 = null;
    for (ctx.results.items) |result| {
        if (last_file == null or !std.mem.eql(u8, last_file.?, result.file_path)) {
            file_count += 1;
            last_file = result.file_path;
        }
    }

    try writer.print(" in {d} file", .{file_count});
    if (file_count != 1) try writer.writeAll("s");

    try writer.print(" (searched {d} files, skipped {d} ignored)", .{ ctx.files_searched, ctx.files_skipped });

    if (ctx.results.items.len >= ctx.max_results) {
        try writer.print("\nNote: Result limit ({d}) reached. There may be more matches.", .{ctx.max_results});
    }

    try writer.writeAll("\n```");

    return try output.toOwnedSlice(ctx.allocator);
}

fn validate(allocator: std.mem.Allocator, arguments: []const u8) bool {
    const Args = struct {
        pattern: []const u8,
        file_filter: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{}) catch return false;
    defer parsed.deinit();

    // Block empty pattern
    if (parsed.value.pattern.len == 0) return false;

    // Validate file filter if provided
    if (parsed.value.file_filter) |filter| {
        // Block absolute paths
        if (std.mem.startsWith(u8, filter, "/")) return false;
        // Block directory traversal
        if (std.mem.indexOf(u8, filter, "..") != null) return false;
    }

    return true;
}
