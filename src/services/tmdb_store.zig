const std = @import("std");
const state = @import("../core/state.zig");
const paths = @import("../core/paths.zig");
const db = @import("../core/db.zig");

const alloc = @import("../core/alloc.zig").allocator;

// ══════════════════════════════════════════════════════════
// Item CRUD
// ══════════════════════════════════════════════════════════

pub fn upsertItem(item: *const state.TmdbItem) void {
    const sql =
        \\INSERT OR REPLACE INTO tmdb_items (id, title, year, release_date, rating, overview, media_type, genre_text, poster_path)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
    ;
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);

    db.bindInt(stmt, 1, item.id);
    db.bindText(stmt, 2, item.title[0..item.title_len]);
    db.bindText(stmt, 3, item.year[0..item.year_len]);
    db.bindText(stmt, 4, item.release_date[0..item.release_date_len]);
    db.bindDouble(stmt, 5, @floatCast(item.rating));
    db.bindText(stmt, 6, item.overview[0..item.overview_len]);
    db.bindText(stmt, 7, item.media_type[0..item.media_type_len]);
    db.bindText(stmt, 8, item.genre_text[0..item.genre_text_len]);
    db.bindText(stmt, 9, item.poster_path[0..item.poster_path_len]);

    _ = db.step(stmt);
}

// ══════════════════════════════════════════════════════════
// List Management (favorites, watchlist, watching)
// ══════════════════════════════════════════════════════════

pub fn isInList(list: *std.ArrayListUnmanaged(state.TmdbItem), id: i32) bool {
    for (list.items) |entry| {
        if (entry.id == id) return true;
    }
    return false;
}

pub fn toggleList(list: *std.ArrayListUnmanaged(state.TmdbItem), item: *state.TmdbItem) void {
    const list_name = getListName(list);

    for (list.items, 0..) |entry, i| {
        if (entry.id == item.id) {
            _ = list.orderedRemove(i);
            removeFromDbList(item.id, list_name);
            return;
        }
    }
    list.append(alloc, item.*) catch {};

    upsertItem(item);
    addToDbList(item.id, list_name);
}

fn addToDbList(item_id: i32, list_name: []const u8) void {
    const sql = "INSERT OR IGNORE INTO tmdb_lists (item_id, list_name) VALUES (?1, ?2)";
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);
    db.bindInt(stmt, 1, item_id);
    db.bindText(stmt, 2, list_name);
    _ = db.step(stmt);
}

fn removeFromDbList(item_id: i32, list_name: []const u8) void {
    const sql = "DELETE FROM tmdb_lists WHERE item_id = ?1 AND list_name = ?2";
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);
    db.bindInt(stmt, 1, item_id);
    db.bindText(stmt, 2, list_name);
    _ = db.step(stmt);
}

fn getListName(list: *std.ArrayListUnmanaged(state.TmdbItem)) []const u8 {
    if (list == &state.app.tmdb.favorites) return "fav";
    if (list == &state.app.tmdb.watchlist) return "wl";
    if (list == &state.app.tmdb.watching) return "wat";
    return "unknown";
}

// ══════════════════════════════════════════════════════════
// Load / Save
// ══════════════════════════════════════════════════════════

pub fn saveLists() void {
    // No-op: lists are persisted on each toggleList call.
}

pub fn loadLists() void {
    loadListFromDb("fav", &state.app.tmdb.favorites);
    loadListFromDb("wl", &state.app.tmdb.watchlist);
    loadListFromDb("wat", &state.app.tmdb.watching);
}

fn loadListFromDb(list_name: []const u8, target: *std.ArrayListUnmanaged(state.TmdbItem)) void {
    const sql =
        \\SELECT i.id, i.title, i.year, i.release_date, i.rating, i.overview,
        \\       i.media_type, i.genre_text, i.poster_path
        \\FROM tmdb_lists l
        \\JOIN tmdb_items i ON l.item_id = i.id
        \\WHERE l.list_name = ?1
        \\ORDER BY l.added_at DESC
    ;
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, list_name);

    while (db.step(stmt) == db.c.SQLITE_ROW) {
        var item = state.TmdbItem{};
        item.id = db.columnInt(stmt, 0);
        db.copyColumn(stmt, 1, &item.title, &item.title_len);
        db.copyColumn(stmt, 2, &item.year, &item.year_len);
        db.copyColumn(stmt, 3, &item.release_date, &item.release_date_len);
        item.rating = @floatCast(db.columnDouble(stmt, 4));
        db.copyColumn(stmt, 5, &item.overview, &item.overview_len);
        db.copyColumn(stmt, 6, &item.media_type, &item.media_type_len);
        db.copyColumn(stmt, 7, &item.genre_text, &item.genre_text_len);
        db.copyColumn(stmt, 8, &item.poster_path, &item.poster_path_len);
        target.append(alloc, item) catch {};
    }
}

// ══════════════════════════════════════════════════════════
// Poster Cache
// ══════════════════════════════════════════════════════════

pub fn cachePosterData(item_id: i32, jpeg_data: []const u8, width: u32, height: u32) void {
    const sql = "INSERT OR REPLACE INTO poster_cache (item_id, jpeg_data, width, height) VALUES (?1, ?2, ?3, ?4)";
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);
    db.bindInt(stmt, 1, item_id);
    db.bindBlob(stmt, 2, jpeg_data);
    _ = db.c.sqlite3_bind_int(stmt, 3, @intCast(width));
    _ = db.c.sqlite3_bind_int(stmt, 4, @intCast(height));
    _ = db.step(stmt);
}

pub fn loadCachedPoster(item_id: i32) ?struct { data: []u8, w: u32, h: u32 } {
    const sql = "SELECT jpeg_data, width, height FROM poster_cache WHERE item_id = ?1";
    const stmt = db.prepare(sql) orelse return null;
    defer db.finalize(stmt);
    db.bindInt(stmt, 1, item_id);

    if (db.step(stmt) == db.c.SQLITE_ROW) {
        if (db.columnBlob(stmt, 0)) |blob| {
            const w: u32 = @intCast(db.columnInt(stmt, 1));
            const h: u32 = @intCast(db.columnInt(stmt, 2));
            const copy = alloc.alloc(u8, blob.len) catch return null;
            @memcpy(copy, blob);
            return .{ .data = copy, .w = w, .h = h };
        }
    }
    return null;
}

// ══════════════════════════════════════════════════════════
// Migration from old tmdb_lists.tsv
// ══════════════════════════════════════════════════════════

pub fn migrateFromTsv() void {
    const home = @import("../core/io_global.zig").getenv("HOME") orelse return;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/.config/zigzag/tmdb_lists.tsv", .{home}) catch return;

    const file = @import("../core/io_global.zig").openFileAbsolute(path, .{}) catch return;
    defer file.close(@import("../core/io_global.zig").io());

    var read_buf: [8192]u8 = undefined;
    const n = @import("../core/io_global.zig").readAll(file, &read_buf) catch return;
    if (n == 0) return;

    db.exec("BEGIN");

    var lines = std.mem.splitScalar(u8, read_buf[0..n], '\n');
    while (lines.next()) |line| {
        if (line.len < 5) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const list_name = fields.next() orelse continue;
        const id_str = fields.next() orelse continue;
        const title = fields.next() orelse continue;
        const year = fields.next() orelse continue;
        const rating_str = fields.next() orelse "0";
        const mt = fields.next() orelse "movie";

        const id = std.fmt.parseInt(i32, id_str, 10) catch continue;
        const rating = std.fmt.parseFloat(f32, rating_str) catch 0;

        var item = state.TmdbItem{};
        item.id = id;
        item.rating = rating;
        const tlen = @min(title.len, 127);
        @memcpy(item.title[0..tlen], title[0..tlen]);
        item.title_len = tlen;
        const ylen = @min(year.len, 7);
        @memcpy(item.year[0..ylen], year[0..ylen]);
        item.year_len = ylen;
        const mlen = @min(mt.len, 7);
        @memcpy(item.media_type[0..mlen], mt[0..mlen]);
        item.media_type_len = mlen;

        upsertItem(&item);
        addToDbList(id, list_name);
    }

    db.exec("COMMIT");

    var old_buf: [512]u8 = undefined;
    const old_path = std.fmt.bufPrint(&old_buf, "{s}/.config/zigzag/tmdb_lists.tsv.migrated", .{home}) catch return;
    @import("../core/io_global.zig").renameAbsolute(path, old_path) catch {};
}

// Also migrate old separate tmdb.db if it exists
pub fn migrateOldDb() void {
    const home = @import("../core/io_global.zig").getenv("HOME") orelse return;
    var path_buf: [512]u8 = undefined;
    const old_db_path = std.fmt.bufPrintZ(&path_buf, "{s}/.config/zigzag/tmdb.db", .{home}) catch return;
    // Just delete it — data was already in tmdb_lists.tsv which we migrated above
    @import("../core/io_global.zig").deleteFileAbsolute(old_db_path) catch {};
}
