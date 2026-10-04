//! Windows command-line quoting, pure so it is unit tested on any host.
//!
//! A Windows process gets one command-line string and splits it itself. Most
//! programs (anything on the MSVC or MinGW C runtime) split it with the
//! `CommandLineToArgvW` rules implemented by `argQuote`; `cmd.exe` is the odd
//! one out and is handled by the callers that build `cmd /s /c "..."` lines.

const std = @import("std");

/// Quote one argument so `CommandLineToArgvW` gives back exactly `s`: wrapped in
/// double quotes, with a run of backslashes doubled when it ends the argument or
/// precedes a quote, and each embedded quote escaped. Null when `buf` is small.
pub fn argQuote(buf: []u8, s: []const u8) ?[]const u8 {
    var n: usize = 0;
    if (!put(buf, &n, '"')) return null;
    var slashes: usize = 0;
    for (s) |ch| {
        if (ch == '\\') {
            slashes += 1;
            continue;
        }
        if (ch == '"') {
            // Backslashes before a quote are literal only if doubled.
            if (!putRun(buf, &n, '\\', slashes * 2 + 1)) return null;
        } else if (!putRun(buf, &n, '\\', slashes)) return null;
        slashes = 0;
        if (!put(buf, &n, ch)) return null;
    }
    // Trailing backslashes would otherwise escape the closing quote.
    if (!putRun(buf, &n, '\\', slashes * 2)) return null;
    if (!put(buf, &n, '"')) return null;
    return buf[0..n];
}

fn put(buf: []u8, n: *usize, ch: u8) bool {
    if (n.* >= buf.len) return false;
    buf[n.*] = ch;
    n.* += 1;
    return true;
}

fn putRun(buf: []u8, n: *usize, ch: u8, count: usize) bool {
    var i: usize = 0;
    while (i < count) : (i += 1) if (!put(buf, n, ch)) return false;
    return true;
}

/// `argv` joined into one command line with every argument quoted by `argQuote`.
pub fn joinArgv(allocator: std.mem.Allocator, argv: []const []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (argv, 0..) |arg, i| {
        if (i > 0) try out.append(allocator, ' ');
        // Worst case every byte is a backslash or quote and doubles.
        const tmp = try allocator.alloc(u8, arg.len * 2 + 2);
        defer allocator.free(tmp);
        try out.appendSlice(allocator, argQuote(tmp, arg).?);
    }
    return out.toOwnedSlice(allocator);
}

test "argQuote wraps and escapes like CommandLineToArgvW" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\"C:\\Program Files\\x\"", argQuote(&b, "C:\\Program Files\\x").?);
    try std.testing.expectEqualStrings("\"\"", argQuote(&b, "").?);
    try std.testing.expectEqualStrings("\"a\\\"b\"", argQuote(&b, "a\"b").?);
    // Backslashes before a quote double (plus one to escape it); a trailing run doubles.
    try std.testing.expectEqualStrings("\"a\\\\\\\"b\"", argQuote(&b, "a\\\"b").?);
    try std.testing.expectEqualStrings("\"C:\\dir with space\\\\\"", argQuote(&b, "C:\\dir with space\\").?);
    var tiny: [3]u8 = undefined;
    try std.testing.expect(argQuote(&tiny, "abc") == null);
}

test "joinArgv quotes each argument" {
    const line = try joinArgv(std.testing.allocator, &.{ "C:\\a b\\x.exe", "-c", "say \"hi\"" });
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("\"C:\\a b\\x.exe\" \"-c\" \"say \\\"hi\\\"\"", line);
}
