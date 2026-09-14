//! Small at-rest secret envelope. On Windows, DPAPI binds ciphertext to the
//! current user account and suppresses all UI. Other platforms retain the
//! owner-only storage policy until native keychain backends are added.
const std = @import("std");
const builtin = @import("builtin");

const prefix = "dpapi:v1:";
const ui_forbidden: u32 = 0x1;

const DataBlob = extern struct {
    cbData: u32,
    pbData: ?[*]u8,
};

const win = if (builtin.os.tag == .windows) struct {
    extern "crypt32" fn CryptProtectData(
        input: *const DataBlob,
        description: ?[*:0]const u16,
        entropy: ?*const DataBlob,
        reserved: ?*anyopaque,
        prompt: ?*anyopaque,
        flags: u32,
        output: *DataBlob,
    ) callconv(.winapi) i32;
    extern "crypt32" fn CryptUnprotectData(
        input: *const DataBlob,
        description: ?*?[*:0]u16,
        entropy: ?*const DataBlob,
        reserved: ?*anyopaque,
        prompt: ?*anyopaque,
        flags: u32,
        output: *DataBlob,
    ) callconv(.winapi) i32;
    extern "kernel32" fn LocalFree(memory: ?*anyopaque) callconv(.winapi) ?*anyopaque;
} else struct {};

pub fn isSealed(value: []const u8) bool {
    return std.mem.startsWith(u8, value, prefix);
}

/// Seal into caller storage. Non-Windows copies the value unchanged; those
/// callers already store it in an owner-only file/profile directory.
pub fn seal(value: []const u8, out: []u8) ?[]const u8 {
    if (value.len == 0) return out[0..0];
    if (comptime builtin.os.tag != .windows) {
        if (value.len > out.len) return null;
        @memcpy(out[0..value.len], value);
        return out[0..value.len];
    }
    if (value.len > std.math.maxInt(u32)) return null;
    var input = DataBlob{ .cbData = @intCast(value.len), .pbData = @constCast(value.ptr) };
    var encrypted = DataBlob{ .cbData = 0, .pbData = null };
    if (win.CryptProtectData(&input, null, null, null, null, ui_forbidden, &encrypted) == 0 or encrypted.pbData == null) return null;
    defer {
        @memset(encrypted.pbData.?[0..encrypted.cbData], 0);
        _ = win.LocalFree(@ptrCast(encrypted.pbData));
    }
    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(encrypted.cbData);
    if (prefix.len + encoded_len > out.len) return null;
    @memcpy(out[0..prefix.len], prefix);
    _ = encoder.encode(out[prefix.len .. prefix.len + encoded_len], encrypted.pbData.?[0..encrypted.cbData]);
    return out[0 .. prefix.len + encoded_len];
}

/// Reveal a sealed value into caller storage. Legacy plaintext is copied so
/// callers can scrub one buffer uniformly. Invalid DPAPI data never falls back
/// to treating its ciphertext as a credential.
pub fn reveal(stored: []const u8, out: []u8) ?[]const u8 {
    if (!isSealed(stored)) {
        if (stored.len > out.len) return null;
        @memcpy(out[0..stored.len], stored);
        return out[0..stored.len];
    }
    if (comptime builtin.os.tag != .windows) return null;
    const encoded = stored[prefix.len..];
    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(encoded) catch return null;
    if (decoded_len == 0 or decoded_len > 1024) return null;
    var decoded: [1024]u8 = undefined;
    defer @memset(&decoded, 0);
    decoder.decode(decoded[0..decoded_len], encoded) catch return null;

    var input = DataBlob{ .cbData = @intCast(decoded_len), .pbData = decoded[0..decoded_len].ptr };
    var plain = DataBlob{ .cbData = 0, .pbData = null };
    if (win.CryptUnprotectData(&input, null, null, null, null, ui_forbidden, &plain) == 0 or plain.pbData == null) return null;
    defer {
        @memset(plain.pbData.?[0..plain.cbData], 0);
        _ = win.LocalFree(@ptrCast(plain.pbData));
    }
    if (plain.cbData > out.len) return null;
    @memcpy(out[0..plain.cbData], plain.pbData.?[0..plain.cbData]);
    return out[0..plain.cbData];
}

test "secret envelope round-trips and never resembles plaintext on Windows" {
    const secret = "opal-test-secret-42";
    var sealed_buf: [512]u8 = undefined;
    const sealed = seal(secret, &sealed_buf).?;
    if (builtin.os.tag == .windows) {
        try std.testing.expect(isSealed(sealed));
        try std.testing.expect(std.mem.indexOf(u8, sealed, secret) == null);
    }
    var plain_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(secret, reveal(sealed, &plain_buf).?);
}

test "legacy plaintext remains readable for migration" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("legacy-token", reveal("legacy-token", &buf).?);
    try std.testing.expect(reveal("dpapi:v1:not-base64!", &buf) == null);
}
