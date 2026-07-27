//! Storage accounting for the Settings → Storage page.
//!
//! Why this exists: the page used to report ONE number — the content cache —
//! while a real install sat at 1.3 GB (715 MB of ML models, a 248 MB python
//! venv, a 166 MB Suwayomi jar, a 113 MB library DB). A user asking "what is
//! Opal doing with my disk?" had no way to find out and no way to reclaim it.
//!
//! It also used to walk the cache directory synchronously **inside the render
//! path**, on every frame. That is a filesystem walk per frame; this module
//! scans on a worker instead and the UI only ever reads a published snapshot.
//!
//! Threading follows the house pattern: the worker fills `entries` and publishes
//! `count` LAST, `scanning` is an atomic the UI polls, and the UI never touches
//! the filesystem.

const std = @import("std");
const io = @import("io_global.zig");
const paths = @import("paths.zig");
const logs = @import("logs.zig");
const pure = @import("storage_usage_pure.zig");

pub const Kind = pure.Kind;

pub const Entry = struct {
    label: [40]u8 = std.mem.zeroes([40]u8),
    label_len: usize = 0,
    /// Absolute path this row accounts for. Empty when the item is absent.
    path: [512]u8 = std.mem.zeroes([512]u8),
    path_len: usize = 0,
    /// One-line explanation of what is lost by removing it.
    note: [72]u8 = std.mem.zeroes([72]u8),
    note_len: usize = 0,
    bytes: u64 = 0,
    kind: Kind = .cache,

    pub fn labelStr(self: *const Entry) []const u8 {
        return self.label[0..self.label_len];
    }
    pub fn pathStr(self: *const Entry) []const u8 {
        return self.path[0..self.path_len];
    }
    pub fn noteStr(self: *const Entry) []const u8 {
        return self.note[0..self.note_len];
    }
};

pub var entries: [16]Entry = undefined;
/// Published LAST by the worker — the UI reads this to know how many rows are
/// valid, so a partially-filled array is never rendered.
pub var count: usize = 0;
pub var total_bytes: u64 = 0;
pub var scanning = std.atomic.Value(bool).init(false);
/// Set once a scan has completed, so the UI can tell "0 B" from "not scanned".
pub var scanned_once = std.atomic.Value(bool).init(false);

/// Recursive size of a directory tree, in bytes. Symlinks are NOT followed
/// (no_follow on the stat) so a link into the media library cannot make Opal
/// appear to occupy the whole disk, and a link loop cannot hang the worker.
/// `depth` is capped as a second guard.
fn dirSize(path: []const u8, depth: u8) u64 {
    if (depth > 12) return 0;
    var dir = io.openDirAbsolute(path, .{ .iterate = true }) catch return 0;
    defer dir.close(io.io());
    var total: u64 = 0;
    var it = dir.iterate();
    while (it.next(io.io()) catch null) |entry| {
        var child_buf: [700]u8 = undefined;
        const child = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ path, entry.name }) catch continue;
        switch (entry.kind) {
            .file => {
                const f = io.openFileAbsolute(child, .{}) catch continue;
                total += f.length(io.io()) catch 0;
                f.close(io.io());
            },
            .directory => total += dirSize(child, depth + 1),
            else => {}, // symlinks, sockets, fifos: not our bytes
        }
    }
    return total;
}

/// Size of a single file, or 0 when absent.
fn fileSize(path: []const u8) u64 {
    const f = io.openFileAbsolute(path, .{}) catch return 0;
    defer f.close(io.io());
    return f.length(io.io()) catch 0;
}

fn setStr(dst: []u8, len: *usize, src: []const u8) void {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    len.* = n;
}

fn add(built: *usize, label: []const u8, path: []const u8, note: []const u8, kind: Kind, bytes: u64) void {
    if (built.* >= entries.len) return;
    if (bytes == 0) return; // absent or empty — don't clutter the page
    var e = &entries[built.*];
    e.* = .{};
    setStr(&e.label, &e.label_len, label);
    setStr(&e.path, &e.path_len, path);
    setStr(&e.note, &e.note_len, note);
    e.kind = kind;
    e.bytes = bytes;
    built.* += 1;
}

/// Kick a background rescan. Idempotent — a second call while one is in flight
/// is a no-op rather than a second walk of a multi-GB tree.
pub fn scanAsync() void {
    if (scanning.load(.acquire)) return;
    if (std.Thread.spawn(.{}, worker, .{})) |t| t.detach() else |_| {}
}

fn worker() void {
    if (scanning.swap(true, .acq_rel)) return;
    defer scanning.store(false, .release);

    var cfg_buf: [512]u8 = undefined;
    const cfg = paths.configDir(&cfg_buf);
    var cache_buf: [512]u8 = undefined;
    const cache_root = paths.cacheFile(&cache_buf, "");

    var built: usize = 0;
    var p: [700]u8 = undefined;

    // ── User data: shown for accounting, never one-click removable ──
    {
        // The library DB plus its WAL/shm siblings — they are one logical store
        // and the WAL alone can be tens of MB, so counting only the .db under-
        // reports it.
        var db: u64 = 0;
        for ([_][]const u8{ "opal.db", "opal.db-wal", "opal.db-shm", "queue.db" }) |name| {
            const fp = std.fmt.bufPrint(&p, "{s}/{s}", .{ cfg, name }) catch continue;
            db += fileSize(fp);
        }
        const fp = std.fmt.bufPrint(&p, "{s}/opal.db", .{cfg}) catch "";
        add(&built, "Library database", fp, "Watch history, library, settings — not removable", .user_data, db);
    }

    // ── Large downloads: reclaimable, but expensive to refetch ──
    for ([_]struct { dir: []const u8, label: []const u8, note: []const u8 }{
        .{ .dir = "models", .label = "AI & voice models", .note = "Whisper/sherpa/Kokoro — re-downloaded on demand" },
        .{ .dir = "venv", .label = "Python environment", .note = "Rebuilt automatically when a voice feature needs it" },
        .{ .dir = "sherpa-onnx", .label = "Speech engine", .note = "Re-downloaded when voice is next used" },
        .{ .dir = "suwayomi", .label = "Suwayomi server", .note = "The manga server jar — re-downloaded on next start" },
        .{ .dir = "bin", .label = "Helper binaries", .note = "yt-dlp and friends — re-fetched on demand" },
    }) |item| {
        const fp = std.fmt.bufPrint(&p, "{s}/{s}", .{ cfg, item.dir }) catch continue;
        add(&built, item.label, fp, item.note, .download, dirSize(fp, 0));
    }

    // ── Caches: cheap to drop ──
    {
        const fp = std.fmt.bufPrint(&p, "{s}content", .{cache_root}) catch "";
        add(&built, "Content cache", fp, "Encrypted search/browse results", .cache, dirSize(fp, 0));
    }
    {
        const fp = std.fmt.bufPrint(&p, "{s}thumbs", .{cache_root}) catch "";
        add(&built, "Thumbnails", fp, "Scrub previews and queue art", .cache, dirSize(fp, 0));
    }
    {
        const fp = std.fmt.bufPrint(&p, "{s}subs", .{cache_root}) catch "";
        add(&built, "Subtitles", fp, "Downloaded .srt files", .cache, dirSize(fp, 0));
    }
    {
        // IPTV catalog lands as loose json files in the cache root, so size the
        // files by name rather than walking (the root also holds the dirs above,
        // which are already accounted for and must not be double-counted).
        var iptv: u64 = 0;
        for ([_][]const u8{ "iptv-channels.json", "iptv-logos.json", "iptv-streams.json" }) |name| {
            const fp = std.fmt.bufPrint(&p, "{s}{s}", .{ cache_root, name }) catch continue;
            iptv += fileSize(fp);
        }
        const fp = std.fmt.bufPrint(&p, "{s}iptv-channels.json", .{cache_root}) catch "";
        add(&built, "Live TV catalog", fp, "Channel list — refetched on next refresh", .cache, iptv);
    }

    var total: u64 = 0;
    for (entries[0..built]) |e| total += e.bytes;
    total_bytes = total;
    count = built; // publish LAST
    scanned_once.store(true, .release);

    var lb: [96]u8 = undefined;
    var sb: [32]u8 = undefined;
    logs.pushLog("info", "storage", std.fmt.bufPrint(&lb, "Storage scan: {s} across {d} items", .{
        pure.formatBytes(total, &sb), built,
    }) catch "Storage scanned", false);
}

/// Delete the tree backing row `idx`. Refuses user_data outright — that is
/// enforced HERE, not just by hiding a button, so a UI mistake cannot delete a
/// library. Rescans afterwards so the page reflects reality.
pub fn removeEntry(idx: usize) bool {
    if (idx >= count) return false;
    const e = &entries[idx];
    if (!pure.isRemovable(e.kind)) return false;
    const path = e.pathStr();
    if (path.len == 0) return false;
    // Caches/downloads are directories except the IPTV row, which points at one
    // of its json files; try the tree first, then the file.
    io.cwdDeleteTree(path) catch {
        io.deleteFileAbsolute(path) catch {};
    };
    // The IPTV row stands for three sibling files — drop the others too.
    if (std.mem.endsWith(u8, path, "iptv-channels.json")) {
        const base = path[0 .. path.len - "iptv-channels.json".len];
        var buf: [700]u8 = undefined;
        for ([_][]const u8{ "iptv-logos.json", "iptv-streams.json" }) |name| {
            const fp = std.fmt.bufPrint(&buf, "{s}{s}", .{ base, name }) catch continue;
            io.deleteFileAbsolute(fp) catch {};
        }
    }
    scanAsync();
    return true;
}
