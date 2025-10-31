// Agent Builder State - Manages the agent creation/editing UI
const std = @import("std");

/// Field types for agent builder form
pub const FieldType = enum {
    /// Text input for single line (name, description)
    text_input,
    /// Multi-line text area for system prompt
    text_area,
    /// Checkbox list for tool selection
    tool_checkboxes,
};

/// A single field in the agent builder form
pub const AgentField = struct {
    /// Display label (e.g., "Agent Name")
    label: []const u8,

    /// Field type
    field_type: FieldType,

    /// Field identifier (e.g., "name")
    key: []const u8,

    /// Help text shown below the field
    help_text: ?[]const u8 = null,

    /// For text_input/text_area: current value being edited
    edit_buffer: ?std.ArrayListUnmanaged(u8) = null,

    /// For tool_checkboxes: available tool names
    tool_options: ?[]const []const u8 = null,

    /// For tool_checkboxes: which tools are selected
    tool_selected: ?[]bool = null,

    /// Whether this field is currently being edited
    is_editing: bool = false,

    /// For tool_checkboxes: which checkbox has focus
    checkbox_focus_index: usize = 0,
};

/// Main state for the agent builder screen
pub const AgentBuilderState = struct {
    /// Is the agent builder currently active?
    active: bool = false,

    /// Form fields
    fields: []AgentField,

    /// Currently focused field index
    focused_field_index: usize = 0,

    /// Allocator for managing state
    allocator: std.mem.Allocator,

    /// Has user made any changes?
    has_changes: bool = false,

    /// Scroll position (for when form is taller than screen)
    scroll_y: usize = 0,

    /// Validation errors (null if valid)
    validation_error: ?[]const u8 = null,

    /// Initialize agent builder state
    pub fn init(allocator: std.mem.Allocator) !AgentBuilderState {
        // Get list of all available tools
        const tool_names = try getAllToolNames(allocator);

        // Create form fields
        var fields = std.ArrayListUnmanaged(AgentField){};

        // Field 1: Agent Name (text input)
        try fields.append(allocator, .{
            .label = "Agent Name",
            .field_type = .text_input,
            .key = "name",
            .help_text = "Unique identifier (lowercase, hyphens only)",
            .edit_buffer = std.ArrayListUnmanaged(u8){},
        });

        // Field 2: Description (text input)
        try fields.append(allocator, .{
            .label = "Description",
            .field_type = .text_input,
            .key = "description",
            .help_text = "Brief description of what this agent does",
            .edit_buffer = std.ArrayListUnmanaged(u8){},
        });

        // Field 3: System Prompt (text area)
        try fields.append(allocator, .{
            .label = "System Prompt",
            .field_type = .text_area,
            .key = "system_prompt",
            .help_text = "Instructions that define the agent's behavior",
            .edit_buffer = std.ArrayListUnmanaged(u8){},
        });

        // Field 4: Tools (checkbox list)
        const tool_selected = try allocator.alloc(bool, tool_names.len);
        @memset(tool_selected, false); // Default: no tools selected

        try fields.append(allocator, .{
            .label = "Available Tools",
            .field_type = .tool_checkboxes,
            .key = "tools",
            .help_text = "Select which tools this agent can use",
            .tool_options = tool_names,
            .tool_selected = tool_selected,
        });

        return AgentBuilderState{
            .active = true,
            .fields = try fields.toOwnedSlice(allocator),
            .focused_field_index = 0,
            .allocator = allocator,
            .has_changes = false,
            .scroll_y = 0,
            .validation_error = null,
        };
    }

    /// Clean up all allocated memory
    pub fn deinit(self: *AgentBuilderState) void {
        // Free fields
        for (self.fields) |*field| {
            if (field.edit_buffer) |*buffer| {
                buffer.deinit(self.allocator);
            }
            if (field.tool_options) |options| {
                for (options) |tool_name| {
                    self.allocator.free(tool_name);
                }
                self.allocator.free(options);
            }
            if (field.tool_selected) |selected| {
                self.allocator.free(selected);
            }
        }
        self.allocator.free(self.fields);

        // Free validation error if present
        if (self.validation_error) |err_msg| {
            self.allocator.free(err_msg);
        }
    }

    /// Get the currently focused field
    pub fn getFocusedField(self: *AgentBuilderState) ?*AgentField {
        if (self.focused_field_index < self.fields.len) {
            return &self.fields[self.focused_field_index];
        }
        return null;
    }

    /// Move focus to next field (wraps around)
    pub fn focusNext(self: *AgentBuilderState) void {
        if (self.fields.len > 0) {
            self.focused_field_index = (self.focused_field_index + 1) % self.fields.len;
        }
    }

    /// Move focus to previous field (wraps around)
    pub fn focusPrevious(self: *AgentBuilderState) void {
        if (self.fields.len > 0) {
            if (self.focused_field_index == 0) {
                self.focused_field_index = self.fields.len - 1;
            } else {
                self.focused_field_index -= 1;
            }
        }
    }

    /// Validate current form state
    pub fn validate(self: *AgentBuilderState) !bool {
        // Free previous validation error
        if (self.validation_error) |err| {
            self.allocator.free(err);
            self.validation_error = null;
        }

        // Get field values
        const name_field = &self.fields[0];
        const desc_field = &self.fields[1];
        const prompt_field = &self.fields[2];

        // Validate name
        if (name_field.edit_buffer) |*buffer| {
            if (buffer.items.len == 0) {
                self.validation_error = try self.allocator.dupe(u8, "Agent name is required");
                return false;
            }

            // Check name format (lowercase, hyphens, underscores only)
            for (buffer.items) |char| {
                const is_valid = std.ascii.isLower(char) or
                                std.ascii.isDigit(char) or
                                char == '-' or
                                char == '_';
                if (!is_valid) {
                    self.validation_error = try self.allocator.dupe(u8, "Name must contain only lowercase letters, numbers, hyphens, and underscores");
                    return false;
                }
            }
        }

        // Validate description
        if (desc_field.edit_buffer) |*buffer| {
            if (buffer.items.len == 0) {
                self.validation_error = try self.allocator.dupe(u8, "Description is required");
                return false;
            }
        }

        // Validate system prompt
        if (prompt_field.edit_buffer) |*buffer| {
            if (buffer.items.len == 0) {
                self.validation_error = try self.allocator.dupe(u8, "System prompt is required");
                return false;
            }
        }

        return true;
    }

    /// Get list of selected tool names
    pub fn getSelectedTools(self: *const AgentBuilderState, allocator: std.mem.Allocator) ![]const []const u8 {
        const tools_field = &self.fields[3]; // Tools checkbox field

        var selected = std.ArrayListUnmanaged([]const u8){};
        // Note: No defer here - toOwnedSlice() transfers ownership to caller

        if (tools_field.tool_options) |options| {
            if (tools_field.tool_selected) |selected_flags| {
                for (options, selected_flags) |tool_name, is_selected| {
                    if (is_selected) {
                        try selected.append(allocator, try allocator.dupe(u8, tool_name));
                    }
                }
            }
        }

        return selected.toOwnedSlice(allocator);
    }
};

/// Get list of all available tool names dynamically
/// This automatically includes any new tools added to tools.zig
fn getAllToolNames(allocator: std.mem.Allocator) ![]const []const u8 {
    // Import tools module to get tool list
    const tools_module = @import("tools.zig");

    // Get all registered tool definitions
    const all_tools = try tools_module.getAllToolDefinitions(allocator);
    defer {
        for (all_tools) |tool| {
            allocator.free(tool.ollama_tool.function.name);
            allocator.free(tool.ollama_tool.function.description);
            allocator.free(tool.ollama_tool.function.parameters);
        }
        allocator.free(all_tools);
    }

    // Extract just the names
    var names = std.ArrayListUnmanaged([]const u8){};
    defer names.deinit(allocator);

    for (all_tools) |tool| {
        try names.append(allocator, try allocator.dupe(u8, tool.ollama_tool.function.name));
    }

    return names.toOwnedSlice(allocator);
}
