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

    const logs = @import("../core/logs.zig");
    child.spawn() catch |err| {
        if (err == error.FileNotFound) {
            logs.pushLog("ERROR", "streamlink", "python3 not installed (or not in PATH) — cannot resolve live stream", true);
        } else {
            logs.pushLog("ERROR", "streamlink", "failed to spawn resolver helper", true);
        }
        std.log.warn("[streamlink] Failed to spawn resolver: {s}", .{@errorName(err)});
        return null;
    };

    const bytes_read = if (child.stdout) |*stdout| @import("../core/io_global.zig").readAll(stdout, &S.result_buf) catch 0 else 0;
    const term = child.wait() catch |err| blk: {
        std.log.warn("[streamlink] resolver wait() failed: {s}", .{@errorName(err)});
        break :blk @import("../core/io_global.zig").Child.Term{ .unknown = 0 };
    };
    switch (term) {
        .exited => |code| if (code != 0) {
            logs.pushLog("WARN", "streamlink", "resolver exited with a non-zero status", false);
        },
        else => logs.pushLog("WARN", "streamlink", "resolver terminated abnormally", false),
    }

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
    const playermod = @import("../player/player.zig");
    const S = struct {
        var busy: bool = false;
        var url_copy: [1024]u8 = undefined;
        var url_len: usize = 0;
        // Snapshot the STABLE *MediaPlayer pointer (heap-stable across players
        // ArrayList reallocs / single-player collapse reordering) instead of a
        // raw index, which the frame-top collapse can reorder or invalidate.
        var target: ?*playermod.MediaPlayer = null;

        // Static buffers for mpv — must outlive the mpv_command call
        var load_buf: [2048]u8 = std.mem.zeroes([2048]u8);
        var args_load: [3][*c]const u8 = undefined;

        fn worker() void {
            defer @This().busy = false;
            const p = @This().target orelse return;
            std.log.info("[streamlink] Resolving: {s}", .{url_copy[0..url_len]});
            if (resolveStreamUrl(url_copy[0..url_len])) |stream_url| {
                @memset(&load_buf, 0);
                @memcpy(load_buf[0..stream_url.len], stream_url);
                const mpv = @import("../core/c.zig").mpv;
                args_load = .{ "loadfile", @ptrCast(&load_buf), null };
                // Use synchronous mpv_command — we're on a bg thread, safe to block
                const ret = mpv.mpv_command(p.mpv_ctx, @ptrCast(&args_load));
                std.log.info("[streamlink] mpv_command returned {d}", .{ret});
            } else {
                std.log.warn("[streamlink] Failed to resolve stream", .{});
                // Clear the stuck "Resolving live stream..." state — mpv never gets
                // a loadfile on failure, so is_loading would otherwise never clear.
                p.is_loading = false;
                const fail = "Stream offline or unavailable";
                @memset(&p.loading_label, 0);
                @memcpy(p.loading_label[0..fail.len], fail);
                p.loading_label_len = fail.len;
                state.showToast("Stream offline or unavailable");
            }
        }
    };

    if (S.busy) return;
    if (url.len >= S.url_copy.len) return;
    // Resolve the stable player pointer up front, on the caller (UI) thread,
    // while the index is still valid. Guard the lookup.
    if (player_idx >= state.app.players.items.len) return;
    S.target = state.app.players.items[player_idx];
    S.busy = true;
    @memcpy(S.url_copy[0..url.len], url);
    S.url_len = url.len;

    if (std.Thread.spawn(.{}, S.worker, .{})) |t| t.detach() else |_| {
        S.busy = false;
        std.log.warn("[streamlink] Failed to spawn resolver thread", .{});
    }
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
/// Guards is_recording + recording_child against the UI/bg thread race.
/// stopRecording (UI thread) only kills via pid + signal; recordWorker (bg)
/// is the SOLE caller of child.wait().
var recording_mutex: @import("../core/sync.zig").Mutex = .{};

/// Start recording a stream URL using streamlink --record
pub fn startRecording(url: []const u8) void {
    recording_mutex.lock();
    const already = is_recording;
    recording_mutex.unlock();
    if (already) {
        state.showToast("Already recording!");
        return;
    }

    if (url.len == 0 or url.len >= recording_url.len) return;
    @memcpy(recording_url[0..url.len], url);
    recording_url_len = url.len;

    if (std.Thread.spawn(.{}, recordWorker, .{})) |t| t.detach() else |_| {
        std.log.warn("[streamlink] Failed to spawn recording thread", .{});
    }
}

/// Stop current recording.
/// UI thread: only signals the child via pid. recordWorker (bg) is the SOLE
/// caller of child.wait() and is responsible for clearing recording_child /
/// is_recording once the process exits.
pub fn stopRecording() void {
    recording_mutex.lock();
    if (!is_recording) {
        recording_mutex.unlock();
        return;
    }
    // Snapshot the child id under the lock, then release before signalling so
    // we never block the UI thread holding the mutex.
    const id_helper = @import("../core/io_global.zig");
    const pid: ?id_helper.Child.Id = if (recording_child) |*child| child.id else null;
    recording_mutex.unlock();

    if (pid) |p| {
        // SIGTERM (TerminateProcess on Windows) to stop; recordWorker's wait()
        // will observe the exit and tear down the shared state.
        id_helper.terminateProcess(p);
    }
    state.showToast("Recording saved");
    std.log.info("[streamlink] Recording stop requested: {s}", .{recording_filename[0..recording_filename_len]});
}

fn recordWorker() void {
    const url = recording_url[0..recording_url_len];

    // Create recordings directory
    const home = @import("../core/io_global.zig").getenv("HOME") orelse "/tmp";
    var dir_buf: [256]u8 = undefined;
    const rec_dir = std.fmt.bufPrint(&dir_buf, "{s}/Videos/opal_recordings", .{home}) catch "/tmp";
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

    child.spawn() catch |err| {
        const logs = @import("../core/logs.zig");
        if (err == error.FileNotFound) {
            logs.pushLog("ERROR", "streamlink", "streamlink not installed (or not in PATH) — cannot record", true);
        } else {
            logs.pushLog("ERROR", "streamlink", "failed to spawn streamlink for recording", true);
        }
        std.log.warn("[streamlink] Failed to spawn streamlink for recording: {s}", .{@errorName(err)});
        return;
    };

    // Publish recording_child BEFORE is_recording=true so a concurrent
    // stopRecording() never sees is_recording without a valid child to signal.
    recording_mutex.lock();
    recording_child = child;
    is_recording = true;
    recording_mutex.unlock();

    state.showToast("Recording started...");
    std.log.info("[streamlink] Recording to: {s}", .{fname});

    // recordWorker is the SOLE caller of child.wait(). stopRecording only
    // signals the child; we observe the exit here and tear down shared state.
    _ = child.wait() catch {};

    recording_mutex.lock();
    is_recording = false;
    recording_child = null;
    recording_mutex.unlock();
    std.log.info("[streamlink] Recording finished: {s}", .{fname});
}
