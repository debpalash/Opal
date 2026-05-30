const std = @import("std");
const dvui = @import("dvui");
const c = @import("../core/c.zig");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");

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
    current_url: [2048]u8 = std.mem.zeroes([2048]u8),
    current_url_len: usize = 0,
    resume_seeked: bool = false,
    save_counter: u32 = 0, // periodic save every N frames
    provider: state.ContentProvider = .mpv,

    // v2: handle to the per-player torrent HTTP proxy stream (multi-tenant).
    // INVALID_HANDLE means no proxy is currently running for this player.
    proxy_handle: @import("stream_proxy.zig").Handle = @import("stream_proxy.zig").INVALID_HANDLE,

    // ── Per-player browser state ──
    browser_url_buf: [2048]u8 = std.mem.zeroes([2048]u8),
    browser_url_len: usize = 0,
    browser_is_loading: bool = false,
    browser_thread: ?std.Thread = null,
    browser_title: [256]u8 = std.mem.zeroes([256]u8),
    browser_title_len: usize = 0,
    browser_content: ?[]u8 = null,
    browser_links: [128]state.BrowserLink = std.mem.zeroes([128]state.BrowserLink),
    browser_link_count: usize = 0,
    browser_history: [32][2048]u8 = std.mem.zeroes([32][2048]u8),
    browser_history_lens: [32]usize = std.mem.zeroes([32]usize),
    browser_history_count: usize = 0,
    browser_history_pos: usize = 0,
    
    pub fn getMediaTitle(self: *MediaPlayer, out_buf: []u8) usize {
        // 1. If torrent, get torrent name
        if (self.current_torrent_id >= 0) {
            var t_name: [256]u8 = undefined;
            c.mpv.torrent_get_name(state.app.torrent_ses, self.current_torrent_id, &t_name, 256);
            const tn_len = std.mem.indexOfScalar(u8, &t_name, 0) orelse 0;
            if (tn_len > 0) {
                const limit = @min(tn_len, out_buf.len);
                @memcpy(out_buf[0..limit], t_name[0..limit]);
                return limit;
            }
        }
        
        // 2. If it has a browser title
        if (self.provider == .browser and self.browser_title_len > 0) {
            const limit = @min(self.browser_title_len, out_buf.len);
            @memcpy(out_buf[0..limit], self.browser_title[0..limit]);
            return limit;
        }

        // 3. Try reading mpv "media-title"
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
        @memset(&self.source_url, 0);
        @memset(&self.current_url, 0);
        self.current_url_len = 0;
        self.resume_seeked = false;
        self.save_counter = 0;
        self.is_loading = false;
        self.loading_label_len = 0;
        self.provider = .mpv;
        
        // Browser state init
        @memset(&self.browser_url_buf, 0);
        self.browser_url_len = 0;
        self.browser_is_loading = false;
        self.browser_thread = null;
        @memset(&self.browser_title, 0);
        self.browser_title_len = 0;
        self.browser_content = null;
        self.browser_links = std.mem.zeroes([128]state.BrowserLink);
        self.browser_link_count = 0;
        for (&self.browser_history) |*h| @memset(h, 0);
        @memset(&self.browser_history_lens, 0);
        self.browser_history_count = 0;
        self.browser_history_pos = 0;
        self.thumb_texture = null;
        @memset(&self.thumb_texture_path, 0);
        self.thumb_texture_path_len = 0;
        
        self.pixels = try allocator.alloc(dvui.Color.PMA, video_w * video_h);
        @memset(self.pixels, dvui.Color.PMA.black);

        self.mpv_ctx = c.mpv.mpv_create() orelse @panic("fail mpv");
        const hw_val = if (state.app.hwdec_enabled) "auto-safe" else "no";
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "hwdec", hw_val);
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "vo", "libmpv");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "audio-display", "attachment");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "osc", "no");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "osd-bar", "no");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "osd-level", "0");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "script-opts", "osc-visibility=auto");
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
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "network-timeout", "30");
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
        
        // Scan scripts before init (but loading happens after)
        const scripts_mgr = @import("../services/scripts.zig");
        if (!state.app.scripts_scanned) scripts_mgr.scanScripts();
        
        _ = c.mpv.mpv_initialize(self.mpv_ctx);

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
        if (c.mpv.mpv_render_context_create(&self.mpv_gl, self.mpv_ctx, &params) < 0) {
            @panic("fail render");
        }
        // Wake the UI loop whenever mpv has a new frame ready. Without
        // this, dvui sleeps on input idle (no mouse movement) and the
        // texture freezes even though audio keeps playing because the
        // pixel-buffer transfer in ui/grid.zig only happens inside a
        // dvui frame. The callback fires on an mpv-owned thread, so we
        // use the cross-thread form of dvui.refresh (passing *Window).
        c.mpv.mpv_render_context_set_update_callback(self.mpv_gl, &mpvRenderUpdateCallback, null);
        return self;
    }

    pub fn load_file(self: *MediaPlayer, path: [*c]const u8) void {
        // Save position of current video before switching
        self.saveCurrentPosition();
        
        @memset(self.pixels, dvui.Color.PMA.black);
        if (self.texture) |*tex| {
            _ = dvui.Texture.update(tex, self.pixels, .linear) catch {};
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
        
        var args = [_][*c]const u8{ "loadfile", path, null };
        _ = c.mpv.mpv_command(self.mpv_ctx, @ptrCast(&args));

        // ── Memory hooks: record playback for cross-session intelligence ──
        {
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
        }
    }

    /// Check for and apply saved resume position (called after first frame renders)
    pub fn tryResumePosition(self: *MediaPlayer) void {
        if (self.resume_seeked or self.current_url_len == 0 or self.current_url_len > self.current_url.len) return;
        self.resume_seeked = true;
        const history = @import("../services/history.zig");
        const saved_pos = history.getPlaybackPosition(self.current_url[0..self.current_url_len]);
        if (saved_pos > 2) {
            var seek_buf: [64]u8 = undefined;
            const seek_cmd = std.fmt.bufPrintZ(&seek_buf, "seek {d:.1} absolute", .{saved_pos}) catch return;
            _ = c.mpv.mpv_command_string(self.mpv_ctx, seek_cmd.ptr);
            const mins: u32 = @intFromFloat(saved_pos / 60);
            const secs: u32 = @intFromFloat(@mod(saved_pos, 60));
            var toast_buf: [64]u8 = undefined;
            const toast = std.fmt.bufPrint(&toast_buf, "Resumed at {d}:{d:0>2}", .{ mins, secs }) catch return;
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
        const fmt_strings = [_][*:0]const u8{
            "bestvideo[height<=?720]+bestaudio/best",
            "bestvideo[height<=?1080]+bestaudio/best",
            "bestvideo[height<=?2160]+bestaudio/best",
            "bestaudio/best"
        };
        const active_fmt = fmt_strings[state.app.ytdl_format_idx];
        // Use bundled yt-dlp if available, else fall back to system
        const ytdl_path = ytdlp.getPath() orelse "yt-dlp";
        
        // ytdl-format is a top-level mpv option
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "ytdl-format", active_fmt);
        
        // ytdl-raw-options is a top-level mpv option (NOT script-opts!)
        // cookies-from-browser: reuse Firefox session for auth/cookie walls (phub-cli pattern)
        // no-check-certificates: bypass SSL issues
        // no-playlist: prevent ytdl_hook from expanding model/channel pages into 88-video floods
        var raw_buf: [256]u8 = undefined;
        if (state.app.proxy_url_len > 0) {
            const proxy_str = state.app.proxy_url[0..state.app.proxy_url_len];
            if (std.fmt.bufPrintZ(&raw_buf, "cookies-from-browser=firefox,no-check-certificates=,no-playlist=,proxy={s}", .{proxy_str})) |raw| {
                _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "ytdl-raw-options", raw.ptr);
            } else |_| {}
        } else {
            _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "ytdl-raw-options", 
                "cookies-from-browser=firefox,no-check-certificates=,no-playlist=");
        }
        
        // script-opts: ytdl_hook config + sponsorblock
        // try_ytdl_first=no: try direct playback before yt-dlp (avoids playlist expansion)
        // exclude patterns: model/channel pages that expand into huge playlists
        var buf: [512]u8 = undefined;
        const sp_opts = if (state.app.sponsorblock_enabled) ",sponsorblock-mark=all" else "";
        if (std.fmt.bufPrintZ(&buf, "ytdl_hook-ytdl_path={s},ytdl_hook-try_ytdl_first=no,ytdl_hook-exclude=%.*/model/.*|%.*/channels/.*|%.*/pornstar/.*|%.*/playlist.*{s}", .{ytdl_path, sp_opts})) |opts| {
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
            var src: [2048]u8 = undefined;
            var src_len: usize = 0;
            var out: [512]u8 = undefined;
            var out_len: usize = 0;
            var ss_buf: [32]u8 = undefined;
            var ss_len: usize = 0;
            var to_buf: [32]u8 = undefined;
            var to_len: usize = 0;
        };

        @memcpy(ExportCtx.src[0..self.current_url_len], self.current_url[0..self.current_url_len]);
        ExportCtx.src_len = self.current_url_len;

        const ss = std.fmt.bufPrintZ(&ExportCtx.ss_buf, "{d:.2}", .{self.loop_a}) catch return;
        ExportCtx.ss_len = ss.len;
        const to = std.fmt.bufPrintZ(&ExportCtx.to_buf, "{d:.2}", .{self.loop_b}) catch return;
        ExportCtx.to_len = to.len;

        const out_path = std.fmt.bufPrintZ(&ExportCtx.out, "{s}/clip_{d:0>2}m{d:0>2}s-{d:0>2}m{d:0>2}s.mp4", .{
            dl_dir, a_sec / 60, a_sec % 60, b_sec / 60, b_sec % 60,
        }) catch return;
        ExportCtx.out_len = out_path.len;

        state.showToast("Exporting clip...");

        _ = std.Thread.spawn(.{}, struct {
            fn worker() void {
                const io_global = @import("../core/io_global.zig");
                const alloc = @import("../core/alloc.zig").allocator;

                var child = io_global.Child.init(
                    &.{ "ffmpeg", "-y",
                         "-ss", ExportCtx.ss_buf[0..ExportCtx.ss_len],
                         "-to", ExportCtx.to_buf[0..ExportCtx.to_len],
                         "-i", ExportCtx.src[0..ExportCtx.src_len],
                         "-c", "copy",
                         "-avoid_negative_ts", "make_zero",
                         ExportCtx.out[0..ExportCtx.out_len] },
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
                    state.showToast("✓ Clip exported!");
                    logs.pushLog("info", "clip", "Clip exported successfully", false);
                } else {
                    state.showToast("Clip export failed (ffmpeg error)");
                }
            }
        }.worker, .{}) catch {
            state.showToast("Failed to spawn export thread");
        };
    }

    pub fn deinit(self: *MediaPlayer, allocator: std.mem.Allocator) void {
        self.saveCurrentPosition();
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
            } else if (ev.*.event_id == c.mpv.MPV_EVENT_END_FILE) {
                if (p.current_torrent_id >= 0 and p.torrent_is_ready) {
                    // Torrent streaming: check if download is complete
                    var pct: f32 = 0.0;
                    _ = c.mpv.torrent_poll(state.app.torrent_ses, p.current_torrent_id, p.selected_file_idx, null, 0, &pct, null, null);
                    
                    if (pct >= 0.99) {
                        // File fully downloaded — genuine EOF.
                        // Auto-advance to next episode if enabled and multi-file torrent
                        if (state.app.auto_advance) {
                        const file_count = c.mpv.torrent_get_file_count(state.app.torrent_ses, p.current_torrent_id);
                        if (file_count > 1 and p.selected_file_idx >= 0 and p.selected_file_idx + 1 < file_count) {
                            // Find next video file (skip non-video files like .nfo, .txt)
                            var next_idx = p.selected_file_idx + 1;
                            while (next_idx < file_count) {
                                var fname: [512]u8 = undefined;
                                c.mpv.torrent_get_file_name(state.app.torrent_ses, p.current_torrent_id, next_idx, &fname, 512);
                                const name = std.mem.sliceTo(&fname, 0);
                                // Check if it's a video file
                                const is_video = std.mem.endsWith(u8, name, ".mkv") or 
                                    std.mem.endsWith(u8, name, ".mp4") or 
                                    std.mem.endsWith(u8, name, ".avi") or 
                                    std.mem.endsWith(u8, name, ".wmv") or 
                                    std.mem.endsWith(u8, name, ".mov");
                                if (is_video) break;
                                next_idx += 1;
                            }
                            if (next_idx < file_count) {
                                p.selected_file_idx = next_idx;
                                p.torrent_is_ready = false;
                                p.has_metadata = true;
                                logs.pushLog("info", "zigzag", "Auto-advancing to next episode...", false);
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
                        logs.pushLog("warn", "zigzag", "Buffering: waiting for torrent data...", true);
                        p.torrent_is_ready = false;
                        p.has_metadata = true;
                        p.last_error_time = now;
                    }
                } else if (p.current_torrent_id < 0 and state.app.auto_advance) {
                    // Non-torrent content ended — auto-play next from queue
                    const queue_svc = @import("../services/queue.zig");
                    queue_svc.playNextUnplayed(p);
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
                const t_status = c.mpv.torrent_poll(state.app.torrent_ses, p.current_torrent_id, p.selected_file_idx, &buffering_path, @intCast(buffering_path.len), null, null, null);
                
                // Metadata check: torrent_poll returns >= 1 when has_metadata
                // We also check has_metadata directly via file_count for file-selected case
                if (!p.has_metadata) {
                    if (t_status >= 1) {
                        p.has_metadata = true;
                    } else {
                        // Also check if file_count > 0 (metadata arrived between polls)
                        const fc = c.mpv.torrent_get_file_count(state.app.torrent_ses, p.current_torrent_id);
                        if (fc > 0) p.has_metadata = true;
                    }
                }

                if (p.has_metadata) {
                    // Auto-select largest file if not yet selected
                    if (p.selected_file_idx == -1) {
                        const f_count = c.mpv.torrent_get_file_count(state.app.torrent_ses, p.current_torrent_id);
                        var max_sz: i64 = 0;
                        var max_idx: i32 = 0;
                        var i: i32 = 0;
                        while (i < f_count) : (i += 1) {
                            const sz = c.mpv.torrent_get_file_size(state.app.torrent_ses, p.current_torrent_id, i);
                            if (sz > max_sz) { max_sz = sz; max_idx = i; }
                            c.mpv.torrent_set_file_priority(state.app.torrent_ses, p.current_torrent_id, i, 0);
                        }
                        p.selected_file_idx = max_idx;
                        if (max_idx >= 0 and max_idx < f_count) {
                            c.mpv.torrent_set_file_priority(state.app.torrent_ses, p.current_torrent_id, max_idx, 7);
                        }

                        // Re-poll to apply streaming window for selected file
                        _ = c.mpv.torrent_poll(state.app.torrent_ses, p.current_torrent_id, p.selected_file_idx, &buffering_path, @intCast(buffering_path.len), null, null, null);
                    }

                    // ── START PLAYBACK IMMEDIATELY ──
                    // Don't wait for any piece! The HTTP streaming proxy blocks reads
                    // until pieces arrive, so mpv shows its native "Buffering..." state.
                    // This gives instant startup instead of waiting for first piece.

                    // Get file path from torrent_poll (even if pieces aren't ready yet)
                    _ = c.mpv.torrent_poll(state.app.torrent_ses, p.current_torrent_id, p.selected_file_idx, &buffering_path, @intCast(buffering_path.len), null, null, null);
                    const path_len = std.mem.indexOfScalar(u8, &buffering_path, 0) orelse buffering_path.len;
                    const safe_len = @min(path_len, 511);
                    var null_term_path: [513]u8 = undefined;
                    @memcpy(null_term_path[0..safe_len], buffering_path[0..safe_len]);
                    null_term_path[safe_len] = 0;

                    p.torrent_is_ready = true;
                    p.last_load_time = @import("../core/io_global.zig").milliTimestamp();

                    // Ingest media to Vector DB AI Memory
                    var t_name_ai: [256]u8 = undefined;
                    c.mpv.torrent_get_name(state.app.torrent_ses, p.current_torrent_id, &t_name_ai, 256);
                    const nai_len = std.mem.indexOfScalar(u8, &t_name_ai, 0) orelse 0;
                    if (nai_len > 0) {
                        const ai_memory = @import("../services/ai_memory.zig");
                        ai_memory.ingestMemory("system", "User started playing media", "media", t_name_ai[0..nai_len]);
                    }
                    
                    // Check watch history for resume position
                    const watch = @import("watch_history.zig");
                    if (p.resume_percent <= 0.0) {
                        var t_name2: [256]u8 = undefined;
                        c.mpv.torrent_get_name(state.app.torrent_ses, p.current_torrent_id, &t_name2, 256);
                        const n_len = std.mem.indexOfScalar(u8, &t_name2, 0) orelse 0;
                        if (n_len > 0) {
                            const saved_pct = watch.getPosition(t_name2[0..n_len]);
                            if (saved_pct > 1.0 and saved_pct < 95.0) {
                                p.resume_percent = saved_pct;
                            }
                        }
                    }
                    
                    if (p.resume_percent > 0.0) {
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
                        c.mpv.torrent_get_name(state.app.torrent_ses, p.current_torrent_id, &t_name, 256);
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
                _ = c.mpv.torrent_ensure_streaming_buffer(state.app.torrent_ses, p.current_torrent_id, p.selected_file_idx, percent_pos);
                
                // Save position to watch history every ~5 seconds
                const now_ms = @import("../core/io_global.zig").milliTimestamp();
                const WS = struct { var last_save_ms: i64 = 0; };
                if (percent_pos > 0.5 and now_ms - WS.last_save_ms > 5000) {
                    const watch = @import("watch_history.zig");
                    var t_name3: [256]u8 = undefined;
                    c.mpv.torrent_get_name(state.app.torrent_ses, p.current_torrent_id, &t_name3, 256);
                    const n3_len = std.mem.indexOfScalar(u8, &t_name3, 0) orelse 0;
                    if (n3_len > 0) {
                        watch.savePosition(t_name3[0..n3_len], percent_pos, "");
                    }
                    WS.last_save_ms = now_ms;
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
        const f_count = c.mpv.torrent_get_file_count(state.app.torrent_ses, state.app.pending_magnet_tid);
        if (f_count > 0) {
            state.app.pending_has_metadata = true;
        }
    }
}
