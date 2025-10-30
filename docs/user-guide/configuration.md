# Configuration Guide

Local Harness can be configured in three ways:

1. **Interactive Editor** (`/config` command) - Recommended for most users
2. **JSON File** (`~/.config/localharness/config.json`) - For advanced users and automation
3. **CLI Arguments** (`--model`, `--ollama-host`) - For quick overrides

---

## Interactive Config Editor

**The easiest way to configure Local Harness.**

### Quick Start

1. Start Local Harness: `./localharness`
2. Type: `/config`
3. Navigate with Tab, edit with Enter
4. Press Ctrl+S to save

### Features

- ✅ Visual editing (no JSON syntax)
- ✅ Field validation
- ✅ Help text for each setting
- ✅ Provider-specific warnings
- ✅ Cancel changes safely (Esc)

**See [Features Guide](features.md#interactive-configuration-editor) for detailed usage.**

---

## Configuration File

Config file location: `~/.config/localharness/config.json`

This file is automatically created on first run with default values. You can edit it directly or use the `/config` command for a visual editor.

## Default Configuration

```json
{
  "provider": "ollama",
  "ollama_host": "http://localhost:11434",
  "ollama_endpoint": "/api/chat",
  "lmstudio_host": "http://localhost:1234",
  "model": "qwen3-coder:30b",
  "model_keep_alive": "15m",
  "num_ctx": 128000,
  "num_predict": 8192,
  "enable_thinking": true,
  "show_tool_json": false,
  "graph_rag_enabled": false,
  "embedding_model": "nomic-embed-text",  // Ollama format; LM Studio needs "text-embedding-..." prefix
  "indexing_model": "llama3.1:8b",
  "max_chunks_in_history": 5,
  "zvdb_path": ".localharness/graphrag.zvdb",
  "file_read_small_threshold": 200,
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

### Provider Selection

Local Harness supports multiple LLM backends. Choose based on your hardware, preferences, and available models.

#### Ollama (Default)

**Best for:** NVIDIA GPUs, ease of use, quick setup, extended thinking mode

**Configuration:**
```json
{
  "provider": "ollama",
  "ollama_host": "http://localhost:11434",
  "model": "qwen3-coder:30b"
}
```

**Setup:**
```bash
# Install and start Ollama
ollama pull qwen3-coder:30b
ollama serve
```

**Ollama-Specific Features:**
- ✅ Extended thinking mode (`enable_thinking: true`)
- ✅ Model lifecycle control (`model_keep_alive: "15m"`)
- ✅ API-controlled context size (`num_ctx`)
- ✅ All standard features

**Supported Models:**
- `qwen3-coder:30b` - Recommended (coding-focused)
- `llama3.2` - Balanced performance
- `llama3.2:70b` - Higher quality
- Any model from [Ollama Library](https://ollama.com/library)

#### LM Studio

**Best for:** AMD GPUs, visual model management, model experimentation

**Configuration:**
```json
{
  "provider": "lmstudio",
  "lmstudio_host": "http://localhost:1234",
  "model": "qwen2.5-coder-7b"
}
```

**Setup:**
1. Download [LM Studio](https://lmstudio.ai/)
2. Load a model in the UI
3. Start the server (Local Server tab)
4. Verify running on port 1234

**Important Notes:**
- ⚠️ **Context size** must be set in LM Studio UI (not in config file)
- ⚠️ **Extended thinking mode** is not supported
- ⚠️ **`model_keep_alive`** parameter is ignored
- ⚠️ **GraphRAG embedding models**: Use format `text-embedding-nomic-embed-text-v1.5`, load BERT model in UI first
- ✅ All tools work (file operations, GraphRAG, etc.)
- ✅ Embeddings fully supported with error handling and retry logic
- ✅ Function/tool calling supported

#### Switching Providers

**Using Config Editor (Recommended):**
1. Type `/config`
2. Navigate to "Provider" field
3. Press `←` or `→` to change
4. Press Ctrl+S to save

**Manual Edit:**
```bash
# Edit config file
$EDITOR ~/.config/localharness/config.json

# Change provider field
{
  "provider": "lmstudio",  # ← Change this
  ...
}

# Restart Local Harness
```

---

### Model Settings

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `provider` | string | `"ollama"` | LLM backend: `"ollama"` or `"lmstudio"` |
| `model` | string | `"qwen3-coder:30b"` | Model name/identifier |
| `ollama_host` | string | `"http://localhost:11434"` | Ollama server URL |
| `lmstudio_host` | string | `"http://localhost:1234"` | LM Studio server URL |
| `model_keep_alive` | string | `"15m"` | Keep model in memory (Ollama only) |
| `num_ctx` | number | `128000` | Context window size in tokens |
| `num_predict` | number | `8192` | Max tokens to generate (-1 = unlimited) |

**Example - Switch to LM Studio:**
```json
{
  "provider": "lmstudio",
  "model": "qwen2.5-coder-7b",
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

### GraphRAG Settings

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `graph_rag_enabled` | boolean | `false` | Enable GraphRAG context compression |
| `embedding_model` | string | `"nomic-embed-text"` | Model for embeddings - Ollama: `"nomic-embed-text"`, LM Studio: `"text-embedding-..."` |
| `indexing_model` | string | `"llama3.1:8b"` | Model for file analysis (both Ollama and LM Studio) |
| `max_chunks_in_history` | number | `5` | Max entities in summaries |
| `zvdb_path` | string | `".localharness/graphrag.zvdb"` | Vector DB path |

GraphRAG builds knowledge graphs of read files in a secondary loop, compressing conversation history by 90%+ while preserving semantics. Both Ollama and LM Studio are fully supported - the embedder automatically uses your configured provider. See [Features Guide](features.md#graphrag-context-compression).

**Configuration Tips:**
- Use `/config` command to edit embedding/indexing models interactively
- Both models are now visible in the Provider Settings section of the config editor
- For LM Studio: Ensure your embedding model is loaded before enabling GraphRAG
- Debug mode: Set `DEBUG_GRAPHRAG=1` environment variable to see model/provider info during indexing

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
./zig-out/bin/localharness --model llama3.2:70b --ollama-host http://localhost:11434
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

**Location:** `~/.config/localharness/policies.json`

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
- Check file exists: `ls ~/.config/localharness/config.json`
- Verify JSON syntax: `cat ~/.config/localharness/config.json | jq .`
- Check file permissions: `ls -la ~/.config/localharness/`

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
XDG_CONFIG_HOME=~/.config-dev ./localharness

# Production config
XDG_CONFIG_HOME=~/.config-prod ./localharness
```

### Resetting Configuration

Delete config file to regenerate defaults:

```bash
rm ~/.config/localharness/config.json
./localharness  # Will create new default config
```

## See Also

- [Installation Guide](installation.md) - Setup and building
- [Features Guide](features.md) - Complete feature documentation
