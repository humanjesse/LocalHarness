// Configuration management - loading, saving, and persistence
const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const permission = @import("permission.zig");

/// Application configuration
pub const Config = struct {
    ollama_host: []const u8 = "http://localhost:11434",
    ollama_endpoint: []const u8 = "/api/chat",
    model: []const u8 = "qwen3-coder:30b",
    model_keep_alive: []const u8 = "15m", // How long to keep model in memory (e.g., "5m", "15m", or "-1" for infinite)
    num_ctx: usize = 128000, // Context window size in tokens (default: 128k for full conversation history)
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

    pub fn deinit(self: *Config, allocator: mem.Allocator) void {
        allocator.free(self.ollama_host);
        allocator.free(self.ollama_endpoint);
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
const ConfigFile = struct {
    editor: ?[]const []const u8 = null,
    ollama_host: ?[]const u8 = null,
    ollama_endpoint: ?[]const u8 = null,
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
};

/// JSON-serializable policy structure
const PolicyFile = struct {
    scope: []const u8, // "read_files", "write_files", etc.
    mode: []const u8, // "always_allow", "allow_once", "ask_each_time", "deny"
    path_patterns: []const []const u8,
    deny_patterns: []const []const u8,
};

/// Load configuration from ~/.config/zodollama/config.json
pub fn loadConfigFromFile(allocator: mem.Allocator) !Config {
    // Default config - properly allocate all strings
    const default_editor = try allocator.alloc([]const u8, 1);
    default_editor[0] = try allocator.dupe(u8, "nvim");

    var config = Config{
        .ollama_host = try allocator.dupe(u8, "http://localhost:11434"),
        .ollama_endpoint = try allocator.dupe(u8, "/api/chat"),
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

    // Build config file path: ~/.config/zodollama/config.json
    const config_dir = try fs.path.join(allocator, &.{home, ".config", "zodollama"});
    defer allocator.free(config_dir);
    const config_path = try fs.path.join(allocator, &.{config_dir, "config.json"});
    defer allocator.free(config_path);

    // Try to open and read config file
    const file = fs.cwd().openFile(config_path, .{}) catch |err| {
        // File doesn't exist - create it with defaults
        if (err == error.FileNotFound) {
            // Create config directory if it doesn't exist
            fs.cwd().makePath(config_dir) catch |dir_err| {
                if (dir_err != error.PathAlreadyExists) return config;
            };

            // Create default config file
            const new_file = fs.cwd().createFile(config_path, .{}) catch return config;
            defer new_file.close();

            const default_config =
                \\{
                \\  "editor": ["nvim"],
                \\  "ollama_host": "http://localhost:11434",
                \\  "ollama_endpoint": "/api/chat",
                \\  "model": "qwen3-coder:30b",
                \\  "model_keep_alive": "15m",
                \\  "num_ctx": 128000,
                \\  "num_predict": 8192,
                \\  "scroll_lines": 3,
                \\  "color_status": "\u001b[33m",
                \\  "color_link": "\u001b[36m",
                \\  "color_thinking_header": "\u001b[36m",
                \\  "color_thinking_dim": "\u001b[2m",
                \\  "color_inline_code_bg": "\u001b[48;5;237m"
                \\}
                \\
            ;
            new_file.writeAll(default_config) catch return config;

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
    if (parsed.value.ollama_host) |ollama_host| {
        allocator.free(config.ollama_host);
        config.ollama_host = try allocator.dupe(u8, ollama_host);
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

    return config;
}

/// Load permission policies from ~/.config/zodollama/policies.json
pub fn loadPolicies(allocator: mem.Allocator, permission_manager: *permission.PermissionManager) !void {
    // Try to get home directory
    const home = std.posix.getenv("HOME") orelse return; // No home dir, skip loading

    // Build path: ~/.config/zodollama/policies.json
    const config_dir = try fs.path.join(allocator, &.{ home, ".config", "zodollama" });
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
        else if (mem.eql(u8, policy_file.scope, "task_management"))
            .task_management
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

/// Save permission policies to ~/.config/zodollama/policies.json
pub fn savePolicies(allocator: mem.Allocator, permission_manager: *permission.PermissionManager) !void {
    // Get home directory
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;

    // Build path: ~/.config/zodollama/policies.json
    const config_dir = try fs.path.join(allocator, &.{ home, ".config", "zodollama" });
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
            .task_management => "task_management",
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

    // Manually serialize to JSON (Zig 0.15.2 compatible)
    var json_buffer = std.ArrayListUnmanaged(u8){};
    defer json_buffer.deinit(allocator);
    const writer = json_buffer.writer(allocator);

    try writer.writeAll("[\n");
    for (policy_files.items, 0..) |policy, i| {
        try writer.writeAll("  {\n");
        try writer.print("    \"scope\": \"{s}\",\n", .{policy.scope});
        try writer.print("    \"mode\": \"{s}\",\n", .{policy.mode});
        try writer.writeAll("    \"path_patterns\": [");
        for (policy.path_patterns, 0..) |pattern, j| {
            try writer.print("\"{s}\"", .{pattern});
            if (j < policy.path_patterns.len - 1) try writer.writeAll(", ");
        }
        try writer.writeAll("],\n");
        try writer.writeAll("    \"deny_patterns\": [");
        for (policy.deny_patterns, 0..) |pattern, j| {
            try writer.print("\"{s}\"", .{pattern});
            if (j < policy.deny_patterns.len - 1) try writer.writeAll(", ");
        }
        try writer.writeAll("]\n");
        try writer.writeAll("  }");
        if (i < policy_files.items.len - 1) try writer.writeAll(",");
        try writer.writeAll("\n");
    }
    try writer.writeAll("]\n");

    // Write to file
    const file = try fs.cwd().createFile(policies_path, .{ .truncate = true });
    defer file.close();

    try file.writeAll(json_buffer.items);
}
