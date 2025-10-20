// Example: Tool calling with Ollama
// This demonstrates how to use function/tool calling with your Ollama setup

const std = @import("std");
const ollama = @import("ollama.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize Ollama client
    var client = ollama.OllamaClient.init(allocator, "http://localhost:11434", "/api/chat");
    defer client.deinit();

    // Define tools that the model can call
    // Tool 1: Get weather information
    const get_weather_tool = ollama.Tool{
        .type = "function",
        .function = .{
            .name = "get_weather",
            .description = "Get the current weather for a location",
            .parameters =
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "location": {
                \\      "type": "string",
                \\      "description": "The city and state, e.g. San Francisco, CA"
                \\    },
                \\    "unit": {
                \\      "type": "string",
                \\      "enum": ["celsius", "fahrenheit"],
                \\      "description": "The temperature unit"
                \\    }
                \\  },
                \\  "required": ["location"]
                \\}
            ,
        },
    };

    // Tool 2: Execute a shell command
    const execute_command_tool = ollama.Tool{
        .type = "function",
        .function = .{
            .name = "execute_command",
            .description = "Execute a shell command and return the output",
            .parameters =
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "command": {
                \\      "type": "string",
                \\      "description": "The shell command to execute"
                \\    },
                \\    "working_directory": {
                \\      "type": "string",
                \\      "description": "Optional working directory for the command"
                \\    }
                \\  },
                \\  "required": ["command"]
                \\}
            ,
        },
    };

    // Tool 3: Read a file
    const read_file_tool = ollama.Tool{
        .type = "function",
        .function = .{
            .name = "read_file",
            .description = "Read the contents of a file",
            .parameters =
                \\{
                \\  "type": "object",
                \\  "properties": {
                \\    "path": {
                \\      "type": "string",
                \\      "description": "The path to the file to read"
                \\    }
                \\  },
                \\  "required": ["path"]
                \\}
            ,
        },
    };

    const tools = [_]ollama.Tool{ get_weather_tool, execute_command_tool, read_file_tool };

    // Create initial conversation
    var messages = std.ArrayListUnmanaged(ollama.ChatMessage){};
    defer messages.deinit(allocator);

    // Add user message asking about weather
    try messages.append(allocator, .{
        .role = "user",
        .content = "What's the weather like in San Francisco? Also, what's the current date?",
    });

    std.debug.print("User: {s}\n\n", .{messages.items[0].content});

    // Callback to handle streaming responses
    const Context = struct {
        allocator: std.mem.Allocator,
        tool_calls: ?[]const ollama.ToolCall = null,
        content: std.ArrayListUnmanaged(u8),

        fn callback(ctx: *@This(), thinking: ?[]const u8, content: ?[]const u8, tool_calls: ?[]const ollama.ToolCall) void {
            if (thinking) |t| {
                std.debug.print("[Thinking: {s}]", .{t});
            }
            if (content) |c| {
                std.debug.print("{s}", .{c});
                ctx.content.appendSlice(ctx.allocator, c) catch {};
            }
            if (tool_calls) |tc| {
                // Store tool calls for later processing
                // Note: In a real implementation, you'd need to properly allocate and copy these
                ctx.tool_calls = tc;
                std.debug.print("\n[Model requested tool calls]\n", .{});
            }
        }
    };

    var ctx = Context{
        .allocator = allocator,
        .content = std.ArrayListUnmanaged(u8){},
    };
    defer ctx.content.deinit(allocator);

    std.debug.print("Assistant: ", .{});

    // Make streaming request with tools
    try client.chatStream(
        "llama3.2", // or your model like "gpt-oss-120b"
        messages.items,
        false, // thinking
        null, // format
        &tools, // Pass tools array
        &ctx,
        Context.callback,
    );

    std.debug.print("\n\n", .{});

    // Add assistant's response to conversation
    try messages.append(allocator, .{
        .role = "assistant",
        .content = try ctx.content.toOwnedSlice(allocator),
        // Note: tool_calls are stored separately and processed below
    });

    // If the model requested tool calls, execute them and continue conversation
    if (ctx.tool_calls) |tool_calls| {
        std.debug.print("=== Executing Tool Calls ===\n", .{});

        for (tool_calls) |tool_call| {
            std.debug.print("\nTool: {s}\n", .{tool_call.function.name});
            std.debug.print("Arguments: {s}\n", .{tool_call.function.arguments});

            // Execute the tool (simplified example)
            const tool_result = try executeToolCall(allocator, tool_call);
            defer allocator.free(tool_result);

            std.debug.print("Result: {s}\n", .{tool_result});

            // Add tool result to conversation
            try messages.append(allocator, .{
                .role = "tool",
                .content = tool_result,
                .tool_call_id = tool_call.id,
            });
        }

        // Make another request with tool results
        std.debug.print("\n=== Model Processing Tool Results ===\n", .{});
        std.debug.print("Assistant: ", .{});

        var ctx2 = Context{
            .allocator = allocator,
            .content = std.ArrayListUnmanaged(u8){},
        };
        defer ctx2.content.deinit(allocator);

        try client.chatStream(
            "llama3.2",
            messages.items,
            false,
            null,
            &tools,
            &ctx2,
            Context.callback,
        );

        std.debug.print("\n\n", .{});
    }
}

// Simplified tool execution (you'd implement actual logic here)
fn executeToolCall(allocator: std.mem.Allocator, tool_call: ollama.ToolCall) ![]const u8 {
    if (std.mem.eql(u8, tool_call.function.name, "get_weather")) {
        // Parse arguments and return mock weather data
        return try allocator.dupe(u8,
            \\{"temperature": 68, "condition": "sunny", "humidity": 45}
        );
    } else if (std.mem.eql(u8, tool_call.function.name, "execute_command")) {
        // Parse command from arguments JSON
        const args = try std.json.parseFromSlice(
            struct { command: []const u8 },
            allocator,
            tool_call.function.arguments,
            .{},
        );
        defer args.deinit();

        // Execute command (be careful in production!)
        var child = std.process.Child.init(&.{ "sh", "-c", args.value.command }, allocator);
        child.stdout_behavior = .Pipe;
        try child.spawn();

        const output = try child.stdout.?.readToEndAlloc(allocator, 10 * 1024);
        _ = try child.wait();

        return output;
    } else if (std.mem.eql(u8, tool_call.function.name, "read_file")) {
        // Parse path from arguments and read file
        const args = try std.json.parseFromSlice(
            struct { path: []const u8 },
            allocator,
            tool_call.function.arguments,
            .{},
        );
        defer args.deinit();

        const file = try std.fs.cwd().openFile(args.value.path, .{});
        defer file.close();

        return try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    }

    return try allocator.dupe(u8, "{}");
}
