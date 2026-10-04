//! Responsive local-library forms; no UI or database dependencies.
const std = @import("std");

pub fn stackFormControls(available_width: f32) bool {
    // Folder paths and metadata titles need usable fields beside their actions.
    return !std.math.isFinite(available_width) or available_width < 620;
}

pub fn emptyHint(query_length: usize, duplicates_only: bool, roots: usize) []const u8 {
    if (query_length > 0) return "No files match this search.";
    if (duplicates_only) return "No likely duplicates found.";
    if (roots == 0) return "Add a media folder, then scan to see your files here.";
    return "No files indexed yet. Scan your media folders to refresh.";
}

test "Local library folder and editor controls stack in compact windows" {
    try std.testing.expect(stackFormControls(584)); // 640px shell minus panel padding.
    try std.testing.expect(stackFormControls(619));
    try std.testing.expect(!stackFormControls(620));
    try std.testing.expect(!stackFormControls(1200));
    try std.testing.expect(stackFormControls(std.math.nan(f32)));
}

test "Local library empty states give the next useful action" {
    try std.testing.expectEqualStrings("No files match this search.", emptyHint(3, false, 0));
    try std.testing.expectEqualStrings("No likely duplicates found.", emptyHint(0, true, 2));
    try std.testing.expectEqualStrings("Add a media folder, then scan to see your files here.", emptyHint(0, false, 0));
    try std.testing.expectEqualStrings("No files indexed yet. Scan your media folders to refresh.", emptyHint(0, false, 1));
}

/// Exact view identity, independent of frame count and presentation width.
pub const QueryKey = struct {
    query: [256]u8 = @splat(0),
    len: usize = 0,
    duplicates: bool = false,
    revision: u64 = 0,
    pub fn init(query: []const u8, duplicates: bool, revision: u64) QueryKey {
        var key: QueryKey = .{ .len = @min(query.len, 256), .duplicates = duplicates, .revision = revision };
        @memcpy(key.query[0..key.len], query[0..key.len]);
        return key;
    }
    pub fn eql(a: QueryKey, b: QueryKey) bool {
        return a.revision == b.revision and a.duplicates == b.duplicates and std.mem.eql(u8, a.query[0..a.len], b.query[0..b.len]);
    }
};
test "local snapshot unchanged frames retain cache; query and commit invalidate" {
    const key = QueryKey.init("Film", false, 4);
    for (0..120) |_| try std.testing.expect(key.eql(QueryKey.init("Film", false, 4)));
    try std.testing.expect(!key.eql(QueryKey.init("film", false, 4)));
    try std.testing.expect(!key.eql(QueryKey.init("Film", true, 4)));
    try std.testing.expect(!key.eql(QueryKey.init("Film", false, 5)));
}

pub fn acceptsSnapshot(requested: QueryKey, completed: QueryKey, current_revision: u64) bool {
    return requested.eql(completed) and current_revision == completed.revision;
}
test "local snapshot rejects stale worker and mid-query database commit" {
    const old = QueryKey.init("old", false, 7);
    const current = QueryKey.init("new", false, 7);
    try std.testing.expect(!acceptsSnapshot(current, old, 7));
    try std.testing.expect(!acceptsSnapshot(old, old, 8));
    try std.testing.expect(acceptsSnapshot(current, current, 7));
}
