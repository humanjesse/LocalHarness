// Message rendering module - handles all display logic for messages
const std = @import("std");
const mem = std.mem;
const json = std.json;
const ui = @import("ui.zig");
const markdown = @import("markdown.zig");
const render = @import("render.zig");
const types = @import("types.zig");

// Import App type from app module (will be set up after app.zig imports this)
const app_module = @import("app.zig");
const App = app_module.App;
const Message = types.Message;

// Recursive markdown rendering function
pub fn renderItemsToLines(
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
                var wrapped_lines = try render.wrapRawText(app.allocator, item.payload.styled_text, max_content_width - (indent_level * indent_str.len));
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
                 var content_lines = try render.wrapRawText(app.allocator, item.payload.code_block.content, max_content_width - (indent_level * indent_str.len) - 4);
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
                try formatted_text.appendSlice(app.allocator, app.config.color_link); // Link color from config
                try formatted_text.appendSlice(app.allocator,link_text);
                try formatted_text.appendSlice(app.allocator,"\x1b[0m");  // Reset
                try formatted_text.appendSlice(app.allocator," (");
                try formatted_text.appendSlice(app.allocator,link_url);
                try formatted_text.appendSlice(app.allocator,")");

                var wrapped_lines = try render.wrapRawText(app.allocator, formatted_text.items, max_content_width - (indent_level * indent_str.len));
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

                // Calculate ideal column widths and natural minimums
                var col_widths = try app.allocator.alloc(usize, column_count);
                defer app.allocator.free(col_widths);
                var col_natural_mins = try app.allocator.alloc(usize, column_count);
                defer app.allocator.free(col_natural_mins);

                // Initialize with absolute minimum
                for (col_widths) |*w| w.* = 3;
                for (col_natural_mins) |*m| m.* = 3;

                // Check header widths and calculate natural minimums
                for (table.headers, 0..) |header, i| {
                    const len = ui.AnsiParser.getVisibleLength(header);
                    if (len > col_widths[i]) col_widths[i] = len;

                    // Natural minimum is the header length (headers shouldn't wrap)
                    const longest_word = render.getLongestWordLength(header);
                    col_natural_mins[i] = @max(col_natural_mins[i], @max(longest_word, len));
                }

                // Check body cell widths and update natural minimums
                for (table.rows, 0..) |cell_text, idx| {
                    const col_idx = idx % column_count;
                    const len = ui.AnsiParser.getVisibleLength(cell_text);
                    if (len > col_widths[col_idx]) col_widths[col_idx] = len;

                    // Update natural minimum based on longest word in this cell
                    const longest_word = render.getLongestWordLength(cell_text);
                    col_natural_mins[col_idx] = @max(col_natural_mins[col_idx], longest_word);
                }

                // Adjust if total width exceeds available
                const indent_width = indent_level * indent_str.len;
                const available_width = if (max_content_width > indent_width) max_content_width - indent_width else 0;

                // Calculate total width needed: borders + padding + content
                // Format: "│ content │ content │" = (column_count + 1) borders + column_count * 2 spaces + sum(widths)
                var total_width: usize = column_count + 1; // borders
                for (col_widths) |w| total_width += w + 2; // content + padding

                // Intelligent width distribution
                if (total_width > available_width) {
                    // Calculate minimum required width with natural minimums
                    var min_total_width: usize = column_count + 1; // borders
                    for (col_natural_mins) |m| min_total_width += m + 2; // content + padding

                    if (available_width >= min_total_width) {
                        // We can fit the table with natural minimums - distribute intelligently
                        // Step 1: Set all columns to their natural minimum
                        for (col_widths, 0..) |*w, i| {
                            w.* = col_natural_mins[i];
                        }

                        // Step 2: Distribute remaining space to columns proportionally
                        // but give more weight to columns that originally wanted more space
                        var current_total: usize = min_total_width;
                        const extra_space = available_width - min_total_width;

                        if (extra_space > 0) {
                            // Calculate total "demand" (how much extra each column wants)
                            var total_demand: usize = 0;
                            var demands = try app.allocator.alloc(usize, column_count);
                            defer app.allocator.free(demands);

                            for (col_widths, 0..) |ideal_width, i| {
                                // How much does this column want beyond its natural minimum?
                                const demand = if (ideal_width > col_natural_mins[i])
                                    ideal_width - col_natural_mins[i]
                                else
                                    0;
                                demands[i] = demand;
                                total_demand += demand;
                            }

                            // Distribute extra space proportionally to demand
                            if (total_demand > 0) {
                                for (col_widths, 0..) |*w, i| {
                                    const extra = (extra_space * demands[i]) / total_demand;
                                    w.* += extra;
                                }
                            } else {
                                // No demand - distribute evenly
                                const per_column = extra_space / column_count;
                                for (col_widths) |*w| {
                                    w.* += per_column;
                                }
                            }
                        }

                        // Recalculate and fine-tune if needed
                        current_total = column_count + 1;
                        for (col_widths) |w| current_total += w + 2;

                        // Final adjustment: if still too wide, shrink widest columns
                        while (current_total > available_width) {
                            // Find column with most excess above its natural minimum
                            var max_excess: usize = 0;
                            var max_idx: usize = 0;
                            for (col_widths, 0..) |w, i| {
                                const excess = if (w > col_natural_mins[i]) w - col_natural_mins[i] else 0;
                                if (excess > max_excess) {
                                    max_excess = excess;
                                    max_idx = i;
                                }
                            }

                            if (max_excess == 0) break; // All at natural minimum

                            col_widths[max_idx] -= 1;
                            current_total -= 1;
                        }
                    } else {
                        // Terminal too narrow even for natural minimums - use absolute minimums
                        const absolute_min: usize = 3;
                        for (col_widths) |*w| w.* = absolute_min;

                        // Still try to be smart: give slightly more to label columns
                        var abs_min_total: usize = column_count + 1;
                        for (col_widths) |w| abs_min_total += w + 2;

                        if (abs_min_total <= available_width) {
                            const extra = available_width - abs_min_total;
                            // Give extra to narrowest columns first (likely labels)
                            for (0..extra) |_| {
                                var min_width: usize = 1000;
                                var min_idx: usize = 0;
                                for (col_natural_mins, 0..) |nat_min, i| {
                                    if (nat_min < min_width) {
                                        min_width = nat_min;
                                        min_idx = i;
                                    }
                                }
                                col_widths[min_idx] += 1;
                            }
                        }
                    }
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
                    const truncated_header = try render.truncateTextToWidth(app.allocator, header, col_widths[i]);
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
                        wrapped_cells[col_idx] = try render.wrapRawText(app.allocator, cell_text, wrap_width);
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

pub fn drawMessage(
    app: *App,
    writer: anytype,
    message: *Message,
    message_index: usize,
    absolute_y: *usize,
    input_field_height: usize,
) !void {
    const left_padding = 2;
    const y_start = absolute_y.*;
    const max_content_width = if (app.terminal_size.width > left_padding + 4) app.terminal_size.width - left_padding - 4 else 0;

    // Build unified list of all lines to render (thinking + content)
    var all_lines = std.ArrayListUnmanaged([]const u8){};
    defer {
        for (all_lines.items) |line| app.allocator.free(line);
        all_lines.deinit(app.allocator);
    }

    // Add thinking section if present
    const has_thinking = message.thinking_content != null and message.processed_thinking_content != null;
    if (has_thinking) {
        if (message.thinking_expanded) {
            // Expanded thinking: add header + thinking lines + separator
            var thinking_header = std.ArrayListUnmanaged(u8){};
            defer thinking_header.deinit(app.allocator);
            try thinking_header.appendSlice(app.allocator, app.config.color_thinking_header);
            try thinking_header.appendSlice(app.allocator, "Thinking\x1b[0m");
            try all_lines.append(app.allocator, try thinking_header.toOwnedSlice(app.allocator));

            var thinking_lines = std.ArrayListUnmanaged([]const u8){};
            defer thinking_lines.deinit(app.allocator); // Only deinit the ArrayList, not the strings

            if (message.processed_thinking_content) |*thinking_processed| {
                try renderItemsToLines(app, thinking_processed, &thinking_lines, 0, max_content_width);
            }

            // Add thinking lines with dim styling (transfer ownership to all_lines)
            for (thinking_lines.items) |line| {
                var styled_line = std.ArrayListUnmanaged(u8){};
                try styled_line.appendSlice(app.allocator, app.config.color_thinking_dim); // Dim from config
                try styled_line.appendSlice(app.allocator, line);
                try styled_line.appendSlice(app.allocator, "\x1b[0m"); // Reset
                try all_lines.append(app.allocator, try styled_line.toOwnedSlice(app.allocator));
                // Free the original line since we created a styled copy
                app.allocator.free(line);
            }

            // Add separator
            try all_lines.append(app.allocator, try app.allocator.dupe(u8, "SEPARATOR"));
        } else {
            // Collapsed thinking: just show header
            try all_lines.append(app.allocator, try app.allocator.dupe(u8, "\x1b[2m💭 Thinking (Ctrl+O to expand)\x1b[0m"));
            try all_lines.append(app.allocator, try app.allocator.dupe(u8, "SEPARATOR"));
        }
    }

    // Add agent analysis section if present (for sub-agent thinking - file_curator, graphrag, etc.)
    const has_agent_analysis = message.agent_analysis_name != null;
    if (has_agent_analysis) {
        if (message.agent_analysis_completed and !message.agent_analysis_expanded) {
            // COLLAPSED: Show one-liner summary
            const agent_time = message.tool_execution_time orelse 0;
            var summary = std.ArrayListUnmanaged(u8){};
            defer summary.deinit(app.allocator);
            try summary.print(
                app.allocator,
                "\x1b[2m🤔 {s} Analysis (✅ completed, {d}ms) - Ctrl+O to expand\x1b[0m",
                .{message.agent_analysis_name.?, agent_time}
            );
            try all_lines.append(app.allocator, try summary.toOwnedSlice(app.allocator));
            try all_lines.append(app.allocator, try app.allocator.dupe(u8, "SEPARATOR"));
        } else {
            // EXPANDED or STREAMING: Show full content
            // Add hint if completed (can be collapsed)
            if (message.agent_analysis_completed) {
                try all_lines.append(app.allocator, try app.allocator.dupe(u8, "\x1b[2m(Ctrl+O to collapse)\x1b[0m"));
            }

            // Render agent analysis content
            var content_lines = std.ArrayListUnmanaged([]const u8){};
            defer content_lines.deinit(app.allocator);
            try renderItemsToLines(app, &message.processed_content, &content_lines, 0, max_content_width);

            for (content_lines.items) |line| {
                try all_lines.append(app.allocator, line);
            }

            try all_lines.append(app.allocator, try app.allocator.dupe(u8, "SEPARATOR"));
        }
    }

    // Add tool call section if present (for system messages showing tool results)
    const has_tool_call = message.tool_name != null;
    if (has_tool_call) {
        if (message.tool_call_expanded) {
            // Expanded tool call: add header + tool output + separator
            var tool_header = std.ArrayListUnmanaged(u8){};
            defer tool_header.deinit(app.allocator);
            try tool_header.appendSlice(app.allocator, app.config.color_thinking_header);
            try tool_header.print(app.allocator, "Tool: {s}\x1b[0m", .{message.tool_name.?});
            try all_lines.append(app.allocator, try tool_header.toOwnedSlice(app.allocator));

            var tool_lines = std.ArrayListUnmanaged([]const u8){};
            defer tool_lines.deinit(app.allocator);

            try renderItemsToLines(app, &message.processed_content, &tool_lines, 0, max_content_width);

            // Add tool lines with dim styling (transfer ownership to all_lines)
            for (tool_lines.items) |line| {
                var styled_line = std.ArrayListUnmanaged(u8){};
                try styled_line.appendSlice(app.allocator, app.config.color_thinking_dim);
                try styled_line.appendSlice(app.allocator, line);
                try styled_line.appendSlice(app.allocator, "\x1b[0m");
                try all_lines.append(app.allocator, try styled_line.toOwnedSlice(app.allocator));
                app.allocator.free(line);
            }

            // Add separator
            try all_lines.append(app.allocator, try app.allocator.dupe(u8, "SEPARATOR"));
        } else {
            // Collapsed tool call: just show summary
            const status_icon = if (message.tool_success orelse false) "✅" else "❌";
            const status_text = if (message.tool_success orelse false) "SUCCESS" else "FAILED";

            var summary = std.ArrayListUnmanaged(u8){};
            defer summary.deinit(app.allocator);
            try summary.print(
                app.allocator,
                "\x1b[2m🔧 Used tool: {s} ({s} {s})",
                .{message.tool_name.?, status_icon, status_text}
            );
            if (message.tool_execution_time) |exec_time| {
                try summary.print(app.allocator, ", {d}ms", .{exec_time});
            }
            try summary.appendSlice(app.allocator, " - Ctrl+O to expand\x1b[0m");
            try all_lines.append(app.allocator, try summary.toOwnedSlice(app.allocator));
            try all_lines.append(app.allocator, try app.allocator.dupe(u8, "SEPARATOR"));
        }
    }

    // Add main content lines (transfer ownership to all_lines)
    // Skip content for tool calls and agent analysis since we render them above
    if (!has_tool_call and !has_agent_analysis) {
        var content_lines = std.ArrayListUnmanaged([]const u8){};
        defer content_lines.deinit(app.allocator); // Only deinit the ArrayList, not the strings
        try renderItemsToLines(app, &message.processed_content, &content_lines, 0, max_content_width);
        try all_lines.appendSlice(app.allocator, content_lines.items);
    }

    // Add permission prompt if present
    if (message.permission_request) |perm_req| {
        // Add separator before permission prompt
        try all_lines.append(app.allocator, try app.allocator.dupe(u8, "SEPARATOR"));

        // Header with warning emoji
        var perm_header = std.ArrayListUnmanaged(u8){};
        try perm_header.appendSlice(app.allocator, "\x1b[33m⚠️  Permission Request\x1b[0m"); // Yellow
        try all_lines.append(app.allocator, try perm_header.toOwnedSlice(app.allocator));

        try all_lines.append(app.allocator, try app.allocator.dupe(u8, ""));

        // Tool name
        var tool_line = std.ArrayListUnmanaged(u8){};
        try tool_line.appendSlice(app.allocator, "\x1b[1mTool:\x1b[0m ");
        try tool_line.appendSlice(app.allocator, perm_req.tool_call.function.name);
        try all_lines.append(app.allocator, try tool_line.toOwnedSlice(app.allocator));

        // Format arguments based on tool type
        blk: {
            if (mem.eql(u8, perm_req.tool_call.function.name, "replace_lines")) {
                // Special formatting for replace_lines to show line range and content preview
                const ReplaceArgs = struct { path: []const u8, line_start: usize, line_end: usize, new_content: []const u8 };
                const parsed = json.parseFromSlice(ReplaceArgs, app.allocator, perm_req.tool_call.function.arguments, .{}) catch {
                    // Fallback to raw if parsing fails
                    var args_line = std.ArrayListUnmanaged(u8){};
                    try args_line.appendSlice(app.allocator, "\x1b[1mArguments:\x1b[0m ");
                    try args_line.appendSlice(app.allocator, perm_req.tool_call.function.arguments);
                    try all_lines.append(app.allocator, try args_line.toOwnedSlice(app.allocator));
                    break :blk;
                };
                defer parsed.deinit();

            // File path
            var file_line = std.ArrayListUnmanaged(u8){};
            try file_line.appendSlice(app.allocator, "\x1b[1mFile:\x1b[0m ");
            try file_line.appendSlice(app.allocator, parsed.value.path);
            try all_lines.append(app.allocator, try file_line.toOwnedSlice(app.allocator));

            // Line range
            const range_text = try std.fmt.allocPrint(app.allocator, "\x1b[1mReplacing lines:\x1b[0m {d}-{d}", .{parsed.value.line_start, parsed.value.line_end});
            defer app.allocator.free(range_text);
            try all_lines.append(app.allocator, try app.allocator.dupe(u8, range_text));

            try all_lines.append(app.allocator, try app.allocator.dupe(u8, ""));
            try all_lines.append(app.allocator, try app.allocator.dupe(u8, "\x1b[1mChanges:\x1b[0m"));

            // Read the file to get old content
            const old_content_result = blk2: {
                const file = std.fs.cwd().openFile(parsed.value.path, .{}) catch |err| {
                    const error_msg = try std.fmt.allocPrint(app.allocator, "\x1b[33m(Unable to read file: {s})\x1b[0m", .{@errorName(err)});
                    break :blk2 error_msg;
                };
                defer file.close();

                const content = file.readToEndAlloc(app.allocator, 10 * 1024 * 1024) catch |err| {
                    const error_msg = try std.fmt.allocPrint(app.allocator, "\x1b[33m(Unable to read file: {s})\x1b[0m", .{@errorName(err)});
                    break :blk2 error_msg;
                };
                defer app.allocator.free(content);

                // Split content into lines
                var lines = std.ArrayListUnmanaged([]const u8){};
                defer lines.deinit(app.allocator);

                var line_iter = mem.splitScalar(u8, content, '\n');
                while (line_iter.next()) |line| {
                    try lines.append(app.allocator, line);
                }

                // Check if line numbers are valid
                if (parsed.value.line_start == 0 or parsed.value.line_start > lines.items.len or parsed.value.line_end > lines.items.len) {
                    const error_msg = try std.fmt.allocPrint(app.allocator, "\x1b[33m(Line numbers out of range: file has {d} lines)\x1b[0m", .{lines.items.len});
                    break :blk2 error_msg;
                }

                // Extract the old lines (convert to 0-indexed) and add to all_lines
                const start_idx = parsed.value.line_start - 1;
                const end_idx = parsed.value.line_end - 1;

                var line_num = parsed.value.line_start;
                for (lines.items[start_idx..end_idx + 1]) |line| {
                    const formatted_line = try std.fmt.allocPrint(app.allocator, "\x1b[31m- {d}: {s}\x1b[0m", .{line_num, line});
                    try all_lines.append(app.allocator, formatted_line);
                    line_num += 1;
                }

                break :blk2 try app.allocator.dupe(u8, ""); // Success marker (empty string)
            };

            // Check if there was an error reading the file
            const had_error = old_content_result.len > 0 and mem.indexOf(u8, old_content_result, "Unable to read") != null;
            if (had_error) {
                try all_lines.append(app.allocator, try app.allocator.dupe(u8, old_content_result));
            }
            app.allocator.free(old_content_result);

            // Empty line separator
            try all_lines.append(app.allocator, try app.allocator.dupe(u8, ""));

            // Format new content with + prefix and line numbers
            var new_line_iter = mem.splitScalar(u8, parsed.value.new_content, '\n');
            var line_num: usize = parsed.value.line_start;
            while (new_line_iter.next()) |line| {
                // Skip empty trailing line if new_content ends with newline
                if (new_line_iter.index == null and line.len == 0) break;

                const formatted_line = try std.fmt.allocPrint(app.allocator, "\x1b[32m+ {d}: {s}\x1b[0m", .{line_num, line});
                try all_lines.append(app.allocator, formatted_line);
                line_num += 1;
            }
        } else if (mem.eql(u8, perm_req.tool_call.function.name, "insert_lines")) {
                // Special formatting for insert_lines to show insertion point and content preview
                const InsertArgs = struct { path: []const u8, line_start: usize, line_end: usize, new_content: []const u8 };
                const parsed = json.parseFromSlice(InsertArgs, app.allocator, perm_req.tool_call.function.arguments, .{}) catch {
                    // Fallback to raw if parsing fails
                    var args_line = std.ArrayListUnmanaged(u8){};
                    try args_line.appendSlice(app.allocator, "\x1b[1mArguments:\x1b[0m ");
                    try args_line.appendSlice(app.allocator, perm_req.tool_call.function.arguments);
                    try all_lines.append(app.allocator, try args_line.toOwnedSlice(app.allocator));
                    break :blk;
                };
                defer parsed.deinit();

            // File path
            var file_line = std.ArrayListUnmanaged(u8){};
            try file_line.appendSlice(app.allocator, "\x1b[1mFile:\x1b[0m ");
            try file_line.appendSlice(app.allocator, parsed.value.path);
            try all_lines.append(app.allocator, try file_line.toOwnedSlice(app.allocator));

            // Insertion point
            const point_text = try std.fmt.allocPrint(app.allocator, "\x1b[1mInserting before line:\x1b[0m {d}", .{parsed.value.line_start});
            defer app.allocator.free(point_text);
            try all_lines.append(app.allocator, try app.allocator.dupe(u8, point_text));

            try all_lines.append(app.allocator, try app.allocator.dupe(u8, ""));
            try all_lines.append(app.allocator, try app.allocator.dupe(u8, "\x1b[1mChanges:\x1b[0m"));

            // Read the file to show context
            const context_result = blk2: {
                const file = std.fs.cwd().openFile(parsed.value.path, .{}) catch |err| {
                    const error_msg = try std.fmt.allocPrint(app.allocator, "\x1b[33m(Unable to read file: {s})\x1b[0m", .{@errorName(err)});
                    break :blk2 error_msg;
                };
                defer file.close();

                const content = file.readToEndAlloc(app.allocator, 10 * 1024 * 1024) catch |err| {
                    const error_msg = try std.fmt.allocPrint(app.allocator, "\x1b[33m(Unable to read file: {s})\x1b[0m", .{@errorName(err)});
                    break :blk2 error_msg;
                };
                defer app.allocator.free(content);

                // Split content into lines
                var lines = std.ArrayListUnmanaged([]const u8){};
                defer lines.deinit(app.allocator);

                var line_iter = mem.splitScalar(u8, content, '\n');
                while (line_iter.next()) |line| {
                    try lines.append(app.allocator, line);
                }

                // Check if line number is valid
                if (parsed.value.line_start == 0 or parsed.value.line_start > lines.items.len + 1) {
                    const error_msg = try std.fmt.allocPrint(app.allocator, "\x1b[33m(Line number out of range: file has {d} lines)\x1b[0m", .{lines.items.len});
                    break :blk2 error_msg;
                }

                // Show context: 2 lines before insertion point (if available)
                const insert_idx = parsed.value.line_start - 1; // Convert to 0-indexed
                const context_start = if (insert_idx >= 2) insert_idx - 2 else 0;
                const context_end = @min(insert_idx, lines.items.len);

                if (context_start < context_end) {
                    var line_num = context_start + 1;
                    for (lines.items[context_start..context_end]) |line| {
                        const formatted_line = try std.fmt.allocPrint(app.allocator, "\x1b[90m  {d}: {s}\x1b[0m", .{line_num, line});
                        try all_lines.append(app.allocator, formatted_line);
                        line_num += 1;
                    }
                }

                break :blk2 try app.allocator.dupe(u8, ""); // Success marker (empty string)
            };

            // Check if there was an error reading the file
            const had_error = context_result.len > 0 and mem.indexOf(u8, context_result, "Unable to read") != null;
            if (had_error) {
                try all_lines.append(app.allocator, try app.allocator.dupe(u8, context_result));
            }
            app.allocator.free(context_result);

            // Empty line separator before new content
            try all_lines.append(app.allocator, try app.allocator.dupe(u8, ""));

            // Format new content with + prefix and line numbers
            var new_line_iter = mem.splitScalar(u8, parsed.value.new_content, '\n');
            var line_num: usize = parsed.value.line_start;
            while (new_line_iter.next()) |line| {
                // Skip empty trailing line if new_content ends with newline
                if (new_line_iter.index == null and line.len == 0) break;

                const formatted_line = try std.fmt.allocPrint(app.allocator, "\x1b[32m+ {d}: {s}\x1b[0m", .{line_num, line});
                try all_lines.append(app.allocator, formatted_line);
                line_num += 1;
            }

            // Show context: 2 lines after insertion point (if available)
            blk2: {
                const file = std.fs.cwd().openFile(parsed.value.path, .{}) catch break :blk2;
                defer file.close();

                const content = file.readToEndAlloc(app.allocator, 10 * 1024 * 1024) catch break :blk2;
                defer app.allocator.free(content);

                var lines = std.ArrayListUnmanaged([]const u8){};
                defer lines.deinit(app.allocator);

                var line_iter = mem.splitScalar(u8, content, '\n');
                while (line_iter.next()) |line| {
                    try lines.append(app.allocator, line);
                }

                const insert_idx = parsed.value.line_start - 1; // Convert to 0-indexed
                if (insert_idx < lines.items.len) {
                    try all_lines.append(app.allocator, try app.allocator.dupe(u8, ""));
                    const context_start = insert_idx;
                    const context_end = @min(insert_idx + 2, lines.items.len);

                    // Calculate the line numbers after insertion
                    const num_new_lines = blk3: {
                        var count: usize = 0;
                        var iter = mem.splitScalar(u8, parsed.value.new_content, '\n');
                        while (iter.next()) |l| {
                            if (iter.index == null and l.len == 0) break;
                            count += 1;
                        }
                        break :blk3 count;
                    };

                    var display_line_num = parsed.value.line_start + num_new_lines;
                    for (lines.items[context_start..context_end]) |line| {
                        const formatted_line = try std.fmt.allocPrint(app.allocator, "\x1b[90m  {d}: {s}\x1b[0m", .{display_line_num, line});
                        try all_lines.append(app.allocator, formatted_line);
                        display_line_num += 1;
                    }
                }
            }
        } else {
            // Default formatting for other tools
            const args_preview = if (perm_req.tool_call.function.arguments.len > 100)
                try std.fmt.allocPrint(app.allocator, "{s}...", .{perm_req.tool_call.function.arguments[0..97]})
            else
                try app.allocator.dupe(u8, perm_req.tool_call.function.arguments);
            defer app.allocator.free(args_preview);

            var args_line = std.ArrayListUnmanaged(u8){};
            try args_line.appendSlice(app.allocator, "\x1b[1mArguments:\x1b[0m ");
            try args_line.appendSlice(app.allocator, args_preview);
            try all_lines.append(app.allocator, try args_line.toOwnedSlice(app.allocator));
        }
    }

        // Risk level with color
        const risk_color = switch (perm_req.eval_result.show_preview) {
            true => "\x1b[31m", // Red for high risk
            false => "\x1b[32m", // Green for low risk
        };
        const risk_text = if (perm_req.eval_result.show_preview) "HIGH" else "LOW";

        var risk_line = std.ArrayListUnmanaged(u8){};
        try risk_line.appendSlice(app.allocator, "\x1b[1mRisk:\x1b[0m ");
        try risk_line.appendSlice(app.allocator, risk_color);
        try risk_line.appendSlice(app.allocator, risk_text);
        try risk_line.appendSlice(app.allocator, "\x1b[0m");
        try all_lines.append(app.allocator, try risk_line.toOwnedSlice(app.allocator));

        try all_lines.append(app.allocator, try app.allocator.dupe(u8, ""));

        // Action buttons
        var actions_line = std.ArrayListUnmanaged(u8){};
        try actions_line.appendSlice(app.allocator, "\x1b[1m[\x1b[32m1\x1b[0m\x1b[1m] Allow Once\x1b[0m  ");
        try actions_line.appendSlice(app.allocator, "\x1b[1m[\x1b[32m2\x1b[0m\x1b[1m] Session\x1b[0m  ");
        try actions_line.appendSlice(app.allocator, "\x1b[1m[\x1b[36m3\x1b[0m\x1b[1m] Remember\x1b[0m  ");
        try actions_line.appendSlice(app.allocator, "\x1b[1m[\x1b[31m4\x1b[0m\x1b[1m] Deny\x1b[0m");
        try all_lines.append(app.allocator, try actions_line.toOwnedSlice(app.allocator));
    }

    // Now render the unified box with all lines
    const box_height = all_lines.items.len + 2; // +2 for top and bottom borders

    // Calculate viewport height once (account for input field height + taskbar)
    const viewport_height = if (app.terminal_size.height > input_field_height + 1)
        app.terminal_size.height - input_field_height - 1
    else
        1;

    for (0..box_height) |line_idx| {
        const current_absolute_y = absolute_y.* + line_idx;
        try app.valid_cursor_positions.append(app.allocator, current_absolute_y);

        // Render only rows within viewport
        if (current_absolute_y >= app.scroll_y and current_absolute_y - app.scroll_y <= viewport_height) {
            const screen_y = (current_absolute_y - app.scroll_y) + 1;

            // Draw cursor
            if (current_absolute_y == app.cursor_y) {
                try writer.print("\x1b[{d};1H\x1b[0m> ", .{screen_y});
            } else {
                try writer.print("\x1b[{d};1H\x1b[0m  ", .{screen_y});
            }

            // Move to start of box
            try writer.print("\x1b[{d}G", .{left_padding + 1});

            if (line_idx == 0) {
                // Top border
                try writer.writeAll("┌");
                for (0..max_content_width + 2) |_| try writer.writeAll("─");
                try writer.writeAll("┐");
            } else if (line_idx == box_height - 1) {
                // Bottom border
                try writer.writeAll("└");
                for (0..max_content_width + 2) |_| try writer.writeAll("─");
                try writer.writeAll("┘");
            } else {
                // Content line
                const content_line_idx = line_idx - 1;
                const line_text = all_lines.items[content_line_idx];

                // Check if this is a separator
                if (mem.eql(u8, line_text, "SEPARATOR")) {
                    try writer.writeAll("├");
                    for (0..max_content_width + 2) |_| try writer.writeAll("─");
                    try writer.writeAll("┤");
                } else {
                    // Regular content line
                    const line_len = ui.AnsiParser.getVisibleLength(line_text);
                    try writer.writeAll("│ ");
                    try writer.writeAll(line_text);
                    const padding = if (line_len >= max_content_width) 0 else max_content_width - line_len;
                    for (0..padding) |_| try writer.writeAll(" ");
                    try writer.writeAll(" │");
                }
            }
        }
    }

    absolute_y.* += box_height;

    // Add spacing after each message for readability
    // Clear the spacing line if it's in the viewport
    const spacing_y = absolute_y.*;
    if (spacing_y >= app.scroll_y and spacing_y - app.scroll_y <= viewport_height) {
        const screen_y = (spacing_y - app.scroll_y) + 1;
        try writer.print("\x1b[{d};1H\x1b[K", .{screen_y}); // Clear the spacing line
    }
    absolute_y.* += 1;

    // Register single clickable area for entire message (excluding spacing)
    try app.clickable_areas.append(app.allocator, .{
        .y_start = y_start,
        .y_end = absolute_y.* - 2, // -2 to exclude the spacing line
        .x_start = 1,
        .x_end = app.terminal_size.width,
        .message = &app.messages.items[message_index],
    });
}

/// Calculate how many rows the input field will occupy (including top separator, input lines, and bottom border)
pub fn calculateInputFieldHeight(app: *App) !usize {
    const max_visible_lines = 7;

    // If input buffer is empty, we still show one line
    if (app.input_buffer.items.len == 0) {
        return 3; // 1 top separator + 1 input line + 1 bottom border
    }

    // Guard against very small terminal widths
    const width = app.terminal_size.width;
    if (width < 10) {
        // Terminal too narrow, return minimum
        return 3; // 1 top separator + 1 input line + 1 bottom border
    }

    // Wrap the input buffer text to see how many lines it takes
    const max_width = width - 3; // Account for "> " or "  " indent
    var wrapped_lines = try render.wrapRawText(app.allocator, app.input_buffer.items, max_width);
    defer {
        for (wrapped_lines.items) |line| app.allocator.free(line);
        wrapped_lines.deinit(app.allocator);
    }

    const total_lines = if (wrapped_lines.items.len == 0) 1 else wrapped_lines.items.len;
    const num_visible_lines = @min(total_lines, max_visible_lines);

    // Use saturating addition to prevent overflow
    // +1 for top separator, +1 for bottom border
    return num_visible_lines +| 2;
}

pub fn drawInputField(app: *App, writer: anytype) !void {
    const height = app.terminal_size.height;
    const width = app.terminal_size.width;
    const max_visible_lines = 7;

    // Wrap the input buffer text
    const max_width = if (width > 3) width - 3 else 1; // Account for "> " or "  " indent
    var wrapped_lines = if (app.input_buffer.items.len > 0)
        try render.wrapRawText(app.allocator, app.input_buffer.items, max_width)
    else
        std.ArrayListUnmanaged([]const u8){};
    defer {
        for (wrapped_lines.items) |line| app.allocator.free(line);
        wrapped_lines.deinit(app.allocator);
    }

    // If buffer is empty, we still need at least one line for the prompt
    const total_lines = if (wrapped_lines.items.len == 0) 1 else wrapped_lines.items.len;
    const num_visible_lines = @min(total_lines, max_visible_lines);
    const num_hidden_lines = if (total_lines > max_visible_lines) total_lines - max_visible_lines else 0;

    // Calculate positions (from bottom up: taskbar, bottom border, input lines, separator)
    const bottom_border_row = height - 1;
    const last_input_row = height - 2;
    const first_input_row = last_input_row - (num_visible_lines - 1);
    const separator_row = first_input_row - 1;

    // Draw separator with indicator if there are hidden lines
    try writer.print("\x1b[{d};1H", .{separator_row});
    if (num_hidden_lines > 0) {
        // Show indicator for hidden lines
        const indicator = try std.fmt.allocPrint(app.allocator, "──── ↑ {d} more line{s} ", .{
            num_hidden_lines,
            if (num_hidden_lines == 1) "" else "s",
        });
        defer app.allocator.free(indicator);

        const indicator_len = ui.AnsiParser.getVisibleLength(indicator);
        try writer.writeAll(indicator);

        // Fill rest with separator
        if (indicator_len < width) {
            for (0..(width - indicator_len)) |_| try writer.writeAll("─");
        }
    } else {
        // Normal separator
        for (0..width) |_| try writer.writeAll("─");
    }

    // Determine which lines to show (last N lines if we have more than max_visible_lines)
    const start_line_idx = if (num_hidden_lines > 0) num_hidden_lines else 0;

    // Draw input lines
    for (0..num_visible_lines) |i| {
        const screen_row = first_input_row + i;
        try writer.print("\x1b[{d};1H", .{screen_row});

        if (wrapped_lines.items.len == 0) {
            // Empty buffer - just show prompt
            try writer.writeAll("> _");
        } else {
            const line_idx = start_line_idx + i;
            const is_first_visible_line = (i == 0);

            if (is_first_visible_line) {
                try writer.writeAll("> ");
            } else {
                try writer.writeAll("  "); // Indent continuation lines
            }

            if (line_idx < wrapped_lines.items.len) {
                try writer.writeAll(wrapped_lines.items[line_idx]);

                // Show cursor on the last line
                if (line_idx == wrapped_lines.items.len - 1) {
                    try writer.writeAll("_");
                }
            }
        }

        // Clear to end of line
        try writer.writeAll("\x1b[K");
    }

    // Draw bottom border after input lines (before taskbar)
    try writer.print("\x1b[{d};1H", .{bottom_border_row});
    for (0..width) |_| try writer.writeAll("─");
}

// Helper function to calculate total content height without rendering
// Returns the total height all messages would occupy
pub fn calculateContentHeight(self: *App) !usize {
    var absolute_y: usize = 1;
    const max_content_width = if (self.terminal_size.width > 6) self.terminal_size.width - 6 else 0;

    for (self.messages.items) |*message| {
        // Skip tool JSON if hidden by config
        if (message.role == .tool and !self.config.show_tool_json) continue;

        // Build unified list of all lines (thinking + content + permission)
        var all_lines = std.ArrayListUnmanaged([]const u8){};
        defer {
            for (all_lines.items) |line| self.allocator.free(line);
            all_lines.deinit(self.allocator);
        }

        // Add thinking section if present
        const has_thinking = message.thinking_content != null and message.processed_thinking_content != null;
        if (has_thinking) {
            if (message.thinking_expanded) {
                try all_lines.append(self.allocator, try self.allocator.dupe(u8, "thinking_header"));

                var thinking_lines = std.ArrayListUnmanaged([]const u8){};
                defer {
                    for (thinking_lines.items) |line| self.allocator.free(line);
                    thinking_lines.deinit(self.allocator);
                }

                if (message.processed_thinking_content) |*thinking_processed| {
                    try renderItemsToLines(self, thinking_processed, &thinking_lines, 0, max_content_width);
                }

                for (thinking_lines.items) |line| {
                    try all_lines.append(self.allocator, try self.allocator.dupe(u8, line));
                }

                try all_lines.append(self.allocator, try self.allocator.dupe(u8, "SEPARATOR"));
            } else {
                try all_lines.append(self.allocator, try self.allocator.dupe(u8, "thinking_collapsed"));
                try all_lines.append(self.allocator, try self.allocator.dupe(u8, "SEPARATOR"));
            }
        }

        // Add agent analysis section if present (for sub-agent thinking - file_curator, graphrag, etc.)
        const has_agent_analysis = message.agent_analysis_name != null;
        if (has_agent_analysis) {
            if (message.agent_analysis_completed and !message.agent_analysis_expanded) {
                // COLLAPSED: Show one-liner summary (1 line + separator)
                try all_lines.append(self.allocator, try self.allocator.dupe(u8, "agent_collapsed"));
                try all_lines.append(self.allocator, try self.allocator.dupe(u8, "SEPARATOR"));
            } else {
                // EXPANDED or STREAMING: Show full content
                // Add hint if completed (1 line)
                if (message.agent_analysis_completed) {
                    try all_lines.append(self.allocator, try self.allocator.dupe(u8, "agent_hint"));
                }

                // Render agent analysis content
                var agent_lines = std.ArrayListUnmanaged([]const u8){};
                defer {
                    for (agent_lines.items) |line| self.allocator.free(line);
                    agent_lines.deinit(self.allocator);
                }

                try renderItemsToLines(self, &message.processed_content, &agent_lines, 0, max_content_width);

                for (agent_lines.items) |line| {
                    try all_lines.append(self.allocator, try self.allocator.dupe(u8, line));
                }

                try all_lines.append(self.allocator, try self.allocator.dupe(u8, "SEPARATOR"));
            }
        }

        // Add tool call section if present
        const has_tool_call = message.tool_name != null;
        if (has_tool_call) {
            if (message.tool_call_expanded) {
                try all_lines.append(self.allocator, try self.allocator.dupe(u8, "tool_header"));

                var tool_lines = std.ArrayListUnmanaged([]const u8){};
                defer {
                    for (tool_lines.items) |line| self.allocator.free(line);
                    tool_lines.deinit(self.allocator);
                }

                try renderItemsToLines(self, &message.processed_content, &tool_lines, 0, max_content_width);

                for (tool_lines.items) |line| {
                    try all_lines.append(self.allocator, try self.allocator.dupe(u8, line));
                }

                try all_lines.append(self.allocator, try self.allocator.dupe(u8, "SEPARATOR"));
            } else {
                try all_lines.append(self.allocator, try self.allocator.dupe(u8, "tool_collapsed"));
                try all_lines.append(self.allocator, try self.allocator.dupe(u8, "SEPARATOR"));
            }
        }

        // Add main content lines (skip for tool calls and agent analysis)
        if (!has_tool_call and !has_agent_analysis) {
            var content_lines = std.ArrayListUnmanaged([]const u8){};
            defer {
                for (content_lines.items) |line| self.allocator.free(line);
                content_lines.deinit(self.allocator);
            }
            try renderItemsToLines(self, &message.processed_content, &content_lines, 0, max_content_width);
            // Transfer ownership to all_lines by duping
            for (content_lines.items) |line| {
                try all_lines.append(self.allocator, try self.allocator.dupe(u8, line));
            }
        }

        // Add permission prompt if present
        if (message.permission_request != null) {
            try all_lines.append(self.allocator, try self.allocator.dupe(u8, "SEPARATOR"));
            // Permission prompt has ~7 lines
            for (0..7) |_| {
                try all_lines.append(self.allocator, try self.allocator.dupe(u8, "perm_line"));
            }
        }

        const box_height = all_lines.items.len + 2;
        absolute_y += box_height;

        // Add spacing after each message (same as in drawMessage)
        absolute_y += 1;
    }

    return absolute_y;
}

// Helper function to redraw the screen immediately
// Returns the total content height (last absolute_y position)
pub fn redrawScreen(self: *App) !usize {
    self.terminal_size = try ui.Tui.getTerminalSize();
    var stdout_buffer: [8192]u8 = undefined;
    var buffered_writer = ui.BufferedStdoutWriter.init(&stdout_buffer);
    const writer = buffered_writer.writer();

    // Calculate input field height once for this render
    const input_field_height = try calculateInputFieldHeight(self);

    // Move cursor to home WITHOUT clearing - prevents flicker
    try writer.writeAll("\x1b[H");
    self.clickable_areas.clearRetainingCapacity();
    self.valid_cursor_positions.clearRetainingCapacity();

    var absolute_y: usize = 1;
    for (self.messages.items, 0..) |_, i| {
        const message = &self.messages.items[i];

        // Skip tool JSON if hidden by config
        if (message.role == .tool and !self.config.show_tool_json) continue;

        // Draw message (handles both thinking and content)
        try drawMessage(self, writer, message, i, &absolute_y, input_field_height);
    }

    // Ensure cursor_y is always at a valid position
    if (self.valid_cursor_positions.items.len > 0) {
        var cursor_is_valid = false;
        for (self.valid_cursor_positions.items) |pos| {
            if (pos == self.cursor_y) {
                cursor_is_valid = true;
                break;
            }
        }
        if (!cursor_is_valid) {
            // Snap to last valid position (bottom)
            self.cursor_y = self.valid_cursor_positions.items[self.valid_cursor_positions.items.len - 1];
        }
    }

    // Position cursor after last message content to clear any leftover content
    const screen_y_for_clear = if (absolute_y > self.scroll_y)
        (absolute_y - self.scroll_y) + 1
    else
        1;

    // Only clear if there's space between content and input field
    // input_field_height includes separator, +1 for taskbar
    const input_area_start = if (self.terminal_size.height > input_field_height + 1)
        self.terminal_size.height - input_field_height
    else
        1;
    if (screen_y_for_clear < input_area_start) {
        try writer.print("\x1b[{d};1H\x1b[J", .{screen_y_for_clear});
    }

    try drawInputField(self, writer);
    try ui.drawTaskbar(self, writer);

    try buffered_writer.flush();

    return absolute_y;
}
