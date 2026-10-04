//! The Wanted list: titles Opal keeps looking for and downloads when a release
//! that fits the quality profile appears (CouchPotato for the AI age).
//!
//! Items are added by the user, the web UI, or an agent through the operation
//! registry. `tick()` runs from the shared frame/headless loops. It is cheap
//! when nothing is due; when an item is due it spawns ONE worker that searches
//! the torrent backends into a private sink (never disturbing the live search
//! results), picks the best release with `wanted_pure`, and stages the magnet.
//! The next `tick()` on the owner thread adds it to libtorrent, because torrent
//! adds are UI/owner-thread work. A separate pass marks downloads fulfilled when
//! libtorrent reports them complete.
//!
//! Policy (matching, scoring, retry backoff) lives in `wanted_pure.zig`.

const std = @import("std");
const c = @import("../core/c.zig");
const db = @import("../core/db.zig");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const io_g = @import("../core/io_global.zig");
const workers = @import("../core/workers.zig");
const sync = @import("../core/sync.zig");
const alloc = @import("../core/alloc.zig").allocator;
const pure = @import("wanted_pure.zig");
const resolver = @import("resolver.zig");
const risk = @import("torrent_risk_pure.zig");
const intents = @import("torrent_intents.zig");

pub const MAX_ITEMS: usize = 200;
const TICK_INTERVAL_MS: i64 = 30 * 1000;

var table_ready = std.atomic.Value(bool).init(false);
var busy = std.atomic.Value(bool).init(false);
var last_tick_ms: i64 = 0;
var last_follow_ms: i64 = 0;
const FOLLOW_INTERVAL_MS: i64 = 60 * 60 * 1000;
/// Misses before the operator is asked for alternate titles.
const OPERATOR_AFTER_MISSES: u32 = 3;
/// A picked torrent that is no longer in the session after this long is re-searched.
const DEAD_DOWNLOAD_MS: i64 = 3 * 24 * 60 * 60 * 1000;
/// Set by `checkNow`: search this item on the next tick regardless of its backoff.
var force_id = std.atomic.Value(i64).init(0);

const Pending = struct {
    id: i64 = 0,
    magnet: [2048]u8 = undefined,
    magnet_len: usize = 0,
    name: [256]u8 = undefined,
    name_len: usize = 0,
};
var pending_lock = sync.Mutex{};
var pending: Pending = .{};
var pending_ready = false;

// ── Storage ─────────────────────────────────────────────────────────────

fn ensureTable() bool {
    if (table_ready.load(.acquire)) return true;
    if (db.get() == null) return false;
    db.exec(
        "CREATE TABLE IF NOT EXISTS wanted_items(" ++
            "id INTEGER PRIMARY KEY AUTOINCREMENT," ++
            "kind TEXT NOT NULL," ++
            "title TEXT NOT NULL COLLATE NOCASE," ++
            "year INTEGER NOT NULL DEFAULT 0," ++
            "season INTEGER NOT NULL DEFAULT 0," ++
            "episode INTEGER NOT NULL DEFAULT 0," ++
            "min_quality INTEGER NOT NULL DEFAULT 2," ++
            "prefer_quality INTEGER NOT NULL DEFAULT 3," ++
            "max_quality INTEGER NOT NULL DEFAULT 4," ++
            "status TEXT NOT NULL DEFAULT 'wanted'," ++
            "added_ms INTEGER NOT NULL DEFAULT 0," ++
            "last_check_ms INTEGER NOT NULL DEFAULT 0," ++
            "next_check_ms INTEGER NOT NULL DEFAULT 0," ++
            "attempts INTEGER NOT NULL DEFAULT 0," ++
            "infohash TEXT NOT NULL DEFAULT ''," ++
            "picked TEXT NOT NULL DEFAULT ''," ++
            "extra_titles TEXT NOT NULL DEFAULT ''," ++
            "UNIQUE(kind, title, year, season, episode))",
    );
    // Tables created before alternate titles existed get the column added.
    // Only when the column is missing: an ALTER that fails for another reason (the
    // database busy) must not be mistaken for "already there".
    if (db.prepare("SELECT extra_titles FROM wanted_items LIMIT 0")) |probe| {
        db.finalize(probe);
    } else {
        db.exec("ALTER TABLE wanted_items ADD COLUMN extra_titles TEXT NOT NULL DEFAULT ''");
        if (db.prepare("SELECT extra_titles FROM wanted_items LIMIT 0")) |probe| db.finalize(probe) else return false;
    }
    table_ready.store(true, .release);
    return true;
}

const Item = struct {
    id: i64 = 0,
    kind: pure.Kind = .movie,
    title: [160]u8 = undefined,
    title_len: usize = 0,
    year: u16 = 0,
    season: u16 = 0,
    episode: u16 = 0,
    profile: pure.Profile = .{},
    attempts: u32 = 0,
    /// Alternate titles the operator found, newline separated.
    alts: [480]u8 = undefined,
    alts_len: usize = 0,

    fn target(self: *const Item) pure.Target {
        return .{ .kind = self.kind, .title = self.title[0..self.title_len], .year = self.year, .season = self.season, .episode = self.episode };
    }

    fn targetFor(self: *const Item, title: []const u8) pure.Target {
        var t = self.target();
        t.title = title;
        return t;
    }
};

const select_cols = "id, kind, title, year, season, episode, min_quality, prefer_quality, max_quality, attempts, extra_titles";

fn readItem(stmt: ?*db.Stmt) ?Item {
    var it = Item{};
    it.id = db.columnInt64(stmt, 0);
    it.kind = pure.Kind.parse(db.columnText(stmt, 1) orelse return null) orelse return null;
    const title = db.columnText(stmt, 2) orelse return null;
    it.title_len = @min(title.len, it.title.len);
    @memcpy(it.title[0..it.title_len], title[0..it.title_len]);
    it.year = @intCast(std.math.clamp(db.columnInt(stmt, 3), 0, 9999));
    it.season = @intCast(std.math.clamp(db.columnInt(stmt, 4), 0, 9999));
    it.episode = @intCast(std.math.clamp(db.columnInt(stmt, 5), 0, 9999));
    it.profile.min_quality = @intCast(std.math.clamp(db.columnInt(stmt, 6), 0, pure.Q_MAX));
    it.profile.prefer_quality = @intCast(std.math.clamp(db.columnInt(stmt, 7), 0, pure.Q_MAX));
    it.profile.max_quality = @intCast(std.math.clamp(db.columnInt(stmt, 8), 0, pure.Q_MAX));
    it.attempts = @intCast(@max(0, db.columnInt(stmt, 9)));
    const alts = db.columnText(stmt, 10) orelse "";
    it.alts_len = @min(alts.len, it.alts.len);
    @memcpy(it.alts[0..it.alts_len], alts[0..it.alts_len]);
    return it;
}

// ── Public operations (API / agents) ────────────────────────────────────

pub const AddRequest = struct {
    kind: pure.Kind,
    title: []const u8,
    year: u16 = 0,
    season: u16 = 0,
    episode: u16 = 0,
    min_quality: u8 = 2,
    prefer_quality: u8 = 3,
    max_quality: u8 = 4,
};

pub const AddResult = union(enum) {
    added: i64,
    exists: i64,
    invalid: []const u8,
    full,
    unavailable,
};

pub fn add(req: AddRequest) AddResult {
    const title = std.mem.trim(u8, req.title, " \t\r\n");
    if (title.len == 0 or title.len > 150) return .{ .invalid = "title must be 1-150 characters" };
    for (title) |ch| if (ch < 0x20 or ch == 0x7f) return .{ .invalid = "title has control characters" };
    switch (req.kind) {
        .movie => if (req.year != 0 and (req.year < 1888 or req.year > 2200)) return .{ .invalid = "year is out of range" },
        .episode => if (req.season == 0 or req.episode == 0 or req.season > 999 or req.episode > 9999)
            return .{ .invalid = "episodes need a season and an episode number" },
    }
    const profile = pure.Profile{ .min_quality = req.min_quality, .prefer_quality = req.prefer_quality, .max_quality = req.max_quality };
    if (!profile.valid()) return .{ .invalid = "quality must be 1-4 with min <= prefer <= max" };
    if (!ensureTable()) return .unavailable;

    if (findId(req.kind, title, req.year, req.season, req.episode)) |id| return .{ .exists = id };
    if (countItems() >= MAX_ITEMS) return .full;

    const stmt = db.prepare(
        "INSERT INTO wanted_items(kind,title,year,season,episode,min_quality,prefer_quality,max_quality,added_ms) " ++
            "VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)",
    ) orelse return .unavailable;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, req.kind.id());
    db.bindText(stmt, 2, title);
    db.bindInt(stmt, 3, req.year);
    db.bindInt(stmt, 4, req.season);
    db.bindInt(stmt, 5, req.episode);
    db.bindInt(stmt, 6, req.min_quality);
    db.bindInt(stmt, 7, req.prefer_quality);
    db.bindInt(stmt, 8, req.max_quality);
    db.bindInt64(stmt, 9, io_g.milliTimestamp());
    if (db.step(stmt) != db.c.SQLITE_DONE) return .unavailable;
    const id: i64 = db.c.sqlite3_last_insert_rowid(db.get());
    logs.pushLog("info", "wanted", "Added to the wanted list", false);
    state.wakeUi();
    return .{ .added = id };
}

fn findId(kind: pure.Kind, title: []const u8, year: u16, season: u16, episode: u16) ?i64 {
    const stmt = db.prepare("SELECT id FROM wanted_items WHERE kind=?1 AND title=?2 AND year=?3 AND season=?4 AND episode=?5") orelse return null;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, kind.id());
    db.bindText(stmt, 2, title);
    db.bindInt(stmt, 3, year);
    db.bindInt(stmt, 4, season);
    db.bindInt(stmt, 5, episode);
    if (db.step(stmt) == db.c.SQLITE_ROW) return db.columnInt64(stmt, 0);
    return null;
}

fn countItems() usize {
    const stmt = db.prepare("SELECT COUNT(*) FROM wanted_items") orelse return 0;
    defer db.finalize(stmt);
    if (db.step(stmt) == db.c.SQLITE_ROW) return @intCast(@max(0, db.columnInt(stmt, 0)));
    return 0;
}

/// False when no such item exists.
pub fn remove(id: i64) bool {
    if (!ensureTable()) return false;
    const stmt = db.prepare("DELETE FROM wanted_items WHERE id=?1") orelse return false;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, id);
    if (db.step(stmt) != db.c.SQLITE_DONE) return false;
    return db.c.sqlite3_changes(db.get()) > 0;
}

pub fn pause(id: i64) bool {
    return setStatus(id, .paused, "status IN ('wanted')");
}

/// Resumes a paused item, and also re-arms a stuck 'downloading' one (the user
/// deleted the torrent): it searches again right away.
pub fn resume_(id: i64) bool {
    if (!setStatus(id, .wanted, "status IN ('paused','downloading')")) return false;
    const stmt = db.prepare("UPDATE wanted_items SET attempts=0, next_check_ms=0, infohash='', picked='' WHERE id=?1") orelse return true;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, id);
    _ = db.step(stmt);
    state.wakeUi();
    return true;
}

fn setStatus(id: i64, status: pure.Status, comptime guard: []const u8) bool {
    if (!ensureTable()) return false;
    const stmt = db.prepare("UPDATE wanted_items SET status=?1 WHERE id=?2 AND " ++ guard) orelse return false;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, status.id());
    db.bindInt64(stmt, 2, id);
    if (db.step(stmt) != db.c.SQLITE_DONE) return false;
    return db.c.sqlite3_changes(db.get()) > 0;
}

/// Search this item on the next tick, ignoring its retry backoff. False when
/// the item is missing or not in the `wanted` state.
/// Turn "queue the newest episode of every tracked show" on or off.
pub fn setFollowTv(on: bool) void {
    state.app.wanted_follow_tv = on;
    last_follow_ms = 0;
    state.markConfigDirty();
}

/// Alternate titles for an item (from the background operator): replaced
/// wholesale, and the item is searched again soon with the new wording.
pub fn setExtraTitles(id: i64, titles: []const []const u8) bool {
    if (!ensureTable()) return false;
    var joined: [480]u8 = undefined;
    var n: usize = 0;
    for (titles) |raw| {
        const t = pure.cleanAltTitle(raw) orelse continue;
        if (n + t.len + 1 > joined.len) break;
        if (n > 0) {
            joined[n] = '\n';
            n += 1;
        }
        @memcpy(joined[n .. n + t.len], t);
        n += t.len;
    }
    if (n == 0) return false;
    const stmt = db.prepare("UPDATE wanted_items SET extra_titles=?1, next_check_ms=0 WHERE id=?2 AND status='wanted'") orelse return false;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, joined[0..n]);
    db.bindInt64(stmt, 2, id);
    if (db.step(stmt) != db.c.SQLITE_DONE or db.c.sqlite3_changes(db.get()) == 0) return false;
    last_tick_ms = 0;
    state.wakeUi();
    return true;
}

pub fn checkNow(id: i64) bool {
    if (!ensureTable()) return false;
    const stmt = db.prepare("UPDATE wanted_items SET next_check_ms=0 WHERE id=?1 AND status='wanted'") orelse return false;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, id);
    if (db.step(stmt) != db.c.SQLITE_DONE or db.c.sqlite3_changes(db.get()) == 0) return false;
    force_id.store(id, .release);
    last_tick_ms = 0; // do not wait out the interval
    state.wakeUi();
    return true;
}

/// One row for the UI. Fixed buffers so a snapshot needs no allocation.
pub const Row = struct {
    id: i64 = 0,
    kind: pure.Kind = .movie,
    status: pure.Status = .wanted,
    title: [96]u8 = std.mem.zeroes([96]u8),
    title_len: usize = 0,
    year: u16 = 0,
    season: u16 = 0,
    episode: u16 = 0,
    attempts: u32 = 0,
    next_check_ms: i64 = 0,
    picked: [80]u8 = std.mem.zeroes([80]u8),
    picked_len: usize = 0,
    /// Alternate titles the operator found, newline separated (see setExtraTitles).
    extra_titles: [480]u8 = std.mem.zeroes([480]u8),
    extra_titles_len: usize = 0,
};

pub fn snapshot(out: []Row) usize {
    if (out.len == 0 or !ensureTable()) return 0;
    const stmt = db.prepare("SELECT id, kind, title, year, season, episode, status, attempts, next_check_ms, picked, extra_titles FROM wanted_items ORDER BY id DESC LIMIT ?1") orelse return 0;
    defer db.finalize(stmt);
    db.bindInt(stmt, 1, @intCast(@min(out.len, 200)));
    var n: usize = 0;
    while (n < out.len and db.step(stmt) == db.c.SQLITE_ROW) {
        var r = Row{};
        r.id = db.columnInt64(stmt, 0);
        r.kind = pure.Kind.parse(db.columnText(stmt, 1) orelse "") orelse continue;
        const title = db.columnText(stmt, 2) orelse "";
        r.title_len = @min(title.len, r.title.len);
        @memcpy(r.title[0..r.title_len], title[0..r.title_len]);
        r.year = @intCast(std.math.clamp(db.columnInt(stmt, 3), 0, 9999));
        r.season = @intCast(std.math.clamp(db.columnInt(stmt, 4), 0, 9999));
        r.episode = @intCast(std.math.clamp(db.columnInt(stmt, 5), 0, 9999));
        r.status = pure.Status.parse(db.columnText(stmt, 6) orelse "") orelse .wanted;
        r.attempts = @intCast(@max(0, db.columnInt(stmt, 7)));
        r.next_check_ms = db.columnInt64(stmt, 8);
        const picked = db.columnText(stmt, 9) orelse "";
        r.picked_len = @min(picked.len, r.picked.len);
        @memcpy(r.picked[0..r.picked_len], picked[0..r.picked_len]);
        const extra = db.columnText(stmt, 10) orelse "";
        r.extra_titles_len = @min(extra.len, r.extra_titles.len);
        @memcpy(r.extra_titles[0..r.extra_titles_len], extra[0..r.extra_titles_len]);
        out[n] = r;
        n += 1;
    }
    return n;
}

pub fn isSearching() bool {
    return busy.load(.acquire);
}

/// Write `{"items":[...],"searching":bool,"follow_tv":bool}`.
pub fn writeListJson(w: *std.Io.Writer) !void {
    var s = std.json.Stringify{ .writer = w };
    try s.beginObject();
    try s.objectField("items");
    try s.beginArray();
    if (ensureTable()) {
        const stmt = db.prepare(
            "SELECT id, kind, title, year, season, episode, min_quality, prefer_quality, max_quality, " ++
                "status, added_ms, last_check_ms, next_check_ms, attempts, picked, extra_titles FROM wanted_items ORDER BY id DESC LIMIT 200",
        );
        if (stmt) |st| {
            defer db.finalize(st);
            while (db.step(st) == db.c.SQLITE_ROW) {
                try s.beginObject();
                try s.objectField("id");
                try s.write(db.columnInt64(st, 0));
                try s.objectField("kind");
                try s.write(db.columnText(st, 1) orelse "");
                try s.objectField("title");
                try s.write(db.columnText(st, 2) orelse "");
                try s.objectField("year");
                try s.write(db.columnInt(st, 3));
                try s.objectField("season");
                try s.write(db.columnInt(st, 4));
                try s.objectField("episode");
                try s.write(db.columnInt(st, 5));
                try s.objectField("min_quality");
                try s.write(db.columnInt(st, 6));
                try s.objectField("prefer_quality");
                try s.write(db.columnInt(st, 7));
                try s.objectField("max_quality");
                try s.write(db.columnInt(st, 8));
                try s.objectField("status");
                try s.write(db.columnText(st, 9) orelse "wanted");
                try s.objectField("added_ms");
                try s.write(db.columnInt64(st, 10));
                try s.objectField("last_check_ms");
                try s.write(db.columnInt64(st, 11));
                try s.objectField("next_check_ms");
                try s.write(db.columnInt64(st, 12));
                try s.objectField("attempts");
                try s.write(db.columnInt(st, 13));
                try s.objectField("picked");
                try s.write(db.columnText(st, 14) orelse "");
                try s.objectField("extra_titles");
                try s.write(db.columnText(st, 15) orelse "");
                try s.endObject();
            }
        }
    }
    try s.endArray();
    try s.objectField("searching");
    try s.write(busy.load(.acquire));
    try s.objectField("follow_tv");
    try s.write(state.app.wanted_follow_tv);
    try s.endObject();
}

// ── Automation ──────────────────────────────────────────────────────────

/// Call from the shared frame/headless loop on the owner thread. Self-throttled.
pub fn tick() void {
    applyPending();

    const now = io_g.milliTimestamp();
    if (last_tick_ms != 0 and now - last_tick_ms < TICK_INTERVAL_MS) return;
    last_tick_ms = now;

    if (state.app.incognito_mode or state.torrentSession() == null or !ensureTable()) return;

    reconcileDownloads();
    if (state.app.wanted_follow_tv and now - last_follow_ms >= FOLLOW_INTERVAL_MS) {
        last_follow_ms = now;
        followTrackedShows();
    }

    if (busy.load(.acquire)) return;
    const item = nextDue(now) orelse return;
    if (busy.swap(true, .acq_rel)) return;
    const th = workers.spawnLegacy(searchWorker, .{item}) catch {
        busy.store(false, .release);
        return;
    };
    workers.release(th);
}

/// Queue the newest aired episode of every tracked show, once. Only the newest:
/// enabling this must not drag in a show's whole back catalogue. A marker table
/// remembers what was queued, so removing an item from the list stays removed,
/// and anything the user already watched (or watched past) is skipped.
fn followTrackedShows() void {
    const shows = alloc.alloc(db.TvShowRow, 64) catch return;
    defer alloc.free(shows);
    const n = db.tvGetShows(shows);
    db.exec("CREATE TABLE IF NOT EXISTS wanted_followed (tmdb_id INTEGER NOT NULL, season INTEGER NOT NULL, episode INTEGER NOT NULL, PRIMARY KEY (tmdb_id, season, episode))");
    for (shows[0..n]) |*show| {
        const s = show.last_aired.season;
        const e = show.last_aired.episode;
        if (s <= 0 or e <= 0 or show.name_len == 0) continue;
        if (alreadyFollowedOrWatched(show.tmdb_id, s, e)) continue;
        const res = add(.{ .kind = .episode, .title = show.name[0..show.name_len], .season = @intCast(s), .episode = @intCast(e) });
        switch (res) {
            .added, .exists => markFollowed(show.tmdb_id, s, e),
            .full, .unavailable => return,
            .invalid => markFollowed(show.tmdb_id, s, e),
        }
    }
}

fn alreadyFollowedOrWatched(tmdb_id: i32, season: i32, episode: i32) bool {
    const f = db.prepare("SELECT 1 FROM wanted_followed WHERE tmdb_id=?1 AND season=?2 AND episode=?3") orelse return true;
    defer db.finalize(f);
    db.bindInt(f, 1, tmdb_id);
    db.bindInt(f, 2, season);
    db.bindInt(f, 3, episode);
    if (db.step(f) == db.c.SQLITE_ROW) return true;
    const w = db.prepare("SELECT 1 FROM tv_watched WHERE tmdb_id=?1 AND watched=1 AND (season>?2 OR (season=?2 AND episode>=?3)) LIMIT 1") orelse return true;
    defer db.finalize(w);
    db.bindInt(w, 1, tmdb_id);
    db.bindInt(w, 2, season);
    db.bindInt(w, 3, episode);
    return db.step(w) == db.c.SQLITE_ROW;
}

fn markFollowed(tmdb_id: i32, season: i32, episode: i32) void {
    const stmt = db.prepare("INSERT OR IGNORE INTO wanted_followed(tmdb_id,season,episode) VALUES(?1,?2,?3)") orelse return;
    defer db.finalize(stmt);
    db.bindInt(stmt, 1, tmdb_id);
    db.bindInt(stmt, 2, season);
    db.bindInt(stmt, 3, episode);
    _ = db.step(stmt);
}

fn nextDue(now: i64) ?Item {
    const forced = force_id.swap(0, .acq_rel);
    if (forced != 0) {
        const stmt = db.prepare("SELECT " ++ select_cols ++ " FROM wanted_items WHERE id=?1 AND status='wanted'") orelse return null;
        defer db.finalize(stmt);
        db.bindInt64(stmt, 1, forced);
        if (db.step(stmt) == db.c.SQLITE_ROW) return readItem(stmt);
    }
    const stmt = db.prepare("SELECT " ++ select_cols ++ " FROM wanted_items WHERE status='wanted' AND next_check_ms<=?1 ORDER BY next_check_ms ASC LIMIT 1") orelse return null;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, now);
    if (db.step(stmt) == db.c.SQLITE_ROW) return readItem(stmt);
    return null;
}

fn recordMiss(item: Item, now: i64) void {
    const stmt = db.prepare("UPDATE wanted_items SET attempts=attempts+1, last_check_ms=?1, next_check_ms=?2 WHERE id=?3") orelse return;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, now);
    db.bindInt64(stmt, 2, now + pure.retryDelayMs(item.attempts));
    db.bindInt64(stmt, 3, item.id);
    _ = db.step(stmt);
}

fn searchWorker(item: Item) void {
    defer busy.store(false, .release);
    const now = io_g.milliTimestamp();

    // Heap, never the worker's stack: ResolvedItem is several KB and the sink
    // holds MAX_RESULTS of them.
    const rows = alloc.alloc(resolver.ResolvedItem, resolver.MAX_RESULTS) catch {
        recordMiss(item, now);
        return;
    };
    defer alloc.free(rows);

    // The wanted title first, then each alternate title the operator found; stop at
    // the first one that yields an acceptable release.
    var searched: usize = 0;
    var total_candidates: usize = 0;
    var titles = std.mem.splitScalar(u8, item.alts[0..item.alts_len], '\n');
    var primary_done = false;
    while (true) {
        const title: []const u8 = if (!primary_done) blk: {
            primary_done = true;
            break :blk item.title[0..item.title_len];
        } else titles.next() orelse break;
        if (title.len == 0) continue;
        const target = item.targetFor(title);

        var qbuf: [256]u8 = undefined;
        const query = pure.searchQuery(&qbuf, target) orelse continue;
        const n = resolver.searchTorrentsPrivate(query, rows);
        if (workers.isQuitting()) return;
        searched += 1;
        total_candidates += n;

        const cands = alloc.alloc(pure.Candidate, n) catch continue;
        defer alloc.free(cands);
        for (rows[0..n], 0..) |*r, i| {
            const name = r.name[0..r.name_len];
            cands[i] = .{
                .name = name,
                .quality = r.quality,
                .seeds = r.seeds,
                .size_bytes = r.size_bytes,
                .is_magnet = r.source == .torrent and std.ascii.startsWithIgnoreCase(r.url[0..r.url_len], "magnet:?"),
                .blocked = risk.assess(name, @floatFromInt(r.size_bytes)).risk == .block,
            };
        }
        const pick = pure.pickBest(item.profile, target, cands) orelse continue;

        pending_lock.lock();
        defer pending_lock.unlock();
        if (pending_ready) return; // owner thread has not consumed the last pick yet; retry next time
        const r = &rows[pick];
        pending.id = item.id;
        pending.magnet_len = @min(r.url_len, pending.magnet.len - 1);
        @memcpy(pending.magnet[0..pending.magnet_len], r.url[0..pending.magnet_len]);
        pending.magnet[pending.magnet_len] = 0;
        pending.name_len = @min(r.name_len, pending.name.len);
        @memcpy(pending.name[0..pending.name_len], r.name[0..pending.name_len]);
        pending_ready = true;
        state.wakeUi();
        return;
    }

    recordMiss(item, now);
    var lb: [160]u8 = undefined;
    logs.pushLog("info", "wanted", std.fmt.bufPrint(&lb, "No release yet for \"{s}\" ({d} candidates over {d} searches)", .{ item.title[0..item.title_len], total_candidates, searched }) catch "No release yet", false);
    askOperator(item);
}

/// After repeated misses, and only once, ask the background operator for other
/// ways the title is named. The operator checks its own switch, cooldown and budget.
fn askOperator(item: Item) void {
    if (item.attempts + 1 < OPERATOR_AFTER_MISSES or item.alts_len > 0) return;
    var key: [24]u8 = undefined;
    const k = std.fmt.bufPrint(&key, "{d}", .{item.id}) catch return;
    var ctx: [512]u8 = undefined;
    const text = switch (item.kind) {
        .movie => std.fmt.bufPrint(&ctx, "Kind: movie\nTitle: {s}\nYear: {d}\nSearches without an acceptable release: {d}", .{ item.title[0..item.title_len], item.year, item.attempts + 1 }),
        .episode => std.fmt.bufPrint(&ctx, "Kind: TV episode\nShow: {s}\nSeason {d}, episode {d}\nSearches without an acceptable release: {d}", .{ item.title[0..item.title_len], item.season, item.episode, item.attempts + 1 }),
    } catch return;
    _ = @import("operator.zig").request(.match_help, k, text);
}

/// Owner thread: start the chosen torrent and record it.
fn applyPending() void {
    var job: Pending = undefined;
    {
        pending_lock.lock();
        defer pending_lock.unlock();
        if (!pending_ready) return;
        job = pending;
        pending_ready = false;
    }
    if (!ensureTable()) return;
    const ses = state.torrentSession();
    if (ses == null) return;

    // The item may have been removed or paused while the search ran.
    var still_wanted = false;
    {
        const stmt = db.prepare("SELECT 1 FROM wanted_items WHERE id=?1 AND status='wanted'") orelse return;
        defer db.finalize(stmt);
        db.bindInt64(stmt, 1, job.id);
        still_wanted = db.step(stmt) == db.c.SQLITE_ROW;
    }
    if (!still_wanted) return;

    const tid = c.mpv.torrent_add_magnet(ses, @ptrCast(&job.magnet[0]), state.getSavePath());
    const now = io_g.milliTimestamp();
    if (tid < 0) {
        // Duplicate, bad magnet, or no session: back off like a miss.
        const stmt = db.prepare("UPDATE wanted_items SET attempts=attempts+1, last_check_ms=?1, next_check_ms=?2 WHERE id=?3") orelse return;
        defer db.finalize(stmt);
        db.bindInt64(stmt, 1, now);
        db.bindInt64(stmt, 2, now + pure.retryDelayMs(1));
        db.bindInt64(stmt, 3, job.id);
        _ = db.step(stmt);
        logs.pushLog("warn", "wanted", "Could not start the chosen release", false);
        return;
    }
    intents.rememberTorrent(tid);

    var hash_buf: [96]u8 = std.mem.zeroes([96]u8);
    _ = c.mpv.torrent_get_infohash(ses, tid, &hash_buf, hash_buf.len);
    const hash_len = std.mem.indexOfScalar(u8, &hash_buf, 0) orelse hash_buf.len;

    const stmt = db.prepare("UPDATE wanted_items SET status='downloading', infohash=?1, picked=?2, last_check_ms=?3 WHERE id=?4") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, hash_buf[0..hash_len]);
    db.bindText(stmt, 2, job.name[0..job.name_len]);
    db.bindInt64(stmt, 3, now);
    db.bindInt64(stmt, 4, job.id);
    _ = db.step(stmt);

    var tb: [300]u8 = undefined;
    const msg = std.fmt.bufPrint(&tb, "Wanted: downloading {s}", .{job.name[0..job.name_len]}) catch "Wanted: download started";
    logs.pushLog("info", "wanted", msg, false);
    state.showToast(msg);
}

/// Mark `downloading` items fulfilled once libtorrent reports them complete.
fn reconcileDownloads() void {
    const ses = state.torrentSession();
    if (ses == null) return;

    const DlRow = struct { id: i64, hash: [96]u8, len: usize, picked_ms: i64 = 0, seen: bool = false };
    var rows: [64]DlRow = undefined;
    var n: usize = 0;
    {
        const stmt = db.prepare("SELECT id, infohash, last_check_ms FROM wanted_items WHERE status='downloading' AND infohash<>'' ORDER BY id LIMIT 64") orelse return;
        defer db.finalize(stmt);
        while (n < rows.len and db.step(stmt) == db.c.SQLITE_ROW) {
            const h = db.columnText(stmt, 1) orelse continue;
            rows[n].id = db.columnInt64(stmt, 0);
            rows[n].picked_ms = db.columnInt64(stmt, 2);
            rows[n].seen = false;
            rows[n].len = @min(h.len, rows[n].hash.len);
            @memcpy(rows[n].hash[0..rows[n].len], h[0..rows[n].len]);
            n += 1;
        }
    }
    if (n == 0) return;

    const count = c.mpv.torrent_count(ses);
    var id: c_int = 0;
    while (id < count) : (id += 1) {
        if (c.mpv.torrent_is_alive(ses, id) == 0) continue;
        var hb: [96]u8 = std.mem.zeroes([96]u8);
        _ = c.mpv.torrent_get_infohash(ses, id, &hb, hb.len);
        const hl = std.mem.indexOfScalar(u8, &hb, 0) orelse hb.len;
        for (rows[0..n]) |*row| {
            if (!std.ascii.eqlIgnoreCase(hb[0..hl], row.hash[0..row.len])) continue;
            row.seen = true;
            var progress: f32 = 0;
            var rate: c_int = 0;
            var seeds: c_int = 0;
            _ = c.mpv.torrent_poll(ses, id, -1, null, 0, &progress, &rate, &seeds);
            if (std.math.isFinite(progress) and progress >= 0.999) {
                const stmt = db.prepare("UPDATE wanted_items SET status='fulfilled' WHERE id=?1 AND status='downloading'") orelse continue;
                defer db.finalize(stmt);
                db.bindInt64(stmt, 1, row.id);
                _ = db.step(stmt);
                logs.pushLog("info", "wanted", "Wanted item finished downloading", false);
                state.showToast("Wanted: download finished");
            }
        }
    }

    // A torrent that vanished (deleted by the user, lost across a restart) would
    // leave its item "downloading" forever. After a grace period, search again.
    const now = io_g.milliTimestamp();
    for (rows[0..n]) |row| {
        if (row.seen or now - row.picked_ms < DEAD_DOWNLOAD_MS) continue;
        const stmt = db.prepare("UPDATE wanted_items SET status='wanted', attempts=0, next_check_ms=0, infohash='', picked='' WHERE id=?1 AND status='downloading'") orelse continue;
        defer db.finalize(stmt);
        db.bindInt64(stmt, 1, row.id);
        _ = db.step(stmt);
        logs.pushLog("info", "wanted", "A wanted download disappeared; searching again", false);
    }
}
