// Graph Builder - Captures LLM tool calls to build knowledge graph
const std = @import("std");
const indexing_tools = @import("indexing_tools.zig");

const Node = indexing_tools.Node;
const Edge = indexing_tools.Edge;

/// Custom errors for graph building
pub const GraphError = error{
    NodeNotFound,
    DuplicateNode,
} || std.mem.Allocator.Error;

/// In-memory graph builder that captures LLM tool calls
pub const GraphBuilder = struct {
    allocator: std.mem.Allocator,
    nodes: std.StringHashMap(Node),
    edges: std.ArrayList(Edge),

    fn isDebugEnabled() bool {
        return std.posix.getenv("DEBUG_GRAPHRAG") != null;
    }

    /// Initialize empty graph builder
    pub fn init(allocator: std.mem.Allocator) GraphBuilder {
        return .{
            .allocator = allocator,
            .nodes = std.StringHashMap(Node).init(allocator),
            .edges = .{},
        };
    }

    /// Free all graph resources
    pub fn deinit(self: *GraphBuilder) void {
        // Free all nodes
        var node_iter = self.nodes.valueIterator();
        while (node_iter.next()) |node| {
            var mutable_node = node.*;
            mutable_node.deinit(self.allocator);
        }
        self.nodes.deinit();

        // Free all edges
        for (self.edges.items) |*edge| {
            edge.deinit(self.allocator);
        }
        self.edges.deinit(self.allocator);
    }

    /// Create a node from LLM tool call arguments
    /// Handles duplicate nodes by logging warning and skipping (idempotent)
    pub fn createNode(self: *GraphBuilder, args_json: []const u8) !void {
        // Parse node from JSON
        var node = try Node.fromToolCallArgs(self.allocator, args_json);
        errdefer node.deinit(self.allocator);

        // Check for duplicate
        if (self.nodes.contains(node.name)) {
            if (isDebugEnabled()) {
                std.debug.print("[GRAPH] Warning: Duplicate node '{s}' - skipping\n", .{node.name});
            }
            node.deinit(self.allocator);
            return; // Idempotent - just skip
        }

        // Add to nodes map
        try self.nodes.put(node.name, node);

        if (isDebugEnabled()) {
            std.debug.print("[GRAPH] Created node: {s} ({s})\n", .{ node.name, node.node_type.toString() });
        }
    }

    /// Create an edge from LLM tool call arguments
    /// Validates that both nodes exist before adding edge
    pub fn createEdge(self: *GraphBuilder, args_json: []const u8) !void {
        // Parse edge from JSON
        var edge = try Edge.fromToolCallArgs(self.allocator, args_json);
        errdefer edge.deinit(self.allocator);

        // Validate from_node exists
        if (!self.nodes.contains(edge.from_node)) {
            if (isDebugEnabled()) {
                std.debug.print("[GRAPH] Error: Edge references unknown from_node '{s}'\n", .{edge.from_node});
            }
            return error.NodeNotFound;
        }

        // Validate to_node exists
        if (!self.nodes.contains(edge.to_node)) {
            if (isDebugEnabled()) {
                std.debug.print("[GRAPH] Error: Edge references unknown to_node '{s}'\n", .{edge.to_node});
            }
            return error.NodeNotFound;
        }

        // Add edge (allow duplicates - LLM might call same relationship twice)
        try self.edges.append(self.allocator, edge);

        if (isDebugEnabled()) {
            std.debug.print("[GRAPH] Created edge: {s} -{s}-> {s}\n", .{
                edge.from_node,
                edge.relationship.toString(),
                edge.to_node,
            });
        }
    }

    /// Get number of nodes in graph
    pub fn getNodeCount(self: *const GraphBuilder) usize {
        return self.nodes.count();
    }

    /// Get number of edges in graph
    pub fn getEdgeCount(self: *const GraphBuilder) usize {
        return self.edges.items.len;
    }

    /// Check if a node exists by name
    pub fn hasNode(self: *const GraphBuilder, name: []const u8) bool {
        return self.nodes.contains(name);
    }

    /// Get a node by name (returns null if not found)
    pub fn getNode(self: *const GraphBuilder, name: []const u8) ?Node {
        return self.nodes.get(name);
    }

    /// Get all node names (caller must free returned slice)
    pub fn getNodeNames(self: *GraphBuilder) ![][]const u8 {
        var names = try self.allocator.alloc([]const u8, self.nodes.count());
        var iter = self.nodes.keyIterator();
        var i: usize = 0;
        while (iter.next()) |key| : (i += 1) {
            names[i] = key.*;
        }
        return names;
    }

    /// Get formatted list of node names for prompts (caller must free returned string)
    /// Returns comma-separated list like "main, readFile, Config" or "none" if empty
    pub fn getNodeNamesList(self: *const GraphBuilder) ![]const u8 {
        if (self.nodes.count() == 0) {
            return try self.allocator.dupe(u8, "none");
        }

        var list = try std.ArrayList(u8).initCapacity(self.allocator, 0);
        defer list.deinit(self.allocator);

        var iter = self.nodes.keyIterator();
        var first = true;
        while (iter.next()) |key| {
            if (!first) {
                try list.appendSlice(self.allocator, ", ");
            }
            try list.appendSlice(self.allocator, key.*);
            first = false;
        }

        return try list.toOwnedSlice(self.allocator);
    }

    /// Print graph summary for debugging
    pub fn printSummary(self: *const GraphBuilder) void {
        std.debug.print("\n=== Graph Summary ===\n", .{});
        std.debug.print("Nodes: {d}\n", .{self.getNodeCount()});
        std.debug.print("Edges: {d}\n", .{self.getEdgeCount()});

        if (self.getNodeCount() > 0) {
            std.debug.print("\nNode List:\n", .{});
            var node_iter = self.nodes.iterator();
            while (node_iter.next()) |entry| {
                const name = entry.key_ptr.*;
                const node = entry.value_ptr.*;
                std.debug.print("  - {s} ({s})", .{ name, node.node_type.toString() });
                if (node.is_public) {
                    std.debug.print(" [public]", .{});
                }
                std.debug.print("\n", .{});
            }
        }

        if (self.getEdgeCount() > 0) {
            std.debug.print("\nEdge List:\n", .{});
            for (self.edges.items) |edge| {
                std.debug.print("  - {s} -{s}-> {s}\n", .{
                    edge.from_node,
                    edge.relationship.toString(),
                    edge.to_node,
                });
            }
        }

        std.debug.print("===================\n\n", .{});
    }
};
