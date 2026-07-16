//! Glue between the headless HTTP download engine (download_engine.zig) and
//! the app: config plumbing, in-app logging, download history, sidecar
//! restore at startup, and the "start a download of this URL" entry point.
//!
//! The engine itself never touches state/dvui — everything app-flavored
//! happens here, on the UI thread (tick() is called from the Transfers view
//! every frame; history/toast writes are therefore race-free).

const std = @import("std");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const io_global = @import("../core/io_global.zig");
const history = @import("history.zig");
pub const engine = @import("download_engine.zig");
pub const dp = engine.dp;

var initialized = false;
var restore_spawned = false;

fn engineLog(level: []const u8, text: []const u8, is_error: bool) void {
    logs.pushLog(level, "download", text, is_error);
}

/// Called every frame from the Transfers view. Cheap: syncs config knobs into
/// the engine's atomics and drains the completed ring into download history.
pub fn tick() void {
    if (!initialized) {
        initialized = true;
        engine.log_fn = engineLog;
        restoreSidecarsAsync();
    }

    // The torrent speed-limit buttons and Settings write these; the engine
    // reads them lock-free. download_rate_limit is bytes/sec, 0 = unlimited —
    // one limit governs torrents AND HTTP downloads.
    engine.cfg_rate_bps.store(@intCast(@max(state.app.download_rate_limit, 0)), .release);
    engine.cfg_segments.store(std.math.clamp(state.app.http_dl_segments, 1, 8), .release);
    engine.cfg_max_concurrent.store(std.math.clamp(state.app.http_dl_max_concurrent, 1, 8), .release);

    // Completions → history + toast (UI thread — state arrays are safe here).
    var nb: [engine.NAME_LEN]u8 = undefined;
    while (engine.popCompleted(&nb)) |name| {
        history.addDownloadHistory(name, "");
        var tb: [engine.NAME_LEN + 24]u8 = undefined;
        const msg = std.fmt.bufPrint(&tb, "Downloaded {s}", .{name}) catch "Download complete";
        state.showToast(msg);
    }
}

/// Start an HTTP(S) download of `url` into the download directory. The file
/// name is derived from the URL path. Returns false when the URL is not
/// http(s), the table is full, or the same file is already downloading.
pub fn startUrl(url: []const u8) bool {
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://"))
        return false;
    const save_path = state.app.save_path_buf[0..state.app.save_path_len];
    if (save_path.len == 0) return false;
    var name_buf: [200]u8 = undefined;
    const name = dp.filenameFromUrl(url, &name_buf);
    var dest_buf: [engine.PATH_LEN]u8 = undefined;
    const dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}", .{ save_path, name }) catch return false;
    return engine.start(url, dest);
}

/// Scan the download dir once for `*.opal-part.json` sidecars and restore them
/// (paused ones stay paused; interrupted ones re-queue). Runs on a background
/// thread — directory io must not block the UI thread.
fn restoreSidecarsAsync() void {
    if (restore_spawned) return;
    restore_spawned = true;
    const t = std.Thread.spawn(.{}, restoreWorker, .{{}}) catch return;
    t.detach();
}

fn restoreWorker(_: void) void {
    const save_path = state.app.save_path_buf[0..state.app.save_path_len];
    if (save_path.len == 0) return;
    var dir = io_global.cwdOpenDir(save_path, .{ .iterate = true }) catch return;
    defer dir.close(io_global.io());

    const suffix = ".opal-part.json";
    var iter = dir.iterate();
    while (iter.next(io_global.io()) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, suffix)) continue;

        var full: [engine.PATH_LEN + 32]u8 = undefined;
        const spath = std.fmt.bufPrint(&full, "{s}/{s}", .{ save_path, entry.name }) catch continue;

        var jb: [8192]u8 = undefined;
        const f = io_global.openFileAbsolute(spath, .{}) catch continue;
        const n = io_global.readAll(f, &jb) catch {
            io_global.closeFile(f);
            continue;
        };
        io_global.closeFile(f);

        var meta = dp.PartMeta{};
        if (!dp.parsePartMeta(jb[0..n], &meta)) {
            // Unreadable sidecar → drop it so it doesn't rot in the folder.
            io_global.deleteFileAbsolute(spath) catch {};
            continue;
        }
        const dest = spath[0 .. spath.len - suffix.len];
        if (engine.restoreSidecar(&meta, dest)) {
            var lb: [320]u8 = undefined;
            const msg = std.fmt.bufPrint(&lb, "Restored download: {s}", .{
                entry.name[0 .. entry.name.len - suffix.len],
            }) catch "Restored download";
            logs.pushLog("info", "download", msg, false);
        }
    }
}
