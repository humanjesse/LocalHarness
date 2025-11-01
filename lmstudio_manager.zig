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
        // Note: Actual structure may vary based on lms version
        // This is a placeholder for the expected format
        const parsed = std.json.parseFromSlice(
            []LoadedModelInfo,
            self.allocator,
            result.stdout,
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            std.debug.print("⚠ Failed to parse lms ps output: {s}\n", .{@errorName(err)});
            self.allocator.free(result.stdout);
            return &[_]LoadedModelInfo{}; // Return empty array on parse error
        };
        defer parsed.deinit();
        self.allocator.free(result.stdout);

        // Make owned copy of the data
        const owned = try self.allocator.alloc(LoadedModelInfo, parsed.value.len);
        for (parsed.value, 0..) |model, i| {
            owned[i] = .{
                .identifier = try self.allocator.dupe(u8, model.identifier),
                .path = try self.allocator.dupe(u8, model.path),
            };
        }
        return owned;
    }

    /// Load a specific model with options
    pub fn loadModel(
        self: *LMStudioManager,
        model_path: []const u8,
        gpu_offload: []const u8,
    ) !void {
        std.debug.print("   Running: {s} load {s} --gpu={s} -y\n", .{ self.lms_path, model_path, gpu_offload });

        var argv = try std.ArrayList([]const u8).initCapacity(self.allocator, 5);
        defer argv.deinit(self.allocator);

        try argv.appendSlice(self.allocator, &[_][]const u8{
            self.lms_path,
            "load",
            model_path,
        });

        // Add GPU offload option
        const gpu_arg = try std.fmt.allocPrint(self.allocator, "--gpu={s}", .{gpu_offload});
        defer self.allocator.free(gpu_arg);
        try argv.append(self.allocator, gpu_arg);

        // Add -y to skip confirmation prompts
        try argv.append(self.allocator, "-y");

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv.items,
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| {
                if (code != 0) {
                    std.debug.print("   stderr: {s}\n", .{result.stderr});
                    return error.ModelLoadFailed;
                }
            },
            else => return error.ModelLoadFailed,
        }

        if (result.stdout.len > 0) {
            std.debug.print("   {s}\n", .{result.stdout});
        }
    }

    /// Free a list of loaded models
    pub fn freeLoadedModels(self: *LMStudioManager, models: []const LoadedModelInfo) void {
        for (models) |model| {
            self.allocator.free(model.identifier);
            self.allocator.free(model.path);
        }
        self.allocator.free(models);
    }
};

/// Information about a loaded model
pub const LoadedModelInfo = struct {
    identifier: []const u8,
    path: []const u8,
};
