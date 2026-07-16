const std = @import("std");

// ══════════════════════════════════════════════════════════
// Single-instance open forwarding — pure helpers
//
// A second `opal <file|url>` launch hands its argument to the already-running
// instance via POST /api/open?path=… on the local JSON API (remote.zig) and
// exits. This module owns the request-URL construction so the encoding rules
// are testable: the argument may be a filesystem path, an http(s) URL, or a
// magnet URI — magnets in particular carry `&` and `=` which MUST be
// percent-encoded or the server's query parser splits the URI apart.
// ══════════════════════════════════════════════════════════

/// What kind of thing was passed on the command line. Currently informational
/// (every kind forwards the same way), but keeps the classification logic in
/// one tested place.
pub const ArgKind = enum { local, url, magnet };

pub fn classifyArg(arg: []const u8) ArgKind {
    if (std.ascii.startsWithIgnoreCase(arg, "magnet:")) return .magnet;
    if (std.ascii.startsWithIgnoreCase(arg, "http://") or
        std.ascii.startsWithIgnoreCase(arg, "https://")) return .url;
    return .local;
}

fn isUnreserved(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~' or ch == '/';
}

/// Percent-encode `arg` for use as a query-parameter value. Everything outside
/// [A-Za-z0-9-_.~/] is encoded — a superset of the project minimum
/// (space & = # ? % +). '/' stays literal so local paths remain readable in
/// logs; it is safe inside a query value. Returns null if `buf` is too small.
pub fn encodeQueryValue(arg: []const u8, buf: []u8) ?[]const u8 {
    const hex = "0123456789ABCDEF";
    var o: usize = 0;
    for (arg) |ch| {
        if (isUnreserved(ch)) {
            if (o >= buf.len) return null;
            buf[o] = ch;
            o += 1;
        } else {
            if (o + 3 > buf.len) return null;
            buf[o] = '%';
            buf[o + 1] = hex[ch >> 4];
            buf[o + 2] = hex[ch & 0x0f];
            o += 3;
        }
    }
    return buf[0..o];
}

/// Build the full forward-request URL:
///   http://127.0.0.1:<port>/api/open?path=<percent-encoded arg>
/// Returns null if `buf` is too small or `arg` is empty.
pub fn buildOpenUrl(port: u16, arg: []const u8, buf: []u8) ?[]const u8 {
    if (arg.len == 0) return null;
    var enc_buf: [3 * 2048]u8 = undefined;
    const enc = encodeQueryValue(arg, &enc_buf) orelse return null;
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/api/open?path={s}", .{ port, enc }) catch null;
}

// ── Tests ──

test "classifyArg: magnet / url / local" {
    try std.testing.expectEqual(ArgKind.magnet, classifyArg("magnet:?xt=urn:btih:abc"));
    try std.testing.expectEqual(ArgKind.url, classifyArg("https://example.com/a.mp4"));
    try std.testing.expectEqual(ArgKind.url, classifyArg("HTTP://EXAMPLE.COM"));
    try std.testing.expectEqual(ArgKind.local, classifyArg("/home/u/My Movie.mkv"));
    try std.testing.expectEqual(ArgKind.local, classifyArg("relative/file.mp3"));
}

test "encodeQueryValue: required minimum set (space & = # ? % +)" {
    var buf: [128]u8 = undefined;
    const enc = encodeQueryValue("a b&c=d#e?f%g+h", &buf).?;
    try std.testing.expectEqualStrings("a%20b%26c%3Dd%23e%3Ff%25g%2Bh", enc);
}

test "encodeQueryValue: plain path passes through" {
    var buf: [128]u8 = undefined;
    const enc = encodeQueryValue("/Users/u/Movies/show.mkv", &buf).?;
    try std.testing.expectEqualStrings("/Users/u/Movies/show.mkv", enc);
}

test "encodeQueryValue: buffer too small returns null" {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), encodeQueryValue("a b c", &buf));
}

test "buildOpenUrl: magnet ampersands do not split the query" {
    var buf: [512]u8 = undefined;
    const url = buildOpenUrl(41595, "magnet:?xt=urn:btih:abc&dn=Some Name", &buf).?;
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:41595/api/open?path=magnet%3A%3Fxt%3Durn%3Abtih%3Aabc%26dn%3DSome%20Name",
        url,
    );
    // No raw '&' anywhere after the single '?' — the server splits on those.
    const q = std.mem.indexOfScalar(u8, url, '?').?;
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfScalarPos(u8, url, q + 1, '&'));
}

test "buildOpenUrl: empty arg / tiny buffer rejected" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), buildOpenUrl(41595, "", &buf));
    var tiny: [8]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), buildOpenUrl(41595, "/a/b.mkv", &tiny));
}
