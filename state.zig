// Application state management (Phase 1: Task tracking for master loop)
const std = @import("std");
const mem = std.mem;

/// Task status enum for tracking progress
pub const TaskStatus = enum { pending, in_progress, completed };

/// Individual task with ID, content, and status
pub const Task = struct {
    id: []const u8, // String ID like "task_1", "task_2", etc.
    content: []const u8,
    status: TaskStatus,
};

/// Pending file to be indexed by Graph RAG
pub const PendingIndexFile = struct {
    path: []const u8, // owned
    content: []const u8, // owned
};

/// Session-ephemeral application state
pub const AppState = struct {
    allocator: mem.Allocator,
    tasks: std.ArrayListUnmanaged(Task),
    next_task_id: usize,
    session_start: i64,
    iteration_count: usize,
    read_files: std.StringHashMapUnmanaged(void), // Track files read in this session
    indexed_files: std.StringHashMapUnmanaged(void), // Track files indexed in Graph RAG
    pending_index_files: std.ArrayListUnmanaged(PendingIndexFile), // Queue for background indexing

    pub fn init(allocator: mem.Allocator) AppState {
        return .{
            .allocator = allocator,
            .tasks = .{},
            .next_task_id = 1,
            .session_start = std.time.milliTimestamp(),
            .iteration_count = 0,
            .read_files = .{},
            .indexed_files = .{},
            .pending_index_files = .{},
        };
    }

    pub fn addTask(self: *AppState, content: []const u8) ![]const u8 {
        // Generate string ID like "task_1", "task_2", etc.
        const task_id = try std.fmt.allocPrint(self.allocator, "task_{d}", .{self.next_task_id});
        errdefer self.allocator.free(task_id);

        self.next_task_id += 1;

        const owned_content = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(owned_content);

        try self.tasks.append(self.allocator, .{
            .id = task_id,
            .content = owned_content,
            .status = .pending,
        });

        return task_id;
    }

    pub fn updateTask(self: *AppState, task_id: []const u8, new_status: TaskStatus) !void {
        for (self.tasks.items) |*task| {
            if (mem.eql(u8, task.id, task_id)) {
                task.status = new_status;
                return;
            }
        }
        return error.TaskNotFound;
    }

    pub fn getTasks(self: *AppState) []const Task {
        return self.tasks.items;
    }

    pub fn markFileAsRead(self: *AppState, path: []const u8) !void {
        // Check if already tracked to avoid duplicate allocations
        if (self.read_files.contains(path)) {
            return; // Already marked, nothing to do
        }

        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        try self.read_files.put(self.allocator, owned_path, {});
    }

    pub fn wasFileRead(self: *AppState, path: []const u8) bool {
        return self.read_files.contains(path);
    }

    pub fn markFileAsIndexed(self: *AppState, path: []const u8) !void {
        // Check if already indexed to avoid duplicate allocations
        if (self.indexed_files.contains(path)) {
            return; // Already indexed
        }

        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        try self.indexed_files.put(self.allocator, owned_path, {});
    }

    pub fn wasFileIndexed(self: *AppState, path: []const u8) bool {
        return self.indexed_files.contains(path);
    }

    /// Queue a file for background Graph RAG indexing
    pub fn queueFileForIndexing(self: *AppState, path: []const u8, content: []const u8) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);

        const owned_content = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(owned_content);

        try self.pending_index_files.append(self.allocator, .{
            .path = owned_path,
            .content = owned_content,
        });
    }

    /// Check if there are files pending indexing
    pub fn hasPendingIndexing(self: *AppState) bool {
        return self.pending_index_files.items.len > 0;
    }

    /// Pop the next pending file from the indexing queue
    /// Returns null if queue is empty
    /// Caller owns returned memory and must free path and content
    pub fn popPendingIndexFile(self: *AppState) ?PendingIndexFile {
        if (self.pending_index_files.items.len == 0) return null;
        return self.pending_index_files.orderedRemove(0);
    }

    pub fn deinit(self: *AppState) void {
        for (self.tasks.items) |task| {
            self.allocator.free(task.id);
            self.allocator.free(task.content);
        }
        self.tasks.deinit(self.allocator);

        // Free read_files hashmap
        var iter = self.read_files.keyIterator();
        while (iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.read_files.deinit(self.allocator);

        // Free indexed_files hashmap
        var indexed_iter = self.indexed_files.keyIterator();
        while (indexed_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.indexed_files.deinit(self.allocator);

        // Free pending index files queue
        for (self.pending_index_files.items) |pending| {
            self.allocator.free(pending.path);
            self.allocator.free(pending.content);
        }
        self.pending_index_files.deinit(self.allocator);
    }
};
