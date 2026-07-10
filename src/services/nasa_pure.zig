//! Pure NASA Images-API JSON parsing — no I/O, no allocator, fully testable.
//!
//! Two NASA endpoints feed the resolver's NASA worker and BOTH are parsed here
//! so the tested logic is the shipped logic (CLAUDE.md *_pure discipline):
//!
//!   1. images-api.nasa.gov/search → `collection.items[]`, each object carries a
//!      top-level `href` (a per-asset collection.json) plus a nested
//!      `data[0].title` / `data[0].date_created`. `SearchIter` walks the items
//!      array only (pagination `links` / `metadata` are excluded via a
//!      bracket-balanced bound) and yields one Hit per asset.
//!   2. the per-asset collection.json → a bare JSON array of file URL strings.
//!      `pickBestMp4` chooses the best playable .mp4 (prefer ~orig, then the
//!      largest-resolution variant) so mpv gets a real stream URL.
//!
//! Shared low-level JSON field extraction (objEnd/stringField/scalarField) is
//! reused from archive_pure.zig — both are pure (std-only) so the standalone
//! `zig test` on this file compiles that sibling too. All scanning tolerates
//! truncated/garbage input: every function returns null rather than panicking
//! (see the malformed-JSON regression test).

const std = @import("std");
const ap = @import("archive_pure.zig");

// ── search: items[] iteration ────────────────────────────────────────────────

pub const Hit = struct {
    /// Per-asset collection.json URL (the item's first, top-level `href`).
    href: []const u8,
    title: []const u8, // data[0].title — may be empty
    year: []const u8, // first 4 chars of data[0].date_created — may be empty
};

/// End index (one past ']') of a bracket-balanced array starting at
/// `data[start]` (which must be '['). String contents are skipped so a bracket
/// inside a value can't throw off the depth count. data.len if unbalanced.
fn arrayEnd(data: []const u8, start: usize) usize {
    if (start >= data.len or data[start] != '[') return data.len;
    var depth: i32 = 0;
    var i = start;
    var in_str = false;
    var esc = false;
    while (i < data.len) : (i += 1) {
        const ch = data[i];
        if (in_str) {
            if (esc) {
                esc = false;
            } else if (ch == '\\') {
                esc = true;
            } else if (ch == '"') {
                in_str = false;
            }
            continue;
        }
        switch (ch) {
            '"' => in_str = true,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth <= 0) return i + 1;
            },
            else => {},
        }
    }
    return data.len;
}

/// Iterates `collection.items[]`, one Hit per asset object. Bounded to the
/// items array so the response's pagination `links[]` (which also carry `href`)
/// and trailing `metadata` are never mistaken for assets.
pub const SearchIter = struct {
    json: []const u8,
    pos: usize,
    end: usize, // exclusive upper bound (just before items' closing ']')

    pub fn next(self: *SearchIter) ?Hit {
        while (self.pos < self.end) {
            const open = std.mem.indexOfScalarPos(u8, self.json[0..self.end], self.pos, '{') orelse return null;
            const obj_e = ap.objEnd(self.json, open);
            const block_end = @min(obj_e, self.end);
            const block = self.json[open..block_end];
            self.pos = if (obj_e > self.pos) obj_e else open + 1;

            // The item's own href is serialized first (before data[]/links[]),
            // so stringField's first-hit yields the collection.json URL.
            const href = ap.stringField(block, "href") orelse continue;
            if (href.len == 0) continue;
            if (!std.mem.startsWith(u8, href, "http")) continue;

            var year: []const u8 = "";
            if (ap.stringField(block, "date_created")) |dc| {
                if (dc.len >= 4 and isAllDigits(dc[0..4])) year = dc[0..4];
            }
            return .{
                .href = href,
                .title = ap.stringField(block, "title") orelse "",
                .year = year,
            };
        }
        return null;
    }
};

fn isAllDigits(s: []const u8) bool {
    for (s) |ch| if (!std.ascii.isDigit(ch)) return false;
    return s.len > 0;
}

/// Build a SearchIter positioned at `collection.items[`. If the marker is
/// missing the iterator is empty (assets only live inside items).
pub fn iterateItems(json: []const u8) SearchIter {
    if (std.mem.indexOf(u8, json, "\"items\"")) |ik| {
        var p = ik + "\"items\"".len;
        while (p < json.len and json[p] != '[') : (p += 1) {}
        if (p < json.len) {
            const e = arrayEnd(json, p);
            // end just before the closing ']' so a trailing top-level '{' after
            // the array can't be scanned as an item.
            const end = if (e > 0 and e <= json.len) e - 1 else json.len;
            return .{ .json = json, .pos = p + 1, .end = end };
        }
    }
    return .{ .json = json, .pos = json.len, .end = json.len };
}

// ── collection.json: pick the best playable .mp4 ─────────────────────────────

fn endsWithIgnoreCase(s: []const u8, suffix: []const u8) bool {
    if (s.len < suffix.len) return false;
    const tail = s[s.len - suffix.len ..];
    for (tail, suffix) |a, b| if (std.ascii.toLower(a) != b) return false;
    return true;
}

/// Preference rank for a NASA mp4 variant (lower = better). NASA serves fixed
/// suffix tiers; ~orig is the source master, then large→small resolutions.
fn mp4Rank(url: []const u8) u8 {
    if (std.mem.indexOf(u8, url, "~orig") != null) return 0;
    if (std.mem.indexOf(u8, url, "~large") != null) return 1;
    if (std.mem.indexOf(u8, url, "~medium") != null) return 2;
    if (std.mem.indexOf(u8, url, "~mobile") != null) return 3;
    if (std.mem.indexOf(u8, url, "~small") != null) return 4;
    if (std.mem.indexOf(u8, url, "~preview") != null) return 5;
    return 6; // some other .mp4 variant
}

/// Choose the best-quality .mp4 URL from a per-asset collection.json (a bare
/// JSON array of file-URL strings). Prefers ~orig, then the largest-resolution
/// suffix tier; on a tie the first listed wins. Returns the raw URL slice (the
/// caller rewrites http→https). Null when no .mp4 is present.
pub fn pickBestMp4(json: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_rank: u8 = 255;
    var i: usize = 0;
    while (i < json.len) : (i += 1) {
        if (json[i] != '"') continue;
        const s = i + 1;
        var p = s;
        var esc = false;
        while (p < json.len) : (p += 1) {
            if (esc) {
                esc = false;
                continue;
            }
            if (json[p] == '\\') {
                esc = true;
                continue;
            }
            if (json[p] == '"') break;
        }
        if (p >= json.len) break; // unterminated string — stop
        const str = json[s..p];
        i = p; // loop's +1 moves past the closing quote
        if (str.len < 5 or str.len > 2000) continue;
        if (!endsWithIgnoreCase(str, ".mp4")) continue;
        const r = mp4Rank(str);
        if (best == null or r < best_rank) {
            best = str;
            best_rank = r;
        }
    }
    return best;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const sample_search =
    \\{"collection":{"version":"1.0","href":"https://images-api.nasa.gov/search?q=moon",
    \\ "items":[
    \\   {"href":"https://images-assets.nasa.gov/video/apollo11/collection.json",
    \\    "data":[{"center":"HQ","title":"Apollo 11 Landing","nasa_id":"apollo11",
    \\             "date_created":"1969-07-20T00:00:00Z","media_type":"video",
    \\             "description":"has the word title in prose"}],
    \\    "links":[{"href":"https://images-assets.nasa.gov/video/apollo11/apollo11~thumb.jpg","rel":"preview"}]},
    \\   {"href":"https://images-assets.nasa.gov/video/mars/collection.json",
    \\    "data":[{"title":"Mars Flyover","date_created":"2020-01-02T10:00:00Z"}],
    \\    "links":[{"href":"https://images-assets.nasa.gov/video/mars/mars~thumb.jpg","rel":"preview"}]}
    \\ ],
    \\ "links":[{"rel":"next","href":"https://images-api.nasa.gov/search?q=moon&page=2","prompt":"Next"}],
    \\ "metadata":{"total_hits":2}}}
;

test "SearchIter yields asset href/title/year, skips pagination links" {
    var it = iterateItems(sample_search);
    const a = it.next().?;
    try std.testing.expectEqualStrings("https://images-assets.nasa.gov/video/apollo11/collection.json", a.href);
    try std.testing.expectEqualStrings("Apollo 11 Landing", a.title);
    try std.testing.expectEqualStrings("1969", a.year);

    const b = it.next().?;
    try std.testing.expectEqualStrings("https://images-assets.nasa.gov/video/mars/collection.json", b.href);
    try std.testing.expectEqualStrings("Mars Flyover", b.title);
    try std.testing.expectEqualStrings("2020", b.year);

    // Only two assets — the "next"-page link href must NOT be yielded.
    try std.testing.expect(it.next() == null);
}

const sample_collection =
    \\["https://images-assets.nasa.gov/video/apollo11/apollo11~mobile.mp4",
    \\ "https://images-assets.nasa.gov/video/apollo11/apollo11~orig.mp4",
    \\ "http://images-assets.nasa.gov/video/apollo11/apollo11~small.mp4",
    \\ "https://images-assets.nasa.gov/video/apollo11/apollo11.srt",
    \\ "https://images-assets.nasa.gov/video/apollo11/apollo11~thumb.jpg"]
;

test "pickBestMp4 prefers ~orig over lower-res mp4 variants" {
    const f = pickBestMp4(sample_collection).?;
    try std.testing.expectEqualStrings("https://images-assets.nasa.gov/video/apollo11/apollo11~orig.mp4", f);
}

test "pickBestMp4 falls back to best available variant when no ~orig" {
    const no_orig =
        \\["https://x/a~small.mp4","https://x/a~mobile.mp4","https://x/a.srt"]
    ;
    // ~mobile (rank 3) beats ~small (rank 4).
    try std.testing.expectEqualStrings("https://x/a~mobile.mp4", pickBestMp4(no_orig).?);
}

test "pickBestMp4 returns null when no mp4 present" {
    const none = "[\"https://x/a.srt\",\"https://x/a~thumb.jpg\",\"https://x/a.json\"]";
    try std.testing.expect(pickBestMp4(none) == null);
}

test "malformed JSON regression: no crash, null/empty results" {
    const cases = [_][]const u8{
        "",
        "{",
        "{\"collection\":{\"items\":[",
        "{\"items\":[{\"href\":\"http", // unterminated value
        "{\"items\":[{\"href\":\"https://x/collection.json\"", // no closing brace/bracket
        "[\"https://x/a~orig.mp4", // unterminated array/string
        "<<<not json>>>",
        "{\"items\":}",
    };
    for (cases) |cse| {
        var it = iterateItems(cse);
        while (it.next()) |_| {} // must terminate, never panic
        _ = pickBestMp4(cse);
    }
    // A truncated items array still yields the one recoverable asset then stops.
    var it2 = iterateItems("{\"items\":[{\"href\":\"https://x/collection.json\",\"data\":[{\"title\":\"T\"}]}");
    const d = it2.next();
    try std.testing.expect(d != null);
    try std.testing.expectEqualStrings("https://x/collection.json", d.?.href);
    try std.testing.expect(it2.next() == null);
}
