// Context tracking - file changes, todos, and relationships
const std = @import("std");
const mem = std.mem;

/// Type of file read performed
pub const ReadType = enum { 
    full,      // Full file content
    curated,   // Curator-filtered content
    lines,     // Specific line range (read_lines tool)
};

/// Line range for tracking partial file reads (read_lines tool)
pub const ReadLineRange = struct {
    start: usize,
    end: usize,
};

/// Tracks file modifications
pub const FileChangeTracker = struct {
    path: []const u8,              // owned
    original_hash: u64,
    last_read_time: i64,
    curated_result: ?CurationCache = null,
    last_read_type: ReadType = .full,
    last_line_range: ?ReadLineRange = null,
};

/// Cached curation result
pub const CurationCache = struct {
    line_ranges: []LineRange,      // owned
    conversation_hash: u64,
    summary: []const u8,           // owned
    timestamp: i64,
    
    pub const LineRange = struct {
        start: usize,
        end: usize,
        reason: []const u8,        // owned
    };
    
    pub fn deinit(self: *CurationCache, allocator: mem.Allocator) void {
        for (self.line_ranges) |range| {
            allocator.free(range.reason);
        }
        allocator.free(self.line_ranges);
        allocator.free(self.summary);
    }
};

/// Todo context tracking
pub const TodoContext = struct {
    active_todo_id: ?[]const u8 = null,   // borrowed from state
    files_touched_for_todo: std.StringHashMapUnmanaged(void) = .{},
    todo_started_at: i64 = 0,
    
    pub fn deinit(self: *TodoContext, allocator: mem.Allocator) void {
        var iter = self.files_touched_for_todo.keyIterator();
        while (iter.next()) |key| {
            allocator.free(key.*);
        }
        self.files_touched_for_todo.deinit(allocator);
    }
    
    pub fn setActiveTodo(self: *TodoContext, allocator: mem.Allocator, todo_id: []const u8) !void {
        self.active_todo_id = todo_id;
        self.todo_started_at = std.time.milliTimestamp();
        
        // Clear previous file associations
        var iter = self.files_touched_for_todo.keyIterator();
        while (iter.next()) |key| {
            allocator.free(key.*);
        }
        self.files_touched_for_todo.clearRetainingCapacity();
    }
    
    pub fn clearActiveTodo(self: *TodoContext, allocator: mem.Allocator) void {
        self.active_todo_id = null;
        self.todo_started_at = 0;
        
        // Clear file associations
        var iter = self.files_touched_for_todo.keyIterator();
        while (iter.next()) |key| {
            allocator.free(key.*);
        }
        self.files_touched_for_todo.clearRetainingCapacity();
    }
    
    pub fn markFileForActiveTodo(self: *TodoContext, allocator: mem.Allocator, file_path: []const u8) !void {
        if (self.active_todo_id == null) return;
        if (self.files_touched_for_todo.contains(file_path)) return;
        
        const owned_path = try allocator.dupe(u8, file_path);
        try self.files_touched_for_todo.put(allocator, owned_path, {});
    }
};

pub const ModificationType = enum { created, modified, deleted };

/// Recent modification record
pub const RecentModification = struct {
    file_path: []const u8,         // owned
    modification_type: ModificationType,
    timestamp: i64,
    related_todo: ?[]const u8,     // owned if not null
    summary: ?[]const u8,          // owned if not null
    
    pub fn deinit(self: *RecentModification, allocator: mem.Allocator) void {
        allocator.free(self.file_path);
        if (self.related_todo) |todo| allocator.free(todo);
        if (self.summary) |summ| allocator.free(summ);
    }
};

/// Lightweight file relationships (no embeddings!)
pub const FileRelationships = struct {
    allocator: mem.Allocator,
    imports: std.StringHashMapUnmanaged([][]const u8) = .{},
    imported_by: std.StringHashMapUnmanaged([][]const u8) = .{},
    functions: std.StringHashMapUnmanaged([]FunctionInfo) = .{},
    
    pub const FunctionInfo = struct {
        name: []const u8,          // owned
        start_line: usize,
        end_line: usize,
        is_public: bool,
        
        pub fn deinit(self: *FunctionInfo, allocator: mem.Allocator) void {
            allocator.free(self.name);
        }
    };
    
    pub fn init(allocator: mem.Allocator) FileRelationships {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *FileRelationships) void {
        // Free imports hashmap
        var imports_iter = self.imports.iterator();
        while (imports_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.*) |import| {
                self.allocator.free(import);
            }
            self.allocator.free(entry.value_ptr.*);
        }
        self.imports.deinit(self.allocator);
        
        // Free imported_by hashmap
        var imported_iter = self.imported_by.iterator();
        while (imported_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.*) |imported| {
                self.allocator.free(imported);
            }
            self.allocator.free(entry.value_ptr.*);
        }
        self.imported_by.deinit(self.allocator);
        
        // Free functions hashmap
        var funcs_iter = self.functions.iterator();
        while (funcs_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.*) |*func| {
                func.deinit(self.allocator);
            }
            self.allocator.free(entry.value_ptr.*);
        }
        self.functions.deinit(self.allocator);
    }
    
    /// Add import relationship
    pub fn addImport(self: *FileRelationships, file: []const u8, imported: []const u8) !void {
        // Add to imports map
        const result = try self.imports.getOrPut(self.allocator, file);
        if (!result.found_existing) {
            result.key_ptr.* = try self.allocator.dupe(u8, file);
            result.value_ptr.* = &.{};
        }
        
        // Check if already in list
        for (result.value_ptr.*) |existing| {
            if (mem.eql(u8, existing, imported)) return; // Already added
        }
        
        // Add imported file to list
        var list = std.ArrayListUnmanaged([]const u8).fromOwnedSlice(result.value_ptr.*);
        try list.append(self.allocator, try self.allocator.dupe(u8, imported));
        result.value_ptr.* = try list.toOwnedSlice(self.allocator);
        
        // Add to imported_by (reverse index)
        const rev_result = try self.imported_by.getOrPut(self.allocator, imported);
        if (!rev_result.found_existing) {
            rev_result.key_ptr.* = try self.allocator.dupe(u8, imported);
            rev_result.value_ptr.* = &.{};
        }
        
        // Check if already in reverse list
        for (rev_result.value_ptr.*) |existing| {
            if (mem.eql(u8, existing, file)) return; // Already added
        }
        
        var rev_list = std.ArrayListUnmanaged([]const u8).fromOwnedSlice(rev_result.value_ptr.*);
        try rev_list.append(self.allocator, try self.allocator.dupe(u8, file));
        rev_result.value_ptr.* = try rev_list.toOwnedSlice(self.allocator);
    }
    
    /// Get files imported by a file
    pub fn getImports(self: *FileRelationships, file: []const u8) ?[]const []const u8 {
        return self.imports.get(file);
    }
    
    /// Get files that import a file
    pub fn getImportedBy(self: *FileRelationships, file: []const u8) ?[]const []const u8 {
        return self.imported_by.get(file);
    }
};

/// Unified context tracker
pub const ContextTracker = struct {
    allocator: mem.Allocator,
    
    // File tracking
    read_files: std.StringHashMapUnmanaged(FileChangeTracker) = .{},
    recent_modifications: std.ArrayListUnmanaged(RecentModification) = .{},
    relationships: FileRelationships,
    
    // Todo tracking
    todo_context: TodoContext = .{},
    
    // Configuration
    max_recent_modifications: usize = 20,
    cache_ttl_seconds: i64 = 3600,
    
    pub fn init(allocator: mem.Allocator) ContextTracker {
        return .{
            .allocator = allocator,
            .relationships = FileRelationships.init(allocator),
        };
    }
    
    pub fn deinit(self: *ContextTracker) void {
        // Free read_files
        var iter = self.read_files.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.curated_result) |*cache| {
                cache.deinit(self.allocator);
            }
        }
        self.read_files.deinit(self.allocator);
        
        // Free recent modifications
        for (self.recent_modifications.items) |*mod| {
            mod.deinit(self.allocator);
        }
        self.recent_modifications.deinit(self.allocator);
        
        // Free relationships
        self.relationships.deinit();
        
        // Free todo context
        self.todo_context.deinit(self.allocator);
    }
    
    /// Track file read
    pub fn trackFileRead(
        self: *ContextTracker,
        file_path: []const u8,
        content: []const u8,
        read_type: ReadType,
        line_range: ?ReadLineRange,
    ) !void {
        const hash = std.hash.Wyhash.hash(0, content);
        
        // Check if already tracking
        if (self.read_files.getPtr(file_path)) |tracker| {
            // Update existing tracker
            tracker.original_hash = hash;
            tracker.last_read_time = std.time.milliTimestamp();
            tracker.last_read_type = read_type;
            tracker.last_line_range = line_range;
            // Keep existing curated_result cache
            return;
        }
        
        // Add new tracker
        const owned_path = try self.allocator.dupe(u8, file_path);
        try self.read_files.put(self.allocator, owned_path, .{
            .path = owned_path,
            .original_hash = hash,
            .last_read_time = std.time.milliTimestamp(),
            .last_read_type = read_type,
            .last_line_range = line_range,
        });
    }
    
    /// Record file modification
    pub fn recordModification(
        self: *ContextTracker,
        file_path: []const u8,
        mod_type: ModificationType,
        summary: ?[]const u8,
    ) !void {
        // Limit queue size
        if (self.recent_modifications.items.len >= self.max_recent_modifications) {
            var first = self.recent_modifications.orderedRemove(0);
            first.deinit(self.allocator);
        }
        
        const owned_path = try self.allocator.dupe(u8, file_path);
        const owned_summary = if (summary) |s| try self.allocator.dupe(u8, s) else null;
        const related_todo = if (self.todo_context.active_todo_id) |id|
            try self.allocator.dupe(u8, id)
        else
            null;
        
        try self.recent_modifications.append(self.allocator, .{
            .file_path = owned_path,
            .modification_type = mod_type,
            .timestamp = std.time.milliTimestamp(),
            .related_todo = related_todo,
            .summary = owned_summary,
        });
        
        // Mark file for active todo
        try self.todo_context.markFileForActiveTodo(self.allocator, file_path);
        
        // Update hash if file was previously read
        if (self.read_files.getPtr(file_path)) |tracker| {
            const file = std.fs.cwd().openFile(file_path, .{}) catch return;
            defer file.close();
            const new_content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch return;
            defer self.allocator.free(new_content);
            tracker.original_hash = std.hash.Wyhash.hash(0, new_content);
            
            // Invalidate cache since file changed
            if (tracker.curated_result) |*cache| {
                cache.deinit(self.allocator);
                tracker.curated_result = null;
            }
        }
    }
    
    /// Check if file has changed since read
    pub fn hasFileChanged(self: *ContextTracker, file_path: []const u8) !bool {
        const tracker = self.read_files.get(file_path) orelse return false;
        
        const file = std.fs.cwd().openFile(file_path, .{}) catch return false;
        defer file.close();
        
        const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        defer self.allocator.free(content);
        
        const current_hash = std.hash.Wyhash.hash(0, content);
        return current_hash != tracker.original_hash;
    }
};
