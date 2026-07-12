//! Pure paging logic for the onboarding tour — no dvui/state imports, so it is
//! unit-testable in isolation (see build.zig `test` step). `onboarding.zig`
//! routes its Back/Next/dots through these so the tested logic *is* the shipped
//! logic (no drift).

const std = @import("std");

/// Is `page` the final page of a `total`-page tour? Governs whether the primary
/// button reads "Next →" (advance) or "Get started" (finish). A 0-page tour has
/// no last page in the advance sense, but we treat page 0 as last so an empty
/// tour still finishes rather than dead-ending.
pub fn isLast(page: usize, total: usize) bool {
    if (total == 0) return true;
    return page + 1 >= total;
}

/// Clamp a raw page index into [0, total-1]. Guards against a stored/replayed
/// index that outruns the current page count (e.g. tour shrank between builds).
pub fn clamp(page: usize, total: usize) usize {
    if (total == 0) return 0;
    return @min(page, total - 1);
}

/// Advance one page, saturating at the last page (never past it).
pub fn next(page: usize, total: usize) usize {
    return clamp(page + 1, total);
}

/// Go back one page, saturating at 0 (usize can't go negative).
pub fn prev(page: usize) usize {
    return if (page == 0) 0 else page - 1;
}

test "isLast: only the final index is last" {
    try std.testing.expect(!isLast(0, 4));
    try std.testing.expect(!isLast(2, 4));
    try std.testing.expect(isLast(3, 4));
    // Single-page tour: page 0 is immediately last.
    try std.testing.expect(isLast(0, 1));
    // Degenerate empty tour finishes rather than looping.
    try std.testing.expect(isLast(0, 0));
}

test "next saturates at the last page" {
    try std.testing.expectEqual(@as(usize, 1), next(0, 4));
    try std.testing.expectEqual(@as(usize, 3), next(2, 4));
    // Already last — stays put, no overflow past the end.
    try std.testing.expectEqual(@as(usize, 3), next(3, 4));
    try std.testing.expectEqual(@as(usize, 3), next(99, 4));
}

test "prev saturates at zero" {
    try std.testing.expectEqual(@as(usize, 0), prev(0));
    try std.testing.expectEqual(@as(usize, 0), prev(1));
    try std.testing.expectEqual(@as(usize, 2), prev(3));
}

test "clamp reins in an out-of-range replayed index" {
    try std.testing.expectEqual(@as(usize, 0), clamp(0, 4));
    try std.testing.expectEqual(@as(usize, 3), clamp(3, 4));
    // Tour shrank underneath a stale index.
    try std.testing.expectEqual(@as(usize, 3), clamp(9, 4));
    try std.testing.expectEqual(@as(usize, 0), clamp(9, 0));
}
