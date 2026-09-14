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

const ResolveJob = struct {
    url: [1024]u8 = undefined,
    url_len: usize = 0,
    resolver: [512]u8 = undefined,
    resolver_len: usize = 0,
    target_address: usize = 0,
    load_serial: u64 = 0,
    epoch: u64 = 0,
};

const ResolvePublication = struct {
    target_address: usize = 0,
    load_serial: u64 = 0,
    success: bool = false,
    url: [2048]u8 = undefined,
    url_len: usize = 0,
};

var resolve_epoch = std.atomic.Value(u64).init(0);
var resolve_publication: ResolvePublication = .{};
var resolve_publication_ready = false;
var resolve_publication_mutex: @import("../core/sync.zig").Mutex = .{};

fn publishResolution(job: ResolveJob, stream_url: ?[]const u8) void {
    const workers = @import("../core/workers.zig");
    if (workers.isQuitting() or resolve_epoch.load(.acquire) != job.epoch) return;

    resolve_publication_mutex.lock();
    defer resolve_publication_mutex.unlock();
    // Re-check under the publication lock so a newer request cannot be
    // overwritten by an old helper that finished at the same instant.
    if (resolve_epoch.load(.acquire) != job.epoch) return;
    resolve_publication = .{
        .target_address = job.target_address,
        .load_serial = job.load_serial,
        .success = stream_url != null,
    };
    if (stream_url) |url| {
        const n = @min(url.len, resolve_publication.url.len);
        @memcpy(resolve_publication.url[0..n], url[0..n]);
        resolve_publication.url_len = n;
    }
    resolve_publication_ready = true;
    state.wakeUi();
}

fn resolveWorker(job: ResolveJob) void {
    const workers = @import("../core/workers.zig");
    const python = @import("../core/pybin.zig").python() orelse {
        @import("../core/logs.zig").pushLog("error", "streamlink", @import("../core/pybin.zig").missingHint(), true);
        publishResolution(job, null);
        return;
    };
    if (resolve_epoch.load(.acquire) != job.epoch or workers.isQuitting()) return;

    const argv = [_][]const u8{
        python,
        job.resolver[0..job.resolver_len],
        job.url[0..job.url_len],
        "best",
    };
    const bounded = @import("../core/bounded_process.zig");
    var process = bounded.StreamProcess.init(&argv, .{
        .timeout_ms = 30_000,
        .terminate_grace_ms = 200,
        .max_output_bytes = 2048,
        .stderr_behavior = .Ignore,
        .cancel_epoch = .{ .epoch64 = .{ .value = &resolve_epoch, .expected = job.epoch } },
        .cancel_flag = workers.quittingSignal(),
    });
    process.start() catch {
        @import("../core/logs.zig").pushLog("error", "streamlink", "Could not start the live-stream resolver", false);
        publishResolution(job, null);
        return;
    };

    var output: [2048]u8 = undefined;
    const n = if (process.stdout()) |stdout| @import("../core/io_global.zig").readAll(stdout, &output) catch 0 else 0;
    _ = process.noteOutput(n);
    const result = process.finish();
    if (!result.ok()) {
        if (!result.cancelled and !workers.isQuitting())
            @import("../core/logs.zig").pushLog("warn", "streamlink", "Live-stream resolver timed out or failed", false);
        publishResolution(job, null);
        return;
    }

    const trimmed = std.mem.trim(u8, output[0..n], " \t\r\n");
    if (trimmed.len == 0 or
        std.mem.startsWith(u8, trimmed, "error:") or
        std.mem.eql(u8, trimmed, "offline") or
        !std.mem.startsWith(u8, trimmed, "http"))
    {
        publishResolution(job, null);
        return;
    }
    publishResolution(job, trimmed);
}

/// Resolve a live URL away from the UI thread. Every request owns its URL and
/// resolver path; a newer request cancels an older helper instead of silently
/// dropping the click or letting stale output replace the active media.
pub fn resolveStreamUrlAsync(url: []const u8, target: *@import("../player/player.zig").MediaPlayer, load_serial: u64) void {
    if (url.len == 0 or url.len > 1024 or load_serial == 0) return;
    const resolver = getResolverPath();
    if (resolver.len == 0 or resolver.len > 512) return;

    var job: ResolveJob = .{
        .url_len = url.len,
        .resolver_len = resolver.len,
        .target_address = @intFromPtr(target),
        .load_serial = load_serial,
        .epoch = resolve_epoch.fetchAdd(1, .acq_rel) + 1,
    };
    @memcpy(job.url[0..url.len], url);
    @memcpy(job.resolver[0..resolver.len], resolver);

    resolve_publication_mutex.lock();
    resolve_publication_ready = false;
    resolve_publication_mutex.unlock();
    @import("../core/workers.zig").spawn(resolveWorker, .{job}) catch {
        @import("../core/logs.zig").pushLog("error", "streamlink", "Could not start the live-stream resolver worker", false);
        publishResolution(job, null);
    };
}

/// UI-thread handoff. A result is applied only if both the heap-stable address
/// and the process-unique logical load still match a live player.
pub fn drainResolved() void {
    var publication: ResolvePublication = undefined;
    resolve_publication_mutex.lock();
    if (!resolve_publication_ready) {
        resolve_publication_mutex.unlock();
        return;
    }
    publication = resolve_publication;
    resolve_publication_ready = false;
    resolve_publication_mutex.unlock();

    const target: ?*@import("../player/player.zig").MediaPlayer = for (state.app.players.items) |player| {
        if (@intFromPtr(player) == publication.target_address and player.load_serial == publication.load_serial)
            break player;
    } else null;
    const player = target orelse return;

    if (publication.success and publication.url_len > 0) {
        // `load()` staged the public page as stable history identity. Commit
        // only the resolved HLS URL through the typed credential-clearing seam.
        player.commitPlayback(.{ .url = publication.url[0..publication.url_len] });
        std.log.info("[streamlink] resolved stream committed", .{});
        return;
    }

    player.is_loading = false;
    const fail = "Stream offline or unavailable";
    @memset(&player.loading_label, 0);
    @memcpy(player.loading_label[0..fail.len], fail);
    player.loading_label_len = fail.len;
    state.showToast(fail);
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

    if (@import("../core/workers.zig").spawnLegacy(recordWorker, .{})) |t| @import("../core/workers.zig").release(t) else |_| {
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
    const home = @import("../core/paths.zig").homeDir();
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
