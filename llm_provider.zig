// LLM Provider Abstraction - Unified interface for Ollama, LM Studio, and future providers
const std = @import("std");
const ollama = @import("ollama.zig");
const lmstudio = @import("lmstudio.zig");

/// Configuration warning for a specific provider
pub const ConfigWarning = struct {
    message: []const u8,
};

/// Field types for provider-specific configuration
pub const FieldType = enum {
    text_input,
    toggle,
    number_input,
};

/// Configuration value union for provider fields
pub const ConfigValue = union(enum) {
    text: []const u8,
    boolean: bool,
    number: i64,
    nullable_number: ?i64,
};

/// Provider-specific configuration field definition
pub const ProviderConfigField = struct {
    key: []const u8, // Field identifier (e.g., "host", "auto_start")
    label: []const u8, // Display label
    field_type: FieldType, // UI field type
    help_text: []const u8, // Help description
    default_value: ConfigValue, // Default value
};

/// Capabilities that different providers may or may not support
pub const ProviderCapabilities = struct {
    /// Supports extended thinking mode (Ollama-specific)
    supports_thinking: bool,

    /// Supports keep_alive parameter for model lifecycle management
    supports_keep_alive: bool,

    /// Supports tool/function calling
    supports_tools: bool,

    /// Supports JSON mode
    supports_json_mode: bool,

    /// Supports streaming responses
    supports_streaming: bool,

    /// Supports embeddings
    supports_embeddings: bool,

    /// Supports setting context size (num_ctx) via API
    supports_context_api: bool,

    /// Provider name for display
    name: []const u8,

    /// Default port for this provider
    default_port: u16,

    /// Configuration warnings specific to this provider
    config_warnings: []const ConfigWarning,

    /// Provider-specific configuration fields for UI
    config_fields: []const ProviderConfigField,
};

/// Centralized registry of all supported providers and their capabilities
pub const ProviderRegistry = struct {
    /// Ollama provider capabilities
    pub const OLLAMA = ProviderCapabilities{
        .supports_thinking = true,
        .supports_keep_alive = true,
        .supports_tools = true,
        .supports_json_mode = true,
        .supports_streaming = true,
        .supports_embeddings = true,
        .supports_context_api = true,
        .name = "Ollama",
        .default_port = 11434,
        .config_warnings = &[_]ConfigWarning{},
        .config_fields = &[_]ProviderConfigField{
            .{
                .key = "host",
                .label = "Ollama Host",
                .field_type = .text_input,
                .help_text = "HTTP endpoint for Ollama server (e.g., http://localhost:11434)",
                .default_value = .{ .text = "http://localhost:11434" },
            },
            .{
                .key = "endpoint",
                .label = "API Endpoint",
                .field_type = .text_input,
                .help_text = "Ollama API path (usually /api/chat)",
                .default_value = .{ .text = "/api/chat" },
            },
            .{
                .key = "keep_alive",
                .label = "Model Keep Alive",
                .field_type = .text_input,
                .help_text = "How long to keep model loaded (e.g., 15m, 1h, -1 for infinite)",
                .default_value = .{ .text = "15m" },
            },
        },
    };

    /// LM Studio provider capabilities
    pub const LMSTUDIO = ProviderCapabilities{
        .supports_thinking = false,
        .supports_keep_alive = false,
        .supports_tools = true,
        .supports_json_mode = true,
        .supports_streaming = true,
        .supports_embeddings = true,
        .supports_context_api = false,
        .name = "LM Studio",
        .default_port = 1234,
        .config_warnings = &[_]ConfigWarning{
            .{ .message = "Context size set at model load time (not per-request like Ollama)." },
        },
        .config_fields = &[_]ProviderConfigField{
            .{
                .key = "host",
                .label = "LM Studio Host",
                .field_type = .text_input,
                .help_text = "HTTP endpoint for LM Studio server (e.g., http://localhost:1234)",
                .default_value = .{ .text = "http://localhost:1234" },
            },
            .{
                .key = "auto_start",
                .label = "Auto-Start Server",
                .field_type = .toggle,
                .help_text = "Automatically start LM Studio API server if not running (requires LM Studio app to be open)",
                .default_value = .{ .boolean = true },
            },
            .{
                .key = "auto_load_model",
                .label = "Auto-Load Model",
                .field_type = .toggle,
                .help_text = "Automatically load model if none is loaded",
                .default_value = .{ .boolean = true },
            },
            .{
                .key = "gpu_offload",
                .label = "GPU Offload",
                .field_type = .text_input,
                .help_text = "GPU acceleration: 'auto', 'max', or 0.0-1.0",
                .default_value = .{ .text = "auto" },
            },
            .{
                .key = "ttl",
                .label = "Model TTL (seconds)",
                .field_type = .number_input,
                .help_text = "Auto-unload model after inactivity (0 = never unload)",
                .default_value = .{ .number = 0 },
            },
        },
    };

    /// All available providers
    pub const ALL = [_]ProviderCapabilities{ OLLAMA, LMSTUDIO };

    /// Get provider capabilities by name
    pub fn get(name: []const u8) ?ProviderCapabilities {
        if (std.mem.eql(u8, name, "ollama")) return OLLAMA;
        if (std.mem.eql(u8, name, "lmstudio")) return LMSTUDIO;
        return null;
    }

    /// Get list of all provider names
    pub fn listNames(allocator: std.mem.Allocator) ![][]const u8 {
        var names = try allocator.alloc([]const u8, ALL.len);
        for (ALL, 0..) |provider, i| {
            names[i] = provider.name;
        }
        return names;
    }

    /// Get list of all provider identifiers (lowercase keys)
    pub fn listIdentifiers(allocator: std.mem.Allocator) ![][]const u8 {
        const identifiers = try allocator.alloc([]const u8, ALL.len);
        identifiers[0] = "ollama";
        identifiers[1] = "lmstudio";
        return identifiers;
    }
};

/// Ollama-specific provider implementation
pub const OllamaProvider = struct {
    chat_client: ollama.OllamaClient,
    embeddings_client: @import("embeddings.zig").EmbeddingsClient,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, chat_endpoint: []const u8) OllamaProvider {
        return .{
            .chat_client = ollama.OllamaClient.init(allocator, host, chat_endpoint),
            .embeddings_client = @import("embeddings.zig").EmbeddingsClient.init(allocator, host),
        };
    }

    pub fn deinit(self: *OllamaProvider) void {
        self.chat_client.deinit();
        self.embeddings_client.deinit();
    }

    pub fn getCapabilities() ProviderCapabilities {
        return ProviderRegistry.OLLAMA;
    }

    pub fn chatStream(
        self: *OllamaProvider,
        model: []const u8,
        messages: []const ollama.ChatMessage,
        think: bool,
        format: ?[]const u8,
        tools: ?[]const ollama.Tool,
        keep_alive: ?[]const u8,
        num_ctx: ?usize,
        num_predict: ?isize,
        temperature: ?f32,
        repeat_penalty: ?f32,
        context: anytype,
        callback: fn (
            ctx: @TypeOf(context),
            thinking_chunk: ?[]const u8,
            content_chunk: ?[]const u8,
            tool_calls_chunk: ?[]const ollama.ToolCall,
        ) void,
    ) !void {
        return self.chat_client.chatStream(
            model,
            messages,
            think,
            format,
            tools,
            keep_alive,
            num_ctx,
            num_predict,
            temperature,
            repeat_penalty,
            context,
            callback,
        );
    }

    pub fn embed(
        self: *OllamaProvider,
        model: []const u8,
        text: []const u8,
    ) ![]f32 {
        return self.embeddings_client.embed(model, text);
    }

    pub fn embedBatch(
        self: *OllamaProvider,
        model: []const u8,
        texts: []const []const u8,
    ) ![][]f32 {
        return self.embeddings_client.embedBatch(model, texts);
    }
};

/// LM Studio-specific provider implementation
pub const LMStudioProvider = struct {
    chat_client: lmstudio.LMStudioClient,
    embeddings_client: lmstudio.LMStudioEmbeddingsClient,

    pub fn init(allocator: std.mem.Allocator, host: []const u8) LMStudioProvider {
        return .{
            .chat_client = lmstudio.LMStudioClient.init(allocator, host),
            .embeddings_client = lmstudio.LMStudioEmbeddingsClient.init(allocator, host),
        };
    }

    pub fn deinit(self: *LMStudioProvider) void {
        self.chat_client.deinit();
        self.embeddings_client.deinit();
    }

    pub fn getCapabilities() ProviderCapabilities {
        return ProviderRegistry.LMSTUDIO;
    }

    pub fn chatStream(
        self: *LMStudioProvider,
        model: []const u8,
        messages: []const ollama.ChatMessage,
        think: bool,  // Ignored - not supported
        format: ?[]const u8,
        tools: ?[]const ollama.Tool,
        keep_alive: ?[]const u8,  // Ignored - not supported
        num_ctx: ?usize,
        num_predict: ?isize,
        temperature: ?f32,
        repeat_penalty: ?f32,
        context: anytype,
        callback: fn (
            ctx: @TypeOf(context),
            thinking_chunk: ?[]const u8,
            content_chunk: ?[]const u8,
            tool_calls_chunk: ?[]const ollama.ToolCall,
        ) void,
    ) !void {
        _ = think; // Not supported by LM Studio
        _ = keep_alive; // Not supported by LM Studio

        return self.chat_client.chatStream(
            model,
            messages,
            format,
            tools,
            num_ctx,
            num_predict,
            temperature,
            repeat_penalty,
            context,
            callback,
        );
    }

    pub fn embed(
        self: *LMStudioProvider,
        model: []const u8,
        text: []const u8,
    ) ![]f32 {
        return self.embeddings_client.embed(model, text);
    }

    pub fn embedBatch(
        self: *LMStudioProvider,
        model: []const u8,
        texts: []const []const u8,
    ) ![][]f32 {
        return self.embeddings_client.embedBatch(model, texts);
    }
};

/// Unified LLM Provider - can be any supported provider
pub const LLMProvider = union(enum) {
    ollama: OllamaProvider,
    lmstudio: LMStudioProvider,

    /// Get the capabilities of the current provider
    pub fn getCapabilities(self: *const LLMProvider) ProviderCapabilities {
        return switch (self.*) {
            .ollama => OllamaProvider.getCapabilities(),
            .lmstudio => LMStudioProvider.getCapabilities(),
        };
    }

    /// Unified chat streaming interface
    pub fn chatStream(
        self: *LLMProvider,
        model: []const u8,
        messages: []const ollama.ChatMessage,
        think: bool,
        format: ?[]const u8,
        tools: ?[]const ollama.Tool,
        keep_alive: ?[]const u8,
        num_ctx: ?usize,
        num_predict: ?isize,
        temperature: ?f32,
        repeat_penalty: ?f32,
        context: anytype,
        callback: fn (
            ctx: @TypeOf(context),
            thinking_chunk: ?[]const u8,
            content_chunk: ?[]const u8,
            tool_calls_chunk: ?[]const ollama.ToolCall,
        ) void,
    ) !void {
        switch (self.*) {
            .ollama => |*provider| {
                return provider.chatStream(
                    model,
                    messages,
                    think,
                    format,
                    tools,
                    keep_alive,
                    num_ctx,
                    num_predict,
                    temperature,
                    repeat_penalty,
                    context,
                    callback,
                );
            },
            .lmstudio => |*provider| {
                return provider.chatStream(
                    model,
                    messages,
                    think,
                    format,
                    tools,
                    keep_alive,
                    num_ctx,
                    num_predict,
                    temperature,
                    repeat_penalty,
                    context,
                    callback,
                );
            },
        }
    }

    /// Unified embeddings interface - single text
    pub fn embed(
        self: *LLMProvider,
        model: []const u8,
        text: []const u8,
    ) ![]f32 {
        return switch (self.*) {
            .ollama => |*provider| provider.embed(model, text),
            .lmstudio => |*provider| provider.embed(model, text),
        };
    }

    /// Unified embeddings interface - batch
    pub fn embedBatch(
        self: *LLMProvider,
        model: []const u8,
        texts: []const []const u8,
    ) ![][]f32 {
        return switch (self.*) {
            .ollama => |*provider| provider.embedBatch(model, texts),
            .lmstudio => |*provider| provider.embedBatch(model, texts),
        };
    }

    /// Clean up provider resources
    pub fn deinit(self: *LLMProvider) void {
        switch (self.*) {
            .ollama => |*provider| provider.deinit(),
            .lmstudio => |*provider| provider.deinit(),
        }
    }
};

/// Factory function to create the appropriate provider based on configuration
pub fn createProvider(
    provider_type: []const u8,
    allocator: std.mem.Allocator,
    config: anytype,  // Generic config type to avoid circular dependency
) !LLMProvider {
    // Verify provider exists in registry
    const caps = ProviderRegistry.get(provider_type) orelse {
        std.debug.print("❌ Error: Unknown provider '{s}'\n", .{provider_type});
        std.debug.print("   Available providers: ", .{});
        for (ProviderRegistry.ALL, 0..) |provider, i| {
            if (i > 0) std.debug.print(", ", .{});
            std.debug.print("{s}", .{provider.name});
        }
        std.debug.print("\n\n", .{});
        return error.UnsupportedProvider;
    };

    // Log initialization
    std.debug.print("✓ Initializing {s} provider...\n", .{caps.name});

    // Create the appropriate provider
    if (std.mem.eql(u8, provider_type, "ollama")) {
        return LLMProvider{
            .ollama = OllamaProvider.init(
                allocator,
                config.ollama_host,
                config.ollama_endpoint,
            ),
        };
    } else if (std.mem.eql(u8, provider_type, "lmstudio")) {
        // Try to initialize LM Studio manager for auto-management
        const lmstudio_manager = @import("lmstudio_manager.zig");
        var manager = lmstudio_manager.LMStudioManager.init(allocator) catch |err| {
            std.debug.print("⚠ LM Studio CLI not found: {s}\n", .{@errorName(err)});
            std.debug.print("   Auto-management disabled. Install with: npx lmstudio install-cli\n", .{});
            std.debug.print("   Continuing without auto-management...\n\n", .{});

            return LLMProvider{
                .lmstudio = LMStudioProvider.init(
                    allocator,
                    config.lmstudio_host,
                ),
            };
        };

        // Auto-start server if configured
        if (config.lmstudio_auto_start) {
            const server_running = manager.isServerRunning() catch false;
            if (!server_running) {
                std.debug.print("🚀 Starting LM Studio server...\n", .{});
                manager.startServer() catch |err| {
                    std.debug.print("❌ Failed to start server: {s}\n", .{@errorName(err)});
                    std.debug.print("   Please start LM Studio manually.\n\n", .{});
                };

                // Wait briefly for server to start
                std.Thread.sleep(2 * std.time.ns_per_s);
            } else {
                std.debug.print("✓ LM Studio server already running\n", .{});
            }
        }

        // Auto-load model if configured
        if (config.lmstudio_auto_load_model) {
            std.debug.print("\n🔍 Auto-load enabled, checking model status...\n", .{});

            const loaded = manager.listLoadedModels() catch |err| blk: {
                std.debug.print("⚠️  Warning: Failed to query loaded models: {s}\n", .{@errorName(err)});
                std.debug.print("   Continuing with empty model list (will attempt to load)\n", .{});
                break :blk &[_]lmstudio_manager.LoadedModelInfo{};
            };
            defer manager.freeLoadedModels(loaded);

            // Show currently loaded models for debugging
            if (loaded.len > 0) {
                std.debug.print("   Currently loaded models ({d}):\n", .{loaded.len});
                for (loaded) |model| {
                    std.debug.print("     - {s} (identifier: {s})\n", .{model.path, model.identifier});
                }
            } else {
                std.debug.print("   No models currently loaded\n", .{});
            }

            // Helper function to check if a specific model is loaded
            const isModelLoaded = struct {
                fn check(models: []const lmstudio_manager.LoadedModelInfo, model_path: []const u8) bool {
                    for (models) |model| {
                        if (std.mem.eql(u8, model.path, model_path) or std.mem.eql(u8, model.identifier, model_path)) {
                            return true;
                        }
                    }
                    return false;
                }
            }.check;

            // Check and load main model
            if (!isModelLoaded(loaded, config.model)) {
                // Validate model exists in available models first
                std.debug.print("\n🔎 Checking if model exists: {s}\n", .{config.model});
                const available = manager.queryAvailableModels() catch |err| blk: {
                    std.debug.print("⚠️  Warning: Could not query available models: {s}\n", .{@errorName(err)});
                    std.debug.print("   Will attempt to load anyway...\n", .{});
                    break :blk &[_]lmstudio_manager.LoadedModelInfo{};
                };
                defer manager.freeLoadedModels(available);

                var model_exists = false;
                for (available) |model| {
                    if (std.mem.eql(u8, model.path, config.model) or std.mem.eql(u8, model.identifier, config.model)) {
                        model_exists = true;
                        break;
                    }
                }

                if (!model_exists and available.len > 0) {
                    std.debug.print("❌ Model not found in LM Studio's downloaded models!\n", .{});
                    std.debug.print("   Requested: {s}\n", .{config.model});
                    std.debug.print("   Available models ({d}):\n", .{available.len});
                    for (available) |model| {
                        std.debug.print("     - {s}\n", .{model.path});
                    }
                    std.debug.print("\n💡 Please update your config to use one of the above models\n", .{});
                    std.debug.print("   or download '{s}' in LM Studio first.\n\n", .{config.model});
                } else if (model_exists) {
                    std.debug.print("✓ Model found in available models\n", .{});
                }

                // Detect optimal context length
                const optimal = manager.getOptimalContextLength(config.model, config.num_ctx);

                // Show what we're doing
                std.debug.print("\n📦 Loading main model: {s}...\n", .{config.model});
                if (optimal.model_max) |max| {
                    std.debug.print("   Model max context: {d} tokens\n", .{max});
                    if (optimal.clamped) {
                        std.debug.print("   Configured: {d} tokens → Using: {d} tokens (auto-clamped)\n",
                            .{config.num_ctx, optimal.context});
                    } else {
                        std.debug.print("   Using: {d} tokens\n", .{optimal.context});
                    }
                }
                // Note: num_predict (max output tokens) is set per API request
                // LM Studio will validate/clamp if it exceeds model capabilities
                std.debug.print("   Max output tokens: {d} (validated by LM Studio)\n", .{config.num_predict});

                manager.loadModel(
                    config.model,
                    config.lmstudio_gpu_offload,
                    optimal.context,
                    if (config.lmstudio_ttl > 0) config.lmstudio_ttl else null,
                ) catch |err| {
                    std.debug.print("\n❌ Auto-load failed for main model\n", .{});
                    std.debug.print("   Model: {s}\n", .{config.model});
                    std.debug.print("   Error: {s}\n", .{@errorName(err)});
                    std.debug.print("   GPU Offload: {s}\n", .{config.lmstudio_gpu_offload});
                    std.debug.print("   Context Length: {d}\n", .{optimal.context});
                    if (config.lmstudio_ttl > 0) {
                        std.debug.print("   TTL: {d} seconds\n", .{config.lmstudio_ttl});
                    }
                    std.debug.print("\n💡 The app will continue, but you may need to:\n", .{});
                    std.debug.print("   1. Check that the model exists in LM Studio\n", .{});
                    std.debug.print("   2. Verify the model path in config matches exactly\n", .{});
                    std.debug.print("   3. Load the model manually in LM Studio\n\n", .{});
                };
            } else {
                std.debug.print("✓ Main model already loaded: {s}\n", .{config.model});
            }

            // Check and load embedding model if GraphRAG is enabled
            if (config.graph_rag_enabled and !std.mem.eql(u8, config.embedding_model, config.model)) {
                if (!isModelLoaded(loaded, config.embedding_model)) {
                    // Detect optimal context length for embedding model
                    const optimal = manager.getOptimalContextLength(config.embedding_model, config.num_ctx);

                    std.debug.print("📦 Loading embedding model: {s}...\n", .{config.embedding_model});
                    if (optimal.model_max) |max| {
                        std.debug.print("   Model max context: {d} tokens\n", .{max});
                        if (optimal.clamped) {
                            std.debug.print("   Configured: {d} tokens → Using: {d} tokens (auto-clamped)\n",
                                .{config.num_ctx, optimal.context});
                        } else {
                            std.debug.print("   Using: {d} tokens\n", .{optimal.context});
                        }
                    }

                    manager.loadModel(
                        config.embedding_model,
                        config.lmstudio_gpu_offload,
                        optimal.context,
                        if (config.lmstudio_ttl > 0) config.lmstudio_ttl else null,
                    ) catch |err| {
                        std.debug.print("\n❌ Auto-load failed for embedding model\n", .{});
                        std.debug.print("   Model: {s}\n", .{config.embedding_model});
                        std.debug.print("   Error: {s}\n", .{@errorName(err)});
                        std.debug.print("   GPU Offload: {s}\n", .{config.lmstudio_gpu_offload});
                        std.debug.print("   Context Length: {d}\n", .{optimal.context});
                        std.debug.print("\n💡 GraphRAG requires an embedding model. Please:\n", .{});
                        std.debug.print("   1. Download a nomic-embed-text model in LM Studio\n", .{});
                        std.debug.print("   2. Verify the embedding_model path in config\n", .{});
                        std.debug.print("   3. Load it manually or restart the app\n\n", .{});
                    };
                } else {
                    std.debug.print("✓ Embedding model already loaded: {s}\n", .{config.embedding_model});
                }
            }
        }

        // Clean up manager (we don't need to keep it around after initialization)
        manager.deinit();

        return LLMProvider{
            .lmstudio = LMStudioProvider.init(
                allocator,
                config.lmstudio_host,
            ),
        };
    } else {
        // Should never reach here if registry.get() worked
        return error.UnsupportedProvider;
    }
}
