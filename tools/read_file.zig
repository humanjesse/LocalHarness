// Read File Tool - Smart unified file reading with auto-detection
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

// Result from formatWithCuration containing both content and thinking
const CurationOutput = struct {
    content: []const u8,
    thinking: ?[]const u8,
};

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "read_file"),
                .description = try allocator.dupe(u8, "Reads a file with smart context optimization. Automatically adapts based on file size: small files (<100 lines) show full content, medium files (100-500 lines) show conversation-relevant sections, large files (>500 lines) show structural overview (imports, types, signatures). All files are indexed in GraphRAG for later queries. Use this as your primary file reading tool. For surgical access to specific line ranges, use read_lines instead."),
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
            .name = "read_file",
            .description = "Read file contents (smart context optimization)",
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
        std.debug.print("[DEBUG] read_file (unified) execute started\n", .{});
    }

    // Handle empty arguments
    if (arguments.len == 0 or std.mem.eql(u8, arguments, "{}")) {
        return ToolResult.err(allocator, .validation_failed, "read_file requires a 'path' argument", start_time);
    }

    const Args = struct { path: []const u8 };
    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{}) catch {
        return ToolResult.err(allocator, .parse_error, "Invalid JSON arguments", start_time);
    };
    defer parsed.deinit();

    if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
        std.debug.print("[DEBUG] Reading file: {s}\n", .{parsed.value.path});
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

    // Count lines
    const total_lines = countLines(content);

    // Get thresholds from config
    const small_threshold = context.config.file_read_small_threshold;
    const large_threshold = context.config.file_read_large_threshold;

    if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
        std.debug.print("[DEBUG] File has {d} lines. Thresholds: small={d}, large={d}\n", .{ total_lines, small_threshold, large_threshold });
    }

    // Smart auto-detection based on file size
    var thinking: ?[]const u8 = null;
    const formatted = if (total_lines < small_threshold) blk: {
        // SMALL FILES: Return full content (no agent overhead)
        break :blk try formatFullFile(allocator, parsed.value.path, content, total_lines);
    } else blk: {
        // MEDIUM/LARGE FILES: Use agent for curation/structure extraction
        const mode = if (total_lines <= large_threshold) "curated" else "structure";
        const output = try formatWithCuration(allocator, context, parsed.value.path, content, total_lines, mode);
        thinking = output.thinking;  // Capture thinking for ToolResult
        break :blk output.content;
    };
    defer if (thinking) |t| allocator.free(t);

    // Queue FULL file for GraphRAG indexing (always full content, not curated!)
    if (context.config.graph_rag_enabled and
        context.indexing_queue != null and
        !context.state.wasFileIndexed(parsed.value.path))
    {
        const IndexingTask = @import("../graphrag/indexing_queue.zig").IndexingTask;

        // Format full file for indexing
        const full_formatted = try formatFileForIndexing(allocator, parsed.value.path, content, total_lines);

        const task = IndexingTask{
            .file_path = try allocator.dupe(u8, parsed.value.path),
            .content = full_formatted, // Already allocated
            .allocator = allocator,
        };

        try context.indexing_queue.?.push(task);

        if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
            std.debug.print("[GRAPHRAG] Queued full file {s} for indexing\n", .{parsed.value.path});
        }
    }

    // Mark file as read
    try context.state.markFileAsRead(parsed.value.path);

    if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
        std.debug.print("[DEBUG] read_file returning success\n", .{});
    }

    return ToolResult.ok(allocator, formatted, start_time, thinking);
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

// ============================================================================
// Helper Functions
// ============================================================================

/// Count lines in content
fn countLines(content: []const u8) usize {
    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |_| {
        count += 1;
    }
    return count;
}

/// Format full file content (small files <100 lines)
fn formatFullFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    content: []const u8,
    total_lines: usize,
) ![]const u8 {
    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    // Split content into lines
    var lines = std.ArrayListUnmanaged([]const u8){};
    defer lines.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        try lines.append(allocator, line);
    }

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

/// Format file with agent curation (medium/large files)
fn formatWithCuration(
    allocator: std.mem.Allocator,
    context: *AppContext,
    file_path: []const u8,
    content: []const u8,
    total_lines: usize,
    mode: []const u8, // "curated" or "structure"
) !CurationOutput {
    if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
        std.debug.print("[DEBUG] Invoking file_curator agent ({s} mode)...\n", .{mode});
    }

    // Build conversation context if available
    var conv_summary = std.ArrayListUnmanaged(u8){};
    defer conv_summary.deinit(allocator);

    if (context.recent_messages) |recent_msgs| {
        if (recent_msgs.len > 0) {
            try conv_summary.appendSlice(allocator, "CONVERSATION CONTEXT:\n");
            try conv_summary.appendSlice(allocator, "(Recent messages to help understand what the user is investigating)\n\n");

            for (recent_msgs) |msg| {
                const role_name = switch (msg.role) {
                    .user => "User",
                    .assistant => "Assistant",
                    .system => "System",
                    .tool => continue,
                    .display_only_data => continue,
                };

                // Truncate very long messages
                const msg_content = if (msg.content.len > 300)
                    msg.content[0..300]
                else
                    msg.content;

                try conv_summary.writer(allocator).print("{s}: {s}\n\n", .{ role_name, msg_content });
            }

            try conv_summary.appendSlice(allocator, "---\n\n");
        }
    }

    const conv_ctx_slice = if (conv_summary.items.len > 0)
        try allocator.dupe(u8, conv_summary.items)
    else
        null;
    defer if (conv_ctx_slice) |ctx| allocator.free(ctx);

    // Build agent context
    const agent_context = AgentContext{
        .allocator = allocator,
        .ollama_client = context.ollama_client,
        .config = context.config,
        .capabilities = .{
            .allowed_tools = &.{},
            .max_iterations = 2,
            .temperature = 0.3,
            .num_ctx = 16384,
            .num_predict = 2000,
            .enable_thinking = false,
            .model_override = null,
        },
        .recent_messages = context.recent_messages,
    };

    // Extract progress callback from app context (for real-time streaming)
    const progress_callback = context.agent_progress_callback;
    const callback_user_data = context.agent_progress_user_data;

    // Invoke appropriate agent function with progress streaming
    const agent_result = if (std.mem.eql(u8, mode, "structure"))
        file_curator.extractStructure(allocator, agent_context, content, progress_callback, callback_user_data)
    else
        file_curator.curateForRelevance(allocator, agent_context, content, conv_ctx_slice, progress_callback, callback_user_data);

    var result = agent_result catch |err| {
        if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
            std.debug.print("[DEBUG] Agent execution failed: {}, falling back to full file\n", .{err});
        }
        // Fallback: return full file (no thinking)
        return .{
            .content = try formatFullFile(allocator, file_path, content, total_lines),
            .thinking = null,
        };
    };
    defer result.deinit(allocator);

    if (!result.success) {
        if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
            std.debug.print("[DEBUG] Agent returned error, falling back to full file\n", .{});
        }
        return .{
            .content = try formatFullFile(allocator, file_path, content, total_lines),
            .thinking = null,
        };
    }

    // Parse curation result
    const curation = file_curator.parseCurationResult(
        allocator,
        result.data orelse "",
    ) catch |err| {
        if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
            std.debug.print("[DEBUG] Failed to parse curation JSON: {}, falling back to full file\n", .{err});
        }
        return .{
            .content = try formatFullFile(allocator, file_path, content, total_lines),
            .thinking = null,
        };
    };
    defer curation.deinit();

    if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
        std.debug.print("[DEBUG] Curation parsed successfully, formatting output...\n", .{});
    }

    // Format curated output and extract thinking
    const formatted_content = try file_curator.formatCuratedFile(
        allocator,
        file_path,
        content,
        curation.value,
        mode,
    );

    // Return both content and thinking
    return .{
        .content = formatted_content,
        .thinking = if (result.thinking) |t| try allocator.dupe(u8, t) else null,
    };
}

/// Format file for GraphRAG indexing (always full content)
fn formatFileForIndexing(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    content: []const u8,
    total_lines: usize,
) ![]const u8 {
    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    // Split content into lines
    var lines = std.ArrayListUnmanaged([]const u8){};
    defer lines.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        try lines.append(allocator, line);
    }

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
