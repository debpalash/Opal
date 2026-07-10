//! Pure Internet-Archive JSON parsing — no I/O, no allocator, fully testable.
//!
//! Two IA endpoints feed the resolver's Archive worker and BOTH are parsed
//! here so the tested logic is the shipped logic (CLAUDE.md *_pure discipline):
//!
//!   1. advancedsearch.php  → `response.docs[]` each `{identifier,title,year}`.
//!      `DocIter` walks the docs array order-independently (fields may appear
//!      in any order inside an object).
//!   2. metadata/{id}       → `files[]` each `{name,format,size,...}`. We pick
//!      the largest directly-playable video file so mpv gets a real stream URL
//!      (`pickBestVideoFile`) rather than guessing `{id}.mp4` (which 404s on
//!      most items).
//!
//! All extraction is byte-scanning tolerant of truncated/garbage input: every
//! function returns null / 0 rather than panicking (see the malformed-JSON
//! regression test).

const std = @import("std");

// ── Low-level JSON field extraction ──────────────────────────────────────────

/// Read the end index of a brace-balanced object that begins at `data[start]`
/// (which must be '{'). Returns an index one past the closing '}', or data.len
/// if unbalanced. String contents are skipped so a '{' inside a value can't
/// throw off the depth count.
pub fn objEnd(data: []const u8, start: usize) usize {
    if (start >= data.len or data[start] != '{') return data.len;
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
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth <= 0) return i + 1;
            },
            else => {},
        }
    }
    return data.len;
}

/// Value of a JSON string field `"key": <value>` inside `block`. Tolerates an
/// optional leading `[` so an array-valued field (`"title":["a","b"]`) yields
/// its first string element. Stops at the first unescaped quote. Null if the
/// key is absent or its value is not a string. The returned slice still carries
/// JSON escapes (\" \\ …) — decode at the call site if needed.
pub fn stringField(block: []const u8, key: []const u8) ?[]const u8 {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, block, search_from, key)) |ki| {
        // Require the key to be a real `"key"` token (quote before, quote after)
        // so "year" can't match inside "yearx" and "title" can't match a
        // substring of some other field.
        const before_ok = ki > 0 and block[ki - 1] == '"';
        const after = ki + key.len;
        const after_ok = after < block.len and block[after] == '"';
        if (!before_ok or !after_ok) {
            search_from = ki + key.len;
            continue;
        }
        var p = after + 1; // past closing quote of the key
        // skip `:` and whitespace and an optional array-open bracket
        while (p < block.len and (block[p] == ':' or block[p] == ' ' or
            block[p] == '\t' or block[p] == '\n' or block[p] == '\r' or block[p] == '['))
            p += 1;
        if (p >= block.len or block[p] != '"') return null; // not a string value
        p += 1;
        const vstart = p;
        var esc = false;
        while (p < block.len) : (p += 1) {
            if (esc) {
                esc = false;
                continue;
            }
            if (block[p] == '\\') {
                esc = true;
                continue;
            }
            if (block[p] == '"') return block[vstart..p];
        }
        return null; // unterminated value quote
    }
    return null;
}

/// Value of a JSON field that may be a string OR a bare number:
/// `"year":"1968"` or `"year":1968`. Returns the digit/text run. Null if absent.
pub fn scalarField(block: []const u8, key: []const u8) ?[]const u8 {
    if (stringField(block, key)) |s| return s;
    // Number form.
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, block, search_from, key)) |ki| {
        const before_ok = ki > 0 and block[ki - 1] == '"';
        const after = ki + key.len;
        const after_ok = after < block.len and block[after] == '"';
        if (!before_ok or !after_ok) {
            search_from = ki + key.len;
            continue;
        }
        var p = after + 1;
        while (p < block.len and (block[p] == ':' or block[p] == ' ' or
            block[p] == '\t' or block[p] == '\n' or block[p] == '\r'))
            p += 1;
        const nstart = p;
        while (p < block.len and (std.ascii.isDigit(block[p]) or block[p] == '.' or block[p] == '-'))
            p += 1;
        if (p > nstart) return block[nstart..p];
        return null;
    }
    return null;
}

// ── advancedsearch.php: docs[] iteration ─────────────────────────────────────

pub const Doc = struct {
    identifier: []const u8,
    title: []const u8, // may be empty
    year: []const u8, // may be empty
};

/// Iterates the `response.docs[]` array of an advancedsearch.php JSON response,
/// yielding one Doc per object. Order-independent within an object. Starts at
/// the `"docs":[` marker so header fields can't be mistaken for docs.
pub const DocIter = struct {
    json: []const u8,
    pos: usize,

    pub fn next(self: *DocIter) ?Doc {
        while (std.mem.indexOfPos(u8, self.json, self.pos, "\"identifier\"")) |ki| {
            // Object bounds: the '{' opening this doc is the last '{' before the
            // identifier key; docs objects are flat so this is unambiguous.
            const obj_start = std.mem.lastIndexOfScalar(u8, self.json[0..ki], '{') orelse {
                self.pos = ki + 12;
                continue;
            };
            const obj_e = objEnd(self.json, obj_start);
            const block = self.json[obj_start..obj_e];
            self.pos = if (obj_e > self.pos) obj_e else ki + 12;

            const id = stringField(block, "identifier") orelse continue;
            if (id.len == 0) continue;
            return .{
                .identifier = id,
                .title = stringField(block, "title") orelse "",
                .year = scalarField(block, "year") orelse "",
            };
        }
        return null;
    }
};

/// Build a DocIter positioned at the docs array (or at 0 if the marker is
/// missing — identifiers only appear inside docs, so scanning is still safe).
pub fn iterateDocs(json: []const u8) DocIter {
    const start = if (std.mem.indexOf(u8, json, "\"docs\"")) |d| d else 0;
    return .{ .json = json, .pos = start };
}

// ── metadata/{id}: pick the best playable file ───────────────────────────────

const video_exts = [_][]const u8{
    ".mp4", ".m4v", ".ogv", ".webm", ".mkv", ".mov", ".avi", ".mpeg", ".mpg",
};

fn isVideoName(name: []const u8) bool {
    if (name.len == 0 or name.len > 512) return false;
    var lower: [512]u8 = undefined;
    for (0..name.len) |i| lower[i] = std.ascii.toLower(name[i]);
    const l = lower[0..name.len];
    for (video_exts) |ext| if (std.mem.endsWith(u8, l, ext)) return true;
    return false;
}

fn isMp4Name(name: []const u8) bool {
    if (name.len < 4) return false;
    var lower: [512]u8 = undefined;
    if (name.len > lower.len) return false;
    for (0..name.len) |i| lower[i] = std.ascii.toLower(name[i]);
    const l = lower[0..name.len];
    return std.mem.endsWith(u8, l, ".mp4") or std.mem.endsWith(u8, l, ".m4v");
}

/// Choose the file name of the largest directly-playable video in a
/// metadata/{id} JSON response. Prefers .mp4/.m4v (widest mpv/HTTP
/// compatibility, and IA's derivative streams are h.264 mp4); falls back to the
/// largest other video container. Returns the raw `name` (NOT url-encoded — the
/// caller percent-encodes the path segment). Null when no video file is listed.
pub fn pickBestVideoFile(json: []const u8) ?[]const u8 {
    // Constrain scanning to the "files" array when present.
    const files_key = std.mem.indexOf(u8, json, "\"files\"");
    var pos: usize = files_key orelse 0;

    var best_mp4: ?[]const u8 = null;
    var best_mp4_size: u64 = 0;
    var best_other: ?[]const u8 = null;
    var best_other_size: u64 = 0;

    while (std.mem.indexOfPos(u8, json, pos, "\"name\"")) |ki| {
        const obj_start = std.mem.lastIndexOfScalar(u8, json[0..ki], '{') orelse {
            pos = ki + 6;
            continue;
        };
        const obj_e = objEnd(json, obj_start);
        const block = json[obj_start..obj_e];
        pos = if (obj_e > pos) obj_e else ki + 6;

        const name = stringField(block, "name") orelse continue;
        if (!isVideoName(name)) continue;

        const size: u64 = if (scalarField(block, "size")) |s|
            (std.fmt.parseInt(u64, std.mem.trim(u8, s, " \t\r\n"), 10) catch 0)
        else
            0;

        if (isMp4Name(name)) {
            if (best_mp4 == null or size > best_mp4_size) {
                best_mp4 = name;
                best_mp4_size = size;
            }
        } else {
            if (best_other == null or size > best_other_size) {
                best_other = name;
                best_other_size = size;
            }
        }
    }
    return best_mp4 orelse best_other;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const sample_search =
    \\{"responseHeader":{"status":0,"params":{"identifier":"ignored-header"}},
    \\ "response":{"numFound":2,"start":0,"docs":[
    \\   {"identifier":"night_of_the_living_dead","title":"Night of the Living Dead","year":"1968"},
    \\   {"title":"Plan 9 from Outer Space","year":1959,"identifier":"Plan9FromOuterSpace"}
    \\ ]}}
;

test "DocIter extracts identifier/title/year (order-independent, header ignored)" {
    var it = iterateDocs(sample_search);
    const a = it.next().?;
    try std.testing.expectEqualStrings("night_of_the_living_dead", a.identifier);
    try std.testing.expectEqualStrings("Night of the Living Dead", a.title);
    try std.testing.expectEqualStrings("1968", a.year);

    // Second doc lists fields in a different order and a NUMERIC year.
    const b = it.next().?;
    try std.testing.expectEqualStrings("Plan9FromOuterSpace", b.identifier);
    try std.testing.expectEqualStrings("Plan 9 from Outer Space", b.title);
    try std.testing.expectEqualStrings("1959", b.year);

    // Only two docs — the header "identifier" must NOT be yielded.
    try std.testing.expect(it.next() == null);
}

test "stringField requires a whole-key token" {
    const block = "{\"posteryear\":\"x\",\"year\":\"1970\"}";
    try std.testing.expectEqualStrings("1970", stringField(block, "year").?);
    // A key that only appears as a substring must not match.
    try std.testing.expect(stringField("{\"years_active\":\"12\"}", "year") == null);
}

const sample_metadata =
    \\{"server":"ia800","metadata":{"identifier":"x"},"files":[
    \\  {"name":"x.thumbs/frame.jpg","format":"JPEG","size":"1000"},
    \\  {"name":"x_512kb.mp4","format":"h.264","size":"52428800"},
    \\  {"name":"x.ogv","format":"Ogg Video","size":"104857600"},
    \\  {"name":"x.mp4","format":"h.264 HD","size":"734003200"},
    \\  {"name":"x_meta.xml","format":"Metadata","size":"900"}
    \\]}
;

test "pickBestVideoFile prefers the largest mp4 over a bigger non-mp4" {
    // The .ogv (100MB) is larger than the small mp4 but the LARGE mp4 (700MB)
    // must win — mp4 tier preferred, largest within tier.
    const f = pickBestVideoFile(sample_metadata).?;
    try std.testing.expectEqualStrings("x.mp4", f);
}

test "pickBestVideoFile falls back to non-mp4 video when no mp4 exists" {
    const only_ogv =
        "{\"files\":[{\"name\":\"a.jpg\",\"size\":\"5\"}," ++
        "{\"name\":\"movie.ogv\",\"size\":\"200\"}," ++
        "{\"name\":\"movie.webm\",\"size\":\"500\"}]}";
    try std.testing.expectEqualStrings("movie.webm", pickBestVideoFile(only_ogv).?);
}

test "pickBestVideoFile returns null when no playable video is present" {
    const none = "{\"files\":[{\"name\":\"a.jpg\",\"size\":\"5\"},{\"name\":\"b.txt\",\"size\":\"9\"}]}";
    try std.testing.expect(pickBestVideoFile(none) == null);
}

test "malformed JSON regression: no crash, null/empty results" {
    const cases = [_][]const u8{
        "",
        "{",
        "{\"response\":{\"docs\":[",
        "{\"docs\":[{\"identifier\":\"trunc", // unterminated value
        "{\"docs\":[{\"identifier\":\"ok\"", // no closing brace/bracket
        "{\"files\":[{\"name\":\"x.mp4\",\"size\":\"12", // unterminated size
        "<<<not json>>>",
        "{\"identifier\":}", // key with no value
    };
    for (cases) |cse| {
        var it = iterateDocs(cse);
        while (it.next()) |_| {} // must terminate, never panic
        _ = pickBestVideoFile(cse);
        _ = stringField(cse, "title");
        _ = scalarField(cse, "year");
    }
    // A truncated docs array yields the one recoverable identifier and then stops.
    var it2 = iterateDocs("{\"docs\":[{\"identifier\":\"ok\",\"title\":\"T\"}");
    const d = it2.next();
    try std.testing.expect(d != null);
    try std.testing.expectEqualStrings("ok", d.?.identifier);
    try std.testing.expect(it2.next() == null);
}
