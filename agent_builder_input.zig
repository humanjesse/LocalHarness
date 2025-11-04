// Agent Builder Input Handler - Processes user input for the agent builder
const std = @import("std");
const agent_builder_state = @import("agent_builder_state");
const agent_writer = @import("agent_writer");

const AgentBuilderState = agent_builder_state.AgentBuilderState;
const AgentField = agent_builder_state.AgentField;
const FieldType = agent_builder_state.FieldType;

/// Result of handling input
pub const InputResult = enum {
    /// Continue showing builder
    @"continue",
    /// User wants to save and close
    save_and_close,
    /// User wants to cancel (discard changes)
    cancel,
    /// Screen needs redraw
    redraw,
};

/// Handle input for the agent builder
pub fn handleInput(
    state: *AgentBuilderState,
    input: []const u8,
) !InputResult {
    // Handle escape sequences first (arrow keys, etc.)
    if (input.len >= 3 and input[0] == 0x1B and input[1] == '[') {
        return try handleEscapeSequence(state, input);
    }

    // Handle single-byte inputs
    if (input.len == 1) {
        return try handleSingleKey(state, input[0]);
    }

    // Handle multi-byte input
    return .@"continue";
}

/// Handle escape sequences (arrow keys, etc.)
fn handleEscapeSequence(state: *AgentBuilderState, input: []const u8) !InputResult {
    // Up arrow: move focus up
    if (input.len == 3 and input[2] == 'A') {
        if (state.getFocusedField()) |field| {
            if (field.field_type == .tool_checkboxes) {
                // In checkbox field, move checkbox selection up with wrap-around
                if (field.tool_options) |options| {
                    if (field.checkbox_focus_index > 0) {
                        field.checkbox_focus_index -= 1;
                    } else {
                        // At first checkbox - wrap to last
                        field.checkbox_focus_index = options.len - 1;
                    }
                    return .redraw;
                }
            }
        }
        state.focusPrevious();
        return .redraw;
    }

    // Down arrow: move focus down
    if (input.len == 3 and input[2] == 'B') {
        if (state.getFocusedField()) |field| {
            if (field.field_type == .tool_checkboxes) {
                // In checkbox field, move checkbox selection down with wrap-around
                if (field.tool_options) |options| {
                    if (field.checkbox_focus_index < options.len - 1) {
                        field.checkbox_focus_index += 1;
                    } else {
                        // At last checkbox - wrap to first
                        field.checkbox_focus_index = 0;
                    }
                    return .redraw;
                }
            }
        }
        state.focusNext();
        return .redraw;
    }

    return .@"continue";
}

/// Handle single key presses
fn handleSingleKey(state: *AgentBuilderState, key: u8) !InputResult {
    // If we're in edit mode, pass most keys to input handler
    if (state.getFocusedField()) |field| {
        if (field.is_editing and (field.field_type == .text_input or field.field_type == .text_area)) {
            // Allow Tab, Ctrl+S, Esc to still work in edit mode
            if (key != '\t' and key != 0x13 and key != 0x1B) {
                return try handleTextInput(state, field, key);
            }
        }
    }

    switch (key) {
        // Tab: Move to next field
        '\t' => {
            // Commit any pending edits
            if (state.getFocusedField()) |field| {
                if (field.is_editing) {
                    field.is_editing = false;
                    state.has_changes = true;
                }
            }
            state.focusNext();
            return .redraw;
        },

        // Enter: Activate current field
        '\r', '\n' => {
            return try handleEnterKey(state);
        },

        // Escape: Exit edit mode or cancel
        0x1B => {
            if (state.getFocusedField()) |field| {
                if (field.is_editing) {
                    field.is_editing = false;
                    return .redraw;
                }
            }
            return .cancel;
        },

        // Ctrl+S: Save agent
        0x13 => {
            return .save_and_close;
        },

        // Space: Toggle checkbox in tool list
        ' ' => {
            if (state.getFocusedField()) |field| {
                if (field.field_type == .tool_checkboxes) {
                    try toggleCheckbox(state, field);
                    state.has_changes = true;
                    return .redraw;
                }
            }
            return .@"continue";
        },

        else => {
            return .@"continue";
        },
    }
}

/// Handle Enter key on current field
fn handleEnterKey(state: *AgentBuilderState) !InputResult {
    if (state.getFocusedField()) |field| {
        switch (field.field_type) {
            .text_input, .text_area => {
                // Toggle edit mode
                field.is_editing = !field.is_editing;
                if (!field.is_editing) {
                    state.has_changes = true;
                }
                return .redraw;
            },
            .tool_checkboxes => {
                // Toggle current checkbox
                try toggleCheckbox(state, field);
                state.has_changes = true;
                return .redraw;
            },
        }
    }
    return .@"continue";
}

/// Handle text input for text fields
fn handleTextInput(state: *AgentBuilderState, field: *AgentField, key: u8) !InputResult {
    if (field.edit_buffer == null) {
        field.edit_buffer = std.ArrayListUnmanaged(u8){};
    }

    switch (key) {
        // Backspace: Delete last character
        0x7F, 0x08 => {
            if (field.edit_buffer) |*buffer| {
                if (buffer.items.len > 0) {
                    _ = buffer.pop();
                    state.has_changes = true;
                    return .redraw;
                }
            }
        },

        // Enter in text_area: Add newline
        '\r', '\n' => {
            if (field.field_type == .text_area) {
                if (field.edit_buffer) |*buffer| {
                    try buffer.append(state.allocator, '\n');
                    state.has_changes = true;
                    return .redraw;
                }
            } else {
                // In text_input, enter commits
                field.is_editing = false;
                state.has_changes = true;
                return .redraw;
            }
        },

        // Regular character: Append to buffer
        else => {
            if (std.ascii.isPrint(key) or key == '\n') {
                if (field.edit_buffer) |*buffer| {
                    try buffer.append(state.allocator, key);
                    state.has_changes = true;
                    return .redraw;
                }
            }
        },
    }

    return .@"continue";
}

/// Toggle checkbox at current focus
fn toggleCheckbox(state: *AgentBuilderState, field: *AgentField) !void {
    _ = state;
    if (field.tool_selected) |selected| {
        const idx = field.checkbox_focus_index;
        if (idx < selected.len) {
            selected[idx] = !selected[idx];
        }
    }
}

/// Save agent to markdown file
pub fn saveAgent(state: *AgentBuilderState) !void {
    // Validate first
    if (!try state.validate()) {
        return error.ValidationFailed;
    }

    // Get field values
    const name = state.fields[0].edit_buffer.?.items;
    const description = state.fields[1].edit_buffer.?.items;
    const system_prompt = state.fields[2].edit_buffer.?.items;
    const selected_tools = try state.getSelectedTools(state.allocator);
    defer {
        for (selected_tools) |tool_name| {
            state.allocator.free(tool_name);
        }
        state.allocator.free(selected_tools);
    }

    // Write to markdown file
    try agent_writer.writeAgent(
        state.allocator,
        name,
        description,
        system_prompt,
        selected_tools,
    );
}
