// Config Editor Renderer - Draws the configuration UI to the terminal
const std = @import("std");
const config_editor_state = @import("config_editor_state.zig");
const ui = @import("ui.zig");

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
    // Field container border (left)
    try writer.print("\x1b[{d};{d}H│ ", .{ y, box_x });

    // Highlight if focused
    if (is_focused) {
        try writer.writeAll("\x1b[7m"); // Reverse video
    }

    // Field label
    try writer.print("{s}: ", .{field.label});

    // Field value based on type
    switch (field.field_type) {
        .radio => {
            try drawRadioField(writer, field, state);
        },
        .toggle => {
            try drawToggleField(writer, field, state);
        },
        .text_input => {
            try drawTextInputField(writer, field, state);
        },
        .number_input => {
            try drawNumberInputField(writer, field, state);
        },
    }

    if (is_focused) {
        try writer.writeAll("\x1b[0m"); // Reset formatting
    }

    // Right border padding
    // Calculate how much space we've used and pad to box width
    try writer.print("\x1b[{d}G│", .{box_x + box_width - 1});

    // Help text line
    if (field.help_text) |help| {
        try writer.print("\x1b[{d};{d}H│ \x1b[2m{s}\x1b[0m", .{ y + 1, box_x, help });
        try writer.print("\x1b[{d}G│", .{box_x + box_width - 1});
    }
}

/// Draw radio button field (e.g., provider selection)
fn drawRadioField(writer: anytype, field: *const ConfigField, state: *const ConfigEditorState) !void {
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

/// Draw toggle field (checkbox)
fn drawToggleField(writer: anytype, field: *const ConfigField, state: *const ConfigEditorState) !void {
    const is_enabled = getFieldBoolValue(state, field.key);

    if (is_enabled) {
        try writer.writeAll("[✓] ON");
    } else {
        try writer.writeAll("[ ] OFF");
    }
}

/// Draw text input field
fn drawTextInputField(writer: anytype, field: *const ConfigField, state: *const ConfigEditorState) !void {
    const current_value = getFieldValue(state, field.key);

    if (field.is_editing and field.edit_buffer != null) {
        // Show edit buffer with cursor
        try writer.print("{s}█", .{field.edit_buffer.?});
    } else {
        // Show current value
        try writer.print("{s}", .{current_value});
    }
}

/// Draw number input field
fn drawNumberInputField(writer: anytype, field: *const ConfigField, state: *const ConfigEditorState) !void {
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
        } else if (std.mem.eql(u8, field.key, "max_chunks_in_history")) {
            try writer.print("{d}", .{config.max_chunks_in_history});
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
    if (std.mem.eql(u8, key, "embedding_model")) return config.embedding_model;
    if (std.mem.eql(u8, key, "indexing_model")) return config.indexing_model;

    return "";
}

/// Get boolean value from config based on field key
fn getFieldBoolValue(state: *const ConfigEditorState, key: []const u8) bool {
    const config = &state.temp_config;

    if (std.mem.eql(u8, key, "enable_thinking")) return config.enable_thinking;
    if (std.mem.eql(u8, key, "graph_rag_enabled")) return config.graph_rag_enabled;
    if (std.mem.eql(u8, key, "show_tool_json")) return config.show_tool_json;

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
    const llm_provider = @import("llm_provider.zig");

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
