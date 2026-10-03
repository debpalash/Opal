//! Native HTTP request ownership, separate from application UI/proxy setup.
//! Callers own the shared client; each fetch exclusively owns its connection
//! until its watchdog is detached. Owned Io task cancellation covers
//! DNS/connect/TLS before std.http exposes the connected request socket.
const std = @import("std");
const io = @import("io_global.zig");
const sync = @import("sync.zig");
const workers = @import("workers.zig");

pub const nativeIo = @import("http_dns_native.zig").nativeIo;

pub const Options = struct {
    timeout_secs: u8 = 10,
    cancel_epoch: ?@import("bounded_process.zig").CancelEpoch = null,
    user_agent: []const u8 = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0",
    referer: ?[]const u8 = null,
    max_response: usize = 256 * 1024,
    accept: ?[]const u8 = null,
    method: std.http.Method = .GET,
    payload: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    auth_header: ?[]const u8 = null,
    extra_headers: []const std.http.Header = &.{},
    /// Keep a non-secret byte Range across CDN redirects. Other caller
    /// headers are still stripped when the origin changes.
    preserve_range_on_redirect: bool = false,
    // Optional response status for callers that need to distinguish an HTTP
    // rejection (for example expired credentials) from transport failure.
    // Remains null if no response head was received.
    status_out: ?*?std.http.Status = null,
};

pub fn effectiveTimeoutSecs(requested: u8) u8 {
    return std.math.clamp(requested, @as(u8, 1), @as(u8, 20));
}

const max_redirects = 5;

const Watchdog = struct {
    mutex: sync.Mutex = .{},
    socket: ?std.Io.net.Stream = null,
    expired: std.atomic.Value(bool) = .init(false),
    deadline_ms: i64,

    fn attach(self: *Watchdog, stream: std.Io.net.Stream) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        // A connect that finishes after the watchdog expired must not start
        // an unguarded send/read, even when cancellation races connection completion.
        if (self.expired.load(.acquire) or workers.isQuitting() or
            io.monotonicMilliTimestamp() >= self.deadline_ms) return false;
        self.socket = stream;
        return true;
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
};

fn releaseRequest(req: *std.http.Client.Request, wd: *Watchdog) void {
    // deinit() normally drains unread bodies to enable pooling. On a rejected
    // response, oversized body, or redirect that can mean an unbounded read.
    // Preserve pooling only when the body has actually finished.
    // Decide pooling and unbind atomically against expire: a shutdown stream
    // must never slip into the shared pool between the check and unbind.
    wd.mutex.lock();
    if (req.connection) |connection| {
        if (wd.expired.load(.acquire) or req.reader.state != .ready) connection.closing = true;
    }
    wd.socket = null;
    wd.mutex.unlock();
    req.deinit();
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
    if (opts.status_out) |out| out.* = null;
    if (workers.isQuitting() or epochCancelled(opts.cancel_epoch)) return null;
    var wd: Watchdog = .{ .deadline_ms = io.monotonicMilliTimestamp() +| @as(i64, effectiveTimeoutSecs(opts.timeout_secs)) * 1000 };
    var done: std.atomic.Value(bool) = .init(false);
    // An Io task supplies cancellation context before DNS/connect/TLS begins.
    // Always join it before releasing borrowed client, buffer, headers or payload.
    var task = client.io.concurrent(fetchSignalled, .{ client, url, buf, opts, &wd, &done }) catch return null;
    while (!done.load(.acquire)) {
        if (workers.isQuitting() or epochCancelled(opts.cancel_epoch) or io.monotonicMilliTimestamp() >= wd.deadline_ms) {
            wd.expire();
            _ = task.cancel(client.io);
            return null;
        }
        io.sleep(5 * std.time.ns_per_ms);
    }
    const result = task.await(client.io);
    if (workers.isQuitting() or epochCancelled(opts.cancel_epoch) or io.monotonicMilliTimestamp() >= wd.deadline_ms) return null;
    return result;
}

fn epochCancelled(epoch: ?@import("bounded_process.zig").CancelEpoch) bool {
    const token = epoch orelse return false;
    return switch (token) {
        .epoch32 => |e| e.value.load(.acquire) != e.expected,
        .epoch64 => |e| e.value.load(.acquire) != e.expected,
    };
}

fn fetchSignalled(client: *std.http.Client, url: []const u8, buf: []u8, opts: Options, wd: *Watchdog, done: *std.atomic.Value(bool)) ?[]const u8 {
    defer done.store(true, .release);
    return fetchOwned(client, url, buf, opts, wd);
}

fn fetchOwned(client: *std.http.Client, url: []const u8, buf: []u8, opts: Options, wd: *Watchdog) ?[]const u8 {
    if (workers.isQuitting()) return null;
    if (opts.status_out) |out| out.* = null;
    var uri = std.Uri.parse(url) catch return null;
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
        defer releaseRequest(&req, wd);
        const connection = req.connection orelse return null;
        if (!wd.attach(connection.stream_reader.stream)) return null;
        if (payload) |body| {
            req.sendBodyComplete(@constCast(body)) catch return null;
        } else if (method.requestHasBody()) {
            // Empty POST/PUT remain body-bearing HTTP methods. sendBodiless
            // asserts for these methods (Plex timeline sends an empty POST).
            req.sendBodyComplete(@constCast("")) catch return null;
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
                    if (opts.preserve_range_on_redirect) {
                        for (opts.extra_headers, 0..) |header, i| {
                            if (std.ascii.eqlIgnoreCase(header.name, "Range")) {
                                extra_headers = opts.extra_headers[i .. i + 1];
                                break;
                            }
                        }
                    }
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
            .ok, .created, .accepted, .partial_content => {},
            .no_content => return buf[0..0],
            else => return null,
        }

        // Read straight into the caller's buffer. `allocRemaining` grew a heap
        // ArrayList to the full body, then we memcpy'd it into `buf` and freed
        // it again — a malloc/free plus a full second copy on every outbound
        // request, of which the resolver fans out hundreds per search.
        var transfer_buf: [16 * 1024]u8 = undefined;
        const DecodeBuffers = struct {
            transfer: [16 * 1024]u8,
            history: [std.compress.flate.max_window_len]u8,
            state: std.http.Decompress,
        };
        // The client advertises gzip/deflate. Keep the bounded decoder history
        // on the heap rather than adding it to the worker's redirect buffers.
        const compressed = switch (response.head.content_encoding) {
            .identity => false,
            .gzip, .deflate => true,
            else => return null,
        };
        const decoding = if (compressed) client.allocator.create(DecodeBuffers) catch return null else null;
        defer if (decoding) |scratch| client.allocator.destroy(scratch);
        const reader = if (decoding) |scratch|
            response.readerDecompressing(&scratch.transfer, &scratch.state, &scratch.history)
        else
            response.reader(&transfer_buf);
        const cap = @min(opts.max_response, buf.len);
        var filled: usize = 0;
        // readSliceShort returns fewer bytes than asked for only at end of
        // stream, so a 0-length read is the natural terminator.
        while (filled < cap) {
            const got = reader.readSliceShort(buf[filled..cap]) catch {
                if (req.connection) |conn| conn.closing = true;
                return null;
            };
            if (got == 0) break;
            filled += got;
        }
        // Enforce the limit on decoded bytes, including compressed expansion.
        // A full buffer is valid only if the decoded stream ends exactly here.
        if (filled == cap) {
            var extra: [1]u8 = undefined;
            const more = reader.readSliceShort(&extra) catch {
                if (req.connection) |conn| conn.closing = true;
                return null;
            };
            if (more != 0) {
                if (req.connection) |conn| conn.closing = true;
                return null;
            }
        }
        if (filled < 2) return null;
        return buf[0..filled];
    }
}
