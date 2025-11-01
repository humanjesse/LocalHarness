// Config Editor Input Handler - Processes user input for the config editor
const std = @import("std");
const config_editor_state = @import("config_editor_state.zig");

const ConfigEditorState = config_editor_state.ConfigEditorState;
const ConfigField = config_editor_state.ConfigField;
const FieldType = config_editor_state.FieldType;

/// Result of handling input
pub const InputResult = enum {
    /// Continue showing editor
    @"continue",
    /// User wants to save and close
    save_and_close,
    /// User wants to cancel (discard changes)
    cancel,
    /// Screen needs redraw
    redraw,
};

/// Handle input for the config editor
pub fn handleInput(
    state: *ConfigEditorState,
    input: []const u8,
) !InputResult {
    // Handle escape sequences first (arrow keys, function keys, etc.)
    if (input.len >= 3 and input[0] == 0x1B and input[1] == '[') {
        return try handleEscapeSequence(state, input);
    }

    // Handle single-byte inputs
    if (input.len == 1) {
        return try handleSingleKey(state, input[0]);
    }

    // Handle multi-byte input (UTF-8, etc.)
    return .@"continue";
}

/// Handle escape sequences (arrow keys, etc.)
fn handleEscapeSequence(state: *ConfigEditorState, input: []const u8) !InputResult {
    // Up arrow: \x1b[A
    if (input.len == 3 and input[2] == 'A') {
        state.focusPrevious();
        return .redraw;
    }

    // Down arrow: \x1b[B
    if (input.len == 3 and input[2] == 'B') {
        state.focusNext();
        return .redraw;
    }

    // Left arrow: \x1b[D - cycle radio buttons backward
    if (input.len == 3 and input[2] == 'D') {
        if (state.getFocusedField()) |field| {
            if (field.field_type == .radio) {
                try cycleRadioBackward(state, field);
                state.has_changes = true;
                return .redraw;
            }
        }
        return .@"continue";
    }

    // Right arrow: \x1b[C - cycle radio buttons forward
    if (input.len == 3 and input[2] == 'C') {
        if (state.getFocusedField()) |field| {
            if (field.field_type == .radio) {
                try cycleRadioForward(state, field);
                state.has_changes = true;
                return .redraw;
            }
        }
        return .@"continue";
    }

    return .@"continue";
}

/// Handle single key presses
fn handleSingleKey(state: *ConfigEditorState, key: u8) !InputResult {
    // If we're in edit mode for a text/number input, pass most keys to input handler
    // (except Tab and Ctrl keys which should still work for navigation/save)
    if (state.getFocusedField()) |field| {
        if (field.is_editing and (field.field_type == .text_input or field.field_type == .number_input)) {
            // Allow Tab, Ctrl+S, Esc to still work in edit mode
            if (key != '\t' and key != 0x13 and key != 0x1B) {
                return try handleTextInput(state, field, key);
            }
        }
    }

    switch (key) {
        // Tab: Move to next field
        '\t' => {
            // If in edit mode, commit changes first
            if (state.getFocusedField()) |field| {
                if (field.is_editing) {
                    if (field.field_type == .text_input) {
                        try commitTextEdit(state, field);
                    } else if (field.field_type == .number_input) {
                        try commitNumberEdit(state, field);
                    }
                    field.is_editing = false;
                    state.has_changes = true;
                }
            }
            state.focusNext();
            return .redraw;
        },

        // Enter: Toggle/activate current field
        '\r', '\n' => {
            return try handleEnterKey(state);
        },

        // Escape: Exit edit mode, or cancel and close if not editing
        0x1B => {
            if (state.getFocusedField()) |field| {
                if (field.is_editing and (field.field_type == .text_input or field.field_type == .number_input)) {
                    // Exit edit mode without saving changes to this field
                    field.is_editing = false;
                    return .redraw;
                }
            }
            return .cancel;
        },

        // Ctrl+S (Save): Save and close
        0x13 => {
            return .save_and_close;
        },

        // Ctrl+R (Reset): Reset to defaults
        0x12 => {
            // TODO: Implement reset to defaults
            return .redraw;
        },

        // Space: Toggle boolean fields
        ' ' => {
            if (state.getFocusedField()) |field| {
                if (field.field_type == .toggle) {
                    try toggleField(state, field);
                    state.has_changes = true;
                    return .redraw;
                }
            }
            return .@"continue";
        },

        else => {
            // If in edit mode for text input, handle character input
            if (state.getFocusedField()) |field| {
                if (field.is_editing and field.field_type == .text_input) {
                    return try handleTextInput(state, field, key);
                }
            }
            return .@"continue";
        },
    }
}

/// Handle Enter key on current field
fn handleEnterKey(state: *ConfigEditorState) !InputResult {
    if (state.getFocusedField()) |field| {
        switch (field.field_type) {
            .toggle => {
                try toggleField(state, field);
                state.has_changes = true;
                return .redraw;
            },
            .radio => {
                try cycleRadioForward(state, field);
                state.has_changes = true;
                return .redraw;
            },
            .text_input => {
                if (field.is_editing) {
                    // Finish editing - save buffer to config
                    try commitTextEdit(state, field);
                    field.is_editing = false;
                    state.has_changes = true;
                } else {
                    // Start editing - copy current value to edit buffer
                    try startTextEdit(state, field);
                }
                return .redraw;
            },
            .number_input => {
                if (field.is_editing) {
                    // Finish editing - parse buffer and save to config
                    try commitNumberEdit(state, field);
                    field.is_editing = false;
                    state.has_changes = true;
                } else {
                    // Start editing - copy current number to edit buffer
                    try startNumberEdit(state, field);
                }
                return .redraw;
            },
        }
    }
    return .@"continue";
}

/// Toggle a boolean field
fn toggleField(state: *ConfigEditorState, field: *ConfigField) !void {
    const config = &state.temp_config;
    const llm_provider = @import("llm_provider.zig");

    // Check if this is a shared toggle field
    if (std.mem.eql(u8, field.key, "enable_thinking")) {
        config.enable_thinking = !config.enable_thinking;
    } else if (std.mem.eql(u8, field.key, "graph_rag_enabled")) {
        config.graph_rag_enabled = !config.graph_rag_enabled;
    } else if (std.mem.eql(u8, field.key, "show_tool_json")) {
        config.show_tool_json = !config.show_tool_json;
    } else if (std.mem.eql(u8, field.key, "indexing_enable_thinking")) {
        config.indexing_enable_thinking = !config.indexing_enable_thinking;
    } else {
        // Try provider-specific toggle fields
        const current_value = config.getProviderField(config.provider, field.key);
        if (current_value == .boolean) {
            const new_value = llm_provider.ConfigValue{ .boolean = !current_value.boolean };
            try config.setProviderField(state.allocator, config.provider, field.key, new_value);
        }
    }
}

/// Cycle radio button forward
fn cycleRadioForward(state: *ConfigEditorState, field: *ConfigField) !void {
    if (field.options) |options| {
        const current_value = getCurrentRadioValue(state, field.key);

        // Find current index
        var current_idx: ?usize = null;
        for (options, 0..) |option, i| {
            if (std.mem.eql(u8, current_value, option)) {
                current_idx = i;
                break;
            }
        }

        // Move to next option (wrap around)
        const next_idx = if (current_idx) |idx|
            (idx + 1) % options.len
        else
            0;

        try setRadioValue(state, field.key, options[next_idx]);
    }
}

/// Cycle radio button backward
fn cycleRadioBackward(state: *ConfigEditorState, field: *ConfigField) !void {
    if (field.options) |options| {
        const current_value = getCurrentRadioValue(state, field.key);

        var current_idx: ?usize = null;
        for (options, 0..) |option, i| {
            if (std.mem.eql(u8, current_value, option)) {
                current_idx = i;
                break;
            }
        }

        const prev_idx = if (current_idx) |idx|
            if (idx == 0) options.len - 1 else idx - 1
        else
            options.len - 1;

        try setRadioValue(state, field.key, options[prev_idx]);
    }
}

/// Start editing a text field
fn startTextEdit(state: *ConfigEditorState, field: *ConfigField) !void {
    const config = &state.temp_config;

    // Free old buffer if exists
    if (field.edit_buffer) |old_buffer| {
        state.allocator.free(old_buffer);
    }

    // Handle special nullable fields that need formatting
    if (std.mem.eql(u8, field.key, "indexing_temperature")) {
        field.edit_buffer = if (config.indexing_temperature) |temp|
            try std.fmt.allocPrint(state.allocator, "{d:.2}", .{temp})
        else
            try state.allocator.dupe(u8, "null");
    } else if (std.mem.eql(u8, field.key, "indexing_num_predict")) {
        field.edit_buffer = if (config.indexing_num_predict) |num|
            try std.fmt.allocPrint(state.allocator, "{d}", .{num})
        else
            try state.allocator.dupe(u8, "null");
    } else if (std.mem.eql(u8, field.key, "indexing_repeat_penalty")) {
        field.edit_buffer = if (config.indexing_repeat_penalty) |penalty|
            try std.fmt.allocPrint(state.allocator, "{d:.2}", .{penalty})
        else
            try state.allocator.dupe(u8, "null");
    } else {
        // Get current value from config for regular text fields
        const current_value = getCurrentTextValue(state, field.key);
        // Allocate edit buffer and copy current value
        field.edit_buffer = try state.allocator.dupe(u8, current_value);
    }

    field.is_editing = true;
}

/// Commit text edit to config
fn commitTextEdit(state: *ConfigEditorState, field: *ConfigField) !void {
    if (field.edit_buffer) |buffer| {
        try setTextValue(state, field.key, buffer);
    }
}

/// Start editing a number field
fn startNumberEdit(state: *ConfigEditorState, field: *ConfigField) !void {
    // Get current number value from config and convert to string
    const current_number = getCurrentNumberValue(state, field.key);

    // Format number to string
    var buf: [32]u8 = undefined;
    const number_str = if (std.mem.eql(u8, field.key, "num_predict"))
        try std.fmt.bufPrint(&buf, "{d}", .{@as(isize, @intCast(current_number))})
    else
        try std.fmt.bufPrint(&buf, "{d}", .{current_number});

    // Allocate edit buffer and copy formatted number
    const buffer = try state.allocator.dupe(u8, number_str);

    // Free old buffer if exists
    if (field.edit_buffer) |old_buffer| {
        state.allocator.free(old_buffer);
    }

    field.edit_buffer = buffer;
    field.is_editing = true;
}

/// Commit number edit to config
fn commitNumberEdit(state: *ConfigEditorState, field: *ConfigField) !void {
    if (field.edit_buffer) |buffer| {
        // Parse the string buffer to a number
        const parsed = std.fmt.parseInt(isize, buffer, 10) catch {
            // If parsing fails, just ignore the edit
            return;
        };

        try setNumberValue(state, field.key, parsed);
    }
}

/// Handle character input during text editing
fn handleTextInput(state: *ConfigEditorState, field: *ConfigField, key: u8) !InputResult {
    if (field.edit_buffer) |old_buffer| {
        // Handle backspace
        if (key == 0x7F or key == 0x08) {
            if (old_buffer.len > 0) {
                // Shrink buffer by 1 character
                const new_buffer = try state.allocator.alloc(u8, old_buffer.len - 1);
                @memcpy(new_buffer, old_buffer[0..old_buffer.len - 1]);
                state.allocator.free(old_buffer);
                field.edit_buffer = new_buffer;
                return .redraw;
            }
            return .@"continue";
        }
        // Handle printable characters
        else if (key >= 0x20 and key <= 0x7E) {
            // For number inputs, only accept digits and minus sign
            if (field.field_type == .number_input) {
                const is_digit = key >= '0' and key <= '9';
                const is_minus = key == '-' and old_buffer.len == 0; // Only at start
                if (!is_digit and !is_minus) {
                    return .@"continue";
                }
            }

            // Grow buffer by 1 and append character
            const new_buffer = try state.allocator.alloc(u8, old_buffer.len + 1);
            @memcpy(new_buffer[0..old_buffer.len], old_buffer);
            new_buffer[old_buffer.len] = key;
            state.allocator.free(old_buffer);
            field.edit_buffer = new_buffer;
            return .redraw;
        }
    }

    return .@"continue";
}

/// Get current radio value from config
fn getCurrentRadioValue(state: *const ConfigEditorState, key: []const u8) []const u8 {
    const config = &state.temp_config;

    if (std.mem.eql(u8, key, "provider")) return config.provider;

    return "";
}

/// Set radio value in config
fn setRadioValue(state: *ConfigEditorState, key: []const u8, value: []const u8) !void {
    const config = &state.temp_config;

    if (std.mem.eql(u8, key, "provider")) {
        const old_provider = config.provider;
        const changed = !std.mem.eql(u8, old_provider, value);

        state.allocator.free(config.provider);
        config.provider = try state.allocator.dupe(u8, value);

        // Rebuild sections when provider changes to show provider-specific fields
        if (changed) {
            try state.rebuildSections();
        }
    }
}

/// Get current text value from config
fn getCurrentTextValue(state: *const ConfigEditorState, key: []const u8) []const u8 {
    const config = &state.temp_config;

    // Shared fields
    if (std.mem.eql(u8, key, "model")) return config.model;
    if (std.mem.eql(u8, key, "embedding_model")) return config.embedding_model;
    if (std.mem.eql(u8, key, "indexing_model")) return config.indexing_model;

    // Try provider-specific fields
    const provider_value = config.getProviderField(config.provider, key);
    if (provider_value == .text) {
        return provider_value.text;
    }

    return "";
}

/// Set text value in config
fn setTextValue(state: *ConfigEditorState, key: []const u8, value: []const u8) !void {
    const config = &state.temp_config;
    const llm_provider = @import("llm_provider.zig");

    // Shared fields
    if (std.mem.eql(u8, key, "model")) {
        state.allocator.free(config.model);
        config.model = try state.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "embedding_model")) {
        state.allocator.free(config.embedding_model);
        config.embedding_model = try state.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "indexing_model")) {
        state.allocator.free(config.indexing_model);
        config.indexing_model = try state.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "indexing_temperature")) {
        // Parse nullable float - "null" or empty = null, otherwise parse as float
        if (std.mem.eql(u8, value, "null") or value.len == 0) {
            config.indexing_temperature = null;
        } else {
            config.indexing_temperature = std.fmt.parseFloat(f32, value) catch null;
        }
    } else if (std.mem.eql(u8, key, "indexing_num_predict")) {
        // Parse nullable int - "null" or empty = null, otherwise parse as int
        if (std.mem.eql(u8, value, "null") or value.len == 0) {
            config.indexing_num_predict = null;
        } else {
            config.indexing_num_predict = std.fmt.parseInt(isize, value, 10) catch null;
        }
    } else if (std.mem.eql(u8, key, "indexing_repeat_penalty")) {
        // Parse nullable float - "null" or empty = null, otherwise parse as float
        if (std.mem.eql(u8, value, "null") or value.len == 0) {
            config.indexing_repeat_penalty = null;
        } else {
            config.indexing_repeat_penalty = std.fmt.parseFloat(f32, value) catch null;
        }
    } else {
        // Try provider-specific text fields
        const new_value = llm_provider.ConfigValue{ .text = value };
        try config.setProviderField(state.allocator, config.provider, key, new_value);
    }
}

/// Get current number value from config
fn getCurrentNumberValue(state: *const ConfigEditorState, key: []const u8) isize {
    const config = &state.temp_config;

    if (std.mem.eql(u8, key, "num_ctx")) return @as(isize, @intCast(config.num_ctx));
    if (std.mem.eql(u8, key, "num_predict")) return config.num_predict;
    if (std.mem.eql(u8, key, "max_chunks_in_history")) return @as(isize, @intCast(config.max_chunks_in_history));
    if (std.mem.eql(u8, key, "scroll_lines")) return @as(isize, @intCast(config.scroll_lines));
    if (std.mem.eql(u8, key, "file_read_small_threshold")) return @as(isize, @intCast(config.file_read_small_threshold));
    if (std.mem.eql(u8, key, "indexing_max_iterations")) return @as(isize, @intCast(config.indexing_max_iterations));

    return 0;
}

/// Set number value in config
fn setNumberValue(state: *ConfigEditorState, key: []const u8, value: isize) !void {
    const config = &state.temp_config;

    if (std.mem.eql(u8, key, "num_ctx")) {
        config.num_ctx = @as(usize, @intCast(@max(0, value)));
    } else if (std.mem.eql(u8, key, "num_predict")) {
        config.num_predict = value;
    } else if (std.mem.eql(u8, key, "max_chunks_in_history")) {
        config.max_chunks_in_history = @as(usize, @intCast(@max(0, value)));
    } else if (std.mem.eql(u8, key, "scroll_lines")) {
        config.scroll_lines = @as(usize, @intCast(@max(1, value)));
    } else if (std.mem.eql(u8, key, "file_read_small_threshold")) {
        config.file_read_small_threshold = @as(usize, @intCast(@max(0, value)));
    } else if (std.mem.eql(u8, key, "indexing_max_iterations")) {
        config.indexing_max_iterations = @as(usize, @intCast(@max(1, value)));
    }
}
