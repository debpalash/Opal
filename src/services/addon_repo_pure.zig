//! Signed repository format. Verify exact manifest bytes before parsing files.
const std = @import("std");
const Ed = std.crypto.sign.Ed25519;
pub const MAX_BYTES = 256 * 1024;
pub const Permission = enum { network, full_access };
pub const File = struct { name: []const u8, content: []const u8 };
pub const Panel = struct { title: []const u8, body: []const u8 };
pub const Addon = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    permissions: []const Permission = &.{},
    files: []const File = &.{},
    panel: ?Panel = null,
    pub fn requests(self: Addon, permission: Permission) bool {
        for (self.permissions) |p| if (p == permission) return true;
        return false;
    }
};
pub const Catalog = struct { version: u32, addons: []const Addon };
const Envelope = struct { manifest: []const u8, signature: []const u8 };
pub const Verified = struct {
    envelope: std.json.Parsed(Envelope),
    catalog: std.json.Parsed(Catalog),
    pub fn deinit(self: Verified) void {
        self.catalog.deinit();
        self.envelope.deinit();
    }
};

pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 32 or id[0] == '.' or id[0] == '-') return false;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    return true;
}

pub fn validRepoUrl(url: []const u8) bool {
    if (url.len == 0 or url.len > 1024 or std.mem.indexOfAny(u8, url, "\r\n\t #@") != null) return false;
    const uri = std.Uri.parse(url) catch return false;
    if (uri.user != null or uri.password != null or uri.host == null or uri.fragment != null) return false;
    if (std.mem.eql(u8, uri.scheme, "https")) return true;
    // Explicit localhost exception permits private fixtures/offline development.
    if (!std.mem.eql(u8, uri.scheme, "http")) return false;
    const host = uri.host.?.percent_encoded;
    return std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "localhost");
}

pub fn verify(a: std.mem.Allocator, bytes: []const u8, key_hex: []const u8) !Verified {
    if (bytes.len > MAX_BYTES or key_hex.len != 64) return error.InvalidRepository;
    var key: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&key, key_hex) catch return error.InvalidKey;
    const public = Ed.PublicKey.fromBytes(key) catch return error.InvalidKey;
    const envelope = try std.json.parseFromSlice(Envelope, a, bytes, .{ .allocate = .alloc_always });
    errdefer envelope.deinit();
    if (envelope.value.signature.len != 128) return error.InvalidSignature;
    var sig: [64]u8 = undefined;
    _ = std.fmt.hexToBytes(&sig, envelope.value.signature) catch return error.InvalidSignature;
    Ed.Signature.fromBytes(sig).verify(envelope.value.manifest, public) catch return error.InvalidSignature;
    const catalog = try std.json.parseFromSlice(Catalog, a, envelope.value.manifest, .{});
    errdefer catalog.deinit();
    if (catalog.value.version != 1 or catalog.value.addons.len > 32) return error.InvalidCatalog;
    for (catalog.value.addons, 0..) |addon, index| {
        if (!validId(addon.id) or addon.name.len == 0 or addon.name.len > 64 or addon.version.len == 0 or addon.version.len > 32 or addon.files.len > 4) return error.InvalidAddon;
        for (catalog.value.addons[0..index]) |other| if (std.mem.eql(u8, addon.id, other.id)) return error.DuplicateAddon;
        var manifest = false;
        var executable = false;
        for (addon.files, 0..) |file, i| {
            if (file.content.len > 64 * 1024) return error.FileTooLarge;
            for (addon.files[0..i]) |previous| if (std.mem.eql(u8, previous.name, file.name)) return error.DuplicateFile;
            if (std.mem.eql(u8, file.name, "manifest.json")) {
                if (file.content.len > 4096) return error.FileTooLarge;
                manifest = true;
                const unsafe = try @import("plugins_pure.zig").manifestUnsafe(a, file.content);
                if (unsafe and !addon.requests(.full_access)) return error.PermissionMismatch;
            } else if (std.mem.eql(u8, file.name, "search") or std.mem.eql(u8, file.name, "resolve") or std.mem.eql(u8, file.name, "trending")) {
                if (!std.mem.startsWith(u8, file.content, "#!/usr/bin/env lua\n")) return error.InvalidLuaEntrypoint;
                executable = true;
            } else return error.InvalidFile;
        }
        if (!manifest or (executable and !addon.requests(.network))) return error.PermissionMismatch;
        if (addon.panel) |panel| if (panel.title.len == 0 or panel.title.len > 96 or panel.body.len > 4096) return error.InvalidPanel;
    }
    return .{ .envelope = envelope, .catalog = catalog };
}

fn signedFixture(a: std.mem.Allocator, manifest: []const u8, key: Ed.KeyPair) ![]u8 {
    const signature = try key.sign(manifest, null);
    const hex = std.fmt.bytesToHex(signature.toBytes(), .lower);
    return std.json.Stringify.valueAlloc(a, Envelope{ .manifest = manifest, .signature = &hex }, .{});
}

test "repository verifies exact bytes and rejects tampering and wrong pinned keys" {
    const a = std.testing.allocator;
    const key = try Ed.KeyPair.generateDeterministic(.{1} ** 32);
    const bytes = try signedFixture(a, "{\"version\":1,\"addons\":[]}", key);
    defer a.free(bytes);
    const hex = std.fmt.bytesToHex(key.public_key.toBytes(), .lower);
    const verified = try verify(a, bytes, &hex);
    verified.deinit();
    const wrong = try Ed.KeyPair.generateDeterministic(.{2} ** 32);
    const wrong_hex = std.fmt.bytesToHex(wrong.public_key.toBytes(), .lower);
    try std.testing.expectError(error.InvalidSignature, verify(a, bytes, &wrong_hex));
    const at = std.mem.indexOf(u8, bytes, "version").?;
    bytes[at] = 'V';
    try std.testing.expectError(error.InvalidSignature, verify(a, bytes, &hex));
}

test "signed repository cannot traverse paths or hide executable permissions" {
    const a = std.testing.allocator;
    const key = try Ed.KeyPair.generateDeterministic(.{3} ** 32);
    const hex = std.fmt.bytesToHex(key.public_key.toBytes(), .lower);
    const bad = try signedFixture(a,
        \\{"version":1,"addons":[{"id":"demo","name":"Demo","version":"1","files":[{"name":"../escape","content":"bad"}]}]}
    , key);
    defer a.free(bad);
    try std.testing.expectError(error.InvalidFile, verify(a, bad, &hex));
    const hidden = try signedFixture(a,
        \\{"version":1,"addons":[{"id":"demo","name":"Demo","version":"1","files":[{"name":"manifest.json","content":"{\"allow_unsafe\":true}"}]}]}
    , key);
    defer a.free(hidden);
    try std.testing.expectError(error.PermissionMismatch, verify(a, hidden, &hex));
}

test "repository URLs require explicit HTTPS or local fixture host" {
    try std.testing.expect(validRepoUrl("https://example.org/repository.json"));
    try std.testing.expect(validRepoUrl("http://127.0.0.1:1234/repo"));
    try std.testing.expect(!validRepoUrl("http://example.org/repo"));
    try std.testing.expect(!validRepoUrl("https://user:pass@example.org/repo"));
    try std.testing.expect(!validId("../demo"));
}
