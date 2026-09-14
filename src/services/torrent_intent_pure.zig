//! Privacy boundary for durable torrent restart intent.
//!
//! Only exact-topic (`xt`) hashes survive. Display names, trackers, web seeds,
//! peers and arbitrary query parameters may contain private passkeys or user
//! data, so they are deliberately discarded before SQLite sees the value.

const std = @import("std");

pub const MAX_IDENTITY: usize = 160;
const v1_prefix = "xt=urn:btih:";
const v2_prefix = "xt=urn:btmh:1220";

fn copyLowerHex(src: []const u8, dest: []u8) bool {
    if (src.len != dest.len) return false;
    for (src, 0..) |ch, i| {
        if (!std.ascii.isHex(ch)) return false;
        dest[i] = std.ascii.toLower(ch);
    }
    return true;
}

/// Canonicalize a magnet to the minimum identity needed to rejoin its swarm.
/// Supports v1, v2 and hybrid magnets; every non-`xt` field is dropped.
pub fn canonicalIdentity(input: []const u8, out: []u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, input, "magnet:?")) return null;

    var v1: [40]u8 = undefined;
    var v2: [64]u8 = undefined;
    var has_v1 = false;
    var has_v2 = false;
    var fields = std.mem.splitScalar(u8, input["magnet:?".len..], '&');
    while (fields.next()) |field| {
        if (!has_v1 and std.mem.startsWith(u8, field, v1_prefix)) {
            has_v1 = copyLowerHex(field[v1_prefix.len..], &v1);
        } else if (!has_v2 and std.mem.startsWith(u8, field, v2_prefix)) {
            has_v2 = copyLowerHex(field[v2_prefix.len..], &v2);
        }
    }
    if (!has_v1 and !has_v2) return null;

    if (has_v1 and has_v2) {
        return std.fmt.bufPrint(out, "magnet:?xt=urn:btih:{s}&xt=urn:btmh:1220{s}", .{ &v1, &v2 }) catch null;
    }
    if (has_v1) return std.fmt.bufPrint(out, "magnet:?xt=urn:btih:{s}", .{&v1}) catch null;
    return std.fmt.bufPrint(out, "magnet:?xt=urn:btmh:1220{s}", .{&v2}) catch null;
}

test "identity strips private and descriptive magnet fields" {
    var out: [MAX_IDENTITY]u8 = undefined;
    const raw = "magnet:?dn=Private+Name&tr=https://tracker.example/announce?passkey=SECRET&xt=urn:btih:0123456789ABCDEF0123456789ABCDEF01234567&ws=https://user:token@example/file";
    const got = canonicalIdentity(raw, &out).?;
    try std.testing.expectEqualStrings("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567", got);
    try std.testing.expect(std.mem.indexOf(u8, got, "SECRET") == null);
}

test "identity preserves v2 and hybrid swarm hashes" {
    var out: [MAX_IDENTITY]u8 = undefined;
    const v2_hash = "CAF1E1C30E81CB361B9EE167C4AA64228A7FA4FA9F6105232B28AD099F3A302E";
    const v2 = canonicalIdentity("magnet:?xt=urn:btmh:1220" ++ v2_hash ++ "&dn=test", &out).?;
    try std.testing.expectEqualStrings("magnet:?xt=urn:btmh:1220caf1e1c30e81cb361b9ee167c4aa64228a7fa4fa9f6105232b28ad099f3a302e", v2);

    const hybrid = canonicalIdentity("magnet:?xt=urn:btmh:1220" ++ v2_hash ++ "&xt=urn:btih:631A31DD0A46257D5078C0DEE4E66E26F73E42AC", &out).?;
    try std.testing.expectEqualStrings("magnet:?xt=urn:btih:631a31dd0a46257d5078c0dee4e66e26f73e42ac&xt=urn:btmh:1220caf1e1c30e81cb361b9ee167c4aa64228a7fa4fa9f6105232b28ad099f3a302e", hybrid);
}

test "identity rejects malformed or non-hex topics" {
    var out: [MAX_IDENTITY]u8 = undefined;
    try std.testing.expect(canonicalIdentity("https://example.test", &out) == null);
    try std.testing.expect(canonicalIdentity("magnet:?dn=no-hash", &out) == null);
    try std.testing.expect(canonicalIdentity("magnet:?xt=urn:btih:short", &out) == null);
    try std.testing.expect(canonicalIdentity("magnet:?xt=urn:btmh:1220zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz", &out) == null);
}
