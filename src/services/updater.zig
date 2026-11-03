//! Background release checks; downloading and restarting require separate user actions.
const std = @import("std");
const builtin = @import("builtin");
const io = @import("../core/io_global.zig");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const workers = @import("../core/workers.zig");
const alloc = @import("../core/alloc.zig").allocator;
const fetch = @import("reliable_fetch.zig");
pub const pure = @import("updater_pure.zig");
pub const APP_VERSION: []const u8 = @import("build_options").app_version;
const native = builtin.os.tag == .macos and !@import("build_options").headless;
const api = struct {
    extern fn opal_update_target(out: [*]u8, cap: usize) usize;
    extern fn opal_update_prepare(archive: [*:0]const u8, target: [*:0]const u8, version: [*:0]const u8, out: [*]u8, cap: usize) usize;
    extern fn opal_update_restart(target: [*:0]const u8, stage: [*:0]const u8, version: [*:0]const u8, script: [*:0]const u8) c_int;
    extern fn opal_update_ack() void;
    extern fn opal_update_discard(stage: [*:0]const u8) void;
};
pub const Snapshot = struct {
    selection: pure.Selection = .{},
    has_update: bool = false,
    is_checking: bool = false,
    is_downloading: bool = false,
    is_ready: bool = false,
    show_prompt: bool = false,
    downloaded: u64 = 0,
    last_error_buf: [160]u8 = @splat(0),
    last_error_len: usize = 0,
    last_check_ts: i64 = 0,
    target: [2048:0]u8 = @splat(0),
    prepared: [2048:0]u8 = @splat(0),
    download: [1024:0]u8 = @splat(0),
    pub fn latestTag(self: *const Snapshot) []const u8 {
        return self.selection.version.text();
    }
    pub fn lastError(self: *const Snapshot) []const u8 {
        return self.last_error_buf[0..self.last_error_len];
    }
};
var mutex: @import("../core/sync.zig").Mutex = .{};
var current: Snapshot = .{};
var notice: pure.Notice = .{};
var restart_requested = std.atomic.Value(bool).init(false);
var first_tick: i64 = 0;
var last_poll: i64 = 0;
var healthy_frames: usize = 0;
const release_opts: fetch.Opts = .{ .https_only = true, .impersonate = false, .timeout_secs = 20, .use_dpi_proxy = false };
pub fn snapshot() Snapshot {
    mutex.lock();
    defer mutex.unlock();
    return current;
}
pub fn dismiss() void {
    mutex.lock();
    defer mutex.unlock();
    notice.dismiss();
    current.show_prompt = false;
}
pub fn show() void {
    mutex.lock();
    defer mutex.unlock();
    current.show_prompt = current.has_update;
    state.wakeUi();
}
fn fail(message: []const u8, notify: bool) void {
    logs.pushLog("error", "updater", message, false);
    mutex.lock();
    defer mutex.unlock();
    current.last_error_len = @min(message.len, current.last_error_buf.len);
    @memcpy(current.last_error_buf[0..current.last_error_len], message[0..current.last_error_len]);
    if (notify) current.show_prompt = true;
}
pub fn checkAsync() void {
    check(true);
}
fn check(manual: bool) void {
    mutex.lock();
    if (current.is_checking or current.is_downloading or current.is_ready or workers.isQuitting()) {
        if (manual and current.has_update) current.show_prompt = true;
        mutex.unlock();
        return;
    }
    current.is_checking = true;
    current.last_check_ts = io.timestamp();
    current.last_error_len = 0;
    mutex.unlock();
    workers.spawn(checkWorker, .{manual}) catch {
        mutex.lock();
        current.is_checking = false;
        mutex.unlock();
    };
}
pub fn tick() void {
    if (builtin.is_test or state.app.is_headless) return;
    if (comptime native) if (healthy_frames < 2 and io.getenv("OPAL_UPDATE_ACK") != null and state.app.config_loaded.load(.acquire)) {
        if (healthy_frames == 0) state.wakeUi() else api.opal_update_ack();
        healthy_frames += 1;
    };
    if (!state.app.config_loaded.load(.acquire)) return;
    const now = io.monotonicMilliTimestamp();
    if (first_tick == 0) first_tick = now;
    const value = snapshot();
    if (value.is_downloading and now - last_poll >= 250) {
        last_poll = now;
        var path: [1100]u8 = undefined;
        const part = std.fmt.bufPrint(&path, "{s}.part", .{std.mem.sliceTo(&value.download, 0)}) catch return;
        const info = io.cwdStatFile(part) catch return;
        mutex.lock();
        current.downloaded = info.size;
        mutex.unlock();
    }
    if (state.app.auto_check_updates and now - first_tick >= 15_000 and (value.last_check_ts == 0 or io.timestamp() - value.last_check_ts >= 86400)) check(false);
}
fn checkWorker(manual: bool) void {
    defer {
        mutex.lock();
        current.is_checking = false;
        current.last_check_ts = io.timestamp();
        mutex.unlock();
        state.wakeUi();
    }
    const body = alloc.alloc(u8, 256 * 1024) catch {
        fail("Could not check for updates", manual);
        return;
    };
    defer alloc.free(body);
    var options = release_opts;
    options.headers = &.{ .{ .name = "Accept", .value = "application/vnd.github+json" }, .{ .name = "User-Agent", .value = "Opal-Updater" } };
    const payload = fetch.fetch("https://api.github.com/repos/debpalash/Opal/releases/latest", body, options) orelse {
        fail("Could not check for updates. Try again when connected.", manual);
        return;
    };
    const metadata = std.json.parseFromSlice(pure.Release, alloc, payload, .{ .ignore_unknown_fields = true }) catch {
        fail("Could not read the update information. Try again later.", manual);
        return;
    };
    defer metadata.deinit();
    if (pure.version(metadata.value.tag_name) == null) {
        fail("Could not read the update version. Try again later.", manual);
        return;
    }
    var target: [2048:0]u8 = @splat(0);
    var can_install = false;
    if (comptime native) can_install = api.opal_update_target(&target, target.len) > 0;
    const platform: pure.Platform = if (builtin.os.tag == .macos) (if (builtin.cpu.arch == .aarch64) .mac_arm64 else .mac_intel) else if (builtin.os.tag == .windows) .windows else .linux;
    var selected: pure.Selection = undefined;
    const available = pure.select(alloc, payload, APP_VERSION, platform, can_install, &selected);
    mutex.lock();
    defer mutex.unlock();
    current.has_update = available;
    if (available) {
        current.selection = selected;
        current.target = target;
        notice.offer(selected.version.text(), manual);
        current.show_prompt = notice.visible;
    }
}
pub fn downloadAndOpenAsync() void {
    mutex.lock();
    if (current.is_downloading or current.is_checking or !current.has_update or workers.isQuitting()) {
        mutex.unlock();
        return;
    }
    if (current.is_ready) {
        current.show_prompt = true;
        mutex.unlock();
        return;
    }
    const release = current;
    current.last_error_len = 0;
    current.show_prompt = true;
    if (release.selection.mode == .website) {
        mutex.unlock();
        openRelease();
        return;
    }
    current.is_downloading = true;
    current.downloaded = 0;
    mutex.unlock();
    workers.spawn(downloadWorker, .{release}) catch {
        fail("Could not start the update download", true);
        mutex.lock();
        current.is_downloading = false;
        mutex.unlock();
    };
}
fn downloadWorker(release: Snapshot) void {
    defer {
        mutex.lock();
        current.is_downloading = false;
        mutex.unlock();
        state.wakeUi();
    }
    var nonce: [16]u8 = undefined;
    if (!io.randomSecure(&nonce)) {
        fail("Could not prepare the update download", true);
        return;
    }
    const token = std.fmt.bytesToHex(nonce, .lower);
    var tmp: [512]u8 = undefined;
    var path: [1024:0]u8 = @splat(0);
    const file = std.fmt.bufPrint(&path, "{s}/Opal-update-{s}-{s}", .{ io.tmpDir(&tmp), token, release.selection.asset.text() }) catch {
        fail("Update download path is too long", true);
        return;
    };
    mutex.lock();
    current.download = path;
    mutex.unlock();
    var keep = false;
    defer if (!keep) io.deleteFileAbsolute(file) catch {};
    var options = release_opts;
    options.timeout_secs = 600;
    options.max_filesize = 512 * 1024 * 1024;
    if (!fetch.download(release.selection.url.text(), file, options).ok()) {
        fail("Update download failed. Your app has not changed.", true);
        return;
    }
    if (!verifyReleaseChecksum(file, release)) {
        fail("Update verification failed. Your app has not changed.", true);
        return;
    }
    if (workers.isQuitting()) return;
    var prepared: [2048:0]u8 = @splat(0);
    if (release.selection.mode == .bundle) {
        if (comptime native) {
            var version: [65:0]u8 = @splat(0);
            @memcpy(version[0..release.latestTag().len], release.latestTag());
            if (api.opal_update_prepare(&path, &release.target, &version, &prepared, prepared.len) == 0) {
                fail("Could not prepare the update. Your app has not changed.", true);
                return;
            }
        } else return;
    } else {
        @memcpy(prepared[0..file.len], file);
        keep = true;
    }
    mutex.lock();
    current.prepared = prepared;
    current.is_ready = true;
    current.show_prompt = true;
    current.downloaded = release.selection.size;
    mutex.unlock();
}
fn verifyReleaseChecksum(path: []const u8, release: Snapshot) bool {
    var sums: [32768]u8 = undefined;
    const text = fetch.fetch(release.selection.sums.text(), &sums, release_opts) orelse return false;
    const expected = @import("ytdlp_update_pure.zig").expectedChecksum(text, release.selection.asset.text()) orelse return false;
    const file = io.openFileAbsolute(path, .{}) catch return false;
    defer io.closeFile(file);
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [32768]u8 = undefined;
    while (true) {
        if (workers.isQuitting()) return false;
        const n = io.read(file, &buffer) catch return false;
        if (n == 0) break;
        sha.update(buffer[0..n]);
    }
    var digest: [32]u8 = undefined;
    sha.final(&digest);
    return @import("ytdlp_update_pure.zig").checksumMatches(expected, digest);
}
pub fn restartAndInstall() void {
    const value = snapshot();
    if (!value.is_ready or workers.isQuitting() or restartRequested()) return;
    if (value.selection.mode == .bundle) {
        if (comptime native) {
            var version: [65:0]u8 = @splat(0);
            @memcpy(version[0..value.latestTag().len], value.latestTag());
            if (api.opal_update_restart(&value.target, &value.prepared, &version, @embedFile("updater_install_macos.sh")) == 0) {
                fail("Could not start installation. Your app has not changed.", true);
                return;
            }
            restart_requested.store(true, .release);
            state.wakeUi();
        }
    } else {
        const args: []const []const u8 = if (builtin.os.tag == .windows) &.{ "msiexec", "/i", std.mem.sliceTo(&value.prepared, 0) } else &.{ "open", std.mem.sliceTo(&value.prepared, 0) };
        var child = io.Child.init(args, alloc);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch {
            fail("Could not open the update installer", true);
            return;
        };
        dismiss();
    }
}
pub fn restartRequested() bool {
    return restart_requested.load(.acquire);
}
pub fn openRelease() void {
    const value = snapshot();
    var url: [256]u8 = undefined;
    const link = std.fmt.bufPrint(&url, "https://github.com/debpalash/Opal/releases/tag/v{s}", .{value.latestTag()}) catch return;
    const c = @import("../core/c.zig");
    var z: [257:0]u8 = @splat(0);
    @memcpy(z[0..link.len], link);
    _ = c.sdl.SDL_OpenURL(&z);
}
pub fn shutdown() void {
    if (restartRequested()) return;
    const value = snapshot();
    if (value.is_ready and value.selection.mode == .bundle) {
        if (comptime native) api.opal_update_discard(&value.prepared);
    }
    if (value.is_ready and value.selection.mode == .installer) io.deleteFileAbsolute(std.mem.sliceTo(&value.prepared, 0)) catch {};
}
pub fn fixtureForTest(value: Snapshot) void {
    if (!builtin.is_test) @compileError("Update fixture is test-only");
    mutex.lock();
    current = value;
    mutex.unlock();
}
