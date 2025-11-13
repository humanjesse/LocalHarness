// Text Utilities - Shared text measurement and formatting functions
const std = @import("std");

/// Calculate visual width of a UTF-8 string (counts codepoints, not bytes)
/// This properly handles multi-byte UTF-8 characters like "●" which take 3 bytes but display as 1 character
pub fn visualWidth(text: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;

    while (i < text.len) {
        const byte = text[i];

        // Count UTF-8 characters by checking the leading byte
        // UTF-8 continuation bytes start with 10xxxxxx, we skip those
        if ((byte & 0b1100_0000) != 0b1000_0000) {
            width += 1;
        }
        i += 1;
    }

    return width;
}

/// Count visible characters (excluding ANSI escape sequences)
/// Also properly handles UTF-8 multi-byte characters
pub fn countVisibleChars(text: []const u8) usize {
    var count: usize = 0;
    var in_escape = false;
    var i: usize = 0;

    while (i < text.len) {
        const c = text[i];

        if (c == '\x1b') {
            in_escape = true;
        } else if (in_escape and c == 'm') {
            in_escape = false;
        } else if (!in_escape) {
            // Only count non-continuation UTF-8 bytes
            if ((c & 0b1100_0000) != 0b1000_0000) {
                count += 1;
            }
        }

        i += 1;
    }

    return count;
}

/// Truncate text to fit within max_width, adding ellipsis if needed
pub fn truncateText(text: []const u8, max_width: usize, buffer: []u8) []const u8 {
    const vis_width = visualWidth(text);

    if (vis_width <= max_width) {
        @memcpy(buffer[0..text.len], text);
        return buffer[0..text.len];
    }

    // Need to truncate with ellipsis
    const ellipsis = "...";
    if (max_width <= ellipsis.len) {
        // Not enough space even for ellipsis, just return truncated
        const truncate_bytes = @min(text.len, max_width);
        @memcpy(buffer[0..truncate_bytes], text[0..truncate_bytes]);
        return buffer[0..truncate_bytes];
    }

    // Count bytes needed for target visual width
    const target_width = max_width - ellipsis.len;
    var byte_count: usize = 0;
    var char_count: usize = 0;

    while (byte_count < text.len and char_count < target_width) {
        const byte = text[byte_count];
        if ((byte & 0b1100_0000) != 0b1000_0000) {
            char_count += 1;
        }
        byte_count += 1;
    }

    @memcpy(buffer[0..byte_count], text[0..byte_count]);
    @memcpy(buffer[byte_count..byte_count + ellipsis.len], ellipsis);
    return buffer[0..byte_count + ellipsis.len];
}
