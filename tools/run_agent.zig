// run_agent tool - Execute a user-defined agent
const std = @import("std");
const ollama = @import("../ollama.zig");
const tools_module = @import("../tools.zig");
const context_module = @import("../context.zig");
const agents_module = @import("../agents.zig");

const ToolDefinition = tools_module.ToolDefinition;
const ToolResult = tools_module.ToolResult;
const AppContext = context_module.AppContext;

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "run_agent"),
                .description = try allocator.dupe(u8, "Execute a specialized agent to perform a task. Agents are sub-systems with specific capabilities and tools. Use 'list_agents' to see available agents. Each agent has a defined role and set of allowed tools."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "required": ["agent", "task"],
                    \\  "properties": {
                    \\    "agent": {
                    \\      "type": "string",
                    \\      "description": "Name of the agent to run (e.g., 'code_reviewer', 'doc_writer')"
                    \\    },
                    \\    "task": {
                    \\      "type": "string",
                    \\      "description": "Description of the task for the agent to perform"
                    \\    }
                    \\  }
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "run_agent",
            .description = "Execute a specialized agent",
            .risk_level = .medium, // Medium risk - agents can execute tools
            .required_scopes = &.{.execute_commands},
        },
        .execute = execute,
    };
}

pub fn execute(
    allocator: std.mem.Allocator,
    arguments: []const u8,
    context: *AppContext,
) !ToolResult {
    const start_time = std.time.milliTimestamp();

    // Parse arguments
    const Args = struct {
        agent: []const u8,
        task: []const u8,
    };

    const parsed = std.json.parseFromSlice(Args, allocator, arguments, .{}) catch {
        return try ToolResult.err(
            allocator,
            .parse_error,
            "Invalid arguments. Expected: {\"agent\": \"name\", \"task\": \"description\"}",
            start_time,
        );
    };
    defer parsed.deinit();

    // Get agent registry from app context
    const agent_registry = context.agent_registry orelse {
        return try ToolResult.err(
            allocator,
            .internal_error,
            "Agent registry not initialized",
            start_time,
        );
    };

    // Look up agent
    const agent_def = agent_registry.get(parsed.value.agent) orelse {
        const err_msg = try std.fmt.allocPrint(
            allocator,
            "Agent '{s}' not found. Use 'list_agents' to see available agents.",
            .{parsed.value.agent},
        );
        defer allocator.free(err_msg);
        return try ToolResult.err(
            allocator,
            .not_found,
            err_msg,
            start_time,
        );
    };

    // Update progress context with actual agent name (before execution)
    if (context.agent_progress_user_data) |user_data| {
        const ProgressDisplayContext = agents_module.ProgressDisplayContext;
        const progress_ctx: *ProgressDisplayContext = @ptrCast(@alignCast(user_data));

        // Free old generic name and set actual agent name
        allocator.free(progress_ctx.task_name);
        progress_ctx.task_name = try allocator.dupe(u8, agent_def.name);
    }

    // Build agent context
    const agent_context = agents_module.AgentContext{
        .allocator = allocator,
        .llm_provider = context.llm_provider,
        .config = context.config,
        .system_prompt = agent_def.system_prompt,
        .capabilities = agent_def.capabilities,
        .vector_store = context.vector_store,
        .embedder = context.embedder,
        .recent_messages = context.recent_messages,
    };

    // Execute agent
    var result = try agent_def.execute(
        allocator,
        agent_context,
        parsed.value.task,
        context.agent_progress_callback,
        context.agent_progress_user_data,
    );
    defer result.deinit(allocator);

    // Format result
    if (result.success) {
        const output = try std.fmt.allocPrint(
            allocator,
            "Agent '{s}' completed successfully:\n\n{s}",
            .{ parsed.value.agent, result.data orelse "(no output)" },
        );
        defer allocator.free(output);

        return try ToolResult.ok(
            allocator,
            output,
            start_time,
            result.thinking,
        );
    } else {
        const err_msg = try std.fmt.allocPrint(
            allocator,
            "Agent '{s}' failed: {s}",
            .{ parsed.value.agent, result.error_message orelse "unknown error" },
        );
        defer allocator.free(err_msg);

        return try ToolResult.err(
            allocator,
            .internal_error,
            err_msg,
            start_time,
        );
    }
}
