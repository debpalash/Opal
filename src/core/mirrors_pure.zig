//! Pure (io-free) mirror/failover rules for installed sources — unit-testable
//! via `zig build test`. `mirrors.zig` routes through these.
//!
//! Why this exists: every source had exactly ONE `base`. When that domain is
//! blocked, seized or Cloudflare-walled the source returns nothing and says
//! nothing — the single most common failure mode for this class of site.
//!
//! A source may now supply a `mirrors` endpoint field alongside `base`:
//!
//!     { "base": "https://1337x.to",
//!       "mirrors": "https://1337x.st,https://x1337x.eu" }
//!
//! In the manifest it may also be a JSON array; `source_config.reload()` folds an
//! array into the same comma-separated string, so there is ONE representation to
//! parse. Order is base first, then mirrors as listed; the last host that
//! actually answered is tried first next time (remembered for the session only —
//! there is no background prober).

const std = @import("std");

/// Hosts tried for one source. Base + mirrors; anything past this is ignored.
pub const MAX_CANDIDATES = 8;

/// One candidate origin, whitespace- and trailing-slash-trimmed.
pub fn normalize(raw: []const u8) []const u8 {
    var u = std.mem.trim(u8, raw, " \t\r\n\"");
    while (u.len > 0 and u[u.len - 1] == '/') u = u[0 .. u.len - 1];
    return u;
}

/// Only http(s) origins are usable as a mirror. Rejects the empty string, bare
/// hostnames and anything with a space (which would be two entries, not one).
pub fn usable(u: []const u8) bool {
    if (!(std.mem.startsWith(u8, u, "http://") or std.mem.startsWith(u8, u, "https://"))) return false;
    if (std.mem.indexOfScalar(u8, u, ' ') != null) return false;
    // Needs at least one host character after the scheme.
    const after = if (std.mem.startsWith(u8, u, "https://")) u[8..] else u[7..];
    return after.len > 0;
}

/// Candidate origins for a source, in configured order: `base` first, then each
/// entry of `spec` (comma / semicolon / newline separated). Normalized, filtered
/// to http(s), de-duplicated, capped at `out.len`. Returns how many were written.
pub fn candidates(base: []const u8, spec: []const u8, out: [][]const u8) usize {
    var n: usize = 0;

    const add = struct {
        fn f(u_raw: []const u8, o: [][]const u8, count: *usize) void {
            if (count.* >= o.len) return;
            const u = normalize(u_raw);
            if (!usable(u)) return;
            for (o[0..count.*]) |seen| {
                if (std.mem.eql(u8, seen, u)) return;
            }
            o[count.*] = u;
            count.* += 1;
        }
    }.f;

    add(base, out, &n);

    var it = std.mem.tokenizeAny(u8, spec, ",;\n\r\t ");
    while (it.next()) |part| add(part, out, &n);

    return n;
}

/// Which candidate to try on attempt `attempt` (0-based) when `last_good` was
/// the host that answered last time. Rotates so the last-good host is tried
/// first and every other host is still tried exactly once.
pub fn attemptIndex(count: usize, last_good: usize, attempt: usize) usize {
    if (count == 0) return 0;
    const lg = if (last_good < count) last_good else 0;
    return (lg + attempt) % count;
}

/// True when a response body is an interstitial rather than the content — a
/// Cloudflare/DDoS-Guard challenge or a block page. Those come back HTTP 200, so
/// the fetch "succeeds" and the parse silently finds nothing; treat them as a
/// dead host and move to the next mirror.
pub fn looksBlocked(body: []const u8) bool {
    if (body.len == 0) return true;
    const head = body[0..@min(body.len, 4096)];
    const needles = [_][]const u8{
        "Just a moment...",
        "cf-browser-verification",
        "Checking your browser before accessing",
        "Attention Required! | Cloudflare",
        "DDoS-Guard",
        "_Incapsula_Resource",
        "This site can’t be reached",
        "has been seized",
    };
    for (needles) |nd| {
        if (std.mem.indexOf(u8, head, nd) != null) return true;
    }
    return false;
}

/// Whether to fail over to the next candidate. `body` is null when the fetch
/// itself failed (connection refused, DNS, timeout, or any non-2xx — `http.fetch`
/// collapses all of those into null).
pub fn shouldFailover(body: ?[]const u8) bool {
    const b = body orelse return true;
    return looksBlocked(b);
}

// ══════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "normalize trims whitespace, quotes and trailing slashes" {
    try expectEqualStrings("https://1337x.to", normalize("  https://1337x.to/ "));
    try expectEqualStrings("https://1337x.to", normalize("https://1337x.to///"));
    try expectEqualStrings("", normalize("   "));
}

test "usable accepts only http(s) origins" {
    try expect(usable("https://1337x.to"));
    try expect(usable("http://127.0.0.1:9117"));
    try expect(!usable(""));
    try expect(!usable("1337x.to"));
    try expect(!usable("ftp://1337x.to"));
    try expect(!usable("https://"));
    try expect(!usable("https://a b"));
}

test "candidates puts base first and de-duplicates" {
    var buf: [MAX_CANDIDATES][]const u8 = undefined;
    const n = candidates("https://1337x.to", "https://1337x.st, https://x1337x.eu", &buf);
    try expectEqual(@as(usize, 3), n);
    try expectEqualStrings("https://1337x.to", buf[0]);
    try expectEqualStrings("https://1337x.st", buf[1]);
    try expectEqualStrings("https://x1337x.eu", buf[2]);

    // The base repeated in the mirror list is not tried twice, with or without
    // the trailing slash that distinguishes the two spellings.
    const n2 = candidates("https://1337x.to", "https://1337x.to/,https://1337x.st", &buf);
    try expectEqual(@as(usize, 2), n2);
    try expectEqualStrings("https://1337x.st", buf[1]);
}

test "candidates tolerates every separator style and junk entries" {
    var buf: [MAX_CANDIDATES][]const u8 = undefined;
    const n = candidates("https://a.example", "https://b.example\nhttps://c.example;  ;https://d.example\t\n", &buf);
    try expectEqual(@as(usize, 4), n);
    try expectEqualStrings("https://d.example", buf[3]);

    // Non-http junk is dropped, not passed to the fetcher.
    const n2 = candidates("https://a.example", "javascript:alert(1),b.example,ftp://c", &buf);
    try expectEqual(@as(usize, 1), n2);

    // No base, only mirrors → still usable.
    const n3 = candidates("", "https://only.example", &buf);
    try expectEqual(@as(usize, 1), n3);
    try expectEqualStrings("https://only.example", buf[0]);

    // Nothing configured at all → zero candidates, caller stays inert.
    try expectEqual(@as(usize, 0), candidates("", "", &buf));
}

test "candidates never writes past the caller's array" {
    var buf: [2][]const u8 = undefined;
    const n = candidates("https://a.example", "https://b.example,https://c.example,https://d.example", &buf);
    try expectEqual(@as(usize, 2), n);
}

test "attemptIndex rotates to the last-good host and still covers every host" {
    // Fresh session: plain order.
    try expectEqual(@as(usize, 0), attemptIndex(3, 0, 0));
    try expectEqual(@as(usize, 1), attemptIndex(3, 0, 1));
    try expectEqual(@as(usize, 2), attemptIndex(3, 0, 2));

    // Mirror #2 answered last time → it goes first, and the other two still get
    // a turn (a rotation, not a swap — no host is skipped or repeated).
    var seen = [_]bool{false} ** 3;
    for (0..3) |a| seen[attemptIndex(3, 2, a)] = true;
    try expect(seen[0] and seen[1] and seen[2]);
    try expectEqual(@as(usize, 2), attemptIndex(3, 2, 0));

    // Stale index (mirror list shrank) falls back to the base, never OOB.
    try expectEqual(@as(usize, 0), attemptIndex(2, 7, 0));
    try expectEqual(@as(usize, 0), attemptIndex(0, 3, 5));
}

test "looksBlocked catches 200-OK challenge pages" {
    try expect(looksBlocked("<html><head><title>Just a moment...</title></head></html>"));
    try expect(looksBlocked("<html>Checking your browser before accessing 1337x.to</html>"));
    try expect(looksBlocked("<div class=\"cf-browser-verification\">"));
    try expect(looksBlocked("<h1>DDoS-Guard</h1>"));
    try expect(looksBlocked("")); // empty body is not content either
    try expect(!looksBlocked("<html><body><tr><td class=\"name\">Some.Release.1080p</td></tr></body></html>"));
}

test "shouldFailover on a failed fetch and on a challenge body" {
    try expect(shouldFailover(null)); // connection refused / DNS / non-2xx
    try expect(shouldFailover("Just a moment..."));
    try expect(!shouldFailover("<rss><channel><item><title>x</title></item></channel></rss>"));
}
