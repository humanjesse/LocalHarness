// LLM Helper - Unified patterns for LLM invocation across app and agents
const std = @import("std");
const ollama = @import("ollama.zig");
const llm_provider_module = @import("llm_provider.zig");

/// Request parameters for LLM invocation (unified across app and agents)
pub const LLMRequest = struct {
    /// Model to use
    model: []const u8,

    /// Messages in conversation history
    messages: []const ollama.ChatMessage,

    /// System prompt (will be prepended as first message if provided)
    system_prompt: ?[]const u8 = null,

    /// Available tools for the model
    tools: ?[]const ollama.Tool = null,

    /// Temperature (0.0 = deterministic, 1.0 = creative)
    temperature: f32 = 0.7,

    /// Context window size
    num_ctx: ?usize = null,

    /// Max tokens to predict
    num_predict: ?isize = null,

    /// Response format (e.g., "json" for JSON mode)
    format: ?[]const u8 = null,

    /// Keep alive duration
    keep_alive: []const u8 = "5m",

    /// Enable extended thinking
    think: bool = false,

    /// Repeat penalty (1.0 = no penalty)
    repeat_penalty: f32 = 1.1,
};

/// Helper for streaming LLM chat with consistent error handling
pub fn chatStream(
    provider: *llm_provider_module.LLMProvider,
    request: LLMRequest,
    allocator: std.mem.Allocator,
    context: anytype,
    callback: fn (
        ctx: @TypeOf(context),
        thinking_chunk: ?[]const u8,
        content_chunk: ?[]const u8,
        tool_calls_chunk: ?[]const ollama.ToolCall,
    ) void,
) !void {
    // Build message array (prepend system prompt if provided)
    var messages_to_send: []const ollama.ChatMessage = undefined;
    var messages_with_system: std.ArrayListUnmanaged(ollama.ChatMessage) = .{};
    defer messages_with_system.deinit(allocator);

    if (request.system_prompt) |sys_prompt| {
        try messages_with_system.append(allocator, .{
            .role = "system",
            .content = sys_prompt,
        });
        try messages_with_system.appendSlice(allocator, request.messages);
        messages_to_send = messages_with_system.items;
    } else {
        messages_to_send = request.messages;
    }

    // Get provider capabilities to check what's supported
    const caps = provider.getCapabilities();

    // Only enable thinking if both request and provider support it
    const enable_thinking = request.think and caps.supports_thinking;

    // Only pass keep_alive if provider supports it
    const keep_alive = if (caps.supports_keep_alive) request.keep_alive else null;

    // Call provider chatStream with unified parameters (capability-aware)
    try provider.chatStream(
        request.model,
        messages_to_send,
        enable_thinking,
        request.format,
        request.tools,
        keep_alive,
        request.num_ctx,
        request.num_predict,
        request.temperature,
        request.repeat_penalty,
        context,
        callback,
    );
}

/// Parse JSON response from LLM into typed struct
/// Returns error if JSON is invalid or doesn't match expected type
pub fn parseJSONResponse(
    allocator: std.mem.Allocator,
    comptime T: type,
    response: []const u8,
) !std.json.Parsed(T) {
    // Handle common LLM JSON mistakes: markdown code fences
    var cleaned_response = response;

    // Strip leading/trailing whitespace
    cleaned_response = std.mem.trim(u8, cleaned_response, " \n\r\t");

    // Strip markdown code fences if present
    if (std.mem.startsWith(u8, cleaned_response, "```json")) {
        cleaned_response = cleaned_response[7..]; // Skip ```json
        if (std.mem.indexOf(u8, cleaned_response, "```")) |end_idx| {
            cleaned_response = cleaned_response[0..end_idx];
        }
    } else if (std.mem.startsWith(u8, cleaned_response, "```")) {
        cleaned_response = cleaned_response[3..]; // Skip ```
        if (std.mem.indexOf(u8, cleaned_response, "```")) |end_idx| {
            cleaned_response = cleaned_response[0..end_idx];
        }
    }

    // Strip again after fence removal
    cleaned_response = std.mem.trim(u8, cleaned_response, " \n\r\t");

    // Parse JSON
    return try std.json.parseFromSlice(T, allocator, cleaned_response, .{
        .ignore_unknown_fields = true, // Be lenient with extra fields
    });
}

/// Validate that response is valid JSON before parsing
/// Returns true if valid, false otherwise
pub fn isValidJSON(response: []const u8) bool {
    // Quick validation - try to parse as generic Value
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        std.heap.page_allocator, // Use temp allocator for validation
        response,
        .{},
    ) catch return false;

    parsed.deinit();
    return true;
}

/// Helper to build tool array from tool names
/// Used by agents to filter tools based on capabilities
pub fn filterTools(
    allocator: std.mem.Allocator,
    all_tools: []const ollama.Tool,
    allowed_tool_names: []const []const u8,
) ![]const ollama.Tool {
    var filtered = std.ArrayListUnmanaged(ollama.Tool){};
    defer filtered.deinit(allocator);

    for (all_tools) |tool| {
        for (allowed_tool_names) |allowed_name| {
            if (std.mem.eql(u8, tool.function.name, allowed_name)) {
                try filtered.append(allocator, tool);
                break;
            }
        }
    }

    return try filtered.toOwnedSlice(allocator);
}

/// Message builder helper - reduces boilerplate
pub const MessageBuilder = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayListUnmanaged(ollama.ChatMessage),

    pub fn init(allocator: std.mem.Allocator) MessageBuilder {
        return .{
            .allocator = allocator,
            .messages = .{},
        };
    }

    pub fn deinit(self: *MessageBuilder) void {
        // Free all message contents
        for (self.messages.items) |msg| {
            self.allocator.free(msg.content);
            if (msg.tool_call_id) |id| {
                self.allocator.free(id);
            }
            // Note: tool_calls ownership is complex, handled by caller
        }
        self.messages.deinit(self.allocator);
    }

    pub fn addSystem(self: *MessageBuilder, content: []const u8) !void {
        try self.messages.append(self.allocator, .{
            .role = "system",
            .content = try self.allocator.dupe(u8, content),
        });
    }

    pub fn addUser(self: *MessageBuilder, content: []const u8) !void {
        try self.messages.append(self.allocator, .{
            .role = "user",
            .content = try self.allocator.dupe(u8, content),
        });
    }

    pub fn addAssistant(self: *MessageBuilder, content: []const u8) !void {
        try self.messages.append(self.allocator, .{
            .role = "assistant",
            .content = try self.allocator.dupe(u8, content),
        });
    }

    pub fn addTool(self: *MessageBuilder, tool_call_id: []const u8, content: []const u8) !void {
        try self.messages.append(self.allocator, .{
            .role = "tool",
            .content = try self.allocator.dupe(u8, content),
            .tool_call_id = try self.allocator.dupe(u8, tool_call_id),
        });
    }

    pub fn build(self: *MessageBuilder) ![]const ollama.ChatMessage {
        return try self.messages.toOwnedSlice(self.allocator);
    }

    pub fn getSlice(self: *const MessageBuilder) []const ollama.ChatMessage {
        return self.messages.items;
    }
};

/// Extract text content from streaming chunks (common pattern)
pub fn extractTextFromChunks(
    allocator: std.mem.Allocator,
    chunks: []const struct { content: ?[]const u8 },
) ![]const u8 {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(allocator);

    for (chunks) |chunk| {
        if (chunk.content) |content| {
            try buffer.appendSlice(allocator, content);
        }
    }

    return try buffer.toOwnedSlice(allocator);
}
