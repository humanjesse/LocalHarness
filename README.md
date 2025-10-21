# ZodoLlama

A fast, lightweight terminal chat interface for Ollama written in Zig. Chat with local LLMs in your terminal with real-time markdown rendering.

![ZodoLlama Demo](zodollamademo.gif)

## Quick Start

### Prerequisites

- **Zig** (0.15.2 or later)
- **Ollama** running locally
- Any ANSI-compatible terminal

### Installation

```bash
# Install and start Ollama
ollama pull qwen3-coder:30b
ollama serve

# Build and run ZodoLlama
zig build
./zig-out/bin/zodollama
```

## Features

- **Real-time streaming** with responsive, non-blocking UI
- **Markdown rendering** - Code blocks, tables, lists, and emoji
- **Tool calling** - AI can read/write files, search code, and manage tasks
- **Permission system** - Control tool access with persistent policies
- **Task management** - Track multi-step workflows
- **Thinking blocks** - See AI reasoning (collapsible with mouse)
- **Mouse support** - Scroll and interact with messages
- **Configurable** - Customize model, host, and colors

## Usage

**Chat:**
- Type your message and press `Enter` to send
- Watch the AI response stream in real-time
- Scroll with mouse wheel to view history

**Controls:**

| Key/Action | Function |
|------------|----------|
| `Enter` | Send message |
| `Escape` | Clear input |
| `/quit` + `Enter` | Quit |
| Mouse wheel | Scroll messages (moves `>` cursor) |
| `Ctrl+O` | Toggle thinking block at cursor position (`>`) |

## Tool Permission System

Control AI access to tools (file read/write, search, tasks) with a permission prompt system.

**Options:** Allow Once (1), Session (2), Remember (3), or Deny (4)

Policies persist in `~/.config/zodollama/policies.json`. Some tools like file trees and searches are auto-approved; file writes require permission.

## Configuration

Config: `~/.config/zodollama/config.json` (created on first run)

Key options: `model`, `ollama_host`, `num_ctx` (context window), `num_predict` (max tokens), `editor`, `scroll_lines`, and color settings.

CLI overrides available: `--model`, `--ollama-host`

## Platform Support

Linux (tested on x86_64), macOS. Windows not supported.

## Documentation

See [docs/](docs/README.md) for user guide, architecture, and development info.

## License

MIT License

---

<details>
<summary><strong>Technical Details</strong></summary>

**Architecture:**
- Multi-threaded streaming with thread-safe design
- Flicker-free rendering with smart viewport management
- Event-driven permission system with async tool execution
- Modular codebase (~7k lines of Zig across 15 files)

**Markdown:** Headers, emphasis, links, lists, code blocks, tables, emoji

**History:** Evolved from ZigMark, a terminal markdown viewer

</details>
