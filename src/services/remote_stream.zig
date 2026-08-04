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
    var url_buf: [160]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://image.tmdb.org/t/p/w185{s}", .{tmdb_path}) catch return send404(stream);
    serveProxied(stream, url, url);
}

/// GET /api/jellyfin/poster?id=<itemId>[&t=] — proxy a Jellyfin item's Primary
/// image through the shared poster disk cache. The connected server URL + auth
/// token live in state (never sent by the browser), so the phone never sees the
/// Jellyfin credentials; `<img>` just references this same-origin route. The id
/// is validated (jellyfin_pure.validItemId) before it reaches the URL — it can't
/// escape the path or inject query params.
pub fn handleJfPoster(stream: std.Io.net.Stream, item_id: []const u8) void {
    const jp = @import("jellyfin_pure.zig");
    if (!jp.validItemId(item_id)) return send404(stream);
    if (!state.app.jf.connected) return send404(stream);

    // Snapshot server + token into locals (avoid a torn read if the UI edits
    // them, and to bound them).
    var server_buf: [256]u8 = undefined;
    const server_len = @min(state.app.jf.server_url_len, server_buf.len);
    @memcpy(server_buf[0..server_len], state.app.jf.server_url[0..server_len]);
    const server = server_buf[0..server_len];
    if (server.len == 0) return send404(stream);

    var token_buf: [256]u8 = undefined;
    const token_len = @min(state.app.jf.token_len, token_buf.len);
    @memcpy(token_buf[0..token_len], state.app.jf.token[0..token_len]);
    const token = token_buf[0..token_len];

    // Cache key omits the api_key so a token rotation can't orphan cached
    // posters (shared with the desktop worker via jellyfin_pure).
    var key_buf: [512]u8 = undefined;
    const cache_key = jp.primaryImageCacheKey(server, item_id, &key_buf) orelse return send404(stream);
    var url_buf: [600]u8 = undefined;
    const url = jp.primaryImageUrl(server, item_id, token, &url_buf) orelse return send404(stream);
    serveProxied(stream, url, cache_key);
}

/// GET /api/comics/page?i=<n>[&t=] — serve one downloaded comic page.
///
/// `state.app.comic.page_pixels[i]` already holds the ORIGINAL encoded bytes the
/// source served (comics.zig downloads, it never re-encodes), so this is a copy
/// and a write — no proxying, no disk cache, and the reader's cookies/referer
/// never matter. `comics.copyPage` takes the pages mutex so a concurrent
/// `loadComic` can't free the buffer mid-send; a not-yet-downloaded page is a
/// 404 the client re-polls as `dl_progress` climbs.
pub fn handleComicPage(stream: std.Io.net.Stream, idx: usize) void {
    if (idx >= state.app.comic.page_count) return send404(stream);
    const comics = @import("comics.zig");
    const bytes = comics.copyPage(idx, alloc) orelse return send404(stream);
    defer alloc.free(bytes);
    const mime = @import("comics_pure.zig").imageMime(bytes);
    var hdr: [256]u8 = undefined;
    // no-store: page N means a different image once the reader loads a new comic.
    const h = std.fmt.bufPrint(&hdr, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nCache-Control: no-store\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\n\r\n", .{ mime, bytes.len }) catch return;
    if (writeAll(stream, h)) _ = writeAll(stream, bytes);
}

/// GET /api/podcasts/poster?idx=<n>[&t=] — proxy a podcast show's iTunes cover
/// (a public https URL held in state) through the shared poster disk cache. By
/// index (not an arbitrary URL param) so the proxy can only ever fetch an
/// artwork URL the desktop already parsed — no SSRF surface.
pub fn handlePodcastPoster(stream: std.Io.net.Stream, idx: usize) void {
    if (idx >= state.app.podcasts.result_count) return send404(stream);
    const r = &state.app.podcasts.results[idx];
    // Snapshot the URL — a concurrent re-search may rewrite results[idx].
    var art_buf: [300]u8 = undefined;
    const alen = @min(r.artwork_len, art_buf.len);
    if (alen == 0) return send404(stream);
    @memcpy(art_buf[0..alen], r.artwork[0..alen]);
    const url = art_buf[0..alen];
    if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://"))
        return send404(stream);
    serveProxied(stream, url, url);
}

/// Serve `fetch_url` as an image, backed by the shared poster disk cache keyed
/// by `cache_key`. Cache hit → serve the stored encoded bytes; miss → curl
/// once, store, serve. Runs on the connection thread (blocking curl ok).
fn serveProxied(stream: std.Io.net.Stream, fetch_url: []const u8, cache_key: []const u8) void {
    const poster = @import("../core/poster.zig");
    // Two ownership paths, two frees: the cache hands back c_alloc bytes
    // (cacheFreeEncoded); a network fetch lives in our own app-alloc buffer.
    if (poster.cacheLoadForUrl(cache_key)) |cached| {
        defer poster.cacheFreeEncoded(cached);
        sendImage(stream, cached);
        return;
    }
    const buf = alloc.alloc(u8, 512 * 1024) catch return send404(stream);
    defer alloc.free(buf);
    var child = io_g.Child.init(&.{ "curl", "-s", "--max-time", "10", fetch_url }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return send404(stream);
    const n = if (child.stdout) |*so| io_g.readAll(so, buf) catch 0 else 0;
    _ = child.wait() catch {};
    if (n < 100) return send404(stream);
    poster.cacheStoreForUrl(cache_key, buf[0..n], 0, 0);
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

// ══════════════════════════════════════════════════════════
// On-the-fly transcode
// ══════════════════════════════════════════════════════════
//
// Direct-play covers MP4/H.264 and the audio formats, but most scraped
// releases are MKV/H.265/AC3 and no browser demuxes those. This pipes the file
// through ffmpeg into fragmented MP4 (`frag_keyframe+empty_moov`) so it can be
// played while it is still being produced.
//
// Deliberate limits, so the shape is honest rather than half-magic:
//
//   * NO Range support. The output does not exist ahead of time and has no
//     length, so `Accept-Ranges: none` and no Content-Length. Seeking is done
//     by RESTARTING the transcode at an offset — that is what `start` is for,
//     and the web player reloads the URL rather than issuing a range request.
//   * One ffmpeg per request, killed when the client goes away. Without that a
//     closed tab would leave an encoder pinning a core forever.
//   * `veryfast` + CRF 23: this has to keep ahead of playback on a laptop, and
//     an unwatchably-late perfect encode is worse than a good-enough live one.

/// Where ffmpeg actually is. Resolved once and cached.
///
/// A bare "ffmpeg" is not enough: an app launched from Finder inherits a
/// minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin) with no Homebrew in it, so the
/// installed Opal.app would report "no ffmpeg" on a machine that plainly has
/// it. Probe the usual install locations directly, then fall back to PATH for
/// the dev/CLI case and for distros that put it somewhere else.
var ffmpeg_checked: bool = false;
var ffmpeg_path_buf: [128]u8 = std.mem.zeroes([128]u8);
var ffmpeg_path_len: usize = 0;

const FFMPEG_CANDIDATES = [_][]const u8{
    "/opt/homebrew/bin/ffmpeg", // Apple Silicon Homebrew
    "/usr/local/bin/ffmpeg", // Intel Homebrew / manual installs
    "/opt/local/bin/ffmpeg", // MacPorts
    "/usr/bin/ffmpeg", // Linux distro packages
    "/snap/bin/ffmpeg",
};

/// Absolute path to ffmpeg, or "" when it could not be found.
pub fn ffmpegPath() []const u8 {
    if (ffmpeg_checked) return ffmpeg_path_buf[0..ffmpeg_path_len];
    ffmpeg_checked = true;

    for (FFMPEG_CANDIDATES) |cand| {
        _ = io_g.cwdStatFile(cand) catch continue;
        const n = @min(cand.len, ffmpeg_path_buf.len);
        @memcpy(ffmpeg_path_buf[0..n], cand[0..n]);
        ffmpeg_path_len = n;
        return ffmpeg_path_buf[0..n];
    }

    // Not in a known location — try PATH resolution as a last resort.
    var child = io_g.Child.init(&.{ "ffmpeg", "-version" }, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return "";
    _ = child.wait() catch {};
    const fallback = "ffmpeg";
    @memcpy(ffmpeg_path_buf[0..fallback.len], fallback);
    ffmpeg_path_len = fallback.len;
    return ffmpeg_path_buf[0..fallback.len];
}

pub fn haveFfmpeg() bool {
    return ffmpegPath().len > 0;
}

/// Wait until the socket will accept more data, or give up.
///
/// This is the fix for the transcode leak. `io_g.streamWriteAll` blocks
/// indefinitely once the peer stops reading: the kernel send buffer fills and
/// no timeout surfaces through the threaded Io layer (SO_SNDTIMEO measured to
/// have no effect). The loop therefore never returned to reap ffmpeg, leaving
/// one blocked encoder per abandoned stream.
///
/// std.posix in 0.16 no longer exposes send()/write() (both moved behind Io),
/// but poll() is still there — so gate each write on POLLOUT with a deadline.
/// A vanished reader never becomes writable, so the deadline fires, the loop
/// breaks, and the encoder gets killed. POLLHUP catches a clean close instantly.
fn waitWritable(stream: std.Io.net.Stream, timeout_ms: i32) bool {
    if (@import("builtin").os.tag == .windows) return true; // no poll(); fall back to blocking
    var pfd = [_]std.posix.pollfd{.{
        .fd = stream.socket.handle,
        .events = std.posix.POLL.OUT,
        .revents = 0,
    }};
    const ready = std.posix.poll(&pfd, timeout_ms) catch return false;
    if (ready == 0) return false; // deadline hit — nobody is reading
    const bad = std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL;
    if (pfd[0].revents & bad != 0) return false;
    return true;
}

/// Put a deadline on writes to `stream`.
///
/// Without this a transcode outlives its viewer forever: when the client goes
/// away the kernel send buffer fills, `writeAll` blocks with no timeout, the
/// read/write loop never breaks, and `child.kill()` below is never reached.
/// Measured: four ffmpeg processes still pinning CPU 45s after the client was
/// killed. A bounded send turns that into a write error, which breaks the loop
/// and reaps the encoder.
fn setSendTimeout(stream: std.Io.net.Stream, secs: i32) void {
    if (@import("builtin").os.tag == .windows) return;
    const tv = std.posix.timeval{ .sec = secs, .usec = 0 };
    std.posix.setsockopt(
        stream.socket.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.SNDTIMEO,
        std.mem.asBytes(&tv),
    ) catch {};
}

/// Watchdog for one transcode. The connection thread cannot clean up after
/// itself here: when the viewer disappears the socket write blocks with no
/// usable timeout (SO_SNDTIMEO does not surface through the threaded Io layer,
/// measured), so the loop never returns to call kill(). A separate thread
/// watching write progress is the only thing that can still act.
///
/// Heap-allocated and owned by the watchdog, per the "never hand a detached
/// thread a pointer into mutable state" rule — the connection thread only sets
/// atomics on it and never frees.
const TranscodeGuard = struct {
    pid: io_g.Child.Id,
    last_progress_ms: std.atomic.Value(i64),
    done: std.atomic.Value(bool),
    /// Points at the connection thread's loop phase (0=read 1=poll 2=write
    /// 3=exited). Diagnostic only — logged when the watchdog reaps, so a stall
    /// names the blocking call instead of needing another round of guesses.
    phase: ?*const u8 = null,

    /// No write has landed in this long → nobody is watching.
    const STALL_LIMIT_MS: i64 = 60_000;

    fn watch(self: *TranscodeGuard) void {
        while (!self.done.load(.acquire)) {
            io_g.sleep(5 * std.time.ns_per_s);
            if (self.done.load(.acquire)) break;
            const idle = io_g.milliTimestamp() - self.last_progress_ms.load(.acquire);
            if (idle > STALL_LIMIT_MS) {
                // SIGTERM without reaping: the connection thread still owns the
                // Child and its kill()/wait() must stay valid.
                // SIGTERM is not enough for a pipe-blocked ffmpeg (it retries
                // the interrupted write); the connection thread's stdout close
                // is the real cure, this is the last-resort backstop.
                std.posix.kill(self.pid, std.posix.SIG.KILL) catch {};
                var msg: [96]u8 = undefined;
                const where: []const u8 = switch (if (self.phase) |ph| ph.* else 255) {
                    0 => "blocked reading ffmpeg stdout",
                    1 => "blocked in poll(POLLOUT)",
                    2 => "blocked in socket write",
                    3 => "loop already exited",
                    else => "unknown",
                };
                const m = std.fmt.bufPrint(&msg, "stalled encoder reaped — {s}", .{where}) catch "stalled encoder reaped";
                @import("../core/logs.zig").pushLog("info", "transcode", m, false);
                break;
            }
        }
        alloc.destroy(self);
    }
};

/// Transcode writes use a small chunk on purpose.
///
/// The poll(POLLOUT) gate below only bounds the write if the write actually
/// FITS once poll reports space. With the 256 KB CHUNK, poll would report
/// "writable" on a nearly-full buffer, the blocking write would fill it and
/// then park on the remainder — which is exactly how the encoder leaked at
/// +40s despite the gate. 16 KB comfortably fits any default SO_SNDBUF, so a
/// gated write completes instead of blocking, and a departed viewer reliably
/// hits the deadline.
const TRANSCODE_CHUNK = 16 * 1024;

/// How long a stalled write may block before we conclude the viewer is gone.
/// Long enough to ride out a paused player buffering, short enough that a
/// closed tab does not leave an encoder running for minutes.
const TRANSCODE_SEND_TIMEOUT_S: i32 = 20;

/// `/transcode?file=<rel>&t=<token>[&start=<seconds>]`
///
/// Cleanup note, because three obvious fixes here were wrong.
///
/// An abandoned stream used to leave ffmpeg alive forever. The instinct is
/// "the write is blocking, so bound the write" — SO_SNDTIMEO, a stall
/// watchdog, and poll(POLLOUT) gating were all tried and all MEASURED as not
/// working. Instrumenting the loop showed why: it exits perfectly fine. The
/// blocked party was ffmpeg, not us.
///
/// ffmpeg blocked writing to a full stdout pipe cannot be signalled away: it
/// takes SIGTERM, its handler sets a flag, it retries the interrupted write
/// and blocks again, never reaching the flag check. The survivor ignored even
/// a manual `kill -TERM`. Closing OUR read end is the cure — the next write
/// gets EPIPE and it exits by itself. Verified: encoder gone within 5s.
pub fn handleTranscode(stream: std.Io.net.Stream, rel: []const u8, start_s: u32) void {
    if (!haveFfmpeg()) {
        const body = "{\"error\":\"ffmpeg not installed — transcoding unavailable\"}";
        var hdr: [160]u8 = undefined;
        const h = std.fmt.bufPrint(&hdr, "HTTP/1.1 501 Not Implemented\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{body.len}) catch return;
        _ = writeAll(stream, h);
        _ = writeAll(stream, body);
        return;
    }

    var root_buf: [512]u8 = undefined;
    var path_buf: [1600]u8 = undefined;
    const path = resolveUnder(downloadsRoot(&root_buf), rel, &path_buf) orelse return send404(stream);
    _ = io_g.cwdStatFile(path) catch return send404(stream);

    var ss_buf: [16]u8 = undefined;
    const ss = std.fmt.bufPrint(&ss_buf, "{d}", .{start_s}) catch "0";

    // -ss BEFORE -i is the fast (keyframe) seek; exact-frame seeking would
    // decode everything up to the offset, which defeats the point.
    var child = io_g.Child.init(&.{
        ffmpegPath(),
        "-hide_banner", "-loglevel", "error",
        "-ss",          ss,
        "-i",           path,
        "-c:v",         "libx264",
        "-preset",      "veryfast",
        "-crf",         "23",
        "-c:a",         "aac",
        "-ac",          "2",
        "-movflags",    "frag_keyframe+empty_moov+default_base_moof",
        "-f",           "mp4",
        "pipe:1",
    }, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return send404(stream);

    // No Content-Length: the length is unknowable until the encode finishes.
    // Connection: close so the client treats EOF as end-of-stream.
    const hdr =
        "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nAccept-Ranges: none\r\n" ++
        "Cache-Control: no-store\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n";
    if (!writeAll(stream, hdr)) {
        _ = child.kill() catch {};
        return;
    }

    const buf = alloc.alloc(u8, TRANSCODE_CHUNK) catch {
        _ = child.kill() catch {};
        return;
    };
    defer alloc.free(buf);

    setSendTimeout(stream, TRANSCODE_SEND_TIMEOUT_S);

    // Arm the stall watchdog. Best-effort: if the thread cannot spawn we still
    // stream, we just lose the ability to reap a wedged encoder.
    var guard: ?*TranscodeGuard = null;
    if (child.id) |pid| {
        if (alloc.create(TranscodeGuard)) |g| {
            g.* = .{
                .pid = pid,
                .last_progress_ms = std.atomic.Value(i64).init(io_g.milliTimestamp()),
                .done = std.atomic.Value(bool).init(false),
            };
            if (std.Thread.spawn(.{}, TranscodeGuard.watch, .{g})) |th| {
                th.detach();
                guard = g;
            } else |_| {
                @import("../core/logs.zig").pushLog("error", "transcode", "watchdog thread failed to spawn", true);
                alloc.destroy(g);
            }
        } else |_| {}
    }
    defer if (guard) |g| g.done.store(true, .release);

    // Instrumented: three earlier fixes were guesses that did not work, so the
    // loop records WHICH call it is sitting in. The watchdog logs that when it
    // reaps, which is how we learn where this actually parks.
    var phase: u8 = 0; // 0=read 1=poll 2=write 3=exited
    if (guard) |g| g.phase = &phase;

    while (true) {
        phase = 0;
        const n = if (child.stdout) |*so| (io_g.read(so, buf) catch 0) else 0;
        if (n == 0) break; // encoder finished or died
        // A departed viewer must end the stream rather than park this thread:
        // gate on writability, then write.
        phase = 1;
        if (!waitWritable(stream, TRANSCODE_SEND_TIMEOUT_S * 1000)) break;
        phase = 2;
        if (!writeAll(stream, buf[0..n])) break;
        if (guard) |g| g.last_progress_ms.store(io_g.milliTimestamp(), .release);
    }
    phase = 3;

    // THE fix for the leaked encoder. Signals do not work here: ffmpeg blocked
    // writing to a full stdout pipe takes SIGTERM, its handler sets a flag, it
    // then RETRIES the interrupted write and blocks again — never reaching the
    // flag check. Measured: the survivor ignored even a manual `kill -TERM`.
    //
    // Closing our read end is what actually ends it — the next write gets
    // EPIPE and ffmpeg exits on its own. kill()/wait() afterwards just reaps.
    if (child.stdout) |*so| {
        so.close(io_g.io());
        child.stdout = null;
    }
    _ = child.kill() catch {};
    _ = child.wait() catch {};
}
