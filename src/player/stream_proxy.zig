const std = @import("std");
const c = @import("../core/c.zig");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");

// ══════════════════════════════════════════════════════════
// ZigZag v2 — Torrent HTTP Streaming Proxy
//
// Instead of letting MPV open the raw file on disk (where
// undownloaded pieces = zeros/garbage → glitches), we run
// a localhost HTTP server that serves the torrent data 
// piece-by-piece. When MPV requests a byte range that isn't
// downloaded yet, the server BLOCKS until the piece arrives.
//
// This is exactly how Stremio, Popcorn Time, and WebTorrent
// handle torrent streaming — back-pressure prevents the 
// player from reading undownloaded data.
//
// Flow:
//   1. Torrent starts → we call startProxy(torrent_id, file_idx)
//   2. Proxy binds to 127.0.0.1:<random_port>
//   3. MPV loads http://127.0.0.1:<port>/stream instead of the file
//   4. MPV sends Range requests → proxy maps to pieces → blocks until ready → serves data
// ══════════════════════════════════════════════════════════

const CHUNK_SIZE: usize = 512 * 1024; // 512KB per read chunk

pub var proxy_port: u16 = 0;
pub var proxy_running: bool = false;
var proxy_thread: ?std.Thread = null;
var proxy_torrent_id: i32 = -1;
var proxy_file_idx: i32 = -1;
var proxy_stop: bool = false;
var proxy_file_size: i64 = 0;
var proxy_file_name: [256]u8 = undefined;
var proxy_file_name_len: usize = 0;

pub fn startProxy(torrent_id: i32, file_idx: i32) ?u16 {
    if (proxy_running) stopProxy();
    
    proxy_torrent_id = torrent_id;
    proxy_file_idx = file_idx;
    proxy_stop = false;
    proxy_file_size = c.mpv.torrent_get_file_size(state.app.torrent_ses, torrent_id, file_idx);
    
    if (proxy_file_size <= 0) {
        logs.pushLog("error", "proxy", "Cannot start proxy: file size unknown", false);
        return null;
    }
    
    // Get filename for content-type detection
    @memset(&proxy_file_name, 0);
    c.mpv.torrent_get_file_name(state.app.torrent_ses, torrent_id, file_idx, &proxy_file_name, 256);
    proxy_file_name_len = std.mem.indexOfScalar(u8, &proxy_file_name, 0) orelse 0;
    
    proxy_thread = std.Thread.spawn(.{}, proxyWorker, .{}) catch {
        logs.pushLog("error", "proxy", "Failed to spawn proxy thread", false);
        return null;
    };
    
    // Wait for port to be assigned
    var attempts: u32 = 0;
    while (proxy_port == 0 and attempts < 100) : (attempts += 1) {
        @import("../core/io_global.zig").sleep(10 * std.time.ns_per_ms);
    }
    
    if (proxy_port > 0) {
        proxy_running = true;
        var msg_buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&msg_buf, "Stream proxy on :{d}", .{proxy_port}) catch "Stream proxy started";
        logs.pushLog("info", "proxy", msg, false);
    }
    
    return proxy_port;
}

pub fn stopProxy() void {
    proxy_stop = true;
    proxy_running = false;
    
    // Connect to the socket to unblock accept()
    if (proxy_port > 0) {
        const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", proxy_port) catch return;
        var conn = addr.connect(@import("../core/io_global.zig").io(), .{ .mode = .stream }) catch return;
        conn.close(@import("../core/io_global.zig").io());
    }
    
    if (proxy_thread) |t| {
        t.join();
        proxy_thread = null;
    }
    proxy_port = 0;
    proxy_torrent_id = -1;
    proxy_file_idx = -1;
}

/// Get the stream URL for the current proxy
pub fn getStreamUrl(buf: *[128]u8) ?[]const u8 {
    if (!proxy_running or proxy_port == 0) return null;
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/stream", .{proxy_port}) catch null;
}

/// Detect MIME type from filename extension
fn getMimeType() []const u8 {
    if (proxy_file_name_len == 0) return "application/octet-stream";
    const name = proxy_file_name[0..proxy_file_name_len];
    if (std.mem.endsWith(u8, name, ".mkv")) return "video/x-matroska";
    if (std.mem.endsWith(u8, name, ".mp4")) return "video/mp4";
    if (std.mem.endsWith(u8, name, ".avi")) return "video/x-msvideo";
    if (std.mem.endsWith(u8, name, ".mov")) return "video/quicktime";
    if (std.mem.endsWith(u8, name, ".wmv")) return "video/x-ms-wmv";
    if (std.mem.endsWith(u8, name, ".webm")) return "video/webm";
    if (std.mem.endsWith(u8, name, ".flv")) return "video/x-flv";
    if (std.mem.endsWith(u8, name, ".ts")) return "video/mp2t";
    if (std.mem.endsWith(u8, name, ".m4v")) return "video/mp4";
    return "application/octet-stream";
}

fn proxyWorker() void {
    // 0.16 Server no longer exposes listen_address; use fixed port.
    proxy_port = 45678;
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", proxy_port) catch return;
    var server = addr.listen(@import("../core/io_global.zig").io(), .{ .reuse_address = true }) catch return;
    defer server.deinit(@import("../core/io_global.zig").io());

    while (!proxy_stop) {
        var conn = server.accept(@import("../core/io_global.zig").io()) catch continue;
        if (proxy_stop) { conn.close(@import("../core/io_global.zig").io()); break; }
        
        // Spawn a thread per connection so mpv can make concurrent requests
        // (probe request + data request can overlap)
        _ = std.Thread.spawn(.{}, handleConnectionThread, .{conn}) catch {
            handleConnection(conn) catch {};
            conn.close(@import("../core/io_global.zig").io());
            continue;
        };
    }
    
    proxy_port = 0;
    proxy_running = false;
}

fn handleConnectionThread(stream: std.Io.net.Stream) void {
    defer stream.close(@import("../core/io_global.zig").io());
    handleConnection(stream) catch {};
}

fn handleConnection(stream: std.Io.net.Stream) !void {
    // Read HTTP request
    var req_buf: [4096]u8 = undefined;
    const req_len = @import("../core/io_global.zig").streamReadAll(stream, &req_buf) catch return;
    if (req_len < 10) return;
    const request = req_buf[0..req_len];
    
    // Check for HEAD request (mpv probes with HEAD first)
    const is_head = std.mem.startsWith(u8, request, "HEAD ");
    
    // Parse Range header
    var range_start: i64 = 0;
    var range_end: i64 = proxy_file_size - 1;
    var has_range = false;
    
    if (std.mem.indexOf(u8, request, "Range: bytes=")) |range_idx| {
        has_range = true;
        const range_line_start = range_idx + "Range: bytes=".len;
        var range_line_end = range_line_start;
        while (range_line_end < request.len and request[range_line_end] != '\r' and request[range_line_end] != '\n') : (range_line_end += 1) {}
        const range_str = request[range_line_start..range_line_end];
        
        // Parse "start-end" or "start-"
        if (std.mem.indexOf(u8, range_str, "-")) |dash_idx| {
            const start_str = range_str[0..dash_idx];
            range_start = std.fmt.parseInt(i64, start_str, 10) catch 0;
            
            if (dash_idx + 1 < range_str.len) {
                const end_str = range_str[dash_idx + 1 ..];
                if (end_str.len > 0) {
                    range_end = std.fmt.parseInt(i64, end_str, 10) catch (proxy_file_size - 1);
                }
            }
        }
    }
    
    // Clamp ranges
    if (range_start < 0) range_start = 0;
    if (range_end >= proxy_file_size) range_end = proxy_file_size - 1;
    if (range_start > range_end) return;
    
    const content_length = range_end - range_start + 1;
    const mime = getMimeType();
    
    // Send HTTP response headers
    var hdr_buf: [512]u8 = undefined;
    const status_line = if (has_range) "206 Partial Content" else "200 OK";
    const hdr = std.fmt.bufPrint(&hdr_buf,
        "HTTP/1.1 {s}\r\n" ++
        "Content-Type: {s}\r\n" ++
        "Accept-Ranges: bytes\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n" ++
        "Access-Control-Allow-Origin: *\r\n",
        .{ status_line, mime, content_length },
    ) catch return;
    _ = @import("../core/io_global.zig").streamWriteAll(stream, hdr) catch return;
    
    if (has_range) {
        var range_hdr: [128]u8 = undefined;
        const rh = std.fmt.bufPrint(&range_hdr, "Content-Range: bytes {d}-{d}/{d}\r\n", .{ range_start, range_end, proxy_file_size }) catch return;
        _ = @import("../core/io_global.zig").streamWriteAll(stream, rh) catch return;
    }
    
    _ = @import("../core/io_global.zig").streamWriteAll(stream, "\r\n") catch return;
    
    // HEAD requests: headers only, no body
    if (is_head) return;
    
    // Stream data using piece-aware blocking reads
    var offset: i64 = range_start;
    var data_buf: [CHUNK_SIZE]u8 = undefined;
    
    while (offset <= range_end and !proxy_stop) {
        const remaining: usize = @intCast(range_end - offset + 1);
        const want = @min(remaining, CHUNK_SIZE);
        const read = c.mpv.torrent_read_bytes(
            state.app.torrent_ses,
            proxy_torrent_id,
            proxy_file_idx,
            offset,
            @ptrCast(&data_buf),
            @intCast(want),
        );
        
        if (read <= 0) break; // Error or EOF
        
        // Write all data (retry partial writes)
        var written_total: usize = 0;
        const read_u: usize = @intCast(read);
        @import("../core/io_global.zig").streamWriteAll(stream, data_buf[written_total..read_u]) catch break;
        written_total = read_u;
        
        offset += read;
    }
}
