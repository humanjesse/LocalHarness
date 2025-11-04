// Context compression system - token tracking and compression configuration
const std = @import("std");
const mem = std.mem;

/// Configuration for compression system
pub const CompressionConfig = struct {
    enabled: bool = true,
    trigger_threshold_pct: f32 = 0.70,
    target_usage_pct: f32 = 0.40,
    min_messages_before_compress: usize = 50,
    enable_recursive_compression: bool = true,
};

pub const MessageRole = enum { user, assistant, system, tool, display_only_data };

/// Token usage tracker
pub const TokenTracker = struct {
    allocator: mem.Allocator,
    estimated_tokens_used: usize = 0,
    max_context_tokens: usize,
    message_token_estimates: std.ArrayListUnmanaged(MessageTokenEstimate) = .{},
    
    pub const MessageTokenEstimate = struct {
        message_idx: usize,
        estimated_tokens: usize,
        role: MessageRole,
    };
    
    pub fn init(allocator: mem.Allocator, max_context: usize) TokenTracker {
        return .{
            .allocator = allocator,
            .max_context_tokens = max_context,
        };
    }
    
    pub fn deinit(self: *TokenTracker) void {
        self.message_token_estimates.deinit(self.allocator);
    }
    
    /// Estimate tokens for content (rough heuristic: 4 chars ≈ 1 token)
    /// This is conservative and works reasonably well for most models
    pub fn estimateMessageTokens(content: []const u8) usize {
        return @max(1, content.len / 4);
    }
    
    /// Track a new message
    pub fn trackMessage(
        self: *TokenTracker,
        msg_idx: usize,
        content: []const u8,
        role: MessageRole,
    ) !void {
        const tokens = estimateMessageTokens(content);
        try self.message_token_estimates.append(self.allocator, .{
            .message_idx = msg_idx,
            .estimated_tokens = tokens,
            .role = role,
        });
        self.estimated_tokens_used += tokens;
    }
    
    /// Check if compression is needed based on configuration
    pub fn needsCompression(self: *TokenTracker, config: CompressionConfig) bool {
        if (!config.enabled) return false;
        
        if (self.message_token_estimates.items.len < config.min_messages_before_compress) {
            return false;
        }
        
        const usage_pct = @as(f32, @floatFromInt(self.estimated_tokens_used)) / 
                          @as(f32, @floatFromInt(self.max_context_tokens));
        
        return usage_pct >= config.trigger_threshold_pct;
    }
    
    /// Get target tokens after compression
    pub fn getTargetTokens(self: *TokenTracker, config: CompressionConfig) usize {
        return @as(usize, @intFromFloat(
            @as(f32, @floatFromInt(self.max_context_tokens)) * config.target_usage_pct
        ));
    }
    
    /// Get current usage percentage (0.0 to 1.0)
    pub fn getUsagePercent(self: *TokenTracker) f32 {
        return @as(f32, @floatFromInt(self.estimated_tokens_used)) / 
               @as(f32, @floatFromInt(self.max_context_tokens));
    }
    
    /// Reset tracking (used after compression)
    pub fn reset(self: *TokenTracker) void {
        for (self.message_token_estimates.items) |_| {
            // Items don't own memory, just clear list
        }
        self.message_token_estimates.clearRetainingCapacity();
        self.estimated_tokens_used = 0;
    }
    
    /// Recalculate tokens from scratch (used after compression applies new messages)
    pub fn recalculate(self: *TokenTracker, messages: anytype) !void {
        self.reset();
        
        for (messages, 0..) |msg, idx| {
            const role: MessageTokenEstimate.role = switch (msg.role) {
                .user => .user,
                .assistant => .assistant,
                .system => .system,
                .tool => .tool,
                .display_only_data => .display_only_data,
            };
            
            try self.trackMessage(idx, msg.content, role);
        }
    }
};
