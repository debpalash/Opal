const std = @import("std");
const dvui = @import("dvui");
const c = @import("../core/c.zig");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const http_headers = @import("http_headers_pure.zig");
const playback_load = @import("playback_load_pure.zig");
const playback_fallback = @import("playback_fallback_pure.zig");
const playback_snapshot = @import("playback_snapshot_pure.zig");
pub const HttpHeader = http_headers.HttpHeader;
pub const LoadMode = playback_load.Mode;
pub const PlaybackOrigin = playback_load.Origin;
pub const LoadRequest = playback_load.Request;
pub const PlaybackSnapshot = playback_snapshot.Snapshot;

const MAX_LOAD_URL = 8192;

/// Production adapter for the typed playback-command seam.  This is the only
/// implementation allowed to issue mpv's media-load command; the pure module
/// drives the same two-method interface against an in-memory fake in tests.
const MpvPlaybackSink = struct {
    ctx: *c.mpv.mpv_handle,

    fn stringNode(value: [*:0]const u8) c.mpv.mpv_node {
        return .{
            .u = .{ .string = @constCast(value) },
            .format = c.mpv.MPV_FORMAT_STRING,
        };
    }

    fn intNode(value: i64) c.mpv.mpv_node {
        return .{
            .u = .{ .int64 = value },
            .format = c.mpv.MPV_FORMAT_INT64,
        };
    }

    pub fn setOption(self: *MpvPlaybackSink, name: []const u8, value: []const u8) void {
        var name_buf: [64]u8 = undefined;
        const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{name}) catch return;
        var value_buf: [2049]u8 = undefined;
        const value_z = std.fmt.bufPrintZ(&value_buf, "{s}", .{value}) catch return;
        _ = c.mpv.mpv_set_option_string(self.ctx, name_z.ptr, value_z.ptr);
    }

    pub fn loadFile(self: *MpvPlaybackSink, url: []const u8, mode: LoadMode, options: playback_load.FileOptions) void {
        var url_buf: [MAX_LOAD_URL + 1]u8 = undefined;
        const url_z = std.fmt.bufPrintZ(&url_buf, "{s}", .{url}) catch return;
        var user_agent_buf: [2049]u8 = undefined;
        const user_agent_z = std.fmt.bufPrintZ(&user_agent_buf, "{s}", .{options.user_agent}) catch return;
        var header_fields_buf: [2049]u8 = undefined;
        const header_fields_z = std.fmt.bufPrintZ(&header_fields_buf, "{s}", .{options.header_fields}) catch return;

        // `loadfile`'s final argument is a native key/value map when invoked
        // through mpv_command_node. This avoids comma/string escaping and,
        // crucially, stores HTTP identity on the playlist entry instead of
        // changing the options of media that is already playing.
        var option_values = [_]c.mpv.mpv_node{
            stringNode(user_agent_z.ptr),
            stringNode(header_fields_z.ptr),
            stringNode(options.cache_pause_initial.ptr),
            stringNode(options.network_timeout.ptr),
        };
        var option_keys = [_][*c]u8{
            @constCast("user-agent"),
            @constCast("http-header-fields"),
            @constCast("cache-pause-initial"),
            @constCast("network-timeout"),
        };
        var option_list: c.mpv.mpv_node_list = .{
            .num = option_values.len,
            .values = @ptrCast(&option_values),
            .keys = @ptrCast(&option_keys),
        };
        const options_node: c.mpv.mpv_node = .{
            .u = .{ .list = &option_list },
            .format = c.mpv.MPV_FORMAT_NODE_MAP,
        };

        // mpv 0.38+ takes `loadfile <url> <flags> <index> <options>`; older
        // libmpv (Ubuntu 22.04's 0.34) takes `loadfile <url> <flags> <options>`
        // and would read the index as the options map, rejecting the whole
        // command (issue #47). Decided from the RUNTIME library version.
        // c_ulong is 64-bit on Linux/macOS and 32-bit on Windows; the value
        // itself is a 16.16 pair, so it always fits u32.
        const runtime_api: u32 = @intCast(c.mpv.mpv_client_api_version());
        const with_index = playback_load.loadfileHasIndexArg(runtime_api);
        var arg_values = [_]c.mpv.mpv_node{
            stringNode("loadfile"),
            stringNode(url_z.ptr),
            stringNode(mode.mpvArg().ptr),
            if (with_index) intNode(-1) else options_node,
            options_node,
        };
        var arg_list: c.mpv.mpv_node_list = .{
            .num = if (with_index) arg_values.len else arg_values.len - 1,
            .values = @ptrCast(&arg_values),
        };
        var command_node: c.mpv.mpv_node = .{
            .u = .{ .list = &arg_list },
            .format = c.mpv.MPV_FORMAT_NODE_ARRAY,
        };
        const rc = c.mpv.mpv_command_node(self.ctx, &command_node, null);
        if (rc < 0) {
            // A rejected load used to be silent: mpv wrote one line to stdout
            // and the UI showed "Opening stream" forever. Say what happened,
            // in the log ring AND on screen, with the library version so a
            // too-old libmpv is recognisable at a glance.
            var msg_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "loadfile rejected by libmpv (client API {d}.{d}): {s}", .{
                runtime_api >> 16,
                runtime_api & 0xffff,
                std.mem.span(c.mpv.mpv_error_string(rc)),
            }) catch "loadfile rejected by libmpv";
            var delivered = false;
            for (state.app.players.items) |p| {
                if (p.mpv_ctx != self.ctx) continue;
                p.setLoadError(msg);
                delivered = true;
                break;
            }
            if (!delivered) {
                logs.pushLog("error", "player", msg, true);
                state.showToast(msg);
            }
        }
    }
};

pub const video_w = 1920;
pub const video_h = 1080;

const PositionSnapshot = struct {
    identity: [MAX_LOAD_URL]u8 = undefined,
    identity_len: usize = 0,
    position: f64 = 0,
    duration: f64 = 0,
    episode_active: bool = false,
    tmdb_id: i32 = 0,
    season: i32 = 0,
    episode: i32 = 0,
    played_seconds: f64 = 0,
    catalog_movie_tmdb_id: i32 = 0,
};

const PositionSaveJob = struct {
    snapshot: PositionSnapshot,
    force_remote: bool,
    sequence: u64,
};

const POSITION_SAVE_QUEUE_CAP: usize = 16;
const position_save_pure = @import("position_save_pure.zig");
var position_save_sequence = std.atomic.Value(u64).init(0);
var position_save_pending = std.atomic.Value(u32).init(0);
var position_save_queue: [POSITION_SAVE_QUEUE_CAP]PositionSaveJob = undefined;
var position_save_queue_head: usize = 0;
var position_save_queue_count: usize = 0;
var position_save_worker_active: bool = false;
var position_save_queue_mutex: @import("../core/sync.zig").Mutex = .{};
var position_save_stamps: [16]position_save_pure.Stamp = [_]position_save_pure.Stamp{.{}} ** 16;
var position_save_stamp_cursor: usize = 0;
var playback_load_sequence = std.atomic.Value(u64).init(0);

fn samePositionIdentity(a: PositionSnapshot, b: PositionSnapshot) bool {
    return a.identity_len == b.identity_len and
        std.mem.eql(u8, a.identity[0..a.identity_len], b.identity[0..b.identity_len]);
}

fn persistPositionSnapshot(snapshot: PositionSnapshot, force_remote: bool) void {
    if (state.app.incognito_mode or snapshot.identity_len == 0) return;
    const identity = snapshot.identity[0..snapshot.identity_len];
    const percent = if (snapshot.duration > 0) (snapshot.position / snapshot.duration) * 100.0 else 0;
    // Activity owns UI-thread current-item state; publish here rather than from
    // the database worker. Durable persistence below deliberately skips it.
    @import("../services/activity.zig").onProgress(identity, percent);

    const job: PositionSaveJob = .{
        .snapshot = snapshot,
        .force_remote = force_remote,
        .sequence = position_save_sequence.fetchAdd(1, .acq_rel) + 1,
    };

    var start_worker = false;
    position_save_queue_mutex.lock();
    var coalesced = false;
    for (0..position_save_queue_count) |offset| {
        const index = (position_save_queue_head + offset) % POSITION_SAVE_QUEUE_CAP;
        if (!samePositionIdentity(position_save_queue[index].snapshot, snapshot)) continue;
        const preserve_force = position_save_queue[index].force_remote;
        position_save_queue[index] = job;
        position_save_queue[index].force_remote = preserve_force or force_remote;
        coalesced = true;
        break;
    }
    if (!coalesced) {
        if (position_save_queue_count < POSITION_SAVE_QUEUE_CAP) {
            const tail = (position_save_queue_head + position_save_queue_count) % POSITION_SAVE_QUEUE_CAP;
            position_save_queue[tail] = job;
            position_save_queue_count += 1;
            _ = position_save_pending.fetchAdd(1, .acq_rel);
        } else {
            // Keep memory and worker use fixed under pathological rapid media
            // switching. The newest resume point is more useful than the
            // oldest queued one, and the in-flight save remains untouched.
            position_save_queue[position_save_queue_head] = job;
        }
    }
    if (!position_save_worker_active) {
        position_save_worker_active = true;
        start_worker = true;
    }
    position_save_queue_mutex.unlock();

    if (!start_worker) return;
    @import("../core/workers.zig").spawn(positionSaveDrainWorker, .{}) catch {
        // Resource exhaustion is exceptional; preserve resume correctness even
        // then. The active latch makes this caller the sole synchronous drainer.
        positionSaveDrainWorker();
    };
}

fn writePositionSave(job: PositionSaveJob) void {
    const snapshot = job.snapshot;
    const identity = snapshot.identity[0..snapshot.identity_len];
    const identity_hash = std.hash.Wyhash.hash(0, identity);

    // The single drainer serializes stores. Keep the sequence gate as a final
    // defense if a queued item was superseded while its predecessor was active.
    if (!position_save_pure.accept(&position_save_stamps, &position_save_stamp_cursor, identity_hash, job.sequence)) return;

    @import("../services/history.zig").savePlaybackPositionBackground(identity, snapshot.position, snapshot.duration, snapshot.catalog_movie_tmdb_id);
    @import("../services/server_progress.zig").submit(identity, snapshot.position, snapshot.duration, job.force_remote);
    if (snapshot.episode_active) {
        @import("../core/db.zig").tvSavePosition(
            snapshot.tmdb_id,
            snapshot.season,
            snapshot.episode,
            snapshot.position,
            snapshot.duration,
        );
        @import("../core/db.zig").tvSavePlayedSeconds(
            snapshot.tmdb_id,
            snapshot.season,
            snapshot.episode,
            snapshot.played_seconds,
        );
    }
}

fn positionSaveDrainWorker() void {
    while (true) {
        position_save_queue_mutex.lock();
        if (position_save_queue_count == 0) {
            // Publish idle while holding the producer lock. An enqueue can now
            // either be observed by us or take responsibility for a new worker.
            position_save_worker_active = false;
            position_save_queue_mutex.unlock();
            return;
        }
        const job = position_save_queue[position_save_queue_head];
        position_save_queue_head = (position_save_queue_head + 1) % POSITION_SAVE_QUEUE_CAP;
        position_save_queue_count -= 1;
        position_save_queue_mutex.unlock();

        writePositionSave(job);
        _ = position_save_pending.fetchSub(1, .acq_rel);
    }
}

/// Final resume persistence must enqueue its authenticated server update before
/// server_progress.flushForShutdown() runs. Keep this barrier short; the global
/// owned-worker drain still guarantees local DB completion after the window is
/// hidden if storage is unusually slow.
pub fn flushPositionSavesForShutdown(timeout_ms: i64) void {
    const io_g = @import("../core/io_global.zig");
    const deadline = io_g.monotonicMilliTimestamp() + @max(timeout_ms, 1);
    while (position_save_pending.load(.acquire) != 0 and io_g.monotonicMilliTimestamp() < deadline) {
        io_g.sleep(std.time.ns_per_ms);
    }
}

pub const MediaPlayer = struct {
    mpv_ctx: *c.mpv.mpv_handle,
    mpv_gl: ?*c.mpv.mpv_render_context,
    /// Front buffer: the last frame the render worker finished. Read by the
    /// UI upload and by frame OCR — both under `frame_mutex`.
    pixels: []dvui.Color.PMA,
    texture: ?dvui.Texture,

    // ── Software render worker ──
    // mpv's SW render API rasterises on the CALLING thread (colour
    // conversion, scaling, OSD). Doing that on the UI thread stalled every
    // dvui frame for the whole conversion (25–200 ms at 4K). `render_thread`
    // renders into `back_pixels` and swaps it with `pixels` under
    // `frame_mutex`; the UI thread only uploads the front buffer.
    back_pixels: []dvui.Color.PMA,
    render_thread: ?std.Thread,
    render_stop: std.atomic.Value(bool),
    /// Set by mpv's update callback (any thread) to wake the worker.
    render_wake: std.Io.Event,
    frame_mutex: @import("../core/sync.zig").Mutex,
    /// A finished frame sits in `pixels` and has not been uploaded yet.
    frame_ready: bool,
    /// Dimensions of the frame in `pixels` (row stride is frame_w * 4 bytes).
    frame_w: u32,
    frame_h: u32,
    /// Pixel layout of the frame in `pixels` (the `sw_format` it was rendered
    /// with), so the upload always creates a texture that matches the bytes
    /// even if the format choice changes after the worker started.
    frame_fmt: dvui.enums.TexturePixelFormat,
    /// Render size requested by the UI (native size capped to the buffer).
    want_w: std.atomic.Value(u32),
    want_h: std.atomic.Value(u32),
    current_torrent_id: i32,
    torrent_is_ready: bool,
    has_metadata: bool,
    last_load_time: i64,
    selected_file_idx: i32 = -1, // -1 means auto-select largest
    last_error_time: i64 = 0,
    is_buffering_paused: bool = false,
    is_loading: bool = false,
    /// Process-unique identity for this logical replacement load. Async
    /// resolvers publish against it instead of dereferencing a stale player.
    load_serial: u64 = 0,
    loading_label: [128]u8 = std.mem.zeroes([128]u8),
    loading_label_len: usize = 0,
    load_error: [192]u8 = std.mem.zeroes([192]u8),
    load_error_len: usize = 0,
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
    playback_origin: PlaybackOrigin = .direct,
    queue_item_id: i64 = -1,
    is_torrent: bool,
    metadata_start_time: i64,
    resume_percent: f64 = 0.0,
    resume_position_secs: f64 = 0.0, // exact-second resume (wins over percent)
    /// Newest non-EOF-parked time-pos observed during playback. An EOF reload
    /// on a still-incomplete torrent resumes here instead of restarting from
    /// 0 when percent-pos is unusable (parked at ~100/NaN after the file
    /// closed). Reset on every replace load; the 5s saver re-records it once
    /// mpv reports a trustworthy position again.
    last_good_pos_secs: f64 = 0.0,
    current_url: [MAX_LOAD_URL]u8 = std.mem.zeroes([MAX_LOAD_URL]u8),
    current_url_len: usize = 0,
    fallback_url: [MAX_LOAD_URL]u8 = std.mem.zeroes([MAX_LOAD_URL]u8),
    fallback_url_len: usize = 0,
    fallback_recovery: playback_fallback.State = .{},
    server_recovery_attempted: bool = false,
    history_identity: [2048]u8 = std.mem.zeroes([2048]u8),
    history_identity_len: usize = 0,
    restore_target: [2048]u8 = std.mem.zeroes([2048]u8),
    restore_target_len: usize = 0,
    current_user_agent: [2048]u8 = std.mem.zeroes([2048]u8),
    current_user_agent_len: usize = 0,
    current_header_fields: [2048]u8 = std.mem.zeroes([2048]u8),
    current_header_fields_len: usize = 0,
    current_loopback_stream: bool = false,
    /// First-attempt YouTube manifest skipping is safe for normal videos. Keep
    /// one robust retry armed until FILE_LOADED for live/restricted edge cases.
    ytdl_fast_retry_pending: bool = false,
    resume_seeked: bool = false,
    restore_session_position: ?f64 = null,
    provider_resume_position: ?f64 = null,
    restore_session_paused: bool = true,
    restore_session_speed: f64 = 1,
    /// Monotonic deadline for playback-position persistence. Database writes
    /// must follow elapsed time, not video/UI frame rate.
    last_position_save_ms: i64 = 0,
    provider: state.ContentProvider = .mpv,

    // ── Cached mpv properties (A4) ──
    // Populated via mpv_observe_property + MPV_EVENT_PROPERTY_CHANGE in the
    // event loop (see updateTorrentBackgroundTasks) so the per-frame render
    // path doesn't issue synchronous IPC (or per-frame allocations) for these.
    cached_paused: bool = true, // mirror of mpv "pause"
    last_seen_pos: f64 = 0, // last valid mpv time-pos seen in the event loop (co-watch rewind detect)
    cached_duration: f64 = 0,
    cached_volume: f64 = 100,
    cached_speed: f64 = 1,
    cached_muted: bool = false,
    cached_paused_for_cache: bool = false,
    cached_playlist_count: i64 = 0,
    cached_playlist_pos: i64 = 0,
    cached_video_width: i64 = 0,
    cached_video_height: i64 = 0,
    cached_hwdec: [32]u8 = std.mem.zeroes([32]u8),
    cached_hwdec_len: usize = 0,
    hwdec_fallback_notified: bool = false,
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
    /// TMDB path fragment OR a full cover URL — resolved by
    /// ui/loading_pure.posterUrl so every source can show art here.
    loading_art: [256]u8 = std.mem.zeroes([256]u8),
    loading_art_len: usize = 0,
    loading_kind: u8 = 0,
    loading_year: [8]u8 = std.mem.zeroes([8]u8),
    loading_year_len: usize = 0,
    loading_rating: f32 = 0,
    loading_extra: [96]u8 = std.mem.zeroes([96]u8),
    loading_extra_len: usize = 0,
    /// Fact-card deck state: how many times the viewer paged, and when they
    /// last did (the auto-rotate clock restarts from there so a manual page
    /// gets a full interval instead of flipping again immediately).
    loading_card_manual: usize = 0,
    loading_card_since_ms: i64 = 0,
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
    /// Verified TMDB movie identity copied through the pending-play handoff.
    /// Playback must accumulate real viewed time before account sync fires.
    catalog_tmdb_id: i32 = 0,
    catalog_movie_committed: bool = false,
    catalog_played_seconds: f64 = 0,
    catalog_sample_ms: i64 = 0,
    catalog_sample_pos: f64 = 0,

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

    /// Allocation-free render snapshot. All fields are mirrors maintained by
    /// mpv property-change events, so callers never synchronously cross into
    /// libmpv while laying out a frame.
    pub fn playbackSnapshot(self: *const MediaPlayer) PlaybackSnapshot {
        return .{
            .paused = self.cached_paused,
            .paused_for_cache = self.cached_paused_for_cache,
            .time_pos = self.last_seen_pos,
            .duration = self.cached_duration,
            .volume = self.cached_volume,
            .speed = self.cached_speed,
            .muted = self.cached_muted,
            .playlist_count = self.cached_playlist_count,
            .playlist_pos = self.cached_playlist_pos,
            .video_width = self.cached_video_width,
            .video_height = self.cached_video_height,
        };
    }

    /// Replay viewer-level choices onto this mpv context. Safe before, during,
    /// or after a load; used when async config finishes after a fast CLI open.
    pub fn applyPersistentPreferences(self: *MediaPlayer) void {
        var volume = state.app.playback_volume;
        var speed = state.app.playback_speed;
        var muted: c_int = if (state.app.playback_muted) 1 else 0;
        _ = c.mpv.mpv_set_property(self.mpv_ctx, "volume", c.mpv.MPV_FORMAT_DOUBLE, &volume);
        _ = c.mpv.mpv_set_property(self.mpv_ctx, "speed", c.mpv.MPV_FORMAT_DOUBLE, &speed);
        _ = c.mpv.mpv_set_property(self.mpv_ctx, "mute", c.mpv.MPV_FORMAT_FLAG, &muted);
        if (state.app.audio_lang_len > 0)
            _ = c.mpv.mpv_set_property_string(self.mpv_ctx, "alang", state.app.audio_lang_buf[0..].ptr);
        if (state.app.sub_lang_len > 0)
            _ = c.mpv.mpv_set_property_string(self.mpv_ctx, "slang", state.app.sub_lang_buf[0..].ptr);
        _ = c.mpv.mpv_set_property_string(self.mpv_ctx, "sub-visibility", if (state.app.subtitles_enabled) "yes" else "no");
        if (state.app.audio_device_len > 0)
            _ = c.mpv.mpv_set_property_string(self.mpv_ctx, "audio-device", state.app.audio_device_buf[0..].ptr);
        if (state.app.video_aspect_len > 0)
            _ = c.mpv.mpv_set_property_string(self.mpv_ctx, "video-aspect-override", state.app.video_aspect_buf[0..].ptr);
        self.cached_volume = volume;
        self.cached_speed = speed;
        self.cached_muted = muted != 0;
        self.cell_volume = volume;
        self.cell_speed = speed;
    }

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
                var safe_title_buf: [2048]u8 = undefined;
                const display_title = @import("watch_history_pure.zig").persistedTarget(ts, &safe_title_buf).identity;
                const limit = @min(display_title.len, out_buf.len);
                @memcpy(out_buf[0..limit], display_title[0..limit]);
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
        return initPrepared(allocator, true);
    }

    fn maybeNotifyHwdecFallback(self: *MediaPlayer) void {
        const current: ?[]const u8 = if (self.cached_hwdec_len > 0)
            self.cached_hwdec[0..self.cached_hwdec_len]
        else
            null;
        if (!@import("hwdec_feedback_pure.zig").shouldNotify(
            state.app.hwdec_enabled,
            current,
            self.cached_video_width,
            self.cached_video_height,
            self.hwdec_fallback_notified,
        )) return;
        self.hwdec_fallback_notified = true;
        logs.pushLog("warn", "player", "Hardware decoding unavailable for this video; using software decoding", false);
        state.showToast("GPU decode unavailable — using software for this video");
    }

    fn initPrepared(allocator: std.mem.Allocator, start_renderer: bool) !*MediaPlayer {
        const self = try allocator.create(MediaPlayer);
        self.texture = null;
        self.current_torrent_id = -1;
        self.torrent_is_ready = false;
        self.has_metadata = false;
        self.last_load_time = 0;
        self.last_error_time = 0;
        self.is_buffering_paused = false;
        self.load_serial = 0;
        self.selected_file_idx = -1;
        self.cell_volume = state.app.playback_volume;
        self.cell_speed = state.app.playback_speed;
        self.loop_a = -1.0;
        self.loop_b = -1.0;
        self.is_flipped = false;
        self.rotation = 0;
        self.source_url_len = 0;
        self.playback_origin = .direct;
        self.queue_item_id = -1;
        self.is_torrent = false;
        self.metadata_start_time = 0;
        self.resume_percent = 0.0;
        self.resume_position_secs = 0.0;
        self.last_good_pos_secs = 0.0;
        @memset(&self.source_url, 0);
        @memset(&self.current_url, 0);
        self.current_url_len = 0;
        @memset(&self.fallback_url, 0);
        self.fallback_url_len = 0;
        self.fallback_recovery = .{};
        self.server_recovery_attempted = false;
        @memset(&self.history_identity, 0);
        self.history_identity_len = 0;
        @memset(&self.restore_target, 0);
        self.restore_target_len = 0;
        @memset(&self.current_user_agent, 0);
        self.current_user_agent_len = 0;
        @memset(&self.current_header_fields, 0);
        self.current_header_fields_len = 0;
        self.current_loopback_stream = false;
        self.ytdl_fast_retry_pending = false;
        self.resume_seeked = false;
        self.restore_session_position = null;
        self.provider_resume_position = null;
        self.restore_session_paused = true;
        self.restore_session_speed = 1;
        self.last_position_save_ms = 0;
        self.is_loading = false;
        self.loading_label_len = 0;
        @memset(&self.load_error, 0);
        self.load_error_len = 0;
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
        self.cached_duration = 0;
        self.cached_volume = state.app.playback_volume;
        self.cached_speed = state.app.playback_speed;
        self.cached_muted = state.app.playback_muted;
        self.cached_paused_for_cache = false;
        self.cached_playlist_count = 0;
        self.cached_playlist_pos = 0;
        self.cached_video_width = 0;
        self.cached_video_height = 0;
        @memset(&self.cached_hwdec, 0);
        self.cached_hwdec_len = 0;
        self.hwdec_fallback_notified = false;
        self.anime_skip_active = false;
        self.cached_vid_no = false;
        self.vis_applied = false;
        @memset(&self.cached_sub_text, 0);
        self.cached_sub_text_len = 0;
        @memset(&self.loading_label, 0);
        self.loading_title_len = 0;
        @memset(&self.loading_title, 0);
        self.loading_art_len = 0;
        @memset(&self.loading_art, 0);
        self.loading_kind = 0;
        self.loading_year_len = 0;
        @memset(&self.loading_year, 0);
        self.loading_rating = 0;
        self.loading_extra_len = 0;
        @memset(&self.loading_extra, 0);
        self.loading_card_manual = 0;
        self.loading_card_since_ms = 0;
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
        self.catalog_tmdb_id = 0;
        self.catalog_movie_committed = false;
        self.catalog_played_seconds = 0;
        self.catalog_sample_ms = 0;
        self.catalog_sample_pos = 0;
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

        self.render_thread = null;
        self.render_stop = std.atomic.Value(bool).init(false);
        self.render_wake = .unset;
        self.frame_mutex = .{};
        self.frame_ready = false;
        self.frame_w = 0;
        self.frame_h = 0;
        self.frame_fmt = swTextureFormat();
        self.want_w = std.atomic.Value(u32).init(0);
        self.want_h = std.atomic.Value(u32).init(0);
        if (state.app.is_headless or !start_renderer) {
            // Headless: no display surface, so no software-render pixel buffer.
            // Empty slice — deinit's allocator.free on a zero-len slice is a no-op.
            self.pixels = &.{};
            self.back_pixels = &.{};
        } else {
            self.pixels = try allocator.alloc(dvui.Color.PMA, video_w * video_h);
            self.back_pixels = allocator.alloc(dvui.Color.PMA, video_w * video_h) catch |err| {
                allocator.free(self.pixels);
                return err;
            };
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
            allocator.free(self.back_pixels);
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
        // `load-console` is the current mpv option. Keep the legacy spelling as
        // a harmless compatibility attempt for older packaged builds.
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "load-console", "no");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "load-osd-console", "no");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "load-select", "no");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "load-positioning", "no");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "load-commands", "no");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "load-context-menu", "no");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "load-stats-overlay", "no");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "load-auto-profiles", "no");
        // Opal owns all keyboard, pointer and chrome input. Avoid initializing
        // mpv's unused input bindings and terminal/status machinery.
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "input-builtin-bindings", "no");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "input-default-bindings", "no");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "input-cursor", "no");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "msg-level", "all=warn");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "terminal", "no");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "clipboard-backends", "");

        // Let mpv cache network/slow sources but bypass its demuxer cache for
        // ordinary local files. Forcing cache=yes made cold disk opens retain
        // data they can seek directly.
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "cache", "auto");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "cache-secs", "120");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "demuxer-max-bytes", "300MiB");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "demuxer-readahead-secs", "60");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "demuxer-max-back-bytes", "100MiB");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "force-seekable", "no");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "hr-seek", "yes");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "keep-open", "always");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "loop-file", "inf");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "demuxer-seekable-cache", "auto");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "idle", "yes");

        // ── Opt-in playback options ──
        //
        // Adopted from JJenkx/mpv-atmos-patched's tuning guide, but only the
        // options that exist in UPSTREAM mpv — verified against this build with
        // `mpv --list-options` on 2026-08-01. That repo's headline features
        // (TrueHD/Atmos MAT passthrough, http-segmented-connections,
        // demuxer-cache-unselected-*) live in its own patched mpv+FFmpeg and are
        // NOT reachable from a system mpv, so they are deliberately not here.
        //
        // Every one defaults OFF, because each trades something real:
        if (state.app.prefetch_playlist) {
            // Makes next-episode transitions instant. Costs a second concurrent
            // download — on a torrent that is a whole extra swarm, which is why
            // this is not the default for a streaming-first app.
            _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "prefetch-playlist", "yes");
        }
        if (state.app.audio_passthrough) {
            // Bitstream compressed audio to an AVR instead of decoding it.
            // TrueHD is deliberately absent: upstream mpv cannot emit the MAT
            // framing Atmos needs (that is the entire reason the atmos fork
            // exists), so listing it here would advertise silence.
            _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "audio-spdif", "ac3,dts,eac3");
        }
        if (state.app.audio_exclusive) {
            // Exclusive device access: bit-perfect, but nothing else on the
            // machine can make a sound while a player is open.
            _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "audio-exclusive", "yes");
        }

        // ── Network stream resilience ──
        // With HTTP proxy for torrents, cache-pause works correctly:
        // the proxy stalls HTTP when pieces aren't ready, mpv shows "Buffering..."
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "cache-pause", "yes");
        // Typed loads override this to yes only for the blocking torrent proxy.
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "cache-pause-initial", "no");
        // 1s (mpv's own default), not 3. cache-pause-initial means mpv opens in
        // the buffering state and will not start until this many seconds of
        // media are demuxed — pulled through a proxy that blocks per piece. At 3
        // that was a fixed multi-second wait bolted onto every torrent start,
        // on top of the gate's own 4 MB and the demuxer's index seek. cache-pause
        // still re-buffers if the swarm can't keep up, so the cost of starting
        // earlier is a possible early re-buffer, not a stutter.
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "cache-pause-wait", "1");
        // Network timeouts — retry aggressively instead of giving up
        // Ordinary web reads get a finite recovery deadline.
        //
        // Infinite reads remain load-bearing for torrent streaming. ffmpeg cannot distinguish a
        // read ERROR from end-of-file (demux_lavf.c returns AVERROR_EOF for both),
        // so a 30s timeout on a slow torrent read reached mpv as "the file ended" —
        // it stopped cleanly, with no error, and no amount of further downloading
        // brought it back. YouTube/IPTV/direct HTTP use 15 seconds; the bounded
        // torrent loopback gets a 20-second defense-in-depth timeout per load.
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "network-timeout", "15");
        // reconnect_on_http_error used to appear TWICE here ("…=4xx,…=5xx").
        // stream-lavf-o is a KEY-VALUE list, so that is one key set twice and
        // ffmpeg keeps the last write — 4xx reconnects were silently disabled,
        // meaning a single 403/404 on an IPTV segment ended the stream instead
        // of retrying. ffmpeg wants ONE comma-separated value, and a comma
        // inside a value needs mpv's %<len>% escape: %7% == len("4xx,5xx").
        // (Verified against mpv 0.41 — a wrong length is a hard parse error,
        // so this escape is checked, not merely tolerated.)
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_delay_max=5,reconnect_on_network_error=1,reconnect_on_http_error=%7%4xx,5xx");
        // Prefer the highest HLS rendition. Do not force a ten-segment live-edge
        // delay; libavformat's default selects the appropriate edge.
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "hls-bitrate", "max");

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
        // Opal owns resume identity and persistence. mpv watch-later state is a
        // second filename-keyed authority and adds avoidable disk work.
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "save-position-on-quit", "no");
        _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "resume-playback", "no");

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

        // ── Escape hatch: OPAL_MPV_OPTS="name=value;name=value" ──
        // Raw mpv options applied last (they override everything above), for
        // diagnosing playback on a machine we cannot see. Not a user setting.
        applyEnvMpvOpts(self.mpv_ctx);

        // Scan scripts before init (but loading happens after)
        const scripts_mgr = @import("../services/scripts.zig");
        if (!state.app.scripts_scanned) scripts_mgr.scanScripts();

        _ = c.mpv.mpv_initialize(self.mpv_ctx);
        self.applyPersistentPreferences();

        // The render callback only fires for video frames. Wake dvui for every
        // queued client event too, so audio-only playback, pause changes and
        // late metadata cannot sit unprocessed until unrelated pointer input.
        // mpv requires this callback to remain notification-only.
        c.mpv.mpv_set_wakeup_callback(self.mpv_ctx, &mpvWakeupCallback, null);

        // ── Observe properties so the render hot path can read cached fields
        // instead of issuing synchronous mpv_get_property IPC every frame (A4).
        // Updates arrive as MPV_EVENT_PROPERTY_CHANGE in the event loop.
        _ = c.mpv.mpv_observe_property(self.mpv_ctx, 0, "pause", c.mpv.MPV_FORMAT_FLAG);
        _ = c.mpv.mpv_observe_property(self.mpv_ctx, 0, "vid", c.mpv.MPV_FORMAT_STRING);
        _ = c.mpv.mpv_observe_property(self.mpv_ctx, 0, "sub-text", c.mpv.MPV_FORMAT_STRING);
        // time-pos drives co-watch rewind detection even during silent stretches
        // (no subtitle change). Value arrives in the event payload — no per-frame IPC.
        _ = c.mpv.mpv_observe_property(self.mpv_ctx, 0, "time-pos", c.mpv.MPV_FORMAT_DOUBLE);
        _ = c.mpv.mpv_observe_property(self.mpv_ctx, 0, "duration", c.mpv.MPV_FORMAT_DOUBLE);
        _ = c.mpv.mpv_observe_property(self.mpv_ctx, 0, "volume", c.mpv.MPV_FORMAT_DOUBLE);
        _ = c.mpv.mpv_observe_property(self.mpv_ctx, 0, "speed", c.mpv.MPV_FORMAT_DOUBLE);
        _ = c.mpv.mpv_observe_property(self.mpv_ctx, 0, "mute", c.mpv.MPV_FORMAT_FLAG);
        _ = c.mpv.mpv_observe_property(self.mpv_ctx, 0, "paused-for-cache", c.mpv.MPV_FORMAT_FLAG);
        _ = c.mpv.mpv_observe_property(self.mpv_ctx, 0, "playlist-count", c.mpv.MPV_FORMAT_INT64);
        _ = c.mpv.mpv_observe_property(self.mpv_ctx, 0, "playlist-pos", c.mpv.MPV_FORMAT_INT64);
        _ = c.mpv.mpv_observe_property(self.mpv_ctx, 0, "dwidth", c.mpv.MPV_FORMAT_INT64);
        _ = c.mpv.mpv_observe_property(self.mpv_ctx, 0, "dheight", c.mpv.MPV_FORMAT_INT64);
        _ = c.mpv.mpv_observe_property(self.mpv_ctx, 0, "hwdec-current", c.mpv.MPV_FORMAT_STRING);

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
        if (start_renderer and !state.app.is_headless) {
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
            // The render worker owns every mpv_render_* call from here on: it
            // waits on `render_wake`, which mpv's update callback sets from an
            // mpv-owned thread whenever a new frame (or redraw) is pending.
            // The worker wakes dvui itself once a frame is in the front
            // buffer, so the UI only redraws when there is something to show.
            // Admitted through the owned supervisor's compatibility seam so
            // it is counted by the shutdown drain; stopRenderWorker() (run
            // from appDeinit, BEFORE the drain) is what makes it exit.
            self.render_thread = @import("../core/workers.zig").spawnLegacy(renderWorker, .{self}) catch |err| {
                // Same degrade path as a failed render context: audio and
                // controls keep working, video stays black for this player.
                std.debug.print("[player] render worker spawn failed: {s}\n", .{@errorName(err)});
                logs.pushLog("error", "player", "video render thread could not start — video disabled for this player (audio still works)", true);
                c.mpv.mpv_render_context_free(self.mpv_gl);
                self.mpv_gl = null;
                return self;
            };
            c.mpv.mpv_render_context_set_update_callback(self.mpv_gl, &mpvRenderUpdateCallback, @ptrCast(self));
        }
        return self;
    }

    /// Attach the software renderer to a player whose libmpv core was prepared
    /// off-thread. Texture upload still remains owned by the UI thread.
    fn startPreparedRenderer(self: *MediaPlayer, allocator: std.mem.Allocator) !void {
        if (state.app.is_headless or self.mpv_gl != null) return;
        if (self.pixels.len == 0) {
            self.pixels = try allocator.alloc(dvui.Color.PMA, video_w * video_h);
            self.back_pixels = allocator.alloc(dvui.Color.PMA, video_w * video_h) catch |err| {
                allocator.free(self.pixels);
                self.pixels = &.{};
                return err;
            };
        }

        var params = [_]c.mpv.mpv_render_param{
            .{ .type = c.mpv.MPV_RENDER_PARAM_API_TYPE, .data = @constCast(c.mpv.MPV_RENDER_API_TYPE_SW) },
            .{ .type = c.mpv.MPV_RENDER_PARAM_INVALID, .data = null },
        };
        if (c.mpv.mpv_render_context_create(&self.mpv_gl, self.mpv_ctx, &params) < 0) {
            self.mpv_gl = null;
            logs.pushLog("error", "player", "mpv render context unavailable; audio remains usable", true);
            return;
        }
        self.render_thread = @import("../core/workers.zig").spawnLegacy(renderWorker, .{self}) catch |err| {
            std.debug.print("[player] render worker spawn failed: {s}\n", .{@errorName(err)});
            logs.pushLog("error", "player", "video render worker unavailable; audio remains usable", true);
            c.mpv.mpv_render_context_free(self.mpv_gl);
            self.mpv_gl = null;
            return;
        };
        c.mpv.mpv_render_context_set_update_callback(self.mpv_gl, &mpvRenderUpdateCallback, @ptrCast(self));
    }

    /// Software render worker. Loop: wait for mpv's "new frame" signal, ask
    /// mpv what changed, rasterise the frame into the back buffer at the size
    /// the UI asked for, publish it as the front buffer, wake dvui.
    ///
    /// mpv paces us: mpv_render_context_render blocks until the frame's
    /// target display time (its default), so the worker sleeps between frames
    /// and never spins. Only this thread calls mpv_render_* after init.
    fn renderWorker(self: *MediaPlayer) void {
        const io = @import("../core/io_global.zig").io();
        while (true) {
            self.render_wake.waitUncancelable(io);
            self.render_wake.reset();
            if (self.render_stop.load(.acquire)) return;
            const gl = self.mpv_gl orelse return;

            const flags = c.mpv.mpv_render_context_update(gl);
            if ((flags & c.mpv.MPV_RENDER_UPDATE_FRAME) == 0) continue;

            var w = self.want_w.load(.acquire);
            var h = self.want_h.load(.acquire);
            if (w < 2 or h < 2 or @as(usize, w) * @as(usize, h) > self.back_pixels.len) {
                w = video_w;
                h = video_h;
            }
            const size = [2]c_int{ @intCast(w), @intCast(h) };
            const pitch: usize = @as(usize, w) * 4;
            // Snapshot the format for this frame: the UI may switch
            // `sw_format` once (native texture format pick) after we started.
            const fmt = sw_format;
            var params = [_]c.mpv.mpv_render_param{
                .{ .type = c.mpv.MPV_RENDER_PARAM_SW_SIZE, .data = @constCast(&size) },
                .{ .type = c.mpv.MPV_RENDER_PARAM_SW_FORMAT, .data = @constCast(fmt) },
                .{ .type = c.mpv.MPV_RENDER_PARAM_SW_STRIDE, .data = @constCast(&pitch) },
                .{ .type = c.mpv.MPV_RENDER_PARAM_SW_POINTER, .data = self.back_pixels.ptr },
                .{ .type = c.mpv.MPV_RENDER_PARAM_INVALID, .data = null },
            };
            const t0: i64 = if (perf.enabled) perfNow() else 0;
            const rc = c.mpv.mpv_render_context_render(gl, &params);
            if (perf.enabled) {
                const dt = perfNow() - t0;
                _ = perf.frames.fetchAdd(1, .monotonic);
                _ = perf.render_ns.fetchAdd(dt, .monotonic);
                _ = perf.render_max_ns.fetchMax(dt, .monotonic);
            }
            if (rc < 0) continue;

            // Publish: the just-rendered buffer becomes the front buffer.
            self.frame_mutex.lock();
            const front = self.pixels;
            self.pixels = self.back_pixels;
            self.back_pixels = front;
            self.frame_w = w;
            self.frame_h = h;
            self.frame_fmt = textureFormatOf(fmt);
            self.frame_ready = true;
            self.frame_mutex.unlock();
            // Wake the UI immediately after publication. Timing persistence is
            // deliberately asynchronous; diagnostics must never delay the frame
            // they are measuring.
            wakeDvuiFromMpv();
            // Trigger-to-play milestone: first published video frame. Reports
            // once per armed trigger, then disarms (openFirstFrame no-ops when
            // nothing is armed, so the per-frame cost is one branch).
            if (open_trigger_ns != 0) openFirstFrame();
        }
    }

    /// Blank both pixel buffers (new file / stop) and queue the black frame for
    /// upload, so the pane never shows the previous video's last frame.
    fn clearFrame(self: *MediaPlayer) void {
        if (self.pixels.len == 0) return;
        self.frame_mutex.lock();
        defer self.frame_mutex.unlock();
        // Front buffer only: the worker may be mid-render into the back buffer
        // (it renders outside the lock on purpose), and that render replaces
        // the back buffer's contents anyway.
        @memset(self.pixels, dvui.Color.PMA.black);
        if (self.texture) |tex| {
            self.frame_w = tex.width;
            self.frame_h = tex.height;
            self.frame_ready = true;
        }
    }

    pub fn load_file(self: *MediaPlayer, path: [*c]const u8) void {
        self.load(.{ .url = std.mem.span(path) });
    }

    fn setLoadError(self: *MediaPlayer, message: []const u8) void {
        @memset(&self.load_error, 0);
        const n = @min(message.len, self.load_error.len);
        @memcpy(self.load_error[0..n], message[0..n]);
        self.load_error_len = n;
        self.is_loading = false;
        logs.pushLog("error", "player", self.load_error[0..n], true);
        state.showToast(self.load_error[0..n]);
        state.wakeUi();
    }

    /// Start a typed media load. Replace performs the full playback transition;
    /// append deliberately changes only mpv's playlist. Both modes ultimately
    /// cross `commitPlayback`, which owns per-entry HTTP options and the sole
    /// raw media-load command.
    pub fn load(self: *MediaPlayer, request: LoadRequest) void {
        // Guard the mpv boundary. Every play path funnels through here, and
        // mpv does two hostile things with junk input: loadfile("") logs a
        // "Cannot open file ''" error, and loadfile(<directory>) expands the
        // directory into a recursive playlist walk of the entire tree (saw it
        // march through ~/Desktop/github trying every .sol/.ts file). Reject
        // both before touching player state.
        const guard_span = request.url;
        if (guard_span.len > MAX_LOAD_URL) return;
        if (!@import("resume_pure.zig").plausibleMediaPath(guard_span)) {
            @import("../core/logs.zig").pushLog("warn", "player", "Ignored empty media path", true);
            return;
        }
        var public_identity_buf: [MAX_LOAD_URL]u8 = undefined;
        const public_identity = @import("watch_history_pure.zig").persistedTarget(guard_span, &public_identity_buf).identity;
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

        // Queueing a file must not reset the current title/resume/visual state.
        // It still crosses the same command seam, but its credentials are
        // attached to the queued entry without touching the current stream.
        if (request.mode == .append) {
            self.commitPlayback(request);
            return;
        }

        // A replace starts a new logical playback owner. This is separate from
        // commitPlayback because async resolution/fallback commits belong to
        // the already-staged original request and must not erase its identity.
        @import("../services/auto_subs.zig").cancelForMediaChange();
        self.load_serial = playback_load_sequence.fetchAdd(1, .acq_rel) + 1;
        // A replace is a new logical position: a previous file's stall point
        // must never become this file's EOF-reload resume. Reloads of the SAME
        // file are unaffected — the resume fields are consumed into mpv
        // options before this runs (see the torrent readiness gate below).
        self.last_good_pos_secs = 0.0;
        self.playback_origin = request.origin;
        self.queue_item_id = if (request.origin == .queue) request.queue_item_id else -1;
        if (request.origin != .torrent) {
            self.current_torrent_id = -1;
            self.torrent_is_ready = false;
            self.is_torrent = false;
        }
        if (request.origin == .playlist) {
            const n = @min(request.url.len, self.source_url.len - 1);
            @memcpy(self.source_url[0..n], request.url[0..n]);
            self.source_url[n] = 0;
            self.source_url_len = n;
        } else if (request.origin != .torrent) {
            self.source_url_len = 0;
        }

        // Snapshot the outgoing item before its identity fields are replaced.
        // Persistence follows the new mpv handoff, so decode can begin while
        // the old resume row is committed without losing episode identity.
        const previous_position = self.captureCurrentPosition();
        self.last_position_save_ms = @import("../core/io_global.zig").monotonicMilliTimestamp();

        // Blank the pane (queued as a frame for the UI upload) so the previous
        // video's last frame never lingers under the new file's loading state.
        self.clearFrame();
        // Set loading state for UI feedback
        self.is_loading = true;
        @memset(&self.load_error, 0);
        self.load_error_len = 0;
        const path_span = request.url;
        const label = if (public_identity.len > 0) public_identity else "Private stream";
        const label_len = @min(label.len, self.loading_label.len);
        @memcpy(self.loading_label[0..label_len], label[0..label_len]);
        self.loading_label_len = label_len;

        // Store the full bounded identity for retry/resume/history. The loading
        // label is intentionally short, but must never impose its 128-byte cap
        // on a signed URL whose query credentials can be much longer.
        const url_len = @min(path_span.len, self.current_url.len);
        @memcpy(self.current_url[0..url_len], path_span[0..url_len]);
        self.current_url_len = url_len;
        const requested_identity = if (request.history_identity.len > 0) request.history_identity else public_identity;
        var identity_buf: [MAX_LOAD_URL]u8 = undefined;
        const safe_identity = @import("watch_history_pure.zig").persistedTarget(requested_identity, &identity_buf).identity;
        const identity_len = @min(safe_identity.len, self.history_identity.len);
        @memcpy(self.history_identity[0..identity_len], safe_identity[0..identity_len]);
        self.history_identity_len = identity_len;
        const requested_restore = if (request.restore_target.len > 0) request.restore_target else @import("watch_history_pure.zig").persistedTarget(path_span, &identity_buf).reopen;
        var restore_buf: [MAX_LOAD_URL]u8 = undefined;
        const safe_restore = @import("watch_history_pure.zig").persistedTarget(requested_restore, &restore_buf).reopen;
        const restore_len = @min(safe_restore.len, self.restore_target.len);
        @memcpy(self.restore_target[0..restore_len], safe_restore[0..restore_len]);
        self.restore_target_len = restore_len;
        const user_agent = playback_load.effectiveUserAgent(request);
        const ua_len = @min(user_agent.len, self.current_user_agent.len);
        @memcpy(self.current_user_agent[0..ua_len], user_agent[0..ua_len]);
        self.current_user_agent_len = ua_len;
        var header_buf: [2048]u8 = undefined;
        const header_fields = playback_load.resolvedHeaderFields(request, &header_buf);
        const header_len = @min(header_fields.len, self.current_header_fields.len);
        @memcpy(self.current_header_fields[0..header_len], header_fields[0..header_len]);
        self.current_header_fields_len = header_len;
        self.current_loopback_stream = request.loopback_stream;
        self.fallback_url_len = 0;
        self.fallback_recovery.reset();
        self.server_recovery_attempted = false;
        if (request.fallback_url.len <= self.fallback_url.len and
            playback_load.shouldArmFallback(path_span, request.fallback_url, request.mode) and
            @import("resume_pure.zig").plausibleMediaPath(request.fallback_url))
        {
            @memcpy(self.fallback_url[0..request.fallback_url.len], request.fallback_url);
            self.fallback_url_len = request.fallback_url.len;
            self.fallback_recovery.arm(true);
        }
        self.ytdl_fast_retry_pending = std.ascii.indexOfIgnoreCase(path_span, "youtube.com/") != null or
            std.ascii.indexOfIgnoreCase(path_span, "youtu.be/") != null;
        if (self.ytdl_fast_retry_pending) self.applyYtdlRawOptions(true, true);
        self.resume_seeked = false;
        self.provider_resume_position = playback_load.saneResumePosition(request.resume_position_secs);

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
            openLoadIssued();
            streamlink.resolveStreamUrlAsync(path_span, self, self.load_serial);
            if (previous_position) |snapshot| persistPositionSnapshot(snapshot, true);
            return; // Don't call mpv loadfile directly — the async thread will do it
        }

        // Clear any visualiser left over from the previous file BEFORE loading. The
        // graph maps [aid1] to both [ao] and [vo], so if it survived into a VIDEO
        // file it would replace the actual picture with a waveform. Re-armed by the
        // "vid" observer once we know the new file is audio-only.
        self.vis_applied = false;
        self.cached_video_width = 0;
        self.cached_video_height = 0;
        self.cached_hwdec_len = 0;
        self.hwdec_fallback_notified = false;
        _ = c.mpv.mpv_set_property_string(self.mpv_ctx, "lavfi-complex", "");

        // Replay the viewer's last explicit media choices before loading the
        // next file. Numeric aid/sid values are file-local, so language tags are
        // remembered instead; mpv resolves them against each new track list.
        self.applyPersistentPreferences();

        // Stamp the actual handoff, not the earlier bookkeeping phase.
        openLoadIssued();
        self.commitPlayback(request);
        if (previous_position) |snapshot| persistPositionSnapshot(snapshot, true);
        @import("../services/server_progress.zig").started(self.history_identity[0..self.history_identity_len]);

        // ── Memory hooks: record playback for cross-session intelligence ──
        {
            // Local taste engine: settles the previous item (abandon
            // detection) and logs the .play event (buffered, off-thread).
            const identity = self.history_identity[0..self.history_identity_len];
            @import("../services/activity.zig").onPlay(identity);

            const ai_memory = @import("../services/ai_memory.zig");
            const title = identity;
            if (title.len == 0) return;
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

    /// Execute an already-prepared replace/append command without beginning a
    /// second UI/resume transition. Async resolvers use this after `load()` has
    /// staged the original source identity. All other callers should use
    /// `load()`. This remains the same typed seam: replace resets persistent
    /// HTTP state, while append only configures its new playlist entry.
    pub fn commitPlayback(self: *MediaPlayer, request: LoadRequest) void {
        if (request.url.len == 0 or request.url.len > MAX_LOAD_URL) return;
        var sink: MpvPlaybackSink = .{ .ctx = self.mpv_ctx };
        _ = playback_load.dispatch(&sink, request);
    }

    /// Reserve the one provider-negotiated recovery allowed for this load.
    /// Called only after local/direct alternatives have failed.
    pub fn beginServerRecovery(self: *MediaPlayer) bool {
        if (self.server_recovery_attempted) return false;
        self.server_recovery_attempted = true;
        self.is_loading = true;
        self.load_error_len = 0;
        const label = "Negotiating compatible stream...";
        @memcpy(self.loading_label[0..label.len], label);
        self.loading_label_len = label.len;
        return true;
    }

    /// Apply a provider-generated URL without beginning another logical media
    /// transition. Identity, artwork, saved resume, and sanitized auth headers
    /// stay attached to the original item.
    pub fn applyServerRecovery(self: *MediaPlayer, url: []const u8) void {
        if (url.len == 0 or url.len > self.current_url.len or
            !@import("resume_pure.zig").plausibleMediaPath(url))
        {
            self.failServerRecovery("Server returned an unusable playback URL");
            return;
        }
        @memcpy(self.current_url[0..url.len], url);
        self.current_url_len = url.len;
        self.resume_seeked = false;
        self.is_loading = true;
        self.load_error_len = 0;
        self.commitPlayback(.{
            .url = self.current_url[0..self.current_url_len],
            .user_agent = self.current_user_agent[0..self.current_user_agent_len],
            .prepared_header_fields = self.current_header_fields[0..self.current_header_fields_len],
            .loopback_stream = self.current_loopback_stream,
        });
    }

    pub fn failServerRecovery(self: *MediaPlayer, message: []const u8) void {
        self.setLoadError(message);
    }

    /// Retry the current logical item without losing its owner, credential-free
    /// history identity, provider deep link, HTTP identity, or loopback policy.
    /// The desktop and remote player both use this seam so a retry behaves the
    /// same regardless of which surface requested it.
    pub fn retryCurrentLoad(self: *MediaPlayer) bool {
        if (self.current_url_len == 0) return false;

        var url: [MAX_LOAD_URL]u8 = undefined;
        const url_len = @min(self.current_url_len, url.len);
        @memcpy(url[0..url_len], self.current_url[0..url_len]);
        var user_agent: [2048]u8 = undefined;
        const user_agent_len = @min(self.current_user_agent_len, user_agent.len);
        @memcpy(user_agent[0..user_agent_len], self.current_user_agent[0..user_agent_len]);
        var headers: [2048]u8 = undefined;
        const headers_len = @min(self.current_header_fields_len, headers.len);
        @memcpy(headers[0..headers_len], self.current_header_fields[0..headers_len]);
        var history_identity: [2048]u8 = undefined;
        const history_len = @min(self.history_identity_len, history_identity.len);
        @memcpy(history_identity[0..history_len], self.history_identity[0..history_len]);
        var restore_target: [2048]u8 = undefined;
        const restore_len = @min(self.restore_target_len, restore_target.len);
        @memcpy(restore_target[0..restore_len], self.restore_target[0..restore_len]);

        const origin = self.playback_origin;
        const queue_item_id = self.queue_item_id;
        const loopback_stream = self.current_loopback_stream;
        self.load(.{
            .url = url[0..url_len],
            .origin = origin,
            .queue_item_id = queue_item_id,
            .history_identity = history_identity[0..history_len],
            .restore_target = restore_target[0..restore_len],
            .user_agent = user_agent[0..user_agent_len],
            .prepared_header_fields = headers[0..headers_len],
            .loopback_stream = loopback_stream,
        });
        return true;
    }

    /// Load a direct network stream with an explicit User-Agent and an arbitrary
    /// set of per-request HTTP headers (Referer, Origin, Cookie, …).
    ///
    /// This is the single code path behind every headers-aware load. The UA and
    /// `http-header-fields` are attached to the file's playlist entry; replace
    /// also clears context-wide leftovers so an unrelated later load cannot be
    /// tagged with another host's Referer/Cookie.
    ///
    /// Header joining/sanitizing lives in `http_headers_pure.buildHeaderFields`
    /// (mpv splits the option on `,`, so unsafe values are dropped there).
    pub fn loadStreamWithHttpHeaders(self: *MediaPlayer, url: []const u8, user_agent: []const u8, headers: []const HttpHeader) void {
        self.load(.{ .url = url, .user_agent = user_agent, .headers = headers });
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
        self.saveCurrentPositionImpl(false);
    }

    /// Save immediately when leaving an item, including its authenticated
    /// server progress. The network submission itself remains asynchronous.
    pub fn saveCurrentPositionFinal(self: *MediaPlayer) void {
        self.saveCurrentPositionImpl(true);
    }

    fn saveCurrentPositionImpl(self: *MediaPlayer, force_remote: bool) void {
        const snapshot = self.captureCurrentPosition() orelse return;
        persistPositionSnapshot(snapshot, force_remote);
    }

    fn captureCurrentPosition(self: *MediaPlayer) ?PositionSnapshot {
        if (self.current_url_len == 0 or self.current_url_len > self.current_url.len) return null;
        var pos: f64 = 0;
        var dur: f64 = 0;
        _ = c.mpv.mpv_get_property(self.mpv_ctx, "time-pos", c.mpv.MPV_FORMAT_DOUBLE, &pos);
        _ = c.mpv.mpv_get_property(self.mpv_ctx, "duration", c.mpv.MPV_FORMAT_DOUBLE, &dur);
        if (!(pos > 1 and dur > 5)) return null;

        const identity = if (self.history_identity_len > 0)
            self.history_identity[0..self.history_identity_len]
        else
            self.current_url[0..self.current_url_len];
        var snapshot: PositionSnapshot = .{ .position = pos, .duration = dur };
        snapshot.identity_len = @min(identity.len, snapshot.identity.len);
        @memcpy(snapshot.identity[0..snapshot.identity_len], identity[0..snapshot.identity_len]);

        // Only capture an episode binding while it matches this exact outgoing
        // stream; the copied scalar identity remains valid after the new load.
        const pe = &state.app.playing_episode;
        if (pe.matches(self.current_url[0..self.current_url_len])) {
            snapshot.episode_active = true;
            snapshot.tmdb_id = pe.tmdb_id;
            snapshot.season = pe.season;
            snapshot.episode = pe.episode;
            snapshot.played_seconds = pe.played_seconds;
        } else if (self.catalog_tmdb_id > 0) {
            snapshot.catalog_movie_tmdb_id = self.catalog_tmdb_id;
        }
        return snapshot;
    }

    /// Check for and apply saved resume position (called after first frame renders)
    pub fn tryResumePosition(self: *MediaPlayer) void {
        if (self.resume_seeked or self.current_url_len == 0 or self.current_url_len > self.current_url.len) return;
        // A connected provider supplied this position in the typed load
        // request. It neither depends on the local DB finishing its cold load
        // nor inherits "restore last session paused" semantics.
        if (self.provider_resume_position) |position| {
            self.provider_resume_position = null;
            self.resume_seeked = true;
            var command: [80]u8 = undefined;
            const seek = std.fmt.bufPrintZ(&command, "seek {d:.3} absolute", .{position}) catch return;
            _ = c.mpv.mpv_command_string(self.mpv_ctx, seek.ptr);
            return;
        }
        // A media-first launch can beat the background DB/config load. Keep the
        // attempt armed so the regular frame tick retries as soon as history is
        // published instead of permanently treating the item as new.
        if (!state.app.init_history_loaded) return;
        self.resume_seeked = true;
        const pe = &state.app.playing_episode;
        const cur = self.current_url[0..self.current_url_len];
        if (pe.armed) {
            pe.armed = false;
            const n = @min(cur.len, pe.url.len);
            @memcpy(pe.url[0..n], cur[0..n]);
            pe.url_len = n;
            pe.played_seconds = @import("../core/db.zig").tvPlayedSeconds(pe.tmdb_id, pe.season, pe.episode);
            pe.sample_ms = 0;
            pe.active = true;
            const pw = &state.app.pending_watch;
            @import("../core/db.zig").tvTouchShow(pe.tmdb_id, pw.name[0..pw.name_len], pw.poster_path[0..pw.poster_path_len]);
            @import("../services/tv_library.zig").markDirty();
        }
        if (self.restore_session_position) |position| {
            self.restore_session_position = null;
            var paused: c_int = if (self.restore_session_paused) 1 else 0;
            var speed = self.restore_session_speed;
            _ = c.mpv.mpv_set_property(self.mpv_ctx, "pause", c.mpv.MPV_FORMAT_FLAG, &paused);
            _ = c.mpv.mpv_set_property(self.mpv_ctx, "speed", c.mpv.MPV_FORMAT_DOUBLE, &speed);
            var command: [80]u8 = undefined;
            const seek = std.fmt.bufPrintZ(&command, "seek {d:.3} absolute", .{position}) catch return;
            _ = c.mpv.mpv_command_string(self.mpv_ctx, seek.ptr);
            return;
        }
        const history = @import("../services/history.zig");

        // Claim a pending episode arm: this load is the episode that was just
        // launched, so bind the binding to THIS url. Everything afterwards
        // (position saves, resumes) is gated on the url still matching, so the
        // binding dies with the media rather than leaking onto the next thing
        // that plays.

        // Prefer the per-episode position for a tracked episode. The URL-keyed
        // lookup can't help there: an episode's URL is a torrent/stream link that
        // differs between sessions, so the same episode resumed from a different
        // magnet would look brand new.
        const saved_pos = if (pe.matches(cur))
            @import("../core/db.zig").tvGetPosition(pe.tmdb_id, pe.season, pe.episode)
        else
            history.getPlaybackPosition(if (self.history_identity_len > 0)
                self.history_identity[0..self.history_identity_len]
            else
                cur);

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

    /// Remove a deleted torrent from this player without removing the player
    /// pane. Stop mpv before the torrent session/file is torn down, so Windows
    /// can release its open file handle; clear the logical load as well as the
    /// transport so the last frame, loading overlay and mini-player disappear.
    pub fn unloadRemovedTorrent(self: *MediaPlayer, torrent_id: i32) void {
        if (self.current_torrent_id != torrent_id) return;
        self.load_serial = playback_load_sequence.fetchAdd(1, .acq_rel) + 1;
        const stream_proxy = @import("stream_proxy.zig");
        if (self.proxy_handle.isValid()) {
            // Cancel pending torrent reads before issuing a synchronous mpv
            // stop, otherwise the demuxer can hold the UI thread until its
            // network-read timeout expires.
            stream_proxy.stopProxy(self.proxy_handle);
            self.proxy_handle = stream_proxy.INVALID_HANDLE;
        }
        _ = c.mpv.mpv_command_string(self.mpv_ctx, "stop");
        self.clearFrame();
        self.current_torrent_id = -1;
        self.selected_file_idx = -1;
        self.is_torrent = false;
        self.playback_origin = .direct;
        self.queue_item_id = -1;
        self.torrent_is_ready = false;
        self.has_metadata = false;
        self.is_buffering_paused = false;
        self.is_loading = false;
        self.metadata_start_time = 0;
        self.current_url_len = 0;
        self.source_url_len = 0;
        self.fallback_url_len = 0;
        self.fallback_recovery = .{};
        self.current_loopback_stream = false;
        self.ytdl_fast_retry_pending = false;
        self.history_identity_len = 0;
        self.restore_target_len = 0;
        self.loading_label_len = 0;
        self.load_error_len = 0;
        self.np_title_len = 0;
        self.np_subtitle_len = 0;
        self.restore_session_position = null;
        self.provider_resume_position = null;
        self.resume_seeked = false;
        self.last_good_pos_secs = 0;
        self.last_seen_pos = 0;
        self.cached_duration = 0;
        self.cached_paused = true;
        state.wakeUi();
    }

    /// Silence playback as soon as application shutdown starts. The command is
    /// asynchronous so a demuxer blocked on network/torrent input cannot stall
    /// the UI thread while the native window is being closed.
    pub fn stopForShutdown(self: *MediaPlayer) void {
        var args = [_][*c]const u8{ "stop", null };
        _ = c.mpv.mpv_command_async(self.mpv_ctx, 0, &args);
    }

    /// Stop and join the software render worker (idempotent; video stays
    /// black afterwards, so this is shutdown-only). The worker is admitted
    /// through the owned supervisor and players are destroyed only AFTER the
    /// worker drain, so appDeinit calls this BEFORE the drain — otherwise
    /// every shutdown would wait out the drain deadline on a thread that only
    /// exits in deinit. Must run before mpv_render_context_free: only one
    /// thread may be inside mpv_render_* at a time, and the worker may be
    /// parked in mpv_render_context_render waiting for a frame's target time
    /// (at most one frame interval).
    pub fn stopRenderWorker(self: *MediaPlayer) void {
        if (self.render_thread) |t| {
            self.render_stop.store(true, .release);
            self.render_wake.set(@import("../core/io_global.zig").io());
            t.join();
            self.render_thread = null;
        }
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

        self.applyYtdlRawOptions(true, false);

        // script-opts: ytdl_hook config (+ sponsorblock). Built by
        // ytdl_opts_pure.buildScriptOpts (tested) because the old ad-hoc
        // string started its exclude value with `%`, which mpv parses as its
        // %<len>% escape — the WHOLE option was rejected, ytdl_path with it,
        // and YouTube only worked where a system yt-dlp happened to be on PATH.
        const ytdl_opts = @import("ytdl_opts_pure.zig");
        var buf: [512]u8 = undefined;
        if (ytdl_opts.buildScriptOpts(.{
            .ytdl_path = ytdl_path,
            .sponsorblock = state.app.sponsorblock_enabled,
        }, &buf)) |opts| {
            _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "script-opts", opts.ptr);
        }
    }

    fn applyYtdlRawOptions(self: *MediaPlayer, fast: bool, runtime: bool) void {
        // ytdl-raw-options is a top-level mpv option (NOT script-opts!).
        // Never silently borrow browser logins or inherit unrelated yt-dlp config.
        // TLS verification stays enabled; a browser profile's existence is not consent.
        // no-playlist: prevent ytdl_hook from expanding model/channel pages
        // Raw options are built by ytdl_opts_pure (tested) so the exact string
        // mpv receives is covered — including the regression that no YouTube
        // player client may be pinned here (see that module's header).
        const ytdl_opts = @import("ytdl_opts_pure.zig");
        var raw_buf: [400]u8 = undefined;
        if (ytdl_opts.buildRawOptions(.{
            .proxy = state.app.proxy_url[0..state.app.proxy_url_len],
            // Additive (deno stays yt-dlp's default); a missing node only
            // reproduces the "no JS runtime" warning, so no probing needed.
            .js_runtime = "node",
            .youtube_fast = fast,
        }, &raw_buf)) |raw| {
            var raw_z: [401]u8 = undefined;
            @memcpy(raw_z[0..raw.len], raw);
            raw_z[raw.len] = 0;
            if (runtime) {
                _ = c.mpv.mpv_set_property_string(self.mpv_ctx, "ytdl-raw-options", &raw_z);
            } else {
                _ = c.mpv.mpv_set_option_string(self.mpv_ctx, "ytdl-raw-options", &raw_z);
            }
        }
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

        if (@import("../core/workers.zig").spawnLegacy(struct {
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
                if (term == .exited and term.exited == 0) {
                    state.showToast("Clip exported!");
                    logs.pushLog("info", "clip", "Clip exported successfully", false);
                } else {
                    state.showToast("Clip export failed (ffmpeg error)");
                }
            }
        }.worker, .{ectx})) |t| @import("../core/workers.zig").release(t) else |_| {
            ctx_alloc.destroy(ectx);
            state.showToast("Failed to spawn export thread");
        }
    }

    pub fn deinit(self: *MediaPlayer, allocator: std.mem.Allocator) void {
        self.saveCurrentPositionFinal();
        @import("../core/poster.zig").deinitPoster(&self.loading_poster_pixels, &self.loading_poster_tex);
        @import("../core/poster.zig").deinitPoster(&self.np_art_pixels, &self.np_art_tex);
        if (self.proxy_handle.isValid()) {
            @import("stream_proxy.zig").stopProxy(self.proxy_handle);
            self.proxy_handle = @import("stream_proxy.zig").INVALID_HANDLE;
        }
        // Stop the render worker BEFORE freeing the render context: only one
        // thread may be inside mpv_render_* at a time, and the worker may be
        // parked in mpv_render_context_render waiting for a frame's target
        // time (at most one frame interval).
        self.stopRenderWorker();
        c.mpv.mpv_render_context_free(self.mpv_gl);
        c.mpv.mpv_terminate_destroy(self.mpv_ctx);
        allocator.free(self.pixels);
        allocator.free(self.back_pixels);
        allocator.destroy(self);
    }
};

// One prepared idle engine removes libmpv/script initialization from the first
// Home/Recents click. It is scheduled only after the first painted window and
// config restore, so process startup and file-association launches stay lean.
var warm_started = std.atomic.Value(bool).init(false);
var warm_done = std.atomic.Value(bool).init(false);
var warm_cancel = std.atomic.Value(bool).init(false);
var warm_event: std.Io.Event = .unset;
var warm_mutex: @import("../core/sync.zig").Mutex = .{};
var warm_player: ?*MediaPlayer = null;

pub fn scheduleWarmPlayer(allocator: std.mem.Allocator) void {
    if (state.app.is_headless or state.app.players.items.len != 0) return;
    if (warm_started.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
    @import("../core/workers.zig").spawn(warmPlayerWorker, .{allocator}) catch {
        warm_done.store(true, .release);
        warm_event.set(@import("../core/io_global.zig").io());
    };
}

fn warmPlayerWorker(allocator: std.mem.Allocator) void {
    defer {
        warm_done.store(true, .release);
        warm_event.set(@import("../core/io_global.zig").io());
        // A playback request may have been deferred instead of blocking the UI
        // on this worker. Publish completion before waking the frame loop so it
        // can acquire the prepared core immediately.
        state.wakeUi();
    }
    if (warm_cancel.load(.acquire) or @import("../core/workers.zig").isQuitting()) return;
    const prepared = MediaPlayer.initPrepared(allocator, false) catch return;
    if (warm_cancel.load(.acquire) or @import("../core/workers.zig").isQuitting()) {
        prepared.deinit(allocator);
        return;
    }
    warm_mutex.lock();
    warm_player = prepared;
    warm_mutex.unlock();
}

/// True only while the off-thread libmpv preparation is unfinished. UI entry
/// points use this to defer their request instead of waiting inside a click.
pub fn warmPlayerPreparing() bool {
    return warm_started.load(.acquire) and !warm_done.load(.acquire);
}

/// Get the prepared engine when available; a click arriving during preparation
/// waits only for the remaining work instead of initializing a duplicate core.
pub fn acquire(allocator: std.mem.Allocator) !*MediaPlayer {
    if (warm_started.load(.acquire) and !warm_done.load(.acquire)) {
        warm_event.waitUncancelable(@import("../core/io_global.zig").io());
    }
    warm_mutex.lock();
    const prepared = warm_player;
    warm_player = null;
    warm_mutex.unlock();
    if (prepared) |p| {
        p.startPreparedRenderer(allocator) catch |err| {
            p.deinit(allocator);
            return err;
        };
        return p;
    }
    return MediaPlayer.init(allocator);
}

/// Cancel and dispose an unused prepared engine before the worker barrier.
pub fn shutdownWarmPlayer(allocator: std.mem.Allocator) void {
    warm_cancel.store(true, .release);
    if (warm_started.load(.acquire) and !warm_done.load(.acquire)) {
        warm_event.waitUncancelable(@import("../core/io_global.zig").io());
    }
    warm_mutex.lock();
    const prepared = warm_player;
    warm_player = null;
    warm_mutex.unlock();
    if (prepared) |p| p.deinit(allocator);
}

/// Invoked by mpv (on an mpv-owned thread) whenever a new video frame is
/// ready for rendering. We wake the dvui main loop so that the
/// pixel-buffer transfer in ui/grid.zig runs and the on-screen texture
/// updates. Without this, dvui's SDL backend sleeps on input idle and
/// the video freezes while audio continues. dvui.refresh is explicitly
/// thread-safe when a *Window is passed (see dvui/src/dvui.zig).
fn mpvRenderUpdateCallback(ctx: ?*anyopaque) callconv(.c) void {
    // Notification-only (no mpv API allowed in here): hand the frame to the
    // player's render worker, which rasterises it and then wakes dvui.
    const p: *MediaPlayer = @ptrCast(@alignCast(ctx orelse return));
    p.render_wake.set(@import("../core/io_global.zig").io());
}

/// Invoked for every queued mpv client event, including audio-only streams and
/// property changes that do not produce a render frame.
fn mpvWakeupCallback(_: ?*anyopaque) callconv(.c) void {
    wakeDvuiFromMpv();
}

fn wakeDvuiFromMpv() void {
    if (state.app.dvui_win) |win| {
        dvui.refresh(win, @src(), null);
    }
}

/// Apply the current picture preset to `p`, resolving `auto` against the file's
/// own colour metadata.
///
/// Called on MPV_EVENT_FILE_LOADED (colour metadata is not known before that) and
/// whenever the user changes the preset on a live player. The four properties
/// are the ones Opal's video equalizer already drives, so this is a different
/// way of setting settings that were always there — not a second pipeline.
///
/// Note this is a GRADE, not HDR passthrough: `vo=libmpv` + SW render means mpv
/// rasterises to a CPU buffer and the display never sees HDR metadata. What the
/// `hdr` preset fixes is the flat, grey, desaturated look HDR material has when
/// shown through an SDR path.
pub fn applyPicturePreset(p: anytype) void {
    const av_pure = @import("av_pure.zig");

    // mpv reports these as strings on video-params; absent (audio, or not yet
    // decoded) reads as empty, which isHdrVideo treats as "not HDR".
    var gamma_buf: [32]u8 = undefined;
    var prim_buf: [32]u8 = undefined;
    const gamma = getPropStringInto(p.mpv_ctx, "video-params/gamma", &gamma_buf);
    const primaries = getPropStringInto(p.mpv_ctx, "video-params/primaries", &prim_buf);

    // Software-scaler threading, decided per file. HDR sources carry per-frame
    // metadata (Dolby Vision RPU / HDR10+ scene data) that makes mpv treat
    // every frame as a format change: it rebuilds its zimg graph AND its
    // thread pool on every single frame. Measured on a 4K DV episode with a
    // 32-thread CPU: ~200 ms per frame (4 fps) with the "auto" pool, 25 ms
    // with one thread (no pool to rebuild). SDR sources rebuild once, so they
    // keep the multi-threaded default. Live option: mpv re-reads it on the
    // next frame.
    _ = c.mpv.mpv_set_option_string(
        p.mpv_ctx,
        "zimg-threads",
        if (av_pure.isHdrVideo(gamma, primaries)) "1" else "auto",
    );

    const chosen = av_pure.resolveAuto(
        av_pure.picturePresetFromInt(state.app.picture_preset),
        gamma,
        primaries,
    );
    const v = av_pure.pictureValues(chosen);

    const props = [_]struct { prop: [*:0]const u8, val: i32 }{
        .{ .prop = "brightness", .val = v.brightness },
        .{ .prop = "contrast", .val = v.contrast },
        .{ .prop = "saturation", .val = v.saturation },
        .{ .prop = "gamma", .val = v.gamma },
    };
    var buf: [16]u8 = undefined;
    for (props) |pr| {
        const s = std.fmt.bufPrintZ(&buf, "{d}", .{av_pure.clampVideoFilter(pr.val)}) catch continue;
        _ = c.mpv.mpv_set_property_string(p.mpv_ctx, pr.prop, s.ptr);
    }
}

/// The loaded video's transfer function (`pq`, `hlg`, `bt.1886`, …), or empty
/// when nothing is loaded. Lets the UI show what `auto` actually resolved to
/// instead of an opaque "Auto".
pub fn colorGammaOf(p: anytype, buf: []u8) []const u8 {
    return getPropStringInto(p.mpv_ctx, "video-params/gamma", buf);
}

// ── Playback perf probe ──
// Enabled with OPAL_PLAYBACK_STATS=1. Times the two UI-thread costs of the
// software render path (mpv render → RGBA buffer, then buffer → GPU texture)
// and prints them with mpv's own drop counters every ~2s to stderr.
pub const PerfProbe = struct {
    enabled: bool = false,
    // Written by the render worker, read by the UI thread → atomics.
    frames: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    render_ns: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    render_max_ns: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    // UI thread only.
    ui_frames: u32 = 0,
    uploads: u32 = 0,
    upload_ns: i64 = 0,
    upload_max_ns: i64 = 0,
    last_report_ms: i64 = 0,
};
pub var perf: PerfProbe = .{};

/// Render-target pixel format handed to mpv's software renderer. "rgb0" (the
/// documented fast path) by default; OPAL_SW_FORMAT overrides it for testing.
pub var sw_format: [*:0]const u8 = "rgb0";
/// True when OPAL_SW_FORMAT pinned `sw_format`; the UI's native-format pick
/// (ui/grid.zig chooseSwFormat) then leaves it alone.
pub var sw_format_forced: bool = false;

/// dvui texture pixel format matching an mpv render-target format's byte order.
pub fn textureFormatOf(fmt: [*:0]const u8) dvui.enums.TexturePixelFormat {
    const f = std.mem.span(fmt);
    if (std.mem.eql(u8, f, "rgba")) return .rgba_32;
    if (std.mem.eql(u8, f, "bgra")) return .bgra_32;
    if (std.mem.eql(u8, f, "bgr0")) return .bgrx_32;
    return .rgbx_32;
}

/// dvui texture pixel format matching the current `sw_format`.
pub fn swTextureFormat() dvui.enums.TexturePixelFormat {
    return textureFormatOf(sw_format);
}

fn applyEnvMpvOpts(ctx: *c.mpv.mpv_handle) void {
    if (std.c.getenv("OPAL_SW_FORMAT")) |raw| {
        const v = std.mem.span(raw);
        const known = [_][*:0]const u8{ "rgba", "rgb0", "bgr0", "bgra" };
        for (known) |k| {
            if (std.mem.eql(u8, v, std.mem.span(k))) {
                sw_format = k;
                sw_format_forced = true;
            }
        }
    }
    const raw = std.c.getenv("OPAL_MPV_OPTS") orelse return;
    var it = std.mem.splitScalar(u8, std.mem.span(raw), ';');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        var kbuf: [128]u8 = undefined;
        var vbuf: [1024]u8 = undefined;
        const k = std.fmt.bufPrintZ(&kbuf, "{s}", .{kv[0..eq]}) catch continue;
        const v = std.fmt.bufPrintZ(&vbuf, "{s}", .{kv[eq + 1 ..]}) catch continue;
        const rc = c.mpv.mpv_set_option_string(ctx, k.ptr, v.ptr);
        std.debug.print("[mpv-opts] {s}={s} -> {d}\n", .{ k, v, rc });
    }
}

pub fn perfInit() void {
    const raw = std.c.getenv("OPAL_PLAYBACK_STATS") orelse return;
    const v = std.mem.span(raw);
    perf.enabled = v.len > 0 and v[0] != '0';
}

pub fn perfNow() i64 {
    return @intCast(std.Io.Clock.awake.now(@import("../core/io_global.zig").io()).nanoseconds);
}

pub fn perfReport(p: *MediaPlayer) void {
    if (!perf.enabled) return;
    const now_ms = @import("../core/io_global.zig").monotonicMilliTimestamp();
    if (perf.last_report_ms == 0) {
        perf.last_report_ms = now_ms;
        return;
    }
    if (now_ms - perf.last_report_ms < 2000) return;
    const dt_s = @as(f64, @floatFromInt(now_ms - perf.last_report_ms)) / 1000.0;
    perf.last_report_ms = now_ms;
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    var b3: [64]u8 = undefined;
    var b4: [64]u8 = undefined;
    var b5: [64]u8 = undefined;
    var b6: [64]u8 = undefined;
    var b7: [64]u8 = undefined;
    var b8: [64]u8 = undefined;
    const frames = perf.frames.swap(0, .monotonic);
    const render_ns = perf.render_ns.swap(0, .monotonic);
    const render_max_ns = perf.render_max_ns.swap(0, .monotonic);
    const fr: f64 = @floatFromInt(@max(frames, 1));
    const uf: f64 = @floatFromInt(@max(perf.uploads, 1));
    std.debug.print(
        "[perf] {d:.1}s: vid_frames={d} ({d:.1}/s) ui_frames={d} ({d:.1}/s) render avg={d:.2}ms max={d:.2}ms upload avg={d:.2}ms max={d:.2}ms | hwdec={s} drop_vo={s} drop_dec={s} delayed={s} vf_fps={s} in={s} out={s} cache={s}s\n",
        .{
            dt_s,
            frames,
            @as(f64, @floatFromInt(frames)) / dt_s,
            perf.ui_frames,
            @as(f64, @floatFromInt(perf.ui_frames)) / dt_s,
            @as(f64, @floatFromInt(render_ns)) / fr / 1e6,
            @as(f64, @floatFromInt(render_max_ns)) / 1e6,
            @as(f64, @floatFromInt(perf.upload_ns)) / uf / 1e6,
            @as(f64, @floatFromInt(perf.upload_max_ns)) / 1e6,
            getPropStringInto(p.mpv_ctx, "hwdec-current", &b1),
            getPropStringInto(p.mpv_ctx, "frame-drop-count", &b2),
            getPropStringInto(p.mpv_ctx, "decoder-frame-drop-count", &b3),
            getPropStringInto(p.mpv_ctx, "vo-delayed-frame-count", &b4),
            getPropStringInto(p.mpv_ctx, "estimated-vf-fps", &b5),
            getPropStringInto(p.mpv_ctx, "video-params/pixelformat", &b6),
            getPropStringInto(p.mpv_ctx, "video-out-params/pixelformat", &b7),
            getPropStringInto(p.mpv_ctx, "demuxer-cache-duration", &b8),
        },
    );
    perf.ui_frames = 0;
    perf.uploads = 0;
    perf.upload_ns = 0;
    perf.upload_max_ns = 0;
}

/// Read an mpv string property into `buf`, returning a slice of it (empty when
/// the property is unset). mpv owns the returned string, so it is copied out and
/// freed here rather than escaping.
fn getPropStringInto(ctx: ?*c.mpv.mpv_handle, name: [*:0]const u8, buf: []u8) []const u8 {
    const s = c.mpv.mpv_get_property_string(ctx, name);
    if (s == null) return "";
    defer c.mpv.mpv_free(@ptrCast(s));
    const span = std.mem.span(s);
    const n = @min(span.len, buf.len);
    @memcpy(buf[0..n], span[0..n]);
    return buf[0..n];
}

// ── Trigger-to-play timing ──
// Wall-clock milestones from a user open trigger (CLI arg, forwarded
// second-instance open, or in-app open) to playback. Reported via
// std.debug.print AND <configDir>/timing.log, because a GUI-subsystem launch
// has no console to read back.
//   trigger     — user action parsed (appInit CLI / stashRemoteOpen / first load)
//   load-issued — MediaPlayer.load handed the URL to mpv
//   file-loaded — MPV_EVENT_FILE_LOADED (demuxed, tracks known)
//   first-frame — first published video frame (audio-only reports at file-loaded)
pub var open_trigger_ns: i64 = 0;
var timing_armed = std.atomic.Value(bool).init(false);
var open_load_ns: i64 = 0;
var open_loaded_ns: i64 = 0;
var open_first_frame_ns: i64 = 0;
var timing_frame_gate: @import("playback_timing_pure.zig").FrameGate = .{};
var timing_mutex: @import("../core/sync.zig").Mutex = .{};
var timing_ring: [12][256]u8 = std.mem.zeroes([12][256]u8);
var timing_ring_lens: [12]usize = std.mem.zeroes([12]usize);
var timing_ring_count: usize = 0;
var timing_ring_generation: u64 = 0;
var timing_flush_pending = std.atomic.Value(bool).init(false);

/// Arm (or re-arm) the trigger clock. Trigger sites call this when no trigger
/// is already armed so rapid successive opens attribute to the first intent.
pub fn openTriggerNow() void {
    timing_mutex.lock();
    defer timing_mutex.unlock();
    open_trigger_ns = perfNow();
    timing_armed.store(true, .release);
    open_load_ns = 0;
    open_loaded_ns = 0;
    open_first_frame_ns = 0;
    timing_frame_gate.reset();
}

pub fn openTriggerArmed() bool {
    return timing_armed.load(.acquire);
}

/// Called from MediaPlayer.load (replace path, incl. the async streamlink
/// branch): stamps load-issued, arming the trigger when nothing did (in-app
/// opens). A stale armed trigger is kept — the first frame still attributes
/// to the original user intent — but load/loaded stamps restart for this file.
pub fn openLoadIssued() void {
    timing_mutex.lock();
    defer timing_mutex.unlock();
    const now = perfNow();
    if (open_trigger_ns == 0) {
        open_trigger_ns = now;
        timing_armed.store(true, .release);
    }
    open_load_ns = now;
    open_loaded_ns = 0;
    open_first_frame_ns = 0;
    timing_frame_gate.loadIssued();
    timingReportLocked("load-issued", now, false);
}

/// Called on MPV_EVENT_FILE_LOADED. Audio-only files never publish a video
/// frame, so they report and disarm here instead. Otherwise the trigger stays
/// armed until the first frame lands, whichever order the two arrive in (the
/// render worker and the UI event pump race).
pub fn openFileLoaded(has_video: bool) void {
    if (!timing_armed.load(.acquire)) return;
    timing_mutex.lock();
    defer timing_mutex.unlock();
    if (open_trigger_ns == 0) return;
    const now = perfNow();
    open_loaded_ns = now;
    timing_frame_gate.fileLoaded();
    timingReportLocked(if (has_video) "file-loaded" else "file-loaded(audio-only)", now, !has_video);
}

/// Called when the render worker publishes a video frame. Reports once per
/// armed trigger. Render notifications before FILE_LOADED can belong to the
/// previous file and are rejected by the generation gate.
pub fn openFirstFrame() void {
    if (!timing_armed.load(.acquire)) return;
    timing_mutex.lock();
    defer timing_mutex.unlock();
    if (open_trigger_ns == 0 or open_first_frame_ns != 0 or !timing_frame_gate.acceptFirstFrame()) return;
    const now = perfNow();
    open_first_frame_ns = now;
    timingReportLocked("first-frame", now, open_loaded_ns != 0);
}

/// Caller holds timing_mutex so milestone reads, logging, and disarming form
/// one transaction across the UI and render threads.
fn timingReportLocked(stage: []const u8, now_ns: i64, disarm: bool) void {
    const toMs = struct {
        fn f(ns: i64) f64 {
            return @as(f64, @floatFromInt(ns)) / 1e6;
        }
    }.f;
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[timing] {s}: trigger+{d:.0}ms load+{d:.0}ms loaded+{d:.0}ms\n", .{
        stage,
        toMs(now_ns - open_trigger_ns),
        if (open_load_ns == 0) @as(f64, 0) else toMs(now_ns - open_load_ns),
        if (open_loaded_ns == 0) @as(f64, 0) else toMs(now_ns - open_loaded_ns),
    }) catch return;
    std.debug.print("{s}", .{line});
    queueTimingLogLocked(line);
    if (disarm) {
        timing_armed.store(false, .release);
        open_trigger_ns = 0;
        open_load_ns = 0;
        open_loaded_ns = 0;
        open_first_frame_ns = 0;
        timing_frame_gate.reset();
    }
}

/// Queue the last few timing lines for a background write. The render/UI thread
/// only copies a tiny fixed buffer and schedules at most one flusher; slow or
/// antivirus-filtered storage can never sit between frame publication and paint.
/// timing_mutex is held by the caller.
fn queueTimingLogLocked(line: []const u8) void {
    if (timing_ring_count >= timing_ring.len) {
        std.mem.copyForwards([256]u8, timing_ring[0..], timing_ring[1..]);
        std.mem.copyForwards(usize, timing_ring_lens[0..], timing_ring_lens[1..]);
        timing_ring_count = timing_ring.len - 1;
    }
    const n = @min(line.len, timing_ring[0].len);
    @memcpy(timing_ring[timing_ring_count][0..n], line[0..n]);
    timing_ring_lens[timing_ring_count] = n;
    timing_ring_count += 1;

    timing_ring_generation +%= 1;
    if (timing_flush_pending.swap(true, .acq_rel)) return;
    @import("../core/workers.zig").spawn(timingFlushWorker, .{}) catch {
        timing_flush_pending.store(false, .release);
    };
}

/// Snapshot and persist on an owned worker. If another milestone arrives while
/// writing, loop and publish the newer snapshot before releasing the one-worker
/// latch. Fixed buffers keep this allocation-free and teardown-safe.
fn timingFlushWorker() void {
    const io_g = @import("../core/io_global.zig");
    while (true) {
        // Coalesce load/file/frame milestones that land in one scheduler turn.
        io_g.sleep(2 * std.time.ns_per_ms);

        var out: [12 * 256]u8 = undefined;
        var w: usize = 0;
        var generation: u64 = 0;
        timing_mutex.lock();
        for (0..timing_ring_count) |i| {
            const ln = timing_ring_lens[i];
            @memcpy(out[w..][0..ln], timing_ring[i][0..ln]);
            w += ln;
        }
        generation = timing_ring_generation;
        timing_mutex.unlock();

        var dir_buf: [512]u8 = undefined;
        var path_buf: [768]u8 = undefined;
        if (std.fmt.bufPrint(&path_buf, "{s}/timing.log", .{
            @import("../core/paths.zig").configDir(&dir_buf),
        })) |path| {
            if (io_g.createFileAbsolute(path, .{ .truncate = true })) |f| {
                io_g.writeAll(f, out[0..w]) catch {};
                f.close(io_g.io());
            } else |_| {}
        } else |_| {}

        timing_mutex.lock();
        const stable = timing_ring_generation == generation;
        if (stable) timing_flush_pending.store(false, .release);
        timing_mutex.unlock();
        if (stable) return;
    }
}

fn eventDouble(pc: *const c.mpv.mpv_event_property, fallback: f64) f64 {
    if (pc.format != c.mpv.MPV_FORMAT_DOUBLE or pc.data == null) return fallback;
    const value = @as(*const f64, @ptrCast(@alignCast(pc.data))).*;
    return if (std.math.isFinite(value)) value else fallback;
}

fn isActivePlayer(p: *const MediaPlayer) bool {
    return state.app.active_player_idx < state.app.players.items.len and
        state.app.players.items[state.app.active_player_idx] == p;
}

fn eventInt64(pc: *const c.mpv.mpv_event_property) i64 {
    if (pc.format != c.mpv.MPV_FORMAT_INT64 or pc.data == null) return 0;
    return @as(*const i64, @ptrCast(@alignCast(pc.data))).*;
}

fn eventFlag(pc: *const c.mpv.mpv_event_property) bool {
    if (pc.format != c.mpv.MPV_FORMAT_FLAG or pc.data == null) return false;
    return @as(*const c_int, @ptrCast(@alignCast(pc.data))).* != 0;
}

pub fn updateTorrentBackgroundTasks() void {
    const now_ms = @import("../core/io_global.zig").monotonicMilliTimestamp();

    // Republish the "a torrent is waiting to start playing" flag every frame.
    // The stall watchdog wakes the UI while it is set, which is what keeps the
    // handoff below running when nobody is touching the machine. Computed first
    // so the `break`s inside the per-player work below cannot skip it.
    {
        const tsp = @import("../services/torrent_stall_pure.zig");
        var awaiting = false;
        for (state.app.players.items) |p| {
            if (tsp.awaitingHandoff(p.current_torrent_id, p.torrent_is_ready)) {
                awaiting = true;
                break;
            }
        }
        state.torrent_handoff_pending.store(awaiting, .release);
    }

    for (state.app.players.items) |p| {
        // PUMP MPV EVENTS
        while (true) {
            const ev = c.mpv.mpv_wait_event(p.mpv_ctx, 0);
            if (ev.*.event_id == c.mpv.MPV_EVENT_NONE) break;

            if (ev.*.event_id == c.mpv.MPV_EVENT_START_FILE) {
                p.provider = .mpv;
                // Do not show the previous item's time/size while the new file
                // is opening, and do not misclassify its first timestamp as a
                // co-watch rewind.
                p.last_seen_pos = 0;
                p.cached_duration = 0;
                p.cached_paused_for_cache = false;
                p.cached_video_width = 0;
                p.cached_video_height = 0;
                p.cached_sub_text_len = 0;
            } else if (ev.*.event_id == c.mpv.MPV_EVENT_FILE_LOADED) {
                p.ytdl_fast_retry_pending = false;
                p.load_error_len = 0;
                if (p.restore_session_position != null or p.provider_resume_position != null or state.app.playing_episode.armed) {
                    p.resume_seeked = false;
                    p.tryResumePosition();
                }
                // Colour metadata is known now, which is the earliest the `auto`
                // picture preset can decide anything — before this, video-params
                // is empty and every file would look SDR.
                applyPicturePreset(p);

                // Tracks are parsed now. If the media brought no subtitle track
                // (no embedded stream, no sidecar picked up by sub-auto=fuzzy),
                // kick an automatic OpenSubtitles fetch for the best match.
                // Guarded internally (toggle, API key, per-file dedupe).
                var sub_count: i64 = 0;
                _ = c.mpv.mpv_get_property(p.mpv_ctx, "sub", c.mpv.MPV_FORMAT_INT64, &sub_count);
                var has_sub = false;
                var has_video = false;
                {
                    var tc: i64 = 0;
                    _ = c.mpv.mpv_get_property(p.mpv_ctx, "track-list/count", c.mpv.MPV_FORMAT_INT64, &tc);
                    var ti: i64 = 0;
                    while (ti < tc) : (ti += 1) {
                        var q: [48]u8 = undefined;
                        const qz = std.fmt.bufPrintZ(&q, "track-list/{d}/type", .{ti}) catch continue;
                        const ts = c.mpv.mpv_get_property_string(p.mpv_ctx, qz.ptr);
                        if (ts != null) {
                            const ttype = std.mem.span(ts);
                            if (std.mem.eql(u8, ttype, "sub")) has_sub = true;
                            if (std.mem.eql(u8, ttype, "video")) has_video = true;
                            c.mpv.mpv_free(@ptrCast(ts));
                        }
                        if (has_sub and has_video) break;
                    }
                }
                // Trigger-to-play milestone (audio-only reports + disarms here;
                // video reports again at its first published frame).
                openFileLoaded(has_video);
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
            } else if (ev.*.event_id == c.mpv.MPV_EVENT_PLAYBACK_RESTART) {
                // Demuxing alone is not proof that a version is usable: codec
                // initialization may still fail after FILE_LOADED. Disarm only
                // once mpv says playback actually started.
                p.fallback_recovery.playbackStarted();
            } else if (ev.*.event_id == c.mpv.MPV_EVENT_END_FILE) {
                const ended = @as(*c.mpv.mpv_event_end_file, @ptrCast(@alignCast(ev.*.data)));
                if (ended.reason == c.mpv.MPV_END_FILE_REASON_ERROR) {
                    // Server/library adapters may provide one alternate URL for
                    // the same logical item (another media version or the
                    // server's generic direct stream). Preserve the stable
                    // identity, headers, resume point and player surface while
                    // retrying it, and never loop after that second attempt.
                    if (p.fallback_url_len > 0 and p.fallback_recovery.takeOnFailure()) {
                        const fallback_len = p.fallback_url_len;
                        @memcpy(p.current_url[0..fallback_len], p.fallback_url[0..fallback_len]);
                        p.current_url_len = fallback_len;
                        p.resume_seeked = false;
                        p.is_loading = true;
                        const label = "Trying compatible stream...";
                        @memcpy(p.loading_label[0..label.len], label);
                        p.loading_label_len = label.len;
                        logs.pushLog("info", "player", "Primary stream failed; trying compatible fallback", false);
                        p.commitPlayback(.{
                            .url = p.current_url[0..p.current_url_len],
                            .user_agent = p.current_user_agent[0..p.current_user_agent_len],
                            .prepared_header_fields = p.current_header_fields[0..p.current_header_fields_len],
                            .loopback_stream = p.current_loopback_stream,
                        });
                        continue;
                    }
                    const identity = p.history_identity[0..p.history_identity_len];
                    if (std.mem.startsWith(u8, identity, "opal://jellyfin/video/") and p.beginServerRecovery()) {
                        const p_idx: usize = for (state.app.players.items, 0..) |candidate, idx| {
                            if (candidate == p) break idx;
                        } else state.app.players.items.len;
                        if (@import("../services/jellyfin.zig").requestTranscodeRecovery(identity, p_idx)) {
                            logs.pushLog("info", "jellyfin", "Direct streams failed; negotiating server transcode", false);
                            continue;
                        }
                    }
                    if (std.mem.startsWith(u8, identity, "opal://plex/item/") and p.beginServerRecovery()) {
                        var transcode_buf: [2048]u8 = undefined;
                        if (@import("../services/plex.zig").transcodeRecoveryUrl(identity, &transcode_buf)) |transcode_url| {
                            logs.pushLog("info", "plex", "Direct versions failed; using server transcode", false);
                            p.applyServerRecovery(transcode_url);
                            continue;
                        }
                    }
                    // Normal YouTube videos skip manifest/config requests for a
                    // substantially faster first frame. Live/restricted edge
                    // cases can need those requests, so retry exactly once with
                    // the complete extractor path before surfacing the error.
                    if (p.ytdl_fast_retry_pending and p.current_url_len > 0) {
                        p.ytdl_fast_retry_pending = false;
                        p.applyYtdlRawOptions(false, true);
                        logs.pushLog("info", "ytdlp", "Fast extraction unavailable; retrying robust YouTube path", false);
                        p.commitPlayback(.{ .url = p.current_url[0..p.current_url_len] });
                        continue;
                    }
                    const source = if (p.is_torrent and p.source_url_len > 0) p.source_url[0..p.source_url_len] else p.current_url[0..p.current_url_len];
                    if (@import("../services/tmdb.zig").retryEpisodeSource(source)) continue;

                    const detail = std.mem.span(c.mpv.mpv_error_string(ended.@"error"));
                    var error_buf: [256]u8 = undefined;
                    const message = std.fmt.bufPrint(&error_buf, "Could not play this media: {s}", .{detail}) catch "Could not play this media";
                    p.setLoadError(message);
                }
                if (ended.reason != c.mpv.MPV_END_FILE_REASON_EOF) continue;
                if (state.app.playing_episode.matches(p.current_url[0..p.current_url_len])) {
                    // A streaming torrent can hit a temporary EOF before its
                    // remaining pieces arrive. Only advance after a real end.
                    var complete: f32 = 1;
                    if (p.current_torrent_id >= 0)
                        _ = c.mpv.torrent_poll(state.torrentSession(), p.current_torrent_id, p.selected_file_idx, null, 0, &complete, null, null);
                    if (complete >= 0.99) {
                        p.saveCurrentPositionFinal();
                        if (state.app.auto_advance) @import("../services/tv_library.zig").playNeighborEpisode(1);
                        continue;
                    }
                }
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
                        var cur_usable = false;
                        if (c.mpv.mpv_get_property(p.mpv_ctx, "percent-pos", c.mpv.MPV_FORMAT_DOUBLE, &cur_pct) >= 0) {
                            if (cur_pct > 0.1 and cur_pct < 99.9 and !std.math.isNan(cur_pct)) {
                                p.resume_percent = cur_pct;
                                cur_usable = true;
                            }
                        }
                        // percent-pos is unusable at a parked EOF (>= 99.9, or
                        // NaN once the file closed): without this the reload
                        // silently fell back to 0 and every stall restarted the
                        // movie from the beginning. Resume at the newest
                        // non-EOF-parked position instead; when nothing
                        // trustworthy was ever observed, from-start remains.
                        if (playback_load.eofReloadResumeSecs(cur_usable, p.last_good_pos_secs)) |secs| {
                            p.resume_percent = 0.0;
                            p.resume_position_secs = secs;
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
                        if (prev_paused != new_paused and p.history_identity_len > 0) {
                            @import("../services/server_progress.zig").playState(
                                p.history_identity[0..p.history_identity_len],
                                p.last_seen_pos,
                                p.cached_duration,
                                new_paused,
                            );
                        }
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
                            p.updateDialogueRing(txt, p.last_seen_pos);
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
                                const pe = &state.app.playing_episode;
                                const bound = pe.matches(p.current_url[0..p.current_url_len]);
                                if (bound) {
                                    if (pe.sample_ms != 0 and !p.cached_paused and !p.cached_paused_for_cache) {
                                        pe.played_seconds += @import("../services/tmdb_pure.zig").playedDelta(pe.sample_pos, newpos, @as(f64, @floatFromInt(now_ms - pe.sample_ms)) / 1000, p.cached_speed);
                                    }
                                    pe.sample_ms = now_ms;
                                    pe.sample_pos = newpos;
                                }
                                if (pw.armed and !pw.committed and
                                    bound and pw.tmdb_id == pe.tmdb_id and pw.season == pe.season and pw.episode == pe.episode and
                                    @import("../services/tmdb_pure.zig").tvWatchCommitDue(newpos, p.cached_duration, pe.played_seconds) and
                                    state.app.active_player_idx < state.app.players.items.len and
                                    state.app.players.items[state.app.active_player_idx] == p)
                                {
                                    pw.committed = true;
                                    pw.armed = false;
                                    @import("../services/tmdb.zig").commitPendingWatch();
                                }
                            }
                            // Movie history uses the same seek-resistant rule as
                            // episodes: credits position alone is insufficient;
                            // at least 90% must have advanced during real play.
                            if (p.catalog_tmdb_id > 0 and
                                p.loading_kind == @import("../ui/loading_pure.zig").MediaKind.movie.toInt() and
                                !p.catalog_movie_committed)
                            {
                                if (p.catalog_sample_ms != 0 and !p.cached_paused and !p.cached_paused_for_cache) {
                                    p.catalog_played_seconds += @import("../services/tmdb_pure.zig").playedDelta(
                                        p.catalog_sample_pos,
                                        newpos,
                                        @as(f64, @floatFromInt(now_ms - p.catalog_sample_ms)) / 1000,
                                        p.cached_speed,
                                    );
                                }
                                p.catalog_sample_ms = now_ms;
                                p.catalog_sample_pos = newpos;
                                if (@import("../services/tmdb_pure.zig").watchCommitDue(newpos, p.cached_duration, p.catalog_played_seconds) and isActivePlayer(p)) {
                                    p.catalog_movie_committed = true;
                                    const history_identity = if (p.history_identity_len > 0)
                                        p.history_identity[0..p.history_identity_len]
                                    else
                                        p.current_url[0..p.current_url_len];
                                    @import("watch_history.zig").bindCatalogMovie(history_identity, p.catalog_tmdb_id);
                                    @import("../services/trakt.zig").markWatchedMovie(p.catalog_tmdb_id);
                                    @import("../services/simkl.zig").markWatchedMovie(p.catalog_tmdb_id);
                                }
                            }
                        }
                    }
                } else if (std.mem.eql(u8, pname, "duration")) {
                    p.cached_duration = eventDouble(pc, 0);
                } else if (std.mem.eql(u8, pname, "volume")) {
                    const value = eventDouble(pc, 100);
                    p.cached_volume = value;
                    if (state.app.config_loaded.load(.acquire) and isActivePlayer(p) and @abs(value - state.app.playback_volume) > 0.01) {
                        state.app.playback_volume = std.math.clamp(value, 0, 100);
                        p.cell_volume = state.app.playback_volume;
                        state.markConfigDirty();
                    }
                } else if (std.mem.eql(u8, pname, "speed")) {
                    const value = eventDouble(pc, 1);
                    p.cached_speed = value;
                    if (state.app.config_loaded.load(.acquire) and isActivePlayer(p) and @abs(value - state.app.playback_speed) > 0.001) {
                        state.app.playback_speed = std.math.clamp(value, 0.25, 4);
                        p.cell_speed = state.app.playback_speed;
                        state.markConfigDirty();
                    }
                } else if (std.mem.eql(u8, pname, "mute")) {
                    const value = eventFlag(pc);
                    p.cached_muted = value;
                    if (state.app.config_loaded.load(.acquire) and isActivePlayer(p) and value != state.app.playback_muted) {
                        state.app.playback_muted = value;
                        state.markConfigDirty();
                    }
                } else if (std.mem.eql(u8, pname, "paused-for-cache")) {
                    p.cached_paused_for_cache = eventFlag(pc);
                } else if (std.mem.eql(u8, pname, "playlist-count")) {
                    p.cached_playlist_count = eventInt64(pc);
                } else if (std.mem.eql(u8, pname, "playlist-pos")) {
                    p.cached_playlist_pos = eventInt64(pc);
                } else if (std.mem.eql(u8, pname, "dwidth")) {
                    p.cached_video_width = eventInt64(pc);
                    p.maybeNotifyHwdecFallback();
                } else if (std.mem.eql(u8, pname, "dheight")) {
                    p.cached_video_height = eventInt64(pc);
                    p.maybeNotifyHwdecFallback();
                } else if (std.mem.eql(u8, pname, "hwdec-current")) {
                    p.cached_hwdec_len = 0;
                    if (pc.*.format == c.mpv.MPV_FORMAT_STRING and pc.*.data != null) {
                        const sptr = @as(*[*c]u8, @ptrCast(@alignCast(pc.*.data))).*;
                        const value = if (sptr != null) std.mem.span(sptr) else "";
                        const n = @min(value.len, p.cached_hwdec.len);
                        @memcpy(p.cached_hwdec[0..n], value[0..n]);
                        p.cached_hwdec_len = n;
                    }
                    p.maybeNotifyHwdecFallback();
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
                    if (p.selected_file_idx >= c.mpv.torrent_get_file_count(state.torrentSession(), p.current_torrent_id))
                        p.selected_file_idx = -1;
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
                        var episode_idx: i32 = -1;
                        var playable_count: usize = 0;
                        var risky_count: i32 = 0;
                        var i: i32 = 0;
                        while (i < f_count) : (i += 1) {
                            c.mpv.torrent_set_file_priority(state.torrentSession(), p.current_torrent_id, i, 0);
                            var fname: [512]u8 = undefined;
                            c.mpv.torrent_get_file_name(state.torrentSession(), p.current_torrent_id, i, &fname, 512);
                            const name = std.mem.sliceTo(&fname, 0);
                            if (media_ext.isExecutableOrArchive(name)) risky_count += 1;
                            if (!media_ext.isPlayable(name)) continue; // skip non-media
                            playable_count += 1;
                            if (state.app.playing_episode.armed) {
                                if (@import("../services/subtitles_pure.zig").findSxxEyy(name)) |episode| {
                                    if (episode.s == state.app.playing_episode.season and episode.e == state.app.playing_episode.episode) episode_idx = i;
                                }
                            }
                            const sz = c.mpv.torrent_get_file_size(state.torrentSession(), p.current_torrent_id, i);
                            if (sz > max_sz) {
                                max_sz = sz;
                                max_idx = i;
                            }
                        }

                        if (episode_idx >= 0) {
                            max_idx = episode_idx;
                        } else if (state.app.playing_episode.armed and playable_count > 1) {
                            p.selected_file_idx = -2;
                            p.is_loading = false;
                            _ = @import("../services/tmdb.zig").retryEpisodeSource(p.source_url[0..p.source_url_len]);
                            state.showToast("The requested episode could not be identified in this torrent.");
                            continue;
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
                            p.load(.{ .url = stream_url, .origin = .torrent, .loopback_stream = true });
                            logs.pushLog("info", "player", "Streaming via HTTP proxy", false);
                        } else {
                            // Fallback to raw file if URL generation fails
                            p.load(.{ .url = null_term_path[0..safe_len], .origin = .torrent });
                        }
                    } else {
                        // Fallback to raw file if proxy fails to start
                        p.load(.{ .url = null_term_path[0..safe_len], .origin = .torrent });
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

                // Five-second wall-time cadence keeps synchronous property
                // queries and SQLite writes out of the render cadence.
                if (percent_pos > 0.5 and
                    (p.last_position_save_ms == 0 or now_ms - p.last_position_save_ms >= 5000))
                {
                    p.last_position_save_ms = now_ms;
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
                        // Torrent completion for the EOF-park guard below: one
                        // C call per 5s save tick, never per frame.
                        var complete: f32 = 1;
                        _ = c.mpv.torrent_poll(state.torrentSession(), p.current_torrent_id, p.selected_file_idx, null, 0, &complete, null, null);
                        // Never record mpv parked at the end of a still-
                        // incomplete torrent: percent-pos reads 100 at EOF
                        // with single-digit percent on disk, and that row
                        // marks an unwatched file fully watched (and can never
                        // resume correctly). Genuine finishes go through
                        // saveCurrentPositionFinal, not here.
                        if (!playback_load.skipEofParkedSave(complete < 0.99, percent_pos, pos_s, dur_s)) {
                            watch.savePositionFull(t_name3[0..n3_len], percent_pos, pos_s, dur_s, p.source_url[0..p.source_url_len], p.catalog_tmdb_id);
                            // Newest trustworthy position: an EOF-reload stall
                            // resumes here instead of restarting from 0.
                            if (std.math.isFinite(pos_s) and pos_s > 0) p.last_good_pos_secs = pos_s;
                        }
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

            // Five-second wall-time cadence. Explicit close/switch paths still
            // save immediately, so a quieter hot path does not lose progress.
            if (p.current_url_len > 0 and
                (p.last_position_save_ms == 0 or now_ms - p.last_position_save_ms >= 5000))
            {
                p.last_position_save_ms = now_ms;
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
