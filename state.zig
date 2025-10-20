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

/// Session-ephemeral application state
/// Phase 1: Task management only
/// Phase 2+: Will include graph RAG, vector store, etc.
pub const AppState = struct {
    allocator: mem.Allocator,
    tasks: std.ArrayListUnmanaged(Task),
    next_task_id: usize,
    session_start: i64,
    iteration_count: usize,
    read_files: std.StringHashMapUnmanaged(void), // Track files read in this session

    pub fn init(allocator: mem.Allocator) AppState {
        return .{
            .allocator = allocator,
            .tasks = .{},
            .next_task_id = 1,
            .session_start = std.time.milliTimestamp(),
            .iteration_count = 0,
            .read_files = .{},
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
    }
};
