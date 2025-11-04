// Hot context injection - generate current session context for LLM
const std = @import("std");
const mem = std.mem;
const tracking = @import("tracking");

const ContextTracker = tracking.ContextTracker;

/// Find file paths mentioned in recent messages
/// Returns a set of file paths for cache-friendly filtering
fn findFilesInRecentMessages(
    allocator: mem.Allocator,
    recent_messages: anytype, // Expects []Message slice
) !std.StringHashMapUnmanaged(void) {
    var mentioned_files = std.StringHashMapUnmanaged(void){};

    // Process recent messages for file mentions
    if (recent_messages.len > 0) {
        for (recent_messages) |msg| {
            // Simple heuristic: look for common file patterns
            // Matches: *.zig, *.md, *.txt, paths with /
            var iter = std.mem.tokenizeAny(u8, msg.content, " \n\t\"'`");
            while (iter.next()) |token| {
                // Check if looks like a file path
                const has_extension = std.mem.indexOf(u8, token, ".zig") != null or
                                     std.mem.indexOf(u8, token, ".md") != null or
                                     std.mem.indexOf(u8, token, ".txt") != null or
                                     std.mem.indexOf(u8, token, ".json") != null;
                const has_slash = std.mem.indexOf(u8, token, "/") != null;

                if (has_extension or has_slash) {
                    // Normalize: remove trailing punctuation
                    var clean_token = token;
                    while (clean_token.len > 0 and
                           (clean_token[clean_token.len - 1] == ',' or
                            clean_token[clean_token.len - 1] == '.' or
                            clean_token[clean_token.len - 1] == ':' or
                            clean_token[clean_token.len - 1] == ')')) {
                        clean_token = clean_token[0..clean_token.len - 1];
                    }

                    if (clean_token.len > 0) {
                        const owned = try allocator.dupe(u8, clean_token);
                        try mentioned_files.put(allocator, owned, {});
                    }
                }
            }
        }
    }

    return mentioned_files;
}

/// Generate hot context summary to inject before messages
/// This tells the LLM about recent changes, active todos, file modifications, etc.
pub fn generateHotContext(
    allocator: mem.Allocator,
    tracker: *ContextTracker,
    state: anytype, // AppState
    recent_messages: anytype, // For relevance filtering (can be ?[]Message or []Message)
) ![]const u8 {
    var context = std.ArrayListUnmanaged(u8){};
    errdefer context.deinit(allocator);
    const writer = context.writer(allocator);
    
    var has_content = false;
    
    // Start with header
    try writer.writeAll("═══ CURRENT CONTEXT ═══\n");
    
    // 1. Active todo
    if (tracker.todo_context.active_todo_id) |todo_id| {
        for (state.todos.items) |todo| {
            if (mem.eql(u8, todo.id, todo_id)) {
                try writer.print("🎯 Active Task: {s}\n", .{todo.content});
                has_content = true;
                
                // Show associated files
                if (tracker.todo_context.files_touched_for_todo.count() > 0) {
                    try writer.writeAll("   Files modified: ");
                    var iter = tracker.todo_context.files_touched_for_todo.keyIterator();
                    var first = true;
                    while (iter.next()) |path| {
                        if (!first) try writer.writeAll(", ");
                        try writer.print("{s}", .{path.*});
                        first = false;
                    }
                    try writer.writeAll("\n");
                }
                break;
            }
        }
    }
    
    // 2. Active context files (cache-optimized: only show conversation-relevant files)
    // Find files mentioned in recent messages for relevance filtering
    var mentioned_files = try findFilesInRecentMessages(allocator, recent_messages);
    defer {
        // Free all keys first, then deinit the map
        var iter = mentioned_files.keyIterator();
        while (iter.next()) |key| {
            allocator.free(key.*);
        }
        mentioned_files.deinit(allocator);
    }
    errdefer {
        var iter = mentioned_files.keyIterator();
        while (iter.next()) |key| {
            allocator.free(key.*);
        }
    }

    // Collect relevant files (mentioned in conversation OR in active todo)
    var relevant_files = std.ArrayListUnmanaged(*tracking.FileChangeTracker){};
    defer relevant_files.deinit(allocator);

    var file_iter = tracker.read_files.valueIterator();
    while (file_iter.next()) |file_tracker| {
        const is_mentioned = mentioned_files.contains(file_tracker.path);
        const is_in_todo = tracker.todo_context.files_touched_for_todo.contains(file_tracker.path);

        if (is_mentioned or is_in_todo) {
            try relevant_files.append(allocator, file_tracker);
        }
    }

    // Only show section if we have relevant files
    if (relevant_files.items.len > 0) {
        if (has_content) try writer.writeAll("\n");
        try writer.writeAll("📖 Active Context Files:\n");

        // Sort alphabetically for stable, cache-friendly ordering
        const sortContext = struct {
            pub fn lessThan(_: void, a: *tracking.FileChangeTracker, b: *tracking.FileChangeTracker) bool {
                return std.mem.order(u8, a.path, b.path) == .lt;
            }
        };
        std.mem.sort(*tracking.FileChangeTracker, relevant_files.items, {}, sortContext.lessThan);

        // Show up to 5 relevant files
        const count = @min(5, relevant_files.items.len);
        for (relevant_files.items[0..count]) |file_tracker| {
            const description = switch (file_tracker.last_read_type) {
                .full => "Full file",
                .curated => "Curated view",
                .lines => "Specific lines",
            };

            try writer.print("   • {s} - {s}", .{ file_tracker.path, description });

            // Add details based on type
            if (file_tracker.last_read_type == .curated and file_tracker.curated_result != null) {
                const cache = file_tracker.curated_result.?;
                try writer.print(" ({d} sections)", .{cache.line_ranges.len});
            } else if (file_tracker.last_line_range) |range| {
                try writer.print(" (lines {d}-{d})", .{ range.start, range.end });
            }

            try writer.writeAll("\n");
        }
        has_content = true;
    }
    
    // 3. Recent modifications (last 5)
    const recent_count = @min(5, tracker.recent_modifications.items.len);
    if (recent_count > 0) {
        if (has_content) try writer.writeAll("\n");
        try writer.writeAll("📝 Recent Changes:\n");
        
        // Show most recent first
        var i: usize = 0;
        while (i < recent_count) : (i += 1) {
            const idx = tracker.recent_modifications.items.len - 1 - i;
            const mod = tracker.recent_modifications.items[idx];
            
            const action = switch (mod.modification_type) {
                .created => "Created",
                .modified => "Modified",
                .deleted => "Deleted",
            };
            
            try writer.print("   • {s}: {s}", .{ action, mod.file_path });
            
            if (mod.summary) |summary| {
                const short = if (summary.len > 60) summary[0..60] else summary;
                try writer.print(" - {s}", .{short});
                if (summary.len > 60) try writer.writeAll("...");
            }
            
            try writer.writeAll("\n");
        }
        has_content = true;
    }

    // 4. Files with unseen changes
    // DISABLED: This feature was causing 100-300ms latency per tracked file on every message
    // because hasFileChanged() reads entire files from disk to compare hashes.
    //
    // The feature's purpose was to warn when files are modified externally (e.g., in another editor).
    // However, the performance cost outweighs the benefit for most use cases.
    //
    // If this feature is needed in the future, it should be re-implemented using stat()
    // to check modification time instead of reading file contents.
    //
    // Original code (commented out 2024-11-03 for performance):
    // var changed_files = std.ArrayListUnmanaged([]const u8){};
    // defer changed_files.deinit(allocator);
    //
    // var iter = tracker.read_files.keyIterator();
    // while (iter.next()) |path| {
    //     if (tracker.hasFileChanged(path.*) catch false) {
    //         try changed_files.append(allocator, path.*);
    //     }
    // }
    //
    // if (changed_files.items.len > 0) {
    //     if (has_content) try writer.writeAll("\n");
    //     try writer.writeAll("⚠️  Files Modified Since Last Read:\n");
    //     for (changed_files.items) |path| {
    //         try writer.print("   • {s}\n", .{path});
    //     }
    //     has_content = true;
    // }

    // 5. Pending todos summary
    var pending_count: usize = 0;
    var in_progress_count: usize = 0;
    var completed_count: usize = 0;
    
    for (state.todos.items) |todo| {
        switch (todo.status) {
            .pending => pending_count += 1,
            .in_progress => in_progress_count += 1,
            .completed => completed_count += 1,
        }
    }
    
    const total_todos = state.todos.items.len;
    if (total_todos > 0) {
        if (has_content) try writer.writeAll("\n");
        try writer.print("📋 Todos: ", .{});
        
        var parts = std.ArrayListUnmanaged([]const u8){};
        defer {
            for (parts.items) |part| allocator.free(part);
            parts.deinit(allocator);
        }
        
        if (in_progress_count > 0) {
            try parts.append(allocator, try std.fmt.allocPrint(allocator, "{d} in progress", .{in_progress_count}));
        }
        if (pending_count > 0) {
            try parts.append(allocator, try std.fmt.allocPrint(allocator, "{d} pending", .{pending_count}));
        }
        if (completed_count > 0) {
            try parts.append(allocator, try std.fmt.allocPrint(allocator, "{d} completed", .{completed_count}));
        }
        
        for (parts.items, 0..) |part, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll(part);
        }
        try writer.writeAll("\n");
        has_content = true;
    }
    
    // Only include header/footer if we have content
    if (!has_content) {
        context.deinit(allocator); // Free the unused buffer
        return try allocator.dupe(u8, "");
    }
    
    try writer.writeAll("═══════════════════════\n\n");
    
    return try context.toOwnedSlice(allocator);
}

/// Hash conversation context for cache keys
/// Uses recent messages to determine if conversation context has changed
/// messages can be null or an array of any message type with .content field
pub fn hashConversationContext(messages: anytype) u64 {
    var hasher = std.hash.Wyhash.init(0);
    
    if (messages) |msgs| {
        // Hash recent messages (last 5)
        const start = if (msgs.len > 5) msgs.len - 5 else 0;
        for (msgs[start..]) |msg| {
            hasher.update(msg.content);
        }
    }
    
    return hasher.final();
}
