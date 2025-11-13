// Conversation database module - SQLite persistence for all conversation data
const std = @import("std");
const sqlite = @import("sqlite");
const types = @import("types");
const ollama = @import("ollama");
const markdown = @import("markdown");

const Allocator = std.mem.Allocator;

pub const ConversationDB = struct {
    db: *sqlite.Db,
    allocator: Allocator,

    const Self = @This();

    /// Initialize database connection and create schema if needed
    pub fn init(allocator: Allocator, db_path: []const u8) !Self {
        // Open database with WAL mode for better concurrency
        const db = try sqlite.open(
            db_path,
            sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE,
        );
        errdefer sqlite.close(db);

        var self = Self{
            .db = db,
            .allocator = allocator,
        };

        // Enable WAL mode for non-blocking reads during writes
        try sqlite.exec(db, "PRAGMA journal_mode=WAL");

        // Enable foreign keys
        try sqlite.exec(db, "PRAGMA foreign_keys=ON");

        // Create schema if it doesn't exist
        try self.createSchema();

        return self;
    }

    pub fn deinit(self: *Self) void {
        sqlite.close(self.db);
    }

    /// Create database schema
    fn createSchema(self: *Self) !void {
        // Conversations table
        try sqlite.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS conversations (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    profile_name TEXT NOT NULL,
            \\    started_at INTEGER NOT NULL,
            \\    last_message_at INTEGER NOT NULL,
            \\    message_count INTEGER DEFAULT 0,
            \\    tool_call_count INTEGER DEFAULT 0,
            \\    iteration_count INTEGER DEFAULT 0
            \\)
        );

        // Messages table
        try sqlite.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS messages (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    conversation_id INTEGER NOT NULL,
            \\    message_index INTEGER NOT NULL,
            \\    role TEXT NOT NULL,
            \\    content TEXT NOT NULL,
            \\    thinking_content TEXT,
            \\    timestamp INTEGER NOT NULL,
            \\    tool_call_id TEXT,
            \\    thinking_expanded INTEGER DEFAULT 1,
            \\    tool_call_expanded INTEGER DEFAULT 0,
            \\    tool_name TEXT,
            \\    tool_success INTEGER,
            \\    tool_execution_time INTEGER,
            \\    agent_analysis_name TEXT,
            \\    agent_analysis_expanded INTEGER DEFAULT 0,
            \\    agent_analysis_completed INTEGER DEFAULT 0,
            \\    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
            \\)
        );


        // Agent executions table
        try sqlite.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS agent_executions (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    message_id INTEGER NOT NULL,
            \\    agent_name TEXT NOT NULL,
            \\    thinking TEXT,
            \\    result_data TEXT,
            \\    execution_time_ms INTEGER,
            \\    tool_calls_made INTEGER DEFAULT 0,
            \\    iterations_used INTEGER DEFAULT 0,
            \\    timestamp INTEGER NOT NULL,
            \\    FOREIGN KEY (message_id) REFERENCES messages(id) ON DELETE CASCADE
            \\)
        );

        // Session state table
        try sqlite.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS session_state (
            \\    conversation_id INTEGER PRIMARY KEY,
            \\    todos_json TEXT,
            \\    read_files_json TEXT,
            \\    indexed_files_json TEXT,
            \\    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
            \\)
        );

        // Metadata table
        try sqlite.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS db_metadata (
            \\    key TEXT PRIMARY KEY,
            \\    value TEXT NOT NULL
            \\)
        );

        // Create indexes
        try sqlite.exec(self.db,
            \\CREATE INDEX IF NOT EXISTS idx_messages_conversation
            \\ON messages(conversation_id, message_index)
        );

        try sqlite.exec(self.db,
            \\CREATE INDEX IF NOT EXISTS idx_conversations_profile
            \\ON conversations(profile_name, last_message_at DESC)
        );

        // Set schema version
        try self.setMetadata("schema_version", "1");
    }

    /// Create a new conversation
    pub fn createConversation(self: *Self, profile_name: []const u8) !i64 {
        const now = std.time.timestamp();

        const stmt = try sqlite.prepare(self.db,
            \\INSERT INTO conversations (profile_name, started_at, last_message_at)
            \\VALUES (?, ?, ?)
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, profile_name);
        try sqlite.bindInt64(stmt, 2, now);
        try sqlite.bindInt64(stmt, 3, now);

        _ = try sqlite.step(stmt);

        return sqlite.lastInsertRowId(self.db);
    }

    /// Save a message to the database
    pub fn saveMessage(self: *Self, conversation_id: i64, message_index: i64, message: *const types.Message) !i64 {
        const stmt = try sqlite.prepare(self.db,
            \\INSERT INTO messages (
            \\    conversation_id, message_index, role, content, thinking_content,
            \\    timestamp, tool_call_id, thinking_expanded, tool_call_expanded,
            \\    tool_name, tool_success, tool_execution_time,
            \\    agent_analysis_name, agent_analysis_expanded, agent_analysis_completed
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        );
        defer sqlite.finalize(stmt);

        const role_str = @tagName(message.role);

        try sqlite.bindInt64(stmt, 1, conversation_id);
        try sqlite.bindInt64(stmt, 2, message_index);
        try sqlite.bindText(stmt, 3, role_str);
        try sqlite.bindText(stmt, 4, message.content);

        if (message.thinking_content) |thinking| {
            try sqlite.bindText(stmt, 5, thinking);
        } else {
            try sqlite.bindNull(stmt, 5);
        }

        try sqlite.bindInt64(stmt, 6, message.timestamp);

        if (message.tool_call_id) |id| {
            try sqlite.bindText(stmt, 7, id);
        } else {
            try sqlite.bindNull(stmt, 7);
        }

        try sqlite.bindInt64(stmt, 8, if (message.thinking_expanded) 1 else 0);
        try sqlite.bindInt64(stmt, 9, if (message.tool_call_expanded) 1 else 0);

        if (message.tool_name) |name| {
            try sqlite.bindText(stmt, 10, name);
        } else {
            try sqlite.bindNull(stmt, 10);
        }

        if (message.tool_success) |success| {
            try sqlite.bindInt64(stmt, 11, if (success) 1 else 0);
        } else {
            try sqlite.bindNull(stmt, 11);
        }

        if (message.tool_execution_time) |time| {
            try sqlite.bindInt64(stmt, 12, time);
        } else {
            try sqlite.bindNull(stmt, 12);
        }

        if (message.agent_analysis_name) |name| {
            try sqlite.bindText(stmt, 13, name);
        } else {
            try sqlite.bindNull(stmt, 13);
        }

        try sqlite.bindInt64(stmt, 14, if (message.agent_analysis_expanded) 1 else 0);
        try sqlite.bindInt64(stmt, 15, if (message.agent_analysis_completed) 1 else 0);

        _ = try sqlite.step(stmt);

        const message_id = sqlite.lastInsertRowId(self.db);

        // Update conversation stats
        try self.updateConversationStats(conversation_id);

        return message_id;
    }



    /// Save an agent execution
    pub fn saveAgentExecution(self: *Self, message_id: i64, agent_name: []const u8,
                              thinking: ?[]const u8, result_data: ?[]const u8,
                              execution_time_ms: ?i64, tool_calls_made: i64,
                              iterations_used: i64) !i64 {
        const now = std.time.timestamp();

        const stmt = try sqlite.prepare(self.db,
            \\INSERT INTO agent_executions (message_id, agent_name, thinking, result_data,
            \\                              execution_time_ms, tool_calls_made, iterations_used, timestamp)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindInt64(stmt, 1, message_id);
        try sqlite.bindText(stmt, 2, agent_name);

        if (thinking) |t| {
            try sqlite.bindText(stmt, 3, t);
        } else {
            try sqlite.bindNull(stmt, 3);
        }

        if (result_data) |d| {
            try sqlite.bindText(stmt, 4, d);
        } else {
            try sqlite.bindNull(stmt, 4);
        }

        if (execution_time_ms) |time| {
            try sqlite.bindInt64(stmt, 5, time);
        } else {
            try sqlite.bindNull(stmt, 5);
        }

        try sqlite.bindInt64(stmt, 6, tool_calls_made);
        try sqlite.bindInt64(stmt, 7, iterations_used);
        try sqlite.bindInt64(stmt, 8, now);

        _ = try sqlite.step(stmt);

        return sqlite.lastInsertRowId(self.db);
    }

    /// Update conversation statistics
    fn updateConversationStats(self: *Self, conversation_id: i64) !void {
        const now = std.time.timestamp();

        const stmt = try sqlite.prepare(self.db,
            \\UPDATE conversations
            \\SET last_message_at = ?,
            \\    message_count = (SELECT COUNT(*) FROM messages WHERE conversation_id = ?)
            \\WHERE id = ?
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindInt64(stmt, 1, now);
        try sqlite.bindInt64(stmt, 2, conversation_id);
        try sqlite.bindInt64(stmt, 3, conversation_id);

        _ = try sqlite.step(stmt);
    }

    /// Set a metadata key-value pair
    fn setMetadata(self: *Self, key: []const u8, value: []const u8) !void {
        const stmt = try sqlite.prepare(self.db,
            \\INSERT OR REPLACE INTO db_metadata (key, value) VALUES (?, ?)
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, key);
        try sqlite.bindText(stmt, 2, value);

        _ = try sqlite.step(stmt);
    }

    /// Get a metadata value
    pub fn getMetadata(self: *Self, key: []const u8) !?[]const u8 {
        const stmt = try sqlite.prepare(self.db,
            \\SELECT value FROM db_metadata WHERE key = ?
        );
        defer sqlite.finalize(stmt);

        try sqlite.bindText(stmt, 1, key);

        const rc = try sqlite.step(stmt);
        if (rc == sqlite.SQLITE_ROW) {
            if (sqlite.columnText(stmt, 0)) |text| {
                return try self.allocator.dupe(u8, text);
            }
        }

        return null;
    }

    /// Begin a transaction
    pub fn beginTransaction(self: *Self) !void {
        try sqlite.exec(self.db, "BEGIN TRANSACTION");
    }

    /// Commit a transaction
    pub fn commitTransaction(self: *Self) !void {
        try sqlite.exec(self.db, "COMMIT");
    }

    /// Rollback a transaction
    pub fn rollbackTransaction(self: *Self) !void {
        try sqlite.exec(self.db, "ROLLBACK");
    }
};
