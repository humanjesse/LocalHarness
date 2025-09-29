# ZigMark

A fast, lightweight terminal-based markdown viewer written in Zig. ZigMark provides an elegant TUI (Text User Interface) for browsing and editing markdown documents with real-time rendering.

## Features

- **Beautiful rendering** with ANSI styling, box drawing, and proper text wrapping
- **Interactive navigation** using vi-style keys and mouse support
- **Expandable document view** - collapse/expand files for quick browsing
- **Live editing integration** - seamlessly open documents in your preferred editor
- **Rich markdown support** - headers, lists, blockquotes, code blocks, links, and emphasis
- **Unicode-aware** text processing with proper line wrapping
- **Memory efficient** with careful allocation management

## Prerequisites

- **Zig compiler** (version 0.15.1 or later)
- Ghostty & Nvim

## Installation & Setup

1. Clone the repository:

2. Build the project:
   ```bash
   zig build
   ```

3. Run ZigMark:
   ```bash
   zig build run
   ```

## Usage

### Adding Markdown Files

Place your markdown files in the `my_notes/` directory (created automatically on first run):

You can also specify a custom notes directory:

```bash
zig build run -- --notes-dir /path/to/your/notes
```

### Controls

| Key/Action | Function |
|------------|----------|
| `j` / `k` | Navigate up/down through documents |
| `Space` | Toggle expand/collapse current document |
| `Enter` | Open current document in editor (nvim) |
| `q` | Quit application |
| **Mouse** | |
| Left click | Open document in editor |
| Right click | Toggle expand/collapse |

### Navigation Tips

- Documents appear as `[ filename ]` when collapsed
- Use `j`/`k` or mouse to navigate between documents
- Press `Space` to expand and view rendered markdown content
- Press `Enter` or left-click to edit documents in your editor

## Supported Markdown Features

- **Headers** (`#`, `##`, `###`, etc.)
- **Emphasis** (`*italic*`, `**bold**`, `~~strikethrough~~`)
- **Links** (`[text](url)`) - displayed with styling and URL
- **Lists** (ordered and unordered with proper nesting)
- **Blockquotes** (`>`) with visual borders
- **Code blocks** (``` fenced blocks) with syntax highlighting preparation
- **Inline code** (`code`) with background styling
- **Horizontal rules** (`---`)

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## License

MIT License - see LICENSE file for details.
