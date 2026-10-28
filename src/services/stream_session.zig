//! Continuum streaming sessions (ROADMAP 7.4 / 4.2): play local media on a
//! browser, phone or another Opal.
//!
//!   POST /api/stream                 id=<local-library id> | current=1,
//!                                    [quality=original|1080p|720p|480p]
//!                                    [start=<secs>] [caps=h264,aac,hls,...]
//!                                    [pause_source=1]  -> session JSON
//!   GET  /api/stream                 encoder + active session count
//!   GET  /api/stream/<sid>/[<token>/]index.m3u8 | init.mp4 | seg_NNNNN.m4s | direct
//!   POST /api/stream/<sid>/[<token>/]progress   pos=&dur=  (Continue Watching)
//!   POST /api/stream/<sid>/[<token>/]stop
//!
//! Auth: creating a session needs normal API auth. Fetching accepts EITHER
//! normal API auth (path without a token) OR the session's signed stream token
//! carried in the path — so a TV/peer can fetch without the account token, and
//! relative segment URIs in the playlist inherit it. Tokens are HMAC-SHA256
//! over (sid, expiry) with a random in-memory key: they die with the process.
//!
//! The web never sees a filesystem path: sessions are created from a library
//! id (or the desktop's current item) and addressed by a random session id.
//!
//! ffmpeg writes fMP4 HLS into <cache>/hls/<sid>/ (event playlist, ~4 s
//! segments, temp_file renames so a reader never sees a partial segment).
//! At most MAX_SESSIONS run at once; an idle session is stopped and its
//! directory removed by tick(); quitting kills ffmpeg via bounded_process's
//! cancel flag. Decisions (direct/remux/transcode, encoder, argv, names,
//! tokens) live in stream_pure.zig.

const std = @import("std");
const builtin = @import("builtin");
const state = @import("../core/state.zig");
const io_g = @import("../core/io_global.zig");
const sync = @import("../core/sync.zig");
const logs = @import("../core/logs.zig");
const paths = @import("../core/paths.zig");
const workers = @import("../core/workers.zig");
const bounded = @import("../core/bounded_process.zig");
const alloc = @import("../core/alloc.zig").allocator;
const wire = @import("remote_http.zig");
const pure = @import("stream_pure.zig");
const rs_pure = @import("remote_stream_pure.zig");

pub const MAX_SESSIONS = 2;
/// A session nobody fetched from for this long is stopped and deleted.
pub const IDLE_MS: i64 = 10 * 60 * 1000;
/// How long a playlist request waits for ffmpeg's first segment.
const FIRST_SEGMENT_WAIT_MS: i64 = 20_000;
/// Hard ceiling on one encode (a long film at realtime-or-better fits easily).
const ENCODE_TIMEOUT_MS: i64 = 8 * 3600 * 1000;
const CHUNK = 256 * 1024;

const Slot = struct {
    // Guarded by `mutex`; immutable between create() and free while `used`.
    lifetime: pure.SlotLifetime = .{}, // guarded by mutex
    id: [pure.SID_LEN]u8 = undefined,
    path: [2048]u8 = undefined,
    path_len: usize = 0,
    title: [pure.TITLE_MAX]u8 = undefined,
    title_len: usize = 0,
    dir: [1024]u8 = undefined,
    dir_len: usize = 0,
    plan: pure.Plan = undefined,
    start_secs: u32 = 0,
    duration: f64 = 0,
    // Progress reported by the client, applied on the UI thread (guarded by `mutex`).
    progress_pos: f64 = 0,
    progress_dur: f64 = 0,
    progress_dirty: bool = false,
    // Cross-thread flags.
    last_ms: std.atomic.Value(i64) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),
    running: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),

    fn sid(self: *const Slot) []const u8 {
        return self.id[0..];
    }
    fn dirPath(self: *const Slot) []const u8 {
        return self.dir[0..self.dir_len];
    }
    fn touch(self: *Slot) void {
        self.last_ms.store(io_g.milliTimestamp(), .release);
    }
};

var slots: [MAX_SESSIONS]Slot = [_]Slot{.{}} ** MAX_SESSIONS;
var mutex: sync.Mutex = .{};
var key: [pure.KEY_LEN]u8 = undefined;
var key_ready = false; // under `mutex`
var hls_root_cleaned = false; // under `mutex`

// ── Key / tokens ──────────────────────────────────────────────────────────

fn ensureKeyLocked() bool {
    if (key_ready) return true;
    if (!io_g.randomSecure(&key)) return false;
    key_ready = true;
    return true;
}

/// Mint a token for `sid` valid for `ttl_secs`. Empty when no key could be made.
pub fn mint(sid: []const u8, ttl_secs: i64, out: *[pure.TOKEN_MAX]u8) []const u8 {
    mutex.lock();
    defer mutex.unlock();
    if (!ensureKeyLocked()) return out[0..0];
    return pure.mintToken(&key, sid, io_g.timestamp() + ttl_secs, out);
}

fn verify(sid: []const u8, token: []const u8) pure.Verdict {
    mutex.lock();
    defer mutex.unlock();
    if (!key_ready) return .invalid;
    return pure.verifyToken(&key, sid, token, io_g.timestamp());
}

// ── Encoder detection (once) ──────────────────────────────────────────────

var encoder_checked = false; // under `mutex`
var encoder_choice: pure.Encoder = .libx264;

fn deviceExists(p: []const u8) bool {
    io_g.cwdAccess(p, .{}) catch return false;
    return true;
}

fn encoder() pure.Encoder {
    mutex.lock();
    if (encoder_checked) {
        const e = encoder_choice;
        mutex.unlock();
        return e;
    }
    mutex.unlock();
    const out = alloc.alloc(u8, 256 * 1024) catch return .libx264;
    defer alloc.free(out);
    const ffmpeg = @import("remote_stream.zig").ffmpegPath();
    const r = bounded.run(&.{ ffmpeg, "-hide_banner", "-encoders" }, out, .{ .timeout_ms = 10_000 });
    const choice = pure.chooseEncoder(builtin.os.tag, r.output, deviceExists(pure.VAAPI_DEVICE), deviceExists("/dev/nvidia0"));
    mutex.lock();
    encoder_choice = choice;
    encoder_checked = true;
    mutex.unlock();
    return choice;
}

// ── Probe ─────────────────────────────────────────────────────────────────

fn probe(abs_path: []const u8) ?pure.Probe {
    var tool_buf: [256]u8 = undefined;
    const ffprobe = pure.siblingTool(@import("remote_stream.zig").ffmpegPath(), "ffprobe", &tool_buf) orelse return null;
    var input_buf: [2100]u8 = undefined;
    const input = std.fmt.bufPrint(&input_buf, "file:{s}", .{abs_path}) catch return null;
    const out = alloc.alloc(u8, 512 * 1024) catch return null;
    defer alloc.free(out);
    const r = bounded.run(&.{ ffprobe, "-v", "error", "-show_format", "-show_streams", "-of", "json", input }, out, .{ .timeout_ms = 20_000 });
    if (!r.ok()) return null;
    const dot = std.mem.lastIndexOfScalar(u8, abs_path, '.') orelse abs_path.len;
    return pure.parseProbe(alloc, r.output, abs_path[dot..]) catch null;
}

// ── Session lifecycle ─────────────────────────────────────────────────────

pub const CreateError = error{ NotFound, NoFfmpeg, ProbeFailed, Busy, NoEntropy, Io };

pub const Created = struct {
    sid: [pure.SID_LEN]u8 = undefined,
    token: [pure.TOKEN_MAX]u8 = undefined,
    token_len: usize = 0,
    mode: pure.Mode = .direct,
    offset: u32 = 0,
    duration: f64 = 0,
    encoder: pure.Encoder = .libx264,

    pub fn tokenText(self: *const Created) []const u8 {
        return self.token[0..self.token_len];
    }
    /// The entry file for this mode: the playlist, or the source for direct play.
    pub fn entry(self: *const Created) []const u8 {
        return if (self.mode == .direct) "direct" else pure.PLAYLIST;
    }
};

pub const CreateOptions = struct {
    abs_path: []const u8,
    title: []const u8,
    quality: pure.Quality = .original,
    caps: pure.Caps = pure.Caps.baseline,
    start_secs: u32 = 0,
    /// A peer Opal plays anything mpv does: skip probing and serve the file.
    force_direct: bool = false,
};

fn hlsRoot(buf: []u8) []const u8 {
    return paths.cacheFile(buf, "hls");
}

/// Stop + delete expired sessions whose worker is gone. Caller holds `mutex`.
fn reapLocked(now_ms: i64) void {
    for (&slots) |*s| {
        if (!s.lifetime.used) continue;
        const idle = pure.idleExpired(s.last_ms.load(.acquire), now_ms, IDLE_MS);
        if (idle) s.stop.store(true, .release);
        if ((idle or s.stop.load(.acquire)) and !s.running.load(.acquire) and !s.progress_dirty and s.lifetime.retire()) {
            if (s.dir_len > 0) io_g.cwdDeleteTree(s.dirPath()) catch {};
            s.lifetime.used = false;
        }
    }
}

pub fn create(opts: CreateOptions, out: *Created) CreateError!void {
    if (opts.abs_path.len == 0 or opts.abs_path[0] != '/' or opts.abs_path.len > 2047) return error.NotFound;
    {
        const f = io_g.openFileAbsolute(opts.abs_path, .{}) catch return error.NotFound;
        f.close(io_g.io());
    }
    var plan: pure.Plan = .{ .mode = .direct, .has_video = true, .has_audio = true, .copy_video = true, .copy_audio = true };
    var duration: f64 = 0;
    if (!opts.force_direct) {
        if (!@import("remote_stream.zig").haveFfmpeg()) return error.NoFfmpeg;
        const p = probe(opts.abs_path) orelse return error.ProbeFailed;
        plan = pure.decide(p, opts.caps, opts.quality);
        duration = p.duration;
    }
    const enc: pure.Encoder = if (plan.mode == .transcode) encoder() else .libx264;

    var id_bytes: [pure.SID_LEN / 2]u8 = undefined;
    if (!io_g.randomSecure(&id_bytes)) return error.NoEntropy;

    var root_buf: [1024]u8 = undefined;
    const root = hlsRoot(&root_buf);
    const slot: *Slot = blk: {
        mutex.lock();
        defer mutex.unlock();
        if (!ensureKeyLocked()) return error.NoEntropy;
        if (!hls_root_cleaned) {
            // Leftovers from a previous run (crash, kill -9) are never served.
            io_g.cwdDeleteTree(root) catch {};
            hls_root_cleaned = true;
        }
        reapLocked(io_g.milliTimestamp());
        for (&slots) |*s| {
            if (s.lifetime.used) continue;
            s.* = .{};
            const reserved = s.lifetime.reserve();
            std.debug.assert(reserved);
            _ = pure.sessionIdFromBytes(id_bytes, &s.id);
            @memcpy(s.path[0..opts.abs_path.len], opts.abs_path);
            s.path_len = opts.abs_path.len;
            const tn = @min(opts.title.len, s.title.len);
            @memcpy(s.title[0..tn], opts.title[0..tn]);
            s.title_len = tn;
            s.plan = plan;
            s.start_secs = if (plan.mode == .direct) 0 else opts.start_secs;
            s.duration = duration;
            s.touch();
            if (plan.mode != .direct) {
                const d = std.fmt.bufPrint(&s.dir, "{s}/{s}", .{ root, s.sid() }) catch {
                    s.lifetime.used = false;
                    return error.Io;
                };
                s.dir_len = d.len;
                s.running.store(true, .release);
            }
            break :blk s;
        }
        return error.Busy;
    };

    defer unpin(slot);
    if (plan.mode != .direct) {
        io_g.cwdMakePath(slot.dirPath()) catch {
            release(slot);
            return error.Io;
        };
        const thread = workers.spawnLegacy(encodeWorker, .{ slot, enc }) catch {
            release(slot);
            return error.Io;
        };
        workers.release(thread);
    }

    out.* = .{};
    @memcpy(&out.sid, &slot.id);
    out.mode = plan.mode;
    out.offset = slot.start_secs;
    out.duration = duration;
    out.encoder = enc;
    mutex.lock();
    const tok = pure.mintToken(&key, slot.sid(), io_g.timestamp() + pure.TOKEN_TTL_SECS, &out.token);
    mutex.unlock();
    out.token_len = tok.len;

    var log_buf: [160]u8 = undefined;
    logs.pushLog("info", "stream", std.fmt.bufPrint(&log_buf, "stream session {s}: {s}{s}{s}", .{
        out.sid[0..8],
        @tagName(plan.mode),
        if (plan.mode == .transcode) " via " else "",
        if (plan.mode == .transcode) pure.encoderName(enc) else "",
    }) catch "stream session started", false);
}

fn release(slot: *Slot) void {
    slot.running.store(false, .release);
    mutex.lock();
    defer mutex.unlock();
    if (slot.dir_len > 0) io_g.cwdDeleteTree(slot.dirPath()) catch {};
    slot.stop.store(true, .release);
}

fn encodeWorker(slot: *Slot, enc: pure.Encoder) void {
    defer slot.running.store(false, .release);
    var args: pure.ArgBuf = .{};
    const argv = pure.buildFfmpegArgs(&args, @import("remote_stream.zig").ffmpegPath(), slot.path[0..slot.path_len], slot.plan, enc, slot.start_secs) catch {
        slot.failed.store(true, .release);
        return;
    };
    var proc = bounded.StreamProcess.init(argv, .{
        .timeout_ms = ENCODE_TIMEOUT_MS,
        .max_output_bytes = 1024 * 1024,
        .cwd = slot.dirPath(),
        .cancel_flag = workers.quittingSignal(),
        .abort_flag = &slot.stop,
    });
    proc.start() catch {
        slot.failed.store(true, .release);
        logs.pushLog("warn", "stream", "stream: could not start ffmpeg", true);
        return;
    };
    const res = proc.finish();
    if (!res.ok() and !slot.stop.load(.acquire) and !workers.isQuitting()) {
        slot.failed.store(true, .release);
        logs.pushLog("warn", "stream", "stream: ffmpeg failed for this file", true);
    }
}

fn find(sid: []const u8) ?*Slot {
    mutex.lock();
    defer mutex.unlock();
    for (&slots) |*s| {
        if (s.lifetime.used and !s.stop.load(.acquire) and std.mem.eql(u8, s.sid(), sid)) {
            s.lifetime.acquire();
            return s;
        }
    }
    return null;
}

fn unpin(s: *Slot) void {
    mutex.lock();
    defer mutex.unlock();
    s.lifetime.release();
}

/// Stop a session now (its directory goes on the next tick).
pub fn stop(sid: []const u8) bool {
    const s = find(sid) orelse return false;
    defer unpin(s);
    s.stop.store(true, .release);
    return true;
}

/// UI thread (and the headless loop): reap idle sessions and apply reported
/// progress through the same history path the desktop player uses.
pub fn tick() void {
    const Pending = struct { title: [pure.TITLE_MAX]u8 = undefined, title_len: usize = 0, path: [2048]u8 = undefined, path_len: usize = 0, pos: f64 = 0, dur: f64 = 0 };
    var pending: [MAX_SESSIONS]Pending = undefined;
    var n: usize = 0;
    mutex.lock();
    for (&slots) |*s| {
        if (!s.lifetime.used or !s.progress_dirty) continue;
        s.progress_dirty = false;
        const p = &pending[n];
        p.* = .{ .pos = s.progress_pos, .dur = s.progress_dur };
        @memcpy(p.title[0..s.title_len], s.title[0..s.title_len]);
        p.title_len = s.title_len;
        @memcpy(p.path[0..s.path_len], s.path[0..s.path_len]);
        p.path_len = s.path_len;
        n += 1;
    }
    reapLocked(io_g.milliTimestamp());
    mutex.unlock();
    for (pending[0..n]) |*p| {
        const percent = pure.percentOf(p.pos, p.dur);
        const name = if (p.title_len > 0) p.title[0..p.title_len] else std.fs.path.basename(p.path[0..p.path_len]);
        @import("../player/watch_history.zig").savePositionFull(name, percent, p.pos, p.dur, p.path[0..p.path_len], 0);
    }
}

pub fn activeCount() usize {
    mutex.lock();
    defer mutex.unlock();
    var n: usize = 0;
    for (&slots) |*s| {
        if (s.lifetime.used) n += 1;
    }
    return n;
}

// ── HTTP ──────────────────────────────────────────────────────────────────

/// Token-authenticated fetches, routed by remote.zig BEFORE its API auth gate.
/// Returns false for anything that is not `/api/stream/<sid>/<token>/<name>`,
/// so the request falls through to normal authentication.
pub fn handlePublic(stream: std.Io.net.Stream, method: []const u8, path: []const u8, request: []const u8) bool {
    const prefix = "/api/stream/";
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    const sp = pure.parseStreamPath(path[prefix.len..]) orelse return false;
    const token = sp.token orelse return false;
    switch (verify(sp.sid, token)) {
        .ok => {},
        .expired => {
            wire.sendJsonStatus(stream, "401 Unauthorized", "{\"error\":\"stream link expired\"}");
            return true;
        },
        .invalid => {
            wire.sendJsonStatus(stream, "401 Unauthorized", "{\"error\":\"unauthorized\"}");
            return true;
        },
    }
    serveNamed(stream, method, sp.sid, sp.name, request);
    return true;
}

/// Routes under `/api` reached after normal API authentication.
pub fn handleApi(stream: std.Io.net.Stream, method: []const u8, api_path: []const u8, query: []const u8, body: []const u8, request: []const u8) bool {
    if (std.mem.eql(u8, api_path, "/stream")) {
        if (std.mem.eql(u8, method, "GET")) {
            var buf: [160]u8 = undefined;
            const j = std.fmt.bufPrint(&buf, "{{\"ok\":true,\"ffmpeg\":{s},\"encoder\":\"{s}\",\"sessions\":{d},\"max\":{d}}}", .{
                if (@import("remote_stream.zig").haveFfmpeg()) "true" else "false",
                pure.encoderName(encoder()),
                activeCount(),
                MAX_SESSIONS,
            }) catch return true;
            wire.sendJson(stream, j);
        } else if (wire.requireMethod(stream, method, "POST")) {
            createRoute(stream, query, body);
        }
        return true;
    }
    const prefix = "/stream/";
    if (!std.mem.startsWith(u8, api_path, prefix)) return false;
    const sp = pure.parseStreamPath(api_path[prefix.len..]) orelse {
        wire.sendJsonStatus(stream, "404 Not Found", "{\"error\":\"no such stream file\"}");
        return true;
    };
    // A tokenized path that reached here already passed API auth; the token is
    // still checked so a stale link behaves the same either way.
    if (sp.token) |tok| if (verify(sp.sid, tok) != .ok) {
        wire.sendJsonStatus(stream, "401 Unauthorized", "{\"error\":\"stream link expired\"}");
        return true;
    };
    serveNamed(stream, method, sp.sid, sp.name, request);
    return true;
}

fn requestBody(request: []const u8) []const u8 {
    const i = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return "";
    return request[i + 4 ..];
}

fn sendError(stream: std.Io.net.Stream, e: CreateError) void {
    switch (e) {
        error.NotFound => wire.sendJsonStatus(stream, "404 Not Found", "{\"error\":\"media not found\"}"),
        error.NoFfmpeg => wire.sendJsonStatus(stream, "501 Not Implemented", "{\"error\":\"ffmpeg not installed: streaming unavailable\"}"),
        error.ProbeFailed => wire.sendJsonStatus(stream, "422 Unprocessable Entity", "{\"error\":\"this file could not be read\"}"),
        error.Busy => wire.sendJsonStatus(stream, "503 Service Unavailable", "{\"error\":\"two streams are already running: stop one first\"}"),
        error.NoEntropy, error.Io => wire.sendJsonStatus(stream, "500 Internal Server Error", "{\"error\":\"could not start the stream\"}"),
    }
}

/// The desktop's current item when it is a local file: absolute path, title
/// and position. Pauses it when asked ("take over on this device").
pub const CurrentLocal = struct {
    path: [2048]u8 = undefined,
    path_len: usize = 0,
    title: [pure.TITLE_MAX]u8 = undefined,
    title_len: usize = 0,
    position: f64 = 0,
    duration: f64 = 0,
};

pub fn currentLocal(out: *CurrentLocal, pause: bool) bool {
    const h = @import("handoff.zig");
    var cur: h.Current = .{};
    if (!h.snapshotCurrent(&cur, pause)) return false;
    const local = h.localPathOf(cur.source()) orelse return false;
    if (local.len > out.path.len) return false;
    @memcpy(out.path[0..local.len], local);
    out.path_len = local.len;
    @memcpy(out.title[0..cur.title_len], cur.title[0..cur.title_len]);
    out.title_len = cur.title_len;
    out.position = cur.position;
    out.duration = cur.duration;
    return true;
}

fn createRoute(stream: std.Io.net.Stream, query: []const u8, body: []const u8) void {
    var path_buf: [2048]u8 = undefined;
    var title_buf: [pure.TITLE_MAX]u8 = undefined;
    var abs_path: []const u8 = "";
    var title: []const u8 = "";
    var start: f64 = 0;
    var dec: [128]u8 = undefined;
    if (wire.formParam(body, query, "start", &dec)) |s| start = std.fmt.parseFloat(f64, s) catch 0;
    const want_pause = std.mem.eql(u8, wire.formParam(body, query, "pause_source", &dec) orelse "", "1");

    if (wire.formParam(body, query, "id", &dec)) |id_text| {
        const id = std.fmt.parseInt(i64, id_text, 10) catch 0;
        const lib = @import("local_library.zig");
        const got = lib.pathById(id, &path_buf, &title_buf) orelse return sendError(stream, error.NotFound);
        abs_path = got.path;
        title = got.title;
    } else if (std.mem.eql(u8, wire.formParam(body, query, "current", &dec) orelse "", "1")) {
        var cur: CurrentLocal = .{};
        if (!currentLocal(&cur, want_pause)) {
            wire.sendJsonStatus(stream, "409 Conflict", "{\"error\":\"the desktop is not playing a local file\"}");
            return;
        }
        @memcpy(path_buf[0..cur.path_len], cur.path[0..cur.path_len]);
        abs_path = path_buf[0..cur.path_len];
        @memcpy(title_buf[0..cur.title_len], cur.title[0..cur.title_len]);
        title = title_buf[0..cur.title_len];
        if (start <= 0) start = cur.position;
    } else {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"pass id= or current=1\"}");
        return;
    }
    var caps_buf: [160]u8 = undefined;
    const caps = pure.parseCaps(wire.formParam(body, query, "caps", &caps_buf) orelse "");
    var q_buf: [16]u8 = undefined;
    const quality = pure.parseQuality(wire.formParam(body, query, "quality", &q_buf) orelse "original");
    const start_secs: u32 = if (std.math.isFinite(start) and start > 0) @intFromFloat(@min(start, pure.MAX_POSITION)) else 0;

    var created: Created = .{};
    create(.{ .abs_path = abs_path, .title = title, .quality = quality, .caps = caps, .start_secs = start_secs }, &created) catch |e| return sendError(stream, e);

    var json: [1400]u8 = undefined;
    var w = std.Io.Writer.fixed(&json);
    w.print("{{\"ok\":true,\"sid\":\"{s}\",\"mode\":\"{s}\",\"quality\":\"{s}\",\"url\":\"/api/stream/{s}/{s}/{s}\",\"offset\":{d},\"start\":{d},\"duration\":{d:.3},\"encoder\":\"{s}\",\"title\":\"", .{
        created.sid[0..],
        @tagName(created.mode),
        pure.qualityName(quality),
        created.sid[0..],
        created.tokenText(),
        created.entry(),
        created.offset,
        start_secs,
        created.duration,
        if (created.mode == .transcode) pure.encoderName(created.encoder) else "copy",
    }) catch return;
    wire.writeJsonString(&w, title);
    w.writeAll("\"}") catch return;
    wire.sendJson(stream, json[0..w.end]);
}

fn serveNamed(stream: std.Io.net.Stream, method: []const u8, sid: []const u8, name: []const u8, request: []const u8) void {
    const s = find(sid) orelse {
        wire.sendJsonStatus(stream, "404 Not Found", "{\"error\":\"stream session ended\"}");
        return;
    };
    defer unpin(s);
    s.touch();
    if (std.mem.eql(u8, name, "stop")) {
        if (!wire.requireMethod(stream, method, "POST")) return;
        s.stop.store(true, .release);
        s.last_ms.store(0, .release); // reap on the next tick
        wire.sendJson(stream, "{\"ok\":true}");
        return;
    }
    if (std.mem.eql(u8, name, "progress")) {
        if (!wire.requireMethod(stream, method, "POST")) return;
        const body = requestBody(request);
        var dec: [64]u8 = undefined;
        const pos = std.fmt.parseFloat(f64, wire.formParam(body, "", "pos", &dec) orelse "") catch -1;
        const dur = std.fmt.parseFloat(f64, wire.formParam(body, "", "dur", &dec) orelse "") catch 0;
        if (!std.math.isFinite(pos) or pos < 0 or pos > pure.MAX_POSITION) {
            wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"invalid position\"}");
            return;
        }
        mutex.lock();
        s.progress_pos = pos;
        s.progress_dur = if (std.math.isFinite(dur) and dur > 0) dur else s.duration;
        s.progress_dirty = true;
        mutex.unlock();
        state.wakeUi();
        wire.sendJson(stream, "{\"ok\":true}");
        return;
    }
    if (!std.mem.eql(u8, method, "GET") and !std.mem.eql(u8, method, "HEAD")) {
        _ = wire.requireMethod(stream, method, "GET");
        return;
    }
    if (std.mem.eql(u8, name, "direct")) {
        if (s.plan.mode != .direct) {
            wire.sendJsonStatus(stream, "404 Not Found", "{\"error\":\"this session is HLS\"}");
            return;
        }
        serveDirect(stream, s.path[0..s.path_len], request);
        return;
    }
    if (s.plan.mode == .direct or !pure.isFileName(name)) {
        wire.sendJsonStatus(stream, "404 Not Found", "{\"error\":\"no such stream file\"}");
        return;
    }
    var file_buf: [1100]u8 = undefined;
    const file_path = std.fmt.bufPrint(&file_buf, "{s}/{s}", .{ s.dirPath(), name }) catch return;
    if (std.mem.eql(u8, name, pure.PLAYLIST)) {
        servePlaylist(stream, s, file_path);
        return;
    }
    serveFile(stream, file_path, if (std.mem.eql(u8, name, pure.INIT)) "video/mp4" else "video/iso.segment");
}

fn servePlaylist(stream: std.Io.net.Stream, s: *Slot, file_path: []const u8) void {
    const deadline = io_g.milliTimestamp() + FIRST_SEGMENT_WAIT_MS;
    const buf = alloc.alloc(u8, 512 * 1024) catch return;
    defer alloc.free(buf);
    while (true) {
        if (io_g.openFileAbsolute(file_path, .{})) |f| {
            const n = f.readPositionalAll(io_g.io(), buf, 0) catch 0;
            f.close(io_g.io());
            if (n > 0 and std.mem.indexOf(u8, buf[0..n], "#EXTINF") != null) {
                var hdr: [256]u8 = undefined;
                const h = std.fmt.bufPrint(&hdr, "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nCache-Control: no-store\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\n\r\n", .{n}) catch return;
                io_g.streamWriteAll(stream, h) catch return;
                io_g.streamWriteAll(stream, buf[0..n]) catch {};
                return;
            }
        } else |_| {}
        if (s.failed.load(.acquire)) {
            wire.sendJsonStatus(stream, "502 Bad Gateway", "{\"error\":\"the encoder failed for this file\"}");
            return;
        }
        if (!s.running.load(.acquire) or io_g.milliTimestamp() > deadline or workers.isQuitting()) {
            wire.sendJsonStatus(stream, "503 Service Unavailable", "{\"error\":\"stream is not ready yet\"}");
            return;
        }
        io_g.sleep(200 * std.time.ns_per_ms);
    }
}

fn serveFile(stream: std.Io.net.Stream, file_path: []const u8, content_type: []const u8) void {
    const f = io_g.openFileAbsolute(file_path, .{}) catch {
        wire.sendJsonStatus(stream, "404 Not Found", "{\"error\":\"no such stream file\"}");
        return;
    };
    defer f.close(io_g.io());
    const size = f.length(io_g.io()) catch return;
    var hdr: [256]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nCache-Control: no-store\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\n\r\n", .{ content_type, size }) catch return;
    io_g.streamWriteAll(stream, h) catch return;
    pump(stream, f, 0, size);
}

fn pump(stream: std.Io.net.Stream, f: std.Io.File, start: u64, total: u64) void {
    const buf = alloc.alloc(u8, CHUNK) catch return;
    defer alloc.free(buf);
    var off = start;
    var left = total;
    while (left > 0) {
        const want: usize = @intCast(@min(left, buf.len));
        const n = f.readPositionalAll(io_g.io(), buf[0..want], off) catch break;
        if (n == 0) break;
        io_g.streamWriteAll(stream, buf[0..n]) catch break;
        off += n;
        left -= n;
    }
}

fn headerValue(request: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, request, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name))
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

/// Range-aware serving of the session's source file (direct play / peer mpv).
fn serveDirect(stream: std.Io.net.Stream, abs_path: []const u8, request: []const u8) void {
    const f = io_g.openFileAbsolute(abs_path, .{}) catch {
        wire.sendJsonStatus(stream, "404 Not Found", "{\"error\":\"media not found\"}");
        return;
    };
    defer f.close(io_g.io());
    const size = f.length(io_g.io()) catch return;
    const range: ?rs_pure.Range = if (headerValue(request, "range")) |rv| rs_pure.parseRange(rv, size) else null;
    const start: u64 = if (range) |r| r.start else 0;
    const end: u64 = if (range) |r| r.end else (if (size > 0) size - 1 else 0);
    const total: u64 = if (size == 0) 0 else end - start + 1;
    var hdr: [512]u8 = undefined;
    const ct = rs_pure.contentType(abs_path);
    const h = if (range != null)
        std.fmt.bufPrint(&hdr, "HTTP/1.1 206 Partial Content\r\nContent-Type: {s}\r\nAccept-Ranges: bytes\r\nContent-Range: bytes {d}-{d}/{d}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\n\r\n", .{ ct, start, end, size, total }) catch return
    else
        std.fmt.bufPrint(&hdr, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nAccept-Ranges: bytes\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\n\r\n", .{ ct, size }) catch return;
    io_g.streamWriteAll(stream, h) catch return;
    if (std.mem.startsWith(u8, request, "HEAD ")) return;
    pump(stream, f, start, total);
}
