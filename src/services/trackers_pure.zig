//! Pure tracker-list logic — parsing, validation, dedupe, cap, serialization.
//!
//! Opal streams magnets, so time-to-first-piece IS the product. A magnet with
//! only its own (often dead) tracker list has to wait on DHT bootstrap before a
//! single peer shows up. Injecting a large, CURRENT public tracker list at
//! add-time is the cheapest fix there is — but the list has to come from the
//! network at runtime, and network text is untrusted.
//!
//! Everything that decides *what counts as a tracker* lives here so it can be
//! tested against the real upstream files byte-for-byte; `trackers.zig` only
//! does the fetching/caching and hands the result to the C++ wrapper.
//!
//! TWO SEPARATOR STYLES. The upstream lists disagree:
//!   - ngosang/trackerslist `trackers_best.txt` — entry, BLANK LINE, entry, ...
//!   - plain newline lists (XIU2 raw variants, a hand-edited cache file)
//! A single parser handles both by treating any run of blank lines as nothing
//! more than a separator; there is no "record" concept to get wrong.
//!
//! LICENCE: the upstream lists are GPL-2.0 (Opal is GPL-3.0). They are fetched
//! at RUNTIME and never vendored into this repo — see trackers.zig. The
//! FALLBACK list below is Opal's own long-standing baked-in set, not a copy of
//! anyone's file.

const std = @import("std");

/// libtorrent announces to every tracker in the list on add; past ~75 the
/// announce burst costs more than the extra peers are worth.
pub const MAX_TRACKERS: usize = 75;

/// Longest announce URL we will keep. Real entries top out around 60 bytes;
/// anything longer is junk, not a tracker.
pub const MAX_URL_LEN: usize = 160;

/// Below this many usable entries the fetched list is treated as a failure and
/// the caller falls through to the next source (see trackers.zig).
pub const MIN_USABLE: usize = 8;

/// Re-fetch once a day. Both upstreams regenerate daily; more often is rude,
/// less often defeats the point.
pub const TTL_SECS: i64 = 24 * 60 * 60;

/// Schemes libtorrent can actually announce to. Anything else (`ws`, `dht`,
/// `magnet`, a stray markdown link) is dropped.
const VALID_SCHEMES = [_][]const u8{ "udp", "http", "https", "wss" };

/// Opal's own baked-in set — the OFFLINE FALLBACK, so a cold start with no
/// cache and no network still gets more than the magnet's own trackers.
/// This is the list that used to be duplicated verbatim in two places inside
/// torrent_wrapper.cpp.
pub const FALLBACK = [_][]const u8{
    "udp://tracker.opentrackr.org:1337/announce",
    "udp://open.stealth.si:80/announce",
    "udp://tracker.torrent.eu.org:451/announce",
    "udp://tracker.bittor.pw:1337/announce",
    "udp://public.popcorn-tracker.org:6969/announce",
    "udp://tracker.dler.org:6969/announce",
    "udp://exodus.desync.com:6969/announce",
    "udp://open.demonii.com:1337/announce",
};

pub const Entry = struct {
    buf: [MAX_URL_LEN]u8 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Entry) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Fixed-size, no allocation — same convention as the state structs.
pub const List = struct {
    items: [MAX_TRACKERS]Entry = [_]Entry{.{}} ** MAX_TRACKERS,
    count: usize = 0,

    pub fn at(self: *const List, i: usize) []const u8 {
        return self.items[i].slice();
    }

    pub fn full(self: *const List) bool {
        return self.count >= MAX_TRACKERS;
    }

    pub fn reset(self: *List) void {
        self.count = 0;
    }
};

// ══════════════════════════════════════════════════════════
// URL DISSECTION
// ══════════════════════════════════════════════════════════

/// Scheme before "://", or null when there is no "://".
pub fn schemeOf(url: []const u8) ?[]const u8 {
    const i = std.mem.indexOf(u8, url, "://") orelse return null;
    if (i == 0) return null;
    return url[0..i];
}

/// Host WITHOUT port or path — the dedupe key. IPv6 literals keep their
/// brackets (`[2001:db8::1]`) so the colon-splitting doesn't shred them.
pub fn hostOf(url: []const u8) ?[]const u8 {
    const i = std.mem.indexOf(u8, url, "://") orelse return null;
    const rest = url[i + 3 ..];
    if (rest.len == 0) return null;

    if (rest[0] == '[') {
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
        if (close < 2) return null;
        return rest[0 .. close + 1];
    }
    const end = std.mem.indexOfAny(u8, rest, ":/?#") orelse rest.len;
    if (end == 0) return null;
    return rest[0..end];
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

fn schemeAllowed(scheme: []const u8) bool {
    for (VALID_SCHEMES) |s| {
        if (eqlIgnoreCase(scheme, s)) return true;
    }
    return false;
}

/// Is this a tracker announce URL we are willing to hand to libtorrent?
///
/// Rejects, in order: wrong length, no/blocked scheme, whitespace or control
/// bytes or quoting (i.e. a markdown/HTML fragment, not a URL), an unusable
/// host, and — deliberately — a `0.0.0.0` host, which is what a DNS blocklist
/// turns a tracker domain into when the list itself was resolved locally.
pub fn isAnnounceUrl(url: []const u8) bool {
    if (url.len < 10 or url.len > MAX_URL_LEN) return false;

    const scheme = schemeOf(url) orelse return false;
    if (!schemeAllowed(scheme)) return false;

    for (url) |ch| {
        if (ch <= ' ' or ch == 127) return false; // space, tab, CR, control
        if (ch == '"' or ch == '\'' or ch == '<' or ch == '>' or ch == '\\') return false;
    }

    const host = hostOf(url) orelse return false;
    if (host.len < 3) return false;
    // A real tracker host is a dotted name or an IP/IPv6 literal. This also
    // drops "localhost" and bare labels, which are never in a public list.
    if (std.mem.indexOfScalar(u8, host, '.') == null and host[0] != '[') return false;
    if (std.mem.eql(u8, host, "0.0.0.0")) return false;

    // Every entry in both upstreams ends in /announce (a few sites use
    // /announce.php). No announce path means it is not an announce endpoint.
    if (std.mem.indexOf(u8, url, "/announce") == null) return false;

    return true;
}

// ══════════════════════════════════════════════════════════
// PARSING
// ══════════════════════════════════════════════════════════

/// True when `list` already holds an entry for this URL's host.
/// Dedupe is BY HOST, not by URL: `udp://x:1337/announce` and
/// `http://x:1337/announce` are the same tracker announced twice, and both
/// upstream lists contain such pairs.
pub fn hasHost(list: *const List, host: []const u8) bool {
    var i: usize = 0;
    while (i < list.count) : (i += 1) {
        const h = hostOf(list.at(i)) orelse continue;
        if (eqlIgnoreCase(h, host)) return true;
    }
    return false;
}

fn append(list: *List, url: []const u8) bool {
    if (list.count >= MAX_TRACKERS) return false;
    if (url.len > MAX_URL_LEN) return false;
    var e = &list.items[list.count];
    @memcpy(e.buf[0..url.len], url);
    e.len = @intCast(url.len);
    list.count += 1;
    return true;
}

/// Parse a fetched/cached tracker list into `list`, APPENDING to whatever is
/// already there (so several sources can be merged with one dedupe pass).
/// Returns how many entries were added.
///
/// Handles both separator styles, `\r\n`, a UTF-8 BOM, `#` comments and
/// trailing junk — every line is trimmed and validated on its own, so a blank
/// line is simply a line that validates to nothing.
pub fn parseInto(text: []const u8, list: *List) usize {
    var body = text;
    if (std.mem.startsWith(u8, body, "\xEF\xBB\xBF")) body = body[3..];

    var added: usize = 0;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        if (list.full()) break;
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0) continue;
        if (line[0] == '#' or line[0] == ';') continue;
        if (!isAnnounceUrl(line)) continue;
        const host = hostOf(line) orelse continue;
        if (hasHost(list, host)) continue;
        if (append(list, line)) added += 1;
    }
    return added;
}

/// Append Opal's baked-in offline set (deduped against what is already there).
/// Returns how many were added.
pub fn appendFallback(list: *List) usize {
    var added: usize = 0;
    for (FALLBACK) |t| {
        if (list.full()) break;
        const host = hostOf(t) orelse continue;
        if (hasHost(list, host)) continue;
        if (append(list, t)) added += 1;
    }
    return added;
}

// ══════════════════════════════════════════════════════════
// SERIALIZATION + REFRESH POLICY
// ══════════════════════════════════════════════════════════

/// Newline-joined, NUL-terminated — the exact blob the C++ wrapper parses in
/// torrent_set_extra_trackers(). Returns the slice WITHOUT the NUL (the NUL is
/// written one past the end so the buffer is a valid C string). Returns null if
/// `buf` is too small.
pub fn serializeZ(list: *const List, buf: []u8) ?[]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < list.count) : (i += 1) {
        const s = list.at(i);
        if (n + s.len + 2 > buf.len) return null; // + separator + NUL
        if (n > 0) {
            buf[n] = '\n';
            n += 1;
        }
        @memcpy(buf[n .. n + s.len], s);
        n += s.len;
    }
    if (n + 1 > buf.len) return null;
    buf[n] = 0;
    return buf[0..n];
}

/// Byte size serializeZ needs, NUL included.
pub fn serializedSize(list: *const List) usize {
    var n: usize = 1; // NUL
    var i: usize = 0;
    while (i < list.count) : (i += 1) {
        n += list.at(i).len;
        if (i > 0) n += 1;
    }
    return n;
}

/// Should the cache be re-fetched? True when there is no cache (`mtime_s <= 0`),
/// when it is older than the TTL, or when its mtime is in the future (a clock
/// jump / bad copy — never trust it forever).
pub fn needsRefresh(now_s: i64, mtime_s: i64, ttl_s: i64) bool {
    if (mtime_s <= 0) return true;
    if (mtime_s > now_s) return true;
    return (now_s - mtime_s) >= ttl_s;
}

// ══════════════════════════════════════════════════════════
// TESTS
// ══════════════════════════════════════════════════════════

// Verbatim head of https://raw.githubusercontent.com/ngosang/trackerslist/
// master/trackers_best.txt — BLANK-LINE separated, trailing blank line.
// Fetched 2026-07-30. Fixture only; not shipped, not vendored.
const FIXTURE_NGOSANG =
    "udp://tracker.publictracker.xyz:6969/announce\n" ++
    "\n" ++
    "http://tracker.opentrackr.org:1337/announce\n" ++
    "\n" ++
    "udp://open.demonii.com:1337/announce\n" ++
    "\n" ++
    "udp://open.stealth.si:80/announce\n" ++
    "\n" ++
    "udp://tracker2.dler.org:80/announce\n" ++
    "\n" ++
    "udp://tracker.wildkat.net:6969/announce\n" ++
    "\n" ++
    "udp://tracker.torrent.eu.org:451/announce\n" ++
    "\n" ++
    "udp://tracker.qu.ax:6969/announce\n" ++
    "\n" ++
    "udp://tracker.opentrackr.org:6969/announce\n" ++
    "\n";

// Verbatim head + tail of https://cf.trackerslist.com/best.txt — same
// blank-line style today, mixed schemes including the one wss entry.
const FIXTURE_CF =
    "http://1337.abcvg.info:80/announce\n" ++
    "\n" ++
    "http://bt1.archive.org:6969/announce\n" ++
    "\n" ++
    "http://bt2.archive.org:6969/announce\n" ++
    "\n" ++
    "http://ipv4announce.sktorrent.eu:6969/announce\n" ++
    "\n" ++
    "http://nyaa.tracker.wf:7777/announce\n" ++
    "\n" ++
    "udp://tracker.tryhackx.org:6969/announce\n" ++
    "\n" ++
    "udp://tracker.wildkat.net:6969/announce\n" ++
    "\n" ++
    "wss://tracker.openwebtorrent.com:443/announce\n" ++
    "\n";

// The other separator style a list may arrive in (XIU2 raw variants, and our
// own cache file, which serializeZ writes with single newlines).
const FIXTURE_PLAIN =
    "udp://tracker.opentrackr.org:1337/announce\n" ++
    "udp://open.stealth.si:80/announce\n" ++
    "udp://tracker.torrent.eu.org:451/announce\n";

test "parseInto: blank-line separated (ngosang trackers_best.txt)" {
    var l = List{};
    const n = parseInto(FIXTURE_NGOSANG, &l);
    // 9 lines, but opentrackr.org appears twice (http + udp) → deduped by host.
    try std.testing.expectEqual(@as(usize, 8), n);
    try std.testing.expectEqual(@as(usize, 8), l.count);
    try std.testing.expectEqualStrings("udp://tracker.publictracker.xyz:6969/announce", l.at(0));
    // The FIRST occurrence of a host wins; the later udp:// dup is dropped.
    try std.testing.expectEqualStrings("http://tracker.opentrackr.org:1337/announce", l.at(1));
}

test "parseInto: plain-newline separated" {
    var l = List{};
    try std.testing.expectEqual(@as(usize, 3), parseInto(FIXTURE_PLAIN, &l));
    try std.testing.expectEqualStrings("udp://open.stealth.si:80/announce", l.at(1));
}

test "parseInto: both formats produce identical results for the same entries" {
    var a = List{};
    var b = List{};
    _ = parseInto("udp://a.example:80/announce\n\nudp://b.example:80/announce\n\n", &a);
    _ = parseInto("udp://a.example:80/announce\nudp://b.example:80/announce\n", &b);
    try std.testing.expectEqual(a.count, b.count);
    try std.testing.expectEqualStrings(a.at(0), b.at(0));
    try std.testing.expectEqualStrings(a.at(1), b.at(1));
}

test "parseInto: merging two sources dedupes across them" {
    var l = List{};
    const n1 = parseInto(FIXTURE_NGOSANG, &l);
    const n2 = parseInto(FIXTURE_CF, &l);
    // tracker.wildkat.net is in BOTH fixtures — counted once.
    try std.testing.expectEqual(@as(usize, 8), n1);
    try std.testing.expectEqual(@as(usize, 7), n2);
    try std.testing.expectEqual(@as(usize, 15), l.count);
    try std.testing.expect(hasHost(&l, "tracker.wildkat.net"));
    try std.testing.expectEqualStrings("wss://tracker.openwebtorrent.com:443/announce", l.at(14));
}

test "parseInto: CRLF, BOM, comments and blank runs" {
    var l = List{};
    const txt = "\xEF\xBB\xBF# a comment\r\n\r\n\r\nudp://a.example:80/announce\r\n\r\n" ++
        "; another comment\r\nudp://b.example:80/announce\r\n\r\n\r\n";
    try std.testing.expectEqual(@as(usize, 2), parseInto(txt, &l));
    try std.testing.expectEqualStrings("udp://a.example:80/announce", l.at(0));
}

test "isAnnounceUrl: scheme filter" {
    try std.testing.expect(isAnnounceUrl("udp://t.example:6969/announce"));
    try std.testing.expect(isAnnounceUrl("http://t.example:80/announce"));
    try std.testing.expect(isAnnounceUrl("https://t.example:443/announce"));
    try std.testing.expect(isAnnounceUrl("wss://t.example:443/announce"));
    // Not announce-capable schemes.
    try std.testing.expect(!isAnnounceUrl("ftp://t.example:21/announce"));
    try std.testing.expect(!isAnnounceUrl("magnet:?xt=urn:btih:aaaa/announce"));
    try std.testing.expect(!isAnnounceUrl("dht://router.bittorrent.com:6881/announce"));
}

test "isAnnounceUrl: junk rejection" {
    try std.testing.expect(!isAnnounceUrl(""));
    try std.testing.expect(!isAnnounceUrl("udp://"));
    try std.testing.expect(!isAnnounceUrl("just some prose"));
    try std.testing.expect(!isAnnounceUrl("udp://t.example:6969")); // no announce path
    try std.testing.expect(!isAnnounceUrl("udp://localhost:6969/announce")); // bare label
    try std.testing.expect(!isAnnounceUrl("<a href=udp://t.example:80/announce>")); // markup
    try std.testing.expect(!isAnnounceUrl("udp://t.example:80/announce extra")); // trailing junk
    // Over-long lines are junk, never trackers.
    var long: [MAX_URL_LEN + 40]u8 = undefined;
    @memset(&long, 'a');
    @memcpy(long[0..6], "udp://");
    try std.testing.expect(!isAnnounceUrl(&long));
}

test "isAnnounceUrl: DNS-blocklist sinkhole is rejected" {
    // NextDNS/pi-hole style blocking turns a tracker domain into 0.0.0.0; a
    // list resolved on such a machine must not poison the cache.
    try std.testing.expect(!isAnnounceUrl("udp://0.0.0.0:6969/announce"));
    try std.testing.expect(isAnnounceUrl("udp://93.158.213.92:6969/announce")); // real _ip entry
}

test "hostOf: port, path and IPv6" {
    try std.testing.expectEqualStrings("t.example", hostOf("udp://t.example:6969/announce").?);
    try std.testing.expectEqualStrings("t.example", hostOf("http://t.example/announce").?);
    try std.testing.expectEqualStrings("93.158.213.92", hostOf("udp://93.158.213.92:6969/announce").?);
    try std.testing.expectEqualStrings("[2001:db8::1]", hostOf("udp://[2001:db8::1]:6969/announce").?);
    try std.testing.expect(hostOf("no-scheme-here") == null);
}

test "dedupe is by host and case-insensitive" {
    var l = List{};
    const txt = "udp://Tracker.Example:6969/announce\nhttp://tracker.example:1337/announce\n";
    try std.testing.expectEqual(@as(usize, 1), parseInto(txt, &l));
}

test "cap: never exceeds MAX_TRACKERS" {
    var l = List{};
    var text: [MAX_TRACKERS * 3 * 48]u8 = undefined;
    var n: usize = 0;
    for (0..MAX_TRACKERS * 3) |i| {
        const line = std.fmt.bufPrint(text[n..], "udp://t{d}.example:6969/announce\n", .{i}) catch unreachable;
        n += line.len;
    }
    _ = parseInto(text[0..n], &l);
    try std.testing.expectEqual(MAX_TRACKERS, l.count);
    try std.testing.expect(l.full());
    // A second source cannot push it over either.
    try std.testing.expectEqual(@as(usize, 0), parseInto(FIXTURE_NGOSANG, &l));
    try std.testing.expectEqual(@as(usize, 0), appendFallback(&l));
    try std.testing.expectEqual(MAX_TRACKERS, l.count);
}

test "appendFallback: offline start still gets the baked-in eight" {
    var l = List{};
    try std.testing.expectEqual(FALLBACK.len, appendFallback(&l));
    try std.testing.expectEqual(@as(usize, 8), l.count);
    for (0..l.count) |i| try std.testing.expect(isAnnounceUrl(l.at(i)));
}

test "appendFallback: dedupes against an already-fetched list" {
    var l = List{};
    _ = parseInto(FIXTURE_NGOSANG, &l);
    // open.demonii.com, open.stealth.si, tracker.torrent.eu.org and
    // tracker.opentrackr.org are all in both → only 4 of the 8 are new.
    try std.testing.expectEqual(@as(usize, 4), appendFallback(&l));
    try std.testing.expectEqual(@as(usize, 12), l.count);
}

test "serializeZ round-trips through parseInto" {
    var a = List{};
    _ = parseInto(FIXTURE_NGOSANG, &a);
    _ = parseInto(FIXTURE_CF, &a);

    var buf: [MAX_TRACKERS * (MAX_URL_LEN + 1)]u8 = undefined;
    const blob = serializeZ(&a, &buf).?;
    try std.testing.expectEqual(serializedSize(&a), blob.len + 1);
    try std.testing.expectEqual(@as(u8, 0), buf[blob.len]); // NUL-terminated

    var b = List{};
    _ = parseInto(blob, &b);
    try std.testing.expectEqual(a.count, b.count);
    for (0..a.count) |i| try std.testing.expectEqualStrings(a.at(i), b.at(i));
}

test "serializeZ: empty list is an empty C string" {
    const l = List{};
    var buf: [4]u8 = undefined;
    const blob = serializeZ(&l, &buf).?;
    try std.testing.expectEqual(@as(usize, 0), blob.len);
    try std.testing.expectEqual(@as(u8, 0), buf[0]);
}

test "serializeZ: refuses to overflow a short buffer" {
    var l = List{};
    _ = appendFallback(&l);
    var buf: [16]u8 = undefined;
    try std.testing.expect(serializeZ(&l, &buf) == null);
}

test "needsRefresh: daily TTL" {
    const day = TTL_SECS;
    try std.testing.expect(needsRefresh(1_000_000, 0, day)); // no cache
    try std.testing.expect(!needsRefresh(1_000_000, 1_000_000 - 60, day)); // fresh
    try std.testing.expect(needsRefresh(1_000_000, 1_000_000 - day, day)); // exactly stale
    try std.testing.expect(needsRefresh(1_000_000, 1_000_000 - day - 1, day));
    try std.testing.expect(needsRefresh(1_000_000, 2_000_000, day)); // mtime in the future
}

test "MIN_USABLE guards a truncated/garbage download" {
    // A 404 page or a half-written body parses to almost nothing; the caller
    // uses MIN_USABLE to fall through to the next source instead of caching it.
    var l = List{};
    _ = parseInto("<!DOCTYPE html><html><body>404: Not Found</body></html>", &l);
    try std.testing.expectEqual(@as(usize, 0), l.count);
    try std.testing.expect(l.count < MIN_USABLE);
}
