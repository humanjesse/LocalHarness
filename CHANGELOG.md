# Changelog

All notable changes to Local Harness will be documented in this file.

## [Unreleased] - 2025-10-27

### Added
- **Provider Registry System** - Centralized provider capabilities and metadata:
  - **ProviderRegistry** - Single source of truth for all provider capabilities
  - **Config validation** - Automatically validates provider compatibility and settings
  - **Runtime capability checks** - Features only enabled if provider supports them
  - **Dynamic config editor** - Provider list and warnings auto-generated from registry
  - **Provider-specific warnings** - Context size notes for LM Studio shown in UI
  - Benefits:
    - Add new providers by updating one file (`llm_provider.zig`)
    - Validation shows helpful warnings for incompatible settings
    - No hardcoded provider checks scattered in codebase
    - UI automatically adapts to provider capabilities

- **LM Studio Support** - Multiple LLM backend support via provider abstraction:
  - **New provider system** with tagged union architecture (`llm_provider.zig`)
  - **LM Studio client** with OpenAI-compatible API support (`lmstudio.zig`)
  - **Provider capabilities detection** - Each provider reports supported features
  - **Graceful feature handling** - Unsupported features (e.g., Ollama's `think` mode on LM Studio) are silently ignored
  - **Configuration:**
    ```json
    {
      "provider": "ollama",  // or "lmstudio"
      "ollama_host": "http://localhost:11434",
      "lmstudio_host": "http://localhost:1234"
    }
    ```
  - **Supported features:**
    - Chat streaming with SSE (Server-Sent Events) parsing
    - Tool/function calling (same format as Ollama)
    - Embeddings (single and batch)
    - All existing tools work with both providers
    - GraphRAG indexing works with both providers
    - Agent system works with both providers

- **Provider-Aware Embeddings for GraphRAG** - Unified embeddings interface supporting both Ollama and LM Studio:
  - **Generic Embedder Interface** (`embedder_interface.zig`) - Union type dispatching to provider-specific implementations
  - **Provider-aware initialization** - App automatically creates correct embedder based on configured provider
  - **Config Editor UI** - Added "Embedding Model" and "Indexing Model" fields to Provider Settings section
  - **Validation** - GraphRAG config validation warns if embedding/indexing models are empty
  - **Debug transparency** - `DEBUG_GRAPHRAG=1` shows model and provider configuration during indexing
  - **Updated defaults** - Changed default embedding model from `embeddinggemma:300m` to `nomic-embed-text` for better availability
  - **HTTP API fix** - Fixed LM Studio batch embeddings to use correct Zig 0.15.2 HTTP response reading
  - **Configuration:**
    ```json
    {
      "graph_rag_enabled": true,
      "embedding_model": "nomic-embed-text",  // Works with both providers
      "indexing_model": "llama3.1:8b"         // Model for file analysis
    }
    ```

### Changed
- **Provider abstraction layer** - All LLM interactions now go through unified interface:
  - `app.zig`: Uses `LLMProvider` instead of `OllamaClient`
  - `context.zig`: `AppContext` now holds `LLMProvider`
  - `agents.zig`: `AgentContext` updated for provider abstraction
  - `agent_executor.zig`: Tool execution uses provider interface
  - `llm_helper.zig`: Helper functions now provider-agnostic
  - `graphrag/llm_indexer.zig`: Indexing uses provider interface
  - `tools/read_file.zig`: File curator agent uses provider

### Technical Details
- **New files:**
  - `llm_provider.zig` (370 lines) - Provider abstraction and factory
  - `lmstudio.zig` (630 lines) - LM Studio OpenAI-compatible client
  - `embedder_interface.zig` (41 lines) - Generic embedder interface for both providers
- **Modified files:**
  - `config.zig` (+30 lines) - Provider selection, LM Studio host, GraphRAG validation
  - `app.zig` (~70 lines changed) - Provider initialization, embedder initialization
  - `context.zig` (5 lines) - Context struct update, generic embedder type
  - `agents.zig` (5 lines) - Agent context update, generic embedder type
  - `agent_executor.zig` (10 lines) - Provider usage
  - `llm_helper.zig` (5 lines) - Generic provider parameter
  - `graphrag/llm_indexer.zig` (15 lines) - Provider interface, debug output
  - `tools/read_file.zig` (5 lines) - Provider usage
  - `app_graphrag.zig` (5 lines) - Provider usage
  - `config_editor_state.zig` (15 lines) - Added embedding/indexing model fields
  - `config_editor_input.zig` (8 lines) - Input handlers for new fields
  - `config_editor_renderer.zig` (0 lines) - Reuses existing text input renderer
- **Architecture:**
  - Tagged union pattern (`union(enum)`) for zero-cost abstraction
  - Type-safe provider dispatch via Zig's compile-time `switch`
  - Provider-specific implementations isolated in separate files
  - Capability system allows runtime feature detection
  - Factory pattern for provider instantiation

### Benefits
- ✅ **Multi-backend support** - Choose between Ollama and LM Studio
- ✅ **Performance testing** - Easy to compare providers on different hardware
- ✅ **Future-proof** - Easy to add OpenAI, Anthropic, or other providers
- ✅ **Zero overhead** - Tagged union compiles to direct calls, no vtable
- ✅ **Type safety** - Compiler enforces all providers implement full interface
- ✅ **Clean separation** - Provider-specific code isolated from app logic

### Use Cases
- **AMD GPU users**: LM Studio may provide better performance/compatibility
- **Model experimentation**: Easy switching between provider ecosystems
- **Redundancy**: Fallback if one provider is unavailable
- **Feature comparison**: Test same conversation on different backends

---

## [Unreleased] - 2025-10-26

### Added
- **Unified Progress Display System (Phase 2)** - All LLM sub-tasks now share a consistent progress display:
  - **`ProgressDisplayContext`** replaces both `AgentProgressContext` and `IndexingProgressContext`
  - **Extended `ProgressUpdateType`** enum with GraphRAG-specific events (`.embedding`, `.storage`)
  - **`finalizeProgressMessage()`** provides unified finalization with beautiful formatting
  - GraphRAG indexing now displays with same polish as agent messages
  - Execution time, statistics (nodes/edges/embeddings), and collapse/expand support
  - Auto-collapse on completion to save screen space
  - ~100 lines of duplication eliminated across app.zig, app_graphrag.zig, and llm_indexer.zig
  - Files modified: agents.zig, message_renderer.zig, app.zig, app_graphrag.zig, graphrag/llm_indexer.zig
  - See `AGENT_ARCHITECTURE.md` for detailed documentation

- **Real-Time Agent Progress Streaming** - File curator agent now streams thinking and analysis in real-time:
  - See agent's thinking as it analyzes files (character-by-character streaming)
  - Live updates showing curation decisions and reasoning
  - Progress shown via temporary message that updates during execution
  - Automatic cleanup after completion (final result shown separately)
  - Full transparency into agent decision-making process
  - Implemented via `AgentProgressContext` and progress callbacks through `AppContext`

- **Unified read_file Context Management** - Intelligent file reading with automatic mode detection:
  - **Smart auto-detection** based on file size (configurable thresholds):
    - Small files (<100 lines): Full content, no agent overhead
    - Medium files (100-500 lines): Conversation-aware curation
    - Large files (>500 lines): Structure extraction only
  - **New structure extraction mode** - Shows file skeleton only (imports, types, function signatures)
  - **Configuration support** - User-tunable thresholds in `config.json`:
    ```json
    {
      "file_read_small_threshold": 100,
      "file_read_large_threshold": 500
    }
    ```

### Changed
- **file_curator agent enhanced** with dual-mode support:
  - Added `STRUCTURE_SYSTEM_PROMPT` for skeleton extraction
  - Added public APIs: `curateForRelevance()`, `extractStructure()`
  - Modified `formatCuratedFile()` to accept mode label
- **read_file tool completely rewritten**:
  - Now intelligently adapts based on file size
  - Uses config thresholds instead of hardcoded values
  - Always queues full file for GraphRAG indexing
  - Robust fallback to full file if agent fails
  - Updated tool description for LLM guidance

### Removed
- **read_file_curated tool** - Functionality merged into unified `read_file`
  - Deleted `tools/read_file_curated.zig`
  - Removed from tool registry in `tools.zig`
  - LLM no longer needs to choose between tools

### Benefits
- ✅ **Massive context savings** - 60-88% reduction on first read (Turn 1)
- ✅ **Cumulative efficiency** - Combined with GraphRAG: 90%+ savings across conversations
- ✅ **Simpler mental model** - One primary tool (read_file), one surgical tool (read_lines)
- ✅ **Zero LLM confusion** - Auto-detection removes tool selection burden
- ✅ **Full searchability** - GraphRAG still indexes complete files
- ✅ **User control** - Configurable thresholds for different workflows

### Technical Details

**Context Reduction Metrics:**
| File Size | Old Behavior | New Behavior | Savings |
|-----------|--------------|--------------|---------|
| 50 lines  | 50 (full)    | 50 (full)    | 0%      |
| 150 lines | 150 (full)   | ~60 (curated)| 60%     |
| 300 lines | 300 (full)   | ~120 (curated)| 60%    |
| 1000 lines| 1000 (full)  | ~120 (structure)| 88%  |

**Conversation Example:**
```
Turn 1: read_file("app.zig") [1200 lines]
  Before: 1200 lines in context
  After: 150 lines (structure mode)
  Savings: 88%

Turn 2: User follow-up
  Context: Turn 1 compressed to 50 lines (GraphRAG)
  Cumulative: 93% context reduction
```

**Files Modified:**
- `agents/file_curator.zig` (+160 lines) - Dual-mode agent support
- `tools/read_file.zig` (complete rewrite) - Smart auto-detection
- `tools.zig` (-1 tool import) - Registry cleanup
- `config.zig` (+2 fields) - Threshold configuration

**Documentation:**
- Added `docs/architecture/unified-read-file.md` - Complete design documentation

---

## [Unreleased] - 2025-01-25

### Fixed
- **Tool JSON Display Toggle** - Fixed `/toggle-toolcall-json` command bugs:
  - **Bug #1**: Command didn't trigger immediate redraw during streaming/tool execution
    - Added `should_redraw` check in streaming input handler (app.zig:1974-1983)
    - Screen now redraws immediately when toggling visibility
  - **Bug #2**: Tool JSON messages appeared after streaming ended despite being hidden
    - Normal render path (line 1935-1939) lacked `show_tool_json` filtering
    - Added same filtering logic as `redrawScreen()` function
    - Tool messages now consistently respect visibility setting

### Refactored
- **GraphRAG Module Extraction** - Separated GraphRAG integration from core app logic:
  - Created `app_graphrag.zig` (642 lines, 25KB) with all GraphRAG functionality
  - Reduced `app.zig` from 2,057 lines (91KB) to 1,377 lines (63KB) - **33% smaller**
  - **Extracted components:**
    - Helper functions: `isReadFileResult()`, `extractFilePathFromResult()`
    - Progress tracking: `IndexingProgressContext`, `indexingProgressCallback()`
    - Message updates: `updateMessageWithLineRange()`, `updateMessageWithMetadata()`
    - State machines: `processPendingIndexing()`, `processQueuedFiles()` (~460 lines)
  - Made `maintainBottomAnchor()` and `updateCursorToBottom()` public for module access
  - All GraphRAG functions now accessed via `app_graphrag.*` namespace

### Benefits
- ✅ **Cleaner separation** - GraphRAG features isolated in dedicated module
- ✅ **Improved readability** - Core app loop 33% shorter, easier to understand
- ✅ **Better maintainability** - GraphRAG changes won't clutter main app file
- ✅ **Modular architecture** - GraphRAG feels like a clean plugin
- ✅ **Consistent UX** - Tool JSON visibility toggle works correctly in all modes

### Technical Details
- Modified `app.zig` (2,057 → 1,377 lines):
  - Removed 680 lines of GraphRAG code
  - Added `app_graphrag` import
  - Updated 4 call sites to use new module
  - Made 2 functions public for module access
- Created `app_graphrag.zig` (642 lines):
  - 7 public functions for GraphRAG operations
  - Operates on `*App` parameter (stateless module pattern)
  - Full documentation comments preserved

---

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
