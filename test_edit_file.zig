// Test program to verify edit_file tool works correctly
const std = @import("std");
const tools_module = @import("tools.zig");
const state_module = @import("state.zig");
const config_module = @import("config.zig");
const context_module = @import("context.zig");
const ollama = @import("ollama.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Testing Edit File Tool ===\n\n", .{});

    // Initialize app state
    var app_state = state_module.AppState.init(allocator);
    defer app_state.deinit();

    // Create a dummy config
    const config = config_module.Config{
        .model = "test",
        .ollama_host = "http://localhost:11434",
        .ollama_endpoint = "/api/chat",
        .editor = &.{"vim"},
        .scroll_lines = 3,
        .color_status = "\x1b[33m",
        .color_link = "\x1b[36m",
        .color_thinking_header = "\x1b[36m",
        .color_thinking_dim = "\x1b[2m",
        .color_inline_code_bg = "\x1b[48;5;237m",
    };

    // Create app context
    var app_context = context_module.AppContext{
        .allocator = allocator,
        .config = &config,
        .state = &app_state,
    };

    // Create a test file
    const test_file_path = "test_edit_target.txt";
    const original_content = "Hello, World!\nThis is line 2.\nGoodbye!";

    std.debug.print("Creating test file: {s}\n", .{test_file_path});
    {
        const file = try std.fs.cwd().createFile(test_file_path, .{});
        defer file.close();
        try file.writeAll(original_content);
    }
    defer std.fs.cwd().deleteFile(test_file_path) catch {};

    std.debug.print("Original content:\n{s}\n\n", .{original_content});

    // Test 1: Try to edit WITHOUT reading first (should fail)
    std.debug.print("Test 1: Editing without reading first (should fail)...\n", .{});
    const edit_args_no_read =
        \\{
        \\  "path": "test_edit_target.txt",
        \\  "old_string": "World",
        \\  "new_string": "Zig"
        \\}
    ;

    const edit_call_no_read = ollama.ToolCall{
        .id = "test_1",
        .type = "function",
        .function = .{
            .name = "edit_file",
            .arguments = edit_args_no_read,
        },
    };

    var result1 = try tools_module.executeToolCall(allocator, edit_call_no_read, &app_context);
    defer result1.deinit(allocator);

    if (!result1.success and result1.error_type == .permission_denied) {
        std.debug.print("✅ Correctly rejected: {s}\n\n", .{result1.error_message.?});
    } else {
        std.debug.print("❌ FAILED: Should have been rejected!\n\n", .{});
        return error.TestFailed;
    }

    // Test 2: Read the file first
    std.debug.print("Test 2: Reading file first...\n", .{});
    const read_args =
        \\{
        \\  "path": "test_edit_target.txt"
        \\}
    ;

    const read_call = ollama.ToolCall{
        .id = "test_2",
        .type = "function",
        .function = .{
            .name = "read_file",
            .arguments = read_args,
        },
    };

    var result2 = try tools_module.executeToolCall(allocator, read_call, &app_context);
    defer result2.deinit(allocator);

    if (result2.success) {
        std.debug.print("✅ File read successfully\n\n", .{});
    } else {
        std.debug.print("❌ FAILED to read: {s}\n\n", .{result2.error_message.?});
        return error.TestFailed;
    }

    // Test 3: Now edit should work
    std.debug.print("Test 3: Editing after reading (should succeed)...\n", .{});
    const edit_args =
        \\{
        \\  "path": "test_edit_target.txt",
        \\  "old_string": "World",
        \\  "new_string": "Zig"
        \\}
    ;

    const edit_call = ollama.ToolCall{
        .id = "test_3",
        .type = "function",
        .function = .{
            .name = "edit_file",
            .arguments = edit_args,
        },
    };

    var result3 = try tools_module.executeToolCall(allocator, edit_call, &app_context);
    defer result3.deinit(allocator);

    if (result3.success) {
        std.debug.print("✅ Edit successful: {s}\n", .{result3.data.?});
    } else {
        std.debug.print("❌ FAILED to edit: {s}\n", .{result3.error_message.?});
        std.debug.print("Error type: {s}\n\n", .{@tagName(result3.error_type)});
        return error.TestFailed;
    }

    // Verify the edit
    const file = try std.fs.cwd().openFile(test_file_path, .{});
    defer file.close();
    const new_content = try file.readToEndAlloc(allocator, 1024);
    defer allocator.free(new_content);

    std.debug.print("New content:\n{s}\n\n", .{new_content});

    if (std.mem.indexOf(u8, new_content, "Zig") != null) {
        std.debug.print("✅ Content was modified correctly\n", .{});
    } else {
        std.debug.print("❌ Content was NOT modified!\n", .{});
        return error.TestFailed;
    }

    // Test 4: Try editing with non-unique string (should fail)
    std.debug.print("\nTest 4: Editing with non-unique string (should fail)...\n", .{});

    // First, create content with duplicates
    const dup_content = "foo bar foo";
    {
        const dup_file = try std.fs.cwd().createFile(test_file_path, .{});
        defer dup_file.close();
        try dup_file.writeAll(dup_content);
    }

    // Read it first
    var result4a = try tools_module.executeToolCall(allocator, read_call, &app_context);
    defer result4a.deinit(allocator);

    const edit_args_dup =
        \\{
        \\  "path": "test_edit_target.txt",
        \\  "old_string": "foo",
        \\  "new_string": "baz"
        \\}
    ;

    const edit_call_dup = ollama.ToolCall{
        .id = "test_4",
        .type = "function",
        .function = .{
            .name = "edit_file",
            .arguments = edit_args_dup,
        },
    };

    var result4 = try tools_module.executeToolCall(allocator, edit_call_dup, &app_context);
    defer result4.deinit(allocator);

    if (!result4.success and result4.error_type == .validation_failed) {
        std.debug.print("✅ Correctly rejected non-unique string: {s}\n", .{result4.error_message.?});
    } else {
        std.debug.print("❌ FAILED: Should have rejected non-unique string!\n", .{});
        return error.TestFailed;
    }

    // Test 5: Try with replace_all=true
    std.debug.print("\nTest 5: Using replace_all=true for multiple occurrences...\n", .{});

    const edit_args_all =
        \\{
        \\  "path": "test_edit_target.txt",
        \\  "old_string": "foo",
        \\  "new_string": "baz",
        \\  "replace_all": true
        \\}
    ;

    const edit_call_all = ollama.ToolCall{
        .id = "test_5",
        .type = "function",
        .function = .{
            .name = "edit_file",
            .arguments = edit_args_all,
        },
    };

    var result5 = try tools_module.executeToolCall(allocator, edit_call_all, &app_context);
    defer result5.deinit(allocator);

    if (result5.success) {
        std.debug.print("✅ Replace all successful: {s}\n", .{result5.data.?});

        // Verify both were replaced
        const verify_file = try std.fs.cwd().openFile(test_file_path, .{});
        defer verify_file.close();
        const verify_content = try verify_file.readToEndAlloc(allocator, 1024);
        defer allocator.free(verify_content);

        const expected = "baz bar baz";
        if (std.mem.eql(u8, verify_content, expected)) {
            std.debug.print("✅ Both occurrences were replaced\n", .{});
        } else {
            std.debug.print("❌ Unexpected content: {s}\n", .{verify_content});
            return error.TestFailed;
        }
    } else {
        std.debug.print("❌ FAILED: {s}\n", .{result5.error_message.?});
        return error.TestFailed;
    }

    std.debug.print("\n=== All Edit File Tests Passed! ===\n\n", .{});
}
