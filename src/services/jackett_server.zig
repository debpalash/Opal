//! Owned Jackett sidecar. Contained worker kills/reaps only our process tree.
const std = @import("std");
const io = @import("../core/io_global.zig");
const state = @import("../core/state.zig");
const sources = @import("../core/source_config.zig");
const workers = @import("../core/workers.zig");
const sync = @import("../core/sync.zig");
const alloc = @import("../core/alloc.zig").allocator;
const pure = @import("jackett_pure.zig");
var active = std.atomic.Value(bool).init(false);
var stopping = std.atomic.Value(bool).init(false);
var mutex: sync.Mutex = .{};
var status: [128]u8 = @splat(0);
var base: [512]u8 = @splat(0);
var key: [512]u8 = @splat(0);
var ready = false;
// UI-thread request consumed by the presentation layer; services never import it.
var connection_requested = false;
pub fn openConnection() void {
    connection_requested = true;
    state.app.router.navigate(.connect);
}
pub fn takeConnectionRequest() bool {
    const requested = connection_requested;
    connection_requested = false;
    return requested;
}
pub const Snapshot = struct { active: bool, ready: bool, status: [128]u8, base: [512]u8, key: [512]u8 };
pub fn snapshot() Snapshot {
    mutex.lock();
    defer mutex.unlock();
    return .{ .active = active.load(.acquire), .ready = ready, .status = status, .base = base, .key = key };
}
fn put(out: []u8, value: []const u8) void {
    @memset(out, 0);
    @memcpy(out[0..@min(out.len - 1, value.len)], value[0..@min(out.len - 1, value.len)]);
}
fn setStatus(value: []const u8) void {
    mutex.lock();
    put(&status, value);
    mutex.unlock();
    state.wakeUi();
}
pub fn start() void {
    if (active.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
    stopping.store(false, .release);
    setStatus("Preparing Jackett…");
    workers.spawn(worker, .{}) catch {
        active.store(false, .release);
        setStatus("Could not start Jackett.");
    };
}
pub fn stop() void {
    stopping.store(true, .release);
}
fn accept(line: []const u8) void {
    const Event = struct { event: []const u8, message: []const u8 = "", base: []const u8 = "", apikey: []const u8 = "" };
    var parsed = std.json.parseFromSlice(Event, alloc, line, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const event = parsed.value;
    if (!std.mem.eql(u8, event.event, "ready")) {
        setStatus(event.message);
        return;
    }
    if (stopping.load(.acquire) or workers.isQuitting()) return;
    var url_buf: [2400]u8 = undefined;
    if (!std.mem.startsWith(u8, event.base, "http://127.0.0.1:") or pure.catalogUrl(event.base, event.apikey, &url_buf) == null) return;
    var selection_buf: [512]u8 = undefined;
    var managed_buf: [16]u8 = undefined;
    const was_managed = std.mem.eql(u8, sources.copyValue("jackett", "managed", &managed_buf) orelse "", "true");
    const selection = if (was_managed) sources.copyValue("jackett", "indexers", &selection_buf) orelse "*" else "*";
    const json = std.json.Stringify.valueAlloc(alloc, .{ .base = event.base, .apikey = event.apikey, .indexers = selection, .managed = "true", .thread_count = "8" }, .{}) catch return;
    defer alloc.free(json);
    if (!sources.install("jackett", json)) {
        setStatus("Jackett started, but saving its connection failed.");
        return;
    }
    mutex.lock();
    put(&base, event.base);
    put(&key, event.apikey);
    ready = true;
    put(&status, "Jackett is running inside Opal.");
    mutex.unlock();
    state.wakeUi();
}
fn worker() void {
    defer {
        mutex.lock();
        ready = false;
        mutex.unlock();
        active.store(false, .release);
        if (stopping.load(.acquire)) setStatus("Jackett stopped. Tracker settings are kept.");
        state.wakeUi();
    }
    const python = @import("../core/pybin.zig").python() orelse {
        setStatus("Opal's Python runtime is unavailable.");
        return;
    };
    var cfg: [512]u8 = undefined;
    var root_buf: [800]u8 = undefined;
    const root = std.fmt.bufPrint(&root_buf, "{s}/jackett-managed", .{@import("../core/paths.zig").configDir(&cfg)}) catch return;
    var process = @import("../core/bounded_process.zig").StreamProcess.init(&.{ python, "-u", "-c", @embedFile("jackett_manager.py"), "--root", root }, .{
        .timeout_ms = std.math.maxInt(i64),
        .terminate_grace_ms = 500,
        .cancel_flag = workers.quittingSignal(),
        .abort_flag = &stopping,
        .max_output_bytes = 64 * 1024,
    });
    process.start() catch {
        setStatus("Could not launch managed Jackett.");
        return;
    };
    var line: [8192]u8 = undefined;
    var used: usize = 0;
    if (process.stdout()) |stdout| {
        var chunk: [1024]u8 = undefined;
        while (true) {
            const n = io.read(stdout, &chunk) catch break;
            if (n == 0 or !process.noteOutput(n)) break;
            for (chunk[0..n]) |c| {
                if (c == '\n') {
                    accept(line[0..used]);
                    used = 0;
                } else if (used < line.len) {
                    line[used] = c;
                    used += 1;
                } else {
                    process.requestStop();
                    break;
                }
            }
        }
    }
    const outcome = process.finish();
    if (!outcome.ok() and !stopping.load(.acquire) and !workers.isQuitting()) setStatus("Jackett stopped unexpectedly. Retry to restart it.");
}

var auto_started = false;
/// Called after startup source configuration is loaded, on the UI thread.
pub fn tick() void {
    if (auto_started or @import("builtin").is_test) return;
    auto_started = true;
    var flag: [16]u8 = undefined;
    if (sources.copyValue("jackett", "managed", &flag)) |value| if (std.mem.eql(u8, value, "true")) start();
}
