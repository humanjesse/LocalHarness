const std = @import("std");

const GitIgnorePattern = struct {
    pattern: []const u8,
    is_negation: bool,
    is_directory_only: bool,
};

const GitIgnore = struct {
    patterns: std.ArrayList(GitIgnorePattern),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !GitIgnore {
        return .{
            .patterns = try std.ArrayList(GitIgnorePattern).initCapacity(allocator, 0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GitIgnore) void {
        for (self.patterns.items) |pattern| {
            self.allocator.free(pattern.pattern);
        }
        self.patterns.deinit(self.allocator);
    }

    pub fn loadDefaultPatterns(self: *GitIgnore) !void {
        const default_patterns = [_][]const u8{
            // Common directories
            "node_modules/",
            ".git/",
            "dist/",
            "build/",
            "out/",
            "target/",
            "vendor/",
            ".venv/",
            "venv/",
            "env/",
            "__pycache__/",
            "bin/",
            "obj/",
            "coverage/",
            "logs/",
            ".cache/",
            "tmp/",
            "temp/",
            "public/",
            "assets/",
            "zig-cache/",
            "zig-out/",

            // Common file types
            "*.log",
            "*.lock",
            "package-lock.json",
            "yarn.lock",
            "pnpm-lock.yaml",
            "*.min.js",
            "*.min.css",
            "*.map",
            "*.exe",
            "*.dll",
            "*.so",
            "*.o",
            "*.obj",
            "*.class",
            "*.jar",
            "*.war",
            "*.pyc",
            "*.bin",
            "*.db",
            "*.sqlite",
            "*.sqlite3",
            "*.jpg",
            "*.png",
            "*.gif",
            "*.svg",
            "*.ico",
            "*.pdf",
            "*.doc",
            "*.docx",
            "*.zip",
            "*.tar",
            "*.tar.gz",
            "*.rar",
            "*.bak",
            "*.tmp",

            // Hidden files and config
            ".DS_Store",
            "Thumbs.db",
            ".env",
            ".env.local",
            ".env.*",
            ".aws/",
            ".ssh/",
            "*.swp",
            "*.swo",

            // Project-specific
            "test-results/",
            "*.egg-info/",
            "dist-packages/",
            "*.iml",
            "out/production/",
            "*.a",
            "*.lib",
            "go.sum",
            "Gemfile.lock",
            "composer.lock",

            // Sensitive files
            "*.key",
            "*.pem",
            "*.crt",
            "secrets.yaml",
            "credentials.json",
        };

        for (default_patterns) |pattern| {
            try self.parseLine(pattern);
        }
    }

    pub fn loadFromFile(self: *GitIgnore, dir: std.fs.Dir, filename: []const u8) !void {
        const file = dir.openFile(filename, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            try self.parseLine(line);
        }
    }

    fn parseLine(self: *GitIgnore, line: []const u8) !void {
        var trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') return;

        var is_negation = false;
        var is_directory_only = false;

        if (trimmed[0] == '!') {
            is_negation = true;
            trimmed = trimmed[1..];
        }

        if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '/') {
            is_directory_only = true;
            trimmed = trimmed[0 .. trimmed.len - 1];
        }

        const pattern_copy = try self.allocator.dupe(u8, trimmed);
        errdefer self.allocator.free(pattern_copy); // Free on error

        try self.patterns.append(self.allocator, .{
            .pattern = pattern_copy,
            .is_negation = is_negation,
            .is_directory_only = is_directory_only,
        });
    }

    pub fn shouldIgnore(self: *const GitIgnore, path: []const u8, is_directory: bool) bool {
        var ignored = false;

        for (self.patterns.items) |pattern| {
            if (pattern.is_directory_only and !is_directory) continue;

            if (matchPattern(pattern.pattern, path)) {
                ignored = !pattern.is_negation;
            }
        }

        return ignored;
    }
};

fn matchPattern(pattern: []const u8, path: []const u8) bool {
    if (std.mem.indexOf(u8, pattern, "**") != null) {
        const last_slash = std.mem.lastIndexOfScalar(u8, pattern, '/');
        if (last_slash) |idx| {
            const filename_pattern = pattern[idx + 1 ..];
            const path_filename = std.fs.path.basename(path);
            return simpleGlobMatch(filename_pattern, path_filename);
        }
    }

    if (std.mem.indexOf(u8, pattern, "*") != null) {
        return simpleGlobMatch(pattern, std.fs.path.basename(path));
    }

    return std.mem.eql(u8, pattern, path) or
        std.mem.eql(u8, pattern, std.fs.path.basename(path)) or
        std.mem.endsWith(u8, path, pattern);
}

fn simpleGlobMatch(pattern: []const u8, text: []const u8) bool {
    var pat_idx: usize = 0;
    var text_idx: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    while (text_idx < text.len) {
        if (pat_idx < pattern.len and (pattern[pat_idx] == text[text_idx] or pattern[pat_idx] == '?')) {
            pat_idx += 1;
            text_idx += 1;
        } else if (pat_idx < pattern.len and pattern[pat_idx] == '*') {
            star_idx = pat_idx;
            match_idx = text_idx;
            pat_idx += 1;
        } else if (star_idx) |star| {
            pat_idx = star + 1;
            match_idx += 1;
            text_idx = match_idx;
        } else {
            return false;
        }
    }

    while (pat_idx < pattern.len and pattern[pat_idx] == '*') {
        pat_idx += 1;
    }

    return pat_idx == pattern.len;
}

fn collectFiles(
    allocator: std.mem.Allocator,
    files: *std.ArrayList([]const u8),
    dir: std.fs.Dir,
    prefix: []const u8,
    gitignore: *const GitIgnore,
    depth: usize,
) !void {
    // Limit recursion depth to prevent stack overflow
    if (depth > 10) return;

    var iter = dir.iterate();

    var entries = try std.ArrayList(std.fs.Dir.Entry).initCapacity(allocator, 0);
    defer entries.deinit(allocator);

    // Limit total entries to prevent memory issues
    var entry_count: usize = 0;
    const max_entries: usize = 1000;

    while (iter.next() catch null) |entry| {
        entry_count += 1;
        if (entry_count > max_entries) break;

        entries.append(allocator, entry) catch break;
    }

    const items = entries.items;
    std.mem.sort(std.fs.Dir.Entry, items, {}, struct {
        fn lessThan(_: void, a: std.fs.Dir.Entry, b: std.fs.Dir.Entry) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);

    for (items) |entry| {
        // Validate entry name
        if (entry.name.len == 0 or entry.name.len > 255) continue;

        // Validate UTF-8
        if (!std.unicode.utf8ValidateSlice(entry.name)) continue;

        if (gitignore.shouldIgnore(entry.name, entry.kind == .directory)) {
            continue;
        }

        // Build full path
        const full_path = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name })
        else
            try allocator.dupe(u8, entry.name);

        // Skip files/directories with null bytes in their names
        if (std.mem.indexOfScalar(u8, entry.name, 0) != null) {
            allocator.free(full_path);
            continue;
        }

        if (entry.kind == .directory) {

            var subdir = dir.openDir(entry.name, .{ .iterate = true }) catch {
                allocator.free(full_path);
                continue;
            };
            defer subdir.close();

            try collectFiles(allocator, files, subdir, full_path, gitignore, depth + 1);
            allocator.free(full_path);
        } else if (entry.kind == .file) {
            try files.append(allocator, full_path);
        } else {
            allocator.free(full_path);
        }
    }
}

/// Generate a JSON array of file paths for LLM consumption
pub fn generateTree(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var cwd = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer cwd.close();

    var gitignore = try GitIgnore.init(allocator);
    defer gitignore.deinit();

    try gitignore.loadDefaultPatterns();
    try gitignore.loadFromFile(cwd, ".gitignore");

    // Collect all file paths
    var files = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer {
        for (files.items) |file| allocator.free(file);
        files.deinit(allocator);
    }

    try collectFiles(allocator, &files, cwd, "", &gitignore, 0);

    // Build JSON array
    var output = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer output.deinit(allocator);

    try output.append(allocator, '[');
    for (files.items, 0..) |file, i| {
        try output.append(allocator, '"');
        // Properly escape all special characters for JSON
        for (file) |c| {
            switch (c) {
                '"' => try output.appendSlice(allocator, "\\\""),
                '\\' => try output.appendSlice(allocator, "\\\\"),
                '\n' => try output.appendSlice(allocator, "\\n"),
                '\r' => try output.appendSlice(allocator, "\\r"),
                '\t' => try output.appendSlice(allocator, "\\t"),
                0x08 => try output.appendSlice(allocator, "\\b"), // backspace
                0x0C => try output.appendSlice(allocator, "\\f"), // form feed
                else => {
                    // Escape other control characters as \uXXXX
                    if (c < 0x20) {
                        var buf: [6]u8 = undefined;
                        const escaped = try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c});
                        try output.appendSlice(allocator, escaped);
                    } else {
                        try output.append(allocator, c);
                    }
                },
            }
        }
        try output.append(allocator, '"');
        if (i < files.items.len - 1) {
            try output.append(allocator, ',');
        }
    }
    try output.append(allocator, ']');

    return try output.toOwnedSlice(allocator);
}
