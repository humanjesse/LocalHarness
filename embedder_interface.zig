// Generic embedder interface that works with any provider
// Allows GraphRAG to use Ollama or LM Studio embeddings seamlessly

const std = @import("std");
const embeddings = @import("embeddings");
const lmstudio = @import("lmstudio");

/// Generic embedder that dispatches to the correct provider implementation
pub const Embedder = union(enum) {
    ollama: *embeddings.EmbeddingsClient,
    lmstudio: *lmstudio.LMStudioEmbeddingsClient,

    /// Embed a single text string
    pub fn embed(self: *Embedder, model: []const u8, text: []const u8) ![]f32 {
        return switch (self.*) {
            .ollama => |client| client.embed(model, text),
            .lmstudio => |client| client.embed(model, text),
        };
    }

    /// Embed multiple text strings in a batch
    pub fn embedBatch(
        self: *Embedder,
        model: []const u8,
        texts: []const []const u8,
    ) ![][]f32 {
        return switch (self.*) {
            .ollama => |client| client.embedBatch(model, texts),
            .lmstudio => |client| client.embedBatch(model, texts),
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Embedder) void {
        switch (self.*) {
            .ollama => |client| client.deinit(),
            .lmstudio => |client| client.deinit(),
        }
    }
};
