//! Scroll half of the UI-position restore (ui/ui_restore.zig), kept in core
//! and dvui-free so service-owned lists (search results, TMDB gallery and
//! episodes) can report and receive offsets without importing the UI layer.
//! UI thread only — called from page renders and appFrame.

const std = @import("std");
const io = @import("io_global.zig");
const pure = @import("ui_restore_pure.zig");

/// How long a restored scroll waits for its list to grow tall enough once that
/// list is on screen (content streams in from the network).
const SETTLE_MS: i64 = 6000;

pub var pending_target: pure.ScrollTarget = .none;
pub var pending_y: f32 = 0;
var pending_deadline_ms: i64 = 0;

/// Last offset each retained list reported.
var observed_y = std.EnumArray(pure.ScrollTarget, f32).initFill(0);

pub fn arm(target: pure.ScrollTarget, y: f32) void {
    pending_target = target;
    pending_y = y;
    pending_deadline_ms = 0;
}

pub fn cancel() void {
    pending_target = .none;
}

/// The offset to persist for `target`: a restored offset still waiting for
/// its content is the real position.
pub fn current(target: pure.ScrollTarget) f32 {
    if (target == .none) return 0;
    return if (pending_target == target) pending_y else observed_y.get(target);
}

/// Called by a retained list right before its scrollArea with its live
/// geometry. Records the offset for capture and returns an offset to apply
/// once a pending restore fits (see ui_restore_pure.scrollStep).
pub fn hook(target: pure.ScrollTarget, scroll_max: f32, viewport_y: f32) ?f32 {
    observed_y.set(target, viewport_y);
    if (pending_target != target) return null;
    const now_ms = io.milliTimestamp();
    if (pending_deadline_ms == 0) pending_deadline_ms = now_ms + SETTLE_MS;
    const y = pure.scrollStep(pending_y, scroll_max, now_ms >= pending_deadline_ms) orelse return null;
    pending_target = .none;
    observed_y.set(target, y);
    return y;
}
