const std = @import("std");
const state = @import("../core/state.zig");
const io_g = @import("../core/io_global.zig");
const workers = @import("../core/workers.zig");
const pure = @import("cast_pure.zig");

// ══════════════════════════════════════════════════════════
// Cast — send media to Chromecast (catt) or AirPlay (pyatv) via external tools.
// Requires: catt (pip install catt) and/or pyatv (pip install pyatv). Either
// is optional; parsing + argv live in cast_pure.zig.
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

pub const Snapshot = struct {
    devices: [pure.max_devices]CastDevice = undefined,
    count: usize = 0,
    /// Index of the active target in `devices`, if it is still listed.
    active_idx: ?usize = null,
};

/// Consistent copy of the device list for readers on other threads.
pub fn snapshot(out: *Snapshot) void {
    mutex.lock();
    defer mutex.unlock();
    out.count = @min(device_count, pure.max_devices);
    @memcpy(out.devices[0..out.count], devices[0..out.count]);
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

            var child = io_g.Child.init(argv.slice(), alloc);
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Ignore;
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
                state.showToast(switch (d.protocol) {
                    .chromecast => "Cast failed (catt exited with an error)",
                    .airplay => "AirPlay failed. Pair first: atvremote --id <id> --protocol airplay pair",
                });
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
