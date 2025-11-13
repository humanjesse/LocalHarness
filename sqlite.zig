// Minimal SQLite3 C API bindings
const std = @import("std");

// SQLite result codes
pub const SQLITE_OK = 0;
pub const SQLITE_ERROR = 1;
pub const SQLITE_BUSY = 5;
pub const SQLITE_LOCKED = 6;
pub const SQLITE_NOMEM = 7;
pub const SQLITE_READONLY = 8;
pub const SQLITE_INTERRUPT = 9;
pub const SQLITE_IOERR = 10;
pub const SQLITE_CORRUPT = 11;
pub const SQLITE_NOTFOUND = 12;
pub const SQLITE_FULL = 13;
pub const SQLITE_CANTOPEN = 14;
pub const SQLITE_PROTOCOL = 15;
pub const SQLITE_EMPTY = 16;
pub const SQLITE_SCHEMA = 17;
pub const SQLITE_TOOBIG = 18;
pub const SQLITE_CONSTRAINT = 19;
pub const SQLITE_MISMATCH = 20;
pub const SQLITE_MISUSE = 21;
pub const SQLITE_NOLFS = 22;
pub const SQLITE_AUTH = 23;
pub const SQLITE_FORMAT = 24;
pub const SQLITE_RANGE = 25;
pub const SQLITE_NOTADB = 26;
pub const SQLITE_ROW = 100;
pub const SQLITE_DONE = 101;

// SQLite data types
pub const SQLITE_INTEGER = 1;
pub const SQLITE_FLOAT = 2;
pub const SQLITE_TEXT = 3;
pub const SQLITE_BLOB = 4;
pub const SQLITE_NULL = 5;

// SQLite open flags
pub const SQLITE_OPEN_READONLY = 0x00000001;
pub const SQLITE_OPEN_READWRITE = 0x00000002;
pub const SQLITE_OPEN_CREATE = 0x00000004;
pub const SQLITE_OPEN_URI = 0x00000040;
pub const SQLITE_OPEN_MEMORY = 0x00000080;
pub const SQLITE_OPEN_NOMUTEX = 0x00008000;
pub const SQLITE_OPEN_FULLMUTEX = 0x00010000;
pub const SQLITE_OPEN_SHAREDCACHE = 0x00020000;
pub const SQLITE_OPEN_PRIVATECACHE = 0x00040000;

// Opaque types
pub const Db = opaque {};
pub const Stmt = opaque {};

// External C functions
extern "c" fn sqlite3_open_v2(filename: [*:0]const u8, ppDb: **Db, flags: c_int, zVfs: ?[*:0]const u8) c_int;
extern "c" fn sqlite3_close(db: *Db) c_int;
extern "c" fn sqlite3_exec(db: *Db, sql: [*:0]const u8, callback: ?*const fn () callconv(.c) void, arg: ?*anyopaque, errmsg: ?*[*:0]u8) c_int;
extern "c" fn sqlite3_prepare_v2(db: *Db, zSql: [*:0]const u8, nByte: c_int, ppStmt: **Stmt, pzTail: ?*[*:0]const u8) c_int;
extern "c" fn sqlite3_step(stmt: *Stmt) c_int;
extern "c" fn sqlite3_finalize(stmt: *Stmt) c_int;
extern "c" fn sqlite3_reset(stmt: *Stmt) c_int;
extern "c" fn sqlite3_bind_int64(stmt: *Stmt, index: c_int, value: i64) c_int;
extern "c" fn sqlite3_bind_text(stmt: *Stmt, index: c_int, value: [*:0]const u8, n: c_int, destructor: ?*const fn () callconv(.c) void) c_int;
extern "c" fn sqlite3_bind_null(stmt: *Stmt, index: c_int) c_int;
extern "c" fn sqlite3_column_int64(stmt: *Stmt, iCol: c_int) i64;
extern "c" fn sqlite3_column_text(stmt: *Stmt, iCol: c_int) [*:0]const u8;
extern "c" fn sqlite3_column_type(stmt: *Stmt, iCol: c_int) c_int;
extern "c" fn sqlite3_errmsg(db: *Db) [*:0]const u8;
extern "c" fn sqlite3_last_insert_rowid(db: *Db) i64;
extern "c" fn sqlite3_changes(db: *Db) c_int;
extern "c" fn sqlite3_free(ptr: *anyopaque) void;

// Helper constants
pub const SQLITE_STATIC = @as(?*const fn () callconv(.c) void, @ptrFromInt(0));
pub const SQLITE_TRANSIENT = @as(?*const fn () callconv(.c) void, @ptrFromInt(@as(usize, @bitCast(@as(isize, -1)))));

// Zig wrappers
pub fn open(filename: []const u8, flags: c_int) !*Db {
    var db: *Db = undefined;
    const filename_z = try std.heap.page_allocator.dupeZ(u8, filename);
    defer std.heap.page_allocator.free(filename_z);

    const rc = sqlite3_open_v2(filename_z.ptr, &db, flags, null);
    if (rc != SQLITE_OK) {
        return error.SqliteOpenFailed;
    }
    return db;
}

pub fn close(db: *Db) void {
    _ = sqlite3_close(db);
}

pub fn exec(db: *Db, sql: []const u8) !void {
    const sql_z = try std.heap.page_allocator.dupeZ(u8, sql);
    defer std.heap.page_allocator.free(sql_z);

    const rc = sqlite3_exec(db, sql_z.ptr, null, null, null);
    if (rc != SQLITE_OK) {
        const err = sqlite3_errmsg(db);
        std.debug.print("SQLite error: {s}\n", .{err});
        return error.SqliteExecFailed;
    }
}

pub fn prepare(db: *Db, sql: []const u8) !*Stmt {
    var stmt: *Stmt = undefined;
    const sql_z = try std.heap.page_allocator.dupeZ(u8, sql);
    defer std.heap.page_allocator.free(sql_z);

    const rc = sqlite3_prepare_v2(db, sql_z.ptr, -1, &stmt, null);
    if (rc != SQLITE_OK) {
        const err = sqlite3_errmsg(db);
        std.debug.print("SQLite prepare error: {s}\n", .{err});
        return error.SqlitePrepareFailed;
    }
    return stmt;
}

pub fn step(stmt: *Stmt) !c_int {
    const rc = sqlite3_step(stmt);
    if (rc != SQLITE_ROW and rc != SQLITE_DONE) {
        return error.SqliteStepFailed;
    }
    return rc;
}

pub fn finalize(stmt: *Stmt) void {
    _ = sqlite3_finalize(stmt);
}

pub fn reset(stmt: *Stmt) !void {
    const rc = sqlite3_reset(stmt);
    if (rc != SQLITE_OK) {
        return error.SqliteResetFailed;
    }
}

pub fn bindInt64(stmt: *Stmt, index: c_int, value: i64) !void {
    const rc = sqlite3_bind_int64(stmt, index, value);
    if (rc != SQLITE_OK) {
        return error.SqliteBindFailed;
    }
}

pub fn bindText(stmt: *Stmt, index: c_int, value: []const u8) !void {
    const value_z = try std.heap.page_allocator.dupeZ(u8, value);
    // Note: Using TRANSIENT so SQLite makes its own copy
    const rc = sqlite3_bind_text(stmt, index, value_z.ptr, @intCast(value.len), SQLITE_TRANSIENT);
    std.heap.page_allocator.free(value_z);
    if (rc != SQLITE_OK) {
        return error.SqliteBindFailed;
    }
}

pub fn bindNull(stmt: *Stmt, index: c_int) !void {
    const rc = sqlite3_bind_null(stmt, index);
    if (rc != SQLITE_OK) {
        return error.SqliteBindFailed;
    }
}

pub fn columnInt64(stmt: *Stmt, col: c_int) i64 {
    return sqlite3_column_int64(stmt, col);
}

pub fn columnText(stmt: *Stmt, col: c_int) ?[]const u8 {
    const rc = sqlite3_column_type(stmt, col);
    if (rc == SQLITE_NULL) {
        return null;
    }
    const text = sqlite3_column_text(stmt, col);
    return std.mem.span(text);
}

pub fn lastInsertRowId(db: *Db) i64 {
    return sqlite3_last_insert_rowid(db);
}

pub fn changes(db: *Db) c_int {
    return sqlite3_changes(db);
}

pub fn errorMsg(db: *Db) []const u8 {
    const msg = sqlite3_errmsg(db);
    return std.mem.span(msg);
}
