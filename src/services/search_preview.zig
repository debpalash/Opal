//! One explicit, muted-by-default trailer player, isolated from playback/history.
//! select/start/poll/render/stop/deinit run on the UI thread. snapshot is safe
//! for other readers. Stop on query, selection, route, and overlay close; deinit
//! after the process worker barrier. Only verified TMDB records reach libmpv.
const std = @import("std");
const dvui = @import("dvui");
const c = @import("../core/c.zig").mpv;
const sdl = @import("../core/c.zig").sdl;
const state = @import("../core/state.zig");
const workers = @import("../core/workers.zig");
const allocator = @import("../core/alloc.zig").allocator;
const sync = @import("../core/sync.zig");
const pure = @import("search_preview_pure.zig");
pub const Kind = pure.Kind;
pub const Status = pure.Status;
pub const Failure = pure.Failure;
pub const Metadata = pure.Metadata;
pub const Lookup = struct {
    metadata: Metadata = .{},
    status: Status = .failed,
    failure: Failure = .transport,
};
pub const Credentials = struct {
    key: [256]u8 = @splat(0),
    key_len: usize = 0,
};
pub const Snapshot = struct {
    identity: u64 = 0,
    generation: u64 = 0,
    status: Status = .idle,
    failure: Failure = .none,
    metadata: pure.Metadata = .{},
    muted: bool = true,
    pub fn canStart(self: Snapshot) bool {
        return (self.status == .ready or self.status == .ended or (self.status == .failed and self.failure == .playback)) and self.metadata.trailer_url_len > 0;
    }
    pub fn label(self: Snapshot) []const u8 {
        return switch (self.status) {
            .idle => "No trailer selected",
            .loading => "Checking official trailers…",
            .ready => "Official trailer",
            .starting => "Loading trailer…",
            .playing => "Trailer preview",
            .ended => "Trailer ended",
            .unavailable => "No official trailer available",
            .failed => if (self.failure == .playback) "Trailer could not play — open its verified link" else "Trailer metadata could not load",
        };
    }
};

const Job = struct {
    generation: u64,
    kind: Kind,
    id: i32,
    key: [512]u8 = @splat(0),
    key_len: usize = 0,
};
var mutex: sync.Mutex = .{};
var lifecycle: pure.Lifecycle = .{};
var current: Snapshot = .{};
var selected_kind: Kind = .movie;
var selected_id: i32 = 0;
var pending: ?Job = null;
var worker_busy: bool = false; // mutex; at most one fetch, latest pending coalesces.
var credentials: Credentials = .{}; // UI/config owner publishes; API readers copy.
var mpv: ?*c.mpv_handle = null; // UI only, never registered in state.app.players.
var renderer: ?*c.mpv_render_context = null;
var pixels: ?[]u8 = null;
var texture: ?dvui.Texture = null;
var frame_ready = false;
const frame_width: u32 = 640;
const frame_height: u32 = 360;

pub fn snapshot() Snapshot {
    mutex.lock();
    defer mutex.unlock();
    return current;
}

/// Called by the credential owner (UI after config is ready; headless startup).
/// A reader-only lock around raw settings would not protect concurrent writers.
pub fn publishCredentials(key: []const u8) void {
    mutex.lock();
    defer mutex.unlock();
    credentials = .{};
    if (key.len > credentials.key.len) return;
    @memcpy(credentials.key[0..key.len], key);
    credentials.key_len = key.len;
}

pub fn copyCredentials() Credentials {
    mutex.lock();
    defer mutex.unlock();
    return credentials;
}

/// Selecting fetches metadata only. No playback or audio begins until start().
pub fn select(identity: u64, kind: Kind, id: i32) void {
    // This method is UI-only, so the editable credential is copied by its owner.
    const key_len = @min(state.app.tmdb.api_key_len, state.app.tmdb.api_key.len);
    publishCredentials(state.app.tmdb.api_key[0..key_len]);
    mutex.lock();
    const unchanged = lifecycle.selected and lifecycle.identity == identity and selected_kind == kind and selected_id == id;
    mutex.unlock();
    if (unchanged) return;
    destroyPlayer();
    mutex.lock();
    const generation = lifecycle.select(identity);
    selected_kind = kind;
    selected_id = id;
    current = .{ .identity = identity, .generation = generation, .status = .loading };
    pending = null;
    if (id <= 0) {
        current.status = .unavailable;
        current.failure = .no_official_video;
    } else {
        var job = Job{ .generation = generation, .kind = kind, .id = id, .key_len = credentials.key_len };
        @memcpy(job.key[0..job.key_len], credentials.key[0..job.key_len]);
        pending = job;
    }
    mutex.unlock();
    launchPending();
}

fn launchPending() void {
    mutex.lock();
    defer mutex.unlock();
    if (worker_busy or pending == null or workers.isQuitting()) return;
    const job = pending.?;
    pending = null;
    worker_busy = true;
    workers.spawn(fetchMetadata, .{job}) catch {
        worker_busy = false;
        if (lifecycle.accepts(job.generation)) {
            current.status = .failed;
            current.failure = .transport;
        }
    };
}

fn fetchMetadata(job: Job) void {
    var reply: Lookup = .{};
    defer {
        mutex.lock();
        worker_busy = false;
        if (!workers.isQuitting() and lifecycle.accepts(job.generation)) {
            current.metadata = reply.metadata;
            current.failure = reply.failure;
            current.status = reply.status;
        }
        mutex.unlock();
        state.wakeUi();
    }
    reply = lookupMetadata(job.kind, job.id, job.key[0..job.key_len]);
}

/// Independent bounded lookup for API workers. The caller owns/snapshots its
/// key; neither selected native work nor preview playback is touched here.
pub fn lookupMetadata(kind: Kind, id: i32, key: []const u8) Lookup {
    if (id <= 0) return .{ .failure = .invalid_response };
    // No key (or an unusable one) is not an error: Cinemeta carries the same
    // official trailer ids for the keyless catalog.
    const usable = key.len > 0 and key.len <= 256 and for (key) |ch| {
        if (ch <= 32 or ch == 127) break false;
    } else true;
    if (!usable) return lookupCinemeta(kind, id);
    if (workers.isQuitting()) return .{};
    var path_buf: [96]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/3/{s}/{d}?append_to_response=videos", .{ @tagName(kind), id }) catch return .{};
    const body = @import("tmdb_api.zig").tmdbPreviewApiOwned(path, key) orelse return .{};
    defer allocator.free(body);
    const meta = pure.parseForId(allocator, body, id) catch return .{ .failure = .invalid_response };
    return .{ .metadata = meta, .status = if (meta.trailer_url_len > 0) .ready else .unavailable, .failure = if (meta.trailer_url_len > 0) .none else .no_official_video };
}

fn lookupCinemeta(kind: Kind, id: i32) Lookup {
    if (workers.isQuitting()) return .{};
    const api = @import("tmdb_api.zig");
    const meta_kind: @import("cinemeta_meta_pure.zig").Kind = if (kind == .tv) .series else .movie;
    var imdb_buf: [16]u8 = undefined;
    const imdb = api.knownImdb(meta_kind, id, &imdb_buf);
    if (imdb.len == 0) return .{ .status = .unavailable, .failure = .no_official_video };
    const body = api.cinemetaMetaOwned(meta_kind, imdb) orelse return .{};
    defer allocator.free(body);
    const meta = pure.parseCinemeta(allocator, body, id) catch return .{ .failure = .invalid_response };
    return .{ .metadata = meta, .status = if (meta.trailer_url_len > 0) .ready else .unavailable, .failure = if (meta.trailer_url_len > 0) .none else .no_official_video };
}

fn failPlayback() void {
    destroyPlayer();
    mutex.lock();
    current.status = .failed;
    current.failure = .playback;
    mutex.unlock();
}

/// Explicit activation only. A separate libmpv core has no app scripts,
/// history, playlist, resume state, browser cookies, or persistent watch-later.
pub fn start() bool {
    const snap = snapshot();
    if (!snap.canStart() or workers.isQuitting()) return false;
    destroyPlayer();
    const handle = c.mpv_create() orelse {
        failPlayback();
        return false;
    };
    mpv = handle;
    const opts = [_]struct { name: [*:0]const u8, value: [*:0]const u8 }{
        .{ .name = "config", .value = "no" },
        .{ .name = "terminal", .value = "no" },
        .{ .name = "load-scripts", .value = "no" },
        .{ .name = "audio-file-auto", .value = "no" },
        .{ .name = "sub-auto", .value = "no" },
        .{ .name = "vo", .value = if (@import("build_options").headless) "null" else "libmpv" },
        .{ .name = "mute", .value = "yes" },
        .{ .name = "volume", .value = "50" },
        .{ .name = "loop-file", .value = "no" },
        .{ .name = "keep-open", .value = "yes" },
        .{ .name = "idle", .value = "yes" },
        .{ .name = "save-position-on-quit", .value = "no" },
        .{ .name = "resume-playback", .value = "no" },
        .{ .name = "input-default-bindings", .value = "no" },
        .{ .name = "input-vo-keyboard", .value = "no" },
        .{ .name = "network-timeout", .value = "8" },
        .{ .name = "video-timing-offset", .value = "0" },
        .{ .name = "ytdl-format", .value = "best[height<=480]/bestvideo[height<=480]+bestaudio/best" },
        .{ .name = "ytdl-raw-options", .value = "ignore-config=,no-playlist=" },
    };
    for (opts) |opt| if (c.mpv_set_option_string(handle, opt.name, opt.value) < 0) {
        failPlayback();
        return false;
    };
    var script_buf: [1024]u8 = undefined;
    if (@import("../player/ytdl_opts_pure.zig").buildScriptOpts(.{ .ytdl_path = @import("ytdlp.zig").getPath() orelse "yt-dlp" }, &script_buf)) |opts_z| {
        _ = c.mpv_set_option_string(handle, "script-opts", opts_z.ptr);
    }
    if (c.mpv_initialize(handle) < 0) {
        failPlayback();
        return false;
    }
    if (!@import("build_options").headless) {
        var params = [_]c.mpv_render_param{
            .{ .type = c.MPV_RENDER_PARAM_API_TYPE, .data = @constCast(c.MPV_RENDER_API_TYPE_SW) },
            .{ .type = c.MPV_RENDER_PARAM_INVALID, .data = null },
        };
        if (c.mpv_render_context_create(&renderer, handle, &params) < 0) {
            failPlayback();
            return false;
        }
        pixels = allocator.alloc(u8, frame_width * frame_height * 4) catch {
            failPlayback();
            return false;
        };
    }
    if (!@import("../player/player.zig").loadDetached(handle, .{ .url = snap.metadata.trailer_url[0..snap.metadata.trailer_url_len] })) {
        failPlayback();
        return false;
    }
    mutex.lock();
    current.status = .starting;
    current.failure = .none;
    current.muted = true;
    mutex.unlock();
    return true;
}

pub fn setMuted(muted: bool) void {
    const handle = mpv orelse return;
    var value: c_int = if (muted) 1 else 0;
    if (c.mpv_set_property(handle, "mute", c.MPV_FORMAT_FLAG, &value) >= 0) {
        mutex.lock();
        current.muted = muted;
        mutex.unlock();
    }
}

/// Non-blocking event drain. Call each UI frame while preview is selected.
pub fn poll() void {
    launchPending();
    const handle = mpv orelse return;
    for (0..32) |_| {
        const event = c.mpv_wait_event(handle, 0);
        if (event == null or event.*.event_id == c.MPV_EVENT_NONE) break;
        switch (event.*.event_id) {
            c.MPV_EVENT_FILE_LOADED => {
                mutex.lock();
                current.status = .playing;
                mutex.unlock();
            },
            c.MPV_EVENT_END_FILE => {
                const end: *const c.mpv_event_end_file = @ptrCast(@alignCast(event.*.data));
                mutex.lock();
                current.status = if (end.reason == c.MPV_END_FILE_REASON_ERROR) .failed else .ended;
                current.failure = if (end.reason == c.MPV_END_FILE_REASON_ERROR) .playback else .none;
                mutex.unlock();
            },
            else => {},
        }
    }
    // keep-open retains the last trailer frame without END_FILE on some mpv
    // versions. The real EOF property, never elapsed-time guessing, ends UI state.
    if (snapshot().status == .playing) {
        var eof: c_int = 0;
        if (c.mpv_get_property(handle, "eof-reached", c.MPV_FORMAT_FLAG, &eof) >= 0 and eof != 0) {
            mutex.lock();
            current.status = .ended;
            mutex.unlock();
        }
    }
}

/// Bounded 640×360 software preview; no decode/upload for invisible overlays.
/// Call inside a bounded preview panel. Muted previews do not block for A/V time.
pub fn render(src: std.builtin.SourceLocation, id: usize, width: f32, height: f32) void {
    if (comptime @import("build_options").headless) return;
    if (width <= 0 or height <= 0) return;
    const ctx = renderer orelse return;
    const buf = pixels orelse return;
    const flags = c.mpv_render_context_update(ctx);
    if (flags & c.MPV_RENDER_UPDATE_FRAME != 0) {
        const size = [2]c_int{ frame_width, frame_height };
        const stride: usize = frame_width * 4;
        const blocking: c_int = 0;
        var params = [_]c.mpv_render_param{
            .{ .type = c.MPV_RENDER_PARAM_SW_SIZE, .data = @constCast(&size) },
            .{ .type = c.MPV_RENDER_PARAM_SW_FORMAT, .data = @constCast("rgb0") },
            .{ .type = c.MPV_RENDER_PARAM_SW_STRIDE, .data = @constCast(&stride) },
            .{ .type = c.MPV_RENDER_PARAM_SW_POINTER, .data = buf.ptr },
            .{ .type = c.MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, .data = @constCast(&blocking) },
            .{ .type = c.MPV_RENDER_PARAM_INVALID, .data = null },
        };
        if (c.mpv_render_context_render(ctx, &params) >= 0) {
            const sdl_renderer: *sdl.SDL_Renderer = @ptrCast(@alignCast(dvui.currentWindow().backend.impl.renderer));
            if (texture == null) {
                if (sdl.SDL_CreateTexture(sdl_renderer, sdl.SDL_PIXELFORMAT_RGBX32, sdl.SDL_TEXTUREACCESS_STREAMING, frame_width, frame_height)) |tex| {
                    _ = sdl.SDL_SetTextureBlendMode(tex, sdl.SDL_BLENDMODE_NONE);
                    _ = sdl.SDL_SetTextureScaleMode(tex, sdl.SDL_ScaleModeLinear);
                    texture = .{ .ptr = tex, .width = frame_width, .height = frame_height, .format = .rgbx_32 };
                }
            }
            if (texture) |tex| {
                const ptr: *sdl.SDL_Texture = @ptrCast(@alignCast(tex.ptr));
                frame_ready = sdl.SDL_UpdateTexture(ptr, null, buf.ptr, frame_width * 4) == 0;
            }
        }
    }
    if (frame_ready) if (texture) |tex| {
        _ = dvui.image(src, .{ .source = .{ .texture = tex } }, .{ .id_extra = id, .min_size_content = .{ .w = width, .h = height }, .max_size_content = .{ .w = width, .h = height } });
    };
    const status = snapshot().status;
    if (status == .playing or status == .starting) @import("../ui/components.zig").animatedRefresh(33_000);
}

fn destroyPlayer() void {
    // No render worker: all render calls and teardown belong to the UI thread.
    if (renderer) |ctx| c.mpv_render_context_free(ctx);
    renderer = null;
    if (mpv) |ctx| c.mpv_terminate_destroy(ctx);
    mpv = null;
    if (pixels) |buf| allocator.free(buf);
    pixels = null;
    if (texture) |tex| dvui.textureDestroyLater(tex);
    texture = null;
    frame_ready = false;
}

pub fn stop() void {
    destroyPlayer();
    mutex.lock();
    defer mutex.unlock();
    // Route guards may call stop every frame. Once invalidated, preserve its
    // generation; a still-running old worker already cannot publish into it.
    if (!lifecycle.selected and pending == null and current.status == .idle) return;
    lifecycle.stop();
    pending = null;
    current = .{ .generation = lifecycle.generation };
}

/// Close/replay the selected preview without refetching verified metadata.
pub fn closePlayback() void {
    destroyPlayer();
    mutex.lock();
    defer mutex.unlock();
    if (lifecycle.selected and current.metadata.trailer_url_len > 0) {
        current.status = .ready;
        current.failure = .none;
        current.muted = true;
    }
}

pub fn deinit() void {
    stop();
    mutex.lock();
    credentials = .{};
    mutex.unlock();
}
