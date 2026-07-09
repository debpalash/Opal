const std = @import("std");
const builtin = @import("builtin");

/// Centralized allocator for Opal — still ONE global allocator (see
/// CLAUDE.md), but the backing differs by build mode:
///  - Debug: DebugAllocator with safety on — use-after-free/double-free
///    detection + the shutdown leak report that gates every session.
///  - Release: std.heap.smp_allocator — the thread-safe allocator built for
///    ReleaseFast. The DebugAllocator's bookkeeping showed up in production
///    CPU samples on every hot path (posters, JSON, resolver churn).
const debug_mode = builtin.mode == .Debug;

var gpa_instance = if (debug_mode) std.heap.DebugAllocator(.{
    .safety = true, // use-after-free / double-free detection
    .thread_safe = true, // resolver/search/AI threads allocate concurrently
}){} else {};

pub const allocator: std.mem.Allocator = if (debug_mode)
    gpa_instance.allocator()
else
    std.heap.smp_allocator;

/// Shutdown hook: leak detection is a Debug-only feature (smp_allocator has
/// no tracking); release builds just say goodbye.
pub fn deinit() void {
    if (debug_mode) {
        const check = gpa_instance.deinit();
        if (check == .leak) {
            std.debug.print("\n\n!! GLOBAL MEMORY LEAK DETECTED !!\n\n", .{});
        } else {
            std.debug.print("Clean shutdown: 0 memory leaks.\n", .{});
        }
    }
}
