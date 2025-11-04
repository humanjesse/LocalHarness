// File Curator Agent - Analyzes files and curates important line ranges for context
const std = @import("std");
const agent_executor = @import("agent_executor");
const app_module = @import("app");
const agents_module = app_module.agents_module; // Get agents from app
const llm_helper = @import("llm_helper");

const AgentDefinition = agents_module.AgentDefinition;
const AgentContext = agents_module.AgentContext;
const AgentResult = agents_module.AgentResult;
const AgentCapabilities = agents_module.AgentCapabilities;
const ProgressCallback = agents_module.ProgressCallback;

/// System prompt for conversation-aware relevance curation
pub const CURATOR_SYSTEM_PROMPT =
    \\You are a code context curator analyzing files for an ongoing conversation.
    \\
    \\IMPORTANT: The user prompt may include conversation context showing what the user
    \\is asking about. Use this to curate INTELLIGENTLY based on RELEVANCE.
    \\
    \\PRIMARY STRATEGY (if conversation context provided):
    \\1. What is the user investigating? What concepts, functions, or features?
    \\2. Keep ONLY code directly related to their questions/interests
    \\3. Be AGGRESSIVE - omit even structurally important code if it's not relevant
    \\4. The user can always ask for more - prioritize relevance over completeness
    \\
    \\Example: User asks "How does error handling work?"
    \\  → Keep: Error types, error handling code, error propagation
    \\  → Omit: Happy path logic, imports, initialization, unrelated functions
    \\  → Result: Maybe only 10-20% of file, but HIGHLY relevant
    \\
    \\FALLBACK STRATEGY (if no conversation context):
    \\Curate based on code structure:
    \\  KEEP: Imports, type definitions, function signatures, complex logic, public APIs
    \\  OMIT: Verbose comments, boilerplate, simple getters, test data, auto-generated code
    \\  Target: 30-50% preservation
    \\
    \\RULES (always apply):
    \\1. Preserve continuity - don't create fragmented snippets
    \\2. Include enough context to understand each preserved section
    \\3. Each line range should be 3+ lines minimum (avoid single-line snippets)
    \\4. Line ranges are INCLUSIVE (start and end lines are both included)
    \\5. Explain your reasoning in the "reason" field for each range
    \\
    \\RESPOND WITH ONLY VALID JSON (no markdown, no explanation):
    \\{
    \\  "line_ranges": [
    \\    {"start": 1, "end": 15, "reason": "error type definitions (user asked about errors)"},
    \\    {"start": 45, "end": 78, "reason": "error handling in main function"}
    \\  ],
    \\  "summary": "Omitted: happy path logic, initialization, unrelated helpers (not relevant to error handling question)",
    \\  "preserved_percentage": 18
    \\}
;


/// Get the agent definition
pub fn getDefinition(allocator: std.mem.Allocator) !AgentDefinition {
    // Allocate and copy strings that need to persist
    const name = try allocator.dupe(u8, "file_curator");
    const description = try allocator.dupe(u8, "Analyzes file content and curates important line ranges for context");

    return .{
        .name = name,
        .description = description,
        .system_prompt = CURATOR_SYSTEM_PROMPT,
        .capabilities = .{
            .allowed_tools = &.{}, // No tools needed - pure analysis
            .max_iterations = 2, // Usually completes in 1, allow 2 for retry
            .model_override = null, // Use same model as main app (or could use faster model)
            .temperature = 0.3, // Lower temperature for more consistent output
            .num_ctx = 32768, // Large context for big files (doubled from 16k)
            .num_predict = 2000, // Enough for JSON response
            .enable_thinking = true, // Enable to show reasoning process to user
            .format = "json", // Force JSON output for consistent parsing
        },
        .execute = execute,
    };
}

/// Execute the file curator agent
fn execute(
    allocator: std.mem.Allocator,
    context: AgentContext,
    task: []const u8,
    progress_callback: ?ProgressCallback,
    callback_user_data: ?*anyopaque,
) !AgentResult {
    const start_time = std.time.milliTimestamp();

    // Initialize agent executor
    var executor = agent_executor.AgentExecutor.init(allocator, context.capabilities);
    defer executor.deinit();

    // Run the agent (no tools available for curator)
    const empty_tools: []const @import("ollama").Tool = &.{};

    const result = executor.run(
        context,
        CURATOR_SYSTEM_PROMPT,
        task,
        empty_tools,
        progress_callback,
        callback_user_data,
    ) catch |err| {
        const end_time = std.time.milliTimestamp();
        const stats = agents_module.AgentStats{
            .iterations_used = executor.iterations_used,
            .tool_calls_made = 0,
            .execution_time_ms = end_time - start_time,
        };
        const error_msg = try std.fmt.allocPrint(
            allocator,
            "File curator execution failed: {}",
            .{err},
        );
        defer allocator.free(error_msg);
        return try AgentResult.err(allocator, error_msg, stats);
    };

    return result;
}

/// Curation result structure (for parsing agent output)
pub const CurationResult = struct {
    line_ranges: []LineRange,
    summary: []const u8,
    preserved_percentage: ?f32 = null,

    pub const LineRange = struct {
        start: usize,
        end: usize,
        reason: []const u8,
    };
};

/// Parse and validate curation result from agent
pub fn parseCurationResult(
    allocator: std.mem.Allocator,
    json_response: []const u8,
) !std.json.Parsed(CurationResult) {
    return try llm_helper.parseJSONResponse(allocator, CurationResult, json_response);
}

/// Format file content with curated line ranges
/// Returns a formatted string showing only the curated lines with context
pub fn formatCuratedFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    full_content: []const u8,
    curation: CurationResult,
) ![]const u8 {
    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    // Split content into lines
    var lines = std.ArrayListUnmanaged([]const u8){};
    defer lines.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, full_content, '\n');
    while (line_iter.next()) |line| {
        try lines.append(allocator, line);
    }

    const total_lines = lines.items.len;

    // Calculate actual preserved lines
    var preserved_line_count: usize = 0;
    for (curation.line_ranges) |range| {
        if (range.end >= range.start and range.end <= total_lines) {
            preserved_line_count += (range.end - range.start + 1);
        }
    }

    const preserved_pct = if (total_lines > 0)
        @as(f32, @floatFromInt(preserved_line_count)) / @as(f32, @floatFromInt(total_lines)) * 100.0
    else
        0.0;

    // Write header with metadata
    try writer.writeAll("```\n");
    try writer.print("File: {s} (curated)\n", .{file_path});
    try writer.print("Total lines: {d} | Preserved: {d} ({d:.1}%)\n", .{
        total_lines,
        preserved_line_count,
        preserved_pct,
    });
    try writer.print("Curation summary: {s}\n", .{curation.summary});
    try writer.writeAll("\nContent (curated line ranges):\n\n");

    // Write each curated range
    for (curation.line_ranges, 0..) |range, idx| {
        // Validate range
        if (range.start < 1 or range.start > total_lines) {
            continue; // Skip invalid range
        }
        if (range.end < range.start or range.end > total_lines) {
            continue; // Skip invalid range
        }

        // Write range header
        try writer.print("--- Lines {d}-{d}: {s} ---\n", .{
            range.start,
            range.end,
            range.reason,
        });

        // Write lines (convert to 0-indexed)
        const start_idx = range.start - 1;
        const end_idx = range.end - 1;

        for (lines.items[start_idx .. end_idx + 1], start_idx..) |line, line_idx| {
            try writer.print("{d}: {s}\n", .{ line_idx + 1, line });
        }

        // Add spacing between ranges
        if (idx < curation.line_ranges.len - 1) {
            try writer.writeAll("\n... (lines omitted) ...\n\n");
        }
    }

    // Write footer
    try writer.writeAll("\nNote: This is a curated view. Full file available in GraphRAG index.\n");
    try writer.writeAll("```");

    return try output.toOwnedSlice(allocator);
}

// ============================================================================
// Public API for read_file tool
// ============================================================================

/// Curate file for relevance to ongoing conversation (all files above small threshold)
/// Uses conversation-aware CURATOR_SYSTEM_PROMPT which adapts to file size naturally
pub fn curateForRelevance(
    allocator: std.mem.Allocator,
    context: AgentContext,
    file_content: []const u8,
    conversation_context: ?[]const u8,
    progress_callback: ?ProgressCallback,
    callback_user_data: ?*anyopaque,
) !AgentResult {
    // Format content with line numbers
    var numbered_content = std.ArrayListUnmanaged(u8){};
    defer numbered_content.deinit(allocator);
    const writer = numbered_content.writer(allocator);

    var line_iter = std.mem.splitScalar(u8, file_content, '\n');
    var line_num: usize = 1;
    while (line_iter.next()) |line| : (line_num += 1) {
        try writer.print("{d}: {s}\n", .{ line_num, line });
    }

    const numbered = try numbered_content.toOwnedSlice(allocator);
    defer allocator.free(numbered);

    // Build task prompt with optional conversation context
    const task = if (conversation_context) |conv_ctx|
        try std.fmt.allocPrint(
            allocator,
            "{s}\nAnalyze this file and curate lines RELEVANT to the conversation above:\n\n{s}",
            .{ conv_ctx, numbered },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "Analyze this file and curate the most important structural elements:\n\n{s}",
            .{numbered},
        );
    defer allocator.free(task);

    // Run agent with curated mode
    return runCuration(allocator, context, task, CURATOR_SYSTEM_PROMPT, progress_callback, callback_user_data);
}


/// Internal helper: Run curation agent with specified system prompt
fn runCuration(
    allocator: std.mem.Allocator,
    context: AgentContext,
    task: []const u8,
    system_prompt: []const u8,
    progress_callback: ?ProgressCallback,
    callback_user_data: ?*anyopaque,
) !AgentResult {
    const start_time = std.time.milliTimestamp();

    // Initialize agent executor
    var executor = agent_executor.AgentExecutor.init(allocator, context.capabilities);
    defer executor.deinit();

    // Run the agent (no tools available for curator)
    const empty_tools: []const @import("ollama").Tool = &.{};

    const result = executor.run(
        context,
        system_prompt,
        task,
        empty_tools,
        progress_callback,
        callback_user_data,
    ) catch |err| {
        const end_time = std.time.milliTimestamp();
        const stats = agents_module.AgentStats{
            .iterations_used = executor.iterations_used,
            .tool_calls_made = 0,
            .execution_time_ms = end_time - start_time,
        };
        const error_msg = try std.fmt.allocPrint(
            allocator,
            "File curation failed: {}",
            .{err},
        );
        defer allocator.free(error_msg);
        return try AgentResult.err(allocator, error_msg, stats);
    };

    return result;
}
