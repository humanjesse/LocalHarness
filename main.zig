// --- main.zig (Chat Interface with Ollama) ---
const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const process = std.process;
const ui = @import("ui.zig");
const markdown = @import("markdown.zig");
const ollama = @import("ollama.zig");

pub const Config = struct {
    ollama_host: []const u8 = "http://localhost:11434",
    model: []const u8 = "gpt-oss:120b",
    editor: []const []const u8 = &.{"nvim"},

    pub fn deinit(self: *Config, allocator: mem.Allocator) void {
        allocator.free(self.ollama_host);
        allocator.free(self.model);
        for (self.editor) |arg| {
            allocator.free(arg);
        }
        allocator.free(self.editor);
    }
};

pub const Message = struct {
    role: enum { user, assistant, system },
    content: []const u8, // Raw markdown text
    processed_content: std.ArrayListUnmanaged(markdown.RenderableItem),
    is_expanded: bool = true, // Default expanded for chat messages
    timestamp: i64,
};

pub const ClickableArea = struct {
    y_start: usize,
    y_end: usize,
    x_start: usize,
    x_end: usize,
    message: *Message,
};

fn openEditorAndWait(allocator: mem.Allocator, editor: []const []const u8, note_path: []const u8) !void {
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

fn truncateTextToWidth(allocator: mem.Allocator, text: []const u8, max_width: usize) ![]const u8 {
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
            .table => {
                const table = item.payload.table;
                const column_count = table.column_count;

                // Calculate column widths (minimum 8, based on content)
                var col_widths = try app.allocator.alloc(usize, column_count);
                defer app.allocator.free(col_widths);

                // Initialize with minimum widths
                for (col_widths) |*w| w.* = 8;

                // Check header widths
                for (table.headers, 0..) |header, i| {
                    const len = ui.AnsiParser.getVisibleLength(header);
                    if (len > col_widths[i]) col_widths[i] = len;
                }

                // Check body cell widths
                for (table.rows, 0..) |cell_text, idx| {
                    const col_idx = idx % column_count;
                    const len = ui.AnsiParser.getVisibleLength(cell_text);
                    if (len > col_widths[col_idx]) col_widths[col_idx] = len;
                }

                // Adjust if total width exceeds available
                const indent_width = indent_level * indent_str.len;
                const available_width = if (max_content_width > indent_width) max_content_width - indent_width else 0;

                // Calculate total width needed: borders + padding + content
                // Format: "│ content │ content │" = (column_count + 1) borders + column_count * 2 spaces + sum(widths)
                var total_width: usize = column_count + 1; // borders
                for (col_widths) |w| total_width += w + 2; // content + padding

                // Guard against underflow: ensure available_width can accommodate borders
                const min_required_width = (column_count * 3) + (column_count + 1) + (column_count * 2); // min 3 chars per col + borders + padding
                if (total_width > available_width and available_width > min_required_width) {
                    // Distribute width proportionally
                    const scale_factor = @as(f32, @floatFromInt(available_width - min_required_width)) / @as(f32, @floatFromInt(total_width - min_required_width));
                    for (col_widths) |*w| {
                        const scaled = @as(usize, @intFromFloat(@as(f32, @floatFromInt(w.*)) * scale_factor));
                        w.* = if (scaled < 3) 3 else scaled; // Minimum 3 chars per column
                    }

                    // Recalculate total width after scaling
                    var new_total_width: usize = column_count + 1;
                    for (col_widths) |w| new_total_width += w + 2;

                    // If still too wide (due to minimum width constraints), shrink columns iteratively
                    while (new_total_width > available_width) {
                        // Find the widest column and shrink it by 1
                        var max_width: usize = 0;
                        var max_idx: usize = 0;
                        for (col_widths, 0..) |w, i| {
                            if (w > max_width) {
                                max_width = w;
                                max_idx = i;
                            }
                        }

                        // If all columns are at minimum, break to prevent infinite loop
                        if (max_width <= 3) break;

                        col_widths[max_idx] -= 1;
                        new_total_width -= 1;
                    }
                } else if (available_width <= min_required_width) {
                    // Terminal too narrow for table - use minimum widths
                    for (col_widths) |*w| w.* = 3;
                }

                // Top border
                var top_border = std.ArrayListUnmanaged(u8){};
                defer top_border.deinit(app.allocator);
                for (0..indent_level) |_| try top_border.appendSlice(app.allocator, indent_str);
                try top_border.appendSlice(app.allocator, "┌");
                for (col_widths, 0..) |width, i| {
                    for (0..width + 2) |_| try top_border.appendSlice(app.allocator, "─");
                    if (i < column_count - 1) {
                        try top_border.appendSlice(app.allocator, "┬");
                    }
                }
                try top_border.appendSlice(app.allocator, "┐");
                try output_lines.append(app.allocator, try top_border.toOwnedSlice(app.allocator));

                // Header row
                var header_line = std.ArrayListUnmanaged(u8){};
                defer header_line.deinit(app.allocator);
                for (0..indent_level) |_| try header_line.appendSlice(app.allocator, indent_str);
                try header_line.appendSlice(app.allocator, "│");
                for (table.headers, 0..) |header, i| {
                    try header_line.appendSlice(app.allocator, " ");

                    // Truncate header to fit column width
                    const truncated_header = try truncateTextToWidth(app.allocator, header, col_widths[i]);
                    defer app.allocator.free(truncated_header);

                    const content_len = ui.AnsiParser.getVisibleLength(truncated_header);
                    const padding = if (content_len >= col_widths[i]) 0 else col_widths[i] - content_len;

                    // Apply alignment
                    const alignment = table.alignments[i];
                    if (alignment == .center) {
                        const left_pad = padding / 2;
                        const right_pad = padding - left_pad;
                        for (0..left_pad) |_| try header_line.appendSlice(app.allocator, " ");
                        try header_line.appendSlice(app.allocator, truncated_header);
                        for (0..right_pad) |_| try header_line.appendSlice(app.allocator, " ");
                    } else if (alignment == .right) {
                        for (0..padding) |_| try header_line.appendSlice(app.allocator, " ");
                        try header_line.appendSlice(app.allocator, truncated_header);
                    } else { // left
                        try header_line.appendSlice(app.allocator, truncated_header);
                        for (0..padding) |_| try header_line.appendSlice(app.allocator, " ");
                    }

                    try header_line.appendSlice(app.allocator, " │");
                }
                try output_lines.append(app.allocator, try header_line.toOwnedSlice(app.allocator));

                // Header separator
                var separator = std.ArrayListUnmanaged(u8){};
                defer separator.deinit(app.allocator);
                for (0..indent_level) |_| try separator.appendSlice(app.allocator, indent_str);
                try separator.appendSlice(app.allocator, "├");
                for (col_widths, 0..) |width, i| {
                    for (0..width + 2) |_| try separator.appendSlice(app.allocator, "─");
                    if (i < column_count - 1) {
                        try separator.appendSlice(app.allocator, "┼");
                    }
                }
                try separator.appendSlice(app.allocator, "┤");
                try output_lines.append(app.allocator, try separator.toOwnedSlice(app.allocator));

                // Body rows - with multi-line cell support
                const row_count = table.rows.len / column_count;
                for (0..row_count) |row_idx| {
                    // Wrap all cells in this row
                    var wrapped_cells = try app.allocator.alloc(std.ArrayListUnmanaged([]const u8), column_count);
                    defer {
                        for (wrapped_cells) |*cell_lines| {
                            for (cell_lines.items) |line| app.allocator.free(line);
                            cell_lines.deinit(app.allocator);
                        }
                        app.allocator.free(wrapped_cells);
                    }

                    // Wrap each cell's text and find max line count
                    // Wrap to (col_width - 2) to leave room for continuation line indent
                    var max_lines: usize = 1;
                    for (0..column_count) |col_idx| {
                        const cell_idx = row_idx * column_count + col_idx;
                        const cell_text = table.rows[cell_idx];

                        // Reserve 2 chars for indent on continuation lines
                        const wrap_width = if (col_widths[col_idx] >= 2) col_widths[col_idx] - 2 else col_widths[col_idx];
                        wrapped_cells[col_idx] = try wrapRawText(app.allocator, cell_text, wrap_width);
                        if (wrapped_cells[col_idx].items.len > max_lines) {
                            max_lines = wrapped_cells[col_idx].items.len;
                        }
                    }

                    // Render each line of the row
                    for (0..max_lines) |line_idx| {
                        var row_line = std.ArrayListUnmanaged(u8){};
                        defer row_line.deinit(app.allocator);
                        for (0..indent_level) |_| try row_line.appendSlice(app.allocator, indent_str);
                        try row_line.appendSlice(app.allocator, "│");

                        for (0..column_count) |col_idx| {
                            try row_line.appendSlice(app.allocator, " ");

                            const cell_lines = wrapped_cells[col_idx].items;
                            const cell_content = if (line_idx < cell_lines.len) blk: {
                                // Add indentation for continuation lines (not the first line)
                                if (line_idx > 0) {
                                    var indented = std.ArrayListUnmanaged(u8){};
                                    try indented.appendSlice(app.allocator, "  ");  // 2-space indent
                                    try indented.appendSlice(app.allocator, cell_lines[line_idx]);
                                    break :blk try indented.toOwnedSlice(app.allocator);
                                } else {
                                    break :blk try app.allocator.dupe(u8, cell_lines[line_idx]);
                                }
                            } else blk: {
                                break :blk try app.allocator.dupe(u8, "");
                            };
                            defer app.allocator.free(cell_content);

                            const content_len = ui.AnsiParser.getVisibleLength(cell_content);
                            const padding = if (content_len >= col_widths[col_idx]) 0 else col_widths[col_idx] - content_len;

                            const alignment = table.alignments[col_idx];
                            if (alignment == .center and line_idx == 0) {  // Only center first line
                                const left_pad = padding / 2;
                                const right_pad = padding - left_pad;
                                for (0..left_pad) |_| try row_line.appendSlice(app.allocator, " ");
                                try row_line.appendSlice(app.allocator, cell_content);
                                for (0..right_pad) |_| try row_line.appendSlice(app.allocator, " ");
                            } else if (alignment == .right and line_idx == 0) {  // Only right-align first line
                                for (0..padding) |_| try row_line.appendSlice(app.allocator, " ");
                                try row_line.appendSlice(app.allocator, cell_content);
                            } else {  // left (or continuation lines)
                                try row_line.appendSlice(app.allocator, cell_content);
                                for (0..padding) |_| try row_line.appendSlice(app.allocator, " ");
                            }

                            try row_line.appendSlice(app.allocator, " │");
                        }

                        try output_lines.append(app.allocator, try row_line.toOwnedSlice(app.allocator));
                    }
                }

                // Bottom border
                var bottom_border = std.ArrayListUnmanaged(u8){};
                defer bottom_border.deinit(app.allocator);
                for (0..indent_level) |_| try bottom_border.appendSlice(app.allocator, indent_str);
                try bottom_border.appendSlice(app.allocator, "└");
                for (col_widths, 0..) |width, i| {
                    for (0..width + 2) |_| try bottom_border.appendSlice(app.allocator, "─");
                    if (i < column_count - 1) {
                        try bottom_border.appendSlice(app.allocator, "┴");
                    }
                }
                try bottom_border.appendSlice(app.allocator, "┘");
                try output_lines.append(app.allocator, try bottom_border.toOwnedSlice(app.allocator));
            },
             .blank_line => {
                try output_lines.append(app.allocator, try app.allocator.dupe(u8, ""));
            },
        }
    }
}


fn drawExpandedMessage(
    app: *App,
    writer: anytype,
    message: *Message,
    message_index: usize,
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
    try renderItemsToLines(app, &message.processed_content, &content_lines, 0, max_content_width);

    // Step 2: Draw the box around the rendered lines using the classic logic.
    const box_height = content_lines.items.len + 2;

    for (0..box_height) |line_idx| {
        const current_absolute_y = absolute_y.* + line_idx;
        try app.valid_cursor_positions.append(app.allocator, current_absolute_y);

        // Render only rows 1 to height-4 (leaves space for separator, input, status bar)
        if (current_absolute_y >= app.scroll_y and current_absolute_y - app.scroll_y <= app.terminal_size.height - 4) {
            const screen_y = (current_absolute_y - app.scroll_y) + 1;

            // Draw cursor (with ANSI reset and extra space to clear column 2)
            if (current_absolute_y == app.cursor_y) try writer.print("\x1b[{d};1H\x1b[0m> ", .{screen_y}) else try writer.print("\x1b[{d};1H\x1b[0m  ", .{screen_y});
            
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
                const padding = if (line_len >= max_content_width) 0 else max_content_width - line_len;
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
        .message = &app.messages.items[message_index],
    });
}

fn drawInputField(app: *App, writer: anytype) !void {
    const height = app.terminal_size.height;
    const width = app.terminal_size.width;

    // Input field occupies rows: height-3, height-2, height-1
    // Row height-1 is status bar (handled by drawTaskbar)
    // Row height-2 is input box
    // Row height-3 is separator

    const separator_row = height - 2;
    const input_row = height - 1;

    // Draw separator
    try writer.print("\x1b[{d};1H", .{separator_row});
    for (0..width) |_| try writer.writeAll("─");

    // Draw input box
    try writer.print("\x1b[{d};1H> ", .{input_row});

    // Show input buffer content
    const max_display = width - 3; // Account for "> " prompt
    const buffer_text = if (app.input_buffer.items.len > max_display)
        app.input_buffer.items[app.input_buffer.items.len - max_display..]
    else
        app.input_buffer.items;

    try writer.writeAll(buffer_text);

    // Show cursor at end of input
    if (app.input_buffer.items.len < max_display) {
        try writer.writeAll("_"); // Visual cursor
    }

    // Clear to end of line (removes any leftover characters from previous input)
    try writer.writeAll("\x1b[K");
}

fn drawCollapsedMessage(
    app: *App,
    writer: anytype,
    message: *Message,
    message_index: usize,
    absolute_y: *usize,
) !void {
    const left_padding = 2;
    const current_absolute_y = absolute_y.*;
    try app.valid_cursor_positions.append(app.allocator, current_absolute_y);

    // Render only rows 1 to height-4 (leaves space for separator, input, status bar)
    if (current_absolute_y >= app.scroll_y and current_absolute_y - app.scroll_y <= app.terminal_size.height - 4) {
        const screen_y = (current_absolute_y - app.scroll_y) + 1;

        // Draw cursor (with ANSI reset and extra space to clear column 2)
        if (current_absolute_y == app.cursor_y) {
            try writer.print("\x1b[{d};1H\x1b[0m> ", .{screen_y});
        } else {
             try writer.print("\x1b[{d};1H\x1b[0m  ", .{screen_y});
        }
        try writer.print("\x1b[{d}G", .{left_padding + 1});
        const role_label = switch (message.role) {
            .user => "You",
            .assistant => "Assistant",
            .system => "System",
        };
        try writer.print("[ {s} ]", .{role_label});
    }
    try app.clickable_areas.append(app.allocator, .{
        .y_start = absolute_y.*,
        .y_end = absolute_y.*,
        .x_start = left_padding + 1,
        .x_end = left_padding + 15, // Enough space for labels
        .message = &app.messages.items[message_index],
    });
    absolute_y.* += 2;
}

pub const App = struct {
    allocator: mem.Allocator,
    config: Config,
    messages: std.ArrayListUnmanaged(Message),
    ollama_client: ollama.OllamaClient,
    input_buffer: std.ArrayListUnmanaged(u8),
    clickable_areas: std.ArrayListUnmanaged(ClickableArea),
    scroll_y: usize = 0,
    cursor_y: usize = 1,
    terminal_size: ui.TerminalSize,
    valid_cursor_positions: std.ArrayListUnmanaged(usize),
    // Resize handling state
    resize_in_progress: bool = false,
    saved_expansion_states: std.ArrayListUnmanaged(bool),
    last_resize_time: i64 = 0,

    pub fn init(allocator: mem.Allocator, config: Config) !App {
        var app = App{
            .allocator = allocator,
            .config = config,
            .messages = .{},
            .ollama_client = ollama.OllamaClient.init(allocator, config.ollama_host),
            .input_buffer = .{},
            .clickable_areas = .{},
            .terminal_size = try ui.Tui.getTerminalSize(),
            .valid_cursor_positions = .{},
            .saved_expansion_states = .{},
        };

        // Add a welcome message
        const welcome_text = "Welcome to ZodoLlama! Type your message below and press Enter to chat.";
        const welcome_processed = try markdown.processMarkdown(allocator, welcome_text);
        try app.messages.append(allocator, .{
            .role = .system,
            .content = try allocator.dupe(u8, welcome_text),
            .processed_content = welcome_processed,
            .is_expanded = true,
            .timestamp = std.time.milliTimestamp(),
        });

        return app;
    }

    // Helper function to redraw the screen immediately
    fn redrawScreen(self: *App) !void {
        self.terminal_size = try ui.Tui.getTerminalSize();
        var stdout_buffer: [8192]u8 = undefined;
        var buffered_writer = ui.BufferedStdoutWriter.init(&stdout_buffer);
        const writer = buffered_writer.writer();

        // Move cursor to home WITHOUT clearing - prevents flicker
        try writer.writeAll("\x1b[H");
        self.clickable_areas.clearRetainingCapacity();
        self.valid_cursor_positions.clearRetainingCapacity();

        var absolute_y: usize = 1;
        for (self.messages.items, 0..) |_, i| {
            const message = &self.messages.items[i];
            if (message.is_expanded) {
                try drawExpandedMessage(self, writer, message, i, &absolute_y);
            } else {
                try drawCollapsedMessage(self, writer, message, i, &absolute_y);
            }
        }

        try drawInputField(self, writer);
        try ui.drawTaskbar(self, writer);

        // Clear from current cursor position to end of screen
        // This removes any leftover content from previous renders
        try writer.writeAll("\x1b[J");

        try buffered_writer.flush();
    }

    // Send a message and get streaming response from Ollama
    pub fn sendMessage(self: *App, user_text: []const u8) !void {
        // 1. Add user message
        const user_content = try self.allocator.dupe(u8, user_text);
        const user_processed = try markdown.processMarkdown(self.allocator, user_content);
        try self.messages.append(self.allocator, .{
            .role = .user,
            .content = user_content,
            .processed_content = user_processed,
            .is_expanded = true,
            .timestamp = std.time.milliTimestamp(),
        });

        // ** IMMEDIATE REDRAW - Show user message right away **
        try self.redrawScreen();

        // 2. Prepare message history for Ollama
        var ollama_messages = std.ArrayListUnmanaged(ollama.ChatMessage){};
        defer ollama_messages.deinit(self.allocator);

        for (self.messages.items) |msg| {
            const role_str = switch (msg.role) {
                .user => "user",
                .assistant => "assistant",
                .system => "system",
            };
            try ollama_messages.append(self.allocator, .{
                .role = role_str,
                .content = msg.content,
            });
        }

        // 3. Create placeholder for assistant response
        const assistant_content = try self.allocator.dupe(u8, "Thinking...");
        const assistant_processed = try markdown.processMarkdown(self.allocator, assistant_content);
        try self.messages.append(self.allocator, .{
            .role = .assistant,
            .content = assistant_content,
            .processed_content = assistant_processed,
            .is_expanded = true,
            .timestamp = std.time.milliTimestamp(),
        });

        // ** REDRAW - Show "Thinking..." placeholder **
        try self.redrawScreen();

        // 4. Get streaming response from Ollama
        var response_buffer = std.ArrayListUnmanaged(u8){};
        defer response_buffer.deinit(self.allocator);

        const StreamContext = struct {
            app: *App,
            response_buffer: *std.ArrayListUnmanaged(u8),
        };

        var stream_ctx = StreamContext{
            .app = self,
            .response_buffer = &response_buffer,
        };

        const streamCallback = struct {
            fn callback(ctx: *StreamContext, chunk: []const u8) void {
                // Append chunk to response buffer
                ctx.response_buffer.appendSlice(ctx.app.allocator, chunk) catch return;

                // Update the last message with accumulated response
                var last_message = &ctx.app.messages.items[ctx.app.messages.items.len - 1];
                ctx.app.allocator.free(last_message.content);
                for (last_message.processed_content.items) |*item| {
                    item.deinit(ctx.app.allocator);
                }
                last_message.processed_content.deinit(ctx.app.allocator);

                last_message.content = ctx.app.allocator.dupe(u8, ctx.response_buffer.items) catch return;
                last_message.processed_content = markdown.processMarkdown(ctx.app.allocator, last_message.content) catch return;

                // Redraw to show the new content
                ctx.app.redrawScreen() catch return;
            }
        }.callback;

        // Call streaming chat
        try self.ollama_client.chatStream(
            self.config.model,
            ollama_messages.items,
            &stream_ctx,
            streamCallback,
        );
    }

    pub fn deinit(self: *App) void {
        for (self.messages.items) |*message| {
            self.allocator.free(message.content);
            for (message.processed_content.items) |*item| {
                item.deinit(self.allocator);
            }
            message.processed_content.deinit(self.allocator);
        }
        self.messages.deinit(self.allocator);
        self.ollama_client.deinit();
        self.input_buffer.deinit(self.allocator);
        self.clickable_areas.deinit(self.allocator);
        self.valid_cursor_positions.deinit(self.allocator);
        self.saved_expansion_states.deinit(self.allocator);
    }

    pub fn run(self: *App, app_tui: *ui.Tui) !void {
        _ = app_tui; // Will be used later for editor integration
        while (true) {
            const current_time = std.time.milliTimestamp();

            // Handle resize signals
            if (ui.resize_pending) {
                ui.resize_pending = false;
                self.last_resize_time = current_time;

                // First resize signal - save states and collapse all
                if (!self.resize_in_progress) {
                    self.resize_in_progress = true;

                    // Save current expansion states
                    self.saved_expansion_states.clearRetainingCapacity();
                    for (self.messages.items) |message| {
                        try self.saved_expansion_states.append(self.allocator, message.is_expanded);
                    }

                    // Collapse all messages for smooth resizing
                    for (self.messages.items) |*message| {
                        message.is_expanded = false;
                    }
                }
            }

            // Check if resize has completed (no signals for 200ms)
            if (self.resize_in_progress and (current_time - self.last_resize_time) > 200) {
                self.resize_in_progress = false;

                // Restore expansion states
                for (self.messages.items, 0..) |*message, i| {
                    if (i < self.saved_expansion_states.items.len) {
                        message.is_expanded = self.saved_expansion_states.items[i];
                    }
                }
                self.saved_expansion_states.clearRetainingCapacity();
            }

            self.terminal_size = try ui.Tui.getTerminalSize();
            var stdout_buffer: [8192]u8 = undefined;
            var buffered_writer = ui.BufferedStdoutWriter.init(&stdout_buffer);
            const writer = buffered_writer.writer();
            // Move cursor to home WITHOUT clearing - prevents flicker
            try writer.writeAll("\x1b[H");
            self.clickable_areas.clearRetainingCapacity();
            self.valid_cursor_positions.clearRetainingCapacity();

            var absolute_y: usize = 1;
            for (self.messages.items, 0..) |_, i| {
                const message = &self.messages.items[i];
                if (message.is_expanded) {
                    try drawExpandedMessage(self, writer, message, i, &absolute_y);
                } else {
                    try drawCollapsedMessage(self, writer, message, i, &absolute_y);
                }
            }

            // Draw input field at the bottom (3 rows before status)
            try drawInputField(self, writer);
            try ui.drawTaskbar(self, writer);
            // Clear from current cursor position to end of screen
            try writer.writeAll("\x1b[J");
            try buffered_writer.flush();
            var should_redraw = false;
            while (!should_redraw) {
                // Check for resize signal before blocking on input
                if (ui.resize_pending) {
                    should_redraw = true;
                    break;
                }

                // Check for resize completion timeout
                if (self.resize_in_progress) {
                    const now = std.time.milliTimestamp();
                    if (now - self.last_resize_time > 200) {
                        should_redraw = true;
                        break;
                    }
                }

                var read_buffer: [128]u8 = undefined;
                const bytes_read = ui.c.read(ui.c.STDIN_FILENO, &read_buffer, read_buffer.len);
                if (bytes_read <= 0) {
                    // Check again after read timeout/interrupt
                    if (ui.resize_pending) {
                        should_redraw = true;
                        break;
                    }
                    // Also check resize timeout after read returns
                    if (self.resize_in_progress) {
                        const now = std.time.milliTimestamp();
                        if (now - self.last_resize_time > 200) {
                            should_redraw = true;
                            break;
                        }
                    }
                    continue;
                }
                const input = read_buffer[0..@intCast(bytes_read)];
                if (try ui.handleInput(self, input, &should_redraw)) {
                    return;
                }
            }

            // View height accounts for input field + status bar: total height - 4 rows
            const view_height = self.terminal_size.height - 4;
            if (self.cursor_y < self.scroll_y + 1) {
                self.scroll_y = self.cursor_y - 1;
            }
            if (self.cursor_y > self.scroll_y + view_height) {
                self.scroll_y = self.cursor_y - view_height;
            }
        }
    }
};

const ConfigFile = struct {
    editor: ?[]const []const u8 = null,
    ollama_host: ?[]const u8 = null,
    model: ?[]const u8 = null,
};

fn loadConfigFromFile(allocator: mem.Allocator) !Config {
    // Default config - properly allocate all strings
    const default_editor = try allocator.alloc([]const u8, 1);
    default_editor[0] = try allocator.dupe(u8, "nvim");

    var config = Config{
        .ollama_host = try allocator.dupe(u8, "http://localhost:11434"),
        .model = try allocator.dupe(u8, "gpt-oss:120b"),
        .editor = default_editor,
    };

    // Try to get home directory
    const home = std.posix.getenv("HOME") orelse return config;

    // Build config file path: ~/.config/zodollama/config.json
    const config_dir = try fs.path.join(allocator, &.{home, ".config", "zodollama"});
    defer allocator.free(config_dir);
    const config_path = try fs.path.join(allocator, &.{config_dir, "config.json"});
    defer allocator.free(config_path);

    // Try to open and read config file
    const file = fs.cwd().openFile(config_path, .{}) catch |err| {
        // File doesn't exist - create it with defaults
        if (err == error.FileNotFound) {
            // Create config directory if it doesn't exist
            fs.cwd().makePath(config_dir) catch |dir_err| {
                if (dir_err != error.PathAlreadyExists) return config;
            };

            // Create default config file
            const new_file = fs.cwd().createFile(config_path, .{}) catch return config;
            defer new_file.close();

            const default_config =
                \\{
                \\  "editor": ["nvim"],
                \\  "ollama_host": "http://localhost:11434",
                \\  "model": "gpt-oss:120b"
                \\}
                \\
            ;
            new_file.writeAll(default_config) catch return config;

            return config;
        }
        return config;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 16) catch return config;
    defer allocator.free(content);

    // Parse JSON
    const parsed = std.json.parseFromSlice(ConfigFile, allocator, content, .{}) catch return config;
    defer parsed.deinit();

    // Apply loaded values
    if (parsed.value.ollama_host) |ollama_host| {
        allocator.free(config.ollama_host);
        config.ollama_host = try allocator.dupe(u8, ollama_host);
    }

    if (parsed.value.model) |model| {
        allocator.free(config.model);
        config.model = try allocator.dupe(u8, model);
    }

    if (parsed.value.editor) |editor| {
        for (config.editor) |arg| allocator.free(arg);
        allocator.free(config.editor);

        var new_editor = try allocator.alloc([]const u8, editor.len);
        for (editor, 0..) |arg, i| {
            new_editor[i] = try allocator.dupe(u8, arg);
        }
        config.editor = new_editor;
    }

    return config;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var config = try loadConfigFromFile(allocator);
    defer config.deinit(allocator);

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    // CLI flags override config file
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--ollama-host")) {
            if (args.next()) |host| {
                allocator.free(config.ollama_host);
                config.ollama_host = try allocator.dupe(u8, host);
            } else {
                std.debug.print("Error: --ollama-host flag requires a URL argument.\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, arg, "--model")) {
            if (args.next()) |model| {
                allocator.free(config.model);
                config.model = try allocator.dupe(u8, model);
            } else {
                std.debug.print("Error: --model flag requires a model name argument.\n", .{});
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
