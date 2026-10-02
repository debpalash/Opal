//! Conditional-GET parsing for the web companion's static assets.
//!
//! `Cache-Control: no-cache` tells a browser to revalidate on every load, but
//! without a validator there is nothing to compare against — so it re-downloads
//! the whole body anyway. Serving a strong `ETag` and answering `If-None-Match`
//! with an empty `304` is what actually makes a reload cheap. The matching and
//! header parsing live here so they are testable without a socket or the
//! filesystem; `remote_static.zig` owns the asset table and the I/O.

const std = @import("std");

/// Case-insensitive `name: value` lookup over a raw request head.
/// Returns null when the header is absent. Stops at the blank line that ends
/// the head, so a body containing the same text cannot be mistaken for a header.
pub fn headerValue(raw: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, raw, "\r\n");
    _ = lines.next(); // request line
    while (lines.next()) |line| {
        if (line.len == 0) return null; // end of head
        if (line.len <= name.len) continue;
        if (!std.ascii.eqlIgnoreCase(line[0..name.len], name)) continue;
        if (line[name.len] != ':') continue;
        return std.mem.trim(u8, line[name.len + 1 ..], " \t");
    }
    return null;
}

/// True when the client already holds this exact body. Accepts the `*` wildcard
/// and a comma-separated list, as RFC 9110 requires, with optional whitespace.
pub fn clientHasEtag(raw: []const u8, etag: []const u8) bool {
    const header = headerValue(raw, "If-None-Match") orelse return false;
    if (std.mem.indexOf(u8, header, "*") != null) return true;
    var candidates = std.mem.splitScalar(u8, header, ',');
    while (candidates.next()) |candidate| {
        if (std.mem.eql(u8, std.mem.trim(u8, candidate, " \t"), etag)) return true;
    }
    return false;
}

test "a header is matched case-insensitively" {
    const raw = "GET /js/core.js HTTP/1.1\r\nHost: x\r\nif-none-match: \"0123456789abcdef\"\r\n\r\n";
    try std.testing.expectEqualStrings("\"0123456789abcdef\"", headerValue(raw, "If-None-Match").?);
    try std.testing.expect(clientHasEtag(raw, "\"0123456789abcdef\""));
    try std.testing.expect(!clientHasEtag(raw, "\"fedcba9876543210\""));
}

test "If-None-Match accepts a list and the wildcard" {
    try std.testing.expect(clientHasEtag("GET / HTTP/1.1\r\nIf-None-Match: *\r\n\r\n", "\"x\""));
    const list = "GET / HTTP/1.1\r\nIf-None-Match: \"a\", \"b\" ,\"c\"\r\n\r\n";
    try std.testing.expect(clientHasEtag(list, "\"b\""));
    try std.testing.expect(clientHasEtag(list, "\"c\""));
    try std.testing.expect(!clientHasEtag(list, "\"d\""));
}

test "a request without the header never claims to match" {
    try std.testing.expect(!clientHasEtag("GET /js/core.js HTTP/1.1\r\nHost: x\r\n\r\n", "\"x\""));
}

test "a header name prefix is not a header" {
    // `If-None-Matchx` must not satisfy a lookup for `If-None-Match`.
    const raw = "GET / HTTP/1.1\r\nIf-None-Matchx: \"a\"\r\n\r\n";
    try std.testing.expect(headerValue(raw, "If-None-Match") == null);
    try std.testing.expect(!clientHasEtag(raw, "\"a\""));
}

test "a header-like string in the body is not a header" {
    const raw = "GET / HTTP/1.1\r\nHost: x\r\n\r\nIf-None-Match: \"a\"\r\n";
    try std.testing.expect(headerValue(raw, "If-None-Match") == null);
    try std.testing.expect(!clientHasEtag(raw, "\"a\""));
}
