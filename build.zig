// --- build.zig ---
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zodollama",
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

    // UI module - will be updated after app_module is created
    const ui_module = b.createModule(.{
        .root_source_file = b.path("ui.zig"),
    });

    // New modular architecture modules
    const ollama_module = b.createModule(.{
        .root_source_file = b.path("ollama.zig"),
    });

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

    const context_module = b.createModule(.{
        .root_source_file = b.path("context.zig"),
    });
    context_module.addImport("state", state_module);
    context_module.addImport("config", config_module);

    const tools_module = b.createModule(.{
        .root_source_file = b.path("tools.zig"),
    });
    tools_module.addImport("ollama", ollama_module);
    tools_module.addImport("permission", permission_module);
    tools_module.addImport("context", context_module);
    tools_module.addImport("state", state_module);

    // New refactored modules
    const types_module = b.createModule(.{
        .root_source_file = b.path("types.zig"),
    });
    types_module.addImport("markdown", markdown_module);
    types_module.addImport("ollama", ollama_module);
    types_module.addImport("permission", permission_module);

    const render_module = b.createModule(.{
        .root_source_file = b.path("render.zig"),
    });
    render_module.addImport("ui", ui_module);
    render_module.addImport("markdown", markdown_module);
    render_module.addImport("types", types_module);

    const app_module = b.createModule(.{
        .root_source_file = b.path("app.zig"),
    });
    app_module.addImport("ui", ui_module);
    app_module.addImport("markdown", markdown_module);
    app_module.addImport("ollama", ollama_module);
    app_module.addImport("permission", permission_module);
    app_module.addImport("tools", tools_module);
    app_module.addImport("types", types_module);
    app_module.addImport("state", state_module);
    app_module.addImport("context", context_module);
    app_module.addImport("config", config_module);
    app_module.addImport("render", render_module);

    // UI module needs app and types (circular dependency handled by Zig)
    ui_module.addImport("app", app_module);
    ui_module.addImport("types", types_module);

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

    // Test executable for task tools
    const test_exe = b.addExecutable(.{
        .name = "test_tools",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_tools.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add imports for test executable
    test_exe.root_module.addImport("tools", tools_module);
    test_exe.root_module.addImport("state", state_module);
    test_exe.root_module.addImport("config", config_module);
    test_exe.root_module.addImport("context", context_module);
    test_exe.root_module.addImport("ollama", ollama_module);

    test_exe.linkSystemLibrary("c");
    b.installArtifact(test_exe);

    const test_run_cmd = b.addRunArtifact(test_exe);
    test_run_cmd.step.dependOn(b.getInstallStep());

    const test_step = b.step("test-tools", "Test the task management tools");
    test_step.dependOn(&test_run_cmd.step);

    // Test executable for edit_file tool
    const test_edit_exe = b.addExecutable(.{
        .name = "test_edit_file",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_edit_file.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add imports for test_edit_file executable
    test_edit_exe.root_module.addImport("tools", tools_module);
    test_edit_exe.root_module.addImport("state", state_module);
    test_edit_exe.root_module.addImport("config", config_module);
    test_edit_exe.root_module.addImport("context", context_module);
    test_edit_exe.root_module.addImport("ollama", ollama_module);

    test_edit_exe.linkSystemLibrary("c");
    b.installArtifact(test_edit_exe);

    const test_edit_run_cmd = b.addRunArtifact(test_edit_exe);
    test_edit_run_cmd.step.dependOn(b.getInstallStep());

    const test_edit_step = b.step("test-edit", "Test the edit_file tool");
    test_edit_step.dependOn(&test_edit_run_cmd.step);
}
