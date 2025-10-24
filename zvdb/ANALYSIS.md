# zvdb Gap Analysis

**Date:** 2025-10-19
**Zig Version:** 0.15.2
**Purpose:** Evaluate zvdb for integration into semantic code search project

---

## Overview

**zvdb** is a pure Zig implementation of the HNSW (Hierarchical Navigable Small World) algorithm for approximate nearest neighbor search. It provides:
- Thread-safe vector storage and search
- Generic type support (f32, f64, etc.)
- In-memory index with configurable parameters
- Clean, well-tested codebase

**Current Status:** ✅ Compiles and tests pass on Zig 0.15.2 (updated today)

---

## Requirements Checklist

| Requirement | Status | Notes |
|-------------|--------|-------|
| High-dimensional vectors (768/1024) | ✅ **YES** | Benchmarks test up to 1024 dims |
| HNSW algorithm | ✅ **YES** | Fully implemented |
| Fast ANN search | ✅ **YES** | Built-in, needs performance validation |
| Cosine similarity | ❌ **NO** | Only L2 (Euclidean) distance |
| Custom vector IDs | ❌ **NO** | Auto-generated IDs only |
| K-nearest neighbor search | ✅ **YES** | `search(query, k)` implemented |
| Written in Zig | ✅ **YES** | Pure Zig, no C dependencies |
| In-memory storage | ✅ **YES** | AutoHashMap-based |
| Vector deletion by ID | ❌ **NO** | Removed from codebase (commit 6227664) |
| Persistence/serialization | ❌ **NO** | Not implemented |
| Thread-safe | ✅ **YES** | Mutexes on operations |
| Query latency < 100ms | ⚠️ **UNKNOWN** | Benchmarks exist but need fixing |

---

## Critical Gaps

### 1. Distance Metric - NEEDS MODIFICATION
**Current:** L2 (squared Euclidean) distance only
```zig
// hnsw.zig:182-192
fn distance(a: []const T, b: []const T) T {
    var sum: T = 0;
    for (a, 0..) |_, i| {
        const diff = a[i] - b[i];
        sum += diff * diff;
    }
    return sum; // Squared Euclidean
}
```

**Required:** Cosine similarity (preferred for embeddings)

**Impact:** HIGH - Embedding models typically use cosine similarity

### 2. Vector ID Management - NEEDS MODIFICATION
**Current:** Auto-incrementing IDs (0, 1, 2, ...)
```zig
// hnsw.zig:77
const id = self.nodes.count(); // Auto-generated
```

**Required:** Custom IDs to map vectors to code entities

**Impact:** HIGH - Cannot associate vectors with your code graph nodes

### 3. Vector Deletion - MAJOR GAP
**Current:** Deletion was removed (git commit 6227664: "remove deletion (HNSW no like deletion)")

**Required:** Optional in your spec, but useful for updating code

**Impact:** MEDIUM - Can work around with periodic index rebuilds

### 4. Persistence - MISSING BUT OPTIONAL
**Current:** No save/load functionality

**Required:** Optional ("Can serialize/deserialize index to disk")

**Impact:** LOW - Can rebuild index on startup if needed

---

## Prioritized Implementation Roadmap

### PRIORITY 1: Essential Features (2-3 days)
**Required to use zvdb in your project**

- [ ] **Add Cosine Similarity** (1-2 days)
  - Add distance metric enum: `enum { L2, Cosine, DotProduct }`
  - Implement cosine distance function
  - Make HNSW configurable with distance metric
  - Update tests

- [ ] **Add Custom ID Support** (1 day)
  - Add external_id → internal_id mapping
  - Modify `insert()` to accept optional user ID: `insert(point, id: ?u64)`
  - Add `getById(id: u64)` lookup function
  - Add `removeById(id: u64)` stub for future

### PRIORITY 2: Performance Validation (< 1 day)
**Verify it meets your latency requirements**

- [ ] **Fix Benchmark Format Strings** (30 min)
  - Change `std.debug.print("{}", .{result})` → `print("{any}", .{result})`
  - Fix in `single_threaded_benchmarks.zig:10,15`
  - Fix in `multi_threaded_benchmarks.zig` (similar)

- [ ] **Run Performance Tests** (30 min)
  - Test with 768 dimensions (embeddingemma size)
  - Test with k=5 (your requirement)
  - Verify latency < 100ms per query
  - Document results

### PRIORITY 3: Optional Enhancements (5-7 days)
**Nice to have, not blocking**

- [ ] **Add Soft Deletion** (2-3 days) - if needed
  - Add `deleted: bool` flag to Node
  - Filter deleted nodes in search
  - Add `compact()` function to rebuild without deleted nodes

- [ ] **Add Persistence** (3-4 days) - if needed
  - Implement `save(path: []const u8)` function
  - Implement `load(path: []const u8)` function
  - Serialize: nodes, connections, metadata
  - Handle allocator differences on load

---

## Performance Considerations

### Target Requirements
- **Query latency:** < 100ms for k=5 nearest neighbors
- **Vector dimensions:** 768 or 1024 (embeddinggemma)
- **Index size:** Unknown (depends on codebase size)

### Current Benchmarks
Located in `benchmarks/single_threaded_benchmarks.zig`:
```zig
.num_points = 100_000,
.dimensions = &[_]usize{ 128, 512, 768, 1024 }, // ✅ Includes your sizes!
.num_queries = 10_000,
.k_values = &[_]usize{ 10, 25, 50, 100 },
```

**Status:** ⚠️ Benchmarks exist but have Zig 0.15 format errors

**Next Step:** Fix and run to validate performance

### HNSW Parameters
Current defaults (in tests):
```zig
HNSW(f32).init(allocator, m: 16, ef_construction: 200)
```

- `m`: Max connections per layer (higher = better accuracy, slower search)
- `ef_construction`: Candidate list size during build (higher = better quality)

May need tuning for your use case.

---

## Decision Points

### Should You Continue with zvdb?

**✅ Reasons to Use zvdb:**
- Pure Zig - full control, easy to modify
- Clean codebase - well-tested, understandable
- Already handles your dimensions (768/1024)
- 2-3 days of work for essential features
- Learning opportunity
- No C dependencies

**❌ Reasons to Look Elsewhere:**
- 2-3 days development time
- Less battle-tested than alternatives
- No community support
- Missing persistence (if critical)

### Alternative Options

| Option | Pros | Cons |
|--------|------|------|
| **hnswlib** (C++) | Battle-tested, feature-complete, fast | C++ dependency, harder to modify |
| **Faiss** (C++) | Industry standard, highly optimized | Heavy dependency, complex API |
| **Build your own** | Full control, Zig-native | 2-4 weeks development time |

**Recommendation:** Try zvdb first. If 2-3 days of enhancement is acceptable, you get a pure Zig solution. If performance doesn't meet requirements after tuning, fall back to hnswlib.

---

## Next Steps

### Immediate Actions (When Resuming)

1. **Decide:** Continue with zvdb or explore alternatives?

2. **If continuing with zvdb:**
   - Start with Priority 1 tasks (cosine similarity + custom IDs)
   - Fix benchmarks and validate performance
   - Document any parameter tuning needed

3. **If exploring alternatives:**
   - Research hnswlib Zig bindings
   - Check if Faiss has C API usable from Zig
   - Estimate integration effort

### Quick Win (1 hour)
Fix and run benchmarks to get performance data:
```bash
# Fix format strings, then:
zig build bench-single
```

This will tell you if zvdb can meet your latency requirements before investing in feature development.

---

## Technical Notes

### Code Locations
- **HNSW implementation:** `src/hnsw.zig`
- **Distance function:** `src/hnsw.zig:182-192`
- **ID generation:** `src/hnsw.zig:77`
- **Tests:** `src/test_hnsw.zig`
- **Benchmarks:** `benchmarks/single_threaded_benchmarks.zig`

### Git History
- `6227664`: "remove deletion (HNSW no like deletion)" - deletion removed
- `c48c9c8`: "we begin" - initial implementation
- Today: Updated for Zig 0.15.2 compatibility

### Design Considerations
- **Why deletion is hard:** HNSW is a graph structure. Removing nodes requires reconnecting neighbors and maintaining graph quality.
- **Why cosine similarity:** Embedding models produce normalized vectors where angle (cosine) matters more than distance.
- **Why custom IDs:** Your code graph nodes need stable IDs to cross-reference with vectors.

---

**Document Version:** 1.0
**Last Updated:** 2025-10-19
