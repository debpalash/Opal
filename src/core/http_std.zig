//! std.http backend for services/reliable_fetch on Android, which ships no curl
//! binary (regression: every TMDB/Cinemeta/catalog fetch failed). Same API
//! shape as http_apple.zig. Pooled client + bundled CA + bionic DNS come from
//! http.zig / http_dns_native.zig. Decisions live in http_std_pure.zig.
//!
//! Opts handling: headers/secret_headers/user_agent/referer/range/
//! secret_basic_auth sent (credentials stripped on cross-origin redirects);
//! method/post_body/secret_post_body honored; timeout_secs = overall deadline
//! (std.http can't separate connect time, so connect_timeout_secs is not
//! applied separately); max_filesize + buffer size cap the body; https_only on
//! request and every hop; follow_redirects (max 5); cancel_epoch, abort_flag
//! and app shutdown cancel the Io task. Unsupported: `form`, `post_body_file`
//! (-> invalid_input). impersonate / use_dpi_proxy are ignored.
const std = @import("std");
const alloc = @import("alloc.zig").allocator;
const io = @import("io_global.zig");
const workers = @import("workers.zig");
const http = @import("http.zig");
const pure = @import("http_std_pure.zig");
const rf_pure = @import("../services/reliable_fetch_pure.zig");
const reliable = @import("../services/reliable_fetch.zig");

const SinkRes = enum { cont, stop, overflow, failed };
const Sink = struct {
    ctx: *anyopaque,
    f: *const fn (*anyopaque, []const u8) SinkRes,
};

const Job = struct {
    url: []const u8,
    opts: *const reliable.Opts,
    sink: Sink,
    headers_out: []u8 = &.{},
    head_len: usize = 0,
    status: u16 = 0,
    fail: ?pure.Fail = null,
    overflow: bool = false,
    stopped: bool = false,
    /// Only read the body for 2xx responses (downloads).
    body_2xx_only: bool = false,
    done: std.Io.Event = .unset,
};

fn cancelled(opts: *const reliable.Opts) bool {
    if (workers.isQuitting()) return true;
    if (opts.abort_flag) |f| if (f.load(.acquire)) return true;
    return if (opts.cancel_epoch) |e| e.fired() else false;
}

fn setFail(job: *Job, f: pure.Fail) void {
    job.fail = f;
}

fn toStd(arena: std.mem.Allocator, hs: []const rf_pure.Header) ![]const std.http.Header {
    const out = try arena.alloc(std.http.Header, hs.len);
    for (hs, out) |h, *o| o.* = .{ .name = h.name, .value = h.value };
    return out;
}

fn failOf(job: *Job, e: anyerror) void {
    job.fail = pure.failFromError(@errorName(e));
}

fn task(job: *Job) void {
    defer job.done.set(http.directStreamingClient().io);
    perform(job);
}

fn perform(job: *Job) void {
    const opts = job.opts;
    const client = http.directStreamingClient();
    var ar = std.heap.ArenaAllocator.init(alloc);
    defer ar.deinit();
    const arena = ar.allocator();

    if (opts.form.len > 0 or opts.post_body_file != null) return setFail(job, .invalid_input);
    if (opts.secret_post_body != null and opts.post_body != null) return setFail(job, .invalid_input);
    const plain_hdrs = toStd(arena, opts.headers) catch return setFail(job, .transport);
    const secret_hdrs = toStd(arena, opts.secret_headers) catch return setFail(job, .transport);
    var payload: ?[]const u8 = opts.secret_post_body orelse opts.post_body;
    var method = pure.parseMethod(opts.method, payload != null) orelse return setFail(job, .invalid_input);
    var uri = std.Uri.parse(job.url) catch return setFail(job, .invalid_input);
    const origin = uri;
    var cross = false;
    var redirects: usize = 0;
    while (true) {
        if (!pure.schemeAllowed(uri.scheme, opts.https_only)) return setFail(job, .invalid_input);
        const hdrs = pure.buildHeaders(arena, plain_hdrs, secret_hdrs, .{
            .user_agent = opts.user_agent,
            .referer = opts.referer,
            .range = opts.range,
            .basic_auth = opts.secret_basic_auth,
        }, cross) catch return setFail(job, .invalid_input);

        var req = client.request(method, uri, .{ .redirect_behavior = .unhandled, .extra_headers = hdrs }) catch |e| return failOf(job, e);
        defer {
            // Never drain an unread/oversized body just to pool the socket.
            if (req.connection) |c| if (req.reader.state != .ready) {
                c.closing = true;
            };
            req.deinit();
        }
        if (payload) |body| {
            req.sendBodyComplete(@constCast(body)) catch |e| return failOf(job, e);
        } else if (method.requestHasBody()) {
            req.sendBodyComplete(@constCast("")) catch |e| return failOf(job, e);
        } else {
            req.sendBodiless() catch |e| return failOf(job, e);
        }
        var response = req.receiveHead(&.{}) catch |e| return failOf(job, e);
        const status: u16 = @intFromEnum(response.head.status);
        job.status = status;
        const hn = @min(response.head.bytes.len, job.headers_out.len);
        @memcpy(job.headers_out[0..hn], response.head.bytes[0..hn]);
        job.head_len = hn;

        if (pure.isRedirect(status) and opts.follow_redirects) {
            if (redirects == pure.max_redirects) return setFail(job, .transport);
            const location = response.head.location orelse return setFail(job, .transport);
            const storage = arena.alloc(u8, @max(location.len, 1) + 2048) catch return setFail(job, .transport);
            @memcpy(storage[0..location.len], location);
            var s: []u8 = storage;
            const next = uri.resolveInPlace(location.len, &s) catch return setFail(job, .transport);
            var ha: [std.Io.net.HostName.max_len]u8 = undefined;
            var hb: [std.Io.net.HostName.max_len]u8 = undefined;
            const a_host = std.Io.net.HostName.fromUri(origin, &ha) catch return setFail(job, .transport);
            const b_host = std.Io.net.HostName.fromUri(next, &hb) catch return setFail(job, .transport);
            if (!pure.sameOrigin(origin.scheme, a_host.bytes, origin.port, next.scheme, b_host.bytes, next.port)) cross = true;
            if (pure.redirectDropsBody(status, method == .POST, method == .HEAD)) {
                method = .GET;
                payload = null;
            }
            uri = next;
            redirects += 1;
            continue;
        }
        if (job.body_2xx_only and (status < 200 or status >= 300)) return;
        if (status == 204 or status == 304 or method == .HEAD) return;

        const DecodeBuffers = struct {
            transfer: [16 * 1024]u8,
            history: [std.compress.flate.max_window_len]u8,
            state: std.http.Decompress,
        };
        const compressed = switch (response.head.content_encoding) {
            .identity => false,
            .gzip, .deflate => true,
            else => return setFail(job, .transport),
        };
        const scratch = alloc.create(DecodeBuffers) catch return setFail(job, .transport);
        defer alloc.destroy(scratch);
        const reader = if (compressed)
            response.readerDecompressing(&scratch.transfer, &scratch.state, &scratch.history)
        else
            response.reader(&scratch.transfer);
        while (true) {
            const chunk = reader.peekGreedy(1) catch |e| switch (e) {
                error.EndOfStream => return,
                error.ReadFailed => {
                    if (req.connection) |c| c.closing = true;
                    return setFail(job, .transport);
                },
            };
            const n = chunk.len;
            switch (job.sink.f(job.sink.ctx, chunk)) {
                .cont => reader.toss(n),
                .stop => {
                    job.stopped = true;
                    return;
                },
                .overflow => {
                    job.overflow = true;
                    return;
                },
                .failed => return setFail(job, .transport),
            }
        }
    }
}

/// Run `job` as a cancellable Io task, polling external cancellation and the
/// deadline. Returns the failure class, or null when the task finished.
fn run(job: *Job, deadline_ms: i64) ?pure.Fail {
    const client = http.directStreamingClient();
    const start = io.monotonicMilliTimestamp();
    var t = client.io.concurrent(task, .{job}) catch return .transport;
    while (!job.done.isSet()) {
        const stop: ?pure.Fail = if (cancelled(job.opts)) .cancelled else if (io.monotonicMilliTimestamp() - start >= deadline_ms) .timed_out else null;
        if (stop) |f| {
            _ = t.cancel(client.io);
            return f;
        }
        job.done.waitTimeout(client.io, .{ .duration = .{ .raw = .fromMilliseconds(5), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => {
                _ = t.cancel(client.io);
                return .cancelled;
            },
        };
    }
    t.await(client.io);
    return job.fail;
}

fn toFailure(f: pure.Fail) reliable.Failure {
    return switch (f) {
        .transport => .transport,
        .timed_out => .timed_out,
        .cancelled => .cancelled,
        .invalid_input => .invalid_input,
    };
}

// ── request ───────────────────────────────────────────────

const BufSink = struct {
    body: []u8,
    cap: usize,
    filled: usize = 0,
    fn put(p: *anyopaque, bytes: []const u8) SinkRes {
        const self: *BufSink = @ptrCast(@alignCast(p));
        const room = self.cap - self.filled;
        const n = @min(room, bytes.len);
        @memcpy(self.body[self.filled..][0..n], bytes[0..n]);
        self.filled += n;
        return if (n < bytes.len) .overflow else .cont;
    }
};

pub fn request(url: []const u8, body_out: []u8, headers_out: []u8, opts: reliable.Opts) reliable.FetchResult {
    if (cancelled(&opts)) return .{ .backend = .native, .failure = .cancelled };
    if (url.len == 0 or body_out.len == 0) return .{ .backend = .native, .failure = .invalid_input };
    var bs: BufSink = .{ .body = body_out, .cap = pure.bodyCap(body_out.len, opts.max_filesize) };
    var job: Job = .{ .url = url, .opts = &opts, .sink = .{ .ctx = &bs, .f = BufSink.put }, .headers_out = headers_out };
    const started = io.monotonicMilliTimestamp();
    const fail = run(&job, pure.deadlineMs(opts.timeout_secs));
    var res: reliable.FetchResult = .{
        .backend = .native,
        .status = job.status,
        .latency_ms = @intCast(@max(0, io.monotonicMilliTimestamp() - started)),
        .headers = headers_out[0..job.head_len],
    };
    if (fail) |f| {
        res.failure = toFailure(f);
        res.headers = "";
        return res;
    }
    switch (pure.bodyOutcome(bs.filled, job.overflow, opts.keep_head_on_overflow)) {
        .ok => res.body = body_out[0..bs.filled],
        .empty => res.failure = .empty,
        .truncated_fail => res.failure = .truncated,
        .truncated_head => {
            const head = rf_pure.headPrefix(body_out[0..bs.filled], bs.filled);
            res.body = body_out[0..head.len];
            res.truncated = true;
            if (head.len == 0) res.failure = .empty;
        },
    }
    return res;
}

// ── download ──────────────────────────────────────────────

const FileSink = struct {
    file: std.Io.File,
    written: u64 = 0,
    max: ?u64,
    fn put(p: *anyopaque, bytes: []const u8) SinkRes {
        const self: *FileSink = @ptrCast(@alignCast(p));
        if (self.max) |m| if (self.written + bytes.len > m) return .overflow;
        io.writeAll(self.file, bytes) catch return .failed;
        self.written += bytes.len;
        return .cont;
    }
};

/// Atomic `<dest>.part` -> `dest`, like the curl path; dest untouched on failure.
pub fn download(url: []const u8, dest_path: []const u8, opts: reliable.Opts) reliable.DownloadResult {
    if (cancelled(&opts)) return .{ .failure = .cancelled };
    var tmp_buf: [1100]u8 = undefined;
    if (url.len == 0) return .{ .failure = .invalid_input };
    const tmp = rf_pure.downloadTempPath(&tmp_buf, dest_path) orelse return .{ .failure = .invalid_input };
    const file = io.cwdCreateFile(tmp, .{ .truncate = true }) catch return .{ .failure = .transport };
    var fs: FileSink = .{ .file = file, .max = opts.max_filesize };
    var hdr: [16 * 1024]u8 = undefined;
    var job: Job = .{ .url = url, .opts = &opts, .sink = .{ .ctx = &fs, .f = FileSink.put }, .headers_out = &hdr, .body_2xx_only = true };
    const fail = run(&job, pure.deadlineMs(opts.timeout_secs));
    io.closeFile(file);
    const result: reliable.DownloadResult = .{
        .status = job.status,
        .failure = if (fail) |f| toFailure(f) else if (job.overflow) .truncated else .none,
    };
    if (!result.ok()) {
        io.cwdDeleteFile(tmp) catch {};
        return result;
    }
    std.Io.Dir.rename(std.Io.Dir.cwd(), tmp, std.Io.Dir.cwd(), dest_path, io.io()) catch {
        io.cwdDeleteFile(tmp) catch {};
        return .{ .status = job.status, .failure = .transport };
    };
    return result;
}

// ── stream ────────────────────────────────────────────────

pub fn stream(url: []const u8, opts: reliable.Opts, ctx: anytype, comptime onLine: fn (@TypeOf(ctx), []const u8) bool) reliable.StreamResult {
    if (cancelled(&opts)) return .{ .backend = .native, .failure = .cancelled };
    if (url.len == 0 or opts.max_line_bytes == 0) return .{ .backend = .native, .failure = .invalid_input };
    const line_buf = alloc.alloc(u8, opts.max_line_bytes) catch return .{ .backend = .native, .failure = .transport };
    defer alloc.free(line_buf);
    const S = struct {
        decoder: rf_pure.LineDecoder,
        ctx: @TypeOf(ctx),
        total: usize = 0,
        max: usize,
        fn put(p: *anyopaque, bytes: []const u8) SinkRes {
            const self: *@This() = @ptrCast(@alignCast(p));
            self.total += bytes.len;
            if (self.total > self.max) return .overflow;
            return if (self.decoder.feed(bytes, self.ctx, onLine)) .cont else .stop;
        }
    };
    var s: S = .{ .decoder = .{ .buf = line_buf, .phase = .body }, .ctx = ctx, .max = opts.max_stream_bytes };
    var hdr: [16 * 1024]u8 = undefined;
    var job: Job = .{ .url = url, .opts = &opts, .sink = .{ .ctx = &s, .f = S.put }, .headers_out = &hdr };
    const started = io.monotonicMilliTimestamp();
    const fail = run(&job, pure.deadlineMs(opts.timeout_secs));
    const ok_end = fail == null and !job.stopped and !job.overflow;
    _ = s.decoder.finish("\x00opal-no-marker", ok_end, ctx, onLine);
    var r: reliable.StreamResult = .{
        .status = job.status,
        .latency_ms = @intCast(@max(0, io.monotonicMilliTimestamp() - started)),
        .backend = .native,
        .stopped = job.stopped,
        .lines = s.decoder.lines,
        .truncated_lines = s.decoder.truncated_lines,
    };
    r.failure = if (job.stopped) .none else if (fail) |f| toFailure(f) else if (job.overflow) .truncated else if (s.decoder.lines == 0) .empty else .none;
    return r;
}
