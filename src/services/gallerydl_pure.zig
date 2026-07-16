//! Pure logic for the gallery-dl download backend — no state, no io, no dvui.
//!
//! gallery-dl (https://github.com/mikf/gallery-dl) downloads image galleries
//! and media from hundreds of art/booru/gallery sites that yt-dlp doesn't
//! cover. It's invoked exactly like yt-dlp — a CLI child process — so the only
//! app-specific decisions are:
//!
//!   1. classification — is THIS url an image-gallery/art/booru host that
//!      gallery-dl should handle, vs a video host that yt-dlp/http handles?
//!   2. argv building — assemble a safe argv list (no shell, `--` before the
//!      url so a leading `-` can't be read as a flag; dest passed as its own
//!      arg so spaces are harmless).
//!   3. output parsing — gallery-dl prints one local file path per line to
//!      stdout; a leading "# " marks a file that already existed (skipped).
//!
//! gallerydl.zig routes production through these so the tested logic ships.

const std = @import("std");

// ══════════════════════════════════════════════════════════
// URL → backend classification
// ══════════════════════════════════════════════════════════

/// Hosts that are unambiguously image-gallery / art / booru / illustration
/// sites. Kept deliberately narrow: video-first hosts (youtube, vimeo, the
/// adult tube sites, etc.) are NOT here, so they fall through to the existing
/// yt-dlp / http path. A generic "booru" substring catches the long tail of
/// booru clones (safebooru, tbib, xbooru, hypnohub, ...).
const GALLERY_HOSTS = [_][]const u8{
    "pixiv.net",
    "danbooru.donmai.us",
    "gelbooru.com",
    "konachan.com",
    "konachan.net",
    "yande.re",
    "rule34.xxx",
    "e-hentai.org",
    "exhentai.org",
    "nhentai.net",
    "deviantart.com",
    "artstation.com",
    "imgur.com",
    "wallhaven.cc",
    "kemono.party",
    "kemono.su",
    "coomer.party",
    "coomer.su",
    "fanbox.cc",
    "pawoo.net",
    "seiga.nicovideo.jp",
    "hentai-foundry.com",
    "gofile.io",
    "sankakucomplex.com",
    "chan.sankakucomplex.com",
};

/// Lower-case ASCII in place into `buf`, returning the written slice (host
/// comparison must be case-insensitive; URLs are ASCII here).
fn lowerInto(s: []const u8, buf: []u8) []const u8 {
    const n = @min(s.len, buf.len);
    for (s[0..n], 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return buf[0..n];
}

/// Extract the host span (between scheme and the first '/', '?', '#' or ':')
/// from a url. Returns the whole string when there's no scheme so bare hosts
/// still classify.
pub fn hostOf(url: []const u8) []const u8 {
    var rest = url;
    if (std.mem.indexOf(u8, rest, "://")) |i| rest = rest[i + 3 ..];
    // strip credentials (user:pw@) if they appear before the first '/'
    if (std.mem.indexOfScalar(u8, rest, '@')) |a| {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        if (a < slash) rest = rest[a + 1 ..];
    }
    var end: usize = rest.len;
    for (rest, 0..) |ch, i| {
        if (ch == '/' or ch == '?' or ch == '#' or ch == ':') {
            end = i;
            break;
        }
    }
    return rest[0..end];
}

/// True when gallery-dl should handle this URL rather than yt-dlp / the HTTP
/// downloader. Matches a known gallery host (suffix match on a dot boundary,
/// so subdomains like `www.` or `i.` count) or the generic `booru` marker.
pub fn shouldUseGalleryDl(url: []const u8) bool {
    if (url.len == 0) return false;
    if (!std.mem.startsWith(u8, url, "http://") and
        !std.mem.startsWith(u8, url, "https://")) return false;

    var lbuf: [512]u8 = undefined;
    const host = lowerInto(hostOf(url), &lbuf);
    if (host.len == 0) return false;

    // Generic booru clones (safebooru, tbib, xbooru, hypnohub, lolibooru, ...).
    if (std.mem.indexOf(u8, host, "booru") != null) return true;

    for (GALLERY_HOSTS) |h| {
        if (std.mem.eql(u8, host, h)) return true;
        // suffix match on a dot boundary: "www.pixiv.net" endsWith "pixiv.net"
        if (host.len > h.len and
            std.mem.endsWith(u8, host, h) and
            host[host.len - h.len - 1] == '.') return true;
    }
    return false;
}

// ══════════════════════════════════════════════════════════
// argv builder
// ══════════════════════════════════════════════════════════

/// Number of slots buildArgv fills. Callers pass a `[ARGV_LEN][]const u8`.
pub const ARGV_LEN = 6;

/// Build the gallery-dl argv into `buf`, returning the used slice. All values
/// are passed as discrete argv entries (never concatenated into a shell
/// string), so spaces / `;` / `$(...)` in `dest_dir` or `url` are inert. `--`
/// terminates option parsing so a url beginning with `-` is treated as a url.
///
///   gallery-dl -D <dest_dir> --no-mtime -- <url>
///
/// `-D` puts every file directly in dest_dir (flat, no per-site subtree), which
/// matches Opal's single downloads folder. `--no-mtime` avoids stamping files
/// with a remote mtime the transfers list would sort oddly.
pub fn buildArgv(
    bin: []const u8,
    dest_dir: []const u8,
    url: []const u8,
    buf: *[ARGV_LEN][]const u8,
) []const []const u8 {
    buf[0] = bin;
    buf[1] = "-D";
    buf[2] = dest_dir;
    buf[3] = "--no-mtime";
    buf[4] = "--";
    buf[5] = url;
    return buf[0..ARGV_LEN];
}

// ══════════════════════════════════════════════════════════
// output-line parsing
// ══════════════════════════════════════════════════════════

pub const LineKind = enum { downloaded, skipped, ignore };

pub const ParsedLine = struct {
    kind: LineKind,
    path: []const u8,
};

/// Classify one line of gallery-dl stdout.
///   "/downloads/foo.jpg"      → downloaded, path="/downloads/foo.jpg"
///   "# /downloads/foo.jpg"    → skipped (already on disk), path=the path
///   ""                        → ignore
/// Anything that doesn't look like a path (progress/log noise) → ignore.
pub fn parseOutputLine(raw_line: []const u8) ParsedLine {
    const line = std.mem.trim(u8, raw_line, " \t\r\n");
    if (line.len == 0) return .{ .kind = .ignore, .path = "" };

    // "# <path>" — file already existed, gallery-dl skipped the download.
    if (std.mem.startsWith(u8, line, "# ")) {
        const p = std.mem.trim(u8, line[2..], " \t\r\n");
        if (p.len == 0) return .{ .kind = .ignore, .path = "" };
        return .{ .kind = .skipped, .path = p };
    }

    // gallery-dl log/diagnostic lines look like "[extractor.pixiv][error] ..."
    // — bracketed tags, never a real path we want to record.
    if (line[0] == '[') return .{ .kind = .ignore, .path = "" };

    return .{ .kind = .downloaded, .path = line };
}

/// The basename of a path (for the toast / history label).
pub fn baseName(path: []const u8) []const u8 {
    if (path.len == 0) return path;
    const trimmed = std.mem.trimEnd(u8, path, "/");
    if (trimmed.len == 0) return path;
    if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |i| return trimmed[i + 1 ..];
    return trimmed;
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "shouldUseGalleryDl — gallery/art/booru hosts classify true" {
    const gallery = [_][]const u8{
        "https://www.pixiv.net/en/artworks/12345",
        "https://danbooru.donmai.us/posts/999",
        "https://gelbooru.com/index.php?page=post&s=view&id=1",
        "https://safebooru.org/index.php?page=post",
        "https://xbooru.com/index.php?page=post", // generic booru substring
        "https://yande.re/post/show/1",
        "https://www.deviantart.com/someone/art/Title-123",
        "https://www.artstation.com/artwork/abc",
        "https://imgur.com/gallery/abcd",
        "https://wallhaven.cc/w/abcdef",
        "https://kemono.party/patreon/user/1/post/2",
        "https://nhentai.net/g/123456/",
        "http://rule34.xxx/index.php?page=post",
    };
    for (gallery) |u| {
        try std.testing.expect(shouldUseGalleryDl(u));
    }
}

test "shouldUseGalleryDl — video / generic hosts classify false" {
    const video = [_][]const u8{
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://youtu.be/dQw4w9WgXcQ",
        "https://vimeo.com/12345",
        "https://www.twitch.tv/somestreamer",
        "https://www.pornhub.com/view_video.php?viewkey=x",
        "https://example.com/file.zip",
        "magnet:?xt=urn:btih:abcdef", // not http(s)
        "ftp://host/file",
        "",
    };
    for (video) |u| {
        try std.testing.expect(!shouldUseGalleryDl(u));
    }
}

test "hostOf strips scheme, path, port, credentials" {
    try std.testing.expectEqualStrings("pixiv.net", hostOf("https://pixiv.net/artworks/1"));
    try std.testing.expectEqualStrings("pixiv.net", hostOf("https://pixiv.net:443/x"));
    try std.testing.expectEqualStrings("host.tld", hostOf("http://user:pw@host.tld/path"));
    try std.testing.expectEqualStrings("bare.host", hostOf("bare.host/x"));
    try std.testing.expectEqualStrings("h", hostOf("https://h"));
}

test "buildArgv — discrete args, no shell injection, dest with spaces" {
    var buf: [ARGV_LEN][]const u8 = undefined;
    const dest = "/Users/me/My Downloads"; // space in dest
    const url = "https://pixiv.net/en/artworks/1; rm -rf ~"; // injection attempt
    const argv = buildArgv("/opt/homebrew/bin/gallery-dl", dest, url, &buf);

    try std.testing.expectEqual(@as(usize, ARGV_LEN), argv.len);
    try std.testing.expectEqualStrings("/opt/homebrew/bin/gallery-dl", argv[0]);
    try std.testing.expectEqualStrings("-D", argv[1]);
    // Dest is ONE argv entry — the space is not a separator.
    try std.testing.expectEqualStrings("/Users/me/My Downloads", argv[2]);
    try std.testing.expectEqualStrings("--no-mtime", argv[3]);
    // `--` guards a url that might start with '-'.
    try std.testing.expectEqualStrings("--", argv[4]);
    // The whole url (semicolon and all) is ONE argv entry — never a shell word.
    try std.testing.expectEqualStrings(url, argv[5]);
}

test "buildArgv — url starting with dash stays a url after --" {
    var buf: [ARGV_LEN][]const u8 = undefined;
    const url = "-oops://weird"; // pathological
    const argv = buildArgv("gallery-dl", "/dl", url, &buf);
    try std.testing.expectEqualStrings("--", argv[4]);
    try std.testing.expectEqualStrings(url, argv[5]);
}

test "parseOutputLine — downloaded / skipped / ignore" {
    {
        const p = parseOutputLine("/Users/me/dl/pixiv_12345_p0.jpg");
        try std.testing.expectEqual(LineKind.downloaded, p.kind);
        try std.testing.expectEqualStrings("/Users/me/dl/pixiv_12345_p0.jpg", p.path);
    }
    {
        const p = parseOutputLine("  /dl/with trailing.png  \r\n");
        try std.testing.expectEqual(LineKind.downloaded, p.kind);
        try std.testing.expectEqualStrings("/dl/with trailing.png", p.path);
    }
    {
        const p = parseOutputLine("# /dl/already_here.jpg");
        try std.testing.expectEqual(LineKind.skipped, p.kind);
        try std.testing.expectEqualStrings("/dl/already_here.jpg", p.path);
    }
    {
        const p = parseOutputLine("[extractor.pixiv][error] boom");
        try std.testing.expectEqual(LineKind.ignore, p.kind);
    }
    {
        const p = parseOutputLine("");
        try std.testing.expectEqual(LineKind.ignore, p.kind);
    }
    {
        const p = parseOutputLine("   ");
        try std.testing.expectEqual(LineKind.ignore, p.kind);
    }
}

test "baseName" {
    try std.testing.expectEqualStrings("foo.jpg", baseName("/a/b/foo.jpg"));
    try std.testing.expectEqualStrings("foo.jpg", baseName("foo.jpg"));
    try std.testing.expectEqualStrings("dir", baseName("/a/dir/"));
}
