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
ollama pull llama3.2
ollama serve

# Build and run ZodoLlama
zig build
./zig-out/bin/zodollama
```

## Features

- **Real-time streaming** - Non-blocking UI stays responsive while AI responds
- **Markdown rendering** - Beautiful formatting with code blocks, tables, lists, and emoji
- **Smart auto-scroll** - Follows AI responses, disables when you scroll manually
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
| Mouse wheel | Scroll messages |
| Click message | Toggle thinking block |

## Configuration

Config file: `~/.config/zodollama/config.json` (created on first run)

```json
{
  "model": "llama3.2",
  "ollama_host": "http://localhost:11434",
  "editor": ["nvim"]
}
```

**CLI overrides:**
```bash
./zig-out/bin/zodollama --model llama3.2 --ollama-host http://localhost:11434
```

## Platform Support

**Tested:** Linux x86_64
**Should work:** Other Linux distributions, macOS
**Not supported:** Windows

## Contributing

Contributions welcome! Please submit issues and pull requests.

## License

MIT License - see LICENSE file for details.

---

<details>
<summary><strong>Technical Details</strong></summary>

### Architecture

- **Multi-threaded streaming** - API calls run in background thread
- **Thread-safe design** - Mutex-protected chunk queue
- **Flicker-free rendering** - Smart viewport management
- **Incremental parsing** - Real-time markdown processing

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
