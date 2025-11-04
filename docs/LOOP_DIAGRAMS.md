# Loop Flow Diagrams

## 1. Main Chat Loop Architecture

```
app.zig:run()  [while(true) loop starting at line 1030]
│
├─── Config Editor Mode (Lines 1031-1107)
│    └─ If config_editor is Some: Handle editor input, save/cancel
│
├─── Tool Executor State Machine (Lines 1109-1287)
│    │
│    ├─ hasPendingWork() → true
│    │  │
│    │  └─ tick() returns:
│    │     ├─ show_permission_prompt: Display permission UI
│    │     ├─ render_requested: Execute tool
│    │     ├─ iteration_complete: Continue to next streaming
│    │     └─ iteration_limit_reached: Stop looping
│    │
│    └─ hasPendingWork() → false: Skip this section
│
├─── Compression Checkpoint (After Tool Execution)
│    │
│    ├─ Condition: !streaming_active && !tool_executor.hasPendingWork()
│    │
│    └─ Check if compression needed:
│        ├─ context_tracker.estimated_tokens > 70% threshold?
│        └─ Yes → compressor.compressWithAgent() (inline, synchronous)
│            ├─ Compress old messages (preserve last 5 pairs)
│            ├─ Update message history in-place
│            └─ Reset token tracker
│
├─── Stream Chunk Processing (Lines 1303-1539)
│    │
│    ├─ If streaming_active: Process stream chunks (10ms sleep)
│    │  │
│    │  └─ For each chunk:
│    │     ├─ Accumulate thinking/content
│    │     ├─ chunk.done?
│    │     │  ├─ true:  Check for tool calls
│    │     │  │         ├─ Has tools? → tool_executor.startExecution()
│    │     │  │         └─ No tools? → Check compression checkpoint
│    │     │  └─ false: Update assistant message
│    │
│    └─ Non-blocking input handling (10ms loop)
│
├─── Main Render Section (Lines 1541-1593)
│    │
│    └─ If !streaming_active:
│        ├─ Get terminal size
│        ├─ Render message history
│        ├─ Render input field
│        └─ Render taskbar
│
├─── Input Handling (Lines 1595-1667)
│    │
│    ├─ If streaming_active || tool_executor.hasPendingWork():
│    │  └─ Non-blocking read (10ms sleep)
│    │
│    └─ Else (idle):
│        └─ Blocking read (waits for input)
│
└─── Cursor & Viewport Management (Lines 1670-1682)
     └─ Adjust scroll position
     
[LOOP BACK TO TOP]
```

---

## 2. Tool Calling Flow

```
User sends message: sendMessage(text)
│
├─ Reset tool_call_depth = 0
├─ Reset iteration_count = 0
├─ Add user message to history
└─ Call startStreaming()
   │
   ├─ Create assistant placeholder message
   │
   ├─ Convert app messages to ollama.ChatMessage format
   │  ├─ Skip display_only_data messages
   │  ├─ Messages may contain compressed content (💬 [Compressed] prefix)
   │  └─ Hot context injected before LLM call
   │
   ├─ Create StreamThreadContext:
   │  ├─ model = config.model
   │  ├─ messages = prepared messages
   │  ├─ tools = self.tools (array of ollama.Tool)
   │  └─ ... other config ...
   │
   └─ Spawn background thread: streamingThreadFn()
      │
      └─ In thread: Get provider capabilities
         │
         ├─ Capability check:
         │  ├─ enable_thinking = config.enable_thinking AND caps.supports_thinking
         │  └─ keep_alive = caps.supports_keep_alive ? config.keep_alive : null
         │
         ├─ Call: llm_provider.chatStream()
         │  │
         │  ├─ Provider dispatch (union switch):
         │  │  │
         │  │  ├─ Ollama path:
         │  │  │  └─ OllamaProvider.chatStream()
         │  │  │     ├─ Build JSON payload with:
         │  │  │     │  ├─ messages
         │  │  │     │  ├─ tools (if tools.len > 0)
         │  │  │     │  ├─ keep_alive (if not null)
         │  │  │     │  └─ num_ctx (if set)
         │  │  │     └─ Stream response using callback
         │  │  │
         │  │  └─ LM Studio path:
         │  │     └─ LMStudioProvider.chatStream()
         │  │        ├─ Build JSON payload with:
         │  │        │  ├─ messages
         │  │        │  ├─ tools (if tools.len > 0)
         │  │        │  └─ OpenAI format parameters
         │  │        ├─ Parse SSE stream
         │  │        └─ Accumulate tool calls by index
         │  │
         │  └─ For each chunk: Call ChunkCallback.callback()
         │     ├─ Extract thinking/content/tool_calls
         │     └─ Add to stream_chunks queue
         │
         └─ Stream ends: Add .done chunk

[BACK IN MAIN LOOP]
│
├─ Process stream chunks until done
│
└─ When chunk.done:
   │
   ├─ pending_tool_calls = accumulated tool calls
   │
   ├─ Check: tool_call_depth < max_tool_depth?
   │  │
   │  ├─ YES:
   │  │  ├─ Attach tool_calls to assistant message
   │  │  ├─ Call: tool_executor.startExecution(tool_calls)
   │  │  └─ Next loop iteration: Execute tools
   │  │     │
   │  │     ├─ For each tool call:
   │  │     │  ├─ Check permission
   │  │     │  ├─ Execute: tools_module.executeToolCall()
   │  │     │  ├─ Create display message (transparency)
   │  │     │  ├─ Create tool message (JSON result)
   │  │     │  └─ Add both to messages
   │  │     │
   │  │     ├─ Increment iteration_count
   │  │     └─ Call startStreaming() again (LOOP BACK)
   │  │
   │  └─ NO: Max depth reached
   │     └─ Show error, stop looping
   │
   └─ NO TOOL CALLS:
      └─ Response complete, check compression checkpoint
```

---

## 3. Compression Checkpoint (Inline, Not Secondary Loop)

```
Main Loop checks after tool execution:
  !streaming_active AND !tool_executor.hasPendingWork()
  │
  └─ Check if compression needed:
     │
     ├─ context_tracker.estimated_tokens_used > (num_ctx * 0.70)?
     │  │
     │  ├─ YES: Trigger compression (inline, synchronous)
     │  │  │
     │  │  └─ compressor.compressWithAgent(allocator, messages, tracker, llm_provider, config)
     │  │     │
     │  │     ├─ Step 1: Build agent context
     │  │     │  ├─ Load compression agent
     │  │     │  ├─ Provide 4 specialized tools:
     │  │     │  │  ├─ get_compression_metadata
     │  │     │  │  ├─ compress_tool_result
     │  │     │  │  ├─ compress_conversation_segment
     │  │     │  │  └─ verify_compression_target
     │  │     │  └─ Set capabilities (max 15 iterations, temp 0.7)
     │  │     │
     │  │     ├─ Step 2: Run compression agent
     │  │     │  ├─ Agent analyzes conversation history
     │  │     │  ├─ Calls tools to compress messages
     │  │     │  │  ├─ Tool results: Use tracked metadata
     │  │     │  │  ├─ User messages: LLM compress to ~50 tokens
     │  │     │  │  └─ Assistant messages: LLM compress to ~200 tokens
     │  │     │  └─ Preserves last 5 user+assistant pairs (protected)
     │  │     │
     │  │     ├─ Step 3: Update message history in-place
     │  │     │  ├─ Replace old messages with compressed versions
     │  │     │  ├─ Free old message content
     │  │     │  └─ Mark compressed messages with 💬 [Compressed] prefix
     │  │     │
     │  │     ├─ Step 4: Reset token tracker
     │  │     │  ├─ Recalculate estimated tokens
     │  │     │  └─ Target: reduce from 70% (56k) to 40% (32k)
     │  │     │
     │  │     └─ Return compression stats
     │  │        ├─ original_message_count
     │  │        ├─ compressed_message_count
     │  │        ├─ tool_results_compressed
     │  │        └─ messages_protected
     │  │
     │  └─ NO: Continue to next iteration
     │
     └─ [MAIN LOOP CONTINUES]

Compression Quality:
  ├─ User messages: Preserve question, intent, technical details
  ├─ Assistant messages: Preserve explanations, code changes, decisions
  ├─ Tool results: Use metadata for context-aware summaries
  └─ Protected messages: Last 5 pairs never compressed (recent work safe)
```

---

## 4. Provider Tool Handling Comparison

```
Tool Definition (ollama.Tool):
  {
    type: "function",
    function: {
      name: string,
      description: string,
      parameters: JSON schema string
    }
  }

OLLAMA PATH:
├─ Create JSON request:
│  └─ "tools": [
│      {
│        "type": "function",
│        "function": { "name": "...", ... }
│      }
│    ]
│
├─ Send to: http://localhost:11434/api/chat
│
├─ Parse response:
│  └─ message.tool_calls: [
│      {
│        "id": "...",
│        "function": {
│          "name": "...",
│          "arguments": <JSON value>  ← Can be object or string!
│        }
│      }
│    ]
│
└─ Callback: callback(context, thinking, content, tool_calls)

LM STUDIO PATH:
├─ Create JSON request (OpenAI format):
│  └─ "tools": [
│      {
│        "type": "function",
│        "function": { "name": "...", ... }
│      }
│    ]
│
├─ Send to: http://localhost:1234/v1/chat/completions
│
├─ Parse SSE streaming:
│  └─ chunks with delta.tool_calls: [
│      {
│        "index": 0,
│        "id": "...",
│        "function": {
│          "name": "...streaming...",
│          "arguments": "...streaming..."
│        }
│      }
│    ]
│     
│  ├─ Accumulate by index (tool_calls stream in pieces)
│  └─ Send complete on finish_reason: "tool_calls"
│
└─ Callback: callback(context, reasoning, content, tool_calls)
   (reasoning = LM Studio's thinking equivalent)

KEY DIFFERENCES:
• Ollama: Complete tool calls in single message chunk
• LM Studio: Tool calls stream in pieces by index
• Ollama: thinking field
• LM Studio: reasoning field (+ index-based accumulation)
• Both: Same tool format in requests
• Both: Same callback interface (after accumulation)
```

---

## 5. Message History Flow with Context Management

```
User Message
  │
  └─ startStreaming()
     │
     ├─ Get message history (may contain compressed messages)
     │  ├─ Old messages: Compressed if token usage was high
     │  │  └─ Marked with 💬 [Compressed] prefix
     │  └─ Recent messages: Last 5 user+assistant pairs (full, never compressed)
     │
     ├─ Hot Context Injection (BEFORE LLM):
     │  │
     │  └─ injection.buildWorkflowContext():
     │     ├─ Files read: List from context_tracker
     │     ├─ Files modified: List with line ranges
     │     ├─ Current todos: Active task status
     │     └─ Workflow state: Current user activity
     │
     └─ Send to LLM with full context awareness

LLM sees:
  ├─ Hot context header (workflow awareness)
  ├─ Compressed old messages (semantic meaning preserved via LLM compression)
  └─ Full recent messages (last 5 pairs protected)

Benefits:
  ├─ Context window managed automatically
  ├─ Recent work never compressed
  ├─ Semantic meaning preserved (not truncation)
  └─ Workflow awareness via hot injection
```

---

## 6. Tool Executor State Machine

```
Initial State: idle

User sends message with tools requested
│
└─ tool_executor.startExecution(tool_calls)
   │
   └─ State: executing

Main loop's tool_executor.tick() runs:
│
├─ Has pending permission request?
│  │
│  ├─ YES: State → show_permission_prompt
│  │      Main loop shows UI, waits for response
│  │      Next tick: User responds, State → executing
│  │
│  └─ NO: Continue to execution
│
├─ Current tool in .executing state?
│  │
│  ├─ YES: State → render_requested
│  │      Main loop calls executeTool()
│  │      Shows results, adds to message history
│  │      Next tick: Advance to next tool
│  │
│  └─ NO: Check all done
│
├─ All tools executed?
│  │
│  ├─ YES: Check iteration limit
│  │      iteration_count < max_iterations?
│  │      │
│  │      ├─ YES: State → iteration_complete
│  │      │      Main loop calls startStreaming() again
│  │      │      Next tick: Back to initial state
│  │      │
│  │      └─ NO: State → iteration_limit_reached
│  │           Main loop shows error
│  │           Returns to idle
│  │
│  └─ NO: State → executing (next tool)

State: idle (no pending work)
```

---

## 7. Complete Request/Response Cycle

```
USER ENTERS: "Read the file"
   │
   ├─ sendMessage("Read the file")
   │  ├─ Add to messages
   │  └─ startStreaming()
   │
   ├─ Background thread spawned
   │
   ├─ Thread: Build request
   │  ├─ Include messages
   │  ├─ Include tools array
   │  └─ Include capabilities (think, keep_alive)
   │
   ├─ Thread: Send to LLM (Ollama or LM Studio)
   │
   ├─ Thread: Stream response
   │  └─ Callback adds chunks to stream_chunks queue
   │
   └─ Main Loop:
      │
      ├─ Process stream chunks (real-time)
      │  └─ Update assistant message as chunks arrive
      │
      ├─ Chunk.done received
      │  │
      │  ├─ Tool calls detected?
      │  │  │
      │  │  ├─ YES:
      │  │  │  ├─ tool_executor.startExecution()
      │  │  │  │
      │  │  │  └─ Next loop iteration:
      │  │  │     ├─ tool_executor.tick() → render_requested
      │  │  │     ├─ executeTool(tool_call)
      │  │  │     │  └─ Execute: read_file tool
      │  │  │     │     ├─ Read file from disk
      │  │  │     │     ├─ Queue for GraphRAG indexing
      │  │  │     │     └─ Return result
      │  │  │     ├─ Create display message
      │  │  │     ├─ Create tool message with JSON
      │  │  │     └─ Add both to history
      │  │  │
      │  │  │  └─ Next loop: startStreaming() again
      │  │  │     (LLM sees file content in messages)
      │  │  │
      │  │  └─ NO:
      │  │     └─ Response complete!
      │  │        └─ Check GraphRAG work
      │  │           ├─ Queue not empty?
      │  │           └─ app_graphrag.processQueuedFiles()
      │  │              └─ Show UI prompt for indexing options
      │  │
      │  └─ Main rendering loop
      │     └─ Display updated message history
      │
      └─ User presses key
         └─ Handle input or continue

[CYCLE COMPLETE - Ready for next user message]
```

---

## 8. File Locations Quick Reference

```
Core Loop Logic:
├─ /home/wassie/Desktop/localharness/app.zig (1021-1683)
│  └─ run() = main chat loop (lines 1021-1683)
│  └─ startStreaming() = prepare and spawn thread (lines 647-756)
│  └─ streamingThreadFn() = background streaming (lines 432-578)
│  └─ sendMessage() = user message entry point (lines 759-792)

Tool Handling:
├─ /home/wassie/Desktop/localharness/llm_provider.zig
│  └─ Unified interface + provider dispatch
└─ /home/wassie/Desktop/localharness/ollama.zig
   └─ Ollama-specific tool passing
└─ /home/wassie/Desktop/localharness/lmstudio.zig
   └─ LM Studio-specific tool passing

Context Management:
├─ /home/wassie/Desktop/localharness/context_management/tracking.zig
│  └─ ContextTracker: Tracks files, modifications, todos, token usage
├─ /home/wassie/Desktop/localharness/context_management/compressor.zig
│  └─ Compression logic and LLM-based summarization
├─ /home/wassie/Desktop/localharness/injection.zig
│  └─ Hot context injection before LLM calls
└─ /home/wassie/Desktop/localharness/agents_hardcoded/compression_agent.zig
   └─ Compression agent with specialized tools

Compression Tools:
├─ /home/wassie/Desktop/localharness/tools/get_compression_metadata.zig
├─ /home/wassie/Desktop/localharness/tools/compress_tool_result.zig
├─ /home/wassie/Desktop/localharness/tools/compress_conversation_segment.zig
└─ /home/wassie/Desktop/localharness/tools/verify_compression_target.zig

Tool Execution:
├─ /home/wassie/Desktop/localharness/tool_executor.zig
│  └─ State machine for tool execution
└─ /home/wassie/Desktop/localharness/tools.zig
   └─ Tool definitions and registry
```

