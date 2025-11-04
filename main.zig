// Local Harness - Terminal chat interface for Ollama and LM Studio
const std = @import("std");
const ui = @import("ui");
const markdown = @import("markdown");
const config_module = @import("config");
const app_module = @import("app");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var config = try config_module.loadConfigFromFile(allocator);
    // Note: Config ownership is transferred to App - App.deinit() will free it

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    // CLI flags override config file
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\Local Harness - Terminal chat interface for Ollama and LM Studio
                \\
                \\Usage: localharness [OPTIONS]
                \\
                \\Options:
                \\  --ollama-host <URL>    Ollama server URL (default: http://localhost:11434)
                \\  --model <NAME>         Model to use (default: from config file)
                \\  --help, -h             Show this help message
                \\
                \\Configuration:
                \\  Config file: ~/.config/localharness/config.json
                \\
                \\Controls:
                \\  Scroll Wheel     Scroll through messages
                \\  Shift+Click      Highlight and copy text
                \\
            , .{});
            return;
        } else if (std.mem.eql(u8, arg, "--ollama-host")) {
            if (args.next()) |host| {
                allocator.free(config.ollama_host);
                config.ollama_host = try allocator.dupe(u8, host);
            } else {
                std.debug.print("Error: --ollama-host flag requires a URL argument.\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, arg, "--model")) {
            if (args.next()) |model| {
                allocator.free(config.model);
                config.model = try allocator.dupe(u8, model);
            } else {
                std.debug.print("Error: --model flag requires a model name argument.\n", .{});
                return;
            }
        }
    }

    var app = app_module.App.init(allocator, config) catch |err| {
        std.debug.print("Application initialization failed: {s}\n", .{@errorName(err)});
        return;
    };
    // CRITICAL: Fix context pointers after app is in final location
    app.fixContextPointers();
    defer app.deinit();

    // Initialize color configuration for markdown and UI AFTER app is created
    // This ensures the global pointers point to app.config (which lives for the entire program)
    // instead of the stack-allocated config variable (which would be freed by app.deinit)
    markdown.initColors(app.config.color_inline_code_bg);
    ui.initUIColors(app.config.color_status);

    // Wait 5 seconds to allow reviewing initialization messages before TUI takes over
    std.debug.print("\nStarting UI in 5 seconds...\n", .{});
    std.Thread.sleep(5 * std.time.ns_per_s);

    var app_tui = ui.Tui{ .orig_termios = undefined };
    try app_tui.enableRawMode();
    defer app_tui.disableRawMode();

    try app.run(&app_tui);
}
