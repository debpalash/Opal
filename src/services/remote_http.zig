//! Small HTTP/JSON primitives shared by the remote API feature modules.
//!
//! This module deliberately knows nothing about routes or application state.
//! Keeping wire-format details here lets each feature handler expose one small
//! `handle(...)` seam without copying response, query, or escaping logic.

const std = @import("std");
const io_g = @import("../core/io_global.zig");
const body_pure = @import("remote_body_pure.zig");

const RESPONSE_WRITE_TIMEOUT_S: i64 = 5;

fn writeResponse(stream: std.Io.net.Stream, data: []const u8) !void {
    try io_g.streamWriteAll(stream, data);
}

const WriteEvent = union(enum) {
    write: anyerror!void,
    deadline: std.Io.Cancelable!void,
};

/// Bound ordinary API writes so one authenticated client that stops reading
/// cannot pin a connection worker indefinitely. No application-state lock is
/// held while this function runs.
fn writeTimed(stream: std.Io.net.Stream, data: []const u8) bool {
    var events: [2]WriteEvent = undefined;
    var select = std.Io.Select(WriteEvent).init(io_g.io(), &events);
    defer select.cancelDiscard();
    select.concurrent(.write, writeResponse, .{ stream, data }) catch return false;
    select.concurrent(.deadline, waitResponseDeadline, .{}) catch return false;
    return switch (select.await() catch return false) {
        .write => |result| if (result) true else |_| false,
        .deadline => |result| blk: {
            _ = result catch {};
            @import("../core/logs.zig").pushLog("warn", "remote", "API response write timed out", false);
            break :blk false;
        },
    };
}

fn waitResponseDeadline() std.Io.Cancelable!void {
    return std.Io.Timeout.sleep(.{ .duration = .{
        .clock = .awake,
        .raw = .fromSeconds(RESPONSE_WRITE_TIMEOUT_S),
    } }, io_g.io());
}

pub fn sendJson(stream: std.Io.net.Stream, json: []const u8) void {
    sendJsonExtra(stream, "200 OK", json, "");
}

/// JSON response with caller-supplied, compile-time/trusted response headers.
/// Used for browser session cookies; provider/request data must never enter
/// `extra_headers`.
pub fn sendJsonExtra(stream: std.Io.net.Stream, status: []const u8, json: []const u8, extra_headers: []const u8) void {
    var header: [768]u8 = undefined;
    const h = std.fmt.bufPrint(&header, "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nCache-Control: no-store\r\n{s}Content-Length: {d}\r\n\r\n", .{ status, extra_headers, json.len }) catch return;
    if (!writeTimed(stream, h)) return;
    _ = writeTimed(stream, json);
}

pub fn sendJsonStatus(stream: std.Io.net.Stream, status: []const u8, json: []const u8) void {
    sendJsonExtra(stream, status, json, "");
}

/// Standards-compliant throttling response. `Retry-After` is expressed as
/// whole seconds and always at least one so clients never busy-loop on a zero.
pub fn sendRateLimited(stream: std.Io.net.Stream, retry_after_raw: i64, json: []const u8) void {
    const retry_after: u64 = @intCast(@max(@as(i64, 1), retry_after_raw));
    var header: [320]u8 = undefined;
    const h = std.fmt.bufPrint(
        &header,
        "HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nRetry-After: {d}\r\nCache-Control: no-store\r\nContent-Length: {d}\r\n\r\n",
        .{ retry_after, json.len },
    ) catch return;
    if (!writeTimed(stream, h)) return;
    _ = writeTimed(stream, json);
}

pub fn asciiEqualIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        const al = if (ac >= 'A' and ac <= 'Z') ac + 32 else ac;
        const bl = if (bc >= 'A' and bc <= 'Z') bc + 32 else bc;
        if (al != bl) return false;
    }
    return true;
}

/// Parse the body length from a complete HTTP/1 header block. Duplicate
/// lengths and every Transfer-Encoding are rejected rather than creating an
/// ambiguous request boundary. Opal implements only fixed Content-Length
/// framing; accepting even `identity` here creates divergent proxy behavior.
fn requestContentLength(headers: []const u8) !usize {
    var found: ?usize = null;
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next(); // request line
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.MalformedHeader;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (asciiEqualIgnoreCase(name, "content-length")) {
            if (found != null) return error.DuplicateContentLength;
            found = std.fmt.parseInt(usize, value, 10) catch return error.InvalidContentLength;
        } else if (asciiEqualIgnoreCase(name, "transfer-encoding")) {
            return error.UnsupportedTransferEncoding;
        }
    }
    return found orelse 0;
}

const HEADER_READ_TIMEOUT_S: i64 = 5;
const BODY_READ_TIMEOUT_S: i64 = 10;

const HeaderRead = struct {
    used: usize,
    header_end: usize,
};

fn readHeaderRaw(reader: *std.Io.net.Stream.Reader, buf: []u8) !?HeaderRead {
    var used: usize = 0;
    while (used < buf.len) {
        var vec: [1][]u8 = .{buf[used..]};
        const n = reader.interface.readVec(&vec) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };
        if (n == 0) return null;
        used += n;
        if (std.mem.indexOf(u8, buf[0..used], "\r\n\r\n")) |header_end|
            return .{ .used = used, .header_end = header_end };
    }
    return error.RequestTooLarge;
}

fn readBodyRaw(reader: *std.Io.net.Stream.Reader, buf: []u8, used_start: usize, required: usize) !?usize {
    var used = used_start;
    if (used >= required) return required;
    while (used < required) {
        // Stop at the declared boundary. This server closes after one request,
        // so bytes beyond Content-Length are never interpreted as a second one.
        var vec: [1][]u8 = .{buf[used..required]};
        const n = reader.interface.readVec(&vec) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };
        if (n == 0) return null;
        used += n;
    }
    return required;
}

fn waitReadPhase(seconds: i64) std.Io.Cancelable!void {
    return std.Io.Timeout.sleep(.{ .duration = .{
        .clock = .awake,
        .raw = .fromSeconds(seconds),
    } }, io_g.io());
}

const HeaderEvent = union(enum) {
    read: anyerror!?HeaderRead,
    deadline: std.Io.Cancelable!void,
};

fn readHeaderTimed(reader: *std.Io.net.Stream.Reader, buf: []u8) !?HeaderRead {
    var events: [2]HeaderEvent = undefined;
    var select = std.Io.Select(HeaderEvent).init(io_g.io(), &events);
    defer select.cancelDiscard();
    select.concurrent(.read, readHeaderRaw, .{ reader, buf }) catch return error.SystemResources;
    select.concurrent(.deadline, waitReadPhase, .{HEADER_READ_TIMEOUT_S}) catch return error.SystemResources;
    return switch (try select.await()) {
        .read => |result| try result,
        .deadline => |result| {
            try result;
            return error.RequestTimeout;
        },
    };
}

const BodyEvent = union(enum) {
    read: anyerror!?usize,
    deadline: std.Io.Cancelable!void,
};

fn readBodyTimed(reader: *std.Io.net.Stream.Reader, buf: []u8, used: usize, required: usize) !?usize {
    var events: [2]BodyEvent = undefined;
    var select = std.Io.Select(BodyEvent).init(io_g.io(), &events);
    defer select.cancelDiscard();
    select.concurrent(.read, readBodyRaw, .{ reader, buf, used, required }) catch return error.SystemResources;
    select.concurrent(.deadline, waitReadPhase, .{BODY_READ_TIMEOUT_S}) catch return error.SystemResources;
    return switch (try select.await()) {
        .read => |result| try result,
        .deadline => |result| {
            try result;
            return error.RequestTimeout;
        },
    };
}

/// Read exactly one bounded HTTP request with independent total deadlines for
/// the header and declared body. A slow drip cannot reset either clock and
/// occupy one of the fixed connection slots indefinitely.
pub fn readRequest(stream: std.Io.net.Stream, buf: []u8) !?[]const u8 {
    const req = (try readRequestImpl(stream, buf, null)) orelse return null;
    return req.bytes;
}

/// A request read by `readRequestGrow`. `bytes` is the whole request (head and
/// body). When the body did not fit the caller's buffer it lives on the heap in
/// `owned`; the caller frees it with the allocator it passed in.
pub const Request = struct {
    bytes: []const u8,
    owned: ?[]u8 = null,
};

/// Lets one route accept a body larger than the fixed buffer.
pub const Grow = struct {
    allocator: std.mem.Allocator,
    /// Called only when the declared request would not fit, with the head that
    /// was already read (request line and headers, through the blank line). It
    /// must authenticate the caller as well as match the route: returning true
    /// makes the server allocate up to `remote_body_pure.GROW_MAX_BODY`.
    gate: *const fn (head: []const u8) bool,
};

/// `readRequest` plus an opt-in for one route to send up to 64 KB. The head must
/// still fit `buf`; only the body can spill to the heap, and only when
/// `grow.gate` approves the head. Everything else still gets RequestTooLarge.
pub fn readRequestGrow(stream: std.Io.net.Stream, buf: []u8, grow: Grow) !?Request {
    return readRequestImpl(stream, buf, grow);
}

fn readRequestImpl(stream: std.Io.net.Stream, buf: []u8, grow: ?Grow) !?Request {
    var reader_buf: [1024]u8 = undefined;
    var reader = stream.reader(io_g.io(), &reader_buf);
    const header = (try readHeaderTimed(&reader, buf)) orelse return null;
    const body_len = try requestContentLength(buf[0..header.header_end]);
    const head_len = header.header_end + 4;
    const required = std.math.add(usize, head_len, body_len) catch
        return error.RequestTooLarge;
    const gate_ok = if (grow) |g| required > buf.len and g.gate(buf[0..head_len]) else false;
    switch (body_pure.plan(buf.len, header.header_end, body_len, gate_ok)) {
        .too_large => return error.RequestTooLarge,
        .fits => {
            // Critically, equality is valid. The old loop returned RequestTooLarge
            // whenever a correctly framed request occupied the entire 4096-byte cap.
            if (header.used >= required) return .{ .bytes = buf[0..required] };
            const complete = (try readBodyTimed(&reader, buf, header.used, required)) orelse return null;
            return .{ .bytes = buf[0..complete] };
        },
        .grow => {
            const heap = try grow.?.allocator.alloc(u8, required);
            errdefer grow.?.allocator.free(heap);
            @memcpy(heap[0..header.used], buf[0..header.used]);
            const complete = (try readBodyTimed(&reader, heap, header.used, required)) orelse {
                grow.?.allocator.free(heap);
                return null;
            };
            return .{ .bytes = heap[0..complete], .owned = heap };
        },
    }
}

pub fn requireMethod(stream: std.Io.net.Stream, actual: []const u8, expected: []const u8) bool {
    if (std.mem.eql(u8, actual, expected)) return true;
    var body_buf: [96]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "{{\"error\":\"method must be {s}\"}}", .{expected}) catch
        "{\"error\":\"method not allowed\"}";
    sendJsonStatus(stream, "405 Method Not Allowed", body);
    return false;
}

pub fn queryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        var kv = std.mem.splitScalar(u8, pair, '=');
        const k = kv.next() orelse continue;
        const v = kv.next() orelse continue;
        if (std.mem.eql(u8, k, key)) return v;
    }
    return null;
}

pub fn urlDecode(src: []const u8, buf: []u8) ?[]const u8 {
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len and o < buf.len) {
        if (src[i] == '%' and i + 2 < src.len) {
            buf[o] = std.fmt.parseInt(u8, src[i + 1 .. i + 3], 16) catch {
                buf[o] = src[i];
                i += 1;
                o += 1;
                continue;
            };
            i += 3;
            o += 1;
        } else if (src[i] == '+') {
            buf[o] = ' ';
            i += 1;
            o += 1;
        } else {
            buf[o] = src[i];
            i += 1;
            o += 1;
        }
    }
    if (o == 0) return null;
    return buf[0..o];
}

pub fn formParam(body: []const u8, query: []const u8, key: []const u8, out: []u8) ?[]const u8 {
    const raw = queryParam(body, key) orelse queryParam(query, key) orelse return null;
    return urlDecode(raw, out) orelse raw;
}

/// Write the contents of one JSON string (without surrounding quotes).
pub fn writeJsonString(w: *std.Io.Writer, value: []const u8) void {
    for (value) |ch| switch (ch) {
        '"' => w.writeAll("\\\"") catch return,
        '\\' => w.writeAll("\\\\") catch return,
        '\n' => w.writeAll("\\n") catch return,
        '\r' => w.writeAll("\\r") catch return,
        '\t' => w.writeAll("\\t") catch return,
        0x08 => w.writeAll("\\b") catch return,
        0x0c => w.writeAll("\\f") catch return,
        else => {
            if (ch < 0x20) {
                w.print("\\u{x:0>4}", .{ch}) catch return;
            } else {
                w.writeByte(ch) catch return;
            }
        },
    };
}

test "query and URL helpers stay bounded" {
    try std.testing.expectEqualStrings("two", queryParam("one=1&name=two", "name").?);
    var out: [16]u8 = undefined;
    try std.testing.expectEqualStrings("a b/c", urlDecode("a+b%2Fc", &out).?);
    var form: [16]u8 = undefined;
    try std.testing.expectEqualStrings("body value", formParam("key=body+value", "key=query", "key", &form).?);
}

test "JSON string writer escapes control characters" {
    var out: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    writeJsonString(&w, "a\"b\n");
    try std.testing.expectEqualStrings("a\\\"b\\n", out[0..w.end]);
}
