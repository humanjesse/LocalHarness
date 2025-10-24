// Embeddings API client for Ollama - using Zig 0.15.2 std.http
const std = @import("std");
const http = std.http;
const json = std.json;
const mem = std.mem;

// Response from Ollama embeddings API (single text)
// NOTE: Ollama API returns "embeddings" (plural) as array of arrays even for single text
const EmbeddingResponse = struct {
    model: []const u8 = "",
    embeddings: ?[][]f32 = null,  // Array of arrays, even for single text
};

// Response from Ollama embeddings API (batch)
const BatchEmbeddingResponse = struct {
    model: []const u8 = "",
    embeddings: ?[][]f32 = null,
};

// Error response from Ollama API
const ErrorResponse = struct {
    @"error": []const u8,
};

pub const EmbeddingsClient = struct {
    allocator: mem.Allocator,
    client: http.Client,
    base_url: []const u8,
    endpoint: []const u8,

    pub fn init(allocator: mem.Allocator, base_url: []const u8) EmbeddingsClient {
        return .{
            .allocator = allocator,
            .client = http.Client{ .allocator = allocator },
            .base_url = base_url,
            .endpoint = "/api/embed",
        };
    }

    pub fn deinit(self: *EmbeddingsClient) void {
        self.client.deinit();
    }

    /// Generate embedding for a single text
    /// Returns owned slice of f32 - caller must free
    pub fn embed(
        self: *EmbeddingsClient,
        model: []const u8,
        text: []const u8,
    ) ![]f32 {
        // Build JSON payload manually
        var payload_list = std.ArrayListUnmanaged(u8){};
        defer payload_list.deinit(self.allocator);

        try payload_list.appendSlice(self.allocator, "{\"model\":\"");
        try payload_list.appendSlice(self.allocator, model);
        try payload_list.appendSlice(self.allocator, "\",\"input\":\"");

        // Escape special characters in text
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

        // DEBUG: Print request payload
        if (std.posix.getenv("DEBUG_EMBEDDINGS")) |_| {
            std.debug.print("\n=== DEBUG: Embeddings Request ===\n{s}\n=== END ===\n", .{payload});
        }

        // Try making the request with retry logic for stale connections
        return self.embedImpl(payload) catch |err| {
            // Handle stale connection errors with retry
            if (err == error.EndOfStream or err == error.ConnectionResetByPeer) {
                if (std.posix.getenv("DEBUG_EMBEDDINGS")) |_| {
                    std.debug.print("Connection failed: {s} - Retrying...\n", .{@errorName(err)});
                }

                // Recreate HTTP client to clear stale connection pool
                self.client.deinit();
                self.client = http.Client{ .allocator = self.allocator };

                // Small delay before retry
                std.Thread.sleep(100 * std.time.ns_per_ms);

                // Retry the request
                return self.embedImpl(payload) catch |retry_err| {
                    std.debug.print("Failed to connect to Ollama embeddings API: {s}\n", .{@errorName(retry_err)});
                    return retry_err;
                };
            }
            return err;
        };
    }

    /// Internal implementation of embed - separated for retry logic
    fn embedImpl(self: *EmbeddingsClient, payload: []const u8) ![]f32 {
        if (std.posix.getenv("DEBUG_EMBEDDINGS")) |_| {
            std.debug.print("=== DEBUG: embedImpl starting...\n", .{});
        }
        // Build full URL and parse
        const full_url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, self.endpoint });
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
        const response = try req.receiveHead(redirect_buffer);

        if (response.head.status != .ok) {
            return error.BadStatus;
        }

        // Read response body (handles both Content-Length and chunked encoding)
        var response_body = std.ArrayListUnmanaged(u8){};
        defer response_body.deinit(self.allocator);

        const conn_reader = req.connection.?.reader();
        var read_buffer: [16384]u8 = undefined;

        // Read all available data
        while (true) {
            var read_vec = [_][]u8{&read_buffer};
            const bytes_read = conn_reader.*.readVec(&read_vec) catch break;
            if (bytes_read == 0) break;

            try response_body.appendSlice(self.allocator, read_buffer[0..bytes_read]);

            // Check if we have complete JSON response
            if (response_body.items.len > 0) {
                // Find the start of JSON (skip chunk size if present)
                var json_start: usize = 0;
                for (response_body.items, 0..) |c, i| {
                    if (c == '{') {
                        json_start = i;
                        break;
                    }
                }

                // Find the end of JSON
                var json_end: ?usize = null;
                if (json_start > 0 or response_body.items[0] == '{') {
                    for (0..response_body.items.len) |_i| {
                        const i = response_body.items.len - 1 - _i;
                        if (response_body.items[i] == '}') {
                            json_end = i + 1;
                            break;
                        }
                    }
                }

                // If we have complete JSON, stop reading
                if (json_end != null) {
                    break;
                }
            }
        }

        // Extract JSON from response (handles chunked encoding)
        var json_start: usize = 0;
        for (response_body.items, 0..) |c, i| {
            if (c == '{') {
                json_start = i;
                break;
            }
        }

        var json_end: usize = response_body.items.len;
        for (0..response_body.items.len) |_i| {
            const i = response_body.items.len - 1 - _i;
            if (response_body.items[i] == '}') {
                json_end = i + 1;
                break;
            }
        }

        // Use only the JSON portion for parsing
        const json_data = response_body.items[json_start..json_end];

        if (std.posix.getenv("DEBUG_EMBEDDINGS")) |_| {
            std.debug.print("=== DEBUG: Extracted JSON ({d} bytes) ===\n", .{json_data.len});
        }

        // Check for error response first
        if (mem.indexOf(u8, json_data, "\"error\"") != null) {
            const error_parsed = json.parseFromSlice(
                ErrorResponse,
                self.allocator,
                json_data,
                .{},
            ) catch {
                std.debug.print("Failed to parse error response: {s}\n", .{json_data});
                return error.EmbeddingAPIError;
            };
            defer error_parsed.deinit();
            std.debug.print("Ollama embedding API error: {s}\n", .{error_parsed.value.@"error"});
            return error.EmbeddingAPIError;
        }

        // Parse JSON response (ignoring unknown fields since API response varies)
        const parsed = try json.parseFromSlice(
            EmbeddingResponse,
            self.allocator,
            json_data,
            .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            },
        );
        defer parsed.deinit();

        // Check if embeddings array is present
        const embeddings_array = parsed.value.embeddings orelse {
            std.debug.print("No embeddings in response\n", .{});
            return error.NoEmbeddingInResponse;
        };

        if (embeddings_array.len == 0) {
            std.debug.print("Empty embeddings array in response\n", .{});
            return error.NoEmbeddingInResponse;
        }

        // Get the first embedding from the array
        const embedding_data = embeddings_array[0];
        if (embedding_data.len == 0) {
            std.debug.print("Empty embedding vector in response\n", .{});
            return error.NoEmbeddingInResponse;
        }

        // Copy embedding (parseFromSlice owns the memory, we need to dupe)
        const embedding = try self.allocator.dupe(f32, embedding_data);

        return embedding;
    }

    /// Generate embeddings for multiple texts
    /// NOTE: Ollama doesn't support batch embeddings, so we make multiple requests
    /// Returns owned slice of embedding slices - caller must free all
    pub fn embedBatch(
        self: *EmbeddingsClient,
        model: []const u8,
        texts: []const []const u8,
    ) ![][]f32 {
        if (texts.len == 0) return try self.allocator.alloc([]f32, 0);

        // Ollama supports batch embeddings with array input
        // Build JSON payload: {"model": "...", "input": ["text1", "text2", ...]}
        var payload_list = std.ArrayListUnmanaged(u8){};
        defer payload_list.deinit(self.allocator);

        try payload_list.appendSlice(self.allocator, "{\"model\":\"");
        try payload_list.appendSlice(self.allocator, model);
        try payload_list.appendSlice(self.allocator, "\",\"input\":[");

        for (texts, 0..) |text, i| {
            try payload_list.append(self.allocator, '"');

            // Escape special characters in text
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
            if (i < texts.len - 1) {
                try payload_list.append(self.allocator, ',');
            }
        }

        try payload_list.appendSlice(self.allocator, "]}");

        const payload = try payload_list.toOwnedSlice(self.allocator);
        defer self.allocator.free(payload);

        if (std.posix.getenv("DEBUG_EMBEDDINGS")) |_| {
            std.debug.print("\n=== DEBUG: Batch Embeddings Request ({d} texts) ===\n", .{texts.len});
        }

        // Try making the request with retry logic for stale connections
        return self.embedBatchImpl(payload) catch |err| {
            // Handle stale connection errors with retry
            if (err == error.EndOfStream or err == error.ConnectionResetByPeer) {
                if (std.posix.getenv("DEBUG_EMBEDDINGS")) |_| {
                    std.debug.print("Connection failed: {s} - Retrying...\n", .{@errorName(err)});
                }

                // Recreate HTTP client to clear stale connection pool
                self.client.deinit();
                self.client = http.Client{ .allocator = self.allocator };

                // Small delay before retry
                std.Thread.sleep(100 * std.time.ns_per_ms);

                // Retry the request
                return self.embedBatchImpl(payload) catch |retry_err| {
                    std.debug.print("Failed to connect to Ollama embeddings API: {s}\n", .{@errorName(retry_err)});
                    return retry_err;
                };
            }
            return err;
        };
    }

    /// Internal implementation of embedBatch - separated for retry logic
    fn embedBatchImpl(self: *EmbeddingsClient, payload: []const u8) ![][]f32 {
        // Build full URL and parse
        const full_url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, self.endpoint });
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
        const response = try req.receiveHead(redirect_buffer);

        if (response.head.status != .ok) {
            return error.BadStatus;
        }

        // Read response body (handles both Content-Length and chunked encoding)
        var response_body = std.ArrayListUnmanaged(u8){};
        defer response_body.deinit(self.allocator);

        const conn_reader = req.connection.?.reader();
        var read_buffer: [16384]u8 = undefined;

        // Read all available data
        while (true) {
            var read_vec = [_][]u8{&read_buffer};
            const bytes_read = conn_reader.*.readVec(&read_vec) catch break;
            if (bytes_read == 0) break;

            try response_body.appendSlice(self.allocator, read_buffer[0..bytes_read]);

            // Check if we have complete JSON response
            if (response_body.items.len > 0) {
                // Find the start of JSON (skip chunk size if present)
                var json_start: usize = 0;
                for (response_body.items, 0..) |c, i| {
                    if (c == '{') {
                        json_start = i;
                        break;
                    }
                }

                // Find the end of JSON
                var json_end: ?usize = null;
                if (json_start > 0 or response_body.items[0] == '{') {
                    for (0..response_body.items.len) |_i| {
                        const i = response_body.items.len - 1 - _i;
                        if (response_body.items[i] == '}') {
                            json_end = i + 1;
                            break;
                        }
                    }
                }

                // If we have complete JSON, stop reading
                if (json_end != null) {
                    break;
                }
            }
        }

        // Extract JSON from response (handles chunked encoding)
        var json_start: usize = 0;
        for (response_body.items, 0..) |c, i| {
            if (c == '{') {
                json_start = i;
                break;
            }
        }

        var json_end: usize = response_body.items.len;
        for (0..response_body.items.len) |_i| {
            const i = response_body.items.len - 1 - _i;
            if (response_body.items[i] == '}') {
                json_end = i + 1;
                break;
            }
        }

        // Use only the JSON portion for parsing
        const json_data = response_body.items[json_start..json_end];

        if (std.posix.getenv("DEBUG_EMBEDDINGS")) |_| {
            const preview_len = @min(json_data.len, 200);
            std.debug.print("=== DEBUG: Batch Response (first {d} bytes) ===\n{s}...\n", .{ preview_len, json_data[0..preview_len] });
        }

        // Check for error response first
        if (mem.indexOf(u8, json_data, "\"error\"") != null) {
            const error_parsed = json.parseFromSlice(
                ErrorResponse,
                self.allocator,
                json_data,
                .{},
            ) catch {
                std.debug.print("Failed to parse error response: {s}\n", .{json_data});
                return error.EmbeddingAPIError;
            };
            defer error_parsed.deinit();
            std.debug.print("Ollama embedding API error: {s}\n", .{error_parsed.value.@"error"});
            return error.EmbeddingAPIError;
        }

        // Parse batch response (for batch requests, the API returns the same format)
        const parsed = try json.parseFromSlice(
            BatchEmbeddingResponse,
            self.allocator,
            json_data,
            .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            },
        );
        defer parsed.deinit();

        // Check if embeddings are present
        const embeddings_array = parsed.value.embeddings orelse {
            std.debug.print("No embeddings in batch response\n", .{});
            return error.NoEmbeddingInResponse;
        };

        // Copy embeddings (parseFromSlice owns the memory, we need to dupe)
        const result = try self.allocator.alloc([]f32, embeddings_array.len);
        errdefer {
            for (result, 0..) |emb, i| {
                if (i < embeddings_array.len) self.allocator.free(emb);
            }
            self.allocator.free(result);
        }

        for (embeddings_array, 0..) |emb, i| {
            result[i] = try self.allocator.dupe(f32, emb);
        }

        if (std.posix.getenv("DEBUG_EMBEDDINGS")) |_| {
            std.debug.print("=== Batch embeddings successful: {d} embeddings generated ===\n", .{result.len});
        }

        return result;
    }
};

// Helper function to compute cosine similarity between two embeddings
pub fn cosineSimilarity(a: []const f32, b: []const f32) f32 {
    if (a.len != b.len) return 0.0;

    var dot_product: f32 = 0.0;
    var norm_a: f32 = 0.0;
    var norm_b: f32 = 0.0;

    for (a, b) |av, bv| {
        dot_product += av * bv;
        norm_a += av * av;
        norm_b += bv * bv;
    }

    const denominator = @sqrt(norm_a) * @sqrt(norm_b);
    if (denominator == 0.0) return 0.0;

    return dot_product / denominator;
}
