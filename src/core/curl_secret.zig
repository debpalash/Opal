//! Feed sensitive curl headers through a private stdin pipe.
//!
//! Callers put `--config -` in curl's argv and pass the header values here.
//! The token never appears in `/proc/<pid>/cmdline`, process listings, crash
//! reports that capture argv, or shell history.

const std = @import("std");
const io = @import("io_global.zig");

pub const max_header_len = 2048;

/// Spawn `child`, encode each header as a curl config directive, write the
/// directives to its stdin, and close the pipe so curl observes EOF.
pub fn spawnWithHeaders(child: *io.Child, headers: []const []const u8) !void {
    // Validate everything before starting a process. In particular, reject
    // CR/LF instead of permitting a credential to inject another directive.
    for (headers) |header| {
        var checked: [max_header_len * 2 + 16]u8 = undefined;
        _ = try configLine(header, &checked);
    }

    child.stdin_behavior = .Pipe;
    try child.spawn();
    errdefer {
        child.closeStdin();
        _ = child.kill() catch {};
    }

    const stdin = if (child.stdin) |*pipe| pipe else return error.StdinUnavailable;
    for (headers) |header| {
        var line_buf: [max_header_len * 2 + 16]u8 = undefined;
        const line = try configLine(header, &line_buf);
        try io.writeAll(stdin, line);
    }
    child.closeStdin();
}

/// Curl's config syntax uses double-quoted values. Escape only the two bytes
/// with syntax meaning and reject controls; ordinary UTF-8 bytes pass through.
pub fn configLine(header: []const u8, out: []u8) ![]const u8 {
    if (header.len == 0 or header.len > max_header_len) return error.InvalidHeader;
    const prefix = "header = \"";
    const suffix = "\"\n";
    if (out.len < prefix.len + suffix.len) return error.NoSpaceLeft;
    @memcpy(out[0..prefix.len], prefix);
    var n: usize = prefix.len;
    for (header) |ch| {
        if (ch < 0x20 or ch == 0x7f) return error.InvalidHeader;
        if (ch == '\\' or ch == '"') {
            if (n + 2 + suffix.len > out.len) return error.NoSpaceLeft;
            out[n] = '\\';
            n += 1;
        } else if (n + 1 + suffix.len > out.len) {
            return error.NoSpaceLeft;
        }
        out[n] = ch;
        n += 1;
    }
    @memcpy(out[n .. n + suffix.len], suffix);
    n += suffix.len;
    return out[0..n];
}

test "curl config header escapes syntax and rejects injection" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "header = \"Authorization: Bearer a\\\"b\\\\c\"\n",
        try configLine("Authorization: Bearer a\"b\\c", &buf),
    );
    try std.testing.expectError(error.InvalidHeader, configLine("Authorization: Bearer ok\noutput=/tmp/pwn", &buf));
    try std.testing.expectError(error.InvalidHeader, configLine("", &buf));
}

test "headers travel over a closed stdin pipe" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var child = io.Child.init(&.{ "sh", "-c", "cat" }, std.testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try spawnWithHeaders(&child, &.{"Authorization: Bearer test-token"});

    var got: [256]u8 = undefined;
    const n = if (child.stdout) |*stdout| try io.readAll(stdout, &got) else 0;
    const term = try child.wait();
    try std.testing.expect(term.exited == 0);
    try std.testing.expectEqualStrings(
        "header = \"Authorization: Bearer test-token\"\n",
        got[0..n],
    );
}
