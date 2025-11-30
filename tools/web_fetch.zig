// Web Fetch Tool - Fetch and extract text content from a URL
//
// ETHICAL & LEGAL CONSIDERATIONS:
// - Users are responsible for ensuring they have permission to access fetched URLs
// - Respects HTTP status codes but does NOT follow redirects (for security)
// - Identifies itself honestly via User-Agent header
// - Does NOT respect robots.txt (consider adding for production use)
// - Maximum response size is 10MB to prevent abuse
//
const std = @import("std");
const http = std.http;
const ollama = @import("ollama");
const permission = @import("permission");
const context_module = @import("context");
const tools_module = @import("../tools.zig");
const html_utils = @import("html_utils");

const AppContext = context_module.AppContext;
const ToolDefinition = tools_module.ToolDefinition;
const ToolResult = tools_module.ToolResult;

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "web_fetch"),
                .description = try allocator.dupe(u8, "Fetch the text content of a webpage. Retrieves the HTML from a URL and extracts the readable text content (HTML tags are stripped). Use this after web_search to read the actual content of pages. Maximum response size is 100KB of text."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "url": {
                    \\      "type": "string",
                    \\      "description": "The URL to fetch (must start with http:// or https://)"
                    \\    }
                    \\  },
                    \\  "required": ["url"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "web_fetch",
            .description = "Fetch content from a URL",
            .risk_level = .medium,
            .required_scopes = &.{.network_access},
            .validator = null,
        },
        .execute = execute,
    };
}

const FetchArgs = struct {
    url: []const u8,
};

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    _ = context;
    const start_time = std.time.milliTimestamp();

    if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
        std.debug.print("[DEBUG web_fetch] execute() called\n", .{});
        std.debug.print("[DEBUG web_fetch] Raw arguments: {s}\n", .{arguments});
    }

    // Parse arguments
    const parsed = std.json.parseFromSlice(FetchArgs, allocator, arguments, .{}) catch |err| {
        if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
            std.debug.print("[DEBUG web_fetch] JSON parse error: {}\n", .{err});
        }
        return ToolResult.err(allocator, .parse_error, "Invalid arguments: expected {url: string}", start_time);
    };
    defer parsed.deinit();

    const args = parsed.value;

    if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
        std.debug.print("[DEBUG web_fetch] Parsed URL: {s}\n", .{args.url});
    }

    // Validate URL
    if (!std.mem.startsWith(u8, args.url, "http://") and !std.mem.startsWith(u8, args.url, "https://")) {
        if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
            std.debug.print("[DEBUG web_fetch] URL validation failed - must start with http:// or https://\n", .{});
        }
        return ToolResult.err(allocator, .validation_failed, "URL must start with http:// or https://", start_time);
    }

    // Fetch URL content
    if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
        std.debug.print("[DEBUG web_fetch] Starting URL fetch...\n", .{});
    }
    const content = fetchURL(allocator, args.url) catch |err| {
        if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
            std.debug.print("[DEBUG web_fetch] Fetch failed with error: {}\n", .{err});
        }
        const msg = try std.fmt.allocPrint(allocator, "Failed to fetch URL: {s}", .{@errorName(err)});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .io_error, msg, start_time);
    };
    defer allocator.free(content);

    if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
        std.debug.print("[DEBUG web_fetch] Fetched {d} bytes\n", .{content.len});
    }

    // Strip HTML tags to get clean text
    if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
        std.debug.print("[DEBUG web_fetch] Stripping HTML tags...\n", .{});
    }
    const clean_text = try html_utils.stripHTMLTags(allocator, content);
    defer allocator.free(clean_text);

    if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
        std.debug.print("[DEBUG web_fetch] Stripped to {d} bytes of text\n", .{clean_text.len});
    }

    // Truncate to 100KB max (like Claude Code does)
    const max_size: usize = 100 * 1024;
    const truncated = if (clean_text.len > max_size) blk: {
        const truncated_str = try std.fmt.allocPrint(
            allocator,
            "{s}\n\n[Content truncated: {d} bytes total, showing first {d} bytes]",
            .{ clean_text[0..max_size], clean_text.len, max_size },
        );
        break :blk truncated_str;
    } else blk: {
        break :blk try allocator.dupe(u8, clean_text);
    };
    defer allocator.free(truncated);

    return ToolResult.ok(allocator, truncated, start_time, null);
}

fn fetchURL(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    return fetchURLWithRedirects(allocator, url, 0);
}

fn fetchURLWithRedirects(allocator: std.mem.Allocator, url: []const u8, redirect_count: u32) ![]const u8 {
    // Prevent infinite redirect loops
    const MAX_REDIRECTS = 5;
    if (redirect_count >= MAX_REDIRECTS) {
        if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
            std.debug.print("[DEBUG web_fetch] Too many redirects ({d})\n", .{redirect_count});
        }
        return error.TooManyRedirects;
    }

    if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
        std.debug.print("[DEBUG web_fetch] fetchURL() called for: {s} (redirect #{d})\n", .{url, redirect_count});
    }

    // Create HTTP client
    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    // Parse URI
    const uri = std.Uri.parse(url) catch {
        if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
            std.debug.print("[DEBUG web_fetch] URI parse failed\n", .{});
        }
        return error.InvalidUrl;
    };

    if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
        std.debug.print("[DEBUG web_fetch] URI parsed successfully\n", .{});
    }

    // Prepare headers with honest identification
    const headers_buffer = try allocator.alloc(http.Header, 4);
    defer allocator.free(headers_buffer);
    headers_buffer[0] = .{ .name = "User-Agent", .value = "localharness/1.0 (CLI chat application with web fetch capabilities)" };
    headers_buffer[1] = .{ .name = "Accept", .value = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" };
    headers_buffer[2] = .{ .name = "Accept-Language", .value = "en-US,en;q=0.5" };
    headers_buffer[3] = .{ .name = "Accept-Encoding", .value = "gzip, deflate" };

    // Make HTTP request
    var request = try client.request(.GET, uri, .{
        .extra_headers = headers_buffer,
    });
    defer request.deinit();

    if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
        std.debug.print("[DEBUG web_fetch] Sending HTTP request...\n", .{});
    }

    try request.sendBodiless();

    var redirect_buffer: [8192]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);

    // Check status
    const status = response.head.status;

    if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
        std.debug.print("[DEBUG web_fetch] HTTP status: {}\n", .{status});
    }

    if (status != .ok) {
        if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
            std.debug.print("[DEBUG web_fetch] Non-OK status received\n", .{});
        }
        if (status == .not_found) return error.NotFound;
        if (status == .forbidden) return error.Forbidden;

        // Handle redirects (301, 302, 303, 307, 308)
        if (status == .moved_permanently or status == .found or
            status == .see_other or status == .temporary_redirect or
            status == .permanent_redirect) {

            // Extract Location header
            const location = blk: {
                var it = response.head.iterateHeaders();
                while (it.next()) |header| {
                    if (std.ascii.eqlIgnoreCase(header.name, "location")) {
                        break :blk header.value;
                    }
                }
                return error.RedirectWithoutLocation;
            };

            if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
                std.debug.print("[DEBUG web_fetch] Redirect to: {s}\n", .{location});
            }

            // Build absolute URL from Location header
            const redirect_url = if (std.mem.startsWith(u8, location, "http://") or
                                     std.mem.startsWith(u8, location, "https://"))
                // Absolute URL - use as-is
                try allocator.dupe(u8, location)
            else if (std.mem.startsWith(u8, location, "/"))
                // Relative URL starting with / - reconstruct from current URI
                blk: {
                    // Get host string from URI
                    const host_str = if (uri.host) |h| h.percent_encoded else return error.NoHost;
                    break :blk try std.fmt.allocPrint(allocator, "{s}://{s}{s}", .{
                        uri.scheme,
                        host_str,
                        location,
                    });
                }
            else
                // Other relative URLs - not supported for safety
                return error.UnsupportedRedirect;

            defer allocator.free(redirect_url);

            // Security check: Prevent redirect to localhost/internal IPs
            if (std.mem.indexOf(u8, redirect_url, "localhost") != null or
                std.mem.indexOf(u8, redirect_url, "127.0.0.1") != null or
                std.mem.indexOf(u8, redirect_url, "0.0.0.0") != null or
                std.mem.indexOf(u8, redirect_url, "[::1]") != null) {
                if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
                    std.debug.print("[DEBUG web_fetch] Blocked redirect to localhost/internal IP\n", .{});
                }
                return error.RedirectToLocalhost;
            }

            // Follow the redirect recursively
            return fetchURLWithRedirects(allocator, redirect_url, redirect_count + 1);
        }

        return error.HttpError;
    }

    // Debug transfer encoding info
    if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
        std.debug.print("[DEBUG web_fetch] Transfer encoding: {}\n", .{response.head.transfer_encoding});
        std.debug.print("[DEBUG web_fetch] Content-Length: {?d}\n", .{response.head.content_length});
    }

    // Extract Content-Encoding header for decompression
    // Must duplicate since the header buffer gets reused during body read
    const content_encoding: ?[]const u8 = blk: {
        var it = response.head.iterateHeaders();
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "content-encoding")) {
                break :blk allocator.dupe(u8, header.value) catch null;
            }
        }
        break :blk null;
    };
    defer if (content_encoding) |enc| allocator.free(enc);

    if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
        if (content_encoding) |enc| {
            std.debug.print("[DEBUG web_fetch] Content-Encoding: {s}\n", .{enc});
        } else {
            std.debug.print("[DEBUG web_fetch] Content-Encoding: none\n", .{});
        }
    }

    // Read response body using proper HTTP Reader (handles chunked encoding automatically)
    if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
        std.debug.print("[DEBUG web_fetch] Reading response body using response.reader()...\n", .{});
    }

    // Use response.reader() which handles chunked encoding and content-length automatically
    var transfer_buffer: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buffer);

    var body_list = std.ArrayListUnmanaged(u8){};
    defer body_list.deinit(allocator);

    var read_buffer: [8192]u8 = undefined;
    var total_read: usize = 0;
    var iterations: usize = 0;
    const max_iterations: usize = 10000; // Increased for large pages

    // Time-based timeout tracking
    var last_read_time = std.time.milliTimestamp();
    const timeout_ms: i64 = 30000; // 30 second timeout
    var consecutive_zero_reads: usize = 0;
    const max_zero_reads: usize = 5; // Allow a few zero-byte reads for timing

    while (iterations < max_iterations) : (iterations += 1) {
        // Check for timeout since last successful read
        const now = std.time.milliTimestamp();
        if (now - last_read_time > timeout_ms) {
            if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
                std.debug.print("[DEBUG web_fetch] Timeout: no data for {d}ms, breaking with {d} bytes\n", .{ timeout_ms, total_read });
            }
            break; // Exit gracefully with whatever we got
        }

        var read_vec = [_][]u8{&read_buffer};
        const bytes_read = reader.*.readVec(&read_vec) catch |err| {
            if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
                std.debug.print("[DEBUG web_fetch] Read error: {}, breaking\n", .{err});
            }
            break;
        };

        if (bytes_read == 0) {
            consecutive_zero_reads += 1;
            if (consecutive_zero_reads >= max_zero_reads) {
                if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
                    std.debug.print("[DEBUG web_fetch] {d} consecutive zero-byte reads, stopping\n", .{consecutive_zero_reads});
                }
                break;
            }
            continue;
        }

        consecutive_zero_reads = 0; // Reset on successful read
        total_read += bytes_read;
        last_read_time = now; // Reset timeout on successful read
        try body_list.appendSlice(allocator, read_buffer[0..bytes_read]);

        if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
            std.debug.print("[DEBUG web_fetch] Read {d} bytes (total: {d})\n", .{ bytes_read, total_read });
        }

        if (body_list.items.len > 10 * 1024 * 1024) {
            if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
                std.debug.print("[DEBUG web_fetch] Response too large (>10MB)\n", .{});
            }
            return error.ResponseTooLarge;
        }
    }

    const body = try body_list.toOwnedSlice(allocator);

    if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
        std.debug.print("[DEBUG web_fetch] Successfully read {d} bytes\n", .{body.len});
    }

    // Decompress if needed
    const decompressed = try decompressContent(allocator, body, content_encoding);
    allocator.free(body); // Free the compressed body

    if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
        std.debug.print("[DEBUG web_fetch] After decompression: {d} bytes\n", .{decompressed.len});
    }

    return decompressed;
}

/// Decompress content based on Content-Encoding header
fn decompressContent(
    allocator: std.mem.Allocator,
    body: []const u8,
    content_encoding: ?[]const u8,
) ![]u8 {
    const encoding = content_encoding orelse {
        // No encoding, return copy of original
        return try allocator.dupe(u8, body);
    };

    if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
        std.debug.print("[DEBUG web_fetch] Decompressing with encoding: {s}\n", .{encoding});
    }

    // Determine container type based on Content-Encoding
    const container: std.compress.flate.Container = if (std.ascii.eqlIgnoreCase(encoding, "gzip"))
        .gzip
    else if (std.ascii.eqlIgnoreCase(encoding, "deflate"))
        .raw // deflate uses raw container (no gzip/zlib wrapper)
    else {
        // Unknown encoding, return original
        if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
            std.debug.print("[DEBUG web_fetch] Unknown encoding '{s}', returning raw\n", .{encoding});
        }
        return try allocator.dupe(u8, body);
    };

    // Create reader from compressed body
    var input_reader: std.Io.Reader = .fixed(body);

    // Create allocating writer for output
    var output_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer output_writer.deinit();

    // Initialize decompressor
    var decompress: std.compress.flate.Decompress = .init(&input_reader, container, &.{});

    // Stream decompressed data to writer
    _ = decompress.reader.streamRemaining(&output_writer.writer) catch |err| {
        if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
            std.debug.print("[DEBUG web_fetch] Decompression failed: {}\n", .{err});
        }
        // errdefer will handle cleanup
        return error.DecompressFailed;
    };

    // Get the decompressed bytes
    const result = output_writer.written();

    // We need to transfer ownership - duplicate the data and free the writer
    const owned_result = try allocator.dupe(u8, result);
    output_writer.deinit();

    return owned_result;
}

