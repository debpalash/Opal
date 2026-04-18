//! Dependency bootstrap — first-run auto-install of optional binaries.
//! Philosophy: never silently download binaries (licensing + trust).
//! But the whisper model is a public ML weight, clearly-licensed, safe
//! to fetch. Binaries themselves must be installed via brew / system
//! package manager; we only detect + surface helpful install hints.

const std = @import("std");
const logs = @import("logs.zig");
const io_global = @import("io_global.zig");

pub const Status = struct {
    apfel: bool = false,
    ffmpeg: bool = false,
    whisper: bool = false,
    whisper_model: bool = false,
};

pub fn check() Status {
    var s: Status = .{};

    s.apfel = have("/opt/homebrew/bin/apfel") or have("/usr/local/bin/apfel");
    s.ffmpeg = have("/opt/homebrew/bin/ffmpeg") or have("/usr/local/bin/ffmpeg") or have("/usr/bin/ffmpeg");
    s.whisper = have("/opt/homebrew/bin/whisper-cpp") or
        have("/opt/homebrew/bin/whisper-cli") or
        have("bin/whisper.cpp/build/bin/whisper-cli");

    var home_buf: [512]u8 = undefined;
    const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "/tmp";
    if (std.fmt.bufPrintZ(&home_buf, "{s}/.config/opal/models/ggml-tiny.en.bin", .{home})) |model_path| {
        s.whisper_model = have(model_path);
    } else |_| {}

    return s;
}

fn have(path: []const u8) bool {
    io_global.cwdAccess(path, .{}) catch return false;
    return true;
}

/// One-liner brew install command for missing deps. Copy-paste ready.
pub fn installCmd(buf: []u8, s: Status) []const u8 {
    var parts: [4][]const u8 = undefined;
    var n: usize = 0;
    if (!s.apfel) { parts[n] = "apfel"; n += 1; }
    if (!s.ffmpeg) { parts[n] = "ffmpeg"; n += 1; }
    if (!s.whisper) { parts[n] = "whisper-cpp"; n += 1; }
    if (n == 0) return "";

    var off: usize = 0;
    const prefix = "brew install ";
    @memcpy(buf[off..off + prefix.len], prefix);
    off += prefix.len;
    for (parts[0..n], 0..) |p, i| {
        if (i > 0) { buf[off] = ' '; off += 1; }
        @memcpy(buf[off..off + p.len], p);
        off += p.len;
    }
    return buf[0..off];
}

/// Download whisper tiny model to ~/.config/opal/models/ on a background
/// thread. Idempotent — no-op if present.
pub fn fetchWhisperModelAsync() void {
    const S = struct {
        fn worker() void {
            var home_buf: [512]u8 = undefined;
            const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else return;
            const dir = std.fmt.bufPrintZ(&home_buf, "{s}/.config/opal/models", .{home}) catch return;

            // mkpath + check if already present
            io_global.makeDirAbsolute(dir) catch {};
            var path_buf: [512]u8 = undefined;
            const model_path = std.fmt.bufPrintZ(&path_buf, "{s}/ggml-tiny.en.bin", .{dir}) catch return;
            io_global.cwdAccess(model_path, .{}) catch {
                // Missing — fetch
                logs.pushLog("info", "deps", "Fetching whisper tiny model (~39MB)…", true);
                var curl = io_global.Child.init(&.{
                    "curl", "-L", "--fail", "--silent", "--show-error",
                    "-o", model_path,
                    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin",
                }, @import("alloc.zig").allocator);
                curl.stdout_behavior = .Ignore;
                curl.stderr_behavior = .Ignore;
                curl.spawn() catch {
                    logs.pushLog("error", "deps", "curl not found — cannot fetch whisper model", false);
                    return;
                };
                _ = curl.wait() catch {};
                logs.pushLog("info", "deps", "Whisper model ready at ~/.config/opal/models/", true);
                return;
            };
        }
    };
    _ = std.Thread.spawn(.{}, S.worker, .{}) catch {};
}
