# Compression Implementation Plan

**Date:** 2025-11-02  
**Goal:** Implement hybrid compression (metadata + LLM) to reduce 70% → 40% token usage  
**Estimated Time:** 3.5 hours

---

## Design Decisions (Locked In)

1. ✅ **Approach:** Hybrid (metadata for tools, LLM for conversations)
2. ✅ **Protected Messages:** Last 5 user+assistant messages NEVER compressed
3. ✅ **Granularity:** Message-level (not conversation windows)
4. ✅ **Trigger/Target:** 70% → 40% (56k → 32k tokens)
5. ✅ **LLM Model:** Use same model as main conversation (simpler)
6. ✅ **LLM Timing:** Synchronous (block user during compression)
7. ✅ **Failure Handling:** Accept higher token count if can't reach 40%, log warning
8. ✅ **Batch Calls:** One LLM call per message (simpler, more reliable)
9. ✅ **Re-expansion:** No re-expansion in v1 (compressed is permanent)

---

## Implementation Phases

### Phase 1: Create compressor.zig Structure (20 min)

**Goal:** Set up file structure, types, and imports

**File:** `context_management/compressor.zig`

**Tasks:**
- [ ] Create file with standard imports
- [ ] Define `CompressionResult` struct
- [ ] Define `CompressionStats` struct
- [ ] Add helper type definitions
- [ ] Add debug logging helpers

**Code:**
```zig
const std = @import("std");
const mem = std.mem;
const tracking = @import("tracking");
const compression = @import("compression");
const types = @import("../types.zig");

const Message = types.Message;
const MessageRole = types.MessageRole;

pub const CompressionResult = struct {
    compressed_messages: []Message,
    original_tokens: usize,
    compressed_tokens: usize,
    compression_ratio: f32,
    stats: CompressionStats,
    
    pub fn deinit(self: *CompressionResult, allocator: mem.Allocator) void {
        for (self.compressed_messages) |*msg| {
            allocator.free(msg.content);
            allocator.free(msg.processed_content);
            if (msg.thinking_content) |tc| allocator.free(tc);
        }
        allocator.free(self.compressed_messages);
    }
};

pub const CompressionStats = struct {
    tool_results_compressed: usize = 0,
    user_messages_compressed: usize = 0,
    assistant_messages_compressed: usize = 0,
    display_data_deleted: usize = 0,
    messages_protected: usize = 0,
    total_messages_processed: usize = 0,
};

fn isDebugEnabled() bool {
    return std.posix.getenv("DEBUG_CONTEXT") != null;
}

fn debugPrint(comptime fmt: []const u8, args: anytype) void {
    if (isDebugEnabled()) {
        std.debug.print("[COMPRESSOR] " ++ fmt, args);
    }
}
```

**Verification:**
- [ ] File compiles without errors
- [ ] Types are correctly defined

---

### Phase 2: Implement Protected Message Detection (15 min)

**Goal:** Identify last 5 user+assistant messages that should never be compressed

**Function:** `identifyProtectedMessages()`

**Tasks:**
- [ ] Implement backward walk through messages
- [ ] Count only user+assistant messages
- [ ] Mark last 5 as protected
- [ ] Add debug logging

**Code:**
```zig
fn identifyProtectedMessages(
    allocator: mem.Allocator,
    messages: []const Message,
) ![]bool {
    debugPrint("Identifying protected messages (last 5 user+assistant)...\n", .{});
    
    var protected = try allocator.alloc(bool, messages.len);
    @memset(protected, false);
    
    // Walk backward, protect last 5 user+assistant messages
    var conversation_count: usize = 0;
    const target_protected = 5;
    
    var i = messages.len;
    while (i > 0 and conversation_count < target_protected) {
        i -= 1;
        const msg = messages[i];
        
        if (msg.role == .user or msg.role == .assistant) {
            protected[i] = true;
            conversation_count += 1;
            debugPrint("  Protected message {d} (role={s}, count={d}/5)\n", 
                .{i, @tagName(msg.role), conversation_count});
        }
    }
    
    debugPrint("Total protected: {d} messages\n", .{conversation_count});
    return protected;
}
```

**Verification:**
- [ ] Test with 10 user+assistant messages → last 5 protected
- [ ] Test with 3 user+assistant messages → all 3 protected
- [ ] Test with mixed message types → correct counting

---

### Phase 3: Implement Metadata-Based Tool Compression (45 min)

**Goal:** Compress tool results using tracked metadata (fast, no LLM calls)

**Functions:**
- `compressToolMessage()` - Main dispatcher
- `compressReadFileTool()` - Use curator cache
- `compressWriteTool()` - Use modification tracker
- `compressGenericTool()` - Fallback for other tools

**Tasks:**
- [ ] Implement tool type detection
- [ ] Implement read_file compression with curator cache
- [ ] Implement write_file compression with modification tracker
- [ ] Implement generic tool fallback
- [ ] Add JSON parsing helpers
- [ ] Add error handling for malformed tool results

**Code Structure:**
```zig
fn compressToolMessage(
    allocator: mem.Allocator,
    tool_message: Message,
    tracker: *tracking.ContextTracker,
) !Message {
    debugPrint("Compressing tool message...\n", .{});
    
    // Detect tool type from content
    if (isReadFileTool(tool_message.content)) {
        debugPrint("  Detected read_file tool\n", .{});
        return compressReadFileTool(allocator, tool_message, tracker);
    }
    
    if (isWriteFileTool(tool_message.content)) {
        debugPrint("  Detected write_file tool\n", .{});
        return compressWriteTool(allocator, tool_message, tracker);
    }
    
    debugPrint("  Using generic tool compression\n", .{});
    return compressGenericTool(allocator, tool_message);
}

fn isReadFileTool(content: []const u8) bool {
    return std.mem.indexOf(u8, content, "\"file_path\"") != null and
           std.mem.indexOf(u8, content, "\"content\"") != null;
}

fn isWriteFileTool(content: []const u8) bool {
    return std.mem.indexOf(u8, content, "write_file") != null or
           std.mem.indexOf(u8, content, "insert_lines") != null or
           std.mem.indexOf(u8, content, "replace_lines") != null;
}

fn compressReadFileTool(
    allocator: mem.Allocator,
    tool_message: Message,
    tracker: *tracking.ContextTracker,
) !Message {
    // Parse JSON to extract file_path
    const ToolResult = struct {
        file_path: []const u8,
        content: []const u8,
    };
    
    const parsed = std.json.parseFromSlice(
        ToolResult,
        allocator,
        tool_message.content,
        .{},
    ) catch {
        debugPrint("  Failed to parse tool JSON, using generic compression\n", .{});
        return compressGenericTool(allocator, tool_message);
    };
    defer parsed.deinit();
    
    const file_path = parsed.value.file_path;
    const line_count = std.mem.count(u8, parsed.value.content, "\n") + 1;
    
    // Check for curator cache
    if (tracker.read_files.get(file_path)) |file_tracker| {
        if (file_tracker.curated_result) |cache| {
            debugPrint("  Found curator cache for {s}\n", .{file_path});
            
            const summary = try std.fmt.allocPrint(
                allocator,
                "📄 [Compressed] Read {s} ({d} lines, hash:{x})\n" ++
                "• Curator Summary: {s}\n" ++
                "• Full content cached and available",
                .{
                    file_path,
                    line_count,
                    file_tracker.original_hash,
                    cache.summary,
                }
            );
            
            return createSystemMessage(allocator, summary);
        }
    }
    
    // No cache, basic compression
    debugPrint("  No curator cache for {s}, using basic summary\n", .{file_path});
    const summary = try std.fmt.allocPrint(
        allocator,
        "📄 [Compressed] Read {s} ({d} lines)",
        .{file_path, line_count}
    );
    
    return createSystemMessage(allocator, summary);
}

fn compressWriteTool(
    allocator: mem.Allocator,
    tool_message: Message,
    tracker: *tracking.ContextTracker,
) !Message {
    // Parse to get file_path
    const ToolResult = struct {
        file_path: []const u8,
    };
    
    const parsed = std.json.parseFromSlice(
        ToolResult,
        allocator,
        tool_message.content,
        .{},
    ) catch return compressGenericTool(allocator, tool_message);
    defer parsed.deinit();
    
    const file_path = parsed.value.file_path;
    
    // Find modification in tracker
    for (tracker.recent_modifications.items) |mod| {
        if (std.mem.eql(u8, mod.file_path, file_path)) {
            const time_ago = @divFloor(
                std.time.milliTimestamp() - mod.timestamp,
                60000  // Convert to minutes
            );
            
            const mod_type = switch (mod.modification_type) {
                .created => "Created",
                .modified => "Modified",
                .deleted => "Deleted",
            };
            
            var summary_list = std.ArrayList(u8).init(allocator);
            const writer = summary_list.writer();
            
            try writer.print("✏️ [Compressed] {s} {s} ({d} min ago)", 
                .{mod_type, file_path, time_ago});
            
            if (mod.related_todo_id) |todo_id| {
                try writer.print("\n• Related to todo: '{s}'", .{todo_id});
            }
            
            const summary = try summary_list.toOwnedSlice();
            return createSystemMessage(allocator, summary);
        }
    }
    
    // Fallback if not found in tracker
    return compressGenericTool(allocator, tool_message);
}

fn compressGenericTool(
    allocator: mem.Allocator,
    tool_message: Message,
) !Message {
    const summary = try std.fmt.allocPrint(
        allocator,
        "🔧 [Compressed] Tool executed successfully",
        .{}
    );
    return createSystemMessage(allocator, summary);
}

fn createSystemMessage(allocator: mem.Allocator, content: []const u8) !Message {
    // Process markdown for UI display
    const processed = try processMarkdownSimple(allocator, content);
    
    return Message{
        .role = .system,
        .content = content,
        .processed_content = processed,
        .timestamp = std.time.milliTimestamp(),
        .tool_calls = null,
        .tool_call_id = null,
        .thinking_content = null,
        .thinking_expanded = false,
    };
}

// Simplified markdown processing (avoid circular dependency)
fn processMarkdownSimple(allocator: mem.Allocator, content: []const u8) ![]const u8 {
    // For now, just duplicate - we'll integrate with markdown.zig later
    return try allocator.dupe(u8, content);
}
```

**Verification:**
- [ ] Test read_file with curator cache → uses cache summary
- [ ] Test read_file without cache → uses basic summary
- [ ] Test write_file → uses modification tracker
- [ ] Test generic tool → uses fallback

---

### Phase 4: Implement LLM-Based Conversation Compression (60 min)

**Goal:** Compress user/assistant messages using LLM summarization

**Functions:**
- `compressUserMessage()` - Compress user questions
- `compressAssistantMessage()` - Compress assistant responses

**Tasks:**
- [ ] Design LLM compression prompts
- [ ] Implement LLM call wrapper
- [ ] Implement user message compression (target: 50 tokens)
- [ ] Implement assistant message compression (target: 200 tokens)
- [ ] Add error handling for LLM failures
- [ ] Add fallback compression (truncation) if LLM fails

**Code:**
```zig
fn compressUserMessage(
    allocator: mem.Allocator,
    user_message: Message,
    llm_provider: anytype,
) !Message {
    debugPrint("Compressing user message (target: 50 tokens)...\n", .{});
    
    // Build compression prompt
    const prompt = try std.fmt.allocPrint(
        allocator,
        "Compress this user message to 1-2 sentences (max 50 tokens). " ++
        "Preserve the main question, key technical details, and intent.\n\n" ++
        "Original message:\n{s}\n\n" ++
        "Compressed version:",
        .{user_message.content}
    );
    defer allocator.free(prompt);
    
    // Call LLM
    const compressed = callLLMForCompression(
        allocator,
        llm_provider,
        prompt,
        60,  // max_tokens (slightly over target for safety)
    ) catch |err| {
        debugPrint("  LLM compression failed: {}, using fallback\n", .{err});
        return fallbackCompressMessage(allocator, user_message, 50);
    };
    defer allocator.free(compressed);
    
    // Prefix with compression marker
    const final_content = try std.fmt.allocPrint(
        allocator,
        "💬 [Compressed] {s}",
        .{std.mem.trim(u8, compressed, " \n\t")}
    );
    
    const processed = try processMarkdownSimple(allocator, final_content);
    
    return Message{
        .role = .user,
        .content = final_content,
        .processed_content = processed,
        .timestamp = user_message.timestamp,
        .tool_calls = null,
        .tool_call_id = null,
        .thinking_content = null,
        .thinking_expanded = false,
    };
}

fn compressAssistantMessage(
    allocator: mem.Allocator,
    assistant_message: Message,
    llm_provider: anytype,
) !Message {
    debugPrint("Compressing assistant message (target: 200 tokens)...\n", .{});
    
    const prompt = try std.fmt.allocPrint(
        allocator,
        "Compress this assistant response to 2-3 sentences (max 200 tokens). " ++
        "Preserve key explanations, code changes, and decisions.\n\n" ++
        "Original response:\n{s}\n\n" ++
        "Compressed version:",
        .{assistant_message.content}
    );
    defer allocator.free(prompt);
    
    const compressed = callLLMForCompression(
        allocator,
        llm_provider,
        prompt,
        250,  // max_tokens
    ) catch |err| {
        debugPrint("  LLM compression failed: {}, using fallback\n", .{err});
        return fallbackCompressMessage(allocator, assistant_message, 200);
    };
    defer allocator.free(compressed);
    
    const final_content = try std.fmt.allocPrint(
        allocator,
        "💬 [Compressed] {s}",
        .{std.mem.trim(u8, compressed, " \n\t")}
    );
    
    const processed = try processMarkdownSimple(allocator, final_content);
    
    return Message{
        .role = .assistant,
        .content = final_content,
        .processed_content = processed,
        .timestamp = assistant_message.timestamp,
        .tool_calls = null,
        .tool_call_id = null,
        .thinking_content = null,
        .thinking_expanded = false,
    };
}

fn callLLMForCompression(
    allocator: mem.Allocator,
    llm_provider: anytype,
    prompt: []const u8,
    max_tokens: usize,
) ![]const u8 {
    // Call LLM with low temperature for consistent compression
    const result = try llm_provider.generateCompletion(
        allocator,
        prompt,
        .{
            .temperature = 0.3,  // Low temp for consistency
            .max_tokens = @intCast(max_tokens),
            .stream = false,
        }
    );
    
    return result;
}

fn fallbackCompressMessage(
    allocator: mem.Allocator,
    message: Message,
    target_tokens: usize,
) !Message {
    // Fallback: Simple truncation
    const target_chars = target_tokens * 4;  // 4 chars ≈ 1 token
    const truncated = if (message.content.len > target_chars)
        message.content[0..target_chars]
    else
        message.content;
    
    const final_content = try std.fmt.allocPrint(
        allocator,
        "💬 [Compressed/Truncated] {s}...",
        .{truncated}
    );
    
    const processed = try processMarkdownSimple(allocator, final_content);
    
    return Message{
        .role = message.role,
        .content = final_content,
        .processed_content = processed,
        .timestamp = message.timestamp,
        .tool_calls = null,
        .tool_call_id = null,
        .thinking_content = null,
        .thinking_expanded = false,
    };
}
```

**Verification:**
- [ ] Test user message compression → ~50 tokens
- [ ] Test assistant message compression → ~200 tokens
- [ ] Test LLM failure → fallback truncation works
- [ ] Test empty/short messages → handled gracefully

---

### Phase 5: Implement Main Compression Function (30 min)

**Goal:** Orchestrate the entire compression process

**Function:** `compressMessageHistory()`

**Tasks:**
- [ ] Implement main compression loop
- [ ] Track compression statistics
- [ ] Handle target token achievement
- [ ] Add comprehensive debug logging
- [ ] Calculate compression ratio

**Code:**
```zig
pub fn compressMessageHistory(
    allocator: mem.Allocator,
    messages: []const Message,
    tracker: *tracking.ContextTracker,
    token_tracker: *compression.TokenTracker,
    config: compression.CompressionConfig,
    llm_provider: anytype,
) !CompressionResult {
    
    debugPrint("Starting compression...\n", .{});
    debugPrint("  Original messages: {d}\n", .{messages.len});
    debugPrint("  Original tokens: {d}\n", .{token_tracker.estimated_tokens_used});
    debugPrint("  Target tokens: {d}\n", .{token_tracker.getTargetTokens(config)});
    
    var stats = CompressionStats{
        .total_messages_processed = messages.len,
    };
    
    const original_tokens = token_tracker.estimated_tokens_used;
    const target_tokens = token_tracker.getTargetTokens(config);
    
    // Step 1: Identify protected messages
    const protected = try identifyProtectedMessages(allocator, messages);
    defer allocator.free(protected);
    
    for (protected) |is_protected| {
        if (is_protected) stats.messages_protected += 1;
    }
    
    // Step 2: Compress messages
    var compressed = std.ArrayList(Message).init(allocator);
    errdefer {
        for (compressed.items) |*msg| {
            allocator.free(msg.content);
            allocator.free(msg.processed_content);
            if (msg.thinking_content) |tc| allocator.free(tc);
        }
        compressed.deinit();
    }
    
    for (messages, 0..) |msg, idx| {
        if (protected[idx]) {
            // Protected - keep as-is
            try compressed.append(try cloneMessage(allocator, msg));
            continue;
        }
        
        // Compress based on message type
        const compressed_msg = switch (msg.role) {
            .tool => blk: {
                stats.tool_results_compressed += 1;
                break :blk try compressToolMessage(allocator, msg, tracker);
            },
            .user => blk: {
                stats.user_messages_compressed += 1;
                break :blk try compressUserMessage(allocator, msg, llm_provider);
            },
            .assistant => blk: {
                stats.assistant_messages_compressed += 1;
                break :blk try compressAssistantMessage(allocator, msg, llm_provider);
            },
            .display_only_data => blk: {
                stats.display_data_deleted += 1;
                debugPrint("  Skipping display_only_data message\n", .{});
                continue; // Skip entirely
            },
            .system => try cloneMessage(allocator, msg), // Keep system
        };
        
        try compressed.append(compressed_msg);
        
        // Check if reached target
        const current_tokens = estimateTokens(compressed.items);
        if (current_tokens <= target_tokens) {
            debugPrint("  Reached target! Current: {d}, Target: {d}\n", 
                .{current_tokens, target_tokens});
            
            // Keep remaining messages as-is
            if (idx + 1 < messages.len) {
                for (messages[idx+1..]) |remaining_msg| {
                    try compressed.append(try cloneMessage(allocator, remaining_msg));
                }
            }
            break;
        }
    }
    
    const compressed_tokens = estimateTokens(compressed.items);
    const ratio = @as(f32, @floatFromInt(compressed_tokens)) / 
                  @as(f32, @floatFromInt(original_tokens));
    
    debugPrint("\n=== Compression Complete ===\n", .{});
    debugPrint("  Messages: {d} → {d}\n", .{messages.len, compressed.items.len});
    debugPrint("  Tokens: {d} → {d}\n", .{original_tokens, compressed_tokens});
    debugPrint("  Reduction: {d:.1}%\n", .{(1.0 - ratio) * 100.0});
    debugPrint("  Stats:\n", .{});
    debugPrint("    Tool results compressed: {d}\n", .{stats.tool_results_compressed});
    debugPrint("    User messages compressed: {d}\n", .{stats.user_messages_compressed});
    debugPrint("    Assistant messages compressed: {d}\n", .{stats.assistant_messages_compressed});
    debugPrint("    Display data deleted: {d}\n", .{stats.display_data_deleted});
    debugPrint("    Messages protected: {d}\n", .{stats.messages_protected});
    debugPrint("===========================\n\n", .{});
    
    if (compressed_tokens > target_tokens) {
        debugPrint("WARNING: Could not reach target tokens ({d} > {d})\n", 
            .{compressed_tokens, target_tokens});
    }
    
    return CompressionResult{
        .compressed_messages = try compressed.toOwnedSlice(),
        .original_tokens = original_tokens,
        .compressed_tokens = compressed_tokens,
        .compression_ratio = ratio,
        .stats = stats,
    };
}

fn cloneMessage(allocator: mem.Allocator, msg: Message) !Message {
    return Message{
        .role = msg.role,
        .content = try allocator.dupe(u8, msg.content),
        .processed_content = try allocator.dupe(u8, msg.processed_content),
        .timestamp = msg.timestamp,
        .tool_calls = msg.tool_calls,
        .tool_call_id = msg.tool_call_id,
        .thinking_content = if (msg.thinking_content) |tc|
            try allocator.dupe(u8, tc) else null,
        .thinking_expanded = msg.thinking_expanded,
    };
}

fn estimateTokens(messages: []const Message) usize {
    var total: usize = 0;
    for (messages) |msg| {
        total += compression.TokenTracker.estimateMessageTokens(msg.content);
    }
    return total;
}
```

**Verification:**
- [ ] Test full compression flow with mixed messages
- [ ] Verify protected messages unchanged
- [ ] Verify compression stats accurate
- [ ] Verify target token achievement (or warning logged)

---

### Phase 6: Wire Up Compression in app.zig (20 min)

**Goal:** Integrate compression into the main application loop

**Tasks:**
- [ ] Add compressor import to app.zig
- [ ] Add compression trigger after token tracking
- [ ] Replace message history with compressed version
- [ ] Recalculate token tracker
- [ ] Add debug output

**Code to add in app.zig:**
```zig
// At top of file, add import:
const compressor = @import("compressor");

// In sendMessage(), replace existing needsCompression check:
if (tracker.needsCompression(self.compression_config)) {
    if (std.posix.getenv("DEBUG_CONTEXT")) |_| {
        std.debug.print("[CONTEXT] Token limit approaching: {d}/{d}\n", .{
            tracker.estimated_tokens_used,
            tracker.max_context_tokens,
        });
        std.debug.print("[CONTEXT] Triggering compression...\n", .{});
    }
    
    // Perform compression
    const result = try compressor.compressMessageHistory(
        self.allocator,
        self.messages.items,
        &self.context_tracker,
        tracker,
        self.compression_config,
        self.llm_provider,
    );
    defer result.deinit(self.allocator);
    
    // Clean up old messages
    for (self.messages.items) |*msg| {
        self.allocator.free(msg.content);
        self.allocator.free(msg.processed_content);
        if (msg.thinking_content) |tc| self.allocator.free(tc);
    }
    self.messages.clearRetainingCapacity();
    
    // Replace with compressed messages
    try self.messages.appendSlice(self.allocator, result.compressed_messages);
    
    // Recalculate token tracker
    tracker.reset();
    for (self.messages.items, 0..) |msg, idx| {
        const role_enum: compression.MessageRole = switch (msg.role) {
            .user => .user,
            .assistant => .assistant,
            .system => .system,
            .tool => .tool,
            .display_only_data => .display_only_data,
        };
        try tracker.trackMessage(idx, msg.content, role_enum);
    }
    
    if (std.posix.getenv("DEBUG_CONTEXT")) |_| {
        std.debug.print(
            "[CONTEXT] Compression successful: {d} → {d} tokens ({d:.1}% reduction)\n",
            .{
                result.original_tokens,
                result.compressed_tokens,
                (1.0 - result.compression_ratio) * 100.0,
            }
        );
    }
}
```

**Verification:**
- [ ] Compression triggers at 70%
- [ ] Message history replaced correctly
- [ ] Token tracker recalculated
- [ ] Debug output shows compression stats

---

### Phase 7: Add Compressor Module to build.zig (10 min)

**Goal:** Make compressor.zig available as a module

**Tasks:**
- [ ] Add compressor module definition
- [ ] Add dependencies (tracking, compression, types)
- [ ] Add to app module imports

**Code to add in build.zig:**
```zig
// After compression module definition:
const compressor_module = b.addModule("compressor", .{
    .root_source_file = b.path("context_management/compressor.zig"),
});
compressor_module.addImport("tracking", tracking_module);
compressor_module.addImport("compression", compression_module);

// Add to app module:
app_module.addImport("compressor", compressor_module);
```

**Verification:**
- [ ] Build succeeds: `zig build`
- [ ] No circular dependency errors

---

### Phase 8: Testing (30 min)

**Goal:** Verify compression works end-to-end

**Test Cases:**

**Test 1: Basic Compression**
```
Setup: Create conversation with 60k tokens
- 5 recent user+assistant messages (5k tokens)
- 10 old user+assistant messages (10k tokens)
- 5 tool results (45k tokens)

Expected:
- Recent messages protected (unchanged)
- Old messages compressed
- Tool results compressed heavily
- Final tokens ~30-35k (target 32k)
```

**Test 2: Protected Messages**
```
Setup: Create 10 user+assistant messages only

Expected:
- Last 5 protected
- First 5 compressed
- Protected messages byte-identical to originals
```

**Test 3: Tool Compression with Cache**
```
Setup: read_file tool with curator cache available

Expected:
- Tool result compressed to ~150 tokens
- Summary includes curator summary text
- References cache availability
```

**Test 4: LLM Compression Failure**
```
Setup: Mock LLM to return error

Expected:
- Fallback truncation used
- No crash
- Debug log shows fallback used
```

**Verification:**
- [ ] All tests pass
- [ ] No memory leaks (run with GPA leak detection)
- [ ] Performance acceptable (compression < 5 seconds)

---

### Phase 9: Documentation Updates (15 min)

**Goal:** Update documentation to reflect completion

**Tasks:**
- [ ] Update `CONTEXT_MANAGEMENT_CHANGES.md`
  - Change "No Compression Implementation" to "Compression Implemented"
  - Add compression algorithm section
  - Update known issues
- [ ] Update `COMPRESSION_DESIGN.md`
  - Mark as "IMPLEMENTED"
  - Add actual performance metrics
- [ ] Add compression example to README (optional)

---

## Implementation Order

```
Day 1 (2 hours):
  Phase 1: Structure (20 min) ✓
  Phase 2: Protected messages (15 min) ✓
  Phase 3: Tool compression (45 min) ✓
  Phase 7: Build integration (10 min) ✓
  [Checkpoint: Build and test tool compression]
  
Day 1 (1.5 hours):  
  Phase 4: LLM compression (60 min)
  Phase 5: Main function (30 min)
  [Checkpoint: Build and test full compression]
  
Day 2 (1 hour):
  Phase 6: App integration (20 min)
  Phase 8: Testing (30 min)
  Phase 9: Documentation (10 min)
  [Complete: Ship it!]
```

---

## Success Criteria

**Must Have:**
- ✅ Compression triggers at 70% token usage
- ✅ Reduces to ~40% (32k/80k tokens)
- ✅ Last 5 user+assistant messages protected
- ✅ Tool results compressed using metadata
- ✅ Conversations compressed using LLM
- ✅ No memory leaks
- ✅ Build succeeds

**Nice to Have:**
- ✅ Compression completes in < 5 seconds
- ✅ Compression ratio > 50% reduction
- ✅ Debug output comprehensive and useful
- ✅ Handles edge cases gracefully

---

## Risk Mitigation

**Risk 1: LLM compression too slow**
- Mitigation: Add timeout, fall back to truncation
- Fallback: Use truncation-only compression (no LLM)

**Risk 2: Can't reach 40% target**
- Mitigation: Log warning, accept higher token count
- Alternative: Compress more aggressively (reduce protected from 5 to 3)

**Risk 3: LLM API issues (generateCompletion doesn't exist)**
- Mitigation: Check LLM provider API first
- Fallback: Skip LLM compression, use metadata-only

**Risk 4: Compressed messages break UI**
- Mitigation: Test compressed message rendering
- Fallback: Add special rendering for compressed messages

---

## Next Steps

1. **Start Phase 1** - Create compressor.zig structure
2. **Checkpoint after Phase 3** - Verify tool compression works
3. **Checkpoint after Phase 5** - Verify full compression works
4. **Integration** - Wire up to app.zig
5. **Test** - Verify with real conversations
6. **Ship** - Update docs and merge

---

**Ready to begin? Let's start with Phase 1!**
