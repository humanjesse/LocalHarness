# Zig HTTP Client Guide for Zig 0.15.2

This guide explains how to use Zig's `std.http.Client` for making HTTP POST requests with JSON payloads and handling streaming responses, specifically for building an Ollama API client.

## Important: Zig 0.15 Breaking Changes

Zig 0.15 introduced a major HTTP Client API redesign. **The `client.open()` method does not exist** in this version. This guide covers the correct Zig 0.15.2 API.

## Table of Contents

1. [API Overview](#api-overview)
2. [Making POST Requests](#making-post-requests)
3. [Reading Responses](#reading-responses)
4. [Streaming NDJSON](#streaming-ndjson)
5. [Memory Management](#memory-management)
6. [Known Issues](#known-issues)
7. [Migration from 0.14](#migration-from-014)

---

## API Overview

### Key Methods

| Method | Purpose |
|--------|---------|
| `client.request(.POST, uri, .{})` | Create a new request |
| `request.sendBodyComplete(payload)` | Send headers + body in one call |
| `request.sendBodiless()` | For GET/HEAD requests with no body |
| `request.receiveHead(&buffer)` | Receive response headers |
| `request.reader()` | Get response body reader (has bugs, see below) |

### Basic Pattern

```zig
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse("http://localhost:11434/api/generate");

    var request = try client.request(.POST, uri, .{});
    defer request.deinit();

    // Send request...
}
```

---

## Making POST Requests

### Simple POST with JSON

```zig
fn makePostRequest(allocator: std.mem.Allocator) !void {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse("http://localhost:11434/api/generate");

    // Create request
    var request = try client.request(.POST, uri, .{});
    defer request.deinit();

    // Prepare JSON payload (must be mutable []u8, not []const u8)
    var payload = [_]u8{0} ** 256;
    const payload_str = "{\"model\": \"llama3.2\", \"prompt\": \"Hello\"}";
    @memcpy(payload[0..payload_str.len], payload_str);
    const payload_slice = payload[0..payload_str.len];

    // Send the complete body at once
    try request.sendBodyComplete(payload_slice);

    // Receive response headers
    var redirect_buffer: [8192]u8 = undefined;
    const response = try request.receiveHead(&redirect_buffer);

    std.debug.print("Status: {}\n", .{response.head.status});
}
```

### POST with Custom Headers

```zig
var request = try client.request(.POST, uri, .{
    .headers = .{
        .content_type = .{ .override = "application/json; charset=utf-8" },
        .authorization = .{ .override = "Bearer YOUR_TOKEN" },
    },
});
defer request.deinit();

try request.sendBodyComplete(payload_slice);
```

### Using std.json.stringify

For complex JSON structures:

```zig
const data = .{
    .model = "llama3.2",
    .prompt = "Why is the sky blue?",
    .stream = false,
};

var json_list = std.ArrayList(u8).init(allocator);
defer json_list.deinit();

try std.json.stringify(data, .{}, json_list.writer());

// json_list.items is []u8, so can use directly
try request.sendBodyComplete(json_list.items);
```

---

## Reading Responses

### Reading Headers Only

```zig
var redirect_buffer: [8192]u8 = undefined;
const response = try request.receiveHead(&redirect_buffer);

// Access status
std.debug.print("Status: {}\n", .{response.head.status});

// Access content length
if (response.head.content_length) |len| {
    std.debug.print("Content-Length: {}\n", .{len});
}
```

### Reading Complete Response

⚠️ **Known Issue**: The `bodyReader()` method in Zig 0.15.2 has bugs that cause panics. Workaround:

**Option 1: Check status only**
```zig
const response = try request.receiveHead(&redirect_buffer);
if (response.head.status == .ok) {
    std.debug.print("Request successful!\n", .{});
}
```

**Option 2: Manual read loop** (if you need the body)
```zig
var response_buffer = std.ArrayList(u8).init(allocator);
errdefer response_buffer.deinit();

var read_buffer: [4096]u8 = undefined;
while (true) {
    const bytes_read = try request.read(&read_buffer);
    if (bytes_read == 0) break; // EOF
    try response_buffer.appendSlice(read_buffer[0..bytes_read]);
}

const body = try response_buffer.toOwnedSlice();
defer allocator.free(body);
```

---

## Streaming NDJSON

Ollama API returns streaming responses as newline-delimited JSON (NDJSON). Each line is a separate JSON object.

### Example: Streaming Chat Responses

```zig
fn handleStreamingResponse(
    request: *std.http.Client.Request,
    allocator: std.mem.Allocator,
    callback: *const fn (chunk: []const u8) void,
) !void {
    var line_buffer = std.ArrayList(u8).init(allocator);
    defer line_buffer.deinit();

    var read_buffer: [4096]u8 = undefined;
    var bytes_in_buffer: usize = 0;
    var buffer_pos: usize = 0;

    while (true) {
        // Refill buffer if needed
        if (buffer_pos >= bytes_in_buffer) {
            bytes_in_buffer = try request.read(&read_buffer);
            if (bytes_in_buffer == 0) break; // EOF
            buffer_pos = 0;
        }

        // Look for newline delimiter
        const remaining = read_buffer[buffer_pos..bytes_in_buffer];
        if (std.mem.indexOf(u8, remaining, "\n")) |newline_pos| {
            // Found a complete line
            try line_buffer.appendSlice(remaining[0..newline_pos]);
            buffer_pos += newline_pos + 1;

            // Process the JSON line
            if (line_buffer.items.len > 0) {
                const parsed = std.json.parseFromSlice(
                    ResponseType,
                    allocator,
                    line_buffer.items,
                    .{ .ignore_unknown_fields = true },
                ) catch {
                    line_buffer.clearRetainingCapacity();
                    continue;
                };
                defer parsed.deinit();

                // Process the chunk
                callback(parsed.value.response);

                // Check if done
                if (parsed.value.done) break;
            }

            line_buffer.clearRetainingCapacity();
        } else {
            // No newline yet, accumulate data
            try line_buffer.appendSlice(remaining);
            buffer_pos = bytes_in_buffer;
        }
    }
}
```

---

## Memory Management

### Allocator Patterns

**1. General Purpose Allocator (for applications):**
```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    // Use allocator...
}
```

**2. Arena Allocator (for request-scoped memory):**
```zig
fn handleRequest(gpa: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit(); // Frees all allocations at once
    const allocator = arena.allocator();
    // Make requests, parse JSON, etc.
}
```

**3. Managing Owned Memory:**
```zig
// When returning allocated data, caller owns the memory
fn generate(self: *Client, prompt: []const u8) ![]const u8 {
    // ... make request ...

    const parsed = try std.json.parseFromSlice(Response, allocator, body, .{});
    defer parsed.deinit();

    // Duplicate the string before parsed is freed
    return try self.allocator.dupe(u8, parsed.value.response);
}

// Caller must free the returned data
pub fn main() !void {
    const response = try client.generate("Hello");
    defer allocator.free(response); // Free when done
}
```

### Memory Management Rules

- Every allocation must have a corresponding deallocation
- Use `defer` to ensure cleanup happens even on errors
- `errdefer` cleans up only on error paths
- When parsing JSON with `parseFromSlice()`, always call `parsed.deinit()`
- When returning allocated data, document ownership clearly

---

## Known Issues

### Issue 1: bodyReader() Panics (Zig 0.15.2)

**Symptom:** Calling `request.bodyReader()` causes a panic about union field access.

**Workaround:**
- Use `request.read()` in a manual loop (see examples above)
- Or only check response status without reading body

### Issue 2: HTTPS POST Hangs

**Symptom:** `http.Client` can hang on HTTPS POST requests when request body size exceeds write buffer size.

**Workaround:**
- Use HTTP for local Ollama instances (`http://localhost:11434`)
- Ensure payloads fit within buffer size
- Consider chunked transfer encoding for large payloads

### Issue 3: Payload Must Be Mutable

**Symptom:** `sendBodyComplete()` requires `[]u8`, not `[]const u8`.

**Solution:**
```zig
// WRONG - compiler error
const payload: []const u8 = "{}";
try request.sendBodyComplete(payload); // Error!

// RIGHT - use mutable buffer
var payload = [_]u8{0} ** 256;
@memcpy(payload[0..2], "{}");
try request.sendBodyComplete(payload[0..2]); // Works!
```

---

## Migration from Zig 0.14

### Old API (Zig 0.11-0.14) - DO NOT USE in 0.15+

```zig
// ❌ OLD - Does not work in 0.15+
var req = try client.open(.POST, uri, .{
    .server_header_buffer = &header_buffer,
});
req.transfer_encoding = .{ .content_length = payload.len };
try req.send();
var writer = req.writer();
try writer.writeAll(payload);
try req.finish();
try req.wait();
```

### New API (Zig 0.15+)

```zig
// ✅ NEW - Correct for 0.15+
var request = try client.request(.POST, uri, .{});
try request.sendBodyComplete(payload_slice);
var redirect_buffer: [8192]u8 = undefined;
const response = try request.receiveHead(&redirect_buffer);
```

### Key API Changes

| Old (0.14) | New (0.15) |
|------------|------------|
| `client.open()` | `client.request()` |
| `req.transfer_encoding = ...` | Not needed with `sendBodyComplete()` |
| `req.send()` | `request.sendBodyComplete()` or `request.sendBodiless()` |
| `req.writer().writeAll()` | Included in `sendBodyComplete()` |
| `req.finish()` | Not needed |
| `req.wait()` | Replaced by `request.receiveHead()` |

---

## Complete Example: Ollama Client

```zig
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize HTTP client
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    // Parse URI
    const uri = try std.Uri.parse("http://localhost:11434/api/generate");

    // Create request
    var request = try client.request(.POST, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
    });
    defer request.deinit();

    // Prepare JSON payload
    const data = .{
        .model = "llama3.2",
        .prompt = "Why is the sky blue?",
        .stream = false,
    };

    var json_list = std.ArrayList(u8).init(allocator);
    defer json_list.deinit();

    try std.json.stringify(data, .{}, json_list.writer());

    // Send request
    try request.sendBodyComplete(json_list.items);

    // Receive response
    var redirect_buffer: [8192]u8 = undefined;
    const response = try request.receiveHead(&redirect_buffer);

    if (response.head.status != .ok) {
        std.debug.print("Request failed: {}\n", .{response.head.status});
        return error.RequestFailed;
    }

    std.debug.print("Request successful!\n", .{});
}
```

---

## Additional Resources

- [Zig 0.15.2 Release Notes](https://ziglang.org/download/0.15.2/release-notes.html)
- [Zig Standard Library Documentation](https://ziglang.org/documentation/master/std/)
- [Ollama API Documentation](https://docs.ollama.com/api)

---

## Troubleshooting

### "Connection refused" Error
- Ensure Ollama is running: `ollama serve`
- Check the correct port (default: 11434)
- Verify firewall settings

### JSON Parse Errors
- Use `.ignore_unknown_fields = true` for forward compatibility
- Check response with `std.debug.print()` to see actual data
- Validate JSON structure matches your response type

### Memory Leaks
- Ensure all `defer parsed.deinit()` calls are present
- Check that returned allocations are freed by caller
- Use `defer allocator.free()` for all owned slices
- Run with `-Doptimize=Debug` to enable safety checks

### Request Hangs
- Known HTTPS POST issue in 0.15.2 (see Known Issues above)
- Try HTTP instead of HTTPS for local connections
- Reduce payload size
- Add timeout handling

---

## Performance Tips

1. **Reuse HTTP Client**: Don't create a new client for each request
2. **Use Arena Allocator**: For request-scoped allocations
3. **Buffer Size**: Adjust buffer sizes based on expected response size
4. **Connection Pooling**: The HTTP client handles connection reuse automatically
5. **Streaming**: Use streaming for large responses to reduce memory usage
