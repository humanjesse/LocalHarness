// --- ui.zig ---
// Manages terminal state, input, and drawing.
const std = @import("std");
const mem = std.mem;
const main = @import("main.zig");

// --- START: Merged from c_api.zig ---
pub const c = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("sys/ioctl.h");
});
// --- END: Merged from c_api.zig ---

// --- START: Merged from tui.zig ---
pub const TerminalSize = struct {
    width: u16,
    height: u16,
};

pub const Tui = struct {
    orig_termios: c.struct_termios,

    pub fn enableRawMode(self: *Tui) !void {
        if (c.tcgetattr(c.STDIN_FILENO, &self.orig_termios) != 0) return error.GetAttrFailed;
        var raw = self.orig_termios;
        raw.c_lflag &= ~@as(c.tcflag_t, c.ECHO | c.ICANON | c.ISIG | c.IEXTEN);
        raw.c_iflag &= ~@as(c.tcflag_t, c.IXON | c.ICRNL);
        raw.c_oflag &= ~@as(c.tcflag_t, c.OPOST);
        raw.c_cc[c.VMIN] = 0;
        raw.c_cc[c.VTIME] = 1;
        if (c.tcsetattr(c.STDIN_FILENO, c.TCSAFLUSH, &raw) != 0) return error.SetAttrFailed;
        try std.io.getStdOut().writer().print("\x1b[?25l\x1b[?1000h", .{});
    }

    pub fn disableRawMode(self: *const Tui) void {
        _ = c.tcsetattr(c.STDIN_FILENO, c.TCSAFLUSH, &self.orig_termios);
        std.io.getStdOut().writer().print("\x1b[?25h\x1b[?1000l", .{}) catch {};
    }

    pub fn getTerminalSize() !TerminalSize {
        var ws: c.struct_winsize = undefined;
        if (c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &ws) == -1 or ws.ws_col == 0) {
            return error.IoctlFailed;
        }
        return TerminalSize{ .width = ws.ws_col, .height = ws.ws_row };
    }
};
// --- END: Merged from tui.zig ---

// --- START: Merged from ansi.zig ---
pub const AnsiParser = struct {
    const State = enum {
        normal,
        got_escape,
        got_bracket,
    };

    pub fn getVisibleLength(s: []const u8) usize {
        var i: usize = 0;
        var count: usize = 0;
        var state = State.normal;

        while (i < s.len) {
            const byte = s[i];
            switch (state) {
                .normal => {
                    if (byte == 0x1b) {
                        state = .got_escape;
                        i += 1;
                    } else {
                        if (byte & 0x80 == 0) {
                            i += 1;
                        } else if (byte & 0xE0 == 0xC0) {
                            i += 2;
                        } else if (byte & 0xF0 == 0xE0) {
                            i += 3;
                        } else if (byte & 0xF8 == 0xF0) {
                            i += 4;
                        } else {
                            i += 1;
                        }
                        count += 1;
                    }
                },
                .got_escape => {
                    if (byte == '[') {
                        state = .got_bracket;
                    } else {
                        state = .normal;
                    }
                    i += 1;
                },
                .got_bracket => {
                    if (byte >= 0x40 and byte <= 0x7E) {
                        state = .normal;
                    }
                    i += 1;
                },
            }
        }
        return count;
    }
};
// --- END: Merged from ansi.zig ---

// --- START: Merged from taskbar.zig ---
pub fn drawTaskbar(app: *const main.App, writer: anytype) !void {
    try writer.print("\x1b[{d};1H", .{app.terminal_size.height});
    try writer.print("\x1b[2K", .{});
    try writer.print("Press 'q' to quit.", .{});
}
// --- END: Merged from taskbar.zig ---

// --- START: Merged from actions.zig ---
fn findCursorIndex(app: *const main.App) ?usize {
    for (app.valid_cursor_positions.items, 0..) |pos, i| {
        if (pos == app.cursor_y) {
            return i;
        }
    }
    return null;
}

fn findAreaAtCursor(app: *const main.App) ?main.ClickableArea {
    for (app.clickable_areas.items) |area| {
        if (app.cursor_y >= area.y_start and app.cursor_y <= area.y_end) {
            return area;
        }
    }
    return null;
}

pub fn handleInput(
    app: *main.App,
    input: []const u8,
    note_to_open: *?[]const u8,
    should_redraw: *bool,
) !bool { // Returns true if the app should quit.
    if (input.len == 1) {
        switch (input[0]) {
            'q' => return true,
            'j' => {
                if (findCursorIndex(app)) |idx| {
                    if (idx + 1 < app.valid_cursor_positions.items.len) {
                        app.cursor_y = app.valid_cursor_positions.items[idx + 1];
                        should_redraw.* = true;
                    }
                }
            },
            'k' => {
                if (findCursorIndex(app)) |idx| {
                    if (idx > 0) {
                        app.cursor_y = app.valid_cursor_positions.items[idx - 1];
                        should_redraw.* = true;
                    }
                }
            },
            '\r' => {
                if (findAreaAtCursor(app)) |area| {
                    note_to_open.* = area.note.path;
                }
            },
            ' ' => {
                if (findAreaAtCursor(app)) |area| {
                    area.note.is_expanded = !area.note.is_expanded;
                    if (!area.note.is_expanded) {
                        app.cursor_y = area.y_start;
                    }
                    should_redraw.* = true;
                }
            },
            else => {},
        }
    }

    if (input.len >= 6 and mem.eql(u8, input[0..3], "\x1b[M")) {
        const button = input[3];
        const col = input[4] - 32;
        const row = input[5] - 32;

        for (app.clickable_areas.items) |area| {
            const clicked_y = @as(usize, row) + app.scroll_y - 1;
            if (clicked_y >= area.y_start and clicked_y <= area.y_end and col >= area.x_start and col <= area.x_end) {
                switch (button) {
                    32 => { // Left-click
                        note_to_open.* = area.note.path;
                    },
                    34 => { // Right-click
                        area.note.is_expanded = !area.note.is_expanded;
                        if (!area.note.is_expanded) {
                            app.cursor_y = area.y_start;
                        }
                        should_redraw.* = true;
                    },
                    else => {},
                }
                break;
            }
        }
    }

    return false; // Do not quit
}
// --- END: Merged from actions.zig ---
