//! Optional external VLC playback. Never interpolate media paths/URLs into a
//! shell command or a log (signed stream URLs can contain credentials).
const std = @import("std");
const builtin = @import("builtin");
const io = @import("../core/io_global.zig");
const logs = @import("../core/logs.zig");
const state = @import("../core/state.zig");
const workers = @import("../core/workers.zig");

pub const Status = enum(u8) { idle, launching, opened, failed };
var status_value = std.atomic.Value(Status).init(.idle);
var busy = std.atomic.Value(bool).init(false);
var generation = std.atomic.Value(u64).init(0);

pub fn status() Status {
    return status_value.load(.acquire);
}

const Request = struct {
    url: [8192]u8 = undefined,
    len: usize = 0,
    generation: u64 = 0,
};
/// Only direct media addresses and ordinary file paths can be handed to VLC.
/// Opal-specific identities (opal://, magnet:, etc.) require an internal
/// resolver; passing them to VLC would look like a successful open but fail.
pub fn playable(url: []const u8) bool {
    if (url.len == 0 or url.len > 8192 or std.mem.indexOfScalar(u8, url, 0) != null) return false;
    const schemes = [_][]const u8{ "http://", "https://", "rtsp://", "rtmp://", "file://", "mms://" };
    for (schemes) |scheme| if (std.ascii.startsWithIgnoreCase(url, scheme)) return true;
    if (std.mem.indexOfScalar(u8, url, ':')) |colon| {
        // Drive-letter paths are ordinary paths, not URI schemes.
        if (!(builtin.os.tag == .windows and colon == 1 and std.ascii.isAlphabetic(url[0]))) return false;
    }
    return std.mem.indexOf(u8, url, "://") == null;
}


/// Queue playback in VLC without replacing or interrupting Opal's player.
/// Returns false if the request cannot be admitted. A later OS launch error is
/// reported by status() and in Logs, without printing the media URL.
pub fn launch(url: []const u8) bool {
    if (!playable(url)) return false;
    if (busy.swap(true, .acq_rel)) return false;
    var request: Request = .{};
    @memcpy(request.url[0..url.len], url);
    request.len = url.len;
    request.generation = generation.fetchAdd(1, .acq_rel) + 1;
    status_value.store(.launching, .release);
    workers.spawn(run, .{request}) catch {
        busy.store(false, .release);
        status_value.store(.failed, .release);
        logs.pushLog("error", "vlc", "Could not start external VLC launch worker", true);
        return false;
    };
    return true;
}

fn available(path: []const u8) bool {
    io.cwdAccess(path, .{}) catch return false;
    return true;
}

fn candidate(buf: []u8, base: []const u8, suffix: []const u8) ?[]const u8 {
    const path = std.fmt.bufPrint(buf, "{s}/{s}", .{ base, suffix }) catch return null;
    return if (available(path)) path else null;
}

fn vlcBinary(buf: []u8) []const u8 {
    if (builtin.os.tag == .windows) {
        // GUI launches rarely inherit the terminal's PATH. Check the normal
        // installers first; portable/Scoop installs still resolve via PATH.
        const roots = [_][*:0]const u8{ "ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA" };
        for (roots) |key| {
            if (std.c.getenv(key)) |raw| {
                if (candidate(buf, std.mem.span(raw), "VideoLAN/VLC/vlc.exe")) |path| return path;
            }
        }
        return "vlc.exe";
    }
    if (builtin.os.tag == .macos) {
        if (available("/Applications/VLC.app/Contents/MacOS/VLC")) return "/Applications/VLC.app/Contents/MacOS/VLC";
        if (candidate(buf, @import("../core/paths.zig").homeDir(), "Applications/VLC.app/Contents/MacOS/VLC")) |path| return path;
        return "vlc";
    }
    for ([_][]const u8{ "/usr/bin/vlc", "/usr/local/bin/vlc", "/snap/bin/vlc" }) |path| {
        if (available(path)) return path;
    }
    if (std.c.getenv("PATH")) |raw| {
        var dirs = std.mem.tokenizeScalar(u8, std.mem.span(raw), ':');
        while (dirs.next()) |dir| {
            if (candidate(buf, dir, "vlc")) |path| return path;
        }
    }
    return "";
}

fn run(request: Request) void {
    var binary_buf: [1024]u8 = undefined;
    const binary = vlcBinary(&binary_buf);
    if (binary.len == 0) {
        status_value.store(.failed, .release);
        busy.store(false, .release);
        logs.pushLog("error", "vlc", "VLC was not found. Install VLC or add it to PATH; see Settings > Playback.", true);
        state.wakeUi();
        return;
    }
    // Linux setsid -f forks the player away from our worker, so closing Opal
    // does not wait for a long-running external playback session. macOS open
    // hands the request to LaunchServices. On Windows we spawn VLC directly
    // (std.process handles Windows argv quoting) and close its OS handles below.
    const linux_detach = builtin.os.tag == .linux and available("/usr/bin/setsid");
    const argv: []const []const u8 = if (linux_detach)
        &.{ "/usr/bin/setsid", "-f", binary, "--one-instance", "--", request.url[0..request.len] }
    else if (builtin.os.tag == .macos)
        &.{ "open", "-a", "VLC", "--", request.url[0..request.len] }
    else
        &.{ binary, "--one-instance", "--", request.url[0..request.len] };
    var child = io.Child.init(argv, std.heap.c_allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        status_value.store(.failed, .release);
        busy.store(false, .release);
        logs.pushLog("error", "vlc", "VLC could not be started. Install VLC or add vlc to PATH; see Settings > Playback.", true);
        state.wakeUi();
        return;
    };
    status_value.store(.opened, .release);
    busy.store(false, .release);
    logs.pushLog("info", "vlc", "Launched external VLC (media URL and any credentials hidden); playback errors are handled in VLC", false);
    state.wakeUi();
    if (builtin.os.tag == .windows) {
        // Windows has no zombies: unlike POSIX, closing both parent handles
        // leaves VLC running independently and needs no waiting worker.
        const process = child.real.?;
        std.os.windows.CloseHandle(process.id.?);
        std.os.windows.CloseHandle(process.thread_handle);
        return;
    }
    // Reap only the short-lived macOS/open or Linux/setsid launcher. If setsid
    // is unavailable on Linux, the worker must wait for VLC to avoid a zombie.
    const result = child.wait() catch return;
    const ok = switch (result) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok and generation.load(.acquire) == request.generation) {
        status_value.store(.failed, .release);
        logs.pushLog("error", "vlc", "VLC exited with an error; check the media URL and VLC installation", true);
        state.wakeUi();
    }
}
