// Profile Commands - Handle /profile slash commands
const std = @import("std");
const mem = std.mem;
const profile_manager = @import("profile_manager");

/// Result of handling a profile command
pub const ProfileCommandResult = enum {
    /// Command handled successfully, should redraw
    success_redraw,
    /// Command handled, open profile UI
    open_ui,
    /// Command failed with error message
    @"error",
    /// Not a profile command
    not_handled,
};

/// Handle a profile command
pub fn handleProfileCommand(
    app: anytype,
    command: []const u8,
    error_message: *?[]const u8,
) !ProfileCommandResult {
    const allocator = app.allocator;

    // Check if it starts with /profile
    if (!mem.startsWith(u8, command, "/profile")) {
        return .not_handled;
    }

    // /profiles - shortcut to open UI
    if (mem.eql(u8, command, "/profiles")) {
        return .open_ui;
    }

    // Parse subcommand
    var parts = mem.tokenizeScalar(u8, command, ' ');
    _ = parts.next(); // Skip "/profile"

    const subcommand = parts.next() orelse {
        // No subcommand - show usage
        error_message.* = try allocator.dupe(u8,
            \\Usage: /profile <command> [args]
            \\Commands:
            \\  list              - List all profiles
            \\  switch <name>     - Switch to a profile
            \\  save <name>       - Save current config as new profile
            \\  delete <name>     - Delete a profile
            \\  /profiles         - Open profile manager UI
        );
        return .@"error";
    };

    // Handle subcommands
    if (mem.eql(u8, subcommand, "list")) {
        return try handleListCommand(allocator, error_message);
    } else if (mem.eql(u8, subcommand, "switch")) {
        const profile_name = parts.rest();
        if (profile_name.len == 0) {
            error_message.* = try allocator.dupe(u8, "Usage: /profile switch <name>");
            return .@"error";
        }
        return try handleSwitchCommand(app, profile_name, error_message);
    } else if (mem.eql(u8, subcommand, "save")) {
        const profile_name = parts.rest();
        if (profile_name.len == 0) {
            error_message.* = try allocator.dupe(u8, "Usage: /profile save <name>");
            return .@"error";
        }
        return try handleSaveCommand(app, profile_name, error_message);
    } else if (mem.eql(u8, subcommand, "delete")) {
        const profile_name = parts.rest();
        if (profile_name.len == 0) {
            error_message.* = try allocator.dupe(u8, "Usage: /profile delete <name>");
            return .@"error";
        }
        return try handleDeleteCommand(allocator, profile_name, error_message);
    } else {
        error_message.* = try std.fmt.allocPrint(allocator, "Unknown subcommand: {s}", .{subcommand});
        return .@"error";
    }
}

/// Handle /profile list
fn handleListCommand(allocator: mem.Allocator, error_message: *?[]const u8) !ProfileCommandResult {
    const profiles = try profile_manager.listProfiles(allocator);
    defer {
        for (profiles) |name| allocator.free(name);
        allocator.free(profiles);
    }

    const active_profile = try profile_manager.getActiveProfileName(allocator);
    defer allocator.free(active_profile);

    if (profiles.len == 0) {
        error_message.* = try allocator.dupe(u8, "No profiles found.");
        return .@"error";
    }

    // Build list message
    var list = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer list.deinit(allocator);

    try list.appendSlice(allocator, "Available profiles:\n");
    for (profiles) |name| {
        if (mem.eql(u8, name, active_profile)) {
            try list.writer(allocator).print("  • {s} (active)\n", .{name});
        } else {
            try list.writer(allocator).print("  • {s}\n", .{name});
        }
    }

    error_message.* = try list.toOwnedSlice(allocator);
    std.debug.print("{s}", .{error_message.*.?});
    return .success_redraw;
}

/// Handle /profile switch <name>
fn handleSwitchCommand(
    app: anytype,
    profile_name: []const u8,
    error_message: *?[]const u8,
) !ProfileCommandResult {
    const allocator = app.allocator;

    // Validate profile name
    if (!profile_manager.validateProfileName(profile_name)) {
        error_message.* = try std.fmt.allocPrint(
            allocator,
            "Invalid profile name: {s}. Use only alphanumeric characters, dashes, and underscores.",
            .{profile_name},
        );
        return .@"error";
    }

    // Check if already active
    const active_profile = try profile_manager.getActiveProfileName(allocator);
    defer allocator.free(active_profile);

    if (mem.eql(u8, profile_name, active_profile)) {
        error_message.* = try std.fmt.allocPrint(allocator, "Already using profile: {s}", .{profile_name});
        return .@"error";
    }

    // Check if profile exists
    const profiles = try profile_manager.listProfiles(allocator);
    defer {
        for (profiles) |name| allocator.free(name);
        allocator.free(profiles);
    }

    var found = false;
    for (profiles) |name| {
        if (mem.eql(u8, name, profile_name)) {
            found = true;
            break;
        }
    }

    if (!found) {
        error_message.* = try std.fmt.allocPrint(allocator, "Profile not found: {s}", .{profile_name});
        return .@"error";
    }

    // Check if streaming is active
    if (app.streaming_active) {
        error_message.* = try allocator.dupe(u8, "Cannot switch profiles while streaming. Please wait for the current response to complete.");
        return .@"error";
    }

    // Check if any modals are open
    if (app.config_editor != null or app.agent_builder != null or app.help_viewer != null) {
        error_message.* = try allocator.dupe(u8, "Cannot switch profiles while a modal is open. Please close it first.");
        return .@"error";
    }

    // Perform switch
    try profile_manager.switchActiveProfile(app, profile_name);

    std.debug.print("✓ Switched to profile: {s}\n", .{profile_name});
    return .success_redraw;
}

/// Handle /profile save <name>
fn handleSaveCommand(
    app: anytype,
    profile_name: []const u8,
    error_message: *?[]const u8,
) !ProfileCommandResult {
    const allocator = app.allocator;

    // Validate profile name
    if (!profile_manager.validateProfileName(profile_name)) {
        error_message.* = try std.fmt.allocPrint(
            allocator,
            "Invalid profile name: {s}. Use only alphanumeric characters, dashes, and underscores.",
            .{profile_name},
        );
        return .@"error";
    }

    // Check if profile already exists
    const profiles = try profile_manager.listProfiles(allocator);
    defer {
        for (profiles) |name| allocator.free(name);
        allocator.free(profiles);
    }

    for (profiles) |name| {
        if (mem.eql(u8, name, profile_name)) {
            error_message.* = try std.fmt.allocPrint(
                allocator,
                "Profile '{s}' already exists. Use '/profile switch {s}' to use it.",
                .{ profile_name, profile_name },
            );
            return .@"error";
        }
    }

    // Save current config as new profile
    try profile_manager.saveProfile(allocator, profile_name, app.config);

    std.debug.print("✓ Saved current config as profile: {s}\n", .{profile_name});
    return .success_redraw;
}

/// Handle /profile delete <name>
fn handleDeleteCommand(
    allocator: mem.Allocator,
    profile_name: []const u8,
    error_message: *?[]const u8,
) !ProfileCommandResult {
    // Check if it's the active profile
    const active_profile = try profile_manager.getActiveProfileName(allocator);
    defer allocator.free(active_profile);

    if (mem.eql(u8, profile_name, active_profile)) {
        error_message.* = try std.fmt.allocPrint(
            allocator,
            "Cannot delete active profile: {s}. Switch to another profile first.",
            .{profile_name},
        );
        return .@"error";
    }

    // Check if profile exists
    const profiles = try profile_manager.listProfiles(allocator);
    defer {
        for (profiles) |name| allocator.free(name);
        allocator.free(profiles);
    }

    var found = false;
    for (profiles) |name| {
        if (mem.eql(u8, name, profile_name)) {
            found = true;
            break;
        }
    }

    if (!found) {
        error_message.* = try std.fmt.allocPrint(allocator, "Profile not found: {s}", .{profile_name});
        return .@"error";
    }

    // Check if it's the last profile
    if (profiles.len <= 1) {
        error_message.* = try allocator.dupe(u8, "Cannot delete the last remaining profile.");
        return .@"error";
    }

    // Delete profile
    try profile_manager.deleteProfile(allocator, profile_name);

    std.debug.print("✓ Deleted profile: {s}\n", .{profile_name});
    return .success_redraw;
}
