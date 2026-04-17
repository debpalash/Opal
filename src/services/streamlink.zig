const std = @import("std");
const state = @import("../core/state.zig");

// ══════════════════════════════════════════════════════════
// Streamlink Integration
//
// Resolves live stream URLs (Chaturbate, Twitch, Kick, etc.)
// using a Python helper that calls streamlink as a library
// (same approach as GridPlayer), extracting direct HLS URLs.
// ══════════════════════════════════════════════════════════

/// Domains that should be resolved via streamlink
const streamlink_domains = [_][]const u8{
    "chaturbate.com",
    "twitch.tv",
    "kick.com",
    "stripchat.com",
    "bongacams.com",
    "cam4.com",
    "camsoda.com",
    "myfreecams.com",
    "flirt4free.com",
    "livejasmin.com",
    "dailymotion.com",
    "crunchyroll.com",
    "bilibili.com",
    "afreecatv.com",
    "pluto.tv",
    "picarto.tv",
    "dlive.tv",
    "rumble.com",
    "odysee.com",
};

/// Check if a URL should be handled by streamlink
pub fn isStreamlinkUrl(url: []const u8) bool {
    if (!std.mem.startsWith(u8, url, "http")) return false;
    for (streamlink_domains) |domain| {
        if (std.mem.indexOf(u8, url, domain) != null) return true;
    }
    return false;
}

/// Get the path to our streamlink_resolve.py helper
pub fn getResolverPath() []const u8 {
    const S = struct {
        var buf: [512]u8 = undefined;
    };
    // Try next to binary first
    if (@import("../core/io_global.zig").selfExeDirPath(&S.buf)) |exe_dir| {
        const resolver_suffix = "/streamlink_resolve.py";
        const dir_len = exe_dir.len;
        if (dir_len + resolver_suffix.len < S.buf.len) {
            @memcpy(S.buf[dir_len .. dir_len + resolver_suffix.len], resolver_suffix);
            const candidate = S.buf[0 .. dir_len + resolver_suffix.len];
            if (@import("../core/io_global.zig").cwdAccess(candidate, .{})) |_| {
                return candidate;
            } else |_| {}
        }
    } else |_| {}
    // Fallback: project bin/ directory (compiled via zig build)
    return "bin/streamlink_resolve.py";
}

/// Resolve a live stream URL to a direct HLS URL via our Python helper.
/// Returns the resolved URL in a static buffer, or null on failure.
pub fn resolveStreamUrl(url: []const u8) ?[]const u8 {
    const S = struct {
        var result_buf: [2048]u8 = undefined;
    };

    // Find the resolver script
    const resolver = getResolverPath();

    const argv: []const []const u8 = &.{
        "python3",
        resolver,
        url,
        "best",
    };

    var child = @import("../core/io_global.zig").Child.init(argv, @import("../core/alloc.zig").allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch {
        std.log.warn("[streamlink] Failed to spawn resolver", .{});
        return null;
    };

    const bytes_read = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, &S.result_buf) catch 0 else 0;
    _ = child.wait() catch {};

    const trimmed = std.mem.trim(u8, S.result_buf[0..bytes_read], " \t\r\n");
    if (trimmed.len == 0) return null;

    // Check for error responses
    if (std.mem.startsWith(u8, trimmed, "error:") or std.mem.eql(u8, trimmed, "offline")) {
        std.log.info("[streamlink] {s}", .{trimmed});
        return null;
    }

    // Must be a URL
    if (!std.mem.startsWith(u8, trimmed, "http")) return null;

    // Copy to start of static buffer
    if (@intFromPtr(trimmed.ptr) != @intFromPtr(&S.result_buf[0])) {
        var tmp: [2048]u8 = undefined;
        @memcpy(tmp[0..trimmed.len], trimmed);
        @memcpy(S.result_buf[0..trimmed.len], tmp[0..trimmed.len]);
    }

    std.log.info("[streamlink] Resolved: {s}", .{S.result_buf[0..trimmed.len]});
    return S.result_buf[0..trimmed.len];
}

/// Async version: resolve via streamlink in a background thread,
/// then load the result into the player.
pub fn resolveStreamUrlAsync(url: []const u8, player_idx: usize) void {
    const S = struct {
        var url_copy: [1024]u8 = undefined;
        var url_len: usize = 0;
        var p_idx: usize = 0;
        // Static buffers for mpv — must outlive the mpv_command call
        var load_buf: [2048]u8 = std.mem.zeroes([2048]u8);
        var args_load: [3][*c]const u8 = undefined;

        fn worker() void {
            std.log.info("[streamlink] Resolving: {s}", .{url_copy[0..url_len]});
            if (resolveStreamUrl(url_copy[0..url_len])) |stream_url| {
                if (state.app.players.items.len > p_idx) {
                    @memset(&load_buf, 0);
                    @memcpy(load_buf[0..stream_url.len], stream_url);
                    const mpv = @import("../core/c.zig").mpv;
                    args_load = .{ "loadfile", @ptrCast(&load_buf), null };
                    // Use synchronous mpv_command — we're on a bg thread, safe to block
                    const ret = mpv.mpv_command(state.app.players.items[p_idx].mpv_ctx, @ptrCast(&args_load));
                    std.log.info("[streamlink] mpv_command returned {d} for player {d}", .{ret, p_idx});
                }
            } else {
                std.log.warn("[streamlink] Failed to resolve stream", .{});
                // Show toast on main thread
                state.showToast("Stream offline or unavailable");
            }
        }
    };

    if (url.len >= S.url_copy.len) return;
    @memcpy(S.url_copy[0..url.len], url);
    S.url_len = url.len;
    S.p_idx = player_idx;

    _ = std.Thread.spawn(.{}, S.worker, .{}) catch {
        std.log.warn("[streamlink] Failed to spawn resolver thread", .{});
    };
}

// ══════════════════════════════════════════════════════════
// Stream Recording
// ══════════════════════════════════════════════════════════

pub var is_recording: bool = false;
pub var recording_url: [1024]u8 = std.mem.zeroes([1024]u8);
pub var recording_url_len: usize = 0;
pub var recording_child: ?@import("../core/io_global.zig").Child = null;
pub var recording_filename: [256]u8 = std.mem.zeroes([256]u8);
pub var recording_filename_len: usize = 0;

/// Start recording a stream URL using streamlink --record
pub fn startRecording(url: []const u8) void {
    if (is_recording) {
        state.showToast("Already recording!");
        return;
    }

    if (url.len == 0 or url.len >= recording_url.len) return;
    @memcpy(recording_url[0..url.len], url);
    recording_url_len = url.len;

    _ = std.Thread.spawn(.{}, recordWorker, .{}) catch {
        std.log.warn("[streamlink] Failed to spawn recording thread", .{});
    };
}

/// Stop current recording
pub fn stopRecording() void {
    if (!is_recording) return;
    if (recording_child) |*child| {
        // Send SIGTERM to gracefully stop
        const pid = child.id;
        const kill_argv: []const []const u8 = &.{ "kill", "-TERM" };
        _ = kill_argv;
        // Use posix kill
        std.posix.kill(pid, std.posix.SIG.TERM) catch {};
        _ = child.wait() catch {};
        recording_child = null;
    }
    is_recording = false;
    state.showToast("Recording saved");
    std.log.info("[streamlink] Recording stopped: {s}", .{recording_filename[0..recording_filename_len]});
}

fn recordWorker() void {
    const url = recording_url[0..recording_url_len];

    // Create recordings directory
    const home = @import("../core/io_global.zig").getenv("HOME") orelse "/tmp";
    var dir_buf: [256]u8 = undefined;
    const rec_dir = std.fmt.bufPrint(&dir_buf, "{s}/Videos/zigzag_recordings", .{home}) catch "/tmp";
    @import("../core/io_global.zig").cwdMakePath(rec_dir) catch {};

    // Generate filename with timestamp
    const ts = @import("../core/io_global.zig").timestamp();
    const fname = std.fmt.bufPrint(&recording_filename, "{s}/stream_{d}.ts", .{ rec_dir, ts }) catch {
        std.log.warn("[streamlink] Failed to create filename", .{});
        return;
    };
    recording_filename_len = fname.len;

    // Use streamlink to record: streamlink --record <file> <url> best
    const argv: []const []const u8 = &.{
        "streamlink",
        "--record",
        fname,
        url,
        "best",
    };

    var child = @import("../core/io_global.zig").Child.init(argv, @import("../core/alloc.zig").allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch {
        std.log.warn("[streamlink] Failed to spawn streamlink for recording", .{});
        return;
    };

    recording_child = child;
    is_recording = true;
    state.showToast("Recording started...");
    std.log.info("[streamlink] Recording to: {s}", .{fname});

    // Wait for it to finish (or be killed)
    _ = child.wait() catch {};
    is_recording = false;
    recording_child = null;
    std.log.info("[streamlink] Recording finished: {s}", .{fname});
}
