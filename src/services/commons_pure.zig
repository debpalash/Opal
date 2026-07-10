//! Pure Wikimedia-Commons JSON parsing — no I/O, no allocator, fully testable.
//!
//! Feeds the resolver's Commons worker from a single MediaWiki API response:
//!
//!   action=query&generator=search&prop=imageinfo&iiprop=url|size|mime&format=json
//!
//! yields `query.pages{}` — an OBJECT keyed by pageid, one entry per matching
//! File: page. Each page carries `title` (a "File:…" name) plus an
//! `imageinfo[0]` object holding the direct upload.wikimedia.org `url` (a
//! mpv-native .webm/.ogv), `size`, `mime`, and occasionally `duration`.
//!
//! `PageIter` walks the pages by anchoring on each `"imageinfo"` key and taking
//! the nearest enclosing `{` as the page object (page fields before imageinfo —
//! pageid/ns/title — are all scalars, so that brace is unambiguously the page
//! open). Shared JSON field extraction (objEnd/stringField/scalarField) is
//! reused from archive_pure.zig. All scanning tolerates truncated/garbage input
//! (see the malformed-JSON regression test).

const std = @import("std");
const ap = @import("archive_pure.zig");

pub const Page = struct {
    title: []const u8, // "File:" prefix already stripped — may be empty
    url: []const u8, // imageinfo[0].url (direct upload.wikimedia.org file)
    mime: []const u8, // imageinfo[0].mime — may be empty
    size: []const u8, // imageinfo[0].size digits — may be empty
    duration: []const u8, // imageinfo[0].duration (only if the API returned it)
};

/// Iterates `query.pages{}` value objects, one Page per File: result. Anchors
/// on `"imageinfo"` so a page with no imageinfo (deleted/blocked file) is
/// skipped. Order follows the JSON's page order.
pub const PageIter = struct {
    json: []const u8,
    pos: usize,

    pub fn next(self: *PageIter) ?Page {
        while (std.mem.indexOfPos(u8, self.json, self.pos, "\"imageinfo\"")) |ki| {
            // Nearest '{' before "imageinfo" is the page object open: the only
            // fields ahead of imageinfo (pageid/ns/title/imagerepository) are
            // scalars, so no nested brace intervenes.
            const obj_start = std.mem.lastIndexOfScalar(u8, self.json[0..ki], '{') orelse {
                self.pos = ki + "\"imageinfo\"".len;
                continue;
            };
            const obj_e = ap.objEnd(self.json, obj_start);
            const block = self.json[obj_start..obj_e];
            self.pos = if (obj_e > self.pos) obj_e else ki + "\"imageinfo\"".len;

            const url = ap.stringField(block, "url") orelse continue;
            if (url.len == 0) continue;

            var title = ap.stringField(block, "title") orelse "";
            title = stripFilePrefix(title);

            return .{
                .title = title,
                .url = url,
                .mime = ap.stringField(block, "mime") orelse "",
                .size = ap.scalarField(block, "size") orelse "",
                .duration = ap.scalarField(block, "duration") orelse "",
            };
        }
        return null;
    }
};

/// Build a PageIter positioned at `query.pages{` (or 0 if the marker is absent —
/// imageinfo only appears inside pages, so scanning is still safe).
pub fn iteratePages(json: []const u8) PageIter {
    const start = if (std.mem.indexOf(u8, json, "\"pages\"")) |d| d else 0;
    return .{ .json = json, .pos = start };
}

/// Drop a leading "File:" (or localized-namespace-free) prefix from a Commons
/// page title so the surfaced name reads "Foo.webm" not "File:Foo.webm".
pub fn stripFilePrefix(title: []const u8) []const u8 {
    if (title.len >= 5 and std.ascii.eqlIgnoreCase(title[0..5], "file:")) return title[5..];
    return title;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const sample =
    \\{"batchcomplete":"","query":{"pages":{
    \\  "42":{"pageid":42,"ns":6,"title":"File:Earth rotation.webm","imagerepository":"local",
    \\        "imageinfo":[{"url":"https://upload.wikimedia.org/wikipedia/commons/a/ab/Earth_rotation.webm",
    \\                      "descriptionurl":"https://commons.wikimedia.org/wiki/File:Earth_rotation.webm",
    \\                      "size":12345678,"width":1920,"height":1080,"mime":"video/webm"}]},
    \\  "77":{"pageid":77,"ns":6,"title":"File:Moon phases.ogv",
    \\        "imageinfo":[{"url":"https://upload.wikimedia.org/wikipedia/commons/c/cd/Moon_phases.ogv",
    \\                      "size":98765,"mime":"video/ogg","duration":42.5}]}
    \\}}}
;

test "PageIter extracts title(url/mime/size), File: prefix stripped" {
    var it = iteratePages(sample);
    const a = it.next().?;
    try std.testing.expectEqualStrings("Earth rotation.webm", a.title);
    try std.testing.expectEqualStrings("https://upload.wikimedia.org/wikipedia/commons/a/ab/Earth_rotation.webm", a.url);
    try std.testing.expectEqualStrings("video/webm", a.mime);
    try std.testing.expectEqualStrings("12345678", a.size);
    try std.testing.expectEqualStrings("", a.duration);

    const b = it.next().?;
    try std.testing.expectEqualStrings("Moon phases.ogv", b.title);
    try std.testing.expectEqualStrings("https://upload.wikimedia.org/wikipedia/commons/c/cd/Moon_phases.ogv", b.url);
    try std.testing.expectEqualStrings("video/ogg", b.mime);
    try std.testing.expectEqualStrings("42.5", b.duration);

    try std.testing.expect(it.next() == null);
}

test "url key not confused by descriptionurl" {
    const one =
        "{\"query\":{\"pages\":{\"1\":{\"title\":\"File:X.webm\",\"imageinfo\":[{" ++
        "\"descriptionurl\":\"https://desc/wrong\",\"url\":\"https://right/X.webm\",\"mime\":\"video/webm\"}]}}}}";
    var it = iteratePages(one);
    const p = it.next().?;
    try std.testing.expectEqualStrings("https://right/X.webm", p.url);
}

test "stripFilePrefix is case-insensitive and leaves non-File titles" {
    try std.testing.expectEqualStrings("A.webm", stripFilePrefix("File:A.webm"));
    try std.testing.expectEqualStrings("A.webm", stripFilePrefix("file:A.webm"));
    try std.testing.expectEqualStrings("Nofile.webm", stripFilePrefix("Nofile.webm"));
}

test "pages with no imageinfo are skipped" {
    const gap =
        "{\"query\":{\"pages\":{" ++
        "\"1\":{\"title\":\"File:Deleted.webm\"}," ++ // no imageinfo — skipped
        "\"2\":{\"title\":\"File:Live.webm\",\"imageinfo\":[{\"url\":\"https://u/Live.webm\"}]}}}}";
    var it = iteratePages(gap);
    const p = it.next().?;
    try std.testing.expectEqualStrings("Live.webm", p.title);
    try std.testing.expectEqualStrings("https://u/Live.webm", p.url);
    try std.testing.expect(it.next() == null);
}

test "malformed JSON regression: no crash, terminates" {
    const cases = [_][]const u8{
        "",
        "{",
        "{\"query\":{\"pages\":{",
        "{\"query\":{\"pages\":{\"1\":{\"title\":\"File:trunc", // unterminated value
        "{\"pages\":{\"1\":{\"imageinfo\":[{\"url\":\"https://u/x.webm\"", // no closing braces
        "<<<not json>>>",
        "{\"imageinfo\":}",
    };
    for (cases) |cse| {
        var it = iteratePages(cse);
        while (it.next()) |_| {} // must terminate, never panic
    }
    // A truncated page still yields its one recoverable url then stops.
    var it2 = iteratePages("{\"pages\":{\"1\":{\"title\":\"File:Ok.webm\",\"imageinfo\":[{\"url\":\"https://u/Ok.webm\"}]}");
    const d = it2.next();
    try std.testing.expect(d != null);
    try std.testing.expectEqualStrings("https://u/Ok.webm", d.?.url);
    try std.testing.expect(it2.next() == null);
}
