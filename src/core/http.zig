const std = @import("std");
const builtin = @import("builtin");
const logs = @import("logs.zig");
const alloc = @import("alloc.zig");
const io_global = @import("io_global.zig");
const sync = @import("sync.zig");

// ══════════════════════════════════════════════════════════
// Opal v3 — Native HTTP Client (no curl)
//
// Replaces curl child process with std.http.Client.
// Benefits:
// - Connection reuse: one process-global keep-alive client, so warm hosts
//   skip the TCP+TLS handshake (previously a fresh Client was built AND
//   destroyed on EVERY call — the "reuse" was a lie).
// - ~100x less overhead for small requests
// - Proxy support via std.http.Client config
//
// The shared client is safe to use CONCURRENTLY from many worker threads:
// std.http.Client owns an internal ConnectionPool guarded by its own Io.Mutex,
// so requests are pooled without being serialized. Do NOT wrap it in an
// external mutex — that would serialize the parallel resolver/poster fetches.
//
// Every fetch is bounded by a stall watchdog (see Watchdog) so a source that
// accepts TCP then goes silent can't hang a worker forever (which used to leave
// the caller's in-flight latch stuck and the route permanently empty).
// ══════════════════════════════════════════════════════════

pub const HttpOptions = struct {
    timeout_secs: u8 = 10,
    user_agent: []const u8 = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0",
    referer: ?[]const u8 = null,
    max_response: usize = 256 * 1024, // 256KB default
    accept: ?[]const u8 = null,
    method: std.http.Method = .GET,
    payload: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    auth_header: ?[]const u8 = null,
};

pub const HttpResponse = struct {
    body: []u8,
    len: usize,
    ok: bool,
    
    pub fn deinit(self: *HttpResponse) void {
        _ = self;
        // body points into caller's buffer, no-op
    }
};

// ── Shared keep-alive client ──────────────────────────────
// A single process-global std.http.Client, created lazily on first fetch. It
// is NEVER deinit()'d during runtime — connections stay pooled for the process
// lifetime (that's the whole point of keep-alive). Concurrent `request()` calls
// from many threads are safe: the client's internal ConnectionPool has its own
// Io.Mutex. Freed once at shutdown via `deinit()` to keep the DebugAllocator's
// "0 memory leaks" gate clean.
var g_client: std.http.Client = undefined;
var client_ready = std.atomic.Value(bool).init(false);
var client_init_lock: sync.Mutex = .{};

fn sharedClient() *std.http.Client {
    if (client_ready.load(.acquire)) return &g_client;
    // Slow path: build it once. The init-once mutex only guards CONSTRUCTION,
    // not requests, so two first-callers can't both build a client, but warm
    // callers never touch the lock.
    client_init_lock.lock();
    defer client_init_lock.unlock();
    if (client_ready.load(.acquire)) return &g_client; // lost the race — already built
    const io = io_global.io();
    g_client = .{ .allocator = alloc.allocator, .io = io };
    // Zig 0.16's TLS path reads `client.now.?` for cert-validity checks; it is
    // null by default and panics the moment a request negotiates TLS (e.g. an
    // http→https redirect on a poster fetch). Seed it with the realtime clock.
    // One seed suffices: cert-validity windows are months/years, and the std
    // TLS path re-rescans the CA bundle on demand. (Refreshing it per-fetch on
    // a SHARED client would be a data race on `client.now`.)
    g_client.now = std.Io.Timestamp.now(io, .real);
    client_ready.store(true, .release);
    return &g_client;
}

/// Release the shared client at process shutdown (frees pooled connections so
/// the Debug leak report stays at 0). Call once from appDeinit, after workers
/// have stopped. Idempotent.
pub fn deinit() void {
    if (client_ready.swap(false, .acq_rel)) g_client.deinit();
}

/// Clamp the caller's requested read timeout into a sane bound: at least 1s so
/// a slow-but-alive server isn't cut off, at most 20s so no fetch can hang
/// unboundedly even when the caller passed 0 or a huge value. Pure — routed
/// through by fetch() so the shipped clamp is the tested clamp.
pub fn effectiveTimeoutSecs(requested: u8) u8 {
    return std.math.clamp(requested, @as(u8, 1), @as(u8, 20));
}

const is_windows = builtin.os.tag == .windows;

// ── Stall watchdog ────────────────────────────────────────
// Bounds a single request. std.http's request()/receiveHead()/reader expose NO
// per-request deadline in 0.16, and the Threaded Io backend does BLOCKING
// readv() syscalls where EAGAIN (SO_RCVTIMEO) and EBADF (closing the fd) are
// both `errnoBug` → panic. The one safe way to unblock a stalled read is
// shutdown(): it makes the blocked readv return 0 (EOF) via the SUCCESS path.
// So a small watchdog thread, armed with this request's socket fd, calls
// shutdown() once the deadline passes and the fetch hasn't signalled done.
// POSIX only (the shutdown/fd plumbing is libc); on Windows the shared client
// still applies but the per-request timeout is a no-op (documented follow-up).
const Watchdog = struct {
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fd: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(-1),
    timeout_ms: i64,

    fn run(self: *Watchdog) void {
        const deadline = io_global.milliTimestamp() + self.timeout_ms;
        while (!self.done.load(.acquire)) {
            const now = io_global.milliTimestamp();
            if (now >= deadline) break;
            // Poll in short steps so the happy path (fetch sets done, then
            // joins) waits at most ~5ms; over a full stall this is a few
            // thousand cheap wakeups — negligible CPU.
            const remaining = deadline - now;
            const step_ms: u64 = @intCast(@min(remaining, @as(i64, 5)));
            io_global.sleep(step_ms * 1_000_000);
        }
        if (self.done.load(.acquire)) return; // fetch finished — nothing to unblock
        const fd = self.fd.load(.acquire);
        if (fd >= 0) _ = std.c.shutdown(fd, @as(c_int, std.c.SHUT.RDWR));
    }
};

/// Fetch URL into caller-provided buffer. Returns slice of response body.
pub fn fetch(url: []const u8, buf: []u8, opts: HttpOptions) ?[]const u8 {
    // Build headers
    var headers_buf: [8]std.http.Header = undefined;
    var header_count: usize = 0;
    
    headers_buf[header_count] = .{ .name = "User-Agent", .value = opts.user_agent };
    header_count += 1;
    
    if (opts.referer) |ref| {
        headers_buf[header_count] = .{ .name = "Referer", .value = ref };
        header_count += 1;
    }
    
    if (opts.accept) |acc| {
        headers_buf[header_count] = .{ .name = "Accept", .value = acc };
        header_count += 1;
    }

    if (opts.content_type) |ct| {
        headers_buf[header_count] = .{ .name = "Content-Type", .value = ct };
        header_count += 1;
    }

    if (opts.auth_header) |auth| {
        // e.g. "Authorization: Bearer xxx" -> We construct it inside or split? 
        // We will assume auth_header provides ONLY the value and we use name="Authorization". Wait, Jellyfin uses "X-Emby-Authorization"!
        // Let's assume auth_header is the raw header line like "X-Emby-Authorization: xxx"
        if (std.mem.indexOfScalar(u8, auth, ':')) |colon| {
            headers_buf[header_count] = .{
                .name = auth[0..colon],
                .value = auth[colon + 1 ..], // Will leave leading space which std.http tolerates
            };
            header_count += 1;
        }
    }
    
    // Shared, keep-alive client (see sharedClient). Never deinit'd here.
    const client = sharedClient();

    const uri = std.Uri.parse(url) catch {
        logs.pushLog("warn", "http", "Invalid URL", true);
        return null;
    };

    // Arm the stall watchdog BEFORE connecting so it bounds the whole request.
    // It gets this request's socket fd right after connect (below) and, if the
    // deadline passes with the fetch still stuck, shutdown()s the socket so the
    // blocked read returns EOF instead of hanging the worker forever.
    var wd = Watchdog{ .timeout_ms = @as(i64, effectiveTimeoutSecs(opts.timeout_secs)) * 1000 };
    var wd_thread: ?std.Thread = null;
    if (comptime !is_windows) {
        wd_thread = std.Thread.spawn(.{}, Watchdog.run, .{&wd}) catch null;
    }
    defer {
        wd.done.store(true, .release);
        if (wd_thread) |t| t.join();
    }

    var req = client.request(opts.method, uri, .{
        .redirect_behavior = @enumFromInt(5), // Follow up to 5 redirects
        .extra_headers = headers_buf[0..header_count],
    }) catch {
        logs.pushLog("warn", "http", "HTTP connect failed", true);
        return null;
    };
    defer req.deinit();

    // Hand the watchdog this request's socket so it can unblock a stalled read.
    // (Covers the send + receiveHead + body read of the initial connection —
    // i.e. the direct source fetches that were hanging. A stall on a *new*
    // connection opened while std follows a redirect uses a different fd and is
    // not covered; the initial hop and pooled reuse are.)
    if (comptime !is_windows) {
        if (req.connection) |conn| {
            wd.fd.store(@intCast(conn.stream_reader.stream.socket.handle), .release);
        }
    }

    if (opts.payload) |payload| {
        req.sendBodyComplete(@constCast(payload)) catch return null;
    } else {
        req.sendBodiless() catch {
            logs.pushLog("warn", "http", "HTTP send failed", true);
            return null;
        };
    }
    
    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch {
        logs.pushLog("warn", "http", "HTTP receive failed", true);
        return null;
    };
    
    if (response.head.status != .ok and response.head.status != .created) {
        return null;
    }
    
    // Read body
    var transfer_buf: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    
    // Clamp the read limit to the caller's buffer — never allocate/download more
    // than we can return (a huge response otherwise allocs then gets discarded).
    const read_limit = @min(opts.max_response, buf.len);
    const body = reader.allocRemaining(alloc.allocator, std.Io.Limit.limited(read_limit)) catch {
        return null;
    };
    defer alloc.allocator.free(body);

    if (body.len < 2 or body.len > buf.len) {
        return null;
    }
    
    @memcpy(buf[0..body.len], body);
    return buf[0..body.len];
}

/// Fetch URL into heap-allocated buffer (caller must free with c_allocator).
pub fn fetchAlloc(url: []const u8, opts: HttpOptions) ?[]u8 {
    var stack_buf: [256 * 1024]u8 = undefined;
    const resp = fetch(url, &stack_buf, opts) orelse return null;
    
    const result = std.heap.c_allocator.alloc(u8, resp.len) catch return null;
    @memcpy(result, resp);
    return result;
}

/// Fetch image data via curl (raw bytes for stbi). std.http (used by fetch())
/// silently returns NULL for some image CDNs — notably `cdn.myanimelist.net`
/// (every anime poster), which curl fetches fine (verified: 200, image/jpeg).
/// The rest of the codebase already prefers curl over the fragile 0.16 std.http
/// for exactly this reason, so poster/image fetching does too. Reads the raw
/// bytes straight into `buf` (binary-safe), bounded by --connect-timeout /
/// --max-time so a dead CDN host can't stall a poster-daemon slot.
pub fn fetchImage(url: []const u8, buf: []u8) ?[]const u8 {
    if (url.len == 0 or url.len > 2048) return null;
    var child = io_global.Child.init(&.{
        "curl",              "-s",
        "-L",                "--connect-timeout",
        "3",                 "--max-time",
        "15",                "-A",
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        url,
    }, alloc.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;
    const n = if (child.stdout) |*so| io_global.readAll(so, buf) catch 0 else 0;
    _ = child.wait() catch {};
    if (n < 2) return null;
    return buf[0..n];
}

/// Simple JSON field extraction (replaces copy-pasted patterns).
pub fn jsonStr(json: []const u8, key: []const u8) ?[]const u8 {
    var kb: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&kb, "\"{s}\":", .{key}) catch return null;
    
    const idx = std.mem.indexOf(u8, json, needle) orelse return null;
    var start = idx + needle.len;
    while (start < json.len and (json[start] == ' ' or json[start] == '\t')) start += 1;
    if (start >= json.len) return null;
    
    if (json[start] == '"') {
        start += 1;
        var end = start;
        var esc = false;
        while (end < json.len) : (end += 1) {
            if (esc) { esc = false; continue; }
            if (json[end] == '\\') { esc = true; continue; }
            if (json[end] == '"') break;
        }
        return json[start..end];
    } else {
        var end = start;
        while (end < json.len and json[end] != ',' and json[end] != '}' and json[end] != ']' and json[end] != ' ') : (end += 1) {}
        return json[start..end];
    }
}

/// Extract JSON string into a fixed buffer.
pub fn jsonStrInto(json: []const u8, key: []const u8, out: []u8, out_len: *usize) void {
    if (jsonStr(json, key)) |val| {
        const n = @min(val.len, out.len);
        @memcpy(out[0..n], val[0..n]);
        out_len.* = n;
    }
}

/// URL-encode a string.
pub fn urlEncode(input: []const u8, buf: []u8) []const u8 {
    var len: usize = 0;
    for (input) |ch| {
        if (len + 3 >= buf.len) break;
        if ((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.') {
            buf[len] = ch;
            len += 1;
        } else if (ch == ' ') {
            buf[len] = '+';
            len += 1;
        } else {
            buf[len] = '%';
            buf[len + 1] = "0123456789ABCDEF"[ch >> 4];
            buf[len + 2] = "0123456789ABCDEF"[ch & 0xF];
            len += 3;
        }
    }
    return buf[0..len];
}
