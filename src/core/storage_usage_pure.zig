//! Pure (io-free) helpers for the Storage settings page — unit-testable via
//! `zig build test`. storage_usage.zig routes through these so the tested logic
//! IS the shipped logic.

const std = @import("std");

/// What a stored item *is*, which decides how dangerous deleting it is and how
/// the row is presented. Ordered least → most destructive.
pub const Kind = enum {
    /// Re-fetched automatically on next use. Safe to drop, costs a refetch.
    cache,
    /// Large downloaded artifacts (ML models, the Suwayomi jar, a python venv).
    /// Safe to drop, but re-downloading is expensive — warn about the size.
    download,
    /// Irreplaceable: the library, watch history, settings. Never offer a
    /// one-click delete for these; they are shown for accounting only.
    user_data,
};

/// Whether the UI may offer a "remove" action for this kind at all.
pub fn isRemovable(kind: Kind) bool {
    return switch (kind) {
        .cache, .download => true,
        .user_data => false,
    };
}

/// Whether removing this needs the two-step confirm (vs a plain button).
/// Big re-downloads deserve a confirm even though they are technically safe.
pub fn needsConfirm(kind: Kind) bool {
    return switch (kind) {
        .cache => false,
        .download, .user_data => true,
    };
}

/// Human byte size into `buf`: "0 B", "512 B", "1.0 KB", "9.8 MB", "1.3 GB".
///
/// Binary units (1024), matching what `du -h` reports, so the number a user
/// sees here matches the one their file manager shows. One decimal place from
/// KB up; bytes are shown whole because "0.5 KB" reads worse than "512 B".
pub fn formatBytes(bytes: u64, buf: []u8) []const u8 {
    const KB: u64 = 1024;
    const MB: u64 = 1024 * KB;
    const GB: u64 = 1024 * MB;
    const TB: u64 = 1024 * GB;
    if (bytes < KB) return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "?";
    const f = @as(f64, @floatFromInt(bytes));
    if (bytes < MB) return std.fmt.bufPrint(buf, "{d:.1} KB", .{f / @as(f64, KB)}) catch "?";
    if (bytes < GB) return std.fmt.bufPrint(buf, "{d:.1} MB", .{f / @as(f64, MB)}) catch "?";
    if (bytes < TB) return std.fmt.bufPrint(buf, "{d:.1} GB", .{f / @as(f64, GB)}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.1} TB", .{f / @as(f64, TB)}) catch "?";
}

/// Percentage of `total` that `part` occupies, clamped to 0…100. Returns 0 when
/// total is 0 rather than dividing by zero.
pub fn percentOf(part: u64, total: u64) u8 {
    if (total == 0) return 0;
    const pct = (part * 100) / total;
    return @intCast(@min(pct, 100));
}

test "formatBytes picks sane units at every boundary" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0 B", formatBytes(0, &b));
    try std.testing.expectEqualStrings("512 B", formatBytes(512, &b));
    try std.testing.expectEqualStrings("1023 B", formatBytes(1023, &b));
    // Exactly 1 KB must roll over to KB, not print "1024 B".
    try std.testing.expectEqualStrings("1.0 KB", formatBytes(1024, &b));
    try std.testing.expectEqualStrings("1.0 MB", formatBytes(1024 * 1024, &b));
    try std.testing.expectEqualStrings("1.0 GB", formatBytes(1024 * 1024 * 1024, &b));
    // The real numbers from a live install (715 MB models, 1.3 GB total).
    try std.testing.expectEqualStrings("715.0 MB", formatBytes(715 * 1024 * 1024, &b));
    const one_three_gb: u64 = @intFromFloat(1.3 * 1024.0 * 1024.0 * 1024.0);
    try std.testing.expectEqualStrings("1.3 GB", formatBytes(one_three_gb, &b));
}

test "formatBytes never overflows a small buffer" {
    var tiny: [3]u8 = undefined;
    // bufPrint fails → "?" sentinel, never a partial/garbage string.
    try std.testing.expectEqualStrings("?", formatBytes(123456789, &tiny));
}

test "percentOf clamps and never divides by zero" {
    try std.testing.expectEqual(@as(u8, 0), percentOf(100, 0));
    try std.testing.expectEqual(@as(u8, 50), percentOf(50, 100));
    try std.testing.expectEqual(@as(u8, 100), percentOf(100, 100));
    // A stale part larger than total (scan raced a delete) must not wrap.
    try std.testing.expectEqual(@as(u8, 100), percentOf(200, 100));
    try std.testing.expectEqual(@as(u8, 0), percentOf(0, 0));
}

test "user data is never one-click removable" {
    // REGRESSION GUARD: the library/watch-history row must never grow a delete
    // button. Losing opal.db is unrecoverable — there is no backup of it.
    try std.testing.expect(!isRemovable(.user_data));
    try std.testing.expect(isRemovable(.cache));
    try std.testing.expect(isRemovable(.download));
    // Expensive re-downloads still get the two-step confirm.
    try std.testing.expect(!needsConfirm(.cache));
    try std.testing.expect(needsConfirm(.download));
}
