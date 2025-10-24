// Centralized Tool Registry for GraphRAG Indexing
// Mirrors the main tools.zig pattern but specialized for indexing tasks
const std = @import("std");
const ollama = @import("../ollama.zig");
const GraphBuilder = @import("graph_builder.zig").GraphBuilder;
const indexing_tools = @import("indexing_tools.zig");

// ============================================================================
// Tool Result Types
// ============================================================================

/// Result returned by indexing tool execution
/// Simplified version of main ToolResult - no timing metadata
pub const IndexingToolResult = struct {
    success: bool,
    message: []const u8,  // Human-readable feedback for LLM
    data: ?[]const u8,    // Optional structured data (JSON)

    /// Create success result
    pub fn ok(allocator: std.mem.Allocator, message: []const u8) !IndexingToolResult {
        return .{
            .success = true,
            .message = try allocator.dupe(u8, message),
            .data = null,
        };
    }

    /// Create error result
    pub fn err(allocator: std.mem.Allocator, message: []const u8) !IndexingToolResult {
        return .{
            .success = false,
            .message = try allocator.dupe(u8, message),
            .data = null,
        };
    }

    /// Helper to escape JSON strings
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

    /// Serialize to JSON for LLM consumption
    pub fn toJSON(self: *const IndexingToolResult, allocator: std.mem.Allocator) ![]const u8 {
        var json = std.ArrayListUnmanaged(u8){};
        defer json.deinit(allocator);
        const writer = json.writer(allocator);

        try writer.writeAll("{");
        try writer.print("\"success\":{s},", .{if (self.success) "true" else "false"});

        // Escape message for JSON
        const escaped_msg = try escapeJSON(allocator, self.message);
        defer allocator.free(escaped_msg);
        try writer.print("\"message\":\"{s}\"", .{escaped_msg});

        if (self.data) |d| {
            const escaped_data = try escapeJSON(allocator, d);
            defer allocator.free(escaped_data);
            try writer.print(",\"data\":\"{s}\"", .{escaped_data});
        }

        try writer.writeAll("}");

        return try json.toOwnedSlice(allocator);
    }

    /// Clean up allocated memory
    pub fn deinit(self: *IndexingToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        if (self.data) |d| allocator.free(d);
    }
};

// ============================================================================
// Context and Definition Types
// ============================================================================

/// Execution context for indexing tools
/// Contains mutable graph builder and statistics
pub const IndexingContext = struct {
    graph_builder: *GraphBuilder,
    file_path: []const u8,
    stats: struct {
        nodes_created: usize = 0,
        edges_created: usize = 0,
        errors: usize = 0,
    } = .{},
};

/// Tool definition for indexing tools
/// Similar to main ToolDefinition but without permission metadata
pub const IndexingToolDefinition = struct {
    // Ollama tool schema (for API calls)
    ollama_tool: ollama.Tool,
    // Execution function
    execute: *const fn (
        allocator: std.mem.Allocator,
        arguments: []const u8,
        context: *IndexingContext,
    ) anyerror!IndexingToolResult,
};

// ============================================================================
// Registry Functions
// ============================================================================

/// Returns all indexing tool definitions
/// Caller owns memory and must free each tool's strings
pub fn getAllIndexingToolDefinitions(allocator: std.mem.Allocator) ![]IndexingToolDefinition {
    var tools = std.ArrayListUnmanaged(IndexingToolDefinition){};
    errdefer tools.deinit(allocator);

    // Add create_node tool
    try tools.append(allocator, try indexing_tools.getCreateNodeDefinition(allocator));

    // Add create_edge tool
    try tools.append(allocator, try indexing_tools.getCreateEdgeDefinition(allocator));

    return try tools.toOwnedSlice(allocator);
}

/// Extracts just the Ollama tool schemas for API calls
/// Caller owns returned memory
pub fn getIndexingTools(allocator: std.mem.Allocator) ![]const ollama.Tool {
    const definitions = try getAllIndexingToolDefinitions(allocator);
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

/// Execute an indexing tool call by name
/// Finds matching tool and executes it with given context
pub fn executeIndexingToolCall(
    allocator: std.mem.Allocator,
    tool_call: ollama.ToolCall,
    context: *IndexingContext,
) !IndexingToolResult {
    const definitions = try getAllIndexingToolDefinitions(allocator);
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
    const msg = try std.fmt.allocPrint(allocator, "Unknown indexing tool: {s}", .{tool_call.function.name});
    defer allocator.free(msg);
    return IndexingToolResult.err(allocator, msg);
}
