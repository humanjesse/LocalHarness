// GraphRAG integration module - handles the secondary loop for indexing read_file results
// This module is responsible for:
// - Detecting read_file tool results
// - Managing the GraphRAG choice UI (full indexing, custom lines, metadata only)
// - Processing the indexing queue
// - Updating messages with indexed content

const std = @import("std");
const mem = std.mem;
const json = std.json;
const markdown = @import("markdown.zig");
const types = @import("types.zig");
const state_module = @import("state.zig");
const ui = @import("ui.zig");
const message_renderer = @import("message_renderer.zig");
const graphrag_query = @import("graphrag/query.zig");
const IndexingQueue = @import("graphrag/indexing_queue.zig").IndexingQueue;

// Forward declare App type (will be imported from app.zig)
const App = @import("app.zig").App;
const Message = types.Message;

/// Helper to detect if content is from a read_file tool result
pub fn isReadFileResult(content: []const u8) bool {
    return mem.indexOf(u8, content, "File: ") != null and
           mem.indexOf(u8, content, "Total lines:") != null;
}

/// Helper to extract file path from read_file result
pub fn extractFilePathFromResult(content: []const u8) ?[]const u8 {
    const file_prefix = "File: ";
    const start_idx = mem.indexOf(u8, content, file_prefix) orelse return null;
    const after_prefix = content[start_idx + file_prefix.len ..];

    const end_idx = mem.indexOf(u8, after_prefix, "\n") orelse return null;
    return after_prefix[0..end_idx];
}

/// Progress callback context for GraphRAG indexing
pub const IndexingProgressContext = struct {
    app: *App,
    current_message_idx: ?usize = null, // Track which message to update
    accumulated_content: std.ArrayListUnmanaged(u8) = .{},
};

/// Progress callback for GraphRAG indexing - updates UI with streaming content
pub fn indexingProgressCallback(user_data: *anyopaque, update_type: @import("graphrag/llm_indexer.zig").ProgressUpdateType, message: []const u8) void {
    const ctx = @as(*IndexingProgressContext, @ptrCast(@alignCast(user_data)));

    // Accumulate the message content
    ctx.accumulated_content.appendSlice(ctx.app.allocator, message) catch return;

    // Find or create the progress message
    if (ctx.current_message_idx == null) {
        // Create new system message for this indexing progress
        const content = ctx.app.allocator.dupe(u8, ctx.accumulated_content.items) catch return;
        const processed = markdown.processMarkdown(ctx.app.allocator, content) catch return;

        ctx.app.messages.append(ctx.app.allocator, .{
            .role = .display_only_data,
            .content = content,
            .processed_content = processed,
            .thinking_expanded = false,
            .timestamp = std.time.milliTimestamp(),
        }) catch return;

        ctx.current_message_idx = ctx.app.messages.items.len - 1;
    } else {
        // Update existing message
        const idx = ctx.current_message_idx.?;
        var msg = &ctx.app.messages.items[idx];

        // Free old content
        ctx.app.allocator.free(msg.content);
        for (msg.processed_content.items) |*item| {
            item.deinit(ctx.app.allocator);
        }
        msg.processed_content.deinit(ctx.app.allocator);

        // Update with new content
        msg.content = ctx.app.allocator.dupe(u8, ctx.accumulated_content.items) catch return;
        msg.processed_content = markdown.processMarkdown(ctx.app.allocator, msg.content) catch return;
    }

    // Redraw screen to show progress
    if (!ctx.app.user_scrolled_away) {
        ctx.app.maintainBottomAnchor() catch return;
    }
    _ = message_renderer.redrawScreen(ctx.app) catch return;
    if (!ctx.app.user_scrolled_away) {
        ctx.app.updateCursorToBottom();
    }

    _ = update_type; // Unused for now, but available for future formatting
}

/// Update message history with custom line range
/// Finds the tool result message for the file and replaces content with selected lines
pub fn updateMessageWithLineRange(app: *App, file_path: []const u8, line_range: types.LineRange) !void {
    // Find the tool result message for this file
    var target_msg: ?*Message = null;
    for (app.messages.items) |*msg| {
        if (msg.role == .tool and isReadFileResult(msg.content)) {
            if (extractFilePathFromResult(msg.content)) |path| {
                if (mem.eql(u8, path, file_path)) {
                    target_msg = msg;
                    break;
                }
            }
        }
    }

    if (target_msg == null) return error.MessageNotFound;
    var msg = target_msg.?;

    // Extract the original file content (between "Content:\n" and "\n\nNotes:")
    const content_start = mem.indexOf(u8, msg.content, "Content:\n") orelse return error.InvalidFormat;
    const content_end = mem.indexOf(u8, msg.content, "\n\nNotes:") orelse return error.InvalidFormat;
    const file_content = msg.content[content_start + "Content:\n".len .. content_end];

    // Split into lines
    var lines = std.ArrayListUnmanaged([]const u8){};
    defer lines.deinit(app.allocator);

    var line_iter = mem.splitScalar(u8, file_content, '\n');
    while (line_iter.next()) |line| {
        try lines.append(app.allocator, line);
    }

    // Extract requested line range (1-indexed)
    const start_idx = if (line_range.start > 0) line_range.start - 1 else 0;
    const end_idx = @min(line_range.end, lines.items.len);

    if (start_idx >= lines.items.len) return error.InvalidRange;

    // Build new content with just the requested lines
    var new_content = std.ArrayListUnmanaged(u8){};
    defer new_content.deinit(app.allocator);
    const writer = new_content.writer(app.allocator);

    try writer.writeAll("```\n");
    try writer.print("File: {s}\n", .{file_path});
    try writer.print("Lines {d}-{d} (of {d} total)\n", .{ line_range.start, end_idx, lines.items.len });
    try writer.writeAll("Content:\n");

    for (lines.items[start_idx..end_idx], 0..) |line, i| {
        const line_num = start_idx + i + 1;

        // Parse the line to extract content after the line number
        const line_content = if (mem.indexOf(u8, line, ": ")) |colon_pos|
            line[colon_pos + 2 ..]
        else
            line;

        try writer.print("{d}: {s}\n", .{ line_num, line_content });
    }

    try writer.writeAll("\nNotes: Custom line range selected by user.\n");
    try writer.writeAll("```");

    // Replace message content
    app.allocator.free(msg.content);
    for (msg.processed_content.items) |*item| {
        item.deinit(app.allocator);
    }
    msg.processed_content.deinit(app.allocator);

    msg.content = try new_content.toOwnedSlice(app.allocator);
    msg.processed_content = try markdown.processMarkdown(app.allocator, msg.content);
}

/// Update message history with metadata only (tool call + filename)
/// Replaces full file content with minimal summary
pub fn updateMessageWithMetadata(app: *App, file_path: []const u8) !void {
    // Find the tool result message for this file
    var target_msg: ?*Message = null;
    for (app.messages.items) |*msg| {
        if (msg.role == .tool and isReadFileResult(msg.content)) {
            if (extractFilePathFromResult(msg.content)) |path| {
                if (mem.eql(u8, path, file_path)) {
                    target_msg = msg;
                    break;
                }
            }
        }
    }

    if (target_msg == null) return error.MessageNotFound;
    var msg = target_msg.?;

    // Create minimal metadata content
    const new_content = try std.fmt.allocPrint(
        app.allocator,
        "```\nTool: read_file\nFile: {s}\nStatus: Read successfully (content not saved)\n```",
        .{file_path},
    );

    // Replace message content
    app.allocator.free(msg.content);
    for (msg.processed_content.items) |*item| {
        item.deinit(app.allocator);
    }
    msg.processed_content.deinit(app.allocator);

    msg.content = new_content;
    msg.processed_content = try markdown.processMarkdown(app.allocator, msg.content);
}

/// Process pending indexing queue (post-response batch indexing)
/// Shows progress messages and allows user to skip with any keypress
pub fn processPendingIndexing(app: *App) !void {
    const total_files = app.state.pending_index_files.items.len;
    if (total_files == 0) return;

    // Show initial status
    const start_msg = try std.fmt.allocPrint(
        app.allocator,
        "📊 Indexing {d} pending file{s}... (press any key to skip)",
        .{ total_files, if (total_files == 1) "" else "s" },
    );
    defer app.allocator.free(start_msg);

    const start_processed = try markdown.processMarkdown(app.allocator, start_msg);
    try app.messages.append(app.allocator, .{
        .role = .display_only_data,
        .content = try app.allocator.dupe(u8, start_msg),
        .processed_content = start_processed,
        .thinking_expanded = false,
        .timestamp = std.time.milliTimestamp(),
    });

    // Redraw to show message
    if (!app.user_scrolled_away) {
        try app.maintainBottomAnchor();
    }
    _ = try message_renderer.redrawScreen(app);
    if (!app.user_scrolled_away) {
        app.updateCursorToBottom();
    }

    const indexed_count: usize = 0; // TODO: Will be used when LLM indexer is implemented
    var skipped_count: usize = 0;

    // Process each file in queue
    while (app.state.popPendingIndexFile()) |pending| {
        defer {
            app.allocator.free(pending.path);
            app.allocator.free(pending.content);
        }

        // Check for user input (non-blocking) - any key skips indexing
        var read_buffer: [128]u8 = undefined;
        const bytes_read = ui.c.read(ui.c.STDIN_FILENO, &read_buffer, read_buffer.len);
        if (bytes_read > 0) {
            // User pressed a key - stop indexing
            const remaining = app.state.pending_index_files.items.len;

            // Clear the queue
            for (app.state.pending_index_files.items) |remaining_file| {
                app.allocator.free(remaining_file.path);
                app.allocator.free(remaining_file.content);
            }
            app.state.pending_index_files.clearRetainingCapacity();

            const skip_msg = try std.fmt.allocPrint(
                app.allocator,
                "⏭️  Skipped indexing {d} remaining file{s}",
                .{ remaining + 1, if (remaining + 1 == 1) "" else "s" },
            );
            const skip_processed = try markdown.processMarkdown(app.allocator, skip_msg);
            try app.messages.append(app.allocator, .{
                .role = .display_only_data,
                .content = skip_msg,
                .processed_content = skip_processed,
                .thinking_expanded = false,
                .timestamp = std.time.milliTimestamp(),
            });

            // Redraw and return
            if (!app.user_scrolled_away) {
                try app.maintainBottomAnchor();
            }
            _ = try message_renderer.redrawScreen(app);
            if (!app.user_scrolled_away) {
                app.updateCursorToBottom();
            }

            return;
        }

        // Show progress for current file
        const progress_msg = try std.fmt.allocPrint(
            app.allocator,
            "  Indexing {s}...",
            .{pending.path},
        );
        defer app.allocator.free(progress_msg);

        const progress_processed = try markdown.processMarkdown(app.allocator, progress_msg);
        try app.messages.append(app.allocator, .{
            .role = .display_only_data,
            .content = try app.allocator.dupe(u8, progress_msg),
            .processed_content = progress_processed,
            .thinking_expanded = false,
            .timestamp = std.time.milliTimestamp(),
        });

        // Redraw to show progress
        if (!app.user_scrolled_away) {
            try app.maintainBottomAnchor();
        }
        _ = try message_renderer.redrawScreen(app);
        if (!app.user_scrolled_away) {
            app.updateCursorToBottom();
        }

        // TODO: Re-implement with LLM-based indexing (commented out for now)
        if (app.vector_store != null and app.embedder != null) {
            // Temporary: skip indexing until LLM-based indexer is implemented
            skipped_count += 1;
        } else {
            skipped_count += 1;
        }
    }

    // Show completion summary
    const summary_msg = if (skipped_count > 0)
        try std.fmt.allocPrint(
            app.allocator,
            "✅ Indexing complete ({d} indexed, {d} skipped)",
            .{ indexed_count, skipped_count },
        )
    else
        try std.fmt.allocPrint(
            app.allocator,
            "✅ Indexing complete ({d} file{s} indexed)",
            .{ indexed_count, if (indexed_count == 1) "" else "s" },
        );

    const summary_processed = try markdown.processMarkdown(app.allocator, summary_msg);
    try app.messages.append(app.allocator, .{
        .role = .display_only_data,
        .content = summary_msg,
        .processed_content = summary_processed,
        .thinking_expanded = false,
        .timestamp = std.time.milliTimestamp(),
    });

    // Final redraw
    if (!app.user_scrolled_away) {
        try app.maintainBottomAnchor();
    }
    _ = try message_renderer.redrawScreen(app);
    if (!app.user_scrolled_away) {
        app.updateCursorToBottom();
    }
}

/// SECONDARY LOOP: Process all queued files for GraphRAG indexing
///
/// This is the Graph RAG "secondary loop" that runs AFTER the main conversation
/// turn completes. It processes files queued by read_file during tool execution.
///
/// NEW: User can choose how to handle each file:
/// 1. Full GraphRAG indexing (default)
/// 2. Save only custom line ranges
/// 3. Save only metadata (tool call + filename)
///
/// This function works as a state machine with the main loop:
/// - Prompts user for each file (one at a time)
/// - Returns to main loop to wait for response
/// - Processes response and continues to next file
pub fn processQueuedFiles(app: *App) !void {
    if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
        std.debug.print("[GRAPHRAG] processQueuedFiles called\n", .{});
    }

    const queue = app.indexing_queue orelse {
        if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
            std.debug.print("[GRAPHRAG] No indexing queue available\n", .{});
        }
        return;
    };

    if (queue.isEmpty()) {
        if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
            std.debug.print("[GRAPHRAG] Queue is empty\n", .{});
        }
        return; // Nothing to process
    }

    const llm_indexer = @import("graphrag/llm_indexer.zig");

    // Check if we're waiting for a response for the current file
    if (app.graphrag_choice_pending) {
        // Still waiting - do nothing, main loop will handle input
        return;
    }

    // Check if we just got a response for the previous file
    if (app.graphrag_choice_response) |choice| {
        const file_path = app.current_indexing_file orelse return error.NoCurrentFile;

        // Process the choice
        switch (choice) {
            .full_indexing => {
                // Pop the task and index it
                const task_opt = try queue.pop();
                if (task_opt) |task_val| {
                    var task = task_val;
                    defer task.deinit();

                    const progress_msg = try std.fmt.allocPrint(
                        app.allocator,
                        "  📊 Indexing {s}...\n",
                        .{task.file_path},
                    );
                    const progress_processed = try markdown.processMarkdown(app.allocator, progress_msg);
                    try app.messages.append(app.allocator, .{
                        .role = .display_only_data,
                        .content = progress_msg,
                        .processed_content = progress_processed,
                        .thinking_expanded = false,
                        .timestamp = std.time.milliTimestamp(),
                    });

                    // Redraw to show progress
                    if (!app.user_scrolled_away) {
                        try app.maintainBottomAnchor();
                    }
                    _ = try message_renderer.redrawScreen(app);
                    if (!app.user_scrolled_away) {
                        app.updateCursorToBottom();
                    }

                    // Set up progress context for streaming updates
                    var progress_ctx = IndexingProgressContext{
                        .app = app,
                    };
                    defer progress_ctx.accumulated_content.deinit(app.allocator);

                    // Use main model for indexing with progress callback
                    llm_indexer.indexFile(
                        app.allocator,
                        &app.ollama_client,
                        app.config.model,
                        &app.app_context,
                        task.file_path,
                        task.content,
                        indexingProgressCallback,
                        @ptrCast(&progress_ctx),
                    ) catch |err| {
                        const error_msg = try std.fmt.allocPrint(
                            app.allocator,
                            "    ⚠️  Indexing failed: {}",
                            .{err},
                        );
                        const error_processed = try markdown.processMarkdown(app.allocator, error_msg);
                        try app.messages.append(app.allocator, .{
                            .role = .display_only_data,
                            .content = error_msg,
                            .processed_content = error_processed,
                            .thinking_expanded = false,
                            .timestamp = std.time.milliTimestamp(),
                        });
                    };

                    // Mark file as indexed in state
                    app.state.markFileAsIndexed(task.file_path) catch |err| {
                        if (std.posix.getenv("DEBUG_GRAPHRAG")) |_| {
                            std.debug.print("[GRAPHRAG] Failed to mark file as indexed: {}\n", .{err});
                        }
                    };
                }
            },

            .custom_lines => {
                // Wait for line range input if not yet provided
                if (app.line_range_response == null) {
                    // Line input is being handled by main loop
                    return;
                }

                // We have the line range, update message history
                const line_range = app.line_range_response.?;
                updateMessageWithLineRange(app, file_path, line_range) catch |err| {
                    const error_msg = try std.fmt.allocPrint(
                        app.allocator,
                        "  ⚠️  Failed to save custom lines: {}",
                        .{err},
                    );
                    const error_processed = try markdown.processMarkdown(app.allocator, error_msg);
                    try app.messages.append(app.allocator, .{
                        .role = .display_only_data,
                        .content = error_msg,
                        .processed_content = error_processed,
                        .thinking_expanded = false,
                        .timestamp = std.time.milliTimestamp(),
                    });
                };

                // Pop and discard the task (already processed)
                const task_opt = try queue.pop();
                if (task_opt) |task_val| {
                    var task = task_val;
                    task.deinit();
                }

                const success_msg = try std.fmt.allocPrint(
                    app.allocator,
                    "  ✓ Saved lines {d}-{d} from {s}\n",
                    .{ line_range.start, line_range.end, file_path },
                );
                const success_processed = try markdown.processMarkdown(app.allocator, success_msg);
                try app.messages.append(app.allocator, .{
                    .role = .display_only_data,
                    .content = success_msg,
                    .processed_content = success_processed,
                    .thinking_expanded = false,
                    .timestamp = std.time.milliTimestamp(),
                });
            },

            .metadata_only => {
                // Update message history with minimal metadata
                updateMessageWithMetadata(app, file_path) catch |err| {
                    const error_msg = try std.fmt.allocPrint(
                        app.allocator,
                        "  ⚠️  Failed to save metadata: {}",
                        .{err},
                    );
                    const error_processed = try markdown.processMarkdown(app.allocator, error_msg);
                    try app.messages.append(app.allocator, .{
                        .role = .display_only_data,
                        .content = error_msg,
                        .processed_content = error_processed,
                        .thinking_expanded = false,
                        .timestamp = std.time.milliTimestamp(),
                    });
                };

                // Pop and discard the task (already processed)
                const task_opt = try queue.pop();
                if (task_opt) |task_val| {
                    var task = task_val;
                    task.deinit();
                }

                const success_msg = try std.fmt.allocPrint(
                    app.allocator,
                    "  ✓ Saved metadata only for {s}\n",
                    .{file_path},
                );
                const success_processed = try markdown.processMarkdown(app.allocator, success_msg);
                try app.messages.append(app.allocator, .{
                    .role = .display_only_data,
                    .content = success_msg,
                    .processed_content = success_processed,
                    .thinking_expanded = false,
                    .timestamp = std.time.milliTimestamp(),
                });
            },
        }

        // Clear response and file state
        app.graphrag_choice_response = null;
        app.line_range_response = null;
        if (app.current_indexing_file) |file| {
            app.allocator.free(file);
            app.current_indexing_file = null;
        }

        // Redraw after processing
        if (!app.user_scrolled_away) {
            try app.maintainBottomAnchor();
        }
        _ = try message_renderer.redrawScreen(app);
        if (!app.user_scrolled_away) {
            app.updateCursorToBottom();
        }
    }

    // If queue is now empty, show completion message
    if (queue.isEmpty()) {
        const complete_msg = try app.allocator.dupe(u8, "✓ All files processed\n");
        const complete_processed = try markdown.processMarkdown(app.allocator, complete_msg);
        try app.messages.append(app.allocator, .{
            .role = .display_only_data,
            .content = complete_msg,
            .processed_content = complete_processed,
            .thinking_expanded = false,
            .timestamp = std.time.milliTimestamp(),
        });

        // Final redraw
        if (!app.user_scrolled_away) {
            try app.maintainBottomAnchor();
        }
        _ = try message_renderer.redrawScreen(app);
        if (!app.user_scrolled_away) {
            app.updateCursorToBottom();
        }
        return;
    }

    // Peek at the next file to prompt user
    const next_task = queue.peek() orelse return;

    // Count how many lines are in the file for display
    var line_count: usize = 1;
    for (next_task.content) |c| {
        if (c == '\n') line_count += 1;
    }

    // Show prompt for this file
    const prompt_msg = try std.fmt.allocPrint(
        app.allocator,
        "\n📁 File: {s} ({d} lines)\nHow should this be handled?\n",
        .{ next_task.file_path, line_count },
    );
    const prompt_processed = try markdown.processMarkdown(app.allocator, prompt_msg);
    try app.messages.append(app.allocator, .{
        .role = .display_only_data,
        .content = prompt_msg,
        .processed_content = prompt_processed,
        .thinking_expanded = false,
        .timestamp = std.time.milliTimestamp(),
    });

    // Store current file path and set pending flag
    app.current_indexing_file = try app.allocator.dupe(u8, next_task.file_path);
    app.graphrag_choice_pending = true;

    // Redraw to show prompt
    if (!app.user_scrolled_away) {
        try app.maintainBottomAnchor();
    }
    _ = try message_renderer.redrawScreen(app);
    if (!app.user_scrolled_away) {
        app.updateCursorToBottom();
    }
}
