# Commands Reference

Quick reference for all Local Harness commands and keyboard shortcuts.

---

## Chat Commands

### `/help` - Help Viewer

Display comprehensive help documentation in a full-screen modal viewer.

**Usage:** Type `/help` and press Enter

**Content:**
- Slash commands reference
- Keyboard shortcuts
- Basic usage instructions
- Links to detailed documentation

**Navigation:**
- `↑` / `↓` - Scroll content (3 lines)
- `PgUp` / `PgDn` - Scroll faster (10 lines)
- `Home` / `End` - Jump to top/bottom
- `j` / `k` - Vim-style scrolling
- `q` / `Esc` / `Ctrl+C` - Close help viewer

**Tip:** The help viewer is read-only and provides a quick reference without leaving the application. For more detailed documentation, see the docs/ folder.

---

### `/config` - Configuration Editor

Open full-screen interactive configuration editor.

**Usage:** Type `/config` and press Enter

**Navigation:**
- `Tab` / `Shift+Tab` - Next/previous field
- `↑` / `↓` - Navigate fields
- `Enter` - Edit/toggle current field
- `Space` - Toggle checkboxes
- `←` / `→` - Cycle radio buttons

**Actions:**
- `Ctrl+S` - Save changes and close
- `Esc` - Cancel and discard changes

**See:** [Configuration Guide](configuration.md#interactive-config-editor) | [Features](features.md#interactive-configuration-editor)

---

### `/toggle-toolcall-json` - Tool JSON Display

Toggle visibility of raw tool call JSON.

**Usage:** Type `/toggle-toolcall-json` and press Enter

When enabled, shows the JSON passed to each tool:
```json
{
  "path": "/home/user/file.txt",
  "line_start": 1,
  "line_end": 100
}
```

Useful for:
- Debugging tool calls
- Understanding tool parameters
- Learning tool schemas

**Config equivalent:** `show_tool_json: true` in config file

---

### `/quit` - Exit Application

Exit Local Harness gracefully.

**Usage:** Type `/quit` or press `Ctrl+D`

**Note:** Unsaved chat history will be lost. The app does not persist conversation history between sessions.

---

## Tool Permissions

When a tool is requested by the AI, you'll see a permission prompt:

```
╔══════════════════════════════════════╗
║ Tool Permission Request              ║
╠══════════════════════════════════════╣
║ Tool: read_file                      ║
║ Path: /home/user/project/main.zig    ║
╚══════════════════════════════════════╝

[a] Allow once  [A] Allow always  [d] Deny once  [D] Deny always
```

### Permission Options

| Key | Action | Effect | Persists? |
|-----|--------|--------|-----------|
| `a` | Allow once | Run this tool call only | No |
| `A` | Allow always | Auto-approve this tool + path pattern | Yes |
| `d` | Deny once | Skip this tool call | No |
| `D` | Deny always | Auto-deny this tool + path pattern | Yes |

**Path Patterns:**
- Exact match: `/home/user/file.txt`
- Directory: `/home/user/project/*`
- Wildcard: `*.zig`

**Policies persist** in `~/.config/localharness/policies.json`

**Reset permissions:**
```bash
rm ~/.config/localharness/policies.json
```

---

## Keyboard Shortcuts

### During Chat

| Shortcut | Action |
|----------|--------|
| `Enter` | Send message |
| `Ctrl+C` | Cancel current AI response |
| `Ctrl+D` | Exit (same as `/quit`) |
| `Escape` | Clear input buffer |
| `↑` / `↓` | Scroll messages (3 lines) |
| `PgUp` / `PgDn` | Scroll faster |
| `Ctrl+O` | Toggle thinking block at cursor |
| Mouse Wheel | Scroll messages |

### In Config Editor

See [/config](#config---configuration-editor) command above.

---

## Command-Line Arguments

Override config file settings when launching Local Harness:

```bash
# Use different model
localharness --model llama3.2:70b

# Connect to remote Ollama server
localharness --ollama-host http://192.168.1.100:11434

# Combine multiple options
localharness --model qwen2.5:14b --ollama-host http://localhost:11434
```

### Available Flags

| Flag | Type | Example | Description |
|------|------|---------|-------------|
| `--model` | string | `qwen3-coder:30b` | Override model name |
| `--ollama-host` | string | `http://localhost:11434` | Override Ollama server URL |
| `--help` | - | - | Show help message |

**Note:** CLI arguments override config file settings for that session only. They don't modify the config file.

---

## Tips & Tricks

### Quick Config Edit

```bash
# Open config in your editor
$EDITOR ~/.config/localharness/config.json

# Or use visual editor
./localharness
# Then type: /config
```

### Check Server Status

**Ollama:**
```bash
# List available models
curl http://localhost:11434/api/tags

# Check if server is running
curl http://localhost:11434/api/version
```

**LM Studio:**
```bash
# List loaded models
curl http://localhost:1234/v1/models

# Check server status
curl http://localhost:1234/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"test","messages":[],"stream":false}'
```

### View Logs

```bash
# Redirect stderr to file
localharness 2> debug.log

# View in real-time
localharness 2>&1 | tee localharness.log
```

### Reset Configuration

```bash
# Delete config file to regenerate defaults
rm ~/.config/localharness/config.json
./localharness  # Will create new default config
```

### Switch Between Configs

```bash
# Development config
XDG_CONFIG_HOME=~/.config-dev ./localharness

# Production config
XDG_CONFIG_HOME=~/.config-prod ./localharness
```

---

## Common Tasks

### Change Model

**Method 1: Config Editor**
1. Type `/config`
2. Navigate to "Default Model"
3. Press `Enter`, edit value
4. Press `Ctrl+S`

**Method 2: CLI**
```bash
localharness --model llama3.2:70b
```

**Method 3: Edit Config**
```bash
$EDITOR ~/.config/localharness/config.json
# Change "model" field
```

### Switch from Ollama to LM Studio

**Method 1: Config Editor** (Recommended)
1. Type `/config`
2. Navigate to "Provider"
3. Press `→` to cycle to "lmstudio"
4. Update "LM Studio Host" if needed
5. Press `Ctrl+S`

**Method 2: Edit Config**
```json
{
  "provider": "lmstudio",
  "lmstudio_host": "http://localhost:1234",
  "model": "qwen2.5-coder-7b"
}
```

### Configure Settings

**Method 1: Config Editor (Recommended)**
1. Type `/config`
2. Navigate to desired setting
3. Press `Enter` to edit or `Space` to toggle
4. Press `Ctrl+S` to save

**Method 2: Edit Config**
```json
{
  "enable_thinking": true,
  "show_tool_json": false,
  "num_ctx": 128000
}
```

---

## See Also

- [Features Guide](features.md) - Complete feature list
- [Configuration Guide](configuration.md) - Detailed config options
- [Installation](installation.md) - Setup instructions
- [Architecture Docs](../architecture/) - Technical details
