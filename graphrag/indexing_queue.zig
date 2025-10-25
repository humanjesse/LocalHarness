const std = @import("std");

/// Task representing a file to be indexed by the GraphRAG system
pub const IndexingTask = struct {
    file_path: []const u8,
    content: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *IndexingTask) void {
        self.allocator.free(self.file_path);
        self.allocator.free(self.content);
    }
};

/// Simple queue for indexing tasks (sequential processing, no threading)
pub const IndexingQueue = struct {
    tasks: std.ArrayListUnmanaged(IndexingTask) = .{},
    allocator: std.mem.Allocator,

    fn isDebugEnabled() bool {
        return std.posix.getenv("DEBUG_GRAPHRAG") != null;
    }

    pub fn init(allocator: std.mem.Allocator) IndexingQueue {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *IndexingQueue) void {
        // Clean up any remaining tasks
        for (self.tasks.items) |*task| {
            task.deinit();
        }
        self.tasks.deinit(self.allocator);
    }

    /// Push a new indexing task to the queue
    pub fn push(self: *IndexingQueue, task: IndexingTask) !void {
        try self.tasks.append(self.allocator, task);

        if (isDebugEnabled()) {
            std.debug.print("[GRAPHRAG] Queued file for indexing: {s} ({d} bytes)\n", .{ task.file_path, task.content.len });
        }
    }

    /// Check if queue is empty
    pub fn isEmpty(self: *IndexingQueue) bool {
        return self.tasks.items.len == 0;
    }

    /// Get current queue size
    pub fn size(self: *IndexingQueue) usize {
        return self.tasks.items.len;
    }

    /// Drain all tasks from the queue and return them
    /// Caller is responsible for deinit'ing the returned slice and tasks
    pub fn drainAll(self: *IndexingQueue) ![]IndexingTask {
        const items = try self.tasks.toOwnedSlice(self.allocator);
        return items;
    }

    /// Peek at the front task without removing it
    /// Returns null if queue is empty
    pub fn peek(self: *IndexingQueue) ?IndexingTask {
        if (self.tasks.items.len == 0) return null;
        return self.tasks.items[0];
    }

    /// Remove and return the front task
    /// Caller is responsible for deinit'ing the returned task
    /// Returns null if queue is empty
    pub fn pop(self: *IndexingQueue) !?IndexingTask {
        if (self.tasks.items.len == 0) return null;
        const task = self.tasks.orderedRemove(0);
        return task;
    }
};
