const std = @import("std");
const state = @import("../core/state.zig");
const io_g = @import("../core/io_global.zig");
const logs = @import("../core/logs.zig");
const workers = @import("../core/workers.zig");
const pure = @import("cast_pure.zig");
const cv2 = @import("cast_v2_pure.zig");
const dlna = @import("dlna_pure.zig");
const net = @import("cast_net.zig");

// ══════════════════════════════════════════════════════════
// Cast — send media to a Chromecast (native Cast v2), a DLNA / UPnP renderer
// (native AVTransport) or AirPlay (pyatv, optional). Chromecast and DLNA need
// no external tool: discovery is mDNS / SSDP, control is cast_net.zig, wire
// formats are cast_v2_pure.zig / dlna_pure.zig. A local file is served to the
// receiver through a signed stream session on the LAN cast listener
// (cast_serve.zig). Newer Apple TVs refuse play_url until paired once: see
// the pairing section at the end.
// ══════════════════════════════════════════════════════════

const alloc = @import("../core/alloc.zig").allocator;

pub const CastDevice = pure.CastDevice;
pub const Protocol = pure.Protocol;

const scan_wait_ms: i64 = 2500;
const load_timeout_ms: i64 = 20_000;
const control_timeout_ms: i64 = 8_000;
const status_timeout_ms: i64 = 4_000;
/// /cast/status answers from the cache when it is younger than this.
const status_fresh_ms: i64 = 1_000;

// Device list + cast target: written by the scan/cast workers, read by the
// UI thread and remote.zig's connection threads → guarded by `mutex`. Readers
// take a copy via `snapshot`.
var mutex: @import("../core/sync.zig").Mutex = .{};
var devices: [pure.max_devices]CastDevice = undefined;
var device_count: usize = 0;
/// Last device cast to (by value: a rescan may reorder the list).
var active: ?CastDevice = null;
/// Running cast process, so stop can end it (AirPlay play_url blocks until
/// playback ends).
var active_child: ?io_g.Child.Id = null;
/// Stream session serving a local file to the receiver (empty when none).
var active_sid: [@import("stream_pure.zig").SID_LEN]u8 = undefined;
var active_sid_len: usize = 0;
var active_title: [200]u8 = undefined;
var active_title_len: usize = 0;
// Last known receiver status (guarded by `mutex`).
var st_state: cv2.PlayerState = .unknown;
var st_position: f64 = 0;
var st_duration: f64 = 0;
var st_updated_ms: i64 = 0;
var st_error: [160]u8 = undefined;
var st_error_len: usize = 0;

// Polled by the UI thread AND remote.zig's connection threads → atomics.
pub var is_scanning: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
pub var is_casting: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var status_busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// ── AirPlay pairing: one `atvremote ... pair` session at a time ──
// `is_pairing` is the spawn guard (set by startPairing, cleared once the
// worker has reaped atvremote). Everything else is guarded by `mutex`.
pub var is_pairing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var pair_phase: pure.PairPhase = .idle;
/// Bumped per session so a late watchdog never ends a newer session.
var pair_gen: u32 = 0;
var pair_target: CastDevice = .{};
var pair_child: ?io_g.Child.Id = null;
/// Write end of atvremote's stdin. Whoever takes it out under `mutex` (PIN
/// submit, cancel, timeout, worker exit) closes it, so it closes exactly once.
var pair_stdin: ?std.Io.File = null;
var pair_deadline_ms: i64 = 0;
var pair_msg: [160]u8 = undefined;
var pair_msg_len: usize = 0;
/// Scan + pair-setup + the user reading the PIN off the TV.
const pair_timeout_ms: i64 = 150_000;
/// After the PIN is sent, pair-setup finishes in a few seconds.
const pair_verify_timeout_ms: i64 = 45_000;

pub const Snapshot = struct {
    devices: [pure.max_devices]CastDevice = undefined,
    count: usize = 0,
    /// Index of the active target in `devices`, if it is still listed.
    active_idx: ?usize = null,
    pair_phase: pure.PairPhase = .idle,
    pair_name: [64]u8 = undefined,
    pair_name_len: usize = 0,
    pair_msg: [160]u8 = undefined,
    pair_msg_len: usize = 0,

    pub fn pairName(self: *const Snapshot) []const u8 {
        return self.pair_name[0..self.pair_name_len];
    }
    pub fn pairMsg(self: *const Snapshot) []const u8 {
        return self.pair_msg[0..self.pair_msg_len];
    }
};

/// Consistent copy of the device list for readers on other threads.
pub fn snapshot(out: *Snapshot) void {
    mutex.lock();
    defer mutex.unlock();
    out.count = @min(device_count, pure.max_devices);
    @memcpy(out.devices[0..out.count], devices[0..out.count]);
    out.pair_phase = pair_phase;
    const name = pair_target.nameSlice();
    out.pair_name_len = name.len;
    @memcpy(out.pair_name[0..name.len], name);
    out.pair_msg_len = pair_msg_len;
    @memcpy(out.pair_msg[0..pair_msg_len], pair_msg[0..pair_msg_len]);
    out.active_idx = null;
    if (active) |*a| {
        for (out.devices[0..out.count], 0..) |*d, i| {
            if (d.sameTarget(a)) {
                out.active_idx = i;
                break;
            }
        }
    }
}

pub fn deviceCount() usize {
    mutex.lock();
    defer mutex.unlock();
    return device_count;
}

/// What /cast/status reports.
pub const Status = struct {
    casting: bool = false,
    has_device: bool = false,
    device: CastDevice = .{},
    state: cv2.PlayerState = .unknown,
    position: f64 = 0,
    duration: f64 = 0,
    title: [200]u8 = undefined,
    title_len: usize = 0,
    err: [160]u8 = undefined,
    err_len: usize = 0,

    pub fn titleText(self: *const Status) []const u8 {
        return self.title[0..self.title_len];
    }
    pub fn errText(self: *const Status) []const u8 {
        return self.err[0..self.err_len];
    }
};

fn statusLocked(out: *Status) void {
    out.casting = is_casting.load(.acquire);
    out.has_device = active != null;
    if (active) |a| out.device = a;
    out.state = st_state;
    out.position = st_position;
    out.duration = st_duration;
    out.title_len = active_title_len;
    @memcpy(out.title[0..active_title_len], active_title[0..active_title_len]);
    out.err_len = st_error_len;
    @memcpy(out.err[0..st_error_len], st_error[0..st_error_len]);
}

/// Record a receiver answer (CALLER HOLDS `mutex`).
fn applyResultLocked(r: *const net.Result) void {
    if (r.ok) {
        if (r.state != .unknown) st_state = r.state;
        if (r.position >= 0) st_position = r.position;
        if (r.duration > 0) st_duration = r.duration;
        st_error_len = 0;
    } else {
        const n = @min(r.err.len, st_error.len);
        @memcpy(st_error[0..n], r.err[0..n]);
        st_error_len = n;
    }
    st_updated_ms = io_g.monotonicMilliTimestamp();
}

fn applyResult(r: *const net.Result) void {
    mutex.lock();
    defer mutex.unlock();
    applyResultLocked(r);
}

/// Read a spawned scan tool's stdout to EOF into `buf`, keep the newest
/// stderr bytes in `err_tail` (when piped), then reap it. stderr is drained
/// second: atvscript writes only a short exit traceback there, far below the
/// pipe buffer, so it cannot block stdout while that is read.
fn collect(child: *io_g.Child, buf: []u8, err_tail: []u8) struct { out: usize, err: usize } {
    const n = if (child.stdout) |*stdout| io_g.readAll(stdout, buf) catch 0 else 0;
    var err_len: usize = 0;
    var chunk: [512]u8 = undefined;
    if (child.stderr) |*pipe| while (true) {
        const got = io_g.read(pipe, &chunk) catch 0;
        if (got == 0) break;
        err_len = pure.appendTail(err_tail, err_len, chunk[0..got]);
    };
    _ = child.wait() catch {};
    return .{ .out = n, .err = err_len };
}

/// Read a running tool's stdout, then stderr, to EOF, keeping the newest
/// `tail.len` bytes of both. Sequential is safe for atvremote: it logs at
/// WARNING level, so stderr only ever holds an exit traceback (a few KB, far
/// below the pipe buffer) and cannot block it while stdout is drained.
fn drainTail(child: *io_g.Child, tail: []u8) usize {
    var len: usize = 0;
    var chunk: [1024]u8 = undefined;
    inline for (.{ "stdout", "stderr" }) |field| {
        if (@field(child, field)) |*pipe| {
            while (true) {
                const n = io_g.read(pipe, &chunk) catch 0;
                if (n == 0) break;
                len = pure.appendTail(tail, len, chunk[0..n]);
            }
        }
    }
    return len;
}

/// Discover devices: Chromecasts over mDNS and DLNA renderers over SSDP
/// (native, always available) plus AirPlay through `atvscript scan` when
/// pyatv is installed. atvscript runs while the native scans wait.
pub fn scanDevices() void {
    if (is_scanning.swap(true, .acq_rel)) return;

    if (workers.spawnLegacy(struct {
        fn worker() void {
            defer is_scanning.store(false, .release);

            var atv = io_g.Child.init(&pure.atv_scan_argv, alloc);
            atv.stdin_behavior = .Ignore;
            atv.stdout_behavior = .Pipe;
            atv.stderr_behavior = .Pipe; // a startup traceback explains an empty scan
            const have_atv = if (atv.spawn()) |_| true else |_| false;

            const found = alloc.create([pure.max_devices]CastDevice) catch {
                if (have_atv) _ = atv.kill() catch {};
                return;
            };
            defer alloc.destroy(found);
            var n: usize = 0;

            var ccs: [pure.max_devices]cv2.Found = undefined;
            const mdns_dest = std.Io.net.IpAddress.parseIp4(cv2.mdns_group, cv2.mdns_port) catch unreachable;
            const ncc = net.discoverChromecasts(mdns_dest, scan_wait_ms, &ccs);
            for (ccs[0..ncc]) |*f| {
                if (n >= found.len) break;
                found[n] = pure.fromChromecast(f);
                n += 1;
            }
            const renderers = alloc.create([8]dlna.Renderer) catch return;
            defer alloc.destroy(renderers);
            const ssdp_dest = std.Io.net.IpAddress.parseIp4(dlna.ssdp_group, dlna.ssdp_port) catch unreachable;
            const nr = net.discoverRenderers(ssdp_dest, scan_wait_ms, renderers);
            for (renderers[0..nr]) |*r| {
                if (n >= found.len) break;
                found[n] = pure.fromRenderer(r);
                n += 1;
            }

            var atv_broken = false;
            if (have_atv) {
                // Heap: atvscript JSON carries device_info per device.
                const buf = alloc.alloc(u8, 64 * 1024) catch {
                    _ = atv.kill() catch {};
                    return;
                };
                defer alloc.free(buf);
                var err_tail: [2048]u8 = undefined;
                const got = collect(&atv, buf, &err_tail);
                n = pure.parseAtvscriptScan(alloc, buf[0..got.out], found, n);
                atv_broken = pure.pyatvEventLoopBroken(err_tail[0..got.err]);
            }

            mutex.lock();
            pure.carryNeedsPairing(devices[0..device_count], found[0..n]);
            @memcpy(devices[0..n], found[0..n]);
            device_count = n;
            mutex.unlock();

            if (n > 0) {
                var msg: [64]u8 = undefined;
                const toast = std.fmt.bufPrint(&msg, "Found {d} cast device(s)", .{n}) catch "Devices found";
                state.showToast(toast);
            } else {
                state.showToast(if (atv_broken) pure.msg_pyatv_python else "No cast devices found");
            }
        }
    }.worker, .{})) |t| workers.release(t) else |_| is_scanning.store(false, .release);
}

/// Cast `url` to device `device_idx` of the current list, starting at
/// `start_secs`. Returns null when the cast was started, else a user-facing
/// reason (also toasted).
///
/// The URL is a PARAMETER, not read from `state.app.players` here: every caller
/// already holds `state.players_mutex`. See `castActive`.
pub fn castTo(device_idx: usize, url: []const u8, title: []const u8, start_secs: f64) ?[]const u8 {
    if (pure.castRefusal(url)) |why| {
        state.showToast(why);
        return why;
    }

    mutex.lock();
    if (device_idx >= device_count) {
        mutex.unlock();
        state.showToast(pure.msg_no_device);
        return pure.msg_no_device;
    }
    const dev = devices[device_idx];
    mutex.unlock();

    const url_copy = alloc.dupe(u8, url) catch return "Out of memory";
    const title_copy = alloc.dupe(u8, title) catch {
        alloc.free(url_copy);
        return "Out of memory";
    };

    stopRunning(); // one cast at a time
    stopStreamSession();
    mutex.lock();
    active = dev;
    active_title_len = @min(title.len, active_title.len);
    @memcpy(active_title[0..active_title_len], title[0..active_title_len]);
    st_state = .buffering;
    st_position = 0;
    st_duration = 0;
    st_error_len = 0;
    mutex.unlock();
    is_casting.store(true, .release);

    const spawned = if (dev.protocol == .airplay)
        workers.spawnLegacy(airplayWorker, .{ dev, url_copy, title_copy })
    else
        workers.spawnLegacy(nativeWorker, .{ dev, url_copy, title_copy, start_secs });
    if (spawned) |t| {
        workers.release(t);
        return null;
    } else |_| {
        alloc.free(url_copy);
        alloc.free(title_copy);
        is_casting.store(false, .release);
        return "Cast failed";
    }
}

/// Media as the receiver will fetch it.
const Media = struct {
    url: [2400]u8 = undefined,
    url_len: usize = 0,
    content_type: []const u8 = "video/mp4",
    hls: bool = false,
    /// Where the receiver should start (0 when the stream itself starts there).
    start_secs: f64 = 0,

    fn text(self: *const Media) []const u8 {
        return self.url[0..self.url_len];
    }
};

/// Resolve `src` for `dev`: a network URL passes through; a local file gets
/// a signed stream session on the LAN cast listener (transcoded to fMP4 HLS
/// for a Chromecast when it cannot decode the file; served as-is to DLNA).
fn resolveMedia(dev: *const CastDevice, src: []const u8, title: []const u8, start_secs: f64, out: *Media) ?[]const u8 {
    const source = pure.classifySource(src);
    switch (source.kind) {
        .refused => return source.text,
        .network => {
            if (source.text.len > out.url.len) return pure.msg_url_too_long;
            @memcpy(out.url[0..source.text.len], source.text);
            out.url_len = source.text.len;
            out.content_type = pure.contentTypeFor(source.text);
            out.hls = std.mem.eql(u8, out.content_type, "application/x-mpegURL");
            out.start_secs = start_secs;
            return null;
        },
        .local_file => {},
    }
    const session = @import("stream_session.zig");
    const sp = @import("stream_pure.zig");
    const start_whole: u32 = if (std.math.isFinite(start_secs) and start_secs > 0) @intFromFloat(@min(start_secs, sp.MAX_POSITION)) else 0;
    var created: session.Created = .{};
    session.create(.{
        .abs_path = source.text,
        .title = title,
        .caps = sp.parseCaps(pure.chromecast_caps),
        .start_secs = start_whole,
        // A TV's own decoder handles far more than a Chromecast: hand it the file.
        .force_direct = dev.protocol == .dlna,
    }, &created) catch |e| return switch (e) {
        error.NotFound => "The file to cast no longer exists",
        error.NoFfmpeg => "Casting this file needs ffmpeg",
        error.Busy => "Too many streams are running; stop one and retry",
        else => "Could not prepare the file for casting",
    };
    const port = @import("cast_serve.zig").ensure();
    var host_buf: [46]u8 = undefined;
    const host = net.localAddressFor(dev.ipSlice(), &host_buf);
    if (port == 0 or host.len == 0 or std.mem.startsWith(u8, host, "0.")) {
        _ = session.stop(created.sid[0..]);
        return pure.msg_no_lan;
    }
    const u = pure.streamUrl(&out.url, host, port, created.sid[0..], created.tokenText(), created.entry()) orelse {
        _ = session.stop(created.sid[0..]);
        return pure.msg_url_too_long;
    };
    out.url_len = u.len;
    out.hls = created.mode != .direct;
    out.content_type = if (out.hls) "application/x-mpegURL" else pure.contentTypeFor(source.text);
    // An HLS session already starts at the offset; direct play seeks there.
    out.start_secs = if (out.hls) 0 else start_secs;
    mutex.lock();
    @memcpy(active_sid[0..created.sid.len], created.sid[0..]);
    active_sid_len = created.sid.len;
    mutex.unlock();
    return null;
}

fn stillActive(d: *const CastDevice) bool {
    mutex.lock();
    defer mutex.unlock();
    return if (active) |*a| a.sameTarget(d) else false;
}

fn nativeWorker(d: CastDevice, u: []const u8, title: []const u8, start_secs: f64) void {
    defer alloc.free(u);
    defer alloc.free(title);
    const media = alloc.create(Media) catch {
        is_casting.store(false, .release);
        return;
    };
    defer alloc.destroy(media);
    media.* = .{};
    if (resolveMedia(&d, u, title, start_secs, media)) |why| {
        const r = net.Result{ .err = why };
        applyResult(&r);
        is_casting.store(false, .release);
        state.showToast(why);
        return;
    }
    state.showToast(if (d.protocol == .dlna) "Casting to the TV…" else "Casting…");
    const r = switch (d.protocol) {
        .chromecast => net.chromecast(d.ipSlice(), d.port, .{ .load = .{
            .url = media.text(),
            .content_type = media.content_type,
            .title = title,
            .start_secs = media.start_secs,
            .hls_fmp4 = media.hls and std.mem.indexOf(u8, media.text(), "/api/stream/") != null,
        } }, load_timeout_ms),
        .dlna => net.dlnaRun(d.controlSlice(), .{ .load = .{ .url = media.text(), .title = title, .mime = media.content_type, .start_secs = media.start_secs } }),
        .airplay => unreachable,
    };
    if (!stillActive(&d)) return; // superseded or stopped meanwhile
    applyResult(&r);
    if (!r.ok) {
        is_casting.store(false, .release);
        state.showToast(r.err);
        var log_buf: [200]u8 = undefined;
        logs.pushLog("error", "cast", std.fmt.bufPrint(&log_buf, "cast to {s} failed: {s}", .{ @tagName(d.protocol), r.err }) catch "cast failed", true);
    }
}

fn airplayWorker(d: CastDevice, u: []const u8, title: []const u8) void {
    defer alloc.free(u);
    defer alloc.free(title);
    const arg_buf = alloc.alloc(u8, u.len + 16) catch {
        is_casting.store(false, .release);
        return;
    };
    defer alloc.free(arg_buf);
    const argv = pure.castArgv(&d, u, arg_buf) orelse {
        is_casting.store(false, .release);
        state.showToast(pure.msg_url_too_long);
        return;
    };

    // Keep atvremote's output so a credentials refusal can be told apart
    // from other failures (pure.playNeedsPairing).
    var child = io_g.Child.init(argv.slice(), alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch {
        is_casting.store(false, .release);
        state.showToast("AirPlay failed: install pyatv (pip install pyatv)");
        return;
    };
    mutex.lock();
    active_child = child.id;
    st_state = .playing;
    mutex.unlock();

    state.showToast("Casting via AirPlay…");
    var tail: [4096]u8 = undefined;
    const tail_len = drainTail(&child, &tail);
    const term = child.wait() catch null;

    mutex.lock();
    const still_ours = active_child != null and active_child.? == child.id.?;
    if (still_ours) {
        active_child = null;
        st_state = .idle;
    }
    mutex.unlock();

    const failed = if (term) |t| switch (t) {
        .exited => |code| code != 0,
        else => false, // signalled = stopped by us
    } else true;
    if (failed and still_ours) {
        is_casting.store(false, .release);
        if (pure.pyatvEventLoopBroken(tail[0..tail_len])) {
            state.showToast(pure.msg_pyatv_python);
        } else if (pure.playNeedsPairing(tail[0..tail_len])) {
            mutex.lock();
            pure.markNeedsPairing(devices[0..device_count], &d, true);
            mutex.unlock();
            state.showToast(pure.msg_needs_pairing);
        } else {
            state.showToast("AirPlay failed (atvremote exited with an error)");
        }
    } else if (still_ours) {
        // play_url returns when playback ends on the receiver.
        is_casting.store(false, .release);
    }
}

/// Cast whatever the active player is showing, from its current position.
/// CALLER MUST HOLD `state.players_mutex` — it reads the player list.
pub fn castActive(device_idx: usize) ?[]const u8 {
    if (state.app.active_player_idx >= state.app.players.items.len) {
        state.showToast(pure.msg_no_media);
        return pure.msg_no_media;
    }
    const p = state.app.players.items[state.app.active_player_idx];
    return castTo(
        device_idx,
        p.current_url[0..@min(p.current_url_len, p.current_url.len)],
        p.np_title[0..@min(p.np_title_len, p.np_title.len)],
        p.last_seen_pos,
    );
}

/// End the running AirPlay process, if any (SIGTERM; its worker reaps it).
fn stopRunning() void {
    mutex.lock();
    const id = active_child;
    active_child = null;
    mutex.unlock();
    if (id) |pid| io_g.terminateProcess(pid);
}

fn stopStreamSession() void {
    var sid: [@import("stream_pure.zig").SID_LEN]u8 = undefined;
    mutex.lock();
    const n = active_sid_len;
    @memcpy(sid[0..n], active_sid[0..n]);
    active_sid_len = 0;
    mutex.unlock();
    if (n > 0) _ = @import("stream_session.zig").stop(sid[0..n]);
}

/// Stop casting on the last target.
pub fn stopCast() void {
    stopRunning();
    mutex.lock();
    const target = active;
    active = null;
    st_state = .idle;
    mutex.unlock();
    is_casting.store(false, .release);

    const dev = target orelse {
        stopStreamSession();
        state.showToast("Cast stopped");
        return;
    };
    // AirPlay: ending atvremote closes the play_url session, which stops it.
    if (dev.protocol == .airplay) {
        stopStreamSession();
        state.showToast("Cast stopped");
        return;
    }
    if (workers.spawnLegacy(struct {
        fn worker(d: CastDevice) void {
            _ = runNative(&d, .stop);
            stopStreamSession();
            state.showToast("Cast stopped");
        }
    }.worker, .{dev})) |t| workers.release(t) else |_| stopStreamSession();
}

const NativeGoal = union(enum) { play, pause, stop, seek: f64, status };

fn runNative(d: *const CastDevice, goal: NativeGoal) net.Result {
    return switch (d.protocol) {
        .chromecast => net.chromecast(d.ipSlice(), d.port, switch (goal) {
            .play => .play,
            .pause => .pause,
            .stop => .stop,
            .seek => |s| .{ .seek = s },
            .status => .status,
        }, if (goal == .status) status_timeout_ms else control_timeout_ms),
        .dlna => net.dlnaRun(d.controlSlice(), switch (goal) {
            .play => .play,
            .pause => .pause,
            .stop => .stop,
            .seek => |s| .{ .seek = s },
            .status => .status,
        }),
        .airplay => .{ .err = pure.msg_control_unsupported },
    };
}

/// Run a remote-control action on the active cast. Blocks the caller for at
/// most a few seconds (bounded in cast_net). Returns null on success, else a
/// user-facing reason.
pub fn control(c: pure.Control, pos: ?f64) ?[]const u8 {
    mutex.lock();
    const target = active;
    const cur_state = st_state;
    const cur_pos = st_position;
    const dur = st_duration;
    mutex.unlock();
    const d = target orelse return pure.msg_no_session;
    if (c == .stop) {
        stopCast();
        return null;
    }
    if (d.protocol == .airplay) return pure.msg_control_unsupported;
    const goal: NativeGoal = switch (c) {
        .play => .play,
        .pause => .pause,
        .toggle => if (cur_state == .playing or cur_state == .buffering) .pause else .play,
        .seek, .forward, .back => .{ .seek = pure.seekTarget(c, pos, cur_pos, dur) orelse return "Pass pos= in seconds" },
        .stop => unreachable,
    };
    const r = runNative(&d, goal);
    if (!stillActive(&d)) return null;
    applyResult(&r);
    return if (r.ok) null else r.err;
}

/// Current cast status. Refreshes from the receiver when the cache is stale
/// and no refresh is already running; otherwise answers from the cache.
pub fn status(out: *Status) void {
    mutex.lock();
    const target = active;
    const age = io_g.monotonicMilliTimestamp() - st_updated_ms;
    mutex.unlock();
    if (target) |d| if (d.protocol != .airplay and age >= status_fresh_ms and is_casting.load(.acquire) and
        !status_busy.swap(true, .acq_rel))
    {
        defer status_busy.store(false, .release);
        const r = runNative(&d, .status);
        if (stillActive(&d)) applyResult(&r);
    };
    mutex.lock();
    defer mutex.unlock();
    statusLocked(out);
}

// ══════════════════════════════════════════════════════════
// AirPlay pairing — `atvremote --id <id> --protocol airplay pair`.
// The TV shows a PIN, atvremote reads it from stdin, and pyatv (>= 0.14)
// saves the credentials in its own settings file, which every later
// atvremote play_url run loads. See cast_pure.zig for the verified protocol.
// ══════════════════════════════════════════════════════════

/// CALLER HOLDS `mutex`.
fn setPairMsgLocked(msg: []const u8) void {
    const n = @min(msg.len, pair_msg.len);
    @memcpy(pair_msg[0..n], msg[0..n]);
    pair_msg_len = n;
}

/// Begin pairing with device `device_idx`. Returns null when started, else a
/// user-facing reason. Progress is read back through `snapshot`.
pub fn startPairing(device_idx: usize) ?[]const u8 {
    mutex.lock();
    if (device_idx >= device_count) {
        mutex.unlock();
        return pure.msg_no_device;
    }
    const dev = devices[device_idx];
    mutex.unlock();
    if (pure.pairArgv(&dev) == null) return pure.msg_pair_not_airplay;
    if (is_pairing.swap(true, .acq_rel)) return pure.msg_pair_busy;

    mutex.lock();
    pair_gen +%= 1;
    const gen = pair_gen;
    pair_phase = .starting;
    pair_target = dev;
    pair_deadline_ms = io_g.monotonicMilliTimestamp() + pair_timeout_ms;
    setPairMsgLocked("Connecting to the Apple TV…");
    mutex.unlock();

    const worker = workers.spawnLegacy(pairWorker, .{ gen, dev }) catch {
        mutex.lock();
        pair_phase = .failed;
        setPairMsgLocked("Pairing failed to start");
        mutex.unlock();
        is_pairing.store(false, .release);
        return "Pairing failed to start";
    };
    workers.release(worker);
    // Without the watchdog nothing would end a session nobody finishes.
    const dog = workers.spawnLegacy(pairWatchdog, .{gen}) catch {
        abortPair(gen, "Pairing failed to start");
        return "Pairing failed to start";
    };
    workers.release(dog);
    return null;
}

/// Send the PIN shown on the TV. Returns null when sent, else a reason.
pub fn submitPin(text: []const u8) ?[]const u8 {
    const pin = pure.validPin(text) orelse return pure.msg_pair_bad_pin;
    mutex.lock();
    if (pair_phase != .awaiting_pin or pair_stdin == null) {
        mutex.unlock();
        return pure.msg_pair_no_prompt;
    }
    const file = pair_stdin.?;
    pair_stdin = null;
    pair_phase = .verifying;
    pair_deadline_ms = io_g.monotonicMilliTimestamp() + pair_verify_timeout_ms;
    setPairMsgLocked("Checking the PIN…");
    mutex.unlock();

    const line = pin ++ [_]u8{'\n'};
    // A write error means atvremote already exited; its worker reports why.
    io_g.writeAll(file, &line) catch {};
    io_g.closeFile(file);
    return null;
}

/// Cancel the running pairing session, if any.
pub fn cancelPairing() void {
    mutex.lock();
    const gen = pair_gen;
    mutex.unlock();
    abortPair(gen, pure.msg_pair_cancelled);
}

/// End session `gen` early (cancel / timeout): mark it failed, close
/// atvremote's stdin and SIGTERM it. Its worker reaps the process.
fn abortPair(gen: u32, msg: []const u8) void {
    mutex.lock();
    if (pair_gen != gen or !pair_phase.active()) {
        mutex.unlock();
        return;
    }
    pair_phase = .failed;
    setPairMsgLocked(msg);
    const file = pair_stdin;
    pair_stdin = null;
    const pid = pair_child;
    mutex.unlock();
    if (file) |f| io_g.closeFile(f);
    if (pid) |id| io_g.terminateProcess(id);
}

fn pairWatchdog(gen: u32) void {
    while (true) {
        io_g.sleep(500 * std.time.ns_per_ms);
        mutex.lock();
        const live = pair_gen == gen and pair_phase.active();
        const expired = live and io_g.monotonicMilliTimestamp() >= pair_deadline_ms;
        mutex.unlock();
        if (!live) return;
        if (expired) {
            abortPair(gen, pure.msg_pair_timeout);
            state.showToast(pure.msg_pair_timeout);
            return;
        }
    }
}

fn pairWorker(gen: u32, d: CastDevice) void {
    defer is_pairing.store(false, .release);
    const argv = pure.pairArgv(&d) orelse return;

    var child = io_g.Child.init(argv.slice(), alloc);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe; // atvremote logs (errors included) to stdout
    child.stderr_behavior = .Pipe; // only an exit traceback; drained after stdout
    child.spawn() catch {
        mutex.lock();
        if (pair_gen == gen and pair_phase.active()) {
            pair_phase = .failed;
            setPairMsgLocked(pure.msg_pair_no_tool);
        }
        mutex.unlock();
        state.showToast(pure.msg_pair_no_tool);
        return;
    };

    mutex.lock();
    const live = pair_gen == gen and pair_phase.active();
    if (live) {
        pair_child = child.id;
        pair_stdin = child.takeStdin();
    }
    mutex.unlock();
    if (!live) { // cancelled / timed out before the process was registered
        child.closeStdin();
        if (child.id) |id| io_g.terminateProcess(id);
        _ = child.wait() catch {};
        return;
    }

    // The tail holds atvremote's "You may now use these credentials: ..."
    // line on success — wipe it before returning.
    var out: [4096]u8 = undefined;
    var out_len: usize = 0;
    var chunk: [512]u8 = undefined;
    defer std.crypto.secureZero(u8, &out);
    defer std.crypto.secureZero(u8, &chunk);
    var prompted = false;
    if (child.stdout) |*so| {
        while (true) {
            const n = io_g.read(so, &chunk) catch 0;
            if (n == 0) break;
            out_len = pure.appendTail(&out, out_len, chunk[0..n]);
            if (!prompted and pure.pairPromptSeen(out[0..out_len])) {
                prompted = true;
                mutex.lock();
                if (pair_gen == gen and pair_phase == .starting) {
                    pair_phase = .awaiting_pin;
                    setPairMsgLocked("Enter the PIN shown on the TV");
                }
                mutex.unlock();
            }
        }
    }
    if (child.stderr) |*se| while (true) {
        const n = io_g.read(se, &chunk) catch 0;
        if (n == 0) break;
        out_len = pure.appendTail(&out, out_len, chunk[0..n]);
    };
    const term = child.wait() catch null;
    const code: ?u8 = if (term) |t| switch (t) {
        .exited => |c| c,
        else => null,
    } else null;

    var leftover: ?std.Io.File = null;
    var outcome: ?pure.PairOutcome = null;
    mutex.lock();
    if (pair_gen == gen) {
        pair_child = null;
        leftover = pair_stdin;
        pair_stdin = null;
        // Still active = not already ended by cancel / timeout.
        if (pair_phase.active()) {
            const o = pure.pairOutcome(out[0..out_len], code);
            outcome = o;
            pair_phase = if (o == .paired) .paired else .failed;
            setPairMsgLocked(pure.pairOutcomeMessage(o));
            if (o == .paired) pure.markNeedsPairing(devices[0..device_count], &d, false);
        }
    }
    mutex.unlock();
    if (leftover) |f| io_g.closeFile(f);
    if (outcome) |o| state.showToast(if (o == .paired) "AirPlay paired" else pure.pairOutcomeMessage(o));
}
