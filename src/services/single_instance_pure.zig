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
pub const ArgKind = enum { local, url, magnet, torrent_file };

pub fn classifyArg(arg: []const u8) ArgKind {
    if (std.ascii.startsWithIgnoreCase(arg, "magnet:")) return .magnet;
    if (std.ascii.startsWithIgnoreCase(arg, "http://") or
        std.ascii.startsWithIgnoreCase(arg, "https://")) return .url;
    if (std.ascii.endsWithIgnoreCase(arg, ".torrent")) return .torrent_file;
    return .local;
}

fn hexVal(ch: u8) ?u8 {
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'a' and ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' and ch <= 'F') return ch - 'A' + 10;
    return null;
}

/// Normalize one process-open argument. Literal paths and web URLs preserve
/// `%XX` byte-for-byte: decoding those changes valid filenames and signed URL
/// semantics. Only an actual file URI is percent-decoded.
pub fn normalizeOpenArg(raw: []const u8, out: []u8) usize {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or
        (s[0] == '\'' and s[s.len - 1] == '\'')))
    {
        s = std.mem.trim(u8, s[1 .. s.len - 1], " \t\r\n");
    }
    const file_uri = std.ascii.startsWithIgnoreCase(s, "file://");
    if (file_uri) {
        s = s["file://".len..];
        if (std.ascii.startsWithIgnoreCase(s, "localhost/")) s = s["localhost".len..];
        // file:///C:/path is the canonical Windows drive URI form.
        if (s.len >= 4 and s[0] == '/' and std.ascii.isAlphabetic(s[1]) and s[2] == ':' and s[3] == '/') s = s[1..];
    }

    var o: usize = 0;
    var i: usize = 0;
    while (i < s.len and o < out.len) {
        if (file_uri and s[i] == '%' and i + 2 < s.len) {
            if (hexVal(s[i + 1])) |hi| {
                if (hexVal(s[i + 2])) |lo| {
                    const decoded = hi * 16 + lo;
                    // Never inject a C-string terminator into downstream mpv.
                    if (decoded != 0) {
                        out[o] = decoded;
                        o += 1;
                        i += 3;
                        continue;
                    }
                }
            }
        }
        out[o] = s[i];
        o += 1;
        i += 1;
    }
    return o;
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

/// Build just the request path for the forward request:
///   /api/open?path=<percent-encoded arg>
/// The second-instance forwarder speaks raw HTTP over a loopback socket (no
/// HTTP client needed), so it needs the path without the scheme/authority.
/// Returns null if `buf` is too small or `arg` is empty.
pub fn buildOpenPath(arg: []const u8, buf: []u8) ?[]const u8 {
    if (arg.len == 0) return null;
    var enc_buf: [3 * 2048]u8 = undefined;
    const enc = encodeQueryValue(arg, &enc_buf) orelse return null;
    return std.fmt.bufPrint(buf, "/api/open?path={s}", .{enc}) catch null;
}

/// Build the full forward-request URL:
///   http://127.0.0.1:<port>/api/open?path=<percent-encoded arg>
/// Returns null if `buf` is too small or `arg` is empty.
pub fn buildOpenUrl(port: u16, arg: []const u8, buf: []u8) ?[]const u8 {
    if (arg.len == 0) return null;
    var path_buf: [3 * 2048 + 16]u8 = undefined;
    const req_path = buildOpenPath(arg, &path_buf) orelse return null;
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ port, req_path }) catch null;
}

// ── Tests ──

test "classifyArg: magnet / url / local" {
    try std.testing.expectEqual(ArgKind.magnet, classifyArg("magnet:?xt=urn:btih:abc"));
    try std.testing.expectEqual(ArgKind.url, classifyArg("https://example.com/a.mp4"));
    try std.testing.expectEqual(ArgKind.url, classifyArg("HTTP://EXAMPLE.COM"));
    try std.testing.expectEqual(ArgKind.torrent_file, classifyArg("C:\\Media\\show.TORRENT"));
    try std.testing.expectEqual(ArgKind.local, classifyArg("/home/u/My Movie.mkv"));
    try std.testing.expectEqual(ArgKind.local, classifyArg("relative/file.mp3"));
}

test "open argument normalization preserves literal percent escapes" {
    var buf: [256]u8 = undefined;
    var n = normalizeOpenArg("https://cdn.test/a%2Fb.mp4?sig=x%2By", &buf);
    try std.testing.expectEqualStrings("https://cdn.test/a%2Fb.mp4?sig=x%2By", buf[0..n]);
    n = normalizeOpenArg("C:\\Media\\literal%20name.mkv", &buf);
    try std.testing.expectEqualStrings("C:\\Media\\literal%20name.mkv", buf[0..n]);
}

test "file URI normalization decodes and fixes a Windows drive prefix" {
    var buf: [256]u8 = undefined;
    const n = normalizeOpenArg("  \"file:///C:/Media/My%20Film.mkv\"  ", &buf);
    try std.testing.expectEqualStrings("C:/Media/My Film.mkv", buf[0..n]);
}

test "file URI normalization never decodes a nul byte" {
    var buf: [64]u8 = undefined;
    const n = normalizeOpenArg("file:///tmp/a%00b.mkv", &buf);
    try std.testing.expectEqualStrings("/tmp/a%00b.mkv", buf[0..n]);
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

test "buildOpenPath: path-only form matches the URL form's tail" {
    var path_buf: [512]u8 = undefined;
    const req_path = buildOpenPath("/a/b c.mkv", &path_buf).?;
    try std.testing.expectEqualStrings("/api/open?path=/a/b%20c.mkv", req_path);
    var url_buf: [512]u8 = undefined;
    const url = buildOpenUrl(41596, "/a/b c.mkv", &url_buf).?;
    try std.testing.expectEqualStrings("http://127.0.0.1:41596/api/open?path=/a/b%20c.mkv", url);
    // Empty arg rejected, like buildOpenUrl.
    var buf: [512]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), buildOpenPath("", &buf));
}
