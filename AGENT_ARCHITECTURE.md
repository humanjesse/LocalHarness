# Agent Architecture

## Overview

Local Harness now has a unified agent system for running isolated LLM sub-tasks. Agents are self-contained execution units with controlled resource access, separate message histories, and capability-based security.

## Core Components

### 1. `agents.zig` - Core Abstractions

Defines the fundamental agent system types:

- **`AgentDefinition`**: Blueprint for an agent (name, description, system prompt, capabilities, execute function)
- **`AgentCapabilities`**: Resource limits and permissions (allowed tools, max iterations, model override, temperature, etc.)
- **`AgentContext`**: Execution context provided to agents (allocator, ollama_client, config, optional vector store/embedder)
- **`AgentResult`**: Standardized result type (success, data, error_message, stats)
- **`AgentRegistry`**: Lookup registry for finding agents by name
- **`ProgressCallback`**: Callback type for progress updates

### 2. `llm_helper.zig` - Unified LLM Invocation

Centralizes common LLM calling patterns:

- **`LLMRequest`**: Unified request structure for all LLM calls
- **`chatStream()`**: Wrapper for ollama.chatStream with consistent error handling
- **`parseJSONResponse<T>()`**: Robust JSON parsing with markdown fence stripping
- **`MessageBuilder`**: Helper for building message arrays
- **`filterTools()`**: Tool filtering based on capability constraints

### 3. `agent_executor.zig` - Agent Execution Engine

Runs agents in isolation:

- **Isolated message history**: Each agent execution has its own conversation context
- **Tool execution**: Agents can call tools (filtered by capabilities)
- **Iteration loop**: Runs until completion or max iterations
- **Statistics tracking**: Iterations used, tool calls made, execution time
- **Streaming support**: Progress callbacks for UI updates

### 4. `agents/file_curator.zig` - First Concrete Agent

Analyzes files and curates important line ranges:

- **Purpose**: Reduce context usage by identifying only important lines
- **No tools**: Pure analysis agent (no tool calls needed)
- **JSON output**: Returns structured curation spec with line ranges
- **Capabilities**:
  - Max 2 iterations
  - Temperature 0.3 (consistent output)
  - 16k context window
  - No extended thinking

### 5. `tools/read_file_curated.zig` - Agent-Using Tool

First tool to leverage the agent system:

- **Reads file** → **Invokes file curator agent** → **Parses curation** → **Formats output**
- **Fallback**: Returns full file if curation fails
- **GraphRAG integration**: Still indexes FULL file content (not curated view)
- **Context efficiency**: Main conversation only sees curated ~30-50% of file

## Architecture Principles

### 1. Capability-Based Access Control

Agents declare exactly what they can do:

```zig
.capabilities = .{
    .allowed_tools = &.{"create_node", "create_edge"},  // Only these tools
    .max_iterations = 5,                                 // Hard limit
    .model_override = "qwen3:30b",                      // Different model
    .temperature = 0.3,                                  // Lower randomness
}
```

### 2. Isolated Execution

- Agents maintain separate message histories from main app
- No pollution of main conversation context
- Independent iteration counts
- Controlled resource access through AgentContext

### 3. Unified Invocation Pattern

All agents follow the same pattern:

```zig
const agent_def = try file_curator.getDefinition(allocator);
const agent_context = AgentContext{ /* ... */ };
const result = try agent_def.execute(allocator, agent_context, task, callback, user_data);
```

### 4. Separation of Concerns

```
Main App Loop (app.zig)
    ├─ Handles user conversation
    ├─ Manages permissions
    └─ Calls tools
         └─ Tools can invoke agents
              ├─ Agent runs in isolation
              ├─ Returns structured result
              └─ Main loop continues with agent output

GraphRAG Integration (app_graphrag.zig)
    ├─ Secondary loop for file indexing
    ├─ User choice prompts (full/lines/metadata)
    ├─ Progress callbacks for LLM indexing
    └─ Message history updates
```

### 5. Future-Proof Extension

Adding new agents is straightforward:

1. Create `agents/my_agent.zig`
2. Implement `getDefinition()` and `execute()`
3. Define capabilities
4. Use from tools or app logic

## Data Flow Example: read_file (with agent curation)

```
User: "How does error handling work in config.zig?"
  ↓
Main Loop: Calls read_file tool
  ↓
Tool: Reads file (1000 lines)
  ↓
Tool: Detects file > 100 lines → invoke file_curator agent
  ↓
Agent Executor: Runs isolated LLM session with conversation context
  ├─ Message history: [user task + conversation context]
  ├─ LLM sees: "User asked about error handling"
  ├─ LLM filters to error-related code only
  ├─ LLM returns JSON: {"line_ranges": [error types, handlers], "summary": "..."}
  └─ Returns AgentResult with JSON and thinking
  ↓
Tool: Parses curation JSON
  ↓
Tool: Formats curated output (200 lines preserved - error handling only!)
  ↓
Tool: Queues FULL file (1000 lines) for GraphRAG
  ↓
Main Loop: Receives curated view (200 relevant lines)
  ↓
Conversation context has only relevant sections, GraphRAG has full file!
```

## Variables/Functions Unified

### Before Agent System

- LLM calling scattered in `app.zig`, `llm_indexer.zig`, etc.
- Message history management duplicated
- No formal abstraction for sub-tasks
- Tool access control ad-hoc

### After Agent System

- ✅ **LLM calling**: Unified in `llm_helper.chatStream()`
- ✅ **JSON parsing**: Unified in `llm_helper.parseJSONResponse<T>()`
- ✅ **Message building**: Unified in `llm_helper.MessageBuilder`
- ✅ **Agent execution**: Unified in `agent_executor.AgentExecutor`
- ✅ **Tool filtering**: Unified in `llm_helper.filterTools()`
- ✅ **Progress callbacks**: Unified type in `agents.ProgressCallback`

## When to Use Agents vs Tools

### Use a Tool when:
- Direct action needed (read file, write file, grep)
- Single-step operation
- No LLM reasoning required

### Use an Agent when:
- Multi-step analysis needed
- LLM reasoning/synthesis required
- Need isolated context
- Want to use different model/temperature
- Task is composable (agent can be reused)

### Use an Agent-Using Tool when:
- Want agent analysis but triggered from main loop
- Need agent result formatted for conversation
- Want to integrate agent into existing tool ecosystem

## Current Agents

### file_curator
- **Purpose**: Analyze files and identify important line ranges based on conversation context
- **Input**: File path, content, and recent conversation messages
- **Output**: JSON with line ranges and summary (conversation-aware relevance filtering)
- **Use case**: Reduce context usage while preserving searchability - adapts naturally to file size
- **Capabilities**: No tools, 2 iterations max, temperature 0.3
- **Smart behavior**: Filters by relevance when conversation context is available, falls back to structural curation otherwise

## Future Agent Ideas

Based on the architecture, here are agents you could easily add:

### code_reviewer
- **Purpose**: Review code for bugs, style, best practices
- **Tools**: read_file, grep_search
- **Output**: Review report with suggestions

### test_generator
- **Purpose**: Generate unit tests for code
- **Tools**: read_file, write_file
- **Output**: Test files

### documentation_writer
- **Purpose**: Generate/update documentation
- **Tools**: read_file, write_file, file_tree
- **Output**: Markdown documentation

### refactorer
- **Purpose**: Suggest/apply refactorings
- **Tools**: read_file, replace_lines, grep_search
- **Output**: Refactored code or suggestions

### query_planner (GraphRAG)
- **Purpose**: Plan multi-step queries for knowledge graph
- **Tools**: GraphRAG query tools
- **Output**: Query execution plan

## Integration Points

### With GraphRAG
- Agents can access vector_store and embedder through AgentContext
- GraphRAG indexer could be refactored as an agent
- Query agents could orchestrate complex graph searches

### With Permission System
- Agents bypass permission checks (they're trusted internal code)
- Agent-using tools still go through permission system
- User approves tool, tool decides if agent is needed

### With Main Loop
- Agents don't block main loop (could run async in future)
- Agent results cleanly integrate as tool results
- No message history pollution

## Memory Management

All agent components follow Zig memory ownership patterns:

- **AgentResult**: Caller owns returned data, must call `deinit()`
- **AgentExecutor**: Owns message history, must call `deinit()`
- **Tool results**: Owned by caller, freed after use
- **Agent definitions**: Temporary allocations freed immediately

## Testing Strategy

To test the agent system:

1. **Unit test agents**: Call `execute()` directly with mock context
2. **Integration test tools**: Call tool that uses agent
3. **End-to-end test**: Run main app with agent-using tools

Example test flow:
```zig
// Unit test file_curator
const agent_def = try file_curator.getDefinition(allocator);
const result = try agent_def.execute(allocator, context, test_file_content, null, null);
// Verify result contains valid curation JSON

// Integration test read_file_curated
const tool_result = try read_file_curated.execute(allocator, "{\"path\":\"test.zig\"}", &app_context);
// Verify curated output and GraphRAG indexing
```

## Performance Considerations

### Context Savings
- **Before**: 1000-line file → 1000 lines in context
- **After**: 1000-line file → ~350 lines in context (65% reduction)
- **GraphRAG**: Still has full 1000 lines for search

### Agent Overhead
- **Additional LLM call**: ~1-3s per file read
- **Amortized**: Cost is per-file, not per-message
- **Benefit**: Reduces context for entire conversation

### Smart Auto-Detection
The read_file tool automatically detects the best approach:
- **Small files (≤100 lines)**: Full content, instant (no agent overhead)
- **Larger files (>100 lines)**: Conversation-aware curation via file_curator agent
- **For surgical reads**: Use `read_lines` tool for specific line ranges

## Configuration

Current configuration in `config.zig`:

```zig
pub const Config = struct {
    // ... existing fields ...

    // File reading threshold (smart auto-detection)
    file_read_small_threshold: usize = 100,  // Files <= this: full content. Files > this: curated
};
```

Users can customize the threshold in `~/.config/localharness/config.json`:
```json
{
  "file_read_small_threshold": 100
}
```

## Unified Progress Display System

**Added**: 2025-10-26 (Phase 2)

All LLM sub-tasks (agents, GraphRAG indexing, future tasks) now share a unified progress display system:

### Core Components

**`ProgressDisplayContext`** (agents.zig:34-52)
- Replaces both `AgentProgressContext` and `IndexingProgressContext`
- Separate thinking/content buffers for better UX
- Task metadata support (file path, nodes created, edges created, embeddings)
- Tracks task name, icon, start time, finalization state

**`ProgressUpdateType`** (agents.zig:13-22)
- Unified enum: `.thinking`, `.content`, `.tool_call`, `.iteration`, `.complete`
- GraphRAG-specific: `.embedding`, `.storage`
- Single source of truth for all progress events

**`finalizeProgressMessage()`** (message_renderer.zig:17-101)
- Unified finalization with beautiful formatting
- Header with task icon and name
- Statistics display for task metadata
- Auto-collapse with execution time
- Consistent across all task types

### Files Unified

1. **app.zig** - Agent progress callbacks use `ProgressDisplayContext`
2. **app_graphrag.zig** - GraphRAG indexing uses same system
3. **graphrag/llm_indexer.zig** - Removed duplicate types, emits `.complete`
4. **message_renderer.zig** - Single finalization function for all tasks

### Benefits

✅ **Consistent UX** - All progress messages look identical
✅ **Code Reduction** - ~100 lines of duplication eliminated
✅ **Single Source of Truth** - All types defined in agents.zig
✅ **Extensible** - Easy to add new task types
✅ **Professional Polish** - Execution stats, collapse/expand, beautiful formatting

### Display Format

```
📊 GraphRAG Indexing Analysis [COMPLETED] (2.3s)
[Press Ctrl+O to expand]

--- When expanded ---
📊 GraphRAG Indexing Analysis
─────────────────────────────────

[LLM thinking and content here...]

**Statistics:**
- File: file.zig
- Nodes created: 15
- Edges created: 8
- Embeddings: 47

─────────────────────────────────
[Press Ctrl+O to collapse]
```

## Summary

The agent architecture provides:

✅ **Unified pattern** for LLM sub-tasks
✅ **Capability-based security** for resource control
✅ **Isolated execution** for clean separation
✅ **Reusable components** (llm_helper, agent_executor)
✅ **Easy extensibility** for future agents
✅ **GraphRAG integration** via shared context
✅ **First concrete agent** (file_curator) already working
✅ **Unified progress display** for all LLM sub-tasks *(NEW)*

This sets a solid foundation for building more sophisticated agent-based features while maintaining code quality and architectural clarity.
