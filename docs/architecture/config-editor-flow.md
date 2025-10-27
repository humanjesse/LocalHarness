# Config Editor: Data Flow Examples

> **Note:** For architecture overview and integration guide, see [config-editor.md](./config-editor.md)

This document provides detailed walkthroughs showing exactly how data flows through the config editor's three layers.

---

## Example 1: Navigation (Tab Key)

**Scenario:** User presses Tab to move focus to the next field

Let's trace the complete data flow:

```
┌─────────────────────────────────────────────────────────────┐
│ USER ACTION: User presses Tab to focus "Provider" field    │
└────────────────────┬────────────────────────────────────────┘
                     │
                     ↓
┌─────────────────────────────────────────────────────────────┐
│ INPUT LAYER: ui.zig handleInput() receives '\t' (Tab)      │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ if (app.config_editor) |*editor| {                      │ │
│ │     const result = try config_editor_input.handleInput( │ │
│ │         editor,                                         │ │
│ │         input  // "\t"                                  │ │
│ │     );                                                  │ │
│ │ }                                                       │ │
│ └─────────────────────────────────────────────────────────┘ │
└────────────────────┬────────────────────────────────────────┘
                     │
                     ↓
┌─────────────────────────────────────────────────────────────┐
│ INPUT HANDLER: config_editor_input.zig                     │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ fn handleSingleKey(state, '\t') {                       │ │
│ │     '\t' => {                                           │ │
│ │         state.focusNext();  // STATE CHANGE!           │ │
│ │         return .redraw;                                 │ │
│ │     }                                                   │ │
│ │ }                                                       │ │
│ └─────────────────────────────────────────────────────────┘ │
└────────────────────┬────────────────────────────────────────┘
                     │
                     ↓
┌─────────────────────────────────────────────────────────────┐
│ STATE LAYER: config_editor_state.zig                       │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ pub fn focusNext(self: *ConfigEditorState) {            │ │
│ │     self.focused_field_index = (self.focused_field_index│ │
│ │                                   + 1) % total_fields;  │ │
│ │ }                                                       │ │
│ │                                                         │ │
│ │ // Before: focused_field_index = 0 (Provider field)    │ │
│ │ // After:  focused_field_index = 1 (Ollama Host field) │ │
│ └─────────────────────────────────────────────────────────┘ │
└────────────────────┬────────────────────────────────────────┘
                     │
                     │ Return .redraw to app loop
                     ↓
┌─────────────────────────────────────────────────────────────┐
│ APP LOOP: app.zig run()                                    │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ switch (result) {                                       │ │
│ │     .redraw => {                                        │ │
│ │         // Loop continues, will re-render on next iter │ │
│ │     }                                                   │ │
│ │ }                                                       │ │
│ └─────────────────────────────────────────────────────────┘ │
└────────────────────┬────────────────────────────────────────┘
                     │
                     │ Next loop iteration
                     ↓
┌─────────────────────────────────────────────────────────────┐
│ RENDERER: config_editor_renderer.zig                       │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ pub fn render(state, writer, width, height) {           │ │
│ │     for (sections) |section| {                          │ │
│ │         for (fields, index) |field| {                   │ │
│ │             const is_focused = (index ==                │ │
│ │                 state.focused_field_index);             │ │
│ │             // Now index 1 (Ollama Host) is focused    │ │
│ │                                                         │ │
│ │             if (is_focused) {                           │ │
│ │                 try writer.writeAll("\x1b[7m"); // ←──┐│ │
│ │             }                                           ││ │
│ │             // Draw field...                           ││ │
│ │         }                                               ││ │
│ │     }                                                   ││ │
│ │ }                                                       ││ │
│ └─────────────────────────────────────────────────────────┘│ │
└────────────────────┬────────────────────────────────────────┘
                     │                                  Highlight
                     ↓                                  applied
┌─────────────────────────────────────────────────────────────┐
│ TERMINAL: Screen now shows Ollama Host highlighted         │
│                                                             │
│  Provider Settings                                          │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Provider: [●] ollama  [ ] lmstudio                  │   │
│  │                                                     │   │
│  │ [Ollama Host: http://localhost:11434]  ← HIGHLIGHTED│   │
│  │ HTTP endpoint for Ollama server                    │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## 🎯 Now Let's Change the Provider Value

User presses **Enter** to cycle the radio button:

```
USER: Presses Enter
  ↓
INPUT HANDLER: Detects Enter key on radio field
  ↓
  fn handleEnterKey(state) {
      if (field.field_type == .radio) {
          try cycleRadioForward(state, field);
          //         ↓
          //    This calls setRadioValue()
          //         ↓
          //    Updates state.temp_config.provider from "ollama" to "lmstudio"
      }
  }
  ↓
Returns .redraw
  ↓
RENDERER: Reads new temp_config.provider value
  ↓
  fn drawRadioField(writer, field, state) {
      const current = state.temp_config.provider; // Now "lmstudio"

      for (options) |option| {
          if (std.mem.eql(u8, current, option)) {
              try writer.print("[●] {s}", .{option}); // Mark as selected
          } else {
              try writer.print("[ ] {s}", .{option});
          }
      }
  }
  ↓
TERMINAL: Shows updated selection

  Provider: [ ] ollama  [●] lmstudio  ← Changed!
```

---

## 💾 Saving Changes

When user presses **Ctrl+S**:

```
USER: Presses Ctrl+S (0x13)
  ↓
INPUT HANDLER: Detects save key
  ↓
  fn handleSingleKey(state, 0x13) {
      0x13 => return .save_and_close;
  }
  ↓
APP LOOP: Receives .save_and_close
  ↓
  switch (result) {
      .save_and_close => {
          // Step 1: Free old app.config
          self.config.deinit(self.allocator);

          // Step 2: Move temp_config to app.config
          self.config = editor.temp_config;

          // Step 3: Save to disk
          try saveConfigToFile(self.allocator, &self.config);

          // Step 4: Clean up editor (but NOT temp_config, we moved it!)
          self.allocator.free(editor.sections);
          self.allocator.destroy(editor);
          self.config_editor = null;

          // Step 5: Restart provider with new config
          self.llm_provider.deinit();
          self.llm_provider = try llm_provider.createProvider(
              self.config.provider,
              self.allocator,
              self.config
          );
      }
  }
  ↓
NORMAL APP MODE: Config editor closed, changes applied!
```

---

## 🧩 Understanding the "Temp Config" Pattern

**Why do we have both `app.config` and `editor.temp_config`?**

### Without temp_config (❌ Bad):

```zig
// User opens editor
// User changes provider to "lmstudio"
app.config.provider = "lmstudio"; // OOPS! Change happens immediately!

// App now thinks it should use LM Studio, but user hasn't saved yet
// If they press Esc to cancel, the change is already applied!

// Also: LLM provider is now out of sync with config
```

### With temp_config (✅ Good):

```zig
// User opens editor
editor.temp_config = clone(app.config); // Make a copy

// User changes provider to "lmstudio"
editor.temp_config.provider = "lmstudio"; // Only temp is changed

// app.config still says "ollama" - app continues working normally!

// If user presses Esc:
editor.deinit(); // Throws away temp_config, app.config unchanged

// If user presses Ctrl+S:
app.config = editor.temp_config; // Now we commit the changes
try saveConfigToFile(...); // Persist to disk
```

**This is called the "Edit-Commit" pattern** - common in database transactions and GUI forms.

---

## 🎨 Rendering Example: How Focus Highlighting Works

```zig
// Simplified version of the renderer

pub fn render(state: *ConfigEditorState, writer: anytype) !void {
    var global_field_index: usize = 0;

    for (state.sections) |section| {
        for (section.fields) |field| {
            // Check if THIS field is focused
            const is_focused = (global_field_index == state.focused_field_index);

            // Draw field with focus state
            if (is_focused) {
                try writer.writeAll("\x1b[7m"); // Reverse video (highlight)
            }

            try writer.print("{s}: ", .{field.label});

            // Draw value based on field type
            switch (field.field_type) {
                .radio => try drawRadio(writer, field, state),
                .toggle => try drawToggle(writer, field, state),
                // ... etc
            }

            if (is_focused) {
                try writer.writeAll("\x1b[0m"); // Reset formatting
            }

            global_field_index += 1; // Move to next field
        }
    }
}
```

**Key insight**: The renderer doesn't track focus itself - it asks the state "which field is focused?" and highlights accordingly.

---

## 📐 State Machine Diagram

```
┌─────────────────────────────────────────────────────────┐
│                    NORMAL APP MODE                      │
│  (Chat interface, tool execution, etc.)                 │
└────────────────────┬────────────────────────────────────┘
                     │
                     │ User types "/config" + Enter
                     ↓
┌─────────────────────────────────────────────────────────┐
│               CONFIG EDITOR MODE                        │
│  ┌─────────────────────────────────────────────────┐   │
│  │  State: NAVIGATING                              │   │
│  │  - Tab/Shift+Tab moves focus                    │   │
│  │  - Arrow keys move focus                        │   │
│  │  - Enter activates field                        │   │
│  └───────────┬─────────────────────┬─────────────────┘  │
│              │                     │                    │
│      Press Enter on             Press Ctrl+S           │
│      text field                                        │
│              ↓                     ↓                    │
│  ┌─────────────────────┐   ┌──────────────────┐       │
│  │ State: EDITING      │   │ Save & Close     │───┐   │
│  │ - Type characters   │   └──────────────────┘   │   │
│  │ - Backspace deletes │                          │   │
│  │ - Enter commits     │                          │   │
│  └───────────┬─────────┘                          │   │
│              │                                     │   │
│      Press Enter                                   │   │
│      (commit)                                      │   │
│              ↓                                     │   │
│  ┌─────────────────────┐                          │   │
│  │ Back to NAVIGATING  │                          │   │
│  └─────────────────────┘                          │   │
│                                                    │   │
│  ┌──────────────────┐                             │   │
│  │ Press Esc        │                             │   │
│  │ (Cancel, discard)│─────────────────────────────┘   │
│  └──────────────────┘                                 │
└────────────────────┬───────────────────────────────────┘
                     │
                     ↓
┌─────────────────────────────────────────────────────────┐
│              BACK TO NORMAL APP MODE                    │
│  (Changes applied if saved, discarded if canceled)      │
└─────────────────────────────────────────────────────────┘
```

---

## Summary

These examples demonstrate the three core patterns:

1. **Unidirectional data flow**: Input → State → Render
2. **Separation of concerns**: Each layer has one job
3. **Edit-commit pattern**: Work on copies, commit intentionally

For implementation details and integration instructions, see [config-editor.md](./config-editor.md).
