//! Torrent guard — runs on the stall watchdog thread (torrent_stall.tick, 2 Hz)
//! so it sees EVERY torrent, including plain Downloads that never reach the
//! player's malware gate.
//!
//!  1. Once a torrent's file list is known, any executable/installer/script or
//!     bidi-spoofed name stops the whole torrent (all priorities 0, paused) and
//!     records its info-hash in a persistent blocklist.
//!  2. `isBlockedMagnet` refuses a blocklisted info-hash on every later add,
//!     whichever source offers it.
//!  3. Finished files get the OS "downloaded from the internet" mark: macOS
//!     `com.apple.quarantine`, Windows `:Zone.Identifier` (as qBittorrent and
//!     Transmission do), so Gatekeeper/SmartScreen still check anything the
//!     user later opens outside Opal.
//!
//! Policy lives in core/download_safety_pure.zig.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../core/c.zig");
const state = @import("../core/state.zig");
const io_g = @import("../core/io_global.zig");
const logs = @import("../core/logs.zig");
const paths = @import("../core/paths.zig");
const alloc = @import("../core/alloc.zig").allocator;
const pure = @import("../core/download_safety_pure.zig");

var lock: @import("../core/sync.zig").Mutex = .{};
var blocklist: pure.Blocklist = .{};
var loaded = false;

/// Ids already inspected / fully marked. Torrent ids are monotonic and never
/// reused; a ring is enough because a session holds a handful of torrents.
var inspected: [256]i32 = @splat(-1);
var inspected_next: usize = 0;
var marked: [256]i32 = @splat(-1);
var marked_next: usize = 0;
var last_mark_ms: i64 = 0;
const MARK_INTERVAL_MS = 15_000;

fn seen(ring: []const i32, id: i32) bool {
    for (ring) |v| if (v == id) return true;
    return false;
}

fn remember(ring: []i32, next: *usize, id: i32) void {
    ring[next.*] = id;
    next.* = (next.* + 1) % ring.len;
}

fn blocklistPath(buf: []u8) ?[]const u8 {
    var dir_buf: [1024]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/blocked_torrents.txt", .{paths.configDir(&dir_buf)}) catch null;
}

/// Caller holds `lock`.
fn ensureLoadedLocked() void {
    if (loaded) return;
    loaded = true;
    var path_buf: [1100]u8 = undefined;
    const path = blocklistPath(&path_buf) orelse return;
    const text = io_g.cwdReadFileAlloc(path, alloc, 64 * 1024) catch return;
    defer alloc.free(text);
    blocklist.parse(text);
}

/// Caller holds `lock`.
fn saveLocked() void {
    var path_buf: [1100]u8 = undefined;
    const path = blocklistPath(&path_buf) orelse return;
    const out = alloc.alloc(u8, 128 + pure.Blocklist.capacity * 41) catch return;
    defer alloc.free(out);
    const text = blocklist.format(out) orelse return;
    io_g.cwdWriteFile(.{ .sub_path = path, .data = text }) catch {};
}

/// True when the magnet's info-hash was blocked as malware earlier.
pub fn isBlockedMagnet(magnet: []const u8) bool {
    var hash_buf: [40]u8 = undefined;
    const hash = @import("virustotal_pure.zig").infoHashFromMagnet(magnet, &hash_buf) orelse return false;
    lock.lock();
    defer lock.unlock();
    ensureLoadedLocked();
    return blocklist.contains(hash);
}

/// Watchdog-thread hook: inspect new file lists, mark finished files.
pub fn tick(ses: c.mpv.TorrentSession, queueToast: *const fn ([]const u8) void) void {
    const total = c.mpv.torrent_count(ses);
    var i: i32 = 0;
    while (i < total) : (i += 1) {
        if (c.mpv.torrent_is_alive(ses, i) == 0 or seen(&inspected, i)) continue;
        const files = c.mpv.torrent_get_file_count(ses, i);
        if (files <= 0) continue; // metadata not here yet
        remember(&inspected, &inspected_next, i);
        if (inspect(ses, i, files)) queueToast("Blocked a torrent that looks like malware. Nothing was opened.");
    }

    const now = io_g.milliTimestamp();
    if (now - last_mark_ms < MARK_INTERVAL_MS) return;
    last_mark_ms = now;
    i = 0;
    while (i < total) : (i += 1) {
        if (c.mpv.torrent_is_alive(ses, i) == 0 or seen(&marked, i)) continue;
        if (c.mpv.torrent_is_memory_only(ses, i) != 0) continue;
        const files = c.mpv.torrent_get_file_count(ses, i);
        if (files <= 0) continue;
        if (markFinished(ses, i, files)) remember(&marked, &marked_next, i);
    }
}

/// Stop and blocklist the torrent when its file list holds a payload.
fn inspect(ses: c.mpv.TorrentSession, id: i32, files: c_int) bool {
    var f: c_int = 0;
    var offender: [256]u8 = undefined;
    var name_buf: [256]u8 = undefined;
    var facts: pure.FileFacts = .{};
    offender[0] = 0;
    while (f < files) : (f += 1) {
        name_buf[0] = 0;
        c.mpv.torrent_get_file_name(ses, id, f, &name_buf, name_buf.len);
        const name = std.mem.sliceTo(&name_buf, 0);
        const was_exec = facts.executable;
        pure.noteFile(&facts, name);
        if (!was_exec and facts.executable) @memcpy(offender[0 .. name.len + 1], name_buf[0 .. name.len + 1]);
    }
    const why = pure.torrentVerdict(facts) orelse return false;

    f = 0;
    while (f < files) : (f += 1) c.mpv.torrent_set_file_priority(ses, id, f, 0);
    c.mpv.torrent_pause(ses, id);

    var hash_buf: [64]u8 = undefined;
    @memset(&hash_buf, 0);
    if (c.mpv.torrent_get_infohash(ses, id, &hash_buf, hash_buf.len) == 0) {
        lock.lock();
        ensureLoadedLocked();
        if (blocklist.add(std.mem.sliceTo(&hash_buf, 0))) saveLocked();
        lock.unlock();
        // Rows for this torrent leave every result list now, not on the next search.
        @import("resolver.zig").dropRejectedRows();
    }

    var msg: [384]u8 = undefined;
    const name = @import("../core/text.zig").safeUtf8(std.mem.sliceTo(&offender, 0));
    logs.pushLog("error", "torrent", std.fmt.bufPrint(&msg, "Blocked torrent: {s} \"{s}\" (possible malware); stopped and blocklisted", .{ why, name }) catch "Blocked torrent (possible malware)", true);
    return true;
}

/// Mark every finished file; true once all files are finished and marked.
fn markFinished(ses: c.mpv.TorrentSession, id: i32, files: c_int) bool {
    const save_path = state.app.save_path_buf[0..state.app.save_path_len];
    var all_done = true;
    var f: c_int = 0;
    while (f < files) : (f += 1) {
        if (c.mpv.torrent_get_file_progress(ses, id, f) < 1.0) {
            all_done = false;
            continue;
        }
        var rel_buf: [2048]u8 = undefined;
        rel_buf[0] = 0;
        c.mpv.torrent_get_file_path(ses, id, f, &rel_buf, rel_buf.len);
        const rel = std.mem.sliceTo(&rel_buf, 0);
        var full_buf: [2048]u8 = undefined;
        if (pure.joinSavePath(save_path, rel, &full_buf)) |full_path| {
            markDownloaded(full_path);
        }
    }
    return all_done;
}

extern "c" fn getxattr(path: [*:0]const u8, name: [*:0]const u8, value: ?*anyopaque, size: usize, position: u32, options: c_int) isize;
extern "c" fn setxattr(path: [*:0]const u8, name: [*:0]const u8, value: *const anyopaque, size: usize, position: u32, options: c_int) c_int;

/// Add the OS download mark to `path` unless it already has one (the user may
/// have cleared it deliberately; never re-add over an existing value).
pub fn markDownloaded(path: []const u8) void {
    if (comptime builtin.os.tag == .macos) {
        var z: [2049]u8 = undefined;
        if (path.len >= z.len) return;
        @memcpy(z[0..path.len], path);
        z[path.len] = 0;
        const zp: [*:0]const u8 = @ptrCast(&z);
        if (getxattr(zp, "com.apple.quarantine", null, 0, 0, 0) >= 0) return;
        var v: [64]u8 = undefined;
        const value = pure.quarantineValue(&v, io_g.timestamp()) orelse return;
        if (setxattr(zp, "com.apple.quarantine", value.ptr, value.len, 0, 0) < 0) {
            var msg: [256]u8 = undefined;
            logs.pushLog("warn", "download", std.fmt.bufPrint(&msg, "Failed to set macOS quarantine xattr on {s}", .{std.fs.path.basename(path)}) catch "Failed to set macOS quarantine xattr", true);
        }
    } else if (comptime builtin.os.tag == .windows) {
        var ads: [2100]u8 = undefined;
        const stream = std.fmt.bufPrint(&ads, "{s}:Zone.Identifier", .{path}) catch return;
        if (io_g.openFileAbsolute(stream, .{})) |file| {
            file.close(io_g.io());
            return;
        } else |_| {}
        io_g.cwdWriteFile(.{ .sub_path = stream, .data = pure.zone_identifier }) catch |err| {
            var msg: [256]u8 = undefined;
            logs.pushLog("warn", "download", std.fmt.bufPrint(&msg, "Failed to write Zone.Identifier on {s}: {}", .{ std.fs.path.basename(path), err }) catch "Failed to write Zone.Identifier", true);
        };
    }
    // Linux has no enforced equivalent (user.xdg.origin.url is informational).
}
