//! Sub-tab strip fit: decides which tabs keep their text label so the strip
//! never clips a trailing tab off-screen on narrow windows (e.g. Plugins
//! "Content plugins" at 640 px). Labels drop in steps: all labels -> only the
//! active tab's label -> icons only. Pure so the shell strip routes through it.
const std = @import("std");

pub const Mode = enum { full, active_label, icons };

/// `avail`: strip viewport width (<= 0 = unknown, e.g. first frame -> full).
/// `chrome`: per-tab width without its label (margin + padding + icon).
/// `label_gap`: icon-to-label spacing, only paid when a label is shown.
/// `pad`: the bar's own horizontal padding.
pub fn fitMode(avail: f32, pad: f32, chrome: f32, label_gap: f32, labels: []const f32, active: usize) Mode {
    if (avail <= 0 or labels.len == 0) return .full;
    const n: f32 = @floatFromInt(labels.len);
    var full: f32 = pad + n * chrome;
    for (labels) |w| full += w + label_gap;
    if (full <= avail) return .full;
    const active_w = if (active < labels.len) labels[active] + label_gap else 0;
    if (pad + n * chrome + active_w <= avail) return .active_label;
    return .icons;
}

pub fn showLabel(mode: Mode, idx: usize, active: usize) bool {
    return switch (mode) {
        .full => true,
        .active_label => idx == active,
        .icons => false,
    };
}

test "plugins strip at 640 wide drops inactive labels instead of clipping Content plugins" {
    // Measured at 640x800: strip viewport 576, body-font label widths for
    // Sources, Suwayomi, Debrid, Trakt, Content plugins; chrome 36, gap 4+6+6.
    const labels = [_]f32{ 57.5, 74.5, 49.5, 37.5, 115.5 };
    const m = fitMode(576, 8, 36, 16, &labels, 4);
    try std.testing.expectEqual(Mode.active_label, m);
    try std.testing.expect(showLabel(m, 4, 4));
    try std.testing.expect(!showLabel(m, 0, 4));
    // Same strip at 1360 wide (viewport 1136) keeps every label.
    try std.testing.expectEqual(Mode.full, fitMode(1136, 8, 36, 16, &labels, 4));
}

test "wide strip keeps every label" {
    const labels = [_]f32{ 57, 74, 49, 38, 109 };
    const m = fitMode(1300, 8, 40, 4, &labels, 0);
    try std.testing.expectEqual(Mode.full, m);
    for (0..labels.len) |i| try std.testing.expect(showLabel(m, i, 0));
}

test "very narrow strip falls back to icons only" {
    const labels = [_]f32{ 57, 74, 49, 38, 109 };
    const m = fitMode(250, 8, 40, 4, &labels, 4);
    try std.testing.expectEqual(Mode.icons, m);
    try std.testing.expect(!showLabel(m, 4, 4));
}

test "unknown width or empty strip renders full" {
    const labels = [_]f32{ 57, 74 };
    try std.testing.expectEqual(Mode.full, fitMode(0, 8, 40, 4, &labels, 0));
    try std.testing.expectEqual(Mode.full, fitMode(100, 8, 40, 4, &.{}, 0));
}

test "exact fit is full; out-of-range active is treated as no label" {
    const labels = [_]f32{ 10, 10 };
    // 8 + 2*40 + 2*(10+4) = 116
    try std.testing.expectEqual(Mode.full, fitMode(116, 8, 40, 4, &labels, 0));
    try std.testing.expectEqual(Mode.active_label, fitMode(115, 8, 40, 4, &labels, 99));
}
