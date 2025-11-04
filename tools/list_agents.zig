// list_agents tool - List all available agents
const std = @import("std");
const ollama = @import("ollama");
const tools_module = @import("../tools.zig");
const context_module = @import("context");

const ToolDefinition = tools_module.ToolDefinition;
const ToolResult = tools_module.ToolResult;
const AppContext = context_module.AppContext;

pub fn getDefinition(allocator: std.mem.Allocator) !ToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "list_agents"),
                .description = try allocator.dupe(u8, "List all available agents and their descriptions. Agents are specialized sub-systems that can perform specific tasks with their own set of tools and capabilities."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {}
                    \\}
                ),
            },
        },
        .permission_metadata = .{
            .name = "list_agents",
            .description = "List available agents",
            .risk_level = .low, // Low risk - read-only information
            .required_scopes = &.{.system_info},
        },
        .execute = execute,
    };
}

pub fn execute(
    allocator: std.mem.Allocator,
    arguments: []const u8,
    context: *AppContext,
) !ToolResult {
    _ = arguments;
    const start_time = std.time.milliTimestamp();

    // Get agent registry from app context
    const agent_registry = context.agent_registry orelse {
        return try ToolResult.err(
            allocator,
            .internal_error,
            "Agent registry not initialized",
            start_time,
        );
    };

    // Build list of agents
    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    try writer.writeAll("Available Agents:\n\n");

    // Iterate through registry
    var iter = agent_registry.agents.iterator();
    var count: usize = 0;
    while (iter.next()) |entry| {
        const agent_def = entry.value_ptr.*;

        try writer.print("• {s}\n", .{agent_def.name});
        try writer.print("  Description: {s}\n", .{agent_def.description});

        // List allowed tools
        if (agent_def.capabilities.allowed_tools.len > 0) {
            try writer.writeAll("  Tools: ");
            for (agent_def.capabilities.allowed_tools, 0..) |tool, idx| {
                if (idx > 0) try writer.writeAll(", ");
                try writer.print("{s}", .{tool});
            }
            try writer.writeAll("\n");
        } else {
            try writer.writeAll("  Tools: (none)\n");
        }

        try writer.writeAll("\n");
        count += 1;
    }

    if (count == 0) {
        try writer.writeAll("No agents available. Use the agent builder (Ctrl+A) to create one!\n");
    } else {
        try writer.print("Total: {d} agent{s}\n", .{ count, if (count == 1) "" else "s" });
        try writer.writeAll("\nUse 'run_agent(agent=\"name\", task=\"...\")' to execute an agent.\n");
    }

    const output_slice = try output.toOwnedSlice(allocator);
    defer allocator.free(output_slice);  // Free after ToolResult.ok() dups it

    return try ToolResult.ok(
        allocator,
        output_slice,
        start_time,
        null,
    );
}
