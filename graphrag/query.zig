// Graph RAG query - retrieve and summarize chunks for conversation history
const std = @import("std");
const mem = std.mem;
const zvdb = @import("../zvdb/src/zvdb.zig");

/// Summarize a file for conversation history using Graph RAG
/// Returns a compact representation with the most important chunks
pub fn summarizeFileForHistory(
    allocator: mem.Allocator,
    vector_store: *zvdb.HNSW(f32),
    file_path: []const u8,
    max_chunks: usize,
) ![]const u8 {
    var summary = std.ArrayListUnmanaged(u8){};
    defer summary.deinit(allocator);

    const writer = summary.writer(allocator);

    // Header - make it VERY obvious this is a Graph RAG summary
    try writer.writeAll("═══ GRAPH RAG SUMMARY ═══\n");
    try writer.print("File: {s}\n", .{file_path});
    try writer.writeAll("This summary was extracted from the knowledge graph. Use this information to answer questions about the file.\n");
    try writer.writeAll("───────────────────────\n");

    // Get all nodes for this file
    const file_nodes = try getNodesForFile(allocator, vector_store, file_path);
    defer allocator.free(file_nodes);

    if (file_nodes.len == 0) {
        try writer.writeAll("(No indexed content)\n");
        return summary.toOwnedSlice(allocator);
    }

    // Sort nodes by importance (public > private, functions > code blocks)
    const sorted_nodes = try sortNodesByImportance(allocator, vector_store, file_nodes);
    defer allocator.free(sorted_nodes);

    // Include top-K chunks
    const num_to_include = @min(max_chunks, sorted_nodes.len);

    for (sorted_nodes[0..num_to_include]) |node_id| {
        const node = vector_store.getByExternalId(node_id) orelse continue;
        const metadata = node.metadata orelse continue;

        // Extract name and summary from metadata
        const name_opt = metadata.attributes.get("name");
        const summary_opt = metadata.attributes.get("summary");
        const is_public_opt = metadata.attributes.get("is_public");

        const name = if (name_opt) |n| if (n == .string) n.string else "unnamed" else "unnamed";
        const node_summary = if (summary_opt) |s| if (s == .string) s.string else "" else "";
        const is_public = if (is_public_opt) |p| if (p == .bool) p.bool else false else false;

        // Format: ### Name (type) [public]
        // Summary text here
        try writer.print("\n### {s}", .{name});
        try writer.print(" ({s})", .{metadata.node_type});
        if (is_public) {
            try writer.writeAll(" [public]");
        }
        try writer.writeAll("\n");

        // Include the actual summary content
        if (node_summary.len > 0) {
            try writer.print("{s}\n", .{node_summary});
        }

        // Include relationships
        const edges = try vector_store.getOutgoing(node_id, null);
        defer allocator.free(edges);

        if (edges.len > 0) {
            try writer.writeAll("**Relationships**: ");
            for (edges, 0..) |edge, i| {
                if (i > 0) try writer.writeAll(", ");

                // Show relationship type
                try writer.print("{s} → ", .{edge.edge_type});

                const target_node = vector_store.getByExternalId(edge.dst) orelse continue;
                const target_metadata = target_node.metadata orelse continue;
                if (target_metadata.attributes.get("name")) |target_name| {
                    if (target_name == .string) {
                        try writer.print("{s}", .{target_name.string});
                    }
                }
            }
            try writer.writeAll("\n");
        }
    }

    // Footer
    try writer.writeAll("\n───────────────────────\n");
    try writer.print("Graph contains {d} entities total. Showing top {d} most relevant.\n", .{ file_nodes.len, num_to_include });
    try writer.writeAll("═══ END GRAPH RAG SUMMARY ═══\n");

    return summary.toOwnedSlice(allocator);
}

/// Get all node IDs for a specific file
fn getNodesForFile(allocator: mem.Allocator, vector_store: *zvdb.HNSW(f32), file_path: []const u8) ![]u64 {
    _ = allocator; // zvdb's getNodesByFilePath allocates internally
    // zvdb maintains a file_path_index that maps file paths to node IDs
    // getNodesByFilePath returns an owned slice that we must free
    const nodes = try vector_store.getNodesByFilePath(file_path);

    // Cast to non-const since caller will free it
    // This is safe because getNodesByFilePath returns an owned (mutable) slice
    return @constCast(nodes);
}

/// Sort nodes by importance for inclusion in summary
fn sortNodesByImportance(allocator: mem.Allocator, vector_store: *zvdb.HNSW(f32), nodes: []const u64) ![]u64 {
    // Create scored nodes
    var scored_nodes = try allocator.alloc(ScoredNode, nodes.len);
    defer allocator.free(scored_nodes);

    for (nodes, 0..) |node_id, i| {
        const node = vector_store.getByExternalId(node_id) orelse {
            scored_nodes[i] = .{ .node_id = node_id, .score = 0.0 };
            continue;
        };
        const metadata = node.metadata orelse {
            scored_nodes[i] = .{ .node_id = node_id, .score = 0.0 };
            continue;
        };

        var score: f32 = 0.0;

        // Public items are more important
        if (metadata.attributes.get("is_public")) |is_pub| {
            if (is_pub == .string and mem.eql(u8, is_pub.string, "true")) {
                score += 10.0;
            }
        }

        // Functions are more important than code blocks
        if (mem.eql(u8, metadata.node_type, "function")) {
            score += 5.0;
        } else if (mem.eql(u8, metadata.node_type, "struct") or mem.eql(u8, metadata.node_type, "class")) {
            score += 4.0;
        } else if (mem.eql(u8, metadata.node_type, "import")) {
            score += 3.0;
        } else if (mem.eql(u8, metadata.node_type, "code_block")) {
            score += 1.0;
        }

        scored_nodes[i] = .{ .node_id = node_id, .score = score };
    }

    // Sort by score descending
    std.mem.sort(ScoredNode, scored_nodes, {}, compareScores);

    // Extract sorted node IDs
    const result = try allocator.alloc(u64, nodes.len);
    for (scored_nodes, 0..) |scored, i| {
        result[i] = scored.node_id;
    }

    return result;
}

const ScoredNode = struct {
    node_id: u64,
    score: f32,
};

fn compareScores(_: void, a: ScoredNode, b: ScoredNode) bool {
    return a.score > b.score; // Descending order
}

/// Create a simple summary when Graph RAG is not available
pub fn createFallbackSummary(allocator: mem.Allocator, file_path: []const u8, content: []const u8) ![]const u8 {
    var summary = std.ArrayListUnmanaged(u8){};
    defer summary.deinit(allocator);

    const writer = summary.writer(allocator);

    try writer.print("File: {s}\n", .{file_path});

    // Count lines
    var line_count: usize = 1;
    for (content) |c| {
        if (c == '\n') line_count += 1;
    }

    try writer.print("Lines: {d}\n", .{line_count});

    // Include first N lines as preview
    const preview_lines = 10;
    var lines_written: usize = 0;
    var i: usize = 0;

    try writer.writeAll("Preview:\n");
    while (i < content.len and lines_written < preview_lines) : (i += 1) {
        if (content[i] == '\n') lines_written += 1;
        try writer.writeByte(content[i]);
    }

    if (i < content.len) {
        try writer.writeAll("\n... (truncated)\n");
    }

    return summary.toOwnedSlice(allocator);
}
