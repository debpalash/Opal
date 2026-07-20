//! Pure helpers for building mpv's `http-header-fields` option value.
//!
//! mpv takes `http-header-fields` as a **comma-separated** list of
//! `Name: value` entries. That means the option value has no escaping
//! mechanism: a header whose value contains a `,` would be split by mpv into
//! two bogus headers, and a `\r`/`\n` would be a header-injection vector into
//! the raw request.
//!
//! **Documented rule:** a header is DROPPED entirely (not truncated, not
//! escaped) when its name or value is empty, or when either contains `,`,
//! `\r`, or `\n`. Dropping is the safe choice — a missing Referer produces an
//! honest 403 the caller can diagnose, whereas a mangled list corrupts every
//! *other* header in the same option string.
//!
//! Overflow follows the same all-or-nothing discipline: if the next entry does
//! not fit in `out`, it (and everything after it) is dropped, so the returned
//! slice is always a well-formed list.

const std = @import("std");

pub const HttpHeader = struct {
    name: []const u8,
    value: []const u8,
};

/// True when `s` is safe to place inside the comma-separated option value.
fn isSafe(s: []const u8) bool {
    for (s) |ch| {
        if (ch == ',' or ch == '\r' or ch == '\n') return false;
    }
    return true;
}

/// Join `headers` into `Name: value,Name2: value2` inside `out`.
/// Empty/unsafe headers are dropped (see module doc). Returns the written
/// slice, which may be empty.
pub fn buildHeaderFields(headers: []const HttpHeader, out: []u8) []const u8 {
    var len: usize = 0;
    for (headers) |h| {
        if (h.name.len == 0 or h.value.len == 0) continue;
        if (!isSafe(h.name) or !isSafe(h.value)) continue;

        const sep: usize = if (len > 0) 1 else 0;
        const need = sep + h.name.len + 2 + h.value.len; // "Name: value"
        if (len + need > out.len) continue; // drop, never partially emit

        if (sep == 1) {
            out[len] = ',';
            len += 1;
        }
        @memcpy(out[len..][0..h.name.len], h.name);
        len += h.name.len;
        out[len] = ':';
        out[len + 1] = ' ';
        len += 2;
        @memcpy(out[len..][0..h.value.len], h.value);
        len += h.value.len;
    }
    return out[0..len];
}

/// Derive an `Origin` value (`scheme://host[:port]`) from a Referer URL.
///
/// Returns null when `referer` is not an absolute http/https URL or when the
/// authority is empty. The most common IPTV/HLS 403 fix is sending an Origin
/// that matches the Referer's site.
pub fn originFromReferer(referer: []const u8, out: []u8) ?[]const u8 {
    const scheme_end = std.mem.indexOf(u8, referer, "://") orelse return null;
    const scheme = referer[0..scheme_end];
    if (!std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "https")) return null;

    const rest = referer[scheme_end + 3 ..];
    var authority_end = rest.len;
    for (rest, 0..) |ch, i| {
        if (ch == '/' or ch == '?' or ch == '#') {
            authority_end = i;
            break;
        }
    }
    const authority = rest[0..authority_end];
    if (authority.len == 0) return null;
    // Strip any userinfo — Origin is scheme + host + port only.
    const host = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority[at + 1 ..] else authority;
    if (host.len == 0) return null;

    const total = scheme.len + 3 + host.len;
    if (total > out.len) return null;
    @memcpy(out[0..scheme.len], scheme);
    @memcpy(out[scheme.len..][0..3], "://");
    @memcpy(out[scheme.len + 3 ..][0..host.len], host);
    return out[0..total];
}

// ── tests ────────────────────────────────────────────────────────────────

test "buildHeaderFields: empty list yields empty slice" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", buildHeaderFields(&.{}, &buf));
}

test "buildHeaderFields: skips empty name or empty value" {
    var buf: [128]u8 = undefined;
    const hs = [_]HttpHeader{
        .{ .name = "", .value = "x" },
        .{ .name = "Referer", .value = "" },
        .{ .name = "Origin", .value = "https://a.com" },
    };
    try std.testing.expectEqualStrings("Origin: https://a.com", buildHeaderFields(&hs, &buf));
}

test "buildHeaderFields: two headers joined with a comma" {
    var buf: [128]u8 = undefined;
    const hs = [_]HttpHeader{
        .{ .name = "Referer", .value = "https://a.com/e" },
        .{ .name = "Origin", .value = "https://a.com" },
    };
    try std.testing.expectEqualStrings(
        "Referer: https://a.com/e,Origin: https://a.com",
        buildHeaderFields(&hs, &buf),
    );
}

test "buildHeaderFields: value containing a comma is dropped, not emitted" {
    var buf: [128]u8 = undefined;
    const hs = [_]HttpHeader{
        .{ .name = "Cookie", .value = "a=1, b=2" },
        .{ .name = "Origin", .value = "https://a.com" },
    };
    try std.testing.expectEqualStrings("Origin: https://a.com", buildHeaderFields(&hs, &buf));
}

test "buildHeaderFields: CR/LF injection is dropped" {
    var buf: [128]u8 = undefined;
    const hs = [_]HttpHeader{
        .{ .name = "X", .value = "v\r\nEvil: 1" },
        .{ .name = "Y", .value = "ok" },
    };
    try std.testing.expectEqualStrings("Y: ok", buildHeaderFields(&hs, &buf));
}

test "buildHeaderFields: overflow drops the tail, never a partial header" {
    // "Referer: aaaa" is 13 bytes; a 16-byte buffer cannot also fit ",Origin: b".
    var buf: [16]u8 = undefined;
    const hs = [_]HttpHeader{
        .{ .name = "Referer", .value = "aaaa" },
        .{ .name = "Origin", .value = "bbbbbbbbbb" },
    };
    const got = buildHeaderFields(&hs, &buf);
    try std.testing.expectEqualStrings("Referer: aaaa", got);
}

test "originFromReferer: https with path" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://embed.example.com",
        originFromReferer("https://embed.example.com/e/abc?x=1", &buf).?,
    );
}

test "originFromReferer: http with port, no path" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "http://cdn.example.org:8080",
        originFromReferer("http://cdn.example.org:8080", &buf).?,
    );
}

test "originFromReferer: malformed and non-http return null" {
    var buf: [128]u8 = undefined;
    try std.testing.expect(originFromReferer("", &buf) == null);
    try std.testing.expect(originFromReferer("example.com/x", &buf) == null);
    try std.testing.expect(originFromReferer("ftp://example.com/x", &buf) == null);
    try std.testing.expect(originFromReferer("https:///path", &buf) == null);
}

test "originFromReferer: buffer too small returns null" {
    var buf: [8]u8 = undefined;
    try std.testing.expect(originFromReferer("https://embed.example.com/e", &buf) == null);
}
