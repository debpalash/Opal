//! Now Playing projection for the web companion.
//!
//! The player owns many transient fields; this module turns one mutex-protected
//! snapshot into a stable, bounded JSON contract. Artwork source URLs remain
//! server-side because Plex/Jellyfin URLs can contain credentials.

const std = @import("std");
const state = @import("../core/state.zig");
const c = @import("../core/c.zig");
const io_g = @import("../core/io_global.zig");
const txt = @import("../core/text.zig");
const wire = @import("remote_http.zig");

/// Caller must hold `state.players_mutex` for the complete call.
pub fn build(buf: []u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    const party = @import("watch_party.zig");
    const casting = @import("cast.zig").is_casting.load(.acquire);
    const party_role = party.role;
    const party_peers = party.peerCount();
    if (state.app.active_player_idx >= state.app.players.items.len) {
        w.print("{{\"active\":false,\"pos\":0,\"dur\":0,\"vol\":0,\"paused\":true,\"loading\":false,\"buffering\":false,\"recovering\":false,\"title\":\"No media\",\"subtitle\":\"\",\"overview\":\"\",\"kind\":\"\",\"year\":\"\",\"extra\":\"\",\"rating\":0,\"source\":\"\",\"has_art\":false,\"art_key\":\"\",\"casting\":{s},\"party_role\":\"{s}\",\"party_peers\":{d}}}", .{
            if (casting) "true" else "false",
            @tagName(party_role),
            party_peers,
        }) catch return buf[0..0];
        return buf[0..w.end];
    }

    const player = state.app.players.items[state.app.active_player_idx];
    const playback = player.playbackSnapshot();
    var title_prop: [*c]u8 = null;
    _ = c.mpv.mpv_get_property(player.mpv_ctx, "media-title", c.mpv.MPV_FORMAT_STRING, @ptrCast(&title_prop));
    defer if (title_prop != null) c.mpv.mpv_free(@ptrCast(title_prop));
    const mpv_title = if (title_prop != null) std.mem.span(title_prop) else "No media";

    var title_copy: [512]u8 = undefined;
    const title_source = if (player.np_title_len > 0)
        player.np_title[0..@min(player.np_title_len, player.np_title.len)]
    else if (player.loading_title_len > 0)
        player.loading_title[0..@min(player.loading_title_len, player.loading_title.len)]
    else
        mpv_title;
    const title = txt.safeUtf8Buf(title_source, &title_copy);
    var subtitle_copy: [192]u8 = undefined;
    const subtitle = txt.safeUtf8Buf(player.np_subtitle[0..@min(player.np_subtitle_len, player.np_subtitle.len)], &subtitle_copy);
    var overview_copy: [400]u8 = undefined;
    const overview = txt.safeUtf8Buf(player.loading_overview[0..@min(player.loading_overview_len, player.loading_overview.len)], &overview_copy);
    var year_copy: [8]u8 = undefined;
    const year = txt.safeUtf8Buf(player.loading_year[0..@min(player.loading_year_len, player.loading_year.len)], &year_copy);
    var extra_copy: [96]u8 = undefined;
    const extra = txt.safeUtf8Buf(player.loading_extra[0..@min(player.loading_extra_len, player.loading_extra.len)], &extra_copy);

    const art_source = if (player.np_art_url_len > 0)
        player.np_art_url[0..@min(player.np_art_url_len, player.np_art_url.len)]
    else
        player.loading_art[0..@min(player.loading_art_len, player.loading_art.len)];
    const art_key = if (art_source.len > 0) std.hash.Wyhash.hash(0, art_source) else 0;
    const has_context = player.loading_title_len > 0 or player.loading_art_len > 0 or player.loading_overview_len > 0;
    const kind = if (has_context)
        @tagName(@import("../ui/loading_pure.zig").MediaKind.fromInt(player.loading_kind))
    else
        "";

    const now = io_g.milliTimestamp();
    const recovering = player.last_error_time > 0 and now >= player.last_error_time and now - player.last_error_time <= 5000;
    const loading = player.is_loading or (player.is_torrent and !player.torrent_is_ready);
    const buffering = playback.paused_for_cache or player.is_buffering_paused;
    const active = player.current_url_len > 0 or loading or !std.mem.eql(u8, title, "No media");
    const raw_rating: f64 = @floatCast(player.loading_rating);
    const rating = std.math.clamp(finite(raw_rating, 0), 0, 10);

    w.print("{{\"active\":{s},\"pos\":{d:.1},\"dur\":{d:.1},\"vol\":{d:.0},\"paused\":{s},\"loading\":{s},\"buffering\":{s},\"recovering\":{s},\"title\":\"", .{
        if (active) "true" else "false",
        @max(0, finite(playback.time_pos, 0)),
        @max(0, finite(playback.duration, 0)),
        @max(0, finite(playback.volume, 0)),
        if (playback.paused) "true" else "false",
        if (loading) "true" else "false",
        if (buffering) "true" else "false",
        if (recovering) "true" else "false",
    }) catch return buf[0..0];
    wire.writeJsonString(&w, title);
    w.writeAll("\",\"subtitle\":\"") catch return buf[0..0];
    wire.writeJsonString(&w, subtitle);
    w.writeAll("\",\"overview\":\"") catch return buf[0..0];
    wire.writeJsonString(&w, overview);
    w.writeAll("\",\"kind\":\"") catch return buf[0..0];
    wire.writeJsonString(&w, kind);
    w.writeAll("\",\"year\":\"") catch return buf[0..0];
    wire.writeJsonString(&w, year);
    w.writeAll("\",\"extra\":\"") catch return buf[0..0];
    wire.writeJsonString(&w, extra);
    w.print("\",\"rating\":{d:.1},\"source\":\"{s}\",\"has_art\":{s},\"art_key\":\"{x:0>16}\",\"casting\":{s},\"party_role\":\"{s}\",\"party_peers\":{d}}}", .{
        rating,
        if (player.is_torrent) "torrent" else "direct",
        if (art_source.len > 0) "true" else "false",
        art_key,
        if (casting) "true" else "false",
        @tagName(party_role),
        party_peers,
    }) catch return buf[0..0];
    return buf[0..w.end];
}

fn finite(value: f64, fallback: f64) f64 {
    return if (std.math.isNan(value) or std.math.isInf(value)) fallback else value;
}
