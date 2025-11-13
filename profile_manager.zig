// Profile management - CRUD operations and profile switching logic
const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const config_module = @import("config");
const Config = config_module.Config;

/// Get the profiles directory path
fn getProfilesDirectory(allocator: mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    return try fs.path.join(allocator, &.{ home, ".config", "localharness", "profiles" });
}

/// Get the active_profile.txt file path
fn getActiveProfilePath(allocator: mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    return try fs.path.join(allocator, &.{ home, ".config", "localharness", "active_profile.txt" });
}

/// List all available profile names
pub fn listProfiles(allocator: mem.Allocator) ![][]const u8 {
    const profiles_dir = try getProfilesDirectory(allocator);
    defer allocator.free(profiles_dir);

    // Open profiles directory
    var dir = fs.cwd().openDir(profiles_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            // No profiles directory yet - return empty list
            return &[_][]const u8{};
        }
        return err;
    };
    defer dir.close();

    // Iterate through directory and collect .json files
    var profile_list = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    defer {
        // Don't free on normal path since we return the slice
        // Only free on error path
    }
    errdefer {
        for (profile_list.items) |name| allocator.free(name);
        profile_list.deinit(allocator);
    }

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;

        // Check if it ends with .json
        if (mem.endsWith(u8, entry.name, ".json")) {
            // Strip .json extension
            const name_without_ext = entry.name[0 .. entry.name.len - 5];
            try profile_list.append(allocator, try allocator.dupe(u8, name_without_ext));
        }
    }

    return try profile_list.toOwnedSlice(allocator);
}

/// Get the currently active profile name
pub fn getActiveProfileName(allocator: mem.Allocator) ![]u8 {
    const active_path = try getActiveProfilePath(allocator);
    defer allocator.free(active_path);

    const file = fs.cwd().openFile(active_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            // No active profile marker - default to "default"
            return try allocator.dupe(u8, "default");
        }
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024);
    defer allocator.free(content);
    // Trim whitespace
    return try allocator.dupe(u8, mem.trim(u8, content, &std.ascii.whitespace));
}

/// Set the active profile name
pub fn setActiveProfileName(allocator: mem.Allocator, profile_name: []const u8) !void {
    const active_path = try getActiveProfilePath(allocator);
    defer allocator.free(active_path);

    const file = try fs.cwd().createFile(active_path, .{ .truncate = true });
    defer file.close();

    try file.writeAll(profile_name);
}

/// Validate profile name (alphanumeric, dash, underscore only)
pub fn validateProfileName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name.len > 64) return false; // Reasonable limit

    for (name) |c| {
        const valid = (c >= 'a' and c <= 'z') or
                     (c >= 'A' and c <= 'Z') or
                     (c >= '0' and c <= '9') or
                     c == '-' or c == '_';
        if (!valid) return false;
    }

    return true;
}

/// Load a config from a specific profile
pub fn loadProfile(allocator: mem.Allocator, profile_name: []const u8) !Config {
    const profiles_dir = try getProfilesDirectory(allocator);
    defer allocator.free(profiles_dir);

    const profile_filename = try std.fmt.allocPrint(allocator, "{s}.json", .{profile_name});
    defer allocator.free(profile_filename);

    const profile_path = try fs.path.join(allocator, &.{ profiles_dir, profile_filename });
    defer allocator.free(profile_path);

    // Open and read profile file
    const file = try fs.cwd().openFile(profile_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 16);
    defer allocator.free(content);

    // Parse JSON into ConfigFile
    const parsed = try std.json.parseFromSlice(config_module.ConfigFile, allocator, content, .{});
    defer parsed.deinit();

    // Build config from parsed data (same logic as loadConfigFromFile)
    return try buildConfigFromParsed(allocator, parsed.value);
}

/// Helper to build Config from parsed JSON (extracted from config.zig logic)
fn buildConfigFromParsed(allocator: mem.Allocator, parsed: anytype) !Config {
    // Create default config first
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

    // Apply parsed values (same logic as config.zig:268-374)
    if (parsed.provider) |provider| {
        allocator.free(config.provider);
        config.provider = try allocator.dupe(u8, provider);
    }

    if (parsed.ollama_host) |ollama_host| {
        allocator.free(config.ollama_host);
        config.ollama_host = try allocator.dupe(u8, ollama_host);
    }

    if (parsed.lmstudio_host) |lmstudio_host| {
        allocator.free(config.lmstudio_host);
        config.lmstudio_host = try allocator.dupe(u8, lmstudio_host);
    }

    if (parsed.lmstudio_auto_start) |lmstudio_auto_start| {
        config.lmstudio_auto_start = lmstudio_auto_start;
    }

    if (parsed.lmstudio_auto_load_model) |lmstudio_auto_load_model| {
        config.lmstudio_auto_load_model = lmstudio_auto_load_model;
    }

    if (parsed.lmstudio_gpu_offload) |lmstudio_gpu_offload| {
        allocator.free(config.lmstudio_gpu_offload);
        config.lmstudio_gpu_offload = try allocator.dupe(u8, lmstudio_gpu_offload);
    }

    if (parsed.lmstudio_ttl) |lmstudio_ttl| {
        config.lmstudio_ttl = lmstudio_ttl;
    }

    if (parsed.model) |model| {
        allocator.free(config.model);
        config.model = try allocator.dupe(u8, model);
    }

    if (parsed.model_keep_alive) |model_keep_alive| {
        allocator.free(config.model_keep_alive);
        config.model_keep_alive = try allocator.dupe(u8, model_keep_alive);
    }

    if (parsed.num_ctx) |num_ctx| {
        config.num_ctx = num_ctx;
    }

    if (parsed.num_predict) |num_predict| {
        config.num_predict = num_predict;
    }

    if (parsed.editor) |editor| {
        for (config.editor) |arg| allocator.free(arg);
        allocator.free(config.editor);

        var new_editor = try allocator.alloc([]const u8, editor.len);
        for (editor, 0..) |arg, i| {
            new_editor[i] = try allocator.dupe(u8, arg);
        }
        config.editor = new_editor;
    }

    if (parsed.ollama_endpoint) |ollama_endpoint| {
        allocator.free(config.ollama_endpoint);
        config.ollama_endpoint = try allocator.dupe(u8, ollama_endpoint);
    }

    if (parsed.scroll_lines) |scroll_lines| {
        config.scroll_lines = scroll_lines;
    }

    if (parsed.color_status) |color_status| {
        allocator.free(config.color_status);
        config.color_status = try allocator.dupe(u8, color_status);
    }

    if (parsed.color_link) |color_link| {
        allocator.free(config.color_link);
        config.color_link = try allocator.dupe(u8, color_link);
    }

    if (parsed.color_thinking_header) |color_thinking_header| {
        allocator.free(config.color_thinking_header);
        config.color_thinking_header = try allocator.dupe(u8, color_thinking_header);
    }

    if (parsed.color_thinking_dim) |color_thinking_dim| {
        allocator.free(config.color_thinking_dim);
        config.color_thinking_dim = try allocator.dupe(u8, color_thinking_dim);
    }

    if (parsed.color_inline_code_bg) |color_inline_code_bg| {
        allocator.free(config.color_inline_code_bg);
        config.color_inline_code_bg = try allocator.dupe(u8, color_inline_code_bg);
    }

    if (parsed.enable_thinking) |enable_thinking| {
        config.enable_thinking = enable_thinking;
    }

    if (parsed.show_tool_json) |show_tool_json| {
        config.show_tool_json = show_tool_json;
    }

    if (parsed.file_read_small_threshold) |file_read_small_threshold| {
        config.file_read_small_threshold = file_read_small_threshold;
    }

    return config;
}

/// Save a config to a specific profile
pub fn saveProfile(allocator: mem.Allocator, profile_name: []const u8, config: Config) !void {
    const profiles_dir = try getProfilesDirectory(allocator);
    defer allocator.free(profiles_dir);

    // Ensure profiles directory exists
    fs.cwd().makePath(profiles_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const profile_filename = try std.fmt.allocPrint(allocator, "{s}.json", .{profile_name});
    defer allocator.free(profile_filename);

    const profile_path = try fs.path.join(allocator, &.{ profiles_dir, profile_filename });
    defer allocator.free(profile_path);

    // Serialize config to JSON
    const json_string = try std.fmt.allocPrint(
        allocator,
        "{f}\n",
        .{std.json.fmt(config, .{ .whitespace = .indent_2 })},
    );
    defer allocator.free(json_string);

    // Write to file
    const file = try fs.cwd().createFile(profile_path, .{ .truncate = true });
    defer file.close();

    try file.writeAll(json_string);
}

/// Delete a profile
pub fn deleteProfile(allocator: mem.Allocator, profile_name: []const u8) !void {
    const profiles_dir = try getProfilesDirectory(allocator);
    defer allocator.free(profiles_dir);

    const profile_filename = try std.fmt.allocPrint(allocator, "{s}.json", .{profile_name});
    defer allocator.free(profile_filename);

    const profile_path = try fs.path.join(allocator, &.{ profiles_dir, profile_filename });
    defer allocator.free(profile_path);

    try fs.cwd().deleteFile(profile_path);
}

/// Switch to a different profile (full reinitialization)
pub fn switchActiveProfile(app: anytype, profile_name: []const u8) !void {
    const allocator = app.allocator;

    // 1. Load new config
    var new_config = try loadProfile(allocator, profile_name);
    errdefer new_config.deinit(allocator);

    // 2. Validate config
    try new_config.validate();

    // 3. Clean up old config
    app.config.deinit(allocator);

    // 4. Replace config
    app.config = new_config;

    // 5. Reinitialize systems (same pattern as config editor save in app.zig:1179-1188)
    const markdown = @import("markdown");
    const ui = @import("ui");
    const llm_provider_module = @import("llm_provider");

    markdown.initColors(app.config.color_inline_code_bg);
    ui.initUIColors(app.config.color_status);

    app.llm_provider.deinit();
    app.llm_provider = try llm_provider_module.createProvider(
        app.config.provider,
        allocator,
        app.config,
    );

    // 6. Update active profile marker
    try setActiveProfileName(allocator, profile_name);
}
