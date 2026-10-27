//! Unified library read-model (`library_items`). Every vertical calls
//! `upsertProgress` when it records playback progress and `setFavorite` on a
//! star toggle; the home surface reads `loadContinue`/`loadFavorites`. The source
//! tables stay authoritative — this is a denormalized cache so home reads ONE
//! place instead of ~7 schemas, and a future device sync replicates one table.

const std = @import("std");
const db = @import("../core/db.zig");
const pure = @import("library_pure.zig");
const sync = @import("../core/sync.zig");

/// Bumped by every mutator below. Readers use it to decide whether their cached
/// rows are still current.
var version = std.atomic.Value(u64).init(1);

fn markDirty() void {
    _ = version.fetchAdd(1, .release);
}

/// Home-rail snapshot cache.
///
/// The Home surface reads `loadContinue`, `hiddenContinueCount` and
/// `loadFavorites` on every rendered frame. Each was a `prepare` + `step` +
/// `finalize` on the shared FULLMUTEX connection — three SQLite round trips per
/// frame, hundreds of microseconds, to return rows that almost never change
/// between two frames. Now they re-query only when a mutator has moved the
/// version. Same shape as iptv.zig's `fav_dirty`/`ensureFavSet`.
var rail_mutex: sync.Mutex = .{};
var rail_version: u64 = 0;
var continue_rows: [32]pure.LibraryItem = undefined;
var continue_len: usize = 0;
var hidden_continue: usize = 0;
var favorite_rows: [32]pure.LibraryItem = undefined;
var favorite_len: usize = 0;
var pending_continue: [32]pure.LibraryItem = undefined;
var pending_favorites: [32]pure.LibraryItem = undefined;

/// Rebuild the rails if a mutator ran since the last read. Must be called with
/// `rail_mutex` held.
fn refreshRailsLocked() void {
    const current = version.load(.acquire);
    if (current == rail_version) return;
    const next_continue = loadContinueUncached(&pending_continue) orelse return;
    const next_hidden = loadHiddenContinueCountUncached() orelse return;
    const next_favorites = loadFavoritesUncached(&pending_favorites) orelse return;
    @memcpy(continue_rows[0..next_continue], pending_continue[0..next_continue]);
    @memcpy(favorite_rows[0..next_favorites], pending_favorites[0..next_favorites]);
    continue_len = next_continue;
    hidden_continue = next_hidden;
    favorite_len = next_favorites;
    rail_version = current;
}

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
            "next_label=excluded.next_label, deep_link=excluded.deep_link, updated_at=excluded.updated_at, deleted=0",
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
    markDirty();
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
            "updated_at=excluded.updated_at, deleted=0",
    ) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, kind);
    db.bindText(stmt, 2, item_id);
    db.bindText(stmt, 3, title);
    db.bindText(stmt, 4, poster);
    db.bindInt(stmt, 5, if (fav) 1 else 0);
    db.bindText(stmt, 6, deep_link);
    _ = db.step(stmt);
    markDirty();
}

/// Read one source-owned favorite flag by stable identity. Source adapters use
/// this while rebuilding their transient browse rows so an Opal-local favorite
/// survives reconnects and pagination even when the upstream server has no
/// equivalent mutation (Plex is the important case).
pub fn isFavorite(kind: []const u8, item_id: []const u8) bool {
    if (kind.len == 0 or item_id.len == 0) return false;
    const stmt = db.prepare("SELECT is_favorite FROM library_items WHERE kind=?1 AND item_id=?2 AND deleted=0 LIMIT 1") orelse return false;
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
    const stmt = db.prepare("SELECT is_favorite,user_rating,resume_secs,duration_secs FROM library_items WHERE kind=?1 AND item_id=?2 AND deleted=0 LIMIT 1") orelse return .{};
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
            "updated_at=excluded.updated_at, deleted=0",
    ) orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, kind);
    db.bindText(stmt, 2, item_id);
    db.bindText(stmt, 3, title);
    db.bindText(stmt, 4, poster);
    db.bindDouble(stmt, 5, value);
    _ = db.step(stmt);
    markDirty();
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
/// Served from the rail cache when no mutator has run since the last call.
pub fn loadContinue(out: []pure.LibraryItem) usize {
    rail_mutex.lock();
    defer rail_mutex.unlock();
    refreshRailsLocked();
    return copyOut(continue_rows[0..continue_len], out);
}

/// Copy the longest prefix `out` can hold. `LibraryItem` is a fixed-size struct
/// with no pointers, so this is a plain memcpy — orders of magnitude cheaper
/// than re-running the query, which is the entire point of the cache.
fn copyOut(rows: []const pure.LibraryItem, out: []pure.LibraryItem) usize {
    const n = @min(rows.len, out.len);
    @memcpy(out[0..n], rows[0..n]);
    return n;
}

/// The uncached query behind `loadContinue`.
fn loadContinueUncached(out: []pure.LibraryItem) ?usize {
    // The band is comptime-formatted from the pure constants rather than
    // hardcoded, so the SQL filter and `pure.isContinue` can never drift apart.
    const BAND = std.fmt.comptimePrint(
        " FROM library_items WHERE percent > {d} AND percent < {d} AND home_hidden=0 AND deleted=0 ORDER BY home_pinned DESC,updated_at DESC LIMIT ?1",
        .{ pure.CONTINUE_MIN_PCT, pure.CONTINUE_MAX_PCT },
    );
    const stmt = db.prepare("SELECT " ++ COLS ++ BAND) orelse return null;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, @intCast(out.len));
    var n: usize = 0;
    while (n < out.len) : (n += 1) {
        const result = db.step(stmt);
        if (result == db.c.SQLITE_DONE) break;
        if (result != db.c.SQLITE_ROW) return null;
        readRow(stmt, &out[n]);
    }
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
    if (db.step(stmt) == db.c.SQLITE_DONE) markDirty();
}

/// Dismiss one Home card without deleting playback progress or its source row.
pub fn setHomeHidden(kind: []const u8, item_id: []const u8, hidden: bool) void {
    const stmt = db.prepare("UPDATE library_items SET home_hidden=?3 WHERE kind=?1 AND item_id=?2") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, kind);
    db.bindText(stmt, 2, item_id);
    db.bindInt(stmt, 3, if (hidden) 1 else 0);
    if (db.step(stmt) == db.c.SQLITE_DONE) markDirty();
}

pub fn hiddenContinueCount() usize {
    rail_mutex.lock();
    defer rail_mutex.unlock();
    refreshRailsLocked();
    return hidden_continue;
}

/// The uncached query behind `hiddenContinueCount`.
fn loadHiddenContinueCountUncached() ?usize {
    const stmt = db.prepare("SELECT count(*) FROM library_items WHERE home_hidden=1 AND deleted=0 AND percent > ?1 AND percent < ?2") orelse return null;
    defer db.finalize(stmt);
    db.bindDouble(stmt, 1, pure.CONTINUE_MIN_PCT);
    db.bindDouble(stmt, 2, pure.CONTINUE_MAX_PCT);
    if (db.step(stmt) != db.c.SQLITE_ROW) return null;
    return @intCast(@max(0, db.columnInt64(stmt, 0)));
}

pub fn restoreHiddenContinue() void {
    const stmt = db.prepare("UPDATE library_items SET home_hidden=0 WHERE home_hidden=1 AND percent > ?1 AND percent < ?2") orelse return;
    defer db.finalize(stmt);
    db.bindDouble(stmt, 1, pure.CONTINUE_MIN_PCT);
    db.bindDouble(stmt, 2, pure.CONTINUE_MAX_PCT);
    _ = db.step(stmt);
    markDirty();
}

/// Favorites (newest first) into `out`; count filled. Served from the rail cache
/// when no mutator has run since the last call.
pub fn loadFavorites(out: []pure.LibraryItem) usize {
    rail_mutex.lock();
    defer rail_mutex.unlock();
    refreshRailsLocked();
    return copyOut(favorite_rows[0..favorite_len], out);
}

/// The uncached query behind `loadFavorites`.
fn loadFavoritesUncached(out: []pure.LibraryItem) ?usize {
    const stmt = db.prepare("SELECT " ++ COLS ++ " FROM library_items WHERE is_favorite=1 AND deleted=0 ORDER BY updated_at DESC LIMIT ?1") orelse return null;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, @intCast(out.len));
    var n: usize = 0;
    while (n < out.len) : (n += 1) {
        const result = db.step(stmt);
        if (result == db.c.SQLITE_DONE) break;
        if (result != db.c.SQLITE_ROW) return null;
        readRow(stmt, &out[n]);
    }
    return n;
}

// ── Cross-device sync (ROADMAP 6.3) ──────────────────────────────────────────

const sync_pure = @import("library_sync_pure.zig");

const SYNC_COLS = "kind,item_id,title,poster,resume_secs,duration_secs,percent,is_favorite,user_rating,next_label,deep_link,home_hidden,home_pinned,updated_at,deleted,seq";

fn readSyncRow(stmt: ?*db.Stmt, out: *sync_pure.SyncRow) void {
    readRow(stmt, &out.item);
    out.updated_at = db.columnInt64(stmt, 13);
    out.deleted = db.columnInt64(stmt, 14) != 0;
    out.seq = db.columnInt64(stmt, 15);
}

/// This store's sync device id (db.zig seeds it once). Empty when unavailable.
pub fn deviceId(buf: *[sync_pure.DEVICE_ID_MAX]u8) []const u8 {
    const stmt = db.prepare("SELECT value FROM library_sync_meta WHERE key='device_id'") orelse return buf[0..0];
    defer db.finalize(stmt);
    if (db.step(stmt) != db.c.SQLITE_ROW) return buf[0..0];
    // copyColumn keeps a NUL byte, so read into one spare byte.
    var tmp: [sync_pure.DEVICE_ID_MAX + 1]u8 = undefined;
    var n: usize = 0;
    db.copyColumn(stmt, 0, &tmp, &n);
    if (!sync_pure.validDeviceId(tmp[0..n])) return buf[0..0];
    @memcpy(buf[0..n], tmp[0..n]);
    return buf[0..n];
}

/// Highest change sequence written so far (0 for an empty store). A run
/// snapshots it first so rows written mid-run wait for the next run.
pub fn maxSeq() i64 {
    const stmt = db.prepare("SELECT IFNULL(MAX(seq),0) FROM library_items") orelse return 0;
    defer db.finalize(stmt);
    if (db.step(stmt) != db.c.SQLITE_ROW) return 0;
    return db.columnInt64(stmt, 0);
}

/// Delete one item as a tombstone: the row stays (so the delete can sync and
/// an undo can restore it) but every reader hides it. A later local write or a
/// newer peer upsert clears the flag.
pub fn removeItem(kind: []const u8, item_id: []const u8) void {
    if (kind.len == 0 or item_id.len == 0) return;
    const stmt = db.prepare("UPDATE library_items SET deleted=1, updated_at=strftime('%s','now') WHERE kind=?1 AND item_id=?2 AND deleted=0") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, kind);
    db.bindText(stmt, 2, item_id);
    if (db.step(stmt) == db.c.SQLITE_DONE) markDirty();
}

/// Tombstone every live row of one kind (a "clear history" for that vertical).
pub fn removeKind(kind: []const u8) void {
    if (kind.len == 0) return;
    const stmt = db.prepare("UPDATE library_items SET deleted=1, updated_at=strftime('%s','now') WHERE kind=?1 AND deleted=0") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, kind);
    if (db.step(stmt) == db.c.SQLITE_DONE) markDirty();
}

/// Undo `removeKind("watch")` for rows whose source history came back
/// (watch_history.restoreBackup). Re-stamped so the restore syncs too.
pub fn restoreWatchHistory() void {
    db.exec("UPDATE library_items SET deleted=0, updated_at=strftime('%s','now') WHERE kind='watch' AND deleted=1 " ++
        "AND item_id IN (SELECT file_key FROM watch_history WHERE file_key<>'')");
    markDirty();
}

/// Rows with `after < seq <= snapshot_max`, oldest first, tombstones included,
/// skipping rows that came from `peer_device` (echo rule). Mirrors
/// `sync_pure.eligible`; `seq` is unique, so it alone is the keyset.
pub fn loadChangedSince(after: i64, snapshot_max: i64, peer_device: []const u8, out: []sync_pure.SyncRow) usize {
    // Never observe an applied row between its write and its origin tag.
    apply_mutex.lock();
    defer apply_mutex.unlock();
    const stmt = db.prepare("SELECT " ++ SYNC_COLS ++ " FROM library_items WHERE seq > ?1 AND seq <= ?2 " ++
        "AND (?3 = '' OR IFNULL(origin,'') <> ?3) ORDER BY seq ASC LIMIT ?4") orelse return 0;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, after);
    db.bindInt64(stmt, 2, snapshot_max);
    db.bindText(stmt, 3, peer_device);
    db.bindInt64(stmt, 4, @intCast(out.len));
    var n: usize = 0;
    while (n < out.len and db.step(stmt) == db.c.SQLITE_ROW) : (n += 1) readSyncRow(stmt, &out[n]);
    return n;
}

fn loadSyncRow(kind: []const u8, item_id: []const u8, out: *sync_pure.SyncRow) bool {
    const stmt = db.prepare("SELECT " ++ SYNC_COLS ++ " FROM library_items WHERE kind=?1 AND item_id=?2 LIMIT 1") orelse return false;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, kind);
    db.bindText(stmt, 2, item_id);
    if (db.step(stmt) != db.c.SQLITE_ROW) return false;
    readSyncRow(stmt, out);
    return true;
}

/// Serializes sync applies (one worker per peer + the API pull/push routes run
/// concurrently). Each row is read-decide-write-tag; without this, two peers'
/// pulls could both decide against the same stale local row and the older
/// write could land last, or a push could read a row before its origin tag.
/// The shared FULLMUTEX connection serializes single calls, not this sequence.
var apply_mutex: sync.Mutex = .{};

/// Apply peer rows under the last-writer-wins rule. Writes the PEER's
/// `updated_at` verbatim (never now) so a row does not bounce back as "newer".
/// The write takes a fresh local `seq` (trigger), so it relays onward to other
/// peers; `origin` (the sender's device id, '' if unknown) keeps it from being
/// sent back to the sender. Home layout (`home_hidden`/`home_pinned`) is
/// device-local and preserved. Returns how many rows changed; bumps the store
/// version once if any did.
pub fn applySyncRows(rows: []const sync_pure.SyncRow, origin: []const u8) usize {
    var applied: usize = 0;
    for (rows) |*row| {
        const it = &row.item;
        const kind = it.kind[0..it.kind_len];
        const id = it.item_id[0..it.item_id_len];
        var local: sync_pure.SyncRow = undefined;
        apply_mutex.lock();
        defer apply_mutex.unlock();
        const have = loadSyncRow(kind, id, &local);
        if (!sync_pure.shouldApply(if (have) &local else null, row)) continue;
        const stmt = db.prepare(
            "INSERT INTO library_items(kind,item_id,title,poster,resume_secs,duration_secs,percent,is_favorite,user_rating,next_label,deep_link,updated_at,deleted) " ++
                "VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13) " ++
                "ON CONFLICT(kind,item_id) DO UPDATE SET title=excluded.title, poster=excluded.poster, " ++
                "resume_secs=excluded.resume_secs, duration_secs=excluded.duration_secs, percent=excluded.percent, " ++
                "is_favorite=excluded.is_favorite, user_rating=excluded.user_rating, next_label=excluded.next_label, " ++
                "deep_link=excluded.deep_link, updated_at=excluded.updated_at, deleted=excluded.deleted",
        ) orelse continue;
        defer db.finalize(stmt);
        db.bindText(stmt, 1, kind);
        db.bindText(stmt, 2, id);
        db.bindText(stmt, 3, it.title[0..it.title_len]);
        db.bindText(stmt, 4, it.poster[0..it.poster_len]);
        db.bindDouble(stmt, 5, it.resume_secs);
        db.bindDouble(stmt, 6, it.duration_secs);
        db.bindDouble(stmt, 7, pure.percentOf(it.resume_secs, it.duration_secs));
        db.bindInt(stmt, 8, if (it.is_favorite) 1 else 0);
        db.bindDouble(stmt, 9, it.user_rating);
        db.bindText(stmt, 10, it.next_label[0..it.next_label_len]);
        db.bindText(stmt, 11, it.deep_link[0..it.deep_link_len]);
        db.bindInt64(stmt, 12, row.updated_at);
        db.bindInt(stmt, 13, if (row.deleted) 1 else 0);
        if (db.step(stmt) != db.c.SQLITE_DONE) continue;
        applied += 1;
        if (origin.len > 0) setOrigin(kind, id, origin);
    }
    if (applied > 0) markDirty();
    return applied;
}

/// Tag an applied row with its sender. `origin` is outside the seq triggers'
/// column list, so this does not take another seq.
fn setOrigin(kind: []const u8, item_id: []const u8, origin: []const u8) void {
    const stmt = db.prepare("UPDATE library_items SET origin=?3 WHERE kind=?1 AND item_id=?2") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, kind);
    db.bindText(stmt, 2, item_id);
    db.bindText(stmt, 3, origin);
    _ = db.step(stmt);
}
