//! Device-sync client for `library_items` (ROADMAP 6.3): pull each peer's
//! changes, push ours, and the worker + UI-thread tick behind Settings → Device
//! sync. Up to `sync_pure.MAX_PEERS` peers, each with its own cursors.
//!
//! The peer's routes live in remote_library_sync_api.zig; wire format, merge,
//! seq-paging and echo rules in library_sync_pure.zig. Peers (URL, token,
//! cursors, learned device id, status) are persisted in `state.app.lsync`
//! (config.zig).
//!
//! Threading: `syncNow` / `tick` run on the UI thread and are the only writers
//! of `state.app.lsync`. The worker gets a by-value `Job`, and publishes one
//! `Outcome` under `outcome_mutex`; `tick` folds it into state, matching each
//! result to its peer by address (never by index — a peer can be removed or
//! re-pointed mid-run).

const std = @import("std");
const state = @import("../core/state.zig");
const sync = @import("../core/sync.zig");
const workers = @import("../core/workers.zig");
const io_global = @import("../core/io_global.zig");
const logs = @import("../core/logs.zig");
const alloc = @import("../core/alloc.zig").allocator;
const reliable_fetch = @import("reliable_fetch.zig");
const store = @import("library_store.zig");
const sync_pure = @import("library_sync_pure.zig");

const RESPONSE_BYTES: usize = 256 * 1024;
const MAX_PAGES: usize = 64;
const MAX_PEERS = sync_pure.MAX_PEERS;
/// Periodic sync cadence while a peer is configured and auto-sync is on.
pub const AUTO_INTERVAL_MS: i64 = 10 * 60 * 1000;

// ── Blocking client (worker / request threads only) ─────────────────────────

const DeviceBuf = [sync_pure.DEVICE_ID_MAX]u8;

pub const PullResult = struct {
    received: usize = 0,
    applied: usize = 0,
    /// The peer's seq we are caught up to.
    cursor: i64 = 0,
    /// The peer's device id (from its payload).
    device: DeviceBuf = std.mem.zeroes(DeviceBuf),
    device_len: usize = 0,
    /// The saved cursor belonged to another store; pulled from 0 instead.
    restarted: bool = false,

    pub fn deviceId(self: *const PullResult) []const u8 {
        return self.device[0..self.device_len];
    }
};

fn authHeader(buf: []u8, token: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "Bearer {s}", .{token}) catch null;
}

fn getPage(peer: []const u8, auth: []const u8, after: i64, me: []const u8, body_buf: []u8) ?[]const u8 {
    var url_buf: [640]u8 = undefined;
    var uw = std.Io.Writer.fixed(&url_buf);
    uw.print("{s}/api/library/sync?seq={d}", .{ peer, after }) catch return null;
    if (me.len > 0) {
        uw.writeAll("&from=") catch return null;
        sync_pure.writeQueryEscaped(&uw, me) catch return null;
    }
    return reliable_fetch.fetch(url_buf[0..uw.end], body_buf, .{
        // Bearer over curl's stdin config, never argv (`ps`-visible).
        .secret_headers = &.{.{ .name = "Authorization", .value = auth }},
        .headers = &.{.{ .name = "Accept", .value = "application/json" }},
        .impersonate = false,
        .use_dpi_proxy = false,
        .follow_redirects = false,
    });
}

/// Pull every row the peer changed after its seq `since` and merge it locally
/// (applied rows are tagged with the peer's device id as origin). Blocking (one
/// curl per page); never call from the UI thread. `peer_raw` is the peer's base
/// URL, e.g. `http://192.168.1.20:41595`; `expected_device` is the id learned
/// on the last run ('' = unknown). Returns null when the first page fails; a
/// later failure returns what was merged so far with an exact resume cursor.
pub fn pull(peer_raw: []const u8, token: []const u8, since: i64, expected_device: []const u8) ?PullResult {
    const peer = sync_pure.normalizePeer(peer_raw) orelse return null;
    if (!sync_pure.validToken(token)) return null;

    const body_buf = alloc.alloc(u8, RESPONSE_BYTES) catch return null;
    defer alloc.free(body_buf);
    const rows = alloc.alloc(sync_pure.SyncRow, sync_pure.PAGE_ROWS) catch return null;
    defer alloc.free(rows);

    var auth_buf: [220]u8 = undefined;
    const auth = authHeader(&auth_buf, token) orelse return null;
    var me_buf: DeviceBuf = undefined;
    const me = store.deviceId(&me_buf);
    var res: PullResult = .{ .cursor = since };
    var at = since;
    var page: usize = 0;
    var ok_pages: usize = 0;
    while (page < MAX_PAGES) : (page += 1) {
        const json = getPage(peer, auth, at, me, body_buf) orelse {
            logs.pushLog("warn", "sync", "library pull: peer unreachable or refused", true);
            return if (ok_pages == 0) null else res;
        };
        const d = sync_pure.decodePayload(alloc, json, rows) catch {
            logs.pushLog("warn", "sync", "library pull: peer sent an invalid payload", true);
            return if (ok_pages == 0) null else res;
        };
        if (d.version < sync_pure.PROTOCOL) {
            logs.pushLog("warn", "sync", "library pull: the other device runs an older Opal - update it", true);
            return if (ok_pages == 0) null else res;
        }
        if (ok_pages == 0 and !res.restarted and sync_pure.needRestart(since, expected_device, d.deviceId(), d.next_seq)) {
            logs.pushLog("info", "sync", "library pull: the other device's library was reset - syncing from scratch", false);
            res.restarted = true;
            res.cursor = 0;
            at = 0;
            continue;
        }
        ok_pages += 1;
        if (d.device_len > 0) {
            @memcpy(res.device[0..d.device_len], d.deviceId());
            res.device_len = d.device_len;
        }
        res.received += d.count;
        res.applied += store.applySyncRows(rows[0..d.count], d.deviceId());
        // `next_seq` is exact (seq is unique per store): resume strictly after it.
        res.cursor = @max(at, d.next_seq);
        if (!d.has_more or d.next_seq <= at) break;
        at = d.next_seq;
    }
    var log_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&log_buf, "library pull: {d} rows received, {d} applied", .{ res.received, res.applied }) catch "library pull done";
    logs.pushLog("info", "sync", msg, false);
    return res;
}

pub const PushResult = struct { sent: usize = 0, applied: usize = 0, cursor: i64 = 0 };

const PushAck = struct { applied: usize = 0 };

/// The peer's device id from an empty page (for a push with no prior pull).
fn probeDevice(peer: []const u8, auth: []const u8, out: *DeviceBuf) ?[]const u8 {
    var body: [2048]u8 = undefined;
    const json = getPage(peer, auth, std.math.maxInt(i64), "", &body) orelse return null;
    var none: [0]sync_pure.SyncRow = .{};
    const d = sync_pure.decodePayload(alloc, json, &none) catch return null;
    @memcpy(out[0..d.device_len], d.deviceId());
    return out[0..d.device_len];
}

/// POST every local row with seq > `since` to the peer, in batches of at most
/// MAX_POST_ROWS rows / PUSH_MAX_BYTES bytes, skipping rows that came from the
/// peer itself (`peer_device`; probed when empty). Blocking; worker only.
/// Null when the first batch fails; a later failure returns the progress so
/// far (its cursor re-sends the failed batch next run).
pub fn push(peer_raw: []const u8, token: []const u8, since: i64, peer_device_in: []const u8) ?PushResult {
    const peer = sync_pure.normalizePeer(peer_raw) orelse return null;
    if (!sync_pure.validToken(token)) return null;

    var auth_buf: [220]u8 = undefined;
    const auth = authHeader(&auth_buf, token) orelse return null;
    var probe_buf: DeviceBuf = undefined;
    const peer_device = if (peer_device_in.len > 0) peer_device_in else (probeDevice(peer, auth, &probe_buf) orelse {
        logs.pushLog("warn", "sync", "library push: peer unreachable or refused", true);
        return null;
    });
    var me_buf: DeviceBuf = undefined;
    const me = store.deviceId(&me_buf);
    // Rows written during this run (seq > snapshot) go next time.
    const snapshot = store.maxSeq();

    const rows = alloc.alloc(sync_pure.SyncRow, sync_pure.MAX_POST_ROWS) catch return null;
    defer alloc.free(rows);
    const body = alloc.alloc(u8, sync_pure.PUSH_MAX_BYTES) catch return null;
    defer alloc.free(body);

    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/api/library/sync", .{peer}) catch return null;

    var res: PushResult = .{ .cursor = since };
    var at = since;
    var page: usize = 0;
    while (page < MAX_PAGES) : (page += 1) {
        const n = store.loadChangedSince(at, snapshot, peer_device, rows);
        if (n == 0) {
            // Everything up to the snapshot is sent or was an echo.
            res.cursor = snapshot;
            break;
        }
        const batch = sync_pure.encodeBatch(body, rows[0..n], me) catch {
            logs.pushLog("warn", "sync", "library push: could not encode a batch", true);
            return if (page == 0) null else res;
        };
        var ack_buf: [1024]u8 = undefined;
        const ack = reliable_fetch.fetch(url, &ack_buf, .{
            .secret_headers = &.{.{ .name = "Authorization", .value = auth }},
            .headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Accept", .value = "application/json" },
            },
            // Up to 60 KB: stdin, not argv.
            .secret_post_body = batch.body,
            .impersonate = false,
            .use_dpi_proxy = false,
            .follow_redirects = false,
            .timeout_secs = 30,
        }) orelse {
            logs.pushLog("warn", "sync", "library push: peer unreachable or refused", true);
            return if (page == 0) null else res;
        };
        if (std.json.parseFromSlice(PushAck, alloc, ack, .{ .ignore_unknown_fields = true })) |parsed| {
            res.applied += parsed.value.applied;
            parsed.deinit();
        } else |_| {}
        res.sent += batch.count;
        at = rows[batch.count - 1].seq;
        res.cursor = at;
        if (batch.count == n and n < rows.len) {
            res.cursor = snapshot;
            break;
        }
    }
    var log_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&log_buf, "library push: {d} rows sent, {d} applied by peer", .{ res.sent, res.applied }) catch "library push done";
    logs.pushLog("info", "sync", msg, false);
    return res;
}

// ── Worker + UI-thread glue ──────────────────────────────────────────────────

const JobPeer = struct {
    url: [256]u8 = undefined,
    url_len: usize = 0,
    token: [256]u8 = undefined,
    token_len: usize = 0,
    device: DeviceBuf = undefined,
    device_len: usize = 0,
    pull_seq: i64 = 0,
    push_seq: i64 = 0,
};

const Job = struct {
    peers: [MAX_PEERS]JobPeer = undefined,
    count: usize = 0,
};

const PeerOutcome = struct {
    url: [256]u8 = undefined,
    url_len: usize = 0,
    run: sync_pure.RunResult = .{},
    pulled: ?PullResult = null,
    pushed: ?PushResult = null,
};

const Outcome = struct {
    peers: [MAX_PEERS]PeerOutcome = undefined,
    count: usize = 0,
    finished_at: i64 = 0,
};

var busy = std.atomic.Value(bool).init(false);
var outcome_mutex: sync.Mutex = .{};
var outcome: Outcome = .{};
var has_outcome = false;
var last_auto_ms: i64 = 0;

pub fn isBusy() bool {
    return busy.load(.acquire);
}

/// UI thread: start a pull-then-push run against peer `only` (or every
/// configured peer when null). Returns false (with a status line on the peer
/// saying why) when nothing was started.
pub fn syncNow(only: ?usize) bool {
    const ls = &state.app.lsync;
    if (busy.load(.acquire)) return false;
    var job: Job = .{};
    for (ls.peers[0..ls.peer_count], 0..) |*p, i| {
        if (only) |o| if (o != i) continue;
        const peer = sync_pure.normalizePeer(p.urlText()) orelse {
            if (only != null or p.urlText().len > 0) p.setStatus("Enter the other device's address, e.g. http://192.168.1.20:41595");
            continue;
        };
        const token = p.tokenText();
        if (!sync_pure.validToken(token)) {
            p.setStatus("Paste the other device's API token (Settings > Web UI > API Token)");
            continue;
        }
        // Cursors belong to one address; a different one starts from scratch.
        if (sync_pure.bindCursors(p, peer)) state.markConfigDirty();
        const jp = &job.peers[job.count];
        jp.* = .{ .pull_seq = p.pull_seq, .push_seq = p.push_seq, .url_len = peer.len, .token_len = token.len, .device_len = p.device_len };
        @memcpy(jp.url[0..peer.len], peer);
        @memcpy(jp.token[0..token.len], token);
        @memcpy(jp.device[0..p.device_len], p.deviceId());
        job.count += 1;
        p.setStatus("Syncing...");
    }
    if (job.count == 0) return false;
    if (busy.swap(true, .acq_rel)) return false;
    workers.spawn(worker, .{job}) catch {
        busy.store(false, .release);
        for (ls.peers[0..ls.peer_count]) |*p| {
            if (std.mem.eql(u8, p.status[0..p.status_len], "Syncing...")) p.setStatus("Could not start sync");
        }
        return false;
    };
    return true;
}

fn worker(job: Job) void {
    var o: Outcome = .{ .count = job.count };
    for (job.peers[0..job.count], 0..) |*jp, i| {
        const peer = jp.url[0..jp.url_len];
        const token = jp.token[0..jp.token_len];
        const po = &o.peers[i];
        po.* = .{ .url_len = jp.url_len };
        @memcpy(po.url[0..jp.url_len], peer);
        po.pulled = pull(peer, token, jp.pull_seq, jp.device[0..jp.device_len]);
        // Push only after a successful pull: a peer we cannot read is a peer we
        // should not write to (wrong address/token), and pulling first means our
        // pushed rows already reflect the merge and we know the peer's id.
        if (po.pulled) |p| {
            po.run.pulled_to = p.cursor;
            @memcpy(po.run.device[0..p.device_len], p.deviceId());
            po.run.device_len = p.device_len;
            // A reset peer store lost what we pushed before: resend all.
            const push_from: i64 = if (p.restarted) 0 else jp.push_seq;
            const dev = if (p.device_len > 0) p.deviceId() else jp.device[0..jp.device_len];
            po.pushed = push(peer, token, push_from, dev);
            if (po.pushed) |q| po.run.pushed_to = q.cursor;
        }
    }
    o.finished_at = io_global.timestamp();
    outcome_mutex.lock();
    outcome = o;
    has_outcome = true;
    outcome_mutex.unlock();
    busy.store(false, .release);
    state.wakeUi();
}

/// UI thread, once per frame: publish a finished run into state and start the
/// periodic sync when it is due.
pub fn tick() void {
    outcome_mutex.lock();
    const got = has_outcome;
    const o = outcome;
    has_outcome = false;
    outcome_mutex.unlock();
    if (got) applyOutcome(&o);

    const ls = &state.app.lsync;
    if (!ls.auto or state.app.incognito_mode or !state.app.config_loaded.load(.acquire)) return;
    if (ls.peer_count == 0 or busy.load(.acquire)) return;
    const now = io_global.milliTimestamp();
    if (last_auto_ms != 0 and now - last_auto_ms < AUTO_INTERVAL_MS) return;
    last_auto_ms = now;
    _ = syncNow(null);
}

fn applyOutcome(o: *const Outcome) void {
    const ls = &state.app.lsync;
    for (o.peers[0..o.count]) |*po| {
        const url = po.url[0..po.url_len];
        // Removed or re-pointed mid-run: these cursors belong to no one now.
        const idx = sync_pure.findPeer(ls.peers[0..ls.peer_count], url) orelse continue;
        const p = &ls.peers[idx];
        _ = sync_pure.applyRun(p, url, &po.run, o.finished_at);
        var buf: [160]u8 = undefined;
        if (po.pulled) |pl| {
            if (po.pushed) |q| {
                p.setStatus(std.fmt.bufPrint(&buf, "Pulled {d} ({d} changed), pushed {d} ({d} changed)", .{ pl.received, pl.applied, q.sent, q.applied }) catch "Synced");
            } else {
                p.setStatus(std.fmt.bufPrint(&buf, "Pulled {d} ({d} changed); push failed - see Logs", .{ pl.received, pl.applied }) catch "Push failed");
            }
        } else {
            p.setStatus("Could not reach the other device - check the address and token");
        }
    }
    state.markConfigDirty();
}
