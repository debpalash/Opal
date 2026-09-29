//! Bounded HTML primitives shared by installed reading-source adapters.
const std = @import("std");

pub fn attr(tag: []const u8, name: []const u8) ?[]const u8 {
    var p: usize = 0;
    while (std.mem.indexOfPos(u8, tag, p, name)) |at| {
        p = at + name.len;
        if (at > 0 and (std.ascii.isAlphanumeric(tag[at - 1]) or tag[at - 1] == '-' or tag[at - 1] == '_')) continue;
        var i = p;
        while (i < tag.len and std.ascii.isWhitespace(tag[i])) : (i += 1) {}
        if (i >= tag.len or tag[i] != '=') continue;
        i += 1;
        while (i < tag.len and std.ascii.isWhitespace(tag[i])) : (i += 1) {}
        if (i >= tag.len or (tag[i] != '"' and tag[i] != '\'')) continue;
        const q = tag[i];
        i += 1;
        const end = std.mem.indexOfScalarPos(u8, tag, i, q) orelse return null;
        return tag[i..end];
    }
    return null;
}

pub const Anchor = struct { url: []const u8, title: []const u8, cover: []const u8 = "" };
pub const AnchorIter = struct {
    html: []const u8,
    path: []const u8,
    pos: usize = 0,

    pub fn next(self: *AnchorIter) ?Anchor {
        while (std.mem.indexOfScalarPos(u8, self.html, self.pos, '<')) |start| {
            const end = std.mem.indexOfScalarPos(u8, self.html, start, '>') orelse return null;
            self.pos = end + 1;
            const tag = self.html[start .. end + 1];
            // Script/style literals are not document links.
            if (std.mem.startsWith(u8, tag, "<script") or std.mem.startsWith(u8, tag, "<style")) {
                const close = if (std.mem.startsWith(u8, tag, "<script")) "</script>" else "</style>";
                self.pos = if (std.mem.indexOfPos(u8, self.html, self.pos, close)) |p| p + close.len else self.html.len;
                continue;
            }
            if (tag.len < 3 or tag[1] != 'a' or !std.ascii.isWhitespace(tag[2])) continue;
            const close = std.mem.indexOfPos(u8, self.html, self.pos, "</a>") orelse continue;
            const body = self.html[self.pos..close];
            self.pos = close + 4;
            const url = attr(tag, "href") orelse continue;
            if (std.mem.indexOf(u8, url, self.path) == null) continue;
            var title = attr(tag, "title") orelse body;
            var cover: []const u8 = "";
            if (std.mem.indexOf(u8, body, "<img")) |im| {
                const ig = std.mem.indexOfScalarPos(u8, body, im, '>') orelse continue;
                const image = body[im .. ig + 1];
                cover = attr(image, "data-src") orelse attr(image, "src") orelse "";
                if (attr(image, "alt")) |alt| {
                    if (alt.len > 0 and attr(tag, "title") == null) title = alt;
                }
            }
            return .{ .url = url, .title = title, .cover = cover };
        }
        return null;
    }
};

/// Keep remote URLs inside the configured source; relative routes are resolved
/// against it. Prevent lookalike hosts and non-network schemes entering readers.
pub fn sourceUrl(out: []u8, base: []const u8, raw: []const u8) ?[]const u8 {
    const b = std.mem.trimEnd(u8, base, "/");
    if (!(std.mem.startsWith(u8, b, "https://") or std.mem.startsWith(u8, b, "http://"))) return null;
    if (raw.len == 0 or std.mem.indexOfAny(u8, raw, "\r\n") != null) return null;
    if (std.mem.startsWith(u8, raw, b) and raw.len > b.len and (raw[b.len] == '/' or raw[b.len] == '?')) {
        return std.fmt.bufPrint(out, "{s}", .{raw}) catch null;
    }
    if (raw[0] == '/' and !std.mem.startsWith(u8, raw, "//")) return std.fmt.bufPrint(out, "{s}{s}", .{ b, raw }) catch null;
    return null;
}

test "reading links skip script literals and accept spaced single quoted attributes" {
    var it = AnchorIter{ .html = "<script>var x='<a href=\"/book/fake\">fake</a>';</script><a href = '/book/real' title='Real &amp; Good'><img data-src='/cover.jpg'></a>", .path = "/book/" };
    const item = it.next().?;
    try std.testing.expectEqualStrings("/book/real", item.url);
    try std.testing.expectEqualStrings("Real &amp; Good", item.title);
    try std.testing.expectEqualStrings("/cover.jpg", item.cover);
    try std.testing.expect(it.next() == null);
}

test "reading source URL rejects lookalike and external hosts" {
    var out: [128]u8 = undefined;
    try std.testing.expectEqualStrings("https://source.test/book/1", sourceUrl(&out, "https://source.test/", "/book/1").?);
    try std.testing.expect(sourceUrl(&out, "https://source.test", "https://source.test.bad/book/1") == null);
    try std.testing.expect(sourceUrl(&out, "https://source.test", "//bad.test/book/1") == null);
}
