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
├─── GraphRAG Secondary Loop Trigger (Lines 1289-1301)
│    │
│    ├─ Condition: !streaming_active && !tool_executor.hasPendingWork()
│    │
│    └─ If has_graphrag_work:
│        └─ Call: app_graphrag.processQueuedFiles(self)
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
│    │     │  │         └─ No tools? → Call processQueuedFiles()
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
   │  ├─ Apply GraphRAG compression if enabled
   │  └─ Track allocated summaries
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
      └─ Response complete, trigger GraphRAG loop
```

---

## 3. GraphRAG Secondary Loop

```
Main Loop checks:
  !streaming_active AND !tool_executor.hasPendingWork()
  │
  └─ Calls: app_graphrag.processQueuedFiles(app)
     │
     ├─ Step 1: Check if waiting for user choice
     │  │
     │  ├─ graphrag_choice_pending == true?
     │  │  └─ RETURN (wait for main loop input)
     │  │
     │  └─ graphrag_choice_pending == false?
     │     └─ Continue to next step
     │
     ├─ Step 2: Process previous user choice
     │  │
     │  ├─ graphrag_choice_response is Some?
     │  │  │
     │  │  ├─ Choice: full_indexing
     │  │  │  ├─ Pop task from queue
     │  │  │  ├─ Call: llm_indexer.indexFile()
     │  │  │  │  ├─ Serialize file chunks
     │  │  │  │  ├─ Call LLM for indexing analysis
     │  │  │  │  ├─ Create embeddings
     │  │  │  │  ├─ Store in vector_store
     │  │  │  │  └─ Call progress callback (streaming)
     │  │  │  └─ Mark file as indexed in state
     │  │  │
     │  │  ├─ Choice: custom_lines
     │  │  │  ├─ Wait for line_range_response
     │  │  │  ├─ Call: updateMessageWithLineRange()
     │  │  │  ├─ Replace message content with selected lines
     │  │  │  └─ Pop and discard task
     │  │  │
     │  │  └─ Choice: metadata_only
     │  │     ├─ Call: updateMessageWithMetadata()
     │  │     ├─ Replace content with minimal info
     │  │     └─ Pop and discard task
     │  │
     │  ├─ Clear response state
     │  ├─ Clear file state
     │  └─ Redraw UI
     │
     └─ Step 3: Prepare next file or complete
        │
        ├─ Queue empty?
        │  └─ Show completion message, RETURN
        │
        └─ Queue not empty?
           │
           ├─ Peek at next task
           ├─ Count lines
           ├─ Show prompt: "How should this file be handled?"
           │  ├─ 1. Full GraphRAG indexing
           │  ├─ 2. Save custom line range
           │  └─ 3. Metadata only
           │
           ├─ Set: graphrag_choice_pending = true
           ├─ Set: current_indexing_file = next_task.file_path
           ├─ Redraw UI
           └─ RETURN (main loop waits for input)

[MAIN LOOP CONTINUES]
User presses key...
│
└─ Input handling detects GraphRAG choice
   │
   └─ Sets: graphrag_choice_response = user's choice
      │
      └─ Next loop: app_graphrag.processQueuedFiles() 
         runs again and processes the choice
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

## 5. Message History Flow with GraphRAG

```
User Message
  │
  └─ startStreaming()
     │
     ├─ Convert to ollama.ChatMessage
     └─ GraphRAG Compression (if enabled):
        │
        ├─ For each message:
        │  │
        │  ├─ Is tool role AND read_file result?
        │  │  │
        │  │  ├─ Was file indexed?
        │  │  │  └─ YES: Replace with summary from vector_store
        │  │  │
        │  │  └─ NO: Keep original content
        │  │
        │  └─ Non-tool message: Keep as-is
        │
        └─ Track allocated summaries (freed after thread ends)

LLM sees compressed history (read_file → summary)
This keeps context window smaller while preserving key info
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

GraphRAG Loop:
├─ /home/wassie/Desktop/localharness/app_graphrag.zig (424-714)
│  └─ processQueuedFiles() = secondary loop state machine (lines 438-714)

Tool Execution:
├─ /home/wassie/Desktop/localharness/tool_executor.zig
│  └─ State machine for tool execution
└─ /home/wassie/Desktop/localharness/tools.zig
   └─ Tool definitions and registry
```

