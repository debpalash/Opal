//! Pure rules for "download for offline" (mobile first, works on desktop too):
//! the queue state machine, the storage quota, HTTP Range resume and size
//! verification, and the watch-progress merge used to sync back to the paired
//! Opal server. offline.zig (client) and offline_server.zig (server endpoint)
//! route every decision through here, so the tested logic is the shipped logic.
//!
//! Progress merge: every item carries a monotonic per-item `version` (a
//! Lamport clock: a local write after the last sync bumps it to seen + 1).
//! The higher version wins; equal versions fall back to last-writer-wins on
//! `updated_ms`, then to the device id so both sides pick the same record.

const std = @import("std");

pub const MAX_ITEMS: usize = 48;
pub const ID_LEN: usize = 192;
pub const TITLE_LEN: usize = 160;
pub const URL_LEN: usize = 1024;
pub const FILE_LEN: usize = 200;
pub const ERR_LEN: usize = 64;
pub const DEVICE_LEN: usize = 32;
/// Default storage quota for offline copies.
pub const DEFAULT_QUOTA: u64 = 8 << 30;
pub const QUOTA_CHOICES = [_]u64{ 2 << 30, 8 << 30, 32 << 30, 128 << 30 };
/// Automatic retries before an item parks in `failed`.
pub const MAX_ATTEMPTS: u8 = 6;
/// Server identity prefix: the file path relative to the server's downloads root.
pub const SERVER_PREFIX = "srv:";

pub const Source = enum { server, direct };

pub const Status = enum {
    queued,
    downloading,
    paused,
    /// Transfer failed for a transient reason; retried at `retry_at_ms`.
    waiting_network,
    verifying,
    done,
    failed,
};

pub const Event = enum {
    start,
    pause,
    @"resume",
    network_lost,
    network_back,
    bytes_complete,
    verified,
    verify_failed,
    fatal,
    retry,
};

/// The queue state machine. null = the event does not apply in that state
/// (the caller ignores it rather than corrupting the item).
pub fn transition(s: Status, e: Event) ?Status {
    return switch (s) {
        .queued => switch (e) {
            .start => .downloading,
            .pause => .paused,
            .network_lost => .waiting_network,
            .fatal => .failed,
            else => null,
        },
        .downloading => switch (e) {
            .pause => .paused,
            .network_lost => .waiting_network,
            .bytes_complete => .verifying,
            .fatal => .failed,
            else => null,
        },
        .paused => switch (e) {
            .@"resume" => .queued,
            else => null,
        },
        .waiting_network => switch (e) {
            .network_back => .queued,
            .pause => .paused,
            .fatal => .failed,
            else => null,
        },
        .verifying => switch (e) {
            .verified => .done,
            .verify_failed => .failed,
            else => null,
        },
        .failed => switch (e) {
            .retry => .queued,
            else => null,
        },
        .done => null,
    };
}

/// A transient failure: wait and retry, or give up after MAX_ATTEMPTS.
pub fn afterTransientFailure(attempts: u8) Event {
    return if (attempts >= MAX_ATTEMPTS) .fatal else .network_lost;
}

/// Backoff before retry `attempts` (1-based): 2 s, 10 s, 30 s, then 60 s.
pub fn retryDelayMs(attempts: u8) i64 {
    return switch (attempts) {
        0, 1 => 2_000,
        2 => 10_000,
        3 => 30_000,
        else => 60_000,
    };
}

// ── Items ────────────────────────────────────────────────────────────────────

pub const Progress = struct {
    pos_s: f64 = 0,
    dur_s: f64 = 0,
    version: u64 = 0,
    updated_ms: i64 = 0,
    device: [DEVICE_LEN]u8 = std.mem.zeroes([DEVICE_LEN]u8),
    device_len: usize = 0,
    /// A local write the server has not acknowledged yet (client only).
    dirty: bool = false,

    pub fn deviceId(self: *const Progress) []const u8 {
        return self.device[0..self.device_len];
    }
};

pub const Item = struct {
    id: [ID_LEN]u8 = std.mem.zeroes([ID_LEN]u8),
    id_len: usize = 0,
    title: [TITLE_LEN]u8 = std.mem.zeroes([TITLE_LEN]u8),
    title_len: usize = 0,
    source: Source = .server,
    /// Server: path relative to its downloads root. Direct: the full URL.
    url: [URL_LEN]u8 = std.mem.zeroes([URL_LEN]u8),
    url_len: usize = 0,
    /// File name inside the offline directory.
    file: [FILE_LEN]u8 = std.mem.zeroes([FILE_LEN]u8),
    file_len: usize = 0,
    /// Size the source advertised (0 = unknown until the response says).
    expected: u64 = 0,
    /// Bytes on disk in the part file (or the finished file).
    have: u64 = 0,
    status: Status = .queued,
    attempts: u8 = 0,
    retry_at_ms: i64 = 0,
    added_ms: i64 = 0,
    err: [ERR_LEN]u8 = std.mem.zeroes([ERR_LEN]u8),
    err_len: usize = 0,
    progress: Progress = .{},

    pub fn idText(self: *const Item) []const u8 {
        return self.id[0..self.id_len];
    }
    pub fn titleText(self: *const Item) []const u8 {
        return self.title[0..self.title_len];
    }
    pub fn urlText(self: *const Item) []const u8 {
        return self.url[0..self.url_len];
    }
    pub fn fileText(self: *const Item) []const u8 {
        return self.file[0..self.file_len];
    }
    pub fn errText(self: *const Item) []const u8 {
        return self.err[0..self.err_len];
    }
    pub fn setErr(self: *Item, text: []const u8) void {
        const n = @min(text.len, self.err.len);
        @memcpy(self.err[0..n], text[0..n]);
        self.err_len = n;
    }
    /// Apply `e`; false (and no change) when it does not apply.
    pub fn apply(self: *Item, e: Event) bool {
        const next = transition(self.status, e) orelse return false;
        self.status = next;
        return true;
    }
};

fn put(dst: []u8, len: *usize, src: []const u8) bool {
    if (src.len > dst.len) return false;
    @memcpy(dst[0..src.len], src);
    len.* = src.len;
    return true;
}

/// Build a queued item. null when a field does not fit (never truncate an
/// identity or a URL).
pub fn makeItem(source: Source, id: []const u8, title: []const u8, url: []const u8, file: []const u8, expected: u64, now_ms: i64) ?Item {
    var it: Item = .{ .source = source, .expected = expected, .added_ms = now_ms };
    if (id.len == 0 or url.len == 0 or file.len == 0) return null;
    if (!put(&it.id, &it.id_len, id)) return null;
    if (!put(&it.url, &it.url_len, url)) return null;
    if (!put(&it.file, &it.file_len, file)) return null;
    _ = put(&it.title, &it.title_len, title[0..@min(title.len, TITLE_LEN)]);
    return it;
}

/// Identity for a file on the paired server, shared by client and server.
pub fn serverItemId(rel: []const u8, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, SERVER_PREFIX ++ "{s}", .{rel}) catch null;
}

/// The relative path behind a server identity, or null for another source.
pub fn serverRel(id: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, id, SERVER_PREFIX)) return null;
    const rel = id[SERVER_PREFIX.len..];
    if (!safeRelPath(rel)) return null;
    return rel;
}

/// A downloads-relative path that cannot escape its root.
pub fn safeRelPath(rel: []const u8) bool {
    if (rel.len == 0 or rel.len > URL_LEN) return false;
    if (rel[0] == '/' or rel[0] == '\\') return false;
    var it = std.mem.splitAny(u8, rel, "/\\");
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
    }
    for (rel) |c| if (c < 0x20) return false;
    return true;
}

pub fn findIndex(items: []const Item, id: []const u8) ?usize {
    for (items, 0..) |*it, i| {
        if (std.mem.eql(u8, it.idText(), id)) return i;
    }
    return null;
}

// ── Row presentation (offline_ui.zig) ─────────────────────────────────────────

pub const Actions = struct { play: bool = false, pause: bool = false, @"resume": bool = false, retry: bool = false };

/// Which row buttons apply to an item in `s` (Remove always does).
pub fn actionsFor(s: Status) Actions {
    return switch (s) {
        .done => .{ .play = true },
        .queued, .downloading, .waiting_network => .{ .pause = true },
        .paused => .{ .@"resume" = true },
        .failed => .{ .retry = true },
        .verifying => .{},
    };
}

pub fn statusLabel(s: Status) []const u8 {
    return switch (s) {
        .queued => "Queued",
        .downloading => "Downloading",
        .paused => "Paused",
        .waiting_network => "Waiting for network",
        .verifying => "Checking size",
        .done => "Available offline",
        .failed => "Failed",
    };
}

/// Whole percent of the transfer, 0 when the size is unknown.
pub fn percentDone(it: *const Item) u8 {
    if (it.status == .done) return 100;
    if (it.expected == 0) return 0;
    return @intCast(@min(it.have * 100 / it.expected, 100));
}

// ── Quota ────────────────────────────────────────────────────────────────────

/// Bytes an item holds or will hold on disk. Failed items keep their part file
/// until removed, so they still count what they have.
pub fn footprint(it: *const Item) u64 {
    return @max(it.expected, it.have);
}

pub fn committedBytes(items: []const Item) u64 {
    var sum: u64 = 0;
    for (items) |*it| sum +|= footprint(it);
    return sum;
}

pub const Admission = enum { ok, over_quota, duplicate, full, invalid };

/// May a new item of `size` bytes (0 = unknown) join the queue? An unknown
/// size is admitted while there is room left; the transfer then enforces the
/// quota as bytes arrive (exceedsQuota).
pub fn admit(items: []const Item, quota: u64, id: []const u8, size: u64) Admission {
    if (id.len == 0) return .invalid;
    if (findIndex(items, id) != null) return .duplicate;
    if (items.len >= MAX_ITEMS) return .full;
    const used = committedBytes(items);
    if (used >= quota) return .over_quota;
    if (size > quota - used) return .over_quota;
    return .ok;
}

/// During a transfer: would `have` bytes for item `idx` break the quota?
pub fn exceedsQuota(items: []const Item, quota: u64, idx: usize, have: u64) bool {
    var others: u64 = 0;
    for (items, 0..) |*it, i| {
        if (i != idx) others +|= footprint(it);
    }
    return others +| have > quota;
}

// ── Scheduling ───────────────────────────────────────────────────────────────

/// Next item to start: the oldest queued one, or a waiting one whose backoff
/// has elapsed (the caller first applies network_back to it). One transfer
/// at a time keeps a phone's radio and storage writes predictable.
pub fn nextToStart(items: []const Item, now_ms: i64) ?usize {
    for (items) |*it| if (it.status == .downloading or it.status == .verifying) return null;
    var best: ?usize = null;
    for (items, 0..) |*it, i| {
        const ready = it.status == .queued or (it.status == .waiting_network and now_ms >= it.retry_at_ms);
        if (!ready) continue;
        if (best == null or it.added_ms < items[best.?].added_ms) best = i;
    }
    return best;
}

// ── HTTP Range resume ────────────────────────────────────────────────────────

/// `Range` header value to resume from `have` bytes; null starts from zero.
pub fn rangeHeader(have: u64, buf: []u8) ?[]const u8 {
    if (have == 0) return null;
    return std.fmt.bufPrint(buf, "bytes={d}-", .{have}) catch null;
}

pub const ContentRange = struct { start: u64, end: u64, total: ?u64 };

/// Parse `bytes a-b/total` (total may be `*`).
pub fn parseContentRange(value: []const u8) ?ContentRange {
    const v = std.mem.trim(u8, value, " \t");
    if (!std.ascii.startsWithIgnoreCase(v, "bytes ")) return null;
    const rest = v["bytes ".len..];
    const dash = std.mem.indexOfScalar(u8, rest, '-') orelse return null;
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    if (slash < dash) return null;
    const start = std.fmt.parseInt(u64, rest[0..dash], 10) catch return null;
    const end = std.fmt.parseInt(u64, rest[dash + 1 .. slash], 10) catch return null;
    if (end < start) return null;
    const tail = rest[slash + 1 ..];
    const total: ?u64 = if (std.mem.eql(u8, tail, "*")) null else (std.fmt.parseInt(u64, tail, 10) catch return null);
    if (total) |t| if (end >= t) return null;
    return .{ .start = start, .end = end, .total = total };
}

pub const Plan = union(enum) {
    /// 206 continuing exactly at `have`: append. `total` = full size if known.
    append: ?u64,
    /// 200 (Range ignored or not asked): truncate and write from zero.
    restart: ?u64,
    /// 416 after a resume: the part file already holds everything; verify it.
    complete,
    /// Server refused or answered a different range: transient, retry later.
    retry,
    /// Auth or not-found: retrying will not help.
    fatal,
};

/// Decide what to do with a response to a (possibly ranged) GET.
/// `content_length` is the body length of this response, if sent.
pub fn planResponse(status: u16, have: u64, content_range: ?[]const u8, content_length: ?u64) Plan {
    switch (status) {
        200 => return .{ .restart = content_length },
        206 => {
            const cr = parseContentRange(content_range orelse return .retry) orelse return .retry;
            if (cr.start != have) return .retry;
            return .{ .append = cr.total };
        },
        416 => return if (have > 0) .complete else .retry,
        401, 403, 404, 410 => return .fatal,
        else => return .retry,
    }
}

pub const Verdict = enum { ok, short, oversize, unknown_ok };

/// Check the finished file against the size the source advertised. A source
/// that never sent a size is accepted as `unknown_ok` (direct links without
/// Content-Length); the UI labels it unverified.
pub fn verifySize(actual: u64, expected: u64) Verdict {
    if (expected == 0) return if (actual > 0) .unknown_ok else .short;
    if (actual < expected) return .short;
    if (actual > expected) return .oversize;
    return .ok;
}

/// The size to verify against: the listing's size wins when known, the
/// response's total otherwise. A listing that disagrees with the server's own
/// total means the file changed since it was queued: adopt the new total.
pub fn expectedSize(listed: u64, response_total: ?u64) u64 {
    if (response_total) |t| {
        if (listed == 0 or listed != t) return t;
    }
    return listed;
}

// ── Names and URLs ───────────────────────────────────────────────────────────

/// Percent-encode a query value (RFC 3986 unreserved stay literal; `/` too,
/// so paths stay readable). Covers space & = # ? % + at minimum.
pub fn writeQueryValue(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~', '/' => try w.writeByte(c),
        else => try w.print("%{X:0>2}", .{c}),
    };
}

/// `<base>/stream?file=<rel>` on the paired server. The bearer token travels
/// in the Authorization header, never in the URL.
pub fn serverFileUrl(base: []const u8, rel: []const u8, buf: []u8) ?[]const u8 {
    const b = normalizeBase(base) orelse return null;
    var w = std.Io.Writer.fixed(buf);
    w.print("{s}/stream?file=", .{b}) catch return null;
    writeQueryValue(&w, rel) catch return null;
    return buf[0..w.end];
}

/// `<base>/api/downloads[?dir=<sub>]` listing on the paired server.
pub fn serverListUrl(base: []const u8, dir: []const u8, buf: []u8) ?[]const u8 {
    const b = normalizeBase(base) orelse return null;
    var w = std.Io.Writer.fixed(buf);
    w.print("{s}/api/downloads", .{b}) catch return null;
    if (dir.len > 0) {
        if (!safeRelPath(dir)) return null;
        w.writeAll("?dir=") catch return null;
        writeQueryValue(&w, dir) catch return null;
    }
    return buf[0..w.end];
}

pub fn serverProgressUrl(base: []const u8, buf: []u8) ?[]const u8 {
    const b = normalizeBase(base) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/api/offline/progress", .{b}) catch null;
}

/// `http(s)://host[:port]` without a trailing slash; null otherwise.
pub fn normalizeBase(raw: []const u8) ?[]const u8 {
    const t = std.mem.trimEnd(u8, std.mem.trim(u8, raw, " \t\r\n"), "/");
    const scheme_len: usize = if (std.ascii.startsWithIgnoreCase(t, "http://")) 7 else if (std.ascii.startsWithIgnoreCase(t, "https://")) 8 else return null;
    if (t.len <= scheme_len) return null;
    for (t) |c| if (c <= 0x20 or c == '?' or c == '#') return null;
    return t;
}

/// Local file name for an item: `<8 hex of the id hash>-<sanitized basename>`.
/// The prefix keeps two sources with the same basename apart.
pub fn localFileName(id: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    const base = basename(name);
    var w = std.Io.Writer.fixed(buf);
    w.print("{x:0>8}-", .{@as(u32, @truncate(std.hash.Wyhash.hash(0, id)))}) catch return null;
    var wrote: usize = 0;
    for (base) |c| {
        if (w.end + 1 >= buf.len or wrote >= FILE_LEN - 16) break;
        const out: u8 = switch (c) {
            0...0x1f, '/', '\\', ':', '*', '?', '"', '<', '>', '|' => '_',
            else => c,
        };
        w.writeByte(out) catch return null;
        wrote += 1;
    }
    if (wrote == 0) w.writeAll("download") catch return null;
    const out = buf[0..w.end];
    if (out[9] == '.') out[9] = '_'; // never a hidden file
    return out;
}

/// Last path or URL segment, without query/fragment.
pub fn basename(name: []const u8) []const u8 {
    var s = name;
    if (std.mem.indexOfAny(u8, s, "?#")) |q| {
        if (std.mem.indexOf(u8, s, "://") != null) s = s[0..q];
    }
    s = std.mem.trimEnd(u8, s, "/\\");
    if (std.mem.lastIndexOfAny(u8, s, "/\\")) |i| s = s[i + 1 ..];
    return s;
}

// ── Server listing (`GET /api/downloads`) ────────────────────────────────────

pub const Entry = struct {
    name: [FILE_LEN]u8 = std.mem.zeroes([FILE_LEN]u8),
    name_len: usize = 0,
    is_dir: bool = false,
    size: u64 = 0,

    pub fn nameText(self: *const Entry) []const u8 {
        return self.name[0..self.name_len];
    }
};

const WireListing = struct {
    files: []const struct { name: []const u8 = "", is_dir: bool = false, size: u64 = 0 } = &.{},
};

/// Parse the server's listing into `out`; returns the entries kept. Names that
/// do not fit or could escape the directory are skipped.
pub fn parseListing(allocator: std.mem.Allocator, json: []const u8, out: []Entry) !usize {
    const parsed = try std.json.parseFromSlice(WireListing, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var n: usize = 0;
    for (parsed.value.files) |f| {
        if (n >= out.len) break;
        if (!safeRelPath(f.name) or std.mem.indexOfAny(u8, f.name, "/\\") != null) continue;
        var e: Entry = .{ .is_dir = f.is_dir, .size = f.size };
        if (!put(&e.name, &e.name_len, f.name)) continue;
        out[n] = e;
        n += 1;
    }
    return n;
}

// ── Watch progress ───────────────────────────────────────────────────────────

/// Record local playback. The first write after a sync bumps the version past
/// everything this device has seen; later writes before the next sync reuse
/// it, so a long offline session is one version, not hundreds.
pub fn localWrite(prev: Progress, pos_s: f64, dur_s: f64, now_ms: i64, device: []const u8) Progress {
    var p = prev;
    p.pos_s = if (std.math.isFinite(pos_s) and pos_s > 0) pos_s else 0;
    p.dur_s = if (std.math.isFinite(dur_s) and dur_s > 0) dur_s else prev.dur_s;
    if (!prev.dirty) p.version = prev.version +| 1;
    p.updated_ms = @max(now_ms, prev.updated_ms);
    p.device_len = @min(device.len, DEVICE_LEN);
    @memcpy(p.device[0..p.device_len], device[0..p.device_len]);
    p.dirty = true;
    return p;
}

pub const Winner = enum { local, remote, same };

/// Merge rule: version, then updated_ms (last writer), then device id.
pub fn merge(local: *const Progress, remote: *const Progress) Winner {
    if (remote.version != local.version) return if (remote.version > local.version) .remote else .local;
    if (remote.updated_ms != local.updated_ms) return if (remote.updated_ms > local.updated_ms) .remote else .local;
    return switch (std.mem.order(u8, remote.deviceId(), local.deviceId())) {
        .gt => .remote,
        .lt => .local,
        .eq => .same,
    };
}

/// A record a peer may write: finite, non-negative numbers and a version.
pub fn validProgress(p: *const Progress) bool {
    if (!std.math.isFinite(p.pos_s) or !std.math.isFinite(p.dur_s)) return false;
    return p.pos_s >= 0 and p.dur_s >= 0 and p.version > 0 and p.updated_ms > 0;
}

/// Client side, after the server answered a push with its winning record.
/// Adopts a newer server record; clears `dirty` once the server holds ours.
pub fn reconcile(local: Progress, server: Progress) Progress {
    if (!validProgress(&server)) return local;
    switch (merge(&local, &server)) {
        .remote => {
            var p = server;
            p.dirty = false;
            return p;
        },
        .same => {
            var p = local;
            p.dirty = false;
            return p;
        },
        .local => return local,
    }
}

pub fn percentOf(p: *const Progress) f64 {
    if (p.dur_s <= 0) return 0;
    return std.math.clamp(p.pos_s * 100.0 / p.dur_s, 0, 100);
}

// ── Wire: one progress record ────────────────────────────────────────────────

pub fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11, 12, 14...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// `{"id":..,"pos":..,"dur":..,"v":..,"t":..,"dev":..}`
pub fn encodeProgress(w: *std.Io.Writer, id: []const u8, p: *const Progress) !void {
    try w.writeAll("{\"id\":");
    try writeJsonString(w, id);
    try w.print(",\"pos\":{d:.3},\"dur\":{d:.3},\"v\":{d},\"t\":{d},\"dev\":", .{ p.pos_s, p.dur_s, p.version, p.updated_ms });
    try writeJsonString(w, p.deviceId());
    try w.writeByte('}');
}

const WireProgress = struct {
    id: []const u8 = "",
    pos: f64 = 0,
    dur: f64 = 0,
    v: u64 = 0,
    t: i64 = 0,
    dev: []const u8 = "",
};

pub const DecodedProgress = struct {
    id: [ID_LEN]u8 = std.mem.zeroes([ID_LEN]u8),
    id_len: usize = 0,
    progress: Progress = .{},

    pub fn idText(self: *const DecodedProgress) []const u8 {
        return self.id[0..self.id_len];
    }
};

/// Parse one record; null when malformed, oversize or invalid.
pub fn decodeProgress(allocator: std.mem.Allocator, json: []const u8) ?DecodedProgress {
    const parsed = std.json.parseFromSlice(WireProgress, allocator, json, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const v = parsed.value;
    var out: DecodedProgress = .{};
    if (v.id.len == 0 or !put(&out.id, &out.id_len, v.id)) return null;
    if (v.dev.len > DEVICE_LEN) return null;
    out.progress = .{ .pos_s = v.pos, .dur_s = v.dur, .version = v.v, .updated_ms = v.t };
    _ = put(&out.progress.device, &out.progress.device_len, v.dev);
    if (!validProgress(&out.progress)) return null;
    return out;
}

// ── Queue persistence (offline.json) ─────────────────────────────────────────

const WireItem = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    source: Source = .server,
    url: []const u8 = "",
    file: []const u8 = "",
    expected: u64 = 0,
    have: u64 = 0,
    status: Status = .queued,
    attempts: u8 = 0,
    added: i64 = 0,
    err: []const u8 = "",
    pos: f64 = 0,
    dur: f64 = 0,
    v: u64 = 0,
    t: i64 = 0,
    dev: []const u8 = "",
    dirty: bool = false,
};

const WireQueue = struct {
    quota: u64 = DEFAULT_QUOTA,
    device: []const u8 = "",
    items: []const WireItem = &.{},
};

pub fn encodeQueue(w: *std.Io.Writer, items: []const Item, quota: u64, device: []const u8) !void {
    try w.print("{{\"quota\":{d},\"device\":", .{quota});
    try writeJsonString(w, device);
    try w.writeAll(",\"items\":[");
    for (items, 0..) |*it, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"id\":");
        try writeJsonString(w, it.idText());
        try w.writeAll(",\"title\":");
        try writeJsonString(w, it.titleText());
        try w.print(",\"source\":\"{s}\",\"url\":", .{@tagName(it.source)});
        try writeJsonString(w, it.urlText());
        try w.writeAll(",\"file\":");
        try writeJsonString(w, it.fileText());
        try w.print(",\"expected\":{d},\"have\":{d},\"status\":\"{s}\",\"attempts\":{d},\"added\":{d},\"err\":", .{ it.expected, it.have, @tagName(it.status), it.attempts, it.added_ms });
        try writeJsonString(w, it.errText());
        const p = &it.progress;
        try w.print(",\"pos\":{d:.3},\"dur\":{d:.3},\"v\":{d},\"t\":{d},\"dev\":", .{ p.pos_s, p.dur_s, p.version, p.updated_ms });
        try writeJsonString(w, p.deviceId());
        try w.print(",\"dirty\":{}}}", .{p.dirty});
    }
    try w.writeAll("]}");
}

/// Restore the queue. A transfer interrupted by quit resumes as queued (its
/// part file is kept and continued with a Range request); verifying restarts
/// verification the same way.
pub fn decodeQueue(allocator: std.mem.Allocator, json: []const u8, out: []Item, quota: *u64, device: *[DEVICE_LEN]u8, device_len: *usize) !usize {
    const parsed = try std.json.parseFromSlice(WireQueue, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    quota.* = if (parsed.value.quota > 0) parsed.value.quota else DEFAULT_QUOTA;
    device_len.* = 0;
    if (parsed.value.device.len <= DEVICE_LEN) _ = put(device, device_len, parsed.value.device);
    var n: usize = 0;
    for (parsed.value.items) |w| {
        if (n >= out.len) break;
        var it = makeItem(w.source, w.id, w.title, w.url, w.file, w.expected, w.added) orelse continue;
        if (w.source == .server and serverRel(w.id) == null) continue;
        if (!safeRelPath(w.file) or std.mem.indexOfAny(u8, w.file, "/\\") != null) continue;
        it.have = w.have;
        it.attempts = w.attempts;
        it.status = switch (w.status) {
            .downloading, .verifying, .waiting_network => .queued,
            else => |s| s,
        };
        it.setErr(w.err);
        it.progress = .{ .pos_s = w.pos, .dur_s = w.dur, .version = w.v, .updated_ms = w.t, .dirty = w.dirty };
        _ = put(&it.progress.device, &it.progress.device_len, w.dev[0..@min(w.dev.len, DEVICE_LEN)]);
        if (!std.math.isFinite(it.progress.pos_s) or !std.math.isFinite(it.progress.dur_s)) it.progress = .{};
        out[n] = it;
        n += 1;
    }
    return n;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn item(id: []const u8, expected: u64, status: Status, added: i64) Item {
    var it = makeItem(.server, id, id, "a.mkv", "f.mkv", expected, added).?;
    it.status = status;
    return it;
}

test "state machine: happy path, pause/resume, network loss, verify failure" {
    var it = item("srv:a.mkv", 10, .queued, 1);
    try testing.expect(it.apply(.start));
    try testing.expect(it.apply(.network_lost));
    try testing.expectEqual(Status.waiting_network, it.status);
    try testing.expect(it.apply(.network_back));
    try testing.expect(it.apply(.start));
    try testing.expect(it.apply(.pause));
    try testing.expect(!it.apply(.bytes_complete)); // a paused item cannot complete
    try testing.expectEqual(Status.paused, it.status);
    try testing.expect(it.apply(.@"resume"));
    try testing.expect(it.apply(.start));
    try testing.expect(it.apply(.bytes_complete));
    try testing.expect(it.apply(.verified));
    try testing.expectEqual(Status.done, it.status);
    try testing.expect(!it.apply(.retry));
    var bad = item("srv:b.mkv", 10, .verifying, 1);
    try testing.expect(bad.apply(.verify_failed));
    try testing.expect(bad.apply(.retry));
    try testing.expectEqual(Status.queued, bad.status);
}

test "state machine: every state rejects events that do not apply" {
    for (std.enums.values(Status)) |s| {
        for (std.enums.values(Event)) |e| {
            // No event is a silent self-loop: every accepted edge moves.
            if (transition(s, e)) |next| try testing.expect(next != s);
        }
    }
    try testing.expectEqual(@as(?Status, null), transition(.done, .start));
    try testing.expectEqual(@as(?Status, null), transition(.paused, .start));
}

test "row actions follow the state" {
    try testing.expect(actionsFor(.done).play);
    try testing.expect(!actionsFor(.downloading).play);
    try testing.expect(actionsFor(.downloading).pause);
    try testing.expect(actionsFor(.paused).@"resume");
    try testing.expect(actionsFor(.failed).retry);
    const v = actionsFor(.verifying);
    try testing.expect(!v.play and !v.pause and !v.@"resume" and !v.retry);
    var it = item("srv:a", 200, .downloading, 1);
    it.have = 50;
    try testing.expectEqual(@as(u8, 25), percentDone(&it));
    it.have = 400; // never above 100 even if the server sent more
    try testing.expectEqual(@as(u8, 100), percentDone(&it));
    it.expected = 0;
    try testing.expectEqual(@as(u8, 0), percentDone(&it));
}

test "retries back off, then park as failed" {
    try testing.expectEqual(@as(i64, 2_000), retryDelayMs(1));
    try testing.expectEqual(@as(i64, 60_000), retryDelayMs(9));
    try testing.expectEqual(Event.network_lost, afterTransientFailure(MAX_ATTEMPTS - 1));
    try testing.expectEqual(Event.fatal, afterTransientFailure(MAX_ATTEMPTS));
}

test "quota: admission counts every item's footprint" {
    const items = [_]Item{ item("srv:a", 600, .done, 1), item("srv:b", 300, .queued, 2) };
    try testing.expectEqual(@as(u64, 900), committedBytes(&items));
    try testing.expectEqual(Admission.ok, admit(&items, 1000, "srv:c", 100));
    try testing.expectEqual(Admission.over_quota, admit(&items, 1000, "srv:c", 101));
    try testing.expectEqual(Admission.duplicate, admit(&items, 1000, "srv:a", 1));
    try testing.expectEqual(Admission.ok, admit(&items, 1000, "srv:c", 0)); // unknown size, room left
    try testing.expectEqual(Admission.over_quota, admit(&items, 900, "srv:c", 0));
    try testing.expectEqual(Admission.invalid, admit(&items, 1000, "", 1));
}

test "quota: an unknown-size transfer stops when it would overflow" {
    var items = [_]Item{ item("srv:a", 600, .done, 1), item("srv:b", 0, .downloading, 2) };
    try testing.expect(!exceedsQuota(&items, 1000, 1, 400));
    try testing.expect(exceedsQuota(&items, 1000, 1, 401));
    items[1].have = 900; // its own bytes are not double counted
    try testing.expect(exceedsQuota(&items, 1000, 1, 900));
}

test "scheduler: one at a time, oldest first, waits out the backoff" {
    var items = [_]Item{ item("srv:a", 1, .queued, 5), item("srv:b", 1, .waiting_network, 2), item("srv:c", 1, .queued, 3) };
    items[1].retry_at_ms = 1_000;
    try testing.expectEqual(@as(?usize, 2), nextToStart(&items, 500));
    try testing.expectEqual(@as(?usize, 1), nextToStart(&items, 1_000));
    items[0].status = .downloading;
    try testing.expectEqual(@as(?usize, null), nextToStart(&items, 1_000));
}

test "range resume: header, content-range parsing and response plans" {
    var buf: [32]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), rangeHeader(0, &buf));
    try testing.expectEqualStrings("bytes=4096-", rangeHeader(4096, &buf).?);
    const cr = parseContentRange("bytes 4096-9999/10000").?;
    try testing.expectEqual(@as(u64, 4096), cr.start);
    try testing.expectEqual(@as(?u64, 10000), cr.total);
    try testing.expectEqual(@as(?u64, null), parseContentRange("bytes 0-9/*").?.total);
    try testing.expectEqual(@as(?ContentRange, null), parseContentRange("bytes 9-0/10"));
    try testing.expectEqual(@as(?ContentRange, null), parseContentRange("bytes 0-10/10"));
    try testing.expectEqual(@as(?ContentRange, null), parseContentRange("items 0-1/2"));

    try testing.expectEqual(Plan{ .append = 10000 }, planResponse(206, 4096, "bytes 4096-9999/10000", 5904));
    // The server answered a different range: never splice it in.
    try testing.expectEqual(Plan.retry, planResponse(206, 4096, "bytes 0-9999/10000", 10000));
    try testing.expectEqual(Plan.retry, planResponse(206, 4096, null, null));
    // Range ignored: start over.
    try testing.expectEqual(Plan{ .restart = 10000 }, planResponse(200, 4096, null, 10000));
    try testing.expectEqual(Plan.complete, planResponse(416, 10000, null, null));
    try testing.expectEqual(Plan.fatal, planResponse(401, 0, null, null));
    try testing.expectEqual(Plan.fatal, planResponse(404, 10, null, null));
    try testing.expectEqual(Plan.retry, planResponse(503, 10, null, null));
}

test "size verification" {
    try testing.expectEqual(Verdict.ok, verifySize(10, 10));
    try testing.expectEqual(Verdict.short, verifySize(9, 10));
    try testing.expectEqual(Verdict.oversize, verifySize(11, 10));
    try testing.expectEqual(Verdict.unknown_ok, verifySize(11, 0));
    try testing.expectEqual(Verdict.short, verifySize(0, 0));
    try testing.expectEqual(@as(u64, 10), expectedSize(10, 10));
    try testing.expectEqual(@as(u64, 12), expectedSize(10, 12)); // changed on the server
    try testing.expectEqual(@as(u64, 12), expectedSize(0, 12));
    try testing.expectEqual(@as(u64, 10), expectedSize(10, null));
}

test "server URLs percent-encode the file and keep the token out" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "http://10.0.0.2:41595/stream?file=Shows/A%20B%26C%3D%23%3F%25%2B.mkv",
        serverFileUrl("http://10.0.0.2:41595/", "Shows/A B&C=#?%+.mkv", &buf).?,
    );
    try testing.expectEqualStrings("https://h/api/downloads?dir=Shows%20x", serverListUrl("https://h", "Shows x", &buf).?);
    try testing.expectEqual(@as(?[]const u8, null), serverListUrl("https://h", "../etc", &buf));
    try testing.expectEqualStrings("http://h:1/api/offline/progress", serverProgressUrl(" http://h:1/ ", &buf).?);
    try testing.expectEqual(@as(?[]const u8, null), normalizeBase("ftp://h"));
    try testing.expectEqual(@as(?[]const u8, null), normalizeBase("http://"));
    try testing.expectEqual(@as(?[]const u8, null), normalizeBase("http://h/?t=secret"));
}

test "identities and relative paths cannot escape the root" {
    var buf: [64]u8 = undefined;
    const id = serverItemId("Shows/ep1.mkv", &buf).?;
    try testing.expectEqualStrings("srv:Shows/ep1.mkv", id);
    try testing.expectEqualStrings("Shows/ep1.mkv", serverRel(id).?);
    try testing.expectEqual(@as(?[]const u8, null), serverRel("srv:../x"));
    try testing.expectEqual(@as(?[]const u8, null), serverRel("srv:/etc/passwd"));
    try testing.expectEqual(@as(?[]const u8, null), serverRel("url:x"));
    try testing.expect(!safeRelPath("a//b"));
    try testing.expect(!safeRelPath("a\\..\\b"));
}

test "local file names are unique per source and safe" {
    var a: [FILE_LEN]u8 = undefined;
    var b: [FILE_LEN]u8 = undefined;
    const na = localFileName("srv:A/ep.mkv", "A/ep.mkv", &a).?;
    const nb = localFileName("srv:B/ep.mkv", "B/ep.mkv", &b).?;
    try testing.expect(!std.mem.eql(u8, na, nb));
    try testing.expect(std.mem.endsWith(u8, na, "-ep.mkv"));
    const weird = localFileName("u", "https://x.test/v/a:b*.mp4?token=1", &a).?;
    try testing.expect(std.mem.indexOfAny(u8, weird, "/\\:?") == null);
    try testing.expect(std.mem.endsWith(u8, weird, "-a_b_.mp4"));
    try testing.expect(std.mem.endsWith(u8, localFileName("u", "https://x.test/", &a).?, "-x.test"));
}

test "listing parse keeps plain names only" {
    const json =
        \\{"path":"/d","jobs":[],"files":[{"name":"a.mkv","is_dir":false,"size":10},
        \\{"name":"Shows","is_dir":true,"size":0},{"name":"..","is_dir":true,"size":0},
        \\{"name":"x/y","is_dir":false,"size":1}]}
    ;
    var out: [8]Entry = undefined;
    const n = try parseListing(testing.allocator, json, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("a.mkv", out[0].nameText());
    try testing.expectEqual(@as(u64, 10), out[0].size);
    try testing.expect(out[1].is_dir);
}

test "progress: offline writes coalesce into one version bump per sync" {
    var p: Progress = .{ .version = 4, .updated_ms = 100 };
    p = localWrite(p, 10, 100, 200, "phone");
    try testing.expectEqual(@as(u64, 5), p.version);
    p = localWrite(p, 20, 100, 300, "phone");
    try testing.expectEqual(@as(u64, 5), p.version);
    try testing.expect(p.dirty);
    p.dirty = false; // acknowledged by the server
    p = localWrite(p, 30, 100, 250, "phone"); // clock stepped back
    try testing.expectEqual(@as(u64, 6), p.version);
    try testing.expectEqual(@as(i64, 300), p.updated_ms);
    // Garbage positions never reach the wire.
    p = localWrite(p, std.math.nan(f64), std.math.inf(f64), 400, "phone");
    try testing.expectEqual(@as(f64, 0), p.pos_s);
    try testing.expectEqual(@as(f64, 100), p.dur_s);
}

test "progress merge: version beats clock, then last writer, then device" {
    var a: Progress = .{ .version = 7, .updated_ms = 100, .device_len = 4 };
    @memcpy(a.device[0..4], "aaaa");
    var b = a;
    b.version = 6;
    b.updated_ms = 999; // a skewed clock cannot override a newer version
    try testing.expectEqual(Winner.local, merge(&a, &b));
    try testing.expectEqual(Winner.remote, merge(&b, &a));
    b.version = 7;
    try testing.expectEqual(Winner.remote, merge(&a, &b));
    b.updated_ms = 100;
    try testing.expectEqual(Winner.same, merge(&a, &b));
    b.device[0] = 'b';
    try testing.expectEqual(Winner.remote, merge(&a, &b));
    try testing.expectEqual(Winner.local, merge(&b, &a)); // symmetric: both pick b
}

test "progress reconcile after a push" {
    var local = localWrite(.{ .version = 2, .updated_ms = 10 }, 50, 100, 20, "phone");
    // Server stored ours and echoed it back.
    const echoed = reconcile(local, local);
    try testing.expect(!echoed.dirty);
    // Another device moved ahead while we were offline at the same version.
    var newer = local;
    newer.updated_ms = 30;
    newer.pos_s = 80;
    newer.device_len = 3;
    @memcpy(newer.device[0..3], "mac");
    const adopted = reconcile(local, newer);
    try testing.expectEqual(@as(f64, 80), adopted.pos_s);
    try testing.expect(!adopted.dirty);
    // An invalid echo changes nothing.
    local.dirty = true;
    try testing.expect(reconcile(local, .{}).dirty);
}

test "progress wire round trip and rejection" {
    const p = localWrite(.{}, 12.5, 3600, 1_700_000_000_000, "phone-1");
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeProgress(&w, "srv:Shows/a \"b\".mkv", &p);
    const d = decodeProgress(testing.allocator, buf[0..w.end]).?;
    try testing.expectEqualStrings("srv:Shows/a \"b\".mkv", d.idText());
    try testing.expectEqual(@as(u64, 1), d.progress.version);
    try testing.expectEqualStrings("phone-1", d.progress.deviceId());
    try testing.expectApproxEqAbs(@as(f64, 12.5), d.progress.pos_s, 1e-9);
    try testing.expectEqual(@as(?DecodedProgress, null), decodeProgress(testing.allocator, "{\"id\":\"x\",\"pos\":1,\"v\":0,\"t\":5}"));
    try testing.expectEqual(@as(?DecodedProgress, null), decodeProgress(testing.allocator, "{\"id\":\"x\",\"pos\":-1,\"v\":1,\"t\":5}"));
    try testing.expectEqual(@as(?DecodedProgress, null), decodeProgress(testing.allocator, "not json"));
}

test "queue persistence round trip; interrupted transfers resume as queued" {
    var items = [_]Item{ item("srv:a.mkv", 100, .downloading, 1), item("srv:b.mkv", 50, .done, 2) };
    items[0].have = 40;
    items[1].progress = localWrite(.{}, 5, 50, 9, "phone");
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodeQueue(&w, &items, 1234, "phone");
    var out: [4]Item = undefined;
    var quota: u64 = 0;
    var dev: [DEVICE_LEN]u8 = undefined;
    var dev_len: usize = 0;
    const n = try decodeQueue(testing.allocator, buf[0..w.end], &out, &quota, &dev, &dev_len);
    try testing.expectEqualStrings("phone", dev[0..dev_len]);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u64, 1234), quota);
    try testing.expectEqual(Status.queued, out[0].status);
    try testing.expectEqual(@as(u64, 40), out[0].have);
    try testing.expectEqual(Status.done, out[1].status);
    try testing.expect(out[1].progress.dirty);
    try testing.expectEqual(@as(u64, 1), out[1].progress.version);
    // A tampered file name or identity is dropped, not trusted.
    const evil = "{\"items\":[{\"id\":\"srv:../x\",\"url\":\"u\",\"file\":\"f\"},{\"id\":\"srv:a\",\"url\":\"u\",\"file\":\"../f\"}]}";
    try testing.expectEqual(@as(usize, 0), try decodeQueue(testing.allocator, evil, &out, &quota, &dev, &dev_len));
}
