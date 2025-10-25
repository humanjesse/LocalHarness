// Read File Curated Tool - Reads file and curates important lines using agent
const std = @import("std");
const ollama = @import("../ollama.zig");
const permission = @import("../permission.zig");
const context_module = @import("../context.zig");
const tools_module = @import("../tools.zig");
const agents_module = @import("../agents.zig");
const file_curator = @import("../agents/file_curator.zig");

const AppContext = context_module.AppContext;
const ToolDefinition = tools_module.ToolDefinition;
const ToolResult = tools_module.ToolResult;
const AgentContext = agents_module.AgentContext;

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "read_file_curated"),
                .description = try allocator.dupe(u8, "Reads a file and returns a curated view showing only the most important lines. Use this when you want to understand a file's structure without seeing all the details. The full file is still indexed for search. For complete file contents, use read_file instead."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "path": {
                    \\      "type": "string",
                    \\      "description": "The relative path to the file from the project root"
                    \\    }
                    \\  },
                    \\  "required": ["path"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "read_file_curated",
            .description = "Read and curate file contents",
            .risk_level = .medium,
            .required_scopes = &.{.read_files},
            .validator = validate,
        },
        .execute = execute,
    };
}

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    const start_time = std.time.milliTimestamp();

    if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
        std.debug.print("[DEBUG] read_file_curated execute started\n", .{});
    }

    // Handle empty arguments
    if (arguments.len == 0 or std.mem.eql(u8, arguments, "{}")) {
        return ToolResult.err(allocator, .validation_failed, "read_file_curated requires a 'path' argument", start_time);
    }

    const Args = struct { path: []const u8 };
    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{}) catch {
        return ToolResult.err(allocator, .parse_error, "Invalid JSON arguments", start_time);
    };
    defer parsed.deinit();

    if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
        std.debug.print("[DEBUG] Opening file for curation: {s}\n", .{parsed.value.path});
    }

    // Read the file
    const file = std.fs.cwd().openFile(parsed.value.path, .{}) catch {
        const msg = try std.fmt.allocPrint(allocator, "File not found: {s}", .{parsed.value.path});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .not_found, msg, start_time);
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "IO error reading file: {}", .{err});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .io_error, msg, start_time);
    };
    defer allocator.free(content);

    if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
        std.debug.print("[DEBUG] File read ({d} bytes), invoking curator agent...\n", .{content.len});
    }

    // Format content with line numbers for agent
    var numbered_content = std.ArrayListUnmanaged(u8){};
    defer numbered_content.deinit(allocator);
    const writer = numbered_content.writer(allocator);

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var line_num: usize = 1;
    while (line_iter.next()) |line| : (line_num += 1) {
        try writer.print("{d}: {s}\n", .{ line_num, line });
    }

    const numbered = try numbered_content.toOwnedSlice(allocator);
    defer allocator.free(numbered);

    // Format conversation context if available
    var conv_summary = std.ArrayListUnmanaged(u8){};
    defer conv_summary.deinit(allocator);

    if (context.recent_messages) |recent_msgs| {
        if (recent_msgs.len > 0) {
            try conv_summary.appendSlice(allocator, "CONVERSATION CONTEXT:\n");
            try conv_summary.appendSlice(allocator, "(Recent messages to help you understand what the user is investigating)\n\n");

            for (recent_msgs) |msg| {
                const role_name = switch (msg.role) {
                    .user => "User",
                    .assistant => "Assistant",
                    .system => "System",
                    .tool => continue, // Skip tool messages (too noisy)
                    .display_only_data => continue, // Skip UI-only notifications
                };

                // Truncate very long messages (keep first 300 chars)
                const msg_content = if (msg.content.len > 300)
                    msg.content[0..300]
                else
                    msg.content;

                try conv_summary.writer(allocator).print("{s}: {s}\n\n", .{ role_name, msg_content });
            }

            try conv_summary.appendSlice(allocator, "---\n\n");
        }
    }

    // Prepare task for agent
    const task = try std.fmt.allocPrint(
        allocator,
        "{s}Analyze this file and curate lines RELEVANT to the conversation above (if any):\n\nFile: {s}\n\n{s}",
        .{ conv_summary.items, parsed.value.path, numbered },
    );
    defer allocator.free(task);

    // Get agent definition
    const agent_def = try file_curator.getDefinition(allocator);
    defer {
        allocator.free(agent_def.name);
        allocator.free(agent_def.description);
    }

    // Build agent context
    const agent_context = AgentContext{
        .allocator = allocator,
        .ollama_client = context.ollama_client,
        .config = context.config,
        .capabilities = agent_def.capabilities,
        .recent_messages = context.recent_messages, // Pass conversation context
    };

    // Execute agent
    var agent_result = agent_def.execute(
        allocator,
        agent_context,
        task,
        null, // No progress callback
        null,
    ) catch |err| {
        if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
            std.debug.print("[DEBUG] Agent execution failed: {}, falling back to full file\n", .{err});
        }
        // Fallback: return full file if agent fails
        return formatFullFile(allocator, parsed.value.path, content, context, start_time);
    };
    defer agent_result.deinit(allocator);

    if (!agent_result.success) {
        if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
            std.debug.print("[DEBUG] Agent returned error, falling back to full file\n", .{});
        }
        // Fallback: return full file
        return formatFullFile(allocator, parsed.value.path, content, context, start_time);
    }

    if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
        std.debug.print("[DEBUG] Agent succeeded, parsing curation result...\n", .{});
    }

    // Parse curation result
    const curation = file_curator.parseCurationResult(
        allocator,
        agent_result.data orelse "",
    ) catch |err| {
        if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
            std.debug.print("[DEBUG] Failed to parse curation JSON: {}, falling back to full file\n", .{err});
        }
        // Fallback: return full file if parsing fails
        return formatFullFile(allocator, parsed.value.path, content, context, start_time);
    };
    defer curation.deinit();

    if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
        std.debug.print("[DEBUG] Curation parsed successfully, formatting output...\n", .{});
    }

    // Format curated output
    const curated_output = try file_curator.formatCuratedFile(
        allocator,
        parsed.value.path,
        content,
        curation.value,
    );
    defer allocator.free(curated_output);

    // Queue FULL file for GraphRAG indexing (not the curated version!)
    if (context.config.graph_rag_enabled and
        context.indexing_queue != null and
        !context.state.wasFileIndexed(parsed.value.path))
    {
        const IndexingTask = @import("../graphrag/indexing_queue.zig").IndexingTask;

        // Format full content for indexing (same as read_file does)
        const full_formatted = try formatFileForIndexing(allocator, parsed.value.path, content);

        const task_item = IndexingTask{
            .file_path = try allocator.dupe(u8, parsed.value.path),
            .content = full_formatted, // Already allocated, will be owned by queue
            .allocator = allocator,
        };

        try context.indexing_queue.?.push(task_item);

        if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
            std.debug.print("[GRAPHRAG] Queued full file {s} for indexing\n", .{parsed.value.path});
        }
    }

    // Mark file as read
    try context.state.markFileAsRead(parsed.value.path);

    if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
        std.debug.print("[DEBUG] read_file_curated returning curated view\n", .{});
    }

    return ToolResult.ok(allocator, curated_output, start_time);
}

/// Fallback: format full file (when curation fails)
fn formatFullFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    content: []const u8,
    context: *AppContext,
    start_time: i64,
) !ToolResult {
    // Format like read_file does
    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    // Count lines
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var lines = std.ArrayListUnmanaged([]const u8){};
    defer lines.deinit(allocator);

    while (line_iter.next()) |line| {
        try lines.append(allocator, line);
    }

    const total_lines = lines.items.len;

    try writer.writeAll("```\n");
    try writer.print("File: {s}\n", .{file_path});
    try writer.print("Total lines: {d}\n", .{total_lines});
    try writer.writeAll("Content:\n");

    for (lines.items, 0..) |line, idx| {
        try writer.print("{d}: {s}\n", .{ idx + 1, line });
    }

    try writer.writeAll("\nNotes: Lines are 1-indexed. Empty lines are preserved.\n");
    try writer.writeAll("```");

    const formatted = try output.toOwnedSlice(allocator);

    // Queue for indexing
    if (context.config.graph_rag_enabled and
        context.indexing_queue != null and
        !context.state.wasFileIndexed(file_path))
    {
        const IndexingTask = @import("../graphrag/indexing_queue.zig").IndexingTask;
        const task = IndexingTask{
            .file_path = try allocator.dupe(u8, file_path),
            .content = try allocator.dupe(u8, formatted),
            .allocator = allocator,
        };
        try context.indexing_queue.?.push(task);
    }

    try context.state.markFileAsRead(file_path);

    return ToolResult.ok(allocator, formatted, start_time);
}

/// Format file for GraphRAG indexing (same as read_file does)
fn formatFileForIndexing(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    content: []const u8,
) ![]const u8 {
    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    // Count lines
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var lines = std.ArrayListUnmanaged([]const u8){};
    defer lines.deinit(allocator);

    while (line_iter.next()) |line| {
        try lines.append(allocator, line);
    }

    const total_lines = lines.items.len;

    try writer.writeAll("```\n");
    try writer.print("File: {s}\n", .{file_path});
    try writer.print("Total lines: {d}\n", .{total_lines});
    try writer.writeAll("Content:\n");

    for (lines.items, 0..) |line, idx| {
        try writer.print("{d}: {s}\n", .{ idx + 1, line });
    }

    try writer.writeAll("\nNotes: Lines are 1-indexed. Empty lines are preserved.\n");
    try writer.writeAll("```");

    return try output.toOwnedSlice(allocator);
}

fn validate(allocator: std.mem.Allocator, arguments: []const u8) bool {
    const Args = struct { path: []const u8 };
    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{}) catch return false;
    defer parsed.deinit();

    // Check path is not absolute
    if (std.mem.startsWith(u8, parsed.value.path, "/")) return false;

    // Check path doesn't escape with ..
    if (std.mem.indexOf(u8, parsed.value.path, "..") != null) return false;

    return true;
}
