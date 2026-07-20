//! Small text helpers shared across renderers.

const std = @import("std");

/// Longest valid-UTF-8 prefix of `s`.
///
/// Titles, names, and overviews from network sources are copied into
/// fixed-size `[N]u8` buffers and can be truncated mid-codepoint (or carry
/// stray bytes). dvui's text layout asserts valid UTF-8
/// (`utf8ByteSequenceLength(...) catch unreachable`), so passing a raw buffer
/// slice straight to a label/button can panic the whole app. Any free text
/// drawn by dvui must pass through here first.
pub fn safeUtf8(s: []const u8) []const u8 {
    if (std.unicode.utf8ValidateSlice(s)) return s;
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch break;
        if (i + n > s.len) break;
        _ = std.unicode.utf8Decode(s[i .. i + n]) catch break;
        i += n;
    }
    return s[0..i];
}

/// Like `safeUtf8`, but first copies `s` into `out` and validates the COPY.
///
/// `safeUtf8` returns a slice that still points at the source bytes. When the
/// source is a `results[]` title/overview that a background fetch worker may
/// rewrite mid-frame, dvui can read bytes that changed AFTER validation and hit
/// its `utf8ByteSequenceLength(...) catch unreachable` panic (Utf8Invalid…).
/// Validating a stable stack copy makes the returned slice immune to that race
/// (worst case is a momentarily-garbled label, never a crash). Pass a stack
/// buffer as `out`.
pub fn safeUtf8Buf(s: []const u8, out: []u8) []const u8 {
    const n = @min(s.len, out.len);
    // Defensive: a caller passing a slice OF `out` itself already owns a
    // stable copy — @memcpy would panic ("arguments alias"; crashed the TV
    // detail view). Just validate in place.
    if (s.ptr == out.ptr) return safeUtf8(s[0..n]);
    @memcpy(out[0..n], s[0..n]);
    return safeUtf8(out[0..n]);
}

/// Copy `src` into fixed buffer `dst` and write the resulting length to
/// `len_out`, tolerating `src` ALIASING `dst`.
///
/// The recurring crash (footer's universal-language chip, the TV detail view,
/// and safeUtf8Buf above) is a caller passing a buffer's OWN current slice back
/// in — `@memcpy(buf[0..n], buf_slice)` panics with "arguments alias" because
/// the operands overlap. `state.app` fields are `[N]u8`+len and their current
/// value is frequently re-applied, so this is easy to hit. Guarding on pointer
/// identity (identical slice → the bytes are already in place, a no-op) and
/// using copyForwards for the disjoint case removes the whole class. Truncates
/// to `dst.len`.
pub fn setFixedBuf(dst: []u8, len_out: *usize, src: []const u8) void {
    const n = @min(src.len, dst.len);
    if (src.ptr != dst.ptr) std.mem.copyForwards(u8, dst[0..n], src[0..n]);
    len_out.* = n;
}

test "setFixedBuf tolerates src aliasing dst (no @memcpy alias panic)" {
    var buf: [8]u8 = undefined;
    @memcpy(buf[0..5], "hello");
    var len: usize = 0;
    // Aliased: pass the buffer's own slice back in — must not panic.
    setFixedBuf(buf[0..], &len, buf[0..5]);
    try std.testing.expectEqual(@as(usize, 5), len);
    try std.testing.expectEqualStrings("hello", buf[0..len]);
}

test "setFixedBuf copies disjoint src and truncates to dst" {
    var dst: [4]u8 = undefined;
    var len: usize = 0;
    setFixedBuf(dst[0..], &len, "abcdef"); // longer than dst → truncates
    try std.testing.expectEqual(@as(usize, 4), len);
    try std.testing.expectEqualStrings("abcd", dst[0..len]);
}

test "safeUtf8Buf tolerates aliased src/dst (in-place validation)" {
    var buf: [8]u8 = undefined;
    @memcpy(buf[0..5], "hello");
    try std.testing.expectEqualStrings("hello", safeUtf8Buf(buf[0..5], &buf));
}

test "safeUtf8 passes valid through and trims invalid tail" {
    try std.testing.expectEqualStrings("hello", safeUtf8("hello"));
    // Valid 2-byte é (0xC3 0xA9) then a lone continuation byte 0xA9.
    try std.testing.expectEqualStrings("\xC3\xA9", safeUtf8("\xC3\xA9\xA9"));
    // Truncated leading byte of a 2-byte sequence at the very end.
    try std.testing.expectEqualStrings("ab", safeUtf8("ab\xC3"));
    // Lone start byte only.
    try std.testing.expectEqualStrings("", safeUtf8("\xFF"));
}
