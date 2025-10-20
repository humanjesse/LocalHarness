# Scratch Space Architecture (Working Memory for Agentic Iteration)

## Overview

ZodoLlama implements a **scratch space** (working memory) system that allows the LLM to iterate on complex tasks without modifying the user's actual files. This is fundamental to agentic behavior.

## The Problem

When building an agentic system where an LLM can:
1. Break down complex tasks
2. Iterate through multiple steps
3. Try different approaches
4. Track its own progress

You need a place for the LLM to **"think" and "remember"** without permanently modifying the user's system.

## The Solution: AppState (Ephemeral Working Memory)

```zig
// state.zig
pub const AppState = struct {
    allocator: mem.Allocator,
    tasks: std.ArrayListUnmanaged(Task),  // LLM's task breakdown
    next_task_id: usize,
    session_start: i64,
    iteration_count: usize,  // Master loop counter
};
```

### Key Properties

✅ **Ephemeral** - Exists only during the session (lost on quit)
✅ **Modifiable by LLM** - Through task management tools
✅ **Fed back to LLM** - Injected into conversation each iteration
✅ **Visible to user** - Shows LLM's thinking process
✅ **No file modifications** - Pure in-memory state

## Master Loop Flow

```
User: "Refactor markdown.zig to be more modular"
   ↓
[Iteration 1 - Planning]
LLM calls: add_task("Analyze current structure")
LLM calls: add_task("Identify separable components")
LLM calls: add_task("Design module boundaries")
→ AppState now has 3 pending tasks
→ injectTaskContext() sends task list back to LLM
   ↓
[Iteration 2 - Analysis]
LLM calls: read_file("markdown.zig")
LLM calls: update_task(1, "in_progress")
LLM thinks: "I see the code has lexer, parser, renderer mixed together"
→ Task list updated, sent back to LLM
   ↓
[Iteration 3 - Completion]
LLM calls: update_task(1, "completed")
LLM responds: "I've analyzed the structure. Here's my refactor plan:
               1. Separate lexer into lexer.zig ✓
               2. Create renderer.zig for output
               3. Keep markdown.zig as orchestrator"
→ User sees the plan, can approve or modify
   ↓
Done (iteration_count = 3 < max_iterations = 10)
```

## Code Flow

### 1. Task Tools Modify Scratch Space

```zig
// tools/add_task.zig:53
const task_id = context.state.addTask(parsed.value.content);
```

Task tools (`add_task`, `list_tasks`, `update_task`) can modify `AppState` through the `AppContext`.

### 2. Scratch Space Injected Each Iteration

```zig
// app.zig:1278-1306
fn injectTaskContext(self: *App) !void {
    const tasks = self.state.getTasks();
    if (tasks.len == 0) return;

    // Build task summary with icons
    try task_summary.appendSlice(self.allocator, "📋 Current Task List:\n");
    for (tasks) |task| {
        const status_icon = switch (task.status) {
            .pending => "⏳",
            .in_progress => "🔄",
            .completed => "✅",
        };
        // Format and inject into conversation
    }
}
```

### 3. Master Loop Bounded by Max Iterations

```zig
// app.zig:1687-1728
self.state.iteration_count += 1;

if (self.state.iteration_count >= self.max_iterations) {
    // Stop to prevent infinite loops
} else {
    // Continue - inject task context and stream next response
    try self.injectTaskContext();
    try self.startStreaming(null);
}
```

## Why This Design?

### Separation of Concerns

| Component | Purpose | Persistence |
|-----------|---------|-------------|
| **AppState (Scratch Space)** | LLM's working memory | Ephemeral (session-only) |
| **User's Files** | Actual codebase | Persistent (disk) |
| **Conversation History** | Messages exchanged | Ephemeral (session-only) |
| **Config/Policies** | User preferences | Persistent (disk) |

### Benefits

1. **Safe Iteration** - LLM can try things without breaking user's code
2. **Transparent Thinking** - User sees LLM's task breakdown
3. **Resumable Work** - Tasks track progress through multi-step operations
4. **Bounded Execution** - Max iterations prevent infinite loops
5. **Clean Separation** - Scratch space vs. permanent changes

## The Pointer Bug (FIXED)

### The Problem

When `App.init()` created the AppContext, it pointed to fields in the local `app` variable:

```zig
// app.zig (OLD - BROKEN)
pub fn init(allocator: mem.Allocator, config: Config) !App {
    var app = App{ ... };

    app.app_context = .{
        .state = &app.state,  // ← Points to LOCAL variable
    };

    return app;  // ← app MOVES, pointer now invalid!
}
```

When `init()` returns, the `app` struct moves to the caller's stack frame. The pointer in `app_context.state` now points to **freed stack memory** → SEGFAULT when task tools try to use it.

### The Fix

```zig
// app.zig (NEW - FIXED)
pub fn init(...) !App {
    var app = App{
        .app_context = undefined,  // Don't set pointers yet
    };
    return app;
}

pub fn fixContextPointers(self: *App) void {
    self.app_context = .{
        .state = &self.state,  // ← NOW points to final location
    };
}

// main.zig
var app = App.init(allocator, config);
app.fixContextPointers();  // Fix pointers after app is in final location
```

Now `&self.state` points to the actual `app.state` field in main.zig's stack frame, which stays valid throughout the program's execution.

## Future Enhancements

### Phase 2: Persistent Scratch Space

For long-running agentic tasks, you might want:

```zig
pub const AppState = struct {
    // Ephemeral (current design)
    tasks: ArrayList(Task),

    // Persistent (future)
    workspace_dir: []const u8,  // ~/.local/share/zodollama/workspace/
    draft_files: HashMap([]const u8, []const u8),  // filename -> content
    execution_log: ArrayList(LogEntry),
};
```

This would allow:
- LLM to create draft files without touching user's code
- Save/resume work across sessions
- Show diffs before applying changes
- Rollback failed attempts

### Phase 3: Multi-Agent Scratch Spaces

If you add multiple agents:

```zig
pub const Workspace = struct {
    agents: HashMap(AgentId, AppState),
    shared_context: SharedContext,
};
```

Each agent gets its own scratch space, but they can share context.

## Key Takeaway

**The scratch space concept you were describing is already implemented!** The `AppState` with task management tools IS your scratch space. It was just broken by a pointer bug, which is now fixed.

Your architectural instinct was correct - agentic systems need a place to iterate without side effects. You built it. Now it works. 🎉

## Testing

```bash
# Test task tools in isolation
zig build test-tools

# Test in actual app
zig build run
> "Break down how to refactor markdown.zig into smaller modules"
# Watch the LLM create tasks, update them, and iterate
```
