# Changelog

All notable changes to ZodoLlama will be documented in this file.

## [Unreleased] - 2025-01-24

### Added
- **Read Lines Tool** - New `read_lines` tool for fast, targeted file inspection:
  - **Parameters:**
    - `path` (string): Relative file path
    - `start_line` (integer): First line to read (1-indexed)
    - `end_line` (integer): Last line to read (inclusive)
  - **Features:**
    - 500-line maximum range (prevents abuse)
    - No GraphRAG indexing (instant response)
    - Risk level: `.low` (read-only, no side effects)
    - Same line-numbered format as `read_file`
  - **Use Cases:**
    - Quick edits when line numbers are known
    - Following error messages to specific locations
    - Checking specific functions without full file indexing
    - Spot checks of file sections
  - **Smart Errors:**
    - Out-of-bounds detection: "Line 250 out of range (file has 100 lines)"
    - Range limit: "Requested 800 lines. Maximum is 500. Use read_file for larger ranges."
  - **Architecture:**
    - Does NOT queue for GraphRAG (fast exploration vs full analysis)
    - Does NOT mark file as "read" for edit_file (safety: require full context)
    - Suggests `read_file` when appropriate (footer note in output)

### Benefits
- ✅ **Fast exploration** - Instant results without LLM overhead
- ✅ **Clear separation** - `read_lines` = exploration, `read_file` = analysis
- ✅ **Better UX** - Quicker iterations for simple edits
- ✅ **Resource efficient** - Fewer GraphRAG indexing calls

### Technical Details
- Created `tools/read_lines.zig` (200 lines)
- Updated `tools.zig` - Added import and registry entry
- Follows existing tool patterns (validation, error handling, formatting)

---

## [Unreleased] - 2025-01-23

### Enhanced
- **Grep Search Tool** - Major improvements for LLM exploration flexibility:
  - **New Parameters:**
    - `max_results` (integer, 1-1000): Configurable result limit (default: 200, was 100)
    - `include_hidden` (boolean): Search hidden directories like `.config`, `.cargo` (always skips `.git`)
    - `ignore_gitignore` (boolean): Bypass `.gitignore` to search excluded files
  - **Bug Fixes:**
    - Fixed wildcard matching to work as grep-like substring search (e.g., `fn*init` now finds `function validateInit()` anywhere in line)
    - Renamed `smart_case` to `case_insensitive` for clarity (always true)
    - Fixed gitignore exact matching to avoid false positives (e.g., pattern `node` no longer matches `node_modules`)
  - **UX Improvements:**
    - Output header shows active flags: `[+hidden]`, `[+gitignored]`
    - Better limit-reached feedback with actionable guidance
    - Enhanced tool description explaining new capabilities
  - **Permission Changes:**
    - Risk level changed from `.safe` (auto-approved) to `.low` (ask once per session)
    - Enhanced validator checks `max_results` range (1-1000)
  - **VCS Protection:**
    - Always skips `.git`, `.hg`, `.svn`, `.bzr` directories regardless of flags
  - **Test Coverage:**
    - Added comprehensive test suite (`tools/grep_search_test.zig`, 13 test cases)
    - Tests cover wildcard matching, case insensitivity, gitignore handling, hidden dirs, file filtering, and limits

### Benefits
- ✅ **LLM Freedom** - Can progressively escalate search depth (normal → +hidden → +gitignore)
- ✅ **Correctness** - Wildcard matching and gitignore behavior work as expected
- ✅ **Safety** - User visibility through session approval, VCS dirs always protected
- ✅ **Clarity** - Clear feedback about what's being searched and which flags are active

### Technical Details
- Modified `tools/grep_search.zig` (~150 lines changed/added):
  - Lines 18-46: Updated tool definition and parameters
  - Lines 66-79: Added new fields to SearchContext
  - Lines 85-130: Enhanced argument parsing with validation
  - Lines 206-236: Smart hidden directory handling
  - Lines 256-316: Fixed wildcard matching logic
  - Lines 363-376: Improved gitignore pattern matching
  - Lines 460-520: Enhanced output formatting
  - Lines 519-548: Enhanced validator with range checks
- Created `tools/grep_search_test.zig` (300 lines, 13 test cases)

---

## [Previous Release] - 2025-01-20

### Refactored
- **Tool Executor State Machine** - Extracted tool execution logic into dedicated state machine module:
  - Created `tool_executor.zig` (358 lines) with explicit state enum
  - Removed ~440 lines of duplicate/inline execution logic from `app.zig`
  - Implemented Command Pattern: state machine returns actions, App responds
  - 5 clear states: `idle`, `evaluating_policy`, `awaiting_permission`, `executing`, `completed`
  - Non-blocking `tick()` function advances state without blocking
  - Removed `pending_tool_execution` field, replaced with `tool_executor: ToolExecutor`

### Fixed
- **Memory Safety** - Fixed string literal double-free bug:
  - Removed incorrect `free(eval_result.reason)` calls (5 instances)
  - `PolicyEngine.evaluate()` returns string literals, not heap-allocated strings
  - Attempting to free string literals caused crashes during tool execution
  - Audit logger properly duplicates reason strings for its own storage

### Benefits
- ✅ **Separation of Concerns** - Permission logic isolated from UI logic
- ✅ **Testability** - State transitions can be unit tested independently
- ✅ **Readability** - Explicit state enum vs implicit null checks
- ✅ **Non-blocking** - tick() returns immediately, main loop never blocks
- ✅ **Memory Safety** - Clear ownership, prevents double-free bugs

### Technical Details
- Modified `app.zig` (1352 lines):
  - Removed lines 799-1075 (old inline tool execution)
  - Updated streaming completion to call `tool_executor.startExecution()`
  - Changed main loop to check `tool_executor.hasPendingWork()`
  - App now responds to `TickResult` actions from state machine
- Created `tool_executor.zig` (358 lines):
  - `ToolExecutionState` enum with 5 states
  - `TickResult` enum with 5 action types
  - `tick()` method advances state and returns action
  - Owns tool_calls until completion, manages permission flow
- Updated documentation:
  - `docs/architecture/overview.md` - Added state machine flow diagram
  - `docs/architecture/tool-calling.md` - New "Tool Executor State Machine" section
  - Both docs now reflect current architecture

---

## [Previous Release] - 2025-01-19

### Added
- **Receipt Printer Scroll** - New scrolling behavior that automatically follows streaming content like a receipt printer:
  - Auto-scrolls during streaming to show latest responses
  - Cursor tracks the newest content line continuously
  - Manual scroll detection pauses auto-scroll for current session
  - Auto-scroll resumes when user sends next message
  - Implemented via `user_scrolled_away` state flag in `App` struct

### Fixed
- **Non-blocking Tool Execution** - Tools now execute automatically without requiring user input:
  - Main event loop uses non-blocking input when `pending_tool_execution` is active
  - Tool results appear in real-time as each tool completes
  - Eliminated bug where keypresses (Ctrl+O, scroll) were needed to trigger tool execution
  - Added 10ms sleep to prevent CPU busy-waiting during tool execution

### Changed
- **Viewport Management** - All rendering paths now respect manual scroll state:
  - Streaming render logic checks `user_scrolled_away` flag before auto-scrolling
  - Tool execution rendering maintains receipt printer behavior
  - Permission prompts respect scroll state
  - Master loop iterations honor scroll preferences

### Technical Details
- Modified `app.zig` (1852 → 2006 lines):
  - Added `user_scrolled_away: bool` flag to `App` struct
  - Updated 8 locations to conditionally apply `maintainBottomAnchor()` and `updateCursorToBottom()`
  - Changed main loop condition from `streaming_active` to `streaming_active or pending_tool_execution != null`
- Modified `ui.zig` (553 → 559 lines):
  - Mouse wheel scroll up handler sets `user_scrolled_away = true` during streaming
- Updated README.md feature descriptions and technical details

---

## [Previous Release] - 2025-01-19

### Added (Previous)
- **Structured Tool Results** - All tools now return `ToolResult` struct with:
  - `success` boolean flag
  - `data` and `error_message` fields
  - 7 error type categories (none, not_found, validation_failed, permission_denied, io_error, parse_error, internal_error)
  - Execution metadata (execution_time_ms, data_size_bytes, timestamp)
  - `toJSON()` method for model consumption
  - `formatDisplay()` method for user-facing display with full transparency
  - Proper `deinit()` for memory cleanup

### Changed
- **Tool Execution Flow** - Updated all 6 tools to return structured results:
  - `executeGetFileTree` - Now categorizes tree generation errors
  - `executeReadFile` - Differentiates between not_found, io_error, and parse_error
  - `executeGetCurrentTime` - Returns formatted time with metadata
  - `executeAddTask` - Structured success/failure responses
  - `executeListTasks` - Formatted task list with execution metrics
  - `executeUpdateTask` - Categorized validation and not_found errors
- **Tool Results in Conversation** - Model receives JSON with structured error information instead of plain text
- **User Display** - Tool execution shows status icons (✅/❌), error types, execution time, and data size

### Fixed
- **Memory Leaks** - Fixed 5 memory leaks in tool execution functions:
  - `executeGetCurrentTime` - Added defer for time string allocation
  - `executeAddTask` - Added defer for success message
  - `executeUpdateTask` - Added defer for result message
  - `executeListTasks` - Fixed two leaks (empty message and task list)
  - All tool results now properly freed before return

### Technical Details
- Added 198 lines to `tools.zig` (445 → 643 lines)
- Implemented custom JSON escaping for compatibility with Zig 0.15.2
- Updated `executeToolCall` to return `ToolResult` instead of `[]const u8`
- Modified `App.executeTool` and tool execution loop in `app.zig` to handle structured results
- All tools now track execution time from start to completion

### Documentation
- Updated `TOOL_CALLING.md` with structured results section
- Updated `README.md` features and technical details
- Created `CHANGELOG.md` to track project changes

### Benefits
- ✅ Machine-readable error detection for better AI decision-making
- ✅ Performance metrics for debugging and optimization
- ✅ Type-safe error handling with categorization
- ✅ Execution transparency for users
- ✅ Foundation for future retry logic and error recovery strategies
