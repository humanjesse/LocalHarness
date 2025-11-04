// Compression Agent - Intelligently compresses conversation history using tracked metadata
const std = @import("std");
const agent_executor = @import("agent_executor");
const app_module = @import("app");
const agents_module = app_module.agents_module; // Get agents from app
const tools_module = @import("tools");

const AgentDefinition = agents_module.AgentDefinition;
const AgentContext = agents_module.AgentContext;
const AgentResult = agents_module.AgentResult;
const AgentCapabilities = agents_module.AgentCapabilities;
const ProgressCallback = agents_module.ProgressCallback;

/// System prompt for compression agent
pub const COMPRESSION_AGENT_PROMPT =
    \\You are a conversation compression agent. Your job is to analyze a conversation history
    \\and intelligently compress it to reduce token usage while preserving essential information.
    \\
    \\COMPRESSION PHILOSOPHY:
    \\• Preserve user intent and key questions
    \\• Preserve important decisions and technical details
    \\• Preserve relationships between files, todos, and modifications
    \\• Aggressively compress tool results (use metadata)
    \\• Thoughtfully compress old conversations (preserve meaning)
    \\• NEVER touch protected messages (last 5 user+assistant exchanges)
    \\
    \\AVAILABLE TOOLS:
    \\1. get_compression_metadata - Get tracked metadata about the conversation
    \\2. compress_tool_result - Compress a tool result message using metadata
    \\3. compress_conversation_segment - Compress a range of messages with a summary
    \\4. verify_compression_target - Check if compression target achieved
    \\
    \\COMPRESSION STRATEGY:
    \\
    \\PHASE 1: ANALYZE
    \\• Call get_compression_metadata to understand the conversation
    \\• Identify large tool results (read_file with curator cache available)
    \\• Identify compressible conversation segments (old exchanges)
    \\• Note which messages are protected (last 5 user+assistant)
    \\
    \\PHASE 2: PLAN TOOL COMPRESSION
    \\• Prioritize tool results by size (largest first)
    \\• For read_file: Use 'use_curator_cache' strategy
    \\• For write_file/modify: Use 'use_modification_metadata' strategy
    \\• For other tools: Use 'generic' strategy
    \\• Compress all tool results first (fast, high impact)
    \\
    \\PHASE 3: CHECK PROGRESS
    \\• Call verify_compression_target to see if target achieved
    \\• If target achieved: STOP and report success
    \\• If not: Continue to conversation compression
    \\
    \\PHASE 4: PLAN CONVERSATION COMPRESSION
    \\• Identify old user+assistant message pairs (not in last 5)
    \\• Group related exchanges (same topic/file)
    \\• Create concise summaries that preserve:
    \\  - What the user asked
    \\  - What was decided/implemented
    \\  - Key technical details
    \\• Compress segments from oldest to newest
    \\
    \\PHASE 5: VERIFY
    \\• Call verify_compression_target again
    \\• If target achieved: Report success
    \\• If close (within 1000 tokens): Accept and finish
    \\• If far: Suggest more compression needed
    \\
    \\EXAMPLE WORKFLOW:
    \\
    \\1. get_compression_metadata(include_details: false)
    \\   → Analyze: 50k tokens, 15 tool results, 20 user+assistant messages
    \\
    \\2. For each large tool result:
    \\   compress_tool_result(message_index: X, strategy: "use_curator_cache")
    \\   → Result: 20k tokens → 2k tokens (18k saved!)
    \\
    \\3. verify_compression_target()
    \\   → Check: 30k tokens current, 32k target
    \\   → Status: Close! One more compression should do it.
    \\
    \\4. compress_conversation_segment(start: 5, end: 10, summary: "User asked about streaming implementation, assistant explained queue architecture and threading model")
    \\   → Result: 6 messages → 1 summary (3k saved)
    \\
    \\5. verify_compression_target()
    \\   → Check: 27k tokens, 32k target
    \\   → Status: Target achieved!
    \\
    \\IMPORTANT RULES:
    \\• Work iteratively - compress, verify, compress more if needed
    \\• Start with tool results (biggest wins)
    \\• Don't compress protected messages (tool will reject)
    \\• Be aggressive with tool results, thoughtful with conversations
    \\• If stuck, explain what's preventing further compression
    \\• Maximum 8 iterations - finish within this limit
    \\
    \\RESPOND WITH: Clear explanations of what you're doing and why.
    \\Use tools to perform compressions, not just plan them.
;

/// Get the agent definition
pub fn getDefinition(allocator: std.mem.Allocator) !AgentDefinition {
    const name = try allocator.dupe(u8, "compression_agent");
    const description = try allocator.dupe(u8, "Intelligently compresses conversation history using tracked metadata to reduce token usage");

    return .{
        .name = name,
        .description = description,
        .system_prompt = COMPRESSION_AGENT_PROMPT,
        .capabilities = .{
            .allowed_tools = &.{
                "get_compression_metadata",
                "compress_tool_result",
                "compress_conversation_segment",
                "verify_compression_target",
            },
            .max_iterations = 8, // Needs room for analysis + multiple compressions
            .temperature = 0.3, // Low temperature for consistent, focused compression
            .num_ctx = 16384, // Reasonable context for metadata analysis
            .num_predict = 2000, // Enough for explanations + tool calls
            .enable_thinking = true, // Show reasoning to user
        },
        .execute = execute,
    };
}

/// Execute the compression agent
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

    // Get available tools
    const all_tools = try tools_module.getOllamaTools(allocator);
    defer allocator.free(all_tools);

    // Run the agent with compression tools
    const result = executor.run(
        context,
        COMPRESSION_AGENT_PROMPT,
        task,
        all_tools,
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
            "Compression agent execution failed: {}",
            .{err},
        );
        defer allocator.free(error_msg);
        return try AgentResult.err(allocator, error_msg, stats);
    };

    return result;
}

/// Compression result structure (for parsing agent output if needed)
pub const CompressionPlan = struct {
    tool_compressions: []ToolCompression,
    conversation_compressions: []ConversationCompression,
    expected_tokens_after: usize,

    pub const ToolCompression = struct {
        message_idx: usize,
        strategy: []const u8,
        file: ?[]const u8 = null,
    };

    pub const ConversationCompression = struct {
        start_idx: usize,
        end_idx: usize,
        summary: []const u8,
    };
};
