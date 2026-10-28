//! Explicitly shared, bounded local clips; household feed never exposes paths.
const std = @import("std");
const db = @import("../core/household_db.zig");
const io = @import("../core/io_global.zig");
const alloc = @import("../core/alloc.zig").allocator;
const wire = @import("remote_http.zig");
const profiles = @import("profiles.zig");
const session = @import("stream_session.zig");
const pure = @import("moments_pure.zig");
var exporting = std.atomic.Value(bool).init(false);

fn ensure() void {
    db.exec("CREATE TABLE IF NOT EXISTS household_moments(id TEXT PRIMARY KEY,title TEXT NOT NULL,profile TEXT NOT NULL,path TEXT NOT NULL,start REAL NOT NULL,end REAL NOT NULL,created INTEGER NOT NULL DEFAULT (strftime('%s','now')))");
}

fn create(start: f64, end: f64, title: []const u8, out: *[32]u8) !void {
    if (profiles.runningIsKid()) return error.KidProfile;
    if (exporting.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return error.Busy;
    defer exporting.store(false, .release);
    var current: session.CurrentLocal = .{};
    if (!session.currentLocal(&current, false)) return error.LocalMediaRequired;
    if (!pure.validRange(start, end, current.duration)) return error.InvalidRange;
    if (title.len == 0 or title.len > 160) return error.InvalidTitle;
    ensure();
    {
        const count = db.prepare("SELECT count(*) FROM household_moments") orelse return error.Storage;
        defer db.finalize(count);
        if (db.step(count) == db.c.SQLITE_ROW and db.columnInt(count, 0) >= 100) return error.FeedFull;
    }
    var random: [16]u8 = undefined;
    if (!io.randomSecure(&random)) return error.NoEntropy;
    out.* = std.fmt.bytesToHex(random, .lower);
    var cfg: [512]u8 = undefined;
    var root_buf: [600]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "{s}/moments", .{@import("../core/paths.zig").configDir(&cfg)});
    try io.cwdMakePath(root);
    if (@import("builtin").os.tag != .windows) {
        var dir = try io.openDirAbsolute(root, .{});
        defer dir.close(io.io());
        try dir.setPermissions(io.io(), .fromMode(0o700));
    }
    var path_buf: [700]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.mp4", .{ root, out });
    errdefer io.deleteFileAbsolute(path) catch {};
    var ss_buf: [32]u8 = undefined;
    var length_buf: [32]u8 = undefined;
    const ss = try std.fmt.bufPrint(&ss_buf, "{d:.3}", .{start});
    const length = try std.fmt.bufPrint(&length_buf, "{d:.3}", .{end - start});
    var process = @import("../core/bounded_process.zig").StreamProcess.init(&.{
        @import("remote_stream.zig").ffmpegPath(), "-nostdin",                        "-v",                          "error",      "-n",      "-ss",     ss,
        "-i",                                      current.path[0..current.path_len], "-t",                          length,       "-map",    "0:v:0?",  "-map",
        "0:a:0?",                                  "-vf",                             "scale=w='min(1280,iw)':h=-2", "-c:v",       "libx264", "-preset", "veryfast",
        "-c:a",                                    "aac",                             "-movflags",                   "+faststart", path,
    }, .{ .timeout_ms = 120_000, .max_output_bytes = 2048, .cancel_flag = @import("../core/workers.zig").quittingSignal() });
    try process.start();
    const result = process.finish();
    if (!result.ok()) return error.ExportFailed;
    if (@import("builtin").os.tag != .windows) {
        const file = try io.openFileAbsolute(path, .{ .mode = .read_write });
        defer file.close(io.io());
        try file.setPermissions(io.io(), .fromMode(0o600));
    }
    const owner = profiles.runningProfile();
    const stmt = db.prepare("INSERT INTO household_moments(id,title,profile,path,start,end) VALUES(?1,?2,?3,?4,?5,?6)") orelse return error.Storage;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, out);
    db.bindText(stmt, 2, title);
    db.bindText(stmt, 3, owner.idText());
    db.bindText(stmt, 4, path);
    _ = db.c.sqlite3_bind_double(stmt, 5, start);
    _ = db.c.sqlite3_bind_double(stmt, 6, end);
    if (db.step(stmt) != db.c.SQLITE_DONE) return error.Storage;
}

const Clip = struct {
    path: []u8,
    title: []u8,
    duration: f64,
    fn deinit(self: Clip) void {
        alloc.free(self.path);
        alloc.free(self.title);
    }
};
fn get(id: []const u8) !Clip {
    ensure();
    const stmt = db.prepare("SELECT path,title,end-start FROM household_moments WHERE id=?1") orelse return error.Storage;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, id);
    if (db.step(stmt) != db.c.SQLITE_ROW) return error.NotFound;
    const path = try alloc.dupe(u8, db.columnText(stmt, 0) orelse "");
    errdefer alloc.free(path);
    return .{ .path = path, .title = try alloc.dupe(u8, db.columnText(stmt, 1) orelse ""), .duration = db.c.sqlite3_column_double(stmt, 2) };
}

fn list(w: *std.Io.Writer) !void {
    ensure();
    const stmt = db.prepare("SELECT id,title,profile,start,end,created FROM household_moments ORDER BY created DESC,id LIMIT 100") orelse return error.Storage;
    defer db.finalize(stmt);
    try w.writeAll("{\"moments\":[");
    var first = true;
    while (db.step(stmt) == db.c.SQLITE_ROW) {
        if (!first) try w.writeByte(',');
        first = false;
        try std.json.Stringify.value(.{ .id = db.columnText(stmt, 0) orelse "", .title = db.columnText(stmt, 1) orelse "", .profile = db.columnText(stmt, 2) orelse "", .start = db.c.sqlite3_column_double(stmt, 3), .end = db.c.sqlite3_column_double(stmt, 4), .created = db.columnInt64(stmt, 5) }, .{}, w);
    }
    try w.writeAll("]}");
}

fn action(path: []const u8, query: []const u8, body: []const u8, w: *std.Io.Writer) !void {
    var id_buf: [64]u8 = undefined;
    const id = wire.formParam(body, query, "id", &id_buf) orelse "";
    if (std.mem.eql(u8, path, "/moments/create")) {
        var start_buf: [64]u8 = undefined;
        var end_buf: [64]u8 = undefined;
        var title_buf: [200]u8 = undefined;
        const start = try std.fmt.parseFloat(f64, wire.formParam(body, query, "start", &start_buf) orelse "");
        const end = try std.fmt.parseFloat(f64, wire.formParam(body, query, "end", &end_buf) orelse "");
        var result: [32]u8 = undefined;
        try create(start, end, wire.formParam(body, query, "title", &title_buf) orelse "", &result);
        try std.json.Stringify.value(.{ .ok = true, .id = result[0..] }, .{}, w);
        return;
    }
    const clip = try get(id);
    defer clip.deinit();
    if (std.mem.eql(u8, path, "/moments/play")) {
        var created: session.Created = .{};
        try session.create(.{ .abs_path = clip.path, .title = clip.title, .force_direct = true }, &created);
        var url_buf: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "/api/stream/{s}/{s}/direct", .{ &created.sid, created.tokenText() });
        try std.json.Stringify.value(.{ .ok = true, .url = url, .title = clip.title }, .{}, w);
    } else if (std.mem.eql(u8, path, "/moments/send")) {
        var peer_buf: [256]u8 = undefined;
        var token_buf: [512]u8 = undefined;
        var host_buf: [80]u8 = undefined;
        const peer = wire.formParam(body, query, "peer", &peer_buf) orelse "";
        const token = wire.formParam(body, query, "token", &token_buf) orelse "";
        const handoff = @import("handoff.zig");
        var offer: @import("stream_pure.zig").Handoff = .{};
        try handoff.buildOffer(clip.path, clip.title, 0, clip.duration, handoff.hostForPeer(peer, &host_buf), &offer);
        try handoff.sendTo(peer, token, &offer);
        try w.writeAll("{\"ok\":true}");
    } else if (std.mem.eql(u8, path, "/moments/delete")) {
        const stmt = db.prepare("DELETE FROM household_moments WHERE id=?1") orelse return error.Storage;
        defer db.finalize(stmt);
        db.bindText(stmt, 1, id);
        if (db.step(stmt) != db.c.SQLITE_DONE) return error.Storage;
        io.deleteFileAbsolute(clip.path) catch {};
        try w.writeAll("{\"ok\":true}");
    } else return error.UnknownAction;
}

pub fn handle(stream: std.Io.net.Stream, method: []const u8, path: []const u8, query: []const u8, body: []const u8) bool {
    if (!std.mem.eql(u8, path, "/moments") and !std.mem.startsWith(u8, path, "/moments/")) return false;
    if (profiles.runningIsKid()) {
        wire.sendJsonStatus(stream, "403 Forbidden", "{\"error\":\"household clips are unavailable in kid mode\"}");
        return true;
    }
    const listing = std.mem.eql(u8, path, "/moments");
    if (!wire.requireMethod(stream, method, if (listing) "GET" else "POST")) return true;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const result = if (listing) list(&out.writer) else action(path, query, body, &out.writer);
    result catch |err| {
        var buf: [180]u8 = undefined;
        wire.sendJsonStatus(stream, "400 Bad Request", std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch "{\"error\":\"moment action failed\"}");
        return true;
    };
    wire.sendJson(stream, out.written());
    return true;
}
