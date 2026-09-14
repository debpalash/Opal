//! Durable named snapshots of Opal's queue.
const std = @import("std");
const db = @import("../core/db.zig");
const queue = @import("queue.zig");

pub const MAX_COLLECTIONS: usize = 64;
pub const MAX_ITEMS: usize = queue.MAX_QUEUE;

pub const Summary = struct {
    id: i64 = 0,
    name: [96]u8 = std.mem.zeroes([96]u8),
    name_len: usize = 0,
    item_count: usize = 0,
    updated_at: i64 = 0,
};

fn validName(name: []const u8) bool {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    return trimmed.len > 0 and trimmed.len < 96;
}

pub fn list(out: []Summary) usize {
    const stmt = db.prepare(
        "SELECT c.id,c.name,COUNT(i.position),c.updated_at FROM media_collections c " ++
            "LEFT JOIN media_collection_items i ON i.collection_id=c.id " ++
            "GROUP BY c.id ORDER BY c.updated_at DESC,c.name COLLATE NOCASE LIMIT ?1",
    ) orelse return 0;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, @intCast(@min(out.len, MAX_COLLECTIONS)));
    var n: usize = 0;
    while (n < out.len and db.step(stmt) == db.c.SQLITE_ROW) : (n += 1) {
        out[n] = .{};
        out[n].id = db.columnInt64(stmt, 0);
        db.copyColumn(stmt, 1, &out[n].name, &out[n].name_len);
        out[n].item_count = @intCast(@max(db.columnInt64(stmt, 2), 0));
        out[n].updated_at = db.columnInt64(stmt, 3);
    }
    return n;
}

fn idForName(name: []const u8) ?i64 {
    const stmt = db.prepare("SELECT id FROM media_collections WHERE name=?1 LIMIT 1") orelse return null;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, name);
    return if (db.step(stmt) == db.c.SQLITE_ROW) db.columnInt64(stmt, 0) else null;
}

/// Atomically replace a named collection with the current coherent queue.
pub fn saveQueue(name_raw: []const u8) bool {
    const name = std.mem.trim(u8, name_raw, " \t\r\n");
    if (!validName(name)) return false;
    var items: [MAX_ITEMS]queue.QueueItem = undefined;
    const count = queue.snapshotItems(&items);
    db.exec("BEGIN IMMEDIATE");
    var committed = false;
    defer if (!committed) db.exec("ROLLBACK");
    const upsert = db.prepare(
        "INSERT INTO media_collections(name,updated_at) VALUES(?1,strftime('%s','now')) " ++
            "ON CONFLICT(name) DO UPDATE SET updated_at=excluded.updated_at",
    ) orelse return false;
    db.bindText(upsert, 1, name);
    const inserted = db.step(upsert) == db.c.SQLITE_DONE;
    db.finalize(upsert);
    if (!inserted) return false;
    const collection_id = idForName(name) orelse return false;
    const clear = db.prepare("DELETE FROM media_collection_items WHERE collection_id=?1") orelse return false;
    db.bindInt64(clear, 1, collection_id);
    const cleared = db.step(clear) == db.c.SQLITE_DONE;
    db.finalize(clear);
    if (!cleared) return false;
    for (items[0..count], 0..) |*item, position| {
        const stmt = db.prepare("INSERT INTO media_collection_items(collection_id,position,url,title,source,thumb_url) VALUES(?1,?2,?3,?4,?5,?6)") orelse return false;
        defer db.finalize(stmt);
        db.bindInt64(stmt, 1, collection_id);
        db.bindInt64(stmt, 2, @intCast(position));
        db.bindText(stmt, 3, item.url[0..item.url_len]);
        db.bindText(stmt, 4, item.title[0..item.title_len]);
        db.bindText(stmt, 5, item.source[0..item.source_len]);
        db.bindText(stmt, 6, item.thumb_url[0..item.thumb_url_len]);
        if (db.step(stmt) != db.c.SQLITE_DONE) return false;
    }
    db.exec("COMMIT");
    committed = true;
    return true;
}

pub fn remove(id: i64) bool {
    if (id <= 0) return false;
    const children = db.prepare("DELETE FROM media_collection_items WHERE collection_id=?1") orelse return false;
    db.bindInt64(children, 1, id);
    const cleared = db.step(children) == db.c.SQLITE_DONE;
    db.finalize(children);
    if (!cleared) return false;
    const stmt = db.prepare("DELETE FROM media_collections WHERE id=?1") orelse return false;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, id);
    return db.step(stmt) == db.c.SQLITE_DONE;
}

/// Stage every item through the existing queue producer path. `replace`
/// clears the live queue first and waits for UI-thread acknowledgement.
pub fn enqueue(id: i64, replace: bool) bool {
    if (id <= 0 or !queue.isReady()) return false;
    if (replace) {
        const ticket = queue.requestAction(.clear, null) orelse return false;
        if (!queue.waitAction(ticket, 5000)) return false;
    }
    const stmt = db.prepare("SELECT url,title,source,thumb_url FROM media_collection_items WHERE collection_id=?1 ORDER BY position LIMIT ?2") orelse return false;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, id);
    db.bindInt64(stmt, 2, MAX_ITEMS);
    var count: usize = 0;
    while (db.step(stmt) == db.c.SQLITE_ROW and count < MAX_ITEMS) : (count += 1) {
        const url = db.columnText(stmt, 0) orelse continue;
        queue.addToQueueWithThumb(url, db.columnText(stmt, 1) orelse "", db.columnText(stmt, 2) orelse "direct", db.columnText(stmt, 3) orelse "");
    }
    return count > 0;
}
