const std = @import("std");

// ══════════════════════════════════════════════════════════
// Anti-block scrape-fetch — pure block detection
//
// Decides whether a plain HTTP response is a Cloudflare / DDoS-Guard / JS-
// challenge / captcha interstitial (i.e. we were BLOCKED and got a challenge
// page instead of the content). When true, scrape_fetch.zig transparently
// re-fetches the same URL through Opal's anti-detect browser, which passes the
// challenge.
//
// Design goal: NO FALSE POSITIVES. A normal page that merely mentions the word
// "cloudflare" in its footer (millions of sites sit behind Cloudflare and say
// so) must NOT be flagged. We key strictly on interstitial-only markers —
// challenge phrases, challenge script/element ids, and the header signals
// Cloudflare/DDoS-Guard attach to their block responses — never the bare
// brand name.
// ══════════════════════════════════════════════════════════

/// Case-insensitive substring search (ASCII). Empty needle → false (a marker
/// is never "present" as the empty string — avoids matching everything).
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    const last = haystack.len - needle.len;
    outer: while (i <= last) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) continue :outer;
        }
        return true;
    }
    return false;
}

/// Interstitial body phrases. These appear ONLY on challenge / block pages —
/// not in normal page chrome — so a substring hit is a reliable block signal.
/// Deliberately excludes the bare word "cloudflare" (footer badges, "powered
/// by", CDN mentions) which would false-positive on legitimate pages.
const CHALLENGE_MARKERS = [_][]const u8{
    // Cloudflare "Just a moment…" / "Under attack" interstitial
    "Just a moment",
    "Checking your browser",
    "cf-browser-verification",
    "cf_chl_opt",
    "__cf_chl",
    "challenge-platform",
    "cf-challenge-running",
    "id=\"challenge-running\"",
    // Cloudflare block / WAF page
    "Attention Required! | Cloudflare",
    "Sorry, you have been blocked",
    // DDoS-Guard
    "DDoS-Guard",
    "ddos-guard",
    "check.ddos-guard.net",
    // Generic human-verification interstitials (Turnstile / hCaptcha gate)
    "Please verify you are a human",
    "Verifying you are human",
    "Enable JavaScript and cookies to continue",
    "challenges.cloudflare.com/turnstile",
};

/// True when the body looks like a challenge / block interstitial rather than
/// real content. Truncated bodies (we only ever see the head) are fine — the
/// markers all sit in the <head>/top of these pages.
pub fn looksLikeChallengePage(body: []const u8) bool {
    if (body.len == 0) return false;
    for (CHALLENGE_MARKERS) |m| {
        if (containsIgnoreCase(body, m)) return true;
    }
    return false;
}

/// Header/status-level block signal. Cloudflare and DDoS-Guard stamp their
/// challenge/block responses with these headers; a 403/503/429 carrying a
/// cf-ray (or a Cloudflare server banner, or the cf-mitigated marker) is a
/// block, not an application-level error we should surface as-is.
pub fn headerBlock(status: u16, headers: []const u8) bool {
    // cf-mitigated: challenge is emitted regardless of status → always a block.
    if (containsIgnoreCase(headers, "cf-mitigated")) return true;
    // The clearance-challenge cookie is only ever set by a challenge response.
    if (containsIgnoreCase(headers, "cf_clearance")) return true;
    if (containsIgnoreCase(headers, "__ddg") and (status == 403 or status == 503)) return true;
    if (status == 403 or status == 503 or status == 429) {
        if (containsIgnoreCase(headers, "cf-ray")) return true;
        if (containsIgnoreCase(headers, "server: cloudflare")) return true;
        if (containsIgnoreCase(headers, "ddos-guard")) return true;
    }
    return false;
}

/// Blocked = a header/status block signal OR a challenge-interstitial body.
pub fn isBlocked(status: u16, headers: []const u8, body_head: []const u8) bool {
    if (headerBlock(status, headers)) return true;
    if (looksLikeChallengePage(body_head)) return true;
    return false;
}

/// Parse the numeric HTTP status from a raw header dump (curl -D). With
/// redirects the dump holds several `HTTP/x NNN` status lines — the LAST one is
/// the final response, so we scan for the last "HTTP/" line. 0 if none found.
pub fn parseStatus(headers: []const u8) u16 {
    var status: u16 = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, headers, i, "HTTP/")) |pos| {
        // Skip "HTTP/x.y " (or "HTTP/2 ") to the first space, then read digits.
        var p = pos;
        while (p < headers.len and headers[p] != ' ') p += 1;
        while (p < headers.len and headers[p] == ' ') p += 1;
        var code: u16 = 0;
        var got = false;
        while (p < headers.len and headers[p] >= '0' and headers[p] <= '9') : (p += 1) {
            code = code * 10 + (headers[p] - '0');
            got = true;
        }
        if (got) status = code;
        i = pos + 5;
    }
    return status;
}

/// Composite the fetch layer routes through: should this response be re-fetched
/// through the anti-detect browser? True when it is blocked. A fetch that
/// returned nothing at all (empty body AND no usable status) is treated as
/// not-blocked here — we never invent a block from the absence of data; the
/// caller decides whether an empty result is worth a browser retry on its own.
pub fn needsBrowser(status: u16, headers: []const u8, body_head: []const u8) bool {
    return isBlocked(status, headers, body_head);
}

// ── tests ──────────────────────────────────────────────────

// A trimmed-but-representative Cloudflare "Just a moment…" interstitial.
const CF_CHALLENGE_BODY =
    \\<!DOCTYPE html><html lang="en-US"><head><title>Just a moment...</title>
    \\<meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
    \\<meta name="robots" content="noindex,nofollow">
    \\<script src="/cdn-cgi/challenge-platform/h/b/orchestrate/chl_page/v1"></script>
    \\</head><body class="no-js"><div class="main-wrapper">
    \\<h1>Checking your browser before accessing the site.</h1>
    \\<div id="challenge-running"></div>
    \\<script>window._cf_chl_opt={cvId:'3'};</script>
    \\</body></html>
;

// A perfectly normal HTML page that HAPPENS to mention Cloudflare in a footer —
// must NOT be flagged (the classic false-positive we are guarding against).
const NORMAL_BODY =
    \\<!DOCTYPE html><html><head><title>My Comic — Chapter 12</title></head>
    \\<body><h1>Chapter 12</h1><img src="/pages/1.jpg"><img src="/pages/2.jpg">
    \\<footer>This site is protected by Cloudflare. Powered by Cloudflare CDN.</footer>
    \\</body></html>
;

test "cloudflare challenge body is detected" {
    try std.testing.expect(looksLikeChallengePage(CF_CHALLENGE_BODY));
    try std.testing.expect(isBlocked(200, "", CF_CHALLENGE_BODY));
    try std.testing.expect(needsBrowser(200, "", CF_CHALLENGE_BODY));
}

test "normal page mentioning cloudflare in footer is NOT blocked" {
    try std.testing.expect(!looksLikeChallengePage(NORMAL_BODY));
    try std.testing.expect(!isBlocked(200, "server: cloudflare\r\ncf-ray: abc123-LAX\r\n", NORMAL_BODY));
    try std.testing.expect(!needsBrowser(200, "", NORMAL_BODY));
}

test "503 with cf-ray header is blocked even with empty body" {
    const headers = "HTTP/2 503\r\nserver: cloudflare\r\ncf-ray: 7abc-DFW\r\n";
    try std.testing.expect(headerBlock(503, headers));
    try std.testing.expect(isBlocked(503, headers, ""));
    try std.testing.expect(needsBrowser(503, headers, ""));
}

test "cf-mitigated challenge header blocks on any status" {
    try std.testing.expect(headerBlock(200, "cf-mitigated: challenge\r\n"));
    try std.testing.expect(isBlocked(200, "cf-mitigated: challenge\r\n", ""));
}

test "403 without any cloudflare signal is NOT auto-classified as a challenge block" {
    // A plain application 403 (no cf-ray / no challenge body) is not a browser-
    // solvable challenge — don't waste a browser round-trip on it.
    try std.testing.expect(!headerBlock(403, "HTTP/1.1 403 Forbidden\r\ncontent-type: application/json\r\n"));
    try std.testing.expect(!isBlocked(403, "HTTP/1.1 403 Forbidden\r\ncontent-type: application/json\r\n", "{\"error\":\"forbidden\"}"));
}

test "empty / truncated inputs never crash and are not blocked" {
    try std.testing.expect(!looksLikeChallengePage(""));
    try std.testing.expect(!isBlocked(0, "", ""));
    try std.testing.expect(!needsBrowser(0, "", ""));
    try std.testing.expect(!headerBlock(200, ""));
    // A one-byte body must not index out of bounds against long markers.
    try std.testing.expect(!looksLikeChallengePage("x"));
}

test "DDoS-Guard interstitial is detected" {
    const body = "<html><head><title>DDoS-Guard</title></head><body>Checking your browser</body></html>";
    try std.testing.expect(looksLikeChallengePage(body));
    try std.testing.expect(needsBrowser(200, "", body));
}

test "parseStatus reads the final status across redirects" {
    try std.testing.expectEqual(@as(u16, 200), parseStatus("HTTP/2 200\r\ncontent-type: text/html\r\n"));
    try std.testing.expectEqual(@as(u16, 503), parseStatus("HTTP/1.1 301 Moved\r\n\r\nHTTP/2 503\r\nserver: cloudflare\r\n"));
    try std.testing.expectEqual(@as(u16, 403), parseStatus("HTTP/1.1 403 Forbidden\r\n"));
    try std.testing.expectEqual(@as(u16, 0), parseStatus("no status here\r\n"));
    try std.testing.expectEqual(@as(u16, 0), parseStatus(""));
}

test "case-insensitive marker matching" {
    try std.testing.expect(looksLikeChallengePage("<title>JUST A MOMENT...</title>"));
    try std.testing.expect(containsIgnoreCase("ABCdef", "cdE"));
    try std.testing.expect(!containsIgnoreCase("abc", ""));
    try std.testing.expect(!containsIgnoreCase("ab", "abc"));
}
