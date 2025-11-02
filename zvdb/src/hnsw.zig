const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const StringHashMap = std.StringHashMap;
const Order = std.math.Order;
const Mutex = std.Thread.Mutex;

/// Metadata value types for flexible node attributes
pub const MetadataValue = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    bool: bool,

    pub fn deinit(self: *MetadataValue, allocator: Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            else => {},
        }
    }

    pub fn clone(self: MetadataValue, allocator: Allocator) !MetadataValue {
        return switch (self) {
            .string => |s| blk: {
                const owned = try allocator.alloc(u8, s.len);
                @memcpy(owned, s);
                break :blk MetadataValue{ .string = owned };
            },
            .int => |i| MetadataValue{ .int = i },
            .float => |f| MetadataValue{ .float = f },
            .bool => |b| MetadataValue{ .bool = b },
        };
    }
};

/// Rich metadata for graph nodes
pub const NodeMetadata = struct {
    node_type: []const u8, // e.g., "doc_chunk", "function", "entity"
    attributes: StringHashMap(MetadataValue),
    content_ref: ?[]const u8, // path/URI to content
    timestamp: i64, // creation/update time (Unix timestamp)

    pub fn init(allocator: Allocator, node_type: []const u8, content_ref: ?[]const u8) !NodeMetadata {
        const owned_type = try allocator.alloc(u8, node_type.len);
        @memcpy(owned_type, node_type);

        const owned_ref = if (content_ref) |ref| blk: {
            const owned = try allocator.alloc(u8, ref.len);
            @memcpy(owned, ref);
            break :blk owned;
        } else null;

        return NodeMetadata{
            .node_type = owned_type,
            .attributes = StringHashMap(MetadataValue).init(allocator),
            .content_ref = owned_ref,
            .timestamp = std.time.timestamp(),
        };
    }

    pub fn deinit(self: *NodeMetadata, allocator: Allocator) void {
        allocator.free(self.node_type);
        if (self.content_ref) |ref| {
            allocator.free(ref);
        }
        var it = self.attributes.iterator();
        while (it.next()) |entry| {
            var val = entry.value_ptr.*;
            val.deinit(allocator);
        }
        self.attributes.deinit();
    }

    pub fn setAttribute(self: *NodeMetadata, allocator: Allocator, key: []const u8, value: MetadataValue) !void {
        const owned_value = try value.clone(allocator);
        try self.attributes.put(key, owned_value);
    }

    pub fn getAttribute(self: *NodeMetadata, key: []const u8) ?MetadataValue {
        return self.attributes.get(key);
    }
};

/// Explicit typed edge between nodes
pub const Edge = struct {
    src: u64, // External ID of source node
    dst: u64, // External ID of destination node
    edge_type: []const u8, // e.g., "references", "contains", "calls"
    weight: f32, // Semantic strength (0.0-1.0)

    pub fn init(allocator: Allocator, src: u64, dst: u64, edge_type: []const u8, weight: f32) !Edge {
        const owned_type = try allocator.alloc(u8, edge_type.len);
        @memcpy(owned_type, edge_type);
        return Edge{
            .src = src,
            .dst = dst,
            .edge_type = owned_type,
            .weight = weight,
        };
    }

    pub fn deinit(self: *Edge, allocator: Allocator) void {
        allocator.free(self.edge_type);
    }
};

/// Key for uniquely identifying edges in HashMap
pub const EdgeKey = struct {
    src: u64,
    dst: u64,
    edge_type_hash: u64, // Hash of edge_type string

    pub fn init(src: u64, dst: u64, edge_type: []const u8) EdgeKey {
        return EdgeKey{
            .src = src,
            .dst = dst,
            .edge_type_hash = std.hash.Wyhash.hash(0, edge_type),
        };
    }
};

pub fn HNSW(comptime T: type) type {
    return struct {
        const Self = @This();

        const Node = struct {
            id: usize,
            point: []T,
            connections: []ArrayList(usize),
            metadata: ?NodeMetadata,
            mutex: Mutex,

            fn init(allocator: Allocator, id: usize, point: []const T, level: usize, metadata: ?NodeMetadata) !Node {
                const connections = try allocator.alloc(ArrayList(usize), level + 1);
                errdefer allocator.free(connections);
                for (connections) |*conn| {
                    conn.* = ArrayList(usize){};
                }
                const owned_point = try allocator.alloc(T, point.len);
                errdefer allocator.free(owned_point);
                @memcpy(owned_point, point);
                return Node{
                    .id = id,
                    .point = owned_point,
                    .connections = connections,
                    .metadata = metadata,
                    .mutex = Mutex{},
                };
            }

            fn deinit(self: *Node, allocator: Allocator) void {
                for (self.connections) |*conn| {
                    conn.deinit(allocator);
                }
                allocator.free(self.connections);
                allocator.free(self.point);
                if (self.metadata) |*meta| {
                    var m = meta.*;
                    m.deinit(allocator);
                }
            }
        };

        pub const SearchResult = struct {
            external_id: u64,
            point: []const T,
            distance: T,
        };

        allocator: Allocator,
        nodes: AutoHashMap(usize, Node),
        entry_point: ?usize,
        max_level: usize,
        m: usize,
        ef_construction: usize,
        mutex: Mutex,
        // ID mapping: external (user-provided) <-> internal (auto-generated)
        external_to_internal: AutoHashMap(u64, usize),
        internal_to_external: AutoHashMap(usize, u64),
        next_external_id: u64, // For auto-generating external IDs when not provided
        // Graph features
        edges: AutoHashMap(EdgeKey, Edge),
        type_index: StringHashMap(ArrayList(u64)), // node_type -> list of external IDs
        file_path_index: StringHashMap(ArrayList(u64)), // file_path -> list of external IDs

        pub fn init(allocator: Allocator, m: usize, ef_construction: usize) Self {
            return .{
                .allocator = allocator,
                .nodes = AutoHashMap(usize, Node).init(allocator),
                .entry_point = null,
                .max_level = 0,
                .m = m,
                .ef_construction = ef_construction,
                .mutex = Mutex{},
                .external_to_internal = AutoHashMap(u64, usize).init(allocator),
                .internal_to_external = AutoHashMap(usize, u64).init(allocator),
                .next_external_id = 0,
                .edges = AutoHashMap(EdgeKey, Edge).init(allocator),
                .type_index = StringHashMap(ArrayList(u64)).init(allocator),
                .file_path_index = StringHashMap(ArrayList(u64)).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.nodes.iterator();
            while (it.next()) |entry| {
                var node = entry.value_ptr;
                node.deinit(self.allocator);
            }
            self.nodes.deinit();
            self.external_to_internal.deinit();
            self.internal_to_external.deinit();

            // Clean up edges
            var edge_it = self.edges.iterator();
            while (edge_it.next()) |entry| {
                var edge = entry.value_ptr;
                edge.deinit(self.allocator);
            }
            self.edges.deinit();

            // Clean up type index
            var type_it = self.type_index.iterator();
            while (type_it.next()) |entry| {
                var list = entry.value_ptr;
                list.deinit(self.allocator);
            }
            self.type_index.deinit();

            // Clean up file_path index
            var file_path_it = self.file_path_index.iterator();
            while (file_path_it.next()) |entry| {
                var list = entry.value_ptr;
                list.deinit(self.allocator);
            }
            self.file_path_index.deinit();
        }

        pub fn insert(self: *Self, point: []const T, external_id: ?u64) !u64 {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Determine external ID (use provided or auto-generate)
            const ext_id = external_id orelse blk: {
                const auto_id = self.next_external_id;
                self.next_external_id += 1;
                break :blk auto_id;
            };

            // Check if external ID already exists
            if (self.external_to_internal.contains(ext_id)) {
                return error.DuplicateExternalId;
            }

            // Generate internal ID
            const internal_id = self.nodes.count();
            const level = self.randomLevel();
            var node = try Node.init(self.allocator, internal_id, point, level, null);
            errdefer node.deinit(self.allocator);

            // Store the node
            try self.nodes.put(internal_id, node);
            errdefer _ = self.nodes.remove(internal_id);

            // Store ID mappings
            try self.external_to_internal.put(ext_id, internal_id);
            errdefer _ = self.external_to_internal.remove(ext_id);
            try self.internal_to_external.put(internal_id, ext_id);
            errdefer _ = self.internal_to_external.remove(internal_id);

            if (self.entry_point) |entry| {
                var ep_copy = entry;
                var curr_dist = distance(node.point, self.nodes.get(ep_copy).?.point);

                for (0..self.max_level + 1) |layer| {
                    var changed = true;
                    while (changed) {
                        changed = false;
                        const curr_node = self.nodes.get(ep_copy).?;
                        if (layer < curr_node.connections.len) {
                            for (curr_node.connections[layer].items) |neighbor_id| {
                                const neighbor = self.nodes.get(neighbor_id).?;
                                const dist = distance(node.point, neighbor.point);
                                if (dist < curr_dist) {
                                    ep_copy = neighbor_id;
                                    curr_dist = dist;
                                    changed = true;
                                }
                            }
                        }
                    }

                    if (layer <= level) {
                        try self.connect(internal_id, ep_copy, @intCast(layer));
                    }
                }
            } else {
                self.entry_point = internal_id;
            }

            if (level > self.max_level) {
                self.max_level = level;
            }

            return ext_id;
        }

        /// Get the internal ID for a given external ID
        pub fn getInternalId(self: *Self, external_id: u64) ?usize {
            return self.external_to_internal.get(external_id);
        }

        /// Get the external ID for a given internal ID
        pub fn getExternalId(self: *Self, internal_id: usize) ?u64 {
            return self.internal_to_external.get(internal_id);
        }

        /// Get a node by its external ID
        pub fn getByExternalId(self: *Self, external_id: u64) ?Node {
            const internal_id = self.external_to_internal.get(external_id) orelse return null;
            return self.nodes.get(internal_id);
        }

        /// Insert a vector with metadata
        pub fn insertWithMetadata(self: *Self, point: []const T, external_id: ?u64, metadata: NodeMetadata) !u64 {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Determine external ID (use provided or auto-generate)
            const ext_id = external_id orelse blk: {
                const auto_id = self.next_external_id;
                self.next_external_id += 1;
                break :blk auto_id;
            };

            // Check if external ID already exists
            if (self.external_to_internal.contains(ext_id)) {
                return error.DuplicateExternalId;
            }

            // Generate internal ID and create node with metadata
            const internal_id = self.nodes.count();
            const level = self.randomLevel();
            var node = try Node.init(self.allocator, internal_id, point, level, metadata);
            errdefer node.deinit(self.allocator);

            // Store the node
            try self.nodes.put(internal_id, node);
            errdefer _ = self.nodes.remove(internal_id);

            // Store ID mappings
            try self.external_to_internal.put(ext_id, internal_id);
            errdefer _ = self.external_to_internal.remove(ext_id);
            try self.internal_to_external.put(internal_id, ext_id);
            errdefer _ = self.internal_to_external.remove(internal_id);

            // Update type index
            if (node.metadata) |meta| {
                try self.addToTypeIndex(meta.node_type, ext_id);
                // Update file_path index
                if (meta.content_ref) |file_path| {
                    try self.addToFilePathIndex(file_path, ext_id);
                }
            }

            // Build HNSW connections
            if (self.entry_point) |entry| {
                var ep_copy = entry;
                var curr_dist = distance(node.point, self.nodes.get(ep_copy).?.point);

                for (0..self.max_level + 1) |layer| {
                    var changed = true;
                    while (changed) {
                        changed = false;
                        const curr_node = self.nodes.get(ep_copy).?;
                        if (layer < curr_node.connections.len) {
                            for (curr_node.connections[layer].items) |neighbor_id| {
                                const neighbor = self.nodes.get(neighbor_id).?;
                                const dist = distance(node.point, neighbor.point);
                                if (dist < curr_dist) {
                                    ep_copy = neighbor_id;
                                    curr_dist = dist;
                                    changed = true;
                                }
                            }
                        }
                    }

                    if (layer <= level) {
                        try self.connect(internal_id, ep_copy, @intCast(layer));
                    }
                }
            } else {
                self.entry_point = internal_id;
            }

            if (level > self.max_level) {
                self.max_level = level;
            }

            return ext_id;
        }

        /// Update metadata for an existing node
        pub fn updateMetadata(self: *Self, external_id: u64, new_metadata: NodeMetadata) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const internal_id = self.external_to_internal.get(external_id) orelse return error.NodeNotFound;
            var node = self.nodes.getPtr(internal_id) orelse return error.NodeNotFound;

            // Remove from old type index and file_path index
            if (node.metadata) |old_meta| {
                try self.removeFromTypeIndex(old_meta.node_type, external_id);
                if (old_meta.content_ref) |old_path| {
                    try self.removeFromFilePathIndex(old_path, external_id);
                }
                var m = old_meta;
                m.deinit(self.allocator);
            }

            // Update metadata
            node.metadata = new_metadata;

            // Add to new type index and file_path index
            try self.addToTypeIndex(new_metadata.node_type, external_id);
            if (new_metadata.content_ref) |new_path| {
                try self.addToFilePathIndex(new_path, external_id);
            }
        }

        /// Get all node IDs of a specific type
        pub fn getNodesByType(self: *Self, node_type: []const u8) ![]const u64 {
            self.mutex.lock();
            defer self.mutex.unlock();

            const list = self.type_index.get(node_type) orelse {
                // Return empty slice if type not found
                return &[_]u64{};
            };

            // Return a copy of the list
            const result = try self.allocator.alloc(u64, list.items.len);
            @memcpy(result, list.items);
            return result;
        }

        /// Get all node IDs from a specific file path
        pub fn getNodesByFilePath(self: *Self, file_path: []const u8) ![]const u64 {
            self.mutex.lock();
            defer self.mutex.unlock();

            const list = self.file_path_index.get(file_path) orelse {
                // Return empty slice if file_path not found
                return &[_]u64{};
            };

            // Return a copy of the list
            const result = try self.allocator.alloc(u64, list.items.len);
            @memcpy(result, list.items);
            return result;
        }

        /// Helper: Add external ID to type index
        fn addToTypeIndex(self: *Self, node_type: []const u8, external_id: u64) !void {
            var result = try self.type_index.getOrPut(node_type);
            if (!result.found_existing) {
                result.value_ptr.* = ArrayList(u64){};
            }
            try result.value_ptr.append(self.allocator, external_id);
        }

        /// Helper: Remove external ID from type index
        fn removeFromTypeIndex(self: *Self, node_type: []const u8, external_id: u64) !void {
            var list = self.type_index.getPtr(node_type) orelse return;
            for (list.items, 0..) |id, i| {
                if (id == external_id) {
                    _ = list.swapRemove(i);
                    break;
                }
            }
        }

        /// Helper: Add external ID to file_path index
        fn addToFilePathIndex(self: *Self, file_path: []const u8, external_id: u64) !void {
            var result = try self.file_path_index.getOrPut(file_path);
            if (!result.found_existing) {
                result.value_ptr.* = ArrayList(u64){};
            }
            try result.value_ptr.append(self.allocator, external_id);
        }

        /// Helper: Remove external ID from file_path index
        fn removeFromFilePathIndex(self: *Self, file_path: []const u8, external_id: u64) !void {
            var list = self.file_path_index.getPtr(file_path) orelse return;
            for (list.items, 0..) |id, i| {
                if (id == external_id) {
                    _ = list.swapRemove(i);
                    break;
                }
            }
        }

        /// Add a typed edge between two nodes
        pub fn addEdge(self: *Self, src: u64, dst: u64, edge_type: []const u8, weight: f32) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Verify both nodes exist
            if (!self.external_to_internal.contains(src)) return error.SourceNodeNotFound;
            if (!self.external_to_internal.contains(dst)) return error.DestinationNodeNotFound;

            // Create edge and key
            const edge = try Edge.init(self.allocator, src, dst, edge_type, weight);
            const key = EdgeKey.init(src, dst, edge_type);

            // Store edge (overwrites if exists)
            try self.edges.put(key, edge);
        }

        /// Remove a typed edge
        pub fn removeEdge(self: *Self, src: u64, dst: u64, edge_type: []const u8) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const key = EdgeKey.init(src, dst, edge_type);
            if (self.edges.fetchRemove(key)) |kv| {
                var edge = kv.value;
                edge.deinit(self.allocator);
            } else {
                return error.EdgeNotFound;
            }
        }

        /// Get all edges for a node (optionally filtered by type)
        pub fn getEdges(self: *Self, node_id: u64, edge_type_filter: ?[]const u8) ![]const Edge {
            self.mutex.lock();
            defer self.mutex.unlock();

            var result = ArrayList(Edge){};
            errdefer result.deinit(self.allocator);

            var it = self.edges.iterator();
            while (it.next()) |entry| {
                const edge = entry.value_ptr.*;

                // Check if edge involves this node
                const involves_node = edge.src == node_id or edge.dst == node_id;
                if (!involves_node) continue;

                // Apply type filter if provided
                if (edge_type_filter) |filter| {
                    if (!std.mem.eql(u8, edge.edge_type, filter)) continue;
                }

                // Clone edge for return
                const cloned = try Edge.init(self.allocator, edge.src, edge.dst, edge.edge_type, edge.weight);
                try result.append(self.allocator, cloned);
            }

            return result.toOwnedSlice(self.allocator);
        }

        /// Get neighboring node IDs (optionally filtered by edge type)
        pub fn getNeighbors(self: *Self, node_id: u64, edge_type_filter: ?[]const u8) ![]const u64 {
            self.mutex.lock();
            defer self.mutex.unlock();

            var result = ArrayList(u64){};
            errdefer result.deinit(self.allocator);

            var it = self.edges.iterator();
            while (it.next()) |entry| {
                const edge = entry.value_ptr.*;

                // Apply type filter if provided
                if (edge_type_filter) |filter| {
                    if (!std.mem.eql(u8, edge.edge_type, filter)) continue;
                }

                // Add neighbor ID
                if (edge.src == node_id) {
                    try result.append(self.allocator, edge.dst);
                } else if (edge.dst == node_id) {
                    try result.append(self.allocator, edge.src);
                }
            }

            return result.toOwnedSlice(self.allocator);
        }

        /// Get incoming edges for a node
        pub fn getIncoming(self: *Self, node_id: u64, edge_type_filter: ?[]const u8) ![]const Edge {
            self.mutex.lock();
            defer self.mutex.unlock();

            var result = ArrayList(Edge){};
            errdefer result.deinit(self.allocator);

            var it = self.edges.iterator();
            while (it.next()) |entry| {
                const edge = entry.value_ptr.*;

                // Only include edges where this node is the destination
                if (edge.dst != node_id) continue;

                // Apply type filter if provided
                if (edge_type_filter) |filter| {
                    if (!std.mem.eql(u8, edge.edge_type, filter)) continue;
                }

                // Clone edge for return
                const cloned = try Edge.init(self.allocator, edge.src, edge.dst, edge.edge_type, edge.weight);
                try result.append(self.allocator, cloned);
            }

            return result.toOwnedSlice(self.allocator);
        }

        /// Get outgoing edges for a node
        pub fn getOutgoing(self: *Self, node_id: u64, edge_type_filter: ?[]const u8) ![]const Edge {
            self.mutex.lock();
            defer self.mutex.unlock();

            var result = ArrayList(Edge){};
            errdefer result.deinit(self.allocator);

            var it = self.edges.iterator();
            while (it.next()) |entry| {
                const edge = entry.value_ptr.*;

                // Only include edges where this node is the source
                if (edge.src != node_id) continue;

                // Apply type filter if provided
                if (edge_type_filter) |filter| {
                    if (!std.mem.eql(u8, edge.edge_type, filter)) continue;
                }

                // Clone edge for return
                const cloned = try Edge.init(self.allocator, edge.src, edge.dst, edge.edge_type, edge.weight);
                try result.append(self.allocator, cloned);
            }

            return result.toOwnedSlice(self.allocator);
        }

        /// BFS traversal from a starting node up to max_depth
        pub fn traverse(self: *Self, start_id: u64, max_depth: usize, edge_type_filter: ?[]const u8) ![]const u64 {
            self.mutex.lock();
            defer self.mutex.unlock();

            var visited = AutoHashMap(u64, void).init(self.allocator);
            defer visited.deinit();

            var queue = ArrayList(struct { id: u64, depth: usize }){};
            defer queue.deinit(self.allocator);

            var result = ArrayList(u64){};
            errdefer result.deinit(self.allocator);

            // Start with the initial node
            try queue.append(self.allocator, .{ .id = start_id, .depth = 0 });
            try visited.put(start_id, {});
            try result.append(self.allocator, start_id);

            var queue_idx: usize = 0;
            while (queue_idx < queue.items.len) : (queue_idx += 1) {
                const current = queue.items[queue_idx];

                // Stop if we've reached max depth
                if (current.depth >= max_depth) continue;

                // Get neighbors
                var it = self.edges.iterator();
                while (it.next()) |entry| {
                    const edge = entry.value_ptr.*;

                    // Apply type filter if provided
                    if (edge_type_filter) |filter| {
                        if (!std.mem.eql(u8, edge.edge_type, filter)) continue;
                    }

                    // Find neighbor ID
                    const neighbor_id = if (edge.src == current.id)
                        edge.dst
                    else if (edge.dst == current.id)
                        edge.src
                    else
                        continue;

                    // Add if not visited
                    if (!visited.contains(neighbor_id)) {
                        try visited.put(neighbor_id, {});
                        try queue.append(self.allocator, .{ .id = neighbor_id, .depth = current.depth + 1 });
                        try result.append(self.allocator, neighbor_id);
                    }
                }
            }

            return result.toOwnedSlice(self.allocator);
        }

        // Helper to write integers for persistence
        fn writeIntToFile(file: std.fs.File, comptime IntType: type, value: IntType) !void {
            var bytes: [@sizeOf(IntType)]u8 = undefined;
            std.mem.writeInt(IntType, &bytes, value, .little);
            try file.writeAll(&bytes);
        }

        // Helper to read integers for persistence
        fn readIntFromFile(file: std.fs.File, comptime IntType: type) !IntType {
            var bytes: [@sizeOf(IntType)]u8 = undefined;
            const n = try file.readAll(&bytes);
            if (n != @sizeOf(IntType)) return error.UnexpectedEOF;
            return std.mem.readInt(IntType, &bytes, .little);
        }

        /// Save the index to a file
        pub fn save(self: *Self, path: []const u8) !void {
            // Ensure parent directory exists
            if (std.fs.path.dirname(path)) |dir_path| {
                std.fs.cwd().makePath(dir_path) catch |err| switch (err) {
                    error.PathAlreadyExists => {}, // Directory already exists, that's fine
                    else => return err,
                };
            }

            const file = try std.fs.cwd().createFile(path, .{});
            defer file.close();

            // Write header
            const magic: u32 = 0x48_4E_53_57; // "HNSW"
            const version: u32 = 2; // Bumped to v2 for metadata/edge support
            try writeIntToFile(file, u32, magic);
            try writeIntToFile(file, u32, version);

            // Write configuration
            try writeIntToFile(file, u64, self.m);
            try writeIntToFile(file, u64, self.ef_construction);
            try writeIntToFile(file, u64, self.max_level);
            try writeIntToFile(file, u64, self.next_external_id);

            // Write entry point
            const has_entry = self.entry_point != null;
            try writeIntToFile(file, u8, if (has_entry) 1 else 0);
            if (has_entry) {
                try writeIntToFile(file, u64, self.entry_point.?);
            }

            // Write node count
            const node_count = self.nodes.count();
            try writeIntToFile(file, u64, node_count);

            if (node_count == 0) return;

            // Get dimension from first node
            var it = self.nodes.iterator();
            const first_node = it.next().?.value_ptr;
            const dim = first_node.point.len;
            try writeIntToFile(file, u64, dim);

            // Write all nodes
            it = self.nodes.iterator();
            while (it.next()) |entry| {
                const internal_id = entry.key_ptr.*;
                const node = entry.value_ptr.*;
                const external_id = self.internal_to_external.get(internal_id) orelse return error.MissingExternalId;

                // Write IDs
                try writeIntToFile(file, u64, internal_id);
                try writeIntToFile(file, u64, external_id);

                // Write level (number of connection layers - 1)
                const level = node.connections.len - 1;
                try writeIntToFile(file, u64, level);

                // Write point data
                for (node.point) |val| {
                    try file.writeAll(std.mem.asBytes(&val));
                }

                // Write connections for each layer
                for (node.connections) |conn_list| {
                    const conn_count = conn_list.items.len;
                    try writeIntToFile(file, u64, conn_count);
                    for (conn_list.items) |conn_id| {
                        try writeIntToFile(file, u64, conn_id);
                    }
                }

                // Write metadata (v2 feature)
                const has_metadata = node.metadata != null;
                try writeIntToFile(file, u8, if (has_metadata) 1 else 0);
                if (has_metadata) {
                    const meta = node.metadata.?;

                    // Write node_type
                    try writeIntToFile(file, u64, meta.node_type.len);
                    try file.writeAll(meta.node_type);

                    // Write content_ref
                    const has_content_ref = meta.content_ref != null;
                    try writeIntToFile(file, u8, if (has_content_ref) 1 else 0);
                    if (has_content_ref) {
                        const ref = meta.content_ref.?;
                        try writeIntToFile(file, u64, ref.len);
                        try file.writeAll(ref);
                    }

                    // Write timestamp
                    try writeIntToFile(file, i64, meta.timestamp);

                    // Write attributes count
                    const attr_count = meta.attributes.count();
                    try writeIntToFile(file, u64, attr_count);

                    // Write each attribute
                    var attr_it = meta.attributes.iterator();
                    while (attr_it.next()) |attr_entry| {
                        const key = attr_entry.key_ptr.*;
                        const value = attr_entry.value_ptr.*;

                        // Write key
                        try writeIntToFile(file, u64, key.len);
                        try file.writeAll(key);

                        // Write value type and data
                        const value_tag = @intFromEnum(value);
                        try writeIntToFile(file, u8, value_tag);
                        switch (value) {
                            .string => |s| {
                                try writeIntToFile(file, u64, s.len);
                                try file.writeAll(s);
                            },
                            .int => |i| try writeIntToFile(file, i64, i),
                            .float => |f| try file.writeAll(std.mem.asBytes(&f)),
                            .bool => |b| try writeIntToFile(file, u8, if (b) 1 else 0),
                        }
                    }
                }
            }

            // Write edges (v2 feature)
            const edge_count = self.edges.count();
            try writeIntToFile(file, u64, edge_count);

            var edge_it = self.edges.iterator();
            while (edge_it.next()) |entry| {
                const edge = entry.value_ptr.*;

                try writeIntToFile(file, u64, edge.src);
                try writeIntToFile(file, u64, edge.dst);
                try writeIntToFile(file, u64, edge.edge_type.len);
                try file.writeAll(edge.edge_type);
                try file.writeAll(std.mem.asBytes(&edge.weight));
            }
        }

        /// Load the index from a file
        pub fn load(allocator: Allocator, path: []const u8) !Self {
            const file = try std.fs.cwd().openFile(path, .{});
            defer file.close();

            // Read and verify header
            const magic = try readIntFromFile(file, u32);
            if (magic != 0x48_4E_53_57) return error.InvalidFileFormat;

            const version = try readIntFromFile(file, u32);
            if (version != 1 and version != 2) return error.UnsupportedVersion;

            // Read configuration
            const m = try readIntFromFile(file, u64);
            const ef_construction = try readIntFromFile(file, u64);
            const max_level = try readIntFromFile(file, u64);
            const next_external_id = try readIntFromFile(file, u64);

            // Read entry point
            const has_entry = (try readIntFromFile(file, u8)) != 0;
            const entry_point: ?usize = if (has_entry) try readIntFromFile(file, u64) else null;

            // Read node count
            const node_count = try readIntFromFile(file, u64);

            // Initialize HNSW
            var self = Self.init(allocator, m, ef_construction);
            errdefer self.deinit();

            self.max_level = max_level;
            self.next_external_id = next_external_id;
            self.entry_point = entry_point;

            if (node_count == 0) return self;

            // Read dimension
            const dim = try readIntFromFile(file, u64);

            // Read all nodes
            for (0..node_count) |_| {
                // Read IDs
                const internal_id = try readIntFromFile(file, u64);
                const external_id = try readIntFromFile(file, u64);

                // Read level
                const level = try readIntFromFile(file, u64);

                // Read point data
                const point = try allocator.alloc(T, dim);
                errdefer allocator.free(point);

                for (point) |*val| {
                    var bytes: [@sizeOf(T)]u8 = undefined;
                    const n = try file.readAll(&bytes);
                    if (n != @sizeOf(T)) return error.UnexpectedEOF;
                    val.* = std.mem.bytesToValue(T, &bytes);
                }

                // Create node
                const connections = try allocator.alloc(ArrayList(usize), level + 1);
                errdefer allocator.free(connections);

                for (connections) |*conn| {
                    conn.* = ArrayList(usize){};
                }

                var node = Node{
                    .id = internal_id,
                    .point = point,
                    .connections = connections,
                    .metadata = null,
                    .mutex = Mutex{},
                };
                errdefer node.deinit(allocator);

                // Read connections for each layer
                for (node.connections) |*conn_list| {
                    const conn_count = try readIntFromFile(file, u64);
                    try conn_list.ensureTotalCapacity(allocator, conn_count);

                    for (0..conn_count) |_| {
                        const conn_id = try readIntFromFile(file, u64);
                        try conn_list.append(allocator, conn_id);
                    }
                }

                // Read metadata (v2 only)
                if (version == 2) {
                    const has_metadata = (try readIntFromFile(file, u8)) != 0;
                    if (has_metadata) {
                        // Read node_type
                        const type_len = try readIntFromFile(file, u64);
                        const node_type = try allocator.alloc(u8, type_len);
                        errdefer allocator.free(node_type);
                        _ = try file.readAll(node_type);

                        // Read content_ref
                        const has_content_ref = (try readIntFromFile(file, u8)) != 0;
                        const content_ref: ?[]const u8 = if (has_content_ref) blk: {
                            const ref_len = try readIntFromFile(file, u64);
                            const ref = try allocator.alloc(u8, ref_len);
                            errdefer allocator.free(ref);
                            _ = try file.readAll(ref);
                            break :blk ref;
                        } else null;

                        // Read timestamp
                        const timestamp = try readIntFromFile(file, i64);

                        // Create metadata
                        var metadata = NodeMetadata{
                            .node_type = node_type,
                            .attributes = StringHashMap(MetadataValue).init(allocator),
                            .content_ref = content_ref,
                            .timestamp = timestamp,
                        };
                        errdefer metadata.deinit(allocator);

                        // Read attributes
                        const attr_count = try readIntFromFile(file, u64);
                        var attr_keys = try allocator.alloc([]u8, attr_count);
                        defer allocator.free(attr_keys);

                        for (0..attr_count) |i| {
                            // Read key
                            const key_len = try readIntFromFile(file, u64);
                            const key = try allocator.alloc(u8, key_len);
                            attr_keys[i] = key;
                            _ = try file.readAll(key);

                            // Read value
                            const value_tag = try readIntFromFile(file, u8);
                            const value: MetadataValue = switch (value_tag) {
                                0 => blk: { // string
                                    const str_len = try readIntFromFile(file, u64);
                                    const str = try allocator.alloc(u8, str_len);
                                    _ = try file.readAll(str);
                                    break :blk MetadataValue{ .string = str };
                                },
                                1 => MetadataValue{ .int = try readIntFromFile(file, i64) }, // int
                                2 => blk: { // float
                                    var bytes: [@sizeOf(f64)]u8 = undefined;
                                    _ = try file.readAll(&bytes);
                                    break :blk MetadataValue{ .float = std.mem.bytesToValue(f64, &bytes) };
                                },
                                3 => blk: { // bool
                                    const b = (try readIntFromFile(file, u8)) != 0;
                                    break :blk MetadataValue{ .bool = b };
                                },
                                else => return error.InvalidMetadataValueType,
                            };

                            try metadata.attributes.put(key, value);
                        }

                        node.metadata = metadata;

                        // Add to type index
                        try self.addToTypeIndex(metadata.node_type, external_id);
                        // Add to file_path index
                        if (metadata.content_ref) |file_path| {
                            try self.addToFilePathIndex(file_path, external_id);
                        }
                    }
                }

                // Store node and ID mappings
                try self.nodes.put(internal_id, node);
                try self.external_to_internal.put(external_id, internal_id);
                try self.internal_to_external.put(internal_id, external_id);
            }

            // Read edges (v2 only)
            if (version == 2) {
                const edge_count = try readIntFromFile(file, u64);
                for (0..edge_count) |_| {
                    const src = try readIntFromFile(file, u64);
                    const dst = try readIntFromFile(file, u64);

                    const type_len = try readIntFromFile(file, u64);
                    const edge_type = try allocator.alloc(u8, type_len);
                    errdefer allocator.free(edge_type);
                    _ = try file.readAll(edge_type);

                    var weight_bytes: [@sizeOf(f32)]u8 = undefined;
                    _ = try file.readAll(&weight_bytes);
                    const weight = std.mem.bytesToValue(f32, &weight_bytes);

                    const edge = Edge{
                        .src = src,
                        .dst = dst,
                        .edge_type = edge_type,
                        .weight = weight,
                    };

                    const key = EdgeKey.init(src, dst, edge_type);
                    try self.edges.put(key, edge);
                }
            }

            return self;
        }

        fn connect(self: *Self, source: usize, target: usize, level: usize) !void {
            var source_node = self.nodes.getPtr(source) orelse return error.NodeNotFound;
            var target_node = self.nodes.getPtr(target) orelse return error.NodeNotFound;

            source_node.mutex.lock();
            defer source_node.mutex.unlock();
            target_node.mutex.lock();
            defer target_node.mutex.unlock();

            if (level < source_node.connections.len) {
                try source_node.connections[level].append(self.allocator, target);
            }
            if (level < target_node.connections.len) {
                try target_node.connections[level].append(self.allocator, source);
            }

            if (level < source_node.connections.len) {
                try self.shrinkConnections(source, level);
            }
            if (level < target_node.connections.len) {
                try self.shrinkConnections(target, level);
            }
        }

        fn shrinkConnections(self: *Self, node_id: usize, level: usize) !void {
            var node = self.nodes.getPtr(node_id).?;
            var connections = &node.connections[level];
            if (connections.items.len <= self.m) return;

            var candidates = try self.allocator.alloc(usize, connections.items.len);
            defer self.allocator.free(candidates);
            @memcpy(candidates, connections.items);

            const Context = struct {
                self: *Self,
                node: *Node,
            };
            const context = Context{ .self = self, .node = node };

            const compareFn = struct {
                fn compare(ctx: Context, a: usize, b: usize) bool {
                    const dist_a = distance(ctx.node.point, ctx.self.nodes.get(a).?.point);
                    const dist_b = distance(ctx.node.point, ctx.self.nodes.get(b).?.point);
                    return dist_a < dist_b;
                }
            }.compare;

            std.sort.insertion(usize, candidates, context, compareFn);

            connections.shrinkRetainingCapacity(self.m);
            @memcpy(connections.items, candidates[0..self.m]);
        }

        fn randomLevel(self: *Self) usize {
            _ = self;
            var level: usize = 0;
            const max_level = 31;
            while (level < max_level and std.crypto.random.float(f32) < 0.5) {
                level += 1;
            }
            return level;
        }

        fn distance(a: []const T, b: []const T) T {
            if (a.len != b.len) {
                @panic("Mismatched dimensions in distance calculation");
            }

            // Cosine distance: 1 - cosine_similarity
            // cosine_similarity = dot_product / (||a|| * ||b||)
            // Note: This implementation requires floating-point types (f16, f32, f64)
            var dot_product: T = 0;
            var norm_a: T = 0;
            var norm_b: T = 0;

            for (a, 0..) |_, i| {
                dot_product += a[i] * b[i];
                norm_a += a[i] * a[i];
                norm_b += b[i] * b[i];
            }

            // Handle edge case: zero vectors
            if (norm_a == 0 or norm_b == 0) {
                return 1.0; // Maximum distance for zero vectors
            }

            // Calculate cosine similarity and return cosine distance
            const norm_product = std.math.sqrt(norm_a) * std.math.sqrt(norm_b);
            const cosine_similarity = dot_product / norm_product;

            // Clamp to [-1, 1] range to handle floating point errors
            const clamped = @max(-1.0, @min(1.0, cosine_similarity));

            return 1.0 - clamped;
        }

        pub fn search(self: *Self, query: []const T, k: usize) ![]const SearchResult {
            self.mutex.lock();
            defer self.mutex.unlock();

            var result = try ArrayList(SearchResult).initCapacity(self.allocator, k);
            errdefer result.deinit(self.allocator);

            if (self.entry_point) |entry| {
                var candidates = std.PriorityQueue(CandidateNode, void, CandidateNode.lessThan).init(self.allocator, {});
                defer candidates.deinit();

                var visited = std.AutoHashMap(usize, void).init(self.allocator);
                defer visited.deinit();

                try candidates.add(.{ .id = entry, .distance = distance(query, self.nodes.get(entry).?.point) });
                try visited.put(entry, {});

                while (candidates.count() > 0 and result.items.len < k) {
                    const current = candidates.remove();
                    const current_node = self.nodes.get(current.id).?;
                    const external_id = self.internal_to_external.get(current_node.id) orelse continue;

                    try result.append(self.allocator, SearchResult{
                        .external_id = external_id,
                        .point = current_node.point,
                        .distance = distance(query, current_node.point),
                    });

                    for (current_node.connections[0].items) |neighbor_id| {
                        if (!visited.contains(neighbor_id)) {
                            const neighbor = self.nodes.get(neighbor_id).?;
                            const dist = distance(query, neighbor.point);
                            try candidates.add(.{ .id = neighbor_id, .distance = dist });
                            try visited.put(neighbor_id, {});
                        }
                    }
                }
            }

            const Context = struct {
                pub fn lessThan(_: @This(), a: SearchResult, b: SearchResult) bool {
                    return a.distance < b.distance;
                }
            };
            std.sort.insertion(SearchResult, result.items, Context{}, Context.lessThan);

            return result.toOwnedSlice(self.allocator);
        }

        /// Search for k nearest neighbors, filtered by node type
        pub fn searchByType(self: *Self, query: []const T, k: usize, node_type: []const u8) ![]const SearchResult {
            self.mutex.lock();
            defer self.mutex.unlock();

            var result = try ArrayList(SearchResult).initCapacity(self.allocator, k);
            errdefer result.deinit(self.allocator);

            if (self.entry_point) |entry| {
                var candidates = std.PriorityQueue(CandidateNode, void, CandidateNode.lessThan).init(self.allocator, {});
                defer candidates.deinit();

                var visited = std.AutoHashMap(usize, void).init(self.allocator);
                defer visited.deinit();

                try candidates.add(.{ .id = entry, .distance = distance(query, self.nodes.get(entry).?.point) });
                try visited.put(entry, {});

                while (candidates.count() > 0 and result.items.len < k) {
                    const current = candidates.remove();
                    const current_node = self.nodes.get(current.id).?;
                    const external_id = self.internal_to_external.get(current_node.id) orelse continue;

                    // Filter by node type
                    const matches_type = if (current_node.metadata) |meta|
                        std.mem.eql(u8, meta.node_type, node_type)
                    else
                        false;

                    if (matches_type) {
                        try result.append(self.allocator, SearchResult{
                            .external_id = external_id,
                            .point = current_node.point,
                            .distance = distance(query, current_node.point),
                        });
                    }

                    for (current_node.connections[0].items) |neighbor_id| {
                        if (!visited.contains(neighbor_id)) {
                            const neighbor = self.nodes.get(neighbor_id).?;
                            const dist = distance(query, neighbor.point);
                            try candidates.add(.{ .id = neighbor_id, .distance = dist });
                            try visited.put(neighbor_id, {});
                        }
                    }
                }
            }

            const Context = struct {
                pub fn lessThan(_: @This(), a: SearchResult, b: SearchResult) bool {
                    return a.distance < b.distance;
                }
            };
            std.sort.insertion(SearchResult, result.items, Context{}, Context.lessThan);

            return result.toOwnedSlice(self.allocator);
        }

        /// Hybrid query: search for similar nodes, then traverse their graph neighbors
        pub fn searchThenTraverse(
            self: *Self,
            query: []const T,
            k: usize,
            edge_type_filter: ?[]const u8,
            max_depth: usize,
        ) ![]const u64 {
            // First, perform vector search to get top-k similar nodes
            const search_results = try self.search(query, k);
            defer self.allocator.free(search_results);

            var all_nodes = AutoHashMap(u64, void).init(self.allocator);
            defer all_nodes.deinit();

            // Add all search result IDs
            for (search_results) |result| {
                try all_nodes.put(result.external_id, {});
            }

            // For each search result, traverse the graph
            for (search_results) |result| {
                const traversed = try self.traverse(result.external_id, max_depth, edge_type_filter);
                defer self.allocator.free(traversed);

                for (traversed) |node_id| {
                    try all_nodes.put(node_id, {});
                }
            }

            // Convert set to slice
            var result_list = ArrayList(u64){};
            errdefer result_list.deinit(self.allocator);

            var it = all_nodes.keyIterator();
            while (it.next()) |key| {
                try result_list.append(self.allocator, key.*);
            }

            return result_list.toOwnedSlice(self.allocator);
        }

        const CandidateNode = struct {
            id: usize,
            distance: T,

            fn lessThan(_: void, a: CandidateNode, b: CandidateNode) std.math.Order {
                return std.math.order(a.distance, b.distance);
            }
        };
    };
}
