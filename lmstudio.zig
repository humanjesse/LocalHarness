// LM Studio API client (OpenAI-compatible) - using Zig 0.15.2 std.http
const std = @import("std");
const http = std.http;
const json = std.json;
const mem = std.mem;
const ollama = @import("ollama.zig");  // Re-use common types

// OpenAI-compatible streaming response format
const OpenAIStreamChunk = struct {
    id: ?[]const u8 = null,
    object: ?[]const u8 = null,
    created: ?i64 = null,
    model: ?[]const u8 = null,
    choices: ?[]struct {
        index: ?i32 = null,
        delta: ?struct {
            role: ?[]const u8 = null,
            content: ?[]const u8 = null,
            reasoning: ?[]const u8 = null,  // LM Studio reasoning/thinking
            tool_calls: ?[]struct {
                index: ?i32 = null,
                id: ?[]const u8 = null,
                type: ?[]const u8 = null,
                function: ?struct {
                    name: ?[]const u8 = null,
                    arguments: ?[]const u8 = null,
                } = null,
            } = null,
        } = null,
        finish_reason: ?[]const u8 = null,
    } = null,
    usage: ?struct {
        prompt_tokens: ?i32 = null,
        completion_tokens: ?i32 = null,
        total_tokens: ?i32 = null,
    } = null,
};

// OpenAI embeddings response format
const OpenAIEmbeddingResponse = struct {
    object: []const u8,
    data: []struct {
        object: []const u8,
        embedding: []f32,
        index: i32,
    },
    model: []const u8,
    usage: struct {
        prompt_tokens: i32,
        total_tokens: i32,
    },
};

// OpenAI error response format
const OpenAIErrorResponse = struct {
    @"error": struct {
        message: []const u8,
        type: []const u8,
        code: ?[]const u8 = null,
    },
};

/// LM Studio Chat Client (OpenAI-compatible)
pub const LMStudioClient = struct {
    allocator: mem.Allocator,
    client: http.Client,
    base_url: []const u8,

    pub fn init(allocator: mem.Allocator, base_url: []const u8) LMStudioClient {
        return .{
            .allocator = allocator,
            .client = http.Client{ .allocator = allocator },
            .base_url = base_url,
        };
    }

    pub fn deinit(self: *LMStudioClient) void {
        self.client.deinit();
    }

    /// Streaming chat with callback for each chunk
    /// Adapts OpenAI format to Ollama-compatible callback interface
    pub fn chatStream(
        self: *LMStudioClient,
        model: []const u8,
        messages: []const ollama.ChatMessage,
        format: ?[]const u8,
        tools: ?[]const ollama.Tool,
        num_ctx: ?usize,
        num_predict: ?isize,
        temperature: ?f32,
        repeat_penalty: ?f32, // Note: LM Studio doesn't support this, parameter ignored
        context: anytype,
        callback: fn (
            ctx: @TypeOf(context),
            thinking_chunk: ?[]const u8,
            content_chunk: ?[]const u8,
            tool_calls_chunk: ?[]const ollama.ToolCall,
        ) void,
    ) !void {
        // Note: LM Studio doesn't support these OpenAI-incompatible parameters
        _ = num_ctx; // Context size handled by LM Studio settings
        _ = repeat_penalty; // Not in OpenAI API spec

        // Build JSON payload manually for performance
        var payload_list = std.ArrayListUnmanaged(u8){};
        defer payload_list.deinit(self.allocator);

        try payload_list.appendSlice(self.allocator, "{\"model\":\"");
        try payload_list.appendSlice(self.allocator, model);
        try payload_list.appendSlice(self.allocator, "\",\"messages\":[");

        // Add messages
        for (messages, 0..) |msg, i| {
            if (i > 0) try payload_list.append(self.allocator, ',');
            try payload_list.appendSlice(self.allocator, "{\"role\":\"");
            try payload_list.appendSlice(self.allocator, msg.role);
            try payload_list.appendSlice(self.allocator, "\",\"content\":\"");

            // Escape message content
            for (msg.content) |c| {
                if (c == '"') {
                    try payload_list.appendSlice(self.allocator, "\\\"");
                } else if (c == '\\') {
                    try payload_list.appendSlice(self.allocator, "\\\\");
                } else if (c == '\n') {
                    try payload_list.appendSlice(self.allocator, "\\n");
                } else if (c == '\r') {
                    try payload_list.appendSlice(self.allocator, "\\r");
                } else if (c == '\t') {
                    try payload_list.appendSlice(self.allocator, "\\t");
                } else {
                    try payload_list.append(self.allocator, c);
                }
            }
            try payload_list.append(self.allocator, '"');

            // Add tool_call_id if present (for tool response messages)
            if (msg.tool_call_id) |tool_id| {
                try payload_list.appendSlice(self.allocator, ",\"tool_call_id\":\"");
                try payload_list.appendSlice(self.allocator, tool_id);
                try payload_list.append(self.allocator, '"');
            }

            // Add tool_calls if present (for assistant messages with tool calls)
            if (msg.tool_calls) |tc| {
                try payload_list.appendSlice(self.allocator, ",\"tool_calls\":[");
                for (tc, 0..) |tool_call, j| {
                    if (j > 0) try payload_list.append(self.allocator, ',');
                    try payload_list.appendSlice(self.allocator, "{\"id\":\"");
                    if (tool_call.id) |id| {
                        try payload_list.appendSlice(self.allocator, id);
                    } else {
                        try payload_list.appendSlice(self.allocator, "call_0");
                    }
                    try payload_list.appendSlice(self.allocator, "\",\"type\":\"function\",\"function\":{\"name\":\"");
                    try payload_list.appendSlice(self.allocator, tool_call.function.name);
                    try payload_list.appendSlice(self.allocator, "\",\"arguments\":\"");

                    // Escape arguments (which is already a JSON string)
                    for (tool_call.function.arguments) |c| {
                        if (c == '"') {
                            try payload_list.appendSlice(self.allocator, "\\\"");
                        } else if (c == '\\') {
                            try payload_list.appendSlice(self.allocator, "\\\\");
                        } else if (c == '\n') {
                            try payload_list.appendSlice(self.allocator, "\\n");
                        } else {
                            try payload_list.append(self.allocator, c);
                        }
                    }
                    try payload_list.appendSlice(self.allocator, "\"}}");
                }
                try payload_list.append(self.allocator, ']');
            }

            try payload_list.append(self.allocator, '}');
        }

        try payload_list.appendSlice(self.allocator, "],\"stream\":true");

        // Add optional parameters
        if (temperature) |temp| {
            try payload_list.appendSlice(self.allocator, ",\"temperature\":");
            const temp_str = try std.fmt.allocPrint(self.allocator, "{d:.2}", .{temp});
            defer self.allocator.free(temp_str);
            try payload_list.appendSlice(self.allocator, temp_str);
        }

        if (num_predict) |max_tokens| {
            if (max_tokens > 0) {
                try payload_list.appendSlice(self.allocator, ",\"max_tokens\":");
                const tokens_str = try std.fmt.allocPrint(self.allocator, "{d}", .{max_tokens});
                defer self.allocator.free(tokens_str);
                try payload_list.appendSlice(self.allocator, tokens_str);
            }
        }

        // Add tools if provided
        if (tools) |tool_list| {
            try payload_list.appendSlice(self.allocator, ",\"tools\":[");
            for (tool_list, 0..) |tool, i| {
                if (i > 0) try payload_list.append(self.allocator, ',');
                try payload_list.appendSlice(self.allocator, "{\"type\":\"function\",\"function\":{\"name\":\"");
                try payload_list.appendSlice(self.allocator, tool.function.name);
                try payload_list.appendSlice(self.allocator, "\",\"description\":\"");

                // Escape description
                for (tool.function.description) |c| {
                    if (c == '"') {
                        try payload_list.appendSlice(self.allocator, "\\\"");
                    } else if (c == '\\') {
                        try payload_list.appendSlice(self.allocator, "\\\\");
                    } else if (c == '\n') {
                        try payload_list.appendSlice(self.allocator, "\\n");
                    } else {
                        try payload_list.append(self.allocator, c);
                    }
                }

                try payload_list.appendSlice(self.allocator, "\",\"parameters\":");
                try payload_list.appendSlice(self.allocator, tool.function.parameters);
                try payload_list.appendSlice(self.allocator, "}}");
            }
            try payload_list.append(self.allocator, ']');
        }

        // Add response format if JSON mode requested
        if (format) |fmt| {
            if (std.mem.eql(u8, fmt, "json")) {
                try payload_list.appendSlice(self.allocator, ",\"response_format\":{\"type\":\"json_object\"}");
            }
        }

        try payload_list.append(self.allocator, '}');

        const payload = try payload_list.toOwnedSlice(self.allocator);
        defer self.allocator.free(payload);

        // DEBUG: Print request payload
        if (std.posix.getenv("DEBUG_TOOLS") != null or std.posix.getenv("DEBUG_GRAPHRAG") != null) {
            std.debug.print("\n=== DEBUG: LM Studio Request Payload ===\n{s}\n=== END PAYLOAD ===\n\n", .{payload});
        }

        // Make HTTP request
        const full_url = try std.fmt.allocPrint(self.allocator, "{s}/v1/chat/completions", .{self.base_url});
        defer self.allocator.free(full_url);
        const uri = try std.Uri.parse(full_url);

        const headers_buffer = try self.allocator.alloc(http.Header, 2);
        defer self.allocator.free(headers_buffer);
        headers_buffer[0] = .{ .name = "content-type", .value = "application/json" };
        headers_buffer[1] = .{ .name = "accept", .value = "text/event-stream" };

        var req = self.client.request(.POST, uri, .{
            .extra_headers = headers_buffer,
        }) catch |err| {
            std.debug.print("\n❌ Failed to connect to LM Studio at {s}\n", .{self.base_url});
            std.debug.print("   Error: {s}\n", .{@errorName(err)});
            std.debug.print("\n💡 Make sure:\n", .{});
            std.debug.print("   1. LM Studio app is open\n", .{});
            std.debug.print("   2. You've loaded a model in LM Studio\n", .{});
            std.debug.print("   3. Server is started (check 'Local Server' tab)\n", .{});
            std.debug.print("   4. Server is running on {s} (check LM Studio settings)\n\n", .{self.base_url});
            return err;
        };
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = payload.len };

        // Send body
        var body = try req.sendBodyUnflushed(&.{});
        try body.writer.writeAll(payload);
        try body.end();
        try req.connection.?.flush();

        // Receive response
        if (std.posix.getenv("DEBUG_LMSTUDIO") != null) {
            std.debug.print("DEBUG: Waiting for LM Studio response...\n", .{});
        }
        const redirect_buffer = try self.allocator.alloc(u8, 8 * 1024);
        defer self.allocator.free(redirect_buffer);
        const response = try req.receiveHead(redirect_buffer);

        if (std.posix.getenv("DEBUG_LMSTUDIO") != null) {
            std.debug.print("DEBUG: Got response status: {}\n", .{response.head.status});
        }

        if (response.head.status != .ok) {
            std.debug.print("\n❌ LM Studio API error: {}\n", .{response.head.status});
            std.debug.print("\n💡 Common issues:\n", .{});
            std.debug.print("   - No model loaded in LM Studio\n", .{});
            std.debug.print("   - Model name mismatch (check /config)\n", .{});
            std.debug.print("   - Server not fully started\n\n", .{});
            return error.BadStatus;
        }

        // Parse SSE stream using connection's reader
        if (std.posix.getenv("DEBUG_LMSTUDIO") != null) {
            std.debug.print("DEBUG: Starting SSE stream parse...\n", .{});
        }
        const reader = req.connection.?.reader();
        try self.parseSSEStream(reader, context, callback);
        if (std.posix.getenv("DEBUG_LMSTUDIO") != null) {
            std.debug.print("DEBUG: SSE stream parse completed\n", .{});
        }
    }

    /// Decode HTTP chunked transfer encoding
    /// Returns the decoded data or null if incomplete chunk
    fn decodeChunkedData(
        self: *LMStudioClient,
        raw_buffer: *std.ArrayListUnmanaged(u8),
        decoded_buffer: *std.ArrayListUnmanaged(u8),
    ) !bool {
        const debug_mode = std.posix.getenv("DEBUG_LMSTUDIO") != null;

        while (true) {
            // Look for chunk size line (hex number followed by \r\n)
            const crlf_pos = std.mem.indexOf(u8, raw_buffer.items, "\r\n") orelse return false;

            // Parse chunk size (hex)
            const size_str = std.mem.trim(u8, raw_buffer.items[0..crlf_pos], " \t");
            const chunk_size = std.fmt.parseInt(usize, size_str, 16) catch {
                if (debug_mode) {
                    std.debug.print("DEBUG: Failed to parse chunk size: '{s}'\n", .{size_str});
                }
                return error.InvalidChunkSize;
            };

            if (debug_mode) {
                std.debug.print("DEBUG: Decoded chunk size: {d} (0x{s})\n", .{chunk_size, size_str});
            }

            // Check if we have the complete chunk data
            const chunk_start = crlf_pos + 2; // Skip \r\n after size
            const chunk_end = chunk_start + chunk_size;

            if (raw_buffer.items.len < chunk_end + 2) {
                // Incomplete chunk, need more data
                return false;
            }

            // Chunk size 0 means end of chunks
            if (chunk_size == 0) {
                if (debug_mode) {
                    std.debug.print("DEBUG: End of chunked encoding\n", .{});
                }
                return true;
            }

            // Extract chunk data and append to decoded buffer
            try decoded_buffer.appendSlice(self.allocator, raw_buffer.items[chunk_start..chunk_end]);

            // Remove processed chunk from raw buffer (including trailing \r\n)
            const remove_until = chunk_end + 2; // chunk data + \r\n
            const remaining = raw_buffer.items[remove_until..];
            std.mem.copyForwards(u8, raw_buffer.items, remaining);
            try raw_buffer.resize(self.allocator, remaining.len);
        }
    }

    /// Parse Server-Sent Events stream from LM Studio (with chunked encoding support)
    fn parseSSEStream(
        self: *LMStudioClient,
        reader: anytype,
        context: anytype,
        callback: fn (
            ctx: @TypeOf(context),
            thinking_chunk: ?[]const u8,
            content_chunk: ?[]const u8,
            tool_calls_chunk: ?[]const ollama.ToolCall,
        ) void,
    ) !void {
        var raw_buffer = std.ArrayListUnmanaged(u8){}; // Raw HTTP data (chunked)
        defer raw_buffer.deinit(self.allocator);

        var decoded_buffer = std.ArrayListUnmanaged(u8){}; // Decoded SSE data
        defer decoded_buffer.deinit(self.allocator);

        var chunk_buffer: [8192]u8 = undefined;
        var accumulated_tool_calls = std.ArrayListUnmanaged(ollama.ToolCall){};
        defer {
            for (accumulated_tool_calls.items) |tc| {
                if (tc.id) |id| self.allocator.free(id);
                self.allocator.free(tc.function.name);
                self.allocator.free(tc.function.arguments);
            }
            accumulated_tool_calls.deinit(self.allocator);
        }

        const debug_mode = std.posix.getenv("DEBUG_LMSTUDIO") != null;

        while (true) {
            // Read raw data
            var read_vec = [_][]u8{&chunk_buffer};
            const bytes_read = reader.*.readVec(&read_vec) catch |err| {
                if (debug_mode) {
                    std.debug.print("DEBUG: Read error: {s}\n", .{@errorName(err)});
                }
                if (err == error.EndOfStream) break;
                return err;
            };
            if (bytes_read == 0) break;

            try raw_buffer.appendSlice(self.allocator, chunk_buffer[0..bytes_read]);

            // Decode chunked encoding
            _ = try self.decodeChunkedData(&raw_buffer, &decoded_buffer);

            // Process complete SSE lines from decoded buffer
            while (std.mem.indexOf(u8, decoded_buffer.items, "\n")) |newline_pos| {
                var line = decoded_buffer.items[0..newline_pos];

                // Trim \r from end of line (SSE uses \r\n line endings)
                if (line.len > 0 and line[line.len - 1] == '\r') {
                    line = line[0..line.len - 1];
                }

                // Make a copy of the line before we modify the buffer
                const line_copy = try self.allocator.dupe(u8, line);
                defer self.allocator.free(line_copy);

                // Remove this line from decoded buffer
                const remaining = decoded_buffer.items[newline_pos + 1..];
                std.mem.copyForwards(u8, decoded_buffer.items, remaining);
                try decoded_buffer.resize(self.allocator, remaining.len);

                // Skip empty lines and comments
                if (line_copy.len == 0) continue;
                if (line_copy[0] == ':') continue;

                // Check for "data: " prefix (SSE format)
                if (std.mem.startsWith(u8, line_copy, "data: ")) {
                    const data = std.mem.trim(u8, line_copy[6..], " \r\n\t");

                    // Check for [DONE] signal
                    if (std.mem.eql(u8, data, "[DONE]")) break;

                    // Parse JSON chunk
                    const parsed = json.parseFromSlice(
                        OpenAIStreamChunk,
                        self.allocator,
                        data,
                        .{ .ignore_unknown_fields = true },
                    ) catch |err| {
                        if (debug_mode) {
                            std.debug.print("❌ Failed to parse LM Studio SSE chunk: {s}\nData: {s}\n", .{@errorName(err), data});
                        }
                        continue;
                    };
                    defer parsed.deinit();

                    const chunk = parsed.value;

                    // Extract content and tool calls from delta
                    if (chunk.choices) |choices| {
                        if (choices.len > 0 and choices[0].delta != null) {
                            const delta = choices[0].delta.?;

                            // Handle reasoning (thinking content from LM Studio)
                            if (delta.reasoning) |reasoning| {
                                callback(context, reasoning, null, null);
                            }

                            // Handle content
                            if (delta.content) |content| {
                                callback(context, null, content, null);
                            }

                            // Handle tool calls (accumulate them as they stream in)
                            if (delta.tool_calls) |tc_deltas| {
                                for (tc_deltas) |tc_delta| {
                                    if (tc_delta.index) |idx| {
                                        const index = @as(usize, @intCast(idx));

                                        // Ensure we have enough space
                                        while (accumulated_tool_calls.items.len <= index) {
                                            try accumulated_tool_calls.append(self.allocator, .{
                                                .id = null,
                                                .type = null,
                                                .function = .{
                                                    .name = try self.allocator.dupe(u8, ""),
                                                    .arguments = try self.allocator.dupe(u8, ""),
                                                },
                                            });
                                        }

                                        // Update the accumulated tool call
                                        var tc = &accumulated_tool_calls.items[index];

                                        if (tc_delta.id) |id| {
                                            if (tc.id) |old_id| self.allocator.free(old_id);
                                            tc.id = try self.allocator.dupe(u8, id);
                                        }

                                        if (tc_delta.type) |tc_type| {
                                            if (tc.type) |old_type| self.allocator.free(old_type);
                                            tc.type = try self.allocator.dupe(u8, tc_type);
                                        }

                                        if (tc_delta.function) |func| {
                                            if (func.name) |name| {
                                                const old_name = tc.function.name;
                                                tc.function.name = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{old_name, name});
                                                self.allocator.free(old_name);
                                            }

                                            if (func.arguments) |args| {
                                                const old_args = tc.function.arguments;
                                                tc.function.arguments = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{old_args, args});
                                                self.allocator.free(old_args);
                                            }
                                        }
                                    }
                                }
                            }

                            // Check if this is the final chunk with finish_reason
                            if (choices[0].finish_reason) |reason| {
                                if (std.mem.eql(u8, reason, "tool_calls")) {
                                    // Send accumulated tool calls (transfer ownership to callback)
                                    if (accumulated_tool_calls.items.len > 0) {
                                        const owned_calls = try accumulated_tool_calls.toOwnedSlice(self.allocator);
                                        callback(context, null, null, owned_calls);
                                        // toOwnedSlice() already emptied the ArrayList
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // If we accumulated tool calls but never got a finish_reason, send them now
        if (accumulated_tool_calls.items.len > 0) {
            const owned_calls = try accumulated_tool_calls.toOwnedSlice(self.allocator);
            callback(context, null, null, owned_calls);
        }
    }
};

/// LM Studio Embeddings Client (OpenAI-compatible)
pub const LMStudioEmbeddingsClient = struct {
    allocator: mem.Allocator,
    client: http.Client,
    base_url: []const u8,

    pub fn init(allocator: mem.Allocator, base_url: []const u8) LMStudioEmbeddingsClient {
        return .{
            .allocator = allocator,
            .client = http.Client{ .allocator = allocator },
            .base_url = base_url,
        };
    }

    pub fn deinit(self: *LMStudioEmbeddingsClient) void {
        self.client.deinit();
    }

    /// Generate embedding for a single text
    pub fn embed(
        self: *LMStudioEmbeddingsClient,
        model: []const u8,
        text: []const u8,
    ) ![]f32 {
        // Build JSON payload
        var payload_list = std.ArrayListUnmanaged(u8){};
        defer payload_list.deinit(self.allocator);

        try payload_list.appendSlice(self.allocator, "{\"model\":\"");
        try payload_list.appendSlice(self.allocator, model);
        try payload_list.appendSlice(self.allocator, "\",\"input\":\"");

        // Escape text
        for (text) |c| {
            if (c == '"') {
                try payload_list.appendSlice(self.allocator, "\\\"");
            } else if (c == '\\') {
                try payload_list.appendSlice(self.allocator, "\\\\");
            } else if (c == '\n') {
                try payload_list.appendSlice(self.allocator, "\\n");
            } else if (c == '\r') {
                try payload_list.appendSlice(self.allocator, "\\r");
            } else if (c == '\t') {
                try payload_list.appendSlice(self.allocator, "\\t");
            } else {
                try payload_list.append(self.allocator, c);
            }
        }

        try payload_list.appendSlice(self.allocator, "\"}");
        const payload = try payload_list.toOwnedSlice(self.allocator);
        defer self.allocator.free(payload);

        // Try with retry logic for stale connections
        return self.embedImpl(payload) catch |err| {
            if (err == error.EndOfStream or err == error.ConnectionResetByPeer) {
                if (std.posix.getenv("DEBUG_EMBEDDINGS")) |_| {
                    std.debug.print("[DEBUG] Connection error, recreating client and retrying...\n", .{});
                }

                // Recreate HTTP client to clear stale connection pool
                self.client.deinit();
                self.client = http.Client{ .allocator = self.allocator };

                std.Thread.sleep(100 * std.time.ns_per_ms);

                // Retry once
                return self.embedImpl(payload) catch |retry_err| {
                    std.debug.print("\n❌ Failed to connect to LM Studio after retry: {s}\n\n", .{@errorName(retry_err)});
                    return retry_err;
                };
            }
            return err;
        };
    }

    /// Generate embeddings for multiple texts (batch)
    pub fn embedBatch(
        self: *LMStudioEmbeddingsClient,
        model: []const u8,
        texts: []const []const u8,
    ) ![][]f32 {
        // Build JSON payload
        var payload_list = std.ArrayListUnmanaged(u8){};
        defer payload_list.deinit(self.allocator);

        try payload_list.appendSlice(self.allocator, "{\"model\":\"");
        try payload_list.appendSlice(self.allocator, model);
        try payload_list.appendSlice(self.allocator, "\",\"input\":[");

        for (texts, 0..) |text, i| {
            if (i > 0) try payload_list.append(self.allocator, ',');
            try payload_list.append(self.allocator, '"');

            // Escape text
            for (text) |c| {
                if (c == '"') {
                    try payload_list.appendSlice(self.allocator, "\\\"");
                } else if (c == '\\') {
                    try payload_list.appendSlice(self.allocator, "\\\\");
                } else if (c == '\n') {
                    try payload_list.appendSlice(self.allocator, "\\n");
                } else if (c == '\r') {
                    try payload_list.appendSlice(self.allocator, "\\r");
                } else if (c == '\t') {
                    try payload_list.appendSlice(self.allocator, "\\t");
                } else {
                    try payload_list.append(self.allocator, c);
                }
            }
            try payload_list.append(self.allocator, '"');
        }

        try payload_list.appendSlice(self.allocator, "]}");
        const payload = try payload_list.toOwnedSlice(self.allocator);
        defer self.allocator.free(payload);

        // Try with retry logic for stale connections
        return self.embedBatchImpl(payload) catch |err| {
            if (err == error.EndOfStream or err == error.ConnectionResetByPeer) {
                if (std.posix.getenv("DEBUG_EMBEDDINGS")) |_| {
                    std.debug.print("[DEBUG] Connection error, recreating client and retrying...\n", .{});
                }

                // Recreate HTTP client to clear stale connection pool
                self.client.deinit();
                self.client = http.Client{ .allocator = self.allocator };

                std.Thread.sleep(100 * std.time.ns_per_ms);

                // Retry once
                return self.embedBatchImpl(payload) catch |retry_err| {
                    std.debug.print("\n❌ Failed to connect to LM Studio after retry: {s}\n\n", .{@errorName(retry_err)});
                    return retry_err;
                };
            }
            return err;
        };
    }

    fn embedImpl(self: *LMStudioEmbeddingsClient, payload: []const u8) ![]f32 {
        if (std.posix.getenv("DEBUG_EMBEDDINGS")) |_| {
            std.debug.print("\n=== DEBUG: LM Studio Embeddings Request ===\n", .{});
            std.debug.print("URL: {s}/v1/embeddings\n", .{self.base_url});
            std.debug.print("Payload: {s}\n", .{payload});
            std.debug.print("=== END ===\n\n", .{});
        }

        const full_url = try std.fmt.allocPrint(self.allocator, "{s}/v1/embeddings", .{self.base_url});
        defer self.allocator.free(full_url);
        const uri = try std.Uri.parse(full_url);

        const headers_buffer = try self.allocator.alloc(http.Header, 2);
        defer self.allocator.free(headers_buffer);
        headers_buffer[0] = .{ .name = "content-type", .value = "application/json" };
        headers_buffer[1] = .{ .name = "accept", .value = "application/json" };

        var req = try self.client.request(.POST, uri, .{
            .extra_headers = headers_buffer,
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = payload.len };

        var body = try req.sendBodyUnflushed(&.{});
        try body.writer.writeAll(payload);
        try body.end();
        try req.connection.?.flush();

        const redirect_buffer = try self.allocator.alloc(u8, 8 * 1024);
        defer self.allocator.free(redirect_buffer);
        const response = try req.receiveHead(redirect_buffer);

        if (response.head.status != .ok) {
            // Try to read and parse error body
            var error_body = std.ArrayListUnmanaged(u8){};
            defer error_body.deinit(self.allocator);

            const conn_reader = req.connection.?.reader();
            var error_read_buffer: [4096]u8 = undefined;
            while (true) {
                var read_vec = [_][]u8{&error_read_buffer};
                const bytes_read = conn_reader.*.readVec(&read_vec) catch break;
                if (bytes_read == 0) break;
                error_body.appendSlice(self.allocator, error_read_buffer[0..bytes_read]) catch break;
            }

            if (error_body.items.len > 0) {
                // Try to parse as OpenAI error format
                const error_parsed = json.parseFromSlice(
                    OpenAIErrorResponse,
                    self.allocator,
                    error_body.items,
                    .{ .ignore_unknown_fields = true },
                ) catch {
                    std.debug.print("\n❌ LM Studio API error (status {})\n", .{response.head.status});
                    std.debug.print("   Response: {s}\n\n", .{error_body.items});
                    return error.EmbeddingAPIError;
                };
                defer error_parsed.deinit();

                std.debug.print("\n❌ LM Studio API error: {s}\n", .{error_parsed.value.@"error".message});

                // Check for specific known errors and provide guidance
                if (std.mem.indexOf(u8, error_parsed.value.@"error".message, "not embedding") != null or
                    std.mem.indexOf(u8, error_parsed.value.@"error".message, "model_not_found") != null)
                {
                    std.debug.print("💡 Make sure you've loaded an embedding model in LM Studio!\n", .{});
                    std.debug.print("   1. Download a BERT/nomic-bert model\n", .{});
                    std.debug.print("   2. Load it in 'Embedding Model Settings'\n", .{});
                    std.debug.print("   3. Restart the server\n\n", .{});
                }

                return error.EmbeddingAPIError;
            }

            // No error body available
            std.debug.print("\n❌ LM Studio returned status {}\n\n", .{response.head.status});
            return error.BadStatus;
        }

        // Read response body manually (like Ollama implementation)
        var response_body = std.ArrayListUnmanaged(u8){};
        defer response_body.deinit(self.allocator);

        const conn_reader = req.connection.?.reader();
        var read_buffer: [16384]u8 = undefined;

        while (true) {
            var read_vec = [_][]u8{&read_buffer};
            const bytes_read = conn_reader.*.readVec(&read_vec) catch break;
            if (bytes_read == 0) break;
            try response_body.appendSlice(self.allocator, read_buffer[0..bytes_read]);
        }

        // Parse OpenAI embeddings response
        const parsed = try json.parseFromSlice(
            OpenAIEmbeddingResponse,
            self.allocator,
            response_body.items,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();

        // Extract first embedding and return owned copy
        if (parsed.value.data.len == 0) return error.NoEmbedding;
        return try self.allocator.dupe(f32, parsed.value.data[0].embedding);
    }

    fn embedBatchImpl(self: *LMStudioEmbeddingsClient, payload: []const u8) ![][]f32 {
        const full_url = try std.fmt.allocPrint(self.allocator, "{s}/v1/embeddings", .{self.base_url});
        defer self.allocator.free(full_url);
        const uri = try std.Uri.parse(full_url);

        const headers_buffer = try self.allocator.alloc(http.Header, 2);
        defer self.allocator.free(headers_buffer);
        headers_buffer[0] = .{ .name = "content-type", .value = "application/json" };
        headers_buffer[1] = .{ .name = "accept", .value = "application/json" };

        var req = try self.client.request(.POST, uri, .{
            .extra_headers = headers_buffer,
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = payload.len };

        var body = try req.sendBodyUnflushed(&.{});
        try body.writer.writeAll(payload);
        try body.end();
        try req.connection.?.flush();

        const redirect_buffer = try self.allocator.alloc(u8, 8 * 1024);
        defer self.allocator.free(redirect_buffer);
        const response = try req.receiveHead(redirect_buffer);

        if (response.head.status != .ok) {
            // Try to read and parse error body (same as embedImpl)
            var error_body = std.ArrayListUnmanaged(u8){};
            defer error_body.deinit(self.allocator);

            const conn_reader = req.connection.?.reader();
            var error_read_buffer: [4096]u8 = undefined;
            while (true) {
                var read_vec = [_][]u8{&error_read_buffer};
                const bytes_read = conn_reader.*.readVec(&read_vec) catch break;
                if (bytes_read == 0) break;
                error_body.appendSlice(self.allocator, error_read_buffer[0..bytes_read]) catch break;
            }

            if (error_body.items.len > 0) {
                const error_parsed = json.parseFromSlice(
                    OpenAIErrorResponse,
                    self.allocator,
                    error_body.items,
                    .{ .ignore_unknown_fields = true },
                ) catch {
                    std.debug.print("\n❌ LM Studio API error (status {})\n", .{response.head.status});
                    std.debug.print("   Response: {s}\n\n", .{error_body.items});
                    return error.EmbeddingAPIError;
                };
                defer error_parsed.deinit();

                std.debug.print("\n❌ LM Studio API error: {s}\n", .{error_parsed.value.@"error".message});

                if (std.mem.indexOf(u8, error_parsed.value.@"error".message, "not embedding") != null or
                    std.mem.indexOf(u8, error_parsed.value.@"error".message, "model_not_found") != null)
                {
                    std.debug.print("💡 Make sure you've loaded an embedding model in LM Studio!\n", .{});
                    std.debug.print("   1. Download a BERT/nomic-bert model\n", .{});
                    std.debug.print("   2. Load it in 'Embedding Model Settings'\n", .{});
                    std.debug.print("   3. Restart the server\n\n", .{});
                }

                return error.EmbeddingAPIError;
            }

            std.debug.print("\n❌ LM Studio returned status {}\n\n", .{response.head.status});
            return error.BadStatus;
        }

        // Read response body manually (like Ollama implementation)
        var response_body = std.ArrayListUnmanaged(u8){};
        defer response_body.deinit(self.allocator);

        const conn_reader = req.connection.?.reader();
        var read_buffer: [16384]u8 = undefined;

        while (true) {
            var read_vec = [_][]u8{&read_buffer};
            const bytes_read = conn_reader.*.readVec(&read_vec) catch break;
            if (bytes_read == 0) break;
            try response_body.appendSlice(self.allocator, read_buffer[0..bytes_read]);
        }

        // Parse OpenAI embeddings response
        const parsed = try json.parseFromSlice(
            OpenAIEmbeddingResponse,
            self.allocator,
            response_body.items,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();

        // Extract all embeddings and return owned copies
        const result = try self.allocator.alloc([]f32, parsed.value.data.len);
        for (parsed.value.data, 0..) |data, i| {
            result[i] = try self.allocator.dupe(f32, data.embedding);
        }
        return result;
    }
};
