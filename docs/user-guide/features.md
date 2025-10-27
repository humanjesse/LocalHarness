# Features Guide

Complete guide to all ZodoLlama features and capabilities.

> **Quick Reference:** See [Commands Reference](commands.md) for keyboard shortcuts and command syntax.

## Core Features

### Real-time Streaming

**What it does:** AI responses stream in real-time as the model generates them, without blocking the UI.

**How it works:**
- Non-blocking background thread handles API communication
- Chunks arrive and render incrementally
- UI remains responsive during generation
- Can scroll and interact while streaming

**User experience:**
- See responses appear word-by-word
- No waiting for complete response
- Natural conversation flow

### Markdown Rendering

**Supported syntax:**

#### Text Formatting
- **Bold**: `**text**` or `__text__`
- *Italic*: `*text*` or `_text_`
- `Inline code`: `` `code` ``
- ~~Strikethrough~~: `~~text~~`

#### Headers
```markdown
# H1 Header
## H2 Header
### H3 Header
```

#### Links
```markdown
[Link text](https://url.com)
```
- Rendered in cyan (configurable)
- Visible and clickable in terminal

#### Code Blocks
````markdown
```language
code here
```
````
- Syntax highlighting (language-aware)
- Preserves formatting
- Background highlighting

#### Lists

**Unordered:**
```markdown
- Item 1
- Item 2
  - Nested item
```

**Ordered:**
```markdown
1. First
2. Second
   1. Nested
```

#### Tables
```markdown
| Header 1 | Header 2 |
|----------|----------|
| Cell 1   | Cell 2   |
```
- Automatic alignment
- Border rendering
- Multi-line cells supported

#### Blockquotes
```markdown
> Quoted text
> Multiple lines
```

#### Horizontal Rules
```markdown
---
```

#### Emoji
- Full emoji support including:
  - Basic emoji: 😊 🎉 🚀
  - ZWJ sequences: 👨‍👩‍👧‍👦 (family)
  - Skin tone modifiers: 👋🏽
  - CJK characters: 你好 こんにちは

### Tool Calling

**What it does:** AI can autonomously use tools to gather information and complete tasks.

**Available tools:**

#### File System
- **get_file_tree**: List all files in project (recursive)
- **ls**: List single directory with metadata (size, modified time, type) - supports sorting and filtering
- **read_file**: Smart file reading with auto-detection (small: full content, medium: curated, large: structure only) - shows agent thinking in real-time for medium/large files, triggers GraphRAG indexing
- **read_lines**: Read specific line ranges (fast, no indexing - use for quick checks)
- **write_file**: Create or overwrite files with content
- **replace_lines**: Replace specific line ranges in existing files
- **insert_lines**: Insert new content before a specific line in existing files
- **grep_search**: Search files for text patterns (supports wildcards, hidden dirs, gitignore bypass)

#### System
- **get_current_time**: Get current date/time
- **get_working_directory**: Get current working directory path

#### Task Management
- **add_task**: Create a new task
- **list_tasks**: View all tasks
- **update_task**: Update task status

**Example conversations:**
```
You: "What files are in this project?"
AI: [Automatically calls get_file_tree]
    This project contains:
    - main.zig
    - ui.zig
    - ollama.zig
    ...

You: "What's in the tools directory?"
AI: [Calls ls with path="tools", sort_by="size", reverse=true]
    Directory: tools/
    Total: 12 entries (11 files, 1 directory)

    Type  Size     Modified              Name
    FILE  15.2 KB  2025-10-24 10:15:30   grep_search.zig
    FILE  4.8 KB   2025-10-24 09:20:15   read_file.zig
    ...

You: "Find all functions that contain 'init'"
AI: [Calls grep_search with pattern "fn*init"]
    Found 12 matches in 5 files:
    - main.zig:45: pub fn init() !void {
    - ui.zig:120: fn initColors() void {
    ...

You: "Search for database config, including hidden files"
AI: [Calls grep_search with include_hidden=true]
    Found in .config/settings.conf:
    - database_config=localhost
    ...
```

See [Tool Calling Documentation](../architecture/tool-calling.md) for details.

### Master Loop (Agentic Behavior)

**What it does:** AI can perform multi-step tasks autonomously without requiring user prompts between steps.

**How it works:**
1. AI breaks down complex requests
2. Uses tools to gather information
3. Processes results
4. Continues until task complete
5. Provides comprehensive answer

**Example:**
```
You: "How does markdown rendering work?"

[Iteration 1]
AI: [Calls get_file_tree]

[Iteration 2]
AI: [Calls read_file("markdown.zig")]

[Iteration 3]
AI: [Calls read_file("lexer.zig")]

[Final Response]
AI: Based on the code, markdown rendering works through
    a three-stage pipeline:
    1. Lexer tokenizes input (lexer.zig:45-120)
    2. Parser structures tokens (markdown.zig:230-450)
    3. Renderer outputs formatted text (markdown.zig:680-890)
    ...
```

**Limits:**
- Max 10 iterations per request
- Max 15 tool calls per iteration
- Prevents infinite loops

### Task Management

**What it does:** AI can break down complex tasks and track progress.

**Features:**
- Create tasks with string IDs (`"task_1"`, `"task_2"`)
- Track status: pending, in_progress, completed
- View task list anytime
- Session-ephemeral (resets on quit)

**Example:**
```
You: "Refactor markdown.zig to be more modular"

AI: I'll break this down into tasks:
    [add_task "Analyze current structure"]
    [add_task "Design module boundaries"]
    [add_task "Propose refactoring plan"]

    [Iteration 1]
    [update_task "task_1" "in_progress"]
    [read_file "markdown.zig"]
    [update_task "task_1" "completed"]

    Task 1 complete. Moving to module design...
```

**Task list display:**
```
📋 Current Task List:
⏳ task_1: Analyze current structure (pending)
🔄 task_2: Design module boundaries (in_progress)
✅ task_3: Write documentation (completed)
```

### Permission System

**What it does:** Fine-grained control over AI's access to tools.

**Risk levels:**
- **Safe**: Auto-approved (get_file_tree, get_current_time, task tools)
- **Medium**: Requires approval (read_file)
- **High**: Requires approval with warning (future: write_file, execute)

**Permission options:**

When AI requests a tool:
```
⚠️  Permission Request

Tool: read_file
Arguments: {"path": "README.md"}
Risk: MEDIUM

[1] Allow Once  [2] Session  [3] Remember  [4] Deny
```

- **Allow Once** (1): Execute this call only
- **Session** (2): Allow for this session
- **Remember** (3): Always allow (saved to disk)
- **Deny** (4): Block this call

**Policy management:**
- Policies saved in `~/.config/zodollama/policies.json`
- Persist across sessions
- Can be edited manually

### Receipt Printer Scroll

**What it does:** Automatic scrolling that follows streaming content like a receipt printer.

**Behavior:**
- **During streaming:**
  - Auto-scrolls to show latest content
  - Cursor tracks newest line
  - Feels like a receipt printing out

- **Manual scroll:**
  - Mouse wheel up/down
  - Pauses auto-scroll
  - Lets you read earlier messages

- **Resume auto-scroll:**
  - Send next message
  - Auto-scroll resumes automatically

**Visual indicator:**
- `>` cursor shows current line
- Auto-follows during streaming
- Stays put when manually scrolled

### Mouse Support

**What it does:** Full mouse interaction in terminal.

**Supported actions:**
- **Scroll**: Mouse wheel up/down
- **Click thinking blocks**: Expand/collapse (Ctrl+O also works)

**Requirements:**
- Terminal with mouse support (most modern terminals)
- Automatically enabled on startup

### Thinking Blocks

**What it does:** See AI's reasoning process before final answer.

**Display:**
```
💭 Thinking... (click to expand, or Ctrl+O)
[Collapsed by default]

💭 Thinking...
The user wants to know about file structure.
I should use get_file_tree tool to list files,
then provide a categorized overview.
[Expanded - shows reasoning]
```

**Controls:**
- **Ctrl+O**: Toggle thinking block at cursor position
- **Mouse click**: Toggle thinking block (if terminal supports)

**Configuration:**
- Enabled by default for supported models
- Automatically detected from model response

### Agent Progress Streaming ✨ NEW

**What it does:** See sub-agents' thinking and analysis in real-time as they work.

**When it appears:**
- During file curation (medium/large files, 100+ lines)
- Shows live agent analysis and decision-making
- Streams character-by-character like main assistant

**Example:**
```
You: read app.zig

[Appears immediately, streams in real-time]
┌──────────────────────────────────────┐
│ 🤔 File Curator Analyzing...         │
├──────────────────────────────────────┤
│ 💭 Thinking:                         │
│ "Analyzing app.zig (1200 lines)...   │  ← Streams as agent thinks
│ User needs file overview.            │
│ Mode: STRUCTURE (large file)         │
│ Extracting skeleton:                 │
│ - Import statements                  │
│ - Type definitions                   │
│ - Function signatures..."            │
└──────────────────────────────────────┘

[After completion]
Tool Result: read_file (✅ SUCCESS, 1200ms)
💭 Agent Thinking (Ctrl+O to expand)
📄 Curated Output (showing 140 of 1200 lines)
```

**Features:**
- **Live updates** - See thinking as it generates
- **Full transparency** - Understand agent's decisions
- **Auto-cleanup** - Progress message removed when done
- **Captured thinking** - Saved in tool result (Ctrl+O to review)

**Benefits:**
- No silent pauses - always know work is happening
- Educational - learn how agents analyze code
- Debugging - see why agent kept/omitted certain code

## UI Features

### Taskbar

Bottom status bar shows:
```
[Model: llama3.2] [Streaming...] [Msg: 12]
```

Information displayed:
- Current model name
- Streaming status
- Message count
- Scroll position (when scrolled away)

### Interactive Configuration Editor

**Command:** `/config`

A full-screen visual editor for modifying ZodoLlama settings without editing JSON files.

**Features:**
```
┌───────────────────────────────────────┐
│     Configuration Editor              │
│  Tab to navigate, Ctrl+S to save     │
│                                       │
│  Provider Settings                    │
│  ┌─────────────────────────────────┐ │
│  │ Provider: [●] ollama [ ] lmstudio│ │
│  │ Ollama Host: http://localhost...│ │
│  └─────────────────────────────────┘ │
│                                       │
│  Features                             │
│  ┌─────────────────────────────────┐ │
│  │ Extended Thinking: [✓] ON       │ │
│  │ Graph RAG: [✓] ON               │ │
│  └─────────────────────────────────┘ │
│                                       │
│  [Ctrl+S] Save  [Esc] Cancel         │
└───────────────────────────────────────┘
```

**How to use:**
1. Type `/config` and press Enter
2. Navigate with `Tab` or arrow keys
3. Edit fields with `Enter`
4. Press `Ctrl+S` to save or `Esc` to cancel

**Keybindings:**
| Key | Action |
|-----|--------|
| `Tab` / `↑↓` | Navigate fields |
| `Enter` | Edit/toggle field |
| `Space` | Toggle checkboxes |
| `←` / `→` | Cycle radio buttons |
| `Ctrl+S` | Save and close |
| `Esc` | Cancel (discard changes) |

**Benefits:**
- No JSON syntax errors
- Visual feedback for all settings
- Provider-specific warnings
- Safe: changes only apply when saved

See [Configuration Guide](configuration.md#interactive-config-editor) for details.

### Input Handling

**Chat input:**
- Type message
- Press `Enter` to send
- Press `Escape` to clear input
- Multi-line support (press Enter in middle of text)

**Special commands:**
- `/config` + Enter: Open configuration editor
- `/toggle-toolcall-json` + Enter: Show/hide tool JSON
- `/quit` + Enter: Exit application

### Keyboard Shortcuts

| Key | Function |
|-----|----------|
| `Enter` | Send message |
| `Escape` | Clear input |
| `/quit` + `Enter` | Quit application |
| `Ctrl+O` | Toggle thinking block at cursor |
| Mouse wheel | Scroll messages |

### Colors and Themes

**Default color scheme:**
- Status bar: Yellow
- Links: Cyan
- Thinking headers: Cyan
- Thinking content: Dim
- Inline code background: Grey

**Customization:**
See [Configuration Guide](configuration.md#color-settings) for color options.

## Advanced Features

### Structured Tool Results

All tools return JSON with:
- Success/failure status
- Error type categorization (7 types)
- Execution metadata (time, data size, timestamp)
- Error messages when applicable

**Benefits:**
- AI can detect and handle errors programmatically
- Better error recovery strategies
- Performance tracking
- Transparent debugging

**Example:**
```json
{
  "success": true,
  "data": "file contents...",
  "error_type": "none",
  "metadata": {
    "execution_time_ms": 3,
    "data_size_bytes": 1234,
    "timestamp": 1705680000000
  }
}
```

### Non-blocking Tool Execution

**What it does:** Tools execute automatically without requiring user input.

**Behavior:**
- Tool execution happens in background
- Results appear in real-time
- No keypress needed to trigger execution
- UI remains responsive

### GraphRAG Context Compression

**What it does:** Automatically builds knowledge graphs of files you read, then uses them to compress conversation history while preserving semantic meaning.

**How it works:**

**Two-loop architecture:**
1. **Main loop** (fast): read_file returns immediately with full content, queues file for indexing
2. **Secondary loop** (background): After response completes, LLM analyzes queued files to build knowledge graph

**Knowledge graph construction:**
- LLM runs 2-iteration agentic loop on each file:
  - Iteration 1: Extract entities (functions, structs, sections, concepts)
  - Iteration 2: Create relationships (calls, imports, references, relates_to)
- Generates embeddings for semantic search
- Stores in vector database (`.zodollama/graphrag.zvdb`)

**Context compression in action:**
```
Without GraphRAG (344 lines of config.zig in history):
  1→  pub const Config = struct {
  2→      model: []const u8 = "llama3.2",
  3→      ollama_host: []const u8 = "http://localhost:11434",
  ...
  344→  };

With GraphRAG (5 compact entity summaries):
  ### Config (struct) [public]
  Application configuration with model, server settings
  Relationships: imports ConfigFile, used_by loadConfigFromFile

  ### loadConfigFromFile (function) [public]
  Loads configuration from JSON file
  Relationships: returns Config, calls parseJson
  ...
```

**Benefits:**
- Reduces token usage by 90%+ on repeat file references
- Preserves semantic relationships between code entities
- Enables longer conversations without hitting context limits
- AI retains understanding of code structure

**Configuration:**
- Enable/disable: `graph_rag_enabled` in config
- Embedding model: `embedding_model` (default: embeddinggemma:300m)
- Indexing model: `indexing_model` (default: qwen3:30b)
- Summary size: `max_chunks_in_history` (default: 5 entities)

See [Configuration Guide](configuration.md#graphrag-settings) for details.

### Context Assembly

**What it does:** AI receives relevant context automatically.

**Implemented:**
- Tool results added to conversation history
- Task list injected before each iteration
- GraphRAG compresses file content into knowledge graphs
- Semantic retrieval of top-K relevant entities

## Performance

### Startup
- Cold start: < 100ms
- Config load: ~5ms
- Ready to chat immediately

### Streaming
- Latency: < 50ms per chunk
- Render time: < 10ms per message
- Scroll performance: 60 FPS

### Memory
- Base footprint: ~20MB
- Grows with conversation history
- Efficient markdown parsing (arena allocators)

## Platform Support

**Tested:**
- Linux x86_64 (Arch, Ubuntu, Fedora)

**Should work:**
- Other Linux distributions
- macOS (Intel and Apple Silicon)

**Not supported:**
- Windows (terminal API differences)

## Limitations

### Current Limitations

**File access:**
- Limited to 10MB per file
- Write operations require permission approval
- No directory traversal restrictions (future)

**Models:**
- Requires tool calling support
- Works with Llama 3.1+, Qwen 2.5+, Mistral, etc.
- Older models may not support tools

**Persistence:**
- Tasks are session-ephemeral (lost on quit)
- Conversation history not saved
- Only policies persist

### Planned Features

**Advanced File Operations:**
- Create directories
- Delete/rename files
- Batch operations

**Advanced Tools:**
- Execute commands (with safety)
- Git operations
- Test generation

## Tips and Tricks

### Getting Best Results

**Be specific:**
```
❌ "Tell me about the code"
✅ "How does markdown table rendering work?"
```

**Let AI use tools:**
```
❌ "Can you read ui.zig?"
✅ "What does ui.zig do?"
    [AI automatically reads the file]
```

**Complex tasks:**
```
✅ "Refactor markdown.zig to separate concerns"
   [AI breaks down, creates tasks, executes step by step]
```

### Performance Tips

**For large codebases:**
- Let AI search before reading files
- Use task management for complex requests
- Grant session permissions to avoid repeated prompts

**For better responses:**
- Use models with tool calling support
- Enable thinking blocks (shows reasoning)
- Ask follow-up questions for clarification

## Troubleshooting

See [Installation Guide](installation.md#troubleshooting) for:
- Build errors
- Runtime errors
- Connection issues
- Terminal rendering problems

## See Also

- [Configuration Guide](configuration.md) - Customize ZodoLlama
- [Installation Guide](installation.md) - Setup and building
- [Architecture Documentation](../architecture/overview.md) - How it works
