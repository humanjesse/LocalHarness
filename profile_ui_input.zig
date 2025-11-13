// Profile UI Input Handler - Handles keyboard input for profile manager
const std = @import("std");
const profile_ui_state = @import("profile_ui_state");
const profile_manager = @import("profile_manager");
const ProfileUIState = profile_ui_state.ProfileUIState;
const ProfileUIMode = profile_ui_state.ProfileUIMode;

/// Result of input handling
pub const InputResult = enum {
    @"continue", // Continue showing UI
    close, // Close the UI
    redraw, // Redraw the UI
    profile_switched, // Profile was switched, close UI
};

/// Handle input for the profile UI
pub fn handleInput(
    state: *ProfileUIState,
    app: anytype,
    input: []const u8,
) !InputResult {
    switch (state.mode) {
        .list => return try handleListInput(state, app, input),
        .create => return try handleCreateInput(state, app, input),
        .delete_confirm => return try handleDeleteConfirmInput(state, app, input),
    }
}

/// Handle input in list mode
fn handleListInput(
    state: *ProfileUIState,
    app: anytype,
    input: []const u8,
) !InputResult {
    // Escape - close UI
    if (std.mem.eql(u8, input, "\x1b")) {
        return .close;
    }

    // Up arrow
    if (std.mem.eql(u8, input, "\x1b[A")) {
        state.selectPrevious();
        return .redraw;
    }

    // Down arrow or Tab - move down
    if (std.mem.eql(u8, input, "\x1b[B") or std.mem.eql(u8, input, "\t")) {
        state.selectNext();
        return .redraw;
    }

    // Shift+Tab - move up
    if (std.mem.eql(u8, input, "\x1b[Z")) {
        state.selectPrevious();
        return .redraw;
    }

    // Enter - switch to selected profile
    if (std.mem.eql(u8, input, "\r") or std.mem.eql(u8, input, "\n")) {
        if (state.getSelectedProfile()) |profile_name| {
            // Check if already active
            if (std.mem.eql(u8, profile_name, state.active_profile_name)) {
                std.debug.print("Already using profile: {s}\n", .{profile_name});
                return .redraw;
            }

            // Check if streaming
            if (app.streaming_active) {
                std.debug.print("Cannot switch profiles while streaming.\n", .{});
                return .redraw;
            }

            // Switch profile
            try profile_manager.switchActiveProfile(app, profile_name);
            std.debug.print("✓ Switched to profile: {s}\n", .{profile_name});
            return .profile_switched;
        }
        return .redraw;
    }

    // C/c - create new profile
    if (std.mem.eql(u8, input, "c") or std.mem.eql(u8, input, "C")) {
        state.enterCreateMode();
        return .redraw;
    }

    // D/d - delete profile
    if (std.mem.eql(u8, input, "d") or std.mem.eql(u8, input, "D")) {
        if (state.getSelectedProfile()) |profile_name| {
            // Check if it's the active profile
            if (std.mem.eql(u8, profile_name, state.active_profile_name)) {
                std.debug.print("Cannot delete active profile. Switch to another profile first.\n", .{});
                return .redraw;
            }

            // Check if it's the last profile
            if (state.profiles.len <= 1) {
                std.debug.print("Cannot delete the last remaining profile.\n", .{});
                return .redraw;
            }

            try state.enterDeleteMode();
            return .redraw;
        }
        return .redraw;
    }

    return .@"continue";
}

/// Handle input in create mode
fn handleCreateInput(
    state: *ProfileUIState,
    app: anytype,
    input: []const u8,
) !InputResult {
    // Escape - cancel
    if (std.mem.eql(u8, input, "\x1b")) {
        state.cancelCreate();
        return .redraw;
    }

    // Enter - create profile
    if (std.mem.eql(u8, input, "\r") or std.mem.eql(u8, input, "\n")) {
        const profile_name = state.create_buffer.items;

        if (profile_name.len == 0) {
            std.debug.print("Profile name cannot be empty.\n", .{});
            return .redraw;
        }

        // Validate name
        if (!profile_manager.validateProfileName(profile_name)) {
            std.debug.print("Invalid profile name. Use only alphanumeric characters, dashes, and underscores.\n", .{});
            return .redraw;
        }

        // Check if already exists
        for (state.profiles) |existing| {
            if (std.mem.eql(u8, existing, profile_name)) {
                std.debug.print("Profile '{s}' already exists.\n", .{profile_name});
                return .redraw;
            }
        }

        // Create profile (save current config)
        try profile_manager.saveProfile(state.allocator, profile_name, app.config);
        std.debug.print("✓ Created profile: {s}\n", .{profile_name});

        // Refresh profile list
        try state.refreshProfiles();

        // Return to list mode
        state.cancelCreate();
        return .redraw;
    }

    // Backspace
    if (std.mem.eql(u8, input, "\x7f") or std.mem.eql(u8, input, "\x08")) {
        if (state.create_buffer.items.len > 0) {
            _ = state.create_buffer.pop();
            return .redraw;
        }
        return .@"continue";
    }

    // Regular character input
    if (input.len == 1) {
        const c = input[0];
        // Only allow printable ASCII characters
        if (c >= 32 and c <= 126) {
            try state.create_buffer.append(state.allocator, c);
            return .redraw;
        }
    }

    return .@"continue";
}

/// Handle input in delete confirmation mode
fn handleDeleteConfirmInput(
    state: *ProfileUIState,
    _: anytype,
    input: []const u8,
) !InputResult {
    // Escape or N/n - cancel
    if (std.mem.eql(u8, input, "\x1b") or std.mem.eql(u8, input, "n") or std.mem.eql(u8, input, "N")) {
        state.cancelDelete();
        return .redraw;
    }

    // Y/y - confirm deletion
    if (std.mem.eql(u8, input, "y") or std.mem.eql(u8, input, "Y")) {
        if (state.profile_to_delete) |profile_name| {
            try profile_manager.deleteProfile(state.allocator, profile_name);
            std.debug.print("✓ Deleted profile: {s}\n", .{profile_name});

            // Refresh profile list
            try state.refreshProfiles();

            // Return to list mode
            state.cancelDelete();
            return .redraw;
        }
        return .redraw;
    }

    return .@"continue";
}
