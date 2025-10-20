# Tool Calling System

## Overview

ZodoLlama implements a comprehensive tool calling system that allows the AI model to interact with the local environment through defined tools. This enables agentic behavior where the model can autonomously gather context, read files, manage tasks, and more.

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
- **Description:** Generate file tree of current directory
- **Permission:** Auto-approved (safe, read-only)
- **Returns:** JSON array of file paths
- **Use Case:** Understanding project structure

#### `read_file`
- **Description:** Read file contents
- **Permission:** Requires user approval (medium risk)
- **Parameters:**
  - `path` (string): File path relative to project root
- **Returns:** File contents (max 10MB)
- **Error Types:** `not_found`, `io_error`, `parse_error`
- **Side Effect:** Triggers AST parsing and graph indexing (when graph RAG is enabled)

### System Tools

#### `get_current_time`
- **Description:** Get current date and time
- **Permission:** Auto-approved (safe)
- **Returns:** ISO 8601 formatted timestamp
- **Use Case:** Time-aware responses, timestamps

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
   - `high`: Requires approval with warning (future: write_file, execute_command)

2. **User Decision:**
   - **Allow Once**: Execute this tool call only (one-time)
   - **Session**: Allow for this session (until you quit)
   - **Remember**: Always allow (saved to `~/.config/zodollama/policies.json`)
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

Policies are saved in `~/.config/zodollama/policies.json` and persist across sessions.

## Multi-Turn Tool Calling

### The Challenge

Initially, the model could request tools, but results weren't fed back for processing. This broke the agentic flow.

### The Solution

ZodoLlama implements proper multi-turn conversation support:

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

ZodoLlama implements a two-level protection system:

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
"arguments": {}  // JSON object
```

**OpenAI sends:**
```json
"arguments": "{}"  // JSON string
```

ZodoLlama handles both formats by:
1. Parsing with flexible `std.json.Value` type
2. Converting objects to JSON strings when needed
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
- [Master Loop & Graph RAG](master-loop-graphrag.md) - Agentic behavior
