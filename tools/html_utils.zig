// HTML Utilities - Shared functions for HTML processing, URL encoding, and JSON escaping
//
// This module provides common utilities used by web tools (web_fetch, web_search)
// and other parts of the application that need to process HTML or encode data.

const std = @import("std");

/// Strips HTML tags from input and returns clean text.
///
/// Features:
/// - Removes all HTML tags including <script> and <style> content
/// - Decodes common HTML entities (&amp;, &lt;, &nbsp;, etc.)
/// - Normalizes whitespace (multiple spaces/newlines become single space)
/// - Trims leading/trailing whitespace
///
/// Caller owns the returned memory and must free it.
pub fn stripHTMLTags(allocator: std.mem.Allocator, html: []const u8) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8){};
    defer result.deinit(allocator);

    var in_tag = false;
    var in_script = false;
    var in_style = false;
    var last_was_space = false;

    var i: usize = 0;
    while (i < html.len) {
        const byte = html[i];

        // Check for <script> and <style> tags (skip their content)
        // These checks are ASCII-based and safe
        if (byte == '<') {
            if (i + 7 < html.len and std.ascii.eqlIgnoreCase(html[i .. i + 7], "<script")) {
                in_script = true;
                in_tag = true;
            } else if (i + 6 < html.len and std.ascii.eqlIgnoreCase(html[i .. i + 6], "<style")) {
                in_style = true;
                in_tag = true;
            } else if (i + 9 < html.len and std.ascii.eqlIgnoreCase(html[i .. i + 9], "</script>")) {
                in_script = false;
                in_tag = false;
                i += 9;
                continue;
            } else if (i + 8 < html.len and std.ascii.eqlIgnoreCase(html[i .. i + 8], "</style>")) {
                in_style = false;
                in_tag = false;
                i += 8;
                continue;
            } else {
                in_tag = true;
            }
        } else if (byte == '>') {
            in_tag = false;
            i += 1;
            continue;
        }

        if (!in_tag and !in_script and !in_style) {
            // Decode HTML entities (ASCII-based, so safe to check byte directly)
            if (byte == '&') {
                if (i + 5 < html.len and std.mem.eql(u8, html[i .. i + 5], "&amp;")) {
                    try result.append(allocator, '&');
                    i += 5;
                    last_was_space = false;
                    continue;
                } else if (i + 4 < html.len and std.mem.eql(u8, html[i .. i + 4], "&lt;")) {
                    try result.append(allocator, '<');
                    i += 4;
                    last_was_space = false;
                    continue;
                } else if (i + 4 < html.len and std.mem.eql(u8, html[i .. i + 4], "&gt;")) {
                    try result.append(allocator, '>');
                    i += 4;
                    last_was_space = false;
                    continue;
                } else if (i + 6 < html.len and std.mem.eql(u8, html[i .. i + 6], "&quot;")) {
                    try result.append(allocator, '"');
                    i += 6;
                    last_was_space = false;
                    continue;
                } else if (i + 5 < html.len and std.mem.eql(u8, html[i .. i + 5], "&#39;")) {
                    try result.append(allocator, '\'');
                    i += 5;
                    last_was_space = false;
                    continue;
                } else if (i + 6 < html.len and std.mem.eql(u8, html[i .. i + 6], "&nbsp;")) {
                    try result.append(allocator, ' ');
                    i += 6;
                    last_was_space = true;
                    continue;
                }
            }

            // UTF-8 aware character processing
            // Determine how many bytes are in this UTF-8 sequence
            const char_len = std.unicode.utf8ByteSequenceLength(byte) catch {
                // Invalid UTF-8 start byte, skip it
                i += 1;
                continue;
            };

            // Check if we have enough bytes for the complete sequence
            if (i + char_len > html.len) {
                // Truncated UTF-8 sequence at end of input, skip remaining bytes
                break;
            }

            // Validate the UTF-8 sequence
            _ = std.unicode.utf8Decode(html[i..][0..char_len]) catch {
                // Invalid UTF-8 sequence, skip this byte
                i += 1;
                continue;
            };

            // ASCII whitespace check (for single-byte characters only)
            if (char_len == 1 and std.ascii.isWhitespace(byte)) {
                if (!last_was_space) {
                    try result.append(allocator, ' ');
                    last_was_space = true;
                }
            } else {
                // Append the valid UTF-8 sequence
                try result.appendSlice(allocator, html[i .. i + char_len]);
                last_was_space = false;
            }

            i += char_len;
            continue;
        }

        i += 1;
    }

    // Trim and return
    const trimmed = std.mem.trim(u8, result.items, " \t\n\r");
    return try allocator.dupe(u8, trimmed);
}

/// Decodes common HTML entities in text.
///
/// Supported entities: &amp; &lt; &gt; &quot; &#39; &apos;
///
/// Caller owns the returned memory and must free it.
pub fn decodeHTMLEntities(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8){};
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '&') {
            if (std.mem.startsWith(u8, text[i..], "&amp;")) {
                try result.append(allocator, '&');
                i += 5;
            } else if (std.mem.startsWith(u8, text[i..], "&lt;")) {
                try result.append(allocator, '<');
                i += 4;
            } else if (std.mem.startsWith(u8, text[i..], "&gt;")) {
                try result.append(allocator, '>');
                i += 4;
            } else if (std.mem.startsWith(u8, text[i..], "&quot;")) {
                try result.append(allocator, '"');
                i += 6;
            } else if (std.mem.startsWith(u8, text[i..], "&#39;") or std.mem.startsWith(u8, text[i..], "&apos;")) {
                try result.append(allocator, '\'');
                i += if (text[i + 1] == '#') 5 else 6;
            } else {
                try result.append(allocator, text[i]);
                i += 1;
            }
        } else {
            try result.append(allocator, text[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// URL encodes text according to RFC 3986.
///
/// Alphanumeric characters and -_.~ are preserved.
/// Spaces become +
/// Other characters are percent-encoded.
///
/// Caller owns the returned memory and must free it.
pub fn urlEncode(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8){};
    defer result.deinit(allocator);

    for (text) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try result.append(allocator, c);
        } else if (c == ' ') {
            try result.append(allocator, '+');
        } else {
            try result.writer(allocator).print("%{X:0>2}", .{c});
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Escapes a string for safe inclusion in JSON.
///
/// Escapes: " \ \n \r \t
///
/// Caller owns the returned memory and must free it.
pub fn escapeJSON(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8){};
    defer result.deinit(allocator);

    for (text) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    try result.writer(allocator).print("\\u{x:0>4}", .{c});
                } else {
                    try result.append(allocator, c);
                }
            },
        }
    }

    return try result.toOwnedSlice(allocator);
}
