const std = @import("std");
const playlist = @import("playlist_pure.zig");

fn currentIndex(ids: []const i64, current_id: i64) ?usize {
    if (current_id < 0) return null;
    return std.mem.indexOfScalar(i64, ids, current_id);
}

fn firstUnplayed(played: []const bool, order: ?[]const u32) ?usize {
    if (order) |indices| {
        if (indices.len != played.len) return null;
        for (indices) |raw| if (@as(usize, @intCast(raw)) >= played.len) return null;
        for (indices) |raw| {
            const idx: usize = @intCast(raw);
            if (!played[idx]) return idx;
        }
        return null;
    }
    return std.mem.indexOfScalar(bool, played, false);
}

/// Choose relative to stable queue identity. Without a current queue item,
/// forward playback starts at the first unplayed item; repeat-all may restart
/// an entirely played queue. Previous requires a current identity.
pub fn relativeIndex(
    ids: []const i64,
    played: []const bool,
    current_id: i64,
    dir: i32,
    repeat: playlist.RepeatMode,
    shuffle_order: ?[]const u32,
) ?usize {
    if (ids.len == 0 or ids.len != played.len) return null;
    if (currentIndex(ids, current_id)) |current| {
        return if (dir >= 0)
            playlist.nextIndex(current, ids.len, repeat, shuffle_order)
        else
            playlist.prevIndex(current, ids.len, repeat, shuffle_order);
    }
    if (dir < 0 or repeat == .one) return null;
    return firstUnplayed(played, shuffle_order) orelse if (repeat == .all)
        (if (shuffle_order) |order| @as(usize, @intCast(order[0])) else 0)
    else
        null;
}

test "fresh queue starts at first unplayed in natural or shuffled order" {
    const ids = [_]i64{ 10, 20, 30 };
    const played = [_]bool{ true, false, false };
    try std.testing.expectEqual(@as(?usize, 1), relativeIndex(&ids, &played, -1, 1, .off, null));
    const order = [_]u32{ 2, 0, 1 };
    try std.testing.expectEqual(@as(?usize, 2), relativeIndex(&ids, &played, -1, 1, .off, &order));
}

test "stable current identity drives repeat and reorder-safe next" {
    const ids = [_]i64{ 30, 10, 20 };
    const played = [_]bool{ false, true, false };
    try std.testing.expectEqual(@as(?usize, 2), relativeIndex(&ids, &played, 10, 1, .off, null));
    try std.testing.expectEqual(@as(?usize, 1), relativeIndex(&ids, &played, 10, 1, .one, null));
    try std.testing.expectEqual(@as(?usize, 0), relativeIndex(&ids, &played, 20, 1, .all, null));
    try std.testing.expectEqual(@as(?usize, 0), relativeIndex(&ids, &played, 10, -1, .off, null));
}

test "played queue stops without repeat and restarts with repeat all" {
    const ids = [_]i64{ 1, 2 };
    const played = [_]bool{ true, true };
    try std.testing.expectEqual(@as(?usize, null), relativeIndex(&ids, &played, -1, 1, .off, null));
    try std.testing.expectEqual(@as(?usize, 0), relativeIndex(&ids, &played, -1, 1, .all, null));
    try std.testing.expectEqual(@as(?usize, null), relativeIndex(&ids, &played, -1, -1, .all, null));
}

test "malformed parallel state and shuffle order fail closed" {
    const ids = [_]i64{ 1, 2 };
    const short_played = [_]bool{false};
    try std.testing.expectEqual(@as(?usize, null), relativeIndex(&ids, &short_played, -1, 1, .off, null));
    const played = [_]bool{ false, false };
    const bad_order = [_]u32{ 0, 3 };
    try std.testing.expectEqual(@as(?usize, null), relativeIndex(&ids, &played, -1, 1, .off, &bad_order));
}
