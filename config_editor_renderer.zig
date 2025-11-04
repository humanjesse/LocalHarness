// Config Editor Renderer - Draws the configuration UI to the terminal
const std = @import("std");
const config_editor_state = @import("config_editor_state");
const ui = @import("ui");

const ConfigEditorState = config_editor_state.ConfigEditorState;
const ConfigSection = config_editor_state.ConfigSection;
const ConfigField = config_editor_state.ConfigField;
const FieldType = config_editor_state.FieldType;

/// Render the config editor screen
pub fn render(
    state: *ConfigEditorState,
    writer: anytype,
    terminal_width: u16,
    terminal_height: u16,
) !void {
    // Clear screen
    try writer.writeAll("\x1b[2J\x1b[H");

    // Calculate layout dimensions
    const box_width = @min(terminal_width - 4, 70); // Leave 2 chars padding on each side
    const box_start_x = (terminal_width - box_width) / 2; // Center horizontally

    var current_y: usize = 2; // Start 2 rows from top

    // Draw title
    try drawCentered(writer, "Configuration Editor", terminal_width, current_y);
    current_y += 1;

    try drawCentered(writer, "Press Tab/Shift+Tab to navigate, Enter to edit, Ctrl+S to save, Esc to cancel", terminal_width, current_y);
    current_y += 2;

    // Draw each section
    var global_field_index: usize = 0;
    for (state.sections) |section| {
        // Section header
        try writer.print("\x1b[{d};{d}H", .{ current_y, box_start_x });
        try writer.print("\x1b[1;36m{s}\x1b[0m", .{section.title}); // Cyan, bold
        current_y += 1;

        // Section box top border
        try writer.print("\x1b[{d};{d}H┌", .{ current_y, box_start_x });
        for (0..box_width - 2) |_| try writer.writeAll("─");
        try writer.writeAll("┐");
        current_y += 1;

        // Draw fields
        for (section.fields) |field| {
            const is_focused = global_field_index == state.focused_field_index;

            try drawField(
                writer,
                &field,
                state,
                box_start_x,
                current_y,
                box_width,
                is_focused,
            );

            current_y += 2; // Each field takes 2 lines (field + help text)
            global_field_index += 1;
        }

        // Section box bottom border
        try writer.print("\x1b[{d};{d}H└", .{ current_y, box_start_x });
        for (0..box_width - 2) |_| try writer.writeAll("─");
        try writer.writeAll("┘");
        current_y += 2; // Space between sections
    }

    // Draw provider-specific warnings
    try drawProviderWarnings(writer, state, box_start_x, box_width, &current_y, terminal_height);

    // Draw action buttons at bottom
    current_y = terminal_height - 3;
    try drawCentered(writer, "[Ctrl+S] Save  [Esc] Cancel  [Ctrl+R] Reset to Defaults", terminal_width, current_y);

    // Show change indicator if modified
    if (state.has_changes) {
        try writer.print("\x1b[{d};{d}H\x1b[33m● Unsaved changes\x1b[0m", .{ terminal_height - 1, box_start_x });
    }
}

/// Draw a centered line of text
fn drawCentered(writer: anytype, text: []const u8, terminal_width: u16, y: usize) !void {
    // Calculate visible width (strip ANSI codes for centering calculation)
    const visible_len = text.len; // Simplified - in production you'd strip ANSI
    const start_x = if (terminal_width > visible_len)
        (terminal_width - @as(u16, @intCast(visible_len))) / 2
    else
        0;

    try writer.print("\x1b[{d};{d}H{s}", .{ y, start_x, text });
}

/// Calculate visual width of a UTF-8 string (counts codepoints, not bytes)
fn visualWidth(text: []const u8) usize {
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

/// Truncate text to fit within max_width, adding ellipsis if needed
fn truncateText(text: []const u8, max_width: usize, buffer: []u8) []const u8 {
    if (text.len <= max_width) {
        @memcpy(buffer[0..text.len], text);
        return buffer[0..text.len];
    }

    // Need to truncate with ellipsis
    const ellipsis = "...";
    if (max_width <= ellipsis.len) {
        // Not enough space even for ellipsis, just return truncated
        @memcpy(buffer[0..max_width], text[0..max_width]);
        return buffer[0..max_width];
    }

    const text_len = max_width - ellipsis.len;
    @memcpy(buffer[0..text_len], text[0..text_len]);
    @memcpy(buffer[text_len..text_len + ellipsis.len], ellipsis);
    return buffer[0..text_len + ellipsis.len];
}

/// Draw a single field
fn drawField(
    writer: anytype,
    field: *const ConfigField,
    state: *const ConfigEditorState,
    box_x: u16,
    y: usize,
    box_width: u16,
    is_focused: bool,
) !void {
    // Calculate available content width (box_width - borders - padding)
    // Format: "│ content │" so we need to subtract: left border (1) + spaces (2) + right border (1) = 4
    const content_width = box_width -| 4;

    // Create a buffer to accumulate the field content
    var content_buffer: [512]u8 = undefined;
    var content_stream = std.io.fixedBufferStream(&content_buffer);
    const content_writer = content_stream.writer();

    // Build the field content (label + value)
    content_writer.print("{s}: ", .{field.label}) catch {};

    // Field value based on type
    switch (field.field_type) {
        .radio => {
            drawRadioFieldToWriter(content_writer, field, state) catch {};
        },
        .toggle => {
            drawToggleFieldToWriter(content_writer, field, state) catch {};
        },
        .text_input => {
            drawTextInputFieldToWriter(content_writer, field, state) catch {};
        },
        .number_input => {
            drawNumberInputFieldToWriter(content_writer, field, state) catch {};
        },
    }

    const content = content_stream.getWritten();

    // Truncate content if it exceeds available width
    var truncate_buffer: [512]u8 = undefined;
    const display_content = truncateText(content, content_width, &truncate_buffer);

    // Now render the line
    try writer.print("\x1b[{d};{d}H│ ", .{ y, box_x });

    // Highlight if focused
    if (is_focused) {
        try writer.writeAll("\x1b[7m"); // Reverse video
    }

    try writer.writeAll(display_content);

    if (is_focused) {
        try writer.writeAll("\x1b[0m"); // Reset formatting
    }

    // Pad remaining space and draw right border
    // Use visual width (UTF-8 codepoint count) instead of byte length
    const used_width = visualWidth(display_content) + 2; // +2 for "│ " prefix
    const padding_needed = box_width -| used_width -| 1; // -1 for right border
    for (0..padding_needed) |_| {
        try writer.writeAll(" ");
    }
    try writer.writeAll("│");

    // Help text line
    if (field.help_text) |help| {
        var help_buffer: [512]u8 = undefined;
        const display_help = truncateText(help, content_width, &help_buffer);

        try writer.print("\x1b[{d};{d}H│ \x1b[2m{s}\x1b[0m", .{ y + 1, box_x, display_help });

        // Pad and draw right border for help text line
        // Use visual width (UTF-8 codepoint count) instead of byte length
        const help_used_width = visualWidth(display_help) + 2; // +2 for "│ " prefix
        const help_padding_needed = box_width -| help_used_width -| 1;
        for (0..help_padding_needed) |_| {
            try writer.writeAll(" ");
        }
        try writer.writeAll("│");
    }
}

/// Draw radio button field to any writer (for buffering)
fn drawRadioFieldToWriter(writer: anytype, field: *const ConfigField, state: *const ConfigEditorState) !void {
    if (field.options) |options| {
        // Get current value from config
        const current_value = getFieldValue(state, field.key);

        for (options, 0..) |option, i| {
            if (i > 0) try writer.writeAll("  ");

            const is_selected = std.mem.eql(u8, current_value, option);
            if (is_selected) {
                try writer.print("[●] {s}", .{option});
            } else {
                try writer.print("[ ] {s}", .{option});
            }
        }
    }
}

/// Draw toggle field to any writer (for buffering)
fn drawToggleFieldToWriter(writer: anytype, field: *const ConfigField, state: *const ConfigEditorState) !void {
    const is_enabled = getFieldBoolValue(state, field.key);

    if (is_enabled) {
        try writer.writeAll("[✓] ON");
    } else {
        try writer.writeAll("[ ] OFF");
    }
}

/// Draw text input field to any writer (for buffering)
fn drawTextInputFieldToWriter(writer: anytype, field: *const ConfigField, state: *const ConfigEditorState) !void {
    const current_value = getFieldValue(state, field.key);

    if (field.is_editing and field.edit_buffer != null) {
        // Show edit buffer with cursor
        try writer.print("{s}█", .{field.edit_buffer.?});
    } else {
        // Show current value
        try writer.print("{s}", .{current_value});
    }
}

/// Draw number input field to any writer (for buffering)
fn drawNumberInputFieldToWriter(writer: anytype, field: *const ConfigField, state: *const ConfigEditorState) !void {
    const config = &state.temp_config;

    if (field.is_editing and field.edit_buffer != null) {
        // Show edit buffer with cursor
        try writer.print("{s}█", .{field.edit_buffer.?});
    } else {
        // Get actual number value from config and format it
        if (std.mem.eql(u8, field.key, "num_ctx")) {
            try writer.print("{d}", .{config.num_ctx});
        } else if (std.mem.eql(u8, field.key, "num_predict")) {
            try writer.print("{d}", .{config.num_predict});
        } else if (std.mem.eql(u8, field.key, "scroll_lines")) {
            try writer.print("{d}", .{config.scroll_lines});
        } else if (std.mem.eql(u8, field.key, "file_read_small_threshold")) {
            try writer.print("{d}", .{config.file_read_small_threshold});
        } else {
            try writer.writeAll("0");
        }
    }
}

/// Get string value from config based on field key
fn getFieldValue(state: *const ConfigEditorState, key: []const u8) []const u8 {
    const config = &state.temp_config;

    if (std.mem.eql(u8, key, "provider")) return config.provider;
    if (std.mem.eql(u8, key, "ollama_host")) return config.ollama_host;
    if (std.mem.eql(u8, key, "lmstudio_host")) return config.lmstudio_host;
    if (std.mem.eql(u8, key, "model")) return config.model;

    return "";
}

/// Get boolean value from config based on field key
fn getFieldBoolValue(state: *const ConfigEditorState, key: []const u8) bool {
    const config = &state.temp_config;

    // Check global boolean fields first
    if (std.mem.eql(u8, key, "enable_thinking")) return config.enable_thinking;
    if (std.mem.eql(u8, key, "show_tool_json")) return config.show_tool_json;

    // Try provider-specific boolean fields
    const provider_value = config.getProviderField(config.provider, key);
    if (provider_value == .boolean) {
        return provider_value.boolean;
    }

    return false;
}

/// Draw provider-specific warnings and helpful tips
fn drawProviderWarnings(
    writer: anytype,
    state: *const ConfigEditorState,
    box_x: u16,
    box_width: u16,
    current_y: *usize,
    terminal_height: u16,
) !void {
    _ = box_width; // Not used currently, but kept for future enhancements
    const config = &state.temp_config;
    const llm_provider = @import("llm_provider");

    // Check if we have enough space for warnings (need at least 2 lines before footer)
    if (current_y.* + 2 >= terminal_height - 4) {
        return; // Not enough space, skip warning
    }

    // Get provider capabilities from registry
    const caps = llm_provider.ProviderRegistry.get(config.provider) orelse return;

    // Display all warnings for this provider (data-driven!)
    for (caps.config_warnings) |warning| {
        try writer.print("\x1b[{d};{d}H\x1b[33m⚠ Note: {s}\x1b[0m", .{ current_y.*, box_x, warning.message });
        current_y.* += 2; // Space after warning
    }
}
