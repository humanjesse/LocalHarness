// Agent Writer - Saves agent definitions as markdown files in Claude Code format
const std = @import("std");

/// Write agent definition to markdown file in ~/.config/localharness/agents/
pub fn writeAgent(
    allocator: std.mem.Allocator,
    name: []const u8,
    description: []const u8,
    system_prompt: []const u8,
    tools: []const []const u8,
) !void {
    // Get agent directory path
    const agent_dir = try getAgentDirectory(allocator);
    defer allocator.free(agent_dir);

    // Create directory if it doesn't exist
    std.fs.cwd().makePath(agent_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Build file path
    const file_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}.md",
        .{ agent_dir, name },
    );
    defer allocator.free(file_path);

    // Create file
    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();

    // Build file content
    var content = std.ArrayListUnmanaged(u8){};
    defer content.deinit(allocator);

    // Write frontmatter (YAML-like format, Claude Code compatible)
    try content.appendSlice(allocator, "---\n");

    const name_line = try std.fmt.allocPrint(allocator, "name: {s}\n", .{name});
    defer allocator.free(name_line);
    try content.appendSlice(allocator, name_line);

    const desc_line = try std.fmt.allocPrint(allocator, "description: {s}\n", .{description});
    defer allocator.free(desc_line);
    try content.appendSlice(allocator, desc_line);

    // Write tools list (comma-separated)
    if (tools.len > 0) {
        try content.appendSlice(allocator, "tools: ");
        for (tools, 0..) |tool, idx| {
            if (idx > 0) try content.appendSlice(allocator, ", ");
            try content.appendSlice(allocator, tool);
        }
        try content.appendSlice(allocator, "\n");
    }

    try content.appendSlice(allocator, "---\n\n");

    // Write system prompt
    try content.appendSlice(allocator, system_prompt);
    try content.appendSlice(allocator, "\n");

    // Write to file
    try file.writeAll(content.items);
}

/// Get agent directory path (~/.config/localharness/agents/)
pub fn getAgentDirectory(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    return try std.fs.path.join(allocator, &.{
        home,
        ".config",
        "localharness",
        "agents",
    });
}

/// Parse agent from markdown file (for loading)
pub const AgentConfig = struct {
    name: []const u8,
    description: []const u8,
    tools: []const []const u8,
    system_prompt: []const u8,

    pub fn deinit(self: *AgentConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        for (self.tools) |tool| {
            allocator.free(tool);
        }
        allocator.free(self.tools);
        allocator.free(self.system_prompt);
    }
};

/// Parse agent from markdown file
pub fn parseAgentFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
) !AgentConfig {
    // Read file
    const content = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024);
    defer allocator.free(content);

    // Parse frontmatter and body
    return try parseMarkdown(allocator, content);
}

/// Parse markdown content
fn parseMarkdown(allocator: std.mem.Allocator, content: []const u8) !AgentConfig {
    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var tools = std.ArrayListUnmanaged([]const u8){};
    var system_prompt: ?[]const u8 = null;

    // Find frontmatter boundaries
    const first_delim = std.mem.indexOf(u8, content, "---") orelse return error.InvalidFormat;
    const second_delim = std.mem.indexOf(u8, content[first_delim + 3 ..], "---") orelse return error.InvalidFormat;

    // Extract frontmatter
    const frontmatter = content[first_delim + 3 .. first_delim + 3 + second_delim];

    // Extract system prompt (everything after second ---)
    const prompt_start = first_delim + 3 + second_delim + 3;
    if (prompt_start < content.len) {
        const prompt_text = std.mem.trim(u8, content[prompt_start..], " \n\r\t");
        system_prompt = try allocator.dupe(u8, prompt_text);
    }

    // Parse frontmatter lines
    var line_iter = std.mem.splitScalar(u8, frontmatter, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;

        // Parse "key: value"
        if (std.mem.indexOf(u8, trimmed, ": ")) |colon_pos| {
            const key = trimmed[0..colon_pos];
            const value = std.mem.trim(u8, trimmed[colon_pos + 1 ..], " ");

            if (std.mem.eql(u8, key, "name")) {
                name = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "description")) {
                description = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "tools")) {
                // Parse comma-separated tool list
                var tool_iter = std.mem.splitSequence(u8, value, ", ");
                while (tool_iter.next()) |tool_name| {
                    const tool_trimmed = std.mem.trim(u8, tool_name, " ");
                    if (tool_trimmed.len > 0) {
                        try tools.append(allocator, try allocator.dupe(u8, tool_trimmed));
                    }
                }
            }
        }
    }

    // Validate required fields
    if (name == null) return error.MissingName;
    if (description == null) return error.MissingDescription;
    if (system_prompt == null) return error.MissingSystemPrompt;

    return AgentConfig{
        .name = name.?,
        .description = description.?,
        .tools = try tools.toOwnedSlice(allocator),
        .system_prompt = system_prompt.?,
    };
}

/// List all agent files in ~/.config/localharness/agents/
pub fn listAgentFiles(allocator: std.mem.Allocator) ![]const []const u8 {
    const agent_dir = try getAgentDirectory(allocator);
    defer allocator.free(agent_dir);

    var files = std.ArrayListUnmanaged([]const u8){};
    errdefer {
        for (files.items) |file| {
            allocator.free(file);
        }
        files.deinit(allocator);
    }

    // Open directory
    var dir = std.fs.cwd().openDir(agent_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            // Directory doesn't exist yet - return empty list
            return files.toOwnedSlice(allocator);
        }
        return err;
    };
    defer dir.close();

    // Iterate through files
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;

        // Build full path
        const full_path = try std.fs.path.join(allocator, &.{ agent_dir, entry.name });
        try files.append(allocator, full_path);
    }

    return files.toOwnedSlice(allocator);
}
