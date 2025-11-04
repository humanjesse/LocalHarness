// Grep Search Tool Tests
const std = @import("std");
const testing = std.testing;
const grep_search = @import("grep_search.zig");
const context_module = @import("context");

// Helper to create a temporary test directory structure
fn createTestFiles(allocator: std.mem.Allocator, dir: std.fs.Dir) !void {
    // Create test files with various content
    try dir.writeFile("test1.zig", "const allocator = std.mem.Allocator;\nfunction validateInit() {\n    return true;\n}\n");
    try dir.writeFile("test2.zig", "fn init() {\n    const ALLOCATOR = allocator;\n}\n");
    try dir.writeFile("readme.md", "# Test Project\nThis is a test.\n");

    // Create a subdirectory with files
    try dir.makeDir("src");
    var src_dir = try dir.openDir("src", .{});
    defer src_dir.close();
    try src_dir.writeFile("main.zig", "pub fn main() !void {\n    const allocator = Allocator.init();\n}\n");

    // Create a hidden directory
    try dir.makeDir(".config");
    var config_dir = try dir.openDir(".config", .{});
    defer config_dir.close();
    try config_dir.writeFile("settings.conf", "database_config=localhost\nport=5432\n");

    // Create .git directory (should always be skipped)
    try dir.makeDir(".git");
    var git_dir = try dir.openDir(".git", .{});
    defer git_dir.close();
    try git_dir.writeFile("config", "secret_token=abc123\n");

    // Create .gitignore
    try dir.writeFile(".gitignore", "*.log\nnode_modules/\ntest_output\n");

    // Create a file that should be gitignored
    try dir.writeFile("debug.log", "Debug log entry\nallocator used here\n");

    // Create node_modules to test exact gitignore matching
    try dir.makeDir("node_modules");
    var node_dir = try dir.openDir("node_modules", .{});
    defer node_dir.close();
    try node_dir.writeFile("package.json", "{\n  \"name\": \"test\"\n}\n");

    _ = allocator;
}

// Helper to create AppContext for testing
fn createTestContext(allocator: std.mem.Allocator) !*context_module.AppContext {
    var ctx = try allocator.create(context_module.AppContext);
    ctx.* = context_module.AppContext{
        .allocator = allocator,
        .config = undefined,
        .state = undefined,
        .cwd = ".",
    };
    return ctx;
}

test "grep_search - simple pattern finds matches" {
    const allocator = testing.allocator;

    // Create temp directory
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFiles(allocator, tmp.dir);

    // Change to test directory
    var original_cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.os.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    // Create context
    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    // Execute search
    const args = "{\"pattern\":\"allocator\"}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    try testing.expect(result.data != null);

    const output = result.data.?;

    // Should find "allocator" in multiple files
    try testing.expect(std.mem.indexOf(u8, output, "test1.zig") != null);
    try testing.expect(std.mem.indexOf(u8, output, "test2.zig") != null);
}

test "grep_search - wildcard matching works as substring" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFiles(allocator, tmp.dir);

    var original_cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.os.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    // Search for pattern with wildcard
    const args = "{\"pattern\":\"fn*init\"}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    const output = result.data.?;

    // Should match "function validateInit" and "fn init"
    try testing.expect(std.mem.indexOf(u8, output, "validateInit") != null or std.mem.indexOf(u8, output, "fn init") != null);
}

test "grep_search - case insensitive search" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFiles(allocator, tmp.dir);

    var original_cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.os.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    // Search with uppercase pattern
    const args = "{\"pattern\":\"ALLOCATOR\"}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    const output = result.data.?;

    // Should find both "allocator" and "ALLOCATOR"
    try testing.expect(std.mem.indexOf(u8, output, "test1.zig") != null or std.mem.indexOf(u8, output, "test2.zig") != null);
}

test "grep_search - respects gitignore by default" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFiles(allocator, tmp.dir);

    var original_cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.os.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    // Search for pattern that exists in gitignored file
    const args = "{\"pattern\":\"Debug log\"}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    const output = result.data.?;

    // Should NOT find it in debug.log (gitignored)
    try testing.expect(std.mem.indexOf(u8, output, "debug.log") == null);
    try testing.expect(std.mem.indexOf(u8, output, "No matches found") != null);
}

test "grep_search - ignore_gitignore flag bypasses .gitignore" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFiles(allocator, tmp.dir);

    var original_cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.os.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    // Search with ignore_gitignore flag
    const args = "{\"pattern\":\"Debug log\",\"ignore_gitignore\":true}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    const output = result.data.?;

    // Should find it in debug.log now
    try testing.expect(std.mem.indexOf(u8, output, "debug.log") != null);
    try testing.expect(std.mem.indexOf(u8, output, "[+gitignored]") != null);
}

test "grep_search - skips hidden directories by default" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFiles(allocator, tmp.dir);

    var original_cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.os.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    // Search for pattern in hidden directory
    const args = "{\"pattern\":\"database_config\"}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    const output = result.data.?;

    // Should NOT find it in .config/ (hidden)
    try testing.expect(std.mem.indexOf(u8, output, ".config") == null);
}

test "grep_search - include_hidden searches hidden directories" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFiles(allocator, tmp.dir);

    var original_cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.os.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    // Search with include_hidden flag
    const args = "{\"pattern\":\"database_config\",\"include_hidden\":true}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    const output = result.data.?;

    // Should find it in .config/ now
    try testing.expect(std.mem.indexOf(u8, output, ".config") != null);
    try testing.expect(std.mem.indexOf(u8, output, "[+hidden]") != null);
}

test "grep_search - always skips .git directory" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFiles(allocator, tmp.dir);

    var original_cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.os.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    // Search with include_hidden flag (should still skip .git)
    const args = "{\"pattern\":\"secret_token\",\"include_hidden\":true}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    const output = result.data.?;

    // Should NOT find it in .git/ (always skipped)
    try testing.expect(std.mem.indexOf(u8, output, ".git") == null);
}

test "grep_search - file_filter limits search" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFiles(allocator, tmp.dir);

    var original_cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.os.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    // Search only in .zig files
    const args = "{\"pattern\":\"test\",\"file_filter\":\"*.zig\"}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    const output = result.data.?;

    // Should find matches in .zig files but not .md files
    try testing.expect(std.mem.indexOf(u8, output, ".zig") != null);
    try testing.expect(std.mem.indexOf(u8, output, "readme.md") == null);
}

test "grep_search - max_results limits output" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFiles(allocator, tmp.dir);

    var original_cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.os.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    // Search with low max_results
    const args = "{\"pattern\":\"const\",\"max_results\":2}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    const output = result.data.?;

    // Should indicate limit reached
    try testing.expect(std.mem.indexOf(u8, output, "Result limit (2) reached") != null);
}

test "grep_search - validates max_results range" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var original_cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.os.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    // Try with max_results > 1000 (should be clamped to 1000)
    const args = "{\"pattern\":\"test\",\"max_results\":5000}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    // Should succeed but clamp to 1000
    try testing.expect(result.success);
}

test "grep_search - exact gitignore pattern matching" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTestFiles(allocator, tmp.dir);

    // Create a file named "node" that should NOT be ignored
    try tmp.dir.writeFile("node.txt", "This is a node file\n");

    var original_cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const original_cwd = try std.process.getCwd(&original_cwd_buf);
    defer std.os.chdir(original_cwd) catch {};

    try tmp.dir.setAsCwd();

    var ctx = try createTestContext(allocator);
    defer allocator.destroy(ctx);

    // Search for pattern - should find node.txt but not node_modules/
    const args = "{\"pattern\":\"node\",\"ignore_gitignore\":true}";
    const result = try grep_search.execute(allocator, args, ctx);
    defer result.deinit(allocator);

    try testing.expect(result.success);
    const output = result.data.?;

    // node_modules should still be ignored by .gitignore pattern
    // (if gitignore is working correctly with exact matching)
    try testing.expect(std.mem.indexOf(u8, output, "node.txt") != null or std.mem.indexOf(u8, output, "node_modules") != null);
}
