//! Community add-on index: a curated list of signed repositories (URL plus
//! publisher key). The index only *suggests* repositories. Adding one pins its
//! key through `addon_repositories.add`, every catalog is still verified by
//! `addon_repo_pure.verify` against that pinned key, and installed executables
//! still need the host's approval. Nothing here can grant trust.
const std = @import("std");
const repo_pure = @import("addon_repo_pure.zig");
const Ed = std.crypto.sign.Ed25519;

pub const MAX_INDEX_BYTES = 128 * 1024;
pub const MAX_ENTRIES = 64;

pub const Entry = struct {
    id: []const u8,
    name: []const u8,
    url: []const u8,
    public_key: []const u8,
    description: []const u8 = "",
    tags: []const []const u8 = &.{},
};
pub const Index = struct { version: u32, repositories: []const Entry };
const Envelope = struct { manifest: []const u8, signature: []const u8 };

pub fn validKey(hex: []const u8) bool {
    if (hex.len != 64) return false;
    var key: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&key, hex) catch return false;
    _ = Ed.PublicKey.fromBytes(key) catch return false;
    return true;
}

/// Parse and validate an index. With `key_hex` set the bytes must be a signed
/// envelope (`{"manifest","signature"}`, same format as repositories) whose
/// exact manifest bytes verify against that key; otherwise the bytes are the
/// plain index JSON (fetched over HTTPS or from localhost only).
pub fn parse(a: std.mem.Allocator, bytes: []const u8, key_hex: []const u8) !std.json.Parsed(Index) {
    if (bytes.len > MAX_INDEX_BYTES) return error.IndexTooLarge;
    const opts: std.json.ParseOptions = .{ .allocate = .alloc_always, .ignore_unknown_fields = true };
    const parsed = if (key_hex.len == 0)
        try std.json.parseFromSlice(Index, a, bytes, opts)
    else blk: {
        if (!validKey(key_hex)) return error.InvalidKey;
        var key: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&key, key_hex);
        const public = try Ed.PublicKey.fromBytes(key);
        const envelope = try std.json.parseFromSlice(Envelope, a, bytes, .{ .allocate = .alloc_always });
        defer envelope.deinit();
        if (envelope.value.signature.len != 128) return error.InvalidSignature;
        var sig: [64]u8 = undefined;
        _ = std.fmt.hexToBytes(&sig, envelope.value.signature) catch return error.InvalidSignature;
        Ed.Signature.fromBytes(sig).verify(envelope.value.manifest, public) catch return error.InvalidSignature;
        break :blk try std.json.parseFromSlice(Index, a, envelope.value.manifest, opts);
    };
    errdefer parsed.deinit();
    try validate(parsed.value);
    return parsed;
}

fn validate(index: Index) !void {
    if (index.version != 1) return error.UnsupportedIndex;
    if (index.repositories.len > MAX_ENTRIES) return error.TooManyEntries;
    for (index.repositories, 0..) |e, i| {
        if (!repo_pure.validId(e.id)) return error.InvalidEntryId;
        if (e.name.len == 0 or e.name.len > 64 or e.description.len > 280) return error.InvalidEntryText;
        if (!repo_pure.validRepoUrl(e.url)) return error.InvalidEntryUrl;
        if (!validKey(e.public_key)) return error.InvalidEntryKey;
        if (e.tags.len > 8) return error.InvalidEntryText;
        for (e.tags) |tag| if (tag.len == 0 or tag.len > 24) return error.InvalidEntryText;
        for (index.repositories[0..i]) |prev| if (std.mem.eql(u8, prev.id, e.id)) return error.DuplicateEntry;
    }
}

// ── Versions ───────────────────────────────────────────────────────────

/// Semver-like ordering: optional leading `v`, dot-separated numeric parts
/// (missing parts are 0), and a `-prerelease` that sorts before the release.
/// Non-numeric parts compare as ASCII. `+build` metadata is ignored.
pub fn compareVersions(a: []const u8, b: []const u8) std.math.Order {
    const va = splitVersion(a);
    const vb = splitVersion(b);
    const core = compareDotted(va.core, vb.core);
    if (core != .eq) return core;
    if (va.pre.len == 0 and vb.pre.len == 0) return .eq;
    if (va.pre.len == 0) return .gt;
    if (vb.pre.len == 0) return .lt;
    return compareDotted(va.pre, vb.pre);
}

pub fn updateAvailable(installed: []const u8, available: []const u8) bool {
    return compareVersions(available, installed) == .gt;
}

const Split = struct { core: []const u8, pre: []const u8 };
fn splitVersion(raw: []const u8) Split {
    var v = std.mem.trim(u8, raw, " ");
    if (v.len > 0 and (v[0] == 'v' or v[0] == 'V')) v = v[1..];
    v = std.mem.sliceTo(v, '+');
    const dash = std.mem.indexOfScalar(u8, v, '-') orelse return .{ .core = v, .pre = "" };
    return .{ .core = v[0..dash], .pre = v[dash + 1 ..] };
}

fn compareDotted(a: []const u8, b: []const u8) std.math.Order {
    var ia = std.mem.splitScalar(u8, a, '.');
    var ib = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const pa = ia.next();
        const pb = ib.next();
        if (pa == null and pb == null) return .eq;
        const sa = pa orelse "0";
        const sb = pb orelse "0";
        const na = std.fmt.parseInt(u64, sa, 10) catch null;
        const nb = std.fmt.parseInt(u64, sb, 10) catch null;
        const ord = if (na != null and nb != null)
            std.math.order(na.?, nb.?)
        else if (na != null) std.math.Order.lt // numeric identifiers sort first
        else if (nb != null) std.math.Order.gt
        else std.mem.order(u8, sa, sb);
        if (ord != .eq) return ord;
    }
}

// ── Merge with the user's own repositories ─────────────────────────────

pub const OwnRepo = struct { id: []const u8, url: []const u8, public_key: []const u8 };
pub const Status = enum { available, added, conflict };

/// `added` only when the user already pinned the same URL with the same key.
/// The same id or URL under a different key is a `conflict`: the index can
/// never replace a key the user pinned.
pub fn status(entry: Entry, own: []const OwnRepo) Status {
    var result: Status = .available;
    for (own) |r| {
        const same_key = std.ascii.eqlIgnoreCase(r.public_key, entry.public_key);
        const same_url = std.mem.eql(u8, r.url, entry.url);
        if (same_url and same_key) return .added;
        if (std.mem.eql(u8, r.id, entry.id) or same_url) result = .conflict;
    }
    return result;
}

// ── Search ranking ─────────────────────────────────────────────────────

pub const Candidate = struct {
    name: []const u8,
    id: []const u8,
    description: []const u8 = "",
    tags: []const []const u8 = &.{},
};

/// 0 means "does not match". Every whitespace-separated token must match some
/// field; better field matches score higher. An empty query matches all.
pub fn score(query: []const u8, c: Candidate) u32 {
    var total: u32 = 0;
    var tokens = std.mem.tokenizeAny(u8, query, " \t");
    var any = false;
    while (tokens.next()) |tok| {
        any = true;
        const s = tokenScore(tok, c);
        if (s == 0) return 0;
        total += s;
    }
    return if (any) total else 1;
}

fn tokenScore(tok: []const u8, c: Candidate) u32 {
    var best: u32 = 0;
    if (std.ascii.eqlIgnoreCase(c.name, tok)) best = @max(best, 100);
    if (std.ascii.eqlIgnoreCase(c.id, tok)) best = @max(best, 80);
    if (std.ascii.startsWithIgnoreCase(c.name, tok)) best = @max(best, 60);
    if (wordStart(c.name, tok)) best = @max(best, 45);
    if (std.ascii.startsWithIgnoreCase(c.id, tok)) best = @max(best, 50);
    if (std.ascii.findIgnoreCase(c.name, tok) != null) best = @max(best, 30);
    if (std.ascii.findIgnoreCase(c.id, tok) != null) best = @max(best, 25);
    for (c.tags) |tag| {
        if (std.ascii.eqlIgnoreCase(tag, tok)) best = @max(best, 20);
    }
    if (std.ascii.findIgnoreCase(c.description, tok) != null) best = @max(best, 10);
    return best;
}

fn wordStart(hay: []const u8, tok: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, hay, " -_");
    while (words.next()) |w| if (std.ascii.startsWithIgnoreCase(w, tok)) return true;
    return false;
}

/// Fill `out` with indices of matching candidates, best first (ties by name,
/// then id). Returns the count written.
pub fn rank(candidates: []const Candidate, query: []const u8, out: []usize) usize {
    var scores_buf: [256]u32 = undefined;
    var n: usize = 0;
    for (candidates, 0..) |c, i| {
        if (n >= out.len or n >= scores_buf.len) break;
        const s = score(query, c);
        if (s == 0) continue;
        // Insertion sort: n is small (index entries + catalog add-ons).
        var j = n;
        while (j > 0 and before(s, c, scores_buf[j - 1], candidates[out[j - 1]])) : (j -= 1) {
            out[j] = out[j - 1];
            scores_buf[j] = scores_buf[j - 1];
        }
        out[j] = i;
        scores_buf[j] = s;
        n += 1;
    }
    return n;
}

fn before(sa: u32, a: Candidate, sb: u32, b: Candidate) bool {
    if (sa != sb) return sa > sb;
    const by_name = std.ascii.orderIgnoreCase(a.name, b.name);
    if (by_name != .eq) return by_name == .lt;
    return std.mem.order(u8, a.id, b.id) == .lt;
}

// ── Tests ──────────────────────────────────────────────────────────────

const fixture_index = @embedFile("fixtures/addon_index/index.json");
const fixture_signed_index = @embedFile("fixtures/addon_index/index.signed.json");
const fixture_repo = @embedFile("fixtures/addon_index/repo.json");
const fixture_index_key = "1398f62c6d1a457c51ba6a4b5f3dbd2f69fca93216218dc8997e416bd17d93ca";

test "fixture index parses and its entry key verifies the signed fixture repository" {
    const a = std.testing.allocator;
    const index = try parse(a, fixture_index, "");
    defer index.deinit();
    try std.testing.expectEqual(@as(usize, 2), index.value.repositories.len);
    const entry = index.value.repositories[0];
    try std.testing.expectEqualStrings("fixture", entry.id);
    // The pinned key from the index verifies the repo through the existing path.
    const verified = try repo_pure.verify(a, fixture_repo, entry.public_key);
    defer verified.deinit();
    try std.testing.expectEqualStrings("hello-lua", verified.catalog.value.addons[0].id);
    try std.testing.expect(verified.catalog.value.addons[0].requests(.network));
    // Another entry's key cannot vouch for that repository's bytes.
    try std.testing.expectError(error.InvalidSignature, repo_pure.verify(a, fixture_repo, index.value.repositories[1].public_key));
}

test "signed index verifies exact bytes and rejects wrong keys and tampering" {
    const a = std.testing.allocator;
    const index = try parse(a, fixture_signed_index, fixture_index_key);
    defer index.deinit();
    try std.testing.expectEqualStrings("anime-extras", index.value.repositories[1].id);
    const repo_key = index.value.repositories[0].public_key;
    try std.testing.expectError(error.InvalidSignature, parse(a, fixture_signed_index, repo_key));
    // A signed-index setting refuses a plain (unsigned) index.
    try std.testing.expectError(error.UnknownField, parse(a, fixture_index, fixture_index_key));
    const tampered = try a.dupe(u8, fixture_signed_index);
    defer a.free(tampered);
    const at = std.mem.indexOf(u8, tampered, "Anime Extras").?;
    tampered[at] = 'B';
    try std.testing.expectError(error.InvalidSignature, parse(a, tampered, fixture_index_key));
}

test "index entries must be safe ids, HTTPS or localhost URLs and valid keys" {
    const a = std.testing.allocator;
    const key = "ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c";
    const cases = [_]struct { json: []const u8, err: anyerror }{
        .{ .json = "{\"version\":2,\"repositories\":[]}", .err = error.UnsupportedIndex },
        .{ .json = "{\"version\":1,\"repositories\":[{\"id\":\"../x\",\"name\":\"X\",\"url\":\"https://e.org/r\",\"public_key\":\"" ++ key ++ "\"}]}", .err = error.InvalidEntryId },
        .{ .json = "{\"version\":1,\"repositories\":[{\"id\":\"x\",\"name\":\"X\",\"url\":\"http://e.org/r\",\"public_key\":\"" ++ key ++ "\"}]}", .err = error.InvalidEntryUrl },
        .{ .json = "{\"version\":1,\"repositories\":[{\"id\":\"x\",\"name\":\"X\",\"url\":\"https://e.org/r\",\"public_key\":\"zz\"}]}", .err = error.InvalidEntryKey },
        .{ .json = "{\"version\":1,\"repositories\":[{\"id\":\"x\",\"name\":\"X\",\"url\":\"https://e.org/r\",\"public_key\":\"" ++ key ++ "\"},{\"id\":\"x\",\"name\":\"Y\",\"url\":\"https://e.org/s\",\"public_key\":\"" ++ key ++ "\"}]}", .err = error.DuplicateEntry },
    };
    for (cases) |case| try std.testing.expectError(case.err, parse(a, case.json, ""));
    try std.testing.expect(!validKey("ea4a"));
}

test "version comparison orders numeric parts, prefixes and prereleases" {
    const O = std.math.Order;
    try std.testing.expectEqual(O.gt, compareVersions("1.2.0", "1.1.9"));
    try std.testing.expectEqual(O.gt, compareVersions("1.10", "1.9"));
    try std.testing.expectEqual(O.eq, compareVersions("v2", "2.0.0"));
    try std.testing.expectEqual(O.eq, compareVersions("1.0.0+build.5", "1.0.0"));
    try std.testing.expectEqual(O.lt, compareVersions("1.0.0-beta", "1.0.0"));
    try std.testing.expectEqual(O.gt, compareVersions("1.0.0-beta.2", "1.0.0-beta.1"));
    try std.testing.expectEqual(O.lt, compareVersions("1.0.0-alpha", "1.0.0-beta"));
    try std.testing.expectEqual(O.lt, compareVersions("1.0.0-1", "1.0.0-alpha"));
    try std.testing.expect(updateAvailable("1.1.0", "1.2.0"));
    try std.testing.expect(!updateAvailable("1.2.0", "1.2.0"));
    try std.testing.expect(!updateAvailable("2.0.0", "1.9.9"));
}

test "index status never lets an entry replace a pinned key" {
    const key_a = "ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c";
    const key_b = "1398f62c6d1a457c51ba6a4b5f3dbd2f69fca93216218dc8997e416bd17d93ca";
    const entry: Entry = .{ .id = "fixture", .name = "F", .url = "https://e.org/r", .public_key = key_a };
    try std.testing.expectEqual(Status.available, status(entry, &.{}));
    try std.testing.expectEqual(Status.added, status(entry, &.{.{ .id = "mine", .url = "https://e.org/r", .public_key = key_a }}));
    try std.testing.expectEqual(Status.conflict, status(entry, &.{.{ .id = "fixture", .url = "https://other.org/r", .public_key = key_a }}));
    try std.testing.expectEqual(Status.conflict, status(entry, &.{.{ .id = "mine", .url = "https://e.org/r", .public_key = key_b }}));
}

test "search ranks name over id over tags over description and requires every token" {
    const tags_anime = [_][]const u8{"anime"};
    const cands = [_]Candidate{
        .{ .name = "Fixture Repository", .id = "fixture", .description = "Local signed fixture repository" },
        .{ .name = "Anime Extras", .id = "anime-extras", .description = "Anime sources", .tags = &tags_anime },
        .{ .name = "Hello Lua", .id = "hello-lua", .description = "Fixture add-on for anime" },
    };
    var out: [8]usize = undefined;
    var n = rank(&cands, "anime", &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(usize, 1), out[0]);
    try std.testing.expectEqual(@as(usize, 2), out[1]);
    n = rank(&cands, "", &out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 2 }, out[0..n]);
    n = rank(&cands, "fixture lua", &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(usize, 2), out[0]);
    try std.testing.expectEqual(@as(u32, 0), score("zzz", cands[0]));
}
