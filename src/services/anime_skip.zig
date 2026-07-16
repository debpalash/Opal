const std = @import("std");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const http = @import("../core/http.zig");
const sync = @import("../core/sync.zig");
const alloc = @import("../core/alloc.zig");
const c = @import("../core/c.zig");
const pure = @import("anime_skip_pure.zig");

// ══════════════════════════════════════════════════════════════════════════
// Anime-Skip service — "SponsorBlock for anime".
//
// On an anime episode load, a detached worker POSTs `findEpisodeByName` to
// anime-skip's GraphQL API, parses the crowdsourced markers (via the pure
// module), converts point markers → [start,end) ranges, and publishes them
// under a mutex. `tick()` runs from the frame loop, reads the active player's
// mirrored time-pos, and — when playback enters a segment the user opted to
// skip — seeks past it (reusing the player's `seek … absolute` mpv path) and
// shows a "Skipped X" toast.
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

// Once-per-segment latch (UI thread only — read/written in tick()).
var last_skipped_seg: i32 = -1;

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
    last_skipped_seg = -1;
    if (!armed) clear();
}

/// Clear any published segments (also resets the loaded flag + latch).
pub fn clear() void {
    mutex.lock();
    seg_count = 0;
    mutex.unlock();
    loaded.store(false, .release);
    last_skipped_seg = -1;
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

        if (std.Thread.spawn(.{}, @This().run, .{})) |t| {
            t.detach();
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

// ── Per-frame skip check ──────────────────────────────────────────────────
/// Called each frame from the app loop. Cheap no-op unless anime-skip is
/// enabled, the active player is anime-sourced, and markers are loaded.
pub fn tick() void {
    if (!state.app.anime_skip_enabled) return;
    if (!loaded.load(.acquire)) return;
    if (state.app.active_player_idx >= state.app.players.items.len) return;

    const p = state.app.players.items[state.app.active_player_idx];
    if (!p.anime_skip_active) return;
    if (p.cached_paused) return; // don't seek a paused player

    const pos = p.last_seen_pos;
    if (pos <= 0) return;

    const prefs = pure.Prefs{
        .intro = state.app.anime_skip_intro,
        .recap = state.app.anime_skip_recap,
        .credits = state.app.anime_skip_credits,
        .preview = state.app.anime_skip_preview,
    };

    // Snapshot segments under the mutex, then act without holding it.
    mutex.lock();
    var snap: [pure.MAX_SEGMENTS]pure.Segment = undefined;
    const n = seg_count;
    @memcpy(snap[0..n], segs[0..n]);
    mutex.unlock();
    if (n == 0) return;

    const decision = pure.shouldSkip(pos, snap[0..n], prefs, last_skipped_seg) orelse return;

    // Reuse the exact seek path player.zig uses for resume.
    var seek_buf: [64]u8 = undefined;
    const cmd = std.fmt.bufPrintZ(&seek_buf, "seek {d:.1} absolute", .{decision.target}) catch return;
    _ = c.mpv.mpv_command_string(p.mpv_ctx, cmd.ptr);
    p.last_seen_pos = decision.target;
    last_skipped_seg = @intCast(decision.seg_index);

    var toast_buf: [48]u8 = undefined;
    const toast = std.fmt.bufPrint(&toast_buf, "\xe2\x8f\xad Skipped {s}", .{pure.label(decision.category)}) catch "Skipped";
    state.showToast(toast);
}

/// Is the active player currently inside a KNOWN skippable segment (regardless
/// of whether auto-skip for that type is on)? Returns the seek target + label
/// so the player controls can offer a manual "Skip" affordance. null = not in
/// a segment / nothing loaded.
pub fn currentSkippable() ?struct { target: f64, category: pure.Category } {
    if (!state.app.anime_skip_enabled) return null;
    if (!loaded.load(.acquire)) return null;
    if (state.app.active_player_idx >= state.app.players.items.len) return null;
    const p = state.app.players.items[state.app.active_player_idx];
    if (!p.anime_skip_active) return null;
    const pos = p.last_seen_pos;

    mutex.lock();
    defer mutex.unlock();
    for (segs[0..seg_count]) |s| {
        if (pos >= s.start and pos < s.end) {
            // Only offer skips for the four toggle-able categories.
            switch (s.category) {
                .intro, .recap, .credits, .preview => return .{ .target = s.end, .category = s.category },
                else => return null,
            }
        }
    }
    return null;
}

/// Manually skip the current segment (from the player-controls affordance).
pub fn skipNow() void {
    const cur = currentSkippable() orelse return;
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    const p = state.app.players.items[state.app.active_player_idx];
    var seek_buf: [64]u8 = undefined;
    const cmd = std.fmt.bufPrintZ(&seek_buf, "seek {d:.1} absolute", .{cur.target}) catch return;
    _ = c.mpv.mpv_command_string(p.mpv_ctx, cmd.ptr);
    p.last_seen_pos = cur.target;

    var toast_buf: [48]u8 = undefined;
    const toast = std.fmt.bufPrint(&toast_buf, "\xe2\x8f\xad Skipped {s}", .{pure.label(cur.category)}) catch "Skipped";
    state.showToast(toast);
}
