//! macOS Now Playing + hardware media keys — Zig side of
//! src/macos/media_remote.m (MPNowPlayingInfoCenter / MPRemoteCommandCenter).
//!
//! The ObjC command handlers never call into Zig: they enqueue {cmd, arg}
//! records into a mutex-protected ring inside the .m file, and frameTick()
//! drains that ring on the UI thread once per frame. All module state below
//! is therefore UI-thread-only (frameTick from appFrame, clear from
//! appDeinit — same thread), so no atomics are needed HERE; the cross-thread
//! boundary is the pthread mutex in media_remote.m.
//!
//! Compiles to a no-op on non-macOS: every pub fn starts with a comptime-
//! known os check, so the externs are never referenced in emitted code.

const std = @import("std");
const builtin = @import("builtin");
const state = @import("../core/state.zig");
const c = @import("../core/c.zig");
const logs = @import("../core/logs.zig");
const pure = @import("media_remote_pure.zig");

/// macOS AND not headless. The server build stops compiling media_remote.m
/// (build.zig Phase S1) so it links no Cocoa/Foundation — and a headless server
/// has no Now Playing card to publish and no media keys to receive. Comptime, so
/// the externs below are never referenced in the emitted server binary.
const enabled = builtin.os.tag == .macos and !@import("build_options").headless;

extern fn opal_media_remote_init() void;
extern fn opal_media_remote_poll(arg_out: *f64) c_int;
extern fn opal_nowplaying_update(
    title: [*c]const u8,
    artist: [*c]const u8,
    duration_s: f64,
    position_s: f64,
    rate: f64,
) void;
extern fn opal_nowplaying_clear() void;

var inited: bool = false; // remote-command handlers registered
var np_active: bool = false; // a Now Playing card is currently published
var frame_ctr: u32 = 0;
var last_paused: bool = true;

/// Per-frame tick from appFrame(): drain pending hardware media-key commands
/// onto the active player, then refresh the system Now Playing card
/// (immediately on play/pause flips, ~1s cadence otherwise).
pub fn frameTick() void {
    if (!enabled) return;
    pollCommands();
    updateNowPlaying();
}

/// App shutdown (appDeinit) / explicit teardown: drop the Now Playing card.
/// Player-close is handled by frameTick noticing there is no active player.
pub fn clear() void {
    if (!enabled) return;
    clearIfActive();
}

fn clearIfActive() void {
    if (!np_active) return;
    np_active = false;
    opal_nowplaying_clear();
}

fn pollCommands() void {
    // Drain a bounded number per frame so a wedged queue can't stall a frame.
    var budget: u8 = 8;
    while (budget > 0) : (budget -= 1) {
        var arg: f64 = 0;
        const cmd = pure.decode(opal_media_remote_poll(&arg));
        if (cmd == .none) return; // queue empty (or garbage code — dropped)

        // Guard the active-player index (players can close between frames);
        // still consume the command so it doesn't fire on a future player.
        if (state.app.active_player_idx >= state.app.players.items.len) continue;
        const p = state.app.players.items[state.app.active_player_idx];

        switch (cmd) {
            .none => unreachable,
            .play => _ = c.mpv.mpv_set_property_string(p.mpv_ctx, "pause", "no"),
            .pause => _ = c.mpv.mpv_set_property_string(p.mpv_ctx, "pause", "yes"),
            .toggle => p.togglePause(),
            .seek_absolute => {
                var dur: f64 = 0;
                _ = c.mpv.mpv_get_property(p.mpv_ctx, "duration", c.mpv.MPV_FORMAT_DOUBLE, &dur);
                const target = pure.clampSeekTarget(arg, dur);
                var buf: [64]u8 = undefined;
                const seek_cmd = std.fmt.bufPrintZ(&buf, "seek {d:.2} absolute", .{target}) catch continue;
                _ = c.mpv.mpv_command_string(p.mpv_ctx, seek_cmd.ptr);
            },
            .seek_relative => {
                if (std.math.isNan(arg)) continue;
                var buf: [64]u8 = undefined;
                const seek_cmd = std.fmt.bufPrintZ(&buf, "seek {d:.1}", .{arg}) catch continue;
                _ = c.mpv.mpv_command_string(p.mpv_ctx, seek_cmd.ptr);
            },
        }
    }
}

fn updateNowPlaying() void {
    frame_ctr +%= 1;

    if (state.app.active_player_idx >= state.app.players.items.len) {
        clearIfActive();
        return;
    }
    const p = state.app.players.items[state.app.active_player_idx];
    if (p.current_url_len == 0) {
        clearIfActive();
        return;
    }

    // Push cadence: play/pause flips push immediately (cached_paused is the
    // event-loop mirror of mpv "pause" — free to read); otherwise ~1s keeps
    // the elapsed time honest across seeks (position uses the mirrored
    // last_seen_pos — no per-frame mpv IPC on this path).
    const paused = p.cached_paused;
    const throttle_hit = frame_ctr % 60 == 0;
    const pause_flip = np_active and paused != last_paused;
    if (!throttle_hit and !pause_flip) return;

    var title_buf: [257]u8 = undefined;
    const tlen = p.getMediaTitle(title_buf[0..256]);
    if (tlen == 0) return; // nothing named yet — don't publish an empty card
    title_buf[tlen] = 0;

    // Podcast episode / radio station subtitle doubles as the artist line.
    var artist_buf: [193]u8 = undefined;
    const alen = @min(p.np_subtitle_len, 192);
    @memcpy(artist_buf[0..alen], p.np_subtitle[0..alen]);
    artist_buf[alen] = 0;

    var dur: f64 = 0;
    _ = c.mpv.mpv_get_property(p.mpv_ctx, "duration", c.mpv.MPV_FORMAT_DOUBLE, &dur);

    // Register the media-key handlers only once real playback exists — macOS
    // routes media keys to us from the first playbackState set, and an app
    // with nothing playing shouldn't sit in the media-key routing chain.
    if (!inited) {
        inited = true;
        opal_media_remote_init();
        logs.pushLog("info", "macos", "Now Playing + media keys active", false);
    }
    opal_nowplaying_update(&title_buf, &artist_buf, dur, p.last_seen_pos, pure.playbackRate(paused));
    np_active = true;
    last_paused = paused;
}
