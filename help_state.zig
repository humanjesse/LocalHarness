const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

pub const HelpState = struct {
    allocator: Allocator,
    scroll_offset: usize,
    content_lines: std.ArrayListUnmanaged([]const u8),
    total_lines: usize,

    pub fn init(allocator: Allocator) !HelpState {
        var content_lines = std.ArrayListUnmanaged([]const u8){};

        // Build help content
        const help_lines = [_][]const u8{
            "",
            "SLASH COMMANDS",
            "",
            "  /help",
            "    Show this help screen with all available commands and shortcuts.",
            "",
            "  /config",
            "    Open configuration editor to modify LLM provider settings,",
            "    API keys, model parameters, and other application preferences.",
            "",
            "  /profiles",
            "    Open the interactive profile manager to create, switch, and manage",
            "    configuration profiles. Profiles let you save and switch between",
            "    different settings (API keys, models, preferences, etc.).",
            "",
            "  /profile list",
            "    List all available profiles with active profile indicator.",
            "",
            "  /profile switch <name>",
            "    Switch to a different profile and reinitialize settings.",
            "",
            "  /profile save <name>",
            "    Save current configuration as a new profile.",
            "",
            "  /profile delete <name>",
            "    Delete a profile (cannot delete active or last remaining profile).",
            "",
            "  /agents",
            "    Launch the agent builder to create custom AI agents with specific",
            "    system prompts, tools, and configurations.",
            "",
            "  /context",
            "    Generate a comprehensive context summary of your project structure",
            "    and send it to the LLM for better code understanding.",
            "",
            "  /toggle-toolcall-json",
            "    Toggle the display of raw JSON data for LLM tool calls. Useful",
            "    for debugging or understanding how the AI is using tools.",
            "",
            "  /quit",
            "    Exit the application gracefully. Same as pressing Ctrl+D.",
            "",
            "",
            "KEYBOARD SHORTCUTS",
            "",
            "  Enter",
            "    Send your message to the AI or submit the current input.",
            "",
            "  Ctrl+C",
            "    Cancel the current AI response generation. The partial response",
            "    will be discarded and you can start a new message.",
            "",
            "  Ctrl+D",
            "    Exit the application (same as /quit command).",
            "",
            "  Ctrl+O",
            "    Toggle the expansion state of the thinking block at your cursor",
            "    position. Thinking blocks show the AI's reasoning process.",
            "",
            "  Escape",
            "    Clear the input buffer without sending a message.",
            "",
            "  ↑ / ↓ (Arrow Keys)",
            "    Scroll the message view up or down by 3 lines.",
            "",
            "  Page Up / Page Down",
            "    Scroll the message view up or down more quickly.",
            "",
            "  Mouse Wheel",
            "    Scroll through messages naturally using your mouse wheel.",
            "",
            "  Home / End (in help viewer)",
            "    Jump to the top or bottom of the help content.",
            "",
            "",
            "BASIC USAGE",
            "",
            "  Starting a conversation:",
            "    Simply type your message and press Enter. The AI will respond",
            "    with assistance, code suggestions, or answers to your questions.",
            "",
            "  Using tools:",
            "    The AI can automatically use various tools like file operations,",
            "    bash commands, web searches, and more. Tool calls are displayed",
            "    inline with the conversation.",
            "",
            "  Thinking blocks:",
            "    When enabled, thinking blocks show the AI's internal reasoning.",
            "    Click or use Ctrl+O to expand/collapse them.",
            "",
            "  Configuration:",
            "    Use /config to adjust settings like LLM provider (Anthropic,",
            "    OpenAI, LM Studio), model selection, context size, and API keys.",
            "",
            "  Custom agents:",
            "    Use /agents to create specialized AI agents with custom system",
            "    prompts and tool access. Agents are saved and can be reused.",
            "",
            "",
            "DOCUMENTATION",
            "",
            "  For more detailed documentation, see:",
            "    • docs/user-guide/commands.md      - Complete command reference",
            "    • docs/user-guide/features.md      - Feature descriptions",
            "    • docs/user-guide/configuration.md - Configuration options",
            "    • docs/QUICK_START.md              - Getting started guide",
            "",
        };

        for (help_lines) |line| {
            const duped = try allocator.dupe(u8, line);
            try content_lines.append(allocator, duped);
        }

        return HelpState{
            .allocator = allocator,
            .scroll_offset = 0,
            .content_lines = content_lines,
            .total_lines = content_lines.items.len,
        };
    }

    pub fn deinit(self: *HelpState) void {
        for (self.content_lines.items) |line| {
            self.allocator.free(line);
        }
        self.content_lines.deinit(self.allocator);
    }

    pub fn scrollUp(self: *HelpState, lines: usize) void {
        if (self.scroll_offset >= lines) {
            self.scroll_offset -= lines;
        } else {
            self.scroll_offset = 0;
        }
    }

    pub fn scrollDown(self: *HelpState, lines: usize, visible_lines: usize) void {
        const max_scroll = if (self.total_lines > visible_lines)
            self.total_lines - visible_lines
        else
            0;

        self.scroll_offset = @min(self.scroll_offset + lines, max_scroll);
    }

    pub fn scrollToTop(self: *HelpState) void {
        self.scroll_offset = 0;
    }

    pub fn scrollToBottom(self: *HelpState, visible_lines: usize) void {
        if (self.total_lines > visible_lines) {
            self.scroll_offset = self.total_lines - visible_lines;
        } else {
            self.scroll_offset = 0;
        }
    }
};
