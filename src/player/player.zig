const std = @import("std");
const dvui = @import("dvui");
const c = @import("../core/c.zig");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const http_headers = @import("http_headers_pure.zig");
pub const HttpHeader = http_headers.HttpHeader;

/// True if a Firefox profile dir exists, so yt-dlp's --cookies-from-browser
/// firefox won't abort. Checked once and cached.
var ff_checked: bool = false;
var ff_exists: bool = false;
fn firefoxProfileExists() bool {
    if (ff_checked) return ff_exists;
    ff_checked = true;
    const io = @import("../core/io_global.zig");
    const home = io.getenv("HOME") orelse return false;
    var buf: [512]u8 = undefined;
    const macos = std.fmt.bufPrint(&buf, "{s}/Library/Application Support/Firefox/Profiles", .{home}) catch return false;
    if (io.cwdAccess(macos, .{})) {
        ff_exists = true;
        return true;
    } else |_| {}
    const linux = std.fmt.bufPrint(&buf, "{s}/.mozilla/firefox", .{home}) catch return false;
    if (io.cwdAccess(linux, .{})) {
        ff_exists = true;
        return true;
    } else |_| {}
    return false;
}

pub const video_w = 1920;
pub const video_h = 1080;

pub const MediaPlayer = struct {
    mpv_ctx: *c.mpv.mpv_handle,
    mpv_gl: ?*c.mpv.mpv_render_context,
    pixels: []dvui.Color.PMA,
    texture: ?dvui.Texture,
    current_torrent_id: i32,
    torrent_is_ready: bool,
    has_metadata: bool,
    last_load_time: i64,
    selected_file_idx: i32 = -1, // -1 means auto-select largest
    last_error_time: i64 = 0,
    is_buffering_paused: bool = false,
    is_loading: bool = false,
    loading_label: [128]u8 = std.mem.zeroes([128]u8),
    loading_label_len: usize = 0,
    thumb_texture: ?dvui.Texture = null,
    thumb_texture_path: [384]u8 = std.mem.zeroes([384]u8),
    thumb_texture_path_len: usize = 0,
    cell_volume: f64,
    cell_speed: f64,
    loop_a: f64, // A-B loop start (-1 = unset)
    loop_b: f64, // A-B loop end (-1 = unset)
    is_flipped: bool,
    rotation: i32, // 0, 90, 180, 270
    source_url: [2048]u8,
    source_url_len: usize,
    is_torrent: bool,
    metadata_start_time: i64,
    resume_percent: f64 = 0.0,
    resume_position_secs: f64 = 0.0, // exact-second resume (wins over percent)
    current_url: [2048]u8 = std.mem.zeroes([2048]u8),
    current_url_len: usize = 0,
    resume_seeked: bool = false,
    save_counter: u32 = 0, // periodic save every N frames
    provider: state.ContentProvider = .mpv,

    // ── Cached mpv properties (A4) ──
    // Populated via mpv_observe_property + MPV_EVENT_PROPERTY_CHANGE in the
    // event loop (see updateTorrentBackgroundTasks) so the per-frame render
    // path doesn't issue synchronous IPC (or per-frame allocations) for these.
    cached_paused: bool = true, // mirror of mpv "pause"
    last_seen_pos: f64 = 0, // last valid mpv time-pos seen in the event loop (co-watch rewind detect)
    // True only when this player is playing ANIME-sourced media (armed by the
    // anime play flow via services/anime_skip.zig). Gates auto-skip so we
    // don't apply crowdsourced anime timestamps to arbitrary files.
    anime_skip_active: bool = false,
    cached_vid_no: bool = false, // mpv "vid" == "no" (audio-only)
    /// The audio visualiser is applied once per loaded file. Without this latch the
    /// graph would be re-set on every "vid" event it itself provokes.
    vis_applied: bool = false,
    cached_sub_text: [1024]u8 = std.mem.zeroes([1024]u8),
    cached_sub_text_len: usize = 0,

    // ── Rolling dialogue ring (T3) ──
    // Fixed-size, no allocations. Stores the most recent subtitle lines with
    // their mpv time-pos timestamps so the AI can be handed ~60s of context.
    // Appended from the "sub-text" property handler; deduped against the last
    // appended line via a Wyhash so repeated/held subtitles aren't duplicated.
    dialogue_lines: [24][256]u8 = std.mem.zeroes([24][256]u8),
    dialogue_line_lens: [24]usize = std.mem.zeroes([24]usize),
    dialogue_line_ts: [24]f64 = std.mem.zeroes([24]f64),
    dialogue_head: usize = 0, // index of next slot to write
    dialogue_count: usize = 0, // number of valid stored lines (<= 24)
    dialogue_last_hash: u64 = 0, // hash of last appended line (dedup)

    // v2: handle to the per-player torrent HTTP proxy stream (multi-tenant).
    // INVALID_HANDLE means no proxy is currently running for this player.
    proxy_handle: @import("stream_proxy.zig").Handle = @import("stream_proxy.zig").INVALID_HANDLE,

    // ── Loading-screen context (poster + trivia while a torrent buffers) ──
    // Populated from state.app.pending_play_* by addMagnetToEngine when a
    // TMDB-linked play (movie or TV episode) kicks off. Empty len == no
    // context (e.g. a raw magnet paste) — the loading overlay falls back to
    // the plain hourglass + path text it always showed.
    loading_title: [128]u8 = std.mem.zeroes([128]u8),
    loading_title_len: usize = 0,
    loading_poster_path: [64]u8 = std.mem.zeroes([64]u8),
    loading_poster_path_len: usize = 0,
    loading_overview: [400]u8 = std.mem.zeroes([400]u8),
    loading_overview_len: usize = 0,
    loading_is_tv: bool = false,
    loading_meta_fetch_started: bool = false,
    loading_poster_fetching: bool = false,
    loading_poster_pixels: ?[]u8 = null,
    loading_poster_w: u32 = 0,
    loading_poster_h: u32 = 0,
    loading_poster_tex: ?dvui.Texture = null,
    loading_trivia: [400]u8 = std.mem.zeroes([400]u8),
    loading_trivia_len: usize = 0,
    loading_trivia_fetching: bool = false,

    // ── Now-playing audio metadata (podcast episode / radio station) ──
    // Set via setNowPlaying on the meta play path (browser.loadContentDirectMeta)
    // so the player pane + footer show cover art + a rich title/subtitle instead
    // of a black pane + bare stream URL. Cleared on any plain load (load_file)
    // so stale audio art never lingers over a later video. Fixed-size buffers,
    // no allocation churn. The cover art mirrors the shared poster lifecycle:
    // async fetch into np_art_pixels (c_allocator) → uploadIfReady → np_art_tex.
    np_art_url: [512]u8 = std.mem.zeroes([512]u8),
    np_art_url_len: usize = 0,
    np_title: [256]u8 = std.mem.zeroes([256]u8),
    np_title_len: usize = 0,
    np_subtitle: [192]u8 = std.mem.zeroes([192]u8),
    np_subtitle_len: usize = 0,
    np_art_pixels: ?[]u8 = null,
    np_art_w: u32 = 0,
    np_art_h: u32 = 0,
    np_art_tex: ?dvui.Texture = null,
    np_art_fetching: bool = false,
    // FNV-1a of the art URL currently owning np_art_tex/pixels. When a new item
    // is set while a prior fetch is still in flight, the render path uses this to
    // free the stale texture and re-fetch the correct art once the worker lands
    // (same leak-free swap the podcasts cover slots use).
    np_art_url_hash: u64 = 0,

    /// Set (or clear, with empty args) the now-playing audio metadata + cover
    /// art. UI-thread only. Copies the strings in (clamped) and releases any
    /// prior art — but only when no fetch is mid-flight for this slot: freeing
    /// while a detached poster worker still owns the slot would orphan the slice
    /// it is about to write. When a fetch IS in flight the strings still update
    /// and the render path's url-hash guard swaps to the new art once that worker
    /// lands, so nothing leaks and the wrong art never sticks.
    pub fn setNowPlaying(self: *MediaPlayer, art_url: []const u8, title: []const u8, subtitle: []const u8) void {
        if (!self.np_art_fetching) {
            @import("../core/poster.zig").deinitPoster(&self.np_art_pixels, &self.np_art_tex);
            self.np_art_w = 0;
            self.np_art_h = 0;
        }
        const ulen = @min(art_url.len, self.np_art_url.len);
        @memcpy(self.np_art_url[0..ulen], art_url[0..ulen]);
        self.np_art_url_len = ulen;
        const tlen = @min(title.len, self.np_title.len);
        @memcpy(self.np_title[0..tlen], title[0..tlen]);
        self.np_title_len = tlen;
        const slen = @min(subtitle.len, self.np_subtitle.len);
        @memcpy(self.np_subtitle[0..slen], subtitle[0..slen]);
        self.np_subtitle_len = slen;
    }

    /// Advance the now-playing cover-art fetch/upload state machine one frame.
    /// Idempotent and UI-thread only, so every render site that shows the art
    /// (the player pane AND the footer bar) can call it each frame — whichever
    /// runs first arms the async fetch; the rest just observe. The URL-hash
    /// guard gives a leak-free swap when the item changes while a prior fetch is
    /// still in flight (mirrors the podcast cover slots). No-op when no art URL.
    pub fn tickNowPlayingArt(self: *MediaPlayer) void {
        if (self.np_art_url_len == 0) return;
        const poster = @import("../core/poster.zig");
        const art = self.np_art_url[0..self.np_art_url_len];
        const h = std.hash.Fnv1a_64.hash(art);
        if (self.np_art_url_hash != h and !self.np_art_fetching) {
            poster.deinitPoster(&self.np_art_pixels, &self.np_art_tex);
            self.np_art_w = 0;
            self.np_art_h = 0;
            self.np_art_url_hash = h;
        }
        _ = poster.uploadIfReady(&self.np_art_pixels, self.np_art_w, self.np_art_h, &self.np_art_tex);
        if (self.np_art_tex == null and !self.np_art_fetching and self.np_art_pixels == null)
            poster.fetchAsync(art, &self.np_art_pixels, &self.np_art_w, &self.np_art_h, &self.np_art_fetching);
    }

    pub fn getMediaTitle(self: *MediaPlayer, out_buf: []u8) usize {
        // 1. If torrent, get torrent name
        if (self.current_torrent_id >= 0) {
            var t_name: [256]u8 = undefined;
            c.mpv.torrent_get_name(state.torrentSession(), self.current_torrent_id, &t_name, 256);
            const tn_len = std.mem.indexOfScalar(u8, &t_name, 0) orelse 0;
            if (tn_len > 0) {
                const limit = @min(tn_len, out_buf.len);
                @memcpy(out_buf[0..limit], t_name[0..limit]);
                return limit;
            }
        }

        // 2. Try reading mpv "media-title"
        const title_c = c.mpv.mpv_get_property_string(self.mpv_ctx, "media-title");
        if (title_c != null) {
            defer c.mpv.mpv_free(@ptrCast(title_c));
            const ts = std.mem.span(title_c);
            if (ts.len > 0 and !std.mem.eql(u8, ts, "No file") and
                !std.mem.eql(u8, ts, "stream") and !std.mem.eql(u8, ts, "mpv") and ts.len > 1)
            {
                const limit = @min(ts.len, out_buf.len);
                @memcpy(out_buf[0..limit], ts[0..limit]);
                return limit;
            }
        }

        // 4. Try current_url basename
        if (self.current_url_len > 0) {
            const url = self.current_url[0..self.current_url_len];
            const base_end = std.mem.indexOfScalar(u8, url, '?') orelse url.len;
            const path = url[0..base_end];
            const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx|
                (if (idx + 1 < path.len) path[idx + 1 ..] else path)
            else
                path;

            if (basename.len > 0 and !std.mem.eql(u8, basename, "stream") and basename.len > 1) {
                const limit = @min(basename.len, out_buf.len);
                @memcpy(out_buf[0..limit], basename[0..limit]);
                return limit;
            }
        }
        return 0;
    }

    /// Append a subtitle line to the rolling dialogue ring (T3). No allocations.
    /// Only appends when `sub_text` is non-empty AND its hash differs from the
    /// last appended line (dedup of held/repeated subtitles).
    pub fn updateDialogueRing(self: *MediaPlayer, sub_text: []const u8, time_pos: f64) void {
        if (sub_text.len == 0) return;
        const h = std.hash.Wyhash.hash(0, sub_text);
        if (self.dialogue_count > 0 and h == self.dialogue_last_hash) return;

        const slot = self.dialogue_head;
        const n = @min(sub_text.len, self.dialogue_lines[slot].len);
        @memcpy(self.dialogue_lines[slot][0..n], sub_text[0..n]);
        self.dialogue_line_lens[slot] = n;
        self.dialogue_line_ts[slot] = time_pos;

        self.dialogue_head = (slot + 1) % self.dialogue_lines.len;
        if (self.dialogue_count < self.dialogue_lines.len) self.dialogue_count += 1;
        self.dialogue_last_hash = h;
    }

    /// Emit stored dialogue lines whose timestamp is within ~60s of the newest
    /// stored timestamp, oldest->newest, one per line, into `out_buf`. Returns
    /// bytes written (0 if none). No allocations.
    pub fn getRecentDialogue(self: *MediaPlayer, out_buf: []u8) usize {
        if (self.dialogue_count == 0 or out_buf.len == 0) return 0;

        // Newest line is the one just before head (in ring order).
        const ring = self.dialogue_lines.len;
        const newest_idx = (self.dialogue_head + ring - 1) % ring;
        const newest_ts = self.dialogue_line_ts[newest_idx];

        // Oldest valid line in chronological order.
        const start = (self.dialogue_head + ring - self.dialogue_count) % ring;

        var written: usize = 0;
        var i: usize = 0;
        while (i < self.dialogue_count) : (i += 1) {
            const idx = (start + i) % ring;
            const ts = self.dialogue_line_ts[idx];
            // Within ~60s window of newest. Tolerate small backward seeks.
            if (newest_ts - ts > 60.0) continue;

            const ln = self.dialogue_line_lens[idx];
            if (ln == 0) continue;
            if (written >= out_buf.len) break;

            const avail = out_buf.len - written;
            const copy_len = @min(ln, avail);
            @memcpy(out_buf[written .. written + copy_len], self.dialogue_lines[idx][0..copy_len]);
            written += copy_len;
            if (copy_len < ln) break; // out of space mid-line

            // Newline separator (skip after the final emitted line).
            if (i + 1 < self.dialogue_count and written < out_buf.len) {
                out_buf[written] = '\n';
                written += 1;
            }
        }
        return written;
    }

    pub fn init(allocator: std.mem.Allocator) !*MediaPlayer {
        const self = try allocator.create(MediaPlayer);
        self.texture = null;
        self.current_torrent_id = -1;
        self.torrent_is_ready = false;
        self.has_metadata = false;
        self.last_load_time = 0;
        self.last_error_time = 0;
        self.is_buffering_paused = false;
        self.selected_file_idx = -1;
        self.cell_volume = 100.0;
        self.cell_speed = 1.0;
        self.loop_a = -1.0;
        self.loop_b = -1.0;
        self.is_flipped = false;
        self.rotation = 0;
        self.source_url_len = 0;
        self.is_torrent = false;
        self.metadata_start_time = 0;
        self.resume_percent = 0.0;
        self.resume_position_secs = 0.0;
        @memset(&self.source_url, 0);
        @memset(&self.current_url, 0);
        self.current_url_len = 0;
        self.resume_seeked = false;
        self.save_counter = 0;
        self.is_loading = false;
        self.loading_label_len = 0;
        self.provider = .mpv;
        self.thumb_texture = null;
        @memset(&self.thumb_texture_path, 0);
        self.thumb_texture_path_len = 0;

        // `allocator.create` hands back undefined memory and this init assigns
        // fields one-by-one, so the struct-declaration DEFAULTS are never
        // applied. These were missed and read garbage (0xaa under the debug
        // allocator): a garbage `dialogue_head`/`dialogue_count` drove an
        // out-of-bounds in updateDialogueRing (crash on the first subtitle), and
        // a garbage `cached_sub_text_len` risks an OOB / invalid-UTF-8 dvui panic
        // when the sub-text mirror is drawn. Initialize them to their defaults.
        self.cached_paused = true;
        self.last_seen_pos = 0;
        self.anime_skip_active = false;
        self.cached_vid_no = false;
        self.vis_applied = false;
        @memset(&self.cached_sub_text, 0);
        self.cached_sub_text_len = 0;
        @memset(&self.loading_label, 0);
        self.loading_title_len = 0;
        @memset(&self.loading_title, 0);
        self.loading_poster_path_len = 0;
        @memset(&self.loading_poster_path, 0);
        self.loading_overview_len = 0;
        @memset(&self.loading_overview, 0);
        self.loading_is_tv = false;
        self.loading_meta_fetch_started = false;
        self.loading_poster_fetching = false;
        self.loading_poster_pixels = null;
        self.loading_poster_w = 0;
        self.loading_poster_h = 0;
        self.loading_poster_tex = null;
        self.loading_trivia_len = 0;
        @memset(&self.loading_trivia, 0);
        self.loading_trivia_fetching = false;
        @memset(&self.np_art_url, 0);
        self.np_art_url_len = 0;
        @memset(&self.np_title, 0);
        self.np_title_len = 0;
        @memset(&self.np_subtitle, 0);
        self.np_subtitle_len = 0;
        self.np_art_pixels = null;
        self.np_art_w = 0;
        self.np_art_h = 0;
        self.np_art_tex = null;
        self.np_art_fetching = false;
        self.np_art_url_hash = 0;
        @memset(std.mem.asBytes(&self.dialogue_lines), 0);
        @memset(&self.dialogue_line_lens, 0);
        @memset(&self.dialogue_line_ts, 0);
        self.dialogue_head = 0;
        self.dialogue_count = 0;
        self.dialogue_last_hash = 0;
        self.proxy_handle = @import("stream_proxy.zig").INVALID_HANDLE;

        if (state.app.is_headless) {
            // Headless: no display surface, so no software-render pixel buffer.
            // Empty slice — deinit's allocator.free on a zero-len slice is a no-op.
            self.pixels = &.{};
        } else {
            self.pixels = try allocator.alloc(dvui.Color.PMA, video_w * video_h);
            @memset(self.pixels, dvui.Color.PMA.black);
        }

        self.mpv_ctx = c.mpv.mpv_create() orelse {
            // mpv handle creation failed (OOM / broken mpv install). Don't abort
            // the whole process — surface it and fail player creation cleanly so
            // no half-initialized player is ever added to state.app.players. All
            // runtime call sites use `if (init(...)) |p| … else |_|` and skip
            // adding the player on error; the startup call site (`try` in
            // main.zig) turns this into a clean error exit instead of a panic.
            logs.pushLog("error", "player", "mpv handle creation failed (out of memory or broken mpv install) — playback unavailable", true);
            state.showToast("Playback engine unavailable — check your mpv install");
            // self.pixels was allocated just above (empty slice when headless);
            // free it and the struct so this failed init leaks nothing.
            allocator.free(self.pixels);
            allocator.destroy(self);
            return error.MpvCreateFailed;
        };
        const hw_val = if (state.app.hwdec_enabled) "auto-safe" else "no";
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "hwdec", hw_val);
        // Headless: use the null video output so libmpv never opens a display
        // surface. Audio + property events + seek all still work for control.
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "vo", if (state.app.is_headless) "null" else "libmpv");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "audio-display", "attachment");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "osc", "no");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "osd-bar", "no");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "osd-level", "0");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "script-opts", "osc-visibility=auto");
        // Opal draws all chrome itself — mpv's built-in Lua helpers (console,
        // select, positioning, commands, context-menu, stats overlay) each
        // spin up a Lua VM + thread PER PLAYER for UI we never show. CPU
        // samples put 7 idle Lua threads per mpv instance; drop them. NOTE:
        // ytdl_hook must stay (it resolves YouTube/streaming URLs), so we
        // disable the individual scripts rather than load-scripts=no.
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "load-osd-console", "no");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "load-select", "no");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "load-positioning", "no");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "load-commands", "no");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "load-context-menu", "no");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "load-stats-overlay", "no");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "load-auto-profiles", "no");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "input-cursor", "yes");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "msg-level", "all=status");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "terminal", "yes");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "clipboard-backends", "");

        // Streaming-optimized: large demuxer cache for torrent + network tolerance
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "cache", "yes");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "cache-secs", "120");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "demuxer-max-bytes", "300MiB");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "demuxer-readahead-secs", "60");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "demuxer-max-back-bytes", "100MiB");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "force-seekable", "yes");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "hr-seek", "yes");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "keep-open", "always");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "loop-file", "inf");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "demuxer-seekable-cache", "yes");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "idle", "yes");

        // ── Network stream resilience ──
        // With HTTP proxy for torrents, cache-pause works correctly:
        // the proxy stalls HTTP when pieces aren't ready, mpv shows "Buffering..."
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "cache-pause", "yes");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "cache-pause-initial", "yes");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "cache-pause-wait", "3");
        // Network timeouts — retry aggressively instead of giving up
        // 0 = never time out a network read.
        //
        // This is load-bearing for torrent streaming. ffmpeg cannot distinguish a
        // read ERROR from end-of-file (demux_lavf.c returns AVERROR_EOF for both),
        // so a 30s timeout on a slow torrent read reached mpv as "the file ended" —
        // it stopped cleanly, with no error, and no amount of further downloading
        // brought it back. Blocking on a slow stream is fine and expected; timing
        // out is fatal.
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "network-timeout", "0");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_delay_max=5,reconnect_on_network_error=1,reconnect_on_http_error=4xx,reconnect_on_http_error=5xx");
        // HLS-specific: tolerate errors and start further behind live edge to build a huge preload buffer
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "hls-bitrate", "max");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "demuxer-lavf-o", "live_start_index=-10");
        // Increase low-level read buffer for choppy networks
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "stream-buffer-size", "8MiB");

        // ── Premium quality defaults (natural-harmonia-gropius reference) ──
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "deinterlace", "auto");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "deband", if (state.app.deband_enabled) "yes" else "no");
        const scaler_vals = [_][*:0]const u8{ "ewa_lanczossharp", "bilinear", "spline36" };
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "scale", scaler_vals[state.app.video_scaler]);
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "scale-antiring", "0.6");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "cscale", "ewa_lanczos");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "dscale", "hermite");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "volume-max", "100");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "audio-file-auto", "fuzzy");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "sub-auto", "fuzzy");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "sub-font-size", "40");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "save-position-on-quit", "yes");

        _ = c.mpv.mpv_request_log_messages(self.mpv_ctx, "warn");
        self.applyYtdlFormat();

        // ── Replay persisted audio EQ + video color filters ──
        // These were previously applied only when the user clicked in Settings,
        // so they silently reset on restart / for newly-opened files. Set them
        // as options here (same before-init replay site as deband/scaler above),
        // routed through the shared av_pure mapping so they can't drift from the
        // Settings click sites.
        {
            const av_pure = @import("av_pure.zig");
            _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "af", av_pure.eqFilterSpec(state.app.eq_preset).ptr);
            const vfs = [_]struct { prop: [*:0]const u8, val: i32 }{
                .{ .prop = "brightness", .val = state.app.vf_brightness },
                .{ .prop = "contrast", .val = state.app.vf_contrast },
                .{ .prop = "saturation", .val = state.app.vf_saturation },
                .{ .prop = "gamma", .val = state.app.vf_gamma },
            };
            var vf_buf: [16]u8 = undefined;
            for (vfs) |vf| {
                if (std.fmt.bufPrintZ(&vf_buf, "{d}", .{av_pure.clampVideoFilter(vf.val)})) |s| {
                    _ = c.mpv.mpv_set_option_string(self.mpv_ctx, vf.prop, s.ptr);
                } else |_| {}
            }
        }

        // Scan scripts before init (but loading happens after)
        const scripts_mgr = @import("../services/scripts.zig");
        if (!state.app.scripts_scanned) scripts_mgr.scanScripts();

        _ = c.mpv.mpv_initialize(self.mpv_ctx);

        // ── Observe properties so the render hot path can read cached fields
        // instead of issuing synchronous mpv_get_property IPC every frame (A4).
        // Updates arrive as MPV_EVENT_PROPERTY_CHANGE in the event loop.
        _ = c.mpv.mpv_observe_property(self.mpv_ctx, 0, "pause", c.mpv.MPV_FORMAT_FLAG);
        _ = c.mpv.mpv_observe_property(self.mpv_ctx, 0, "vid", c.mpv.MPV_FORMAT_STRING);
        _ = c.mpv.mpv_observe_property(self.mpv_ctx, 0, "sub-text", c.mpv.MPV_FORMAT_STRING);
        // time-pos drives co-watch rewind detection even during silent stretches
        // (no subtitle change). Value arrives in the event payload — no per-frame IPC.
        _ = c.mpv.mpv_observe_property(self.mpv_ctx, 0, "time-pos", c.mpv.MPV_FORMAT_DOUBLE);

        // Load enabled user scripts individually (must happen after mpv_initialize)
        for (0..state.app.script_count) |si| {
            if (!state.app.script_enabled[si]) continue;
            const path = state.app.script_paths[si][0..state.app.script_path_lens[si]];
            if (path.len == 0) continue;
            var path_z: [513]u8 = undefined;
            const pz = std.fmt.bufPrintZ(&path_z, "{s}", .{path}) catch continue;
            var args = [_][*c]const u8{ "load-script", pz.ptr, null };
            _ = c.mpv.mpv_command(self.mpv_ctx, @ptrCast(&args));
        }

        var params = [_]c.mpv.mpv_render_param{
            .{ .type = c.mpv.MPV_RENDER_PARAM_API_TYPE, .data = @constCast(c.mpv.MPV_RENDER_API_TYPE_SW) },
            .{ .type = c.mpv.MPV_RENDER_PARAM_INVALID, .data = null },
        };
        self.mpv_gl = null;
        if (!state.app.is_headless) {
            // Windowed: create the software render context and wire the
            // frame-ready callback. Headless leaves mpv_gl == null (vo=null,
            // no pixel buffer) — the render path is skipped entirely there.
            if (c.mpv.mpv_render_context_create(&self.mpv_gl, self.mpv_ctx, &params) < 0) {
                // Render-context creation failed (rare — driver/OOM). Don't abort
                // the whole app: leave mpv_gl == null and degrade to the same
                // no-video path the headless build already runs safely (audio +
                // controls still work; the render/texture path is null-mpv_gl-safe).
                self.mpv_gl = null;
                logs.pushLog("error", "player", "mpv render-context creation failed — video disabled for this player (audio still works)", true);
                return self;
            }
            // Wake the UI loop whenever mpv has a new frame ready. Without
            // this, dvui sleeps on input idle (no mouse movement) and the
            // texture freezes even though audio keeps playing because the
            // pixel-buffer transfer in ui/grid.zig only happens inside a
            // dvui frame. The callback fires on an mpv-owned thread, so we
            // use the cross-thread form of dvui.refresh (passing *Window).
            c.mpv.mpv_render_context_set_update_callback(self.mpv_gl, &mpvRenderUpdateCallback, null);
        }
        return self;
    }

    pub fn load_file(self: *MediaPlayer, path: [*c]const u8) void {
        // Guard the mpv boundary. Every play path funnels through here, and
        // mpv does two hostile things with junk input: loadfile("") logs a
        // "Cannot open file ''" error, and loadfile(<directory>) expands the
        // directory into a recursive playlist walk of the entire tree (saw it
        // march through ~/Desktop/github trying every .sol/.ts file). Reject
        // both before touching player state.
        const guard_span = std.mem.span(path);
        if (!@import("resume_pure.zig").plausibleMediaPath(guard_span)) {
            @import("../core/logs.zig").pushLog("warn", "player", "Ignored empty media path", true);
            return;
        }
        if (guard_span[0] == '/') {
            const io_g = @import("../core/io_global.zig");
            if (io_g.cwdStatFile(guard_span)) |st| {
                if (st.kind == .directory) {
                    @import("../core/logs.zig").pushLog("warn", "player", "Folders can't be played directly - open a media file inside", true);
                    state.showToast("That's a folder - pick a media file inside it");
                    return;
                }
            } else |_| {}
        }

        // Save position of current video before switching
        self.saveCurrentPosition();

        @memset(self.pixels, dvui.Color.PMA.black);
        if (self.texture) |*tex| {
            // Slice to the TEXTURE's size, not the whole pixel buffer.
            //
            // `pixels` is allocated once at video_w * video_h, but the texture is
            // created in grid.zig at the current RENDER size (rw x rh), which is a
            // different number. dvui's Texture.update hard-@panics on a length
            // mismatch — it is not a catchable error, so the `catch {}` here was
            // decoration. Loading a second file while a texture was alive (a
            // playlist advance, or the buffering reload below) crashed the process:
            //   "Texture size and supplied Content did not match"
            const npix = @as(usize, tex.width) * @as(usize, tex.height);
            if (npix > 0 and npix <= self.pixels.len) {
                _ = dvui.Texture.update(tex, self.pixels[0..npix], .linear) catch {};
            }
        }
        // Set loading state for UI feedback
        self.is_loading = true;
        const path_span = std.mem.span(path);
        const copy_len = @min(path_span.len, self.loading_label.len);
        @memcpy(self.loading_label[0..copy_len], path_span[0..copy_len]);
        self.loading_label_len = copy_len;

        // Store current URL for resume tracking
        @memcpy(self.current_url[0..copy_len], path_span[0..copy_len]);
        self.current_url_len = copy_len;
        self.resume_seeked = false;

        // Anime-Skip: consume a one-shot arm from the anime play flow. Every
        // load starts non-anime; the anime episode load flow arms just before
        // this runs, so THIS load claims it. Non-anime loads clear stale
        // segments so a prior episode's markers can't leak onto other media.
        @import("../services/anime_skip.zig").onFileLoad(self);

        // Clear any prior now-playing audio art/metadata — a fresh load that
        // isn't routed through the meta play path (video, torrent, resume) must
        // not inherit the previous podcast/radio cover. loadContentDirectMeta
        // calls setNowPlaying AGAIN right after this, re-populating it.
        self.setNowPlaying("", "", "");

        // ── Streamlink: resolve live stream URLs asynchronously ──
        const streamlink = @import("../services/streamlink.zig");
        if (streamlink.isStreamlinkUrl(path_span)) {
            // Show "Resolving stream..." in loading label
            const resolving_msg = "Resolving live stream...";
            @memcpy(self.loading_label[0..resolving_msg.len], resolving_msg);
            self.loading_label_len = resolving_msg.len;
            // Get player index for async callback
            const p_idx: usize = for (state.app.players.items, 0..) |p, i| {
                if (p.mpv_ctx == self.mpv_ctx) break i;
            } else 0;
            streamlink.resolveStreamUrlAsync(path_span, p_idx);
            return; // Don't call mpv loadfile directly — the async thread will do it
        }

        // Clear any visualiser left over from the previous file BEFORE loading. The
        // graph maps [aid1] to both [ao] and [vo], so if it survived into a VIDEO
        // file it would replace the actual picture with a waveform. Re-armed by the
        // "vid" observer once we know the new file is audio-only.
        self.vis_applied = false;
        _ = c.mpv.mpv_set_property_string(self.mpv_ctx, "lavfi-complex", "");

        var args = [_][*c]const u8{ "loadfile", path, null };
        _ = c.mpv.mpv_command(self.mpv_ctx, @ptrCast(&args));

        // ── Memory hooks: record playback for cross-session intelligence ──
        {
            // Local taste engine: settles the previous item (abandon
            // detection) and logs the .play event (buffered, off-thread).
            @import("../services/activity.zig").onPlay(path_span);

            const ai_memory = @import("../services/ai_memory.zig");
            const title = path_span;
            // Ingest into vector memory
            ai_memory.ingestMemory("system", title, "media", title);
            // Learn time-of-day preference
            const ts = @import("../core/io_global.zig").timestamp();
            const hour_of_day: u32 = @intCast(@mod(@divTrunc(ts, 3600), 24));
            var hour_buf: [16]u8 = undefined;
            const hour_str = std.fmt.bufPrint(&hour_buf, "{d}:00", .{hour_of_day}) catch "unknown";
            ai_memory.learnPreference("active_hour", hour_str);
        }
    }

    /// Load a direct network stream with an explicit User-Agent and an arbitrary
    /// set of per-request HTTP headers (Referer, Origin, Cookie, …).
    ///
    /// This is the single code path behind every headers-aware load. Both mpv
    /// options persist on the ctx, so they are ALWAYS set here: the UA to the
    /// caller's value or a browser default (never left stale from a prior
    /// stream), and `http-header-fields` set-or-cleared so an unrelated later
    /// load isn't tagged with someone else's Referer/Cookie.
    ///
    /// Header joining/sanitizing lives in `http_headers_pure.buildHeaderFields`
    /// (mpv splits the option on `,`, so unsafe values are dropped there).
    pub fn loadStreamWithHttpHeaders(self: *MediaPlayer, url: []const u8, user_agent: []const u8, headers: []const HttpHeader) void {
        const default_ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
        var ua_buf: [512]u8 = undefined;
        if (std.fmt.bufPrintZ(&ua_buf, "{s}", .{if (user_agent.len > 0) user_agent else default_ua})) |ua| {
            _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "user-agent", ua.ptr);
        } else |_| {}

        var join_buf: [2048]u8 = undefined;
        const fields = http_headers.buildHeaderFields(headers, &join_buf);
        if (fields.len > 0) {
            var z_buf: [2049]u8 = undefined;
            @memcpy(z_buf[0..fields.len], fields);
            z_buf[fields.len] = 0;
            _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "http-header-fields", @ptrCast(&z_buf[0]));
        } else {
            _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "http-header-fields", "");
        }

        var url_buf: [2048]u8 = undefined;
        const url_z = std.fmt.bufPrintZ(&url_buf, "{s}", .{url}) catch return;
        self.load_file(url_z.ptr);
    }

    /// Load a direct network stream (m3u8/mp4) with an HTTP Referer header.
    ///
    /// Many anime hosts (StreamWish, DoodStream, MegaCloud…) 403 the CDN request
    /// unless the embed-page Referer is sent. Thin wrapper over
    /// `loadStreamWithHttpHeaders` — an empty referer clears the option.
    /// Note: this now also pins the UA to the browser default rather than
    /// inheriting whatever a previously-played IPTV channel left on the ctx.
    pub fn loadStreamWithHeaders(self: *MediaPlayer, url: []const u8, referer: []const u8) void {
        self.loadStreamWithHttp(url, "", referer);
    }

    /// Load a direct network stream with an explicit User-Agent AND Referer.
    ///
    /// IPTV CDNs commonly 400/403 unless the exact user_agent / referrer from the
    /// directory is sent (mpv's default "libmpv" UA is a frequent block).
    pub fn loadStreamWithHttp(self: *MediaPlayer, url: []const u8, user_agent: []const u8, referer: []const u8) void {
        const hdrs = [_]HttpHeader{.{ .name = "Referer", .value = referer }};
        self.loadStreamWithHttpHeaders(url, user_agent, &hdrs);
    }

    /// Save current playback position to DB (called periodically from render loop)
    pub fn saveCurrentPosition(self: *MediaPlayer) void {
        if (self.current_url_len == 0 or self.current_url_len > self.current_url.len) return;
        var pos: f64 = 0;
        var dur: f64 = 0;
        _ = c.mpv.mpv_get_property(self.mpv_ctx, "time-pos", c.mpv.MPV_FORMAT_DOUBLE, &pos);
        _ = c.mpv.mpv_get_property(self.mpv_ctx, "duration", c.mpv.MPV_FORMAT_DOUBLE, &dur);
        if (pos > 1 and dur > 5) {
            const history = @import("../services/history.zig");
            history.savePlaybackPosition(self.current_url[0..self.current_url_len], pos, dur);

            // Per-episode resume, stored under real episode identity
            // (tmdb_id, season, episode) rather than the URL — an episode's URL is
            // a torrent/stream link that differs between sessions and sources.
            //
            // Only fires when THIS player's current URL is the one the episode
            // binding claimed; otherwise a movie played after an episode would
            // write its position into the episode's row.
            const pe = &state.app.playing_episode;
            if (pe.matches(self.current_url[0..self.current_url_len])) {
                @import("../core/db.zig").tvSavePosition(pe.tmdb_id, pe.season, pe.episode, pos, dur);
            }
        }
    }

    /// Check for and apply saved resume position (called after first frame renders)
    pub fn tryResumePosition(self: *MediaPlayer) void {
        if (self.resume_seeked or self.current_url_len == 0 or self.current_url_len > self.current_url.len) return;
        self.resume_seeked = true;
        const history = @import("../services/history.zig");

        const cur = self.current_url[0..self.current_url_len];

        // Claim a pending episode arm: this load is the episode that was just
        // launched, so bind the binding to THIS url. Everything afterwards
        // (position saves, resumes) is gated on the url still matching, so the
        // binding dies with the media rather than leaking onto the next thing
        // that plays.
        const pe = &state.app.playing_episode;
        if (pe.armed) {
            pe.armed = false;
            const n = @min(cur.len, pe.url.len);
            @memcpy(pe.url[0..n], cur[0..n]);
            pe.url_len = n;
            pe.active = true; // last
        }

        // Prefer the per-episode position for a tracked episode. The URL-keyed
        // lookup can't help there: an episode's URL is a torrent/stream link that
        // differs between sessions, so the same episode resumed from a different
        // magnet would look brand new.
        const saved_pos = if (pe.matches(cur))
            @import("../core/db.zig").tvGetPosition(pe.tmdb_id, pe.season, pe.episode)
        else
            history.getPlaybackPosition(cur);

        // Only resume a position worth resuming: >= ~30s in and not
        // effectively finished (see watch_history_pure thresholds).
        var dur: f64 = 0;
        _ = c.mpv.mpv_get_property(self.mpv_ctx, "duration", c.mpv.MPV_FORMAT_DOUBLE, &dur);
        if (@import("watch_history_pure.zig").resumeEligible(saved_pos, dur)) {
            var seek_buf: [64]u8 = undefined;
            const seek_cmd = std.fmt.bufPrintZ(&seek_buf, "seek {d:.1} absolute", .{saved_pos}) catch return;
            _ = c.mpv.mpv_command_string(self.mpv_ctx, seek_cmd.ptr);
            var ts_buf: [16]u8 = undefined;
            const ts = @import("../services/youtube_pure.zig").formatDuration(@intFromFloat(saved_pos), &ts_buf);
            var toast_buf: [64]u8 = undefined;
            const toast = std.fmt.bufPrint(&toast_buf, "Resumed at {s}", .{ts}) catch return;
            state.showToast(toast);
        }
    }

    pub fn setLoopA(self: *MediaPlayer) void {
        var pos: f64 = 0;
        _ = c.mpv.mpv_get_property(self.mpv_ctx, "time-pos", c.mpv.MPV_FORMAT_DOUBLE, &pos);
        self.loop_a = pos;
        _ = c.mpv.mpv_set_property(self.mpv_ctx, "ab-loop-a", c.mpv.MPV_FORMAT_DOUBLE, &self.loop_a);
    }

    pub fn setLoopB(self: *MediaPlayer) void {
        var pos: f64 = 0;
        _ = c.mpv.mpv_get_property(self.mpv_ctx, "time-pos", c.mpv.MPV_FORMAT_DOUBLE, &pos);
        self.loop_b = pos;
        _ = c.mpv.mpv_set_property(self.mpv_ctx, "ab-loop-b", c.mpv.MPV_FORMAT_DOUBLE, &self.loop_b);
    }

    pub fn clearLoop(self: *MediaPlayer) void {
        self.loop_a = -1.0;
        self.loop_b = -1.0;
        _ = c.mpv.mpv_command_string(self.mpv_ctx, "set ab-loop-a no");
        _ = c.mpv.mpv_command_string(self.mpv_ctx, "set ab-loop-b no");
    }

    pub fn toggleFlip(self: *MediaPlayer) void {
        self.is_flipped = !self.is_flipped;
        if (self.is_flipped) {
            _ = c.mpv.mpv_command_string(self.mpv_ctx, "vf set hflip");
        } else {
            _ = c.mpv.mpv_command_string(self.mpv_ctx, "vf set \"\"");
        }
    }

    pub fn togglePause(self: *MediaPlayer) void {
        _ = c.mpv.mpv_command_string(self.mpv_ctx, "cycle pause");
    }

    pub fn cycleRotation(self: *MediaPlayer) void {
        self.rotation = @mod(self.rotation + 90, 360);
        var cmd_buf: [64]u8 = undefined;
        if (std.fmt.bufPrintZ(&cmd_buf, "set video-rotate {d}", .{self.rotation})) |cmd| {
            _ = c.mpv.mpv_command_string(self.mpv_ctx, cmd.ptr);
        } else |_| {}
    }

    pub fn applyYtdlFormat(self: *MediaPlayer) void {
        const ytdlp = @import("../services/ytdlp.zig");
        // The format string deprioritizes AV1 (av01): many GPUs — Apple Silicon
        // before M3, and older PCs — can't hardware-decode it, and mpv then shows
        // a black frame with audio only. vp9/h264 videotoolbox-decode fine. Built
        // in a tested pure module so the exact -f string is covered.
        const ytdl_format = @import("ytdl_format_pure.zig");
        const active_fmt = ytdl_format.formatFor(state.app.ytdl_format_idx);
        // Use bundled yt-dlp if available, else fall back to system
        const ytdl_path = ytdlp.getPath() orelse "yt-dlp";

        // ytdl-format is a top-level mpv option
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "ytdl-format", active_fmt.ptr);

        // ytdl-raw-options is a top-level mpv option (NOT script-opts!)
        // cookies-from-browser: reuse Firefox session for auth/cookie walls —
        //   but ONLY if a Firefox profile exists, else yt-dlp aborts with
        //   "could not find firefox cookies database" and playback fails.
        // no-check-certificates: bypass SSL issues
        // no-playlist: prevent ytdl_hook from expanding model/channel pages
        // Raw options are built by ytdl_opts_pure (tested) so the exact string
        // mpv receives is covered — including the regression that no YouTube
        // player client may be pinned here (see that module's header).
        const ytdl_opts = @import("ytdl_opts_pure.zig");
        var raw_buf: [400]u8 = undefined;
        if (ytdl_opts.buildRawOptions(.{
            .firefox_cookies = firefoxProfileExists(),
            .proxy = state.app.proxy_url[0..state.app.proxy_url_len],
        }, &raw_buf)) |raw| {
            var raw_z: [401]u8 = undefined;
            @memcpy(raw_z[0..raw.len], raw);
            raw_z[raw.len] = 0;
            _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "ytdl-raw-options", &raw_z);
        }

        // script-opts: ytdl_hook config + sponsorblock
        // try_ytdl_first=no: try direct playback before yt-dlp (avoids playlist expansion)
        // exclude patterns: model/channel pages that expand into huge playlists
        var buf: [512]u8 = undefined;
        const sp_opts = if (state.app.sponsorblock_enabled) ",sponsorblock-mark=all" else "";
        if (std.fmt.bufPrintZ(&buf, "ytdl_hook-ytdl_path={s},ytdl_hook-try_ytdl_first=no,ytdl_hook-exclude=%.*/model/.*|%.*/channels/.*|%.*/pornstar/.*|%.*/playlist.*{s}", .{ ytdl_path, sp_opts })) |opts| {
            _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "script-opts", opts.ptr);
        } else |_| {}
    }

    /// Export A-B loop segment to file using ffmpeg (background thread).
    pub fn exportClip(self: *MediaPlayer) void {
        if (self.loop_a < 0 or self.loop_b < 0 or self.loop_b <= self.loop_a) {
            state.showToast("Set A-B loop first (L key)");
            return;
        }
        if (self.current_url_len == 0) {
            state.showToast("No media loaded");
            return;
        }

        // Build output path in download directory
        const paths = @import("../core/paths.zig");
        var dir_buf: [512]u8 = undefined;
        const dl_dir = paths.defaultSavePath(&dir_buf);

        // Generate output filename with timestamps
        const a_sec = @as(u32, @intFromFloat(@max(0, self.loop_a)));
        const b_sec = @as(u32, @intFromFloat(@max(0, self.loop_b)));

        const ExportCtx = struct {
            src: [2048]u8 = undefined,
            src_len: usize = 0,
            out: [512]u8 = undefined,
            out_len: usize = 0,
            ss_buf: [32]u8 = undefined,
            ss_len: usize = 0,
            to_buf: [32]u8 = undefined,
            to_len: usize = 0,
        };

        const ctx_alloc = @import("../core/alloc.zig").allocator;
        const ectx = ctx_alloc.create(ExportCtx) catch {
            state.showToast("Out of memory for clip export");
            return;
        };
        ectx.* = .{};

        @memcpy(ectx.src[0..self.current_url_len], self.current_url[0..self.current_url_len]);
        ectx.src_len = self.current_url_len;

        const ss = std.fmt.bufPrintZ(&ectx.ss_buf, "{d:.2}", .{self.loop_a}) catch {
            ctx_alloc.destroy(ectx);
            return;
        };
        ectx.ss_len = ss.len;
        const to = std.fmt.bufPrintZ(&ectx.to_buf, "{d:.2}", .{self.loop_b}) catch {
            ctx_alloc.destroy(ectx);
            return;
        };
        ectx.to_len = to.len;

        const out_path = std.fmt.bufPrintZ(&ectx.out, "{s}/clip_{d:0>2}m{d:0>2}s-{d:0>2}m{d:0>2}s.mp4", .{
            dl_dir, a_sec / 60, a_sec % 60, b_sec / 60, b_sec % 60,
        }) catch {
            ctx_alloc.destroy(ectx);
            return;
        };
        ectx.out_len = out_path.len;

        state.showToast("Exporting clip...");

        if (std.Thread.spawn(.{}, struct {
            fn worker(ec: *ExportCtx) void {
                defer ctx_alloc.destroy(ec);
                const io_global = @import("../core/io_global.zig");
                const alloc = @import("../core/alloc.zig").allocator;

                var child = io_global.Child.init(
                    &.{ "ffmpeg", "-y", "-ss", ec.ss_buf[0..ec.ss_len], "-to", ec.to_buf[0..ec.to_len], "-i", ec.src[0..ec.src_len], "-c", "copy", "-avoid_negative_ts", "make_zero", ec.out[0..ec.out_len] },
                    alloc,
                );
                child.stdout_behavior = .Ignore;
                child.stderr_behavior = .Ignore;
                child.spawn() catch {
                    state.showToast("ffmpeg not found — install it");
                    return;
                };
                const term = child.wait() catch {
                    state.showToast("Clip export failed");
                    return;
                };
                if (term.exited == 0) {
                    state.showToast("Clip exported!");
                    logs.pushLog("info", "clip", "Clip exported successfully", false);
                } else {
                    state.showToast("Clip export failed (ffmpeg error)");
                }
            }
        }.worker, .{ectx})) |t| t.detach() else |_| {
            ctx_alloc.destroy(ectx);
            state.showToast("Failed to spawn export thread");
        }
    }

    pub fn deinit(self: *MediaPlayer, allocator: std.mem.Allocator) void {
        self.saveCurrentPosition();
        @import("../core/poster.zig").deinitPoster(&self.loading_poster_pixels, &self.loading_poster_tex);
        @import("../core/poster.zig").deinitPoster(&self.np_art_pixels, &self.np_art_tex);
        if (self.proxy_handle.isValid()) {
            @import("stream_proxy.zig").stopProxy(self.proxy_handle);
            self.proxy_handle = @import("stream_proxy.zig").INVALID_HANDLE;
        }
        c.mpv.mpv_render_context_free(self.mpv_gl);
        c.mpv.mpv_terminate_destroy(self.mpv_ctx);
        allocator.free(self.pixels);
        allocator.destroy(self);
    }
};

/// Invoked by mpv (on an mpv-owned thread) whenever a new video frame is
/// ready for rendering. We wake the dvui main loop so that the
/// pixel-buffer transfer in ui/grid.zig runs and the on-screen texture
/// updates. Without this, dvui's SDL backend sleeps on input idle and
/// the video freezes while audio continues. dvui.refresh is explicitly
/// thread-safe when a *Window is passed (see dvui/src/dvui.zig).
fn mpvRenderUpdateCallback(_: ?*anyopaque) callconv(.c) void {
    if (state.app.dvui_win) |win| {
        dvui.refresh(win, @src(), null);
    }
}

pub fn updateTorrentBackgroundTasks() void {
    for (state.app.players.items) |p| {
        // PUMP MPV EVENTS
        while (true) {
            const ev = c.mpv.mpv_wait_event(p.mpv_ctx, 0);
            if (ev.*.event_id == c.mpv.MPV_EVENT_NONE) break;

            if (ev.*.event_id == c.mpv.MPV_EVENT_START_FILE) {
                p.provider = .mpv;
            } else if (ev.*.event_id == c.mpv.MPV_EVENT_FILE_LOADED) {
                // Tracks are parsed now. If the media brought no subtitle track
                // (no embedded stream, no sidecar picked up by sub-auto=fuzzy),
                // kick an automatic OpenSubtitles fetch for the best match.
                // Guarded internally (toggle, API key, per-file dedupe).
                var sub_count: i64 = 0;
                _ = c.mpv.mpv_get_property(p.mpv_ctx, "sub", c.mpv.MPV_FORMAT_INT64, &sub_count);
                var has_sub = false;
                {
                    var tc: i64 = 0;
                    _ = c.mpv.mpv_get_property(p.mpv_ctx, "track-list/count", c.mpv.MPV_FORMAT_INT64, &tc);
                    var ti: i64 = 0;
                    while (ti < tc) : (ti += 1) {
                        var q: [48]u8 = undefined;
                        const qz = std.fmt.bufPrintZ(&q, "track-list/{d}/type", .{ti}) catch continue;
                        const ts = c.mpv.mpv_get_property_string(p.mpv_ctx, qz.ptr);
                        if (ts != null) {
                            if (std.mem.eql(u8, std.mem.span(ts), "sub")) has_sub = true;
                            c.mpv.mpv_free(@ptrCast(ts));
                        }
                        if (has_sub) break;
                    }
                }
                if (!has_sub and state.app.auto_download_subs and p.current_torrent_id < 0) {
                    // Non-torrent playback: fire the keyless subtitle engine
                    // (rest.opensubtitles.org → Gestdown) off the media title or
                    // filename. Torrents already trigger it on metadata-ready.
                    var title_buf: [256]u8 = undefined;
                    var qname: []const u8 = "";
                    const tc = c.mpv.mpv_get_property_string(p.mpv_ctx, "media-title");
                    if (tc != null) {
                        const ts = std.mem.span(tc);
                        if (ts.len > 0 and !std.mem.eql(u8, ts, "No file")) {
                            const n = @min(ts.len, title_buf.len);
                            @memcpy(title_buf[0..n], ts[0..n]);
                            qname = title_buf[0..n];
                        }
                        c.mpv.mpv_free(@ptrCast(tc));
                    }
                    if (qname.len == 0 and p.current_url_len > 0) {
                        const url = p.current_url[0..p.current_url_len];
                        const base_end = std.mem.indexOfScalar(u8, url, '?') orelse url.len;
                        const path = url[0..base_end];
                        qname = if (std.mem.lastIndexOfScalar(u8, path, '/')) |ix|
                            (if (ix + 1 < path.len) path[ix + 1 ..] else path)
                        else
                            path;
                    }
                    if (qname.len > 0)
                        @import("subtitles.zig").startSearch(&state.app.sub_engine, qname);
                }
            } else if (ev.*.event_id == c.mpv.MPV_EVENT_END_FILE) {
                if (p.current_torrent_id >= 0 and p.torrent_is_ready) {
                    // Torrent streaming: check if download is complete
                    var pct: f32 = 0.0;
                    _ = c.mpv.torrent_poll(state.torrentSession(), p.current_torrent_id, p.selected_file_idx, null, 0, &pct, null, null);

                    if (pct >= 0.99) {
                        // File fully downloaded — genuine EOF.
                        // Auto-advance to next episode if enabled and multi-file torrent
                        if (state.app.auto_advance) {
                            const file_count = c.mpv.torrent_get_file_count(state.torrentSession(), p.current_torrent_id);
                            if (file_count > 1 and p.selected_file_idx >= 0 and p.selected_file_idx + 1 < file_count) {
                                // Advance to the next PLAYABLE file (skip .nfo,
                                // .txt, and — critically — .exe/.rar/.zip), via
                                // the shared tested classifier (media_ext).
                                const media_ext = @import("../core/media_ext.zig");
                                var next_idx = p.selected_file_idx + 1;
                                while (next_idx < file_count) {
                                    var fname: [512]u8 = undefined;
                                    c.mpv.torrent_get_file_name(state.torrentSession(), p.current_torrent_id, next_idx, &fname, 512);
                                    if (media_ext.isPlayable(std.mem.sliceTo(&fname, 0))) break;
                                    next_idx += 1;
                                }
                                if (next_idx < file_count) {
                                    p.selected_file_idx = next_idx;
                                    p.torrent_is_ready = false;
                                    p.has_metadata = true;
                                    logs.pushLog("info", "opal", "Auto-advancing to next episode...", false);
                                    continue;
                                }
                            }
                        }
                        // No next episode or auto-advance disabled — genuine end
                        continue;
                    }

                    // File still downloading — mpv hit an undownloaded section.
                    // Wait and reload with a longer backoff to give pieces time to arrive.
                    const now = @import("../core/io_global.zig").milliTimestamp();
                    if (now - p.last_error_time > 3000) {
                        logs.pushLog("warn", "opal", "Buffering: waiting for torrent data...", true);

                        // Reload from where we actually were, not from the start.
                        // Without this the reload fell back to the coarse
                        // watch-history percent (written every few hundred frames),
                        // so a mid-stream stall visibly threw playback backwards.
                        var cur_pct: f64 = 0;
                        if (c.mpv.mpv_get_property(p.mpv_ctx, "percent-pos", c.mpv.MPV_FORMAT_DOUBLE, &cur_pct) >= 0) {
                            if (cur_pct > 0.1 and cur_pct < 99.9 and !std.math.isNan(cur_pct)) {
                                p.resume_percent = cur_pct;
                            }
                        }

                        p.torrent_is_ready = false;
                        p.has_metadata = true;
                        p.last_error_time = now;
                    }
                } else if (p.current_torrent_id < 0 and state.app.auto_advance) {
                    // Non-torrent content ended. If it came from the M3U
                    // playlist, advance there (repeat one/all/off + shuffle,
                    // decided by playlist_pure.nextIndex via playlist.advance).
                    // A finished playlist (repeat off) stops rather than
                    // hopping into unrelated queue items; only content that
                    // was never in the playlist falls back to the queue.
                    const playlist_ui = @import("playlist.zig");
                    switch (playlist_ui.advance(p, 1)) {
                        .started, .end_of_playlist => {},
                        .not_playlist => {
                            const queue_svc = @import("../services/queue.zig");
                            queue_svc.playNextUnplayed(p);
                        },
                    }
                }
            } else if (ev.*.event_id == c.mpv.MPV_EVENT_PROPERTY_CHANGE) {
                // Update cached property mirrors so the render hot path avoids
                // per-frame synchronous IPC (A4). data may be NULL/NONE when the
                // property is currently unavailable.
                const pc = @as(*c.mpv.mpv_event_property, @ptrCast(@alignCast(ev.*.data)));
                const pname = if (pc.*.name != null) std.mem.span(pc.*.name) else "";
                if (std.mem.eql(u8, pname, "pause")) {
                    if (pc.*.format == c.mpv.MPV_FORMAT_FLAG and pc.*.data != null) {
                        const flag = @as(*c_int, @ptrCast(@alignCast(pc.*.data))).*;
                        const prev_paused = p.cached_paused;
                        const new_paused = (flag != 0);
                        p.cached_paused = new_paused;
                        // Co-watcher: fire only on a genuine playing->paused transition
                        // for the *active* player (pointer identity, bounds-guarded).
                        if (!prev_paused and new_paused and
                            state.app.active_player_idx < state.app.players.items.len and
                            state.app.players.items[state.app.active_player_idx] == p)
                        {
                            @import("../services/co_watch.zig").onPlaybackEvent(.paused);
                        }
                    }
                } else if (std.mem.eql(u8, pname, "vid")) {
                    if (pc.*.format == c.mpv.MPV_FORMAT_STRING and pc.*.data != null) {
                        const sptr = @as(*[*c]u8, @ptrCast(@alignCast(pc.*.data))).*;
                        const vid = if (sptr != null) std.mem.span(sptr) else "";
                        p.cached_vid_no = std.mem.eql(u8, vid, "no");
                        // Audio-only (radio / podcast / music): synthesise a picture.
                        if (p.cached_vid_no) applyVisualizer(p);
                    } else {
                        // Unavailable (no value) — treat as not audio-only.
                        p.cached_vid_no = false;
                    }
                } else if (std.mem.eql(u8, pname, "sub-text")) {
                    if (pc.*.format == c.mpv.MPV_FORMAT_STRING and pc.*.data != null) {
                        const sptr = @as(*[*c]u8, @ptrCast(@alignCast(pc.*.data))).*;
                        const txt = if (sptr != null) std.mem.span(sptr) else "";
                        const n = @min(txt.len, p.cached_sub_text.len);
                        @memcpy(p.cached_sub_text[0..n], txt[0..n]);
                        p.cached_sub_text_len = n;

                        // T3: also feed the rolling dialogue ring (deduped).
                        // (Rewind detection now lives in the "time-pos" branch so
                        // it fires during silent stretches too.)
                        if (txt.len > 0) {
                            var pos: f64 = 0;
                            _ = c.mpv.mpv_get_property(p.mpv_ctx, "time-pos", c.mpv.MPV_FORMAT_DOUBLE, &pos);
                            p.updateDialogueRing(txt, pos);
                        }
                    } else {
                        p.cached_sub_text_len = 0;
                    }
                } else if (std.mem.eql(u8, pname, "time-pos")) {
                    if (pc.*.format == c.mpv.MPV_FORMAT_DOUBLE and pc.*.data != null) {
                        const newpos = @as(*f64, @ptrCast(@alignCast(pc.*.data))).*;
                        if (newpos >= 0) {
                            // Co-watcher rewind detect: a backward jump > 5s, fired
                            // even during silent stretches. Active player only
                            // (pointer identity, bounds-guarded).
                            if (newpos < p.last_seen_pos - 5.0 and
                                state.app.active_player_idx < state.app.players.items.len and
                                state.app.players.items[state.app.active_player_idx] == p)
                            {
                                @import("../services/co_watch.zig").onPlaybackEvent(.rewound);
                            }
                            p.last_seen_pos = newpos;

                            // Deferred TV watch commit: armed by the episode
                            // play flow, committed only when the ACTIVE player
                            // actually crosses the played-enough threshold —
                            // clicking ▶ alone marks nothing watched.
                            {
                                const pw = &state.app.pending_watch;
                                if (pw.armed and !pw.committed and
                                    @import("../services/tmdb_pure.zig").tvWatchCommitDue(newpos) and
                                    state.app.active_player_idx < state.app.players.items.len and
                                    state.app.players.items[state.app.active_player_idx] == p)
                                {
                                    pw.committed = true;
                                    pw.armed = false;
                                    @import("../services/tmdb.zig").commitPendingWatch();
                                }
                            }
                        }
                    }
                }
            } else if (ev.*.event_id == c.mpv.MPV_EVENT_LOG_MESSAGE) {
                const log_msg = @as(*c.mpv.mpv_event_log_message, @ptrCast(@alignCast(ev.*.data)));
                const prefix = if (log_msg.*.prefix != null) std.mem.span(log_msg.*.prefix) else "mpv";
                const level = if (log_msg.*.level != null) std.mem.span(log_msg.*.level) else "info";
                const text = if (log_msg.*.text != null) std.mem.span(log_msg.*.text) else "";
                const is_err = std.mem.eql(u8, level, "error") or std.mem.eql(u8, level, "fatal") or std.mem.eql(u8, level, "warn");
                logs.pushLog(level, prefix, text, is_err);
            }
        }

        if (p.current_torrent_id >= 0) {
            if (!p.torrent_is_ready) {
                var buffering_path: [512]u8 = undefined;
                const t_status = c.mpv.torrent_poll(state.torrentSession(), p.current_torrent_id, p.selected_file_idx, &buffering_path, @intCast(buffering_path.len), null, null, null);

                // Metadata check: torrent_poll returns >= 1 when has_metadata
                // We also check has_metadata directly via file_count for file-selected case
                if (!p.has_metadata) {
                    if (t_status >= 1) {
                        p.has_metadata = true;
                    } else {
                        // Also check if file_count > 0 (metadata arrived between polls)
                        const fc = c.mpv.torrent_get_file_count(state.torrentSession(), p.current_torrent_id);
                        if (fc > 0) p.has_metadata = true;
                    }
                }

                if (p.has_metadata) {
                    // Auto-select the largest PLAYABLE file if not yet selected.
                    // Non-media (.exe/.rar/.zip/…) is never auto-selected: it fed
                    // mpv garbage ("Failed to recognize file format") and, for
                    // executables, would auto-open a possible malware payload.
                    // -2 is the terminal "no playable media, aborted" sentinel.
                    if (p.selected_file_idx == -1) {
                        const media_ext = @import("../core/media_ext.zig");
                        const f_count = c.mpv.torrent_get_file_count(state.torrentSession(), p.current_torrent_id);
                        var max_sz: i64 = 0;
                        var max_idx: i32 = -1;
                        var risky_count: i32 = 0;
                        var i: i32 = 0;
                        while (i < f_count) : (i += 1) {
                            c.mpv.torrent_set_file_priority(state.torrentSession(), p.current_torrent_id, i, 0);
                            var fname: [512]u8 = undefined;
                            c.mpv.torrent_get_file_name(state.torrentSession(), p.current_torrent_id, i, &fname, 512);
                            const name = std.mem.sliceTo(&fname, 0);
                            if (media_ext.isExecutableOrArchive(name)) risky_count += 1;
                            if (!media_ext.isPlayable(name)) continue; // skip non-media
                            const sz = c.mpv.torrent_get_file_size(state.torrentSession(), p.current_torrent_id, i);
                            if (sz > max_sz) {
                                max_sz = sz;
                                max_idx = i;
                            }
                        }

                        if (max_idx < 0) {
                            // No playable file at all — refuse to load, warn.
                            var lb: [96]u8 = undefined;
                            const msg = if (risky_count > 0)
                                (std.fmt.bufPrint(&lb, "No playable media — {d} executable/archive file(s) NOT opened (possible malware)", .{risky_count}) catch "No playable media in torrent")
                            else
                                "No playable media found in this torrent";
                            logs.pushLog("error", "opal", msg, true);
                            state.showToast(msg);
                            p.selected_file_idx = -2; // terminal: won't re-enter (-1 gate)
                            p.is_loading = false;
                            continue;
                        }

                        if (risky_count > 0) {
                            var lb: [96]u8 = undefined;
                            logs.pushLog("warn", "opal", std.fmt.bufPrint(&lb, "Skipped {d} executable/archive file(s) in this torrent (not opened)", .{risky_count}) catch "Skipped non-media files", false);
                        }

                        p.selected_file_idx = max_idx;
                        c.mpv.torrent_set_file_priority(state.torrentSession(), p.current_torrent_id, max_idx, 7);

                        // Re-poll to apply streaming window for selected file
                        _ = c.mpv.torrent_poll(state.torrentSession(), p.current_torrent_id, p.selected_file_idx, &buffering_path, @intCast(buffering_path.len), null, null, null);
                    }

                    // Torrent had no playable media (-2, set above) — nothing
                    // to start; leave the pane idle instead of polling a bogus
                    // index.
                    if (p.selected_file_idx < 0) break;

                    // ── READINESS GATE ──
                    //
                    // Playback used to start the instant ONE piece existed, on the
                    // theory that "the proxy blocks, so mpv just buffers". It does
                    // not work that way: mpv's Matroska demuxer SEEKS TO THE END of
                    // the file during open, to read the Cues and Tags. So it blocked
                    // inside demux_mkv_open() — before creating a single track —
                    // waiting on bytes nothing had prioritized. That is the black
                    // screen at 00:00 while the torrent sits at 11%: head progress
                    // is irrelevant, because the demuxer never gets past that seek.
                    //
                    // stream_gate works out what THIS container actually needs (it
                    // differs per format), pins those byte ranges at top priority,
                    // and only lets us through once they are present.
                    {
                        const gate = @import("stream_gate.zig");
                        var f_name: [512]u8 = undefined;
                        c.mpv.torrent_get_file_name(state.torrentSession(), p.current_torrent_id, p.selected_file_idx, &f_name, f_name.len);
                        const fn_len = std.mem.indexOfScalar(u8, &f_name, 0) orelse 0;
                        const f_size = c.mpv.torrent_get_file_size(state.torrentSession(), p.current_torrent_id, p.selected_file_idx);

                        if (f_size > 0 and !gate.isReady(
                            p.current_torrent_id,
                            p.selected_file_idx,
                            f_name[0..fn_len],
                            @intCast(f_size),
                        )) {
                            // Keep polling so the deadline window keeps ticking, and
                            // leave torrent_is_ready false so the buffering overlay
                            // stays up (it now shows REAL head+index progress).
                            _ = c.mpv.torrent_poll(state.torrentSession(), p.current_torrent_id, p.selected_file_idx, &buffering_path, @intCast(buffering_path.len), null, null, null);
                            break;
                        }
                    }

                    // Get file path from torrent_poll (even if pieces aren't ready yet)
                    _ = c.mpv.torrent_poll(state.torrentSession(), p.current_torrent_id, p.selected_file_idx, &buffering_path, @intCast(buffering_path.len), null, null, null);
                    const path_len = std.mem.indexOfScalar(u8, &buffering_path, 0) orelse buffering_path.len;
                    const safe_len = @min(path_len, 511);
                    var null_term_path: [513]u8 = undefined;
                    @memcpy(null_term_path[0..safe_len], buffering_path[0..safe_len]);
                    null_term_path[safe_len] = 0;

                    p.torrent_is_ready = true;
                    p.last_load_time = @import("../core/io_global.zig").milliTimestamp();

                    // Ingest media to Vector DB AI Memory
                    var t_name_ai: [256]u8 = undefined;
                    c.mpv.torrent_get_name(state.torrentSession(), p.current_torrent_id, &t_name_ai, 256);
                    const nai_len = std.mem.indexOfScalar(u8, &t_name_ai, 0) orelse 0;
                    if (nai_len > 0) {
                        const ai_memory = @import("../services/ai_memory.zig");
                        ai_memory.ingestMemory("system", "User started playing media", "media", t_name_ai[0..nai_len]);
                    }

                    // Check watch history for resume position — prefer the
                    // exact saved second; fall back to legacy percent rows.
                    const watch = @import("watch_history.zig");
                    if (p.resume_percent <= 0.0 and p.resume_position_secs <= 0.0) {
                        var t_name2: [256]u8 = undefined;
                        c.mpv.torrent_get_name(state.torrentSession(), p.current_torrent_id, &t_name2, 256);
                        const n_len = std.mem.indexOfScalar(u8, &t_name2, 0) orelse 0;
                        if (n_len > 0) {
                            if (watch.getEntry(t_name2[0..n_len])) |we| {
                                const whp = @import("watch_history_pure.zig");
                                if (whp.resumeEligible(we.position_secs, we.duration_secs)) {
                                    p.resume_position_secs = we.position_secs;
                                } else if (we.position_secs <= 0.0 and we.percent > 1.0 and we.percent < 95.0) {
                                    p.resume_percent = we.percent;
                                }
                            }
                        }
                    }

                    if (p.resume_position_secs > 0.0) {
                        // mpv "start" takes plain seconds — exact-second resume.
                        var start_opt: [32]u8 = undefined;
                        if (std.fmt.bufPrintZ(&start_opt, "{d:.2}", .{p.resume_position_secs})) |so| {
                            _ = c.mpv.mpv_set_option_string(p.mpv_ctx, "start", so.ptr);
                        } else |_| {}
                        p.resume_position_secs = 0.0;
                    } else if (p.resume_percent > 0.0) {
                        var start_opt: [32]u8 = undefined;
                        if (std.fmt.bufPrintZ(&start_opt, "{d:.2}%", .{p.resume_percent})) |so| {
                            _ = c.mpv.mpv_set_option_string(p.mpv_ctx, "start", so.ptr);
                        } else |_| {}
                        p.resume_percent = 0.0;
                    } else {
                        // Clear any previous start option to prevent looping
                        _ = c.mpv.mpv_set_option_string(p.mpv_ctx, "start", "none");
                    }

                    // ── Streaming Proxy: serve torrent via HTTP for smooth playback ──
                    // The proxy blocks reads until pieces arrive — no holes, no corruption.
                    // v2: each player owns its proxy handle so multi-stream split-view works,
                    // and the URL carries a per-stream token so foreign processes can't read it.
                    const stream_proxy = @import("stream_proxy.zig");
                    if (p.proxy_handle.isValid()) {
                        stream_proxy.stopProxy(p.proxy_handle);
                        p.proxy_handle = stream_proxy.INVALID_HANDLE;
                    }
                    if (stream_proxy.startProxy(p.current_torrent_id, p.selected_file_idx)) |h| {
                        p.proxy_handle = h;
                        var url_buf: [128]u8 = undefined;
                        if (stream_proxy.getStreamUrl(h, &url_buf)) |stream_url| {
                            var url_z: [128]u8 = undefined;
                            const ul = @min(stream_url.len, 127);
                            @memcpy(url_z[0..ul], stream_url[0..ul]);
                            url_z[ul] = 0;
                            p.load_file(@as([*c]const u8, @ptrCast(&url_z[0])));
                            logs.pushLog("info", "player", "Streaming via HTTP proxy", false);
                        } else {
                            // Fallback to raw file if URL generation fails
                            p.load_file(@as([*c]const u8, @ptrCast(&null_term_path[0])));
                        }
                    } else {
                        // Fallback to raw file if proxy fails to start
                        p.load_file(@as([*c]const u8, @ptrCast(&null_term_path[0])));
                        logs.pushLog("warn", "player", "Proxy failed, using raw file", false);
                    }

                    // Start thumbnail generation for seek preview
                    if (state.app.active_player_idx < state.app.players.items.len and
                        state.app.players.items[state.app.active_player_idx] == p)
                    {
                        state.app.thumb_state.reset();

                        // Auto-search subtitles for this torrent
                        const subs = @import("subtitles.zig");
                        var t_name: [256]u8 = undefined;
                        c.mpv.torrent_get_name(state.torrentSession(), p.current_torrent_id, &t_name, 256);
                        const name_len = std.mem.indexOfScalar(u8, &t_name, 0) orelse 0;
                        if (name_len > 0) {
                            subs.startSearch(&state.app.sub_engine, t_name[0..name_len]);
                        }
                    }
                }
            } else {
                var percent_pos: f64 = 0;
                _ = c.mpv.mpv_get_property(p.mpv_ctx, "percent-pos", c.mpv.MPV_FORMAT_DOUBLE, &percent_pos);

                // Update libtorrent's deadline window so it prioritizes pieces ahead of playback.
                // The HTTP proxy handles back-pressure (blocking reads until pieces arrive),
                // so we no longer need to pause/unpause mpv — it buffers naturally via HTTP.
                _ = c.mpv.torrent_ensure_streaming_buffer(state.torrentSession(), p.current_torrent_id, p.selected_file_idx, percent_pos);

                // Save position to watch history every ~300 frames (~5s at 60fps)
                p.save_counter +%= 1;
                if (percent_pos > 0.5 and p.save_counter % 300 == 0) {
                    const watch = @import("watch_history.zig");
                    var t_name3: [256]u8 = undefined;
                    c.mpv.torrent_get_name(state.torrentSession(), p.current_torrent_id, &t_name3, 256);
                    const n3_len = std.mem.indexOfScalar(u8, &t_name3, 0) orelse 0;
                    if (n3_len > 0) {
                        // source_url is the magnet this torrent was added from
                        // (set in search.zig's addMagnetToEngine) — without it,
                        // this row can never be resumed into the right player
                        // later (Jump back in / History fall back to guessing
                        // from the bare name, which routes to the web browser).
                        var pos_s: f64 = 0;
                        var dur_s: f64 = 0;
                        _ = c.mpv.mpv_get_property(p.mpv_ctx, "time-pos", c.mpv.MPV_FORMAT_DOUBLE, &pos_s);
                        _ = c.mpv.mpv_get_property(p.mpv_ctx, "duration", c.mpv.MPV_FORMAT_DOUBLE, &dur_s);
                        watch.savePositionFull(t_name3[0..n3_len], percent_pos, pos_s, dur_s, p.source_url[0..p.source_url_len]);
                    }
                }
            }
        } else {
            // Non-torrent content: resume + periodic position save
            // Try resume on first playback (after a frame renders)
            if (!p.resume_seeked) {
                var dur: f64 = 0;
                _ = c.mpv.mpv_get_property(p.mpv_ctx, "duration", c.mpv.MPV_FORMAT_DOUBLE, &dur);
                if (dur > 5) {
                    p.tryResumePosition();
                }
            }

            // Periodic position save every ~120 frames (~2s at 60fps)
            p.save_counter +%= 1;
            if (p.save_counter % 120 == 0) {
                p.saveCurrentPosition();
            }
        }
    }

    // Seek-preview thumbnail generation is DISABLED: getThumbPath() has no
    // consumer (no seek-preview UI was ever wired), so generating thumbnails
    // was pure wasted work — and pollGeneration() blocked the UI thread on a
    // per-frame child.wait() until ffmpeg finished. Leaving the thumbnail
    // module + state intact for a future seek-preview feature; just not
    // invoking generation/poll. (H8 + S10)

    // Auto-load subtitles when download completes
    if (state.app.sub_engine.state == .ready) {
        if (state.app.active_player_idx < state.app.players.items.len) {
            const subs = @import("subtitles.zig");
            subs.loadIntoMpv(&state.app.sub_engine, state.app.players.items[state.app.active_player_idx].mpv_ctx);
            state.app.sub_engine.state = .idle; // Don't re-load
        }
    }

    if (state.app.pending_magnet_tid >= 0 and !state.app.pending_has_metadata) {
        const f_count = c.mpv.torrent_get_file_count(state.torrentSession(), state.app.pending_magnet_tid);
        if (f_count > 0) {
            state.app.pending_has_metadata = true;
        }
    }
}

// ── Audio visualiser ──

const vis = @import("visualizer_pure.zig");
const vis_theme = @import("../ui/theme.zig");

/// Current style. Persisted by its label (config.zig) and set from Settings.
pub var vis_style: vis.Style = .bars;

/// Give an audio-only file a picture, Winamp-style.
///
/// mpv's `lavfi-complex` runs the audio through an ffmpeg filter that EMITS a video
/// stream, so the player shows a live waveform/spectrum instead of a static card.
/// ffmpeg does the FFT; we never touch PCM and spawn no audio thread of our own.
///
/// Called from the "vid" observer — the one place we know the file has no video.
/// Setting the graph GIVES mpv a video track, so "vid" fires again with a real
/// value; without the vis_applied latch this would re-set the graph forever.
fn applyVisualizer(p: *MediaPlayer) void {
    if (p.vis_applied) return;
    if (vis_style == .off) return;

    // The accent tints the gradient. It reaches ffmpeg as three DECIMAL NUMBERS,
    // not a string — a u8 can only render as 0-255, so a theme colour has no way to
    // inject filter syntax.
    const a = vis_theme.colors.accent;

    var graph_buf: [1024]u8 = undefined;
    const graph = vis.lavfiComplex(vis_style, a.r, a.g, a.b, &graph_buf);
    if (graph.len == 0) return; // .off, or it did not fit — leave mpv alone

    var z: [1025]u8 = undefined;
    const gz = std.fmt.bufPrintZ(&z, "{s}", .{graph}) catch return;

    p.vis_applied = true;
    _ = c.mpv.mpv_set_property_string(p.mpv_ctx, "lavfi-complex", gz.ptr);
}
