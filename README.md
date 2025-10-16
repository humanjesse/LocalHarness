# ZodoLlama

A fast, lightweight terminal-based chat interface for Ollama written in Zig. ZodoLlama provides an elegant TUI for chatting with local LLMs with real-time markdown rendering of responses.

## Platform Support

**Tested:** Linux x86_64 (Arch Linux, kernel 6.17+)
**Should work:** Other Linux distributions, macOS (POSIX-compatible systems)
**Not supported:** Windows

ZodoLlama uses POSIX terminal APIs. If you try it on another platform, please open an issue and let us know if it works!

## Features

- **Non-blocking streaming** - type, scroll, and interact while AI responds in real-time
- **Background thread processing** - UI stays fully responsive during API calls
- **Smart auto-scroll** - viewport automatically follows AI responses during streaming, disables on manual scroll
- **AI thinking/reasoning blocks** - see the AI's thought process (when available), collapsible for clean reading
- **Beautiful markdown rendering** - AI responses rendered with ANSI styling, box drawing, and proper text wrapping
- **Flicker-free display** - smooth streaming without screen flashing or duplicated borders
- **Interactive chat history** - expand/collapse thinking blocks using mouse clicks
- **Instant scrolling** - mouse wheel scrolling works immediately, no click required
- **Ollama integration** - works with any Ollama-hosted model
- **Configurable** - customize model, host, editor, and UI colors via JSON config
- **Rich markdown support** - headers, lists, blockquotes, code blocks, links, tables, and emphasis
- **Advanced emoji support** - proper width calculation for emoji, skin tone modifiers, and ZWJ sequences
- **Unicode-aware** text processing with proper line wrapping for CJK and multi-byte characters
- **Smooth window resizing** - intelligent content re-wrapping with state preservation
- **Thread-safe architecture** - mutex-protected streaming with proper memory management

## Prerequisites

- **Zig compiler** (version 0.15.2 or later)
- **Ollama** - running locally with at least one model pulled
- Any ANSI-compatible terminal (Ghostty, kitty, alacritty, xterm, iTerm2, etc.)

## Installation & Setup

1. Install and start Ollama:
   ```bash
   # Install Ollama from https://ollama.com
   ollama pull llama3.2  # or any model you prefer
   ollama serve          # start the Ollama server
   ```

2. Build the project:
   ```bash
   zig build
   ```

3. Run ZodoLlama:
   ```bash
   ./zig-out/bin/zodollama
   ```

## Configuration

ZodoLlama creates a config file at `~/.config/zodollama/config.json` on first run. Edit it to customize your setup:

```json
{
  "editor": ["nvim"],
  "ollama_host": "http://localhost:11434",
  "ollama_endpoint": "/api/chat",
  "model": "llama3.2",
  "color_status": "\u001b[33m",
  "color_link": "\u001b[36m",
  "color_thinking_header": "\u001b[36m",
  "color_thinking_dim": "\u001b[2m",
  "color_inline_code_bg": "\u001b[48;5;237m"
}
```

**Configuration Options:**
- `ollama_host` - Ollama API endpoint (default: `http://localhost:11434`)
- `ollama_endpoint` - API endpoint path (default: `/api/chat`)
- `model` - Model to use for chat (must be pulled in Ollama)
- `editor` - Editor for future features
- `color_status` - Status message color (default: yellow `\u001b[33m`)
- `color_link` - Link text color (default: cyan `\u001b[36m`)
- `color_thinking_header` - "Thinking" header color (default: cyan `\u001b[36m`)
- `color_thinking_dim` - Thinking content dimming (default: dim `\u001b[2m`)
- `color_inline_code_bg` - Inline code background (default: grey `\u001b[48;5;237m`)

**Available ANSI Color Codes:**
- Basic colors: `\u001b[31m` (red), `\u001b[32m` (green), `\u001b[33m` (yellow), `\u001b[34m` (blue), `\u001b[35m` (magenta), `\u001b[36m` (cyan), `\u001b[37m` (white)
- Styles: `\u001b[1m` (bold), `\u001b[2m` (dim), `\u001b[3m` (italic), `\u001b[4m` (underline)
- 256-color backgrounds: `\u001b[48;5;NUMm` where NUM is 0-255

**CLI Overrides:**
```bash
./zig-out/bin/zodollama --model llama3.2 --ollama-host http://localhost:11434
```

**Priority:** CLI flags > config file > defaults

## Usage

### Chatting with AI

1. Type your message in the input field at the bottom
2. Press `Enter` to send
3. Watch the AI response stream in real-time with markdown rendering

### Controls

| Key/Action | Function |
|------------|----------|
| `Escape` | Clear input field |
| `Backspace` | Delete character from input |
| `Enter` | Send message (when input has content) |
| `/quit` + `Enter` | Quit application |
| **Mouse** | |
| Mouse wheel up/down | Scroll through messages (auto-scroll disables on use) |
| Left click on message | Toggle expand/collapse thinking block |
| Right click on message | Toggle expand/collapse thinking block |

### Chat Tips

- Your messages and AI responses appear as bordered message boxes
- The AI response streams in real-time - you'll see it being generated token-by-token
- **Thinking blocks** - some models show their reasoning process in a collapsible "Thinking" section (auto-collapsed when response completes)
- **Smart auto-scroll** - viewport automatically follows streaming responses; scroll up to read earlier parts and auto-scroll disables
- **Instant scrolling** - mouse wheel works immediately without clicking first
- **Fully responsive UI** - type, scroll, and interact while the AI is responding
- Wait for the AI to finish (yellow status indicator disappears) before sending your next message
- All markdown in responses is rendered beautifully (code blocks, lists, tables, emphasis, emoji, etc.)
- Click on any message to toggle the thinking block visibility
- Messages stay in history - scroll up to review the entire conversation

### Terminal Resize Handling

ZodoLlama intelligently handles terminal window resizing:
- Content automatically re-wraps to the new terminal width
- Thinking blocks remain in their current state (collapsed/expanded)
- No flicker or rendering artifacts during resize
- Scroll position is preserved when possible

## Supported Markdown Features

- **Headers** (`#`, `##`, `###`, etc.)
- **Emphasis** (`*italic*`, `**bold**`, `~~strikethrough~~`)
- **Links** (`[text](url)`) - displayed with styling and URL
- **Lists** (ordered and unordered with proper nesting)
- **Blockquotes** (`>`) with visual borders
- **Code blocks** (``` fenced blocks) with syntax highlighting preparation
- **Inline code** (`code`) with background styling
- **Horizontal rules** (`---`)
- **Tables** (GFM-style with `|` delimiters) - intelligent column width distribution, column alignment, Unicode box-drawing borders
- **Emoji** - full Unicode emoji support with proper width calculation

### Table Rendering

ZodoLlama includes sophisticated table rendering with intelligent column width distribution:

- **Natural minimum widths** - Each column calculates its natural minimum based on header length and longest words in cells
- **Smart scaling** - When tables exceed terminal width, narrow columns (labels, categories) are protected while wide content columns wrap gracefully
- **Multi-line cell support** - Long cell content wraps with 2-space continuation indent
- **Proportional distribution** - Extra space is allocated based on each column's content demand
- **Alignment support** - Left, center, and right alignment (GFM-style with `:` markers)

This ensures label columns remain readable while content columns adapt to available space.

## Unicode & Emoji Support

ZodoLlama includes comprehensive Unicode handling with ~98% accurate emoji rendering:

- ✅ **Basic emoji** (😀, 🎉, 🚀, ❤️)
- ✅ **Emoji with skin tone modifiers** (👋🏽, 👶🏾, 👨🏿)
- ✅ **Family emoji** (👨‍👩‍👧‍👦, 👩‍👩‍👧‍👦)
- ✅ **Couple emoji** (👨‍❤️‍👨, 👩‍❤️‍👩)
- ✅ **Professional emoji** (👨‍💻, 👩‍⚕️, 👨‍🚒)
- ✅ **Zero-Width Joiner (ZWJ) sequences**
- ✅ **CJK characters** (中文, 日本語, 한국어)

### Implementation

- Pure Zig implementation with no external dependencies
- Comprehensive Unicode range coverage (Unicode 15.0+)
- State machine for ZWJ sequence detection
- Proper handling of variation selectors and combining marks

## Technical Details

### Streaming Architecture

ZodoLlama implements a non-blocking multi-threaded streaming system for real-time AI responses:

- **Background Thread Streaming** - API calls run in separate thread, main thread stays responsive
- **Thread-Safe Chunk Queue** - Mutex-protected queue for passing data between threads
- **Immediate User Feedback** - User messages appear instantly before API call
- **Responsive UI During Streaming** - Type, scroll, and interact while AI responds
- **Smart Auto-Scroll** - Viewport follows streaming responses, automatically disables on manual scroll
- **Thinking/Reasoning Support** - Separate content streams for thinking and response content
- **Streaming Responses** - Ollama chat API with `stream: true` for token-by-token delivery
- **Flicker-Free Rendering** - Uses `\x1b[H` (move cursor home) with precise viewport clearing to prevent artifacts
- **Incremental Markdown Parsing** - Each chunk triggers re-parsing and re-rendering with full markdown support
- **Efficient Event Loop** - Non-blocking input when streaming, blocking when idle for CPU efficiency
- **Accurate Viewport Management** - Render-first approach ensures scroll position matches current content height

### HTTP Client

- MVP implementation uses `curl` subprocess for reliable streaming
- Reads newline-delimited JSON (NDJSON) from Ollama streaming API
- Future: native Zig `std.http.Client` implementation when Zig 0.15 stabilizes

### Memory Management

- Arena allocators for markdown parsing (freed after rendering)
- General Purpose Allocator for message storage and output
- Thread-safe chunk allocation with mutex protection
- Careful deallocation on message updates during streaming
- Thread context cleanup after streaming completes
- No memory leaks in streaming callback loop

### Rendering Pipeline

1. User input → immediate display with placeholder for AI response
2. Background thread spawned for Ollama API streaming
3. Main event loop:
   - Check mutex-protected chunk queue
   - Process all pending chunks
   - For each chunk:
     - Append to thinking/content buffers
     - Free old parsed markdown
     - Re-parse accumulated thinking and content
     - Calculate accurate content height
     - Apply smart auto-scroll (if enabled)
     - Redraw screen with corrected viewport (flicker-free)
   - Handle user input (non-blocking)
   - Continue until streaming completes
4. Auto-collapse thinking block when streaming finishes
5. Thread cleanup when `done: true` received

## Project History

ZodoLlama evolved from **ZigMark**, a terminal markdown document viewer. The conversion maintained the robust markdown rendering engine while transforming the interface from document browsing to AI chat.

**What Changed:**
- Document viewing → Chat interface with Ollama
- File system integration → HTTP API streaming
- Static markdown files → Dynamic AI-generated responses
- Notes directory → Conversation history in memory
- `notes_dir` config → `ollama_host` and `model` config

**What Stayed:**
- Same markdown parser and renderer
- Same Unicode/emoji handling
- Same mouse support for navigation
- Same window resize intelligence
- Same ANSI rendering pipeline

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## License

MIT License - see LICENSE file for details.
