//! Perceptual duplicate detection over the local library (ROADMAP 7.2).
//!
//! One background worker signs every indexed video that has no current
//! signature (SAMPLES grey frames via a low-priority, bounded ffmpeg each),
//! stores it in media_phash, then regroups the whole library with
//! phash_pure.group and writes the group ids back. The exact sampled-bytes
//! fingerprint in local_media still catches byte-identical copies; this
//! catches re-encodes and other resolutions of the same content. The worker
//! starts on demand — when duplicates are requested (UI toggle, web, API) —
//! so a library is never transcoded behind the user's back. All hash and
//! distance decisions live in phash_pure.zig.
const std = @import("std");
const builtin = @import("builtin");
const db = @import("../core/db.zig");
const logs = @import("../core/logs.zig");
const alloc = @import("../core/alloc.zig").allocator;
const io = @import("../core/io_global.zig");
const bounded_process = @import("../core/bounded_process.zig");
const workers = @import("../core/workers.zig");
const pure = @import("phash_pure.zig");
const mp = @import("markers_pure.zig");

const FRAME_TIMEOUT_MS: i64 = 60_000;
const BATCH = 32;
const MAX_GROUPED: usize = 200_000;

pub var hashing = std.atomic.Value(bool).init(false);
var hashed_this_run = std.atomic.Value(u32).init(0);

/// Start the worker unless it is already running. Cheap when nothing is
/// pending: one query, no regroup.
pub fn ensureAsync() void {
    if (hashing.load(.acquire) or workers.isQuitting()) return;
    if (workers.spawnLegacy(worker, .{})) |thread| workers.release(thread) else |_| {}
}

const Row = struct {
    path: [2048]u8 = undefined,
    path_len: usize = 0,
    size: i64 = 0,
    mtime: i64 = 0,
};

const pending_where = "FROM local_media l LEFT JOIN media_phash p ON p.path=l.path " ++
    "WHERE p.path IS NULL OR p.size<>l.size OR p.mtime<>l.mtime";

fn worker() void {
    if (hashing.swap(true, .acq_rel)) return;
    defer {
        hashing.store(false, .release);
        @import("../core/state.zig").wakeUi(); // drop the "comparing" hint
    }
    hashed_this_run.store(0, .release);

    // Forget files that left the index.
    var dirty = false;
    if (db.prepare("DELETE FROM media_phash WHERE path NOT IN (SELECT path FROM local_media)")) |stmt| {
        _ = db.step(stmt);
        if (db.get()) |handle| dirty = db.c.sqlite3_changes(handle) > 0;
        db.finalize(stmt);
    }

    const rows = alloc.alloc(Row, BATCH) catch return;
    defer alloc.free(rows);
    var ffmpeg: []const u8 = "";
    while (!workers.isQuitting()) {
        const n = loadPending(rows);
        if (n == 0) break;
        if (ffmpeg.len == 0) {
            ffmpeg = @import("remote_stream.zig").ffmpegPath();
            if (ffmpeg.len == 0) {
                logs.pushLog("warn", "phash", "ffmpeg not found; visual duplicate detection disabled", false);
                break;
            }
        }
        for (rows[0..n]) |*row| {
            if (workers.isQuitting()) return;
            if (!hashFile(ffmpeg, row)) return; // quitting mid-file: store nothing
            _ = hashed_this_run.fetchAdd(1, .acq_rel);
            dirty = true;
        }
    }
    if (dirty and !workers.isQuitting()) regroup();
}

fn loadPending(out: []Row) usize {
    const stmt = db.prepare("SELECT l.path,l.size,l.mtime " ++ pending_where ++ " ORDER BY l.rowid LIMIT ?1") orelse return 0;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, @intCast(out.len));
    var n: usize = 0;
    while (n < out.len and db.step(stmt) == db.c.SQLITE_ROW) {
        out[n] = .{ .size = db.columnInt64(stmt, 1), .mtime = db.columnInt64(stmt, 2) };
        db.copyColumn(stmt, 0, &out[n].path, &out[n].path_len);
        if (out[n].path_len == 0 or out[n].path_len + 1 >= out[n].path.len) continue; // truncated path
        n += 1;
    }
    return n;
}

/// Sign one file and store the row (an unusable signature is stored as
/// samples=0 so it is not retried until the file changes). Returns false only
/// when quitting interrupted it.
fn hashFile(ffmpeg: []const u8, row: *const Row) bool {
    const path = row.path[0..row.path_len];
    var sig: pure.Signature = .{};
    var positions: [pure.SAMPLES]f64 = undefined;
    if (mp.isVideoName(path)) {
        sig.duration = @import("markers.zig").probeDuration(ffmpeg, path);
        if (pure.samplePositions(sig.duration, &positions)) {
            for (positions, 0..) |t, i| {
                if (workers.isQuitting()) return false;
                var frame: [pure.FRAME_BYTES + 1]u8 = undefined;
                pure.setSample(&sig, i, extractFrame(ffmpeg, path, t, &frame));
            }
        }
    }
    store(path, row.size, row.mtime, sig);
    return true;
}

fn extractFrame(ffmpeg: []const u8, path: []const u8, seconds: f64, buf: *[pure.FRAME_BYTES + 1]u8) ?*const [pure.FRAME_BYTES]u8 {
    var ts: [32]u8 = undefined;
    var frame_argv: [pure.FRAME_ARGC][]const u8 = undefined;
    const tail = pure.frameArgv(ffmpeg, path, seconds, &ts, &frame_argv) orelse return null;
    var argv: [pure.FRAME_ARGC + 3][]const u8 = undefined;
    var n: usize = 0;
    // Background work competing with playback: lowest priority.
    if (builtin.os.tag != .windows) {
        if (io.cwdStatFile("/usr/bin/nice")) |_| {
            for ([_][]const u8{ "/usr/bin/nice", "-n", "19" }) |a| {
                argv[n] = a;
                n += 1;
            }
        } else |_| {}
    }
    for (tail) |a| {
        argv[n] = a;
        n += 1;
    }
    const res = bounded_process.run(argv[0..n], buf, .{ .timeout_ms = FRAME_TIMEOUT_MS });
    if (!res.ok() or res.output.len != pure.FRAME_BYTES) return null;
    return buf[0..pure.FRAME_BYTES];
}

fn store(path: []const u8, size: i64, mtime: i64, sig: pure.Signature) void {
    const stmt = db.prepare("INSERT OR REPLACE INTO media_phash(path,size,mtime,duration,samples,flat_mask,hashes,group_id,distance,updated_at) VALUES(?1,?2,?3,?4,?5,?6,?7,0,0,?8)") orelse return;
    defer db.finalize(stmt);
    const ok = pure.usable(sig);
    var blob: [pure.BLOB_BYTES]u8 = undefined;
    db.bindText(stmt, 1, path);
    db.bindInt64(stmt, 2, size);
    db.bindInt64(stmt, 3, mtime);
    db.bindDouble(stmt, 4, sig.duration);
    db.bindInt64(stmt, 5, if (ok) pure.SAMPLES else 0);
    db.bindInt64(stmt, 6, sig.flat_mask);
    db.bindBlob(stmt, 7, if (ok) pure.encodeHashes(sig, &blob) else "");
    db.bindInt64(stmt, 8, io.timestamp());
    _ = db.step(stmt);
}

/// Recompute every group from the stored signatures and write back only the
/// rows whose group or distance changed.
fn regroup() void {
    const count_stmt = db.prepare("SELECT COUNT(*) FROM media_phash WHERE samples>0") orelse return;
    const counted: usize = if (db.step(count_stmt) == db.c.SQLITE_ROW) @intCast(@max(db.columnInt64(count_stmt, 0), 0)) else 0;
    db.finalize(count_stmt);
    const cap = @min(counted, MAX_GROUPED);

    const sigs = alloc.alloc(pure.Signature, cap) catch return;
    defer alloc.free(sigs);
    const rowids = alloc.alloc(i64, cap) catch return;
    defer alloc.free(rowids);
    const old_group = alloc.alloc(i64, cap) catch return;
    defer alloc.free(old_group);
    const old_distance = alloc.alloc(f32, cap) catch return;
    defer alloc.free(old_distance);
    const order = alloc.alloc(u32, cap) catch return;
    defer alloc.free(order);
    const parent = alloc.alloc(u32, cap) catch return;
    defer alloc.free(parent);
    const groups = alloc.alloc(u32, cap) catch return;
    defer alloc.free(groups);
    const distance = alloc.alloc(f32, cap) catch return;
    defer alloc.free(distance);

    var n: usize = 0;
    if (db.prepare("SELECT rowid,duration,flat_mask,hashes,group_id,distance FROM media_phash WHERE samples>0 ORDER BY rowid LIMIT ?1")) |stmt| {
        defer db.finalize(stmt);
        db.bindInt64(stmt, 1, @intCast(cap));
        while (n < cap and db.step(stmt) == db.c.SQLITE_ROW) {
            var sig: pure.Signature = .{
                .duration = db.columnDouble(stmt, 1),
                .flat_mask = @truncate(@as(u64, @bitCast(db.columnInt64(stmt, 2)))),
            };
            if (!pure.decodeHashes(db.columnBlob(stmt, 3) orelse "", &sig)) continue;
            sigs[n] = sig;
            rowids[n] = db.columnInt64(stmt, 0);
            old_group[n] = db.columnInt64(stmt, 4);
            old_distance[n] = @floatCast(db.columnDouble(stmt, 5));
            n += 1;
        }
    } else return;

    const members = pure.group(sigs[0..n], order[0..n], parent[0..n], groups[0..n], distance[0..n]);
    var updated: usize = 0;
    for (0..n) |i| {
        if (workers.isQuitting()) return;
        if (old_group[i] == groups[i] and @abs(old_distance[i] - distance[i]) < 0.01) continue;
        const stmt = db.prepare("UPDATE media_phash SET group_id=?1,distance=?2 WHERE rowid=?3") orelse return;
        db.bindInt64(stmt, 1, groups[i]);
        db.bindDouble(stmt, 2, distance[i]);
        db.bindInt64(stmt, 3, rowids[i]);
        _ = db.step(stmt);
        db.finalize(stmt);
        updated += 1;
    }
    var lb: [128]u8 = undefined;
    logs.pushLog("info", "phash", std.fmt.bufPrint(&lb, "visual duplicates: {d} of {d} signed files in groups", .{ members, n }) catch "visual duplicates regrouped", false);
    if (updated > 0) @import("local_library.zig").changed();
}

pub const Status = struct { hashing: bool, hashed: u32, pending: usize, signed: usize, grouped: usize };

pub fn status() Status {
    var s: Status = .{ .hashing = hashing.load(.acquire), .hashed = hashed_this_run.load(.acquire), .pending = 0, .signed = 0, .grouped = 0 };
    if (db.prepare("SELECT COUNT(*) " ++ pending_where)) |stmt| {
        if (db.step(stmt) == db.c.SQLITE_ROW) s.pending = @intCast(@max(db.columnInt64(stmt, 0), 0));
        db.finalize(stmt);
    }
    if (db.prepare("SELECT COALESCE(SUM(samples>0),0),COALESCE(SUM(group_id>0),0) FROM media_phash")) |stmt| {
        if (db.step(stmt) == db.c.SQLITE_ROW) {
            s.signed = @intCast(@max(db.columnInt64(stmt, 0), 0));
            s.grouped = @intCast(@max(db.columnInt64(stmt, 1), 0));
        }
        db.finalize(stmt);
    }
    return s;
}

pub const GroupItem = struct {
    group: i64 = 0,
    id: i64 = 0,
    title: [256]u8 = undefined,
    title_len: usize = 0,
    size: u64 = 0,
    duration: f64 = 0,
    distance: f64 = 0,
};

/// Grouped files (group id, then largest copy first). Library ids only — the
/// remote API never sees a path.
pub fn listGroups(offset: usize, out: []GroupItem) usize {
    const stmt = db.prepare("SELECT p.group_id,l.rowid,COALESCE(NULLIF(l.display_title,''),l.title),l.size,p.duration,p.distance " ++
        "FROM media_phash p JOIN local_media l ON l.path=p.path WHERE p.group_id>0 ORDER BY p.group_id,l.size DESC,l.rowid LIMIT ?1 OFFSET ?2") orelse return 0;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, @intCast(out.len));
    db.bindInt64(stmt, 2, @intCast(@min(offset, std.math.maxInt(i64))));
    var n: usize = 0;
    while (n < out.len and db.step(stmt) == db.c.SQLITE_ROW) : (n += 1) {
        out[n] = .{
            .group = db.columnInt64(stmt, 0),
            .id = db.columnInt64(stmt, 1),
            .size = @intCast(@max(db.columnInt64(stmt, 3), 0)),
            .duration = db.columnDouble(stmt, 4),
            .distance = db.columnDouble(stmt, 5),
        };
        db.copyColumn(stmt, 2, &out[n].title, &out[n].title_len);
    }
    return n;
}
