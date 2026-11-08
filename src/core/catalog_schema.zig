//! Catalog persistence shared by desktop and device builds.
const std = @import("std");
const c = @import("opal-native-c");
const statements = [_][:0]const u8{
    \\CREATE TABLE IF NOT EXISTS tmdb_items (
    \\  id INTEGER PRIMARY KEY,
    \\  title TEXT NOT NULL DEFAULT '',
    \\  year TEXT DEFAULT '',
    \\  release_date TEXT DEFAULT '',
    \\  rating REAL DEFAULT 0,
    \\  overview TEXT DEFAULT '',
    \\  media_type TEXT DEFAULT 'movie',
    \\  genre_text TEXT DEFAULT '',
    \\  poster_path TEXT DEFAULT '',
    \\  created_at INTEGER DEFAULT (strftime('%s','now'))
    \\)
    ,
    \\CREATE TABLE IF NOT EXISTS tmdb_lists (
    \\  item_id INTEGER NOT NULL,
    \\  list_name TEXT NOT NULL,
    \\  added_at INTEGER DEFAULT (strftime('%s','now')),
    \\  PRIMARY KEY (item_id, list_name)
    \\)
    ,
};
pub fn create(handle: *c.sqlite3) !void {
    for (statements) |sql| if (c.sqlite3_exec(handle, sql, null, null, null) != c.SQLITE_OK) return error.CatalogSchemaFailed;
}
test "shared catalog schema persists list membership and remains idempotent" {
    var handle: ?*c.sqlite3 = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(":memory:", &handle));
    defer _ = c.sqlite3_close(handle);
    try create(handle.?);
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(handle, "INSERT INTO tmdb_items(id,title,poster_path) VALUES(42,'Saved title','https://example.test/poster.jpg'); INSERT INTO tmdb_lists(item_id,list_name) VALUES(42,'wl')", null, null, null));
    try create(handle.?);
    var stmt: ?*c.sqlite3_stmt = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(handle, "SELECT title FROM tmdb_lists JOIN tmdb_items ON item_id=id WHERE list_name='wl'", -1, &stmt, null));
    defer _ = c.sqlite3_finalize(stmt);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
    try std.testing.expectEqualStrings("Saved title", std.mem.span(c.sqlite3_column_text(stmt, 0)));
    try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(stmt));
}
