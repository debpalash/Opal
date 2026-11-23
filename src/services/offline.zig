//! Download for offline (client side, mobile first). Queues files from the
//! paired Opal server (the first Device sync peer: Settings > Web UI > Device
//! sync) or direct http(s) links into `<downloads>/Offline`, within a storage
//! quota. One transfer runs at a time on a worker; an interrupted transfer
//! keeps its `.part` file and resumes with an HTTP Range request, and a
//! finished file is checked against the advertised size before it is playable.
//!
//! Playing an offline copy records watch progress locally (offline_pure
//! .localWrite) and pushes it to the server's `/api/offline/progress` when
//! the server is reachable; the reply carries the merged winner (version,
//! then last writer). Every rule lives in offline_pure.zig.
//!
//! Threading: `items` is guarded by `mutex`. The UI thread owns scheduling
//! (tick) and all state transitions; workers only report bytes and a final
//! outcome through `result`, which tick applies.

const std = @import("std");
const builtin = @import("builtin");
const state = @import("../core/state.zig");
const sync = @import("../core/sync.zig");
const io = @import("../core/io_global.zig");
const logs = @import("../core/logs.zig");
const paths = @import("../core/paths.zig");
const http = @import("../core/http.zig");
const workers = @import("../core/workers.zig");
const alloc = @import("../core/alloc.zig").allocator;
pub const pure = @import("offline_pure.zig");

var mutex: sync.Mutex = .{};
var items: [pure.MAX_ITEMS]pure.Item = undefined;
var count: usize = 0;
var quota: u64 = pure.DEFAULT_QUOTA;
var device: [pure.DEVICE_LEN]u8 = std.mem.zeroes([pure.DEVICE_LEN]u8);
var device_len: usize = 0;
var loaded = false;
/// Set by the UI thread and the sync worker; tick writes offline.json.
var save_due: std.atomic.Value(bool) = .init(false);

// ── Transfer worker ──
var transfer_busy: std.atomic.Value(bool) = .init(false);
/// Bumped to stop the running transfer (pause/remove/quit).
var transfer_epoch: std.atomic.Value(u32) = .init(0);
const Outcome = enum { complete, transient, fatal, stopped, over_quota };
const Result = struct {
    ready: bool = false,
    id: [pure.ID_LEN]u8 = undefined,
    id_len: usize = 0,
    outcome: Outcome = .transient,
    total: u64 = 0,
    msg: [pure.ERR_LEN]u8 = undefined,
    msg_len: usize = 0,
};
var result: Result = .{}; // guarded by mutex

// ── Server listing (Browse server) ──
pub const MAX_LISTING: usize = 64;
var listing_busy: std.atomic.Value(bool) = .init(false);
var listing: [MAX_LISTING]pure.Entry = undefined;
var listing_count: usize = 0; // guarded by mutex
var listing_dir: [pure.FILE_LEN]u8 = undefined;
var listing_dir_len: usize = 0; // guarded by mutex
var listing_status: [96]u8 = undefined;
var listing_status_len: usize = 0; // guarded by mutex

// ── Progress sync ──
var sync_busy: std.atomic.Value(bool) = .init(false);
var last_sync_ms: i64 = 0;
var last_capture_ms: i64 = 0;
const SYNC_INTERVAL_MS: i64 = 60_000;
const CAPTURE_INTERVAL_MS: i64 = 10_000;

const Peer = struct {
    url: [256]u8 = undefined,
    url_len: usize = 0,
    token: [256]u8 = undefined,
    token_len: usize = 0,
    fn urlText(p: *const Peer) []const u8 {
        return p.url[0..p.url_len];
    }
    fn tokenText(p: *const Peer) []const u8 {
        return p.token[0..p.token_len];
    }
};

/// The paired server: the first Device sync peer with an address and token.
/// UI thread (reads state.app.lsync).
fn pairedServer() ?Peer {
    const ls = &state.app.lsync;
    for (ls.peers[0..ls.peer_count]) |*p| {
        const url = pure.normalizeBase(p.urlText()) orelse continue;
        const token = p.tokenText();
        if (token.len == 0 or url.len > 256) continue;
        var out: Peer = .{};
        @memcpy(out.url[0..url.len], url);
        out.url_len = url.len;
        @memcpy(out.token[0..token.len], token);
        out.token_len = token.len;
        return out;
    }
    return null;
}

pub fn hasServer() bool {
    return pairedServer() != null;
}

fn offlineDir(buf: []u8) []const u8 {
    var root_buf: [512]u8 = undefined;
    const root = if (state.app.save_path_len > 0) state.app.save_path_buf[0..state.app.save_path_len] else paths.defaultSavePath(&root_buf);
    return std.fmt.bufPrint(buf, "{s}/Offline", .{root}) catch "";
}

fn localPath(it: *const pure.Item, buf: []u8) []const u8 {
    var dir_buf: [600]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ offlineDir(&dir_buf), it.fileText() }) catch "";
}

fn partPath(it: *const pure.Item, buf: []u8) []const u8 {
    var dir_buf: [600]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/{s}.part", .{ offlineDir(&dir_buf), it.fileText() }) catch "";
}

fn queueFile(buf: []u8) []const u8 {
    var cfg: [512]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/offline.json", .{paths.configDir(&cfg)}) catch "";
}

// ══════════════════════════════════════════════════════════
// Persistence
// ══════════════════════════════════════════════════════════

fn load() void {
    loaded = true;
    var pb: [600]u8 = undefined;
    const path = queueFile(&pb);
    if (path.len > 0) blk: {
        const f = io.openFileAbsolute(path, .{}) catch break :blk;
        defer io.closeFile(f);
        const buf = alloc.alloc(u8, 512 * 1024) catch break :blk;
        defer alloc.free(buf);
        const n = io.readAll(f, buf) catch break :blk;
        mutex.lock();
        defer mutex.unlock();
        var dev_len: usize = 0;
        count = pure.decodeQueue(alloc, buf[0..n], &items, &quota, &device, &dev_len) catch 0;
        device_len = dev_len;
    }
    if (device_len == 0) {
        // Reuse the Device sync identity when there is one, so this device's
        // records read the same on every peer.
        var lb: [32]u8 = undefined;
        const lid = @import("library_store.zig").deviceId(&lb);
        if (lid.len > 0 and lid.len <= device.len) {
            @memcpy(device[0..lid.len], lid);
            device_len = lid.len;
        } else {
            var raw: [8]u8 = undefined;
            if (!io.randomSecure(&raw)) std.mem.writeInt(u64, &raw, @bitCast(io.milliTimestamp()), .little);
            const hex = std.fmt.bytesToHex(raw, .lower);
            @memcpy(device[0..hex.len], &hex);
            device_len = hex.len;
        }
        save_due.store(true, .release);
    }
}

fn save() void {
    save_due.store(false, .release);
    var pb: [600]u8 = undefined;
    const path = queueFile(&pb);
    if (path.len == 0) return;
    const buf = alloc.alloc(u8, 512 * 1024) catch return;
    defer alloc.free(buf);
    var w = std.Io.Writer.fixed(buf);
    mutex.lock();
    pure.encodeQueue(&w, items[0..count], quota, device[0..device_len]) catch {
        mutex.unlock();
        return;
    };
    mutex.unlock();
    var tmp_buf: [610]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch return;
    const f = io.createFileAbsolute(tmp, .{ .truncate = true }) catch return;
    io.writeAll(f, buf[0..w.end]) catch {
        io.closeFile(f);
        return;
    };
    io.closeFile(f);
    io.renameAbsolute(tmp, path) catch {};
}

// ══════════════════════════════════════════════════════════
// Public API (UI thread)
// ══════════════════════════════════════════════════════════

/// Copy the queue for rendering.
pub fn snapshot(out: []pure.Item) usize {
    if (!loaded) load();
    mutex.lock();
    defer mutex.unlock();
    const n = @min(count, out.len);
    @memcpy(out[0..n], items[0..n]);
    return n;
}

pub fn usage() struct { used: u64, quota: u64 } {
    mutex.lock();
    defer mutex.unlock();
    return .{ .used = pure.committedBytes(items[0..count]), .quota = quota };
}

pub fn setQuota(bytes: u64) void {
    if (bytes == 0) return;
    mutex.lock();
    quota = bytes;
    mutex.unlock();
    save_due.store(true, .release);
}

fn admitAndAppend(it: pure.Item) pure.Admission {
    if (!loaded) load();
    mutex.lock();
    defer mutex.unlock();
    const verdict = pure.admit(items[0..count], quota, it.idText(), it.expected);
    if (verdict != .ok) return verdict;
    items[count] = it;
    count += 1;
    save_due.store(true, .release);
    return .ok;
}

fn toastAdmission(a: pure.Admission, title: []const u8) void {
    var b: [200]u8 = undefined;
    state.showToast(switch (a) {
        .ok => std.fmt.bufPrint(&b, "Saving for offline: {s}", .{title}) catch "Saving for offline",
        .over_quota => "Not enough offline storage left (raise the limit or remove a download)",
        .duplicate => "Already saved for offline",
        .full => "The offline list is full",
        .invalid => "Cannot save this for offline",
    });
}

/// Queue a file from the paired server's downloads folder (`rel` is relative
/// to its root, as listed by /api/downloads).
pub fn queueServerFile(rel: []const u8, size: u64) bool {
    var idb: [pure.ID_LEN]u8 = undefined;
    const id = pure.serverItemId(rel, &idb) orelse return false;
    if (pure.serverRel(id) == null) return false;
    var nb: [pure.FILE_LEN]u8 = undefined;
    const file = pure.localFileName(id, rel, &nb) orelse return false;
    const it = pure.makeItem(.server, id, pure.basename(rel), rel, file, size, io.milliTimestamp()) orelse return false;
    const a = admitAndAppend(it);
    toastAdmission(a, it.titleText());
    return a == .ok;
}

/// Queue a direct http(s) link. Private/loopback targets are refused, as for
/// any HTTP download.
pub fn queueUrl(url: []const u8, title: []const u8) bool {
    if (!(std.ascii.startsWithIgnoreCase(url, "http://") or std.ascii.startsWithIgnoreCase(url, "https://"))) return false;
    if (!@import("fetch_target.zig").stringPermitted(url)) {
        state.showToast("Blocked private network download");
        return false;
    }
    var idb: [pure.ID_LEN]u8 = undefined;
    const id = std.fmt.bufPrint(&idb, "url:{x:0>16}", .{std.hash.Wyhash.hash(0, url)}) catch return false;
    var nb: [pure.FILE_LEN]u8 = undefined;
    const file = pure.localFileName(id, url, &nb) orelse return false;
    if (@import("../core/download_safety_pure.zig").isDangerousDownload(file)) {
        state.showToast("Blocked dangerous download (executable or script)");
        return false;
    }
    const it = pure.makeItem(.direct, id, if (title.len > 0) title else pure.basename(url), url, file, 0, io.milliTimestamp()) orelse return false;
    const a = admitAndAppend(it);
    toastAdmission(a, it.titleText());
    return a == .ok;
}

pub const Action = enum { pause, @"resume", retry, remove };

pub fn apply(id: []const u8, action: Action) void {
    mutex.lock();
    const idx = pure.findIndex(items[0..count], id) orelse {
        mutex.unlock();
        return;
    };
    const was_running = items[idx].status == .downloading;
    switch (action) {
        .pause => _ = items[idx].apply(.pause),
        .@"resume" => _ = items[idx].apply(.@"resume"),
        .retry => if (items[idx].apply(.retry)) {
            items[idx].attempts = 0;
            items[idx].err_len = 0;
        },
        .remove => {
            const it = items[idx];
            std.mem.copyForwards(pure.Item, items[idx .. count - 1], items[idx + 1 .. count]);
            count -= 1;
            mutex.unlock();
            if (was_running) _ = transfer_epoch.fetchAdd(1, .acq_rel);
            var a: [700]u8 = undefined;
            var b: [710]u8 = undefined;
            io.deleteFileAbsolute(localPath(&it, &a)) catch {};
            io.deleteFileAbsolute(partPath(&it, &b)) catch {};
            save_due.store(true, .release);
            return;
        },
    }
    mutex.unlock();
    if (was_running and action == .pause) _ = transfer_epoch.fetchAdd(1, .acq_rel);
    save_due.store(true, .release);
}

/// Play a finished offline copy from local storage.
pub fn play(id: []const u8) void {
    mutex.lock();
    const idx = pure.findIndex(items[0..count], id) orelse {
        mutex.unlock();
        return;
    };
    const it = items[idx];
    mutex.unlock();
    if (it.status != .done) return;
    var pb: [700]u8 = undefined;
    const path = localPath(&it, &pb);
    if (io.cwdStatFile(path)) |_| {} else |_| {
        state.showToast("Offline file is missing");
        return;
    }
    @import("browser.zig").loadContent(path);
}

// ── Browse the paired server's downloads folder ──

pub const Listing = struct {
    entries: [MAX_LISTING]pure.Entry = undefined,
    count: usize = 0,
    dir: [pure.FILE_LEN]u8 = undefined,
    dir_len: usize = 0,
    status: [96]u8 = undefined,
    status_len: usize = 0,
    busy: bool = false,

    pub fn dirText(self: *const Listing) []const u8 {
        return self.dir[0..self.dir_len];
    }
    pub fn statusText(self: *const Listing) []const u8 {
        return self.status[0..self.status_len];
    }
};

pub fn listingSnapshot(out: *Listing) void {
    mutex.lock();
    defer mutex.unlock();
    out.count = listing_count;
    @memcpy(out.entries[0..listing_count], listing[0..listing_count]);
    out.dir_len = listing_dir_len;
    @memcpy(out.dir[0..listing_dir_len], listing_dir[0..listing_dir_len]);
    out.status_len = listing_status_len;
    @memcpy(out.status[0..listing_status_len], listing_status[0..listing_status_len]);
    out.busy = listing_busy.load(.acquire);
}

fn setListingStatus(text: []const u8) void {
    const n = @min(text.len, listing_status.len);
    @memcpy(listing_status[0..n], text[0..n]);
    listing_status_len = n;
}

const ListJob = struct {
    peer: Peer,
    dir: [pure.FILE_LEN]u8 = undefined,
    dir_len: usize = 0,
};

/// List `dir` (relative, "" = root) on the paired server.
pub fn browse(dir: []const u8) void {
    if (listing_busy.load(.acquire)) return;
    if (dir.len > 0 and !pure.safeRelPath(dir)) return;
    if (dir.len > pure.FILE_LEN) return;
    const peer = pairedServer() orelse {
        mutex.lock();
        setListingStatus("Pair a server under Settings > Web UI > Device sync");
        mutex.unlock();
        return;
    };
    var job: ListJob = .{ .peer = peer };
    @memcpy(job.dir[0..dir.len], dir);
    job.dir_len = dir.len;
    mutex.lock();
    setListingStatus("Loading...");
    mutex.unlock();
    listing_busy.store(true, .release);
    const th = workers.spawnLegacy(listWorker, .{job}) catch {
        listing_busy.store(false, .release);
        return;
    };
    workers.release(th);
}

fn listWorker(job: ListJob) void {
    defer listing_busy.store(false, .release);
    var url_buf: [pure.FILE_LEN * 3 + 300]u8 = undefined;
    const dir = job.dir[0..job.dir_len];
    const url = pure.serverListUrl(job.peer.urlText(), dir, &url_buf) orelse return;
    var auth_buf: [300]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Authorization: Bearer {s}", .{job.peer.tokenText()}) catch return;
    const body_buf = alloc.alloc(u8, 128 * 1024) catch return;
    defer alloc.free(body_buf);
    const body = http.fetch(url, body_buf, .{ .accept = "application/json", .auth_header = auth, .timeout_secs = 10, .max_response = body_buf.len }) orelse {
        mutex.lock();
        setListingStatus("Server unreachable");
        mutex.unlock();
        return;
    };
    var tmp: [MAX_LISTING]pure.Entry = undefined;
    const n = pure.parseListing(alloc, body, &tmp) catch {
        mutex.lock();
        setListingStatus("Unexpected reply from the server");
        mutex.unlock();
        return;
    };
    mutex.lock();
    defer mutex.unlock();
    @memcpy(listing[0..n], tmp[0..n]);
    listing_count = n;
    @memcpy(listing_dir[0..dir.len], dir);
    listing_dir_len = dir.len;
    setListingStatus(if (n == 0) "No files on the server here" else "");
}

// ══════════════════════════════════════════════════════════
// Tick (UI thread): apply worker results, schedule, capture, sync
// ══════════════════════════════════════════════════════════

pub fn tick() void {
    if (!state.app.config_loaded.load(.acquire)) return;
    if (!loaded) load();
    const now = io.milliTimestamp();
    applyResult();
    schedule(now);
    if (now - last_capture_ms >= CAPTURE_INTERVAL_MS) {
        last_capture_ms = now;
        captureProgress(now);
    }
    if (now - last_sync_ms >= SYNC_INTERVAL_MS) {
        last_sync_ms = now;
        startSync();
    }
    if (save_due.load(.acquire)) save();
}

fn applyResult() void {
    mutex.lock();
    if (!result.ready) {
        mutex.unlock();
        return;
    }
    const r = result;
    result.ready = false;
    const idx = pure.findIndex(items[0..count], r.id[0..r.id_len]) orelse {
        mutex.unlock();
        return;
    };
    const it = &items[idx];
    const now = io.milliTimestamp();
    switch (r.outcome) {
        .complete => {
            it.expected = pure.expectedSize(it.expected, if (r.total > 0) r.total else null);
            _ = it.apply(.bytes_complete);
        },
        .transient => {
            it.attempts +|= 1;
            it.retry_at_ms = now + pure.retryDelayMs(it.attempts);
            _ = it.apply(pure.afterTransientFailure(it.attempts));
            it.setErr(r.msg[0..r.msg_len]);
        },
        .fatal => {
            _ = it.apply(.fatal);
            it.setErr(r.msg[0..r.msg_len]);
        },
        .over_quota => {
            _ = it.apply(.fatal);
            it.setErr("Over the offline storage limit");
        },
        .stopped => {},
    }
    const verify = it.status == .verifying;
    const copy = it.*;
    mutex.unlock();
    if (verify) verifyItem(copy);
    save_due.store(true, .release);
}

/// Check the finished part file's size, then publish it under its real name.
fn verifyItem(it: pure.Item) void {
    var pb: [710]u8 = undefined;
    var lb: [700]u8 = undefined;
    const part = partPath(&it, &pb);
    const final = localPath(&it, &lb);
    const size: u64 = blk: {
        const st = io.cwdStatFile(part) catch break :blk 0;
        break :blk st.size;
    };
    const verdict = pure.verifySize(size, it.expected);
    const ok = verdict == .ok or verdict == .unknown_ok;
    if (ok) io.renameAbsolute(part, final) catch {};
    mutex.lock();
    defer mutex.unlock();
    const idx = pure.findIndex(items[0..count], it.idText()) orelse return;
    const live = &items[idx];
    live.have = size;
    if (ok) {
        _ = live.apply(.verified);
        if (verdict == .unknown_ok) live.setErr("Size not advertised by the source") else live.err_len = 0;
    } else {
        _ = live.apply(.verify_failed);
        live.setErr(if (verdict == .short) "Incomplete file (size check failed)" else "File larger than advertised");
        io.deleteFileAbsolute(part) catch {};
        live.have = 0;
    }
    var msg: [240]u8 = undefined;
    logs.pushLog(if (ok) "info" else "warn", "offline", std.fmt.bufPrint(&msg, "{s}: {s} ({d} bytes)", .{ live.titleText(), @tagName(verdict), size }) catch "verified", !ok);
    if (ok) state.showToast("Saved for offline");
}

const Job = struct {
    id: [pure.ID_LEN]u8 = undefined,
    id_len: usize = 0,
    url: [pure.URL_LEN + 300]u8 = undefined,
    url_len: usize = 0,
    auth: [300]u8 = undefined,
    auth_len: usize = 0,
    part: [710]u8 = undefined,
    part_len: usize = 0,
    expected: u64 = 0,
    epoch: u32 = 0,
    direct: bool = false,
};

fn schedule(now: i64) void {
    if (transfer_busy.load(.acquire)) return;
    var job: Job = .{};
    {
        mutex.lock();
        defer mutex.unlock();
        if (result.ready) return;
        const idx = pure.nextToStart(items[0..count], now) orelse return;
        const it = &items[idx];
        if (it.status == .waiting_network) _ = it.apply(.network_back);
        const peer = if (it.source == .server) (pairedServer() orelse {
            // No paired server right now: wait without burning attempts.
            if (it.apply(.network_lost)) it.retry_at_ms = now + 30_000;
            it.setErr("Waiting for the paired server");
            return;
        }) else Peer{};
        if (it.source == .server) {
            const url = pure.serverFileUrl(peer.urlText(), it.urlText(), &job.url) orelse return;
            job.url_len = url.len;
            const auth = std.fmt.bufPrint(&job.auth, "Bearer {s}", .{peer.tokenText()}) catch return;
            job.auth_len = auth.len;
        } else {
            @memcpy(job.url[0..it.url_len], it.urlText());
            job.url_len = it.url_len;
            job.direct = true;
        }
        @memcpy(job.id[0..it.id_len], it.idText());
        job.id_len = it.id_len;
        const part = partPath(it, &job.part);
        job.part_len = part.len;
        job.expected = it.expected;
        if (!it.apply(.start)) return;
        it.err_len = 0;
    }
    var db: [600]u8 = undefined;
    const dir = offlineDir(&db);
    io.cwdMakePath(dir) catch {};
    job.epoch = transfer_epoch.load(.acquire);
    transfer_busy.store(true, .release);
    const th = workers.spawnLegacy(transferWorker, .{job}) catch {
        transfer_busy.store(false, .release);
        postResult(job.id[0..job.id_len], .transient, 0, "Could not start the transfer");
        return;
    };
    workers.release(th);
}

fn postResult(id: []const u8, outcome: Outcome, total: u64, msg: []const u8) void {
    mutex.lock();
    defer mutex.unlock();
    result = .{ .ready = true, .outcome = outcome, .total = total };
    @memcpy(result.id[0..id.len], id);
    result.id_len = id.len;
    const n = @min(msg.len, result.msg.len);
    @memcpy(result.msg[0..n], msg[0..n]);
    result.msg_len = n;
}

fn setHave(id: []const u8, have: u64) bool {
    mutex.lock();
    defer mutex.unlock();
    const idx = pure.findIndex(items[0..count], id) orelse return false;
    items[idx].have = have;
    return !pure.exceedsQuota(items[0..count], quota, idx, have);
}

fn transferWorker(job: Job) void {
    defer transfer_busy.store(false, .release);
    const id = job.id[0..job.id_len];
    var msg: [pure.ERR_LEN]u8 = undefined;
    const out = transfer(&job, &msg);
    postResult(id, out.outcome, out.total, msg[0..out.msg_len]);
    // Wake the UI loop so tick applies the result promptly.
    @import("../core/state.zig").wakeUi();
}

const TransferOut = struct { outcome: Outcome, total: u64 = 0, msg_len: usize = 0 };

fn fail(outcome: Outcome, msg: *[pure.ERR_LEN]u8, text: []const u8) TransferOut {
    const n = @min(text.len, msg.len);
    @memcpy(msg[0..n], text[0..n]);
    return .{ .outcome = outcome, .msg_len = n };
}

fn transfer(job: *const Job, msg: *[pure.ERR_LEN]u8) TransferOut {
    const id = job.id[0..job.id_len];
    const part = job.part[0..job.part_len];
    const file = io.createFileAbsolute(part, .{ .truncate = false, .read = true }) catch return fail(.fatal, msg, "Cannot create the offline file");
    defer io.closeFile(file);
    var have: u64 = blk: {
        const st = file.stat(io.io()) catch break :blk 0;
        break :blk st.size;
    };
    if (job.expected > 0 and have > job.expected) {
        file.setLength(io.io(), 0) catch {};
        have = 0;
    }
    _ = setHave(id, have);

    var client = http.newClient();
    defer client.deinit();
    const uri = std.Uri.parse(job.url[0..job.url_len]) catch return fail(.fatal, msg, "Bad URL");
    var range_buf: [48]u8 = undefined;
    var headers: [3]std.http.Header = undefined;
    var hn: usize = 0;
    headers[hn] = .{ .name = "Accept", .value = "*/*" };
    hn += 1;
    if (pure.rangeHeader(have, &range_buf)) |r| {
        headers[hn] = .{ .name = "Range", .value = r };
        hn += 1;
    }
    if (job.auth_len > 0) {
        headers[hn] = .{ .name = "Authorization", .value = job.auth[0..job.auth_len] };
        hn += 1;
    }
    var req = client.request(.GET, uri, .{
        // The server route never redirects; a direct link may (and then
        // carries no credentials).
        .redirect_behavior = if (job.direct) @fromBackingInt(@intCast(5)) else .not_allowed,
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
        .extra_headers = headers[0..hn],
    }) catch return fail(.transient, msg, "Server unreachable");
    defer req.deinit();
    req.sendBodiless() catch return fail(.transient, msg, "Server unreachable");
    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return fail(.transient, msg, "No response");
    if (response.head.content_encoding != .identity) return fail(.fatal, msg, "Compressed response");

    var content_range: ?[]const u8 = null;
    var hit = response.head.iterateHeaders();
    while (hit.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Content-Range")) content_range = h.value;
    }
    const status: u16 = @intFromEnum(response.head.status);
    const plan = pure.planResponse(status, have, content_range, response.head.content_length);
    var total: ?u64 = null;
    switch (plan) {
        .append => |t| total = t,
        .restart => |len| {
            file.setLength(io.io(), 0) catch return fail(.fatal, msg, "Cannot write the offline file");
            have = 0;
            total = len;
        },
        // Already whole: verify against the size known at queue time.
        .complete => return .{ .outcome = .complete },
        .retry => {
            var b: [48]u8 = undefined;
            return fail(.transient, msg, std.fmt.bufPrint(&b, "Server answered {d}", .{status}) catch "Server error");
        },
        .fatal => {
            var b: [48]u8 = undefined;
            return fail(.fatal, msg, std.fmt.bufPrint(&b, "Server refused ({d})", .{status}) catch "Server refused");
        },
    }
    if (total) |t| if (job.expected > 0 and t != job.expected) {
        logs.pushLog("warn", "offline", "Server size differs from the listing; verifying against the server", false);
    };

    var transfer_buf: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    const chunk = alloc.alloc(u8, 64 * 1024) catch return fail(.transient, msg, "Out of memory");
    defer alloc.free(chunk);
    var last_report: i64 = 0;
    while (true) {
        if (transfer_epoch.load(.acquire) != job.epoch) {
            _ = setHave(id, have);
            return .{ .outcome = .stopped };
        }
        if (workers.isQuitting()) return .{ .outcome = .stopped };
        var w = std.Io.Writer.fixed(chunk);
        const n = reader.stream(&w, .limited(chunk.len)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => {
                _ = setHave(id, have);
                return fail(.transient, msg, "Connection lost");
            },
        };
        if (n == 0) continue;
        file.writePositionalAll(io.io(), chunk[0..n], have) catch return fail(.fatal, msg, "Storage write failed");
        have += n;
        const now = io.milliTimestamp();
        if (now - last_report >= 500) {
            last_report = now;
            if (!setHave(id, have)) return .{ .outcome = .over_quota };
        }
    }
    if (!setHave(id, have)) return .{ .outcome = .over_quota };
    if (total) |t| if (have < t) return fail(.transient, msg, "Connection closed early");
    // Only a size the server stated may replace the listed one; never the
    // byte count we happened to receive (that would make any short file pass).
    return .{ .outcome = .complete, .total = total orelse 0 };
}

// ══════════════════════════════════════════════════════════
// Watch progress
// ══════════════════════════════════════════════════════════

/// Record the active player's position when it plays an offline copy.
fn captureProgress(now: i64) void {
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    const p = state.app.players.items[state.app.active_player_idx];
    if (p.current_url_len == 0) return;
    const url = p.current_url[0..@min(p.current_url_len, p.current_url.len)];
    const pos = p.last_seen_pos;
    const dur = p.cached_duration;
    if (!(pos > 0)) return;
    mutex.lock();
    defer mutex.unlock();
    for (items[0..count]) |*it| {
        if (it.status != .done) continue;
        var pb: [700]u8 = undefined;
        if (!std.mem.eql(u8, localPath(it, &pb), url)) continue;
        if (@abs(it.progress.pos_s - pos) < 1.0) return;
        it.progress = pure.localWrite(it.progress, pos, dur, now, device[0..device_len]);
        save_due.store(true, .release);
        return;
    }
}

const SyncJob = struct {
    peer: Peer,
    bodies: [pure.MAX_ITEMS][600]u8 = undefined,
    lens: [pure.MAX_ITEMS]usize = undefined,
    n: usize = 0,
};

/// Push every unacknowledged server-item record (one small POST each; the
/// server's request buffer is 4 KB).
fn startSync() void {
    if (sync_busy.load(.acquire)) return;
    const peer = pairedServer() orelse return;
    const job = alloc.create(SyncJob) catch return;
    job.* = .{ .peer = peer };
    mutex.lock();
    for (items[0..count]) |*it| {
        if (it.source != .server or !it.progress.dirty or job.n >= job.bodies.len) continue;
        var w = std.Io.Writer.fixed(&job.bodies[job.n]);
        pure.encodeProgress(&w, it.idText(), &it.progress) catch continue;
        job.lens[job.n] = w.end;
        job.n += 1;
    }
    mutex.unlock();
    if (job.n == 0) {
        alloc.destroy(job);
        return;
    }
    sync_busy.store(true, .release);
    const th = workers.spawnLegacy(syncWorker, .{job}) catch {
        sync_busy.store(false, .release);
        alloc.destroy(job);
        return;
    };
    workers.release(th);
}

fn syncWorker(job: *SyncJob) void {
    defer {
        alloc.destroy(job);
        sync_busy.store(false, .release);
    }
    var url_buf: [320]u8 = undefined;
    const url = pure.serverProgressUrl(job.peer.urlText(), &url_buf) orelse return;
    var auth_buf: [300]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Authorization: Bearer {s}", .{job.peer.tokenText()}) catch return;
    var reply_buf: [1024]u8 = undefined;
    var synced: usize = 0;
    for (0..job.n) |i| {
        const body = http.fetch(url, &reply_buf, .{
            .method = .POST,
            .payload = job.bodies[i][0..job.lens[i]],
            .content_type = "application/json",
            .auth_header = auth,
            .accept = "application/json",
            .timeout_secs = 10,
            .max_response = reply_buf.len,
        }) orelse return; // offline: retry on the next interval
        const winner = pure.decodeProgress(alloc, body) orelse continue;
        mutex.lock();
        if (pure.findIndex(items[0..count], winner.idText())) |idx| {
            items[idx].progress = pure.reconcile(items[idx].progress, winner.progress);
            synced += 1;
        }
        mutex.unlock();
    }
    if (synced > 0) save_due.store(true, .release);
}
