// Profile UI State - Modal for managing configuration profiles
const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

/// UI mode for the profile manager
pub const ProfileUIMode = enum {
    list, // Viewing/selecting profiles
    create, // Creating a new profile
    delete_confirm, // Confirming deletion
};

pub const ProfileUIState = struct {
    allocator: Allocator,
    mode: ProfileUIMode,

    // Profile list
    profiles: [][]const u8,
    active_profile_name: []const u8,
    selected_index: usize,

    // For create mode
    create_buffer: std.ArrayListUnmanaged(u8),

    // For delete confirmation
    profile_to_delete: ?[]const u8,

    pub fn init(allocator: Allocator) !ProfileUIState {
        const profile_manager = @import("profile_manager");

        // Load profile list
        const profiles = try profile_manager.listProfiles(allocator);
        errdefer {
            for (profiles) |name| allocator.free(name);
            allocator.free(profiles);
        }

        // Get active profile
        const active_profile_name = try profile_manager.getActiveProfileName(allocator);
        errdefer allocator.free(active_profile_name);

        // Find active profile index for initial selection
        var selected_index: usize = 0;
        for (profiles, 0..) |name, i| {
            if (mem.eql(u8, name, active_profile_name)) {
                selected_index = i;
                break;
            }
        }

        return ProfileUIState{
            .allocator = allocator,
            .mode = .list,
            .profiles = profiles,
            .active_profile_name = active_profile_name,
            .selected_index = selected_index,
            .create_buffer = .{},
            .profile_to_delete = null,
        };
    }

    pub fn deinit(self: *ProfileUIState) void {
        for (self.profiles) |name| {
            self.allocator.free(name);
        }
        self.allocator.free(self.profiles);
        self.allocator.free(self.active_profile_name);
        self.create_buffer.deinit(self.allocator);
        if (self.profile_to_delete) |name| {
            self.allocator.free(name);
        }
    }

    /// Refresh profile list (call after creating/deleting profiles)
    pub fn refreshProfiles(self: *ProfileUIState) !void {
        const profile_manager = @import("profile_manager");

        // Free old list
        for (self.profiles) |name| {
            self.allocator.free(name);
        }
        self.allocator.free(self.profiles);
        self.allocator.free(self.active_profile_name);

        // Reload
        self.profiles = try profile_manager.listProfiles(self.allocator);
        self.active_profile_name = try profile_manager.getActiveProfileName(self.allocator);

        // Reset selection if out of bounds
        if (self.selected_index >= self.profiles.len and self.profiles.len > 0) {
            self.selected_index = self.profiles.len - 1;
        }

        // Find active profile index
        for (self.profiles, 0..) |name, i| {
            if (mem.eql(u8, name, self.active_profile_name)) {
                self.selected_index = i;
                break;
            }
        }
    }

    /// Move selection up
    pub fn selectPrevious(self: *ProfileUIState) void {
        if (self.profiles.len == 0) return;
        if (self.selected_index > 0) {
            self.selected_index -= 1;
        } else {
            self.selected_index = self.profiles.len - 1; // Wrap around
        }
    }

    /// Move selection down
    pub fn selectNext(self: *ProfileUIState) void {
        if (self.profiles.len == 0) return;
        if (self.selected_index < self.profiles.len - 1) {
            self.selected_index += 1;
        } else {
            self.selected_index = 0; // Wrap around
        }
    }

    /// Get currently selected profile name
    pub fn getSelectedProfile(self: *const ProfileUIState) ?[]const u8 {
        if (self.selected_index < self.profiles.len) {
            return self.profiles[self.selected_index];
        }
        return null;
    }

    /// Enter create mode
    pub fn enterCreateMode(self: *ProfileUIState) void {
        self.mode = .create;
        self.create_buffer.clearRetainingCapacity();
    }

    /// Cancel create mode
    pub fn cancelCreate(self: *ProfileUIState) void {
        self.mode = .list;
        self.create_buffer.clearRetainingCapacity();
    }

    /// Enter delete confirmation mode
    pub fn enterDeleteMode(self: *ProfileUIState) !void {
        if (self.getSelectedProfile()) |profile| {
            self.mode = .delete_confirm;
            self.profile_to_delete = try self.allocator.dupe(u8, profile);
        }
    }

    /// Cancel delete mode
    pub fn cancelDelete(self: *ProfileUIState) void {
        self.mode = .list;
        if (self.profile_to_delete) |name| {
            self.allocator.free(name);
            self.profile_to_delete = null;
        }
    }
};
