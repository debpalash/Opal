//! Fetching pages through the user's paired browser: the runtime half.
//!
//! The rules (what may be queued, how long it lives, who may answer, what a
//! result may be) are in browser_fetch_pure.zig. This file owns the lock, the
//! clock, the heap copy of an answer and the blocking wait.
//!
//! Transport (docs/browser-integration.md, section 14): the extension long-polls
//! `GET /api/browser/jobs`, and answers with `POST /api/browser/jobs/<id>`. A
//! caller of `fetch` blocks on its own thread (a connection thread or a scraper
//! worker, never the UI thread) until the answer, the deadline or cancellation.

const std = @import("std");
const io = @import("../core/io_global.zig");
const sync = @import("../core/sync.zig");
const alloc = @import("../core/alloc.zig").allocator;
const pure = @import("browser_fetch_pure.zig");
const bounded_process = @import("../core/bounded_process.zig");

var mutex: sync.Mutex = .{};
var queue: pure.Queue = .{};

const Answer = struct {
    id: u32 = 0,
    outcome: pure.Outcome = .{},
    body: ?[]u8 = null,
};
var answers: [pure.MAX_QUEUE]Answer = [_]Answer{.{}} ** pure.MAX_QUEUE;

pub const Fetched = struct {
    outcome: pure.Outcome,
    /// Owned by the caller: free with `freeBody`.
    body: []u8,
};

pub const Result = union(enum) {
    ok: Fetched,
    /// The browser answered with a refusal or a failure.
    failed: pure.Code,
    no_browser,
    busy,
    bad_request,
    cancelled,
};

pub fn freeBody(body: []u8) void {
    alloc.free(body);
}

fn dropAnswerLocked(id: u32) void {
    for (&answers) |*a| {
        if (a.id != id) continue;
        if (a.body) |b| alloc.free(b);
        a.* = .{};
    }
}

pub fn connected() bool {
    mutex.lock();
    defer mutex.unlock();
    return pure.connected(&queue, io.timestamp());
}

pub fn epochCancelled(epoch: ?bounded_process.CancelEpoch) bool {
    const token = epoch orelse return false;
    return switch (token) {
        .epoch32 => |e| e.value.load(.acquire) != e.expected,
        .epoch64 => |e| e.value.load(.acquire) != e.expected,
    };
}

/// Queue a request and wait for the browser's answer. Blocks up to the job's
/// deadline (90 s when the user may be asked, 40 s when not).
pub fn fetch(spec: pure.Spec, cancel_epoch: ?bounded_process.CancelEpoch) Result {
    mutex.lock();
    const id = pure.submit(&queue, io.timestamp(), spec) catch |e| {
        mutex.unlock();
        return switch (e) {
            error.NoBrowser => .no_browser,
            error.Full => .busy,
            error.BadRequest => .bad_request,
        };
    };
    mutex.unlock();

    while (true) {
        io.sleep(50 * std.time.ns_per_ms);
        const cancelled = epochCancelled(cancel_epoch);
        mutex.lock();
        defer mutex.unlock();
        for (&answers) |*a| {
            if (a.id != id) continue;
            const outcome = a.outcome;
            const body = a.body;
            a.* = .{};
            pure.release(&queue, id);
            if (!outcome.ok) {
                if (body) |b| alloc.free(b);
                return .{ .failed = outcome.code };
            }
            return .{ .ok = .{ .outcome = outcome, .body = body orelse return .{ .failed = .network } } };
        }
        pure.expire(&queue, io.timestamp());
        if (cancelled) {
            pure.release(&queue, id);
            return .cancelled;
        }
        // The slot is gone with no answer: the deadline passed.
        if (pure.stateOf(&queue, id) == .free) return .{ .failed = .timeout };
    }
}

/// A polling browser asks for work. Holds the request open up to `wait_s`
/// (capped), returns a copy of the oldest pending job or null.
pub fn poll(browser_id: i64, wait_s: i64, out: *pure.Job) bool {
    const wait = std.math.clamp(wait_s, 0, pure.POLL_MAX_WAIT_S);
    const started = io.timestamp();
    while (true) {
        {
            mutex.lock();
            defer mutex.unlock();
            const now = io.timestamp();
            pure.noteSeen(&queue, now);
            if (pure.claim(&queue, now, browser_id)) |job| {
                out.* = job.*;
                return true;
            }
        }
        if (io.timestamp() - started >= wait) return false;
        io.sleep(100 * std.time.ns_per_ms);
    }
}

pub const CompleteResult = union(enum) {
    ok,
    bad_result: pure.ResultError,
    no_such_job,
    not_yours,
    expired,
    unavailable,
};

/// The browser's answer. `query` carries the metadata and `body` the raw page text.
pub fn complete(browser_id: i64, id: u32, query: []const u8, body: []const u8) CompleteResult {
    const outcome = pure.parseResult(query, body) catch |e| return .{ .bad_result = e };
    const copy: ?[]u8 = if (outcome.ok) (alloc.dupe(u8, body) catch return .unavailable) else null;

    mutex.lock();
    defer mutex.unlock();
    pure.finish(&queue, io.timestamp(), id, browser_id) catch |e| {
        if (copy) |c| alloc.free(c);
        return switch (e) {
            error.NoSuchJob => .no_such_job,
            error.NotYours => .not_yours,
            error.Expired => .expired,
        };
    };
    for (&answers) |*a| {
        if (a.id != 0) continue;
        a.* = .{ .id = id, .outcome = outcome, .body = copy };
        return .ok;
    }
    // Cannot happen (as many answers as jobs); never leak if it does.
    if (copy) |c| alloc.free(c);
    pure.release(&queue, id);
    return .unavailable;
}

// ── The scraper's use of it ────────────────────────────────────────────────

pub const Text = struct {
    body: []const u8,
    status: u16,
};

const DENIED_SLOTS = 8;
const DENIED_TTL_S: i64 = 120;
const Denied = struct { hash: u64 = 0, until: i64 = 0 };
var denied: [DENIED_SLOTS]Denied = [_]Denied{.{}} ** DENIED_SLOTS;
var denied_next: usize = 0;

fn hostHash(url: []const u8) u64 {
    var buf: [256]u8 = undefined;
    const h = pure.authorityOf(url);
    const n = @min(h.len, buf.len);
    return std.hash.Wyhash.hash(0x6f70616c, std.ascii.lowerString(buf[0..n], h[0..n]));
}

fn recentlyDenied(url: []const u8) bool {
    const h = hostHash(url);
    const now = io.timestamp();
    mutex.lock();
    defer mutex.unlock();
    for (denied) |d| if (d.hash == h and d.until > now) return true;
    return false;
}

fn rememberDenied(url: []const u8) void {
    const h = hostHash(url);
    mutex.lock();
    defer mutex.unlock();
    denied[denied_next % DENIED_SLOTS] = .{ .hash = h, .until = io.timestamp() + DENIED_TTL_S };
    denied_next +%= 1;
}

/// Ask the paired browser for `url` on behalf of a scraper, without ever
/// prompting the user: a host the user has not allowed answers "origin not
/// allowed" at once and the caller falls back to the old bridge. Private-network
/// targets are never sent. Returns null for every kind of failure.
pub fn fetchText(url: []const u8, post_body: ?[]const u8, out_buf: []u8, cancel_epoch: ?bounded_process.CancelEpoch) ?Text {
    if (!connected()) return null;
    pure.validateTarget(url) catch return null;
    if (pure.isPrivateTarget(url)) return null;
    if (recentlyDenied(url)) return null;
    const spec: pure.Spec = .{
        .url = url,
        .method = if (post_body != null) .post else .get,
        .body = post_body orelse "",
        .prompt = false,
    };
    switch (fetch(spec, cancel_epoch)) {
        .ok => |f| {
            defer freeBody(f.body);
            const n = @min(f.body.len, out_buf.len);
            @memcpy(out_buf[0..n], f.body[0..n]);
            return .{ .body = out_buf[0..n], .status = f.outcome.status };
        },
        .failed => |code| {
            if (code == .origin_not_allowed or code == .private_target) rememberDenied(url);
            return null;
        },
        else => return null,
    }
}
