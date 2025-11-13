// Profile UI Renderer - Draws the profile manager UI
const std = @import("std");
const profile_ui_state = @import("profile_ui_state");
const ProfileUIState = profile_ui_state.ProfileUIState;
const ProfileUIMode = profile_ui_state.ProfileUIMode;
const text_utils = @import("text_utils");

/// Render the profile manager screen
pub fn render(
    state: *ProfileUIState,
    writer: anytype,
    terminal_width: u16,
    terminal_height: u16,
) !void {
    // Clear screen
    try writer.writeAll("\x1b[2J\x1b[H");

    const box_width = @min(terminal_width - 4, 60);
    const box_start_x = (terminal_width - box_width) / 2;
    var current_y: usize = 2;

    switch (state.mode) {
        .list => try renderListMode(state, writer, box_width, box_start_x, &current_y, terminal_width, terminal_height),
        .create => try renderCreateMode(state, writer, box_width, box_start_x, &current_y, terminal_width),
        .delete_confirm => try renderDeleteConfirmMode(state, writer, box_width, box_start_x, &current_y, terminal_width),
    }
}

/// Render profile list mode
fn renderListMode(
    state: *ProfileUIState,
    writer: anytype,
    box_width: usize,
    box_start_x: usize,
    current_y: *usize,
    terminal_width: u16,
    terminal_height: u16,
) !void {
    // Title
    try drawCentered(writer, "Profile Manager", terminal_width, current_y.*);
    current_y.* += 1;

    try drawCentered(writer, "↑/↓/Tab to navigate, Enter to switch, C to create, D to delete, Esc to close", terminal_width, current_y.*);
    current_y.* += 2;

    // Current profile indicator
    const current_text = try std.fmt.allocPrint(
        state.allocator,
        "Active profile: \x1b[1;32m{s}\x1b[0m",
        .{state.active_profile_name},
    );
    defer state.allocator.free(current_text);
    try drawCentered(writer, current_text, terminal_width, current_y.*);
    current_y.* += 2;

    // Profile list box
    try writer.print("\x1b[{d};{d}H", .{ current_y.*, box_start_x });
    try writer.print("\x1b[1;36mAvailable Profiles\x1b[0m", .{});
    current_y.* += 1;

    // Box top border
    try writer.print("\x1b[{d};{d}H┌", .{ current_y.*, box_start_x });
    for (0..box_width - 2) |_| try writer.writeAll("─");
    try writer.writeAll("┐");
    current_y.* += 1;

    // Profile list
    if (state.profiles.len == 0) {
        try writer.print("\x1b[{d};{d}H│", .{ current_y.*, box_start_x });
        try drawPadded(writer, "  No profiles found", box_width - 2);
        try writer.writeAll("│");
        current_y.* += 1;
    } else {
        const max_visible = @min(state.profiles.len, terminal_height - current_y.* - 8);
        const start_index = if (state.selected_index >= max_visible)
            state.selected_index - max_visible + 1
        else
            0;

        for (state.profiles[start_index..@min(start_index + max_visible, state.profiles.len)], start_index..) |profile, i| {
            const is_selected = (i == state.selected_index);
            const is_active = std.mem.eql(u8, profile, state.active_profile_name);

            try writer.print("\x1b[{d};{d}H│", .{ current_y.*, box_start_x });

            if (is_selected) {
                try writer.writeAll("\x1b[1;33m"); // Bold yellow for selection
            }

            const prefix = if (is_active) "● " else "  ";
            const profile_text = try std.fmt.allocPrint(
                state.allocator,
                "{s}{s}",
                .{ prefix, profile },
            );
            defer state.allocator.free(profile_text);

            try drawPadded(writer, profile_text, box_width - 2);

            if (is_selected) {
                try writer.writeAll("\x1b[0m"); // Reset formatting
            }

            try writer.writeAll("│");
            current_y.* += 1;
        }
    }

    // Box bottom border
    try writer.print("\x1b[{d};{d}H└", .{ current_y.*, box_start_x });
    for (0..box_width - 2) |_| try writer.writeAll("─");
    try writer.writeAll("┘");
    current_y.* += 2;

    // Actions
    current_y.* = terminal_height - 3;
    try drawCentered(writer, "[Tab/↑↓] Navigate  [Enter] Switch  [C] Create  [D] Delete  [Esc] Close", terminal_width, current_y.*);
}

/// Render create profile mode
fn renderCreateMode(
    state: *ProfileUIState,
    writer: anytype,
    box_width: usize,
    box_start_x: usize,
    current_y: *usize,
    terminal_width: u16,
) !void {
    // Title
    try drawCentered(writer, "Create New Profile", terminal_width, current_y.*);
    current_y.* += 2;

    try drawCentered(writer, "Enter a name for the new profile (alphanumeric, dashes, underscores only)", terminal_width, current_y.*);
    current_y.* += 2;

    // Input box
    try writer.print("\x1b[{d};{d}H┌", .{ current_y.*, box_start_x });
    for (0..box_width - 2) |_| try writer.writeAll("─");
    try writer.writeAll("┐");
    current_y.* += 1;

    try writer.print("\x1b[{d};{d}H│ ", .{ current_y.*, box_start_x });
    try writer.writeAll(state.create_buffer.items);

    // Pad to fill box width
    const used_width = state.create_buffer.items.len + 1; // +1 for space after │
    const remaining = if (box_width - 2 > used_width) box_width - 2 - used_width else 0;
    for (0..remaining) |_| try writer.writeAll(" ");
    try writer.writeAll("│");
    current_y.* += 1;

    try writer.print("\x1b[{d};{d}H└", .{ current_y.*, box_start_x });
    for (0..box_width - 2) |_| try writer.writeAll("─");
    try writer.writeAll("┘");
    current_y.* += 2;

    // Instructions
    try drawCentered(writer, "[Enter] Create  [Esc] Cancel", terminal_width, current_y.*);
}

/// Render delete confirmation mode
fn renderDeleteConfirmMode(
    state: *ProfileUIState,
    writer: anytype,
    _: usize, // box_width
    _: usize, // box_start_x
    current_y: *usize,
    terminal_width: u16,
) !void {
    // Title
    try drawCentered(writer, "Confirm Deletion", terminal_width, current_y.*);
    current_y.* += 2;

    const confirm_text = if (state.profile_to_delete) |profile|
        try std.fmt.allocPrint(state.allocator, "Are you sure you want to delete profile '\x1b[1m{s}\x1b[0m'?", .{profile})
    else
        try state.allocator.dupe(u8, "Delete profile?");
    defer state.allocator.free(confirm_text);

    try drawCentered(writer, confirm_text, terminal_width, current_y.*);
    current_y.* += 1;

    try drawCentered(writer, "\x1b[31mThis action cannot be undone.\x1b[0m", terminal_width, current_y.*);
    current_y.* += 3;

    // Actions
    try drawCentered(writer, "[Y] Yes, Delete  [N/Esc] Cancel", terminal_width, current_y.*);
}

/// Helper: Draw centered text
fn drawCentered(writer: anytype, text: []const u8, terminal_width: u16, row: usize) !void {
    // Strip ANSI codes for length calculation
    const visible_len = text_utils.countVisibleChars(text);
    const start_x = if (terminal_width > visible_len)
        (terminal_width - @as(u16, @intCast(visible_len))) / 2
    else
        0;

    try writer.print("\x1b[{d};{d}H{s}", .{ row, start_x, text });
}

/// Helper: Draw text with padding to fill width
fn drawPadded(writer: anytype, text: []const u8, width: usize) !void {
    try writer.writeAll(text);
    const visible_len = text_utils.countVisibleChars(text);
    if (width > visible_len) {
        for (0..(width - visible_len)) |_| {
            try writer.writeAll(" ");
        }
    }
}
