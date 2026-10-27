const std = @import("std");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const http = @import("../core/http.zig");
const sync = @import("../core/sync.zig");
const alloc = @import("../core/alloc.zig");
const pure = @import("anime_skip_pure.zig");

// ══════════════════════════════════════════════════════════════════════════
// Anime-Skip service — "SponsorBlock for anime".
//
// On an anime episode load, a detached worker POSTs `findEpisodeByName` to
// anime-skip's GraphQL API, parses the crowdsourced markers (via the pure
// module), converts point markers → [start,end) ranges, and publishes them
// under a mutex. skip_segments.tick() runs from the frame loop, reads the active player's
// mirrored time-pos, and — when playback enters a segment the user opted to
// skip — seeks past it. Seeking, the "Skipped X" toast and the Skip button
// are shared with chapter/fingerprint markers in skip_segments.zig.
//
// Read-only: we consume timestamps, never submit them. No login/account.
//
// Gating: skips only fire for ANIME-sourced playback. anime.zig calls
// `onEpisodeLoad` which sets a one-shot `pending_arm`; the very next
// `MediaPlayer.load_file` (the anime episode) consumes it via `onFileLoad`
// and marks that player `anime_skip_active`. Any other file load clears the
// flag AND the stale segments.
// ══════════════════════════════════════════════════════════════════════════

const ENDPOINT = "https://api.anime-skip.com/graphql";
// anime-skip's public client ID (used by their own web/extension tooling; no
// user login needed for reads). Sent on every request.
const CLIENT_ID = "ZGfO0sMF3eCwLYf8yMSCJjlynwNGRXWE";

var mutex = sync.Mutex{};
var segs: [pure.MAX_SEGMENTS]pure.Segment = undefined;
var seg_count: usize = 0;

var loaded = std.atomic.Value(bool).init(false);
var pending_arm = std.atomic.Value(bool).init(false);

/// Consume the one-shot arm set by `onEpisodeLoad`. Returns true exactly once
/// per arm — the anime episode's `load_file` claims it, later loads don't.
pub fn consumePendingArm() bool {
    return pending_arm.swap(false, .acq_rel);
}

/// Called from `MediaPlayer.load_file` for EVERY load. Consumes the pending
/// arm (anime episode → active); a non-anime load clears stale segments so a
/// previous anime episode's markers can't leak onto unrelated media.
pub fn onFileLoad(p: anytype) void {
    const armed = consumePendingArm();
    p.anime_skip_active = armed;
    // Chapter/fingerprint markers of the previous file must not show while
    // this one opens; markers.zig republishes them on FILE_LOADED.
    _ = @import("skip_segments.zig").reset(@intFromPtr(p));
    if (!armed) clear();
}

/// Clear any published segments (also resets the loaded flag + latch).
pub fn clear() void {
    mutex.lock();
    seg_count = 0;
    mutex.unlock();
    loaded.store(false, .release);
}

/// Kick off a background fetch for an anime episode. `episode_name` is the
/// best available human-readable episode name (see anime.zig for how it's
/// composed — best-effort; anime-skip matches on episode NAME).
pub fn onEpisodeLoad(episode_name: []const u8) void {
    if (!state.app.anime_skip_enabled) return;
    if (episode_name.len == 0) return;

    // Fresh episode → wipe old segments, arm the next load, fetch anew.
    clear();
    pending_arm.store(true, .release);

    Fetch.spawn(episode_name);
}

// ── Background fetch worker (struct{var}: copy inputs before spawn) ────────
const Fetch = struct {
    var busy: bool = false;
    var name_buf: [160]u8 = undefined;
    var name_len: usize = 0;

    fn spawn(episode_name: []const u8) void {
        if (@This().busy) return; // a fetch is already in flight
        @This().busy = true;
        const n = @min(episode_name.len, @This().name_buf.len);
        @memcpy(@This().name_buf[0..n], episode_name[0..n]);
        @This().name_len = n;

        if (@import("../core/workers.zig").spawnLegacy(@This().run, .{})) |t| {
            @import("../core/workers.zig").release(t);
        } else |_| {
            @This().busy = false;
        }
    }

    fn run() void {
        defer @This().busy = false;
        const name = @This().name_buf[0..@This().name_len];

        var body_buf: [512]u8 = undefined;
        const body = pure.buildRequestBody(name, &body_buf);
        if (body.len == 0) return;

        // Heap response buffer — never large stack allocs on a spawned thread.
        const resp_buf = alloc.allocator.alloc(u8, 64 * 1024) catch return;
        defer alloc.allocator.free(resp_buf);

        const resp = http.fetch(ENDPOINT, resp_buf, .{
            .method = .POST,
            .payload = body,
            .content_type = "application/json",
            // http.fetch supports one extra header via auth_header ("Name: value").
            .auth_header = "X-Client-ID: " ++ CLIENT_ID,
            .accept = "application/json",
            .max_response = 64 * 1024,
            .timeout_secs = 12,
        }) orelse {
            logs.pushLog("info", "anime-skip", "No timestamps (network or no match)", false);
            return;
        };

        // Duration is unknown at fetch time (the torrent may still be
        // buffering), so pass 0 → the pick-best heuristic falls back to
        // source preference + first match.
        var markers: [pure.MAX_MARKERS]pure.Marker = undefined;
        const nm = pure.parseResponse(alloc.allocator, resp, 0, &markers);
        if (nm == 0) {
            logs.pushLog("info", "anime-skip", "No markers for this episode", false);
            return;
        }

        var local_segs: [pure.MAX_SEGMENTS]pure.Segment = undefined;
        const ns = pure.buildSkipSegments(markers[0..nm], 0, &local_segs);

        mutex.lock();
        seg_count = ns;
        @memcpy(segs[0..ns], local_segs[0..ns]);
        mutex.unlock();
        loaded.store(true, .release);

        var log_buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&log_buf, "Loaded {d} skip markers", .{ns}) catch "Loaded skip markers";
        logs.pushLog("info", "anime-skip", msg, false);
    }
};

// ── Segment snapshot ──────────────────────────────────────────────────────
/// Copy the published Anime-Skip segments (empty when disabled / not loaded).
/// skip_segments.zig merges these with chapter and fingerprint markers
/// (Anime-Skip wins per category) and owns the per-frame skip decision —
/// `shouldSkip`'s [start,end) + once-per-segment semantics live on in
/// skip_policy_pure.decide.
pub fn snapshot(out: []pure.Segment) usize {
    if (!state.app.anime_skip_enabled) return 0;
    if (!loaded.load(.acquire)) return 0;
    mutex.lock();
    defer mutex.unlock();
    const n = @min(seg_count, out.len);
    @memcpy(out[0..n], segs[0..n]);
    return n;
}
