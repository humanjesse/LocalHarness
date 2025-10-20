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

- **Real-time streaming** - Non-blocking UI stays responsive while AI responds
- **Markdown rendering** - Beautiful formatting with code blocks, tables, lists, and emoji
- **Tool calling** - AI can read files, generate file trees, and manage tasks autonomously
- **Structured tool results** - All tools return JSON with success/failure, error types, and execution metrics
- **Master loop** - AI iterates through multi-step tasks until completion (max 10 iterations)
- **Task management** - Break down complex requests into trackable tasks with status updates
- **Permission system** - Fine-grained control over tool access with persistent policies
- **Receipt printer scroll** - Content flows continuously, auto-following streaming responses (resumes on next message if scrolled away)
- **Thinking blocks** - See AI reasoning process (collapsible with mouse clicks)
- **Mouse support** - Scroll and interact with messages using your mouse
- **Configurable** - Customize model, host, and UI colors

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

ZodoLlama includes a built-in permission system to control AI access to tools like file reading/writing and command execution.

**How it works:**

When the AI requests to use a tool, you'll see a permission prompt:

```
⚠️  Permission Request

Tool: read_file
Arguments: {"path": "README.md"}
Risk: LOW

[1] Allow Once  [2] Session  [3] Remember  [4] Deny
```

**Permission Options:**

| Key | Action | Description |
|-----|--------|-------------|
| `1` | Allow Once | Execute this tool call only (one-time) |
| `2` | Session | Allow for this session (until you quit) |
| `3` | Remember | Always allow (saved to `~/.config/zodollama/policies.json`) |
| `4` | Deny | Block this tool call |

**Available Tools:**

*File System:*
- `get_file_tree` - Generate file tree of current directory (auto-approved)
- `grep_search` - Recursively search files for patterns with .gitignore awareness (auto-approved)
- `read_file` - Read file contents (requires permission)
- `write_file` - Create or overwrite files with content (requires permission, high risk)
- `replace_lines` - Replace specific line ranges in existing files (requires permission, high risk)

*System:*
- `get_current_time` - Get current date and time (auto-approved)

*Task Management (Phase 1):*
- `add_task` - Add a new task to track progress, returns string ID like `"task_1"` (auto-approved)
- `list_tasks` - View all current tasks with their string IDs and status (auto-approved)
- `update_task` - Update task status using `task_id` parameter (auto-approved)

**Policy Storage:**

Policies are saved in `~/.config/zodollama/policies.json` and persist across sessions.

## Configuration

Config file: `~/.config/zodollama/config.json` (created on first run)

```json
{
  "model": "qwen3-coder:30b",
  "model_keep_alive": "15m",
  "ollama_host": "http://localhost:11434",
  "editor": ["nvim"],
  "scroll_lines": 3
}
```

### Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `model` | string | `"qwen3-coder:30b"` | Ollama model to use |
| `model_keep_alive` | string | `"15m"` | How long to keep model in memory after last request. Use duration string ("5m", "15m") or "-1" for infinite. Balances responsiveness vs GPU/RAM usage. |
| `ollama_host` | string | `"http://localhost:11434"` | Ollama server URL |
| `editor` | array | `["nvim"]` | Command to open editor for notes |
| `scroll_lines` | number | `3` | Lines to scroll per wheel movement |
| `color_status` | string | `"\u001b[33m"` | Status bar color (yellow) |
| `color_link` | string | `"\u001b[36m"` | Link text color (cyan) |
| `color_thinking_header` | string | `"\u001b[36m"` | Thinking header color (cyan) |
| `color_thinking_dim` | string | `"\u001b[2m"` | Thinking content color (dim) |
| `color_inline_code_bg` | string | `"\u001b[48;5;237m"` | Inline code background (grey) |

**CLI overrides:**
```bash
./zig-out/bin/zodollama --model qwen3-coder:30b --ollama-host http://localhost:11434
```

## Platform Support

**Tested:** Linux x86_64
**Should work:** Other Linux distributions, macOS
**Not supported:** Windows

## Documentation

- **[User Guide](docs/user-guide/installation.md)** - Installation, configuration, and features
- **[Development](docs/development/)** - Contributing, deployment, and development guides
- **[Architecture](docs/architecture/)** - Technical documentation and design
- **[Full Documentation Index](docs/README.md)** - Complete documentation navigation

## Contributing

Contributions welcome! See the [Contributing Guide](docs/development/contributing.md) for details.

## License

MIT License - see LICENSE file for details.

---

<details>
<summary><strong>Technical Details</strong></summary>

### Architecture

**Core Features:**
- **Multi-threaded streaming** - API calls run in background thread
- **Thread-safe design** - Mutex-protected chunk queue
- **Flicker-free rendering** - Smart viewport management with receipt printer scroll (auto-follows streaming, pauses on manual scroll, resumes on next message)
- **Incremental parsing** - Real-time markdown processing
- **Non-blocking tool execution** - Tools execute automatically during streaming without requiring user input
- **Async permission system** - Non-blocking event-driven permission prompts with state machine tool execution
- **Modular tool system** - Centralized tool definitions in `tools.zig` combining schemas, permissions, and execution
- **Structured tool results** - JSON responses with success/error categorization (7 error types) and execution metadata
- **Master loop** - Iterative task execution with automatic tool call handling and iteration limits
- **State management** - Session-ephemeral task tracking with AppContext pattern for future graph RAG

**Modular Codebase:**
- `main.zig` (56 lines) - Entry point
- `app.zig` (1197 lines) - Core application, App struct, event loop, business logic
- `message_renderer.zig` (932 lines) - Message rendering, display logic, screen drawing
- `config.zig` (344 lines) - Configuration and policy persistence
- `ui.zig` (559 lines) - Terminal I/O, input handling, taskbar
- `markdown.zig` (1502 lines) - Markdown parsing and rendering engine
- `tools.zig` (643 lines) - Tool definitions, structured results, execution
- `permission.zig` (684 lines) - Permission management system
- `ollama.zig` (423 lines) - Ollama API client
- `types.zig` (44 lines) - Shared message types
- `state.zig` (69 lines) - Task management state
- `context.zig` (18 lines) - Tool execution context
- `render.zig` (252 lines) - Text wrapping and formatting utilities
- `tree.zig` (365 lines) - File tree generation
- `lexer.zig` (194 lines) - Markdown lexer

### Markdown Support

Headers, emphasis, links, lists, blockquotes, code blocks, inline code, tables, horizontal rules, emoji with ZWJ sequences, CJK characters.

### Memory Management

- Arena allocators for parsing
- General Purpose Allocator for storage
- Thread-safe chunk allocation
- Proper cleanup on completion

### Project History

ZodoLlama evolved from **ZigMark**, a terminal markdown viewer. The core rendering engine was preserved while the interface was transformed from document browsing to AI chat.

</details>
