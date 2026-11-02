//! Pure, unit-tested DPI-desync logic.
//!
//! Nothing in this file performs I/O. It only:
//!   1. parses a TLS ClientHello and locates the SNI hostname byte range, and
//!   2. computes the byte offsets at which the ClientHello should be split into
//!      separate TCP segments so a DPI engine cannot reassemble the SNI.
//!
//! `proxy.zig` routes its production writes through `computeSplits` so the
//! logic that ships is exactly the logic tested here.

const std = @import("std");

/// A byte range inside a buffer.
pub const Range = struct {
    start: usize,
    len: usize,
};

/// Split strategy selected on the command line via `--mode`.
pub const Mode = union(enum) {
    /// Write the first `n` bytes as one segment, then the rest.
    split: usize,
    /// Split in the middle of the SNI hostname. Falls back to `split{ .n = 1 }`
    /// when the ClientHello cannot be parsed.
    sni,
};

/// Up to this many split points (i.e. this + 1 segments). One split point is
/// enough for the current strategies; the list keeps the door open for more.
pub const max_splits = 4;

/// An ordered, de-duplicated list of split offsets, each strictly inside the
/// buffer (0 < offset < len). Segment boundaries; the producer writes
/// `[0..o0), [o0..o1), ... [ok..len)`.
pub const Splits = struct {
    offsets: [max_splits]usize = undefined,
    len: usize = 0,

    pub fn slice(self: *const Splits) []const usize {
        return self.offsets[0..self.len];
    }
};

/// True when `buf` begins like a TLS handshake record (ContentType = 22).
/// The proxy uses this to decide whether a first write is a ClientHello worth
/// desyncing; non-TLS writes pass through untouched.
pub fn looksLikeTlsClientHello(buf: []const u8) bool {
    // record: type(1)=0x16 handshake, version(2), length(2), then
    // handshake type(1)=0x01 client_hello
    if (buf.len < 6) return false;
    if (buf[0] != 0x16) return false; // handshake content type
    if (buf[5] != 0x01) return false; // client_hello handshake type
    return true;
}

fn readU16(buf: []const u8, off: usize) ?u16 {
    if (off + 2 > buf.len) return null;
    return (@as(u16, buf[off]) << 8) | buf[off + 1];
}

/// Parse a single TLS record containing a ClientHello and return the byte
/// range of the first SNI (server_name, host_name type=0) hostname within
/// `buf`, or null if it cannot be found / the buffer is malformed or truncated.
///
/// Layout walked:
///   TLSPlaintext: type(1) legacy_version(2) length(2)
///   Handshake:    msg_type(1)=1 length(3)
///   ClientHello:  legacy_version(2) random(32)
///                 session_id:      len(1) + bytes
///                 cipher_suites:   len(2) + bytes
///                 compression:     len(1) + bytes
///                 extensions:      len(2) + { type(2) len(2) data }...
///   SNI ext (0):  list_len(2) { name_type(1) name_len(2) name }...
pub fn findSni(buf: []const u8) ?Range {
    if (!looksLikeTlsClientHello(buf)) return null;

    // Record header is 5 bytes; handshake body starts at 5.
    var p: usize = 5;

    // Handshake: msg_type(1) + length(3)
    if (p + 4 > buf.len) return null;
    // buf[p] already known 0x01
    p += 4; // skip msg_type + 3-byte length

    // ClientHello: legacy_version(2) + random(32)
    p += 2 + 32;
    if (p > buf.len) return null;

    // session_id
    if (p + 1 > buf.len) return null;
    const sid_len = buf[p];
    p += 1 + sid_len;
    if (p > buf.len) return null;

    // cipher_suites
    const cs_len = readU16(buf, p) orelse return null;
    p += 2 + cs_len;
    if (p > buf.len) return null;

    // compression_methods
    if (p + 1 > buf.len) return null;
    const comp_len = buf[p];
    p += 1 + comp_len;
    if (p > buf.len) return null;

    // extensions block
    const ext_total = readU16(buf, p) orelse return null;
    p += 2;
    const ext_end = p + ext_total;
    if (ext_end > buf.len) return null;

    while (p + 4 <= ext_end) {
        const ext_type = readU16(buf, p).?;
        const ext_len = readU16(buf, p + 2).?;
        const ext_data = p + 4;
        if (ext_data + ext_len > ext_end) return null;

        if (ext_type == 0x0000) {
            // server_name extension
            var q = ext_data;
            const list_len = readU16(buf, q) orelse return null;
            q += 2;
            const list_end = q + list_len;
            if (list_end > ext_data + ext_len) return null;
            while (q + 3 <= list_end) {
                const name_type = buf[q];
                const name_len = readU16(buf, q + 1) orelse return null;
                const name_start = q + 3;
                if (name_start + name_len > list_end) return null;
                if (name_type == 0x00) {
                    // host_name
                    return .{ .start = name_start, .len = name_len };
                }
                q = name_start + name_len;
            }
            return null;
        }

        p = ext_data + ext_len;
    }

    return null;
}

/// Insert `off` into `s` keeping the list sorted, unique, and strictly inside
/// (0, total). Silently ignores out-of-range / duplicate / overflow.
fn pushSplit(s: *Splits, off: usize, total: usize) void {
    if (off == 0 or off >= total) return;
    if (s.len >= max_splits) return;
    // insertion sort, drop duplicates
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s.offsets[i] == off) return;
        if (s.offsets[i] > off) break;
    }
    var j = s.len;
    while (j > i) : (j -= 1) s.offsets[j] = s.offsets[j - 1];
    s.offsets[i] = off;
    s.len += 1;
}

/// Compute the segment split offsets for `hello` under `mode`.
///
/// Guarantees at least one split when `hello.len >= 2`, so the ClientHello is
/// always fragmented. Buffers shorter than 2 bytes yield an empty list (nothing
/// to split — the caller writes them whole).
pub fn computeSplits(hello: []const u8, mode: Mode) Splits {
    var s: Splits = .{};
    if (hello.len < 2) return s;

    switch (mode) {
        .split => |n| {
            const off = std.math.clamp(n, 1, hello.len - 1);
            pushSplit(&s, off, hello.len);
        },
        .sni => {
            if (findSni(hello)) |r| {
                // Split in the middle of the hostname. For len<2 hostnames,
                // splitting just before the last byte still separates it.
                const mid = if (r.len >= 2) r.start + r.len / 2 else r.start;
                pushSplit(&s, mid, hello.len);
            }
            // Fallback (parse failed, or hostname too short/at edge to yield a
            // valid interior split): behave like split:1.
            if (s.len == 0) pushSplit(&s, 1, hello.len);
        },
    }

    // Absolute safety net: never return an empty split for a splittable buffer.
    if (s.len == 0) pushSplit(&s, 1, hello.len);
    return s;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// A real ClientHello captured on this machine via:
///   openssl s_client -connect <listener> -servername example.com
/// "example.com" (11 bytes) sits at offset 244.
const client_hello_example_com = [_]u8{
    0x16, 0x03, 0x01, 0x01, 0x2e, 0x01, 0x00, 0x01, 0x2a, 0x03, 0x03, 0xfa,
    0x70, 0x0d, 0x9d, 0xc6, 0xe4, 0xf1, 0x0c, 0x38, 0x9d, 0x37, 0xb4, 0x0d,
    0x1b, 0xdf, 0xd6, 0x0d, 0xaa, 0xef, 0xd6, 0xf6, 0x94, 0xc5, 0x36, 0x75,
    0xc2, 0xf5, 0x1c, 0x56, 0xc2, 0x50, 0x17, 0x20, 0x60, 0xb6, 0x83, 0x93,
    0x44, 0xc3, 0xac, 0x1d, 0xff, 0x0c, 0xfd, 0x73, 0x4f, 0x6c, 0x7c, 0xeb,
    0xcb, 0x4b, 0xf5, 0xe6, 0x9a, 0x8c, 0xf4, 0x94, 0x0f, 0xb6, 0x2f, 0xd6,
    0xfb, 0xf9, 0x38, 0xc4, 0x00, 0x62, 0x13, 0x03, 0x13, 0x02, 0x13, 0x01,
    0xcc, 0xa9, 0xcc, 0xa8, 0xcc, 0xaa, 0xc0, 0x30, 0xc0, 0x2c, 0xc0, 0x28,
    0xc0, 0x24, 0xc0, 0x14, 0xc0, 0x0a, 0x00, 0x9f, 0x00, 0x6b, 0x00, 0x39,
    0xff, 0x85, 0x00, 0xc4, 0x00, 0x88, 0x00, 0x81, 0x00, 0x9d, 0x00, 0x3d,
    0x00, 0x35, 0x00, 0xc0, 0x00, 0x84, 0xc0, 0x2f, 0xc0, 0x2b, 0xc0, 0x27,
    0xc0, 0x23, 0xc0, 0x13, 0xc0, 0x09, 0x00, 0x9e, 0x00, 0x67, 0x00, 0x33,
    0x00, 0xbe, 0x00, 0x45, 0x00, 0x9c, 0x00, 0x3c, 0x00, 0x2f, 0x00, 0xba,
    0x00, 0x41, 0xc0, 0x11, 0xc0, 0x07, 0x00, 0x05, 0x00, 0x04, 0xc0, 0x12,
    0xc0, 0x08, 0x00, 0x16, 0x00, 0x0a, 0x00, 0xff, 0x01, 0x00, 0x00, 0x7f,
    0x00, 0x2b, 0x00, 0x09, 0x08, 0x03, 0x04, 0x03, 0x03, 0x03, 0x02, 0x03,
    0x01, 0x00, 0x33, 0x00, 0x26, 0x00, 0x24, 0x00, 0x1d, 0x00, 0x20, 0xaa,
    0x3a, 0x9a, 0xdb, 0xb9, 0x76, 0x2d, 0x54, 0x7c, 0x03, 0x31, 0x3b, 0xd2,
    0x4a, 0xa0, 0xee, 0xb0, 0x64, 0x9c, 0x8c, 0x9a, 0x15, 0xfa, 0x8c, 0x25,
    0x66, 0xfc, 0xf7, 0x43, 0x9c, 0xc3, 0x51, 0x00, 0x00, 0x00, 0x10, 0x00,
    0x0e, 0x00, 0x00, 0x0b, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x2e,
    0x63, 0x6f, 0x6d, 0x00, 0x0b, 0x00, 0x02, 0x01, 0x00, 0x00, 0x0a, 0x00,
    0x0a, 0x00, 0x08, 0x00, 0x1d, 0x00, 0x17, 0x00, 0x18, 0x00, 0x19, 0x00,
    0x23, 0x00, 0x00, 0x00, 0x0d, 0x00, 0x18, 0x00, 0x16, 0x08, 0x06, 0x06,
    0x01, 0x06, 0x03, 0x08, 0x05, 0x05, 0x01, 0x05, 0x03, 0x08, 0x04, 0x04,
    0x01, 0x04, 0x03, 0x02, 0x01, 0x02, 0x03,
};

test "findSni: real ClientHello locates example.com" {
    const r = findSni(&client_hello_example_com) orelse return error.SniNotFound;
    try std.testing.expectEqual(@as(usize, 244), r.start);
    try std.testing.expectEqual(@as(usize, 11), r.len);
    try std.testing.expectEqualStrings("example.com", client_hello_example_com[r.start .. r.start + r.len]);
}

test "looksLikeTlsClientHello" {
    try std.testing.expect(looksLikeTlsClientHello(&client_hello_example_com));
    try std.testing.expect(!looksLikeTlsClientHello("GET / HTTP/1.1\r\n"));
    try std.testing.expect(!looksLikeTlsClientHello(&[_]u8{ 0x16, 0x03 })); // too short
    // handshake record but not a client_hello (msg_type 0x02 = server_hello)
    try std.testing.expect(!looksLikeTlsClientHello(&[_]u8{ 0x16, 0x03, 0x01, 0x00, 0x10, 0x02 }));
}

test "findSni: rejects malformed / truncated buffers" {
    try std.testing.expect(findSni("") == null);
    try std.testing.expect(findSni("not tls at all") == null);
    // valid header prefix but truncated body
    try std.testing.expect(findSni(client_hello_example_com[0..50]) == null);
    // truncated right where the hostname would be
    try std.testing.expect(findSni(client_hello_example_com[0..250]) == null);
}

test "computeSplits: split:N basic" {
    const s = computeSplits(&client_hello_example_com, .{ .split = 5 });
    try std.testing.expectEqual(@as(usize, 1), s.len);
    try std.testing.expectEqual(@as(usize, 5), s.offsets[0]);
}

test "computeSplits: split:1 default" {
    const s = computeSplits(&client_hello_example_com, .{ .split = 1 });
    try std.testing.expectEqualSlices(usize, &[_]usize{1}, s.slice());
}

test "computeSplits: split:N clamps oversized N to len-1" {
    const s = computeSplits(&client_hello_example_com, .{ .split = 100000 });
    try std.testing.expectEqual(@as(usize, 1), s.len);
    try std.testing.expectEqual(client_hello_example_com.len - 1, s.offsets[0]);
}

test "computeSplits: sni splits in the middle of the hostname" {
    const s = computeSplits(&client_hello_example_com, .sni);
    try std.testing.expectEqual(@as(usize, 1), s.len);
    // hostname at 244 len 11 -> midpoint 244 + 5 = 249, inside "example.com"
    try std.testing.expectEqual(@as(usize, 249), s.offsets[0]);
    // the split must fall strictly inside the hostname bytes
    try std.testing.expect(s.offsets[0] > 244 and s.offsets[0] < 255);
}

test "computeSplits: sni falls back to split:1 when parsing fails" {
    // Not a ClientHello -> no SNI -> fallback split:1.
    const buf = "this is not a tls record at all, just some bytes";
    const s = computeSplits(buf, .sni);
    try std.testing.expectEqualSlices(usize, &[_]usize{1}, s.slice());
}

test "computeSplits: tiny buffers are never split" {
    try std.testing.expectEqual(@as(usize, 0), computeSplits("", .sni).len);
    try std.testing.expectEqual(@as(usize, 0), computeSplits("x", .{ .split = 1 }).len);
    // exactly 2 bytes -> a single valid split at offset 1
    try std.testing.expectEqualSlices(usize, &[_]usize{1}, computeSplits("xy", .{ .split = 1 }).slice());
}

test "pushSplit keeps offsets sorted, unique and in range" {
    var s: Splits = .{};
    pushSplit(&s, 5, 10);
    pushSplit(&s, 3, 10);
    pushSplit(&s, 5, 10); // dup ignored
    pushSplit(&s, 0, 10); // out of range ignored
    pushSplit(&s, 10, 10); // out of range ignored
    pushSplit(&s, 8, 10);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 3, 5, 8 }, s.slice());
}
