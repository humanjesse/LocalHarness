# Memory Leak Fix - Hot Context Injection

**Date:** 2025-11-02  
**Issue:** Memory leaks detected on app exit from hot context generation

---

## Problem

Two memory leaks were identified when exiting the application:

```
error(gpa): memory address 0x7fc6268a2080 leaked:
/usr/lib/zig/std/array_list.zig:1231:56: 0x14d331e in ensureTotalCapacityPrecise
```

Both leaks originated from `ArrayListUnmanaged(u8)` used to build hot context strings.

---

## Root Causes

### Leak 1: Early Return Without Cleanup

**File:** `context_management/injection.zig`  
**Function:** `generateHotContext()`

**Issue:**
```zig
var context = std.ArrayListUnmanaged(u8){};
errdefer context.deinit(allocator);  // Only on error!

// ... build context ...

if (!has_content) {
    return try allocator.dupe(u8, "");  // LEAK: context not freed!
}

return try context.toOwnedSlice(allocator);  // OK: ownership transferred
```

The `errdefer` only triggers on error, not on successful early returns. When there's no content to inject, we return an empty string but forget to free the `context` buffer.

**Fix:**
```zig
if (!has_content) {
    context.deinit(allocator);  // FREE the unused buffer
    return try allocator.dupe(u8, "");
}
```

### Leak 2: Deferred Cleanup Too Late

**File:** `app.zig`  
**Function:** `startStreaming()`

**Issue:**
```zig
var hot_context_msg: ?ollama.ChatMessage = null;
const hot_context = injection.generateHotContext(...);

if (hot_context) |ctx| {
    defer self.allocator.free(ctx);  // Frees original
    
    if (ctx.len > 0) {
        const ctx_copy = try self.allocator.dupe(u8, ctx);  // ALLOCATED
        
        hot_context_msg = .{
            .content = ctx_copy,
            // ...
        };
        
        try ollama_messages.insert(..., hot_context_msg.?);  // INSERTED
        
        // ... more code that could error ...
    }
}
defer if (hot_context_msg) |msg| self.allocator.free(msg.content);  // TOO LATE!
```

**Problem:** If anything throws an error between `ctx_copy` allocation and the final defer, the copy leaks. The defer is too far from the allocation.

**Fix:**
```zig
var hot_context_content: ?[]const u8 = null;
defer if (hot_context_content) |content| self.allocator.free(content);  // IMMEDIATE

if (hot_context) |ctx| {
    defer self.allocator.free(ctx);
    
    if (ctx.len > 0) {
        const ctx_copy = try self.allocator.dupe(u8, ctx);
        hot_context_content = ctx_copy;  // Track immediately for cleanup
        
        // ... rest of code ...
    }
}
```

Now the defer is set up immediately, and any error after allocation will properly clean up.

---

## Changes Made

### File: `context_management/injection.zig`

**Lines Changed:** 141-144

**Before:**
```zig
if (!has_content) {
    return try allocator.dupe(u8, "");
}
```

**After:**
```zig
if (!has_content) {
    context.deinit(allocator); // Free the unused buffer
    return try allocator.dupe(u8, "");
}
```

### File: `app.zig`

**Lines Changed:** 692-732

**Before:**
```zig
var hot_context_msg: ?ollama.ChatMessage = null;
const hot_context = injection.generateHotContext(...);

if (hot_context) |ctx| {
    defer self.allocator.free(ctx);
    if (ctx.len > 0) {
        const ctx_copy = try self.allocator.dupe(u8, ctx);
        
        hot_context_msg = .{ .content = ctx_copy, ... };
        try ollama_messages.insert(..., hot_context_msg.?);
        // ...
    }
}
defer if (hot_context_msg) |msg| self.allocator.free(msg.content);
```

**After:**
```zig
var hot_context_content: ?[]const u8 = null;
defer if (hot_context_content) |content| self.allocator.free(content);

if (hot_context) |ctx| {
    defer self.allocator.free(ctx);
    if (ctx.len > 0) {
        const ctx_copy = try self.allocator.dupe(u8, ctx);
        hot_context_content = ctx_copy; // Track for cleanup
        
        hot_context_msg = .{ .content = ctx_copy, ... };
        try ollama_messages.insert(..., hot_context_msg.?);
        // ...
    }
}
```

---

## Testing

### Verification Steps

1. **Build and run:**
   ```bash
   zig build
   ./zig-out/bin/localharness
   ```

2. **Exit immediately:**
   ```bash
   echo "/quit" | ./zig-out/bin/localharness
   ```

3. **Check for leaks:**
   ```bash
   # Should see NO "error(gpa): memory address ... leaked" messages
   ```

4. **Test with message (triggers hot context):**
   ```bash
   echo -e "Hello\n/quit" | ./zig-out/bin/localharness
   ```

### Results

✅ **Before fix:** 2 memory leaks detected  
✅ **After fix:** 0 memory leaks detected

---

## Memory Management Patterns

### Good Pattern: Immediate Defer

```zig
var data: ?[]const u8 = null;
defer if (data) |d| allocator.free(d);  // Set up cleanup FIRST

data = try allocator.dupe(u8, source);  // Allocate
// Even if code below errors, defer will clean up
```

### Bad Pattern: Late Defer

```zig
const data = try allocator.dupe(u8, source);  // Allocate

// ... lots of code that could error ...

defer allocator.free(data);  // TOO LATE - errors above leak!
```

### Good Pattern: errdefer + Regular Cleanup

```zig
var list = std.ArrayListUnmanaged(u8){};
errdefer list.deinit(allocator);  // On error

if (early_return_condition) {
    list.deinit(allocator);  // Explicit cleanup on success
    return something;
}

return try list.toOwnedSlice(allocator);  // Transfer ownership
```

---

## Related Issues

### Audit Recommendations

Based on this fix, we should audit other ArrayListUnmanaged usage:

1. ✅ **injection.zig** - Fixed
2. ✅ **app.zig** - Fixed  
3. ✅ **processor.zig** - Reviewed, looks correct (has proper defers)
4. ✅ **queue.zig** - Reviewed, struct field (cleaned up in deinit)
5. ✅ **tracking.zig** - Reviewed, uses fromOwnedSlice/toOwnedSlice (correct pattern)
6. ✅ **compression.zig** - Reviewed, struct field (cleaned up in deinit)

**Result:** No other leaks found in context management code.

---

## Lessons Learned

1. **Defer placement matters:** Place defers IMMEDIATELY after allocation, not at end of function
2. **errdefer is not enough:** Need explicit cleanup on non-error early returns
3. **Testing with GPA:** Zig's GeneralPurposeAllocator leak detection is excellent - use it!
4. **Pattern consistency:** Follow "allocate → defer → use" pattern religiously

---

## Impact

**Severity:** Low (only leaks on app exit, not during normal operation)  
**Frequency:** Every app exit  
**User Impact:** None visible (memory freed by OS on process exit)  
**Developer Impact:** High (leak detector noise, indicates sloppy memory management)

**Priority:** Medium - Fix before merge, but not a critical bug

---

## Status

- [x] Issue identified
- [x] Root cause analyzed
- [x] Fix implemented
- [x] Fix tested
- [x] Code reviewed
- [ ] Merged to main

---

## References

- Main changes document: `docs/CONTEXT_MANAGEMENT_CHANGES.md`
- Zig ArrayListUnmanaged docs: https://ziglang.org/documentation/master/std/#std.ArrayListUnmanaged
- Memory management best practices: https://zig.guide/standard-library/allocators
