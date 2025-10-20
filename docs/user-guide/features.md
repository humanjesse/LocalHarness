# Features Guide

Complete guide to all ZodoLlama features and capabilities.

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
- **get_file_tree**: List all files in project
- **read_file**: Read specific file contents

#### System
- **get_current_time**: Get current date/time

#### Task Management
- **add_task**: Create a new task
- **list_tasks**: View all tasks
- **update_task**: Update task status

**Example conversation:**
```
You: "What files are in this project?"
AI: [Automatically calls get_file_tree]
    This project contains:
    - main.zig
    - ui.zig
    - ollama.zig
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

### Input Handling

**Chat input:**
- Type message
- Press `Enter` to send
- Press `Escape` to clear input
- Multi-line support (press Enter in middle of text)

**Special commands:**
- `/quit` + Enter: Exit application
- `/context`: Manual file tree (legacy, use tool calling instead)

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

### Context Assembly

**What it does:** AI receives relevant context automatically.

**Current:**
- Tool results added to conversation history
- Task list injected before each iteration
- Model sees full conversation context

**Future (Graph RAG):**
- Code structure understanding
- Semantic search
- Smart context retrieval

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
- Read-only (no write operations yet)
- Limited to 10MB per file
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

**Graph RAG (In Development):**
- Code graph construction
- Semantic code search
- Relationship understanding
- Context-aware responses

**File Operations:**
- Write files
- Edit code
- Create directories

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
