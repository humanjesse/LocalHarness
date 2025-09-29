// --- main.zig (with Reverted Box Drawing Logic) ---
const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const process = std.process;
const ui = @import("ui.zig");
const markdown = @import("markdown.zig");

pub const Config = struct {
    notes_dir: []const u8 = "my_notes",
    editor_cmd: []const []const u8 = &.{ "nvim" },
};

pub const Note = struct {
    path: []const u8,
    processed_content: std.ArrayListUnmanaged(markdown.RenderableItem),
    is_expanded: bool = false,
};

pub const ClickableArea = struct {
    y_start: usize,
    y_end: usize,
    x_start: usize,
    x_end: usize,
    note: *Note,
};

fn openEditorAndWait(allocator: mem.Allocator, editor_cmd: []const []const u8, note_path: []const u8) !void {
    var argv = std.ArrayListUnmanaged([]const u8){};
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, editor_cmd);
    try argv.append(allocator, note_path);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    _ = term;
}

fn wrapRawText(allocator: mem.Allocator, text: []const u8, max_width: usize) !std.ArrayListUnmanaged([]const u8) {
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

            while (byte_idx < line.len) {
                if (line[byte_idx] == 0x1b) {
                    var end = byte_idx;
                    while (end < line.len and line[end] != 'm') : (end += 1) {}
                    byte_idx = end + 1;
                    continue;
                }

                const char_len = std.unicode.utf8ByteSequenceLength(line[byte_idx]) catch 1;

                if (max_width > 0 and visible_chars + 1 > max_width) {
                    break;
                }
                visible_chars += 1;
                if (line[byte_idx] == ' ') {
                    last_space_byte_pos = byte_idx;
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

// --- NEW RECURSIVE CONTENT RENDERER ---

fn renderItemsToLines(
    app: *App,
    items: *const std.ArrayListUnmanaged(markdown.RenderableItem),
    output_lines: *std.ArrayListUnmanaged([]const u8),
    indent_level: usize,
    max_content_width: usize,
) !void {
    const indent_str = "  ";

    for (items.items) |*item| {
        switch (item.tag) {
            .styled_text => {
                var wrapped_lines = try wrapRawText(app.allocator, item.payload.styled_text, max_content_width - (indent_level * indent_str.len));
                defer {
                    for (wrapped_lines.items) |l| app.allocator.free(l);
                    wrapped_lines.deinit(app.allocator);
                }

                for (wrapped_lines.items) |line| {
                    var full_line = std.ArrayListUnmanaged(u8){};
                    for (0..indent_level) |_| try full_line.appendSlice(app.allocator, indent_str);
                    try full_line.appendSlice(app.allocator, line);
                    try output_lines.append(app.allocator, try full_line.toOwnedSlice(app.allocator));
                }
            },
            .blockquote => {
                var sub_lines = std.ArrayListUnmanaged([]const u8){};
                defer {
                    for (sub_lines.items) |l| app.allocator.free(l);
                    sub_lines.deinit(app.allocator);
                }

                // Pre-calculate the total width of the prefix the parent will add.
                const prefix_width = (indent_level * indent_str.len) + 2;
                // Use saturating subtraction to prevent underflow.
                const sub_max_width = max_content_width -| prefix_width;
                try renderItemsToLines(app, &item.payload.blockquote, &sub_lines, 0, sub_max_width); 
                for (sub_lines.items) |line| {
                    var full_line = std.ArrayListUnmanaged(u8){};
                    // The parent adds the full prefix to the un-indented child line.
                    for (0..indent_level) |_| try full_line.appendSlice(app.allocator, indent_str);
                    try full_line.appendSlice(app.allocator, "┃ ");
                    try full_line.appendSlice(app.allocator, line);
                    try output_lines.append(app.allocator, try full_line.toOwnedSlice(app.allocator));
                    }
                },

               .list => {
    for (item.payload.list.items.items, 0..) |list_item_blocks, i| {
        // --- START: New logic to calculate dynamic padding ---
        var marker_buf: [16]u8 = undefined;
        var marker_text: []const u8 = undefined;
        if (item.payload.list.is_ordered) {
            marker_text = try std.fmt.bufPrint(&marker_buf, "{d}. ", .{item.payload.list.start_number + i});
        } else {
            marker_text = "• ";
        }
        
        var alignment_padding_buf = std.ArrayListUnmanaged(u8){};
        defer alignment_padding_buf.deinit(app.allocator);
        for (0..ui.AnsiParser.getVisibleLength(marker_text)) |_| {
            try alignment_padding_buf.append(app.allocator, ' ');
        }
        const alignment_padding = alignment_padding_buf.items;
        // --- END: New logic ---

        const prefix_width = (indent_level * indent_str.len) + alignment_padding.len;
        const sub_max_width = max_content_width -| prefix_width;

        var sub_lines = std.ArrayListUnmanaged([]const u8){};
        defer {
            for (sub_lines.items) |l| app.allocator.free(l);
            sub_lines.deinit(app.allocator);
        }

        try renderItemsToLines(app, &list_item_blocks, &sub_lines, 0, sub_max_width);

        for (sub_lines.items, 0..) |line, line_idx| {
            var full_line = std.ArrayListUnmanaged(u8){};
            for (0..indent_level) |_| try full_line.appendSlice(app.allocator, indent_str);

            if (line_idx == 0) {
                try full_line.appendSlice(app.allocator, marker_text);
            } else {
                // Use the new dynamic padding for alignment
                try full_line.appendSlice(app.allocator, alignment_padding);
            }
            try full_line.appendSlice(app.allocator, line);
            try output_lines.append(app.allocator, try full_line.toOwnedSlice(app.allocator));
        }
    }
}, 

                        .horizontal_rule => {
                var hr_line = std.ArrayListUnmanaged(u8){};
                for (0..indent_level) |_| try hr_line.appendSlice(app.allocator, indent_str);
                for (0..(max_content_width / 2)) |_| try hr_line.appendSlice(app.allocator, "─");
                try output_lines.append(app.allocator, try hr_line.toOwnedSlice(app.allocator));
            },
            .code_block => {
                 var box_lines = std.ArrayListUnmanaged([]const u8){};
                 defer {
                    box_lines.deinit(app.allocator);
                 }
                 var content_lines = try wrapRawText(app.allocator, item.payload.code_block.content, max_content_width - (indent_level * indent_str.len) - 4);
                 defer {
                    for(content_lines.items) |l| app.allocator.free(l);
                    content_lines.deinit(app.allocator);
                 }
                 var max_line_len : usize = 0;
                 for(content_lines.items) |l| {
                    const len = ui.AnsiParser.getVisibleLength(l);
                    if (len > max_line_len) max_line_len = len;
                 }

                 // Top border
                 var top_border = std.ArrayListUnmanaged(u8){};
                 for (0..indent_level) |_| try top_border.appendSlice(app.allocator,indent_str);
                 try top_border.appendSlice(app.allocator,"┌");
                 for(0..max_line_len+2) |_| try top_border.appendSlice(app.allocator,"─");
                 try top_border.appendSlice(app.allocator,"┐");
                 try box_lines.append(app.allocator, try top_border.toOwnedSlice(app.allocator));

                 // Content
                 for(content_lines.items) |l| {
                    var content_line = std.ArrayListUnmanaged(u8){};
                    for (0..indent_level) |_| try content_line.appendSlice(app.allocator,indent_str);
                    try content_line.appendSlice(app.allocator,"│ ");
                    try content_line.appendSlice(app.allocator,l);
                    const padding = max_line_len - ui.AnsiParser.getVisibleLength(l);
                    for(0..padding) |_| try content_line.appendSlice(app.allocator," ");
                    try content_line.appendSlice(app.allocator," │");
                    try box_lines.append(app.allocator, try content_line.toOwnedSlice(app.allocator));
                 }

                 // Bottom border
                 var bot_border = std.ArrayListUnmanaged(u8){};
                 for (0..indent_level) |_| try bot_border.appendSlice(app.allocator,indent_str);
                 try bot_border.appendSlice(app.allocator,"└");
                 for(0..max_line_len+2) |_| try bot_border.appendSlice(app.allocator,"─");
                 try bot_border.appendSlice(app.allocator,"┘");
                 try box_lines.append(app.allocator, try bot_border.toOwnedSlice(app.allocator));

                 try output_lines.appendSlice(app.allocator,box_lines.items);
            },
            .link => {
                const link_text = item.payload.link.text;
                const link_url = item.payload.link.url;

                // Format: "Link Text" (URL) with underline styling
                var formatted_text = std.ArrayListUnmanaged(u8){};
                defer formatted_text.deinit(app.allocator);

                try formatted_text.appendSlice(app.allocator,"\x1b[4m"); // Start underline
                try formatted_text.appendSlice(app.allocator,"\x1b[36m"); // Cyan color
                try formatted_text.appendSlice(app.allocator,link_text);
                try formatted_text.appendSlice(app.allocator,"\x1b[0m");  // Reset
                try formatted_text.appendSlice(app.allocator," (");
                try formatted_text.appendSlice(app.allocator,link_url);
                try formatted_text.appendSlice(app.allocator,")");

                var wrapped_lines = try wrapRawText(app.allocator, formatted_text.items, max_content_width - (indent_level * indent_str.len));
                defer {
                    for (wrapped_lines.items) |l| app.allocator.free(l);
                    wrapped_lines.deinit(app.allocator);
                }

                for (wrapped_lines.items) |line| {
                    var full_line = std.ArrayListUnmanaged(u8){};
                    for (0..indent_level) |_| try full_line.appendSlice(app.allocator, indent_str);
                    try full_line.appendSlice(app.allocator, line);
                    try output_lines.append(app.allocator, try full_line.toOwnedSlice(app.allocator));
                }
            },
             .blank_line => {
                try output_lines.append(app.allocator, try app.allocator.dupe(u8, ""));
            },
        }
    }
}


fn drawExpandedNote(
    app: *App,
    writer: anytype,
    note: *Note,
    note_index: usize,
    absolute_y: *usize,
) !void {
    const left_padding = 2;
    const y_start = absolute_y.*;

    const max_content_width = if (app.terminal_size.width > left_padding + 4) app.terminal_size.width - left_padding - 4 else 0;

    // Step 1: Recursively render all content into a simple list of lines.
    var content_lines = std.ArrayListUnmanaged([]const u8){};
    defer {
        for (content_lines.items) |line| app.allocator.free(line);
        content_lines.deinit(app.allocator);
    }
    try renderItemsToLines(app, &note.processed_content, &content_lines, 0, max_content_width);

    // Step 2: Draw the box around the rendered lines using the classic logic.
    const box_height = content_lines.items.len + 2;

    for (0..box_height) |line_idx| {
        const current_absolute_y = absolute_y.* + line_idx;
        try app.valid_cursor_positions.append(app.allocator, current_absolute_y);

        if (current_absolute_y >= app.scroll_y and current_absolute_y - app.scroll_y < app.terminal_size.height - 1) {
            const screen_y = (current_absolute_y - app.scroll_y) + 1;
            
            // Draw cursor
            if (current_absolute_y == app.cursor_y) try writer.print("\x1b[{d};1H>", .{screen_y}) else try writer.print("\x1b[{d};1H ", .{screen_y});
            
            // Move to start of box
            try writer.print("\x1b[{d}G", .{left_padding + 1});

            if (line_idx == 0) {
                try writer.writeAll("┌");
                for (0..max_content_width + 2) |_| try writer.writeAll("─");
                try writer.writeAll("┐");
            } else if (line_idx == box_height - 1) {
                try writer.writeAll("└");
                for (0..max_content_width + 2) |_| try writer.writeAll("─");
                try writer.writeAll("┘");
            } else {
                const line_text = content_lines.items[line_idx - 1];
                const line_len = ui.AnsiParser.getVisibleLength(line_text);
                try writer.writeAll("│ ");
                try writer.writeAll(line_text);
                const padding = max_content_width - line_len;
                for (0..padding) |_| try writer.writeAll(" ");
                try writer.writeAll(" │");
            }
        }
    }
    absolute_y.* += box_height + 1;

    try app.clickable_areas.append(app.allocator, .{
        .y_start = y_start,
        .y_end = absolute_y.* - 2,
        .x_start = 1,
        .x_end = app.terminal_size.width,
        .note = &app.notes.items[note_index],
    });
}

fn drawCollapsedNote(
    app: *App,
    writer: anytype,
    note: *Note,
    note_index: usize,
    absolute_y: *usize,
) !void {
    const left_padding = 2;
    const current_absolute_y = absolute_y.*;
    try app.valid_cursor_positions.append(app.allocator, current_absolute_y);

    if (current_absolute_y >= app.scroll_y and current_absolute_y - app.scroll_y < app.terminal_size.height - 1) {
        const screen_y = (current_absolute_y - app.scroll_y) + 1;
        if (current_absolute_y == app.cursor_y) {
            try writer.print("\x1b[{d};1H>", .{screen_y});
        } else {
             try writer.print("\x1b[{d};1H ", .{screen_y});
        }
        try writer.print("\x1b[{d}G", .{left_padding + 1});
        const filename = fs.path.basename(note.path);
        try writer.print("[ {s} ]", .{filename});
    }
    try app.clickable_areas.append(app.allocator, .{
        .y_start = absolute_y.*,
        .y_end = absolute_y.*,
        .x_start = left_padding + 1,
        .x_end = left_padding + 1 + fs.path.basename(note.path).len + 4,
        .note = &app.notes.items[note_index],
    });
    absolute_y.* += 2;
}

pub const App = struct {
    allocator: mem.Allocator,
    config: Config,
    notes: std.ArrayListUnmanaged(Note),
    clickable_areas: std.ArrayListUnmanaged(ClickableArea),
    scroll_y: usize = 0,
    cursor_y: usize = 1,
    terminal_size: ui.TerminalSize,
    valid_cursor_positions: std.ArrayListUnmanaged(usize),

    pub fn init(allocator: mem.Allocator, config: Config) !App {
        var app = App{
            .allocator = allocator,
            .config = config,
            .notes = .{},
            .clickable_areas = .{},
            .terminal_size = try ui.Tui.getTerminalSize(),
            .valid_cursor_positions = .{},
        };
        const dir_path = app.config.notes_dir;
        std.fs.cwd().makeDir(dir_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
        var dir = try fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind == .file) {
                const file_path = try fs.path.join(allocator, &.{ dir_path, entry.name });
                defer allocator.free(file_path);

                var file = dir.openFile(entry.name, .{}) catch |err| {
                    std.debug.print("Failed to open file {s}: {any}\n", .{ file_path, err });
                    continue;
                };
                defer file.close();

                const content_raw = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
                    std.debug.print("Failed to read file {s}: {any}\n", .{ file_path, err });
                    continue;
                };
                defer allocator.free(content_raw);

                const content_rn_fixed = try mem.replaceOwned(u8, allocator, content_raw, "\r\n", "\n");
                defer allocator.free(content_rn_fixed);
                const content_r_fixed = try mem.replaceOwned(u8, allocator, content_rn_fixed, "\r", "\n");
                defer allocator.free(content_r_fixed);

                const content_processed = try markdown.processMarkdown(allocator, content_r_fixed);
                const owned_path = try allocator.dupe(u8, file_path);

                try app.notes.append(app.allocator, .{ .path = owned_path, .processed_content = content_processed });
            }
        }
        return app;
    }

    pub fn deinit(self: *App) void {
        for (self.notes.items) |*note| {
            self.allocator.free(note.path);
            for (note.processed_content.items) |*item| {
                item.deinit(self.allocator);
            }
            note.processed_content.deinit(self.allocator);
        }
        self.notes.deinit(self.allocator);
        self.clickable_areas.deinit(self.allocator);
        self.valid_cursor_positions.deinit(self.allocator);
    }

    pub fn run(self: *App, app_tui: *ui.Tui) !void {
        while (true) {
            self.terminal_size = try ui.Tui.getTerminalSize();
            var stdout_buffer: [8192]u8 = undefined;
            var buffered_writer = ui.BufferedStdoutWriter.init(&stdout_buffer);
            const writer = buffered_writer.writer();
            try writer.writeAll("\x1b[2J");
            self.clickable_areas.clearRetainingCapacity();
            self.valid_cursor_positions.clearRetainingCapacity();

            var absolute_y: usize = 1;
            for (self.notes.items, 0..) |_, i| {
                const note = &self.notes.items[i];
                if (note.is_expanded) {
                    try drawExpandedNote(self, writer, note, i, &absolute_y);
                } else {
                    try drawCollapsedNote(self, writer, note, i, &absolute_y);
                }
            }

            try ui.drawTaskbar(self, writer);
            try buffered_writer.flush();
            var note_to_open: ?[]const u8 = null;
            var should_redraw = false;
            while (!should_redraw) {
                var read_buffer: [128]u8 = undefined;
                const bytes_read = ui.c.read(ui.c.STDIN_FILENO, &read_buffer, read_buffer.len);
                if (bytes_read <= 0) continue;
                const input = read_buffer[0..@intCast(bytes_read)];
                if (try ui.handleInput(self, input, &note_to_open, &should_redraw)) {
                    return;
                }

                if (note_to_open != null) break;
            }

            const view_height = self.terminal_size.height - 1;
            if (self.cursor_y < self.scroll_y + 1) {
                self.scroll_y = self.cursor_y - 1;
            }
            if (self.cursor_y > self.scroll_y + view_height) {
                self.scroll_y = self.cursor_y - view_height;
            }

            if (note_to_open) |note_path| {
                app_tui.disableRawMode();
                openEditorAndWait(self.allocator, self.config.editor_cmd, note_path) catch |err| {
                    try app_tui.enableRawMode();
                    std.debug.print("Failed to open editor: {any}\n", .{err});
                };
                try app_tui.enableRawMode();

                for (self.notes.items, 0..) |_, i| {
                    if (mem.eql(u8, self.notes.items[i].path, note_path)) {
                        var note = &self.notes.items[i];
                        for (note.processed_content.items) |*item| {
                            item.deinit(self.allocator);
                        }
                        note.processed_content.deinit(self.allocator);
                        
                        var dir = try fs.cwd().openDir(fs.path.dirname(note.path).?, .{});
                        var file = dir.openFile(fs.path.basename(note.path), .{}) catch |err| {
                            std.debug.print("Failed to reopen file {s} for reloading: {any}\n", .{note.path, err});
                            note.processed_content = std.ArrayListUnmanaged(markdown.RenderableItem){};
                            continue;
                        };
                        defer file.close();

                        const content_raw = file.readToEndAlloc(self.allocator, 1024 * 1024) catch |err| {
                            std.debug.print("Failed to re-read file {s}: {any}\n", .{note.path, err});
                            note.processed_content = std.ArrayListUnmanaged(markdown.RenderableItem){};
                            continue;
                        };
                        defer self.allocator.free(content_raw);

                        const content_rn_fixed = try mem.replaceOwned(u8, self.allocator, content_raw, "\r\n", "\n");
                        defer self.allocator.free(content_rn_fixed);
                        const content_r_fixed = try mem.replaceOwned(u8, self.allocator, content_rn_fixed, "\r", "\n");
                        defer self.allocator.free(content_r_fixed);

                        note.processed_content = try markdown.processMarkdown(self.allocator, content_r_fixed);
                        break;
                    }
                }
            }
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var config = Config{};
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--notes-dir")) {
            if (args.next()) |path| {
                config.notes_dir = path;
            } else {
                std.debug.print("Error: --notes-dir flag requires a path argument.\n", .{});
                return;
            }
        }
    }

    var app = App.init(allocator, config) catch |err| {
        std.debug.print("Application initialization failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer app.deinit();
    var app_tui = ui.Tui{ .orig_termios = undefined };
    try app_tui.enableRawMode();
    defer app_tui.disableRawMode();

    try app.run(&app_tui);
}
