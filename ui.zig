// --- ui.zig ---
// Manages terminal state, input, and drawing.
const std = @import("std");
const mem = std.mem;
const app_module = @import("app");
const types_module = @import("types");
const tree = @import("tree");
const markdown = @import("markdown");
const config_editor_state = @import("config_editor_state");

// --- START: Merged from c_api.zig ---
pub const c = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("sys/ioctl.h");
    @cInclude("signal.h");
});
// --- END: Merged from c_api.zig ---

// Global flag for resize detection (volatile for signal safety)
pub var resize_pending: bool = false;

// Signal handler for SIGWINCH (window resize)
fn handleSigwinch(sig: c_int) callconv(.c) void {
    _ = sig;
    resize_pending = true;
}

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

        // Install SIGWINCH handler for window resize detection
        var sa: c.struct_sigaction = std.mem.zeroes(c.struct_sigaction);
        // Linux glibc uses anonymous union - access via __sigaction_handler
        sa.__sigaction_handler = .{ .sa_handler = handleSigwinch };
        _ = c.sigemptyset(&sa.sa_mask);
        sa.sa_flags = 0;
        _ = c.sigaction(c.SIGWINCH, &sa, null);

        // Enable: hide cursor, SGR mouse mode (1006), normal mouse tracking (1000)
        _ = try std.posix.write(std.posix.STDOUT_FILENO, "\x1b[?25l\x1b[?1006h\x1b[?1000h");
    }

    pub fn disableRawMode(self: *const Tui) void {
        _ = c.tcsetattr(c.STDIN_FILENO, c.TCSAFLUSH, &self.orig_termios);
        _ = std.posix.write(std.posix.STDOUT_FILENO, "\x1b[?25h\x1b[?1006l\x1b[?1000l") catch {};
    }

    pub fn getTerminalSize() !TerminalSize {
        // Check if stdout is actually a terminal first
        if (c.isatty(c.STDOUT_FILENO) == 0) {
            // Not a terminal (piped, redirected, or --help), return default size
            return TerminalSize{ .width = 80, .height = 24 };
        }

        var ws: c.struct_winsize = undefined;
        if (c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &ws) == -1 or ws.ws_col == 0) {
            return error.IoctlFailed;
        }
        return TerminalSize{ .width = ws.ws_col, .height = ws.ws_row };
    }
};
// --- END: Merged from tui.zig ---

// Buffered stdout writer for Zig 0.15.1
pub const BufferedStdoutWriter = struct {
    buffer: []u8,
    pos: usize,

    pub fn init(buffer: []u8) BufferedStdoutWriter {
        return .{ .buffer = buffer, .pos = 0 };
    }

    pub const WriteError = error{};

    pub fn write(self: *BufferedStdoutWriter, bytes: []const u8) WriteError!usize {
        if (self.pos + bytes.len > self.buffer.len) {
            // Flush and continue
            self.flush() catch {};
            if (bytes.len > self.buffer.len) {
                // Write directly if too large for buffer
                _ = std.posix.write(std.posix.STDOUT_FILENO, bytes) catch return 0;
                return bytes.len;
            }
        }
        @memcpy(self.buffer[self.pos..][0..bytes.len], bytes);
        self.pos += bytes.len;
        return bytes.len;
    }

    pub const Writer = std.io.GenericWriter(*BufferedStdoutWriter, WriteError, write);

    pub fn writer(self: *BufferedStdoutWriter) Writer {
        return Writer{ .context = self };
    }

    pub fn flush(self: *BufferedStdoutWriter) !void {
        if (self.pos > 0) {
            _ = try std.posix.write(std.posix.STDOUT_FILENO, self.buffer[0..self.pos]);
            self.pos = 0;
        }
    }
};

// --- START: Merged from ansi.zig ---

/// Returns the display width of a Unicode codepoint
/// Emojis and wide characters return 2, regular characters return 1, zero-width returns 0
pub fn getCharWidth(codepoint: u21) usize {
    // Zero-width characters (these combine with previous characters)
    // =====================================================

    // Zero-Width Joiner (used in family emojis, professions, etc.)
    if (codepoint == 0x200D) return 0; // ZWJ

    // Zero-Width Non-Joiner
    if (codepoint == 0x200C) return 0; // ZWNJ

    // Variation Selectors (control emoji vs text presentation)
    if (codepoint >= 0xFE00 and codepoint <= 0xFE0F) return 0; // VS1-VS16
    if (codepoint >= 0xE0100 and codepoint <= 0xE01EF) return 0; // VS17-VS256

    // Skin Tone Modifiers (Fitzpatrick scale)
    if (codepoint >= 0x1F3FB and codepoint <= 0x1F3FF) return 0; // 🏻🏼🏽🏾🏿

    // Combining Diacritical Marks (accents, etc.)
    if (codepoint >= 0x0300 and codepoint <= 0x036F) return 0; // Combining marks
    if (codepoint >= 0x1AB0 and codepoint <= 0x1AFF) return 0; // Extended combining marks
    if (codepoint >= 0x1DC0 and codepoint <= 0x1DFF) return 0; // Combining marks supplement
    if (codepoint >= 0x20D0 and codepoint <= 0x20FF) return 0; // Combining marks for symbols
    if (codepoint >= 0xFE20 and codepoint <= 0xFE2F) return 0; // Combining half marks

    // Format characters
    if (codepoint >= 0x200B and codepoint <= 0x200F) return 0; // Zero-width space, LRM, RLM, etc.
    if (codepoint >= 0x2060 and codepoint <= 0x206F) return 0; // Word joiner, invisible operators

    // Control characters
    if (codepoint < 0x20) return 0; // C0 controls
    if (codepoint >= 0x7F and codepoint < 0xA0) return 0; // DEL and C1 controls

    // Emoji ranges (most common emojis occupy 2 columns in terminals)
    // =====================================================
    // Main emoji blocks
    if (codepoint >= 0x1F000 and codepoint <= 0x1F02F) return 2; // Mahjong Tiles
    if (codepoint >= 0x1F0A0 and codepoint <= 0x1F0FF) return 2; // Playing Cards
    if (codepoint >= 0x1F100 and codepoint <= 0x1F1FF) return 2; // Enclosed Alphanumeric Supplement
    if (codepoint >= 0x1F200 and codepoint <= 0x1F2FF) return 2; // Enclosed Ideographic Supplement
    if (codepoint >= 0x1F300 and codepoint <= 0x1F5FF) return 2; // Miscellaneous Symbols and Pictographs
    if (codepoint >= 0x1F600 and codepoint <= 0x1F64F) return 2; // Emoticons
    if (codepoint >= 0x1F680 and codepoint <= 0x1F6FF) return 2; // Transport and Map Symbols
    if (codepoint >= 0x1F700 and codepoint <= 0x1F77F) return 2; // Alchemical Symbols
    if (codepoint >= 0x1F780 and codepoint <= 0x1F7FF) return 2; // Geometric Shapes Extended
    if (codepoint >= 0x1F800 and codepoint <= 0x1F8FF) return 2; // Supplemental Arrows-C
    if (codepoint >= 0x1F900 and codepoint <= 0x1F9FF) return 2; // Supplemental Symbols and Pictographs
    if (codepoint >= 0x1FA00 and codepoint <= 0x1FA6F) return 2; // Chess Symbols
    if (codepoint >= 0x1FA70 and codepoint <= 0x1FAFF) return 2; // Symbols and Pictographs Extended-A

    // Miscellaneous Symbols (includes common emoji-style symbols)
    if (codepoint >= 0x2600 and codepoint <= 0x26FF) return 2;   // Miscellaneous Symbols (☀, ☂, ⛄, etc.)
    if (codepoint >= 0x2700 and codepoint <= 0x27BF) return 2;   // Dingbats (✂, ✈, ✉, ❤, etc.)

    // Additional symbol ranges that display as wide (emoji-style symbols only!)
    // Note: Most symbols in 0x2300-0x23FF are NARROW (APL, technical symbols)
    // Only specific emoji-presentation symbols from that range should be wide:
    if (codepoint >= 0x231A and codepoint <= 0x231B) return 2;   // ⌚⌛ Watch, Hourglass
    if (codepoint >= 0x23E9 and codepoint <= 0x23F3) return 2;   // ⏩⏪⏫⏬⏭⏮⏯⏰⏱⏲⏳ Media controls
    if (codepoint >= 0x25FD and codepoint <= 0x25FE) return 2;   // ◽◾ Small squares
    if (codepoint >= 0x2614 and codepoint <= 0x2615) return 2;   // ☔☕ Umbrella, Coffee
    if (codepoint >= 0x2648 and codepoint <= 0x2653) return 2;   // ♈-♓ Zodiac signs
    if (codepoint >= 0x2934 and codepoint <= 0x2935) return 2;   // ⤴⤵ Arrow symbols
    if (codepoint >= 0x2B05 and codepoint <= 0x2B07) return 2;   // ⬅⬆⬇ Heavy arrows
    if (codepoint >= 0x2B1B and codepoint <= 0x2B1C) return 2;   // ⬛⬜ Black/white squares
    if (codepoint >= 0x2B50 and codepoint <= 0x2B55) return 2;   // ⭐⭕ Star and circle symbols
    if (codepoint >= 0x3030 and codepoint <= 0x303D) return 2;   // 〰 Wavy dash, part alternation mark
    if (codepoint >= 0x3297 and codepoint <= 0x3299) return 2;   // ㊗㊙ Circled ideographs

    // East Asian Wide characters (CJK ideographs)
    // =====================================================
    if (codepoint >= 0x4E00 and codepoint <= 0x9FFF) return 2;   // CJK Unified Ideographs
    if (codepoint >= 0x3400 and codepoint <= 0x4DBF) return 2;   // CJK Extension A
    if (codepoint >= 0xAC00 and codepoint <= 0xD7AF) return 2;   // Hangul Syllables
    if (codepoint >= 0x3040 and codepoint <= 0x309F) return 2;   // Hiragana
    if (codepoint >= 0x30A0 and codepoint <= 0x30FF) return 2;   // Katakana

    // Most other Unicode characters are single width
    return 1;
}

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
        var in_zwj_sequence = false;
        var zwj_sequence_width: usize = 0;

        while (i < s.len) {
            const byte = s[i];
            switch (state) {
                .normal => {
                    if (byte == 0x1b) {
                        state = .got_escape;
                        i += 1;
                    } else {
                        // Decode UTF-8 character and get its width
                        const char_len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
                        if (i + char_len <= s.len) {
                            const codepoint = std.unicode.utf8Decode(s[i..][0..char_len]) catch {
                                i += 1;
                                count += 1;
                                continue;
                            };

                            const char_width = getCharWidth(codepoint);

                            // ZWJ sequence handling
                            if (codepoint == 0x200D) { // Zero-Width Joiner
                                in_zwj_sequence = true;
                                // Don't add width for ZWJ itself
                            } else if (in_zwj_sequence) {
                                // We're in a ZWJ sequence
                                if (char_width == 0) {
                                    // Zero-width modifier (skin tone, variation selector), continue sequence
                                } else if (char_width == 2) {
                                    // Another emoji in the sequence, but don't add its width
                                    // The entire ZWJ sequence should only count as width 2
                                } else {
                                    // Non-emoji character, end the sequence
                                    in_zwj_sequence = false;
                                    zwj_sequence_width = 0;
                                    count += char_width;
                                }
                            } else {
                                // Normal character or start of potential ZWJ sequence
                                if (char_width == 2) {
                                    zwj_sequence_width = 2;
                                }
                                count += char_width;
                            }

                            i += char_len;
                        } else {
                            i += 1;
                            count += 1;
                        }
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

// Global color configuration for UI elements (initialized at app startup)
pub var status_color: []const u8 = "\x1b[33m"; // Default yellow

/// Initialize UI color configuration from app config
/// Must be called once at app startup
pub fn initUIColors(status: []const u8) void {
    status_color = status;
}

pub fn drawTaskbar(app: *const app_module.App, writer: anytype) !void {
    try writer.print("\x1b[{d};1H", .{app.terminal_size.height});
    try writer.print("\x1b[2K", .{});

    if (app.permission_pending) {
        try writer.print("\x1b[33m⚠️  Permission Required:\x1b[0m Press \x1b[32mA\x1b[0m/\x1b[32mS\x1b[0m/\x1b[36mR\x1b[0m/\x1b[31mD\x1b[0m to respond", .{});
    } else if (app.streaming_active) {
        try writer.print("{s}AI is responding...\x1b[0m (wait for response to finish before sending) | Type '/quit' + Enter to exit", .{status_color});
    } else {
        try writer.print("Type '/quit' and press Enter to exit.", .{});
    }
}
// --- END: Merged from taskbar.zig ---

// --- START: Merged from actions.zig ---
fn findCursorIndex(app: *const app_module.App) ?usize {
    for (app.valid_cursor_positions.items, 0..) |pos, i| {
        if (pos == app.cursor_y) {
            return i;
        }
    }
    return null;
}

fn findAreaAtCursor(app: *const app_module.App) ?types_module.ClickableArea {
    for (app.clickable_areas.items) |area| {
        if (app.cursor_y >= area.y_start and app.cursor_y <= area.y_end) {
            return area;
        }
    }
    return null;
}

fn handleContextCommand(app: *app_module.App) !void {
    // Generate tree structure
    const tree_output = tree.generateTree(app.allocator, ".") catch return;
    defer app.allocator.free(tree_output);

    // Validate the tree output is valid UTF-8
    if (!std.unicode.utf8ValidateSlice(tree_output)) {
        return error.InvalidUtf8;
    }

    // Format message to LLM - requesting JSON response
    const prompt = try std.fmt.allocPrint(
        app.allocator,
        \\Here are all the files in this project as a JSON array:
        \\
        \\{s}
        \\
        \\Based on this file list, analyze the project structure and respond ONLY with valid JSON in this exact format (no markdown, no code blocks, just raw JSON):
        \\
        \\{{
        \\  "mainEntryPoints": ["list of main entry point files"],
        \\  "projectType": ["detected project types like 'zig', 'web', 'cli', etc."],
        \\  "keyDirectories": ["important directories in the project"],
        \\  "configFiles": ["configuration files found"]
        \\}}
        \\
        \\Return ONLY the JSON object, nothing else.
        ,
        .{tree_output},
    );
    defer app.allocator.free(prompt);

    // Send to LLM via existing sendMessage functionality with JSON format
    try app.sendMessage(prompt, "json");
}

pub fn handleInput(
    app: *app_module.App,
    input: []const u8,
    should_redraw: *bool,
) !bool { // Returns true if the app should quit.
    // Handle permission responses first (takes priority over normal input)
    if (app.permission_pending and input.len == 1) {
        const permission = @import("permission");
        switch (input[0]) {
            '1' => {
                app.permission_response = permission.PermissionMode.allow_once;
                app.permission_pending = false;
                should_redraw.* = true;
                return false;
            },
            '2' => {
                app.permission_response = permission.PermissionMode.ask_each_time; // Session grant
                app.permission_pending = false;
                should_redraw.* = true;
                return false;
            },
            '3' => {
                app.permission_response = permission.PermissionMode.always_allow; // Remember
                app.permission_pending = false;
                should_redraw.* = true;
                return false;
            },
            '4' => {
                app.permission_response = permission.PermissionMode.deny;
                app.permission_pending = false;
                should_redraw.* = true;
                return false;
            },
            else => {
                // Ignore other keys when permission is pending
                return false;
            },
        }
    }

    if (input.len == 1) {
        switch (input[0]) {
            '\r', '\n' => {
                // Enter key - check for commands or send message
                if (app.input_buffer.items.len > 0) {
                    // Check for /quit command
                    if (mem.eql(u8, app.input_buffer.items, "/quit")) {
                        return true; // Quit the application
                    }

                    // Check for /context command
                    if (mem.eql(u8, app.input_buffer.items, "/context")) {
                        app.input_buffer.clearRetainingCapacity();
                        should_redraw.* = true;
                        try handleContextCommand(app);
                        return false;
                    }

                    // Check for /toggle-toolcall-json command
                    if (mem.eql(u8, app.input_buffer.items, "/toggle-toolcall-json")) {
                        app.config.show_tool_json = !app.config.show_tool_json;
                        app.input_buffer.clearRetainingCapacity();
                        should_redraw.* = true;

                        // Show confirmation message
                        const status = if (app.config.show_tool_json) "visible" else "hidden";
                        const msg = try std.fmt.allocPrint(
                            app.allocator,
                            "Tool call JSON now {s}",
                            .{status},
                        );
                        const processed = try markdown.processMarkdown(app.allocator, msg);
                        try app.messages.append(app.allocator, .{
                            .role = .display_only_data,
                            .content = msg,
                            .processed_content = processed,
                            .thinking_expanded = false,
                            .timestamp = std.time.milliTimestamp(),
                        });

                        return false;
                    }

                    // Check for /config command
                    if (mem.eql(u8, app.input_buffer.items, "/config")) {
                        // Deinit existing config editor if present
                        if (app.config_editor) |*editor| {
                            editor.deinit();
                        }
                        app.config_editor = try config_editor_state.ConfigEditorState.init(
                            app.allocator,
                            &app.config,
                        );
                        app.input_buffer.clearRetainingCapacity();
                        should_redraw.* = true;
                        return false;
                    }

                    // Check for /agents command
                    if (mem.eql(u8, app.input_buffer.items, "/agents")) {
                        const agent_builder_state = @import("agent_builder_state");
                        // Deinit existing agent builder if present
                        if (app.agent_builder) |*builder| {
                            builder.deinit();
                        }
                        app.agent_builder = try agent_builder_state.AgentBuilderState.init(
                            app.allocator,
                        );
                        app.input_buffer.clearRetainingCapacity();
                        should_redraw.* = true;
                        return false;
                    }

                    // Check for /help command
                    if (mem.eql(u8, app.input_buffer.items, "/help")) {
                        const help_state = @import("help_state");
                        // Deinit existing help viewer if present
                        if (app.help_viewer) |*viewer| {
                            viewer.deinit();
                        }
                        app.help_viewer = try help_state.HelpState.init(
                            app.allocator,
                        );
                        app.input_buffer.clearRetainingCapacity();
                        should_redraw.* = true;
                        return false;
                    }

                    // Check for /profile commands
                    if (mem.startsWith(u8, app.input_buffer.items, "/profile") or mem.eql(u8, app.input_buffer.items, "/profiles")) {
                        const profile_commands = @import("profile_commands.zig");
                        var error_message: ?[]const u8 = null;
                        defer if (error_message) |msg| app.allocator.free(msg);

                        const result = try profile_commands.handleProfileCommand(app, app.input_buffer.items, &error_message);

                        switch (result) {
                            .success_redraw => {
                                app.input_buffer.clearRetainingCapacity();
                                should_redraw.* = true;
                                return false;
                            },
                            .open_ui => {
                                // Open profile UI modal
                                const profile_ui_state_module = @import("profile_ui_state");
                                if (app.profile_ui) |*ui_instance| {
                                    ui_instance.deinit();
                                }
                                app.profile_ui = try profile_ui_state_module.ProfileUIState.init(app.allocator);
                                app.input_buffer.clearRetainingCapacity();
                                should_redraw.* = true;
                                return false;
                            },
                            .@"error" => {
                                if (error_message) |msg| {
                                    std.debug.print("{s}\n", .{msg});
                                }
                                app.input_buffer.clearRetainingCapacity();
                                should_redraw.* = true;
                                return false;
                            },
                            .not_handled => {
                                // Fall through to normal message handling
                            },
                        }
                    }

                    // Don't send new messages while streaming is active
                    // User can type, but the message won't be sent until current stream finishes
                    if (app.streaming_active) {
                        // Optionally: could show a visual indicator or just ignore the Enter
                        // For now, we just don't send the message
                        return false;
                    }

                    // Send the message
                    const message_text = try app.allocator.dupe(u8, app.input_buffer.items);
                    defer app.allocator.free(message_text);

                    app.input_buffer.clearRetainingCapacity();
                    should_redraw.* = true;

                    // Send message and get response (non-blocking - runs in background thread)
                    try app.sendMessage(message_text, null);
                }
            },
            0x7F, 0x08 => { // Backspace (DEL or BS)
                if (app.input_buffer.items.len > 0) {
                    _ = app.input_buffer.pop();
                    should_redraw.* = true;
                }
            },
            0x0F => { // Ctrl+O - toggle thinking, tool call, or agent analysis at cursor position
                if (findAreaAtCursor(app)) |area| {
                    // Toggle agent analysis if present AND completed
                    if (area.message.agent_analysis_name != null and
                        area.message.agent_analysis_completed) {
                        area.message.agent_analysis_expanded = !area.message.agent_analysis_expanded;
                        // Removed dirty state tracking - rendering now automatic
                        should_redraw.* = true;
                    }
                    // Toggle thinking if present
                    else if (area.message.thinking_content != null) {
                        area.message.thinking_expanded = !area.message.thinking_expanded;
                        // Removed dirty state tracking - rendering now automatic
                        should_redraw.* = true;
                    }
                    // Toggle tool call if present
                    else if (area.message.tool_name != null) {
                        area.message.tool_call_expanded = !area.message.tool_call_expanded;
                        // Removed dirty state tracking - rendering now automatic
                        should_redraw.* = true;
                    }
                }
            },
            0x1B => { // Escape - clear input buffer
                if (app.input_buffer.items.len > 0) {
                    app.input_buffer.clearRetainingCapacity();
                    should_redraw.* = true;
                }
            },
            ' ' => {
                // Space always goes to input buffer in chat mode
                try app.input_buffer.append(app.allocator, ' ');
                should_redraw.* = true;
            },
            else => {
                // Printable ASCII characters go to input buffer
                if (input[0] >= 0x20 and input[0] <= 0x7E) {
                    try app.input_buffer.append(app.allocator, input[0]);
                    should_redraw.* = true;
                }
            },
        }
    }

    // SGR mouse parser - handles modern terminals with unlimited coordinates
    // Format: \x1b[<button;col;row;M (press) or m (release)
    if (input.len >= 6 and mem.eql(u8, input[0..3], "\x1b[<")) {
        var idx: usize = 3;

        // Parse button
        var button: u32 = 0;
        while (idx < input.len and input[idx] >= '0' and input[idx] <= '9') : (idx += 1) {
            button = button * 10 + (input[idx] - '0');
        }
        if (idx >= input.len or input[idx] != ';') return false;
        idx += 1;

        // Parse column
        var col: u32 = 0;
        while (idx < input.len and input[idx] >= '0' and input[idx] <= '9') : (idx += 1) {
            col = col * 10 + (input[idx] - '0');
        }
        if (idx >= input.len or input[idx] != ';') return false;
        idx += 1;

        // Parse row
        var row: u32 = 0;
        while (idx < input.len and input[idx] >= '0' and input[idx] <= '9') : (idx += 1) {
            row = row * 10 + (input[idx] - '0');
        }
        if (idx >= input.len or (input[idx] != 'M' and input[idx] != 'm')) return false;

        const is_press = input[idx] == 'M';

        // Only handle button press events
        if (is_press) {
            // Handle scroll wheel - move cursor like j/k navigation
            if (button == 64) { // Scroll up
                if (findCursorIndex(app)) |cursor_idx| {
                    // Move cursor up by scroll_lines positions
                    if (cursor_idx > 0) {
                        const scroll_amount = @min(app.config.scroll_lines, cursor_idx);
                        app.cursor_y = app.valid_cursor_positions.items[cursor_idx - scroll_amount];
                        // Removed dirty state tracking - rendering now automatic
                        should_redraw.* = true;

                        // Mark that user manually scrolled away (disables auto-scroll during streaming)
                        if (app.streaming_active) {
                            // Removed user_scrolled_away tracking
                        }
                    }
                } else if (app.valid_cursor_positions.items.len > 0) {
                    // Cursor not in valid positions - snap to nearest and scroll up
                    app.cursor_y = app.valid_cursor_positions.items[app.valid_cursor_positions.items.len - 1];
                    // Removed dirty state tracking - rendering now automatic
                    should_redraw.* = true;

                    // Mark that user manually scrolled away (disables auto-scroll during streaming)
                    if (app.streaming_active) {
                        // Removed user_scrolled_away tracking
                    }
                }
                return false;
            } else if (button == 65) { // Scroll down
                if (findCursorIndex(app)) |cursor_idx| {
                    // Move cursor down by scroll_lines positions
                    const max_idx = app.valid_cursor_positions.items.len - 1;
                    if (cursor_idx < max_idx) {
                        const scroll_amount = @min(app.config.scroll_lines, max_idx - cursor_idx);
                        app.cursor_y = app.valid_cursor_positions.items[cursor_idx + scroll_amount];
                        // Removed dirty state tracking - rendering now automatic
                        should_redraw.* = true;
                    }
                } else if (app.valid_cursor_positions.items.len > 0) {
                    // Cursor not in valid positions - snap to nearest and scroll down
                    app.cursor_y = app.valid_cursor_positions.items[0];
                    // Removed dirty state tracking - rendering now automatic
                    should_redraw.* = true;
                }
                return false;
            }

            // Mouse clicks no longer toggle thinking boxes - use Ctrl+O instead
            // This allows users to select/highlight text for copying
        }
    }

    // Legacy X10 fallback - supports older terminals (223 col/row limit)
    // Format: \x1b[M + 3 bytes (button, col-32, row-32)
    // Mouse clicks no longer toggle thinking boxes - use Ctrl+O instead

    return false; // Do not quit
}
// --- END: Merged from actions.zig ---
