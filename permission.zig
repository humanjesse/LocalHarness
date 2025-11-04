// Permission Manager - Policy-driven tool execution safety system
const std = @import("std");
const ollama = @import("ollama");

// ============================================================================
// Core Data Structures
// ============================================================================

pub const RiskLevel = enum {
    safe,     // Auto-approve (get_file_tree)
    low,      // Ask once per session
    medium,   // Ask each time (read_file)
    high,     // Ask + show preview
    critical, // Require explicit confirmation
};

pub const Scope = enum {
    read_files,
    write_files,
    execute_commands,
    network_access,
    system_info,
    todo_management, // For internal todo tracking operations
};

pub const PermissionMode = enum {
    always_allow,
    allow_once,
    ask_each_time,
    deny,
};

pub const Decision = enum {
    auto_approved,
    user_approved,
    denied_by_policy,
    denied_by_user,
    failed_validation,
};

// Tool metadata with risk classification
pub const ToolMetadata = struct {
    name: []const u8,
    description: []const u8,
    risk_level: RiskLevel,
    required_scopes: []const Scope,
    validator: ?*const fn (std.mem.Allocator, []const u8) bool = null,
};

// User-defined policy rule
pub const Policy = struct {
    scope: Scope,
    mode: PermissionMode,
    path_patterns: []const []const u8,
    deny_patterns: []const []const u8,
};

// Temporary session grant
pub const SessionGrant = struct {
    tool_name: []const u8,
    granted_at: i64,
    scope: Scope,
};

// Audit trail event
pub const AuditEvent = struct {
    timestamp: i64,
    tool_name: []const u8,
    arguments: []const u8,
    decision: Decision,
    reason: []const u8,
    user_approved: bool,
};

// ============================================================================
// Tool Registry
// ============================================================================

pub const ToolRegistry = struct {
    allocator: std.mem.Allocator,
    tools: std.StringHashMapUnmanaged(ToolMetadata),

    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        return .{
            .allocator = allocator,
            .tools = .{},
        };
    }

    pub fn deinit(self: *ToolRegistry) void {
        var iter = self.tools.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.tools.deinit(self.allocator);
    }

    pub fn register(self: *ToolRegistry, metadata: ToolMetadata) !void {
        try self.tools.put(
            self.allocator,
            try self.allocator.dupe(u8, metadata.name),
            metadata,
        );
    }

    pub fn getMetadata(self: *ToolRegistry, tool_name: []const u8) ?ToolMetadata {
        return self.tools.get(tool_name);
    }

    pub fn validateArguments(
        self: *ToolRegistry,
        tool_name: []const u8,
        arguments: []const u8,
    ) !bool {
        const metadata = self.getMetadata(tool_name) orelse return false;

        // Use custom validator if provided
        if (metadata.validator) |validator| {
            return validator(self.allocator, arguments);
        }

        // Default: just check if it's valid JSON
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            arguments,
            .{},
        ) catch return false;
        defer parsed.deinit();

        return true;
    }
};

// ============================================================================
// Policy Engine
// ============================================================================

pub const PolicyEngine = struct {
    allocator: std.mem.Allocator,
    policies: std.ArrayListUnmanaged(Policy),

    pub const EvaluationResult = struct {
        allowed: bool,
        reason: []const u8,
        ask_user: bool,
        show_preview: bool,
    };

    pub fn init(allocator: std.mem.Allocator) PolicyEngine {
        return .{
            .allocator = allocator,
            .policies = .{},
        };
    }

    pub fn deinit(self: *PolicyEngine) void {
        for (self.policies.items) |policy| {
            for (policy.path_patterns) |pattern| {
                self.allocator.free(pattern);
            }
            self.allocator.free(policy.path_patterns);
            for (policy.deny_patterns) |pattern| {
                self.allocator.free(pattern);
            }
            self.allocator.free(policy.deny_patterns);
        }
        self.policies.deinit(self.allocator);
    }

    pub fn addPolicy(self: *PolicyEngine, policy: Policy) !void {
        try self.policies.append(self.allocator, policy);
    }

    pub fn evaluate(
        self: *PolicyEngine,
        tool_name: []const u8,
        arguments: []const u8,
        metadata: ToolMetadata,
    ) !EvaluationResult {
        // 1. Check risk level first
        switch (metadata.risk_level) {
            .safe => return .{
                .allowed = true,
                .reason = "Tool classified as safe",
                .ask_user = false,
                .show_preview = false,
            },
            .critical => return .{
                .allowed = false,
                .reason = "Critical tool requires explicit approval",
                .ask_user = true,
                .show_preview = true,
            },
            else => {},
        }

        // 2. Check applicable policies
        for (self.policies.items) |policy| {
            if (self.policyApplies(policy, metadata.required_scopes)) {
                if (try self.matchesPolicy(policy, tool_name, arguments)) {
                    switch (policy.mode) {
                        .always_allow => return .{
                            .allowed = true,
                            .reason = "Matched always-allow policy",
                            .ask_user = false,
                            .show_preview = false,
                        },
                        .deny => return .{
                            .allowed = false,
                            .reason = "Denied by policy",
                            .ask_user = false,
                            .show_preview = false,
                        },
                        .ask_each_time => return .{
                            .allowed = false,
                            .reason = "Policy requires user approval",
                            .ask_user = true,
                            .show_preview = metadata.risk_level == .high,
                        },
                        .allow_once => return .{
                            .allowed = false,
                            .reason = "Policy requires approval",
                            .ask_user = true,
                            .show_preview = false,
                        },
                    }
                }
            }
        }

        // 3. Default based on risk level
        return .{
            .allowed = false,
            .reason = "No matching policy, default to ask user",
            .ask_user = true,
            .show_preview = metadata.risk_level == .high or metadata.risk_level == .medium,
        };
    }

    fn matchesPolicy(
        self: *PolicyEngine,
        policy: Policy,
        tool_name: []const u8,
        arguments: []const u8,
    ) !bool {
        // For file operations, check path patterns
        if (std.mem.eql(u8, tool_name, "read_file")) {
            const Args = struct { path: []const u8 };
            const parsed = std.json.parseFromSlice(Args, self.allocator, arguments, .{}) catch return false;
            defer parsed.deinit();

            // Check deny patterns first
            for (policy.deny_patterns) |pattern| {
                if (try self.matchGlob(parsed.value.path, pattern)) {
                    return false; // Denied by pattern
                }
            }

            // Check allow patterns
            for (policy.path_patterns) |pattern| {
                if (try self.matchGlob(parsed.value.path, pattern)) {
                    return true; // Allowed by pattern
                }
            }
        }

        return false;
    }

    fn matchGlob(self: *PolicyEngine, path: []const u8, pattern: []const u8) !bool {
        _ = self;

        // Simple glob matching
        if (std.mem.eql(u8, pattern, "*")) return true;

        // Match /**  (directory and all contents)
        if (std.mem.endsWith(u8, pattern, "/**")) {
            const prefix = pattern[0 .. pattern.len - 3];
            return std.mem.startsWith(u8, path, prefix);
        }

        // Match *.ext (file extension)
        if (std.mem.startsWith(u8, pattern, "*.")) {
            const suffix = pattern[1..];
            return std.mem.endsWith(u8, path, suffix);
        }

        // Exact match
        return std.mem.eql(u8, path, pattern);
    }

    fn policyApplies(self: *PolicyEngine, policy: Policy, scopes: []const Scope) bool {
        _ = self;
        for (scopes) |scope| {
            if (scope == policy.scope) return true;
        }
        return false;
    }
};

// ============================================================================
// Session State
// ============================================================================

pub const SessionState = struct {
    allocator: std.mem.Allocator,
    grants: std.ArrayListUnmanaged(SessionGrant),

    pub fn init(allocator: std.mem.Allocator) SessionState {
        return .{
            .allocator = allocator,
            .grants = .{},
        };
    }

    pub fn deinit(self: *SessionState) void {
        for (self.grants.items) |grant| {
            self.allocator.free(grant.tool_name);
        }
        self.grants.deinit(self.allocator);
    }

    pub fn hasGrant(
        self: *SessionState,
        tool_name: []const u8,
        scope: Scope,
    ) ?SessionGrant {
        for (self.grants.items) |grant| {
            if (std.mem.eql(u8, grant.tool_name, tool_name) and grant.scope == scope) {
                return grant;
            }
        }
        return null;
    }

    pub fn addGrant(self: *SessionState, grant: SessionGrant) !void {
        try self.grants.append(self.allocator, .{
            .tool_name = try self.allocator.dupe(u8, grant.tool_name),
            .granted_at = grant.granted_at,
            .scope = grant.scope,
        });
    }
};

// ============================================================================
// Audit Logger
// ============================================================================

pub const AuditLogger = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayListUnmanaged(AuditEvent),
    log_file: ?std.fs.File,
    max_memory_events: usize,

    pub fn init(allocator: std.mem.Allocator, log_path: ?[]const u8) !AuditLogger {
        var log_file: ?std.fs.File = null;

        if (log_path) |path| {
            // Ensure parent directory exists
            if (std.fs.path.dirname(path)) |dir| {
                std.fs.cwd().makePath(dir) catch {};
            }

            log_file = std.fs.cwd().createFile(path, .{
                .truncate = false,
                .read = true,
            }) catch null;

            if (log_file) |file| {
                file.seekFromEnd(0) catch {}; // Append mode
            }
        }

        return .{
            .allocator = allocator,
            .events = .{},
            .log_file = log_file,
            .max_memory_events = 50, // Keep last 50 in memory
        };
    }

    pub fn deinit(self: *AuditLogger) void {
        for (self.events.items) |event| {
            self.allocator.free(event.tool_name);
            self.allocator.free(event.arguments);
            self.allocator.free(event.reason);
        }
        self.events.deinit(self.allocator);

        if (self.log_file) |file| {
            file.close();
        }
    }

    pub fn log(
        self: *AuditLogger,
        tool_name: []const u8,
        arguments: []const u8,
        decision: Decision,
        reason: []const u8,
        user_approved: bool,
    ) !void {
        const event = AuditEvent{
            .timestamp = std.time.milliTimestamp(),
            .tool_name = try self.allocator.dupe(u8, tool_name),
            .arguments = try self.allocator.dupe(u8, arguments),
            .decision = decision,
            .reason = try self.allocator.dupe(u8, reason),
            .user_approved = user_approved,
        };

        // Add to in-memory buffer (keep only last N)
        try self.events.append(self.allocator, event);
        if (self.events.items.len > self.max_memory_events) {
            const removed = self.events.orderedRemove(0);
            self.allocator.free(removed.tool_name);
            self.allocator.free(removed.arguments);
            self.allocator.free(removed.reason);
        }

        // Write to file if configured
        if (self.log_file) |file| {
            const log_line = try std.fmt.allocPrint(
                self.allocator,
                "[{d}] {s} {s} | {s} | user={} | args={s}\n",
                .{
                    event.timestamp,
                    @tagName(event.decision),
                    event.tool_name,
                    event.reason,
                    event.user_approved,
                    event.arguments,
                },
            );
            defer self.allocator.free(log_line);

            file.writeAll(log_line) catch {};
        }
    }

    pub fn getRecentEvents(self: *AuditLogger) []const AuditEvent {
        return self.events.items;
    }
};

// ============================================================================
// Sandbox Runner
// ============================================================================

pub const SandboxRunner = struct {
    allocator: std.mem.Allocator,
    working_directory: []const u8,
    max_file_size: usize,

    pub const ExecutionResult = struct {
        success: bool,
        output: []const u8,
        error_message: ?[]const u8,
    };

    pub fn init(allocator: std.mem.Allocator, working_dir: []const u8) !SandboxRunner {
        return .{
            .allocator = allocator,
            .working_directory = try allocator.dupe(u8, working_dir),
            .max_file_size = 10 * 1024 * 1024, // 10MB
        };
    }

    pub fn deinit(self: *SandboxRunner) void {
        self.allocator.free(self.working_directory);
    }

    pub fn execute(
        self: *SandboxRunner,
        tool_name: []const u8,
        arguments: []const u8,
        executor_fn: *const fn (std.mem.Allocator, []const u8) anyerror![]const u8,
    ) !ExecutionResult {
        _ = tool_name;

        const output = executor_fn(self.allocator, arguments) catch |err| {
            return ExecutionResult{
                .success = false,
                .output = try self.allocator.dupe(u8, ""),
                .error_message = try std.fmt.allocPrint(
                    self.allocator,
                    "Execution failed: {s}",
                    .{@errorName(err)},
                ),
            };
        };

        return ExecutionResult{
            .success = true,
            .output = output,
            .error_message = null,
        };
    }
};

// ============================================================================
// Permission Manager (Orchestrator)
// ============================================================================

pub const PermissionManager = struct {
    allocator: std.mem.Allocator,
    registry: ToolRegistry,
    policy_engine: PolicyEngine,
    session_state: SessionState,
    audit_logger: AuditLogger,
    sandbox_runner: SandboxRunner,

    pub fn init(allocator: std.mem.Allocator, working_dir: []const u8, audit_log_path: ?[]const u8) !PermissionManager {
        return .{
            .allocator = allocator,
            .registry = ToolRegistry.init(allocator),
            .policy_engine = PolicyEngine.init(allocator),
            .session_state = SessionState.init(allocator),
            .audit_logger = try AuditLogger.init(allocator, audit_log_path),
            .sandbox_runner = try SandboxRunner.init(allocator, working_dir),
        };
    }

    pub fn deinit(self: *PermissionManager) void {
        self.registry.deinit();
        self.policy_engine.deinit();
        self.session_state.deinit();
        self.audit_logger.deinit();
        self.sandbox_runner.deinit();
    }

    // Main entry point - evaluates and potentially executes tool
    pub fn evaluateAndExecute(
        self: *PermissionManager,
        tool_call: ollama.ToolCall,
        executor_fn: *const fn (std.mem.Allocator, []const u8) anyerror![]const u8,
        ask_user_fn: *const fn (ollama.ToolCall, PolicyEngine.EvaluationResult) anyerror!?PermissionMode,
    ) !?SandboxRunner.ExecutionResult {
        // 1. Get tool metadata
        const metadata = self.registry.getMetadata(tool_call.function.name) orelse {
            try self.audit_logger.log(
                tool_call.function.name,
                tool_call.function.arguments,
                .failed_validation,
                "Tool not registered",
                false,
            );
            return null;
        };

        // 2. Validate arguments
        const valid = try self.registry.validateArguments(
            tool_call.function.name,
            tool_call.function.arguments,
        );
        if (!valid) {
            try self.audit_logger.log(
                tool_call.function.name,
                tool_call.function.arguments,
                .failed_validation,
                "Invalid arguments",
                false,
            );
            return null;
        }

        // 3. Check session grants
        if (self.session_state.hasGrant(tool_call.function.name, metadata.required_scopes[0])) |_| {
            const result = try self.sandbox_runner.execute(
                tool_call.function.name,
                tool_call.function.arguments,
                executor_fn,
            );

            try self.audit_logger.log(
                tool_call.function.name,
                tool_call.function.arguments,
                .auto_approved,
                "Session grant active",
                false,
            );

            return result;
        }

        // 4. Evaluate policy
        const eval_result = try self.policy_engine.evaluate(
            tool_call.function.name,
            tool_call.function.arguments,
            metadata,
        );

        // 5. Handle auto-approval
        if (eval_result.allowed and !eval_result.ask_user) {
            const result = try self.sandbox_runner.execute(
                tool_call.function.name,
                tool_call.function.arguments,
                executor_fn,
            );

            try self.audit_logger.log(
                tool_call.function.name,
                tool_call.function.arguments,
                .auto_approved,
                eval_result.reason,
                false,
            );

            return result;
        }

        // 6. Handle auto-denial
        if (!eval_result.allowed and !eval_result.ask_user) {
            try self.audit_logger.log(
                tool_call.function.name,
                tool_call.function.arguments,
                .denied_by_policy,
                eval_result.reason,
                false,
            );
            return null;
        }

        // 7. Ask user
        const user_choice = try ask_user_fn(tool_call, eval_result);

        if (user_choice == null) {
            // User denied
            try self.audit_logger.log(
                tool_call.function.name,
                tool_call.function.arguments,
                .denied_by_user,
                "User denied permission",
                false,
            );
            return null;
        }

        // 8. Handle user choice
        const choice = user_choice.?;
        switch (choice) {
            .allow_once => {
                // Just execute, don't save anything
            },
            .always_allow => {
                // Add to policies (caller should save to file)
                // For now, we'll return the choice and let the caller handle it
            },
            .ask_each_time => {
                // Add session grant
                try self.session_state.addGrant(.{
                    .tool_name = tool_call.function.name,
                    .granted_at = std.time.milliTimestamp(),
                    .scope = metadata.required_scopes[0],
                });
            },
            .deny => unreachable, // Should have been handled above
        }

        // 9. Execute
        const result = try self.sandbox_runner.execute(
            tool_call.function.name,
            tool_call.function.arguments,
            executor_fn,
        );

        try self.audit_logger.log(
            tool_call.function.name,
            tool_call.function.arguments,
            .user_approved,
            eval_result.reason,
            true,
        );

        return result;
    }

    // Register tools from metadata array
    pub fn registerTools(self: *PermissionManager, metadata_list: []const ToolMetadata) !void {
        for (metadata_list) |metadata| {
            try self.registry.register(metadata);
        }
    }
};
