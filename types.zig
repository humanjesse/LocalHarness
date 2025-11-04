// Shared type definitions for Local Harness
const std = @import("std");
const markdown = @import("markdown");
const ollama = @import("ollama");
const permission = @import("permission");

/// Permission request associated with a tool call
pub const PermissionRequest = struct {
    tool_call: ollama.ToolCall,
    eval_result: permission.PolicyEngine.EvaluationResult,
    timestamp: i64,
};

/// Chat message with markdown rendering support
pub const Message = struct {
    role: enum { user, assistant, system, tool, display_only_data },
    content: []const u8, // Raw markdown text
    processed_content: std.ArrayListUnmanaged(markdown.RenderableItem),
    thinking_content: ?[]const u8 = null, // Optional reasoning/thinking content
    processed_thinking_content: ?std.ArrayListUnmanaged(markdown.RenderableItem) = null,
    thinking_expanded: bool = true, // Controls thinking box expansion (main content always shown)
    timestamp: i64,
    // Tool calling fields
    tool_calls: ?[]ollama.ToolCall = null, // Present when assistant calls tools
    tool_call_id: ?[]const u8 = null, // Required when role is "tool"
    // Permission request field
    permission_request: ?PermissionRequest = null, // Present when asking for permission
    // Tool execution display fields (for system messages showing tool results)
    tool_call_expanded: bool = false, // Controls tool result expansion (default collapsed)
    tool_name: ?[]const u8 = null, // Name of executed tool
    tool_success: ?bool = null, // Whether tool succeeded
    tool_execution_time: ?i64 = null, // Execution time in milliseconds
    // Agent analysis fields (for sub-agent thinking display - file_curator, graphrag, etc.)
    agent_analysis_name: ?[]const u8 = null, // e.g., "File Curator"
    agent_analysis_expanded: bool = true, // Default expanded until user collapses
    agent_analysis_completed: bool = false, // Whether agent finished (enables collapse)
};

/// Clickable area for mouse interaction (thinking blocks)
pub const ClickableArea = struct {
    y_start: usize,
    y_end: usize,
    x_start: usize,
    x_end: usize,
    message: *Message,
};

/// Chunk of streaming response data
pub const StreamChunk = struct {
    thinking: ?[]const u8,
    content: ?[]const u8,
    done: bool,
};

/// User's choice for how to handle read_file output in GraphRAG secondary loop
pub const GraphRagChoice = enum {
    full_indexing,   // Run full GraphRAG indexing (default)
    custom_lines,    // Save only specific line ranges
    metadata_only,   // Save just tool call and filename
};

/// Line range specification for custom_lines choice
pub const LineRange = struct {
    start: usize,
    end: usize,
};
