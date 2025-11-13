// Configuration management - loading, saving, and persistence
const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const permission = @import("permission");

/// Application configuration
pub const Config = struct {
    // Provider selection
    provider: []const u8 = "ollama", // LLM provider: "ollama" or "lmstudio"
    ollama_host: []const u8 = "http://localhost:11434",
    ollama_endpoint: []const u8 = "/api/chat",
    lmstudio_host: []const u8 = "http://localhost:1234", // LM Studio default port
    lmstudio_auto_start: bool = true, // Auto-start LM Studio server if not running
    lmstudio_auto_load_model: bool = true, // Auto-load model if none is loaded
    lmstudio_gpu_offload: []const u8 = "auto", // GPU offload: "auto" (becomes "max"), "max", or 0.0-1.0
    lmstudio_ttl: usize = 0, // Auto-unload model after inactivity (seconds, 0 = never unload)
    model: []const u8 = "qwen3-coder:30b",
    model_keep_alive: []const u8 = "15m", // How long to keep model in memory (e.g., "5m", "15m", or "-1" for infinite)
    num_ctx: usize = 128000, // Context window size in tokens (Ollama: per-request; LM Studio: set at model load time)
    num_predict: isize = 8192, // Max tokens to generate per response (default: 8192 for detailed code generation)
    editor: []const []const u8 = &.{"nvim"},
    // UI customization
    scroll_lines: usize = 3, // Number of lines to scroll per wheel movement
    // Color customization
    color_status: []const u8 = "\x1b[33m", // Yellow - AI responding status
    color_link: []const u8 = "\x1b[36m", // Cyan - Link text
    color_thinking_header: []const u8 = "\x1b[36m", // Cyan - "Thinking" header
    color_thinking_dim: []const u8 = "\x1b[2m", // Dim - Thinking content
    color_inline_code_bg: []const u8 = "\x1b[48;5;237m", // Grey background - Inline code
    // Thinking mode
    enable_thinking: bool = true, // Enable extended thinking mode for complex reasoning
    // Tool call display
    show_tool_json: bool = false, // Show raw JSON tool calls (for debugging, default hidden)
    // File reading thresholds (smart auto-detection)
    file_read_small_threshold: usize = 200, // Files <= this: show full content (no agent overhead). Files > this: use conversation-aware curation agent

    /// Validate configuration values and warn about incompatibilities
    pub fn validate(self: *const Config) !void {
        const llm_provider = @import("llm_provider");

        // Validate provider exists
        const caps = llm_provider.ProviderRegistry.get(self.provider) orelse {
            std.debug.print("❌ Invalid provider: '{s}'\n", .{self.provider});
            std.debug.print("   Available providers: ", .{});
            for (llm_provider.ProviderRegistry.ALL, 0..) |provider, i| {
                if (i > 0) std.debug.print(", ", .{});
                std.debug.print("{s}", .{provider.name});
            }
            std.debug.print("\n", .{});
            return error.InvalidProvider;
        };

        // Validate num_ctx range
        if (self.num_ctx < 512 or self.num_ctx > 1_000_000) {
            std.debug.print("❌ Invalid num_ctx: {d}. Must be between 512 and 1,000,000\n", .{self.num_ctx});
            return error.InvalidContextSize;
        }

        // Validate num_predict is reasonable
        if (self.num_predict < -1 or self.num_predict > 100_000) {
            std.debug.print("❌ Invalid num_predict: {d}. Must be between -1 and 100,000\n", .{self.num_predict});
            return error.InvalidPredictSize;
        }

        // Validate URLs
        if (!mem.startsWith(u8, self.ollama_host, "http://") and !mem.startsWith(u8, self.ollama_host, "https://")) {
            std.debug.print("⚠ Warning: ollama_host should start with http:// or https://\n", .{});
        }
        if (!mem.startsWith(u8, self.lmstudio_host, "http://") and !mem.startsWith(u8, self.lmstudio_host, "https://")) {
            std.debug.print("⚠ Warning: lmstudio_host should start with http:// or https://\n", .{});
        }

        // Warn about unsupported feature combinations
        if (self.enable_thinking and !caps.supports_thinking) {
            std.debug.print("⚠ Warning: {s} doesn't support thinking mode. Feature will be disabled.\n", .{caps.name});
        }

        // Display provider-specific warnings
        for (caps.config_warnings) |warning| {
            std.debug.print("⚠ Note ({s}): {s}\n", .{ caps.name, warning.message });
        }
    }

    /// Get the value of a provider-specific field
    pub fn getProviderField(
        self: *const Config,
        provider: []const u8,
        field_key: []const u8,
    ) @import("llm_provider").ConfigValue {
        if (mem.eql(u8, provider, "ollama")) {
            if (mem.eql(u8, field_key, "host")) return .{ .text = self.ollama_host };
            if (mem.eql(u8, field_key, "endpoint")) return .{ .text = self.ollama_endpoint };
            if (mem.eql(u8, field_key, "keep_alive")) return .{ .text = self.model_keep_alive };
        } else if (mem.eql(u8, provider, "lmstudio")) {
            if (mem.eql(u8, field_key, "host")) return .{ .text = self.lmstudio_host };
            if (mem.eql(u8, field_key, "auto_start")) return .{ .boolean = self.lmstudio_auto_start };
            if (mem.eql(u8, field_key, "auto_load_model")) return .{ .boolean = self.lmstudio_auto_load_model };
            if (mem.eql(u8, field_key, "gpu_offload")) return .{ .text = self.lmstudio_gpu_offload };
            if (mem.eql(u8, field_key, "ttl")) return .{ .number = @as(isize, @intCast(self.lmstudio_ttl)) };
        }

        // Return default empty value if not found
        return .{ .text = "" };
    }

    /// Set the value of a provider-specific field
    pub fn setProviderField(
        self: *Config,
        allocator: mem.Allocator,
        provider: []const u8,
        field_key: []const u8,
        value: @import("llm_provider").ConfigValue,
    ) !void {
        if (mem.eql(u8, provider, "ollama")) {
            if (mem.eql(u8, field_key, "host")) {
                allocator.free(self.ollama_host);
                self.ollama_host = try allocator.dupe(u8, value.text);
            } else if (mem.eql(u8, field_key, "endpoint")) {
                allocator.free(self.ollama_endpoint);
                self.ollama_endpoint = try allocator.dupe(u8, value.text);
            } else if (mem.eql(u8, field_key, "keep_alive")) {
                allocator.free(self.model_keep_alive);
                self.model_keep_alive = try allocator.dupe(u8, value.text);
            }
        } else if (mem.eql(u8, provider, "lmstudio")) {
            if (mem.eql(u8, field_key, "host")) {
                allocator.free(self.lmstudio_host);
                self.lmstudio_host = try allocator.dupe(u8, value.text);
            } else if (mem.eql(u8, field_key, "auto_start")) {
                self.lmstudio_auto_start = value.boolean;
            } else if (mem.eql(u8, field_key, "auto_load_model")) {
                self.lmstudio_auto_load_model = value.boolean;
            } else if (mem.eql(u8, field_key, "gpu_offload")) {
                allocator.free(self.lmstudio_gpu_offload);
                self.lmstudio_gpu_offload = try allocator.dupe(u8, value.text);
            } else if (mem.eql(u8, field_key, "ttl")) {
                self.lmstudio_ttl = @as(usize, @intCast(@max(0, value.number)));
            }
        }
    }

    pub fn deinit(self: *Config, allocator: mem.Allocator) void {
        allocator.free(self.provider);
        allocator.free(self.ollama_host);
        allocator.free(self.ollama_endpoint);
        allocator.free(self.lmstudio_host);
        allocator.free(self.lmstudio_gpu_offload);
        allocator.free(self.model);
        allocator.free(self.model_keep_alive);
        for (self.editor) |arg| {
            allocator.free(arg);
        }
        allocator.free(self.editor);
        allocator.free(self.color_status);
        allocator.free(self.color_link);
        allocator.free(self.color_thinking_header);
        allocator.free(self.color_thinking_dim);
        allocator.free(self.color_inline_code_bg);
    }
};

/// JSON-serializable config file structure
pub const ConfigFile = struct {
    provider: ?[]const u8 = null,
    editor: ?[]const []const u8 = null,
    ollama_host: ?[]const u8 = null,
    ollama_endpoint: ?[]const u8 = null,
    lmstudio_host: ?[]const u8 = null,
    lmstudio_auto_start: ?bool = null,
    lmstudio_auto_load_model: ?bool = null,
    lmstudio_gpu_offload: ?[]const u8 = null,
    lmstudio_ttl: ?usize = null,
    model: ?[]const u8 = null,
    model_keep_alive: ?[]const u8 = null,
    num_ctx: ?usize = null,
    num_predict: ?isize = null,
    scroll_lines: ?usize = null,
    color_status: ?[]const u8 = null,
    color_link: ?[]const u8 = null,
    color_thinking_header: ?[]const u8 = null,
    color_thinking_dim: ?[]const u8 = null,
    color_inline_code_bg: ?[]const u8 = null,
    enable_thinking: ?bool = null,
    show_tool_json: ?bool = null,
    file_read_small_threshold: ?usize = null,
};

/// JSON-serializable policy structure
const PolicyFile = struct {
    scope: []const u8, // "read_files", "write_files", etc.
    mode: []const u8, // "always_allow", "allow_once", "ask_each_time", "deny"
    path_patterns: []const []const u8,
    deny_patterns: []const []const u8,
};

/// Load configuration from active profile
pub fn loadConfigFromFile(allocator: mem.Allocator) !Config {
    // Default config - properly allocate all strings
    const default_editor = try allocator.alloc([]const u8, 1);
    default_editor[0] = try allocator.dupe(u8, "nvim");

    var config = Config{
        .provider = try allocator.dupe(u8, "ollama"),
        .ollama_host = try allocator.dupe(u8, "http://localhost:11434"),
        .ollama_endpoint = try allocator.dupe(u8, "/api/chat"),
        .lmstudio_host = try allocator.dupe(u8, "http://localhost:1234"),
        .lmstudio_auto_start = true,
        .lmstudio_auto_load_model = true,
        .lmstudio_gpu_offload = try allocator.dupe(u8, "auto"),
        .lmstudio_ttl = 0,
        .model = try allocator.dupe(u8, "qwen3-coder:30b"),
        .model_keep_alive = try allocator.dupe(u8, "15m"),
        .editor = default_editor,
        .scroll_lines = 3,
        .color_status = try allocator.dupe(u8, "\x1b[33m"),
        .color_link = try allocator.dupe(u8, "\x1b[36m"),
        .color_thinking_header = try allocator.dupe(u8, "\x1b[36m"),
        .color_thinking_dim = try allocator.dupe(u8, "\x1b[2m"),
        .color_inline_code_bg = try allocator.dupe(u8, "\x1b[48;5;237m"),
    };

    // Try to get home directory
    const home = std.posix.getenv("HOME") orelse return config;

    // Build paths
    const config_dir = try fs.path.join(allocator, &.{home, ".config", "localharness"});
    defer allocator.free(config_dir);

    const profiles_dir = try fs.path.join(allocator, &.{config_dir, "profiles"});
    defer allocator.free(profiles_dir);

    // Ensure profiles directory exists
    fs.cwd().makePath(profiles_dir) catch |err| {
        if (err != error.PathAlreadyExists) return config;
    };

    // Get active profile name
    const profile_manager = @import("profile_manager");
    const active_profile = try profile_manager.getActiveProfileName(allocator);
    defer allocator.free(active_profile);

    // Build profile path
    const profile_filename = try std.fmt.allocPrint(allocator, "{s}.json", .{active_profile});
    defer allocator.free(profile_filename);
    const config_path = try fs.path.join(allocator, &.{profiles_dir, profile_filename});
    defer allocator.free(config_path);

    // Try to open and read config file
    const file = fs.cwd().openFile(config_path, .{}) catch |err| {
        // File doesn't exist - create it with defaults
        if (err == error.FileNotFound) {
            // Create profiles directory if it doesn't exist
            fs.cwd().makePath(profiles_dir) catch |dir_err| {
                if (dir_err != error.PathAlreadyExists) return config;
            };

            // Create default profile file (serialize current config with defaults)
            const new_file = fs.cwd().createFile(config_path, .{}) catch return config;
            defer new_file.close();

            // Generate default config JSON from the config struct
            const default_config_json = std.fmt.allocPrint(
                allocator,
                "{f}\n",
                .{std.json.fmt(config, .{ .whitespace = .indent_2 })},
            ) catch return config;
            defer allocator.free(default_config_json);

            new_file.writeAll(default_config_json) catch return config;

            return config;
        }
        return config;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 16) catch return config;
    defer allocator.free(content);

    // Parse JSON
    const parsed = std.json.parseFromSlice(ConfigFile, allocator, content, .{}) catch return config;
    defer parsed.deinit();

    // Apply loaded values
    if (parsed.value.provider) |provider| {
        allocator.free(config.provider);
        config.provider = try allocator.dupe(u8, provider);
    }

    if (parsed.value.ollama_host) |ollama_host| {
        allocator.free(config.ollama_host);
        config.ollama_host = try allocator.dupe(u8, ollama_host);
    }

    if (parsed.value.lmstudio_host) |lmstudio_host| {
        allocator.free(config.lmstudio_host);
        config.lmstudio_host = try allocator.dupe(u8, lmstudio_host);
    }

    if (parsed.value.lmstudio_auto_start) |lmstudio_auto_start| {
        config.lmstudio_auto_start = lmstudio_auto_start;
    }

    if (parsed.value.lmstudio_auto_load_model) |lmstudio_auto_load_model| {
        config.lmstudio_auto_load_model = lmstudio_auto_load_model;
    }

    if (parsed.value.lmstudio_gpu_offload) |lmstudio_gpu_offload| {
        allocator.free(config.lmstudio_gpu_offload);
        config.lmstudio_gpu_offload = try allocator.dupe(u8, lmstudio_gpu_offload);
    }

    if (parsed.value.lmstudio_ttl) |lmstudio_ttl| {
        config.lmstudio_ttl = lmstudio_ttl;
    }

    if (parsed.value.model) |model| {
        allocator.free(config.model);
        config.model = try allocator.dupe(u8, model);
    }

    if (parsed.value.model_keep_alive) |model_keep_alive| {
        allocator.free(config.model_keep_alive);
        config.model_keep_alive = try allocator.dupe(u8, model_keep_alive);
    }

    if (parsed.value.num_ctx) |num_ctx| {
        config.num_ctx = num_ctx;
    }

    if (parsed.value.num_predict) |num_predict| {
        config.num_predict = num_predict;
    }

    if (parsed.value.editor) |editor| {
        for (config.editor) |arg| allocator.free(arg);
        allocator.free(config.editor);

        var new_editor = try allocator.alloc([]const u8, editor.len);
        for (editor, 0..) |arg, i| {
            new_editor[i] = try allocator.dupe(u8, arg);
        }
        config.editor = new_editor;
    }

    if (parsed.value.ollama_endpoint) |ollama_endpoint| {
        allocator.free(config.ollama_endpoint);
        config.ollama_endpoint = try allocator.dupe(u8, ollama_endpoint);
    }

    if (parsed.value.scroll_lines) |scroll_lines| {
        config.scroll_lines = scroll_lines;
    }

    if (parsed.value.color_status) |color_status| {
        allocator.free(config.color_status);
        config.color_status = try allocator.dupe(u8, color_status);
    }

    if (parsed.value.color_link) |color_link| {
        allocator.free(config.color_link);
        config.color_link = try allocator.dupe(u8, color_link);
    }

    if (parsed.value.color_thinking_header) |color_thinking_header| {
        allocator.free(config.color_thinking_header);
        config.color_thinking_header = try allocator.dupe(u8, color_thinking_header);
    }

    if (parsed.value.color_thinking_dim) |color_thinking_dim| {
        allocator.free(config.color_thinking_dim);
        config.color_thinking_dim = try allocator.dupe(u8, color_thinking_dim);
    }

    if (parsed.value.color_inline_code_bg) |color_inline_code_bg| {
        allocator.free(config.color_inline_code_bg);
        config.color_inline_code_bg = try allocator.dupe(u8, color_inline_code_bg);
    }

    if (parsed.value.enable_thinking) |enable_thinking| {
        config.enable_thinking = enable_thinking;
    }

    if (parsed.value.show_tool_json) |show_tool_json| {
        config.show_tool_json = show_tool_json;
    }

    if (parsed.value.file_read_small_threshold) |file_read_small_threshold| {
        config.file_read_small_threshold = file_read_small_threshold;
    }

    // Validate configuration before returning
    config.validate() catch |err| {
        std.debug.print("⚠ Config validation failed: {s}\n", .{@errorName(err)});
        std.debug.print("   Using config anyway, but some features may not work correctly.\n\n", .{});
    };

    return config;
}

/// Load permission policies from ~/.config/localharness/policies.json
pub fn loadPolicies(allocator: mem.Allocator, permission_manager: *permission.PermissionManager) !void {
    // Try to get home directory
    const home = std.posix.getenv("HOME") orelse return; // No home dir, skip loading

    // Build path: ~/.config/localharness/policies.json
    const config_dir = try fs.path.join(allocator, &.{ home, ".config", "localharness" });
    defer allocator.free(config_dir);
    const policies_path = try fs.path.join(allocator, &.{ config_dir, "policies.json" });
    defer allocator.free(policies_path);

    // Try to open policies file
    const file = fs.cwd().openFile(policies_path, .{}) catch |err| {
        // File doesn't exist is OK - just means no policies saved yet
        if (err == error.FileNotFound) return;
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024); // 1MB max
    defer allocator.free(content);

    // Parse JSON
    const parsed = try std.json.parseFromSlice([]const PolicyFile, allocator, content, .{});
    defer parsed.deinit();

    // Convert PolicyFile to Policy and add to engine
    for (parsed.value) |policy_file| {
        // Parse scope
        const scope: permission.Scope = if (mem.eql(u8, policy_file.scope, "read_files"))
            .read_files
        else if (mem.eql(u8, policy_file.scope, "write_files"))
            .write_files
        else if (mem.eql(u8, policy_file.scope, "execute_commands"))
            .execute_commands
        else if (mem.eql(u8, policy_file.scope, "network_access"))
            .network_access
        else if (mem.eql(u8, policy_file.scope, "system_info"))
            .system_info
        else if (mem.eql(u8, policy_file.scope, "todo_management"))
            .todo_management
        else
            continue; // Skip unknown scopes

        // Parse mode
        const mode: permission.PermissionMode = if (mem.eql(u8, policy_file.mode, "always_allow"))
            .always_allow
        else if (mem.eql(u8, policy_file.mode, "allow_once"))
            .allow_once
        else if (mem.eql(u8, policy_file.mode, "ask_each_time"))
            .ask_each_time
        else if (mem.eql(u8, policy_file.mode, "deny"))
            .deny
        else
            continue; // Skip unknown modes

        // Duplicate path patterns
        var path_patterns = try allocator.alloc([]const u8, policy_file.path_patterns.len);
        for (policy_file.path_patterns, 0..) |pattern, i| {
            path_patterns[i] = try allocator.dupe(u8, pattern);
        }

        // Duplicate deny patterns
        var deny_patterns = try allocator.alloc([]const u8, policy_file.deny_patterns.len);
        for (policy_file.deny_patterns, 0..) |pattern, i| {
            deny_patterns[i] = try allocator.dupe(u8, pattern);
        }

        // Add policy to engine
        try permission_manager.policy_engine.addPolicy(.{
            .scope = scope,
            .mode = mode,
            .path_patterns = path_patterns,
            .deny_patterns = deny_patterns,
        });
    }
}

/// Save permission policies to ~/.config/localharness/policies.json
pub fn savePolicies(allocator: mem.Allocator, permission_manager: *permission.PermissionManager) !void {
    // Get home directory
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;

    // Build path: ~/.config/localharness/policies.json
    const config_dir = try fs.path.join(allocator, &.{ home, ".config", "localharness" });
    defer allocator.free(config_dir);

    // Ensure config directory exists
    fs.cwd().makePath(config_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const policies_path = try fs.path.join(allocator, &.{ config_dir, "policies.json" });
    defer allocator.free(policies_path);

    // Convert policies to PolicyFile format
    var policy_files = std.ArrayListUnmanaged(PolicyFile){};
    defer policy_files.deinit(allocator);

    for (permission_manager.policy_engine.policies.items) |policy| {
        const scope_str = switch (policy.scope) {
            .read_files => "read_files",
            .write_files => "write_files",
            .execute_commands => "execute_commands",
            .network_access => "network_access",
            .system_info => "system_info",
            .todo_management => "todo_management",
        };

        const mode_str = switch (policy.mode) {
            .always_allow => "always_allow",
            .allow_once => "allow_once",
            .ask_each_time => "ask_each_time",
            .deny => "deny",
        };

        try policy_files.append(allocator, .{
            .scope = scope_str,
            .mode = mode_str,
            .path_patterns = policy.path_patterns,
            .deny_patterns = policy.deny_patterns,
        });
    }

    // Serialize to JSON using std.json.fmt
    const json_string = try std.fmt.allocPrint(
        allocator,
        "{f}\n",
        .{std.json.fmt(policy_files.items, .{ .whitespace = .indent_2 })},
    );
    defer allocator.free(json_string);

    // Write to file
    const file = try fs.cwd().createFile(policies_path, .{ .truncate = true });
    defer file.close();

    try file.writeAll(json_string);
}

/// Save configuration to active profile
pub fn saveConfigToFile(allocator: mem.Allocator, config: Config) !void {
    const profile_manager = @import("profile_manager");

    // Get active profile name
    const active_profile = try profile_manager.getActiveProfileName(allocator);
    defer allocator.free(active_profile);

    // Save to that profile
    try profile_manager.saveProfile(allocator, active_profile, config);
}
