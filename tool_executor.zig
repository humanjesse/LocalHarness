// Tool Execution State Machine - Manages async tool execution with permissions
const std = @import("std");
const ollama = @import("ollama");
const permission = @import("permission");
const tools_module = @import("tools");
const markdown = @import("markdown");
const context_module = @import("context");

const AppContext = context_module.AppContext;

/// Tool execution states
pub const ToolExecutionState = enum {
    idle,              // No tools to execute
    evaluating_policy, // Checking if tool needs permission
    awaiting_permission, // Waiting for user permission response
    executing,         // Executing the approved tool
    creating_denial_result, // Creating error result for denied permission
    completed,         // All tools in batch completed
};

/// Result of tick() - tells App what to do next
pub const TickResult = enum {
    no_action,           // Nothing to do
    render_requested,    // UI should redraw
    show_permission_prompt, // App should display permission prompt
    iteration_complete,  // All tools done, ready for next iteration
    iteration_limit_reached, // Max iterations hit, stop master loop
};

pub const ToolExecutor = struct {
    allocator: std.mem.Allocator,
    state: ToolExecutionState,

    // Tool execution queue
    pending_calls: ?[]ollama.ToolCall,
    current_index: usize,

    // Permission handling
    pending_permission_tool: ?ollama.ToolCall,
    pending_permission_eval: ?permission.PolicyEngine.EvaluationResult,
    permission_response: ?permission.PermissionMode,

    pub fn init(allocator: std.mem.Allocator) ToolExecutor {
        return .{
            .allocator = allocator,
            .state = .idle,
            .pending_calls = null,
            .current_index = 0,
            .pending_permission_tool = null,
            .pending_permission_eval = null,
            .permission_response = null,
        };
    }

    pub fn deinit(self: *ToolExecutor) void {
        // NOTE: pending_calls and pending_permission_tool are owned by messages
        // They are just references here, so we don't free them
        // The message cleanup in app.deinit() will handle freeing them

        // Clean up permission eval
        // Note: eval.reason is managed by PolicyEngine (usually a string literal)
        // so we don't free it here
        self.pending_permission_eval = null;
    }

    /// Get current execution state (for debugging/UI)
    pub fn getCurrentState(self: *const ToolExecutor) ToolExecutionState {
        return self.state;
    }

    /// Start executing a batch of tool calls
    pub fn startExecution(self: *ToolExecutor, tool_calls: []ollama.ToolCall) void {
        self.pending_calls = tool_calls;
        self.current_index = 0;
        self.state = .evaluating_policy;
    }

    /// Set permission response from user
    pub fn setPermissionResponse(self: *ToolExecutor, response: permission.PermissionMode) void {
        self.permission_response = response;
    }

    /// Check if executor has pending work
    pub fn hasPendingWork(self: *const ToolExecutor) bool {
        return self.state != .idle;
    }

    /// Main tick function - advances state machine
    /// Returns what action the caller (App) should take
    pub fn tick(
        self: *ToolExecutor,
        perm_manager: *permission.PermissionManager,
        iteration_count: usize,
        max_iterations: usize,
    ) !TickResult {
        switch (self.state) {
            .idle => {
                // Nothing to do
                return .no_action;
            },

            .evaluating_policy => {
                if (self.pending_calls == null or self.current_index >= self.pending_calls.?.len) {
                    // No more tools to execute
                    self.state = .completed;
                    return try self.tick(perm_manager, iteration_count, max_iterations);
                }

                const tool_call = self.pending_calls.?[self.current_index];

                // Get metadata
                const metadata = perm_manager.registry.getMetadata(tool_call.function.name);

                if (metadata == null) {
                    // Tool not registered - skip
                    try perm_manager.audit_logger.log(
                        tool_call.function.name,
                        tool_call.function.arguments,
                        .failed_validation,
                        "Tool not registered",
                        false,
                    );
                    self.current_index += 1;
                    self.state = .evaluating_policy; // Re-evaluate next tool
                    return .render_requested;
                }

                const meta = metadata.?;

                // Validate arguments
                const valid = perm_manager.registry.validateArguments(
                    tool_call.function.name,
                    tool_call.function.arguments,
                ) catch false;

                if (!valid) {
                    try perm_manager.audit_logger.log(
                        tool_call.function.name,
                        tool_call.function.arguments,
                        .failed_validation,
                        "Invalid arguments",
                        false,
                    );
                    self.current_index += 1;
                    self.state = .evaluating_policy;
                    return .render_requested;
                }

                // Check session grants
                const has_session_grant = perm_manager.session_state.hasGrant(
                    tool_call.function.name,
                    meta.required_scopes[0],
                ) != null;

                if (has_session_grant) {
                    // Auto-approve with session grant
                    try perm_manager.audit_logger.log(
                        tool_call.function.name,
                        tool_call.function.arguments,
                        .auto_approved,
                        "Session grant active",
                        false,
                    );
                    self.state = .executing;
                    return try self.tick(perm_manager, iteration_count, max_iterations);
                }

                // Evaluate policy
                const eval_result = perm_manager.policy_engine.evaluate(
                    tool_call.function.name,
                    tool_call.function.arguments,
                    meta,
                ) catch {
                    // Policy evaluation failed - skip
                    self.current_index += 1;
                    self.state = .evaluating_policy;
                    return .render_requested;
                };

                if (eval_result.allowed and !eval_result.ask_user) {
                    // Auto-approve
                    try perm_manager.audit_logger.log(
                        tool_call.function.name,
                        tool_call.function.arguments,
                        .auto_approved,
                        eval_result.reason,
                        false,
                    );
                    // Note: eval_result.reason is a string literal, don't free it
                    self.state = .executing;
                    return try self.tick(perm_manager, iteration_count, max_iterations);
                } else if (!eval_result.allowed and !eval_result.ask_user) {
                    // Auto-deny
                    try perm_manager.audit_logger.log(
                        tool_call.function.name,
                        tool_call.function.arguments,
                        .denied_by_policy,
                        eval_result.reason,
                        false,
                    );
                    // Note: eval_result.reason is a string literal, don't free it
                    self.current_index += 1;
                    self.state = .evaluating_policy;
                    return .render_requested;
                } else {
                    // Need to ask user - store eval result and transition to awaiting permission
                    self.pending_permission_tool = tool_call;
                    self.pending_permission_eval = eval_result;
                    self.state = .awaiting_permission;
                    return .show_permission_prompt;
                }
            },

            .awaiting_permission => {
                if (self.permission_response == null) {
                    // Still waiting for user response
                    return .no_action;
                }

                // Response received
                const user_choice = self.permission_response.?;
                self.permission_response = null;

                const tool_call = self.pending_permission_tool.?;
                const eval_result = self.pending_permission_eval.?;
                const metadata = perm_manager.registry.getMetadata(tool_call.function.name).?;

                if (user_choice == .deny) {
                    // Denied - create error result for LLM
                    try perm_manager.audit_logger.log(
                        tool_call.function.name,
                        tool_call.function.arguments,
                        .denied_by_user,
                        "User denied permission",
                        false,
                    );
                    // Note: eval_result.reason is a string literal, don't free it
                    self.pending_permission_eval = null;
                    // Transition to denial result state (App will create error message)
                    self.state = .creating_denial_result;
                    return .render_requested;
                }

                // Handle user choice
                switch (user_choice) {
                    .allow_once => {},
                    .always_allow => {
                        // Save policy
                        var path_patterns: []const []const u8 = undefined;
                        if (metadata.required_scopes[0] == .read_files or metadata.required_scopes[0] == .write_files) {
                            var patterns = try self.allocator.alloc([]const u8, 1);
                            patterns[0] = try self.allocator.dupe(u8, "*");
                            path_patterns = patterns;
                        } else {
                            path_patterns = try self.allocator.alloc([]const u8, 0);
                        }

                        const deny_patterns = try self.allocator.alloc([]const u8, 0);

                        try perm_manager.policy_engine.addPolicy(.{
                            .scope = metadata.required_scopes[0],
                            .mode = .always_allow,
                            .path_patterns = path_patterns,
                            .deny_patterns = deny_patterns,
                        });

                        // Note: Policy saving will be handled by caller (App)
                    },
                    .ask_each_time => {
                        // Add session grant
                        try perm_manager.session_state.addGrant(.{
                            .tool_name = tool_call.function.name,
                            .granted_at = std.time.milliTimestamp(),
                            .scope = metadata.required_scopes[0],
                        });
                    },
                    .deny => unreachable,
                }

                try perm_manager.audit_logger.log(
                    tool_call.function.name,
                    tool_call.function.arguments,
                    .user_approved,
                    eval_result.reason,
                    true,
                );

                // Note: eval_result.reason is a string literal, don't free it
                self.pending_permission_eval = null;
                self.state = .executing;
                return try self.tick(perm_manager, iteration_count, max_iterations);
            },

            .executing => {
                // This state is handled by caller (App) since it needs access to App methods
                // We just mark that we're ready to execute
                // The actual execution happens in App, which then calls advanceAfterExecution()
                return .render_requested;
            },

            .creating_denial_result => {
                // This state is handled by caller (App) since it needs to create messages
                // App will create error ToolResult and display message
                // Then call advanceAfterExecution() to move to next tool
                return .render_requested;
            },

            .completed => {
                // All tools executed - check iteration limit
                // Note: iteration_count will be incremented by caller before next iteration
                if (iteration_count >= max_iterations) {
                    // Max iterations reached
                    self.state = .idle;
                    self.pending_calls = null;
                    return .iteration_limit_reached;
                } else {
                    // Continue to next iteration
                    self.state = .idle;
                    self.pending_calls = null;
                    return .iteration_complete;
                }
            },
        }
    }

    /// Call this after executing a tool successfully to advance to next tool
    pub fn advanceAfterExecution(self: *ToolExecutor) void {
        self.current_index += 1;
        self.state = .evaluating_policy;
    }

    /// Get current tool call being processed (if any)
    pub fn getCurrentToolCall(self: *const ToolExecutor) ?ollama.ToolCall {
        if (self.pending_calls) |calls| {
            if (self.current_index < calls.len) {
                return calls[self.current_index];
            }
        }
        return null;
    }

    /// Get pending permission tool (for showing prompt)
    pub fn getPendingPermissionTool(self: *const ToolExecutor) ?ollama.ToolCall {
        return self.pending_permission_tool;
    }

    /// Get pending permission evaluation (for showing prompt)
    pub fn getPendingPermissionEval(self: *const ToolExecutor) ?permission.PolicyEngine.EvaluationResult {
        return self.pending_permission_eval;
    }
};
