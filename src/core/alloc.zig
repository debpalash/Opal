const std = @import("std");

/// Centralized allocator for Opal — replaces page_allocator usage.
/// GeneralPurposeAllocator pools allocations internally, avoiding
/// mmap/munmap syscalls on every small string allocation.
var gpa_instance = std.heap.DebugAllocator(.{
    .safety = true, // Enable use-after-free / double-free detection in debug
    .thread_safe = true, // Multiple threads (resolver, search, AI) allocate concurrently
}){};

pub const allocator = gpa_instance.allocator();

/// Call at app shutdown to detect leaks (debug only)
pub fn deinit() void {
    const check = gpa_instance.deinit();
    if (check == .leak) {
        std.debug.print("\n\n!! GLOBAL MEMORY LEAK DETECTED !!\n\n", .{});
    } else {
        std.debug.print("Clean shutdown: 0 memory leaks.\n", .{});
    }
}
