//! Browser media serving for the web companion / hosted mode: HTTP Range
//! streaming of downloaded files, SRT→VTT subtitle sidecars, and a poster
//! proxy backed by the shared poster disk cache. Split out of remote.zig
//! (routing/auth) to keep both files sane; pure logic lives in
//! remote_stream_pure.zig (tested).
//!
//! Auth note: <video src> and <img src> cannot attach an Authorization
//! header, so these three routes accept the bearer token as a `t=` query
//! parameter instead. remote.zig validates it BEFORE dispatching here.

const std = @import("std");
const state = @import("../core/state.zig");
const io_g = @import("../core/io_global.zig");
const pure = @import("remote_stream_pure.zig");
const alloc = @import("../core/alloc.zig").allocator;

const CHUNK = 256 * 1024;

fn writeAll(stream: std.Io.net.Stream, bytes: []const u8) bool {
    io_g.streamWriteAll(stream, bytes) catch return false;
    return true;
}

fn send404(stream: std.Io.net.Stream) void {
    _ = writeAll(stream, "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found");
}

fn downloadsRoot(buf: []u8) []const u8 {
    if (state.app.save_path_len > 0) return state.app.save_path_buf[0..state.app.save_path_len];
    return @import("../core/paths.zig").defaultSavePath(buf);
}

fn resolveUnder(root: []const u8, rel: []const u8, buf: []u8) ?[]const u8 {
    if (!pure.safeRelPath(rel)) return null;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ root, rel }) catch null;
}

/// GET /stream?file=<rel>[&t=token] — Range-aware file streaming from the
/// downloads dir. Works mid-download (reads whatever bytes exist; the
/// torrent path already prioritizes sequential pieces for streaming).
pub fn handleStream(stream: std.Io.net.Stream, request: []const u8, rel: []const u8) void {
    var root_buf: [512]u8 = undefined;
    var path_buf: [1600]u8 = undefined;
    const path = resolveUnder(downloadsRoot(&root_buf), rel, &path_buf) orelse return send404(stream);

    const st = io_g.cwdStatFile(path) catch return send404(stream);
    const size: u64 = st.size;

    const file = io_g.cwdOpenFile(path, .{}) catch return send404(stream);
    var fh = file;
    defer fh.close(io_g.io());

    // Range header (if any). Absent/garbage → whole file, 200.
    var range: ?pure.Range = null;
    if (headerValue(request, "range")) |rv| range = pure.parseRange(rv, size);

    const start: u64 = if (range) |r| r.start else 0;
    const end: u64 = if (range) |r| r.end else (if (size > 0) size - 1 else 0);
    const total: u64 = if (size == 0) 0 else end - start + 1;

    var hdr: [512]u8 = undefined;
    const h = if (range != null)
        std.fmt.bufPrint(&hdr, "HTTP/1.1 206 Partial Content\r\nContent-Type: {s}\r\nAccept-Ranges: bytes\r\nContent-Range: bytes {d}-{d}/{d}\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\n\r\n", .{ pure.contentType(rel), start, end, size, total }) catch return
    else
        std.fmt.bufPrint(&hdr, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nAccept-Ranges: bytes\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\n\r\n", .{ pure.contentType(rel), size }) catch return;
    if (!writeAll(stream, h)) return;

    const buf = alloc.alloc(u8, CHUNK) catch return;
    defer alloc.free(buf);
    var off: u64 = start;
    var left: u64 = total;
    while (left > 0) {
        const want: usize = @intCast(@min(left, buf.len));
        const n = fh.readPositionalAll(io_g.io(), buf[0..want], off) catch break;
        if (n == 0) break; // sparse/mid-download tail — stop cleanly
        if (!writeAll(stream, buf[0..n])) break; // client seeked/left
        off += n;
        left -= n;
    }
}

/// GET /vtt?file=<rel .srt/.vtt>[&t=] — subtitle sidecar as WebVTT.
pub fn handleVtt(stream: std.Io.net.Stream, rel: []const u8) void {
    var root_buf: [512]u8 = undefined;
    var path_buf: [1600]u8 = undefined;
    const path = resolveUnder(downloadsRoot(&root_buf), rel, &path_buf) orelse return send404(stream);

    const raw = io_g.cwdReadFileAlloc(path, alloc, 2 * 1024 * 1024) catch return send404(stream);
    defer alloc.free(raw);

    var body: []const u8 = raw;
    var converted: ?[]u8 = null;
    defer if (converted) |c| alloc.free(c);
    if (!std.mem.startsWith(u8, raw, "WEBVTT")) {
        const out = alloc.alloc(u8, raw.len + 64) catch return send404(stream);
        converted = out;
        body = out[0..pure.srtToVtt(raw, out)];
    }

    var hdr: [256]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "HTTP/1.1 200 OK\r\nContent-Type: text/vtt\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\n\r\n", .{body.len}) catch return;
    if (writeAll(stream, h)) _ = writeAll(stream, body);
}

/// GET /poster?path=<tmdb poster_path>[&t=] — serve from the shared poster
/// disk cache; on miss, fetch from TMDB once and cache (same store the
/// desktop grid uses, so phone browsing warms the desktop and vice versa).
pub fn handlePoster(stream: std.Io.net.Stream, tmdb_path: []const u8) void {
    if (tmdb_path.len == 0 or tmdb_path.len > 96 or tmdb_path[0] != '/') return send404(stream);
    const poster = @import("../core/poster.zig");
    var url_buf: [160]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://image.tmdb.org/t/p/w185{s}", .{tmdb_path}) catch return send404(stream);

    // Two ownership paths, two frees: the cache hands back c_alloc bytes
    // (cacheFreeEncoded); a network fetch lives in our own app-alloc buffer.
    if (poster.cacheLoadForUrl(url)) |cached| {
        defer poster.cacheFreeEncoded(cached);
        sendImage(stream, cached);
        return;
    }
    // Cache miss — curl once, store, serve. (Connection thread; blocking ok.)
    const buf = alloc.alloc(u8, 512 * 1024) catch return send404(stream);
    defer alloc.free(buf);
    var child = io_g.Child.init(&.{ "curl", "-s", "--max-time", "10", url }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return send404(stream);
    const n = if (child.stdout) |*so| io_g.readAll(so, buf) catch 0 else 0;
    _ = child.wait() catch {};
    if (n < 100) return send404(stream);
    poster.cacheStoreForUrl(url, buf[0..n], 0, 0);
    sendImage(stream, buf[0..n]);
}

fn sendImage(stream: std.Io.net.Stream, body: []const u8) void {
    var hdr: [256]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nCache-Control: max-age=86400\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\n\r\n", .{body.len}) catch return;
    if (writeAll(stream, h)) _ = writeAll(stream, body);
}

/// Case-insensitive request-header lookup ("range" → bytes=…).
fn headerValue(request: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, request, '\n');
    _ = lines.next();
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len <= name.len + 1) continue;
        if (!std.ascii.eqlIgnoreCase(line[0..name.len], name) or line[name.len] != ':') continue;
        return std.mem.trim(u8, line[name.len + 1 ..], " \t");
    }
    return null;
}
