// --- lexer.zig (Corrected and Final) ---
const std = @import("std");
const mem = std.mem;
const ascii = std.ascii;
const unicode = std.unicode;

pub const Token = struct {
    tag: Tag,
    text: []const u8,
    indent_width: usize = 0,

    pub const Tag = enum {
        indent,
        atx_heading,
        unordered_list_marker,
        ordered_list_marker,
        blockquote,
        code_fence,
        text,
        newline,
        asterisk,
        underscore,
        backtick,
        tilde,
        left_bracket,
        right_bracket,
    };
};

fn isInlineDelimiter(char: u21) bool {
    return switch (char) {
        '*', '_', '`', '~', '[', ']', '\n' => true,
        else => false,
    };
}

const Utf8DecodeResult = struct {
    codepoint: u21,
    len: usize,
};

fn utf8DecodeWithLen(slice: []const u8) !Utf8DecodeResult {
    if (slice.len == 0) return error.InvalidUtf8;
    const seq_len = try unicode.utf8ByteSequenceLength(slice[0]);
    if (slice.len < seq_len) return error.InvalidUtf8;
    const cp = try unicode.utf8Decode(slice[0..seq_len]);
    return .{ .codepoint = cp, .len = seq_len };
}

// In lexer.zig
// REPLACE the existing tokenize function with this one.
pub fn tokenize(allocator: mem.Allocator, input: []const u8) !std.ArrayList(Token) {
    var tokens = std.ArrayList(Token).init(allocator);
    var i: usize = 0;

    while (i < input.len) {
        const start = i;

        // --- START: Block-Level Recognition at Line Start ---
        if (start == 0 or input[start - 1] == '\n') {
            var current_pos = i;
            var width: usize = 0;
            while (current_pos < input.len) {
                const c = input[current_pos];
                if (c == ' ') {
                    width += 1;
                } else if (c == '\t') {
                    width += 4;
                } else {
                    break;
                }
                current_pos += 1;
            }
            if (current_pos > i) {
                try tokens.append(.{
                    .tag = .indent,
                    .text = input[i..current_pos],
                    .indent_width = width,
                });
                i = current_pos;
            }

            if (i >= input.len) break;
            const char = input[i];

            // Code Fence
            if (char == '`' or char == '~') {
                var j = i;
                while (j < input.len and input[j] == char) : (j += 1) {}
                if (j - i >= 3) {
                    try tokens.append(.{ .tag = .code_fence, .text = input[i..j] });
                    i = j;
                    continue;
                }
            }

            // ATX Heading
            if (char == '#') {
                var j = i;
                while (j < input.len and input[j] == '#') : (j += 1) {}
                if (j < input.len and (input[j] == ' ' or input[j] == '\n')) {
                    try tokens.append(.{ .tag = .atx_heading, .text = input[i..j] });
                    i = j;
                    continue;
                }
            }

            // Unordered List Marker
            if (char == '*' or char == '-' or char == '+') {
                if (i + 1 < input.len and input[i + 1] == ' ') {
                    try tokens.append(.{ .tag = .unordered_list_marker, .text = input[i .. i + 1] });
                    i += 1; // Consume only the '*', not the space after it.
                    continue;
                }
            }

            // Ordered List Marker
            if (ascii.isDigit(char)) {
                var j = i + 1;
                while (j < input.len and ascii.isDigit(input[j])) : (j += 1) {}
                if (j < input.len and (input[j] == '.' or input[j] == ')')) {
                    if (j + 1 < input.len and input[j + 1] == ' ') {
                        try tokens.append(.{ .tag = .ordered_list_marker, .text = input[i .. j + 1] });
                        i = j + 1; // Consume the marker (e.g., "1."), not the space.
                        continue;
                    }
                }
            }

           // Blockquote
if (char == '>') {
    try tokens.append(.{ .tag = .blockquote, .text = input[i .. i + 1] });
    i += 1; // Consume the '>'
    continue;

            }
        }
        // --- END: Block-Level Recognition ---

        if (i > start) continue;

        // --- START: Inline-Level Tokenization ---
        const decode_result = try utf8DecodeWithLen(input[i..]);
        switch (decode_result.codepoint) {
            '*' => {
                i += decode_result.len;
                try tokens.append(.{ .tag = .asterisk, .text = input[start..i] });
            },
            '_' => {
                i += decode_result.len;
                try tokens.append(.{ .tag = .underscore, .text = input[start..i] });
            },
            '`' => {
                i += decode_result.len;
                try tokens.append(.{ .tag = .backtick, .text = input[start..i] });
            },
            '~' => {
                i += decode_result.len;
                try tokens.append(.{ .tag = .tilde, .text = input[start..i] });
            },
            '[' => {
                i += decode_result.len;
                try tokens.append(.{ .tag = .left_bracket, .text = input[start..i] });
            },
            ']' => {
                i += decode_result.len;
                try tokens.append(.{ .tag = .right_bracket, .text = input[start..i] });
            },
            '\n' => {
                i += decode_result.len;
                try tokens.append(.{ .tag = .newline, .text = input[start..i] });
            },
            else => {
                const text_start = i;
                var current_pos = i;
                while (current_pos < input.len) {
                    const dr = try utf8DecodeWithLen(input[current_pos..]);
                    if (isInlineDelimiter(dr.codepoint)) {
                        break;
                    }
                    current_pos += dr.len;
                }
                i = current_pos;
                try tokens.append(.{ .tag = .text, .text = input[text_start..i] });
            },
        }
    }
    return tokens;
}
