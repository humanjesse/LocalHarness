# Main Chat Loop and GraphRAG Loop Analysis

## Overview
This is a Zig-based application with two main execution loops:
1. **Main Chat Loop** - `app.zig:run()` function
2. **GraphRAG Secondary Loop** - `app_graphrag.zig:processQueuedFiles()` function

Both loops support tool calling with different handling for Ollama vs LM Studio.

---

## 1. MAIN CHAT LOOP (`app.zig:run()`)

### Location
File: `/home/wassie/Desktop/localharness/app.zig`
Lines: 1021-1683

### Entry Point
```zig
pub fn run(self: *App, app_tui: *ui.Tui) !void
```

### Loop Structure
The main loop is a `while (true)` loop (line 1030) with multiple sub-sections:

#### 1.1 Config Editor Mode (Lines 1031-1107)
- Handles config editing in modal mode
- Takes priority over normal app
- Non-blocking input handling

#### 1.2 Tool Executor State Machine (Lines 1109-1287)
**Handles agentic tool execution and looping**
- Checks if `tool_executor` has pending work
- Advances execution state machine with `tick()`
- Returns states:
  - `.show_permission_prompt` - prompts user for tool permission
  - `.render_requested` - executes tool and displays results
  - `.iteration_complete` - all tools done, continue to next streaming
  - `.iteration_limit_reached` - max iterations hit, stop

#### 1.3 GraphRAG Secondary Loop Trigger (Lines 1289-1301)
**Entry point to GraphRAG processing**
```zig
if (!self.streaming_active and !self.tool_executor.hasPendingWork()) {
    const has_graphrag_work = (self.graphrag_choice_pending or
        self.graphrag_choice_response != null or
        (self.indexing_queue != null and !self.indexing_queue.?.isEmpty()));
    
    if (has_graphrag_work) {
        try app_graphrag.processQueuedFiles(self);
    }
}
```

#### 1.4 Stream Processing (Lines 1303-1539)
**Processes incoming LLM response chunks in real-time**
- Active when `streaming_active == true`
- Non-blocking - sleeps 10ms to avoid busy-waiting
- Accumulates streaming chunks:
  - Thinking content
  - Response content
  - Tool calls

**Key Section: When streaming completes (line 1312-1419)**
```zig
if (chunk.done) {
    // Streaming complete
    
    // Check for tool calls
    if (tool_calls_to_execute) |tool_calls| {
        if (self.tool_call_depth < self.max_tool_depth) {
            // Attach to last assistant message
            last_message.tool_calls = tool_calls;
            // Start tool executor
            self.tool_executor.startExecution(tool_calls);
        }
    } else {
        // No tool calls - response is complete
        // SECONDARY LOOP: Process GraphRAG queue
        app_graphrag.processQueuedFiles(self) catch |err| { ... };
    }
}
```

#### 1.5 Main Render Section (Lines 1541-1593)
- Renders UI when NOT streaming
- Clears screen and redraws message history
- Handles resize signals

#### 1.6 Input Handling (Lines 1595-1667)
- Non-blocking during streaming/tool execution
- Blocking during idle
- Handles quit signal (`Ctrl+C` or special input)

---

## 2. TOOL CALLING IN MAIN LOOP

### 2.1 How Tools Are Passed to LLM

#### In `startStreaming()` function (Lines 647-756):
```zig
fn startStreaming(self: *App, format: ?[]const u8) !void {
    // ... prepare messages ...
    
    // Create placeholder for assistant response
    try self.messages.append(self.allocator, .{
        .role = .assistant,
        .content = assistant_content,
        // ...
    });
    
    // Prepare thread context
    const thread_ctx = try self.allocator.create(StreamThreadContext);
    thread_ctx.* = .{
        .allocator = self.allocator,
        .app = self,
        .llm_provider = &self.llm_provider,
        .model = self.config.model,
        .messages = messages_slice,
        .format = format,
        .tools = self.tools,  // <-- TOOLS PASSED HERE
        .keep_alive = self.config.model_keep_alive,
        .num_ctx = self.config.num_ctx,
        .num_predict = self.config.num_predict,
        .graphrag_summaries = summaries_slice,
    };
    
    // Start streaming in background thread
    self.stream_thread = try std.Thread.spawn(.{}, streamingThreadFn, .{thread_ctx});
}
```

#### In `streamingThreadFn()` function (Lines 432-578):
```zig
fn streamingThreadFn(ctx: *StreamThreadContext) void {
    // ... setup callback ...
    
    const caps = ctx.llm_provider.getCapabilities();
    const enable_thinking = ctx.app.config.enable_thinking and caps.supports_thinking;
    const keep_alive = if (caps.supports_keep_alive) ctx.keep_alive else null;
    
    ctx.llm_provider.chatStream(
        ctx.model,
        ctx.messages,
        enable_thinking,
        ctx.format,
        if (ctx.tools.len > 0) ctx.tools else null,  // <-- CONDITIONAL TOOL PASSING
        keep_alive,
        ctx.num_ctx,
        ctx.num_predict,
        null, // temperature
        null, // repeat_penalty
        ctx,
        ChunkCallback.callback,
    ) catch |err| { ... };
}
```

**Key Points:**
- Tools only passed if `ctx.tools.len > 0`
- Capability-aware thinking and keep_alive
- Tools are in `ollama.Tool` format (standard struct array)

---

## 3. GRAPHRAG SECONDARY LOOP (`app_graphrag.zig`)

### Location
File: `/home/wassie/Desktop/localharness/app_graphrag.zig`
Lines: 424-714

### Entry Point
```zig
pub fn processQueuedFiles(app: *App) !void
```

### Loop Architecture
**State Machine Pattern** - Not a traditional loop, but a state machine that works with the main loop:

```
Main Loop
    ↓
Check: streaming_active && !tool_executor.hasPendingWork() && has_graphrag_work
    ↓
Call: app_graphrag.processQueuedFiles()
    ├─ Wait for user choice? Return to main loop
    ├─ Got choice? Process it
    └─ Continue to next file or complete
```

### State Variables (in `App`)
```zig
graphrag_choice_pending: bool = false,     // Waiting for user input
graphrag_choice_response: ?types.GraphRagChoice = null,  // User's choice
current_indexing_file: ?[]const u8 = null, // Current file being processed
line_range_response: ?types.LineRange = null,  // Custom lines chosen
line_input_pending: bool = false,          // Waiting for line input
indexing_queue: ?*IndexingQueue = null,    // Queue of files to index
```

### GraphRAG Processing Flow (Lines 438-714)

#### Step 1: Check if Waiting (Lines 460-463)
```zig
if (app.graphrag_choice_pending) {
    // Still waiting for user response - do nothing
    return;
}
```

#### Step 2: Process Previous Response (Lines 466-653)
```zig
if (app.graphrag_choice_response) |choice| {
    const file_path = app.current_indexing_file orelse return error.NoCurrentFile;
    
    switch (choice) {
        .full_indexing => {
            // Index entire file using LLM
            // Calls: llm_indexer.indexFile()
            // With progress callback
        },
        .custom_lines => {
            // Wait for line range
            // Update message history with selected lines
        },
        .metadata_only => {
            // Replace content with minimal metadata
        },
    }
    
    // Clear state for next file
    app.graphrag_choice_response = null;
    app.line_range_response = null;
    // Free file path...
}
```

#### Step 3: Check if Queue Empty (Lines 656-676)
```zig
if (queue.isEmpty()) {
    const complete_msg = try app.allocator.dupe(u8, "✓ All files processed\n");
    // ... show completion message ...
    return;
}
```

#### Step 4: Show Prompt for Next File (Lines 678-714)
```zig
const next_task = queue.peek() orelse return;

// Count lines and show prompt
const prompt_msg = try std.fmt.allocPrint(
    app.allocator,
    "\n📁 File: {s} ({d} lines)\nHow should this be handled?\n",
    .{ next_task.file_path, line_count },
);

// Store state for main loop
app.current_indexing_file = try app.allocator.dupe(u8, next_task.file_path);
app.graphrag_choice_pending = true;  // <-- Signal main loop to wait for input
```

---

## 4. TOOL HANDLING DIFFERENCES: OLLAMA vs LM STUDIO

### 4.1 Provider Capabilities Registry

**File:** `/home/wassie/Desktop/localharness/llm_provider.zig`

```zig
// Ollama capabilities
pub const OLLAMA = ProviderCapabilities{
    .supports_thinking = true,      // Extended thinking mode
    .supports_keep_alive = true,    // Model lifecycle mgmt
    .supports_tools = true,         // Tool calling
    .supports_json_mode = true,
    .supports_streaming = true,
    .supports_embeddings = true,
    .supports_context_api = true,   // Can set num_ctx via API
    .name = "Ollama",
    .default_port = 11434,
};

// LM Studio capabilities
pub const LMSTUDIO = ProviderCapabilities{
    .supports_thinking = false,     // NO thinking mode
    .supports_keep_alive = false,   // NO keep_alive
    .supports_tools = true,         // Tool calling supported
    .supports_json_mode = true,
    .supports_streaming = true,
    .supports_embeddings = true,
    .supports_context_api = false,  // NO num_ctx API
    .name = "LM Studio",
    .default_port = 1234,
};
```

### 4.2 Tool Passing - Unified Interface

**File:** `/home/wassie/Desktop/localharness/llm_provider.zig` (Lines 266-321)

Both providers implement the same `chatStream()` interface:
```zig
pub fn chatStream(
    self: *LLMProvider,
    model: []const u8,
    messages: []const ollama.ChatMessage,
    think: bool,                    // Ignored by LM Studio
    format: ?[]const u8,
    tools: ?[]const ollama.Tool,   // SAME FORMAT for both
    keep_alive: ?[]const u8,       // Ignored by LM Studio
    num_ctx: ?usize,               // Ignored by LM Studio
    num_predict: ?isize,
    temperature: ?f32,
    repeat_penalty: ?f32,
    context: anytype,
    callback: fn (...) void,
) !void
```

**Switch statement dispatches to provider-specific implementation:**
```zig
switch (self.*) {
    .ollama => |*provider| {
        return provider.chatStream(model, messages, think, format, 
                                   tools, keep_alive, num_ctx, 
                                   num_predict, temperature, repeat_penalty, 
                                   context, callback);
    },
    .lmstudio => |*provider| {
        return provider.chatStream(model, messages, think, format,
                                   tools, keep_alive, num_ctx,
                                   num_predict, temperature, repeat_penalty,
                                   context, callback);
    },
}
```

### 4.3 Ollama Tool Passing

**File:** `/home/wassie/Desktop/localharness/ollama.zig` (Lines 87-101)

```zig
pub fn chatStream(
    self: *OllamaClient,
    model: []const u8,
    messages: []const ChatMessage,
    think: bool,              // SUPPORTED
    format: ?[]const u8,
    tools: ?[]const Tool,     // Ollama Tool format
    keep_alive: ?[]const u8,  // SUPPORTED
    num_ctx: ?usize,          // SUPPORTED
    num_predict: ?isize,
    temperature: ?f32,
    repeat_penalty: ?f32,     // SUPPORTED
    context: anytype,
    callback: fn (...) void,
) !void
```

**Tool inclusion in payload:**
```zig
// Tools added to JSON payload if provided
if (tools) |tool_list| {
    try payload_list.appendSlice(self.allocator, ",\"tools\":[");
    for (tool_list, 0..) |tool, i| {
        if (i > 0) try payload_list.append(self.allocator, ',');
        try payload_list.appendSlice(self.allocator, "{\"type\":\"function\",\"function\":{\"name\":\"");
        try payload_list.appendSlice(self.allocator, tool.function.name);
        // ... description, parameters ...
    }
    try payload_list.append(self.allocator, ']');
}
```

### 4.4 LM Studio Tool Passing

**File:** `/home/wassie/Desktop/localharness/lmstudio.zig` (Lines 74-91)

```zig
pub fn chatStream(
    self: *LMStudioClient,
    model: []const u8,
    messages: []const ollama.ChatMessage,
    format: ?[]const u8,
    tools: ?[]const ollama.Tool,     // Same format as Ollama
    num_ctx: ?usize,                 // Ignored - LM Studio setting
    num_predict: ?isize,
    temperature: ?f32,
    repeat_penalty: ?f32,            // Ignored - not in OpenAI spec
    context: anytype,
    callback: fn (...) void,
) !void
```

**Signature has no thinking or keep_alive parameters** - they're stripped at wrapper level.

**Tool inclusion is identical to Ollama** (Lines 191-217):
```zig
// Add tools if provided (SAME format)
if (tools) |tool_list| {
    try payload_list.appendSlice(self.allocator, ",\"tools\":[");
    for (tool_list, 0..) |tool, i| {
        // ... identical tool serialization ...
    }
    try payload_list.append(self.allocator, ']');
}
```

### 4.5 Tool Response Parsing Differences

#### Ollama (ollama.zig - Lines 44-51)
**Expects tool_calls in response:**
```zig
message: ?struct {
    role: []const u8,
    content: []const u8,
    thinking: ?[]const u8 = null,
    tool_calls: ?[]struct {
        id: ?[]const u8 = null,
        type: ?[]const u8 = null,
        function: struct {
            name: []const u8,
            arguments: std.json.Value,  // Can be object OR string
        },
    } = null,
} = null,
```

#### LM Studio (lmstudio.zig - Lines 20-28)
**Expects tool_calls in streaming deltas:**
```zig
choices: ?[]struct {
    index: ?i32 = null,
    delta: ?struct {
        role: ?[]const u8 = null,
        content: ?[]const u8 = null,
        reasoning: ?[]const u8 = null,    // Extended thinking (not standard)
        tool_calls: ?[]struct {
            index: ?i32 = null,
            id: ?[]const u8 = null,
            type: ?[]const u8 = null,
            function: ?struct {
                name: ?[]const u8 = null,
                arguments: ?[]const u8 = null,
            } = null,
        } = null,
    } = null,
    finish_reason: ?[]const u8 = null,
} = null,
```

**Key Differences:**
1. **Streaming Format**: LM Studio uses delta-based streaming (OpenAI format), Ollama uses complete message chunks
2. **Thinking Field**: LM Studio calls it `reasoning`, Ollama calls it `thinking`
3. **Tool Call Accumulation**: LM Studio tool calls stream in pieces (index-based), Ollama sends complete tool calls

---

## 5. KEY INTEGRATION POINTS

### 5.1 Message History Management

**In `startStreaming()` (app.zig:662-692):**
```zig
// Convert app messages to Ollama format
for (self.messages.items) |msg| {
    if (msg.role == .display_only_data) continue;  // Skip UI-only
    
    const role_str = switch (msg.role) {
        .user => "user",
        .assistant => "assistant",
        .system => "system",
        .tool => "tool",
        .display_only_data => unreachable,
    };
    try ollama_messages.append(self.allocator, .{
        .role = role_str,
        .content = msg.content,
        .tool_call_id = msg.tool_call_id,
        .tool_calls = msg.tool_calls,
    });
}

// Apply GraphRAG compression if enabled
if (self.config.graph_rag_enabled and self.vector_store != null) {
    const compressed_messages = try self.compressMessageHistoryWithTracking(
        ollama_messages.items,
        &allocated_summaries,
    );
    // ... replace with compressed version
}
```

### 5.2 Tool Execution Flow

**When tools are called in main loop (app.zig:1147-1227):**
1. Tool executor state machine detects tool in `.executing` state
2. Calls `self.executeTool(tool_call)` 
3. Tool executor handles permission checks, recursion depth, etc.
4. Creates two messages:
   - **Display message**: Full transparency of what tool did
   - **Tool message**: JSON result sent back to LLM
5. Both messages added to history for next streaming call

---

## 6. CAPABILITY-AWARE BEHAVIOR

### In `streamingThreadFn()` (app.zig:489-496):

```zig
// Get provider capabilities
const caps = ctx.llm_provider.getCapabilities();

// Only enable thinking if both config AND provider support it
const enable_thinking = ctx.app.config.enable_thinking and caps.supports_thinking;

// Only pass keep_alive if provider supports it
const keep_alive = if (caps.supports_keep_alive) ctx.keep_alive else null;

// Both providers support tools - passed unconditionally (if available)
if (ctx.tools.len > 0) ctx.tools else null
```

**This means:**
- **Ollama**: Thinking + keep_alive enabled if configured
- **LM Studio**: Thinking + keep_alive always disabled (ignored by wrapper)
- **Both**: Tools passed the same way (both support)

---

## 7. TOOL EXECUTION STATE MACHINE

**In `tool_executor.zig` (referenced but not fully shown):**

State transitions:
```
idle
  ↓
startExecution() → executing
  ↓
tick() → show_permission_prompt (if user confirmation needed)
  ↓
setPermissionResponse() → executing → render_requested
  ↓
tick() → (show result) → iteration_complete
  ↓
(if more tools) → iteration_complete → executing
(if no more tools) → iteration_complete → (return to main loop)
(if max iterations) → iteration_limit_reached
```

---

## 8. SUMMARY TABLE

| Feature | Ollama | LM Studio | Main Loop | GraphRAG Loop |
|---------|--------|-----------|-----------|---------------|
| **Tool Calling** | ✓ | ✓ | Both use same `tools` array | Uses main loop results |
| **Thinking/Reasoning** | Extended thinking | Not supported | Capability-checked | N/A |
| **Keep-Alive** | Supported | Not supported | Capability-checked | N/A |
| **Streaming** | Message chunks | Delta-based | Both supported | Uses streaming chunks |
| **Tool Response Parsing** | Complete messages | Streamed deltas | Same callback format | Processes indexed results |
| **Loop Type** | Streaming + Tool iteration | Streaming + Tool iteration | while(true) with sub-states | State machine (cooperative) |
| **Tool Depth** | Limited by `max_tool_depth` | Limited by `max_tool_depth` | Global counter | N/A |
| **Entry Points** | Main: `app.run()` | Main: `app.run()` | Triggered by `sendMessage()` | Triggered when no streaming/tools |

---

## Files Summary

| File | Purpose | Key Functions |
|------|---------|----------------|
| `app.zig` | Main app + chat loop | `run()`, `startStreaming()`, `streamingThreadFn()`, `sendMessage()` |
| `app_graphrag.zig` | GraphRAG secondary loop | `processQueuedFiles()` |
| `llm_provider.zig` | Provider abstraction | `createProvider()`, `chatStream()` (unified interface) |
| `ollama.zig` | Ollama client | `chatStream()` (Ollama-specific), tool payload building |
| `lmstudio.zig` | LM Studio client | `chatStream()` (LM Studio-specific), SSE parsing, tool accumulation |
| `tool_executor.zig` | Tool execution state machine | `tick()`, `startExecution()` |

