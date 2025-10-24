# zvdb
A pure Zig vector database implementation using HNSW (Hierarchical Navigable Small World) for fast approximate nearest neighbor search.

## Features

### Vector Search
- **Cosine Similarity**: Optimized for embedding vectors (768/1024 dimensions)
- **Custom IDs**: Map vectors to your own identifiers (u64)
- **Persistence**: Save and load indices to/from disk (v2 format with metadata/edges)
- **Thread-Safe**: Concurrent insertions and searches
- **Generic Types**: Works with f32, f64, and other float types

### GraphRAG Support
- **Node Metadata**: Store typed nodes with rich attributes (doc_chunk, function, entity, etc.)
- **Typed Edges**: Explicit relationships between nodes with weights
- **Graph Traversal**: BFS traversal with depth limits and edge type filtering
- **Hybrid Queries**: Combine vector similarity with graph relationships
- **Type Filtering**: Search by node type for precise retrieval
- **Metadata Attributes**: Flexible key-value storage (string, int, float, bool)

## Requirements

- Zig 0.15.2 or later

## Quick Start

```zig
const std = @import("std");
const HNSW = @import("zvdb").HNSW;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create index (M=16, ef_construction=200)
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    // Insert vectors with custom IDs
    const id1 = try hnsw.insert(&[_]f32{ 1.0, 2.0, 3.0 }, 100);
    const id2 = try hnsw.insert(&[_]f32{ 4.0, 5.0, 6.0 }, 200);

    // Insert with auto-generated IDs
    const id3 = try hnsw.insert(&[_]f32{ 7.0, 8.0, 9.0 }, null);

    // Search for k nearest neighbors
    const query = &[_]f32{ 3.0, 4.0, 5.0 };
    const results = try hnsw.search(query, 5);
    defer allocator.free(results);

    for (results) |result| {
        std.debug.print("ID: {}, Distance: {d:.4}\n",
            .{ result.external_id, result.distance });
    }

    // Save to disk
    try hnsw.save("index.bin");
}
```

## Persistence

```zig
// Save index (includes metadata and edges in v2 format)
try hnsw.save("my_index.bin");

// Load index
var loaded = try HNSW(f32).load(allocator, "my_index.bin");
defer loaded.deinit();
```

## GraphRAG Usage

### Nodes with Metadata

```zig
const zvdb = @import("zvdb");
const NodeMetadata = zvdb.NodeMetadata;
const MetadataValue = zvdb.MetadataValue;

// Create metadata for a document chunk
var doc_metadata = try NodeMetadata.init(allocator, "doc_chunk", "path/to/file.zig");
try doc_metadata.setAttribute(allocator, "file", MetadataValue{ .string = "parser.zig" });
try doc_metadata.setAttribute(allocator, "line_start", MetadataValue{ .int = 100 });
try doc_metadata.setAttribute(allocator, "line_end", MetadataValue{ .int = 150 });

// Insert node with metadata
const embedding = &[_]f32{ 0.1, 0.2, 0.3, ... };
const doc_id = try hnsw.insertWithMetadata(embedding, null, doc_metadata);

// Query nodes by type
const doc_chunks = try hnsw.getNodesByType("doc_chunk");
defer allocator.free(doc_chunks);
```

### Graph Relationships

```zig
// Add typed edges between nodes
try hnsw.addEdge(func_id, doc_id, "references", 0.8);
try hnsw.addEdge(chunk1_id, chunk2_id, "follows", 1.0);
try hnsw.addEdge(entity_id, func_id, "mentions", 0.9);

// Get neighbors by edge type
const referenced_docs = try hnsw.getNeighbors(func_id, "references");
defer allocator.free(referenced_docs);

// Get incoming/outgoing edges
const incoming = try hnsw.getIncoming(doc_id, "references");
defer {
    for (incoming) |edge| {
        var e = edge;
        e.deinit(allocator);
    }
    allocator.free(incoming);
}
```

### Graph Traversal

```zig
// BFS traversal with max depth and edge type filtering
const related_nodes = try hnsw.traverse(
    start_node_id,
    3, // max depth
    "references" // edge type filter (or null for all types)
);
defer allocator.free(related_nodes);
```

### Hybrid Queries

```zig
// Search by node type
const query_embedding = &[_]f32{ 0.5, 0.3, 0.2, ... };
const similar_chunks = try hnsw.searchByType(query_embedding, 5, "doc_chunk");
defer allocator.free(similar_chunks);

// Search then traverse: find similar nodes, then expand via graph
const expanded_results = try hnsw.searchThenTraverse(
    query_embedding,
    5, // top-k vector results
    "references", // edge type to traverse
    2 // traversal depth
);
defer allocator.free(expanded_results);
```

## Building

```bash
zig build        # Build library
zig build test   # Run tests
```

## Recent Updates

- **2025-10-20**: GraphRAG MVP Release
  - **Node Metadata**: Rich typed nodes with flexible attributes
  - **Typed Edges**: Explicit graph relationships with weights
  - **Graph Traversal**: BFS with depth limits and type filtering
  - **Hybrid Queries**: Combined vector + graph search
  - **Persistence v2**: Backward-compatible format with metadata/edges
  - **38 comprehensive tests** (29 original + 9 GraphRAG tests)

- **2025-10-19**: Major feature release
  - Switched to cosine similarity for embeddings
  - Added custom ID support with external/internal mapping
  - Implemented full persistence (save/load)
  - Updated for Zig 0.15.2 compatibility
  - 29 comprehensive tests covering all features
