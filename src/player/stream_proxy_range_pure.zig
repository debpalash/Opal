//! Parse the single HTTP byte range used by the torrent streaming proxy.
//! In particular, `bytes=-N` means the LAST N bytes, not bytes 0 through N.

const std = @import("std");

pub const Range = struct {
    start: i64,
    end: i64,
};

pub const Result = union(enum) {
    full,
    partial: Range,
    invalid,
};

pub fn parse(request: []const u8, file_size: i64) Result {
    if (file_size <= 0) return .invalid;
    const first_line_end = std.mem.indexOf(u8, request, "\r\n") orelse return .full;
    var lines = std.mem.splitSequence(u8, request[first_line_end + 2 ..], "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], "range")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (value.len < 6 or !std.ascii.eqlIgnoreCase(value[0..6], "bytes=")) return .invalid;
        const spec = value[6..];
        // Multiple ranges need a multipart response, which this proxy does not
        // implement. Reject them rather than returning bytes for the wrong span.
        if (std.mem.indexOfScalar(u8, spec, ',') != null) return .invalid;
        const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return .invalid;
        const start_text = spec[0..dash];
        const end_text = spec[dash + 1 ..];
        if (start_text.len == 0) {
            const suffix = std.fmt.parseInt(i64, end_text, 10) catch return .invalid;
            if (suffix <= 0) return .invalid;
            return .{ .partial = .{ .start = file_size - @min(suffix, file_size), .end = file_size - 1 } };
        }
        const start = std.fmt.parseInt(i64, start_text, 10) catch return .invalid;
        if (start < 0 or start >= file_size) return .invalid;
        const end = if (end_text.len == 0)
            file_size - 1
        else
            std.fmt.parseInt(i64, end_text, 10) catch return .invalid;
        if (end < start) return .invalid;
        return .{ .partial = .{ .start = start, .end = @min(end, file_size - 1) } };
    }
    return .full;
}

test "suffix ranges read the tail needed by demuxers" {
    const result = parse("GET /s/token HTTP/1.1\r\nRange: bytes=-65536\r\n\r\n", 1_000_000);
    try std.testing.expectEqualDeep(Result{ .partial = .{ .start = 934_464, .end = 999_999 } }, result);
    try std.testing.expectEqualDeep(Result{ .partial = .{ .start = 0, .end = 99 } }, parse("GET / HTTP/1.1\r\nRange: bytes=-1000\r\n\r\n", 100));
}

test "explicit, open-ended, and case-insensitive ranges" {
    try std.testing.expectEqualDeep(Result{ .partial = .{ .start = 10, .end = 19 } }, parse("GET / HTTP/1.1\r\nrange: BYTES=10-19\r\n\r\n", 100));
    try std.testing.expectEqualDeep(Result{ .partial = .{ .start = 10, .end = 99 } }, parse("GET / HTTP/1.1\r\nRange: bytes=10-\r\n\r\n", 100));
    try std.testing.expectEqualDeep(Result{ .partial = .{ .start = 90, .end = 99 } }, parse("GET / HTTP/1.1\r\nRange: bytes=90-999\r\n\r\n", 100));
    try std.testing.expectEqualDeep(Result.full, parse("GET /s/Range: bytes=-10 HTTP/1.1\r\nHost: localhost\r\n\r\n", 100));
}

test "malformed or unsatisfiable ranges never return the wrong bytes" {
    for ([_][]const u8{ "bytes=-0", "bytes=100-", "bytes=20-10", "bytes=x-2", "bytes=0-1,3-4", "bytes=", "items=0-1" }) |value| {
        var buf: [128]u8 = undefined;
        const request = try std.fmt.bufPrint(&buf, "GET / HTTP/1.1\r\nRange: {s}\r\n\r\n", .{value});
        try std.testing.expectEqualDeep(Result.invalid, parse(request, 100));
    }
}
