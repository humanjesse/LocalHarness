// Web Search Tool - Search the web using Google Custom Search API
//
// This tool uses the official Google Custom Search JSON API
// Requires API credentials in config: google_search_api_key and google_search_engine_id
// Free tier: 100 queries/day. Paid: $5 per 1,000 queries (up to 10k/day)
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
                .name = try allocator.dupe(u8, "web_search"),
                .description = try allocator.dupe(u8, "Search the web. Returns titles and URLs of results."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "query": {
                    \\      "type": "string",
                    \\      "description": "The search query to look up"
                    \\    },
                    \\    "num_results": {
                    \\      "type": "number",
                    \\      "description": "Number of results to return (default: 10, max: 10)"
                    \\    }
                    \\  },
                    \\  "required": ["query"]
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "web_search",
            .description = "Search the web via Google Custom Search API",
            .risk_level = .low,
            .required_scopes = &.{.network_access},
            .validator = null,
        },
        .execute = execute,
    };
}

const SearchArgs = struct {
    query: []const u8,
    num_results: ?u32 = null,
};

const SearchResult = struct {
    title: []const u8,
    url: []const u8,
};

fn execute(allocator: std.mem.Allocator, arguments: []const u8, context: *AppContext) !ToolResult {
    const start_time = std.time.milliTimestamp();

    if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
        std.debug.print("[DEBUG web_search] execute() called\n", .{});
        std.debug.print("[DEBUG web_search] Raw arguments: {s}\n", .{arguments});
    }

    // Check if API credentials are configured
    const api_key = context.config.google_search_api_key orelse {
        const error_msg =
            \\Google Custom Search API credentials not configured.
            \\
            \\To use web search, you need:
            \\1. Google Custom Search API key
            \\2. Programmable Search Engine ID (cx parameter)
            \\
            \\Setup instructions:
            \\1. Get API key: https://developers.google.com/custom-search/v1/introduction
            \\2. Create search engine: https://programmablesearchengine.google.com/
            \\3. Configure in localharness: Type '/config' and add credentials to Web Search section
            \\
            \\Free tier: 100 queries/day
            \\Paid tier: $5 per 1,000 queries (up to 10k/day)
        ;
        return ToolResult.err(allocator, .validation_failed, error_msg, start_time);
    };

    const engine_id = context.config.google_search_engine_id orelse {
        const error_msg =
            \\Google Search Engine ID not configured.
            \\
            \\You have an API key but no Search Engine ID.
            \\
            \\Setup instructions:
            \\1. Create a Programmable Search Engine: https://programmablesearchengine.google.com/
            \\2. Copy the Search Engine ID (cx parameter)
            \\3. Configure in localharness: Type '/config' and add to Web Search section
        ;
        return ToolResult.err(allocator, .validation_failed, error_msg, start_time);
    };

    // Parse arguments
    const parsed = std.json.parseFromSlice(SearchArgs, allocator, arguments, .{}) catch |err| {
        if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
            std.debug.print("[DEBUG web_search] JSON parse error: {}\n", .{err});
        }
        return ToolResult.err(allocator, .parse_error, "Invalid arguments: expected {query: string, num_results?: number}", start_time);
    };
    defer parsed.deinit();

    const args = parsed.value;
    // Google Custom Search API returns max 10 results per query
    const num_results = if (args.num_results) |n| @min(n, 10) else 10;

    if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
        std.debug.print("[DEBUG web_search] Parsed query: {s}\n", .{args.query});
        std.debug.print("[DEBUG web_search] Num results: {d}\n", .{num_results});
    }

    // Perform search using Google Custom Search API
    if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
        std.debug.print("[DEBUG web_search] Starting Google Custom Search API request...\n", .{});
    }
    const results = searchGoogleAPI(allocator, args.query, num_results, api_key, engine_id) catch |err| {
        if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
            std.debug.print("[DEBUG web_search] Search failed with error: {}\n", .{err});
        }
        const msg = try std.fmt.allocPrint(allocator, "Search failed: {s}", .{@errorName(err)});
        defer allocator.free(msg);
        return ToolResult.err(allocator, .io_error, msg, start_time);
    };
    defer {
        for (results) |result| {
            allocator.free(result.title);
            allocator.free(result.url);
        }
        allocator.free(results);
    }

    // Format results as JSON
    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    // Reusable buffer for escaping to avoid allocations in loop
    var escaped_buffer = std.ArrayListUnmanaged(u8){};
    defer escaped_buffer.deinit(allocator);

    try writer.writeAll("[\n");
    for (results, 0..) |result, i| {
        // Escape title into buffer
        escaped_buffer.clearRetainingCapacity();
        try escapeJSONIntoBuffer(&escaped_buffer, allocator, result.title);
        const escaped_title = escaped_buffer.items;

        // Escape URL into buffer (save title first)
        const title_copy = try allocator.dupe(u8, escaped_title);
        defer allocator.free(title_copy);
        escaped_buffer.clearRetainingCapacity();
        try escapeJSONIntoBuffer(&escaped_buffer, allocator, result.url);
        const escaped_url = escaped_buffer.items;

        try writer.print("  {{\n    \"title\": \"{s}\",\n    \"url\": \"{s}\"\n  }}", .{
            title_copy,
            escaped_url,
        });
        if (i < results.len - 1) try writer.writeAll(",");
        try writer.writeAll("\n");
    }
    try writer.writeAll("]");

    const result_str = try output.toOwnedSlice(allocator);
    defer allocator.free(result_str);

    if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
        std.debug.print("[DEBUG web_search] Returning {d} results\n", .{results.len});
        std.debug.print("[DEBUG web_search] Result JSON length: {d} bytes\n", .{result_str.len});
    }

    return ToolResult.ok(allocator, result_str, start_time, null);
}

fn searchGoogleAPI(
    allocator: std.mem.Allocator,
    query: []const u8,
    num_results: u32,
    api_key: []const u8,
    engine_id: []const u8,
) ![]SearchResult {
    // URL encode the query
    const encoded_query = try html_utils.urlEncode(allocator, query);
    defer allocator.free(encoded_query);

    // Build Google Custom Search API URL
    // Endpoint: https://www.googleapis.com/customsearch/v1?key={api_key}&cx={engine_id}&q={query}
    const url_str = try std.fmt.allocPrint(
        allocator,
        "https://www.googleapis.com/customsearch/v1?key={s}&cx={s}&q={s}&num={d}",
        .{ api_key, engine_id, encoded_query, num_results },
    );
    defer allocator.free(url_str);

    if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
        // Don't print full URL (contains API key)
        std.debug.print("[DEBUG web_search] API request for query: {s}\n", .{query});
        std.debug.print("[DEBUG web_search] Requesting {d} results\n", .{num_results});
    }

    // Create HTTP client
    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    // Parse URI
    const uri = std.Uri.parse(url_str) catch {
        return error.InvalidUrl;
    };

    // Prepare headers
    const headers_buffer = try allocator.alloc(http.Header, 2);
    defer allocator.free(headers_buffer);
    headers_buffer[0] = .{ .name = "User-Agent", .value = "localharness/1.0 (CLI chat application)" };
    headers_buffer[1] = .{ .name = "Accept", .value = "application/json" };

    // Make HTTP request
    var request = try client.request(.GET, uri, .{
        .extra_headers = headers_buffer,
    });
    defer request.deinit();

    try request.sendBodiless();

    var redirect_buffer: [8192]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);

    if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
        std.debug.print("[DEBUG web_search] HTTP status: {}\n", .{response.head.status});
    }

    // Check status
    if (response.head.status != .ok) {
        if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
            std.debug.print("[DEBUG web_search] Non-OK status received\n", .{});
        }
        if (response.head.status == .forbidden) return error.InvalidAPIKey;
        if (response.head.status == .bad_request) return error.InvalidRequest;
        return error.HttpError;
    }

    // Debug transfer encoding info
    if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
        std.debug.print("[DEBUG web_search] Transfer encoding: {}\n", .{response.head.transfer_encoding});
        std.debug.print("[DEBUG web_search] Content-Length: {?d}\n", .{response.head.content_length});
    }

    // Read response body using proper HTTP Reader (handles chunked encoding automatically)
    if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
        std.debug.print("[DEBUG web_search] Reading response body using response.reader()...\n", .{});
    }

    // Use response.reader() which handles chunked encoding and content-length automatically
    var transfer_buffer: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buffer);

    var body_list = std.ArrayListUnmanaged(u8){};
    defer body_list.deinit(allocator);

    var read_buffer: [8192]u8 = undefined;
    var total_read: usize = 0;
    var iterations: usize = 0;
    const max_iterations: usize = 1000;

    // Time-based timeout tracking
    var last_read_time = std.time.milliTimestamp();
    const timeout_ms: i64 = 10000; // 10 second timeout (Google API should be fast)
    var consecutive_zero_reads: usize = 0;
    const max_zero_reads: usize = 5; // Allow a few zero-byte reads for timing

    while (iterations < max_iterations) : (iterations += 1) {
        // Check for timeout since last successful read
        const now = std.time.milliTimestamp();
        if (now - last_read_time > timeout_ms) {
            if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
                std.debug.print("[DEBUG web_search] Timeout: no data for {d}ms, breaking with {d} bytes\n", .{ timeout_ms, total_read });
            }
            break; // Exit gracefully with whatever we got
        }

        var read_vec = [_][]u8{&read_buffer};
        const bytes_read = reader.*.readVec(&read_vec) catch |err| {
            if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
                std.debug.print("[DEBUG web_search] Read error: {}, breaking\n", .{err});
            }
            break;
        };

        if (bytes_read == 0) {
            consecutive_zero_reads += 1;
            if (consecutive_zero_reads >= max_zero_reads) {
                if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
                    std.debug.print("[DEBUG web_search] {d} consecutive zero-byte reads, stopping\n", .{consecutive_zero_reads});
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
            std.debug.print("[DEBUG web_search] Read {d} bytes (total: {d})\n", .{ bytes_read, total_read });
        }

        if (body_list.items.len > 1024 * 1024) {
            if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
                std.debug.print("[DEBUG web_search] Response too large (>1MB)\n", .{});
            }
            return error.ResponseTooLarge; // 1MB max
        }
    }

    const body = try body_list.toOwnedSlice(allocator);
    defer allocator.free(body);

    if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
        std.debug.print("[DEBUG web_search] Received {d} bytes of JSON\n", .{body.len});
    }

    // Parse JSON response
    return parseGoogleAPIResponse(allocator, body);
}

// Google Custom Search API JSON response structure
const GoogleSearchResponse = struct {
    items: ?[]GoogleSearchItem = null,
};

const GoogleSearchItem = struct {
    title: []const u8,
    link: []const u8,
};

fn parseGoogleAPIResponse(allocator: std.mem.Allocator, json_body: []const u8) ![]SearchResult {
    if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
        std.debug.print("[DEBUG web_search] Parsing JSON response\n", .{});
    }

    const parsed = std.json.parseFromSlice(GoogleSearchResponse, allocator, json_body, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
            std.debug.print("[DEBUG web_search] JSON parse error: {}\n", .{err});
        }
        return error.InvalidJSON;
    };
    defer parsed.deinit();

    const items = parsed.value.items orelse {
        // No results found
        if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
            std.debug.print("[DEBUG web_search] No results in API response\n", .{});
        }
        return try allocator.alloc(SearchResult, 0);
    };

    if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
        std.debug.print("[DEBUG web_search] Found {d} items in response\n", .{items.len});
    }

    var results = try allocator.alloc(SearchResult, items.len);
    errdefer {
        for (results) |result| {
            allocator.free(result.title);
            allocator.free(result.url);
        }
        allocator.free(results);
    }

    for (items, 0..) |item, i| {
        results[i] = .{
            .title = try allocator.dupe(u8, item.title),
            .url = try allocator.dupe(u8, item.link),
        };

        if (std.posix.getenv("DEBUG_WEB_TOOLS")) |_| {
            std.debug.print("[DEBUG web_search] Result #{d}: {s}\n", .{ i + 1, item.title });
            std.debug.print("[DEBUG web_search]   URL: {s}\n", .{item.link});
        }
    }

    return results;
}

fn escapeJSONIntoBuffer(buffer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '"' => try buffer.appendSlice(allocator, "\\\""),
            '\\' => try buffer.appendSlice(allocator, "\\\\"),
            '\n' => try buffer.appendSlice(allocator, "\\n"),
            '\r' => try buffer.appendSlice(allocator, "\\r"),
            '\t' => try buffer.appendSlice(allocator, "\\t"),
            else => try buffer.append(allocator, c),
        }
    }
}
