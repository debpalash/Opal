//! Pure types + decisions for the unified `library_items` read-model.
const std = @import("std");

/// A denormalized cross-vertical library row (fixed buffers per Opal convention).
pub const LibraryItem = struct {
    kind: [16]u8 = std.mem.zeroes([16]u8),
    kind_len: usize = 0,
    item_id: [128]u8 = std.mem.zeroes([128]u8),
    item_id_len: usize = 0,
    title: [200]u8 = std.mem.zeroes([200]u8),
    title_len: usize = 0,
    poster: [256]u8 = std.mem.zeroes([256]u8),
    poster_len: usize = 0,
    resume_secs: f64 = 0,
    duration_secs: f64 = 0,
    percent: f64 = 0,
    is_favorite: bool = false,
    next_label: [48]u8 = std.mem.zeroes([48]u8),
    next_label_len: usize = 0,
    deep_link: [512]u8 = std.mem.zeroes([512]u8),
    deep_link_len: usize = 0,
};

/// Percent from resume/duration, clamped to [0,100]. 0 when duration is unknown.
pub fn percentOf(resume_secs: f64, duration_secs: f64) f64 {
    if (duration_secs <= 0 or resume_secs <= 0) return 0;
    const p = resume_secs / duration_secs * 100.0;
    return std.math.clamp(p, 0, 100);
}

/// The lower edge of the "Continue" band. It exists to keep an accidental
/// few-second play off the rail, NOT to gate on absolute progress — chapter 1
/// of a 100-chapter novel is exactly 1%, and a `> 1.0` floor silently hid every
/// such first chapter. A 2-second touch of a 2-hour film is 0.03%, so a lower
/// floor still filters the case this guard is actually for.
pub const CONTINUE_MIN_PCT: f64 = 0.5;
pub const CONTINUE_MAX_PCT: f64 = 95.0;

/// A row belongs on the "Continue watching" rail when it's meaningfully started
/// but not essentially finished.
pub fn isContinue(percent: f64) bool {
    return percent > CONTINUE_MIN_PCT and percent < CONTINUE_MAX_PCT;
}

test "percentOf + isContinue bands" {
    try std.testing.expectEqual(@as(f64, 50), percentOf(60, 120));
    try std.testing.expectEqual(@as(f64, 0), percentOf(60, 0)); // unknown duration
    try std.testing.expect(isContinue(50));
    try std.testing.expect(!isContinue(0.03)); // a 2s touch of a 2h film
    try std.testing.expect(!isContinue(0.5)); // exactly at the floor — excluded
    // Regression: chapter 1 of a 100-chapter novel is exactly 1%. A `> 1.0`
    // floor hid every first chapter from the Continue rail.
    try std.testing.expect(isContinue(1.0));
    try std.testing.expect(!isContinue(98)); // essentially done
}
