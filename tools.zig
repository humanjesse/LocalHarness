// Tools Registry - Centralized tool registration and execution
const std = @import("std");
const ollama = @import("ollama.zig");
const permission = @import("permission.zig");
const context_module = @import("context.zig");

// Import all tool modules
const file_tree = @import("tools/file_tree.zig");
const ls = @import("tools/ls.zig");
const read_file = @import("tools/read_file.zig");
const read_lines = @import("tools/read_lines.zig");
const write_file = @import("tools/write_file.zig");
const replace_lines = @import("tools/replace_lines.zig");
const insert_lines = @import("tools/insert_lines.zig");
const grep_search = @import("tools/grep_search.zig");
const current_time = @import("tools/current_time.zig");
const pwd = @import("tools/pwd.zig");
const add_todo = @import("tools/add_todo.zig");
const list_todos = @import("tools/list_todos.zig");
const update_todo = @import("tools/update_todo.zig");
const run_agent = @import("tools/run_agent.zig");
const list_agents = @import("tools/list_agents.zig");
const git_status = @import("tools/git_status.zig");
const git_diff = @import("tools/git_diff.zig");
const git_log = @import("tools/git_log.zig");
const git_add = @import("tools/git_add.zig");
const git_commit = @import("tools/git_commit.zig");
const git_branch = @import("tools/git_branch.zig");
const git_checkout = @import("tools/git_checkout.zig");
const git_stash = @import("tools/git_stash.zig");
const git_push = @import("tools/git_push.zig");
const git_pull = @import("tools/git_pull.zig");
const git_reset = @import("tools/git_reset.zig");

const AppContext = context_module.AppContext;

// ============================================================================
// Tool Result Types (Shared by all tools)
// ============================================================================

pub const ToolErrorType = enum {
    none,
    not_found,
    validation_failed,
    permission_denied,
    io_error,
    parse_error,
    internal_error,
};

pub const ToolResult = struct {
    success: bool,
    data: ?[]const u8,
    error_message: ?[]const u8,
    error_type: ToolErrorType,
    thinking: ?[]const u8 = null,  // Optional thinking/reasoning from agents
    metadata: struct {
        execution_time_ms: i64,
        data_size_bytes: usize,
        timestamp: i64,
    },

    // Helper to create success result
    pub fn ok(allocator: std.mem.Allocator, data: []const u8, start_time: i64, thinking_opt: ?[]const u8) !ToolResult {
        const end_time = std.time.milliTimestamp();
        return .{
            .success = true,
            .data = try allocator.dupe(u8, data),
            .error_message = null,
            .error_type = .none,
            .thinking = if (thinking_opt) |t| try allocator.dupe(u8, t) else null,
            .metadata = .{
                .execution_time_ms = end_time - start_time,
                .data_size_bytes = data.len,
                .timestamp = end_time,
            },
        };
    }

    // Helper to create error result
    pub fn err(allocator: std.mem.Allocator, error_type: ToolErrorType, message: []const u8, start_time: i64) !ToolResult {
        const end_time = std.time.milliTimestamp();
        return .{
            .success = false,
            .data = null,
            .error_message = try allocator.dupe(u8, message),
            .error_type = error_type,
            .metadata = .{
                .execution_time_ms = end_time - start_time,
                .data_size_bytes = 0,
                .timestamp = end_time,
            },
        };
    }

    // Helper to escape JSON string
    fn escapeJSON(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        var escaped = std.ArrayListUnmanaged(u8){};
        defer escaped.deinit(allocator);
        const writer = escaped.writer(allocator);

        for (input) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => try writer.writeByte(c),
            }
        }

        return try escaped.toOwnedSlice(allocator);
    }

    // Serialize to JSON for model
    pub fn toJSON(self: *const ToolResult, allocator: std.mem.Allocator) ![]const u8 {
        var json = std.ArrayListUnmanaged(u8){};
        defer json.deinit(allocator);
        const writer = json.writer(allocator);

        try writer.writeAll("{");
        try writer.print("\"success\":{s},", .{if (self.success) "true" else "false"});

        if (self.data) |d| {
            const escaped_data = try escapeJSON(allocator, d);
            defer allocator.free(escaped_data);
            try writer.print("\"data\":\"{s}\",", .{escaped_data});
        } else {
            try writer.writeAll("\"data\":null,");
        }

        if (self.error_message) |e| {
            const escaped_err = try escapeJSON(allocator, e);
            defer allocator.free(escaped_err);
            try writer.print("\"error_message\":\"{s}\",", .{escaped_err});
        } else {
            try writer.writeAll("\"error_message\":null,");
        }

        try writer.print("\"error_type\":\"{s}\",", .{@tagName(self.error_type)});
        try writer.print("\"metadata\":{{\"execution_time_ms\":{d},\"data_size_bytes\":{d},\"timestamp\":{d}}}", .{ self.metadata.execution_time_ms, self.metadata.data_size_bytes, self.metadata.timestamp });
        try writer.writeAll("}");

        return try json.toOwnedSlice(allocator);
    }

    // Format for user display (full transparency)
    pub fn formatDisplay(self: *const ToolResult, allocator: std.mem.Allocator, tool_name: []const u8, args: []const u8) ![]const u8 {
        var display = std.ArrayListUnmanaged(u8){};
        defer display.deinit(allocator);
        const writer = display.writer(allocator);

        try writer.print("[Tool: {s}]\n", .{tool_name});

        if (self.success) {
            try writer.writeAll("Status: ✅ SUCCESS\n");
            if (self.data) |d| {
                // Truncate large outputs (increased limit for tree/search results)
                const preview_len = @min(d.len, 10000);
                try writer.print("Result: {s}", .{d[0..preview_len]});
                if (d.len > 10000) {
                    try writer.print("... ({d} more bytes)", .{d.len - 10000});
                }
                try writer.writeAll("\n");
            }
        } else {
            try writer.writeAll("Status: ❌ FAILED\n");
            try writer.print("Error Type: {s}\n", .{@tagName(self.error_type)});
            if (self.error_message) |e| {
                try writer.print("Error: {s}\n", .{e});
            }
        }

        try writer.print("Execution Time: {d}ms\n", .{self.metadata.execution_time_ms});
        try writer.print("Data Size: {d} bytes\n", .{self.metadata.data_size_bytes});
        try writer.print("Arguments: {s}", .{args});

        return try display.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *ToolResult, allocator: std.mem.Allocator) void {
        if (self.data) |d| allocator.free(d);
        if (self.error_message) |e| allocator.free(e);
        if (self.thinking) |t| allocator.free(t);
    }
};

// ============================================================================
// Tool Definition Structure
// ============================================================================

pub const ToolDefinition = struct {
    // Ollama tool schema (for API calls)
    ollama_tool: ollama.Tool,
    // Permission metadata (for safety checks)
    permission_metadata: permission.ToolMetadata,
    // Execution function (Phase 1: accepts AppContext for future graph RAG)
    execute: *const fn (std.mem.Allocator, []const u8, *AppContext) anyerror!ToolResult,
};

// ============================================================================
// Public API
// ============================================================================

/// Returns all tool definitions (caller owns memory)
pub fn getAllToolDefinitions(allocator: std.mem.Allocator) ![]ToolDefinition {
    var tools = std.ArrayListUnmanaged(ToolDefinition){};
    errdefer tools.deinit(allocator);

    // File system tools
    try tools.append(allocator, try file_tree.getDefinition(allocator));
    try tools.append(allocator, try ls.getDefinition(allocator));
    try tools.append(allocator, try read_file.getDefinition(allocator)); // Now unified with smart auto-detection
    try tools.append(allocator, try read_lines.getDefinition(allocator));
    try tools.append(allocator, try write_file.getDefinition(allocator));
    try tools.append(allocator, try replace_lines.getDefinition(allocator));
    try tools.append(allocator, try insert_lines.getDefinition(allocator));
    try tools.append(allocator, try grep_search.getDefinition(allocator));

    // System tools
    try tools.append(allocator, try current_time.getDefinition(allocator));
    try tools.append(allocator, try pwd.getDefinition(allocator));

    // Git tools
    try tools.append(allocator, try git_status.getDefinition(allocator));
    try tools.append(allocator, try git_diff.getDefinition(allocator));
    try tools.append(allocator, try git_log.getDefinition(allocator));
    try tools.append(allocator, try git_add.getDefinition(allocator));
    try tools.append(allocator, try git_commit.getDefinition(allocator));
    try tools.append(allocator, try git_branch.getDefinition(allocator));
    try tools.append(allocator, try git_checkout.getDefinition(allocator));
    try tools.append(allocator, try git_stash.getDefinition(allocator));
    try tools.append(allocator, try git_push.getDefinition(allocator));
    try tools.append(allocator, try git_pull.getDefinition(allocator));
    try tools.append(allocator, try git_reset.getDefinition(allocator));

    // Todo management tools (Phase 1)
    try tools.append(allocator, try add_todo.getDefinition(allocator));
    try tools.append(allocator, try list_todos.getDefinition(allocator));
    try tools.append(allocator, try update_todo.getDefinition(allocator));

    // Agent tools
    try tools.append(allocator, try run_agent.getDefinition(allocator));
    try tools.append(allocator, try list_agents.getDefinition(allocator));

    return try tools.toOwnedSlice(allocator);
}

/// Extracts just the Ollama tool schemas for API calls
pub fn getOllamaTools(allocator: std.mem.Allocator) ![]const ollama.Tool {
    const definitions = try getAllToolDefinitions(allocator);
    defer {
        // Free the definitions array but NOT the ollama_tool contents
        // (caller takes ownership of those)
        allocator.free(definitions);
    }

    var tools = try allocator.alloc(ollama.Tool, definitions.len);
    for (definitions, 0..) |def, i| {
        tools[i] = def.ollama_tool;
    }

    return tools;
}

/// Extracts just the permission metadata for registration
pub fn getPermissionMetadata(allocator: std.mem.Allocator) ![]permission.ToolMetadata {
    const definitions = try getAllToolDefinitions(allocator);
    defer {
        // Free the allocated strings inside each definition
        for (definitions) |def| {
            allocator.free(def.ollama_tool.function.name);
            allocator.free(def.ollama_tool.function.description);
            allocator.free(def.ollama_tool.function.parameters);
        }
        allocator.free(definitions);
    }

    var metadata = try allocator.alloc(permission.ToolMetadata, definitions.len);
    for (definitions, 0..) |def, i| {
        metadata[i] = def.permission_metadata;
    }

    return metadata;
}

/// Execute a tool by name (Phase 1: accepts AppContext for state access)
pub fn executeToolCall(allocator: std.mem.Allocator, tool_call: ollama.ToolCall, context: *AppContext) !ToolResult {
    const start_time = std.time.milliTimestamp();
    const definitions = try getAllToolDefinitions(allocator);
    defer {
        // Free the tool definitions
        for (definitions) |def| {
            allocator.free(def.ollama_tool.function.name);
            allocator.free(def.ollama_tool.function.description);
            allocator.free(def.ollama_tool.function.parameters);
        }
        allocator.free(definitions);
    }

    // Find matching tool and execute
    for (definitions) |def| {
        if (std.mem.eql(u8, def.ollama_tool.function.name, tool_call.function.name)) {
            return try def.execute(allocator, tool_call.function.arguments, context);
        }
    }

    // Tool not found
    const msg = try std.fmt.allocPrint(allocator, "Unknown tool: {s}", .{tool_call.function.name});
    defer allocator.free(msg);
    return ToolResult.err(allocator, .not_found, msg, start_time);
}
