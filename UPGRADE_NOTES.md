# Zig 0.15.1 Upgrade Notes

This document outlines the changes made to upgrade ZigMark from Zig 0.14 to Zig 0.15.1.

## Overview

Zig 0.15.1 introduced significant breaking changes, particularly in the standard library's `ArrayList` API and I/O subsystem. This upgrade required modifications across all source files.

## Breaking Changes

### 1. ArrayListUnmanaged API Changes

**Issue:** Methods like `deinit()` and `append()` now require an explicit `Allocator` parameter.

**Before (Zig 0.14):**
```zig
var list = std.ArrayListUnmanaged(T){};
try list.append(item);
list.deinit();
```

**After (Zig 0.15.1):**
```zig
var list = std.ArrayListUnmanaged(T){};
try list.append(allocator, item);
list.deinit(allocator);
```

**Files Modified:**
- `markdown.zig` - 15+ call sites updated
- `main.zig` - 10+ call sites updated
- `lexer.zig` - Minor updates

### 2. I/O System Overhaul

**Issue:** The `std.io.getStdOut().writer()` API was completely removed as part of a major I/O redesign.

**Before (Zig 0.14):**
```zig
var buffered_writer = std.io.bufferedWriter(std.io.getStdOut().writer());
const writer = buffered_writer.writer();
```

**After (Zig 0.15.1):**
```zig
// Created custom BufferedStdoutWriter using std.posix.write()
var stdout_buffer: [8192]u8 = undefined;
var buffered_writer = ui.BufferedStdoutWriter.init(&stdout_buffer);
const writer = buffered_writer.writer();
```

**Solution Implemented:**
- Created custom `BufferedStdoutWriter` in `ui.zig` using `std.io.GenericWriter`
- Used `std.posix.write()` for direct stdout operations
- Replaced terminal control sequences with `std.posix.write()` calls

### 3. Build System Changes

**Issue:** Executable configuration API changed.

**Before (Zig 0.14):**
```zig
const exe = b.addExecutable(.{
    .name = "my_tui_app",
    .root_source_file = b.path("main.zig"),
    .target = target,
    .optimize = optimize,
});
```

**After (Zig 0.15.1):**
```zig
const exe = b.addExecutable(.{
    .name = "my_tui_app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

### 4. Const Qualifier Issues

**Issue:** Several functions returning `ArrayListUnmanaged` needed `var` instead of `const` to allow `deinit()` calls.

**Pattern:**
```zig
// Changed from:
const list = try someFunction();
defer list.deinit(allocator);  // Error: const can't call mutable method

// To:
var list = try someFunction();
defer list.deinit(allocator);  // OK
```

## Custom Implementation: BufferedStdoutWriter

Since the standard library's buffered writer API changed dramatically, we implemented a custom solution:

```zig
pub const BufferedStdoutWriter = struct {
    buffer: []u8,
    pos: usize,

    pub const WriteError = error{};

    pub fn write(self: *BufferedStdoutWriter, bytes: []const u8) WriteError!usize {
        // Buffer management and std.posix.write() calls
    }

    pub const Writer = std.io.GenericWriter(*BufferedStdoutWriter, WriteError, write);

    pub fn flush(self: *BufferedStdoutWriter) !void {
        // Flush buffer to stdout via std.posix.write()
    }
};
```

## Files Modified Summary

| File | Changes | Line Changes |
|------|---------|--------------|
| `build.zig` | Build system API update | ~8 lines |
| `main.zig` | ArrayList API, BufferedWriter | ~211 lines |
| `markdown.zig` | ArrayList API throughout | ~231 lines |
| `ui.zig` | Custom BufferedWriter, posix.write | ~44 lines |
| `lexer.zig` | ArrayList API | ~32 lines |

**Total:** 5 files modified, ~285 insertions, ~241 deletions

## Testing

After the upgrade, the application builds successfully and maintains all functionality:
- Markdown parsing (CommonMark compliance)
- Terminal UI rendering
- Interactive navigation
- Editor integration

## References

- [Zig 0.15.1 Release Notes](https://ziglang.org/download/0.15.1/release-notes.html)
- Key changes: ArrayListUnmanaged now default, I/O subsystem redesign for future async support

## Migration Tips for Similar Projects

1. **Search and replace patterns:**
   - `.deinit()` → `.deinit(allocator)`
   - `.append(item)` → `.append(allocator, item)`
   - `.appendSlice(slice)` → `.appendSlice(allocator, slice)`

2. **For I/O operations:**
   - Consider using `std.posix.write()` directly for simple cases
   - Implement custom buffered writers using `std.io.GenericWriter`
   - Check if `std.debug.print()` suffices for stderr output

3. **Build system:**
   - Wrap executable configuration in `root_module = b.createModule()`
   - No changes to module dependencies

## Performance Impact

No measurable performance regression observed. The custom `BufferedStdoutWriter` performs equivalently to the previous standard library implementation.