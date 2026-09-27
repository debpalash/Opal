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
    smart: bool = false,
};

pub const SMART_CONTINUE: i64 = -1;
pub const SMART_RECENT: i64 = -2;

fn isSmart(id: i64) bool {
    return id == SMART_CONTINUE or id == SMART_RECENT;
}

fn validName(name: []const u8) bool {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    return trimmed.len > 0 and trimmed.len < 96;
}

pub fn list(out: []Summary) usize {
    if (out.len == 0) return 0;
    // One statement keeps the per-frame native drawer read bounded: smart
    // counts and saved collections share a single prepare/step lifecycle.
    const stmt = db.prepare(
        "SELECT -1,'Continue watching',COUNT(*),COALESCE(MAX(updated_at),0),1,0 " ++
            "FROM watch_history WHERE link<>'' AND percent>=2 AND percent<95 HAVING COUNT(*)>0 " ++
            "UNION ALL SELECT -2,'Recently played',COUNT(*),COALESCE(MAX(updated_at),0),1,0 " ++
            "FROM watch_history WHERE link<>'' HAVING COUNT(*)>0 " ++
            "UNION ALL SELECT c.id,c.name,COUNT(i.position),c.updated_at,0,1 " ++
            "FROM media_collections c LEFT JOIN media_collection_items i ON i.collection_id=c.id GROUP BY c.id " ++
            "ORDER BY 6,4 DESC,2 COLLATE NOCASE LIMIT ?1",
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
        out[n].smart = db.columnInt64(stmt, 4) != 0;
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
    if ((!isSmart(id) and id <= 0) or !queue.isReady()) return false;
    if (replace) {
        const ticket = queue.requestAction(.clear, null) orelse return false;
        if (!queue.waitAction(ticket, 5000)) return false;
    }
    return if (isSmart(id)) enqueueSmartItems(id) else enqueueItems(id);
}

/// UI-thread variant: apply replacement immediately instead of queueing an
/// action and waiting on the same thread that would drain it.
pub fn enqueueNative(id: i64, replace: bool) bool {
    if ((!isSmart(id) and id <= 0) or !queue.isReady()) return false;
    if (replace) queue.clearAll();
    return if (isSmart(id)) enqueueSmartItems(id) else enqueueItems(id);
}

fn enqueueSmartItems(id: i64) bool {
    const sql = if (id == SMART_CONTINUE)
        "SELECT link,name FROM watch_history WHERE link<>'' AND percent>=2 AND percent<95 ORDER BY updated_at DESC LIMIT ?1"
    else
        "SELECT link,name FROM watch_history WHERE link<>'' ORDER BY updated_at DESC LIMIT ?1";
    const stmt = db.prepare(sql) orelse return false;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, MAX_ITEMS);
    var count: usize = 0;
    while (db.step(stmt) == db.c.SQLITE_ROW and count < MAX_ITEMS) : (count += 1) {
        const url = db.columnText(stmt, 0) orelse continue;
        queue.addToQueue(url, db.columnText(stmt, 1) orelse "", "history");
    }
    return count > 0;
}

fn enqueueItems(id: i64) bool {
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

test "smart collection ids remain separate from persisted ids" {
    try std.testing.expect(isSmart(SMART_CONTINUE));
    try std.testing.expect(isSmart(SMART_RECENT));
    try std.testing.expect(!isSmart(1));
    try std.testing.expect(!isSmart(-3));
}
