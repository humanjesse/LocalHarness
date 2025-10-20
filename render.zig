// Rendering utilities - text wrapping, formatting, and display functions
const std = @import("std");
const mem = std.mem;
const ui = @import("ui.zig");
const markdown = @import("markdown.zig");
const types = @import("types.zig");

/// Open an external editor and wait for it to close
pub fn openEditorAndWait(allocator: mem.Allocator, editor: []const []const u8, note_path: []const u8) !void {
    var argv = std.ArrayListUnmanaged([]const u8){};
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, editor);
    try argv.append(allocator, note_path);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    _ = term;
}

/// Wrap text to fit within max_width, respecting Unicode, ANSI codes, and ZWJ emoji sequences
pub fn wrapRawText(allocator: mem.Allocator, text: []const u8, max_width: usize) !std.ArrayListUnmanaged([]const u8) {
    var result = std.ArrayListUnmanaged([]const u8){};
    var line_iterator = mem.splitScalar(u8, text, '\n');

    while (line_iterator.next()) |line| {
        if (line.len == 0) {
            try result.append(allocator, try allocator.dupe(u8, ""));
            continue;
        }

        var current_byte_pos: usize = 0;
        while (current_byte_pos < line.len) {
            var visible_chars: usize = 0;
            var byte_idx: usize = current_byte_pos;
            var last_space_byte_pos: ?usize = null;
            var in_zwj_sequence = false;

            while (byte_idx < line.len) {
                if (line[byte_idx] == 0x1b) {
                    var end = byte_idx;
                    while (end < line.len and line[end] != 'm') : (end += 1) {}
                    byte_idx = end + 1;
                    continue;
                }

                const char_len = std.unicode.utf8ByteSequenceLength(line[byte_idx]) catch 1;

                // Decode the character and get its width
                const char_width = if (byte_idx + char_len <= line.len) blk: {
                    const codepoint = std.unicode.utf8Decode(line[byte_idx..][0..char_len]) catch break :blk 1;
                    break :blk ui.getCharWidth(codepoint);
                } else 1;

                // Handle ZWJ sequences (family emoji, couple emoji, etc.)
                const codepoint = if (byte_idx + char_len <= line.len)
                    std.unicode.utf8Decode(line[byte_idx..][0..char_len]) catch 0
                else
                    0;

                var width_to_add: usize = char_width;
                if (codepoint == 0x200D) { // Zero-Width Joiner
                    in_zwj_sequence = true;
                    width_to_add = 0; // ZWJ itself adds no width
                } else if (in_zwj_sequence) {
                    if (char_width == 0) {
                        // Zero-width modifier in sequence (skin tone, variation selector)
                        width_to_add = 0;
                    } else if (char_width == 2) {
                        // Another emoji in the sequence - don't add width
                        width_to_add = 0;
                    } else {
                        // Non-emoji, end the sequence
                        in_zwj_sequence = false;
                        width_to_add = char_width;
                    }
                }

                if (max_width > 0 and visible_chars + width_to_add > max_width) {
                    break;
                }
                visible_chars += width_to_add;
                if (line[byte_idx] == ' ') {
                    last_space_byte_pos = byte_idx;
                    in_zwj_sequence = false; // Space ends ZWJ sequence
                }

                byte_idx += char_len;
            }

            var break_pos = byte_idx;
            if (byte_idx < line.len) {
                if (last_space_byte_pos) |space_pos| {
                    if (space_pos >= current_byte_pos) {
                        break_pos = space_pos;
                    }
                }
            }

            try result.append(allocator, try allocator.dupe(u8, line[current_byte_pos..break_pos]));
            current_byte_pos = break_pos;
            if (current_byte_pos < line.len and line[current_byte_pos] == ' ') {
                current_byte_pos += 1;
            }
        }
    }
    return result;
}

/// Truncate text to max_width with "..." suffix
pub fn truncateTextToWidth(allocator: mem.Allocator, text: []const u8, max_width: usize) ![]const u8 {
    const visible_len = ui.AnsiParser.getVisibleLength(text);

    // If text fits, return duplicate
    if (visible_len <= max_width) {
        return try allocator.dupe(u8, text);
    }

    // Text is too long - need to truncate with "..."
    // Target: max_width visible chars total, with "..." at the end
    // So we need max_width - 3 visible chars of text, then "..."

    if (max_width < 3) {
        // Very narrow - just return "..." or fewer dots
        if (max_width == 0) return try allocator.dupe(u8, "");
        if (max_width == 1) return try allocator.dupe(u8, ".");
        if (max_width == 2) return try allocator.dupe(u8, "..");
        return try allocator.dupe(u8, "...");
    }

    const target_visible = max_width - 3; // Reserve 3 for "..."

    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    var byte_idx: usize = 0;
    var visible_count: usize = 0;
    var in_ansi_sequence = false;
    var in_zwj_sequence = false;

    while (byte_idx < text.len and visible_count < target_visible) {
        const byte = text[byte_idx];

        // Handle ANSI escape sequences
        if (byte == 0x1b) {
            in_ansi_sequence = true;
            try result.append(allocator, byte);
            byte_idx += 1;
            continue;
        }

        if (in_ansi_sequence) {
            try result.append(allocator, byte);
            byte_idx += 1;
            // Check for end of ANSI sequence (letter in range 0x40-0x7E after '[')
            if (byte >= 0x40 and byte <= 0x7E) {
                in_ansi_sequence = false;
            }
            continue;
        }

        // Decode UTF-8 character
        const char_len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
        if (byte_idx + char_len > text.len) break;

        const codepoint = std.unicode.utf8Decode(text[byte_idx..][0..char_len]) catch {
            byte_idx += 1;
            continue;
        };

        const char_width = ui.getCharWidth(codepoint);

        // Handle ZWJ sequences
        var width_to_add: usize = char_width;
        if (codepoint == 0x200D) { // Zero-Width Joiner
            in_zwj_sequence = true;
            width_to_add = 0;
        } else if (in_zwj_sequence) {
            if (char_width == 0) {
                width_to_add = 0; // Zero-width modifier
            } else if (char_width == 2) {
                width_to_add = 0; // Another emoji in sequence
            } else {
                in_zwj_sequence = false;
                width_to_add = char_width;
            }
        }

        // Check if adding this character would exceed target
        if (visible_count + width_to_add > target_visible) {
            break;
        }

        // Add the character
        try result.appendSlice(allocator, text[byte_idx..][0..char_len]);
        visible_count += width_to_add;
        byte_idx += char_len;
    }

    // Add "..."
    try result.appendSlice(allocator, "...");

    return try result.toOwnedSlice(allocator);
}

/// Find the longest word in text (for table column width calculations)
pub fn getLongestWordLength(text: []const u8) usize {
    var max_len: usize = 0;
    var current_len: usize = 0;
    var byte_idx: usize = 0;

    while (byte_idx < text.len) {
        const byte = text[byte_idx];

        // Skip ANSI escape sequences
        if (byte == 0x1b) {
            var end = byte_idx;
            while (end < text.len and text[end] != 'm') : (end += 1) {}
            byte_idx = end + 1;
            continue;
        }

        const char_len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
        if (byte_idx + char_len > text.len) break;

        const codepoint = std.unicode.utf8Decode(text[byte_idx..][0..char_len]) catch {
            byte_idx += 1;
            continue;
        };

        // Check if it's a word boundary (space, newline, punctuation)
        if (codepoint == ' ' or codepoint == '\n' or codepoint == '\t' or codepoint == ',' or codepoint == '.') {
            if (current_len > max_len) max_len = current_len;
            current_len = 0;
        } else {
            const char_width = ui.getCharWidth(codepoint);
            current_len += char_width;
        }

        byte_idx += char_len;
    }

    // Check final word
    if (current_len > max_len) max_len = current_len;

    return max_len;
}

// Note: renderItemsToLines, drawMessage, and drawInputField have been moved to app.zig
// since they depend on the App struct.
