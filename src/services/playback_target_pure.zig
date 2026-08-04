//! Can a browser actually play this? Pure decision logic for the web UI's
//! "Play here" destination.
//!
//! Opal has no transcoder. Handing a browser an MKV/H.265/AC3 release and
//! hoping produces a black screen with no error — worse than refusing, because
//! the user cannot tell a codec problem from a broken server. So every
//! "Play here" goes through `classify` first, and an unsupported item says why
//! and offers the desktop instead.
//!
//! Judged from the file name / URL alone: that is all the web UI has before it
//! commits to a `<video src>`, and it is enough for the containers and codecs
//! that actually show up. Deliberately conservative — a false "unsupported"
//! costs one click on the desktop button, a false "direct" costs a black
//! screen.

const std = @import("std");

pub const Playability = enum {
    /// Browsers play this natively today.
    direct,
    /// HLS. Safari plays it natively; Chrome/Firefox need an MSE shim we do
    /// not bundle, so they get the honest message instead.
    hls,
    /// Container or codec no browser decodes without transcoding.
    unsupported,
};

/// Extensions every current browser plays.
const DIRECT_EXT = [_][]const u8{
    "mp4", "m4v", "webm", "ogv",
    "mp3", "m4a", "aac", "oga", "ogg", "opus", "wav", "flac",
};

/// Containers browsers do not demux. MKV is the big one: it is what most
/// scraped releases ship in, and Chrome shows a black screen rather than an
/// error.
const UNSUPPORTED_EXT = [_][]const u8{
    "mkv", "avi", "wmv", "flv", "vob", "rmvb", "asf", "mpg", "mpeg",
    "m2ts", "mts", "ts", "divx", "3gp", "iso",
};

/// Codec markers that appear in release names. An .mp4 carrying H.265 still
/// will not play in Chrome or Firefox, so the extension alone is not enough.
const BAD_CODEC_MARKERS = [_][]const u8{
    "x265", "h265", "hevc", "x266", "av1", "vc1", "mpeg2",
    "dts", "truehd", "eac3", "ac3", "flac2", "atmos",
};

fn extOf(name: []const u8) []const u8 {
    // Ignore a query string / fragment first: "…/a.mp4?token=x" is still mp4.
    var end = name.len;
    if (std.mem.indexOfScalar(u8, name, '?')) |q| end = @min(end, q);
    if (std.mem.indexOfScalar(u8, name, '#')) |h| end = @min(end, h);
    const clean = name[0..end];
    const dot = std.mem.lastIndexOfScalar(u8, clean, '.') orelse return "";
    return clean[dot + 1 ..];
}

fn eqlLower(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

fn containsLower(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (eqlLower(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Classify a file name or URL.
pub fn classify(name: []const u8) Playability {
    if (name.len == 0) return .unsupported;
    const ext = extOf(name);

    if (eqlLower(ext, "m3u8")) return .hls;
    for (UNSUPPORTED_EXT) |e| {
        if (eqlLower(ext, e)) return .unsupported;
    }
    for (DIRECT_EXT) |e| {
        if (eqlLower(ext, e)) {
            // Container is fine, but the codec still might not be.
            for (BAD_CODEC_MARKERS) |m| {
                if (containsLower(name, m)) return .unsupported;
            }
            return .direct;
        }
    }
    // No usable extension. A bare http(s) URL is usually a progressive stream
    // or a redirect (radio, podcast enclosures) — let the element try; its
    // error handler reports the failure. Anything else is refused.
    if (std.mem.startsWith(u8, name, "http://") or std.mem.startsWith(u8, name, "https://")) return .direct;
    return .unsupported;
}

/// Why "Play here" is refused, phrased for the person reading it.
pub fn reason(p: Playability) []const u8 {
    return switch (p) {
        .direct => "",
        .hls => "Live streams play in Safari; other browsers need the desktop app.",
        .unsupported => "This format can't play in a browser — open it on the desktop.",
    };
}

// ── Tests ──

test "classify: containers browsers play" {
    for ([_][]const u8{ "Show.S01E01.mp4", "clip.m4v", "a.webm", "song.mp3", "x.flac", "y.OPUS" }) |n|
        try std.testing.expectEqual(Playability.direct, classify(n));
}

test "classify: containers browsers do not play" {
    // MKV is the one that matters — Chrome renders a black screen, not an error.
    for ([_][]const u8{ "Show.S01E01.mkv", "old.avi", "a.wmv", "b.ts", "c.vob" }) |n|
        try std.testing.expectEqual(Playability.unsupported, classify(n));
}

test "classify: HLS is its own case, not direct" {
    try std.testing.expectEqual(Playability.hls, classify("http://host/live/stream.m3u8"));
    try std.testing.expectEqual(Playability.hls, classify("CHANNEL.M3U8"));
}

test "classify: an mp4 carrying H.265 is still unplayable" {
    // The extension says yes, the codec says no. Extension-only classification
    // would hand Chrome a black screen.
    try std.testing.expectEqual(Playability.unsupported, classify("Movie.2024.2160p.x265.mp4"));
    try std.testing.expectEqual(Playability.unsupported, classify("Movie.HEVC.m4v"));
    try std.testing.expectEqual(Playability.unsupported, classify("Show.DDP5.1.Atmos.mp4"));
}

test "classify: a plain H.264 release is direct" {
    try std.testing.expectEqual(Playability.direct, classify("Movie.2024.1080p.x264.AAC.mp4"));
}

test "classify: query strings and fragments do not hide the extension" {
    try std.testing.expectEqual(Playability.direct, classify("https://h/a.mp4?token=abc&x=1"));
    try std.testing.expectEqual(Playability.unsupported, classify("https://h/a.mkv?token=abc"));
    try std.testing.expectEqual(Playability.hls, classify("https://h/live.m3u8#t=0"));
}

test "classify: extensionless http URLs get the benefit of the doubt" {
    // Radio and podcast enclosures are usually redirects with no extension;
    // the media element's error handler reports a real failure.
    try std.testing.expectEqual(Playability.direct, classify("https://stream.example/listen"));
    try std.testing.expectEqual(Playability.unsupported, classify("some-random-token"));
    try std.testing.expectEqual(Playability.unsupported, classify(""));
}

test "classify: case does not matter" {
    try std.testing.expectEqual(Playability.direct, classify("A.MP4"));
    try std.testing.expectEqual(Playability.unsupported, classify("A.MKV"));
    try std.testing.expectEqual(Playability.unsupported, classify("movie.X265.mp4"));
}

test "reason: every refusal explains itself, direct stays silent" {
    try std.testing.expectEqualStrings("", reason(.direct));
    try std.testing.expect(reason(.hls).len > 0);
    try std.testing.expect(reason(.unsupported).len > 0);
}

test "classify: callers must pass the media NAME, not a /stream URL" {
    // Regression: the web UI classified "…/stream?file=X.mkv&t=…". The query
    // string is stripped first, leaving "/stream" with no extension, which then
    // matched the permissive bare-http rule — and <video> got an MKV.
    // A wrapper URL cannot be classified; only the name it carries can.
    try std.testing.expectEqual(Playability.direct, classify("http://h:41595/stream?file=A.mkv&t=tok"));
    try std.testing.expectEqual(Playability.unsupported, classify("A.mkv"));
}
