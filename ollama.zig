// Ollama API client for chat - using Zig 0.15.2 std.http
const std = @import("std");
const http = std.http;
const json = std.json;
const mem = std.mem;

// Tool definition structures (OpenAI format, compatible with Ollama)
pub const ToolFunction = struct {
    name: []const u8,
    description: []const u8,
    parameters: []const u8, // JSON schema string for parameters
};

pub const Tool = struct {
    type: []const u8 = "function",
    function: ToolFunction,
};

// Tool call from model response
pub const ToolCall = struct {
    id: ?[]const u8 = null,  // Optional - we'll generate if not provided
    type: ?[]const u8 = null,  // Optional - defaults to "function"
    function: struct {
        name: []const u8,
        arguments: []const u8, // JSON string
    },
};

pub const ChatMessage = struct {
    role: []const u8, // "user", "assistant", "system", or "tool"
    content: []const u8,
    tool_call_id: ?[]const u8 = null, // Required when role is "tool"
    tool_calls: ?[]ToolCall = null, // Present when assistant calls tools
};

// Internal struct for parsing Ollama responses
// Ollama sends arguments as a JSON object, not a string
const ChatResponseRaw = struct {
    model: []const u8 = "",
    message: ?struct {
        role: []const u8,
        content: []const u8,
        thinking: ?[]const u8 = null,
        tool_calls: ?[]struct {
            id: ?[]const u8 = null,
            type: ?[]const u8 = null,
            function: struct {
                name: []const u8,
                arguments: std.json.Value,  // Accept as JSON value (object or string)
            },
        } = null,
    } = null,
    done: bool = false,
};

const ChatResponse = struct {
    model: []const u8 = "",
    message: ?struct {
        role: []const u8,
        content: []const u8,
        thinking: ?[]const u8 = null,
        tool_calls: ?[]ToolCall = null,
    } = null,
    done: bool = false,
};

pub const OllamaClient = struct {
    allocator: mem.Allocator,
    client: http.Client,
    base_url: []const u8,
    endpoint: []const u8,

    pub fn init(allocator: mem.Allocator, base_url: []const u8, endpoint: []const u8) OllamaClient {
        return .{
            .allocator = allocator,
            .client = http.Client{ .allocator = allocator },
            .base_url = base_url,
            .endpoint = endpoint,
        };
    }

    pub fn deinit(self: *OllamaClient) void {
        self.client.deinit();
    }

    // Streaming chat with callback for each chunk
    pub fn chatStream(
        self: *OllamaClient,
        model: []const u8,
        messages: []const ChatMessage,
        think: bool,
        format: ?[]const u8,
        tools: ?[]const Tool,
        keep_alive: ?[]const u8,
        num_ctx: ?usize,
        num_predict: ?isize,
        context: anytype,
        callback: fn (ctx: @TypeOf(context), thinking_chunk: ?[]const u8, content_chunk: ?[]const u8, tool_calls_chunk: ?[]const ToolCall) void,
    ) !void {
        // Build JSON payload manually with stream: true
        var payload_list = std.ArrayListUnmanaged(u8){};
        defer payload_list.deinit(self.allocator);

        try payload_list.appendSlice(self.allocator, "{\"model\":\"");
        try payload_list.appendSlice(self.allocator, model);
        try payload_list.appendSlice(self.allocator, "\",\"messages\":[");

        for (messages, 0..) |msg, i| {
            if (i > 0) try payload_list.append(self.allocator, ',');
            try payload_list.appendSlice(self.allocator, "{\"role\":\"");
            try payload_list.appendSlice(self.allocator, msg.role);
            try payload_list.appendSlice(self.allocator, "\",\"content\":\"");
            // Escape special characters
            for (msg.content) |c| {
                if (c == '"') {
                    try payload_list.appendSlice(self.allocator, "\\\"");
                } else if (c == '\\') {
                    try payload_list.appendSlice(self.allocator, "\\\\");
                } else if (c == '\n') {
                    try payload_list.appendSlice(self.allocator, "\\n");
                } else if (c == '\r') {
                    try payload_list.appendSlice(self.allocator, "\\r");
                } else {
                    try payload_list.append(self.allocator, c);
                }
            }
            try payload_list.appendSlice(self.allocator, "\"");

            // Add tool_call_id for tool role messages
            if (msg.tool_call_id) |tool_id| {
                try payload_list.appendSlice(self.allocator, ",\"tool_call_id\":\"");
                try payload_list.appendSlice(self.allocator, tool_id);
                try payload_list.appendSlice(self.allocator, "\"");
            }

            // Add tool_calls for assistant messages that called tools
            if (msg.tool_calls) |calls| {
                try payload_list.appendSlice(self.allocator, ",\"tool_calls\":[");
                for (calls, 0..) |call, call_idx| {
                    if (call_idx > 0) try payload_list.append(self.allocator, ',');
                    try payload_list.appendSlice(self.allocator, "{");

                    // Add id if present
                    if (call.id) |id| {
                        try payload_list.appendSlice(self.allocator, "\"id\":\"");
                        try payload_list.appendSlice(self.allocator, id);
                        try payload_list.appendSlice(self.allocator, "\",");
                    }

                    // Add type if present
                    if (call.type) |call_type| {
                        try payload_list.appendSlice(self.allocator, "\"type\":\"");
                        try payload_list.appendSlice(self.allocator, call_type);
                        try payload_list.appendSlice(self.allocator, "\",");
                    }

                    try payload_list.appendSlice(self.allocator, "\"function\":{\"name\":\"");
                    try payload_list.appendSlice(self.allocator, call.function.name);
                    try payload_list.appendSlice(self.allocator, "\",\"arguments\":");
                    // Arguments is already a JSON string, append directly
                    try payload_list.appendSlice(self.allocator, call.function.arguments);
                    try payload_list.appendSlice(self.allocator, "}}");
                }
                try payload_list.append(self.allocator, ']');
            }

            try payload_list.append(self.allocator, '}');
        }

        try payload_list.appendSlice(self.allocator, "],\"stream\":true");
        if (think) {
            try payload_list.appendSlice(self.allocator, ",\"think\":true");
        }
        if (format) |fmt| {
            try payload_list.appendSlice(self.allocator, ",\"format\":\"");
            try payload_list.appendSlice(self.allocator, fmt);
            try payload_list.appendSlice(self.allocator, "\"");
        }

        // Add tools if provided
        if (tools) |tool_list| {
            if (tool_list.len > 0) {
                try payload_list.appendSlice(self.allocator, ",\"tools\":[");
                for (tool_list, 0..) |tool, tool_idx| {
                    if (tool_idx > 0) try payload_list.append(self.allocator, ',');

                    // Manually serialize tool JSON
                    try payload_list.appendSlice(self.allocator, "{\"type\":\"");
                    try payload_list.appendSlice(self.allocator, tool.type);
                    try payload_list.appendSlice(self.allocator, "\",\"function\":{\"name\":\"");
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
                    // Append parameters JSON directly (already a JSON string)
                    try payload_list.appendSlice(self.allocator, tool.function.parameters);
                    try payload_list.appendSlice(self.allocator, "}}");
                }
                try payload_list.append(self.allocator, ']');
            }
        }

        // Add keep_alive if provided
        if (keep_alive) |ka| {
            try payload_list.appendSlice(self.allocator, ",\"keep_alive\":\"");
            try payload_list.appendSlice(self.allocator, ka);
            try payload_list.appendSlice(self.allocator, "\"");
        }

        // Add options object for context window and generation settings
        if (num_ctx != null or num_predict != null) {
            try payload_list.appendSlice(self.allocator, ",\"options\":{");
            var first = true;

            if (num_ctx) |ctx| {
                try payload_list.appendSlice(self.allocator, "\"num_ctx\":");
                const ctx_str = try std.fmt.allocPrint(self.allocator, "{d}", .{ctx});
                defer self.allocator.free(ctx_str);
                try payload_list.appendSlice(self.allocator, ctx_str);
                first = false;
            }

            if (num_predict) |pred| {
                if (!first) try payload_list.append(self.allocator, ',');
                try payload_list.appendSlice(self.allocator, "\"num_predict\":");
                const pred_str = try std.fmt.allocPrint(self.allocator, "{d}", .{pred});
                defer self.allocator.free(pred_str);
                try payload_list.appendSlice(self.allocator, pred_str);
            }

            try payload_list.append(self.allocator, '}');
        }

        try payload_list.appendSlice(self.allocator, "}");

        const payload = try payload_list.toOwnedSlice(self.allocator);
        defer self.allocator.free(payload);

        // DEBUG: Print the actual request payload
        if (std.posix.getenv("DEBUG_TOOLS")) |_| {
            std.debug.print("\n=== DEBUG: Request Payload ===\n{s}\n=== END PAYLOAD ===\n\n", .{payload});
        }

        // Build full URL and parse
        const full_url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{self.base_url, self.endpoint});
        defer self.allocator.free(full_url);
        const uri = try std.Uri.parse(full_url);

        // Prepare headers
        const headers_buffer = try self.allocator.alloc(http.Header, 2);
        defer self.allocator.free(headers_buffer);
        headers_buffer[0] = .{ .name = "content-type", .value = "application/json" };
        headers_buffer[1] = .{ .name = "accept", .value = "application/json" };

        // Make HTTP request
        var req = try self.client.request(.POST, uri, .{
            .extra_headers = headers_buffer,
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = payload.len };

        // Send body
        var body = try req.sendBodyUnflushed(&.{});
        try body.writer.writeAll(payload);
        try body.end();
        try req.connection.?.flush();

        // Receive response head
        const redirect_buffer = try self.allocator.alloc(u8, 8 * 1024);
        defer self.allocator.free(redirect_buffer);
        _ = try req.receiveHead(redirect_buffer);

        // WORKAROUND for Zig 0.15.2 HTTP reader bug:
        // Instead of using response.reader() which has state machine bugs,
        // read directly from the connection stream

        var line_buffer = std.ArrayListUnmanaged(u8){};
        defer line_buffer.deinit(self.allocator);

        var read_buffer: [8192]u8 = undefined;
        var stream_done = false;
        var buffer_pos: usize = 0;
        var buffer_end: usize = 0;

        while (!stream_done) {
            // Refill buffer if empty
            if (buffer_pos >= buffer_end) {
                // Read directly from connection, bypassing buggy response.reader()
                const conn_reader = req.connection.?.reader();
                var read_vec = [_][]u8{&read_buffer};
                buffer_end = conn_reader.*.readVec(&read_vec) catch break;
                if (buffer_end == 0) break; // EOF
                buffer_pos = 0;

                // DEBUG: Print bytes received
                if (std.posix.getenv("DEBUG_TOOLS")) |_| {
                    std.debug.print("Received {} bytes from connection\n", .{buffer_end});
                }
            }

            // Process bytes looking for newlines in the buffer
            const current_slice = read_buffer[buffer_pos..buffer_end];
            for (current_slice, 0..) |byte, i| {
                if (byte == '\n') {
                    // Found complete line - append what we have up to newline
                    const absolute_pos = buffer_pos + i;
                    if (buffer_pos < absolute_pos) {
                        try line_buffer.appendSlice(self.allocator, read_buffer[buffer_pos..absolute_pos]);
                    }
                    buffer_pos = absolute_pos + 1; // Skip the newline

                    // Process the line if it's not empty
                    if (line_buffer.items.len > 0) {
                        // Parse JSON line using the raw format
                        const parsed = json.parseFromSlice(
                            ChatResponseRaw,
                            self.allocator,
                            line_buffer.items,
                            .{ .ignore_unknown_fields = true },
                        ) catch {
                            // FALLBACK: Try to salvage the JSON by finding the last valid '}' and trimming garbage
                            // This handles cases where binary data corrupts the end of valid JSON
                            var last_brace: ?usize = null;
                            for (line_buffer.items, 0..) |char, idx| {
                                if (char == '}') last_brace = idx;
                            }

                            if (last_brace) |brace_pos| {
                                // Try parsing just up to the last }
                                const trimmed = line_buffer.items[0..brace_pos + 1];

                                const parsed_retry = json.parseFromSlice(
                                    ChatResponseRaw,
                                    self.allocator,
                                    trimmed,
                                    .{ .ignore_unknown_fields = true },
                                ) catch {
                                    // Last resort: check for done:true in the trimmed string
                                    if (mem.indexOf(u8, trimmed, "\"done\":true") != null) {
                                        stream_done = true;
                                        break;
                                    }

                                    line_buffer.clearRetainingCapacity();
                                    continue;
                                };
                                defer parsed_retry.deinit();

                                // Process this successfully parsed (trimmed) response
                                if (parsed_retry.value.message) |msg| {
                                    const thinking_chunk = if (msg.thinking) |t| if (t.len > 0) t else null else null;
                                    const content_chunk = if (msg.content.len > 0) msg.content else null;

                                    var converted_tool_calls: ?[]ToolCall = null;
                                    if (msg.tool_calls) |raw_calls| {
                                        // ... same tool call conversion logic ...
                                        var calls_list = std.ArrayListUnmanaged(ToolCall){};
                                        defer {
                                            if (converted_tool_calls == null) {
                                                for (calls_list.items) |call| {
                                                    if (call.id) |id| self.allocator.free(id);
                                                    if (call.type) |t| self.allocator.free(t);
                                                    self.allocator.free(call.function.name);
                                                    self.allocator.free(call.function.arguments);
                                                }
                                                calls_list.deinit(self.allocator);
                                            }
                                        }

                                        for (raw_calls) |raw_call| {
                                            const args_str = switch (raw_call.function.arguments) {
                                                .string => |s| self.allocator.dupe(u8, s) catch continue,
                                                .object => |obj| blk: {
                                                    if (obj.count() == 0) {
                                                        break :blk self.allocator.dupe(u8, "{}") catch continue;
                                                    }
                                                    var buf = std.ArrayListUnmanaged(u8){};
                                                    buf.append(self.allocator, '{') catch continue;
                                                    var iter = obj.iterator();
                                                    var first = true;
                                                    while (iter.next()) |entry| {
                                                        if (!first) buf.appendSlice(self.allocator, ",") catch continue;
                                                        first = false;
                                                        buf.appendSlice(self.allocator, "\"") catch continue;
                                                        buf.appendSlice(self.allocator, entry.key_ptr.*) catch continue;
                                                        buf.appendSlice(self.allocator, "\":") catch continue;
                                                        switch (entry.value_ptr.*) {
                                                            .string => |v| {
                                                                buf.appendSlice(self.allocator, "\"") catch continue;
                                                                buf.appendSlice(self.allocator, v) catch continue;
                                                                buf.appendSlice(self.allocator, "\"") catch continue;
                                                            },
                                                            .integer => |v| {
                                                                const int_str = std.fmt.allocPrint(self.allocator, "{d}", .{v}) catch continue;
                                                                defer self.allocator.free(int_str);
                                                                buf.appendSlice(self.allocator, int_str) catch continue;
                                                            },
                                                            .number_string => |v| {
                                                                buf.appendSlice(self.allocator, v) catch continue;
                                                            },
                                                            .bool => |v| {
                                                                buf.appendSlice(self.allocator, if (v) "true" else "false") catch continue;
                                                            },
                                                            .null => {
                                                                buf.appendSlice(self.allocator, "null") catch continue;
                                                            },
                                                            else => buf.appendSlice(self.allocator, "null") catch continue,
                                                        }
                                                    }
                                                    buf.append(self.allocator, '}') catch continue;
                                                    break :blk buf.toOwnedSlice(self.allocator) catch continue;
                                                },
                                                .array => |_| self.allocator.dupe(u8, "[]") catch continue,
                                                else => self.allocator.dupe(u8, "{}") catch continue,
                                            };

                                            const call_id = if (raw_call.id) |id|
                                                self.allocator.dupe(u8, id) catch {
                                                    self.allocator.free(args_str);
                                                    continue;
                                                }
                                            else
                                                null;

                                            const call_type = if (raw_call.type) |t|
                                                self.allocator.dupe(u8, t) catch {
                                                    if (call_id) |id| self.allocator.free(id);
                                                    self.allocator.free(args_str);
                                                    continue;
                                                }
                                            else
                                                null;

                                            const call_name = self.allocator.dupe(u8, raw_call.function.name) catch {
                                                if (call_id) |id| self.allocator.free(id);
                                                if (call_type) |t| self.allocator.free(t);
                                                self.allocator.free(args_str);
                                                continue;
                                            };

                                            const call = ToolCall{
                                                .id = call_id,
                                                .type = call_type,
                                                .function = .{
                                                    .name = call_name,
                                                    .arguments = args_str,
                                                },
                                            };

                                            calls_list.append(self.allocator, call) catch {
                                                if (call.id) |id| self.allocator.free(id);
                                                if (call.type) |t| self.allocator.free(t);
                                                self.allocator.free(call.function.name);
                                                self.allocator.free(call.function.arguments);
                                                continue;
                                            };
                                        }

                                        if (calls_list.items.len > 0) {
                                            converted_tool_calls = calls_list.toOwnedSlice(self.allocator) catch null;
                                        }
                                    }

                                    if (thinking_chunk != null or content_chunk != null or converted_tool_calls != null) {
                                        callback(context, thinking_chunk, content_chunk, converted_tool_calls);
                                    }
                                }

                                // Check if done
                                if (parsed_retry.value.done) {
                                    stream_done = true;
                                    line_buffer.clearRetainingCapacity();
                                    break;
                                }
                            }

                            line_buffer.clearRetainingCapacity();
                            continue;
                        };
                        defer parsed.deinit();

                        // Extract thinking, content, and tool_calls from message field
                        if (parsed.value.message) |msg| {
                            const thinking_chunk = if (msg.thinking) |t| if (t.len > 0) t else null else null;
                            const content_chunk = if (msg.content.len > 0) msg.content else null;

                            // Convert raw tool calls to our format (stringify arguments)
                            var converted_tool_calls: ?[]ToolCall = null;
                            if (msg.tool_calls) |raw_calls| {
                                var calls_list = std.ArrayListUnmanaged(ToolCall){};
                                defer {
                                    // Only free the list if we fail - on success, ownership transfers
                                    if (converted_tool_calls == null) {
                                        for (calls_list.items) |call| {
                                            if (call.id) |id| self.allocator.free(id);
                                            if (call.type) |t| self.allocator.free(t);
                                            self.allocator.free(call.function.name);
                                            self.allocator.free(call.function.arguments);
                                        }
                                        calls_list.deinit(self.allocator);
                                    }
                                }

                                for (raw_calls) |raw_call| {
                                    // Convert arguments JSON value to string
                                    // Ollama sends `arguments: {}` for tools with no parameters
                                    const args_str = switch (raw_call.function.arguments) {
                                        .string => |s| self.allocator.dupe(u8, s) catch continue,
                                        .object => |obj| blk: {
                                            // Manually serialize the object to JSON
                                            if (obj.count() == 0) {
                                                break :blk self.allocator.dupe(u8, "{}") catch continue;
                                            }
                                            // For non-empty objects, build JSON string
                                            var buf = std.ArrayListUnmanaged(u8){};
                                            buf.append(self.allocator, '{') catch continue;
                                            var iter = obj.iterator();
                                            var first = true;
                                            while (iter.next()) |entry| {
                                                if (!first) buf.appendSlice(self.allocator, ",") catch continue;
                                                first = false;
                                                buf.appendSlice(self.allocator, "\"") catch continue;
                                                buf.appendSlice(self.allocator, entry.key_ptr.*) catch continue;
                                                buf.appendSlice(self.allocator, "\":") catch continue;
                                                // For now, assume string values - extend if needed
                                                switch (entry.value_ptr.*) {
                                                    .string => |v| {
                                                        buf.appendSlice(self.allocator, "\"") catch continue;
                                                        buf.appendSlice(self.allocator, v) catch continue;
                                                        buf.appendSlice(self.allocator, "\"") catch continue;
                                                    },
                                                    else => buf.appendSlice(self.allocator, "null") catch continue,
                                                }
                                            }
                                            buf.append(self.allocator, '}') catch continue;
                                            break :blk buf.toOwnedSlice(self.allocator) catch continue;
                                        },
                                        .array => |_| self.allocator.dupe(u8, "[]") catch continue,
                                        else => self.allocator.dupe(u8, "{}") catch continue,
                                    };

                                    // Duplicate optional fields
                                    const call_id = if (raw_call.id) |id|
                                        self.allocator.dupe(u8, id) catch {
                                            self.allocator.free(args_str);
                                            continue;
                                        }
                                    else
                                        null;

                                    const call_type = if (raw_call.type) |t|
                                        self.allocator.dupe(u8, t) catch {
                                            if (call_id) |id| self.allocator.free(id);
                                            self.allocator.free(args_str);
                                            continue;
                                        }
                                    else
                                        null;

                                    const call_name = self.allocator.dupe(u8, raw_call.function.name) catch {
                                        if (call_id) |id| self.allocator.free(id);
                                        if (call_type) |t| self.allocator.free(t);
                                        self.allocator.free(args_str);
                                        continue;
                                    };

                                    const call = ToolCall{
                                        .id = call_id,
                                        .type = call_type,
                                        .function = .{
                                            .name = call_name,
                                            .arguments = args_str,
                                        },
                                    };

                                    calls_list.append(self.allocator, call) catch {
                                        if (call.id) |id| self.allocator.free(id);
                                        if (call.type) |t| self.allocator.free(t);
                                        self.allocator.free(call.function.name);
                                        self.allocator.free(call.function.arguments);
                                        continue;
                                    };
                                }

                                if (calls_list.items.len > 0) {
                                    converted_tool_calls = calls_list.toOwnedSlice(self.allocator) catch null;
                                }
                            }

                            // Only call callback if there's something to report
                            if (thinking_chunk != null or content_chunk != null or converted_tool_calls != null) {
                                // Callback takes ownership of converted_tool_calls
                                callback(context, thinking_chunk, content_chunk, converted_tool_calls);
                            }
                        }

                        // Check if done
                        if (parsed.value.done) {
                            stream_done = true;
                            line_buffer.clearRetainingCapacity();
                            break;
                        }
                    }

                    line_buffer.clearRetainingCapacity();
                }
            }

            // Append any remaining bytes that haven't been processed (incomplete line)
            if (buffer_pos < buffer_end) {
                try line_buffer.appendSlice(self.allocator, read_buffer[buffer_pos..buffer_end]);
                buffer_pos = buffer_end; // Mark as consumed
            }
        }

        // Stream complete - DEBUG
        if (std.posix.getenv("DEBUG_TOOLS")) |_| {
            std.debug.print("Stream completed normally\n", .{});
        }
    }
};
