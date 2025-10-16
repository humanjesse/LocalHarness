// Ollama API client for chat - using Zig 0.15.2 fetch API
const std = @import("std");
const http = std.http;
const json = std.json;
const mem = std.mem;

pub const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
};

const ChatResponse = struct {
    model: []const u8 = "",
    message: ?struct {
        role: []const u8,
        content: []const u8,
        thinking: ?[]const u8 = null,
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

    pub fn chat(
        self: *OllamaClient,
        model: []const u8,
        messages: []const ChatMessage,
    ) ![]const u8 {
        // Build JSON payload manually
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
            try payload_list.appendSlice(self.allocator, "\"}");
        }

        try payload_list.appendSlice(self.allocator, "],\"stream\":false}");

        const payload = try payload_list.toOwnedSlice(self.allocator);
        defer self.allocator.free(payload);

        // Build URL
        var url_buffer: [256]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}{s}", .{self.base_url, self.endpoint});

        // For MVP, just use curl for now - we'll refactor to proper HTTP later
        // This avoids fighting with Zig 0.15.2's new IO system
        var curl_cmd = std.ArrayList(u8).initCapacity(self.allocator, 512) catch unreachable;
        defer curl_cmd.deinit(self.allocator);

        const writer = curl_cmd.writer(self.allocator);
        try writer.print("curl -s -X POST '{s}' -H 'Content-Type: application/json' -d '{s}'", .{ url, payload });

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "sh", "-c", curl_cmd.items },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            return error.RequestFailed;
        }

        // Parse response
        const parsed = try json.parseFromSlice(
            ChatResponse,
            self.allocator,
            result.stdout,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();

        if (parsed.value.message) |msg| {
            return try self.allocator.dupe(u8, msg.content);
        }

        return error.NoMessageInResponse;
    }

    // Streaming chat with callback for each chunk
    pub fn chatStream(
        self: *OllamaClient,
        model: []const u8,
        messages: []const ChatMessage,
        think: bool,
        context: anytype,
        callback: fn (ctx: @TypeOf(context), thinking_chunk: ?[]const u8, content_chunk: ?[]const u8) void,
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
            try payload_list.appendSlice(self.allocator, "\"}");
        }

        try payload_list.appendSlice(self.allocator, "],\"stream\":true");
        if (think) {
            try payload_list.appendSlice(self.allocator, ",\"think\":true");
        }
        try payload_list.appendSlice(self.allocator, "}");

        const payload = try payload_list.toOwnedSlice(self.allocator);
        defer self.allocator.free(payload);

        // Build URL
        var url_buffer: [256]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}{s}", .{self.base_url, self.endpoint});

        // Use curl with streaming - process line by line
        var curl_cmd = std.ArrayList(u8).initCapacity(self.allocator, 512) catch unreachable;
        defer curl_cmd.deinit(self.allocator);

        const writer = curl_cmd.writer(self.allocator);
        try writer.print("curl -s -N -X POST '{s}' -H 'Content-Type: application/json' -d '{s}'", .{ url, payload });

        // Spawn curl process and read streaming output
        var child = std.process.Child.init(&[_][]const u8{ "sh", "-c", curl_cmd.items }, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Close;

        try child.spawn();
        defer {
            _ = child.wait() catch {};
        }

        // Read streaming response line by line
        const stdout = child.stdout.?;
        var line_buffer = std.ArrayListUnmanaged(u8){};
        defer line_buffer.deinit(self.allocator);

        var read_buffer: [4096]u8 = undefined;
        while (true) {
            const bytes_read = try stdout.read(&read_buffer);
            if (bytes_read == 0) break;

            var start: usize = 0;
            for (read_buffer[0..bytes_read], 0..) |byte, i| {
                if (byte == '\n') {
                    // Found complete line - append what we have before newline
                    try line_buffer.appendSlice(self.allocator, read_buffer[start..i]);

                    // Process the line if it's not empty
                    if (line_buffer.items.len > 0) {
                        // Parse JSON line
                        const parsed = json.parseFromSlice(
                            ChatResponse,
                            self.allocator,
                            line_buffer.items,
                            .{ .ignore_unknown_fields = true },
                        ) catch {
                            line_buffer.clearRetainingCapacity();
                            start = i + 1;
                            continue;
                        };
                        defer parsed.deinit();

                        // Extract thinking and content from message field
                        if (parsed.value.message) |msg| {
                            const thinking_chunk = if (msg.thinking) |t| if (t.len > 0) t else null else null;
                            const content_chunk = if (msg.content.len > 0) msg.content else null;

                            // Only call callback if there's something to report
                            if (thinking_chunk != null or content_chunk != null) {
                                callback(context, thinking_chunk, content_chunk);
                            }
                        }

                        // Check if done
                        if (parsed.value.done) break;
                    }

                    line_buffer.clearRetainingCapacity();
                    start = i + 1;
                }
            }

            // Append remaining bytes to buffer (incomplete line)
            if (start < bytes_read) {
                try line_buffer.appendSlice(self.allocator, read_buffer[start..bytes_read]);
            }
        }
    }
};
