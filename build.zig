// --- build.zig ---
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "my_tui_app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // REFLECTS REFACTORING: Define the three core modules.
    const lexer_module = b.createModule(.{
        .root_source_file = b.path("lexer.zig"),
    });

    const markdown_module = b.createModule(.{
        .root_source_file = b.path("markdown.zig"),
    });

    const ui_module = b.createModule(.{
        .root_source_file = b.path("ui.zig"),
    });

    // The markdown module depends on the lexer module.
    markdown_module.addImport("lexer", lexer_module);
    
    // The ui module depends on the main module for the App struct definition.
    // Note: This creates a small circular dependency which Zig handles gracefully.
    // ui.zig imports main.zig, and main.zig imports ui.zig.
    ui_module.addImport("main", exe.root_module);

    // The main executable imports the high-level markdown and ui modules.
    exe.root_module.addImport("markdown", markdown_module);
    exe.root_module.addImport("ui", ui_module);
    
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
