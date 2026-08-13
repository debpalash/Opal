//! Bounded, allocation-free secret redaction for process/network log text.
//! Returned output is never longer than the input, so callers can allocate one
//! exact-sized buffer and expose only the returned prefix.

const std = @import("std");

fn startsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

fn isValueEnd(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n' or
        ch == '&' or ch == '"' or ch == '\'' or ch == ',' or ch == ';';
}

fn isUrlEnd(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n' or
        ch == '"' or ch == '\'' or ch == '<' or ch == '>';
}

fn write(out: []u8, at: *usize, bytes: []const u8) void {
    const n = @min(bytes.len, out.len - at.*);
    @memcpy(out[at.* .. at.* + n], bytes[0..n]);
    at.* += n;
}

fn redactUrl(input: []const u8, start: usize, out: []u8, at: *usize) usize {
    const scheme_len: usize = if (startsIgnoreCase(input[start..], "https://")) 8 else 7;
    const end = blk: {
        var i = start + scheme_len;
        while (i < input.len and !isUrlEnd(input[i])) : (i += 1) {}
        break :blk i;
    };
    var authority_end = start + scheme_len;
    while (authority_end < end and input[authority_end] != '/' and input[authority_end] != '?' and input[authority_end] != '#') : (authority_end += 1) {}
    const authority = input[start + scheme_len .. authority_end];
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |user_end| {
        write(out, at, input[start .. start + scheme_len]);
        write(out, at, "[redacted]@");
        write(out, at, authority[user_end + 1 ..]);
    } else {
        write(out, at, input[start..authority_end]);
    }

    var tail = authority_end;
    while (tail < end and input[tail] != '?' and input[tail] != '#') : (tail += 1) {}
    write(out, at, input[authority_end..tail]);
    if (tail < end) write(out, at, "?[redacted]");
    return end;
}

fn redactMagnet(input: []const u8, start: usize, out: []u8, at: *usize) usize {
    const end = blk: {
        var i = start;
        while (i < input.len and !isUrlEnd(input[i])) : (i += 1) {}
        break :blk i;
    };
    const amp = std.mem.indexOfScalarPos(u8, input[0..end], start, '&') orelse end;
    write(out, at, input[start..amp]);
    if (amp < end) write(out, at, "&[redacted]");
    return end;
}

const secret_markers = [_][]const u8{
    "x-plex-token:",
    "x-emby-token:",
    "api_key=",
    "apikey=",
    "access_token=",
    "refresh_token=",
    "token=",
};

/// Redact URL credentials/query strings, magnet tracker parameters, bearer
/// headers, and common token parameters. `out.len` must be at least input.len.
pub fn redactInto(input: []const u8, out: []u8) []const u8 {
    if (out.len < input.len) return out[0..0];
    var i: usize = 0;
    var w: usize = 0;
    while (i < input.len) {
        if (startsIgnoreCase(input[i..], "https://") or startsIgnoreCase(input[i..], "http://")) {
            i = redactUrl(input, i, out, &w);
            continue;
        }
        if (startsIgnoreCase(input[i..], "magnet:?")) {
            i = redactMagnet(input, i, out, &w);
            continue;
        }

        const auth_len: usize = if (startsIgnoreCase(input[i..], "proxy-authorization:"))
            "proxy-authorization:".len
        else if (startsIgnoreCase(input[i..], "authorization:"))
            "authorization:".len
        else
            0;
        if (auth_len > 0) {
            write(out, &w, input[i .. i + auth_len]);
            i += auth_len;
            while (i < input.len and (input[i] == ' ' or input[i] == '\t')) : (i += 1)
                write(out, &w, input[i .. i + 1]);
            if (startsIgnoreCase(input[i..], "bearer ")) i += "bearer ".len;
            write(out, &w, "[redacted]");
            while (i < input.len and !isValueEnd(input[i])) : (i += 1) {}
            continue;
        }

        var marker_len: usize = 0;
        inline for (secret_markers) |marker| {
            if (marker_len == 0 and startsIgnoreCase(input[i..], marker)) marker_len = marker.len;
        }
        if (marker_len > 0) {
            write(out, &w, input[i .. i + marker_len]);
            i += marker_len;
            while (i < input.len and (input[i] == ' ' or input[i] == '\t')) : (i += 1) {
                write(out, &w, input[i .. i + 1]);
            }
            write(out, &w, "[redacted]");
            while (i < input.len and !isValueEnd(input[i])) : (i += 1) {}
            continue;
        }

        out[w] = input[i];
        w += 1;
        i += 1;
    }
    return out[0..w];
}

test "redacts URL userinfo and every query or fragment" {
    const input = "open https://alice:secret@media.test/p.m3u8?token=abc&x=1#frag now";
    var out: [input.len]u8 = undefined;
    try std.testing.expectEqualStrings(
        "open https://[redacted]@media.test/p.m3u8?[redacted] now",
        redactInto(input, &out),
    );
}

test "redacts bearer and token fields without swallowing the next message" {
    const input = "Authorization: Bearer abc.def api_key=SECRET; retry";
    var out: [input.len]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Authorization: [redacted] api_key=[redacted]; retry",
        redactInto(input, &out),
    );
}

test "magnet logs retain only the identity hash" {
    const input = "magnet:?xt=urn:btih:ABC&tr=https://tracker/passkey/xyz&dn=Movie";
    var out: [input.len]u8 = undefined;
    try std.testing.expectEqualStrings(
        "magnet:?xt=urn:btih:ABC&[redacted]",
        redactInto(input, &out),
    );
}

test "plain text is unchanged" {
    const input = "resolver finished with 8 rows";
    var out: [input.len]u8 = undefined;
    try std.testing.expectEqualStrings(input, redactInto(input, &out));
}
