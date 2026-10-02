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

fn scanList(list: *std.ArrayListUnmanaged(state.TmdbItem), id: i32) bool {
    for (list.items) |*entry| {
        if (entry.id == id) return true;
    }
    return false;
}

// `isInList` is called three times per visible poster card, and favorites /
// watchlist / watching each hold up to ~1900 items. A card grid therefore turned
// each rendered frame into O(3 × visible_cards × list_len) integer comparisons.
// Keep an id set per list and rebuild it only when the list is actually mutated.
//
// Both mutation points are in this file — `toggleList` (append / orderedRemove)
// and `loadListFromDb` (full repopulate) — so invalidation is explicit rather
// than guessed from a length compare. Reads stay on the render thread, which is
// the only place these are consulted.
const IdSet = struct {
    map: std.AutoHashMapUnmanaged(i32, void) = .empty,
    built_len: usize = 0,
    valid: bool = false,
};

var id_sets: [3]IdSet = .{ .{}, .{}, .{} };

fn setIndexFor(list: *std.ArrayListUnmanaged(state.TmdbItem)) ?usize {
    if (list == &state.app.tmdb.favorites) return 0;
    if (list == &state.app.tmdb.watchlist) return 1;
    if (list == &state.app.tmdb.watching) return 2;
    // Any other list (the transient results list) is short-lived per search, so
    // a set would cost more than the scan it replaces.
    return null;
}

fn invalidateSet(list: *std.ArrayListUnmanaged(state.TmdbItem)) void {
    if (setIndexFor(list)) |index| id_sets[index].valid = false;
}

pub fn isInList(list: *std.ArrayListUnmanaged(state.TmdbItem), id: i32) bool {
    const index = setIndexFor(list) orelse return scanList(list, id);
    const set = &id_sets[index];
    // The length compare is a cheap safety net for a mutation that bypassed an
    // explicit invalidation; it can only ever cause a needless rebuild.
    if (!set.valid or set.built_len != list.items.len) {
        set.map.clearRetainingCapacity();
        for (list.items) |entry| {
            set.map.put(alloc, entry.id, {}) catch return scanList(list, id);
        }
        set.built_len = list.items.len;
        set.valid = true;
    }
    return set.map.contains(id);
}

pub fn toggleList(list: *std.ArrayListUnmanaged(state.TmdbItem), item: *state.TmdbItem) void {
    const list_name = getListName(list);

    for (list.items, 0..) |entry, i| {
        if (entry.id == item.id) {
            const id = entry.id;
            var removed = list.orderedRemove(i);
            @import("../core/poster.zig").deinitPoster(&removed.poster_pixels, &removed.poster_tex);
            removeFromDbList(id, list_name);
            invalidateSet(list);
            return;
        }
    }
    // Lists own their poster resources; copying a live card's texture/pixels
    // aliases ownership and can also copy a permanently busy worker flag.
    var saved = item.*;
    saved.poster_pixels = null;
    saved.poster_tex = null;
    saved.poster_fetching = false;
    saved.poster_attempted = false;
    saved.poster_failed = false;
    saved.poster_w = 0;
    saved.poster_h = 0;
    list.append(alloc, saved) catch return;

    upsertItem(item);
    addToDbList(item.id, list_name);
    invalidateSet(list);
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
    // A full repopulate replaces every id, so any set built from the previous
    // contents is stale — and a reload can produce the same length.
    invalidateSet(target);
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

// Poster caching lives in core/poster.zig (URL-hash keyed, shared by all
// providers, wired into fetchAsync). The old item_id-keyed helpers that sat
// here were never called and were removed.

// ══════════════════════════════════════════════════════════
// Migration from old tmdb_lists.tsv
// ══════════════════════════════════════════════════════════

pub fn migrateFromTsv() void {
    var __cfg_buf_0: [512]u8 = undefined;
    const home = @import("../core/paths.zig").configDir(&__cfg_buf_0);
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/tmdb_lists.tsv", .{home}) catch return;

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
    const old_path = std.fmt.bufPrint(&old_buf, "{s}/tmdb_lists.tsv.migrated", .{home}) catch return;
    @import("../core/io_global.zig").renameAbsolute(path, old_path) catch {};
}

// Also migrate old separate tmdb.db if it exists
pub fn migrateOldDb() void {
    var __cfg_buf_1: [512]u8 = undefined;
    const home = @import("../core/paths.zig").configDir(&__cfg_buf_1);
    var path_buf: [512]u8 = undefined;
    const old_db_path = std.fmt.bufPrintZ(&path_buf, "{s}/tmdb.db", .{home}) catch return;
    // Just delete it — data was already in tmdb_lists.tsv which we migrated above
    @import("../core/io_global.zig").deleteFileAbsolute(old_db_path) catch {};
}

test "Browse regression saved lists do not inherit image ownership or busy flags" {
    var list: std.ArrayListUnmanaged(state.TmdbItem) = .empty;
    defer list.deinit(alloc);
    var item = state.TmdbItem{ .id = 42, .poster_fetching = true, .poster_attempted = true };
    item.poster_pixels = try std.heap.c_allocator.alloc(u8, 4);
    defer std.heap.c_allocator.free(item.poster_pixels.?);
    toggleList(&list, &item);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expect(!list.items[0].poster_fetching);
    try std.testing.expect(list.items[0].poster_pixels == null);
    try std.testing.expect(!list.items[0].poster_attempted);
}
