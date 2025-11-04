// --- build.zig ---
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "localharness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Core lexer module (no dependencies)
    const lexer_module = b.createModule(.{
        .root_source_file = b.path("lexer.zig"),
    });

    // Markdown module (depends on lexer)
    const markdown_module = b.createModule(.{
        .root_source_file = b.path("markdown.zig"),
    });
    markdown_module.addImport("lexer", lexer_module);

    // Tree utility module (shared by ui and tools)
    const tree_module = b.createModule(.{
        .root_source_file = b.path("tools/tree.zig"),
    });

    // UI module - will be updated after app_module is created
    const ui_module = b.createModule(.{
        .root_source_file = b.path("ui.zig"),
    });
    ui_module.addImport("tree", tree_module);

    // New modular architecture modules
    const ollama_module = b.createModule(.{
        .root_source_file = b.path("ollama.zig"),
    });

    const lmstudio_module = b.createModule(.{
        .root_source_file = b.path("lmstudio.zig"),
    });
    lmstudio_module.addImport("ollama", ollama_module);

    const embeddings_module = b.createModule(.{
        .root_source_file = b.path("embeddings.zig"),
    });

    const zvdb_module = b.createModule(.{
        .root_source_file = b.path("zvdb/src/zvdb.zig"),
    });

    const embedder_interface_module = b.createModule(.{
        .root_source_file = b.path("embedder_interface.zig"),
    });
    embedder_interface_module.addImport("embeddings", embeddings_module);
    embedder_interface_module.addImport("lmstudio", lmstudio_module);

    const llm_provider_module = b.createModule(.{
        .root_source_file = b.path("llm_provider.zig"),
    });
    llm_provider_module.addImport("ollama", ollama_module);
    llm_provider_module.addImport("lmstudio", lmstudio_module);
    llm_provider_module.addImport("embeddings", embeddings_module);

    const permission_module = b.createModule(.{
        .root_source_file = b.path("permission.zig"),
    });
    permission_module.addImport("ollama", ollama_module);

    const state_module = b.createModule(.{
        .root_source_file = b.path("state.zig"),
    });

    const config_module = b.createModule(.{
        .root_source_file = b.path("config.zig"),
    });
    config_module.addImport("permission", permission_module);
    config_module.addImport("llm_provider", llm_provider_module);

    const context_module = b.createModule(.{
        .root_source_file = b.path("context.zig"),
    });
    context_module.addImport("state", state_module);
    context_module.addImport("config", config_module);
    context_module.addImport("llm_provider", llm_provider_module);
    context_module.addImport("zvdb", zvdb_module);
    context_module.addImport("embedder_interface", embedder_interface_module);
    // Will add tracking, agents, and types after they're created

    // Context management modules (NEW)
    const compression_module = b.createModule(.{
        .root_source_file = b.path("context_management/compression.zig"),
    });

    const tracking_module = b.createModule(.{
        .root_source_file = b.path("context_management/tracking.zig"),
    });

    const injection_module = b.createModule(.{
        .root_source_file = b.path("context_management/injection.zig"),
    });
    injection_module.addImport("tracking", tracking_module);

    // Agents module (needed by compressor and app)
    const agents_module = b.createModule(.{
        .root_source_file = b.path("agents.zig"),
    });
    agents_module.addImport("ollama", ollama_module);
    agents_module.addImport("llm_provider", llm_provider_module);
    agents_module.addImport("config", config_module);
    agents_module.addImport("zvdb", zvdb_module);
    agents_module.addImport("embedder_interface", embedder_interface_module);
    // Will add tools after it's created

    const compressor_module = b.createModule(.{
        .root_source_file = b.path("context_management/compressor.zig"),
    });
    compressor_module.addImport("tracking", tracking_module);
    compressor_module.addImport("compression", compression_module);
    compressor_module.addImport("agents", agents_module);

    // Now add tracking and agents to context_module
    context_module.addImport("tracking", tracking_module);
    context_module.addImport("agents", agents_module);

    const tools_module = b.createModule(.{
        .root_source_file = b.path("tools.zig"),
    });
    tools_module.addImport("ollama", ollama_module);
    tools_module.addImport("permission", permission_module);
    tools_module.addImport("context", context_module);
    tools_module.addImport("state", state_module);
    tools_module.addImport("injection", injection_module);
    tools_module.addImport("tracking", tracking_module);
    tools_module.addImport("agents", agents_module);
    tools_module.addImport("tree", tree_module);
    // Will add file_curator and types after they're created

    // Now that tools_module is created, add it to agents_module
    agents_module.addImport("tools", tools_module);

    // Now add tools to agents (circular dependency is OK with modules)
    agents_module.addImport("tools", tools_module);

    // Tool executor module (manages async tool execution with permissions)
    const tool_executor_module = b.createModule(.{
        .root_source_file = b.path("tool_executor.zig"),
    });
    tool_executor_module.addImport("ollama", ollama_module);
    tool_executor_module.addImport("permission", permission_module);
    tool_executor_module.addImport("tools", tools_module);
    tool_executor_module.addImport("markdown", markdown_module);
    tool_executor_module.addImport("context", context_module);

    // UI state modules (need to be after tools_module)
    const config_editor_state_module = b.createModule(.{
        .root_source_file = b.path("config_editor_state.zig"),
    });
    config_editor_state_module.addImport("config", config_module);
    config_editor_state_module.addImport("llm_provider", llm_provider_module);

    const agent_builder_state_module = b.createModule(.{
        .root_source_file = b.path("agent_builder_state.zig"),
    });
    agent_builder_state_module.addImport("tools", tools_module);

    const help_state_module = b.createModule(.{
        .root_source_file = b.path("help_state.zig"),
    });

    // UI helper modules (renderer + input for each state)
    const config_editor_renderer_module = b.createModule(.{
        .root_source_file = b.path("config_editor_renderer.zig"),
    });
    config_editor_renderer_module.addImport("config_editor_state", config_editor_state_module);
    config_editor_renderer_module.addImport("ui", ui_module);
    config_editor_renderer_module.addImport("llm_provider", llm_provider_module);

    const config_editor_input_module = b.createModule(.{
        .root_source_file = b.path("config_editor_input.zig"),
    });
    config_editor_input_module.addImport("config_editor_state", config_editor_state_module);
    config_editor_input_module.addImport("llm_provider", llm_provider_module);

    const agent_builder_renderer_module = b.createModule(.{
        .root_source_file = b.path("agent_builder_renderer.zig"),
    });
    agent_builder_renderer_module.addImport("agent_builder_state", agent_builder_state_module);
    agent_builder_renderer_module.addImport("ui", ui_module);

    const agent_builder_input_module = b.createModule(.{
        .root_source_file = b.path("agent_builder_input.zig"),
    });
    agent_builder_input_module.addImport("agent_builder_state", agent_builder_state_module);
    // Will add agent_writer after it's created

    const help_renderer_module = b.createModule(.{
        .root_source_file = b.path("help_renderer.zig"),
    });
    help_renderer_module.addImport("help_state", help_state_module);
    help_renderer_module.addImport("ui", ui_module);

    const help_input_module = b.createModule(.{
        .root_source_file = b.path("help_input.zig"),
    });
    help_input_module.addImport("help_state", help_state_module);

    // Agent system modules
    const llm_helper_module = b.createModule(.{
        .root_source_file = b.path("llm_helper.zig"),
    });
    llm_helper_module.addImport("ollama", ollama_module);
    llm_helper_module.addImport("llm_provider", llm_provider_module);

    const agent_writer_module = b.createModule(.{
        .root_source_file = b.path("agent_writer.zig"),
    });

    // Now add agent_writer to agent_builder_input
    agent_builder_input_module.addImport("agent_writer", agent_writer_module);

    const agent_executor_module = b.createModule(.{
        .root_source_file = b.path("agent_executor.zig"),
    });
    agent_executor_module.addImport("ollama", ollama_module);
    agent_executor_module.addImport("llm_helper", llm_helper_module);
    agent_executor_module.addImport("tools", tools_module);
    agent_executor_module.addImport("context", context_module);
    // Will add app after app_module is created

    const file_curator_module = b.createModule(.{
        .root_source_file = b.path("agents_hardcoded/file_curator.zig"),
    });
    file_curator_module.addImport("agent_executor", agent_executor_module);
    file_curator_module.addImport("llm_helper", llm_helper_module);
    file_curator_module.addImport("ollama", ollama_module);
    // Will add app after app_module is created

    // Now add file_curator to tools_module
    tools_module.addImport("file_curator", file_curator_module);

    const compression_agent_module = b.createModule(.{
        .root_source_file = b.path("agents_hardcoded/compression_agent.zig"),
    });
    compression_agent_module.addImport("agent_executor", agent_executor_module);
    compression_agent_module.addImport("tools", tools_module);
    // Will add app after app_module is created

    const agent_loader_module = b.createModule(.{
        .root_source_file = b.path("agent_loader.zig"),
    });
    agent_loader_module.addImport("agent_writer", agent_writer_module);
    agent_loader_module.addImport("agent_executor", agent_executor_module);
    agent_loader_module.addImport("file_curator", file_curator_module);
    agent_loader_module.addImport("compression_agent", compression_agent_module);
    agent_loader_module.addImport("tools", tools_module);
    agent_loader_module.addImport("ollama", ollama_module);
    // Will add app after app_module is created

    const message_renderer_module = b.createModule(.{
        .root_source_file = b.path("message_renderer.zig"),
    });
    message_renderer_module.addImport("ui", ui_module);
    message_renderer_module.addImport("markdown", markdown_module);
    // Will add render, types and app after they're created

    // New refactored modules
    const types_module = b.createModule(.{
        .root_source_file = b.path("types.zig"),
    });
    types_module.addImport("markdown", markdown_module);
    types_module.addImport("ollama", ollama_module);
    types_module.addImport("permission", permission_module);

    // Now add types to context_module, message_renderer, and tools
    context_module.addImport("types", types_module);
    message_renderer_module.addImport("types", types_module);
    tools_module.addImport("types", types_module);
    tools_module.addImport("compression", compression_module);

    const render_module = b.createModule(.{
        .root_source_file = b.path("render.zig"),
    });
    render_module.addImport("ui", ui_module);
    render_module.addImport("markdown", markdown_module);
    render_module.addImport("types", types_module);

    // Now add render to message_renderer_module
    message_renderer_module.addImport("render", render_module);
    // Will add app to message_renderer after app_module is created

    const app_module = b.createModule(.{
        .root_source_file = b.path("app.zig"),
    });
    app_module.addImport("ui", ui_module);
    app_module.addImport("markdown", markdown_module);
    app_module.addImport("ollama", ollama_module);
    app_module.addImport("lmstudio", lmstudio_module);
    app_module.addImport("embeddings", embeddings_module);
    app_module.addImport("zvdb", zvdb_module);
    app_module.addImport("embedder_interface", embedder_interface_module);
    app_module.addImport("llm_provider", llm_provider_module);
    app_module.addImport("permission", permission_module);
    app_module.addImport("tools", tools_module);
    app_module.addImport("tool_executor", tool_executor_module);
    app_module.addImport("types", types_module);
    app_module.addImport("state", state_module);
    app_module.addImport("config_editor_state", config_editor_state_module);
    app_module.addImport("config_editor_renderer", config_editor_renderer_module);
    app_module.addImport("config_editor_input", config_editor_input_module);
    app_module.addImport("agent_builder_state", agent_builder_state_module);
    app_module.addImport("agent_builder_renderer", agent_builder_renderer_module);
    app_module.addImport("agent_builder_input", agent_builder_input_module);
    app_module.addImport("help_state", help_state_module);
    app_module.addImport("help_renderer", help_renderer_module);
    app_module.addImport("help_input", help_input_module);
    app_module.addImport("context", context_module);
    app_module.addImport("config", config_module);
    app_module.addImport("render", render_module);
    app_module.addImport("compression", compression_module);
    app_module.addImport("tracking", tracking_module);
    app_module.addImport("injection", injection_module);
    app_module.addImport("compressor", compressor_module);
    app_module.addImport("agents", agents_module);
    app_module.addImport("agent_loader", agent_loader_module);
    app_module.addImport("agent_writer", agent_writer_module);
    app_module.addImport("agent_executor", agent_executor_module);
    app_module.addImport("message_renderer", message_renderer_module);
    app_module.addImport("llm_helper", llm_helper_module);

    // Now add app and types to agents and agent modules (circular dependency is OK with modules)
    agents_module.addImport("app", app_module);
    agents_module.addImport("types", types_module);
    agent_executor_module.addImport("app", app_module);
    file_curator_module.addImport("app", app_module);
    compression_agent_module.addImport("app", app_module);
    agent_loader_module.addImport("app", app_module);
    message_renderer_module.addImport("app", app_module);

    // UI module needs app, types, permission, markdown and state modules (circular dependency handled by Zig)
    ui_module.addImport("app", app_module);
    ui_module.addImport("types", types_module);
    ui_module.addImport("permission", permission_module);
    ui_module.addImport("markdown", markdown_module);
    ui_module.addImport("config_editor_state", config_editor_state_module);
    ui_module.addImport("agent_builder_state", agent_builder_state_module);
    ui_module.addImport("help_state", help_state_module);

    // Main executable imports
    exe.root_module.addImport("ui", ui_module);
    exe.root_module.addImport("markdown", markdown_module);
    exe.root_module.addImport("ollama", ollama_module);
    exe.root_module.addImport("permission", permission_module);
    exe.root_module.addImport("tools", tools_module);
    exe.root_module.addImport("types", types_module);
    exe.root_module.addImport("state", state_module);
    exe.root_module.addImport("context", context_module);
    exe.root_module.addImport("config", config_module);
    exe.root_module.addImport("render", render_module);
    exe.root_module.addImport("app", app_module);
    exe.root_module.addImport("compression", compression_module);
    exe.root_module.addImport("tracking", tracking_module);
    exe.root_module.addImport("injection", injection_module);
    exe.root_module.addImport("compressor", compressor_module);

    // Link system C library
    exe.linkSystemLibrary("c");
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);
}
