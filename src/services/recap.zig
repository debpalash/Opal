//! "Previously on…" recaps, generated on demand by the local LLM from the
//! episodes the user has already watched BEFORE the current one (recap_pure
//! enforces the never-later-episodes rule). Sources: our own live-caption
//! transcripts when present, else TMDB episode overviews. Results are cached
//! in the DB per (show, season, episode).
const std = @import("std");
const state = @import("../core/state.zig");
const db = @import("../core/db.zig");
const sync = @import("../core/sync.zig");
const logs = @import("../core/logs.zig");
const io = @import("../core/io_global.zig");
const workers = @import("../core/workers.zig");
const alloc = @import("../core/alloc.zig").allocator;
const pure = @import("recap_pure.zig");
const llm = @import("llm_oneshot.zig");
const babel = @import("babel.zig");

pub const Phase = enum { idle, working, ready, nothing, failed };

/// UI-visible result. Written by the worker under `mutex`.
var mutex: sync.Mutex = .{};
var result: struct {
    phase: Phase = .idle,
    tmdb_id: i32 = 0,
    ep: pure.Ep = .{ .season = 0, .episode = 0 },
    text: [1024]u8 = undefined,
    text_len: usize = 0,
    show: [128]u8 = undefined,
    show_len: usize = 0,
    cached: bool = false,
} = .{};
var busy = std.atomic.Value(bool).init(false);
var generation = std.atomic.Value(u64).init(1);

/// Card visibility (UI thread only).
pub var card_open: bool = false;

pub const Snapshot = struct {
    phase: Phase = .idle,
    tmdb_id: i32 = 0,
    ep: pure.Ep = .{ .season = 0, .episode = 0 },
    text: [1024]u8 = undefined,
    text_len: usize = 0,
    show: [128]u8 = undefined,
    show_len: usize = 0,
    cached: bool = false,
};

pub fn snapshot() Snapshot {
    mutex.lock();
    defer mutex.unlock();
    var s: Snapshot = .{ .phase = result.phase, .tmdb_id = result.tmdb_id, .ep = result.ep, .text_len = result.text_len, .show_len = result.show_len, .cached = result.cached };
    @memcpy(s.text[0..s.text_len], result.text[0..s.text_len]);
    @memcpy(s.show[0..s.show_len], result.show[0..s.show_len]);
    return s;
}

/// The TV episode bound to the active player, if any.
pub fn currentEpisode() ?struct { tmdb_id: i32, ep: pure.Ep } {
    if (state.app.active_player_idx >= state.app.players.items.len) return null;
    const p = state.app.players.items[state.app.active_player_idx];
    const pe = &state.app.playing_episode;
    if (!pe.matches(p.current_url[0..p.current_url_len])) return null;
    return .{ .tmdb_id = pe.tmdb_id, .ep = .{ .season = pe.season, .episode = pe.episode } };
}

/// A recap only makes sense when something airs before this episode.
pub fn eligible() bool {
    if (!state.app.babel_recap_enabled) return false;
    const cur = currentEpisode() orelse return false;
    return cur.ep.season >= 1 and !(cur.ep.season == 1 and cur.ep.episode <= 1);
}

pub fn onMediaChange() void {
    _ = generation.fetchAdd(1, .acq_rel);
    card_open = false;
}

const Args = struct {
    gen: u64,
    tmdb_id: i32,
    ep: pure.Ep,
    force: bool,
    api_key: [256]u8,
    api_key_len: usize,
};

/// UI thread: open the card and (re)generate if needed.
pub fn request(force: bool) void {
    const cur = currentEpisode() orelse return;
    card_open = true;
    {
        mutex.lock();
        defer mutex.unlock();
        const same = result.tmdb_id == cur.tmdb_id and result.ep.season == cur.ep.season and result.ep.episode == cur.ep.episode;
        if (same and !force and (result.phase == .ready or result.phase == .working or result.phase == .nothing)) return;
    }
    if (busy.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
    llm.prepare();
    const t = &state.app.tmdb;
    var args: Args = .{ .gen = generation.load(.acquire), .tmdb_id = cur.tmdb_id, .ep = cur.ep, .force = force, .api_key = t.api_key, .api_key_len = @min(t.api_key_len, t.api_key.len) };
    _ = &args;
    mutex.lock();
    result.phase = .working;
    result.tmdb_id = cur.tmdb_id;
    result.ep = cur.ep;
    result.text_len = 0;
    result.cached = false;
    mutex.unlock();
    if (workers.spawnLegacy(worker, .{args})) |th| workers.release(th) else |_| {
        busy.store(false, .release);
        finish(args, .failed, "Could not start the recap worker.", false);
    }
}

fn finish(a: Args, phase: Phase, text: []const u8, cached: bool) void {
    mutex.lock();
    defer mutex.unlock();
    if (generation.load(.acquire) != a.gen) return;
    if (result.tmdb_id != a.tmdb_id or result.ep.season != a.ep.season or result.ep.episode != a.ep.episode) return;
    result.phase = phase;
    result.text_len = @min(text.len, result.text.len);
    @memcpy(result.text[0..result.text_len], text[0..result.text_len]);
    result.cached = cached;
    state.wakeUi();
}

fn setShow(name: []const u8) void {
    mutex.lock();
    defer mutex.unlock();
    result.show_len = @min(name.len, result.show.len);
    @memcpy(result.show[0..result.show_len], name[0..result.show_len]);
}

// ── DB cache (table created in db.zig: recap_cache) ──

fn cacheGet(tmdb_id: i32, ep: pure.Ep, out: []u8) ?[]const u8 {
    const stmt = db.prepare("SELECT text FROM recap_cache WHERE tmdb_id=? AND season=? AND episode=?") orelse return null;
    defer db.finalize(stmt);
    db.bindInt(stmt, 1, tmdb_id);
    db.bindInt(stmt, 2, ep.season);
    db.bindInt(stmt, 3, ep.episode);
    if (db.step(stmt) != db.c.SQLITE_ROW) return null;
    const t = db.columnText(stmt, 0) orelse return null;
    const n = @min(t.len, out.len);
    @memcpy(out[0..n], t[0..n]);
    return if (n > 0) out[0..n] else null;
}

fn cachePut(tmdb_id: i32, ep: pure.Ep, text: []const u8, sources: usize) void {
    const stmt = db.prepare("INSERT OR REPLACE INTO recap_cache (tmdb_id, season, episode, text, sources, created_at) VALUES (?,?,?,?,?,?)") orelse return;
    defer db.finalize(stmt);
    db.bindInt(stmt, 1, tmdb_id);
    db.bindInt(stmt, 2, ep.season);
    db.bindInt(stmt, 3, ep.episode);
    db.bindText(stmt, 4, text);
    db.bindInt(stmt, 5, @intCast(sources));
    db.bindInt64(stmt, 6, io.timestamp());
    _ = db.step(stmt);
}

fn showName(tmdb_id: i32, out: []u8) []const u8 {
    const stmt = db.prepare("SELECT name FROM tv_shows WHERE tmdb_id=?") orelse return "";
    defer db.finalize(stmt);
    db.bindInt(stmt, 1, tmdb_id);
    if (db.step(stmt) != db.c.SQLITE_ROW) return "";
    const t = db.columnText(stmt, 0) orelse return "";
    const n = @min(t.len, out.len);
    @memcpy(out[0..n], t[0..n]);
    return out[0..n];
}

// ── Worker ──

const SeasonCache = struct {
    season: i32 = -1,
    parsed: ?std.json.Parsed(pure.SeasonJson) = null,
    body: ?[]u8 = null,

    fn deinit(s: *SeasonCache) void {
        if (s.parsed) |p| p.deinit();
        if (s.body) |b| alloc.free(b);
        s.* = .{};
    }

    fn load(s: *SeasonCache, a: *const Args, season: i32) void {
        if (s.season == season) return;
        s.deinit();
        s.season = season;
        if (a.api_key_len == 0) return;
        var path_buf: [96]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/3/tv/{d}/season/{d}", .{ a.tmdb_id, season }) catch return;
        const body = @import("tmdb_api.zig").tmdbApiOwned(path, a.api_key[0..a.api_key_len], @import("tmdb_pure.zig").DETAIL_BODY_LIMIT) orelse return;
        s.body = body;
        s.parsed = pure.parseSeason(alloc, body) catch null;
    }

    fn episode(s: *const SeasonCache, number: i32) ?struct { name: []const u8, overview: []const u8 } {
        const p = s.parsed orelse return null;
        for (p.value.episodes) |e| if (e.episode_number == number) return .{ .name = e.name orelse "", .overview = e.overview orelse "" };
        return null;
    }
};

fn worker(a: Args) void {
    defer busy.store(false, .release);
    var show_buf: [128]u8 = undefined;
    const show = showName(a.tmdb_id, &show_buf);
    setShow(show);

    if (!a.force) {
        var cached_buf: [1024]u8 = undefined;
        if (cacheGet(a.tmdb_id, a.ep, &cached_buf)) |t| {
            finish(a, .ready, t, true);
            return;
        }
    }

    // Watched episodes → strictly-earlier sources (the spoiler rule).
    var watched: [512]pure.Ep = undefined;
    var raw: [512]@import("tv_pure.zig").Ep = undefined;
    const wn = db.tvLoadWatchedAll(a.tmdb_id, &raw);
    for (raw[0..wn], 0..) |e, i| watched[i] = .{ .season = e.season, .episode = e.episode };
    var picked_buf: [pure.max_sources]pure.Ep = undefined;
    const picked = pure.selectSources(watched[0..wn], a.ep, pure.max_sources, &picked_buf);
    if (picked.len == 0) {
        finish(a, .nothing, "Nothing to recap yet: mark earlier episodes as watched (or watch them in Opal) and recaps will draw on them.", false);
        return;
    }

    var sources: [pure.max_sources]pure.Source = undefined;
    var transcripts: [pure.max_sources]?[]u8 = .{null} ** pure.max_sources;
    defer for (transcripts) |t| if (t) |b| alloc.free(b);
    var seasons: SeasonCache = .{};
    defer seasons.deinit();
    for (picked, 0..) |e, i| {
        sources[i] = .{ .ep = e };
        var tp_buf: [800]u8 = undefined;
        const tp = babel.transcriptPath(&tp_buf, a.tmdb_id, e.season, e.episode);
        if (tp.len > 0) {
            if (io.cwdReadFileAlloc(tp, alloc, 512 * 1024)) |body| {
                transcripts[i] = body;
                sources[i].transcript = body;
            } else |_| {}
        }
        if (pure.sourceKind(sources[i]) != .transcript) {
            seasons.load(&a, e.season);
            if (seasons.episode(e.episode)) |info| {
                sources[i].title = info.name;
                sources[i].overview = info.overview;
            }
        }
    }

    var prompt: std.Io.Writer.Allocating = .init(alloc);
    defer prompt.deinit();
    const used = pure.writePrompt(&prompt.writer, show, a.ep, sources[0..picked.len]) catch 0;
    if (used == 0) {
        finish(a, .nothing, "No summaries or transcripts are available for the episodes you've watched yet.", false);
        return;
    }
    if (generation.load(.acquire) != a.gen) return;

    const reply = llm.complete(pure.system_prompt, prompt.written(), 400, 120, null) catch |e| {
        finish(a, .failed, switch (e) {
            error.Offline => "Recaps need an AI model: install one in Settings › AI.",
            else => "The AI model didn't return a usable recap. Try again.",
        }, false);
        return;
    };
    defer alloc.free(reply);
    var clamp_buf: [2048]u8 = undefined;
    const text = pure.clampRecap(reply, pure.max_recap_chars, &clamp_buf);
    if (text.len == 0) {
        finish(a, .failed, "The AI model returned an empty recap. Try again.", false);
        return;
    }
    cachePut(a.tmdb_id, a.ep, text, used);
    logs.pushLog("info", "babel", "Recap generated", false);
    finish(a, .ready, text, false);
}

/// UI thread: read the current recap aloud through the voice TTS path.
pub fn readAloud() void {
    const s = snapshot();
    if (s.phase != .ready or s.text_len == 0) return;
    @import("ai_voice.zig").speakResponse(s.text[0..s.text_len]);
}
