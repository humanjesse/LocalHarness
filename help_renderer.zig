const std = @import("std");
const help_state = @import("help_state");
const ui = @import("ui");
const HelpState = help_state.HelpState;

pub fn render(
    state: *HelpState,
    writer: anytype,
    terminal_width: usize,
    terminal_height: usize,
) !void {
    // Clear screen and move cursor to top
    try writer.writeAll("\x1b[2J\x1b[H");

    // Calculate dimensions for the help box (consistent with config/agents)
    const box_width = @min(terminal_width - 4, 80); // Leave 2 chars padding on each side
    const box_height = terminal_height -| 4; // Leave space for footer
    const left_margin = (terminal_width - box_width) / 2;

    // Calculate visible content area (excluding borders)
    const content_height = box_height -| 2; // Subtract top and bottom border

    // Draw top border
    try moveCursor(writer, left_margin, 1);
    try writer.writeAll("┌");
    var i: usize = 0;
    while (i < box_width - 2) : (i += 1) {
        try writer.writeAll("─");
    }
    try writer.writeAll("┐");

    // Draw content lines
    const start_line = state.scroll_offset;
    const end_line = @min(start_line + content_height, state.total_lines);

    var row: usize = 0;
    var line_idx = start_line;
    while (line_idx < end_line) : ({
        line_idx += 1;
        row += 1;
    }) {
        try moveCursor(writer, left_margin, 2 + row);
        try writer.writeAll("│ "); // Left border + space

        const line = state.content_lines.items[line_idx];
        const available_width = box_width -| 4; // Account for borders and padding (│ + space + space + │)
        const line_visual_width = ui.AnsiParser.getVisibleLength(line);

        // Truncate or pad line to fit within box
        if (line_visual_width >= available_width) {
            // Line is too long, truncate it
            // TODO: Truncate based on visual width, not byte length
            try writer.writeAll(line[0..@min(line.len, available_width)]);
        } else {
            // Line fits, write it and pad with spaces
            try writer.writeAll(line);
            var spaces = available_width - line_visual_width;
            while (spaces > 0) : (spaces -= 1) {
                try writer.writeAll(" ");
            }
        }

        try writer.writeAll(" │"); // Space + right border
    }

    // Fill remaining space with empty lines if content is shorter than box
    while (row < content_height) : (row += 1) {
        try moveCursor(writer, left_margin, 2 + row);
        try writer.writeAll("│ "); // Left border + space
        var spaces: usize = box_width - 4; // Account for borders and padding
        while (spaces > 0) : (spaces -= 1) {
            try writer.writeAll(" ");
        }
        try writer.writeAll(" │"); // Space + right border
    }

    // Draw bottom border
    try moveCursor(writer, left_margin, 2 + content_height);
    try writer.writeAll("└");
    i = 0;
    while (i < box_width - 2) : (i += 1) {
        try writer.writeAll("─");
    }
    try writer.writeAll("┘");

    // Draw footer with instructions
    const footer_row = 2 + content_height + 1;
    try moveCursor(writer, left_margin, footer_row);

    // Calculate scroll indicator
    const scroll_percent = if (state.total_lines > content_height)
        (state.scroll_offset * 100) / (state.total_lines - content_height)
    else
        0;

    const at_top = state.scroll_offset == 0;
    const at_bottom = (state.scroll_offset + content_height) >= state.total_lines;

    var footer_buf: [256]u8 = undefined;
    const footer_text = if (at_top)
        try std.fmt.bufPrint(&footer_buf, "Press ESC to close | ↓/PgDn to scroll down", .{})
    else if (at_bottom)
        try std.fmt.bufPrint(&footer_buf, "Press ESC to close | ↑/PgUp to scroll up", .{})
    else
        try std.fmt.bufPrint(&footer_buf, "Press ESC to close | ↑↓ to scroll ({d}%)", .{scroll_percent});

    // Center the footer text
    const footer_padding = (box_width -| footer_text.len) / 2;
    try moveCursor(writer, left_margin + footer_padding, footer_row);
    try writer.writeAll(footer_text);

    // Flush the output
    try writer.context.flush();
}

fn moveCursor(writer: anytype, x: usize, y: usize) !void {
    var buf: [32]u8 = undefined;
    const seq = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ y, x + 1 });
    try writer.writeAll(seq);
}
