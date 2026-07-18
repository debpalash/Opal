//! Resolve a WORKING python interpreter.
//!
//! Windows ships a `python3.exe` / `python.exe` "App Execution Alias" in
//! %LOCALAPPDATA%\Microsoft\WindowsApps that is NOT an interpreter: it prints
//! "Python was not found; run without arguments to install from the Microsoft
//! Store" and exits non-zero. That alias is on PATH by default, so naively
//! spawning "python3" finds the stub — every nova2 torrent search spawned it,
//! got no stdout, and silently returned zero results.
//!
//! So candidates are not merely looked up, they are PROBED: each is executed
//! (`-c "print(90210)"`) and only accepted if it actually prints. The winner is
//! cached for the process. POSIX keeps the plain "python3"/"python" order, which
//! is what it always used.

const std = @import("std");
const builtin = @import("builtin");
const io_global = @import("io_global.zig");
const alloc = @import("alloc.zig").allocator;

const is_windows = builtin.os.tag == .windows;

/// Probe order. On Windows the PATH names come first (a real install shadows the
/// alias), then the py launcher, then known-good absolute installs. The probe
/// rejects the Store stub regardless of where it appears.
const candidates: []const []const u8 = if (is_windows) &.{
    "python3",
    "python",
    "py",
    "C:/msys64/mingw64/bin/python3.exe",
    "C:/msys64/ucrt64/bin/python3.exe",
} else &.{
    "python3",
    "python",
};

/// Sentinel the probe prints; distinctive so a stub's error text can't match.
const probe_token = "90210";

var resolved_buf: [512]u8 = undefined;
var resolved_len: usize = 0;
var probed = std.atomic.Value(bool).init(false);
var probing = std.atomic.Value(bool).init(false);

/// True when `exe` runs Python and prints the probe token.
fn works(exe: []const u8) bool {
    var child = io_global.Child.init(&.{ exe, "-c", "print(" ++ probe_token ++ ")" }, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    var buf: [64]u8 = undefined;
    const n = if (child.stdout) |*so| io_global.readAll(so, &buf) catch 0 else 0;
    const term = child.wait() catch return false;
    switch (term) {
        .exited => |code| if (code != 0) return false,
        else => return false,
    }
    return std.mem.indexOf(u8, buf[0..n], probe_token) != null;
}

/// The first interpreter that actually works, or null when Python is absent.
/// Probed once per process; the result is cached.
pub fn python() ?[]const u8 {
    if (probed.load(.acquire)) {
        return if (resolved_len > 0) resolved_buf[0..resolved_len] else null;
    }
    if (probing.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
        // Another thread is probing — wait for it to publish.
        while (!probed.load(.acquire)) std.atomic.spinLoopHint();
        return if (resolved_len > 0) resolved_buf[0..resolved_len] else null;
    }
    for (candidates) |cand| {
        if (cand.len > resolved_buf.len) continue;
        if (works(cand)) {
            @memcpy(resolved_buf[0..cand.len], cand);
            resolved_len = cand.len;
            break;
        }
    }
    probed.store(true, .release);
    return if (resolved_len > 0) resolved_buf[0..resolved_len] else null;
}

/// Human-facing reason for the Settings/logs when nothing resolved.
pub fn missingHint() []const u8 {
    return if (is_windows)
        "Python not found. Install it from python.org (the Microsoft Store alias on PATH is not a real interpreter), then restart Opal."
    else
        "Python 3 not found. Install python3, then restart Opal.";
}
