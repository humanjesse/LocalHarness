# Configuration Guide

ZodoLlama can be customized through configuration files and command-line arguments.

## Configuration File

Config file location: `~/.config/zodollama/config.json`

This file is automatically created on first run with default values.

## Default Configuration

```json
{
  "model": "llama3.2",
  "ollama_host": "http://localhost:11434",
  "editor": ["nvim"],
  "scroll_lines": 3,
  "color_status": "\u001b[33m",
  "color_link": "\u001b[36m",
  "color_thinking_header": "\u001b[36m",
  "color_thinking_dim": "\u001b[2m",
  "color_inline_code_bg": "\u001b[48;5;237m"
}
```

## Configuration Options

### Model Settings

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `model` | string | `"llama3.2"` | Ollama model to use |
| `ollama_host` | string | `"http://localhost:11434"` | Ollama server URL |

**Supported Models:**
- `llama3.2` - Default, balanced performance
- `llama3.2:1b` - Faster, lower resource usage
- `llama3.2:70b` - Higher quality, requires more resources
- Any model available in your Ollama instance

**Example:**
```json
{
  "model": "qwen2.5:14b",
  "ollama_host": "http://192.168.1.100:11434"
}
```

### Editor Settings

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `editor` | array | `["nvim"]` | Command to open editor for notes |

**Examples:**
```json
{
  "editor": ["vim"]
}
```

```json
{
  "editor": ["code", "--wait"]
}
```

```json
{
  "editor": ["nano"]
}
```

### UI Settings

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `scroll_lines` | number | `3` | Lines to scroll per wheel movement |

**Scroll Behavior:**
- `1`: Precise, line-by-line scrolling
- `3`: Default, balanced
- `5`: Faster scrolling for large conversations

### Color Settings

All color settings use ANSI escape codes.

| Option | Default | Description |
|--------|---------|-------------|
| `color_status` | `"\u001b[33m"` | Status bar color (yellow) |
| `color_link` | `"\u001b[36m"` | Link text color (cyan) |
| `color_thinking_header` | `"\u001b[36m"` | Thinking block header color (cyan) |
| `color_thinking_dim` | `"\u001b[2m"` | Thinking content color (dim) |
| `color_inline_code_bg` | `"\u001b[48;5;237m"` | Inline code background (grey) |

**Common ANSI Color Codes:**
```
Black:   \u001b[30m
Red:     \u001b[31m
Green:   \u001b[32m
Yellow:  \u001b[33m
Blue:    \u001b[34m
Magenta: \u001b[35m
Cyan:    \u001b[36m
White:   \u001b[37m

Bright variants: \u001b[90m - \u001b[97m
Dim: \u001b[2m
Bold: \u001b[1m
```

**Example Custom Colors:**
```json
{
  "color_status": "\u001b[32m",
  "color_link": "\u001b[94m",
  "color_thinking_header": "\u001b[95m"
}
```

## Command-Line Overrides

Override config file settings with CLI arguments:

```bash
./zig-out/bin/zodollama --model llama3.2:70b --ollama-host http://localhost:11434
```

**Available Arguments:**
- `--model <name>`: Override model
- `--ollama-host <url>`: Override Ollama server URL

**Priority:**
1. Command-line arguments (highest)
2. Config file settings
3. Built-in defaults (lowest)

## Permission Policies

Permission policies are stored separately from configuration:

**Location:** `~/.config/zodollama/policies.json`

**Format:**
```json
{
  "policies": [
    {
      "tool_name": "read_file",
      "decision": "always_allow",
      "created_at": 1705680000000
    }
  ]
}
```

**Policy Types:**
- `always_allow`: Auto-approve this tool
- `always_deny`: Auto-deny this tool
- Session grants: Not persisted (lost on quit)

**Managing Policies:**
- Policies are created through the permission prompt UI
- Select "Remember" option to persist a policy
- Manually edit `policies.json` to remove policies
- Delete `policies.json` to reset all policies

## Environment-Specific Configs

### Development
```json
{
  "model": "llama3.2:1b",
  "ollama_host": "http://localhost:11434"
}
```

### Remote Server
```json
{
  "model": "llama3.2:70b",
  "ollama_host": "http://my-server:11434"
}
```

### Custom Colors (Dark Theme)
```json
{
  "color_status": "\u001b[35m",
  "color_link": "\u001b[36m",
  "color_thinking_header": "\u001b[32m",
  "color_thinking_dim": "\u001b[2m",
  "color_inline_code_bg": "\u001b[48;5;234m"
}
```

## Configuration Tips

### Performance Tuning

**For slower machines:**
```json
{
  "model": "llama3.2:1b",
  "scroll_lines": 5
}
```

**For powerful machines:**
```json
{
  "model": "llama3.2:70b"
}
```

### Terminal Compatibility

If colors look wrong:
1. Check your terminal supports 256 colors: `echo $TERM`
2. Should be `xterm-256color` or similar
3. Use simpler color codes if needed

### Troubleshooting

**Config file not loading:**
- Check file exists: `ls ~/.config/zodollama/config.json`
- Verify JSON syntax: `cat ~/.config/zodollama/config.json | jq .`
- Check file permissions: `ls -la ~/.config/zodollama/`

**Ollama connection issues:**
- Verify Ollama is running: `curl http://localhost:11434/api/tags`
- Check `ollama_host` setting matches your setup
- Try CLI override: `--ollama-host http://localhost:11434`

**Model not found:**
- List available models: `ollama list`
- Pull model: `ollama pull llama3.2`
- Check model name spelling in config

## Advanced Configuration

### Multiple Configs

Switch between configs by using different config directories:

```bash
# Development config
XDG_CONFIG_HOME=~/.config-dev ./zodollama

# Production config
XDG_CONFIG_HOME=~/.config-prod ./zodollama
```

### Resetting Configuration

Delete config file to regenerate defaults:

```bash
rm ~/.config/zodollama/config.json
./zodollama  # Will create new default config
```

## See Also

- [Installation Guide](installation.md) - Setup and building
- [Features Guide](features.md) - Complete feature documentation
