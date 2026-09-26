//! Unified library read-model (`library_items`). Every vertical calls
//! `upsertProgress` when it records playback progress and `setFavorite` on a
//! star toggle; the home surface reads `loadContinue`/`loadFavorites`. The source
//! tables stay authoritative — this is a denormalized cache so home reads ONE
//! place instead of ~7 schemas, and a future device sync replicates one table.

const std = @import("std");
const db = @import("../core/db.zig");
const pure = @import("library_pure.zig");

/// Record/refresh progress for an item. Preserves an existing `is_favorite`
/// (progress updates must not clear a star). `deep_link` is what resumes it.
pub fn upsertProgress(
    kind: []const u8,
    item_id: []const u8,
    title: []const u8,
    poster: []const u8,
    resume_secs: f64,
    duration_secs: f64,
    next_label: []const u8,
    deep_link: []const u8,
) void {
    if (kind.len == 0 or item_id.len == 0) return;
    const percent = pure.percentOf(resume_secs, duration_secs);
    const stmt = db.prepare(
        "INSERT INTO library_items(kind,item_id,title,poster,resume_secs,duration_secs,percent,next_label,deep_link,updated_at) " ++
            "VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,strftime('%s','now')) " ++
            "ON CONFLICT(kind,item_id) DO UPDATE SET title=excluded.title, poster=excluded.poster, " ++
            "resume_secs=excluded.resume_secs, duration_secs=excluded.duration_secs, percent=excluded.percent, " ++
            "next_label=excluded.next_label, deep_link=excluded.deep_link, updated_at=excluded.updated_at",
    ) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, kind);
    db.bindText(stmt, 2, item_id);
    db.bindText(stmt, 3, title);
    db.bindText(stmt, 4, poster);
    db.bindDouble(stmt, 5, resume_secs);
    db.bindDouble(stmt, 6, duration_secs);
    db.bindDouble(stmt, 7, percent);
    db.bindText(stmt, 8, next_label);
    db.bindText(stmt, 9, deep_link);
    _ = db.step(stmt);
}

/// Toggle/set a favorite, carrying a display snapshot so the Favorites rail can
/// paint without a source fetch. Returns nothing; preserves progress fields.
pub fn setFavorite(kind: []const u8, item_id: []const u8, fav: bool, title: []const u8, poster: []const u8, deep_link: []const u8) void {
    if (kind.len == 0 or item_id.len == 0) return;
    const stmt = db.prepare(
        "INSERT INTO library_items(kind,item_id,title,poster,is_favorite,deep_link,updated_at) " ++
            "VALUES(?1,?2,?3,?4,?5,?6,strftime('%s','now')) " ++
            "ON CONFLICT(kind,item_id) DO UPDATE SET is_favorite=excluded.is_favorite, " ++
            "title=CASE WHEN excluded.title!='' THEN excluded.title ELSE title END, " ++
            "poster=CASE WHEN excluded.poster!='' THEN excluded.poster ELSE poster END, " ++
            "deep_link=CASE WHEN excluded.deep_link!='' THEN excluded.deep_link ELSE deep_link END, " ++
            "updated_at=excluded.updated_at",
    ) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, kind);
    db.bindText(stmt, 2, item_id);
    db.bindText(stmt, 3, title);
    db.bindText(stmt, 4, poster);
    db.bindInt(stmt, 5, if (fav) 1 else 0);
    db.bindText(stmt, 6, deep_link);
    _ = db.step(stmt);
}

/// Read one source-owned favorite flag by stable identity. Source adapters use
/// this while rebuilding their transient browse rows so an Opal-local favorite
/// survives reconnects and pagination even when the upstream server has no
/// equivalent mutation (Plex is the important case).
pub fn isFavorite(kind: []const u8, item_id: []const u8) bool {
    if (kind.len == 0 or item_id.len == 0) return false;
    const stmt = db.prepare("SELECT is_favorite FROM library_items WHERE kind=?1 AND item_id=?2 LIMIT 1") orelse return false;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, kind);
    db.bindText(stmt, 2, item_id);
    return db.step(stmt) == db.c.SQLITE_ROW and db.columnInt64(stmt, 0) != 0;
}

pub const ItemState = struct {
    favorite: bool = false,
    user_rating: f64 = -1,
    resume_secs: f64 = 0,
    duration_secs: f64 = 0,
};

/// Read the durable user-owned state for one stable, source-namespaced item.
pub fn getState(kind: []const u8, item_id: []const u8) ItemState {
    if (kind.len == 0 or item_id.len == 0) return .{};
    const stmt = db.prepare("SELECT is_favorite,user_rating,resume_secs,duration_secs FROM library_items WHERE kind=?1 AND item_id=?2 LIMIT 1") orelse return .{};
    defer db.finalize(stmt);
    db.bindText(stmt, 1, kind);
    db.bindText(stmt, 2, item_id);
    if (db.step(stmt) != db.c.SQLITE_ROW) return .{};
    return .{
        .favorite = db.columnInt64(stmt, 0) != 0,
        .user_rating = db.columnDouble(stmt, 1),
        .resume_secs = db.columnDouble(stmt, 2),
        .duration_secs = db.columnDouble(stmt, 3),
    };
}

/// Persist a personal half-step rating. `null` clears it without removing any
/// progress or favorite state carried by the same unified row.
pub fn setRating(kind: []const u8, item_id: []const u8, rating: ?f64, title: []const u8, poster: []const u8) void {
    if (kind.len == 0 or item_id.len == 0) return;
    const value = if (rating) |r| std.math.clamp(r, 0, 10) else -1;
    const stmt = db.prepare(
        "INSERT INTO library_items(kind,item_id,title,poster,user_rating,updated_at) " ++
            "VALUES(?1,?2,?3,?4,?5,strftime('%s','now')) " ++
            "ON CONFLICT(kind,item_id) DO UPDATE SET user_rating=excluded.user_rating, " ++
            "title=CASE WHEN excluded.title!='' THEN excluded.title ELSE title END, " ++
            "poster=CASE WHEN excluded.poster!='' THEN excluded.poster ELSE poster END, " ++
            "updated_at=excluded.updated_at",
    ) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, kind);
    db.bindText(stmt, 2, item_id);
    db.bindText(stmt, 3, title);
    db.bindText(stmt, 4, poster);
    db.bindDouble(stmt, 5, value);
    _ = db.step(stmt);
}

fn readRow(stmt: ?*db.Stmt, out: *pure.LibraryItem) void {
    out.* = .{};
    db.copyColumn(stmt, 0, out.kind[0..], &out.kind_len);
    db.copyColumn(stmt, 1, out.item_id[0..], &out.item_id_len);
    db.copyColumn(stmt, 2, out.title[0..], &out.title_len);
    db.copyColumn(stmt, 3, out.poster[0..], &out.poster_len);
    out.resume_secs = db.columnDouble(stmt, 4);
    out.duration_secs = db.columnDouble(stmt, 5);
    out.percent = db.columnDouble(stmt, 6);
    out.is_favorite = db.columnInt64(stmt, 7) != 0;
    out.user_rating = db.columnDouble(stmt, 8);
    db.copyColumn(stmt, 9, out.next_label[0..], &out.next_label_len);
    db.copyColumn(stmt, 10, out.deep_link[0..], &out.deep_link_len);
    out.home_hidden = db.columnInt64(stmt, 11) != 0;
    out.home_pinned = db.columnInt64(stmt, 12) != 0;
}

const COLS = "kind,item_id,title,poster,resume_secs,duration_secs,percent,is_favorite,user_rating,next_label,deep_link,home_hidden,home_pinned";

/// Continue-watching rows (in-progress, newest first) into `out`; count filled.
pub fn loadContinue(out: []pure.LibraryItem) usize {
    // The band is comptime-formatted from the pure constants rather than
    // hardcoded, so the SQL filter and `pure.isContinue` can never drift apart.
    const BAND = std.fmt.comptimePrint(
        " FROM library_items WHERE percent > {d} AND percent < {d} AND home_hidden=0 ORDER BY home_pinned DESC,updated_at DESC LIMIT ?1",
        .{ pure.CONTINUE_MIN_PCT, pure.CONTINUE_MAX_PCT },
    );
    const stmt = db.prepare("SELECT " ++ COLS ++ BAND) orelse return 0;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, @intCast(out.len));
    var n: usize = 0;
    while (n < out.len and db.step(stmt) == db.c.SQLITE_ROW) : (n += 1) readRow(stmt, &out[n]);
    return n;
}

/// Pinning only changes Home ordering. Source progress and favorites remain
/// authoritative and untouched.
pub fn setHomePinned(kind: []const u8, item_id: []const u8, pinned: bool) void {
    const stmt = db.prepare("UPDATE library_items SET home_pinned=?3 WHERE kind=?1 AND item_id=?2") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, kind);
    db.bindText(stmt, 2, item_id);
    db.bindInt(stmt, 3, if (pinned) 1 else 0);
    _ = db.step(stmt);
}

/// Dismiss one Home card without deleting playback progress or its source row.
pub fn setHomeHidden(kind: []const u8, item_id: []const u8, hidden: bool) void {
    const stmt = db.prepare("UPDATE library_items SET home_hidden=?3 WHERE kind=?1 AND item_id=?2") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, kind);
    db.bindText(stmt, 2, item_id);
    db.bindInt(stmt, 3, if (hidden) 1 else 0);
    _ = db.step(stmt);
}

pub fn hiddenContinueCount() usize {
    const stmt = db.prepare("SELECT count(*) FROM library_items WHERE home_hidden=1 AND percent > ?1 AND percent < ?2") orelse return 0;
    defer db.finalize(stmt);
    db.bindDouble(stmt, 1, pure.CONTINUE_MIN_PCT);
    db.bindDouble(stmt, 2, pure.CONTINUE_MAX_PCT);
    if (db.step(stmt) != db.c.SQLITE_ROW) return 0;
    return @intCast(@max(0, db.columnInt64(stmt, 0)));
}

pub fn restoreHiddenContinue() void {
    const stmt = db.prepare("UPDATE library_items SET home_hidden=0 WHERE home_hidden=1 AND percent > ?1 AND percent < ?2") orelse return;
    defer db.finalize(stmt);
    db.bindDouble(stmt, 1, pure.CONTINUE_MIN_PCT);
    db.bindDouble(stmt, 2, pure.CONTINUE_MAX_PCT);
    _ = db.step(stmt);
}

/// Favorites (newest first) into `out`; count filled.
pub fn loadFavorites(out: []pure.LibraryItem) usize {
    const stmt = db.prepare("SELECT " ++ COLS ++ " FROM library_items WHERE is_favorite=1 ORDER BY updated_at DESC LIMIT ?1") orelse return 0;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, @intCast(out.len));
    var n: usize = 0;
    while (n < out.len and db.step(stmt) == db.c.SQLITE_ROW) : (n += 1) readRow(stmt, &out[n]);
    return n;
}
