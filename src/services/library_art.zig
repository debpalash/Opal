//! Background artwork for library rows that have none.
//!
//! A file, magnet or link played outside the catalog lands in `library_items`
//! (kind "watch") with no poster and the raw release name. This worker parses
//! the name (`release_name_pure`), looks the clean title up in keyless Cinemeta
//! — the catalog the app already uses without a TMDB key — and writes poster,
//! canonical title and "S2 E4" back through `library_store.applyArtwork`
//! (which bumps the rail version, so Home repaints).
//!
//! Privacy: only the parsed title goes out, only for names that look like a
//! release (`release_name_pure.lookupAllowed`); never a path or a file name.
//! A playback that came from the catalog resolves through its remembered IMDb
//! id instead of a title search.
//!
//! Cost: one worker at a time, a bounded batch per run, results (including
//! misses) cached in `library_art_cache` keyed by kind|title|year — every
//! episode of a show shares one lookup — and rows are marked tried in
//! `library_art_tried` so a miss is not refetched for `RETRY_AFTER_S`. A
//! network failure backs off for ten minutes and marks nothing.

const std = @import("std");
const db = @import("../core/db.zig");
const alloc = @import("../core/alloc.zig").allocator;
const io_g = @import("../core/io_global.zig");
const workers = @import("../core/workers.zig");
const state = @import("../core/state.zig");
const http = @import("../core/http.zig");
const pure = @import("release_name_pure.zig");
const picks = @import("operator_picks_pure.zig");
const store = @import("library_store.zig");
const tmdb_api = @import("tmdb_api.zig");

const ROWS_PER_RUN = 24;
const LOOKUPS_PER_RUN = 12;
const FAIL_BACKOFF_MS: i64 = 10 * 60 * 1000;

var busy = std.atomic.Value(bool).init(false);
var rerun = std.atomic.Value(bool).init(false);
var backoff_until_ms = std.atomic.Value(i64).init(0);
var last_item_hash = std.atomic.Value(u64).init(0);
var tables_ready = std.atomic.Value(bool).init(false);

fn ensureTables() bool {
    if (tables_ready.load(.acquire)) return true;
    if (db.get() == null) return false;
    db.exec("CREATE TABLE IF NOT EXISTS library_art_cache(" ++
        "query TEXT PRIMARY KEY, imdb TEXT NOT NULL DEFAULT '', title TEXT NOT NULL DEFAULT '', " ++
        "poster TEXT NOT NULL DEFAULT '', checked_at INTEGER NOT NULL DEFAULT 0)");
    db.exec("CREATE TABLE IF NOT EXISTS library_art_tried(" ++
        "kind TEXT NOT NULL, item_id TEXT NOT NULL, checked_at INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(kind,item_id))");
    tables_ready.store(true, .release);
    return true;
}

/// Start a run unless one is going (then it runs once more) or the last run
/// could not reach the catalog recently. Cheap; safe from any thread.
pub fn kick() void {
    if (state.app.incognito_mode or workers.isQuitting()) return;
    if (io_g.milliTimestamp() < backoff_until_ms.load(.acquire)) return;
    if (busy.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
        rerun.store(true, .release);
        return;
    }
    workers.spawn(run, .{}) catch busy.store(false, .release);
}

/// Called on every progress save; kicks once per newly played item.
pub fn noteItem(item_id: []const u8) void {
    const h = std.hash.Wyhash.hash(0, item_id);
    if (last_item_hash.swap(h, .acq_rel) == h) return;
    kick();
}

fn run() void {
    defer busy.store(false, .release);
    while (!workers.isQuitting()) {
        rerun.store(false, .release);
        if (!processBatch()) return;
        if (!rerun.load(.acquire)) return;
    }
}

const Row = struct {
    kind: [16]u8 = undefined,
    kind_len: usize = 0,
    item_id: [1024]u8 = undefined,
    item_id_len: usize = 0,
    title: [256]u8 = undefined,
    title_len: usize = 0,

    fn kindText(self: *const Row) []const u8 {
        return self.kind[0..self.kind_len];
    }
    fn idText(self: *const Row) []const u8 {
        return self.item_id[0..self.item_id_len];
    }
    fn titleText(self: *const Row) []const u8 {
        return self.title[0..self.title_len];
    }
};

/// What the lookup produced for one title.
const Art = struct {
    title: [128]u8 = undefined,
    title_len: usize = 0,
    poster: [256]u8 = undefined,
    poster_len: usize = 0,

    fn set(self: *Art, title: []const u8, poster: []const u8) void {
        self.title_len = @min(title.len, self.title.len);
        @memcpy(self.title[0..self.title_len], title[0..self.title_len]);
        self.poster_len = @min(poster.len, self.poster.len);
        @memcpy(self.poster[0..self.poster_len], poster[0..self.poster_len]);
    }
};

const Outcome = enum { matched, none, unreachable_, deferred };

const Ctx = struct {
    cands: []picks.Candidate,
    lookups: usize = 0,
    now_s: i64,
};

/// False when the catalog was unreachable (backoff armed) or nothing could run.
fn processBatch() bool {
    if (!ensureTables()) return false;
    const now_s = io_g.timestamp();
    const rows = alloc.alloc(Row, ROWS_PER_RUN) catch return false;
    defer alloc.free(rows);
    const cands = alloc.alloc(picks.Candidate, picks.MAX_CANDIDATES) catch return false;
    defer alloc.free(cands);
    const n = loadMissing(now_s - pure.RETRY_AFTER_S, rows);
    var ctx = Ctx{ .cands = cands, .now_s = now_s };
    var matched: usize = 0;
    for (rows[0..n]) |*row| {
        if (workers.isQuitting()) return false;
        var art = Art{};
        var label_buf: [24]u8 = undefined;
        var label: []const u8 = "";
        var clean: []const u8 = "";
        var parsed: pure.Parsed = .{};
        const outcome = resolveRow(row, &ctx, &art, &parsed);
        if (std.mem.eql(u8, row.kindText(), "watch")) {
            label = pure.episodeLabel(&parsed, &label_buf);
            clean = parsed.titleText();
        }
        switch (outcome) {
            .unreachable_ => {
                backoff_until_ms.store(io_g.milliTimestamp() + FAIL_BACKOFF_MS, .release);
                return false;
            },
            .deferred => continue,
            .matched => {
                if (store.applyArtwork(row.kindText(), row.idText(), art.title[0..art.title_len], art.poster[0..art.poster_len], label)) matched += 1;
            },
            .none => if (clean.len > 0) store.applyDisplay(row.kindText(), row.idText(), clean, label),
        }
        markTried(row, now_s);
    }
    if (matched > 0) {
        var msg: [96]u8 = undefined;
        const text = std.fmt.bufPrint(&msg, "Found artwork for {d} library item(s)", .{matched}) catch "";
        @import("../core/logs.zig").pushLog("info", "Library", text, false);
        state.wakeUi();
    }
    return true;
}

fn loadMissing(retry_before: i64, out: []Row) usize {
    const stmt = db.prepare(
        "SELECT l.kind, l.item_id, l.title FROM library_items l " ++
            "LEFT JOIN library_art_tried t ON t.kind=l.kind AND t.item_id=l.item_id " ++
            "WHERE l.kind IN ('watch','movie','tv') AND l.poster='' AND l.deleted=0 " ++
            "AND (t.checked_at IS NULL OR t.checked_at < ?1) ORDER BY l.updated_at DESC LIMIT ?2",
    ) orelse return 0;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, retry_before);
    db.bindInt64(stmt, 2, @intCast(out.len));
    var n: usize = 0;
    while (n < out.len and db.step(stmt) == db.c.SQLITE_ROW) {
        const r = &out[n];
        r.* = .{};
        db.copyColumn(stmt, 0, r.kind[0..], &r.kind_len);
        db.copyColumn(stmt, 1, r.item_id[0..], &r.item_id_len);
        db.copyColumn(stmt, 2, r.title[0..], &r.title_len);
        // A truncated identity would never match its row again.
        if (r.kind_len == 0 or r.item_id_len == 0 or r.item_id_len >= r.item_id.len - 1) continue; // copyColumn caps at len-1
        n += 1;
    }
    return n;
}

fn markTried(row: *const Row, now_s: i64) void {
    const stmt = db.prepare("INSERT INTO library_art_tried(kind,item_id,checked_at) VALUES(?1,?2,?3) " ++
        "ON CONFLICT(kind,item_id) DO UPDATE SET checked_at=excluded.checked_at") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, row.kindText());
    db.bindText(stmt, 2, row.idText());
    db.bindInt64(stmt, 3, now_s);
    _ = db.step(stmt);
}

fn resolveRow(row: *const Row, ctx: *Ctx, art: *Art, parsed: *pure.Parsed) Outcome {
    const kind = row.kindText();
    if (std.mem.eql(u8, kind, "watch")) {
        parsed.* = pure.parseBest(row.titleText(), row.idText());
        // Catalog playback: the remembered IMDb id beats any parse.
        if (resolveCatalog(row.idText(), art)) return .matched;
        if (!pure.lookupAllowed(parsed)) return .none;
        const first = parsed.media();
        const r = lookup(ctx, first, parsed.titleText(), parsed.year, art);
        // A movie-looking name may be a season pack without an episode marker.
        if (r == .none and first == .movie) return lookup(ctx, .tv, parsed.titleText(), parsed.year, art);
        return r;
    }
    // "movie"/"tv" rows already carry a catalog title (web UI / synced rows).
    const title = row.titleText();
    if (!pure.titleLooksPublic(title)) return .none;
    return lookup(ctx, if (std.mem.eql(u8, kind, "tv")) .tv else .movie, title, 0, art);
}

/// A playback started from a catalog movie page remembers its catalog id in
/// watch_history; with an IMDb id known locally, read Cinemeta's own record.
fn resolveCatalog(item_id: []const u8, art: *Art) bool {
    const id = catalogId(item_id);
    if (id <= 0) return false;
    var imdb_buf: [16]u8 = undefined;
    var imdb = tmdb_api.knownImdb(.movie, id, &imdb_buf);
    if (imdb.len == 0) imdb = db.movieImdbId(id, &imdb_buf);
    if (imdb.len == 0) return false;
    const body = tmdb_api.cinemetaMetaOwned(.movie, imdb) orelse return false;
    defer alloc.free(body);
    const c = pure.parseMetaCandidate(alloc, body, .movie) orelse return false;
    if (c.poster_len == 0) return false;
    art.set(c.titleText(), c.poster[0..c.poster_len]);
    return true;
}

fn catalogId(item_id: []const u8) i32 {
    const stmt = db.prepare("SELECT catalog_tmdb_id FROM watch_history WHERE (file_key=?1 OR link=?1 OR name=?1) AND catalog_tmdb_id>0 LIMIT 1") orelse return 0;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, item_id);
    if (db.step(stmt) != db.c.SQLITE_ROW) return 0;
    return db.columnInt(stmt, 0);
}

/// Cache first; otherwise one Cinemeta search (counted against the run's budget).
fn lookup(ctx: *Ctx, media: pure.Media, title: []const u8, year: u16, art: *Art) Outcome {
    var key_buf: [192]u8 = undefined;
    const key = pure.cacheKey(media, title, year, &key_buf);
    if (key.len == 0) return .none;
    switch (cached(key, ctx.now_s, art)) {
        .hit => return .matched,
        .miss => return .none,
        .unknown => {},
    }
    if (ctx.lookups >= LOOKUPS_PER_RUN) return .deferred;
    ctx.lookups += 1;

    var enc_buf: [400]u8 = undefined;
    const q = http.urlEncode(title, &enc_buf);
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/catalog/{s}/top/search={s}.json", .{ media.catalogType(), q }) catch return .none;
    const body = tmdb_api.cinemetaApiOwned(path, 1024 * 1024) orelse return .unreachable_;
    defer alloc.free(body);
    const n = picks.parseCandidates(alloc, body, media, ctx.cands);
    const hit = pure.pickMatch(title, year, media, ctx.cands[0..n]);
    if (hit) |i| {
        const c = &ctx.cands[i];
        if (c.poster_len > 0) {
            art.set(c.titleText(), c.poster[0..c.poster_len]);
            remember(key, c.imdbText(), c.titleText(), c.poster[0..c.poster_len], ctx.now_s);
            return .matched;
        }
    }
    remember(key, "", "", "", ctx.now_s);
    return .none;
}

const CacheState = enum { hit, miss, unknown };

fn cached(key: []const u8, now_s: i64, art: *Art) CacheState {
    const stmt = db.prepare("SELECT imdb, title, poster, checked_at FROM library_art_cache WHERE query=?1") orelse return .unknown;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, key);
    if (db.step(stmt) != db.c.SQLITE_ROW) return .unknown;
    const poster = db.columnText(stmt, 2) orelse "";
    if (poster.len > 0) {
        art.set(db.columnText(stmt, 1) orelse "", poster);
        return .hit;
    }
    // Misses expire so a title Cinemeta adds later is found eventually.
    return if (now_s - db.columnInt64(stmt, 3) < pure.RETRY_AFTER_S) .miss else .unknown;
}

fn remember(key: []const u8, imdb: []const u8, title: []const u8, poster: []const u8, now_s: i64) void {
    const stmt = db.prepare("INSERT INTO library_art_cache(query,imdb,title,poster,checked_at) VALUES(?1,?2,?3,?4,?5) " ++
        "ON CONFLICT(query) DO UPDATE SET imdb=excluded.imdb, title=excluded.title, poster=excluded.poster, checked_at=excluded.checked_at") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, key);
    db.bindText(stmt, 2, imdb);
    db.bindText(stmt, 3, title);
    db.bindText(stmt, 4, poster);
    db.bindInt64(stmt, 5, now_s);
    _ = db.step(stmt);
}
