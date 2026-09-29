//! Persistent list dismissal. Payload files remain on disk; explicit new
//! downloads or "Show removed files" make them visible again.
const std = @import("std");
const db = @import("../core/db.zig");

pub fn hidden(path: []const u8) bool {
    const stmt = db.prepare("SELECT 1 FROM dismissed_downloads WHERE path=?1") orelse return false;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, path);
    return db.step(stmt) == db.c.SQLITE_ROW;
}

pub fn setHidden(path: []const u8, value: bool) bool {
    const stmt = db.prepare(if (value) "INSERT OR IGNORE INTO dismissed_downloads(path) VALUES(?1)" else "DELETE FROM dismissed_downloads WHERE path=?1") orelse return false;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, path);
    return db.step(stmt) == db.c.SQLITE_DONE;
}

pub fn hiddenChild(root: []const u8, name: []const u8) bool {
    var buf: [2048]u8 = undefined;
    return hidden(std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, name }) catch return false);
}

pub fn restoreAll() void {
    db.exec("DELETE FROM dismissed_downloads");
}
