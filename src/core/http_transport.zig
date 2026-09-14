//! Native HTTP request ownership, separate from application UI/proxy setup.
//! Callers own the shared client; each fetch exclusively owns its connection
//! until its watchdog is detached. DNS/connect/TLS setup is still delegated to
//! std.http, which does not expose a cancellable socket until request() returns.
const std = @import("std");
const builtin = @import("builtin");
const io = @import("io_global.zig");
const sync = @import("sync.zig");
const workers = @import("workers.zig");

pub const Options = struct {
    timeout_secs: u8 = 10,
    user_agent: []const u8 = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0",
    referer: ?[]const u8 = null,
    max_response: usize = 256 * 1024,
    accept: ?[]const u8 = null,
    method: std.http.Method = .GET,
    payload: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    auth_header: ?[]const u8 = null,
    extra_headers: []const std.http.Header = &.{},
    // Optional response status for callers that need to distinguish an HTTP
    // rejection (for example expired credentials) from transport failure.
    // Remains null if no response head was received.
    status_out: ?*?std.http.Status = null,
};

pub fn effectiveTimeoutSecs(requested: u8) u8 {
    return std.math.clamp(requested, @as(u8, 1), @as(u8, 20));
}

const max_redirects = 5;
var fail_watchdog_spawn_for_test = false;
var after_cleanup_for_test: ?*const fn (*Watchdog) void = null;

const Watchdog = struct {
    mutex: sync.Mutex = .{},
    socket: ?std.Io.net.Stream = null,
    done: std.atomic.Value(bool) = .init(false),
    expired: std.atomic.Value(bool) = .init(false),
    deadline_ms: i64,

    fn attach(self: *Watchdog, stream: std.Io.net.Stream) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        // A connect that finishes after the watchdog expired must not start
        // an unguarded send/read, even though connect itself cannot be cancelled.
        if (self.expired.load(.acquire) or workers.isQuitting() or
            io.monotonicMilliTimestamp() >= self.deadline_ms) return false;
        self.socket = stream;
        return true;
    }

    /// Forget the guarded socket so a late expire() cannot shutdown(2) an fd
    /// that the request is about to close or pool. (Named to avoid reading as
    /// std.Thread.detach: the watchdog thread itself is always joined.)
    fn unbindSocket(self: *Watchdog) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.socket = null;
    }

    fn expire(self: *Watchdog) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.expired.store(true, .release);
        if (self.socket) |stream| {
            // Portable socket shutdown wakes a blocked std.Io read on Windows
            // and POSIX. Closing here could instead race request cleanup or hit
            // a recycled handle, so ownership stays with the request thread.
            stream.shutdown(io.io(), .both) catch {};
        }
    }

    fn run(self: *Watchdog) void {
        while (!self.done.load(.acquire)) {
            if (workers.isQuitting() or io.monotonicMilliTimestamp() >= self.deadline_ms) {
                self.expire();
                return;
            }
            io.sleep(5 * std.time.ns_per_ms);
        }
    }
};

fn startWatchdog(wd: *Watchdog) !std.Thread {
    if (builtin.is_test and fail_watchdog_spawn_for_test) return error.ThreadQuotaExceeded;
    return workers.spawnLegacy(Watchdog.run, .{wd});
}

fn releaseRequest(req: *std.http.Client.Request, wd: *Watchdog) void {
    // deinit() normally drains unread bodies to enable pooling. On a rejected
    // response, oversized body, or redirect that can mean an unbounded read.
    // Preserve pooling only when the body has actually finished.
    if (req.connection) |connection| {
        if (req.reader.state != .ready) connection.closing = true;
    }
    // Exclude a concurrent shutdown(2) BEFORE deinit closes or pools the fd.
    // Automatic std.http redirects also release sockets internally, so fetch
    // handles redirects explicitly and uses this boundary on every hop.
    wd.unbindSocket();
    req.deinit();
    if (builtin.is_test) {
        if (after_cleanup_for_test) |hook| hook(wd);
    }
}

fn sameOrigin(a: std.Uri, b: std.Uri) bool {
    if (!std.ascii.eqlIgnoreCase(a.scheme, b.scheme)) return false;
    const default_port: u16 = if (std.ascii.eqlIgnoreCase(a.scheme, "https")) 443 else 80;
    if ((a.port orelse default_port) != (b.port orelse default_port)) return false;
    var a_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    var b_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const a_host = a.getHost(&a_buf) catch return false;
    const b_host = b.getHost(&b_buf) catch return false;
    return a_host.eql(b_host);
}

fn validHeader(name: []const u8, value: []const u8) bool {
    return name.len != 0 and std.mem.indexOfAny(u8, name, ":\r\n") == null and
        std.mem.indexOfAny(u8, value, "\r\n") == null;
}

/// Fetch into a caller-owned bounded buffer. The client must outlive the call.
/// Response reads are deadline/cancellation guarded on every desktop platform.
pub fn fetch(client: *std.http.Client, url: []const u8, buf: []u8, opts: Options) ?[]const u8 {
    if (workers.isQuitting()) return null;
    if (opts.status_out) |out| out.* = null;
    var uri = std.Uri.parse(url) catch return null;
    var wd: Watchdog = .{
        .deadline_ms = io.monotonicMilliTimestamp() +| @as(i64, effectiveTimeoutSecs(opts.timeout_secs)) * 1000,
    };
    const wd_thread = startWatchdog(&wd) catch return null;
    defer {
        wd.done.store(true, .release);
        wd_thread.join();
    }

    var method = opts.method;
    var payload = opts.payload;
    var content_type = opts.content_type;
    var auth = opts.auth_header;
    var extra_headers = opts.extra_headers;
    var referer = opts.referer;
    // Each resolved URI may borrow unchanged components from an earlier hop.
    // Keep all five buffers alive until the complete redirect chain finishes.
    var locations: [max_redirects][8 * 1024]u8 = undefined;
    var redirects: usize = 0;
    while (true) {
        if (wd.expired.load(.acquire) or workers.isQuitting()) return null;
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and
            !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return null;

        var headers: [16]std.http.Header = undefined;
        var count: usize = 0;
        headers[count] = .{ .name = "User-Agent", .value = opts.user_agent };
        count += 1;
        if (referer) |value| {
            headers[count] = .{ .name = "Referer", .value = value };
            count += 1;
        }
        if (opts.accept) |value| {
            headers[count] = .{ .name = "Accept", .value = value };
            count += 1;
        }
        if (content_type) |value| {
            headers[count] = .{ .name = "Content-Type", .value = value };
            count += 1;
        }
        if (auth) |line| {
            if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                headers[count] = .{
                    .name = line[0..colon],
                    .value = std.mem.trim(u8, line[colon + 1 ..], " \t"),
                };
                count += 1;
            }
        }
        if (count + extra_headers.len > headers.len) return null;
        for (extra_headers) |header| {
            headers[count] = header;
            count += 1;
        }
        for (headers[0..count]) |header| {
            if (!validHeader(header.name, header.value)) return null;
        }

        var req = client.request(method, uri, .{
            .redirect_behavior = .unhandled,
            .extra_headers = headers[0..count],
        }) catch return null;
        defer releaseRequest(&req, &wd);
        const connection = req.connection orelse return null;
        if (!wd.attach(connection.stream_reader.stream)) return null;
        if (payload) |body| {
            req.sendBodyComplete(@constCast(body)) catch return null;
        } else {
            req.sendBodiless() catch return null;
        }
        var response = req.receiveHead(&.{}) catch return null;
        if (opts.status_out) |out| out.* = response.head.status;
        switch (response.head.status) {
            .moved_permanently, .found, .see_other, .temporary_redirect, .permanent_redirect => {
                if (redirects == max_redirects) return null;
                const location = response.head.location orelse return null;
                var storage: []u8 = &locations[redirects];
                if (location.len == 0 or location.len > storage.len) return null;
                @memcpy(storage[0..location.len], location);
                const next = uri.resolveInPlace(location.len, &storage) catch return null;
                if (!sameOrigin(uri, next)) {
                    // Never forward server credentials or signed referring URLs
                    // to another scheme/host/port, including sibling domains.
                    auth = null;
                    referer = null;
                    extra_headers = &.{};
                }
                if ((response.head.status == .see_other and method != .HEAD) or
                    ((response.head.status == .moved_permanently or response.head.status == .found) and method == .POST))
                {
                    method = .GET;
                    payload = null;
                    content_type = null;
                }
                uri = next;
                redirects += 1;
                continue;
            },
            .ok, .created, .accepted => {},
            .no_content => return buf[0..0],
            else => return null,
        }

        var transfer_buf: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        const body = reader.allocRemaining(client.allocator, .limited(@min(opts.max_response, buf.len))) catch return null;
        defer client.allocator.free(body);
        if (body.len < 2 or body.len > buf.len) return null;
        @memcpy(buf[0..body.len], body);
        return buf[0..body.len];
    }
}
