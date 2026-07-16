const std = @import("std");
const db = @import("../core/db.zig");
const state = @import("../core/state.zig");
const sync = @import("../core/sync.zig");
const io_global = @import("../core/io_global.zig");
const taste_pure = @import("taste_pure.zig");

// ══════════════════════════════════════════════════════════
//  Activity collector + local taste engine (LOCAL-ONLY).
//
//  record(kind, title, meta) is the single narrow API. Events land in a
//  small mutex-guarded pending buffer and are flushed to SQLite by a
//  detached worker — the UI thread never blocks on a DB write here.
//  Per-item feature vectors (taste_pure.featurize, 128-dim deterministic
//  token hashing) go into the vec_taste vec0 table keyed via taste_items.
//
//  computeSuggestions() (called from the recommendations worker, off the
//  UI thread, at most once per session) builds a recency-decayed taste
//  profile over the logged events and scores the local TMDB catalog
//  against it — the primary tier of the Home "For You" rail.
//
//  Everything is on-device: no network hosts, no telemetry. All of it is
//  gated on state.app.taste_enabled ("Personalized suggestions
//  (local-only)" in Settings) and skipped in incognito mode.
// ══════════════════════════════════════════════════════════

pub const Kind = taste_pure.EventKind;

pub const Meta = struct {
    key: []const u8 = "", // stable identity (url/path/name); title used when empty
    genre: []const u8 = "", // "Action, Thriller" when known
    season_hint: i32 = 0,
    percent_watched: f64 = 0,
};

const MAX_TITLE = 160;
const MAX_KEY = 512;
const MAX_GENRE = 64;
const MAX_PENDING = 32;

const Event = struct {
    kind: Kind = .play,
    title: [MAX_TITLE]u8 = std.mem.zeroes([MAX_TITLE]u8),
    title_len: usize = 0,
    key: [MAX_KEY]u8 = std.mem.zeroes([MAX_KEY]u8),
    key_len: usize = 0,
    genre: [MAX_GENRE]u8 = std.mem.zeroes([MAX_GENRE]u8),
    genre_len: usize = 0,
    season_hint: i32 = 0,
    percent: f64 = 0,
};

// ── Pending buffer (mutex-guarded; flushed off-thread) ──
var pending: [MAX_PENDING]Event = undefined;
var pending_count: usize = 0;
var pending_mutex: sync.Mutex = .{};
var flush_busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Set by record()/clearTasteData(); consumed by the recommendations worker
/// as a cheap "profile needs recomputing" signal.
pub var profile_dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);

fn enabled() bool {
    return state.app.taste_enabled and !state.app.incognito_mode;
}

/// The ONE collection entry point. Cheap on the calling thread: copies the
/// event into the pending buffer and (if idle) kicks the flush worker.
/// Never blocks the UI thread on SQLite.
pub fn record(kind: Kind, title: []const u8, meta: Meta) void {
    if (!enabled()) return;
    if (title.len == 0) return;

    var ev = Event{ .kind = kind, .season_hint = meta.season_hint, .percent = meta.percent_watched };
    const tlen = @min(title.len, MAX_TITLE - 1);
    @memcpy(ev.title[0..tlen], title[0..tlen]);
    ev.title_len = tlen;
    const key = if (meta.key.len > 0) meta.key else title;
    const klen = @min(key.len, MAX_KEY - 1);
    @memcpy(ev.key[0..klen], key[0..klen]);
    ev.key_len = klen;
    const glen = @min(meta.genre.len, MAX_GENRE - 1);
    @memcpy(ev.genre[0..glen], meta.genre[0..glen]);
    ev.genre_len = glen;

    pending_mutex.lock();
    if (pending_count < MAX_PENDING) {
        pending[pending_count] = ev;
        pending_count += 1;
    } // else: drop — taste signal is lossy by design, never block
    pending_mutex.unlock();

    profile_dirty.store(true, .release);
    kickFlush();
}

fn kickFlush() void {
    if (flush_busy.load(.acquire)) return;
    flush_busy.store(true, .release);
    const th = std.Thread.spawn(.{}, struct {
        fn worker() void {
            defer flush_busy.store(false, .release);
            flushPending();
        }
    }.worker, .{}) catch {
        flush_busy.store(false, .release);
        return;
    };
    th.detach();
}

/// Drain the pending buffer to SQLite. Runs on the flush worker only.
/// Snapshot-under-mutex, write-outside-mutex per CLAUDE.md.
fn flushPending() void {
    while (true) {
        var batch: [MAX_PENDING]Event = undefined;
        pending_mutex.lock();
        const n = pending_count;
        if (n > 0) {
            @memcpy(batch[0..n], pending[0..n]);
            pending_count = 0;
        }
        pending_mutex.unlock();
        if (n == 0) return;
        for (batch[0..n]) |*ev| writeEvent(ev);
    }
}

fn kindName(kind: Kind) []const u8 {
    return @tagName(kind);
}

fn writeEvent(ev: *const Event) void {
    const title = ev.title[0..ev.title_len];
    const key = ev.key[0..ev.key_len];
    const genre = ev.genre[0..ev.genre_len];

    // 1) Append to the activity log.
    {
        const sql = "INSERT INTO activity_log (kind, title, key, genre, season_hint, percent_watched) VALUES (?1, ?2, ?3, ?4, ?5, ?6)";
        const stmt = db.prepare(sql) orelse return;
        defer db.finalize(stmt);
        db.bindText(stmt, 1, kindName(ev.kind));
        db.bindText(stmt, 2, title);
        db.bindText(stmt, 3, key);
        db.bindText(stmt, 4, genre);
        db.bindInt(stmt, 5, ev.season_hint);
        db.bindDouble(stmt, 6, ev.percent);
        _ = db.step(stmt);
    }

    // 2) Item feature vector for media-shaped events (searches log intent only).
    switch (ev.kind) {
        .play, .finish, .abandon, .queue_add => upsertVector(key, title, genre),
        .search => {},
    }
}

/// Upsert taste_items(key) and its vec_taste embedding (shared rowid, the
/// vec_aimemory/aimemory pattern from db.zig).
fn upsertVector(key: []const u8, title: []const u8, genre: []const u8) void {
    var vec: [taste_pure.DIM]f32 = undefined;
    if (!taste_pure.featurize(title, genre, &vec)) return; // all-noise title

    {
        const sql = "INSERT INTO taste_items (key, title, genre) VALUES (?1, ?2, ?3) " ++
            "ON CONFLICT(key) DO UPDATE SET title=excluded.title, " ++
            "genre=CASE WHEN excluded.genre != '' THEN excluded.genre ELSE taste_items.genre END";
        const stmt = db.prepare(sql) orelse return;
        defer db.finalize(stmt);
        db.bindText(stmt, 1, key);
        db.bindText(stmt, 2, title);
        db.bindText(stmt, 3, genre);
        _ = db.step(stmt);
    }

    var item_id: i64 = 0;
    {
        const stmt = db.prepare("SELECT id FROM taste_items WHERE key = ?1") orelse return;
        defer db.finalize(stmt);
        db.bindText(stmt, 1, key);
        if (db.step(stmt) != db.c.SQLITE_ROW) return;
        item_id = db.columnInt64(stmt, 0);
    }

    // vec0 has no UPSERT — delete + insert round-trips a re-featurized item.
    {
        const stmt = db.prepare("DELETE FROM vec_taste WHERE id = ?1") orelse return;
        defer db.finalize(stmt);
        db.bindInt64(stmt, 1, item_id);
        _ = db.step(stmt);
    }
    {
        const stmt = db.prepare("INSERT INTO vec_taste (id, embedding) VALUES (?1, ?2)") orelse return;
        defer db.finalize(stmt);
        db.bindInt64(stmt, 1, item_id);
        db.bindBlob(stmt, 2, std.mem.sliceAsBytes(vec[0..]));
        _ = db.step(stmt);
    }
}

// ══════════════════════════════════════════════════════════
// Playback tracking → play / finish / abandon
//
// UI-thread-only statics (both callers — player.load_file and the periodic
// position saves — run on the render thread, same contract as
// watch_history.savePosition). One tracked "current item"; switching away
// below the abandon threshold emits .abandon, crossing FINISH_PCT emits
// .finish exactly once.
// ══════════════════════════════════════════════════════════

const FINISH_PCT: f64 = 90.0;
const ABANDON_MIN_PCT: f64 = 5.0;
const ABANDON_MAX_PCT: f64 = 45.0;

var cur_key: [MAX_KEY]u8 = std.mem.zeroes([MAX_KEY]u8);
var cur_key_len: usize = 0;
var cur_title: [MAX_TITLE]u8 = std.mem.zeroes([MAX_TITLE]u8);
var cur_title_len: usize = 0;
var cur_percent: f64 = 0;
var cur_finished: bool = false;

/// Loopback/proxy URLs (the torrent stream proxy) carry no taste signal —
/// the torrent path reports its real name via onProgress instead.
fn isLocalNoise(key: []const u8) bool {
    return std.mem.indexOf(u8, key, "127.0.0.1") != null or
        std.mem.indexOf(u8, key, "localhost") != null;
}

fn setCurrent(key: []const u8, title: []const u8) void {
    const klen = @min(key.len, MAX_KEY - 1);
    @memcpy(cur_key[0..klen], key[0..klen]);
    cur_key_len = klen;
    const tlen = @min(title.len, MAX_TITLE - 1);
    @memcpy(cur_title[0..tlen], title[0..tlen]);
    cur_title_len = tlen;
    cur_percent = 0;
    cur_finished = false;
}

fn sameAsCurrent(key: []const u8) bool {
    return cur_key_len > 0 and std.mem.eql(u8, cur_key[0..cur_key_len], key);
}

/// Emit .abandon for the previously tracked item if it was dropped early,
/// then clear the tracker.
fn settlePrevious() void {
    if (cur_key_len == 0) return;
    if (!cur_finished and cur_percent >= ABANDON_MIN_PCT and cur_percent < ABANDON_MAX_PCT) {
        record(.abandon, cur_title[0..cur_title_len], .{
            .key = cur_key[0..cur_key_len],
            .percent_watched = cur_percent,
        });
    }
    cur_key_len = 0;
    cur_title_len = 0;
    cur_percent = 0;
    cur_finished = false;
}

/// Chokepoint: a new file starts playing (player.load_file). Settles the
/// previous item and records .play.
pub fn onPlay(path: []const u8) void {
    if (!enabled()) return;
    settlePrevious();
    if (path.len == 0 or isLocalNoise(path)) return;
    const title = taste_pure.deriveTitle(path);
    if (title.len == 0) return;
    setCurrent(path, title);
    record(.play, title, .{ .key = path });
}

/// Chokepoint: periodic position saves (history.savePlaybackPosition and
/// watch_history.savePosition). `percent` in 0..100. Detects finish (>=90%)
/// once per item and item switches (torrents report by name, not URL).
pub fn onProgress(key: []const u8, percent: f64) void {
    if (!enabled()) return;
    if (key.len == 0 or !std.math.isFinite(percent)) return;
    if (!sameAsCurrent(key)) {
        settlePrevious();
        if (isLocalNoise(key)) return;
        const title = taste_pure.deriveTitle(key);
        if (title.len == 0) return;
        setCurrent(key, title);
        // A torrent's proxy-URL play was skipped as local noise — its first
        // named progress report is the real "play" signal.
        record(.play, title, .{ .key = key });
    }
    if (percent > cur_percent) cur_percent = percent;
    if (!cur_finished and cur_percent >= FINISH_PCT) {
        cur_finished = true;
        record(.finish, cur_title[0..cur_title_len], .{
            .key = cur_key[0..cur_key_len],
            .percent_watched = cur_percent,
        });
    }
}

// ══════════════════════════════════════════════════════════
// Taste profile + suggestions
// ══════════════════════════════════════════════════════════

pub const Suggestion = struct {
    title: [128]u8 = std.mem.zeroes([128]u8),
    title_len: usize = 0,
    reason: [256]u8 = std.mem.zeroes([256]u8),
    reason_len: usize = 0,
    score: f64 = 0,
};

const MAX_SEEN = 128; // watched-title hashes excluded from candidates
const MIN_SCORE: f64 = 0.05; // don't surface noise on a weak profile

/// Build the recency-weighted taste profile from activity_log × vec_taste.
/// Returns false when there is no usable signal. `anchor` receives the
/// highest-weighted positive title (for "Because you watched …" receipts).
/// Runs on the recommendations worker — never call per frame.
fn computeProfile(
    out: *[taste_pure.DIM]f32,
    anchor: []u8,
    anchor_len: *usize,
    seen: *[MAX_SEEN]u64,
    seen_len: *usize,
) bool {
    anchor_len.* = 0;
    seen_len.* = 0;

    const sql =
        \\SELECT a.kind, a.percent_watched, a.ts, t.title, v.embedding
        \\FROM activity_log a
        \\JOIN taste_items t ON t.key = CASE WHEN a.key != '' THEN a.key ELSE a.title END
        \\JOIN vec_taste v ON v.id = t.id
        \\ORDER BY a.ts DESC LIMIT 400
    ;
    const stmt = db.prepare(sql) orelse return false;
    defer db.finalize(stmt);

    const now = io_global.timestamp();
    var sum: [taste_pure.DIM]f64 = std.mem.zeroes([taste_pure.DIM]f64);
    var best_w: f64 = 0;

    while (db.step(stmt) == db.c.SQLITE_ROW) {
        const kind_txt = db.columnText(stmt, 0) orelse continue;
        const kind = std.meta.stringToEnum(Kind, kind_txt) orelse continue;
        const pct = db.columnDouble(stmt, 1);
        const ts = db.columnInt64(stmt, 2);
        const item_title = db.columnText(stmt, 3) orelse "";

        const blob = db.columnBlob(stmt, 4) orelse continue;
        const want = taste_pure.DIM * @sizeOf(f32);
        if (blob.len < want) continue;
        var vec: [taste_pure.DIM]f32 = undefined;
        // Byte-wise copy — sqlite BLOB pointers carry no f32 alignment.
        @memcpy(std.mem.sliceAsBytes(vec[0..]), blob[0..want]);

        const age_days = @as(f64, @floatFromInt(@max(0, now - ts))) / 86400.0;
        const w = taste_pure.eventWeight(kind, pct) * taste_pure.decayWeight(age_days, taste_pure.HALF_LIFE_DAYS);
        if (w == 0) continue;
        taste_pure.accumulate(&sum, &vec, w);

        // Anchor: strongest positive contributor names the receipt.
        if (w > best_w and item_title.len > 0) {
            best_w = w;
            const alen = @min(item_title.len, anchor.len - 1);
            @memcpy(anchor[0..alen], item_title[0..alen]);
            anchor_len.* = alen;
        }
        // Anything the user already engaged with is not a suggestion.
        if (seen_len.* < MAX_SEEN and item_title.len > 0) {
            const h = taste_pure.titleHash(item_title);
            var dup = false;
            for (seen[0..seen_len.*]) |s| {
                if (s == h) {
                    dup = true;
                    break;
                }
            }
            if (!dup) {
                seen[seen_len.*] = h;
                seen_len.* += 1;
            }
        }
    }

    return taste_pure.finishProfile(&sum, out);
}

/// Score the local TMDB catalog against the taste profile; write the top
/// suggestions into `out` (descending score). Returns the count (0 when no
/// profile / no candidates — callers fall back to other tiers). Runs on the
/// recommendations worker thread, at most once per session (dirty-flag
/// consumers may re-run on demand — never per frame).
pub fn computeSuggestions(out: []Suggestion) usize {
    if (out.len == 0 or !enabled()) return 0;

    var profile: [taste_pure.DIM]f32 = undefined;
    var anchor: [96]u8 = undefined;
    var anchor_len: usize = 0;
    var seen: [MAX_SEEN]u64 = undefined;
    var seen_len: usize = 0;
    if (!computeProfile(&profile, &anchor, &anchor_len, &seen, &seen_len)) return 0;
    profile_dirty.store(false, .release);

    // Candidates: the locally cached TMDB catalog, minus items already on the
    // user's lists (the genre-fallback rail's convention).
    const sql = "SELECT title, genre_text, rating FROM tmdb_items " ++
        "WHERE id NOT IN (SELECT item_id FROM tmdb_lists) " ++
        "ORDER BY created_at DESC LIMIT 500";
    const stmt = db.prepare(sql) orelse return 0;
    defer db.finalize(stmt);

    var count: usize = 0;
    while (db.step(stmt) == db.c.SQLITE_ROW) {
        const title = db.columnText(stmt, 0) orelse continue;
        if (title.len == 0) continue;
        const genre = db.columnText(stmt, 1) orelse "";
        const rating = db.columnDouble(stmt, 2);

        // Skip titles the user already played/queued/finished.
        const h = taste_pure.titleHash(title);
        var watched = false;
        for (seen[0..seen_len]) |s| {
            if (s == h) {
                watched = true;
                break;
            }
        }
        if (watched) continue;

        var cvec: [taste_pure.DIM]f32 = undefined;
        if (!taste_pure.featurize(title, genre, &cvec)) continue;
        const score = taste_pure.scoreCandidate(&profile, &cvec, rating / 10.0);
        if (score <= MIN_SCORE) continue;

        // Insertion into the fixed-size result window (descending score).
        var pos = count;
        while (pos > 0 and out[pos - 1].score < score) : (pos -= 1) {}
        if (pos >= out.len) continue;
        if (count < out.len) count += 1;
        var i = count - 1;
        while (i > pos) : (i -= 1) out[i] = out[i - 1];

        var s = Suggestion{ .score = score };
        const tlen = @min(title.len, s.title.len - 1);
        @memcpy(s.title[0..tlen], title[0..tlen]);
        s.title_len = tlen;
        const reason: []const u8 = if (anchor_len > 0)
            std.fmt.bufPrint(&s.reason, "Because you watched {s}", .{anchor[0..anchor_len]}) catch "Matches your taste"
        else
            "Matches your taste";
        if (reason.ptr != &s.reason) {
            @memcpy(s.reason[0..reason.len], reason);
        }
        s.reason_len = reason.len;
        out[pos] = s;
    }

    return count;
}

/// "Clear taste data" (Settings): drop every activity row + vector. The
/// tables stay (schema is owned by db.createTables); only rows go.
pub fn clearTasteData() void {
    pending_mutex.lock();
    pending_count = 0;
    pending_mutex.unlock();
    cur_key_len = 0;
    cur_title_len = 0;
    cur_percent = 0;
    cur_finished = false;
    db.exec("DELETE FROM activity_log");
    db.exec("DELETE FROM taste_items");
    db.exec("DELETE FROM vec_taste");
    profile_dirty.store(true, .release);
}
