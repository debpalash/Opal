const std = @import("std");
const state = @import("../core/state.zig");
const sync = @import("../core/sync.zig");
const logs = @import("../core/logs.zig");
const c = @import("../core/c.zig");
const policy = @import("skip_policy_pure.zig");
const anime_skip = @import("anime_skip.zig");
const anime_pure = @import("anime_skip_pure.zig");

// ══════════════════════════════════════════════════════════════════════════
// Skip segments — the ONE skip machinery for intros/recaps/credits/previews.
//
// Sources, in priority order (merged per category by skip_policy_pure.merge):
//   1. Anime-Skip API   — owned by anime_skip.zig (fetch + anime-only gating)
//   2. Chapter titles   — published by markers.zig on FILE_LOADED (any media)
//   3. Fingerprints     — published by markers.zig's worker (local episodes)
//
// `tick()` (frame loop, under players_mutex) auto-skips when the user chose
// "Auto-skip", and executes button/web skip requests. `current()` drives the
// themed "Skip intro" / "Skip credits" / "Next episode" button.
//
// Chapter/fingerprint lists belong to one file load, identified by a
// generation counter bumped on every reset; a worker publishing for an older
// generation is ignored, so markers can never leak onto the next file.
// ══════════════════════════════════════════════════════════════════════════

const MAX = policy.MAX_SEGS;

var mutex = sync.Mutex{};
var generation: u64 = 0; // under mutex
var owner_addr: usize = 0; // under mutex
var chap: [MAX]policy.Seg = undefined;
var chap_n: usize = 0;
var fpl: [MAX]policy.Seg = undefined;
var fp_n: usize = 0;
var next_path: [1024]u8 = undefined;
var next_path_len: usize = 0;

/// Set by the button / web API, consumed by tick() on the owner thread.
var skip_requested = std.atomic.Value(bool).init(false);

// Once-per-segment auto-skip latch. Written by tick() (owner thread), read by
// current() from the web snapshot thread too, hence atomics.
var latch = std.atomic.Value(i32).init(-1);
var latch_gen = std.atomic.Value(u64).init(0);

/// Start a fresh file: drop chapter/fingerprint segments and the next-episode
/// path. Returns the new generation for publishers to tag their results with.
pub fn reset(player_addr: usize) u64 {
    mutex.lock();
    defer mutex.unlock();
    generation +%= 1;
    owner_addr = player_addr;
    chap_n = 0;
    fp_n = 0;
    next_path_len = 0;
    return generation;
}

pub fn currentGeneration() u64 {
    mutex.lock();
    defer mutex.unlock();
    return generation;
}

/// Publish one source's segments for generation `gen` (stale gens dropped).
pub fn publish(source: policy.Source, gen: u64, segs: []const policy.Seg) bool {
    mutex.lock();
    defer mutex.unlock();
    if (gen != generation) return false;
    const n = @min(segs.len, MAX);
    switch (source) {
        .chapters => {
            @memcpy(chap[0..n], segs[0..n]);
            chap_n = n;
        },
        .fingerprint => {
            @memcpy(fpl[0..n], segs[0..n]);
            fp_n = n;
        },
        .anime_skip => return false, // anime_skip.zig owns its own list
    }
    state.wakeUi();
    return true;
}

/// Remember the local file that follows the current one ("Next episode").
pub fn publishNextPath(gen: u64, path: []const u8) void {
    mutex.lock();
    defer mutex.unlock();
    if (gen != generation or path.len > next_path.len) return;
    @memcpy(next_path[0..path.len], path);
    next_path_len = path.len;
}

fn mode() policy.Mode {
    return policy.modeFromInt(state.app.skip_mode);
}

fn prefs() policy.Prefs {
    return .{
        .intro = state.app.anime_skip_intro,
        .recap = state.app.anime_skip_recap,
        .credits = state.app.anime_skip_credits,
        .preview = state.app.anime_skip_preview,
    };
}

pub const Current = struct {
    decision: policy.Decision,
    gen: u64,
};

/// Merged segments for the active player. Returns count and generation.
fn snapshot(out: []policy.Seg, gen_out: *u64) usize {
    if (state.app.active_player_idx >= state.app.players.items.len) return 0;
    const p = state.app.players.items[state.app.active_player_idx];

    var a_raw: [anime_pure.MAX_SEGMENTS]anime_pure.Segment = undefined;
    const an = if (p.anime_skip_active) anime_skip.snapshot(&a_raw) else 0;
    var a_segs: [MAX]policy.Seg = undefined;
    var ak: usize = 0;
    for (a_raw[0..an]) |s| {
        if (ak >= MAX) break;
        a_segs[ak] = .{ .start = s.start, .end = s.end, .category = s.category, .source = .anime_skip };
        ak += 1;
    }

    var ch: [MAX]policy.Seg = undefined;
    var fs: [MAX]policy.Seg = undefined;
    mutex.lock();
    const mine = owner_addr == @intFromPtr(p);
    const cn = if (mine) chap_n else 0;
    const fnn = if (mine) fp_n else 0;
    @memcpy(ch[0..cn], chap[0..cn]);
    @memcpy(fs[0..fnn], fpl[0..fnn]);
    gen_out.* = generation;
    mutex.unlock();

    return policy.merge(.{ a_segs[0..ak], ch[0..cn], fs[0..fnn] }, out);
}

fn hasNextEpisode(p: anytype) bool {
    mutex.lock();
    const local = next_path_len > 0 and owner_addr == @intFromPtr(p);
    mutex.unlock();
    if (local) return true;
    if (p.cached_playlist_count > 1 and p.cached_playlist_pos + 1 < p.cached_playlist_count) return true;
    return @import("tv_library.zig").neighborEpisode(1) != null;
}

/// The segment the play head is in right now (null = none / mode Off).
pub fn current() ?Current {
    if (mode() == .off) return null;
    if (state.app.active_player_idx >= state.app.players.items.len) return null;
    const p = state.app.players.items[state.app.active_player_idx];
    var segs: [MAX]policy.Seg = undefined;
    var gen: u64 = 0;
    const n = snapshot(&segs, &gen);
    if (n == 0) return null;
    var ctx = policy.Context{
        .mode = mode(),
        .prefs = prefs(),
        .duration = p.cached_duration,
        .latch = if (latch_gen.load(.acquire) == gen) latch.load(.acquire) else -1,
    };
    var d = policy.decide(p.last_seen_pos, segs[0..n], ctx) orelse return null;
    // "Next episode" needs a (possibly DB-backed) lookup — only pay for it
    // inside credits/previews.
    if (d.category == .credits or d.category == .preview) {
        ctx.has_next = hasNextEpisode(p);
        d = policy.decide(p.last_seen_pos, segs[0..n], ctx) orelse return null;
    }
    return .{ .decision = d, .gen = gen };
}

/// Button / web: skip the current segment (or play the next episode).
/// Executed on the owner thread by tick().
pub fn requestSkip() void {
    skip_requested.store(true, .release);
    state.wakeUi();
}

fn seekTo(p: anytype, target: f64) void {
    var seek_buf: [64]u8 = undefined;
    const cmd = std.fmt.bufPrintZ(&seek_buf, "seek {d:.1} absolute", .{target}) catch return;
    _ = c.mpv.mpv_command_string(p.mpv_ctx, cmd.ptr);
    p.last_seen_pos = target;
}

fn toastSkipped(cat: policy.Category) void {
    var toast_buf: [48]u8 = undefined;
    const toast = std.fmt.bufPrint(&toast_buf, "Skipped {s}", .{anime_pure.label(cat)}) catch "Skipped";
    state.showToast(toast);
}

fn playNext(p: anytype) void {
    var path_z: [1025]u8 = undefined;
    mutex.lock();
    const n = if (owner_addr == @intFromPtr(p)) next_path_len else 0;
    @memcpy(path_z[0..n], next_path[0..n]);
    mutex.unlock();
    if (n > 0) {
        path_z[n] = 0;
        logs.pushLog("info", "skip", "Next episode (local)", false);
        p.load_file(@ptrCast(&path_z));
        return;
    }
    const tv = @import("tv_library.zig");
    if (tv.neighborEpisode(1) != null) {
        tv.playNeighborEpisode(1);
        return;
    }
    _ = c.mpv.mpv_command_string(p.mpv_ctx, "playlist-next");
}

fn setLatch(index: usize, gen: u64) void {
    latch.store(@intCast(index), .release);
    latch_gen.store(gen, .release);
}

/// Frame-loop hook (desktop + headless). Cheap when nothing is loaded.
pub fn tick() void {
    const requested = skip_requested.swap(false, .acq_rel);
    if (mode() == .off) return;
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    const p = state.app.players.items[state.app.active_player_idx];
    const cur = current() orelse return;
    const d = cur.decision;

    if (requested) {
        if (d.action == .next_episode) {
            playNext(p);
        } else {
            seekTo(p, d.target);
            toastSkipped(d.category);
        }
        setLatch(d.index, cur.gen);
        return;
    }
    if (!d.auto or p.cached_paused or p.last_seen_pos <= 0) return;
    seekTo(p, d.target);
    setLatch(d.index, cur.gen);
    toastSkipped(d.category);
}

/// JSON object for the web player snapshot, or "null".
pub fn writeJson(w: *std.Io.Writer) void {
    const cur = current() orelse {
        w.writeAll("null") catch {};
        return;
    };
    const d = cur.decision;
    w.print("{{\"kind\":\"{s}\",\"action\":\"{s}\",\"label\":\"{s}\",\"target\":{d:.3},\"source\":\"{s}\",\"auto\":{s}}}", .{
        policy.kindName(d.category),
        @tagName(d.action),
        policy.buttonLabel(d),
        d.target,
        policy.sourceName(d.source),
        if (d.auto) "true" else "false",
    }) catch {};
}
