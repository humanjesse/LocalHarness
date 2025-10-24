// Graph RAG Indexing Tools - Tools for LLM to build knowledge graphs
const std = @import("std");
const ollama = @import("../ollama.zig");
const GraphBuilder = @import("graph_builder.zig").GraphBuilder;
const registry = @import("indexing_tool_registry.zig");

const IndexingToolDefinition = registry.IndexingToolDefinition;
const IndexingToolResult = registry.IndexingToolResult;
const IndexingContext = registry.IndexingContext;

/// Represents a semantic node in the knowledge graph
pub const Node = struct {
    name: []const u8,
    node_type: NodeType,
    summary: []const u8,
    is_public: bool = false,
    start_line: ?usize = null,
    end_line: ?usize = null,

    /// Parse Node from tool call JSON arguments
    pub fn fromToolCallArgs(allocator: std.mem.Allocator, args_json: []const u8) !Node {
        const Args = struct {
            name: []const u8,
            node_type: []const u8,
            summary: []const u8,
            is_public: ?bool = null,
            start_line: ?usize = null,
            end_line: ?usize = null,
        };

        const parsed = try std.json.parseFromSlice(Args, allocator, args_json, .{});
        defer parsed.deinit();

        const args = parsed.value;

        // Parse and validate node_type
        const node_type = NodeType.fromString(args.node_type) orelse {
            return error.InvalidNodeType;
        };

        return Node{
            .name = try allocator.dupe(u8, args.name),
            .node_type = node_type,
            .summary = try allocator.dupe(u8, args.summary),
            .is_public = args.is_public orelse false,
            .start_line = args.start_line,
            .end_line = args.end_line,
        };
    }

    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.summary);
    }
};

/// Types of semantic nodes
pub const NodeType = enum {
    function,
    @"struct",
    section,
    concept,

    pub fn fromString(s: []const u8) ?NodeType {
        if (std.mem.eql(u8, s, "function")) return .function;
        if (std.mem.eql(u8, s, "struct")) return .@"struct";
        if (std.mem.eql(u8, s, "section")) return .section;
        if (std.mem.eql(u8, s, "concept")) return .concept;
        return null;
    }

    pub fn toString(self: NodeType) []const u8 {
        return switch (self) {
            .function => "function",
            .@"struct" => "struct",
            .section => "section",
            .concept => "concept",
        };
    }
};

/// Represents a relationship between nodes
pub const Edge = struct {
    from_node: []const u8,
    to_node: []const u8,
    relationship: RelationshipType,
    weight: f32 = 1.0,

    /// Parse Edge from tool call JSON arguments
    pub fn fromToolCallArgs(allocator: std.mem.Allocator, args_json: []const u8) !Edge {
        const Args = struct {
            from_node: []const u8,
            to_node: []const u8,
            relationship: []const u8,
            weight: ?f32 = null,
        };

        const parsed = try std.json.parseFromSlice(Args, allocator, args_json, .{});
        defer parsed.deinit();

        const args = parsed.value;

        // Parse and validate relationship type
        const relationship = RelationshipType.fromString(args.relationship) orelse {
            return error.InvalidRelationshipType;
        };

        return Edge{
            .from_node = try allocator.dupe(u8, args.from_node),
            .to_node = try allocator.dupe(u8, args.to_node),
            .relationship = relationship,
            .weight = args.weight orelse 1.0,
        };
    }

    pub fn deinit(self: *Edge, allocator: std.mem.Allocator) void {
        allocator.free(self.from_node);
        allocator.free(self.to_node);
    }
};

/// Types of relationships between nodes
pub const RelationshipType = enum {
    calls,
    imports,
    references,
    relates_to,

    pub fn fromString(s: []const u8) ?RelationshipType {
        if (std.mem.eql(u8, s, "calls")) return .calls;
        if (std.mem.eql(u8, s, "imports")) return .imports;
        if (std.mem.eql(u8, s, "references")) return .references;
        if (std.mem.eql(u8, s, "relates_to")) return .relates_to;
        return null;
    }

    pub fn toString(self: RelationshipType) []const u8 {
        return switch (self) {
            .calls => "calls",
            .imports => "imports",
            .references => "references",
            .relates_to => "relates_to",
        };
    }
};

/// Execute create_node tool call
fn executeCreateNode(
    allocator: std.mem.Allocator,
    arguments: []const u8,
    context: *IndexingContext,
) !IndexingToolResult {
    // Parse node from JSON arguments
    var node = Node.fromToolCallArgs(allocator, arguments) catch |err| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "Failed to parse node arguments: {}",
            .{err},
        );
        defer allocator.free(msg);
        context.stats.errors += 1;
        return IndexingToolResult.err(allocator, msg);
    };
    errdefer node.deinit(allocator);

    // Check for duplicate node (idempotent - not an error)
    if (context.graph_builder.nodes.contains(node.name)) {
        node.deinit(allocator);
        const msg = try std.fmt.allocPrint(
            allocator,
            "Node '{s}' already exists - skipped (idempotent)",
            .{node.name},
        );
        defer allocator.free(msg);
        return IndexingToolResult.ok(allocator, msg);
    }

    // Add node to graph builder
    try context.graph_builder.nodes.put(node.name, node);
    context.stats.nodes_created += 1;

    // Return success with descriptive feedback
    const msg = try std.fmt.allocPrint(
        allocator,
        "Created node '{s}' (type: {s}, summary: {s})",
        .{ node.name, node.node_type.toString(), node.summary },
    );
    defer allocator.free(msg);
    return IndexingToolResult.ok(allocator, msg);
}

/// Get create_node tool definition for registry
pub fn getCreateNodeDefinition(allocator: std.mem.Allocator) !IndexingToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "create_node"),
                .description = try allocator.dupe(u8, "Create a node for graph rag."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "name": {
                    \\      "type": "string",
                    \\      "description": "Entity name"
                    \\    },
                    \\    "node_type": {
                    \\      "type": "string",
                    \\      "description": "Type: function, struct, section, concept"
                    \\    },
                    \\    "summary": {
                    \\      "type": "string",
                    \\      "description": "What it does"
                    \\    }
                    \\  },
                    \\  "required": ["name", "node_type", "summary"]
                    \\}
                ),
            },
        },
        .execute = executeCreateNode,
    };
}

/// Execute create_edge tool call
fn executeCreateEdge(
    allocator: std.mem.Allocator,
    arguments: []const u8,
    context: *IndexingContext,
) !IndexingToolResult {
    // Parse edge from JSON arguments
    var edge = Edge.fromToolCallArgs(allocator, arguments) catch |err| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "Failed to parse edge arguments: {}",
            .{err},
        );
        defer allocator.free(msg);
        context.stats.errors += 1;
        return IndexingToolResult.err(allocator, msg);
    };
    errdefer edge.deinit(allocator);

    // Validate from_node exists
    if (!context.graph_builder.nodes.contains(edge.from_node)) {
        edge.deinit(allocator);
        const msg = try std.fmt.allocPrint(
            allocator,
            "Edge references unknown from_node '{s}'. Create the node first with create_node.",
            .{edge.from_node},
        );
        defer allocator.free(msg);
        context.stats.errors += 1;
        return IndexingToolResult.err(allocator, msg);
    }

    // Validate to_node exists
    if (!context.graph_builder.nodes.contains(edge.to_node)) {
        edge.deinit(allocator);
        const msg = try std.fmt.allocPrint(
            allocator,
            "Edge references unknown to_node '{s}'. Create the node first with create_node.",
            .{edge.to_node},
        );
        defer allocator.free(msg);
        context.stats.errors += 1;
        return IndexingToolResult.err(allocator, msg);
    }

    // Add edge to graph builder
    try context.graph_builder.edges.append(allocator, edge);
    context.stats.edges_created += 1;

    // Return success with descriptive feedback
    const msg = try std.fmt.allocPrint(
        allocator,
        "Created edge: {s} -{s}-> {s}",
        .{ edge.from_node, edge.relationship.toString(), edge.to_node },
    );
    defer allocator.free(msg);
    return IndexingToolResult.ok(allocator, msg);
}

/// Get create_edge tool definition for registry
pub fn getCreateEdgeDefinition(allocator: std.mem.Allocator) !IndexingToolDefinition {
    return .{
        .ollama_tool = .{
            .type = "function",
            .function = .{
                .name = try allocator.dupe(u8, "create_edge"),
                .description = try allocator.dupe(u8, "Connect two nodes."),
                .parameters = try allocator.dupe(u8,
                    \\{
                    \\  "type": "object",
                    \\  "properties": {
                    \\    "from_node": {
                    \\      "type": "string",
                    \\      "description": "From"
                    \\    },
                    \\    "to_node": {
                    \\      "type": "string",
                    \\      "description": "To"
                    \\    },
                    \\    "relationship": {
                    \\      "type": "string",
                    \\      "description": "Type: calls, imports, references, relates_to"
                    \\    }
                    \\  },
                    \\  "required": ["from_node", "to_node", "relationship"]
                    \\}
                ),
            },
        },
        .execute = executeCreateEdge,
    };
}

// Note: getIndexingTools() has been moved to indexing_tool_registry.zig
// Use registry.getIndexingTools(allocator) instead
