// Test program to verify task tools work correctly
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

    std.debug.print("\n=== Testing Task Management Tools ===\n\n", .{});

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

    // Test 1: Add a task
    std.debug.print("Test 1: Adding a task...\n", .{});
    const add_task_args = "{\n  \"content\": \"Implement user authentication\"\n}";
    const add_tool_call = ollama.ToolCall{
        .id = "test_1",
        .type = "function",
        .function = .{
            .name = "add_task",
            .arguments = add_task_args,
        },
    };

    var add_result = try tools_module.executeToolCall(allocator, add_tool_call, &app_context);
    defer add_result.deinit(allocator);

    if (add_result.success) {
        std.debug.print("✅ Success: {s}\n", .{add_result.data.?});
    } else {
        std.debug.print("❌ Failed: {s}\n", .{add_result.error_message.?});
        return error.TestFailed;
    }

    // Test 2: List tasks
    std.debug.print("\nTest 2: Listing tasks...\n", .{});
    const list_task_args = "{}";
    const list_tool_call = ollama.ToolCall{
        .id = "test_2",
        .type = "function",
        .function = .{
            .name = "list_tasks",
            .arguments = list_task_args,
        },
    };

    var list_result = try tools_module.executeToolCall(allocator, list_tool_call, &app_context);
    defer list_result.deinit(allocator);

    if (list_result.success) {
        std.debug.print("✅ Success:\n{s}\n", .{list_result.data.?});
    } else {
        std.debug.print("❌ Failed: {s}\n", .{list_result.error_message.?});
        return error.TestFailed;
    }

    // Test 3: Update task status
    std.debug.print("\nTest 3: Updating task status...\n", .{});
    const update_task_args = "{\n  \"task_id\": \"task_1\",\n  \"status\": \"in_progress\"\n}";
    const update_tool_call = ollama.ToolCall{
        .id = "test_3",
        .type = "function",
        .function = .{
            .name = "update_task",
            .arguments = update_task_args,
        },
    };

    var update_result = try tools_module.executeToolCall(allocator, update_tool_call, &app_context);
    defer update_result.deinit(allocator);

    if (update_result.success) {
        std.debug.print("✅ Success: {s}\n", .{update_result.data.?});
    } else {
        std.debug.print("❌ Failed: {s}\n", .{update_result.error_message.?});
        return error.TestFailed;
    }

    // Test 4: List tasks again to verify update
    std.debug.print("\nTest 4: Verifying task update...\n", .{});
    var list_result2 = try tools_module.executeToolCall(allocator, list_tool_call, &app_context);
    defer list_result2.deinit(allocator);

    if (list_result2.success) {
        std.debug.print("✅ Success:\n{s}\n", .{list_result2.data.?});
    } else {
        std.debug.print("❌ Failed: {s}\n", .{list_result2.error_message.?});
        return error.TestFailed;
    }

    // Test 5: Add another task
    std.debug.print("\nTest 5: Adding another task...\n", .{});
    const add_task_args2 = "{\n  \"content\": \"Write documentation\"\n}";
    const add_tool_call2 = ollama.ToolCall{
        .id = "test_5",
        .type = "function",
        .function = .{
            .name = "add_task",
            .arguments = add_task_args2,
        },
    };

    var add_result2 = try tools_module.executeToolCall(allocator, add_tool_call2, &app_context);
    defer add_result2.deinit(allocator);

    if (add_result2.success) {
        std.debug.print("✅ Success: {s}\n", .{add_result2.data.?});
    } else {
        std.debug.print("❌ Failed: {s}\n", .{add_result2.error_message.?});
        return error.TestFailed;
    }

    // Test 6: Final list
    std.debug.print("\nTest 6: Final task list...\n", .{});
    var list_result3 = try tools_module.executeToolCall(allocator, list_tool_call, &app_context);
    defer list_result3.deinit(allocator);

    if (list_result3.success) {
        std.debug.print("✅ Success:\n{s}\n", .{list_result3.data.?});
    } else {
        std.debug.print("❌ Failed: {s}\n", .{list_result3.error_message.?});
        return error.TestFailed;
    }

    std.debug.print("\n=== All Tests Passed! ===\n\n", .{});
}
