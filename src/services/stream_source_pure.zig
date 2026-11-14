//! Bounded transport contract shared by executable plugins and Stremio.
const std = @import("std");
pub const Source = struct {
    url: [8192]u8 = @splat(0),
    url_len: usize = 0,
    title: [256]u8 = @splat(0),
    title_len: usize = 0,
    language: [64]u8 = @splat(0),
    language_len: usize = 0,
    quality: [32]u8 = @splat(0),
    quality_len: usize = 0,
    user_agent: [512]u8 = @splat(0),
    user_agent_len: usize = 0,
    header_fields: [2048]u8 = @splat(0),
    header_fields_len: usize = 0,
};

fn string(v: std.json.Value, key: []const u8) []const u8 {
    if (v != .object) return "";
    const f = v.object.get(key) orelse return "";
    return if (f == .string) f.string else "";
}
fn put(dst: []u8, len: *usize, value: []const u8) bool {
    if (value.len > dst.len) return false;
    @memcpy(dst[0..value.len], value);
    len.* = value.len;
    return true;
}
fn safe(value: []const u8) bool {
    for (value) |c| if (c < 32 or c == 127 or c == ',') return false;
    return true;
}
fn header(s: *Source, name: []const u8, value: []const u8) bool {
    if (value.len == 0) return true;
    if (!safe(value)) return false;
    if (std.ascii.eqlIgnoreCase(name, "User-Agent")) return put(&s.user_agent, &s.user_agent_len, value);
    // Only transport identity headers are accepted. Never accept arbitrary
    // option names, Host, connection controls, or newline injection.
    const canonical = if (std.ascii.eqlIgnoreCase(name, "Referer")) "Referer" else if (std.ascii.eqlIgnoreCase(name, "Origin")) "Origin" else return true;
    const sep: []const u8 = if (s.header_fields_len > 0) "," else "";
    const result = std.fmt.bufPrint(s.header_fields[s.header_fields_len..], "{s}{s}: {s}", .{ sep, canonical, value }) catch return false;
    s.header_fields_len += result.len;
    return true;
}
pub fn fromValue(value: std.json.Value) ?Source {
    if (value != .object) return null;
    var s: Source = .{};
    var url = string(value, "url");
    if (url.len == 0) url = string(value, "stream_url");
    if (url.len == 0) {
        const hash = string(value, "infoHash");
        if (hash.len != 40) return null;
        for (hash) |c| if (!std.ascii.isHex(c)) return null;
        const magnet = std.fmt.bufPrint(&s.url, "magnet:?xt=urn:btih:{s}", .{hash}) catch return null;
        s.url_len = magnet.len;
    } else {
        if (!(std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "magnet:?"))) return null;
        for (url) |c| if (c <= 32 or c == 127) return null;
        if (!std.mem.startsWith(u8, url, "magnet:?")) {
            const uri = std.Uri.parse(url) catch return null;
            if (uri.host == null or uri.host.?.percent_encoded.len == 0) return null;
        }
        if (!put(&s.url, &s.url_len, url)) return null;
    }
    var title = string(value, "title");
    if (title.len == 0) title = string(value, "name");
    _ = put(&s.title, &s.title_len, title[0..@min(title.len, s.title.len)]);
    const language = string(value, "language");
    _ = put(&s.language, &s.language_len, language[0..@min(language.len, s.language.len)]);
    const quality = string(value, "quality");
    _ = put(&s.quality, &s.quality_len, quality[0..@min(quality.len, s.quality.len)]);
    var headers = value.object.get("headers");
    if (value.object.get("behaviorHints")) |hints| {
        if (hints == .object) if (hints.object.get("proxyHeaders")) |proxy| {
            if (proxy == .object) headers = proxy.object.get("request");
        };
    }
    if (headers) |h| {
        if (h != .object) return null;
        var it = h.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) return null;
            if (!header(&s, entry.key_ptr.*, entry.value_ptr.string)) return null;
        }
    }
    if (!header(&s, "Referer", string(value, "referer")) or !header(&s, "Origin", string(value, "origin")) or !header(&s, "User-Agent", string(value, "user_agent"))) return null;
    return s;
}
pub fn parseResolve(allocator: std.mem.Allocator, json: []const u8) ?Source {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return null;
    defer parsed.deinit();
    return fromValue(parsed.value);
}
pub fn parseStreams(allocator: std.mem.Allocator, json: []const u8, out: []Source) ?usize {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const rows = parsed.value.object.get("streams") orelse return null;
    if (rows != .array) return null;
    var count: usize = 0;
    for (rows.array.items) |row| {
        if (count == out.len) break;
        out[count] = fromValue(row) orelse continue;
        count += 1;
    }
    return count;
}

test "structured stream JSON preserves escaped URLs and isolates row metadata" {
    var out: [3]Source = undefined;
    const n = parseStreams(std.testing.allocator,
        \\{"streams": [{"url": "https:\/\/media.test/a?x=1&y=2", "title": "First", "language":"en", "behaviorHints":{"proxyHeaders":{"request":{"Referer":"https://page.test/","User-Agent":"Fixture"}}}}, {"url":"https://media.test/b", "title":"Second"}, {"infoHash":"0123456789012345678901234567890123456789"}]}
    , &out).?;
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("https://media.test/a?x=1&y=2", out[0].url[0..out[0].url_len]);
    try std.testing.expectEqualStrings("Fixture", out[0].user_agent[0..out[0].user_agent_len]);
    try std.testing.expectEqualStrings("Referer: https://page.test/", out[0].header_fields[0..out[0].header_fields_len]);
    try std.testing.expectEqualStrings("Second", out[1].title[0..out[1].title_len]);
    try std.testing.expectEqual(@as(usize, 0), out[1].header_fields_len);
    try std.testing.expect(std.mem.startsWith(u8, out[2].url[0..out[2].url_len], "magnet:?"));
}
test "long signed URLs survive intact; overflow and injection fail closed" {
    var url: [9000]u8 = @splat('a');
    @memcpy(url[0..19], "https://media.test/");
    var json: [9500]u8 = undefined;
    const accepted = std.fmt.bufPrint(&json, "{{\"url\":\"{s}\"}}", .{url[0..6000]}) catch unreachable;
    try std.testing.expectEqual(@as(usize, 6000), parseResolve(std.testing.allocator, accepted).?.url_len);
    const rejected = std.fmt.bufPrint(&json, "{{\"url\":\"{s}\"}}", .{&url}) catch unreachable;
    try std.testing.expect(parseResolve(std.testing.allocator, rejected) == null);
    try std.testing.expect(parseResolve(std.testing.allocator, "{\"url\":\"https://x/a\",\"headers\":{\"Referer\":\"a\\r\\nHost: evil\"}}") == null);
    try std.testing.expect(parseResolve(std.testing.allocator, "{\"url\":\"file:///secret\"}") == null);
}

test "malformed rows and invalid hashes never masquerade as direct streams" {
    var out: [3]Source = undefined;
    const json = "{\"streams\":[{\"externalUrl\":\"https://page.test/\"},{\"infoHash\":\"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\"},{\"url\":\"https://media.test/good\"}]}";
    try std.testing.expectEqual(@as(usize, 1), parseStreams(std.testing.allocator, json, &out).?);
    try std.testing.expect(parseStreams(std.testing.allocator, "{\"streams\":{}}", &out) == null);
    try std.testing.expect(parseResolve(std.testing.allocator, "{\"url\":\"https:///missing-host\"}") == null);
    try std.testing.expect(parseResolve(std.testing.allocator, "{\"url\":\"https://media.test/a\",\"headers\":{\"Origin\":\"https://a,Host: b\"}}") == null);
}

/// Equal media URLs are interchangeable only with the same HTTP identity.
pub fn sameIdentity(a: *const Source, b: *const Source) bool {
    return std.mem.eql(u8, a.user_agent[0..a.user_agent_len], b.user_agent[0..b.user_agent_len]) and
        std.mem.eql(u8, a.header_fields[0..a.header_fields_len], b.header_fields[0..b.header_fields_len]);
}
test "dedup keeps different provider HTTP identities separate" {
    const plain = parseResolve(std.testing.allocator, "{\"url\":\"https://cdn.test/a\"}").?;
    const protected = parseResolve(std.testing.allocator, "{\"url\":\"https://cdn.test/a\",\"referer\":\"https://player.test/\"}").?;
    try std.testing.expect(!sameIdentity(&plain, &protected));
    try std.testing.expect(sameIdentity(&protected, &protected));
}
