//! Server half of offline sync: devices that downloaded files for offline
//! play push their watch progress here when they are back online.
//!
//!   GET  /api/offline/progress?id=srv:<rel>   the stored record (404 if none)
//!   POST /api/offline/progress                one record (offline_pure wire
//!                                             format); replies with the winner
//!
//! The merge rule (version, then last writer, then device) is
//! offline_pure.merge. Accepted records are also written into this host's
//! watch history for the file, on the UI thread (tick), so Continue Watching
//! here picks up where the phone stopped. Records persist in
//! `<config>/offline_progress.jsonl`, one per line.

const std = @import("std");
const state = @import("../core/state.zig");
const sync = @import("../core/sync.zig");
const io = @import("../core/io_global.zig");
const paths = @import("../core/paths.zig");
const wire = @import("remote_http.zig");
const alloc = @import("../core/alloc.zig").allocator;
const pure = @import("offline_pure.zig");

const MAX_RECORDS: usize = 256;
const MAX_PENDING: usize = 16;

const Record = struct {
    id: [pure.ID_LEN]u8 = undefined,
    id_len: usize = 0,
    progress: pure.Progress = .{},
};

var mutex: sync.Mutex = .{};
var records: [MAX_RECORDS]Record = undefined;
var record_count: usize = 0;
var loaded = false;
var pending: [MAX_PENDING]Record = undefined;
var pending_count: usize = 0;

fn storeFile(buf: []u8) []const u8 {
    var cfg: [512]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/offline_progress.jsonl", .{paths.configDir(&cfg)}) catch "";
}

fn loadLocked() void {
    loaded = true;
    var pb: [600]u8 = undefined;
    const path = storeFile(&pb);
    if (path.len == 0) return;
    const f = io.openFileAbsolute(path, .{}) catch return;
    defer io.closeFile(f);
    const buf = alloc.alloc(u8, MAX_RECORDS * 512) catch return;
    defer alloc.free(buf);
    const n = io.readAll(f, buf) catch return;
    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (lines.next()) |line| {
        if (record_count >= MAX_RECORDS) break;
        const d = pure.decodeProgress(alloc, line) orelse continue;
        var r: Record = .{ .progress = d.progress };
        @memcpy(r.id[0..d.id_len], d.idText());
        r.id_len = d.id_len;
        records[record_count] = r;
        record_count += 1;
    }
}

fn saveLocked() void {
    var pb: [600]u8 = undefined;
    const path = storeFile(&pb);
    if (path.len == 0) return;
    const buf = alloc.alloc(u8, MAX_RECORDS * 512) catch return;
    defer alloc.free(buf);
    var w = std.Io.Writer.fixed(buf);
    for (records[0..record_count]) |*r| {
        pure.encodeProgress(&w, r.id[0..r.id_len], &r.progress) catch return;
        w.writeByte('\n') catch return;
    }
    var tb: [610]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tb, "{s}.tmp", .{path}) catch return;
    const f = io.createFileAbsolute(tmp, .{ .truncate = true }) catch return;
    io.writeAll(f, buf[0..w.end]) catch {
        io.closeFile(f);
        return;
    };
    io.closeFile(f);
    io.renameAbsolute(tmp, path) catch {};
}

fn findLocked(id: []const u8) ?usize {
    for (records[0..record_count], 0..) |*r, i| {
        if (std.mem.eql(u8, r.id[0..r.id_len], id)) return i;
    }
    return null;
}

/// Merge one pushed record; returns the winner the client should hold.
fn mergeIncoming(d: *const pure.DecodedProgress) Record {
    mutex.lock();
    defer mutex.unlock();
    if (!loaded) loadLocked();
    var incoming: Record = .{ .progress = d.progress };
    incoming.progress.dirty = false;
    @memcpy(incoming.id[0..d.id_len], d.idText());
    incoming.id_len = d.id_len;

    const idx = findLocked(d.idText());
    if (idx) |i| {
        if (pure.merge(&records[i].progress, &incoming.progress) != .remote) return records[i];
        records[i] = incoming;
    } else {
        if (record_count == MAX_RECORDS) {
            // Evict the least recently updated record.
            var oldest: usize = 0;
            for (records[0..record_count], 0..) |*r, i| {
                if (r.progress.updated_ms < records[oldest].progress.updated_ms) oldest = i;
            }
            records[oldest] = incoming;
        } else {
            records[record_count] = incoming;
            record_count += 1;
        }
    }
    saveLocked();
    if (pending_count < MAX_PENDING) {
        pending[pending_count] = incoming;
        pending_count += 1;
    }
    return incoming;
}

fn sendRecord(stream: std.Io.net.Stream, r: *const Record) void {
    var out: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    pure.encodeProgress(&w, r.id[0..r.id_len], &r.progress) catch return;
    wire.sendJson(stream, out[0..w.end]);
}

/// remote.zig dispatch. Host principals only reach /api (bearer-gated).
pub fn handle(stream: std.Io.net.Stream, method: []const u8, path: []const u8, query: []const u8, body: []const u8) bool {
    if (!std.mem.eql(u8, path, "/offline/progress")) return false;
    if (std.mem.eql(u8, method, "GET")) {
        var idb: [pure.ID_LEN]u8 = undefined;
        const id = wire.formParam("", query, "id", &idb) orelse "";
        mutex.lock();
        if (!loaded) loadLocked();
        const idx = findLocked(id);
        const rec: ?Record = if (idx) |i| records[i] else null;
        mutex.unlock();
        if (rec) |r| sendRecord(stream, &r) else wire.sendJsonStatus(stream, "404 Not Found", "{\"error\":\"no record\"}");
        return true;
    }
    if (!wire.requireMethod(stream, method, "POST")) return true;
    const d = pure.decodeProgress(alloc, body) orelse {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"invalid progress record\"}");
        return true;
    };
    if (pure.serverRel(d.idText()) == null) {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"id must be srv:<downloads-relative path>\"}");
        return true;
    }
    const winner = mergeIncoming(&d);
    sendRecord(stream, &winner);
    return true;
}

/// UI thread: fold accepted records into this host's watch history (the
/// writer is UI-thread only), keyed like a web stream session: the file's
/// basename with its absolute path as the link.
pub fn tick() void {
    var batch: [MAX_PENDING]Record = undefined;
    mutex.lock();
    const n = pending_count;
    @memcpy(batch[0..n], pending[0..n]);
    pending_count = 0;
    mutex.unlock();
    if (n == 0) return;
    var root_buf: [512]u8 = undefined;
    const root = if (state.app.save_path_len > 0) state.app.save_path_buf[0..state.app.save_path_len] else paths.defaultSavePath(&root_buf);
    for (batch[0..n]) |*r| {
        const rel = pure.serverRel(r.id[0..r.id_len]) orelse continue;
        var pb: [2048]u8 = undefined;
        const full = std.fmt.bufPrint(&pb, "{s}/{s}", .{ root, rel }) catch continue;
        const p = &r.progress;
        @import("../player/watch_history.zig").savePositionFull(pure.basename(rel), pure.percentOf(p), p.pos_s, p.dur_s, full, 0);
    }
}
