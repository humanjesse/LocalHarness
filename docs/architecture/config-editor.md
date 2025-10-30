# Config Editor Architecture

A full-screen TUI configuration editor with clean three-layer architecture, similar to professional terminal applications like `htop`, `ranger`, and `vim`.

## Quick Start

### What Is It?

An interactive visual editor for Local Harness's configuration that lets users modify settings without editing JSON files directly.

### Files

| File | Purpose | Lines |
|------|---------|-------|
| `config_editor_state.zig` | State management and data structures | ~350 |
| `config_editor_renderer.zig` | Drawing to terminal (ANSI codes, layout) | ~250 |
| `config_editor_input.zig` | Input handling and state mutations | ~300 |

### How to Trigger

User types `/config` in Local Harness → full-screen editor opens → modal mode (editor owns screen and input).

### Integration (3 Steps)

**1. Add to App struct:**
```zig
pub const App = struct {
    config_editor: ?config_editor_state.ConfigEditorState = null,
};
```

**2. Add command handler (in `ui.zig`):**
```zig
if (mem.eql(u8, app.input_buffer.items, "/config")) {
    app.config_editor = try config_editor_state.ConfigEditorState.init(
        app.allocator,
        &app.config,
    );
    app.input_buffer.clearRetainingCapacity();
    should_redraw.* = true;
    return false;
}
```

**3. Wire into main loop (in `app.zig`):**
```zig
pub fn run(self: *App, app_tui: *ui.Tui) !void {
    while (true) {
        // Check if config editor is active
        if (self.config_editor) |*editor| {
            // Render
            var stdout_buffer: [8192]u8 = undefined;
            var buffered_writer = ui.BufferedStdoutWriter.init(&stdout_buffer);
            const writer = buffered_writer.writer();
            try config_editor_renderer.render(
                editor, writer,
                self.terminal_size.width,
                self.terminal_size.height,
            );
            try buffered_writer.flush();

            // Handle input
            var read_buffer: [128]u8 = undefined;
            const bytes_read = ui.c.read(ui.c.STDIN_FILENO, &read_buffer, 128);
            if (bytes_read > 0) {
                const input = read_buffer[0..@intCast(bytes_read)];
                const result = try config_editor_input.handleInput(editor, input);

                switch (result) {
                    .save_and_close => {
                        // Apply changes
                        self.config.deinit(self.allocator);
                        self.config = editor.temp_config;
                        // Save to disk (implement saveConfigToFile)
                        // Recreate provider with new config
                        self.llm_provider.deinit();
                        self.llm_provider = try llm_provider.createProvider(
                            self.config.provider,
                            self.allocator,
                            self.config,
                        );
                        editor.deinit();
                        self.config_editor = null;
                    },
                    .cancel => {
                        editor.deinit();
                        self.config_editor = null;
                    },
                    .redraw, .continue => {},
                }
            }
            continue; // Skip normal app logic
        }

        // Normal app mode
        // ... existing code ...
    }
}
```

---

## Architecture

### The Three-Layer Pattern

```
┌──────────────────────────────────────────────────────────┐
│  1. STATE LAYER (config_editor_state.zig)               │
│  "What data are we tracking?"                           │
│                                                          │
│  - ConfigEditorState: Overall editor state              │
│  - ConfigSection: Grouped fields (Provider, Features)   │
│  - ConfigField: Individual setting (radio/toggle/text)  │
│  - temp_config: Working copy of configuration           │
└───────────────────────┬──────────────────────────────────┘
                        │ reads state
                        ↓
┌──────────────────────────────────────────────────────────┐
│  2. RENDERING LAYER (config_editor_renderer.zig)        │
│  "How do we draw the current state?"                    │
│                                                          │
│  - render(): Main entry point                           │
│  - drawField(): Render individual fields                │
│  - drawRadio/Toggle/TextInput(): Type-specific drawing  │
│  - Uses ANSI escape codes for formatting               │
└───────────────────────┬──────────────────────────────────┘
                        │ updates state
                        ↑
┌──────────────────────────────────────────────────────────┐
│  3. INPUT LAYER (config_editor_input.zig)               │
│  "How do we react to keypresses?"                       │
│                                                          │
│  - handleInput(): Process raw input bytes               │
│  - handleSingleKey(): Process normal keys               │
│  - handleEscapeSequence(): Process arrow keys           │
│  - Returns InputResult (.redraw, .save_and_close, etc.) │
└──────────────────────────────────────────────────────────┘
```

### Key Principles

**1. Separation of Concerns**
- State layer: Pure data, no rendering or input logic
- Renderer: Reads state, never modifies it
- Input handler: Modifies state, doesn't render

**2. Unidirectional Data Flow**
```
Input → State Change → Re-render
```

**3. Modal Editing**
- Config editor "takes over" the screen when active
- Normal app logic suspended during editing
- Clean separation prevents conflicts

**4. Edit-Commit Pattern**
- Work on `temp_config` (copy of app config)
- Changes don't apply until Ctrl+S
- Esc discards all changes safely

### State Layer Details

**ConfigEditorState** - Main state container:
```zig
pub const ConfigEditorState = struct {
    active: bool,
    sections: []ConfigSection,          // Form structure
    focused_field_index: usize,         // Which field has focus
    temp_config: config.Config,         // Working copy
    allocator: std.mem.Allocator,
    has_changes: bool,                  // Unsaved changes?
    scroll_y: usize,                    // For future scrolling
};
```

**ConfigField** - Individual setting:
```zig
pub const ConfigField = struct {
    label: []const u8,                  // "Provider"
    field_type: FieldType,              // radio, toggle, text_input, number_input
    key: []const u8,                    // "provider" (for lookup)
    help_text: ?[]const u8,             // Shown below field
    options: ?[]const []const u8,       // For radio buttons
    edit_buffer: ?[]u8,                 // For text editing
    is_editing: bool,                   // Currently editing?
};
```

**FieldType** - Supported field types:
- `radio` - One choice from multiple (e.g., provider selection)
- `toggle` - Boolean on/off (e.g., enable_thinking)
- `text_input` - Free-form text (e.g., host URL)
- `number_input` - Integer value (e.g., num_ctx)

### Renderer Layer Details

**Visual Layout:**
```
┌───────────────────────────────────────────────────────────┐
│              Configuration Editor                         │  ← Title
│  Press Tab to navigate, Enter to edit, Ctrl+S to save    │  ← Instructions
│                                                           │
│  Provider Settings                                        │  ← Section header
│  ┌─────────────────────────────────────────────────────┐ │
│  │ Provider: [●] ollama  [ ] lmstudio                  │ │  ← Radio field
│  │ Select your LLM backend                             │ │  ← Help text
│  │                                                     │ │
│  │ Ollama Host: http://localhost:11434                │ │  ← Text field
│  │ HTTP endpoint for Ollama server                    │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                           │
│  [Ctrl+S] Save  [Esc] Cancel                             │  ← Footer
│  ● Unsaved changes                                        │  ← Indicator
└───────────────────────────────────────────────────────────┘
```

**ANSI Formatting:**
- Section headers: `\x1b[1;36m` (cyan bold)
- Focused field: `\x1b[7m` (reverse video)
- Help text: `\x1b[2m` (dim)
- Warning: `\x1b[33m` (yellow)
- Reset: `\x1b[0m`

**Field Rendering:**
- Radio: `[●] selected  [ ] unselected`
- Toggle: `[✓] ON` or `[ ] OFF`
- Text input (editing): `value█` (cursor shown)
- Text input (not editing): `value`

### Input Layer Details

**Keybindings:**

| Key | Action |
|-----|--------|
| `Tab` | Move to next field |
| `Shift+Tab` | Move to previous field |
| `↑` / `↓` | Navigate fields |
| `Enter` | Toggle / Start editing / Commit edit |
| `Space` | Toggle checkbox |
| `←` / `→` | Cycle radio button |
| `Ctrl+S` | Save changes and close |
| `Esc` | Cancel and close (discard changes) |

**Input Processing Flow:**
```
Raw bytes → handleInput()
    ↓
Is escape sequence? (\x1b[...)
    Yes → handleEscapeSequence() (arrows)
    No → handleSingleKey() (normal keys)
    ↓
Modify state (focus change, toggle, text edit)
    ↓
Return InputResult
    - .continue: Do nothing
    - .redraw: Re-render next frame
    - .save_and_close: Apply changes
    - .cancel: Discard changes
```

---

## Integration Guide

### Prerequisites

You need these imports in your files:

```zig
const config_editor_state = @import("config_editor_state.zig");
const config_editor_renderer = @import("config_editor_renderer.zig");
const config_editor_input = @import("config_editor_input.zig");
```

### Complete Integration Example

See "Quick Start" section above for the 3-step integration. Here's the complete flow:

**User Flow:**
1. User types `/config` → Command handler activates editor
2. Main loop detects `app.config_editor != null` → Enters modal mode
3. Editor renders → User navigates/edits → Input updates state
4. User presses Ctrl+S → Changes applied → Editor closed
5. Main loop continues → Normal app mode resumes

**State Transitions:**
```
Normal Mode → (user types /config) → Modal Mode
    ↓                                      ↓
App owns screen                    Editor owns screen
App handles input                  Editor handles input
    ↑                                      ↓
Normal Mode ← (save/cancel) ← Modal Mode
```

---

## Adding Fields

### 4-Step Process

**Example:** Add a "dark_mode" boolean setting

**Step 1: Config struct** (`config.zig`)
```zig
pub const Config = struct {
    dark_mode: bool = false,
    // ... other fields ...
};
```

**Step 2: Form builder** (`config_editor_state.zig` in `buildFormSections()`)
```zig
// In appropriate section (e.g., "Features"):
try fields.append(allocator, .{
    .label = "Dark Mode",
    .field_type = .toggle,
    .key = "dark_mode",
    .help_text = "Use dark color scheme",
});
```

**Step 3: Input handler** (`config_editor_input.zig`)
```zig
// In toggleField():
fn toggleField(state: *ConfigEditorState, field: *ConfigField) !void {
    const config = &state.temp_config;
    // ... existing toggles ...
    if (std.mem.eql(u8, field.key, "dark_mode")) {
        config.dark_mode = !config.dark_mode;
    }
}
```

**Step 4: Renderer** (`config_editor_renderer.zig`)
```zig
// In getFieldBoolValue():
fn getFieldBoolValue(state: *const ConfigEditorState, key: []const u8) bool {
    const config = &state.temp_config;
    // ... existing fields ...
    if (std.mem.eql(u8, key, "dark_mode")) return config.dark_mode;
    return false;
}
```

Done! The field will appear in the config editor.

### Field Type Examples

**Boolean (Toggle):**
```zig
.field_type = .toggle,
.key = "my_bool_setting",
```

**Text Input:**
```zig
.field_type = .text_input,
.key = "my_text_setting",
```

**Number Input:**
```zig
.field_type = .number_input,
.key = "my_number_setting",
```

**Radio (Multiple Choice):**
```zig
.field_type = .radio,
.key = "my_choice",
.options = &[_][]const u8{ "option1", "option2", "option3" },
```

---

## Advanced Topics

### Field Validation

Validate input before committing:

```zig
// In config_editor_input.zig commitTextEdit():
fn commitTextEdit(state: *ConfigEditorState, field: *ConfigField) !void {
    if (field.edit_buffer) |buffer| {
        // Validate URLs
        if (std.mem.eql(u8, field.key, "ollama_host") or
            std.mem.eql(u8, field.key, "lmstudio_host")) {
            if (!std.mem.startsWith(u8, buffer, "http://") and
                !std.mem.startsWith(u8, buffer, "https://")) {
                // Could show error message in UI
                return error.InvalidURL;
            }
        }

        try setTextValue(state, field.key, buffer);
    }
}
```

### Conditional Fields

Hide fields based on other settings:

```zig
// In config_editor_renderer.zig drawField():
// Skip LM Studio host if provider is Ollama
if (std.mem.eql(u8, field.key, "lmstudio_host")) {
    const provider = state.temp_config.provider;
    if (!std.mem.eql(u8, provider, "lmstudio")) {
        return; // Don't render this field
    }
}
```

### Dynamic Warnings

Show provider-specific warnings:

```zig
// In config_editor_renderer.zig:
fn drawProviderWarnings(writer: anytype, state: *const ConfigEditorState, ...) !void {
    const llm_provider = @import("llm_provider.zig");
    const caps = llm_provider.ProviderRegistry.get(state.temp_config.provider) orelse return;

    // Display all warnings for this provider
    for (caps.config_warnings) |warning| {
        try writer.print("\x1b[33m⚠ Note: {s}\x1b[0m", .{warning.message});
    }
}
```

### Common Pitfalls

**❌ Don't: Renderer modifying state**
```zig
fn drawField(field: *ConfigField) {
    field.is_focused = true; // BAD: Renderer shouldn't change state
}
```

**✅ Do: Pass focus as parameter**
```zig
fn drawField(field: *const ConfigField, is_focused: bool) {
    if (is_focused) { /* highlight */ }
}
```

**❌ Don't: Input handler doing rendering**
```zig
fn handleKey(...) {
    state.focused_index += 1;
    try writer.writeAll("\x1b[2J"); // BAD: Input shouldn't render
}
```

**✅ Do: Return result, let main loop render**
```zig
fn handleKey(...) !InputResult {
    state.focused_index += 1;
    return .redraw; // GOOD: Signal that redraw is needed
}
```

**❌ Don't: Modify app.config directly**
```zig
app.config.provider = "lmstudio"; // BAD: Can't cancel changes
```

**✅ Do: Work on temp_config**
```zig
editor.temp_config.provider = "lmstudio"; // GOOD: Can cancel
// ... user presses Ctrl+S ...
app.config = editor.temp_config; // Commit
```

---

## Reference

### Result Enums

**InputResult:**
```zig
pub const InputResult = enum {
    continue,        // Do nothing
    redraw,          // Re-render next frame
    save_and_close,  // Apply changes and close
    cancel,          // Discard changes and close
};
```

### Memory Management

**Initialization:**
```zig
// ConfigEditorState.init() allocates:
// - Sections array
// - Fields arrays
// - temp_config (cloned from app config)
// - Edit buffers (on-demand during editing)
```

**Cleanup:**
```zig
// ConfigEditorState.deinit() frees:
// - temp_config (including all strings)
// - Edit buffers
// - Options arrays (from listIdentifiers, etc.)
// - Fields arrays
// - Sections array
```

**Important:** Always call `deinit()` when closing editor, whether saving or canceling.

---

## Benefits of This Architecture

1. **Maintainable** - Each layer has one job, easy to modify
2. **Testable** - Layers can be tested independently
3. **Extensible** - Adding fields takes ~5 minutes
4. **Safe** - Edit-commit pattern prevents accidental changes
5. **Professional** - Follows patterns from established TUI apps
6. **Educational** - Demonstrates clean architecture principles

---

## See Also

- [Config Editor Data Flow](./config-editor-flow.md) - Detailed walkthrough examples
- [Configuration Guide](../user-guide/configuration.md) - User-facing documentation
- [Features Guide](../user-guide/features.md) - List of all features
