// Shared type definitions for ZodoLlama
const std = @import("std");
const markdown = @import("markdown.zig");
const ollama = @import("ollama.zig");
const permission = @import("permission.zig");

/// Permission request associated with a tool call
pub const PermissionRequest = struct {
    tool_call: ollama.ToolCall,
    eval_result: permission.PolicyEngine.EvaluationResult,
    timestamp: i64,
};

/// Chat message with markdown rendering support
pub const Message = struct {
    role: enum { user, assistant, system, tool },
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
