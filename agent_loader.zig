// Agent Loader - Discovers and loads markdown-defined agents
const std = @import("std");
const agents_module = @import("agents.zig");
const agent_writer = @import("agent_writer.zig");
const agent_executor = @import("agent_executor.zig");
const file_curator = @import("agents_hardcoded/file_curator.zig");

const AgentDefinition = agents_module.AgentDefinition;
const AgentRegistry = agents_module.AgentRegistry;
const AgentContext = agents_module.AgentContext;
const AgentResult = agents_module.AgentResult;
const AgentCapabilities = agents_module.AgentCapabilities;
const ProgressCallback = agents_module.ProgressCallback;

/// Loaded agent metadata (stored for execution)
pub const LoadedAgent = struct {
    config: agent_writer.AgentConfig,
    definition: AgentDefinition,
};

/// Agent loader manages discovery and loading of agents
pub const AgentLoader = struct {
    allocator: std.mem.Allocator,
    registry: *AgentRegistry,
    loaded_agents: std.ArrayListUnmanaged(LoadedAgent),
    native_agent_definitions: std.ArrayListUnmanaged(AgentDefinition),

    pub fn init(allocator: std.mem.Allocator, registry: *AgentRegistry) AgentLoader {
        return .{
            .allocator = allocator,
            .registry = registry,
            .loaded_agents = .{},
            .native_agent_definitions = .{},
        };
    }

    pub fn deinit(self: *AgentLoader) void {
        // Clean up markdown agents
        for (self.loaded_agents.items) |*loaded| {
            var cfg = &loaded.config;
            cfg.deinit(self.allocator);
        }
        self.loaded_agents.deinit(self.allocator);

        // Clean up native agent definitions (allocated strings)
        for (self.native_agent_definitions.items) |def| {
            self.allocator.free(def.name);
            self.allocator.free(def.description);
            // Note: system_prompt and tools are static for native agents
        }
        self.native_agent_definitions.deinit(self.allocator);
    }

    /// Load all agents (native + markdown)
    pub fn loadAllAgents(self: *AgentLoader) !void {
        // Clean up previously loaded markdown agents before reloading (prevents memory leaks)
        for (self.loaded_agents.items) |*loaded| {
            var cfg = &loaded.config;
            cfg.deinit(self.allocator);
        }
        self.loaded_agents.clearRetainingCapacity();

        // Clean up previously loaded native agent definitions
        for (self.native_agent_definitions.items) |def| {
            self.allocator.free(def.name);
            self.allocator.free(def.description);
        }
        self.native_agent_definitions.clearRetainingCapacity();

        // Clear existing agents in registry (prevents double-registration crashes)
        self.registry.clear();

        // Ensure agent directory exists (proactive creation for user convenience)
        const agent_dir = try agent_writer.getAgentDirectory(self.allocator);
        defer self.allocator.free(agent_dir);

        std.fs.cwd().makePath(agent_dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                std.debug.print("Warning: Failed to create agent directory {s}: {}\n", .{ agent_dir, err });
                // Continue anyway - agent loading will still work for native agents
            }
        };

        // Create README.md if it doesn't exist (one-time user guidance)
        createAgentReadmeIfNeeded(self.allocator, agent_dir) catch |err| {
            std.debug.print("Warning: Failed to create agent README: {}\n", .{err});
            // Non-fatal - just skip README creation
        };

        // Register native agents first
        try self.registerNativeAgents();

        // Then load markdown agents
        try self.loadMarkdownAgents();
    }

    /// Register built-in native Zig agents
    fn registerNativeAgents(self: *AgentLoader) !void {
        // Register file_curator (native agent with complex JSON parsing)
        const curator_def = try file_curator.getDefinition(self.allocator);
        try self.registry.register(curator_def);

        // Store definition for cleanup (name and description are allocated)
        try self.native_agent_definitions.append(self.allocator, curator_def);

        // Future native agents would be registered here
    }

    /// Load and register markdown-defined agents
    fn loadMarkdownAgents(self: *AgentLoader) !void {
        // Get list of agent files
        const agent_files = try agent_writer.listAgentFiles(self.allocator);
        defer {
            for (agent_files) |file_path| {
                self.allocator.free(file_path);
            }
            self.allocator.free(agent_files);
        }

        // Load each agent
        for (agent_files) |file_path| {
            self.loadSingleAgent(file_path) catch |err| {
                std.debug.print("Warning: Failed to load agent from {s}: {}\n", .{ file_path, err });
                continue;
            };
        }
    }

    /// Load a single markdown agent
    fn loadSingleAgent(self: *AgentLoader, file_path: []const u8) !void {
        // Parse agent config from markdown
        var config = try agent_writer.parseAgentFile(self.allocator, file_path);
        errdefer config.deinit(self.allocator);

        // Create AgentDefinition from config
        const definition = try self.createDefinitionFromConfig(&config);

        // Store loaded agent
        try self.loaded_agents.append(self.allocator, .{
            .config = config,
            .definition = definition,
        });

        // Register in registry
        try self.registry.register(definition);
    }

    /// Create AgentDefinition from markdown config
    fn createDefinitionFromConfig(self: *AgentLoader, config: *const agent_writer.AgentConfig) !AgentDefinition {
        _ = self;

        // Build capabilities
        const capabilities = AgentCapabilities{
            .allowed_tools = config.tools,
            .max_iterations = config.max_iterations orelse 25, // Default for markdown agents
            .temperature = 0.7,
            .num_ctx = null, // Use default
            .num_predict = -1,
            .enable_thinking = false,
        };

        return AgentDefinition{
            .name = config.name,
            .description = config.description,
            .system_prompt = config.system_prompt,
            .capabilities = capabilities,
            .execute = genericMarkdownAgentExecute,
        };
    }
};

/// Generic execute function for all markdown-defined agents
fn genericMarkdownAgentExecute(
    allocator: std.mem.Allocator,
    context: AgentContext,
    task: []const u8,
    progress_callback: ?ProgressCallback,
    callback_user_data: ?*anyopaque,
) !AgentResult {
    const start_time = std.time.milliTimestamp();

    // Initialize agent executor
    var executor = agent_executor.AgentExecutor.init(allocator, context.capabilities);
    defer executor.deinit();

    // Get tools that agent is allowed to use
    const tools_module = @import("tools.zig");
    const all_tools = try tools_module.getAllToolDefinitions(allocator);
    defer {
        for (all_tools) |tool| {
            allocator.free(tool.ollama_tool.function.name);
            allocator.free(tool.ollama_tool.function.description);
            allocator.free(tool.ollama_tool.function.parameters);
        }
        allocator.free(all_tools);
    }

    // Filter tools by capability
    var allowed_tools = std.ArrayListUnmanaged(@import("ollama.zig").Tool){};
    defer allowed_tools.deinit(allocator);

    for (all_tools) |tool| {
        // Check if tool is in allowed list
        for (context.capabilities.allowed_tools) |allowed_name| {
            if (std.mem.eql(u8, tool.ollama_tool.function.name, allowed_name)) {
                // Duplicate the tool for agent use
                const tool_copy = @import("ollama.zig").Tool{
                    .type = try allocator.dupe(u8, tool.ollama_tool.type),
                    .function = .{
                        .name = try allocator.dupe(u8, tool.ollama_tool.function.name),
                        .description = try allocator.dupe(u8, tool.ollama_tool.function.description),
                        .parameters = try allocator.dupe(u8, tool.ollama_tool.function.parameters),
                    },
                };
                try allowed_tools.append(allocator, tool_copy);
                break;
            }
        }
    }
    defer {
        for (allowed_tools.items) |tool| {
            allocator.free(tool.type);
            allocator.free(tool.function.name);
            allocator.free(tool.function.description);
            allocator.free(tool.function.parameters);
        }
    }

    // Run agent
    const result = executor.run(
        context,
        context.system_prompt, // From markdown definition
        task,
        allowed_tools.items,
        progress_callback,
        callback_user_data,
    ) catch |err| {
        const end_time = std.time.milliTimestamp();
        const stats = agents_module.AgentStats{
            .iterations_used = executor.iterations_used,
            .tool_calls_made = 0,
            .execution_time_ms = end_time - start_time,
        };
        const error_msg = try std.fmt.allocPrint(
            allocator,
            "Agent execution failed: {}",
            .{err},
        );
        defer allocator.free(error_msg);
        return try AgentResult.err(allocator, error_msg, stats);
    };

    return result;
}

/// Create README.md in agent directory if it doesn't exist
fn createAgentReadmeIfNeeded(allocator: std.mem.Allocator, agent_dir: []const u8) !void {
    const readme_path = try std.fs.path.join(allocator, &.{ agent_dir, "README.md" });
    defer allocator.free(readme_path);

    // Check if README already exists
    std.fs.cwd().access(readme_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            // README doesn't exist - create it
            const file = try std.fs.cwd().createFile(readme_path, .{});
            defer file.close();

            try file.writeAll(
                \\# Local Harness Agents
                \\
                \\This directory contains agent definitions for Local Harness.
                \\
                \\## What are Agents?
                \\
                \\Agents are specialized LLM sub-tasks that run in isolation with controlled capabilities.
                \\They help break down complex tasks into manageable, reusable components.
                \\
                \\## Creating a Custom Agent
                \\
                \\You can create custom agents by adding markdown files to this directory.
                \\
                \\### Agent File Format
                \\
                \\```markdown
                \\---
                \\name: my_agent
                \\description: Brief description of what this agent does
                \\tools: read_file, grep_search, write_file
                \\---
                \\
                \\You are an expert at [specific task].
                \\
                \\Your goal is to [what the agent should accomplish].
                \\
                \\Guidelines:
                \\- Be thorough and systematic
                \\- Use available tools effectively
                \\- Return clear, actionable results
                \\```
                \\
                \\### Field Descriptions
                \\
                \\- **name**: Unique identifier for the agent (lowercase, underscores allowed)
                \\- **description**: User-facing description shown in agent lists
                \\- **tools**: Comma-separated list of tools the agent can use (optional)
                \\- **system prompt**: Everything after the second `---` becomes the agent's instructions
                \\
                \\### Available Tools
                \\
                \\Common tools you can grant to agents:
                \\- `read_file` - Read file contents
                \\- `read_lines` - Read specific line ranges
                \\- `write_file` - Create or modify files
                \\- `grep_search` - Search for patterns in files
                \\- `file_tree` - Get directory structure
                \\- `replace_lines` - Replace specific lines in a file
                \\- `bash_command` - Execute shell commands (use with caution)
                \\
                \\### Example: Code Reviewer Agent
                \\
                \\```markdown
                \\---
                \\name: code_reviewer
                \\description: Reviews code for bugs, style issues, and best practices
                \\tools: read_file, grep_search
                \\---
                \\
                \\You are an expert code reviewer with deep knowledge of software engineering best practices.
                \\
                \\When reviewing code, analyze for:
                \\1. Potential bugs and edge cases
                \\2. Code style and readability
                \\3. Performance issues
                \\4. Security vulnerabilities
                \\5. Best practice violations
                \\
                \\Provide specific line numbers and actionable suggestions for improvements.
                \\```
                \\
                \\## Using Agents
                \\
                \\Once created, agents can be used in two ways:
                \\
                \\1. **Via the agent builder**: Type `/agent` in the app to create and manage agents
                \\2. **By asking the LLM**: Request "use the code_reviewer agent to review app.zig"
                \\
                \\## Built-in Agents
                \\
                \\Local Harness includes these native agents:
                \\- **file_curator**: Analyzes files and identifies important sections based on conversation context
                \\
                \\## Documentation
                \\
                \\For more information, see:
                \\- Agent architecture: See AGENT_BUILDER_IMPLEMENTATION.md in the project root
                \\- Tool reference: Type `/help` in the app
                \\
                \\## Notes
                \\
                \\- Agents run in isolation with their own message history
                \\- They cannot access tools they haven't been granted
                \\- Maximum 10 iterations per agent execution (configurable)
                \\- Agents are reloaded automatically when you save a new agent via `/agent`
                \\
            );
        } else {
            // Other error accessing the file - propagate it
            return err;
        }
    };
    // If file exists, do nothing
}
