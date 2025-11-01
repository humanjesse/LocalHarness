const std = @import("std");
const mem = std.mem;
const help_state = @import("help_state.zig");
const HelpState = help_state.HelpState;

pub const InputResult = enum {
    close,
    redraw,
    @"continue",
};

pub fn handleInput(
    state: *HelpState,
    input: []const u8,
    visible_lines: usize,
) !InputResult {
    // Handle SGR mouse events (mouse wheel scrolling)
    // Format: \x1b[<button;col;row;M (press) or m (release)
    if (input.len >= 6 and mem.eql(u8, input[0..3], "\x1b[<")) {
        if (parseMouseInput(state, input, visible_lines)) |result| {
            return result;
        }
    }

    // Handle escape sequences (arrow keys, page up/down, etc.)
    if (input.len >= 3 and input[0] == 0x1b and input[1] == '[') {
        return handleEscapeSequence(state, input, visible_lines);
    }

    // Handle single-byte commands
    if (input.len == 1) {
        const ch = input[0];

        switch (ch) {
            // Escape key - close help
            0x1b => return .close,

            // Ctrl+C - also close help
            0x03 => return .close,

            // 'q' or 'Q' - close help
            'q', 'Q' => return .close,

            // Arrow up (in case it comes as single byte)
            'k', 'K' => {
                state.scrollUp(3);
                return .redraw;
            },

            // Arrow down (in case it comes as single byte)
            'j', 'J' => {
                state.scrollDown(3, visible_lines);
                return .redraw;
            },

            else => return .@"continue",
        }
    }

    return .@"continue";
}

fn handleEscapeSequence(
    state: *HelpState,
    input: []const u8,
    visible_lines: usize,
) !InputResult {
    // ESC [ A = up arrow
    // ESC [ B = down arrow
    // ESC [ 5 ~ = page up
    // ESC [ 6 ~ = page down
    // ESC [ H = home
    // ESC [ F = end

    if (input.len >= 3) {
        const code = input[2];

        switch (code) {
            'A' => {
                // Up arrow
                state.scrollUp(3);
                return .redraw;
            },
            'B' => {
                // Down arrow
                state.scrollDown(3, visible_lines);
                return .redraw;
            },
            'H' => {
                // Home key
                state.scrollToTop();
                return .redraw;
            },
            'F' => {
                // End key
                state.scrollToBottom(visible_lines);
                return .redraw;
            },
            '5' => {
                // Page up (ESC [ 5 ~)
                if (input.len >= 4 and input[3] == '~') {
                    state.scrollUp(10);
                    return .redraw;
                }
            },
            '6' => {
                // Page down (ESC [ 6 ~)
                if (input.len >= 4 and input[3] == '~') {
                    state.scrollDown(10, visible_lines);
                    return .redraw;
                }
            },
            else => {},
        }
    }

    return .@"continue";
}

fn parseMouseInput(
    state: *HelpState,
    input: []const u8,
    visible_lines: usize,
) ?InputResult {
    // SGR mouse format: \x1b[<button;col;row;M (press) or m (release)
    var idx: usize = 3; // Skip "\x1b[<"

    // Parse button number
    var button: u32 = 0;
    while (idx < input.len and input[idx] >= '0' and input[idx] <= '9') : (idx += 1) {
        button = button * 10 + (input[idx] - '0');
    }
    if (idx >= input.len or input[idx] != ';') return null;
    idx += 1;

    // Skip column (we don't need it for scrolling)
    while (idx < input.len and input[idx] >= '0' and input[idx] <= '9') : (idx += 1) {}
    if (idx >= input.len or input[idx] != ';') return null;
    idx += 1;

    // Skip row (we don't need it for scrolling)
    while (idx < input.len and input[idx] >= '0' and input[idx] <= '9') : (idx += 1) {}
    if (idx >= input.len or (input[idx] != 'M' and input[idx] != 'm')) return null;

    const is_press = input[idx] == 'M';

    // Only handle button press events
    if (is_press) {
        if (button == 64) {
            // Scroll up
            state.scrollUp(3);
            return .redraw;
        } else if (button == 65) {
            // Scroll down
            state.scrollDown(3, visible_lines);
            return .redraw;
        }
    }

    return null;
}
