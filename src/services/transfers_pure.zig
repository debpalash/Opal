//! Pure merge/dedup/status/sort logic for the unified Downloads list.
//!
//! Downloads used to be three tabs (Files / Active / History) over three
//! unrelated sources. Merging them into ONE list creates a problem the tabs
//! hid: a finished torrent legitimately exists in all three at once — still
//! seeding (Active), sitting in the download dir (Files), and recorded in
//! History. A naive concat shows it three times.
//!
//! So the merge needs an identity. The governing rule here is that **a wrong
//! merge is worse than a duplicate**: collapsing two different releases that
//! happen to share a title destroys information and mis-attributes actions
//! (pausing the wrong torrent, deleting the wrong folder). A duplicate row is
//! merely untidy. Hence `matchStrength` stops DECISIVELY on a hash/path
//! mismatch and never falls through to fuzzy name comparison, and a name-only
//! match is only trusted when a live torrent is one of the two sides.
//!
//! No dvui / state / c imports — this is unit-testable in isolation and the
//! renderer only *executes* the decisions made here (registered in build.zig's
//! `test` step).

const std = @import("std");

pub const MAX_ROWS: usize = 256;
pub const NAME_LEN: usize = 256;
pub const DISK_LEN: usize = 256;
pub const NORM_LEN: usize = 128;
pub const IH_LEN: usize = 40; // lowercase hex sha1 (v1 btih)

pub const Status = enum(u8) {
    downloading, // live torrent, progress < 1, running
    fetching, // live torrent, metadata not yet acquired
    paused, // live torrent, progress < 1, paused
    errored, // live torrent but torrent_poll() failed
    seeding, // live torrent, progress >= 1, running
    complete, // live torrent, progress >= 1, paused
    on_disk, // no live torrent; present in the download dir
    archived, // history record only — not on disk, no torrent
};

pub const Origin = enum(u8) { torrent, file, history };

pub const Filter = enum(u8) { all, downloading, seeding, on_disk, history };

pub const Row = struct {
    // ── identity, strongest first ──
    ih: [IH_LEN]u8 = std.mem.zeroes([IH_LEN]u8),
    ih_len: u8 = 0, // 0 or 40
    disk: [DISK_LEN]u8 = std.mem.zeroes([DISK_LEN]u8),
    disk_len: u16 = 0, // basename in the download dir; 0 = not on disk
    norm: [NORM_LEN]u8 = std.mem.zeroes([NORM_LEN]u8),
    norm_len: u16 = 0, // WEAK key only

    // ── display (raw bytes; the renderer prettifies) ──
    name: [NAME_LEN]u8 = std.mem.zeroes([NAME_LEN]u8),
    name_len: u16 = 0,

    // ── provenance handles: a merged row carries the UNION ──
    origin: Origin = .file,
    torrent_id: i32 = -1,
    hist_idx: i16 = -1,

    // ── live torrent stats (valid iff torrent_id >= 0) ──
    progress: f32 = 0,
    dl_rate: u32 = 0,
    seeds: u16 = 0,
    paused: bool = false,
    has_metadata: bool = false,
    poll_err: bool = false,

    // ── disk / size / date ──
    size: u64 = 0,
    mtime: i64 = 0,
    added_at: i64 = 0,
    is_dir: bool = false,

    pub fn hasTorrent(self: *const Row) bool {
        return self.torrent_id >= 0;
    }
    pub fn hasFile(self: *const Row) bool {
        return self.disk_len > 0;
    }
    pub fn hasHistory(self: *const Row) bool {
        return self.hist_idx >= 0;
    }
    pub fn nameSlice(self: *const Row) []const u8 {
        return self.name[0..@min(self.name_len, self.name.len)];
    }
    pub fn diskSlice(self: *const Row) []const u8 {
        return self.disk[0..@min(self.disk_len, self.disk.len)];
    }
    pub fn ihSlice(self: *const Row) []const u8 {
        return self.ih[0..@min(self.ih_len, self.ih.len)];
    }
    pub fn normSlice(self: *const Row) []const u8 {
        return self.norm[0..@min(self.norm_len, self.norm.len)];
    }
};

// ══════════════════════════════════════════════════════════
// Field setters (bounded copies — fixed buffers, never slices)
// ══════════════════════════════════════════════════════════

pub fn setName(r: *Row, s: []const u8) void {
    const n = @min(s.len, NAME_LEN);
    @memcpy(r.name[0..n], s[0..n]);
    r.name_len = @intCast(n);
}
pub fn setDisk(r: *Row, s: []const u8) void {
    const n = @min(s.len, DISK_LEN);
    @memcpy(r.disk[0..n], s[0..n]);
    r.disk_len = @intCast(n);
}
pub fn setIh(r: *Row, s: []const u8) void {
    if (s.len != IH_LEN) {
        r.ih_len = 0;
        return;
    }
    @memcpy(r.ih[0..IH_LEN], s[0..IH_LEN]);
    r.ih_len = IH_LEN;
}
pub fn setNorm(r: *Row, s: []const u8) void {
    const n = @min(s.len, NORM_LEN);
    @memcpy(r.norm[0..n], s[0..n]);
    r.norm_len = @intCast(n);
}

// ══════════════════════════════════════════════════════════
// Identity helpers
// ══════════════════════════════════════════════════════════

/// Lowercase, keep alphanumerics, collapse every run of separators to one space
/// (so "Foo.Bar.2024" and "Foo Bar 2024" agree). It deliberately does NOT strip
/// site/scene prefixes: `norm` is only used to match a live torrent against a
/// history row, and history names are written FROM the torrent's own name
/// (transfers.zig's remove path), so both sides already carry the same prefix.
/// Adding a stripper would only widen the weak key for no gain — and a wider
/// weak key is exactly how a wrong merge happens.
/// WEAK key — only ever used under the live-torrent gate in `matchStrength`.
pub fn normalizeName(src: []const u8, out: *[NORM_LEN]u8) usize {
    var n: usize = 0;
    var last_space = true; // trims leading space
    for (src) |ch0| {
        if (n >= NORM_LEN) break;
        const ch = std.ascii.toLower(ch0);
        const keep = std.ascii.isAlphanumeric(ch);
        if (keep) {
            out[n] = ch;
            n += 1;
            last_space = false;
        } else if (!last_space) {
            out[n] = ' ';
            n += 1;
            last_space = true;
        }
    }
    while (n > 0 and out[n - 1] == ' ') n -= 1; // trim trailing
    return n;
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Extract a v1 btih infohash (40 lowercase hex) from a magnet URI, a bare
/// hash, or a truncated magnet. History stores only the first 64 bytes of the
/// magnet, but "magnet:?xt=urn:btih:" is exactly 20 bytes, so the 40-hex hash
/// survives that truncation — which is what makes History↔Active joinable.
/// Returns the number of bytes written to `out` (40) or 0.
pub fn parseInfohash(src: []const u8, out: *[IH_LEN]u8) usize {
    const marker = "btih:";
    var start: usize = 0;
    if (std.mem.indexOf(u8, src, marker)) |i| {
        start = i + marker.len;
    } else if (src.len >= IH_LEN) {
        start = 0; // maybe a bare hash
    } else return 0;

    if (start + IH_LEN > src.len) return 0;
    const cand = src[start .. start + IH_LEN];
    for (cand) |ch| {
        if (hexVal(ch) == null) return 0;
    }
    for (cand, 0..) |ch, i| out[i] = std.ascii.toLower(ch);
    return IH_LEN;
}

/// The first path component of `abs` beneath `save_path` — i.e. the directory
/// entry a torrent actually creates in the download dir. This is what lets an
/// Active torrent be matched against a Files entry without any hashing.
/// Returns a slice INTO `abs`, or null when `abs` isn't under `save_path`.
pub fn firstPathComponentAfter(abs: []const u8, save_path: []const u8) ?[]const u8 {
    if (abs.len == 0 or save_path.len == 0) return null;
    var root = save_path;
    while (root.len > 1 and root[root.len - 1] == '/') root = root[0 .. root.len - 1];
    if (!std.mem.startsWith(u8, abs, root)) return null;
    var rest = abs[root.len..];
    while (rest.len > 0 and rest[0] == '/') rest = rest[1..];
    if (rest.len == 0) return null;
    const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    if (end == 0) return null;
    return rest[0..end];
}

pub const Match = enum { same_strong, same_weak, different, unknown };

/// The identity ladder. The FIRST applicable rule is decisive — INCLUDING a
/// decisive "different". This is the heart of the merge: two releases with the
/// same title but different infohashes must never collapse, so a hash mismatch
/// stops the ladder rather than falling through to name matching.
pub fn matchStrength(a: *const Row, b: *const Row) Match {
    // 1. infohash — exact, decisive both ways.
    if (a.ih_len == IH_LEN and b.ih_len == IH_LEN) {
        return if (std.mem.eql(u8, a.ihSlice(), b.ihSlice())) .same_strong else .different;
    }
    // 2. on-disk entry — literally the same directory entry, decisive both ways.
    if (a.disk_len > 0 and b.disk_len > 0) {
        return if (std.mem.eql(u8, a.diskSlice(), b.diskSlice())) .same_strong else .different;
    }
    // 3. normalized name — WEAK. Only trusted when a live torrent is involved:
    //    a torrent's name is the exact string libtorrent reports and is what
    //    history rows are written from on removal. Between two dead records
    //    (file vs history) a name collision is not enough evidence, so we return
    //    .unknown and keep them separate — a duplicate beats a wrong merge.
    if (a.norm_len >= 8 and b.norm_len >= 8 and std.mem.eql(u8, a.normSlice(), b.normSlice())) {
        if (a.hasTorrent() or b.hasTorrent()) return .same_weak;
        return .unknown;
    }
    return .unknown;
}

// ══════════════════════════════════════════════════════════
// Status / filter / sort
// ══════════════════════════════════════════════════════════

pub fn statusFor(r: *const Row) Status {
    if (r.hasTorrent()) {
        if (r.poll_err) return .errored;
        if (!r.has_metadata) return .fetching;
        if (r.progress < 1.0) return if (r.paused) .paused else .downloading;
        return if (r.paused) .complete else .seeding;
    }
    if (r.hasFile()) return .on_disk;
    return .archived;
}

/// Chip membership is EVIDENCE-based, not status-based: one merged row that is
/// seeding AND on disk AND in history is legitimately counted by Seeding, On
/// disk and History — exactly once in each. That's the point of merging.
pub fn matchesFilter(r: *const Row, f: Filter) bool {
    return switch (f) {
        .all => true,
        .downloading => switch (statusFor(r)) {
            .downloading, .fetching, .paused, .errored => true,
            else => false,
        },
        .seeding => switch (statusFor(r)) {
            .seeding, .complete => true,
            else => false,
        },
        .on_disk => r.hasFile(),
        .history => r.hasHistory(),
    };
}

pub fn countsFor(rows: []const Row, out: *[5]usize) void {
    out.* = .{ 0, 0, 0, 0, 0 };
    for (rows) |*r| {
        inline for (.{ Filter.all, .downloading, .seeding, .on_disk, .history }, 0..) |f, i| {
            if (matchesFilter(r, f)) out[i] += 1;
        }
    }
}

fn statusRank(s: Status) u8 {
    return switch (s) {
        .downloading => 0,
        .fetching => 1,
        .paused => 2,
        .errored => 3,
        .seeding => 4,
        .complete => 5,
        .on_disk => 6,
        .archived => 7,
    };
}

/// Packed sort key so ordering is a plain integer compare (Row is ~800B — never
/// memcpy-swap it; sort an index array instead).
/// Layout: [status rank : 8][activity, descending : 32][name tiebreak : 24]
pub fn sortKey(r: *const Row) u64 {
    const st = statusFor(r);
    const rank: u64 = statusRank(st);

    // Active rows rank by speed (what's actually moving goes on top); finished
    // and archived rows rank by recency (what I just finished goes on top).
    const metric: u32 = switch (st) {
        .downloading, .fetching, .paused, .errored => r.dl_rate,
        .seeding, .complete, .on_disk => blk: {
            const t = if (r.mtime > 0) r.mtime else r.added_at;
            break :blk if (t <= 0) 0 else @as(u32, @truncate(@as(u64, @intCast(t))));
        },
        .archived => blk: {
            const t = r.added_at;
            break :blk if (t <= 0) 0 else @as(u32, @truncate(@as(u64, @intCast(t))));
        },
    };
    const inv: u64 = ~@as(u64, metric) & 0xFFFF_FFFF; // descending

    var tie: u64 = 0;
    const nm = r.normSlice();
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const b: u64 = if (i < nm.len) nm[i] else 0;
        tie = (tie << 8) | b;
    }
    return (rank << 56) | (inv << 24) | (tie & 0xFF_FFFF);
}

/// Fill `order` with indices into `rows`, sorted. Stable on ties (index order).
pub fn sortOrder(rows: []const Row, order: []u16) usize {
    const n = @min(rows.len, order.len);
    for (0..n) |i| order[i] = @intCast(i);
    const Ctx = struct {
        rows: []const Row,
        fn lessThan(ctx: @This(), a: u16, b: u16) bool {
            const ka = sortKey(&ctx.rows[a]);
            const kb = sortKey(&ctx.rows[b]);
            if (ka != kb) return ka < kb;
            return a < b; // stable
        }
    };
    std.sort.pdq(u16, order[0..n], Ctx{ .rows = rows }, Ctx.lessThan);
    return n;
}

// ══════════════════════════════════════════════════════════
// The merge
// ══════════════════════════════════════════════════════════

/// Fold a matched row's evidence into the surviving row. Precedence:
/// a live torrent owns the display name and size (libtorrent's name is the
/// authoritative one, and a history `name` may be a raw magnet string), while
/// disk/history handles are additive so the merged row offers the UNION of
/// actions.
fn absorb(dst: *Row, src: *const Row) void {
    // Handles are additive.
    if (!dst.hasTorrent() and src.hasTorrent()) {
        dst.torrent_id = src.torrent_id;
        dst.progress = src.progress;
        dst.dl_rate = src.dl_rate;
        dst.seeds = src.seeds;
        dst.paused = src.paused;
        dst.has_metadata = src.has_metadata;
        dst.poll_err = src.poll_err;
        // A torrent's name outranks a file/history name.
        if (src.name_len > 0) setName(dst, src.nameSlice());
        if (src.size > 0) dst.size = src.size;
        dst.origin = .torrent;
    }
    if (!dst.hasFile() and src.hasFile()) {
        setDisk(dst, src.diskSlice());
        dst.is_dir = src.is_dir;
        if (dst.mtime == 0) dst.mtime = src.mtime;
        if (dst.size == 0) dst.size = src.size;
    }
    if (!dst.hasHistory() and src.hasHistory()) {
        dst.hist_idx = src.hist_idx;
        if (dst.added_at == 0) dst.added_at = src.added_at;
    }
    // Identity keys are additive too — absorbing a hashed row makes the
    // survivor joinable against later rows.
    if (dst.ih_len == 0 and src.ih_len == IH_LEN) setIh(dst, src.ihSlice());
    if (dst.norm_len == 0 and src.norm_len > 0) setNorm(dst, src.normSlice());
    if (dst.name_len == 0 and src.name_len > 0) setName(dst, src.nameSlice());
}

/// Merge torrents + files + history into one deduplicated set.
/// Torrents are seeded first so a live handle always wins the display fields.
pub fn buildRows(
    torrents: []const Row,
    files: []const Row,
    history: []const Row,
    out: *[MAX_ROWS]Row,
) usize {
    var n: usize = 0;

    for ([_][]const Row{ torrents, files, history }) |group| {
        for (group) |*incoming| {
            if (n >= MAX_ROWS) return n;
            var merged = false;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                switch (matchStrength(&out[i], incoming)) {
                    .same_strong, .same_weak => {
                        absorb(&out[i], incoming);
                        merged = true;
                        break;
                    },
                    // `.different` and `.unknown` both mean "not this row" — keep
                    // scanning. Neither may collapse the pair.
                    .different, .unknown => {},
                }
            }
            if (!merged) {
                out[n] = incoming.*;
                n += 1;
            }
        }
    }
    return n;
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

fn mkTorrent(id: i32, ih: ?[]const u8, disk: ?[]const u8, name: []const u8, progress: f32, paused: bool) Row {
    var r = Row{ .origin = .torrent, .torrent_id = id, .progress = progress, .paused = paused, .has_metadata = true };
    setName(&r, name);
    if (ih) |h| setIh(&r, h);
    if (disk) |d| setDisk(&r, d);
    var nb: [NORM_LEN]u8 = undefined;
    setNorm(&r, nb[0..normalizeName(name, &nb)]);
    return r;
}
fn mkFile(disk: []const u8, size: u64) Row {
    var r = Row{ .origin = .file, .size = size, .mtime = 1000 };
    setName(&r, disk);
    setDisk(&r, disk);
    var nb: [NORM_LEN]u8 = undefined;
    setNorm(&r, nb[0..normalizeName(disk, &nb)]);
    return r;
}
fn mkHist(idx: i16, ih: ?[]const u8, name: []const u8) Row {
    var r = Row{ .origin = .history, .hist_idx = idx, .added_at = 500 };
    setName(&r, name);
    if (ih) |h| setIh(&r, h);
    var nb: [NORM_LEN]u8 = undefined;
    setNorm(&r, nb[0..normalizeName(name, &nb)]);
    return r;
}

const HASH_A = "aabbccddeeff00112233445566778899aabbccdd";
const HASH_B = "1122334455667788990011223344556677889900";

test "normalizeName agrees across separator spellings" {
    var b: [NORM_LEN]u8 = undefined;
    // Dots vs spaces vs underscores must all agree — that's the whole job.
    try std.testing.expectEqualStrings("foo bar 2024 1080p", b[0..normalizeName("Foo.Bar.2024.1080p", &b)]);
    try std.testing.expectEqualStrings("foo bar 2024 1080p", b[0..normalizeName("  Foo Bar__2024 - 1080p!! ", &b)]);
    // Prefixes are PRESERVED (see the doc comment): a site prefix appears on both
    // sides of a torrent↔history match, and keeping it keeps the weak key narrow.
    try std.testing.expectEqualStrings(
        "www uindex org normal 2026 1080p",
        b[0..normalizeName("www.UIndex.org - Normal 2026 1080p", &b)],
    );
    try std.testing.expectEqualStrings("", b[0..normalizeName("...", &b)]);
}

test "parseInfohash survives the 64-byte truncated magnet history stores" {
    var out: [IH_LEN]u8 = undefined;
    // Full magnet.
    var s = "magnet:?xt=urn:btih:" ++ HASH_A ++ "&dn=Foo";
    try std.testing.expectEqual(@as(usize, 40), parseInfohash(s, &out));
    try std.testing.expectEqualStrings(HASH_A, &out);
    // Regression: history truncates the magnet to 64 bytes. "magnet:?xt=urn:btih:"
    // is 20 bytes, so exactly the 40-hex hash survives — this is what makes a
    // history row joinable to a live torrent.
    const truncated = s[0..@min(64, s.len)];
    try std.testing.expectEqual(@as(usize, 40), parseInfohash(truncated, &out));
    try std.testing.expectEqualStrings(HASH_A, &out);
    // Bare hash, uppercase → lowercased.
    try std.testing.expectEqual(@as(usize, 40), parseInfohash("AABBCCDDEEFF00112233445566778899AABBCCDD", &out));
    try std.testing.expectEqualStrings(HASH_A, &out);
    // Garbage.
    try std.testing.expectEqual(@as(usize, 0), parseInfohash("", &out));
    try std.testing.expectEqual(@as(usize, 0), parseInfohash("btih:short", &out));
    try std.testing.expectEqual(@as(usize, 0), parseInfohash("not-a-hash-at-all-not-a-hash-at-all-nope", &out));
}

test "firstPathComponentAfter finds the entry a torrent creates on disk" {
    try std.testing.expectEqualStrings("Show.S01", firstPathComponentAfter("/dl/Show.S01/ep1.mkv", "/dl").?);
    try std.testing.expectEqualStrings("movie.mkv", firstPathComponentAfter("/dl/movie.mkv", "/dl").?);
    try std.testing.expectEqualStrings("Show.S01", firstPathComponentAfter("/dl/Show.S01/ep1.mkv", "/dl/").?);
    try std.testing.expect(firstPathComponentAfter("/other/x.mkv", "/dl") == null);
    try std.testing.expect(firstPathComponentAfter("", "/dl") == null); // no metadata yet
}

test "matchStrength: a hash mismatch is DECISIVE — same title must not collapse" {
    // The anti-wrong-merge test. Two different releases, byte-identical names.
    const a = mkTorrent(0, HASH_A, null, "Foo.Bar.2024.1080p", 0.5, false);
    const b = mkHist(1, HASH_B, "Foo.Bar.2024.1080p");
    try std.testing.expectEqual(Match.different, matchStrength(&a, &b));

    // Same hash → same item even with different display names.
    const c = mkHist(2, HASH_A, "magnet:?xt=urn:btih:" ++ HASH_A);
    try std.testing.expectEqual(Match.same_strong, matchStrength(&a, &c));
}

test "matchStrength: two dead records with equal names are NOT merged" {
    // file vs history, no hash, no shared disk entry → not enough evidence.
    // Prefer a duplicate over a wrong merge.
    const f = mkFile("Foo.Bar.2024.1080p", 100);
    var h = mkHist(0, null, "Foo.Bar.2024.1080p");
    h.disk_len = 0;
    try std.testing.expectEqual(Match.unknown, matchStrength(&f, &h));

    // But a LIVE torrent vouches for the name → weak match is trusted.
    var t = mkTorrent(3, null, null, "Foo.Bar.2024.1080p", 0.5, false);
    t.disk_len = 0;
    try std.testing.expectEqual(Match.same_weak, matchStrength(&t, &h));
}

test "matchStrength: different disk entries are decisively different" {
    const a = mkFile("Foo", 1);
    const b = mkFile("Bar", 1);
    try std.testing.expectEqual(Match.different, matchStrength(&a, &b));
    const c = mkFile("Foo", 2);
    try std.testing.expectEqual(Match.same_strong, matchStrength(&a, &c));
}

test "buildRows: THE TRIPLE CASE — seeding + on disk + in history = ONE row" {
    var out: [MAX_ROWS]Row = undefined;
    const t = [_]Row{mkTorrent(7, HASH_A, "Foo", "Foo", 1.0, false)}; // seeding
    const f = [_]Row{mkFile("Foo", 1234)};
    const h = [_]Row{mkHist(3, HASH_A, "magnet:?xt=urn:btih:" ++ HASH_A)};

    const n = buildRows(&t, &f, &h, &out);
    try std.testing.expectEqual(@as(usize, 1), n);

    const r = &out[0];
    try std.testing.expectEqual(Status.seeding, statusFor(r));
    try std.testing.expect(r.hasTorrent() and r.hasFile() and r.hasHistory());
    try std.testing.expectEqual(@as(i32, 7), r.torrent_id);
    try std.testing.expectEqual(@as(i16, 3), r.hist_idx);
    // The torrent's name wins — a raw magnet string must never become the label.
    try std.testing.expectEqualStrings("Foo", r.nameSlice());

    // It is counted ONCE under each chip it has evidence for.
    var counts: [5]usize = undefined;
    countsFor(out[0..n], &counts);
    try std.testing.expectEqual(@as(usize, 1), counts[0]); // all
    try std.testing.expectEqual(@as(usize, 0), counts[1]); // downloading
    try std.testing.expectEqual(@as(usize, 1), counts[2]); // seeding
    try std.testing.expectEqual(@as(usize, 1), counts[3]); // on disk
    try std.testing.expectEqual(@as(usize, 1), counts[4]); // history
}

test "buildRows: negative control — three unrelated items stay THREE rows" {
    var out: [MAX_ROWS]Row = undefined;
    const t = [_]Row{mkTorrent(1, HASH_A, "Alpha", "Alpha", 0.4, false)};
    const f = [_]Row{mkFile("Beta", 10)};
    const h = [_]Row{mkHist(0, HASH_B, "Gamma")};
    try std.testing.expectEqual(@as(usize, 3), buildRows(&t, &f, &h, &out));
}

test "buildRows: a fetching magnet does not swallow an unrelated file" {
    var out: [MAX_ROWS]Row = undefined;
    var t = mkTorrent(2, HASH_A, null, "", 0, false); // no metadata yet
    t.has_metadata = false;
    const ts = [_]Row{t};
    const f = [_]Row{mkFile("Something.Else", 5)};
    const n = buildRows(&ts, &f, &.{}, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(Status.fetching, statusFor(&out[0]));
}

test "statusFor truth table" {
    var r = mkTorrent(1, null, null, "x", 0.5, false);
    try std.testing.expectEqual(Status.downloading, statusFor(&r));
    r.paused = true;
    try std.testing.expectEqual(Status.paused, statusFor(&r));
    r.progress = 1.0;
    try std.testing.expectEqual(Status.complete, statusFor(&r));
    r.paused = false;
    try std.testing.expectEqual(Status.seeding, statusFor(&r));
    r.has_metadata = false;
    try std.testing.expectEqual(Status.fetching, statusFor(&r));
    r.poll_err = true;
    try std.testing.expectEqual(Status.errored, statusFor(&r));

    const f = mkFile("d", 1);
    try std.testing.expectEqual(Status.on_disk, statusFor(&f));
    var h = mkHist(0, null, "n");
    h.disk_len = 0;
    try std.testing.expectEqual(Status.archived, statusFor(&h));
}

test "sortOrder: live work first (fastest first), then finished, then archived" {
    var rows: [4]Row = undefined;
    rows[0] = mkHist(0, HASH_B, "old"); // archived
    rows[0].disk_len = 0;
    rows[1] = mkTorrent(1, null, null, "slow", 0.5, false);
    rows[1].dl_rate = 100;
    rows[2] = mkFile("done", 1); // on_disk
    rows[3] = mkTorrent(2, null, null, "fast", 0.5, false);
    rows[3].dl_rate = 900_000;

    var order: [4]u16 = undefined;
    _ = sortOrder(&rows, &order);
    // fast downloader, slow downloader, on-disk file, archived history
    try std.testing.expectEqual(@as(u16, 3), order[0]);
    try std.testing.expectEqual(@as(u16, 1), order[1]);
    try std.testing.expectEqual(@as(u16, 2), order[2]);
    try std.testing.expectEqual(@as(u16, 0), order[3]);
}
