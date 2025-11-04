// Agent Builder Renderer - Draws the agent builder UI to the terminal
const std = @import("std");
const agent_builder_state = @import("agent_builder_state");
const ui = @import("ui");

const AgentBuilderState = agent_builder_state.AgentBuilderState;
const AgentField = agent_builder_state.AgentField;
const FieldType = agent_builder_state.FieldType;

/// Render the agent builder screen
pub fn render(
    state: *AgentBuilderState,
    writer: anytype,
    terminal_width: u16,
    terminal_height: u16,
) !void {
    // Clear screen
    try writer.writeAll("\x1b[2J\x1b[H");

    // Calculate layout dimensions
    const box_width = @min(terminal_width - 4, 80); // Wider box for text areas
    const box_start_x = (terminal_width - box_width) / 2;

    var current_y: usize = 2;

    // Draw title
    try drawCentered(writer, "🤖 Agent Builder", terminal_width, current_y);
    current_y += 1;

    try drawCentered(writer, "Create a new agent with custom tools and behavior", terminal_width, current_y);
    current_y += 1;

    try drawCentered(writer, "Tab/Shift+Tab: navigate | Enter: edit | Space: toggle | Ctrl+S: save | Esc: cancel", terminal_width, current_y);
    current_y += 2;

    // Draw form box
    try writer.print("\x1b[{d};{d}H┌", .{ current_y, box_start_x });
    for (0..box_width - 2) |_| try writer.writeAll("─");
    try writer.writeAll("┐");
    current_y += 1;

    // Draw each field
    for (state.fields, 0..) |*field, idx| {
        const is_focused = idx == state.focused_field_index;

        switch (field.field_type) {
            .text_input => {
                try drawTextInputField(
                    writer,
                    field,
                    box_start_x,
                    &current_y,
                    box_width,
                    is_focused,
                );
            },
            .text_area => {
                try drawTextAreaField(
                    writer,
                    field,
                    box_start_x,
                    &current_y,
                    box_width,
                    terminal_height,
                    is_focused,
                );
            },
            .tool_checkboxes => {
                try drawToolCheckboxes(
                    writer,
                    field,
                    box_start_x,
                    &current_y,
                    box_width,
                    terminal_height,
                    is_focused,
                );
            },
        }
    }

    // Draw form box bottom
    try writer.print("\x1b[{d};{d}H└", .{ current_y, box_start_x });
    for (0..box_width - 2) |_| try writer.writeAll("─");
    try writer.writeAll("┘");
    current_y += 2;

    // Show validation error if present
    if (state.validation_error) |err_msg| {
        try writer.print("\x1b[{d};{d}H", .{ current_y, box_start_x });
        try writer.print("\x1b[31m⚠ {s}\x1b[0m", .{err_msg});
        current_y += 1;
    }

    // Draw action buttons at bottom
    current_y = terminal_height - 3;
    try drawCentered(writer, "[Ctrl+S] Save Agent  [Esc] Cancel", terminal_width, current_y);

    // Show change indicator
    if (state.has_changes) {
        try writer.print("\x1b[{d};{d}H\x1b[33m● Unsaved changes\x1b[0m", .{ terminal_height - 1, box_start_x });
    }
}

/// Draw centered text
fn drawCentered(writer: anytype, text: []const u8, terminal_width: u16, y: usize) !void {
    const visible_len = text.len; // TODO: Strip ANSI for accurate centering
    const start_x = if (terminal_width > visible_len)
        (terminal_width - @as(u16, @intCast(visible_len))) / 2
    else
        0;

    try writer.print("\x1b[{d};{d}H{s}", .{ y, start_x, text });
}

/// Draw text input field (single line)
fn drawTextInputField(
    writer: anytype,
    field: *const AgentField,
    box_x: u16,
    current_y: *usize,
    box_width: u16,
    is_focused: bool,
) !void {
    // Label line
    try writer.print("\x1b[{d};{d}H│ ", .{ current_y.*, box_x });

    if (is_focused) {
        try writer.writeAll("\x1b[7m"); // Reverse video
    }

    try writer.print("{s}: ", .{field.label});

    // Value
    if (field.edit_buffer) |*buffer| {
        if (buffer.items.len > 0) {
            const max_display = box_width - field.label.len - 8;
            const display_text = if (buffer.items.len > max_display)
                buffer.items[0..max_display]
            else
                buffer.items;
            try writer.print("{s}", .{display_text});

            // Show cursor if editing
            if (is_focused and field.is_editing) {
                try writer.writeAll("_");
            }
        } else if (is_focused and field.is_editing) {
            try writer.writeAll("_");
        }
    }

    if (is_focused) {
        try writer.writeAll("\x1b[0m");
    }

    try writer.print("\x1b[{d}G│", .{box_x + box_width - 1});
    current_y.* += 1;

    // Help text
    if (field.help_text) |help| {
        try writer.print("\x1b[{d};{d}H│ \x1b[2m{s}\x1b[0m", .{ current_y.*, box_x, help });
        try writer.print("\x1b[{d}G│", .{box_x + box_width - 1});
        current_y.* += 1;
    }

    current_y.* += 1; // Extra spacing
}

/// Draw text area field (multi-line)
fn drawTextAreaField(
    writer: anytype,
    field: *const AgentField,
    box_x: u16,
    current_y: *usize,
    box_width: u16,
    terminal_height: u16,
    is_focused: bool,
) !void {
    _ = terminal_height; // Reserved for scrolling

    // Label line
    try writer.print("\x1b[{d};{d}H│ ", .{ current_y.*, box_x });

    if (is_focused) {
        try writer.writeAll("\x1b[1;36m"); // Cyan bold
    }

    try writer.print("{s}:", .{field.label});

    if (is_focused) {
        try writer.writeAll("\x1b[0m");
    }

    try writer.print("\x1b[{d}G│", .{box_x + box_width - 1});
    current_y.* += 1;

    // Content area (show first few lines)
    const max_lines = 5;
    var line_count: usize = 0;

    if (field.edit_buffer) |*buffer| {
        var line_iter = std.mem.splitScalar(u8, buffer.items, '\n');
        while (line_iter.next()) |line| {
            if (line_count >= max_lines) break;

            try writer.print("\x1b[{d};{d}H│ ", .{ current_y.*, box_x });

            if (is_focused) {
                try writer.writeAll("\x1b[7m");
            }

            const max_display = box_width - 6;
            const display_line = if (line.len > max_display)
                line[0..max_display]
            else
                line;

            try writer.print("  {s}", .{display_line});

            if (is_focused) {
                try writer.writeAll("\x1b[0m");
            }

            try writer.print("\x1b[{d}G│", .{box_x + box_width - 1});
            current_y.* += 1;
            line_count += 1;
        }
    }

    // Show placeholder if empty
    if (line_count == 0) {
        try writer.print("\x1b[{d};{d}H│ \x1b[2m  (Enter to edit...)\x1b[0m", .{ current_y.*, box_x });
        try writer.print("\x1b[{d}G│", .{box_x + box_width - 1});
        current_y.* += 1;
        line_count = 1;
    }

    // Pad remaining lines
    while (line_count < max_lines) : (line_count += 1) {
        try writer.print("\x1b[{d};{d}H│ ", .{ current_y.*, box_x });
        try writer.print("\x1b[{d}G│", .{box_x + box_width - 1});
        current_y.* += 1;
    }

    // Help text
    if (field.help_text) |help| {
        try writer.print("\x1b[{d};{d}H│ \x1b[2m{s}\x1b[0m", .{ current_y.*, box_x, help });
        try writer.print("\x1b[{d}G│", .{box_x + box_width - 1});
        current_y.* += 1;
    }

    current_y.* += 1;
}

/// Draw tool checkboxes
fn drawToolCheckboxes(
    writer: anytype,
    field: *const AgentField,
    box_x: u16,
    current_y: *usize,
    box_width: u16,
    terminal_height: u16,
    is_focused: bool,
) !void {
    _ = terminal_height; // Reserved for scrolling

    // Label line
    try writer.print("\x1b[{d};{d}H│ ", .{ current_y.*, box_x });

    if (is_focused) {
        try writer.writeAll("\x1b[1;36m"); // Cyan bold
    }

    try writer.print("{s}:", .{field.label});

    if (is_focused) {
        try writer.writeAll("\x1b[0m");
    }

    try writer.print("\x1b[{d}G│", .{box_x + box_width - 1});
    current_y.* += 1;

    // Help text
    if (field.help_text) |help| {
        try writer.print("\x1b[{d};{d}H│ \x1b[2m{s}\x1b[0m", .{ current_y.*, box_x, help });
        try writer.print("\x1b[{d}G│", .{box_x + box_width - 1});
        current_y.* += 1;
    }

    // Draw checkboxes (show max 15 at a time - covers typical tool count)
    const max_visible = 15;
    var shown: usize = 0;

    if (field.tool_options) |tools| {
        if (field.tool_selected) |selected| {
            for (tools, selected, 0..) |tool_name, is_selected, idx| {
                if (shown >= max_visible) break;

                try writer.print("\x1b[{d};{d}H│ ", .{ current_y.*, box_x });

                // Highlight current checkbox if focused and this is the selected one
                const is_this_focused = is_focused and idx == field.checkbox_focus_index;
                if (is_this_focused) {
                    try writer.writeAll("\x1b[7m"); // Reverse video
                }

                // Draw checkbox
                const checkbox = if (is_selected) "[✓]" else "[ ]";
                try writer.print("  {s} {s}", .{ checkbox, tool_name });

                if (is_this_focused) {
                    try writer.writeAll("\x1b[0m");
                }

                try writer.print("\x1b[{d}G│", .{box_x + box_width - 1});
                current_y.* += 1;
                shown += 1;
            }

            // Show "more tools" indicator if needed
            if (tools.len > max_visible) {
                try writer.print("\x1b[{d};{d}H│ \x1b[2m  ... and {d} more tools (scroll down to see all)\x1b[0m", .{ current_y.*, box_x, tools.len - max_visible });
                try writer.print("\x1b[{d}G│", .{box_x + box_width - 1});
                current_y.* += 1;
            }
        }
    }

    current_y.* += 1;
}
