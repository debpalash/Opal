//! Pure wire format + merge rule for cross-device `library_items` sync
//! (ROADMAP 6.3). Two Opal instances exchange rows over `/api/library/sync`;
//! this module owns the JSON shape and the last-writer-wins decision so the
//! shipped logic is the tested logic.
//!
//! Synced: identity, display snapshot, progress, favorite, rating, and the row's
//! own `updated_at`. NOT synced: `home_hidden`/`home_pinned` — Home layout is a
//! per-device choice.
//!
//! Deletes travel as tombstones: the row stays, `deleted` is set and
//! `updated_at` moves forward, so the same LWW rule removes it on the peer (a
//! newer tombstone hides; a newer upsert resurrects).

const std = @import("std");
const library_pure = @import("library_pure.zig");

pub const LibraryItem = library_pure.LibraryItem;

/// One row on the wire: the library item plus the writer's timestamp.
pub const SyncRow = struct {
    item: LibraryItem = .{},
    updated_at: i64 = 0,
    /// Tombstone: the item was removed on the writer. Display fields ride
    /// along unchanged (they let an undo restore the row) but readers hide it.
    deleted: bool = false,
    /// Local change sequence (store-only, not on the wire).
    seq: i64 = 0,
};

/// Sync protocol version, sent as `"v"` in every payload. v2: seq cursors +
/// device ids (v1 paged on `updated_at` and could strand relayed rows).
pub const PROTOCOL: u32 = 2;

/// Rows per GET page. Worst case ~1.5 KB per row encoded, so a page fits the
/// 256 KB response buffer with room to spare.
pub const PAGE_ROWS: usize = 100;
/// Upper bound on rows accepted in one POST.
pub const MAX_POST_ROWS: usize = 128;
/// Byte budget for one pushed POST body. The peer's gated body cap is 64 KB
/// (remote_body_pure.GROW_MAX_BODY); stay under it with header room to spare.
pub const PUSH_MAX_BYTES: usize = 60 * 1024;

// ── Merge rule ────────────────────────────────────────────────────────────────

/// Last-writer-wins on `updated_at` per (kind,item_id). The favorite flag rides
/// with the row, so the newer row's favorite wins. Equal timestamps break on a
/// content order both peers compute identically, so a tie converges instead of
/// ping-ponging: a tombstone first (a delete in the same second as an edit is
/// the later intent), then favorite, further progress, rating, link.
pub fn shouldApply(local: ?*const SyncRow, remote: *const SyncRow) bool {
    if (!isValid(remote)) return false;
    const l = local orelse return true;
    if (remote.updated_at != l.updated_at) return remote.updated_at > l.updated_at;
    if (remote.deleted != l.deleted) return remote.deleted;
    return tieOrder(&remote.item, &l.item) == .gt;
}

fn tieOrder(a: *const LibraryItem, b: *const LibraryItem) std.math.Order {
    if (a.is_favorite != b.is_favorite) return if (a.is_favorite) .gt else .lt;
    const prog = std.math.order(a.resume_secs, b.resume_secs);
    if (prog != .eq) return prog;
    const rating = std.math.order(a.user_rating, b.user_rating);
    if (rating != .eq) return rating;
    const dur = std.math.order(a.duration_secs, b.duration_secs);
    if (dur != .eq) return dur;
    const link = std.mem.order(u8, a.deep_link[0..a.deep_link_len], b.deep_link[0..b.deep_link_len]);
    if (link != .eq) return link;
    const title = std.mem.order(u8, a.title[0..a.title_len], b.title[0..b.title_len]);
    if (title != .eq) return title;
    return std.mem.order(u8, a.poster[0..a.poster_len], b.poster[0..b.poster_len]);
}

/// A row a peer may write: identity present, timestamp positive, numbers finite.
pub fn isValid(row: *const SyncRow) bool {
    const it = &row.item;
    if (it.kind_len == 0 or it.item_id_len == 0 or row.updated_at <= 0) return false;
    for ([_]f64{ it.resume_secs, it.duration_secs, it.user_rating }) |v| {
        if (!std.math.isFinite(v)) return false;
    }
    return it.resume_secs >= 0 and it.duration_secs >= 0;
}

// ── Change sequence + echo rule (paging) ─────────────────────────────────────
//
// Paging and cursors run on each store's LOCAL change sequence (`seq`), never on
// `updated_at`. Every write — a local edit OR an applied peer row — takes the
// next `seq` (SQLite triggers, db.zig), so a row pulled from A with A's old
// `updated_at` still sorts after every cursor this device already handed to C
// and reaches C on the next run. `updated_at` only decides LWW (shouldApply).
//
// `seq` is unique per store, so a single integer is an exact keyset: a page
// ends at its last row's seq and the next request resumes strictly after it.
//
// Echo: an applied row remembers its `origin` (the sending device's id); it is
// never served or pushed back to that same device, but still goes to others.

/// Device ids: lowercase hex from `hex(randomblob(16))`.
pub const DEVICE_ID_MAX: usize = 32;

pub fn validDeviceId(id: []const u8) bool {
    if (id.len < 8 or id.len > DEVICE_ID_MAX) return false;
    for (id) |c| switch (c) {
        '0'...'9', 'a'...'z', 'A'...'Z' => {},
        else => return false,
    };
    return true;
}

/// Echo rule: a row that came from `peer_device` is not sent back to it. An
/// unknown peer (empty id) gets everything.
pub fn skipForPeer(origin: []const u8, peer_device: []const u8) bool {
    return peer_device.len > 0 and std.mem.eql(u8, origin, peer_device);
}

/// Row selection for one page, mirrored by `library_store.loadChangedSince`'s
/// SQL: after the cursor, at or below the run's snapshot, not an echo.
pub fn eligible(seq: i64, origin: []const u8, after: i64, snapshot_max: i64, peer_device: []const u8) bool {
    return seq > after and seq <= snapshot_max and !skipForPeer(origin, peer_device);
}

pub const PageEnd = struct { next: i64, has_more: bool };

/// Cursor after a page of `count` eligible rows (limit `limit`). A full page
/// resumes exactly after its last row. A short page saw every eligible row up
/// to `snapshot_max`, echoes it skipped included, so it jumps there.
pub fn pageEnd(count: usize, limit: usize, last_seq: i64, snapshot_max: i64) PageEnd {
    if (count > 0 and count >= limit) return .{ .next = last_seq, .has_more = true };
    return .{ .next = snapshot_max, .has_more = false };
}

/// A saved pull cursor is meaningless when the peer is a different store (new
/// device id) or its sequence went backwards (restored backup): pull from 0.
pub fn needRestart(since: i64, expected_device: []const u8, got_device: []const u8, next: i64) bool {
    if (since <= 0) return false;
    if (expected_device.len > 0 and got_device.len > 0 and !std.mem.eql(u8, expected_device, got_device)) return true;
    return next < since;
}

// ── Device identity (clone detection) ────────────────────────────────────────
//
// The device id lives in the db (`library_sync_meta.device_id`), so a copied
// opal.db (new machine, restored backup on a second box) would make two live
// stores share one id — peers then mistake one for the other: rows from the
// copy are tagged with the original's id and never relayed to the original
// (echo rule), and cursors earned against one are applied to the other.
//
// Defence: the id is ALSO recorded outside the db, in `<config dir>/sync_device`,
// and the db carries `bound=1` once that file was written for it. On open:
//
//   file == db id, bound      keep
//   file == db id, not bound  adopt (mark bound)
//   file missing, not bound   adopt (fresh store, or first run of this version)
//   file missing, bound       reroll (the db was bound on another install)
//   file != db id             reroll (this install's db was replaced by a copy)
//   db id invalid             reroll
//
// Reroll = fresh random id (never the file's old id: the db now holds another
// store's seq space, so peers' cursors for the old id would skip rows), file
// rewritten, and every local peer cursor reset (one idempotent full resync).
//
// Why a reroll does not echo-storm: the copy holds the original's rows with
// origin '' (its local writes) or a third peer's id — never the original's own
// id (the echo rule never stores a row back on its sender). After the reroll
// the copy serves those rows to the original as its own; they are identical
// (same updated_at + content), so shouldApply's tie rule rejects them, nothing
// is written, no seq moves, nothing relays. Each direction costs one full
// transfer, then cursors are quiet. Rows that diverged after the copy merge
// once by LWW like any other change.
//
// Limits: a copy taken by a pre-binding build (db never bound) and a copy of
// the WHOLE config dir (db + sync_device together) are indistinguishable from
// the original and keep the shared id. Rows a third peer already tagged with
// the shared id stay tagged until their next write.

pub const IdentityAction = enum { keep, adopt, reroll };

pub fn identityAction(db_id: []const u8, db_bound: bool, file_id: []const u8) IdentityAction {
    if (!validDeviceId(db_id)) return .reroll;
    if (!validDeviceId(file_id)) return if (db_bound) .reroll else .adopt;
    if (!std.mem.eql(u8, file_id, db_id)) return .reroll;
    return if (db_bound) .keep else .adopt;
}

/// After a reroll this store is a new device to everyone: forget cursors so
/// the next run re-exchanges everything (idempotent under LWW). The learned
/// peer ids stay — the peers themselves did not change.
pub fn resetCursorsAfterReroll(peers: []Peer) void {
    for (peers) |*p| {
        p.pull_seq = 0;
        p.push_seq = 0;
    }
}

// ── Parallel runs ────────────────────────────────────────────────────────────
//
// One worker per peer (at most MAX_PEERS at once), so a slow or dead peer only
// delays itself. `slot_urls[i]` is the peer address worker slot i is serving,
// '' when the slot is free (idle AND its last outcome consumed).

/// Slot for a run against `url`: null when that peer already has a run in
/// flight (never two runs on one peer's cursors) or every slot is taken.
pub fn pickSlot(slot_urls: []const []const u8, url: []const u8) ?usize {
    var free: ?usize = null;
    for (slot_urls, 0..) |s, i| {
        if (s.len == 0) {
            if (free == null) free = i;
        } else if (std.mem.eql(u8, s, url)) return null;
    }
    return free;
}

// ── Peers (state.app.lsync) ──────────────────────────────────────────────────

pub const MAX_PEERS: usize = 4;

/// One paired device. `url`/`token` are NUL-terminated text-entry buffers the
/// settings fields edit in place. Cursors belong to `cursor_url` (the
/// normalized address they were earned against) and to the peer's `device`.
pub const Peer = struct {
    url: [256]u8 = std.mem.zeroes([256]u8),
    token: [256]u8 = std.mem.zeroes([256]u8),
    cursor_url: [256]u8 = std.mem.zeroes([256]u8),
    cursor_url_len: usize = 0,
    device: [DEVICE_ID_MAX]u8 = std.mem.zeroes([DEVICE_ID_MAX]u8),
    device_len: usize = 0,
    /// The peer's seq we pulled up to.
    pull_seq: i64 = 0,
    /// Our seq we pushed up to.
    push_seq: i64 = 0,
    last_sync: i64 = 0,
    status: [160]u8 = std.mem.zeroes([160]u8),
    status_len: usize = 0,

    pub fn urlText(self: *const Peer) []const u8 {
        return zText(&self.url);
    }
    pub fn tokenText(self: *const Peer) []const u8 {
        return zText(&self.token);
    }
    pub fn cursorUrl(self: *const Peer) []const u8 {
        return self.cursor_url[0..self.cursor_url_len];
    }
    pub fn deviceId(self: *const Peer) []const u8 {
        return self.device[0..self.device_len];
    }
    pub fn setStatus(self: *Peer, text: []const u8) void {
        const n = @min(text.len, self.status.len);
        @memcpy(self.status[0..n], text[0..n]);
        self.status_len = n;
    }
    pub fn setDevice(self: *Peer, id: []const u8) void {
        if (!validDeviceId(id)) return;
        @memcpy(self.device[0..id.len], id);
        self.device_len = id.len;
    }
};

pub fn zText(buf: []const u8) []const u8 {
    return buf[0 .. std.mem.indexOfScalar(u8, buf, 0) orelse buf.len];
}

/// Point a peer's cursors at the normalized `url`. A different address is a
/// different store: both cursors and the learned device id reset. Returns
/// true when something reset (caller marks config dirty).
pub fn bindCursors(p: *Peer, url: []const u8) bool {
    if (std.mem.eql(u8, url, p.cursorUrl())) return false;
    const n = @min(url.len, p.cursor_url.len);
    @memcpy(p.cursor_url[0..n], url[0..n]);
    p.cursor_url_len = n;
    p.pull_seq = 0;
    p.push_seq = 0;
    p.device_len = 0;
    return true;
}

/// What one finished run against one peer produced.
pub const RunResult = struct {
    /// Pull cursor reached; null when the pull failed (nothing changes).
    pulled_to: ?i64 = null,
    /// Push cursor reached; null when the push failed or did not run.
    pushed_to: ?i64 = null,
    device: [DEVICE_ID_MAX]u8 = std.mem.zeroes([DEVICE_ID_MAX]u8),
    device_len: usize = 0,
};

/// Fold a run into its peer. Ignored (false) when the user re-pointed the peer
/// at another address meanwhile: those cursors belong to the old one.
pub fn applyRun(p: *Peer, run_url: []const u8, r: *const RunResult, finished_at: i64) bool {
    if (!std.mem.eql(u8, run_url, p.cursorUrl())) return false;
    const pulled = r.pulled_to orelse return true;
    p.pull_seq = @max(0, pulled);
    if (r.device_len > 0) p.setDevice(r.device[0..r.device_len]);
    if (r.pushed_to) |q| {
        p.push_seq = @max(0, q);
        p.last_sync = finished_at;
    }
    return true;
}

/// Index of the peer whose cursors belong to `cursor_url`.
pub fn findPeer(peers: []const Peer, cursor_url: []const u8) ?usize {
    if (cursor_url.len == 0) return null;
    for (peers, 0..) |*p, i| if (std.mem.eql(u8, p.cursorUrl(), cursor_url)) return i;
    return null;
}

/// Append a blank peer; null when full.
pub fn addPeer(peers: []Peer, count: *usize) ?usize {
    if (count.* >= peers.len) return null;
    peers[count.*] = .{};
    count.* += 1;
    return count.* - 1;
}

/// Remove peer `idx`, keeping the others (and their cursors) in order. The
/// freed slot is zeroed so the token does not linger.
pub fn removePeer(peers: []Peer, count: *usize, idx: usize) void {
    if (idx >= count.*) return;
    var i = idx;
    while (i + 1 < count.*) : (i += 1) peers[i] = peers[i + 1];
    count.* -= 1;
    @memset(std.mem.asBytes(&peers[count.*]), 0);
    peers[count.*] = .{};
}

/// Normalize a peer base URL (`http(s)://host:port`, no trailing slash).
pub fn normalizePeer(raw: []const u8) ?[]const u8 {
    const peer = std.mem.trimEnd(u8, std.mem.trim(u8, raw, " \t"), "/");
    if (!(std.mem.startsWith(u8, peer, "http://") or std.mem.startsWith(u8, peer, "https://"))) return null;
    const host_start = std.mem.indexOf(u8, peer, "://").? + 3;
    if (peer.len == host_start or peer.len > 400) return null;
    for (peer) |c| if (c <= ' ' or c >= 0x7f or c == '"' or c == '\\') return null;
    return peer;
}

/// A bearer token we will put in a header: printable ASCII, bounded.
pub fn validToken(token: []const u8) bool {
    if (token.len == 0 or token.len > 200) return false;
    for (token) |c| if (c <= ' ' or c >= 0x7f) return false;
    return true;
}

/// Percent-encode a query value: everything except RFC 3986 unreserved bytes.
pub fn writeQueryEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try w.writeByte(c),
        else => try w.print("%{X:0>2}", .{c}),
    };
}

// ── Encode ────────────────────────────────────────────────────────────────────

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
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

fn finite(v: f64) f64 {
    return if (std.math.isFinite(v)) v else 0;
}

/// One row as a JSON object.
pub fn encodeRow(w: *std.Io.Writer, row: *const SyncRow) !void {
    const it = &row.item;
    try w.writeAll("{\"kind\":");
    try writeJsonString(w, it.kind[0..it.kind_len]);
    try w.writeAll(",\"item_id\":");
    try writeJsonString(w, it.item_id[0..it.item_id_len]);
    try w.writeAll(",\"title\":");
    try writeJsonString(w, it.title[0..it.title_len]);
    try w.writeAll(",\"poster\":");
    try writeJsonString(w, it.poster[0..it.poster_len]);
    try w.print(",\"resume_secs\":{d},\"duration_secs\":{d},\"is_favorite\":{s},\"user_rating\":{d}", .{
        finite(it.resume_secs), finite(it.duration_secs), if (it.is_favorite) "true" else "false", finite(it.user_rating),
    });
    try w.writeAll(",\"next_label\":");
    try writeJsonString(w, it.next_label[0..it.next_label_len]);
    try w.writeAll(",\"deep_link\":");
    try writeJsonString(w, it.deep_link[0..it.deep_link_len]);
    try w.print(",\"updated_at\":{d},\"deleted\":{s}}}", .{ row.updated_at, if (row.deleted) "true" else "false" });
}

fn writeHeader(w: *std.Io.Writer, device: []const u8) !void {
    try w.print("{{\"v\":{d},\"device\":", .{PROTOCOL});
    try writeJsonString(w, if (validDeviceId(device)) device else "");
    try w.writeAll(",\"rows\":[");
}

/// `{"v":2,"device":D,"rows":[...],"next_seq":N,"has_more":B}` — the GET
/// response. `device` is the sender's id (rows applied from it get that
/// origin); a client resumes after `next_seq` while `has_more`.
pub fn encodePayload(w: *std.Io.Writer, rows: []const SyncRow, next_seq: i64, has_more: bool, device: []const u8) !void {
    try writeHeader(w, device);
    for (rows, 0..) |*row, i| {
        if (i > 0) try w.writeByte(',');
        try encodeRow(w, row);
    }
    try w.print("],\"next_seq\":{d},\"has_more\":{s}}}", .{ next_seq, if (has_more) "true" else "false" });
}

pub const Batch = struct {
    /// Encoded POST body (aliases the caller's buffer).
    body: []const u8,
    /// Leading rows of the input that made it into `body`.
    count: usize,
};

/// Encode as many leading `rows` as fit in `out` (≤ MAX_POST_ROWS) as one push
/// body. Always at least one row when `rows` is non-empty and `out` holds a
/// single worst-case row, so a push loop always makes progress.
pub fn encodeBatch(out: []u8, rows: []const SyncRow, device: []const u8) !Batch {
    const trailer = "],\"next_seq\":0,\"has_more\":false}";
    var w = std.Io.Writer.fixed(out);
    try writeHeader(&w, device);
    var n: usize = 0;
    var scratch: [8 * 1024]u8 = undefined;
    while (n < rows.len and n < MAX_POST_ROWS) : (n += 1) {
        var rw = std.Io.Writer.fixed(&scratch);
        try encodeRow(&rw, &rows[n]);
        const sep: usize = if (n > 0) 1 else 0;
        if (w.end + sep + rw.end + trailer.len > out.len) {
            if (n == 0) return error.WriteFailed;
            break;
        }
        if (sep == 1) try w.writeByte(',');
        try w.writeAll(scratch[0..rw.end]);
    }
    try w.writeAll(trailer);
    return .{ .body = out[0..w.end], .count = n };
}

// ── Decode ────────────────────────────────────────────────────────────────────

const WireRow = struct {
    kind: []const u8 = "",
    item_id: []const u8 = "",
    title: []const u8 = "",
    poster: []const u8 = "",
    resume_secs: f64 = 0,
    duration_secs: f64 = 0,
    is_favorite: bool = false,
    user_rating: f64 = -1,
    next_label: []const u8 = "",
    deep_link: []const u8 = "",
    updated_at: i64 = 0,
    deleted: bool = false,
};

const WirePayload = struct {
    v: u32 = 1,
    device: []const u8 = "",
    rows: []const WireRow = &.{},
    next_seq: i64 = 0,
    has_more: bool = false,
};

pub const Decoded = struct {
    /// Rows written to `out` (valid ones only).
    count: usize = 0,
    /// Rows dropped: invalid identity/timestamp/numbers, an oversize field, or
    /// no room left in `out`.
    rejected: usize = 0,
    version: u32 = 1,
    next_seq: i64 = 0,
    has_more: bool = false,
    /// Sender's device id; empty when absent or malformed.
    device: [DEVICE_ID_MAX]u8 = std.mem.zeroes([DEVICE_ID_MAX]u8),
    device_len: usize = 0,

    pub fn deviceId(self: *const Decoded) []const u8 {
        return self.device[0..self.device_len];
    }
};

/// Copy `src` into a fixed buffer; false if it does not fit (never truncate an
/// identity — a truncated id would merge into a different item).
fn put(dst: []u8, len: *usize, src: []const u8) bool {
    if (src.len > dst.len) return false;
    @memcpy(dst[0..src.len], src);
    len.* = src.len;
    return true;
}

fn fromWire(w: *const WireRow, out: *SyncRow) bool {
    out.* = .{};
    const it = &out.item;
    if (!put(&it.kind, &it.kind_len, w.kind)) return false;
    if (!put(&it.item_id, &it.item_id_len, w.item_id)) return false;
    if (!put(&it.title, &it.title_len, w.title)) return false;
    if (!put(&it.poster, &it.poster_len, w.poster)) return false;
    if (!put(&it.next_label, &it.next_label_len, w.next_label)) return false;
    if (!put(&it.deep_link, &it.deep_link_len, w.deep_link)) return false;
    it.resume_secs = w.resume_secs;
    it.duration_secs = w.duration_secs;
    it.percent = library_pure.percentOf(w.resume_secs, w.duration_secs);
    it.is_favorite = w.is_favorite;
    it.user_rating = if (w.user_rating < 0) -1 else @min(w.user_rating, 10);
    out.updated_at = w.updated_at;
    out.deleted = w.deleted;
    return isValid(out);
}

/// Parse a sync payload into `out`. Malformed JSON is an error; individual bad
/// rows are counted in `rejected` and skipped.
pub fn decodePayload(allocator: std.mem.Allocator, json: []const u8, out: []SyncRow) !Decoded {
    const parsed = try std.json.parseFromSlice(WirePayload, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var res: Decoded = .{ .version = parsed.value.v, .next_seq = parsed.value.next_seq, .has_more = parsed.value.has_more };
    if (validDeviceId(parsed.value.device)) _ = put(&res.device, &res.device_len, parsed.value.device);
    for (parsed.value.rows) |*w| {
        if (res.count >= out.len or !fromWire(w, &out[res.count])) {
            res.rejected += 1;
            continue;
        }
        res.count += 1;
    }
    return res;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

fn mk(kind: []const u8, id: []const u8, ts: i64, fav: bool, resume_secs: f64) SyncRow {
    var r: SyncRow = .{ .updated_at = ts };
    _ = put(&r.item.kind, &r.item.kind_len, kind);
    _ = put(&r.item.item_id, &r.item.item_id_len, id);
    r.item.is_favorite = fav;
    r.item.resume_secs = resume_secs;
    r.item.duration_secs = 100;
    return r;
}

test "newer remote row wins, carrying its favorite flag" {
    const local = mk("movie", "tt1", 100, true, 10);
    const remote = mk("movie", "tt1", 200, false, 50);
    try std.testing.expect(shouldApply(&local, &remote));
}

test "older remote row is ignored" {
    const local = mk("movie", "tt1", 200, false, 10);
    const remote = mk("movie", "tt1", 100, true, 90);
    try std.testing.expect(!shouldApply(&local, &remote));
}

test "unknown local row: any valid remote row applies" {
    const remote = mk("tv", "42", 1, false, 0);
    try std.testing.expect(shouldApply(null, &remote));
}

test "equal timestamps resolve deterministically and symmetrically" {
    const a = mk("movie", "tt1", 100, true, 10);
    const b = mk("movie", "tt1", 100, false, 90);
    // Favorite wins the tie regardless of which side holds it.
    try std.testing.expect(shouldApply(&b, &a));
    try std.testing.expect(!shouldApply(&a, &b));
    // Same favorite: further progress wins, from either side.
    const c = mk("movie", "tt1", 100, false, 10);
    try std.testing.expect(shouldApply(&c, &b));
    try std.testing.expect(!shouldApply(&b, &c));
    // Identical rows never apply (no ping-pong, no needless write).
    try std.testing.expect(!shouldApply(&a, &a));
}

test "invalid remote rows never apply" {
    var r = mk("movie", "tt1", 0, true, 1);
    try std.testing.expect(!shouldApply(null, &r));
    r = mk("", "tt1", 5, true, 1);
    try std.testing.expect(!shouldApply(null, &r));
    r = mk("movie", "tt1", 5, true, std.math.nan(f64));
    try std.testing.expect(!shouldApply(null, &r));
    r = mk("movie", "tt1", 5, true, -3);
    try std.testing.expect(!shouldApply(null, &r));
}

test "encode then decode round-trips a row, escapes included" {
    var row = mk("movie", "tt\"1\\x", 1700000000, true, 12.5);
    _ = put(&row.item.title, &row.item.title_len, "Line\nTwo \"quoted\"");
    _ = put(&row.item.deep_link, &row.item.deep_link_len, "opal://movie/tt1?x=1&y=2");
    row.item.user_rating = 7.5;
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodePayload(&w, &[_]SyncRow{row}, 42, false, "0123456789abcdef");
    var out: [2]SyncRow = undefined;
    const d = try decodePayload(std.testing.allocator, buf[0..w.end], &out);
    try std.testing.expectEqual(@as(usize, 1), d.count);
    try std.testing.expectEqual(@as(usize, 0), d.rejected);
    try std.testing.expectEqual(@as(i64, 42), d.next_seq);
    try std.testing.expectEqual(PROTOCOL, d.version);
    try std.testing.expectEqualStrings("0123456789abcdef", d.deviceId());
    const got = &out[0];
    try std.testing.expectEqualStrings("tt\"1\\x", got.item.item_id[0..got.item.item_id_len]);
    try std.testing.expectEqualStrings("Line\nTwo \"quoted\"", got.item.title[0..got.item.title_len]);
    try std.testing.expectEqualStrings("opal://movie/tt1?x=1&y=2", got.item.deep_link[0..got.item.deep_link_len]);
    try std.testing.expect(got.item.is_favorite);
    try std.testing.expectEqual(@as(f64, 12.5), got.item.resume_secs);
    try std.testing.expectEqual(@as(f64, 7.5), got.item.user_rating);
    try std.testing.expectEqual(@as(f64, 12.5), got.item.percent);
    try std.testing.expectEqual(@as(i64, 1700000000), got.updated_at);
    // The decoded row is the same row: the tie rule must not re-apply it.
    try std.testing.expect(!shouldApply(&row, got));
}

test "decode rejects oversize ids and bad rows but keeps the good ones" {
    const long_id = "x" ** 200;
    const json = "{\"rows\":[{\"kind\":\"movie\",\"item_id\":\"" ++ long_id ++ "\",\"updated_at\":5}," ++
        "{\"kind\":\"movie\",\"item_id\":\"ok\",\"updated_at\":5,\"extra\":1}," ++
        "{\"kind\":\"movie\",\"item_id\":\"nots\"}]}";
    var out: [4]SyncRow = undefined;
    const d = try decodePayload(std.testing.allocator, json, &out);
    try std.testing.expectEqual(@as(usize, 1), d.count);
    try std.testing.expectEqual(@as(usize, 2), d.rejected);
    try std.testing.expectEqualStrings("ok", out[0].item.item_id[0..out[0].item.item_id_len]);
}

test "decode caps rows at the output capacity" {
    const json = "{\"rows\":[{\"kind\":\"tv\",\"item_id\":\"1\",\"updated_at\":1},{\"kind\":\"tv\",\"item_id\":\"2\",\"updated_at\":1}]}";
    var out: [1]SyncRow = undefined;
    const d = try decodePayload(std.testing.allocator, json, &out);
    try std.testing.expectEqual(@as(usize, 1), d.count);
    try std.testing.expectEqual(@as(usize, 1), d.rejected);
}

test "malformed payload is an error" {
    var out: [1]SyncRow = undefined;
    for ([_][]const u8{ "{\"rows\":[", "not json", "{\"rows\":5}" }) |bad| {
        if (decodePayload(std.testing.allocator, bad, &out)) |_| return error.TestUnexpectedResult else |_| {}
    }
}

test "payload carries next_seq, has_more and a validated device id" {
    const rows = [_]SyncRow{ mk("movie", "a", 7, false, 1), mk("tv", "b c&d", 7, false, 1) };
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodePayload(&w, &rows, 77, true, "dev00001");
    var out: [2]SyncRow = undefined;
    const d = try decodePayload(std.testing.allocator, buf[0..w.end], &out);
    try std.testing.expect(d.has_more);
    try std.testing.expectEqual(@as(i64, 77), d.next_seq);
    try std.testing.expectEqualStrings("dev00001", d.deviceId());
    // A malformed device id is dropped, never half-used as an origin.
    w = std.Io.Writer.fixed(&buf);
    try encodePayload(&w, &.{}, 9, false, "bad id\"x");
    const e = try decodePayload(std.testing.allocator, buf[0..w.end], &out);
    try std.testing.expectEqual(@as(usize, 0), e.deviceId().len);
    const forged = "{\"device\":\"../../etc\",\"rows\":[]}";
    const f = try decodePayload(std.testing.allocator, forged, &out);
    try std.testing.expectEqual(@as(usize, 0), f.deviceId().len);
    try std.testing.expectEqual(@as(u32, 1), f.version);
}

test "peer URL and token validation" {
    try std.testing.expectEqualStrings("http://10.0.0.2:41595", normalizePeer(" http://10.0.0.2:41595/ ").?);
    try std.testing.expect(normalizePeer("https://x") != null);
    for ([_][]const u8{ "", "ftp://x", "http://", "http://a b", "10.0.0.2:41595", "file:///etc" }) |bad| {
        try std.testing.expect(normalizePeer(bad) == null);
    }
    try std.testing.expect(validToken("abcDEF123-_"));
    try std.testing.expect(!validToken(""));
    try std.testing.expect(!validToken("a b"));
    try std.testing.expect(!validToken("a\r\nX-Evil: 1"));
}

test "query escaping covers space & = # ? % + and non-ASCII" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeQueryEscaped(&w, "a b&c=d#e?f%g+h/\xc3\xa9");
    try std.testing.expectEqualStrings("a%20b%26c%3Dd%23e%3Ff%25g%2Bh%2F%C3%A9", buf[0..w.end]);
}

test "newer tombstone removes; newer upsert resurrects" {
    const live = mk("movie", "tt1", 100, true, 40);
    var tomb = mk("movie", "tt1", 200, true, 40);
    tomb.deleted = true;
    try std.testing.expect(shouldApply(&live, &tomb));
    // A stale tombstone does not delete a newer edit.
    var old_tomb = mk("movie", "tt1", 50, false, 0);
    old_tomb.deleted = true;
    try std.testing.expect(!shouldApply(&live, &old_tomb));
    // Re-watching after the delete (newer upsert) brings the row back.
    const again = mk("movie", "tt1", 300, false, 5);
    try std.testing.expect(shouldApply(&tomb, &again));
    // A tombstone for an item this device never had still records the delete.
    try std.testing.expect(shouldApply(null, &tomb));
}

test "tombstone wins a same-second tie from either side" {
    const live = mk("movie", "tt1", 100, true, 90);
    var tomb = mk("movie", "tt1", 100, false, 0);
    tomb.deleted = true;
    try std.testing.expect(shouldApply(&live, &tomb));
    try std.testing.expect(!shouldApply(&tomb, &live));
    try std.testing.expect(!shouldApply(&tomb, &tomb));
}

test "deleted flag round-trips; missing flag decodes as live" {
    var row = mk("tv", "42", 1700000000, false, 0);
    row.deleted = true;
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encodePayload(&w, &[_]SyncRow{row}, 1, false, "");
    var out: [1]SyncRow = undefined;
    const d = try decodePayload(std.testing.allocator, buf[0..w.end], &out);
    try std.testing.expectEqual(@as(usize, 1), d.count);
    try std.testing.expect(out[0].deleted);
    const legacy = "{\"rows\":[{\"kind\":\"tv\",\"item_id\":\"1\",\"updated_at\":1}]}";
    _ = try decodePayload(std.testing.allocator, legacy, &out);
    try std.testing.expect(!out[0].deleted);
}

test "push batch caps at MAX_POST_ROWS and decodes back" {
    var rows: [MAX_POST_ROWS + 5]SyncRow = undefined;
    for (&rows, 0..) |*r, i| {
        var id_buf: [8]u8 = undefined;
        r.* = mk("tv", std.fmt.bufPrint(&id_buf, "{d}", .{i}) catch unreachable, 10 + @as(i64, @intCast(i)), false, 1);
    }
    const buf = try std.testing.allocator.alloc(u8, PUSH_MAX_BYTES);
    defer std.testing.allocator.free(buf);
    const b = try encodeBatch(buf, &rows, "feedc0de");
    try std.testing.expectEqual(MAX_POST_ROWS, b.count);
    const out = try std.testing.allocator.alloc(SyncRow, MAX_POST_ROWS);
    defer std.testing.allocator.free(out);
    const d = try decodePayload(std.testing.allocator, b.body, out);
    try std.testing.expectEqual(MAX_POST_ROWS, d.count);
    try std.testing.expectEqual(@as(usize, 0), d.rejected);
    try std.testing.expectEqualStrings("feedc0de", d.deviceId());
}

test "push batch stops at the byte budget but always sends one row" {
    var rows: [8]SyncRow = undefined;
    for (&rows) |*r| {
        r.* = mk("movie", "tt1", 5, false, 1);
        _ = put(&r.item.deep_link, &r.item.deep_link_len, "x" ** 500);
    }
    var small: [1400]u8 = undefined;
    const b = try encodeBatch(&small, &rows, "");
    try std.testing.expect(b.count >= 1 and b.count < rows.len);
    try std.testing.expect(b.body.len <= small.len);
    var out: [8]SyncRow = undefined;
    const d = try decodePayload(std.testing.allocator, b.body, &out);
    try std.testing.expectEqual(b.count, d.count);
    var tiny: [64]u8 = undefined;
    try std.testing.expectError(error.WriteFailed, encodeBatch(&tiny, &rows, ""));
}

test "seq paging: full page resumes after its last row, short page jumps to the snapshot" {
    const full = pageEnd(100, 100, 340, 900);
    try std.testing.expect(full.has_more);
    try std.testing.expectEqual(@as(i64, 340), full.next);
    // Short page (echoes skipped after row 410): cursor covers them too.
    const short = pageEnd(3, 100, 410, 900);
    try std.testing.expect(!short.has_more);
    try std.testing.expectEqual(@as(i64, 900), short.next);
    // Empty store page.
    try std.testing.expectEqual(@as(i64, 0), pageEnd(0, 100, 0, 0).next);
    // Selection: strictly after the cursor, within the snapshot.
    try std.testing.expect(!eligible(5, "", 5, 9, ""));
    try std.testing.expect(eligible(6, "", 5, 9, ""));
    try std.testing.expect(!eligible(10, "", 5, 9, ""));
}

test "origin skip: never back to the sender, still to everyone else" {
    try std.testing.expect(skipForPeer("aaaa1111", "aaaa1111"));
    try std.testing.expect(!skipForPeer("aaaa1111", "bbbb2222"));
    try std.testing.expect(!skipForPeer("", "bbbb2222")); // local write goes everywhere
    try std.testing.expect(!skipForPeer("aaaa1111", "")); // unknown peer gets all
    try std.testing.expect(!eligible(6, "aaaa1111", 5, 9, "aaaa1111"));
    try std.testing.expect(eligible(6, "aaaa1111", 5, 9, "cccc3333"));
}

test "pull restarts from 0 when the peer's store changed" {
    try std.testing.expect(!needRestart(0, "aaaa1111", "bbbb2222", 0)); // nothing to restart
    try std.testing.expect(needRestart(50, "aaaa1111", "bbbb2222", 80)); // new device id
    try std.testing.expect(needRestart(50, "aaaa1111", "aaaa1111", 20)); // seq went backwards
    try std.testing.expect(!needRestart(50, "aaaa1111", "aaaa1111", 50));
    try std.testing.expect(!needRestart(50, "", "aaaa1111", 60)); // first contact learns the id
}

test "device identity: keep, adopt, and reroll a cloned db" {
    const a = "aaaaaaaa11111111aaaaaaaa11111111";
    const d = "dddddddd22222222dddddddd22222222";
    try std.testing.expectEqual(IdentityAction.keep, identityAction(a, true, a));
    // Fresh store / upgrade from a pre-binding build: adopt the db id.
    try std.testing.expectEqual(IdentityAction.adopt, identityAction(a, false, ""));
    try std.testing.expectEqual(IdentityAction.adopt, identityAction(a, false, a));
    // Regression: A's opal.db copied onto a fresh install D (bound, no file).
    try std.testing.expectEqual(IdentityAction.reroll, identityAction(a, true, ""));
    // A's opal.db copied over D's existing store (D's file holds D's id).
    try std.testing.expectEqual(IdentityAction.reroll, identityAction(a, true, d));
    try std.testing.expectEqual(IdentityAction.reroll, identityAction(a, false, d));
    // Garbage on either side never yields a shared id.
    try std.testing.expectEqual(IdentityAction.reroll, identityAction("", false, ""));
    try std.testing.expectEqual(IdentityAction.reroll, identityAction("../x", true, "../x"));
    try std.testing.expectEqual(IdentityAction.reroll, identityAction(a, true, "bad id!"));
    try std.testing.expectEqual(IdentityAction.adopt, identityAction(a, false, "bad id!"));
}

test "reroll resets cursors but keeps learned peer ids" {
    var peers: [2]Peer = .{ .{ .pull_seq = 40, .push_seq = 12 }, .{ .pull_seq = 7, .push_seq = 3 } };
    peers[0].setDevice("bbbb2222");
    resetCursorsAfterReroll(&peers);
    for (peers) |p| {
        try std.testing.expectEqual(@as(i64, 0), p.pull_seq);
        try std.testing.expectEqual(@as(i64, 0), p.push_seq);
    }
    try std.testing.expectEqualStrings("bbbb2222", peers[0].deviceId());
}

test "parallel slots: one run per peer, first free slot, none when full" {
    try std.testing.expectEqual(@as(?usize, 0), pickSlot(&.{ "", "", "", "" }, "http://a:1"));
    try std.testing.expectEqual(@as(?usize, 1), pickSlot(&.{ "http://b:1", "", "" }, "http://a:1"));
    // A dead peer's slot does not block the others; a second run on it is refused.
    try std.testing.expectEqual(@as(?usize, 0), pickSlot(&.{ "", "http://dead:9", "" }, "http://a:1"));
    try std.testing.expectEqual(@as(?usize, null), pickSlot(&.{ "", "http://dead:9", "" }, "http://dead:9"));
    try std.testing.expectEqual(@as(?usize, null), pickSlot(&.{ "http://a:1", "http://b:1" }, "http://c:1"));
}

test "3 devices: cloned store after a reroll converges without echo" {
    var a: SimDev = .{ .id = "aaaa1111" };
    var b: SimDev = .{ .id = "bbbb2222" };
    a.write(mk("movie", "x", 10, false, 1), "");
    a.write(mk("movie", "y", 11, true, 1), "");
    var ab: SimLink = .{};
    _ = simSync(&b, &a, &ab);
    // D = byte copy of A, rerolled to a fresh id; D's links start at 0.
    var d = a;
    d.id = "dddd4444";
    var da: SimLink = .{};
    var db_: SimLink = .{};
    const a_seq = a.seq;
    // First contact re-sends everything, but nothing applies: no seq moves.
    _ = simSync(&d, &a, &da);
    _ = simSync(&d, &b, &db_);
    try std.testing.expectEqual(a_seq, a.seq);
    // Then quiet in both directions.
    try std.testing.expectEqual(@as(usize, 0), simSync(&d, &a, &da));
    try std.testing.expectEqual(@as(usize, 0), simSync(&d, &b, &db_));
    // D's own edit reaches A via B (tagged with D's id, so it relays to A).
    d.write(mk("movie", "z", 20, false, 1), "");
    _ = simSync(&d, &b, &db_);
    _ = simSync(&b, &a, &ab);
    try std.testing.expect(a.find("z") != null);
}

fn setUrl(p: *Peer, url: []const u8) void {
    @memset(&p.url, 0);
    @memcpy(p.url[0..url.len], url);
}

test "multi-peer cursors are isolated per peer" {
    var peers: [MAX_PEERS]Peer = [_]Peer{.{}} ** MAX_PEERS;
    var count: usize = 0;
    const a = addPeer(&peers, &count).?;
    const b = addPeer(&peers, &count).?;
    setUrl(&peers[a], "http://a:1");
    setUrl(&peers[b], "http://b:1");
    try std.testing.expect(bindCursors(&peers[a], "http://a:1"));
    try std.testing.expect(bindCursors(&peers[b], "http://b:1"));
    var r: RunResult = .{ .pulled_to = 40, .pushed_to = 12 };
    @memcpy(r.device[0..8], "aaaa1111");
    r.device_len = 8;
    try std.testing.expect(applyRun(&peers[a], "http://a:1", &r, 1000));
    try std.testing.expectEqual(@as(i64, 40), peers[a].pull_seq);
    try std.testing.expectEqual(@as(i64, 12), peers[a].push_seq);
    try std.testing.expectEqualStrings("aaaa1111", peers[a].deviceId());
    // B untouched by A's run.
    try std.testing.expectEqual(@as(i64, 0), peers[b].pull_seq);
    try std.testing.expectEqual(@as(i64, 0), peers[b].push_seq);
    try std.testing.expectEqual(@as(usize, 0), peers[b].device_len);
    // Outcomes route by address, not index.
    try std.testing.expectEqual(@as(?usize, b), findPeer(peers[0..count], "http://b:1"));
    // Re-pointing B resets only B; a run for B's old address is dropped.
    peers[b].pull_seq = 7;
    try std.testing.expect(bindCursors(&peers[b], "http://b:2"));
    try std.testing.expectEqual(@as(i64, 0), peers[b].pull_seq);
    try std.testing.expect(!applyRun(&peers[b], "http://b:1", &r, 1001));
    try std.testing.expectEqual(@as(i64, 0), peers[b].pull_seq);
    try std.testing.expectEqual(@as(i64, 40), peers[a].pull_seq);
    // A failed pull leaves cursors alone; a failed push keeps last_sync.
    const failed: RunResult = .{};
    try std.testing.expect(applyRun(&peers[a], "http://a:1", &failed, 2000));
    try std.testing.expectEqual(@as(i64, 40), peers[a].pull_seq);
    try std.testing.expectEqual(@as(i64, 1000), peers[a].last_sync);
    // Removing A shifts B down with its own cursors and clears the slot.
    removePeer(&peers, &count, a);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("http://b:2", peers[0].cursorUrl());
    try std.testing.expectEqual(@as(usize, 0), peers[1].tokenText().len);
    try std.testing.expectEqual(@as(?usize, null), findPeer(peers[0..count], "http://a:1"));
    // Capacity.
    while (addPeer(&peers, &count)) |_| {}
    try std.testing.expectEqual(MAX_PEERS, count);
}

// ── Three-device simulation (regression: relayed rows + echo) ────────────────
//
// A tiny in-memory store driven only by the rules above (shouldApply, eligible,
// pageEnd, skipForPeer) — the same decisions library_store/library_sync ship.

const SimRow = struct { row: SyncRow, origin: []const u8 };

const SimDev = struct {
    id: []const u8,
    rows: [16]SimRow = undefined,
    n: usize = 0,
    seq: i64 = 0,

    fn find(self: *SimDev, id: []const u8) ?*SimRow {
        for (self.rows[0..self.n]) |*r| if (std.mem.eql(u8, r.row.item.item_id[0..r.row.item.item_id_len], id)) return r;
        return null;
    }
    fn write(self: *SimDev, row: SyncRow, origin: []const u8) void {
        self.seq += 1;
        var r = row;
        r.seq = self.seq;
        if (self.find(row.item.item_id[0..row.item.item_id_len])) |slot| {
            slot.* = .{ .row = r, .origin = origin };
        } else {
            self.rows[self.n] = .{ .row = r, .origin = origin };
            self.n += 1;
        }
    }
    fn apply(self: *SimDev, row: *const SyncRow, origin: []const u8) bool {
        const local: ?*const SyncRow = if (self.find(row.item.item_id[0..row.item.item_id_len])) |l| &l.row else null;
        if (!shouldApply(local, row)) return false;
        self.write(row.*, origin);
        return true;
    }
    /// Rows for `peer_device` after `after`, seq order, at most `limit`.
    fn page(self: *SimDev, after: i64, peer_device: []const u8, limit: usize, out: []SyncRow) SimPage {
        const snap = self.seq;
        var count: usize = 0;
        var last: i64 = after;
        var s = after + 1;
        while (s <= snap and count < limit) : (s += 1) {
            for (self.rows[0..self.n]) |*r| {
                if (r.row.seq == s and eligible(r.row.seq, r.origin, after, snap, peer_device)) {
                    out[count] = r.row;
                    count += 1;
                    last = s;
                }
            }
        }
        return .{ .end = pageEnd(count, limit, last, snap), .count = count };
    }
};

const SimPage = struct { end: PageEnd, count: usize };

const SimLink = struct { pull: i64 = 0, push: i64 = 0 };

/// One pull-then-push run of `me` against `peer`; returns rows pushed.
fn simSync(me: *SimDev, peer: *SimDev, link: *SimLink) usize {
    var buf: [16]SyncRow = undefined;
    while (true) {
        const p = peer.page(link.pull, me.id, 2, &buf);
        for (buf[0..p.count]) |*r| _ = me.apply(r, peer.id);
        link.pull = p.end.next;
        if (!p.end.has_more) break;
    }
    var sent: usize = 0;
    while (true) {
        const p = me.page(link.push, peer.id, 2, &buf);
        for (buf[0..p.count]) |*r| _ = peer.apply(r, me.id);
        sent += p.count;
        link.push = p.end.next;
        if (!p.end.has_more) break;
    }
    return sent;
}

test "3 devices: a relayed row with an OLD updated_at still reaches the third device" {
    var a: SimDev = .{ .id = "aaaa1111" };
    var b: SimDev = .{ .id = "bbbb2222" };
    var c: SimDev = .{ .id = "cccc3333" };
    var ab: SimLink = .{};
    var bc: SimLink = .{};
    // B writes at t=500 and syncs with C: B's push cursor to C moves past it.
    b.write(mk("tv", "b1", 500, false, 1), "");
    _ = simSync(&b, &c, &bc);
    try std.testing.expect(c.find("b1") != null);
    // A (clock behind / offline) wrote at t=100; it reaches B later.
    a.write(mk("movie", "a1", 100, true, 30), "");
    _ = simSync(&b, &a, &ab);
    try std.testing.expect(b.find("a1") != null);
    // An updated_at cursor (>=500) would strand a1 on B. The seq cursor does not.
    _ = simSync(&b, &c, &bc);
    const got = c.find("a1") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 100), got.row.updated_at);
    // C deletes a1 (newer tombstone) -> B -> A.
    var tomb = mk("movie", "a1", 900, true, 30);
    tomb.deleted = true;
    c.write(tomb, "");
    _ = simSync(&b, &c, &bc);
    _ = simSync(&b, &a, &ab);
    try std.testing.expect(a.find("a1").?.row.deleted);
}

test "3 devices: no echo — synced rows are not sent back to their sender" {
    var a: SimDev = .{ .id = "aaaa1111" };
    var b: SimDev = .{ .id = "bbbb2222" };
    var c: SimDev = .{ .id = "cccc3333" };
    var ab: SimLink = .{};
    var bc: SimLink = .{};
    a.write(mk("movie", "x", 10, false, 1), "");
    a.write(mk("movie", "y", 11, false, 1), "");
    a.write(mk("movie", "z", 12, false, 1), "");
    // B pulls 3 rows from A; its push back to A sends none of them.
    try std.testing.expectEqual(@as(usize, 0), simSync(&b, &a, &ab));
    // ...but relays all 3 to C, and C has nothing to send back to B.
    try std.testing.expectEqual(@as(usize, 3), simSync(&b, &c, &bc));
    var cb: SimLink = .{};
    _ = simSync(&c, &b, &cb); // C's first pull from B: learns B's rows.
    try std.testing.expectEqual(@as(usize, 0), simSync(&c, &b, &cb));
    // A second run is quiet in both directions.
    try std.testing.expectEqual(@as(usize, 0), simSync(&b, &a, &ab));
    try std.testing.expectEqual(@as(usize, 0), simSync(&b, &c, &bc));
}
