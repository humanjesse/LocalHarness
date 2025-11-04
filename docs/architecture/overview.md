# Local Harness Architecture Overview

## Introduction

Local Harness is a fast, lightweight terminal chat interface for local LLMs (Ollama, LM Studio) written in Zig. This document provides a high-level overview of the system architecture.

## Core Design Principles

1. **Performance**: Non-blocking UI, efficient rendering, minimal overhead
2. **Simplicity**: Clean codebase, modular design, easy to understand
3. **Extensibility**: Plugin-style tool system, configurable components
4. **Safety**: Permission system, memory safety via Zig, error handling

## System Architecture

```
┌──────────────────────────────────────────────────────────┐
│                         User                             │
└────────────────────┬─────────────────────────────────────┘
                     │
                     ↓
        ┌────────────────────────────┐
        │   Terminal UI (ui.zig)     │
        │  • Input handling          │
        │  • Mouse support           │
        │  • Scrolling               │
        │  • Taskbar                 │
        └────────────┬───────────────┘
                     │
                     ↓
        ┌────────────────────────────┐
        │   App Core (app.zig)       │
        │  • Event loop              │
        │  • Message history         │
        │  • Rendering logic         │
        │  • Tool execution          │
        └────────────┬───────────────┘
                     │
        ┌────────────┼────────────┐
        │            │            │
        ↓            ↓            ↓
┌──────────────┐ ┌────────┐ ┌──────────┐
│ Markdown     │ │ Ollama │ │ Tools    │
│ Renderer     │ │ Client │ │ System   │
│              │ │        │ │          │
│ • Parser     │ │ • Chat │ │ • Def    │
│ • Lexer      │ │ • Tool │ │ • Exec   │
│ • Render     │ │   Call │ │ • Perm   │
└──────────────┘ └────┬───┘ └────┬─────┘
                      │          │
                      ↓          ↓
              ┌──────────────────────────┐
              │  Ollama Server           │
              │  (External)              │
              └──────────────────────────┘
```

## Component Breakdown

### 1. Entry Point (`main.zig`) - 56 lines
**Responsibilities:**
- Initialize configuration
- Create App instance
- Run event loop
- Handle graceful shutdown

### 2. Application Core (`app.zig`) - 2006 lines
**Responsibilities:**
- Central event loop coordination
- Message history management
- Streaming response handling
- Tool execution orchestration
- Master loop iteration control
- Task context injection
- Viewport and rendering management

**Key Structures:**
```zig
pub const App = struct {
    allocator: mem.Allocator,
    config: Config,
    messages: ArrayList(Message),
    streaming_active: bool,
    tool_executor: ToolExecutor,  // State machine for async tool execution
    tool_call_depth: usize,
    max_tool_depth: usize,
    state: AppState,  // Task management
    app_context: AppContext,  // Tool execution context
    permission_manager: PermissionManager,
    // ... UI state ...
};
```

### 3. Terminal UI (`ui.zig`) - 559 lines
**Responsibilities:**
- Raw terminal mode setup
- Input capture (keyboard, mouse)
- Mouse wheel scrolling
- Taskbar rendering
- Non-blocking input handling

**Key Functions:**
- `enableRawMode()` / `disableRawMode()`
- `readInput()` - Non-blocking input with timeout
- `handleMouseEvent()` - Mouse wheel and click handling
- `renderTaskbar()` - Status bar at bottom

### 4. Markdown Engine (`markdown.zig`) - 1502 lines
**Responsibilities:**
- Parse markdown into tokens
- Render formatted output
- Handle complex features:
  - Headers, emphasis, links
  - Code blocks, inline code
  - Lists (ordered/unordered)
  - Tables
  - Blockquotes
  - Emoji (including ZWJ sequences)

**Architecture:**
```
Raw Text → Lexer (lexer.zig) → Tokens → Parser → Rendered Output
```

### 5. Ollama Client (`ollama.zig`) - 423 lines
**Responsibilities:**
- HTTP communication with Ollama server
- Streaming response handling
- Tool call parsing
- JSON serialization/deserialization

**Key Functions:**
- `chatStream()` - Streaming chat API
- `parseStreamChunk()` - Parse NDJSON responses
- Tool call serialization

### 6. Tool System (`tools.zig`) - 643 lines
**Responsibilities:**
- Tool definition registry
- Structured tool result generation
- Execution dispatch

**Components:**
- Tool definitions (schema + metadata)
- `ToolResult` struct with error categorization
- Execution functions for each tool
- JSON formatting utilities

### 7. Permission System (`permission.zig`) - 684 lines
**Responsibilities:**
- Fine-grained access control
- User consent prompts
- Policy persistence
- Audit logging

**Permission Levels:**
- `safe`: Auto-approved (read-only, low risk)
- `medium`: Requires user approval
- `high`: Requires approval with warning

### 8. Tool Executor (`tool_executor.zig`) - 358 lines
**Responsibilities:**
- Async tool execution state machine
- Permission flow orchestration
- Iteration limit enforcement

**State Machine:**
```zig
pub const ToolExecutionState = enum {
    idle,              // No tools to execute
    evaluating_policy, // Checking permissions
    awaiting_permission, // Waiting for user
    executing,         // Tool being executed
    completed,         // Batch complete
};
```

**Command Pattern:**
- Returns `TickResult` actions to App
- App responds to: `show_permission_prompt`, `render_requested`, `iteration_complete`
- Non-blocking: tick() never blocks, just advances state

### 9. Supporting Modules

**`config.zig` (344 lines):**
- Configuration file management
- Policy storage
- Default settings

**`types.zig` (44 lines):**
- Shared message types
- Cross-module data structures

**`state.zig` (69 lines):**
- Session-ephemeral task tracking
- Task status management

**`context.zig` (18 lines):**
- Tool execution context definition
- Future graph RAG integration point

**`render.zig` (252 lines):**
- Text wrapping utilities
- Formatting helpers
- Width calculation

**`tree.zig` (365 lines):**
- File tree generation
- Directory traversal

**`lexer.zig` (194 lines):**
- Markdown tokenization
- Character-level parsing

## Data Flow

### Message Flow

```
User Input
   ↓
App.handleUserInput()
   ↓
Add to message history
   ↓
Start streaming thread
   ↓
Ollama API call (with tools)
   ↓
Stream response chunks
   ↓
Parse markdown incrementally
   ↓
Render to viewport
   ↓
Tool calls detected?
   ├─ Yes → Execute tools → Add results → Continue streaming
   └─ No → Stream complete
```

### Tool Execution Flow (State Machine)

```
Model requests tool calls (streaming done)
   ↓
tool_executor.startExecution(calls)
   ↓
┌─────────────────────────────────────────┐
│  ToolExecutor State Machine (tick())   │
│                                         │
│  idle → evaluating_policy               │
│          ↓                              │
│         Check metadata & validate args  │
│          ↓                              │
│         Evaluate permission policy      │
│          ↓                              │
│    ┌────┴────┐                          │
│    │ Allowed? │                         │
│    └─┬────┬──┘                          │
│   Yes│    │No (ask_user)                │
│      │    ↓                             │
│      │  awaiting_permission             │
│      │    ↓                             │
│      │  [User responds]                 │
│      │    ↓                             │
│      └──→ executing                     │
│            ↓                            │
│       [App executes tool]               │
│            ↓                            │
│       Next tool (loop)                  │
│            ↓                            │
│         completed                       │
│            ↓                            │
│    Check iteration limit                │
│    ┌──────┴──────┐                      │
│    │ < max_iter? │                      │
│    └─┬─────────┬─┘                      │
│   Yes│         │No                      │
│      ↓         ↓                        │
│  Continue   Stop                        │
└─────────────────────────────────────────┘
   ↓
Auto-continue streaming (next iteration)
```

**State Machine Benefits:**
- Non-blocking: tick() returns immediately
- Clear state: Always know where we are in execution
- Separation: Permission logic isolated from App
- Testable: State transitions can be unit tested

## Threading Model

### Main Thread
- UI rendering
- Input handling
- Message processing
- Tool execution (Phase 1)

### Streaming Thread
- Ollama API communication
- Response chunk parsing
- Tool call detection
- Thread-safe chunk queue

**Synchronization:**
- Mutex-protected chunk queue
- Event-driven UI updates
- Non-blocking input with timeout

## Memory Management

### Allocator Usage

1. **General Purpose Allocator**: Main app allocations
2. **Arena Allocators**: Markdown parsing (per-message)
3. **Thread-safe Allocations**: Streaming chunk queue

### Ownership Model

- **Messages**: Owned by App, freed on history clear
- **Markdown Tokens**: Arena-allocated, freed after rendering
- **Tool Results**: Owned by message history
- **Config/Policies**: Persistent, freed on app exit

## State Management

### App State (Ephemeral)
```zig
pub const AppState = struct {
    tasks: ArrayListUnmanaged(Task),
    next_task_id: usize,
    session_start: i64,
    iteration_count: usize,
};
```

### Persistent State
- Configuration: `~/.config/localharness/config.json`
- Permissions: `~/.config/localharness/policies.json`

## Rendering Pipeline

```
Markdown Text
   ↓
Lexer (tokenize)
   ↓
Parser (structure)
   ↓
Viewport calculation
   ↓
Text wrapping
   ↓
ANSI escape codes
   ↓
Terminal output
```

### Viewport Management

**Receipt Printer Scroll:**
- Auto-follows streaming content (like a receipt printer)
- Cursor tracks newest content continuously
- Manual scroll pauses auto-scroll
- Auto-scroll resumes on next message

**State Tracking:**
- `viewport_start`: First visible line
- `cursor_line`: Current cursor position
- `user_scrolled_away`: Manual scroll detection flag

## Master Loop Architecture

The master loop enables agentic behavior by iterating until task completion.

**Algorithm:**
```
1. Add user message to history
2. Loop (max 10 iterations):
   a. Call Ollama API with message history + tools
   b. Collect response (content + tool_calls)
   c. Add assistant message to history
   d. If no tool_calls → break (task complete)
   e. For each tool_call:
      - Execute tool (with permission check)
      - Add result to history
      - Inject task context (if tasks exist)
   f. Continue loop
3. Return control to UI
```

**Safety Limits:**
- Max 10 iterations per user message
- Max 15 tool calls per iteration
- Resets on new user message

## Context Management & Compression Architecture (Implemented)

**Integrated System for Token Management**

Local Harness implements a unified context management system that tracks file usage, caches agent results, and automatically compresses conversation history when needed.

### System Design

```
MAIN LOOP with Integrated Context Management:
User question → [Hot Context Injection] → LLM → Tool calls → Response
                         ↓                                ↓
                  ContextTracker                    read_file
                  (file tracking,                   (curator agent
                   curator cache)                    with caching)
                         ↓
                  [Check token usage]
                         ↓ (if >70%)
                  Compression Agent
                  (compress old messages,
                   preserve last 5 pairs)
```

**Key Benefits:**
- Single integrated system (no secondary loop complexity)
- File curator caching: 50-100x speedup on repeated reads
- Intelligent compression: LLM-based summarization, not truncation
- Hot context injection: Automatic workflow awareness before every LLM call
- Protected messages: Recent work never compressed (last 5 user+assistant pairs)

**Components:**
- **ContextTracker** (`context_management/tracking.zig`): Tracks files, modifications, todos with hash-based invalidation
- **File Curator Cache** (`context_management/tracking.zig`): Caches curator results per conversation context
- **Compression Agent** (`agents_hardcoded/compression_agent.zig`): Runs when token usage hits 70% threshold
- **Compression Tools** (4 specialized tools): `get_compression_metadata`, `compress_tool_result`, `compress_conversation_segment`, `verify_compression_target`
- **Hot Context Injection** (`injection.zig`): Builds workflow context before each LLM call

**Compression Strategy:**
- Trigger: 70% token usage (56k/80k context)
- Target: 40% token usage (32k/80k context)
- Protected: Last 5 user+assistant message pairs
- Method: LLM-based compression (temperature 0.3) with graceful fallback to truncation

See [Context Management Documentation](context-management.md) and [Compression System Documentation](compression-system.md) for implementation details.

## Configuration Architecture

### Config Hierarchy
1. Default values (hardcoded)
2. Config file (`~/.config/localharness/config.json`)
3. CLI arguments (override file settings)

### Configurable Components
- Model selection
- Ollama server URL
- UI colors
- Scroll behavior
- Editor command

## Error Handling

### Levels
1. **User-facing errors**: Displayed as messages
2. **Tool errors**: Returned to model as structured results
3. **Internal errors**: Logged, graceful degradation
4. **Fatal errors**: Clean shutdown

### Strategy
- Permission denials → Added to history (model can adapt)
- Tool execution failures → Structured error result
- Network errors → Retry with backoff
- Parse errors → Skip malformed data, continue

## Performance Characteristics

### Startup Time
- Cold start: < 100ms
- Config load: ~5ms
- First render: < 50ms

### Runtime
- Streaming latency: < 50ms per chunk
- Markdown render: < 10ms for typical message
- Scroll performance: 60 FPS
- Memory footprint: ~20MB base + message history

### Scalability
- Message history: Grows with conversation
- Markdown complexity: O(n) where n = message length
- Tool execution: Depends on tool (file I/O bound)

## Security Model

### Trust Boundaries
1. **User Input**: Trusted (user controls terminal)
2. **Model Output**: Untrusted (requires rendering safety)
3. **Tool Execution**: Gated by permission system
4. **File Access**: Restricted to project directory (future)

### Protections
- Permission system for all tool calls
- No arbitrary command execution (yet)
- Markdown rendering doesn't execute code
- Memory safety via Zig

## Testing Strategy

### Current
- Manual testing during development
- Build-time type checking (Zig compiler)

### Future
- Unit tests for core components
- Integration tests for tool system
- End-to-end tests for user flows

## See Also

- [Tool Calling System](tool-calling.md)
- [Task Management](task-management.md)
- [Master Loop Analysis](../LOOP_ANALYSIS.md)
