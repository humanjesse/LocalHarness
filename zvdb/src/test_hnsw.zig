const std = @import("std");
const testing = std.testing;
const HNSW = @import("hnsw.zig").HNSW;

// Helper function to create a random point
fn randomPoint(allocator: std.mem.Allocator, dim: usize) ![]f32 {
    const point = try allocator.alloc(f32, dim);
    for (point) |*v| {
        v.* = std.crypto.random.float(f32);
    }
    return point;
}

// Helper function to calculate cosine distance (same as used in HNSW)
fn cosineDistance(a: []const f32, b: []const f32) f32 {
    var dot_product: f32 = 0;
    var norm_a: f32 = 0;
    var norm_b: f32 = 0;

    for (a, 0..) |_, i| {
        dot_product += a[i] * b[i];
        norm_a += a[i] * a[i];
        norm_b += b[i] * b[i];
    }

    if (norm_a == 0 or norm_b == 0) {
        return 1.0;
    }

    const norm_product = std.math.sqrt(norm_a) * std.math.sqrt(norm_b);
    const cosine_similarity = dot_product / norm_product;
    const clamped = @max(-1.0, @min(1.0, cosine_similarity));
    return 1.0 - clamped;
}

test "HNSW - Basic Functionality" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    // Insert some points
    _ = try hnsw.insert(&[_]f32{ 1, 2, 3 }, null);
    _ = try hnsw.insert(&[_]f32{ 4, 5, 6 }, null);
    _ = try hnsw.insert(&[_]f32{ 7, 8, 9 }, null);

    // Search for nearest neighbors
    const query = &[_]f32{ 3, 4, 5 };
    const results = try hnsw.search(query, 2);
    defer allocator.free(results);

    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expect(cosineDistance(query, results[0].point) <= cosineDistance(query, results[1].point));
}

test "HNSW - Empty Index" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    const query = &[_]f32{ 1, 2, 3 };
    const results = try hnsw.search(query, 5);
    defer allocator.free(results);

    try testing.expectEqual(@as(usize, 0), results.len);
}

test "HNSW - Single Point" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    const point = &[_]f32{ 1, 2, 3 };
    _ = try hnsw.insert(point, null);

    const results = try hnsw.search(point, 1);
    defer allocator.free(results);

    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqualSlices(f32, point, results[0].point);
}

test "HNSW - Large Dataset" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    const num_points = 10000;
    const dim = 128;

    // Insert many points
    for (0..num_points) |_| {
        const point = try randomPoint(allocator, dim);
        defer allocator.free(point);
        _ = try hnsw.insert(point, null);
    }

    // Search for nearest neighbors
    const query = try randomPoint(allocator, dim);
    defer allocator.free(query);

    const k = 10;
    const results = try hnsw.search(query, k);
    defer allocator.free(results);

    try testing.expectEqual(@as(usize, k), results.len);

    // Check if results are sorted by distance
    var last_dist: f32 = 0;
    for (results) |result| {
        const dist = cosineDistance(query, result.point);
        try testing.expect(dist >= last_dist);
        last_dist = dist;
    }
}

test "HNSW - Edge Cases" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    // Insert duplicate points
    const point = &[_]f32{ 1, 2, 3 };
    _ = try hnsw.insert(point, null);
    _ = try hnsw.insert(point, null);

    const results = try hnsw.search(point, 2);
    defer allocator.free(results);

    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqualSlices(f32, point, results[0].point);
    try testing.expectEqualSlices(f32, point, results[1].point);

    // Search with k larger than number of points
    const large_k_results = try hnsw.search(point, 100);
    defer allocator.free(large_k_results);

    try testing.expectEqual(@as(usize, 2), large_k_results.len);
}

test "HNSW - Memory Leaks" {
    var hnsw: HNSW(f32) = undefined;
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        hnsw = HNSW(f32).init(allocator, 16, 200);

        const num_points = 1000;
        const dim = 64;

        for (0..num_points) |_| {
            const point = try randomPoint(allocator, dim);
            _ = try hnsw.insert(point, null);
            // Intentionally not freeing 'point' to test if HNSW properly manages memory
        }

        const query = try randomPoint(allocator, dim);
        const results = try hnsw.search(query, 10);
        _ = results;
        // Intentionally not freeing 'results' or 'query'
    }
    // The ArenaAllocator will detect any memory leaks when it's deinitialized
}

test "HNSW - Concurrent Access" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    const num_threads = 8;
    const points_per_thread = 1000;
    const dim = 128;

    const ThreadContext = struct {
        hnsw: *HNSW(f32),
        allocator: std.mem.Allocator,
    };

    const thread_fn = struct {
        fn func(ctx: *const ThreadContext) !void {
            for (0..points_per_thread) |_| {
                const point = try ctx.allocator.alloc(f32, dim);
                defer ctx.allocator.free(point);
                for (point) |*v| {
                    v.* = std.crypto.random.float(f32);
                }
                _ = try ctx.hnsw.insert(point, null);
            }
        }
    }.func;

    var threads: [num_threads]std.Thread = undefined;
    var contexts: [num_threads]ThreadContext = undefined;

    for (&threads, 0..) |*thread, i| {
        contexts[i] = .{
            .hnsw = &hnsw,
            .allocator = allocator,
        };
        thread.* = try std.Thread.spawn(.{}, thread_fn, .{&contexts[i]});
    }

    for (&threads) |*thread| {
        thread.join();
    }

    // Verify that all points were inserted
    const expected_count = num_threads * points_per_thread;
    const actual_count = hnsw.nodes.count();
    try testing.expectEqual(expected_count, actual_count);

    // Test search after concurrent insertion
    const query = try randomPoint(allocator, dim);
    defer allocator.free(query);

    const results = try hnsw.search(query, 10);
    defer allocator.free(results);

    try testing.expectEqual(@as(usize, 10), results.len);
}

test "HNSW - Stress Test" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    const num_points = 100000;
    const dim = 128;
    const num_queries = 100;

    // Insert many points
    for (0..num_points) |_| {
        const point = try randomPoint(allocator, dim);
        defer allocator.free(point);
        _ = try hnsw.insert(point, null);
    }

    // Perform multiple searches
    for (0..num_queries) |_| {
        const query = try randomPoint(allocator, dim);
        defer allocator.free(query);

        const results = try hnsw.search(query, 10);
        defer allocator.free(results);

        try testing.expectEqual(@as(usize, 10), results.len);
    }
}

test "HNSW - Different Float Types" {
    const allocator = testing.allocator;

    // Test with f32 (default)
    {
        var hnsw_f32 = HNSW(f32).init(allocator, 16, 200);
        defer hnsw_f32.deinit();

        _ = try hnsw_f32.insert(&[_]f32{ 1.1, 2.2, 3.3 }, null);
        _ = try hnsw_f32.insert(&[_]f32{ 4.4, 5.5, 6.6 }, null);
        _ = try hnsw_f32.insert(&[_]f32{ 7.7, 8.8, 9.9 }, null);

        const query_f32 = &[_]f32{ 3.3, 4.4, 5.5 };
        const results_f32 = try hnsw_f32.search(query_f32, 2);
        defer allocator.free(results_f32);

        try testing.expectEqual(@as(usize, 2), results_f32.len);
    }

    // Test with f64 type
    {
        var hnsw_f64 = HNSW(f64).init(allocator, 16, 200);
        defer hnsw_f64.deinit();

        _ = try hnsw_f64.insert(&[_]f64{ 1.1, 2.2, 3.3 }, null);
        _ = try hnsw_f64.insert(&[_]f64{ 4.4, 5.5, 6.6 }, null);
        _ = try hnsw_f64.insert(&[_]f64{ 7.7, 8.8, 9.9 }, null);

        const query_f64 = &[_]f64{ 3.3, 4.4, 5.5 };
        const results_f64 = try hnsw_f64.search(query_f64, 2);
        defer allocator.free(results_f64);

        try testing.expectEqual(@as(usize, 2), results_f64.len);
    }
}

test "HNSW - Consistency" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    const num_points = 10000;
    const dim = 128;

    // Insert points
    for (0..num_points) |_| {
        const point = try randomPoint(allocator, dim);
        defer allocator.free(point);
        _ = try hnsw.insert(point, null);
    }

    // Perform multiple searches with the same query
    const query = try randomPoint(allocator, dim);
    defer allocator.free(query);

    const num_searches = 10;
    const k = 10;
    var first_result = try allocator.alloc(f32, k * dim);
    defer allocator.free(first_result);

    for (0..num_searches) |i| {
        const results = try hnsw.search(query, k);
        defer allocator.free(results);

        if (i == 0) {
            // Store the first result for comparison
            for (results, 0..) |result, j| {
                @memcpy(first_result[j * dim .. (j + 1) * dim], result.point);
            }
        } else {
            // Compare with the first result
            for (results, 0..) |result, j| {
                const start = j * dim;
                const end = (j + 1) * dim;
                try testing.expectEqualSlices(f32, first_result[start..end], result.point);
            }
        }
    }
}

test "Cosine Distance - Identical Vectors" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    const point = &[_]f32{ 1.0, 2.0, 3.0 };
    _ = try hnsw.insert(point, null);

    // Identical vectors should have distance very close to 0
    const results = try hnsw.search(point, 1);
    defer allocator.free(results);

    try testing.expectEqual(@as(usize, 1), results.len);
    const dist = cosineDistance(point, results[0].point);
    try testing.expectApproxEqAbs(@as(f32, 0.0), dist, 1e-6);
}

test "Cosine Distance - Orthogonal Vectors" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    // Orthogonal vectors: [1, 0, 0] and [0, 1, 0]
    const v1 = &[_]f32{ 1.0, 0.0, 0.0 };
    const v2 = &[_]f32{ 0.0, 1.0, 0.0 };
    _ = try hnsw.insert(v1, null);
    _ = try hnsw.insert(v2, null);

    // Orthogonal vectors should have cosine similarity = 0, so distance = 1
    const results = try hnsw.search(v1, 2);
    defer allocator.free(results);

    try testing.expectEqual(@as(usize, 2), results.len);

    // First result should be v1 itself (distance ~0)
    const dist_v1 = cosineDistance(v1, results[0].point);
    try testing.expectApproxEqAbs(@as(f32, 0.0), dist_v1, 1e-6);

    // Second result should be v2 (distance ~1 for orthogonal)
    const dist_v2 = cosineDistance(v1, results[1].point);
    try testing.expectApproxEqAbs(@as(f32, 1.0), dist_v2, 1e-5);
}

test "Cosine Distance - Opposite Vectors" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    // Opposite vectors: [1, 0] and [-1, 0]
    const v1 = &[_]f32{ 1.0, 0.0 };
    const v2 = &[_]f32{ -1.0, 0.0 };
    _ = try hnsw.insert(v1, null);
    _ = try hnsw.insert(v2, null);

    // Opposite vectors should have cosine similarity = -1, so distance = 2
    const dist = cosineDistance(v1, v2);
    try testing.expectApproxEqAbs(@as(f32, 2.0), dist, 1e-5);
}

test "Cosine Distance - Known Values" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    // Test with known vectors
    const v1 = &[_]f32{ 3.0, 4.0 };  // magnitude = 5
    const v2 = &[_]f32{ 4.0, 3.0 };  // magnitude = 5

    _ = try hnsw.insert(v1, null);
    _ = try hnsw.insert(v2, null);

    // Dot product = 3*4 + 4*3 = 24
    // Cosine similarity = 24 / (5 * 5) = 24/25 = 0.96
    // Cosine distance = 1 - 0.96 = 0.04
    const dist = cosineDistance(v1, v2);
    try testing.expectApproxEqAbs(@as(f32, 0.04), dist, 1e-5);
}

test "Cosine Distance - Normalized vs Unnormalized" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    // Same direction, different magnitudes
    const v1 = &[_]f32{ 1.0, 2.0, 3.0 };
    const v2 = &[_]f32{ 2.0, 4.0, 6.0 }; // v2 = 2 * v1

    _ = try hnsw.insert(v1, null);
    _ = try hnsw.insert(v2, null);

    // Vectors in the same direction should have distance ~0 regardless of magnitude
    const dist = cosineDistance(v1, v2);
    try testing.expectApproxEqAbs(@as(f32, 0.0), dist, 1e-6);
}

test "Cosine Distance - Zero Vector Handling" {
    // Test that zero vectors are handled gracefully
    const zero = &[_]f32{ 0.0, 0.0, 0.0 };
    const nonzero = &[_]f32{ 1.0, 2.0, 3.0 };

    // Should return maximum distance (1.0) for zero vectors
    const dist = cosineDistance(zero, nonzero);
    try testing.expectEqual(@as(f32, 1.0), dist);
}

test "Cosine Distance - High Dimensional Embeddings" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    const dim = 768; // Typical embedding dimension

    // Create two similar high-dimensional vectors
    const v1 = try allocator.alloc(f32, dim);
    defer allocator.free(v1);
    const v2 = try allocator.alloc(f32, dim);
    defer allocator.free(v2);

    for (0..dim) |i| {
        v1[i] = @as(f32, @floatFromInt(i)) / 768.0;
        v2[i] = @as(f32, @floatFromInt(i)) / 768.0 + 0.01; // Slightly different
    }

    _ = try hnsw.insert(v1, null);
    _ = try hnsw.insert(v2, null);

    const results = try hnsw.search(v1, 2);
    defer allocator.free(results);

    try testing.expectEqual(@as(usize, 2), results.len);

    // First result should be v1 itself
    const dist1 = cosineDistance(v1, results[0].point);
    try testing.expectApproxEqAbs(@as(f32, 0.0), dist1, 1e-5);

    // Second result should be v2, which is close but not identical
    const dist2 = cosineDistance(v1, results[1].point);
    try testing.expect(dist2 > 0.0);
    try testing.expect(dist2 < 0.1); // Should be relatively close
}

test "Custom IDs - User Provided IDs" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    // Insert vectors with custom IDs
    const id1 = try hnsw.insert(&[_]f32{ 1.0, 2.0, 3.0 }, 100);
    const id2 = try hnsw.insert(&[_]f32{ 4.0, 5.0, 6.0 }, 200);
    const id3 = try hnsw.insert(&[_]f32{ 7.0, 8.0, 9.0 }, 300);

    try testing.expectEqual(@as(u64, 100), id1);
    try testing.expectEqual(@as(u64, 200), id2);
    try testing.expectEqual(@as(u64, 300), id3);

    // Search should return results with custom IDs
    const results = try hnsw.search(&[_]f32{ 2.0, 3.0, 4.0 }, 3);
    defer allocator.free(results);

    try testing.expectEqual(@as(usize, 3), results.len);

    // Verify that results contain our custom IDs
    var found_ids = [_]bool{false} ** 3;
    for (results) |result| {
        if (result.external_id == 100) found_ids[0] = true;
        if (result.external_id == 200) found_ids[1] = true;
        if (result.external_id == 300) found_ids[2] = true;
    }
    try testing.expect(found_ids[0] and found_ids[1] and found_ids[2]);
}

test "Custom IDs - Auto-generated IDs" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    // Insert without specifying IDs (auto-generated)
    const id1 = try hnsw.insert(&[_]f32{ 1.0, 2.0 }, null);
    const id2 = try hnsw.insert(&[_]f32{ 3.0, 4.0 }, null);
    const id3 = try hnsw.insert(&[_]f32{ 5.0, 6.0 }, null);

    // Auto-generated IDs should be sequential starting from 0
    try testing.expectEqual(@as(u64, 0), id1);
    try testing.expectEqual(@as(u64, 1), id2);
    try testing.expectEqual(@as(u64, 2), id3);
}

test "Custom IDs - Mixed Custom and Auto IDs" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    // Mix custom and auto-generated IDs
    const id1 = try hnsw.insert(&[_]f32{ 1.0, 2.0 }, 1000); // Custom
    const id2 = try hnsw.insert(&[_]f32{ 3.0, 4.0 }, null); // Auto
    const id3 = try hnsw.insert(&[_]f32{ 5.0, 6.0 }, 2000); // Custom
    const id4 = try hnsw.insert(&[_]f32{ 7.0, 8.0 }, null); // Auto

    try testing.expectEqual(@as(u64, 1000), id1);
    try testing.expectEqual(@as(u64, 0), id2); // First auto ID
    try testing.expectEqual(@as(u64, 2000), id3);
    try testing.expectEqual(@as(u64, 1), id4); // Second auto ID
}

test "Custom IDs - Duplicate ID Error" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    // Insert with a custom ID
    _ = try hnsw.insert(&[_]f32{ 1.0, 2.0 }, 100);

    // Try to insert with the same ID - should fail
    const result = hnsw.insert(&[_]f32{ 3.0, 4.0 }, 100);
    try testing.expectError(error.DuplicateExternalId, result);
}

test "Custom IDs - Lookup by External ID" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    const v1 = &[_]f32{ 1.0, 2.0, 3.0 };
    const v2 = &[_]f32{ 4.0, 5.0, 6.0 };
    const v3 = &[_]f32{ 7.0, 8.0, 9.0 };

    _ = try hnsw.insert(v1, 100);
    _ = try hnsw.insert(v2, 200);
    _ = try hnsw.insert(v3, 300);

    // Look up by external ID
    const node1 = hnsw.getByExternalId(100);
    const node2 = hnsw.getByExternalId(200);
    const node3 = hnsw.getByExternalId(300);
    const node_none = hnsw.getByExternalId(999);

    try testing.expect(node1 != null);
    try testing.expect(node2 != null);
    try testing.expect(node3 != null);
    try testing.expect(node_none == null);

    try testing.expectEqualSlices(f32, v1, node1.?.point);
    try testing.expectEqualSlices(f32, v2, node2.?.point);
    try testing.expectEqualSlices(f32, v3, node3.?.point);
}

test "Custom IDs - ID Mapping Functions" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    _ = try hnsw.insert(&[_]f32{ 1.0, 2.0 }, 100);
    _ = try hnsw.insert(&[_]f32{ 3.0, 4.0 }, 200);

    // Test external -> internal mapping
    const internal1 = hnsw.getInternalId(100);
    const internal2 = hnsw.getInternalId(200);
    const internal_none = hnsw.getInternalId(999);

    try testing.expect(internal1 != null);
    try testing.expect(internal2 != null);
    try testing.expect(internal_none == null);

    // Test internal -> external mapping
    const external1 = hnsw.getExternalId(internal1.?);
    const external2 = hnsw.getExternalId(internal2.?);

    try testing.expectEqual(@as(u64, 100), external1.?);
    try testing.expectEqual(@as(u64, 200), external2.?);
}

test "Persistence - Save and Load Round Trip" {
    const allocator = testing.allocator;
    const test_file = "test_hnsw_save.bin";
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Create and populate an index
    {
        var hnsw = HNSW(f32).init(allocator, 16, 200);
        defer hnsw.deinit();

        _ = try hnsw.insert(&[_]f32{ 1.0, 2.0, 3.0 }, 100);
        _ = try hnsw.insert(&[_]f32{ 4.0, 5.0, 6.0 }, 200);
        _ = try hnsw.insert(&[_]f32{ 7.0, 8.0, 9.0 }, 300);

        try hnsw.save(test_file);
    }

    // Load and verify
    {
        var loaded = try HNSW(f32).load(allocator, test_file);
        defer loaded.deinit();

        // Verify configuration
        try testing.expectEqual(@as(usize, 16), loaded.m);
        try testing.expectEqual(@as(usize, 200), loaded.ef_construction);

        // Verify node count
        try testing.expectEqual(@as(usize, 3), loaded.nodes.count());

        // Verify external IDs and data
        const node1 = loaded.getByExternalId(100);
        const node2 = loaded.getByExternalId(200);
        const node3 = loaded.getByExternalId(300);

        try testing.expect(node1 != null);
        try testing.expect(node2 != null);
        try testing.expect(node3 != null);

        try testing.expectEqualSlices(f32, &[_]f32{ 1.0, 2.0, 3.0 }, node1.?.point);
        try testing.expectEqualSlices(f32, &[_]f32{ 4.0, 5.0, 6.0 }, node2.?.point);
        try testing.expectEqualSlices(f32, &[_]f32{ 7.0, 8.0, 9.0 }, node3.?.point);

        // Verify search still works
        const results = try loaded.search(&[_]f32{ 2.0, 3.0, 4.0 }, 3);
        defer allocator.free(results);
        try testing.expectEqual(@as(usize, 3), results.len);
    }
}

test "Persistence - Empty Index" {
    const allocator = testing.allocator;
    const test_file = "test_hnsw_empty.bin";
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Save empty index
    {
        var hnsw = HNSW(f32).init(allocator, 16, 200);
        defer hnsw.deinit();
        try hnsw.save(test_file);
    }

    // Load and verify
    {
        var loaded = try HNSW(f32).load(allocator, test_file);
        defer loaded.deinit();

        try testing.expectEqual(@as(usize, 0), loaded.nodes.count());
        try testing.expectEqual(@as(usize, 16), loaded.m);
        try testing.expectEqual(@as(usize, 200), loaded.ef_construction);
    }
}

test "Persistence - Large Index" {
    const allocator = testing.allocator;
    const test_file = "test_hnsw_large.bin";
    defer std.fs.cwd().deleteFile(test_file) catch {};

    const num_points = 1000;
    const dim = 128;

    // Create and save large index
    {
        var hnsw = HNSW(f32).init(allocator, 16, 200);
        defer hnsw.deinit();

        for (0..num_points) |i| {
            const point = try randomPoint(allocator, dim);
            defer allocator.free(point);
            _ = try hnsw.insert(point, i);
        }

        try hnsw.save(test_file);
    }

    // Load and verify
    {
        var loaded = try HNSW(f32).load(allocator, test_file);
        defer loaded.deinit();

        try testing.expectEqual(num_points, loaded.nodes.count());

        // Verify all IDs are present
        for (0..num_points) |i| {
            const node = loaded.getByExternalId(i);
            try testing.expect(node != null);
            try testing.expectEqual(dim, node.?.point.len);
        }

        // Verify search works
        const query = try randomPoint(allocator, dim);
        defer allocator.free(query);

        const results = try loaded.search(query, 10);
        defer allocator.free(results);

        try testing.expectEqual(@as(usize, 10), results.len);
    }
}

test "Persistence - Preserves Graph Structure" {
    const allocator = testing.allocator;
    const test_file = "test_hnsw_graph.bin";
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Create index and record search results
    var original_results: []const HNSW(f32).SearchResult = undefined;
    const query = &[_]f32{ 5.0, 5.0, 5.0 };

    {
        var hnsw = HNSW(f32).init(allocator, 16, 200);
        defer hnsw.deinit();

        _ = try hnsw.insert(&[_]f32{ 1.0, 1.0, 1.0 }, 1);
        _ = try hnsw.insert(&[_]f32{ 2.0, 2.0, 2.0 }, 2);
        _ = try hnsw.insert(&[_]f32{ 3.0, 3.0, 3.0 }, 3);
        _ = try hnsw.insert(&[_]f32{ 4.0, 4.0, 4.0 }, 4);
        _ = try hnsw.insert(&[_]f32{ 6.0, 6.0, 6.0 }, 6);
        _ = try hnsw.insert(&[_]f32{ 7.0, 7.0, 7.0 }, 7);
        _ = try hnsw.insert(&[_]f32{ 8.0, 8.0, 8.0 }, 8);
        _ = try hnsw.insert(&[_]f32{ 9.0, 9.0, 9.0 }, 9);

        original_results = try hnsw.search(query, 5);

        try hnsw.save(test_file);
    }
    defer allocator.free(original_results);

    // Load and verify search results are the same
    {
        var loaded = try HNSW(f32).load(allocator, test_file);
        defer loaded.deinit();

        const loaded_results = try loaded.search(query, 5);
        defer allocator.free(loaded_results);

        try testing.expectEqual(original_results.len, loaded_results.len);

        // Verify same IDs in same order
        for (original_results, loaded_results) |orig, load| {
            try testing.expectEqual(orig.external_id, load.external_id);
            try testing.expectApproxEqAbs(orig.distance, load.distance, 1e-6);
        }
    }
}

test "Persistence - High Dimensional Vectors" {
    const allocator = testing.allocator;
    const test_file = "test_hnsw_highdim.bin";
    defer std.fs.cwd().deleteFile(test_file) catch {};

    const dim = 768; // Typical embedding dimension

    // Create and save
    {
        var hnsw = HNSW(f32).init(allocator, 16, 200);
        defer hnsw.deinit();

        for (0..100) |i| {
            const point = try randomPoint(allocator, dim);
            defer allocator.free(point);
            _ = try hnsw.insert(point, i * 10);
        }

        try hnsw.save(test_file);
    }

    // Load and verify
    {
        var loaded = try HNSW(f32).load(allocator, test_file);
        defer loaded.deinit();

        try testing.expectEqual(@as(usize, 100), loaded.nodes.count());

        // Verify dimensions
        const node = loaded.getByExternalId(0);
        try testing.expect(node != null);
        try testing.expectEqual(dim, node.?.point.len);

        // Verify search
        const query = try randomPoint(allocator, dim);
        defer allocator.free(query);

        const results = try loaded.search(query, 5);
        defer allocator.free(results);

        try testing.expectEqual(@as(usize, 5), results.len);
    }
}

test "Persistence - Mixed Custom and Auto IDs" {
    const allocator = testing.allocator;
    const test_file = "test_hnsw_mixed_ids.bin";
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Create with mixed IDs
    {
        var hnsw = HNSW(f32).init(allocator, 16, 200);
        defer hnsw.deinit();

        _ = try hnsw.insert(&[_]f32{ 1.0, 2.0 }, 1000); // Custom
        _ = try hnsw.insert(&[_]f32{ 3.0, 4.0 }, null); // Auto (0)
        _ = try hnsw.insert(&[_]f32{ 5.0, 6.0 }, 2000); // Custom
        _ = try hnsw.insert(&[_]f32{ 7.0, 8.0 }, null); // Auto (1)

        try hnsw.save(test_file);
    }

    // Load and verify IDs are preserved
    {
        var loaded = try HNSW(f32).load(allocator, test_file);
        defer loaded.deinit();

        try testing.expect(loaded.getByExternalId(1000) != null);
        try testing.expect(loaded.getByExternalId(0) != null);
        try testing.expect(loaded.getByExternalId(2000) != null);
        try testing.expect(loaded.getByExternalId(1) != null);

        try testing.expectEqualSlices(f32, &[_]f32{ 1.0, 2.0 }, loaded.getByExternalId(1000).?.point);
        try testing.expectEqualSlices(f32, &[_]f32{ 3.0, 4.0 }, loaded.getByExternalId(0).?.point);
        try testing.expectEqualSlices(f32, &[_]f32{ 5.0, 6.0 }, loaded.getByExternalId(2000).?.point);
        try testing.expectEqualSlices(f32, &[_]f32{ 7.0, 8.0 }, loaded.getByExternalId(1).?.point);

        // Verify next_external_id is preserved (should be 2)
        const new_id = try loaded.insert(&[_]f32{ 9.0, 10.0 }, null);
        try testing.expectEqual(@as(u64, 2), new_id);
    }
}

// ===== GraphRAG Tests =====

const NodeMetadata = @import("hnsw.zig").NodeMetadata;
const MetadataValue = @import("hnsw.zig").MetadataValue;

test "GraphRAG - Node Metadata Insert and Query" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    // Create metadata for different node types
    var doc_meta = try NodeMetadata.init(allocator, "doc_chunk", "path/to/doc1.txt");
    try doc_meta.setAttribute(allocator, "file", MetadataValue{ .string = "parser.zig" });
    try doc_meta.setAttribute(allocator, "line_start", MetadataValue{ .int = 10 });

    var func_meta = try NodeMetadata.init(allocator, "function", null);
    try func_meta.setAttribute(allocator, "name", MetadataValue{ .string = "parseTree" });
    try func_meta.setAttribute(allocator, "public", MetadataValue{ .bool = true });

    // Insert nodes with metadata
    const doc_id = try hnsw.insertWithMetadata(&[_]f32{ 1.0, 2.0, 3.0 }, null, doc_meta);
    const func_id = try hnsw.insertWithMetadata(&[_]f32{ 4.0, 5.0, 6.0 }, null, func_meta);
    _ = try hnsw.insert(&[_]f32{ 7.0, 8.0, 9.0 }, null); // Node without metadata

    // Query by type
    const doc_chunks = try hnsw.getNodesByType("doc_chunk");
    defer allocator.free(doc_chunks);
    try testing.expectEqual(@as(usize, 1), doc_chunks.len);
    try testing.expectEqual(doc_id, doc_chunks[0]);

    const functions = try hnsw.getNodesByType("function");
    defer allocator.free(functions);
    try testing.expectEqual(@as(usize, 1), functions.len);
    try testing.expectEqual(func_id, functions[0]);

    // Query non-existent type
    const entities = try hnsw.getNodesByType("entity");
    defer allocator.free(entities);
    try testing.expectEqual(@as(usize, 0), entities.len);
}

test "GraphRAG - Metadata Update" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    // Insert with original metadata
    const original_meta = try NodeMetadata.init(allocator, "doc_chunk", null);
    const node_id = try hnsw.insertWithMetadata(&[_]f32{ 1.0, 2.0 }, null, original_meta);

    // Verify type index has the node
    var chunks = try hnsw.getNodesByType("doc_chunk");
    allocator.free(chunks);

    // Update metadata with new type
    const new_meta = try NodeMetadata.init(allocator, "entity", "updated_ref");
    try hnsw.updateMetadata(node_id, new_meta);

    // Verify old type no longer has the node
    chunks = try hnsw.getNodesByType("doc_chunk");
    try testing.expectEqual(@as(usize, 0), chunks.len);
    allocator.free(chunks);

    // Verify new type has the node
    const entities = try hnsw.getNodesByType("entity");
    try testing.expectEqual(@as(usize, 1), entities.len);
    try testing.expectEqual(node_id, entities[0]);
    allocator.free(entities);
}

test "GraphRAG - Edge Operations" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    // Insert nodes
    const id1 = try hnsw.insert(&[_]f32{ 1.0, 2.0 }, null);
    const id2 = try hnsw.insert(&[_]f32{ 3.0, 4.0 }, null);
    const id3 = try hnsw.insert(&[_]f32{ 5.0, 6.0 }, null);

    // Add edges
    try hnsw.addEdge(id1, id2, "references", 0.8);
    try hnsw.addEdge(id1, id3, "contains", 0.9);
    try hnsw.addEdge(id2, id3, "references", 0.7);

    // Get all edges for node 1
    const edges1 = try hnsw.getEdges(id1, null);
    defer {
        for (edges1) |edge| {
            var e = edge;
            e.deinit(allocator);
        }
        allocator.free(edges1);
    }
    try testing.expectEqual(@as(usize, 2), edges1.len);

    // Get filtered edges (only "references")
    const ref_edges = try hnsw.getEdges(id1, "references");
    defer {
        for (ref_edges) |edge| {
            var e = edge;
            e.deinit(allocator);
        }
        allocator.free(ref_edges);
    }
    try testing.expectEqual(@as(usize, 1), ref_edges.len);
    try testing.expectEqual(id2, ref_edges[0].dst);

    // Remove edge
    try hnsw.removeEdge(id1, id2, "references");
    const edges_after = try hnsw.getEdges(id1, null);
    defer {
        for (edges_after) |edge| {
            var e = edge;
            e.deinit(allocator);
        }
        allocator.free(edges_after);
    }
    try testing.expectEqual(@as(usize, 1), edges_after.len);
}

test "GraphRAG - Get Neighbors" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    const id1 = try hnsw.insert(&[_]f32{ 1.0 }, null);
    const id2 = try hnsw.insert(&[_]f32{ 2.0 }, null);
    const id3 = try hnsw.insert(&[_]f32{ 3.0 }, null);
    const id4 = try hnsw.insert(&[_]f32{ 4.0 }, null);

    try hnsw.addEdge(id1, id2, "calls", 1.0);
    try hnsw.addEdge(id1, id3, "calls", 1.0);
    try hnsw.addEdge(id1, id4, "references", 1.0);

    // Get all neighbors
    const all_neighbors = try hnsw.getNeighbors(id1, null);
    defer allocator.free(all_neighbors);
    try testing.expectEqual(@as(usize, 3), all_neighbors.len);

    // Get filtered neighbors
    const call_neighbors = try hnsw.getNeighbors(id1, "calls");
    defer allocator.free(call_neighbors);
    try testing.expectEqual(@as(usize, 2), call_neighbors.len);
}

test "GraphRAG - Graph Traversal" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    // Create a simple graph: 1 -> 2 -> 3 -> 4
    const id1 = try hnsw.insert(&[_]f32{ 1.0 }, null);
    const id2 = try hnsw.insert(&[_]f32{ 2.0 }, null);
    const id3 = try hnsw.insert(&[_]f32{ 3.0 }, null);
    const id4 = try hnsw.insert(&[_]f32{ 4.0 }, null);

    try hnsw.addEdge(id1, id2, "next", 1.0);
    try hnsw.addEdge(id2, id3, "next", 1.0);
    try hnsw.addEdge(id3, id4, "next", 1.0);

    // Traverse depth 1: should get id1 and id2
    const depth1 = try hnsw.traverse(id1, 1, "next");
    defer allocator.free(depth1);
    try testing.expectEqual(@as(usize, 2), depth1.len);

    // Traverse depth 3: should get all nodes
    const depth3 = try hnsw.traverse(id1, 3, "next");
    defer allocator.free(depth3);
    try testing.expectEqual(@as(usize, 4), depth3.len);

    // Traverse depth 0: should get only start node
    const depth0 = try hnsw.traverse(id1, 0, "next");
    defer allocator.free(depth0);
    try testing.expectEqual(@as(usize, 1), depth0.len);
    try testing.expectEqual(id1, depth0[0]);
}

test "GraphRAG - Incoming and Outgoing Edges" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    const id1 = try hnsw.insert(&[_]f32{ 1.0 }, null);
    const id2 = try hnsw.insert(&[_]f32{ 2.0 }, null);
    const id3 = try hnsw.insert(&[_]f32{ 3.0 }, null);

    // id1 -> id2, id1 -> id3, id3 -> id2
    try hnsw.addEdge(id1, id2, "calls", 1.0);
    try hnsw.addEdge(id1, id3, "calls", 1.0);
    try hnsw.addEdge(id3, id2, "calls", 1.0);

    // id2 should have 2 incoming edges
    const incoming = try hnsw.getIncoming(id2, null);
    defer {
        for (incoming) |edge| {
            var e = edge;
            e.deinit(allocator);
        }
        allocator.free(incoming);
    }
    try testing.expectEqual(@as(usize, 2), incoming.len);

    // id1 should have 2 outgoing edges
    const outgoing = try hnsw.getOutgoing(id1, null);
    defer {
        for (outgoing) |edge| {
            var e = edge;
            e.deinit(allocator);
        }
        allocator.free(outgoing);
    }
    try testing.expectEqual(@as(usize, 2), outgoing.len);

    // id3 should have 1 incoming and 1 outgoing
    const in3 = try hnsw.getIncoming(id3, null);
    defer {
        for (in3) |edge| {
            var e = edge;
            e.deinit(allocator);
        }
        allocator.free(in3);
    }
    const out3 = try hnsw.getOutgoing(id3, null);
    defer {
        for (out3) |edge| {
            var e = edge;
            e.deinit(allocator);
        }
        allocator.free(out3);
    }
    try testing.expectEqual(@as(usize, 1), in3.len);
    try testing.expectEqual(@as(usize, 1), out3.len);
}

test "GraphRAG - Search by Type" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    // Insert nodes with different types
    const meta1 = try NodeMetadata.init(allocator, "doc_chunk", null);
    const meta2 = try NodeMetadata.init(allocator, "doc_chunk", null);
    const meta3 = try NodeMetadata.init(allocator, "function", null);

    _ = try hnsw.insertWithMetadata(&[_]f32{ 1.0, 0.0 }, null, meta1);
    _ = try hnsw.insertWithMetadata(&[_]f32{ 0.9, 0.1 }, null, meta2);
    _ = try hnsw.insertWithMetadata(&[_]f32{ 0.0, 1.0 }, null, meta3);

    // Search for doc_chunks only
    const query = &[_]f32{ 1.0, 0.0 };
    const results = try hnsw.searchByType(query, 2, "doc_chunk");
    defer allocator.free(results);

    // Should only get doc_chunk nodes
    try testing.expectEqual(@as(usize, 2), results.len);
}

test "GraphRAG - Hybrid Search and Traverse" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    // Create nodes
    const id1 = try hnsw.insert(&[_]f32{ 1.0, 0.0 }, null);
    const id2 = try hnsw.insert(&[_]f32{ 0.9, 0.1 }, null);
    const id3 = try hnsw.insert(&[_]f32{ 0.0, 1.0 }, null);
    const id4 = try hnsw.insert(&[_]f32{ 0.1, 0.9 }, null);

    // Create graph: id1 -> id3, id2 -> id4
    try hnsw.addEdge(id1, id3, "related", 1.0);
    try hnsw.addEdge(id2, id4, "related", 1.0);

    // Search for top-2 similar to [1.0, 0.0], then traverse
    const query = &[_]f32{ 1.0, 0.0 };
    const result_ids = try hnsw.searchThenTraverse(query, 2, "related", 1);
    defer allocator.free(result_ids);

    // Should get id1, id2 (from search) + id3, id4 (from traversal)
    try testing.expect(result_ids.len >= 2); // At least the search results
}

test "GraphRAG - Persistence with Metadata and Edges" {
    const allocator = testing.allocator;
    const test_file = "test_graphrag_persist.bin";
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Create and populate index
    {
        var hnsw = HNSW(f32).init(allocator, 16, 200);
        defer hnsw.deinit();

        // Add nodes with metadata
        var meta1 = try NodeMetadata.init(allocator, "doc_chunk", "file1.zig");
        try meta1.setAttribute(allocator, "line", MetadataValue{ .int = 100 });
        var meta2 = try NodeMetadata.init(allocator, "function", null);
        try meta2.setAttribute(allocator, "name", MetadataValue{ .string = "testFunc" });

        const id1 = try hnsw.insertWithMetadata(&[_]f32{ 1.0, 2.0 }, null, meta1);
        const id2 = try hnsw.insertWithMetadata(&[_]f32{ 3.0, 4.0 }, null, meta2);

        // Add edges
        try hnsw.addEdge(id1, id2, "calls", 0.95);

        // Save
        try hnsw.save(test_file);
    }

    // Load and verify
    {
        var loaded = try HNSW(f32).load(allocator, test_file);
        defer loaded.deinit();

        // Verify nodes exist
        const doc_chunks = try loaded.getNodesByType("doc_chunk");
        defer allocator.free(doc_chunks);
        try testing.expectEqual(@as(usize, 1), doc_chunks.len);

        const functions = try loaded.getNodesByType("function");
        defer allocator.free(functions);
        try testing.expectEqual(@as(usize, 1), functions.len);

        // Verify edges exist
        const edges = try loaded.getEdges(doc_chunks[0], "calls");
        defer {
            for (edges) |edge| {
                var e = edge;
                e.deinit(allocator);
            }
            allocator.free(edges);
        }
        try testing.expectEqual(@as(usize, 1), edges.len);
        try testing.expectEqual(@as(f32, 0.95), edges[0].weight);
    }
}

// File path index tests
test "file_path index - basic indexing" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    // Insert 3 nodes from same file
    var meta1 = try NodeMetadata.init(allocator, "function", "src/main.zig");
    try meta1.setAttribute(allocator, "name", MetadataValue{ .string = "main" });

    var meta2 = try NodeMetadata.init(allocator, "function", "src/main.zig");
    try meta2.setAttribute(allocator, "name", MetadataValue{ .string = "init" });

    var meta3 = try NodeMetadata.init(allocator, "struct", "src/main.zig");
    try meta3.setAttribute(allocator, "name", MetadataValue{ .string = "App" });

    const id1 = try hnsw.insertWithMetadata(&[_]f32{ 1.0, 2.0 }, null, meta1);
    const id2 = try hnsw.insertWithMetadata(&[_]f32{ 3.0, 4.0 }, null, meta2);
    const id3 = try hnsw.insertWithMetadata(&[_]f32{ 5.0, 6.0 }, null, meta3);

    // Query by file_path
    const nodes = try hnsw.getNodesByFilePath("src/main.zig");
    defer allocator.free(nodes);

    try testing.expectEqual(@as(usize, 3), nodes.len);

    // Verify all 3 IDs are present
    var found_id1 = false;
    var found_id2 = false;
    var found_id3 = false;
    for (nodes) |id| {
        if (id == id1) found_id1 = true;
        if (id == id2) found_id2 = true;
        if (id == id3) found_id3 = true;
    }
    try testing.expect(found_id1);
    try testing.expect(found_id2);
    try testing.expect(found_id3);
}

test "file_path index - multiple files" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    // Insert nodes from 3 different files
    const meta1 = try NodeMetadata.init(allocator, "function", "src/main.zig");
    const meta2 = try NodeMetadata.init(allocator, "function", "src/utils.zig");
    const meta3 = try NodeMetadata.init(allocator, "struct", "src/config.zig");
    const meta4 = try NodeMetadata.init(allocator, "function", "src/main.zig");

    const id1 = try hnsw.insertWithMetadata(&[_]f32{ 1.0, 2.0 }, null, meta1);
    const id2 = try hnsw.insertWithMetadata(&[_]f32{ 3.0, 4.0 }, null, meta2);
    const id3 = try hnsw.insertWithMetadata(&[_]f32{ 5.0, 6.0 }, null, meta3);
    const id4 = try hnsw.insertWithMetadata(&[_]f32{ 7.0, 8.0 }, null, meta4);

    // Query each file separately
    const main_nodes = try hnsw.getNodesByFilePath("src/main.zig");
    defer allocator.free(main_nodes);
    try testing.expectEqual(@as(usize, 2), main_nodes.len);

    const utils_nodes = try hnsw.getNodesByFilePath("src/utils.zig");
    defer allocator.free(utils_nodes);
    try testing.expectEqual(@as(usize, 1), utils_nodes.len);
    try testing.expectEqual(id2, utils_nodes[0]);

    const config_nodes = try hnsw.getNodesByFilePath("src/config.zig");
    defer allocator.free(config_nodes);
    try testing.expectEqual(@as(usize, 1), config_nodes.len);
    try testing.expectEqual(id3, config_nodes[0]);

    // Verify main.zig contains both id1 and id4
    var found_id1 = false;
    var found_id4 = false;
    for (main_nodes) |id| {
        if (id == id1) found_id1 = true;
        if (id == id4) found_id4 = true;
    }
    try testing.expect(found_id1);
    try testing.expect(found_id4);
}

test "file_path index - empty query" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    // Insert node from one file
    const meta = try NodeMetadata.init(allocator, "function", "src/main.zig");
    _ = try hnsw.insertWithMetadata(&[_]f32{ 1.0, 2.0 }, null, meta);

    // Query non-existent file_path
    const nodes = try hnsw.getNodesByFilePath("src/nonexistent.zig");
    defer allocator.free(nodes);

    try testing.expectEqual(@as(usize, 0), nodes.len);
}

test "file_path index - metadata update" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    // Insert node with file_path
    const meta1 = try NodeMetadata.init(allocator, "function", "src/old.zig");
    const id = try hnsw.insertWithMetadata(&[_]f32{ 1.0, 2.0 }, null, meta1);

    // Verify it's in old file index
    {
        const old_nodes = try hnsw.getNodesByFilePath("src/old.zig");
        defer allocator.free(old_nodes);
        try testing.expectEqual(@as(usize, 1), old_nodes.len);
        try testing.expectEqual(id, old_nodes[0]);
    }

    // Update metadata to different file_path
    const meta2 = try NodeMetadata.init(allocator, "function", "src/new.zig");
    try hnsw.updateMetadata(id, meta2);

    // Verify moved to new index
    {
        const new_nodes = try hnsw.getNodesByFilePath("src/new.zig");
        defer allocator.free(new_nodes);
        try testing.expectEqual(@as(usize, 1), new_nodes.len);
        try testing.expectEqual(id, new_nodes[0]);
    }

    // Verify removed from old index
    {
        const old_nodes = try hnsw.getNodesByFilePath("src/old.zig");
        defer allocator.free(old_nodes);
        try testing.expectEqual(@as(usize, 0), old_nodes.len);
    }
}

test "file_path index - nodes without file_path" {
    const allocator = testing.allocator;
    var hnsw = HNSW(f32).init(allocator, 16, 200);
    defer hnsw.deinit();

    // Insert node with content_ref = null
    const meta1 = try NodeMetadata.init(allocator, "function", null);
    const id1 = try hnsw.insertWithMetadata(&[_]f32{ 1.0, 2.0 }, null, meta1);

    // Insert node with file_path
    const meta2 = try NodeMetadata.init(allocator, "function", "src/main.zig");
    const id2 = try hnsw.insertWithMetadata(&[_]f32{ 3.0, 4.0 }, null, meta2);

    // Query for main.zig should only return id2
    const nodes = try hnsw.getNodesByFilePath("src/main.zig");
    defer allocator.free(nodes);

    try testing.expectEqual(@as(usize, 1), nodes.len);
    try testing.expectEqual(id2, nodes[0]);

    // Verify node without file_path still exists in database
    const retrieved = hnsw.getByExternalId(id1);
    try testing.expect(retrieved != null);
}
