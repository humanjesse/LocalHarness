// Config Editor State - Manages the full-screen configuration UI state
const std = @import("std");
const config_module = @import("config.zig");

/// Represents different types of configuration fields
pub const FieldType = enum {
    /// Radio button (one choice from multiple options)
    radio,
    /// Text input (free-form string)
    text_input,
    /// Toggle (on/off checkbox)
    toggle,
    /// Number input (integer value)
    number_input,
};

/// A single field in the configuration form
pub const ConfigField = struct {
    /// Display label (e.g., "Provider")
    label: []const u8,

    /// Field type (radio, text, toggle, etc.)
    field_type: FieldType,

    /// Field identifier (e.g., "provider")
    key: []const u8,

    /// Help text shown below the field
    help_text: ?[]const u8 = null,

    /// For radio fields: available options
    options: ?[]const []const u8 = null,

    /// For text/number fields: current value being edited
    edit_buffer: ?[]u8 = null,

    /// Whether this field is currently being edited (cursor in text input)
    is_editing: bool = false,
};

/// Configuration sections for logical grouping
pub const ConfigSection = struct {
    /// Section title (e.g., "Provider Settings")
    title: []const u8,

    /// Fields in this section
    fields: []ConfigField,
};

/// Main state for the config editor screen
pub const ConfigEditorState = struct {
    /// Is the config editor currently active?
    active: bool = false,

    /// All sections in the config form
    sections: []ConfigSection,

    /// Currently focused field index (global across all sections)
    focused_field_index: usize = 0,

    /// Working copy of config (user edits this, not the app config)
    temp_config: config_module.Config,

    /// Allocator for managing temporary state
    allocator: std.mem.Allocator,

    /// Has user made any changes?
    has_changes: bool = false,

    /// Scroll position (for when form is taller than screen)
    scroll_y: usize = 0,

    /// Initialize config editor state with current app config
    pub fn init(allocator: std.mem.Allocator, current_config: *const config_module.Config) !ConfigEditorState {
        // Clone the current config into temp_config
        // This way we can edit without affecting the app until "Save" is clicked
        const temp_config = config_module.Config{
            .provider = try allocator.dupe(u8, current_config.provider),
            .ollama_host = try allocator.dupe(u8, current_config.ollama_host),
            .ollama_endpoint = try allocator.dupe(u8, current_config.ollama_endpoint),
            .lmstudio_host = try allocator.dupe(u8, current_config.lmstudio_host),
            .lmstudio_auto_start = current_config.lmstudio_auto_start,
            .lmstudio_auto_load_model = current_config.lmstudio_auto_load_model,
            .lmstudio_gpu_offload = try allocator.dupe(u8, current_config.lmstudio_gpu_offload),
            .lmstudio_ttl = current_config.lmstudio_ttl,
            .model = try allocator.dupe(u8, current_config.model),
            .model_keep_alive = try allocator.dupe(u8, current_config.model_keep_alive),
            .num_ctx = current_config.num_ctx,
            .num_predict = current_config.num_predict,
            .indexing_temperature = current_config.indexing_temperature,
            .indexing_num_predict = current_config.indexing_num_predict,
            .indexing_repeat_penalty = current_config.indexing_repeat_penalty,
            .indexing_max_iterations = current_config.indexing_max_iterations,
            .indexing_enable_thinking = current_config.indexing_enable_thinking,
            .editor = blk: {
                const editor = try allocator.alloc([]const u8, current_config.editor.len);
                for (current_config.editor, 0..) |arg, i| {
                    editor[i] = try allocator.dupe(u8, arg);
                }
                break :blk editor;
            },
            .scroll_lines = current_config.scroll_lines,
            .color_status = try allocator.dupe(u8, current_config.color_status),
            .color_link = try allocator.dupe(u8, current_config.color_link),
            .color_thinking_header = try allocator.dupe(u8, current_config.color_thinking_header),
            .color_thinking_dim = try allocator.dupe(u8, current_config.color_thinking_dim),
            .color_inline_code_bg = try allocator.dupe(u8, current_config.color_inline_code_bg),
            .enable_thinking = current_config.enable_thinking,
            .show_tool_json = current_config.show_tool_json,
            .graph_rag_enabled = current_config.graph_rag_enabled,
            .embedding_model = try allocator.dupe(u8, current_config.embedding_model),
            .indexing_model = try allocator.dupe(u8, current_config.indexing_model),
            .max_chunks_in_history = current_config.max_chunks_in_history,
            .zvdb_path = try allocator.dupe(u8, current_config.zvdb_path),
            .file_read_small_threshold = current_config.file_read_small_threshold,
        };

        // Build the form structure (sections and fields)
        const sections = try buildFormSections(allocator, &temp_config);

        return ConfigEditorState{
            .active = true,
            .sections = sections,
            .focused_field_index = 0,
            .temp_config = temp_config,
            .allocator = allocator,
            .has_changes = false,
            .scroll_y = 0,
        };
    }

    /// Clean up all allocated memory
    pub fn deinit(self: *ConfigEditorState) void {
        // Free temp config
        self.temp_config.deinit(self.allocator);

        // Free sections and fields
        for (self.sections) |section| {
            // Free section title (dynamically allocated in buildProviderSpecificSection)
            self.allocator.free(section.title);

            for (section.fields) |field| {
                if (field.edit_buffer) |buffer| {
                    self.allocator.free(buffer);
                }
                // Free options array (allocated by listIdentifiers, listNames, etc.)
                if (field.options) |options| {
                    self.allocator.free(options);
                }
            }
            self.allocator.free(section.fields);
        }
        self.allocator.free(self.sections);
    }

    /// Get total number of fields across all sections
    pub fn getTotalFieldCount(self: *const ConfigEditorState) usize {
        var count: usize = 0;
        for (self.sections) |section| {
            count += section.fields.len;
        }
        return count;
    }

    /// Get the currently focused field (returns null if out of bounds)
    pub fn getFocusedField(self: *ConfigEditorState) ?*ConfigField {
        var current_index: usize = 0;
        for (self.sections) |*section| {
            for (section.fields) |*field| {
                if (current_index == self.focused_field_index) {
                    return field;
                }
                current_index += 1;
            }
        }
        return null;
    }

    /// Move focus to next field (wraps around)
    pub fn focusNext(self: *ConfigEditorState) void {
        const total = self.getTotalFieldCount();
        if (total > 0) {
            self.focused_field_index = (self.focused_field_index + 1) % total;
        }
    }

    /// Move focus to previous field (wraps around)
    pub fn focusPrevious(self: *ConfigEditorState) void {
        const total = self.getTotalFieldCount();
        if (total > 0) {
            if (self.focused_field_index == 0) {
                self.focused_field_index = total - 1;
            } else {
                self.focused_field_index -= 1;
            }
        }
    }

    /// Rebuild sections (call when provider changes to update provider-specific fields)
    pub fn rebuildSections(self: *ConfigEditorState) !void {
        // Free old sections
        for (self.sections) |section| {
            self.allocator.free(section.title);
            for (section.fields) |field| {
                if (field.edit_buffer) |buffer| {
                    self.allocator.free(buffer);
                }
                if (field.options) |options| {
                    self.allocator.free(options);
                }
            }
            self.allocator.free(section.fields);
        }
        self.allocator.free(self.sections);

        // Rebuild sections with new provider
        self.sections = try buildFormSections(self.allocator, &self.temp_config);

        // Reset focused field to top
        self.focused_field_index = 0;
    }
};

/// Build the form structure from config
fn buildFormSections(allocator: std.mem.Allocator, temp_config: *const config_module.Config) ![]ConfigSection {
    var sections = std.ArrayListUnmanaged(ConfigSection){};
    errdefer {
        // Clean up any partially built sections on error
        for (sections.items) |section| {
            allocator.free(section.title);
            for (section.fields) |field| {
                if (field.edit_buffer) |buffer| {
                    allocator.free(buffer);
                }
                if (field.options) |options| {
                    allocator.free(options);
                }
            }
            allocator.free(section.fields);
        }
        sections.deinit(allocator);
    }

    // Section 1: Provider Selection
    {
        var fields = std.ArrayListUnmanaged(ConfigField){};

        // Provider selection (radio buttons) - dynamically populated from registry
        const llm_provider = @import("llm_provider.zig");
        const provider_identifiers = try llm_provider.ProviderRegistry.listIdentifiers(allocator);
        try fields.append(allocator, .{
            .label = "Provider",
            .field_type = .radio,
            .key = "provider",
            .help_text = "Select your LLM backend",
            .options = provider_identifiers,
        });

        // Model (text input) - shared across all providers
        try fields.append(allocator, .{
            .label = "Default Model",
            .field_type = .text_input,
            .key = "model",
            .help_text = "Model name to use by default",
        });

        // Embedding Model (text input) - for GraphRAG vector search
        try fields.append(allocator, .{
            .label = "Embedding Model",
            .field_type = .text_input,
            .key = "embedding_model",
            .help_text = "Ollama: 'nomic-embed-text' | LM Studio: 'text-embedding-nomic-embed-text-v1.5' (must be loaded first!)",
        });

        // Indexing Model (text input) - for LLM-based file analysis
        try fields.append(allocator, .{
            .label = "Indexing Model",
            .field_type = .text_input,
            .key = "indexing_model",
            .help_text = "Model for analyzing files during GraphRAG indexing",
        });

        try sections.append(allocator, .{
            .title = try allocator.dupe(u8, "Provider Selection"),
            .fields = try fields.toOwnedSlice(allocator),
        });
    }

    // Section 2: Provider-Specific Settings (dynamically built)
    {
        const provider_section = try buildProviderSpecificSection(allocator, temp_config);
        try sections.append(allocator, provider_section);
    }

    // Section 3: Features
    {
        var fields = std.ArrayListUnmanaged(ConfigField){};

        try fields.append(allocator, .{
            .label = "Extended Thinking",
            .field_type = .toggle,
            .key = "enable_thinking",
            .help_text = "Enable AI reasoning visibility (Ollama only)",
        });

        try fields.append(allocator, .{
            .label = "Graph RAG",
            .field_type = .toggle,
            .key = "graph_rag_enabled",
            .help_text = "Enable code context compression",
        });

        try fields.append(allocator, .{
            .label = "Show Tool JSON",
            .field_type = .toggle,
            .key = "show_tool_json",
            .help_text = "Display raw tool call JSON",
        });

        try fields.append(allocator, .{
            .label = "GraphRAG Indexing Thinking",
            .field_type = .toggle,
            .key = "indexing_enable_thinking",
            .help_text = "Enable thinking mode during file indexing (both Ollama and LM Studio)",
        });

        try sections.append(allocator, .{
            .title = try allocator.dupe(u8, "Features"),
            .fields = try fields.toOwnedSlice(allocator),
        });
    }

    // Section 4: Advanced Settings
    {
        var fields = std.ArrayListUnmanaged(ConfigField){};

        try fields.append(allocator, .{
            .label = "Context Window",
            .field_type = .number_input,
            .key = "num_ctx",
            .help_text = "Token limit for context (default: 128000)",
        });

        try fields.append(allocator, .{
            .label = "Max Tokens to Generate",
            .field_type = .number_input,
            .key = "num_predict",
            .help_text = "Maximum response length (default: 8192)",
        });

        try fields.append(allocator, .{
            .label = "GraphRAG Indexing Temperature",
            .field_type = .text_input,
            .key = "indexing_temperature",
            .help_text = "Temperature for entity extraction (null=default, 0.1=focused, 0.5=balanced)",
        });

        try fields.append(allocator, .{
            .label = "GraphRAG Max Tokens",
            .field_type = .text_input,
            .key = "indexing_num_predict",
            .help_text = "Max tokens for indexing (null=use main config, default: 10240)",
        });

        try fields.append(allocator, .{
            .label = "GraphRAG Repeat Penalty",
            .field_type = .text_input,
            .key = "indexing_repeat_penalty",
            .help_text = "Penalize repetition in indexing (null=default, 1.3=reduce verbosity)",
        });

        try fields.append(allocator, .{
            .label = "GraphRAG Max Iterations",
            .field_type = .number_input,
            .key = "indexing_max_iterations",
            .help_text = "Max analysis passes for indexing (default: 20, increase for models generating 1 tool call at a time)",
        });

        try sections.append(allocator, .{
            .title = try allocator.dupe(u8, "Advanced Settings"),
            .fields = try fields.toOwnedSlice(allocator),
        });
    }

    return sections.toOwnedSlice(allocator);
}

/// Build provider-specific section dynamically from registry
fn buildProviderSpecificSection(allocator: std.mem.Allocator, temp_config: *const config_module.Config) !ConfigSection {
    const llm_provider = @import("llm_provider.zig");

    // Get capabilities for the selected provider
    const caps = llm_provider.ProviderRegistry.get(temp_config.provider) orelse {
        // If provider not found, return empty section
        return ConfigSection{
            .title = "Provider Settings",
            .fields = &[_]ConfigField{},
        };
    };

    var fields = std.ArrayListUnmanaged(ConfigField){};

    // Build fields from registry config_fields
    for (caps.config_fields) |field_def| {
        // Map registry FieldType to config editor FieldType
        const field_type: FieldType = switch (field_def.field_type) {
            .text_input => .text_input,
            .toggle => .toggle,
            .number_input => .number_input,
        };

        try fields.append(allocator, .{
            .label = field_def.label,
            .field_type = field_type,
            .key = field_def.key,
            .help_text = field_def.help_text,
        });
    }

    // Create section title with provider name
    const section_title = try std.fmt.allocPrint(allocator, "{s} Settings", .{caps.name});

    return ConfigSection{
        .title = section_title,
        .fields = try fields.toOwnedSlice(allocator),
    };
}
