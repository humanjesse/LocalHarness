// LM Studio CLI Manager - Wrapper for lms-cli commands
const std = @import("std");
const fs = std.fs;
const mem = std.mem;

/// Manager for LM Studio CLI operations
pub const LMStudioManager = struct {
    allocator: mem.Allocator,
    lms_path: []const u8,

    /// Initialize LM Studio manager by detecting lms binary
    pub fn init(allocator: mem.Allocator) !LMStudioManager {
        const path = try detectLMSPath(allocator);
        return .{
            .allocator = allocator,
            .lms_path = path,
        };
    }

    pub fn deinit(self: *LMStudioManager) void {
        self.allocator.free(self.lms_path);
    }

    /// Detect location of lms binary
    fn detectLMSPath(allocator: mem.Allocator) ![]const u8 {
        const home = std.posix.getenv("HOME") orelse return error.NoHomeDirectory;

        // Try ~/.lmstudio/bin/lms (default location)
        const default_path = try fs.path.join(allocator, &.{ home, ".lmstudio", "bin", "lms" });
        errdefer allocator.free(default_path);

        // Check if exists and is executable
        fs.accessAbsolute(default_path, .{}) catch {
            allocator.free(default_path);
            return error.LMSNotFound;
        };

        return default_path;
    }

    /// Check if LM Studio server is currently running
    pub fn isServerRunning(self: *LMStudioManager) !bool {
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ self.lms_path, "server", "status" },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        // lms server status returns 0 if running
        return switch (result.term) {
            .Exited => |code| code == 0,
            else => false,
        };
    }

    /// Start the LM Studio local server
    pub fn startServer(self: *LMStudioManager) !void {
        std.debug.print("   Running: {s} server start\n", .{self.lms_path});

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ self.lms_path, "server", "start" },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| {
                if (code != 0) {
                    std.debug.print("   stderr: {s}\n", .{result.stderr});
                    return error.ServerStartFailed;
                }
            },
            else => return error.ServerStartFailed,
        }

        if (result.stdout.len > 0) {
            std.debug.print("   {s}\n", .{result.stdout});
        }
    }

    /// List currently loaded models
    pub fn listLoadedModels(self: *LMStudioManager) ![]LoadedModelInfo {
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ self.lms_path, "ps", "--json" },
        });
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| {
                if (code != 0) {
                    self.allocator.free(result.stdout);
                    return error.CommandFailed;
                }
            },
            else => {
                self.allocator.free(result.stdout);
                return error.CommandFailed;
            },
        }

        // Parse JSON response
        // Use intermediate struct matching actual JSON field names
        const ModelJson = struct {
            identifier: []const u8,
            path: []const u8,
            maxContextLength: ?usize = null,
            contextLength: ?usize = null,
            trainedForToolUse: ?bool = null,
            architecture: ?[]const u8 = null,
        };

        const parsed = std.json.parseFromSlice(
            []ModelJson,
            self.allocator,
            result.stdout,
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            std.debug.print("⚠ Failed to parse lms ps output: {s}\n", .{@errorName(err)});
            self.allocator.free(result.stdout);
            return &[_]LoadedModelInfo{}; // Return empty array on parse error
        };
        defer parsed.deinit();
        // DON'T free result.stdout yet - parsed.value contains slices into it!

        // Convert to LoadedModelInfo with owned strings
        const owned = try self.allocator.alloc(LoadedModelInfo, parsed.value.len);
        var i: usize = 0;
        errdefer {
            // Free any strings that were allocated before the error
            for (owned[0..i]) |model| {
                self.allocator.free(model.identifier);
                self.allocator.free(model.path);
                if (model.architecture) |arch| self.allocator.free(arch);
            }
            self.allocator.free(owned);
        }

        for (parsed.value) |model| {
            owned[i] = .{
                .identifier = try self.allocator.dupe(u8, model.identifier),
                .path = try self.allocator.dupe(u8, model.path),
                .max_context_length = model.maxContextLength,
                .context_length = model.contextLength,
                .trained_for_tool_use = model.trainedForToolUse,
                .architecture = if (model.architecture) |arch|
                    try self.allocator.dupe(u8, arch)
                else
                    null,
            };
            i += 1;
        }

        // NOW it's safe to free result.stdout (after we've duped all strings)
        self.allocator.free(result.stdout);

        return owned;
    }

    /// Query all available (downloaded) models via `lms ls --json`
    /// Returns models that are downloaded but not necessarily loaded
    pub fn queryAvailableModels(self: *LMStudioManager) ![]LoadedModelInfo {
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ self.lms_path, "ls", "--json" },
        });
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| {
                if (code != 0) {
                    self.allocator.free(result.stdout);
                    return error.CommandFailed;
                }
            },
            else => {
                self.allocator.free(result.stdout);
                return error.CommandFailed;
            },
        }

        // Parse JSON - same structure as lms ps but without runtime fields
        const ModelJson = struct {
            path: []const u8,
            modelKey: ?[]const u8 = null,  // Some versions use modelKey instead of identifier
            maxContextLength: ?usize = null,
            architecture: ?[]const u8 = null,
        };

        const parsed = std.json.parseFromSlice(
            []ModelJson,
            self.allocator,
            result.stdout,
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            std.debug.print("⚠ Failed to parse lms ls output: {s}\n", .{@errorName(err)});
            self.allocator.free(result.stdout);
            return &[_]LoadedModelInfo{};
        };
        defer parsed.deinit();
        // DON'T free result.stdout yet - parsed.value contains slices into it!

        // Convert to LoadedModelInfo
        const owned = try self.allocator.alloc(LoadedModelInfo, parsed.value.len);
        var i: usize = 0;
        errdefer {
            // Free any strings that were allocated before the error
            for (owned[0..i]) |model| {
                self.allocator.free(model.identifier);
                self.allocator.free(model.path);
                if (model.architecture) |arch| self.allocator.free(arch);
            }
            self.allocator.free(owned);
        }

        for (parsed.value) |model| {
            const identifier = model.modelKey orelse model.path;
            owned[i] = .{
                .identifier = try self.allocator.dupe(u8, identifier),
                .path = try self.allocator.dupe(u8, model.path),
                .max_context_length = model.maxContextLength,
                .context_length = null,  // Not available for unloaded models
                .trained_for_tool_use = null,  // Not available in lms ls
                .architecture = if (model.architecture) |arch|
                    try self.allocator.dupe(u8, arch)
                else
                    null,
            };
            i += 1;
        }

        // NOW it's safe to free result.stdout (after we've duped all strings)
        self.allocator.free(result.stdout);

        return owned;
    }

    /// Result of optimal context length detection
    pub const OptimalContext = struct {
        context: usize,           // Effective context to use
        clamped: bool,            // Whether config was reduced
        model_max: ?usize,        // Model's actual maximum (null if unknown)
    };

    // NOTE: LM Studio CLI does NOT provide metadata for maximum output/prediction tokens.
    // The JSON output from `lms ps --json` and `lms ls --json` includes:
    //   - maxContextLength (input context window) ✓ Used for clamping
    //   - contextLength (currently configured)
    //   - trainedForToolUse, vision, architecture
    // But does NOT include:
    //   - maxPredictTokens, maxOutputTokens, or similar fields
    // Therefore, num_predict (max_tokens in API) is validated by LM Studio at runtime.
    // If the value exceeds model capabilities, LM Studio will clamp or error as appropriate.

    /// Determine optimal context length for a model
    /// Queries model metadata and clamps config value if needed
    pub fn getOptimalContextLength(
        self: *LMStudioManager,
        model_path: []const u8,
        config_context: usize,
    ) OptimalContext {
        // Try loaded models first (lms ps)
        const loaded = self.listLoadedModels() catch |err| blk: {
            if (isDebugEnabled()) {
                std.debug.print("[CONTEXT] Failed to query loaded models: {s}\n", .{@errorName(err)});
            }
            break :blk &[_]LoadedModelInfo{};
        };
        defer self.freeLoadedModels(loaded);

        // Search for model in loaded list
        for (loaded) |model| {
            if (mem.eql(u8, model.path, model_path) or mem.eql(u8, model.identifier, model_path)) {
                if (model.max_context_length) |max_ctx| {
                    if (config_context > max_ctx) {
                        // Clamp to model max
                        if (isDebugEnabled()) {
                            std.debug.print("[CONTEXT] Clamping {d} → {d} (model max: {d})\n",
                                .{config_context, max_ctx, max_ctx});
                        }
                        return .{
                            .context = max_ctx,
                            .clamped = true,
                            .model_max = max_ctx,
                        };
                    } else {
                        // Config is within limits
                        return .{
                            .context = config_context,
                            .clamped = false,
                            .model_max = max_ctx,
                        };
                    }
                }
            }
        }

        // Not in loaded models, try available models (lms ls)
        const available = self.queryAvailableModels() catch |err| blk: {
            if (isDebugEnabled()) {
                std.debug.print("[CONTEXT] Failed to query available models: {s}\n", .{@errorName(err)});
            }
            break :blk &[_]LoadedModelInfo{};
        };
        defer self.freeLoadedModels(available);

        // Search for model in available list
        for (available) |model| {
            if (mem.eql(u8, model.path, model_path) or mem.eql(u8, model.identifier, model_path)) {
                if (model.max_context_length) |max_ctx| {
                    if (config_context > max_ctx) {
                        // Clamp to model max
                        if (isDebugEnabled()) {
                            std.debug.print("[CONTEXT] Clamping {d} → {d} (model max: {d})\n",
                                .{config_context, max_ctx, max_ctx});
                        }
                        return .{
                            .context = max_ctx,
                            .clamped = true,
                            .model_max = max_ctx,
                        };
                    } else {
                        // Config is within limits
                        return .{
                            .context = config_context,
                            .clamped = false,
                            .model_max = max_ctx,
                        };
                    }
                }
            }
        }

        // Model not found or no metadata available - use config as-is
        if (isDebugEnabled()) {
            std.debug.print("[CONTEXT] No metadata for {s}, using config: {d}\n",
                .{model_path, config_context});
        }
        return .{
            .context = config_context,
            .clamped = false,
            .model_max = null,
        };
    }

    fn isDebugEnabled() bool {
        return std.posix.getenv("DEBUG_LMSTUDIO") != null;
    }

    /// Load a specific model with options
    pub fn loadModel(
        self: *LMStudioManager,
        model_path: []const u8,
        gpu_offload: []const u8,
        context_length: ?usize,
        ttl: ?usize,
    ) !void {
        // Convert "auto" to "max" for LM Studio CLI compatibility
        const gpu_value = if (mem.eql(u8, gpu_offload, "auto")) "max" else gpu_offload;

        // Build command preview for console output
        std.debug.print("   Running: {s} load {s} --gpu {s}", .{ self.lms_path, model_path, gpu_value });
        if (context_length) |ctx| {
            std.debug.print(" --context-length {d}", .{ctx});
        }
        if (ttl) |t| {
            std.debug.print(" --ttl {d}", .{t});
        }
        std.debug.print(" -y\n", .{});

        var argv = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
        defer argv.deinit(self.allocator);

        // Allocate argument strings that need to stay alive
        const gpu_arg = try self.allocator.dupe(u8, gpu_value);
        errdefer self.allocator.free(gpu_arg);

        var ctx_arg: ?[]u8 = null;
        errdefer if (ctx_arg) |arg| self.allocator.free(arg);
        if (context_length) |ctx_len| {
            ctx_arg = try std.fmt.allocPrint(self.allocator, "{d}", .{ctx_len});
        }

        var ttl_arg: ?[]u8 = null;
        errdefer if (ttl_arg) |arg| self.allocator.free(arg);
        if (ttl) |ttl_seconds| {
            ttl_arg = try std.fmt.allocPrint(self.allocator, "{d}", .{ttl_seconds});
        }

        // Build argv array
        try argv.appendSlice(self.allocator, &[_][]const u8{
            self.lms_path,
            "load",
            model_path,
        });

        // Add GPU offload option (separate flag and value)
        try argv.append(self.allocator, "--gpu");
        try argv.append(self.allocator, gpu_arg);

        // Add context length option if specified (separate flag and value)
        if (ctx_arg) |arg| {
            try argv.append(self.allocator, "--context-length");
            try argv.append(self.allocator, arg);
        }

        // Add TTL option if specified (separate flag and value)
        if (ttl_arg) |arg| {
            try argv.append(self.allocator, "--ttl");
            try argv.append(self.allocator, arg);
        }

        // Add -y to skip confirmation prompts
        try argv.append(self.allocator, "-y");

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv.items,
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        // Check for errors FIRST before freeing args
        switch (result.term) {
            .Exited => |code| {
                if (code != 0) {
                    std.debug.print("   stderr: {s}\n", .{result.stderr});
                    return error.ModelLoadFailed;
                }
            },
            else => {
                return error.ModelLoadFailed;
            },
        }

        // Success path - free args after process succeeded
        self.allocator.free(gpu_arg);
        if (ctx_arg) |arg| self.allocator.free(arg);
        if (ttl_arg) |arg| self.allocator.free(arg);

        if (result.stdout.len > 0) {
            std.debug.print("   {s}\n", .{result.stdout});
        }

        // Show configured options
        if (context_length) |ctx| {
            std.debug.print("   Context: {d} tokens", .{ctx});
        }
        if (ttl) |t| {
            if (context_length != null) {
                std.debug.print(" | ", .{});
            } else {
                std.debug.print("   ", .{});
            }
            if (t == 0) {
                std.debug.print("TTL: never", .{});
            } else {
                const hours = t / 3600;
                const minutes = (t % 3600) / 60;
                if (hours > 0) {
                    std.debug.print("TTL: {d}h {d}m", .{ hours, minutes });
                } else {
                    std.debug.print("TTL: {d}m", .{minutes});
                }
            }
        }
        if (context_length != null or ttl != null) {
            std.debug.print("\n", .{});
        }
    }

    /// Free a list of loaded models
    pub fn freeLoadedModels(self: *LMStudioManager, models: []const LoadedModelInfo) void {
        for (models) |model| {
            self.allocator.free(model.identifier);
            self.allocator.free(model.path);
            if (model.architecture) |arch| {
                self.allocator.free(arch);
            }
        }
        self.allocator.free(models);
    }
};

/// Information about a loaded model
pub const LoadedModelInfo = struct {
    identifier: []const u8,
    path: []const u8,
    // Model capability metadata
    max_context_length: ?usize = null,
    context_length: ?usize = null,
    trained_for_tool_use: ?bool = null,
    architecture: ?[]const u8 = null,
};
