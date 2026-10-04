//! picks: the Home rail "Picked for you". Once a day, when the operator is on, the
//! user switched on "Use my watch history for picks" and Home is open, a compact
//! list of titles (what they watched, favourited and follow; never file paths) goes
//! to the agent, which recommends up to 12 titles. The app never trusts one: each is
//! looked up in Cinemeta (keyless) and kept only when it resolves to a real
//! catalogue entry with the same title, kind and a year within one. Titles the user
//! already has are dropped. What survives is stored with the one-line reason and
//! shown with the normal catalogue card, a Details button and a Dismiss button.
//!
//! Rules and parsing are in `operator_picks_pure.zig` (unit tested with Cinemeta
//! fixtures); this file reads the user's tables, does the lookups and keeps the rail.

const std = @import("std");
const db = @import("../core/db.zig");
const state = @import("../core/state.zig");
const io_g = @import("../core/io_global.zig");
const http = @import("../core/http.zig");
const workers = @import("../core/workers.zig");
const display_name = @import("../core/display_name_pure.zig");
const poster = @import("../core/poster.zig");
const alloc = @import("../core/alloc.zig").allocator;
const op = @import("operator_pure.zig");
const pure = @import("operator_picks_pure.zig");
const cinemeta = @import("cinemeta_pure.zig");
const operator = @import("operator.zig");
const tmdb_api = @import("tmdb_api.zig");

pub const MAX_PICKS = pure.MAX_PICKS;
pub const REASON_MAX = pure.REASON_MAX;
/// One request per day: the cooldown key is the same every time.
const DAILY_KEY = "daily";
const CHECK_EVERY_MS: i64 = 10 * 60 * 1000;
const KEEP_DISMISSED = 200;

var table_ready = std.atomic.Value(bool).init(false);

fn ensureTable() bool {
    if (table_ready.load(.acquire)) return true;
    if (db.get() == null) return false;
    db.exec(
        "CREATE TABLE IF NOT EXISTS operator_picks(" ++
            "imdb TEXT PRIMARY KEY," ++
            "kind TEXT NOT NULL," ++
            "title TEXT NOT NULL," ++
            "year INTEGER NOT NULL DEFAULT 0," ++
            "poster TEXT NOT NULL DEFAULT ''," ++
            "rating REAL NOT NULL DEFAULT 0," ++
            "overview TEXT NOT NULL DEFAULT ''," ++
            "reason TEXT NOT NULL DEFAULT ''," ++
            "created_ms INTEGER NOT NULL DEFAULT 0," ++
            "dismissed INTEGER NOT NULL DEFAULT 0)",
    );
    table_ready.store(true, .release);
    return true;
}

pub fn enabled() bool {
    return state.app.operator_enabled and state.app.operator_picks_enabled and !state.app.incognito_mode;
}

// ── Taste ───────────────────────────────────────────────────────────────

/// Read one column of titles with `sql` (no binds) into `taste` until `want` were added.
fn addColumn(taste: *pure.Taste, source: pure.Source, sql: [:0]const u8, want: usize) void {
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);
    var added: usize = 0;
    while (added < want and db.step(stmt) == db.c.SQLITE_ROW) {
        const raw = db.columnText(stmt, 0) orelse continue;
        if (pure.rawLooksLikeLink(raw)) continue;
        var clean_buf: [256]u8 = undefined;
        const cleaned = display_name.clean(&clean_buf, raw[0..@min(raw.len, 255)]);
        if (taste.add(source, cleaned)) added += 1;
    }
}

/// Titles only, never a path, link or hash: file-like names go through the app's
/// cleaner and are dropped when they still look like release names.
fn gatherTaste(taste: *pure.Taste) void {
    addColumn(taste, .watched, "SELECT name FROM watch_history ORDER BY updated_at DESC LIMIT 80", 20);
    addColumn(taste, .favourite, "SELECT title FROM library_items WHERE is_favorite=1 AND COALESCE(title,'')<>'' AND kind NOT IN ('iptv','radio','podcast','audiobook') ORDER BY updated_at DESC LIMIT 40", 10);
    addColumn(taste, .favourite, "SELECT i.title FROM tmdb_lists l JOIN tmdb_items i ON i.id=l.item_id WHERE l.list_name='fav' ORDER BY l.added_at DESC LIMIT 40", 10);
    addColumn(taste, .following, "SELECT name FROM tv_shows WHERE tracked=1 AND COALESCE(name,'')<>'' ORDER BY updated_at DESC LIMIT 30", 10);
}

// ── Trigger ─────────────────────────────────────────────────────────────

var last_check_ms: i64 = 0;

/// Called every frame Home is drawn. Returns at once unless the operator and the
/// picks switch are both on; otherwise looks at most every ten minutes, and the
/// operator's own cooldown keeps it to one job a day.
pub fn onHomeOpened() void {
    if (!enabled()) return;
    const now = io_g.milliTimestamp();
    if (last_check_ms != 0 and now - last_check_ms < CHECK_EVERY_MS) return;
    last_check_ms = now;
    if (!ensureTable()) return;
    var taste = pure.Taste{};
    gatherTaste(&taste);
    if (!taste.enough()) return;
    _ = operator.request(.picks, DAILY_KEY, taste.text());
}

// ── Handler ─────────────────────────────────────────────────────────────

var revision = std.atomic.Value(u32).init(1);

/// Null when the catalogue could not be reached (as opposed to "no such title").
fn searchCandidates(kind: pure.Media, title: []const u8, out: []pure.Candidate) ?usize {
    var enc_buf: [400]u8 = undefined;
    const enc = http.urlEncode(title, &enc_buf);
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/catalog/{s}/top/search={s}.json", .{ kind.catalogType(), enc }) catch return 0;
    const body = tmdb_api.cinemetaApiOwned(path, 1024 * 1024) orelse return null;
    defer alloc.free(body);
    return pure.parseCandidates(alloc, body, kind, out);
}

fn store(c: *const pure.Candidate, reason: []const u8, batch_ms: i64) bool {
    const stmt = db.prepare(
        "INSERT INTO operator_picks(imdb,kind,title,year,poster,rating,overview,reason,created_ms,dismissed) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,0) " ++
            "ON CONFLICT(imdb) DO UPDATE SET reason=excluded.reason, created_ms=excluded.created_ms WHERE dismissed=0",
    ) orelse return false;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, c.imdbText());
    db.bindText(stmt, 2, c.kind.id());
    db.bindText(stmt, 3, c.titleText());
    db.bindInt(stmt, 4, c.year);
    db.bindText(stmt, 5, c.poster[0..c.poster_len]);
    db.bindDouble(stmt, 6, c.rating);
    db.bindText(stmt, 7, c.overview[0..c.overview_len]);
    db.bindText(stmt, 8, reason);
    db.bindInt64(stmt, 9, batch_ms);
    if (db.step(stmt) != db.c.SQLITE_DONE) return false;
    // A title the user already dismissed is left alone and does not count.
    return db.c.sqlite3_changes(db.get()) > 0;
}

/// Validate, resolve against the catalogue and store. `key` is unused (one job a day).
pub fn handle(key: []const u8, result_json: []const u8) op.Handled {
    _ = key;
    if (!enabled()) return op.Handled.make(.failed, "Picks were switched off before the answer arrived", .{});
    if (!ensureTable()) return op.Handled.make(.failed, "Picks are not available", .{});
    const picks = pure.parsePicks(alloc, result_json) orelse return op.Handled.make(.failed, "No usable recommendations", .{});

    var taste = pure.Taste{};
    gatherTaste(&taste);

    const rows = alloc.alloc(pure.Candidate, pure.MAX_CANDIDATES) catch return op.Handled.make(.failed, "Out of memory", .{});
    defer alloc.free(rows);

    const batch_ms = io_g.milliTimestamp();
    var kept: usize = 0;
    var unresolved: usize = 0;
    var known: usize = 0;
    // A lookup that could not reach the catalogue (a network blip, not "no such
    // title") gets one more try after the others, instead of silently losing a pick.
    var retry: [MAX_PICKS]bool = [_]bool{false} ** MAX_PICKS;
    var pass: usize = 0;
    while (pass < 2) : (pass += 1) {
        if (pass == 1) {
            var any = false;
            for (retry) |r| any = any or r;
            if (!any) break;
            io_g.sleep(3 * std.time.ns_per_s);
        }
        for (picks.items[0..picks.count], 0..) |*pick, pi| {
            if (workers.isQuitting()) break;
            if (pass == 1 and !retry[pi]) continue;
            retry[pi] = false;
            if (taste.known.contains(pick.titleText())) {
                known += 1;
                continue;
            }
            const n = searchCandidates(pick.kind, pick.titleText(), rows) orelse {
                if (pass == 0) retry[pi] = true else unresolved += 1;
                continue;
            };
            const idx = pure.resolve(pick, rows[0..n]) orelse {
                unresolved += 1;
                continue;
            };
            const c = &rows[idx];
            if (taste.known.contains(c.titleText())) {
                known += 1;
                continue;
            }
            if (store(c, pick.reasonText(), batch_ms)) kept += 1;
        }
    }
    if (kept == 0) return op.Handled.make(.failed, "None of {d} recommendations matched a real title ({d} already known)", .{ picks.count, known });

    // The newest batch replaces the previous one; dismissed titles stay dismissed.
    if (db.prepare("DELETE FROM operator_picks WHERE dismissed=0 AND created_ms<?1")) |stmt| {
        defer db.finalize(stmt);
        db.bindInt64(stmt, 1, batch_ms);
        _ = db.step(stmt);
    }
    if (db.prepare("DELETE FROM operator_picks WHERE dismissed=1 AND imdb NOT IN (SELECT imdb FROM operator_picks WHERE dismissed=1 ORDER BY created_ms DESC LIMIT ?1)")) |stmt| {
        defer db.finalize(stmt);
        db.bindInt(stmt, 1, KEEP_DISMISSED);
        _ = db.step(stmt);
    }
    _ = revision.fetchAdd(1, .acq_rel);
    state.wakeUi();
    return op.Handled.make(.applied, "Picked {d} title{s} for you ({d} dropped: not in the catalogue)", .{ kept, if (kept == 1) "" else "s", unresolved });
}

// ── The rail (UI thread) ────────────────────────────────────────────────

/// Fixed slots, never reallocated: the poster daemon writes pixels straight into a
/// slot from its worker thread, so a slot must not move while a fetch is running.
/// (The shared catalogue poster drain only knows the Browse lists, so these cards
/// fetch their own posters.)
pub const Rail = struct {
    slots: [MAX_PICKS]state.TmdbItem = [_]state.TmdbItem{.{}} ** MAX_PICKS,
    count: usize = 0,
    imdb: [MAX_PICKS][16]u8 = undefined,
    imdb_len: [MAX_PICKS]u8 = [_]u8{0} ** MAX_PICKS,
    reasons: [MAX_PICKS][REASON_MAX]u8 = undefined,
    reason_len: [MAX_PICKS]u8 = [_]u8{0} ** MAX_PICKS,
    poster_tries: [MAX_PICKS]u8 = [_]u8{0} ** MAX_PICKS,
};

var rail: Rail = .{};
var loaded_revision: u32 = 0;
var loaded_visible = false;

fn copyBounded(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

fn anyFetching() bool {
    for (rail.slots[0..rail.count]) |*it| if (it.poster_fetching) return true;
    return false;
}

fn clearRail() void {
    for (rail.slots[0..rail.count]) |*it| poster.deinitPoster(&it.poster_pixels, &it.poster_tex);
    rail.count = 0;
}

fn reloadRail() void {
    clearRail();
    if (!ensureTable()) return;
    const stmt = db.prepare("SELECT imdb,kind,title,year,poster,rating,overview,reason FROM operator_picks WHERE dismissed=0 ORDER BY created_ms DESC, rowid LIMIT 12") orelse return;
    defer db.finalize(stmt);
    while (rail.count < MAX_PICKS and db.step(stmt) == db.c.SQLITE_ROW) {
        const imdb = db.columnText(stmt, 0) orelse continue;
        if (!cinemeta.validImdbId(imdb)) continue;
        const tv = std.mem.eql(u8, db.columnText(stmt, 1) orelse "", "tv");
        var item = state.TmdbItem{};
        item.id = cinemeta.stableId(imdb);
        item.imdb_id_len = copyBounded(&item.imdb_id, imdb);
        const title = db.columnText(stmt, 2) orelse "";
        item.title_len = copyBounded(&item.title, title);
        const year = db.columnInt(stmt, 3);
        if (year > 0) {
            const text = std.fmt.bufPrint(&item.year, "{d}", .{year}) catch item.year[0..0];
            item.year_len = text.len;
        }
        item.poster_path_len = copyBounded(&item.poster_path, db.columnText(stmt, 4) orelse "");
        item.rating = @floatCast(db.columnDouble(stmt, 5));
        item.overview_len = copyBounded(&item.overview, db.columnText(stmt, 6) orelse "");
        item.media_type_len = copyBounded(&item.media_type, if (tv) "tv" else "movie");
        const i = rail.count;
        rail.imdb_len[i] = @intCast(copyBounded(&rail.imdb[i], imdb));
        rail.reason_len[i] = @intCast(copyBounded(&rail.reasons[i], db.columnText(stmt, 7) orelse ""));
        // Series details are keyed by the catalogue id; tell the identity table which
        // IMDb id it stands for so the detail page needs no key.
        tmdb_api.rememberIdentity(if (tv) .series else .movie, item.id, imdb);
        rail.slots[i] = item;
        rail.poster_tries[i] = 0;
        rail.count += 1;
    }
}

/// Start each card's poster once. The result lands in the slot; the card draws it
/// (or its failure icon) like any catalogue card.
fn startPosters() void {
    for (rail.slots[0..rail.count], 0..) |*it, i| {
        if (it.poster_fetching or it.poster_path_len == 0 or it.poster_tex != null or it.poster_pixels != null) continue;
        // A fetch that ended without pixels is retried a few times (the daemon also
        // declines when too many are in flight); after that the card keeps its icon.
        if (it.poster_failed) {
            if (rail.poster_tries[i] >= 4) continue;
            it.poster_failed = false;
        } else if (it.poster_attempted) continue;
        rail.poster_tries[i] += 1;
        poster.fetchAsync(it.poster_path[0..it.poster_path_len], &it.poster_pixels, &it.poster_w, &it.poster_h, &it.poster_fetching);
        // Set either way: the card must not start the shared drain-based fetch itself.
        it.poster_attempted = true;
    }
}

/// UI thread. The picks to draw (empty when the switches are off), reloaded from the
/// database only when the stored set changed.
pub fn railItems() []state.TmdbItem {
    const visible = enabled();
    const rev = revision.load(.acquire);
    if ((visible != loaded_visible or rev != loaded_revision) and !anyFetching()) {
        loaded_visible = visible;
        loaded_revision = rev;
        if (visible) reloadRail() else clearRail();
    }
    startPosters();
    return rail.slots[0..rail.count];
}

pub fn reasonOf(i: usize) []const u8 {
    if (i >= rail.count) return "";
    return rail.reasons[i][0..rail.reason_len[i]];
}

/// The user does not want this one: it is never shown again.
pub fn dismiss(i: usize) void {
    if (i >= rail.count or !ensureTable()) return;
    const stmt = db.prepare("UPDATE operator_picks SET dismissed=1 WHERE imdb=?1") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, rail.imdb[i][0..rail.imdb_len[i]]);
    _ = db.step(stmt);
    _ = revision.fetchAdd(1, .acq_rel);
    state.wakeUi();
}
