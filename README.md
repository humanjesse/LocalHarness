# ZodoLlama

A fast, lightweight terminal-based chat interface for Ollama written in Zig. ZodoLlama provides an elegant TUI for chatting with local LLMs with real-time markdown rendering of responses.

## Features

- **Streaming AI responses** - see tokens appear in real-time as the model generates them
- **Beautiful markdown rendering** - AI responses rendered with ANSI styling, box drawing, and proper text wrapping
- **Flicker-free display** - smooth streaming without screen flashing
- **Interactive chat history** - expand/collapse messages using mouse clicks
- **Ollama integration** - works with any Ollama-hosted model
- **Configurable** - customize model, host, and editor preferences
- **Rich markdown support** - headers, lists, blockquotes, code blocks, links, tables, and emphasis
- **Advanced emoji support** - proper width calculation for emoji, skin tone modifiers, and ZWJ sequences
- **Unicode-aware** text processing with proper line wrapping
- **Smooth window resizing** - intelligent content re-wrapping with state preservation
- **Memory efficient** with careful allocation management

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
   ./zig-out/bin/my_tui_app
   ```

## Configuration

ZodoLlama creates a config file at `~/.config/zodollama/config.json` on first run. Edit it to customize your setup:

```json
{
  "editor": ["nvim"],
  "ollama_host": "http://localhost:11434",
  "model": "llama3.2"
}
```

**Configuration Options:**
- `ollama_host` - Ollama API endpoint (default: `http://localhost:11434`)
- `model` - Model to use for chat (must be pulled in Ollama)
- `editor` - Editor for future features

**CLI Overrides:**
```bash
./zig-out/bin/my_tui_app --model gpt-oss:120b --ollama-host http://localhost:11434
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
| Mouse wheel up/down | Scroll through messages |
| Left click | Toggle expand/collapse message |
| Right click | Toggle expand/collapse message |

### Chat Tips

- Your messages and AI responses appear as expandable message boxes
- The AI response streams in real-time - you'll see it being generated
- All markdown in responses is rendered beautifully (code blocks, lists, tables, emphasis, etc.)
- Messages stay in history - scroll up to see previous conversation
- Use mouse wheel to navigate through long conversations

### Terminal Resize Handling

ZodoLlama intelligently handles terminal window resizing:
- Messages automatically collapse during resize for smooth rendering
- After resize completes (~200ms), messages re-expand with content properly wrapped to the new width
- No flicker or glitchy artifacts during active window dragging
- Preserves your expansion state and scroll position across resize operations

## Supported Markdown Features

- **Headers** (`#`, `##`, `###`, etc.)
- **Emphasis** (`*italic*`, `**bold**`, `~~strikethrough~~`)
- **Links** (`[text](url)`) - displayed with styling and URL
- **Lists** (ordered and unordered with proper nesting)
- **Blockquotes** (`>`) with visual borders
- **Code blocks** (``` fenced blocks) with syntax highlighting preparation
- **Inline code** (`code`) with background styling
- **Horizontal rules** (`---`)
- **Tables** (GFM-style with `|` delimiters) - column alignment, Unicode box-drawing borders
- **Emoji** - full Unicode emoji support with proper width calculation

## Unicode & Emoji Support

ZigMark includes comprehensive Unicode handling with ~98% accurate emoji rendering:

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

ZodoLlama implements a sophisticated streaming system for real-time AI responses:

- **Immediate User Feedback** - User messages appear instantly before API call
- **Streaming Responses** - Ollama chat API with `stream: true` for token-by-token delivery
- **Flicker-Free Rendering** - Uses `\x1b[H` (move cursor home) + `\x1b[J` (clear to end) instead of `\x1b[2J` (clear screen)
- **Incremental Markdown Parsing** - Each chunk triggers re-parsing and re-rendering with full markdown support
- **Efficient Redraws** - Only redraws changed content, preserving existing rendered lines

### HTTP Client

- MVP implementation uses `curl` subprocess for reliable streaming
- Reads newline-delimited JSON (NDJSON) from Ollama streaming API
- Future: native Zig `std.http.Client` implementation when Zig 0.15 stabilizes

### Memory Management

- Arena allocators for markdown parsing (freed after rendering)
- General Purpose Allocator for message storage and output
- Careful deallocation on message updates during streaming
- No memory leaks in streaming callback loop

### Rendering Pipeline

1. User input → immediate display
2. Ollama API call with streaming enabled
3. For each chunk:
   - Append to response buffer
   - Free old parsed markdown
   - Re-parse accumulated response
   - Redraw screen (flicker-free)
4. Continue until `done: true`

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
