# Tool Calling System

## Overview

Local Harness implements a comprehensive tool calling system that allows the AI model to interact with the local environment through defined tools. This enables agentic behavior where the model can autonomously gather context, read files, manage tasks, and more.

## Architecture

### Components

1. **Tool Definitions** (`tools.zig`) - Schema and execution logic
2. **Permission System** (`permission.zig`) - Fine-grained access control
3. **Tool Execution Context** (`context.zig`) - Shared state and resources
4. **Structured Results** - JSON responses with error categorization

### Data Flow

```
User Query
   ↓
Model Response (with tool_calls)
   ↓
Permission Check
   ↓
Tool Execution
   ↓
Structured Result (JSON)
   ↓
Add to Conversation History
   ↓
Continue Streaming (auto-continuation)
   ↓
Model Processes Results → Final Answer
```

## Available Tools

### File System Tools

#### `get_file_tree`
- **Description:** Generate file tree of current directory (recursive)
- **Permission:** Auto-approved (safe, read-only)
- **Returns:** JSON array of file paths
- **Use Case:** Understanding project structure

#### `ls`
- **Description:** List contents of a single directory with detailed metadata
- **Permission:** Auto-approved (low risk, read-only)
- **Parameters:**
  - `path` (string, optional): Directory to list (default: ".")
  - `show_hidden` (boolean, optional): Include hidden files/directories (default: false)
  - `sort_by` (string, optional): Sort by "name", "size", or "modified" (default: "name")
  - `reverse` (boolean, optional): Reverse sort order (default: false)
  - `max_entries` (integer, optional): Max entries to return (default: 500, max: 1000)
- **Returns:** Formatted table with file type, size (human-readable), modified timestamp, and name
- **Features:**
  - Non-recursive (single directory only)
  - Rich metadata: type (FILE/DIR/LINK), size in KB/MB/GB, timestamps
  - Flexible sorting options
  - Directories shown with trailing `/`
  - Summary statistics (total files, dirs, total size)
- **Error Types:** `not_found`, `validation_failed`, `io_error`
- **Security:** Blocks absolute paths and directory traversal
- **Use Case:** Quick directory inspection, finding large files, checking timestamps
- **Example:** `{"path": "tools", "sort_by": "size", "reverse": true}`

#### `read_file`
- **Description:** Read file contents with smart context optimization using file curator agent
- **Permission:** Requires user approval (medium risk)
- **Parameters:**
  - `path` (string): File path relative to project root
- **Returns:** File contents with line numbers (max 10MB)
- **Output Format:** `1: line content\n2: line content...`
- **Error Types:** `not_found`, `io_error`, `parse_error`
- **Smart Features:**
  - Small files (<100 lines): Full content returned instantly
  - Larger files: File curator agent analyzes and returns relevant sections based on conversation context
  - Curator results cached per conversation context for 50-100x speedup on repeated reads
  - Cache invalidation: File hash change or conversation context change triggers re-curation
- **Performance:** First read may take longer for large files (curator analysis), subsequent reads use cached results

#### `write_file`
- **Description:** Create or overwrite a file with content
- **Permission:** Requires user approval (high risk)
- **Parameters:**
  - `path` (string): File path relative to project root
  - `content` (string): File content to write
- **Returns:** Confirmation message with file size
- **Error Types:** `validation_failed`, `io_error`
- **Security:** Blocks absolute paths and directory traversal

#### `replace_lines`
- **Description:** Replace specific line ranges in existing files using 1-indexed line numbers
- **Permission:** Requires user approval (high risk)
- **Parameters:**
  - `path` (string): File path relative to project root
  - `line_start` (integer): First line to replace (1-indexed)
  - `line_end` (integer): Last line to replace (inclusive, 1-indexed)
  - `new_content` (string): Replacement content
- **Returns:** Confirmation with lines replaced count
- **Error Types:** `not_found`, `validation_failed`, `io_error`
- **Workflow:** First call `read_file` to see line numbers, then call `replace_lines`
- **Security:** Blocks absolute paths and directory traversal

#### `insert_lines`
- **Description:** Insert new content before a specific line in existing files using 1-indexed line numbers
- **Permission:** Requires user approval (high risk)
- **Parameters:**
  - `path` (string): File path relative to project root
  - `line_start` (integer): Line number to insert before (1-indexed). Use N+1 to append to end.
  - `line_end` (integer): Must equal `line_start` (enforces single insertion point)
  - `new_content` (string): Content to insert (can contain newlines for multiple lines)
- **Returns:** Confirmation with insertion location
- **Error Types:** `not_found`, `validation_failed`, `io_error`
- **Workflow:** First call `read_file` to see line numbers, then call `insert_lines`
- **Security:** Blocks absolute paths and directory traversal
- **Preview:** Shows context lines before/after insertion point with diff-style formatting

#### `grep_search`
- **Description:** Search files for text patterns with flexible options
- **Permission:** Ask once per session (low risk)
- **Parameters:**
  - `pattern` (string, required): Text to search for (supports `*` wildcards, e.g., `fn*init`)
  - `file_filter` (string, optional): Limit to files matching glob (e.g., `*.zig`, `**/*.md`)
  - `max_results` (integer, optional): Max results to return (default: 200, max: 1000)
  - `include_hidden` (boolean, optional): Search hidden directories like `.config` (default: false, always skips `.git`)
  - `ignore_gitignore` (boolean, optional): Search files normally excluded by `.gitignore` (default: false)
- **Returns:** Formatted search results with file paths, line numbers, and matching lines
- **Features:**
  - Case-insensitive by default
  - Wildcard matching as grep-like substring search
  - Respects `.gitignore` by default (can be bypassed)
  - Always skips `.git`, `.hg`, `.svn`, `.bzr` directories
  - Binary file detection and skipping
  - Output shows active flags: `[+hidden]`, `[+gitignored]`
- **Error Types:** `validation_failed`, `io_error`, `parse_error`
- **Use Case:** Finding code patterns, exploring unfamiliar codebases, locating specific functionality
- **Example:** `{"pattern": "fn*init", "file_filter": "*.zig", "max_results": 50}`

### System Tools

#### `get_current_time`
- **Description:** Get current date and time
- **Permission:** Auto-approved (safe)
- **Returns:** ISO 8601 formatted timestamp
- **Use Case:** Time-aware responses, timestamps

#### `get_working_directory`
- **Description:** Get current working directory path
- **Permission:** Auto-approved (safe)
- **Returns:** Absolute path of current working directory
- **Use Case:** Understanding filesystem location, providing context for file operations

### Task Management Tools

#### `add_task`
- **Description:** Add a new task to track progress
- **Permission:** Auto-approved (safe)
- **Parameters:**
  - `content` (string): Task description
- **Returns:** Task ID (e.g., `"task_1"`)
- **Use Case:** Breaking down complex requests into trackable steps

#### `list_tasks`
- **Description:** View all current tasks with their status
- **Permission:** Auto-approved (safe)
- **Returns:** Array of tasks with IDs, status, and content
- **Use Case:** Checking progress, reviewing task list

#### `update_task`
- **Description:** Update task status
- **Permission:** Auto-approved (safe)
- **Parameters:**
  - `task_id` (string): Task identifier (e.g., `"task_1"`)
  - `status` (enum): `"pending"`, `"in_progress"`, or `"completed"`
- **Returns:** Confirmation message
- **Error Types:** `not_found`, `validation_failed`

## Structured Tool Results

As of 2025-01-19, all tools return structured `ToolResult` objects instead of plain strings.

### ToolResult Structure

```zig
pub const ToolResult = struct {
    success: bool,
    data: ?[]const u8,
    error_message: ?[]const u8,
    error_type: ToolErrorType,
    metadata: struct {
        execution_time_ms: i64,
        data_size_bytes: usize,
        timestamp: i64,
    },
};
```

### Error Types

```zig
pub const ToolErrorType = enum {
    none,              // Success
    not_found,         // File/task not found
    validation_failed, // Invalid arguments
    permission_denied, // Permission system denial
    io_error,          // File system errors
    parse_error,       // JSON parsing errors
    internal_error,    // Runtime/unexpected errors
};
```

### JSON Output Format

**Success:**
```json
{
  "success": true,
  "data": "file contents here...",
  "error_message": null,
  "error_type": "none",
  "metadata": {
    "execution_time_ms": 3,
    "data_size_bytes": 1234,
    "timestamp": 1705680000000
  }
}
```

**Error:**
```json
{
  "success": false,
  "data": null,
  "error_message": "File not found: config.txt",
  "error_type": "not_found",
  "metadata": {
    "execution_time_ms": 2,
    "data_size_bytes": 0,
    "timestamp": 1705680000000
  }
}
```

### Benefits

✅ Machine-readable errors - Model can detect failures programmatically
✅ Error categorization - Different handling for different error types
✅ Execution metrics - Track performance and data sizes
✅ Type safety - Structured data instead of string parsing
✅ Better debugging - Clear error types and timing information

## Permission System Integration

### How It Works

When the AI requests a tool, the permission system evaluates:

1. **Tool Risk Level:**
   - `safe`: Auto-approved (get_file_tree, get_current_time, task tools)
   - `medium`: Requires approval (read_file)
   - `high`: Requires approval with warning (write_file, replace_lines)

2. **User Decision:**
   - **Allow Once**: Execute this tool call only (one-time)
   - **Session**: Allow for this session (until you quit)
   - **Remember**: Always allow (saved to `~/.config/localharness/policies.json`)
   - **Deny**: Block this tool call

3. **Permission Prompt Example:**
```
⚠️  Permission Request

Tool: read_file
Arguments: {"path": "README.md"}
Risk: MEDIUM

[1] Allow Once  [2] Session  [3] Remember  [4] Deny
```

### Policy Storage

Policies are saved in `~/.config/localharness/policies.json` and persist across sessions.

## Tool Executor State Machine

As of 2025-01-20, tool execution uses a dedicated state machine (`tool_executor.zig`) to manage the async execution flow. This replaces the previous inline execution approach.

### Architecture

```
┌──────────────────────────────────────────┐
│         TOOL EXECUTOR (State Machine)    │
│  ┌────────────────────────────────────┐  │
│  │ States:                            │  │
│  │  idle                              │  │
│  │    ↓                               │  │
│  │  evaluating_policy                 │  │
│  │    ↓                               │  │
│  │  awaiting_permission (if needed)   │  │
│  │    ↓                               │  │
│  │  executing                         │  │
│  │    ↓                               │  │
│  │  completed                         │  │
│  └────────────────────────────────────┘  │
│                                          │
│  tick() returns TickResult:              │
│   • no_action                            │
│   • show_permission_prompt               │
│   • render_requested                     │
│   • iteration_complete                   │
│   • iteration_limit_reached              │
└──────────────────────────────────────────┘
                   ↓
         ┌─────────────────┐
         │   APP (Handler) │
         │  - Shows prompts│
         │  - Executes tools│
         │  - Renders UI   │
         └─────────────────┘
```

### How It Works

**Main Loop in app.zig:**
```zig
if (tool_executor.hasPendingWork()) {
    // Forward user's permission response if any
    if (permission_response) |resp| {
        tool_executor.setPermissionResponse(resp);
    }

    // Advance the state machine
    const action = try tool_executor.tick(perm_manager, ...);

    // React to what it tells us to do
    switch (action) {
        .show_permission_prompt => { /* Show UI prompt */ },
        .render_requested => { /* Execute current tool */ },
        .iteration_complete => { /* Start next AI response */ },
        .iteration_limit_reached => { /* Stop, max iterations */ },
        .no_action => { /* Waiting for user input */ },
    }
}
```

### Benefits

| Aspect | Old Approach | New State Machine |
|--------|--------------|-------------------|
| **State** | Implicit (check if null) | Explicit enum |
| **Control Flow** | 440 lines of nested logic | 5 clear states |
| **Blocking** | Loop-based execution | tick() returns immediately |
| **Separation** | Everything in app.zig | Logic in tool_executor |
| **Testability** | Hard to test | State transitions testable |
| **Readability** | Complex nested ifs | Clear state transitions |

### State Transitions

1. **idle** → User does nothing, no tools pending
2. **evaluating_policy** → Checking metadata, validating args, evaluating permissions
3. **awaiting_permission** → User must approve/deny (UI shows prompt)
4. **executing** → Tool is running (handled by App)
5. **completed** → All tools done, check iteration limit

### Key Design Patterns

**Command Pattern:**
- State machine doesn't execute tools directly
- Instead, it **tells App what to do** via TickResult
- App handles UI-specific concerns (prompts, rendering, actual execution)

**Non-Blocking:**
- `tick()` never blocks
- Just advances state and returns an action
- Main loop continues processing input even during tool execution

**Memory Safety:**
- Ownership is clear: tool_executor owns tool_calls until completed
- `eval_result.reason` is **not freed** (string literals from PolicyEngine)
- Prevents double-free bugs

## Multi-Turn Tool Calling

### The Challenge

Initially, the model could request tools, but results weren't fed back for processing. This broke the agentic flow.

### The Solution

Local Harness implements proper multi-turn conversation support:

1. **Model requests tools** → Stored in assistant message with `tool_calls` field
2. **Execute tools** → Generate structured `ToolResult`
3. **Create TWO messages for each tool:**
   - **Display message** (system role): Shows user what happened with execution metrics
   - **API message** (tool role): Proper format for model consumption (JSON)
4. **Auto-continuation** → Automatically stream next response
5. **Model processes results** → Provides informed final answer

### Message History Example

After a successful tool call:

```
1. user: "What files are in this project?"

2. assistant: ""
   tool_calls: [{id: "call_1", function: {name: "get_file_tree", ...}}]

3. system: "[Tool: get_file_tree]
            Status: ✅ SUCCESS
            Result: [file list...]
            Execution Time: 5ms"

4. tool: "{\"success\": true, \"data\": \"[...]\", ...}"
   tool_call_id: "call_1"

5. assistant: "Based on the file list, this project contains..."
```

## Tool Context Pattern

All tools receive an `AppContext` parameter providing access to shared resources:

```zig
pub const ToolExecuteFn = *const fn (
    allocator: std.mem.Allocator,
    arguments: []const u8,
    context: *AppContext,
) anyerror!ToolResult;

pub const AppContext = struct {
    allocator: std.mem.Allocator,
    config: *const Config,
    state: ?*AppState,           // Task management state
    graph: ?*ContextGraph,        // Code graph (future)
    vector_store: ?*VectorStore,  // Embeddings (future)
    embedder: ?*EmbeddingsClient, // Embedding generator (future)
    parser: ?*CodeParser,         // AST parser (future)
};
```

This pattern enables:
- Clean, explicit dependencies
- Thread-safe by design
- Easy to test (can mock context)
- Scales as features are added

## Tool Call Limits

Local Harness implements a two-level protection system:

### Level 1: Tool Call Depth (Per Iteration)
- **Max:** 15 tool calls per iteration
- **Purpose:** Prevent model from calling tools forever in one iteration
- **Resets:** After each master loop iteration

### Level 2: Master Loop Iterations
- **Max:** 10 iterations per user message
- **Purpose:** Prevent infinite iteration loops
- **Resets:** When user sends new message

## Implementation Details

### Ollama API Format

Tools are sent to Ollama in OpenAI-compatible format:

```json
{
  "model": "llama3.2",
  "messages": [...],
  "stream": true,
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "read_file",
        "description": "Read a file's contents",
        "parameters": {
          "type": "object",
          "properties": {
            "path": {"type": "string", "description": "File path"}
          },
          "required": ["path"]
        }
      }
    }
  ]
}
```

### Response Format

When the model wants to call a tool:

```json
{
  "message": {
    "role": "assistant",
    "content": "",
    "tool_calls": [
      {
        "id": "call_abc123",
        "type": "function",
        "function": {
          "name": "read_file",
          "arguments": "{\"path\": \"main.zig\"}"
        }
      }
    ]
  }
}
```

### Arguments Parsing

Ollama's tool calling format differs slightly from OpenAI:

**Ollama sends:**
```json
"arguments": {"path": "file.txt", "line_start": 1}  // JSON object
```

**OpenAI sends:**
```json
"arguments": "{\"path\": \"file.txt\", \"line_start\": 1}"  // JSON string
```

Local Harness handles both formats by:
1. Parsing with flexible `std.json.Value` type
2. Converting objects to JSON strings with proper type handling:
   - `.string` → Quoted string values
   - `.integer` → Numeric values (e.g., `1`, `42`)
   - `.number_string` → Pass-through numeric strings
   - `.bool` → `true` or `false`
   - `.null` → `null`
3. Generating missing `id` and `type` fields if absent

## Model Compatibility

Tool calling works with:

✅ **Supported:**
- gpt-oss-120b
- Llama 3.1+ models
- Qwen 2.5+ models
- Mistral models with function calling support
- Command R+ models

❌ **Not Supported:**
- Older Llama models (< 3.1)
- Basic models without function calling capability

## Example Use Cases

### 1. Code Analysis
```
User: "Tell me about this project"

AI: [Calls get_file_tree]
    I can see this is a Zig project with these main files:
    - main.zig - Entry point
    - ui.zig - Terminal UI
    - ollama.zig - API client
    ...

User: "Show me the main function"

AI: [Calls read_file with path="main.zig"]
    Here's the main function: [shows code from main.zig]
```

### 2. Multi-Step Task Breakdown
```
User: "Refactor markdown.zig to be more modular"

AI: [add_task "Analyze current structure"]
    [add_task "Design module boundaries"]
    [add_task "Propose changes"]
    [read_file "markdown.zig"]
    [update_task "task_1" "completed"]

    I've analyzed the structure. Here's my refactoring plan...
```

## Tips for Model Prompting

To encourage effective tool use:

1. **Clear descriptions**: Write detailed function descriptions
2. **Proper schema**: Follow JSON Schema format for parameters
3. **Security awareness**: Be careful with tools that execute code or access files
4. **Error handling**: Implement proper error handling in tool execution
5. **System prompt**: Guide the model on when to use tools

## Legacy `/context` Command

The old `/context` command is now superseded by the automatic `get_file_tree` tool but remains for backward compatibility.

## Historical Notes

For implementation history and troubleshooting details, see:
- [Tool Calling Fixes](../archive/tool-calling-fixes.md) - Fix documentation
- [Tool Calling Actual Fix](../archive/tool-calling-actual-fix.md) - The real fix details
- [Before/After Flow](../archive/before-after-flow.md) - Flow comparison

## See Also

- [Task Management Architecture](task-management.md) - Scratch space system
