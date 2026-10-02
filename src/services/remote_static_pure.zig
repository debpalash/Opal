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

const EntityTag = struct { value: []const u8, end: usize };

fn entityTag(value: []const u8, start: usize) ?EntityTag {
    var pos = start;
    if (std.mem.startsWith(u8, value[pos..], "W/")) pos += 2;
    if (pos >= value.len or value[pos] != '"') return null;
    const first = pos;
    pos += 1;
    while (pos < value.len and value[pos] != '"') : (pos += 1) {
        // RFC 9110 etagc excludes spaces, control bytes and DEL. A backslash
        // is opaque data, not a quoted-string escape; commas are data too.
        if (value[pos] < 0x21 or value[pos] == 0x7f) return null;
    }
    if (pos >= value.len) return null;
    return .{ .value = value[first .. pos + 1], .end = pos + 1 };
}

/// If-None-Match on GET uses weak comparison (RFC 9110 section 13.1.2).
/// The wildcard is a standalone alternative; quoted '*' is opaque tag data.
/// Scan quoted candidates rather than splitting commas inside opaque tags.
pub fn clientHasEtag(raw: []const u8, etag: []const u8) bool {
    const header = headerValue(raw, "If-None-Match") orelse return false;
    if (std.mem.eql(u8, header, "*")) return true;
    const expected = std.mem.trim(u8, etag, " \t");
    const current = entityTag(expected, 0) orelse return false;
    if (current.end != expected.len) return false;
    var pos: usize = 0;
    var matched = false;
    while (pos < header.len) {
        // RFC list recipients tolerate empty members; only whitespace and
        // commas are ignored, never an unquoted wildcard mixed into a list.
        while (pos < header.len and (header[pos] == ',' or header[pos] == ' ' or header[pos] == '\t')) : (pos += 1) {}
        if (pos == header.len) break;
        const candidate = entityTag(header, pos) orelse return false;
        if (std.mem.eql(u8, candidate.value, current.value)) matched = true;
        pos = candidate.end;
        while (pos < header.len and (header[pos] == ' ' or header[pos] == '\t')) : (pos += 1) {}
        if (pos < header.len and header[pos] != ',') return false;
    }
    return matched;
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

test "conditional GET uses weak comparison in both directions" {
    try std.testing.expect(clientHasEtag("GET / HTTP/1.1\r\nIf-None-Match: W/\"same\"\r\n\r\n", "\"same\""));
    try std.testing.expect(clientHasEtag("GET / HTTP/1.1\r\nIf-None-Match: \"same\"\r\n\r\n", "W/\"same\""));
    try std.testing.expect(!clientHasEtag("GET / HTTP/1.1\r\nIf-None-Match: W/\"different\"\r\n\r\n", "\"same\""));
}

test "opaque commas and asterisks stay inside entity tags" {
    try std.testing.expect(clientHasEtag("GET / HTTP/1.1\r\nIf-None-Match: \"first,tag\", W/\"second,tag\"\r\n\r\n", "\"second,tag\""));
    try std.testing.expect(clientHasEtag("GET / HTTP/1.1\r\nIf-None-Match: \"first,tag\", W/\"second,tag\"\r\n\r\n", "\"first,tag\""));
    try std.testing.expect(!clientHasEtag("GET / HTTP/1.1\r\nIf-None-Match: \"prefix*other\"\r\n\r\n", "\"current\""));
    try std.testing.expect(clientHasEtag("GET / HTTP/1.1\r\nIf-None-Match: \"prefix*other\"\r\n\r\n", "\"prefix*other\""));
    try std.testing.expect(clientHasEtag("GET / HTTP/1.1\r\nIf-None-Match: \t * \t\r\n\r\n", "\"current\""));
}

test "malformed validators cannot turn a different representation into a false 304" {
    const invalid = [_][]const u8{ "W/\"unfinished", "\"current\", *", "prefix*", "w/\"current\"", "\"has space\"", "\"current\"suffix", "\"current\", unquoted" };
    for (invalid) |value| {
        var request: [256]u8 = undefined;
        const raw = try std.fmt.bufPrint(&request, "GET / HTTP/1.1\r\nIf-None-Match: {s}\r\n\r\n", .{value});
        try std.testing.expect(!clientHasEtag(raw, "\"current\""));
    }
    try std.testing.expect(clientHasEtag("GET / HTTP/1.1\r\nIf-None-Match: , \"current\", ,\r\n\r\n", "\"current\""));
}
