//! Jackett API configuration and configured-indexer catalog. No I/O.
const std = @import("std");
pub const MAX_INDEXERS = 64;
pub const Indexer = struct {
    id: [64]u8 = @splat(0),
    id_len: usize = 0,
    name: [128]u8 = @splat(0),
    name_len: usize = 0,
    public: bool = false,
    pub fn idSlice(self: *const Indexer) []const u8 {
        return self.id[0..self.id_len];
    }
    pub fn nameSlice(self: *const Indexer) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub fn validBase(base: []const u8) bool {
    if (base.len == 0 or base.len > 511 or std.mem.indexOfAny(u8, base, " \t\r\n?#\\") != null) return false;
    const uri = std.Uri.parse(base) catch return false;
    return (std.mem.eql(u8, uri.scheme, "http") or std.mem.eql(u8, uri.scheme, "https")) and
        uri.host != null and uri.host.?.percent_encoded.len > 0 and uri.user == null and uri.password == null;
}

pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    return true;
}

/// Uses Jackett's documented Torznab API (dashboard APIs require cookies).
/// Credentials remain private
/// in the request's stdin config, never in curl argv.
pub fn catalogUrl(base: []const u8, key: []const u8, out: []u8) ?[]const u8 {
    if (!validBase(base) or key.len == 0 or key.len > 511 or std.mem.eql(u8, key, "YOUR_API_KEY_HERE")) return null;
    var w = std.Io.Writer.fixed(out);
    w.print("{s}/api/v2.0/indexers/all/results/torznab/api?t=indexers&configured=true&apikey=", .{std.mem.trimEnd(u8, base, "/")}) catch return null;
    const hex = "0123456789ABCDEF";
    for (key) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            w.writeByte(c) catch return null;
        } else {
            w.writeAll(&.{ '%', hex[c >> 4], hex[c & 15] }) catch return null;
        }
    }
    return out[0..w.end];
}

pub fn parseCatalog(allocator: std.mem.Allocator, body: []const u8, out: []Indexer) !usize {
    _ = allocator;
    const tags = @import("torznab_pure.zig");
    const attrs = @import("content_html_pure.zig");
    var xml = std.mem.trim(u8, body, " \r\n\t");
    if (std.mem.startsWith(u8, xml, "<?xml")) {
        const end = std.mem.indexOf(u8, xml, "?>") orelse return error.SyntaxError;
        xml = std.mem.trimStart(u8, xml[end + 2 ..], " \r\n\t");
    }
    if (std.mem.eql(u8, xml, "<indexers />") or std.mem.eql(u8, xml, "<indexers/>")) return 0;
    if (!std.mem.startsWith(u8, xml, "<indexers>") or !std.mem.endsWith(u8, xml, "</indexers>")) return error.SyntaxError;
    var pos: usize = "<indexers>".len;
    var count: usize = 0;
    while (std.mem.indexOfPos(u8, xml, pos, "<indexer ")) |start| {
        const end_tag = std.mem.indexOfScalarPos(u8, xml, start, '>') orelse return error.SyntaxError;
        const end = std.mem.indexOfPos(u8, xml, end_tag, "</indexer>") orelse return error.SyntaxError;
        pos = end + "</indexer>".len;
        const tag = xml[start .. end_tag + 1];
        const content = xml[end_tag + 1 .. end];
        const id = attrs.attr(tag, "id") orelse continue;
        if (!validId(id) or !std.ascii.eqlIgnoreCase(attrs.attr(tag, "configured") orelse "true", "true")) continue;
        var duplicate = false;
        for (out[0..count]) |*prior| if (std.mem.eql(u8, prior.idSlice(), id)) {
            duplicate = true;
            break;
        };
        if (duplicate) continue;
        if (count == out.len) return error.TooManyIndexers;
        out[count] = .{};
        var item = &out[count];
        item.id_len = id.len;
        @memcpy(item.id[0..item.id_len], id);
        const name = tags.extractTag(content, "<title>", "</title>") orelse id;
        item.name_len = @import("opds_pure.zig").decodeXmlEntities(name, &item.name);
        while (item.name_len > 0 and !std.unicode.utf8ValidateSlice(item.name[0..item.name_len])) item.name_len -= 1;
        item.public = std.ascii.eqlIgnoreCase(tags.extractTag(content, "<type>", "</type>") orelse "", "public");
        count += 1;
    }
    return count;
}

pub fn selected(csv: []const u8, id: []const u8) bool {
    if (std.mem.eql(u8, csv, "*")) return true;
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |part| if (std.mem.eql(u8, part, id)) return true;
    return false;
}

test "Jackett URL preserves reverse proxy prefix and encodes API key" {
    var out: [2200]u8 = undefined;
    try std.testing.expectEqualStrings("https://server.test/jackett/api/v2.0/indexers/all/results/torznab/api?t=indexers&configured=true&apikey=a%26b%23c", catalogUrl("https://server.test/jackett/", "a&b#c", &out).?);
    for ([_][]const u8{ "file:///tmp/a", "https://user:pass@a.test", "https://a.test?key=x", "http:///", "http://a.test/#x" }) |base| try std.testing.expect(catalogUrl(base, "secret", &out) == null);
    try std.testing.expect(catalogUrl("http://localhost:9117", "YOUR_API_KEY_HERE", &out) == null);
}

test "Jackett catalog keeps private sources visible and rejects invalid catalogs" {
    var out: [4]Indexer = undefined;
    const xml = "<?xml version=\"1.0\"?><indexers><indexer id=\"nyaasi\" configured=\"true\"><title>Nyaa &amp; anime</title><type>public</type></indexer><indexer id=\"torrentleech\" configured=\"true\"><title>TorrentLeech</title><type>private</type></indexer><indexer id=\"off\" configured=\"false\"><type>public</type></indexer></indexers>";
    try std.testing.expectEqual(@as(usize, 2), try parseCatalog(std.testing.allocator, xml, &out));
    try std.testing.expect(out[0].public and !out[1].public);
    try std.testing.expectEqualStrings("Nyaa & anime", out[0].nameSlice());
    try std.testing.expectError(error.TooManyIndexers, parseCatalog(std.testing.allocator, xml, out[0..1]));
    try std.testing.expectError(error.SyntaxError, parseCatalog(std.testing.allocator, "<html>login</html>", &out));
    try std.testing.expect(selected("*", "nyaasi") and selected("a,nyaasi", "nyaasi"));
    try std.testing.expect(!selected("", "nyaasi") and !selected("nyaasi-extra", "nyaasi"));
}
