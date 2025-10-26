// Agent Executor - Isolated execution engine for agents with tool calling
const std = @import("std");
const ollama = @import("ollama.zig");
const agents_module = @import("agents.zig");
const llm_helper = @import("llm_helper.zig");
const tools_module = @import("tools.zig");
const context_module = @import("context.zig");

const AgentContext = agents_module.AgentContext;
const AgentResult = agents_module.AgentResult;
const AgentStats = agents_module.AgentStats;
const AgentCapabilities = agents_module.AgentCapabilities;
const ProgressCallback = agents_module.ProgressCallback;
const ProgressUpdateType = agents_module.ProgressUpdateType;

/// Context for streaming callback
const StreamContext = struct {
    allocator: std.mem.Allocator,
    content_buffer: std.ArrayListUnmanaged(u8),
    thinking_buffer: std.ArrayListUnmanaged(u8),
    tool_calls: std.ArrayListUnmanaged(ollama.ToolCall),

    // Progress callback
    progress_callback: ?ProgressCallback,
    callback_user_data: ?*anyopaque,
};

/// Callback for streaming LLM response
fn streamCallback(
    ctx: *StreamContext,
    thinking_chunk: ?[]const u8,
    content_chunk: ?[]const u8,
    tool_calls_chunk: ?[]const ollama.ToolCall,
) void {
    // Notify progress callback
    if (ctx.progress_callback) |callback| {
        if (thinking_chunk) |chunk| {
            callback(ctx.callback_user_data, .thinking, chunk);
        }
        if (content_chunk) |chunk| {
            callback(ctx.callback_user_data, .content, chunk);
        }
    }

    // Collect thinking chunks
    if (thinking_chunk) |chunk| {
        ctx.thinking_buffer.appendSlice(ctx.allocator, chunk) catch {};
    }

    // Collect content chunks
    if (content_chunk) |chunk| {
        ctx.content_buffer.appendSlice(ctx.allocator, chunk) catch {};
    }

    // Collect tool calls
    if (tool_calls_chunk) |calls| {
        for (calls) |call| {
            // Notify progress callback about tool call
            if (ctx.progress_callback) |callback| {
                const msg = std.fmt.allocPrint(
                    ctx.allocator,
                    "Calling {s}...",
                    .{call.function.name},
                ) catch continue;
                defer ctx.allocator.free(msg);
                callback(ctx.callback_user_data, .tool_call, msg);
            }

            // Deep copy the tool call
            const copied_call = ollama.ToolCall{
                .id = if (call.id) |id| ctx.allocator.dupe(u8, id) catch continue else null,
                .type = if (call.type) |t| ctx.allocator.dupe(u8, t) catch continue else null,
                .function = .{
                    .name = ctx.allocator.dupe(u8, call.function.name) catch continue,
                    .arguments = ctx.allocator.dupe(u8, call.function.arguments) catch continue,
                },
            };

            ctx.tool_calls.append(ctx.allocator, copied_call) catch {};
        }
    }
}

/// Agent executor - runs an agent's task in isolation
pub const AgentExecutor = struct {
    allocator: std.mem.Allocator,
    message_history: std.ArrayListUnmanaged(ollama.ChatMessage),
    capabilities: AgentCapabilities,

    // Statistics
    iterations_used: usize = 0,
    tool_calls_made: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capabilities: AgentCapabilities) AgentExecutor {
        return .{
            .allocator = allocator,
            .message_history = .{},
            .capabilities = capabilities,
        };
    }

    pub fn deinit(self: *AgentExecutor) void {
        // Free message history
        for (self.message_history.items) |msg| {
            self.allocator.free(msg.content);
            if (msg.tool_call_id) |id| {
                self.allocator.free(id);
            }
            if (msg.tool_calls) |calls| {
                for (calls) |call| {
                    if (call.id) |id| self.allocator.free(id);
                    if (call.type) |t| self.allocator.free(t);
                    self.allocator.free(call.function.name);
                    self.allocator.free(call.function.arguments);
                }
                self.allocator.free(calls);
            }
        }
        self.message_history.deinit(self.allocator);
    }

    /// Main execution loop - runs agent until completion or max iterations
    pub fn run(
        self: *AgentExecutor,
        context: AgentContext,
        system_prompt: []const u8,
        user_task: []const u8,
        available_tools: []const ollama.Tool,
        progress_callback: ?ProgressCallback,
        callback_user_data: ?*anyopaque,
    ) !AgentResult {
        const start_time = std.time.milliTimestamp();

        // Add user task message
        try self.message_history.append(self.allocator, .{
            .role = "user",
            .content = try self.allocator.dupe(u8, user_task),
        });

        // Filter tools based on capabilities
        const allowed_tools = try self.filterAllowedTools(available_tools);
        defer self.allocator.free(allowed_tools);

        // Track thinking content across iterations (will contain final thinking)
        var final_thinking: ?[]const u8 = null;
        defer if (final_thinking) |t| self.allocator.free(t);

        // Main iteration loop
        while (self.iterations_used < self.capabilities.max_iterations) {
            self.iterations_used += 1;

            // Notify progress callback
            if (progress_callback) |callback| {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Iteration {d}/{d}",
                    .{ self.iterations_used, self.capabilities.max_iterations },
                );
                defer self.allocator.free(msg);
                callback(callback_user_data, .iteration, msg);
            }

            // Prepare streaming context
            var stream_ctx = StreamContext{
                .allocator = self.allocator,
                .content_buffer = .{},
                .thinking_buffer = .{},
                .tool_calls = .{},
                .progress_callback = progress_callback,
                .callback_user_data = callback_user_data,
            };
            defer stream_ctx.content_buffer.deinit(self.allocator);
            // Note: thinking_buffer is extracted before defer, so don't deinit here

            // Call LLM
            const model = context.capabilities.model_override orelse context.config.model;
            const request = llm_helper.LLMRequest{
                .model = model,
                .messages = self.message_history.items,
                .system_prompt = system_prompt,
                .tools = if (allowed_tools.len > 0) allowed_tools else null,
                .temperature = self.capabilities.temperature,
                .num_ctx = self.capabilities.num_ctx,
                .num_predict = self.capabilities.num_predict,
                .think = self.capabilities.enable_thinking,
            };

            llm_helper.chatStream(
                context.ollama_client,
                request,
                &stream_ctx,
                streamCallback,
            ) catch |err| {
                const end_time = std.time.milliTimestamp();
                const stats = AgentStats{
                    .iterations_used = self.iterations_used,
                    .tool_calls_made = self.tool_calls_made,
                    .execution_time_ms = end_time - start_time,
                };
                const error_msg = try std.fmt.allocPrint(
                    self.allocator,
                    "LLM call failed: {}",
                    .{err},
                );
                defer self.allocator.free(error_msg);
                return try AgentResult.err(self.allocator, error_msg, stats);
            };

            // Get response content and thinking
            const response_content = try stream_ctx.content_buffer.toOwnedSlice(self.allocator);
            defer self.allocator.free(response_content);

            // Update final_thinking with latest iteration's thinking
            // (Free previous thinking if it exists)
            if (final_thinking) |old_thinking| {
                self.allocator.free(old_thinking);
            }
            final_thinking = if (stream_ctx.thinking_buffer.items.len > 0)
                try stream_ctx.thinking_buffer.toOwnedSlice(self.allocator)
            else
                null;

            // Add assistant message to history
            try self.message_history.append(self.allocator, .{
                .role = "assistant",
                .content = try self.allocator.dupe(u8, response_content),
                .tool_calls = if (stream_ctx.tool_calls.items.len > 0)
                    try stream_ctx.tool_calls.toOwnedSlice(self.allocator)
                else
                    null,
            });

            // Check if we have tool calls to execute
            const last_msg = self.message_history.items[self.message_history.items.len - 1];
            if (last_msg.tool_calls) |tool_calls| {
                // Execute tool calls
                for (tool_calls) |tool_call| {
                    const tool_result = try self.executeTool(tool_call, context);
                    defer self.allocator.free(tool_result);

                    // Add tool result to message history
                    const tool_call_id = tool_call.id orelse "unknown";
                    try self.message_history.append(self.allocator, .{
                        .role = "tool",
                        .content = try self.allocator.dupe(u8, tool_result),
                        .tool_call_id = try self.allocator.dupe(u8, tool_call_id),
                    });

                    self.tool_calls_made += 1;
                }
                // Continue to next iteration to process tool results
                continue;
            }

            // No tool calls - we're done!
            // Notify completion
            if (progress_callback) |callback| {
                callback(callback_user_data, .complete, "Agent completed");
            }

            const end_time = std.time.milliTimestamp();
            const stats = AgentStats{
                .iterations_used = self.iterations_used,
                .tool_calls_made = self.tool_calls_made,
                .execution_time_ms = end_time - start_time,
            };

            return try AgentResult.ok(self.allocator, response_content, stats, final_thinking);
        }

        // Max iterations reached
        const end_time = std.time.milliTimestamp();
        const stats = AgentStats{
            .iterations_used = self.iterations_used,
            .tool_calls_made = self.tool_calls_made,
            .execution_time_ms = end_time - start_time,
        };

        return try AgentResult.err(
            self.allocator,
            "Max iterations reached without completion",
            stats,
        );
    }

    /// Filter tools based on agent capabilities
    fn filterAllowedTools(self: *AgentExecutor, all_tools: []const ollama.Tool) ![]const ollama.Tool {
        if (self.capabilities.allowed_tools.len == 0) {
            // No tools allowed
            return &.{};
        }

        var filtered = std.ArrayListUnmanaged(ollama.Tool){};
        defer filtered.deinit(self.allocator);

        for (all_tools) |tool| {
            for (self.capabilities.allowed_tools) |allowed_name| {
                if (std.mem.eql(u8, tool.function.name, allowed_name)) {
                    try filtered.append(self.allocator, tool);
                    break;
                }
            }
        }

        return try filtered.toOwnedSlice(self.allocator);
    }

    /// Execute a single tool call (agents bypass permission system - they're trusted)
    fn executeTool(
        self: *AgentExecutor,
        tool_call: ollama.ToolCall,
        agent_context: AgentContext,
    ) ![]const u8 {
        // Check if tool is allowed
        var is_allowed = false;
        for (self.capabilities.allowed_tools) |allowed_name| {
            if (std.mem.eql(u8, tool_call.function.name, allowed_name)) {
                is_allowed = true;
                break;
            }
        }

        if (!is_allowed) {
            return try std.fmt.allocPrint(
                self.allocator,
                "Error: Tool '{s}' not allowed for this agent",
                .{tool_call.function.name},
            );
        }

        // Build AppContext from AgentContext
        // Note: Agents don't have full AppContext, but tools expect it
        // We create a minimal AppContext for tool execution
        var app_context = context_module.AppContext{
            .allocator = self.allocator,
            .config = agent_context.config,
            .state = undefined, // Agents don't have state - tools that need state won't work
            .ollama_client = agent_context.ollama_client,
            .vector_store = agent_context.vector_store,
            .embedder = agent_context.embedder,
            .indexing_queue = null, // Agents don't queue for indexing
        };

        // Execute tool (look up in tools module)
        const tool_result = tools_module.executeToolCall(
            self.allocator,
            tool_call,
            &app_context,
        ) catch |err| {
            return try std.fmt.allocPrint(
                self.allocator,
                "Error executing tool: {}",
                .{err},
            );
        };

        // Format result as string
        if (tool_result.success) {
            if (tool_result.data) |data| {
                return try self.allocator.dupe(u8, data);
            } else {
                return try self.allocator.dupe(u8, "Success (no data)");
            }
        } else {
            const error_msg = tool_result.error_message orelse "Unknown error";
            return try std.fmt.allocPrint(
                self.allocator,
                "Error: {s}",
                .{error_msg},
            );
        }
    }
};
