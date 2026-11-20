const std = @import("std");
const state = @import("../core/state.zig");
const io_g = @import("../core/io_global.zig");
const workers = @import("../core/workers.zig");
const pure = @import("cast_pure.zig");

// ══════════════════════════════════════════════════════════
// Cast — send media to Chromecast (catt) or AirPlay (pyatv) via external tools.
// Requires: catt (pip install catt) and/or pyatv (pip install pyatv). Either
// is optional; parsing + argv live in cast_pure.zig. Newer Apple TVs refuse
// play_url until paired once: see the pairing section at the end.
// ══════════════════════════════════════════════════════════

const alloc = @import("../core/alloc.zig").allocator;

pub const CastDevice = pure.CastDevice;
pub const Protocol = pure.Protocol;

// Device list + cast target: written by the scan/cast workers, read by the
// UI thread and remote.zig's connection threads → guarded by `mutex`. Readers
// take a copy via `snapshot`.
var mutex: @import("../core/sync.zig").Mutex = .{};
var devices: [pure.max_devices]CastDevice = undefined;
var device_count: usize = 0;
/// Last device cast to (by value: a rescan may reorder the list).
var active: ?CastDevice = null;
/// Running cast process, so stop can end it (AirPlay play_url blocks until
/// playback ends; catt blocks while serving a local file).
var active_child: ?io_g.Child.Id = null;

// Polled by the UI thread AND remote.zig's connection threads → atomics.
pub var is_scanning: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
pub var is_casting: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

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

/// Read a spawned scan tool's stdout to EOF into `buf`, then reap it.
fn collect(child: *io_g.Child, buf: []u8) usize {
    const n = if (child.stdout) |*stdout| io_g.readAll(stdout, buf) catch 0 else 0;
    _ = child.wait() catch {};
    return n;
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

/// Discover devices with `catt scan` (Chromecast) and `atvscript scan`
/// (AirPlay), run concurrently. Either tool may be missing.
pub fn scanDevices() void {
    if (is_scanning.swap(true, .acq_rel)) return;

    if (workers.spawnLegacy(struct {
        fn worker() void {
            defer is_scanning.store(false, .release);

            var catt = io_g.Child.init(&pure.catt_scan_argv, alloc);
            catt.stdin_behavior = .Ignore;
            catt.stdout_behavior = .Pipe;
            catt.stderr_behavior = .Ignore;
            const have_catt = if (catt.spawn()) |_| true else |_| false;

            var atv = io_g.Child.init(&pure.atv_scan_argv, alloc);
            atv.stdin_behavior = .Ignore;
            atv.stdout_behavior = .Pipe;
            atv.stderr_behavior = .Ignore;
            const have_atv = if (atv.spawn()) |_| true else |_| false;

            if (!have_catt and !have_atv) {
                state.showToast(pure.msg_install);
                return;
            }

            // Heap: atvscript JSON carries device_info per device.
            const buf = alloc.alloc(u8, 64 * 1024) catch {
                if (have_catt) _ = catt.kill() catch {};
                if (have_atv) _ = atv.kill() catch {};
                return;
            };
            defer alloc.free(buf);

            var found: [pure.max_devices]CastDevice = undefined;
            var n: usize = 0;
            if (have_catt) {
                const len = collect(&catt, buf);
                n = pure.parseCattScan(buf[0..len], &found, n);
            }
            if (have_atv) {
                const len = collect(&atv, buf);
                n = pure.parseAtvscriptScan(alloc, buf[0..len], &found, n);
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
                state.showToast("No cast devices found");
            }
        }
    }.worker, .{})) |t| workers.release(t) else |_| is_scanning.store(false, .release);
}

/// Cast `url` to device `device_idx` of the current list. Returns null when
/// the cast was started, else a user-facing reason (also toasted).
///
/// The URL is a PARAMETER, not read from `state.app.players` here: every caller
/// already holds `state.players_mutex`. See `castActive`.
pub fn castTo(device_idx: usize, url: []const u8) ?[]const u8 {
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

    stopRunning(); // one cast at a time
    mutex.lock();
    active = dev;
    mutex.unlock();
    is_casting.store(true, .release);

    if (workers.spawnLegacy(struct {
        fn worker(d: CastDevice, u: []const u8) void {
            defer alloc.free(u);
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

            // AirPlay: keep atvremote's output so a credentials refusal can be
            // told apart from other failures (pure.playNeedsPairing).
            const capture = d.protocol == .airplay;
            var child = io_g.Child.init(argv.slice(), alloc);
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = if (capture) .Pipe else .Ignore;
            child.stderr_behavior = if (capture) .Pipe else .Ignore;
            child.spawn() catch {
                is_casting.store(false, .release);
                state.showToast(switch (d.protocol) {
                    .chromecast => "Cast failed: install catt (pip install catt)",
                    .airplay => "AirPlay failed: install pyatv (pip install pyatv)",
                });
                return;
            };
            mutex.lock();
            active_child = child.id;
            mutex.unlock();

            state.showToast(if (d.protocol == .airplay) "Casting via AirPlay…" else "Casting…");
            var tail: [4096]u8 = undefined;
            const tail_len = if (capture) drainTail(&child, &tail) else 0;
            const term = child.wait() catch null;

            mutex.lock();
            const still_ours = active_child != null and active_child.? == child.id.?;
            if (still_ours) active_child = null;
            mutex.unlock();

            const failed = if (term) |t| switch (t) {
                .exited => |code| code != 0,
                else => false, // signalled = stopped by us
            } else true;
            if (failed and still_ours) {
                is_casting.store(false, .release);
                if (d.protocol == .airplay and pure.playNeedsPairing(tail[0..tail_len])) {
                    mutex.lock();
                    pure.markNeedsPairing(devices[0..device_count], &d, true);
                    mutex.unlock();
                    state.showToast(pure.msg_needs_pairing);
                } else {
                    state.showToast(switch (d.protocol) {
                        .chromecast => "Cast failed (catt exited with an error)",
                        .airplay => "AirPlay failed (atvremote exited with an error)",
                    });
                }
            } else if (d.protocol == .airplay and still_ours) {
                // play_url returns when playback ends on the receiver.
                is_casting.store(false, .release);
            }
            // Chromecast: `catt cast <url>` returns once the device is playing;
            // keep is_casting so Stop stays available until stopCast.
        }
    }.worker, .{ dev, url_copy })) |t| {
        workers.release(t);
        return null;
    } else |_| {
        alloc.free(url_copy);
        is_casting.store(false, .release);
        return "Cast failed";
    }
}

/// Cast whatever the active player is showing. CALLER MUST HOLD
/// `state.players_mutex` — it reads the player list.
pub fn castActive(device_idx: usize) ?[]const u8 {
    if (state.app.active_player_idx >= state.app.players.items.len) {
        state.showToast(pure.msg_no_media);
        return pure.msg_no_media;
    }
    const p = state.app.players.items[state.app.active_player_idx];
    return castTo(device_idx, p.current_url[0..@min(p.current_url_len, p.current_url.len)]);
}

/// End the running cast process, if any (SIGTERM; its worker reaps it).
fn stopRunning() void {
    mutex.lock();
    const id = active_child;
    active_child = null;
    mutex.unlock();
    if (id) |pid| io_g.terminateProcess(pid);
}

/// Stop casting on the last target.
pub fn stopCast() void {
    stopRunning();
    mutex.lock();
    const target = active;
    active = null;
    mutex.unlock();
    is_casting.store(false, .release);

    const dev = target orelse {
        state.showToast("Cast stopped");
        return;
    };
    // AirPlay: ending atvremote closes the play_url session, which stops it.
    if (pure.stopArgv(&dev) == null) {
        state.showToast("Cast stopped");
        return;
    }
    if (workers.spawnLegacy(struct {
        fn worker(d: CastDevice) void {
            const argv = pure.stopArgv(&d) orelse return;
            var child = io_g.Child.init(argv.slice(), alloc);
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Ignore;
            child.spawn() catch return;
            _ = child.wait() catch {};
            state.showToast("Cast stopped");
        }
    }.worker, .{dev})) |t| workers.release(t) else |_| {}
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
    child.stderr_behavior = .Ignore;
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
