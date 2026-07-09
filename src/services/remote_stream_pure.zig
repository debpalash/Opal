//! Pure logic for browser media streaming (headless/hosted playback):
//! HTTP Range parsing, content-type mapping, SRT→VTT conversion.
//! No io/state — unit-tested standalone; remote_stream.zig does the serving.

const std = @import("std");

pub const Range = struct { start: u64, end: u64 }; // inclusive, per RFC 9110

/// Parse a `Range: bytes=a-b` header value against a file of `size` bytes.
/// Returns null for absent/malformed/unsatisfiable ranges (caller sends the
/// whole file with 200, or 416 when explicitly unsatisfiable — we choose the
/// forgiving 200 path for absent, null-with-size-known for garbage).
/// Supports the three RFC forms: `a-b`, `a-` (to EOF), `-n` (last n bytes).
pub fn parseRange(value: []const u8, size: u64) ?Range {
    if (size == 0) return null;
    const v = std.mem.trim(u8, value, " \t");
    if (!std.mem.startsWith(u8, v, "bytes=")) return null;
    const spec = v["bytes=".len..];
    // Only the first range of a multi-range request (browsers send one).
    const first = spec[0 .. std.mem.indexOfScalar(u8, spec, ',') orelse spec.len];
    const dash = std.mem.indexOfScalar(u8, first, '-') orelse return null;
    const a_str = std.mem.trim(u8, first[0..dash], " ");
    const b_str = std.mem.trim(u8, first[dash + 1 ..], " ");

    if (a_str.len == 0) {
        // suffix form: last N bytes
        const n = std.fmt.parseInt(u64, b_str, 10) catch return null;
        if (n == 0) return null;
        const cnt = @min(n, size);
        return .{ .start = size - cnt, .end = size - 1 };
    }
    const a = std.fmt.parseInt(u64, a_str, 10) catch return null;
    if (a >= size) return null; // unsatisfiable
    const b = if (b_str.len == 0)
        size - 1
    else
        @min(std.fmt.parseInt(u64, b_str, 10) catch return null, size - 1);
    if (b < a) return null;
    return .{ .start = a, .end = b };
}

/// Content-Type by file extension (video/audio/subs the streamer serves).
pub fn contentType(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "application/octet-stream";
    const ext = name[dot + 1 ..];
    var lower_buf: [8]u8 = undefined;
    if (ext.len > lower_buf.len) return "application/octet-stream";
    for (ext, 0..) |ch, i| lower_buf[i] = std.ascii.toLower(ch);
    const e = lower_buf[0..ext.len];
    const map = [_]struct { e: []const u8, t: []const u8 }{
        .{ .e = "mp4", .t = "video/mp4" },   .{ .e = "m4v", .t = "video/mp4" },
        .{ .e = "webm", .t = "video/webm" }, .{ .e = "mkv", .t = "video/x-matroska" },
        .{ .e = "avi", .t = "video/x-msvideo" }, .{ .e = "mov", .t = "video/quicktime" },
        .{ .e = "mp3", .t = "audio/mpeg" },  .{ .e = "m4a", .t = "audio/mp4" },
        .{ .e = "flac", .t = "audio/flac" }, .{ .e = "ogg", .t = "audio/ogg" },
        .{ .e = "wav", .t = "audio/wav" },   .{ .e = "vtt", .t = "text/vtt" },
        .{ .e = "srt", .t = "text/vtt" }, // always served converted
        .{ .e = "jpg", .t = "image/jpeg" },  .{ .e = "jpeg", .t = "image/jpeg" },
        .{ .e = "png", .t = "image/png" },
    };
    for (map) |m| if (std.mem.eql(u8, m.e, e)) return m.t;
    return "application/octet-stream";
}

/// True when `rel` is a safe path under the downloads root: no traversal,
/// no absolute paths, non-empty.
pub fn safeRelPath(rel: []const u8) bool {
    if (rel.len == 0 or rel.len > 1024) return false;
    if (rel[0] == '/' or rel[0] == '\\') return false;
    if (std.mem.indexOf(u8, rel, "..") != null) return false;
    if (std.mem.indexOfScalar(u8, rel, 0) != null) return false;
    return true;
}

/// Convert SRT bytes to WebVTT into `out`. Returns bytes written.
/// SRT: index line, `HH:MM:SS,mmm --> HH:MM:SS,mmm`, text, blank.
/// VTT: "WEBVTT\n\n" header, same cues with `.` instead of `,`, index
/// lines dropped (they're legal cue identifiers but add nothing).
pub fn srtToVtt(srt: []const u8, out: []u8) usize {
    const header = "WEBVTT\n\n";
    if (out.len < header.len) return 0;
    @memcpy(out[0..header.len], header);
    var w: usize = header.len;

    var lines = std.mem.splitScalar(u8, srt, '\n');
    var prev_blank = true; // start-of-file behaves like after a blank
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        // Drop pure-number index lines that directly follow a blank line.
        if (prev_blank and line.len > 0 and isAllDigits(line)) continue;
        prev_blank = line.len == 0;

        // Timestamp lines: swap the millisecond comma for a dot.
        const is_ts = std.mem.indexOf(u8, line, "-->") != null;
        for (line) |ch| {
            if (w >= out.len) return w;
            out[w] = if (is_ts and ch == ',') '.' else ch;
            w += 1;
        }
        if (w >= out.len) return w;
        out[w] = '\n';
        w += 1;
    }
    return w;
}

fn isAllDigits(s: []const u8) bool {
    for (s) |ch| if (ch < '0' or ch > '9') return false;
    return true;
}

// ── Tests ──

test "parseRange: the three RFC forms + clamping + garbage" {
    // open-ended (what <video> sends first: bytes=0-)
    try std.testing.expectEqual(Range{ .start = 0, .end = 999 }, parseRange("bytes=0-", 1000).?);
    // bounded
    try std.testing.expectEqual(Range{ .start = 100, .end = 199 }, parseRange("bytes=100-199", 1000).?);
    // end clamps to size-1
    try std.testing.expectEqual(Range{ .start = 900, .end = 999 }, parseRange("bytes=900-5000", 1000).?);
    // suffix (last 100 bytes)
    try std.testing.expectEqual(Range{ .start = 900, .end = 999 }, parseRange("bytes=-100", 1000).?);
    // unsatisfiable / malformed
    try std.testing.expect(parseRange("bytes=1000-", 1000) == null);
    try std.testing.expect(parseRange("bytes=200-100", 1000) == null);
    try std.testing.expect(parseRange("items=0-", 1000) == null);
    try std.testing.expect(parseRange("bytes=x-y", 1000) == null);
    try std.testing.expect(parseRange("bytes=0-", 0) == null);
}

test "contentType maps media extensions, case-insensitive" {
    try std.testing.expectEqualStrings("video/mp4", contentType("Movie.MP4"));
    try std.testing.expectEqualStrings("video/x-matroska", contentType("show.s01e01.mkv"));
    try std.testing.expectEqualStrings("text/vtt", contentType("subs.srt"));
    try std.testing.expectEqualStrings("application/octet-stream", contentType("noext"));
}

test "safeRelPath blocks traversal and absolutes" {
    try std.testing.expect(safeRelPath("Show/S01E01.mkv"));
    try std.testing.expect(!safeRelPath("../../etc/passwd"));
    try std.testing.expect(!safeRelPath("/etc/passwd"));
    try std.testing.expect(!safeRelPath(""));
    try std.testing.expect(!safeRelPath("a/../b"));
}

test "srtToVtt: header, comma→dot, index lines dropped, text preserved" {
    const srt =
        "1\r\n00:00:01,000 --> 00:00:03,500\r\nHello there.\r\n\r\n" ++
        "2\r\n00:00:04,000 --> 00:00:06,000\r\nLine one\r\nLine 2 has 42 digits\r\n";
    var out: [512]u8 = undefined;
    const n = srtToVtt(srt, &out);
    const vtt = out[0..n];
    try std.testing.expect(std.mem.startsWith(u8, vtt, "WEBVTT\n\n"));
    try std.testing.expect(std.mem.indexOf(u8, vtt, "00:00:01.000 --> 00:00:03.500") != null);
    try std.testing.expect(std.mem.indexOf(u8, vtt, "Hello there.") != null);
    // Cue TEXT that is numeric-looking mid-block must survive; index lines don't.
    try std.testing.expect(std.mem.indexOf(u8, vtt, "Line 2 has 42 digits") != null);
    try std.testing.expect(std.mem.indexOf(u8, vtt, "\n1\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, vtt, "\n2\n") == null);
}
