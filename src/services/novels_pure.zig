//! Pure (io-free, state-free) helpers for the light-novel / web-novel reader —
//! unit-testable via `zig build test`.
//!
//! The production code in `novels.zig` calls into these so the tested logic IS
//! the shipped logic (no drift). Covers:
//!   - Wikisource URL building (search / subpage list / chapter parse) — the
//!     one guaranteed-legal, stable-contract source (public-domain classics via
//!     the documented MediaWiki action API, https://www.mediawiki.org/wiki/API)
//!   - allocation-free JSON scanning of those responses (search titles, subpage
//!     titles, the `parse.text` HTML payload) — reusing comics_pure's tested
//!     JSON primitives so there is one scanner, not two
//!   - HTML → clean reading text: strip tags (skip <script>/<style>), decode the
//!     common named + numeric entities, collapse inline whitespace, preserve
//!     line / paragraph breaks
//!   - reader pagination / offset math (UTF-8-boundary-safe page slicing)
//!   - resume-key formatting (last-read chapter index persisted per novel)
//!
//! Everything here is fixed-buffer / no-allocation, matching the project's
//! `[N]u8 + len` convention.

const std = @import("std");

/// Shared JSON primitives — reuse comics_pure's tested, allocation-free scanner
/// (findJsonNode / findJsonStr / ObjIter / jsonUnescape / percentEncodeStrict)
/// so there is exactly ONE JSON scanner in the tree, already covered by its own
/// test suite. Both modules are pure (std-only), so this import never crosses
/// the io_global boundary that would break a standalone test.
pub const cj = @import("comics_pure.zig");

// ══════════════════════════════════════════════════════════
// Wikisource — https://en.wikisource.org/w/api.php (keyless MediaWiki API)
//
// The guaranteed-works source: public-domain novels with a documented, stable
// JSON contract. `action=query&list=search` finds works; `list=allpages` with
// an `apprefix` of "<Work>/" enumerates a work's chapter subpages;
// `action=parse&prop=text` returns one chapter's rendered HTML.
// ══════════════════════════════════════════════════════════

pub const WIKI_HOST = "en.wikisource.org";
pub const WIKI_API = "https://en.wikisource.org/w/api.php";

/// Search for works. `formatversion=2` gives the flat `{"query":{"search":[…]}}`
/// shape parsed below. namespace 0 = main content (skips Author:/Portal: pages).
pub fn buildSearchUrl(out: []u8, query: []const u8, limit: u32) ?[]const u8 {
    if (query.len == 0) return null;
    var enc: [512]u8 = undefined;
    const n = cj.percentEncodeStrict(query, &enc);
    if (n == 0) return null;
    return std.fmt.bufPrint(
        out,
        "{s}?action=query&list=search&srsearch={s}&srlimit={d}&srnamespace=0&format=json&formatversion=2",
        .{ WIKI_API, enc[0..n], limit },
    ) catch null;
}

/// Enumerate a work's chapter subpages: every page whose title starts with
/// "<Work>/". `aplimit` caps the count. Returned alphabetically by the API
/// (best-effort reading order for v1).
pub fn buildSubpagesUrl(out: []u8, work_title: []const u8, limit: u32) ?[]const u8 {
    if (work_title.len == 0) return null;
    var enc: [512]u8 = undefined;
    const n = cj.percentEncodeStrict(work_title, &enc);
    if (n == 0) return null;
    return std.fmt.bufPrint(
        out,
        "{s}?action=query&list=allpages&apprefix={s}%2F&apnamespace=0&aplimit={d}&format=json&formatversion=2",
        .{ WIKI_API, enc[0..n], limit },
    ) catch null;
}

/// Render one chapter (or a single-page work) to HTML. `disable*` params trim
/// the edit-section links, the limit report, and the table of contents so the
/// `parse.text` payload is closer to just the prose.
pub fn buildChapterUrl(out: []u8, page_title: []const u8) ?[]const u8 {
    if (page_title.len == 0) return null;
    var enc: [512]u8 = undefined;
    const n = cj.percentEncodeStrict(page_title, &enc);
    if (n == 0) return null;
    return std.fmt.bufPrint(
        out,
        "{s}?action=parse&page={s}&prop=text&format=json&formatversion=2&disableeditsection=1&disablelimitreport=1&disabletoc=1",
        .{ WIKI_API, enc[0..n] },
    ) catch null;
}

/// The `query.search[…]` array payload of a search response, or null. Walk it
/// with `cj.ObjIter`; each object's display title is `titleField`.
pub fn searchArray(json: []const u8) ?[]const u8 {
    const q = cj.findJsonNode(json, "\"query\"") orelse return null;
    return cj.findJsonNode(q, "\"search\"");
}

/// The `query.allpages[…]` array payload of a subpage-list response, or null.
pub fn allpagesArray(json: []const u8) ?[]const u8 {
    const q = cj.findJsonNode(json, "\"query\"") orelse return null;
    return cj.findJsonNode(q, "\"allpages\"");
}

/// The raw (still JSON-escaped) `"title"` of a `search`/`allpages` object.
/// Run through `cj.jsonUnescape` before display / re-encoding.
pub fn titleField(obj: []const u8) ?[]const u8 {
    return cj.findJsonStr(obj, "\"title\":\"");
}

/// Extract the chapter HTML from an `action=parse` response into `out`,
/// JSON-unescaping as it goes. Returns bytes written (0 when absent / errored).
/// `formatversion=2` puts the HTML directly in `parse.text` (a string).
pub fn extractParseHtml(json: []const u8, out: []u8) usize {
    const parse = cj.findJsonNode(json, "\"parse\"") orelse return 0;
    const raw = cj.findJsonStr(parse, "\"text\":\"") orelse return 0;
    return cj.jsonUnescape(raw, out);
}

/// The display label for a chapter, given its full page title. "Frankenstein/
/// Chapter 1" → "Chapter 1"; a title with no slash is returned unchanged.
pub fn chapterLabel(full_title: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, full_title, '/')) |s| {
        const tail = full_title[s + 1 ..];
        if (tail.len > 0) return tail;
    }
    return full_title;
}

// ══════════════════════════════════════════════════════════
// HTML → clean reading text
// ══════════════════════════════════════════════════════════

/// Named HTML entities we decode (beyond the numeric `&#…;` forms). Kept small
/// and focused on what prose actually uses. UTF-8 replacements.
const NamedEntity = struct { name: []const u8, utf8: []const u8 };
const NAMED = [_]NamedEntity{
    .{ .name = "amp", .utf8 = "&" },
    .{ .name = "lt", .utf8 = "<" },
    .{ .name = "gt", .utf8 = ">" },
    .{ .name = "quot", .utf8 = "\"" },
    .{ .name = "apos", .utf8 = "'" },
    .{ .name = "nbsp", .utf8 = " " },
    .{ .name = "ensp", .utf8 = " " },
    .{ .name = "emsp", .utf8 = " " },
    .{ .name = "thinsp", .utf8 = " " },
    .{ .name = "mdash", .utf8 = "\xE2\x80\x94" }, // em dash
    .{ .name = "ndash", .utf8 = "\xE2\x80\x93" }, // en dash
    .{ .name = "hellip", .utf8 = "\xE2\x80\xA6" }, // ellipsis
    .{ .name = "mldr", .utf8 = "\xE2\x80\xA6" }, // ellipsis
    .{ .name = "lsquo", .utf8 = "\xE2\x80\x98" }, // left single quote
    .{ .name = "rsquo", .utf8 = "\xE2\x80\x99" }, // right single quote
    .{ .name = "ldquo", .utf8 = "\xE2\x80\x9C" }, // left double quote
    .{ .name = "rdquo", .utf8 = "\xE2\x80\x9D" }, // right double quote
    .{ .name = "laquo", .utf8 = "\xC2\xAB" }, // «
    .{ .name = "raquo", .utf8 = "\xC2\xBB" }, // »
    .{ .name = "times", .utf8 = "\xC3\x97" }, // ×
    .{ .name = "deg", .utf8 = "\xC2\xB0" }, // °
    .{ .name = "sect", .utf8 = "\xC2\xA7" }, // §
    .{ .name = "para", .utf8 = "\xC2\xB6" }, // ¶
    .{ .name = "copy", .utf8 = "\xC2\xA9" }, // ©
    .{ .name = "reg", .utf8 = "\xC2\xAE" }, // ®
    .{ .name = "trade", .utf8 = "\xE2\x84\xA2" }, // ™
    .{ .name = "pound", .utf8 = "\xC2\xA3" }, // £
    .{ .name = "eacute", .utf8 = "\xC3\xA9" }, // é
};

/// One decoded entity: the UTF-8 bytes plus how many source bytes it consumed.
const Decoded = struct { utf8: []const u8, consumed: usize };

/// Decode one HTML entity starting at `html[i]` (which is '&'). On success
/// returns the decoded bytes (in `scratch` for numeric forms) and the consumed
/// length; null when the run isn't a recognized entity (caller emits the '&').
fn decodeEntity(html: []const u8, i: usize, scratch: *[8]u8) ?Decoded {
    const rest = html[i..];
    const semi = std.mem.indexOfScalar(u8, rest[0..@min(rest.len, 12)], ';') orelse return null;
    if (semi < 2) return null; // "&;" is not an entity
    const body = rest[1..semi]; // between '&' and ';'
    const consumed = semi + 1;

    if (body[0] == '#') {
        // Numeric: &#NNN; (decimal) or &#xHH; / &#XHH; (hex).
        var cp: u21 = 0;
        if (body.len >= 2 and (body[1] == 'x' or body[1] == 'X')) {
            cp = std.fmt.parseInt(u21, body[2..], 16) catch return null;
        } else {
            cp = std.fmt.parseInt(u21, body[1..], 10) catch return null;
        }
        // Reject NUL / surrogates / out-of-range (would be invalid UTF-8).
        if (cp == 0 or (cp >= 0xD800 and cp <= 0xDFFF) or cp > 0x10FFFF) return null;
        const n = std.unicode.utf8Encode(cp, scratch) catch return null;
        return .{ .utf8 = scratch[0..n], .consumed = consumed };
    }

    inline for (NAMED) |ent| {
        if (std.mem.eql(u8, body, ent.name)) return .{ .utf8 = ent.utf8, .consumed = consumed };
    }
    return null;
}

/// Return true when a tag name is a block-level element whose boundary should
/// become a paragraph break in the extracted text.
fn isParagraphTag(name: []const u8) bool {
    const blocks = [_][]const u8{
        "p",  "div",    "li",  "ul",      "ol",      "blockquote",
        "h1", "h2",     "h3",  "h4",      "h5",      "h6",
        "tr", "table",  "hr",  "section", "article", "dd",
        "dt", "dl",     "pre", "figure",  "header",  "footer",
    };
    for (blocks) |b| if (std.ascii.eqlIgnoreCase(name, b)) return true;
    return false;
}

const Emit = struct {
    fn byte(buf: []u8, oo: *usize, ch: u8) void {
        if (oo.* < buf.len) {
            buf[oo.*] = ch;
            oo.* += 1;
        }
    }
    fn slice(buf: []u8, oo: *usize, s: []const u8) void {
        for (s) |ch| byte(buf, oo, ch);
    }
};

/// Extract the readable text of an HTML fragment into `out`.
///
///   - `<script>` / `<style>` bodies are dropped entirely.
///   - `<br>` becomes a single newline; block-level tags become a paragraph
///     break (blank line); other tags are dropped but leave a word boundary.
///   - runs of inline whitespace collapse to one space.
///   - the common named + numeric HTML entities are decoded to UTF-8.
///   - malformed input (an unterminated `<…`) stops cleanly — never crashes.
///
/// Returns the number of bytes written. Break emission is deferred until the
/// next visible character, so leading and trailing blank lines never appear.
pub fn htmlToText(html: []const u8, out: []u8) usize {
    var o: usize = 0;
    var i: usize = 0;
    var pending_space = false;
    var pending_break: u2 = 0; // 0 none, 1 line (\n), 2 paragraph (\n\n)

    while (i < html.len) {
        const c = html[i];

        if (c == '<') {
            const gt_rel = std.mem.indexOfScalar(u8, html[i..], '>') orelse break; // malformed → stop
            const inner = html[i + 1 .. i + gt_rel]; // between '<' and '>'
            // Tag name: skip an optional '/', then read to whitespace / '/'.
            var ns: usize = 0;
            if (ns < inner.len and inner[ns] == '/') ns += 1;
            const name_start = ns;
            while (ns < inner.len and inner[ns] != ' ' and inner[ns] != '\t' and
                inner[ns] != '\n' and inner[ns] != '\r' and inner[ns] != '/') ns += 1;
            const name = inner[name_start..ns];

            // <script>/<style>: drop the whole element (opening tag, not close).
            if (name_start == 0 and (std.ascii.eqlIgnoreCase(name, "script") or std.ascii.eqlIgnoreCase(name, "style"))) {
                var close_buf: [10]u8 = undefined;
                const close = std.fmt.bufPrint(&close_buf, "</{s}", .{name}) catch {
                    i = i + gt_rel + 1;
                    continue;
                };
                if (indexOfIgnoreCase(html[i..], close)) |rel| {
                    const after = i + rel;
                    const gt2 = std.mem.indexOfScalar(u8, html[after..], '>') orelse break;
                    i = after + gt2 + 1;
                } else {
                    i = html.len;
                }
                continue;
            }

            if (std.ascii.eqlIgnoreCase(name, "br")) {
                if (pending_break < 1) pending_break = 1;
            } else if (isParagraphTag(name)) {
                pending_break = 2;
            }
            i = i + gt_rel + 1;
            continue;
        }

        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            pending_space = true;
            i += 1;
            continue;
        }

        // Visible character (or the start of an entity). Flush a pending break
        // (takes priority) or a pending space, but only once we have real text.
        if (o > 0) {
            if (pending_break == 2) {
                Emit.slice(out, &o, "\n\n");
            } else if (pending_break == 1) {
                Emit.byte(out, &o, '\n');
            } else if (pending_space) {
                Emit.byte(out, &o, ' ');
            }
        }
        pending_break = 0;
        pending_space = false;

        if (c == '&') {
            var scratch: [8]u8 = undefined;
            if (decodeEntity(html, i, &scratch)) |d| {
                Emit.slice(out, &o, d.utf8);
                i += d.consumed;
                if (o >= out.len) break;
                continue;
            }
        }
        Emit.byte(out, &o, c);
        i += 1;
        if (o >= out.len) break; // buffer full — stop cleanly (caller flags truncation)
    }
    return o;
}

/// Case-insensitive substring search (small needle). Returns the index in
/// `haystack` or null.
fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

// ══════════════════════════════════════════════════════════
// Reader pagination (UTF-8-boundary safe)
// ══════════════════════════════════════════════════════════

/// Move `idx` back until it does not fall on a UTF-8 continuation byte
/// (0b10xxxxxx), so a page slice never splits a multi-byte codepoint.
pub fn charBoundaryBack(text: []const u8, idx_in: usize) usize {
    var idx = @min(idx_in, text.len);
    while (idx > 0 and idx < text.len and (text[idx] & 0xC0) == 0x80) idx -= 1;
    return idx;
}

/// Number of `page_size`-byte pages needed to cover `len` bytes (min 1).
pub fn pageCount(len: usize, page_size: usize) usize {
    if (page_size == 0) return 1;
    if (len == 0) return 1;
    return (len + page_size - 1) / page_size;
}

/// The byte range [start,end) of page `page_index` (0-based) within `text`,
/// clamped to char boundaries so neither edge splits a codepoint.
pub fn pageSlice(text: []const u8, page_index: usize, page_size: usize) []const u8 {
    if (page_size == 0 or text.len == 0) return text;
    const raw_start = page_index * page_size;
    if (raw_start >= text.len) return text[text.len..text.len];
    const start = charBoundaryBack(text, raw_start);
    const end = charBoundaryBack(text, @min(raw_start + page_size, text.len));
    return text[start..end];
}

// ══════════════════════════════════════════════════════════
// Resume key (last-read chapter, persisted per novel)
// ══════════════════════════════════════════════════════════

/// Format the resume value stored for a novel: the last-read chapter index as a
/// decimal string. (Persisted via db.librarySetStatus("novel_resume", <title>).)
pub fn formatResume(out: []u8, chapter: usize) []const u8 {
    return std.fmt.bufPrint(out, "{d}", .{chapter}) catch out[0..0];
}

/// Parse a stored resume value back into a chapter index; 0 on empty / garbage.
pub fn parseResume(s: []const u8) usize {
    const t = std.mem.trim(u8, s, " \t\r\n");
    return std.fmt.parseInt(usize, t, 10) catch 0;
}

/// The per-novel resume key (item_id) — the work title, truncated to a safe
/// length for the KV store. Sanitizes nothing else: the value is bound as SQL
/// text, never interpolated.
pub fn resumeKey(work_title: []const u8, out: []u8) []const u8 {
    const n = @min(work_title.len, out.len);
    @memcpy(out[0..n], work_title[0..n]);
    return out[0..n];
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "buildSearchUrl: encodes query + namespace 0" {
    var buf: [512]u8 = undefined;
    const url = buildSearchUrl(&buf, "pride and prejudice", 20).?;
    try std.testing.expect(std.mem.startsWith(u8, url, "https://en.wikisource.org/w/api.php?action=query&list=search"));
    try std.testing.expect(std.mem.indexOf(u8, url, "srsearch=pride%20and%20prejudice") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "srlimit=20") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "srnamespace=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "formatversion=2") != null);
}

test "buildSearchUrl: empty query yields no request" {
    var buf: [512]u8 = undefined;
    try std.testing.expect(buildSearchUrl(&buf, "", 20) == null);
}

test "buildSubpagesUrl: prefix = <Work>/ (slash encoded)" {
    var buf: [512]u8 = undefined;
    const url = buildSubpagesUrl(&buf, "Frankenstein", 200).?;
    try std.testing.expect(std.mem.indexOf(u8, url, "list=allpages") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "apprefix=Frankenstein%2F") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "apnamespace=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "aplimit=200") != null);
}

test "buildChapterUrl: parse endpoint, page encoded" {
    var buf: [512]u8 = undefined;
    const url = buildChapterUrl(&buf, "Frankenstein/Chapter 1").?;
    try std.testing.expect(std.mem.indexOf(u8, url, "action=parse") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "page=Frankenstein%2FChapter%201") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "prop=text") != null);
}

test "searchArray + titleField: walk a search response" {
    const json =
        \\{"batchcomplete":true,"query":{"searchinfo":{"totalhits":3},"search":[{"ns":0,"title":"Frankenstein","pageid":1},{"ns":0,"title":"Frankenstein; or, The Modern Prometheus","pageid":2}]}}
    ;
    const arr = searchArray(json).?;
    var it = cj.ObjIter{ .buf = arr };
    try std.testing.expectEqualStrings("Frankenstein", titleField(it.next().?).?);
    try std.testing.expectEqualStrings("Frankenstein; or, The Modern Prometheus", titleField(it.next().?).?);
    try std.testing.expect(it.next() == null);
}

test "allpagesArray + titleField: walk a subpage list" {
    const json =
        \\{"batchcomplete":true,"query":{"allpages":[{"pageid":10,"ns":0,"title":"Frankenstein/Letter 1"},{"pageid":11,"ns":0,"title":"Frankenstein/Chapter 1"}]}}
    ;
    const arr = allpagesArray(json).?;
    var it = cj.ObjIter{ .buf = arr };
    const a = titleField(it.next().?).?;
    const b = titleField(it.next().?).?;
    try std.testing.expectEqualStrings("Frankenstein/Letter 1", a);
    try std.testing.expectEqualStrings("Frankenstein/Chapter 1", b);
    try std.testing.expectEqualStrings("Letter 1", chapterLabel(a));
    try std.testing.expectEqualStrings("Chapter 1", chapterLabel(b));
}

test "chapterLabel: no slash returns title unchanged" {
    try std.testing.expectEqualStrings("Middlemarch", chapterLabel("Middlemarch"));
    try std.testing.expectEqualStrings("X", chapterLabel("A/B/X"));
    // trailing slash → fall back to the whole title (no empty label)
    try std.testing.expectEqualStrings("Work/", chapterLabel("Work/"));
}

test "extractParseHtml: pulls parse.text HTML, JSON-unescaped" {
    const json =
        \\{"parse":{"title":"Frankenstein/Chapter 1","pageid":42,"text":"<div class=\"mw-parser-output\"><p>I am by birth a Genevese.<\/p><\/div>"}}
    ;
    var out: [256]u8 = undefined;
    const n = extractParseHtml(json, &out);
    try std.testing.expectEqualStrings(
        "<div class=\"mw-parser-output\"><p>I am by birth a Genevese.</p></div>",
        out[0..n],
    );
}

test "extractParseHtml: missing parse/text → 0 (no crash)" {
    var out: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), extractParseHtml("", &out));
    try std.testing.expectEqual(@as(usize, 0), extractParseHtml("{\"error\":{}}", &out));
    try std.testing.expectEqual(@as(usize, 0), extractParseHtml("{\"parse\":{\"title\":\"x\"}}", &out));
}

test "htmlToText: paragraphs preserved, inline whitespace collapsed" {
    var out: [256]u8 = undefined;
    const n = htmlToText("<p>Hello   world</p>\n<p>Second\tparagraph</p>", &out);
    try std.testing.expectEqualStrings("Hello world\n\nSecond paragraph", out[0..n]);
}

test "htmlToText: <br> is a single line break, blocks are paragraph breaks" {
    var out: [256]u8 = undefined;
    const n = htmlToText("Line one<br>Line two", &out);
    try std.testing.expectEqualStrings("Line one\nLine two", out[0..n]);
}

test "htmlToText: nested inline tags leave a clean word boundary" {
    var out: [256]u8 = undefined;
    const n = htmlToText("<p>The <b><i>quick</i></b> <span>brown</span> fox</p>", &out);
    try std.testing.expectEqualStrings("The quick brown fox", out[0..n]);
}

test "htmlToText: entity decoding — named + numeric" {
    var out: [256]u8 = undefined;
    // &amp; &#39; &lt; &gt; &quot; &mdash; &#x2014; &nbsp;
    const n = htmlToText("Tom &amp; Jerry, it&#39;s 3 &lt; 4 &gt; 2 &quot;q&quot; &mdash;&#x2014;&nbsp;end", &out);
    try std.testing.expectEqualStrings("Tom & Jerry, it's 3 < 4 > 2 \"q\" \xE2\x80\x94\xE2\x80\x94 end", out[0..n]);
}

test "htmlToText: <script> and <style> bodies are dropped" {
    var out: [256]u8 = undefined;
    const n = htmlToText("<p>Before</p><script>var x = 1 < 2;</script><style>p{color:red}</style><p>After</p>", &out);
    try std.testing.expectEqualStrings("Before\n\nAfter", out[0..n]);
}

test "htmlToText: empty chapter / whitespace-only → empty output" {
    var out: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), htmlToText("", &out));
    try std.testing.expectEqual(@as(usize, 0), htmlToText("<div>   \n\t  </div>", &out));
    try std.testing.expectEqual(@as(usize, 0), htmlToText("<p></p><p></p>", &out));
}

test "htmlToText: malformed / unterminated tag does not crash" {
    var out: [64]u8 = undefined;
    // Unterminated '<...' at the end: everything from the '<' is dropped.
    const n = htmlToText("Good text <incomplete", &out);
    try std.testing.expectEqualStrings("Good text", out[0..n]);
    // A stray unrecognized entity keeps its literal '&'.
    var out2: [64]u8 = undefined;
    const n2 = htmlToText("A&B and &notanentity; C", &out2);
    try std.testing.expectEqualStrings("A&B and &notanentity; C", out2[0..n2]);
}

test "htmlToText: valid UTF-8 out (numeric astral codepoint)" {
    var out: [64]u8 = undefined;
    const n = htmlToText("music &#119070; note", &out); // U+1D11E
    try std.testing.expect(std.unicode.utf8ValidateSlice(out[0..n]));
    try std.testing.expectEqualStrings("music \xF0\x9D\x84\x9E note", out[0..n]);
}

test "htmlToText: no leading break from a leading block tag" {
    var out: [64]u8 = undefined;
    const n = htmlToText("<div><p>Start here</p></div>", &out);
    try std.testing.expectEqualStrings("Start here", out[0..n]);
}

test "pageCount: ceil division, min 1" {
    try std.testing.expectEqual(@as(usize, 1), pageCount(0, 100));
    try std.testing.expectEqual(@as(usize, 1), pageCount(100, 100));
    try std.testing.expectEqual(@as(usize, 2), pageCount(101, 100));
    try std.testing.expectEqual(@as(usize, 3), pageCount(250, 100));
    try std.testing.expectEqual(@as(usize, 1), pageCount(50, 0)); // guard div-by-zero
}

test "pageSlice: covers the text, boundaries never split a codepoint" {
    // "café!" is 6 bytes (é = 2 bytes). 3-byte pages must not split é.
    const text = "café!";
    const p0 = pageSlice(text, 0, 3);
    const p1 = pageSlice(text, 1, 3);
    try std.testing.expect(std.unicode.utf8ValidateSlice(p0));
    try std.testing.expect(std.unicode.utf8ValidateSlice(p1));
    // Re-concatenating the pages reproduces the whole text with no loss.
    var joined: [16]u8 = undefined;
    @memcpy(joined[0..p0.len], p0);
    @memcpy(joined[p0.len .. p0.len + p1.len], p1);
    try std.testing.expectEqualStrings(text, joined[0 .. p0.len + p1.len]);
}

test "pageSlice: page past the end is empty, not out of bounds" {
    const text = "short";
    const p = pageSlice(text, 9, 100);
    try std.testing.expectEqual(@as(usize, 0), p.len);
}

test "resume: format → parse round-trip, garbage → 0" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("7", formatResume(&buf, 7));
    try std.testing.expectEqual(@as(usize, 7), parseResume("7"));
    try std.testing.expectEqual(@as(usize, 0), parseResume(""));
    try std.testing.expectEqual(@as(usize, 0), parseResume("  \n"));
    try std.testing.expectEqual(@as(usize, 0), parseResume("notanumber"));
    try std.testing.expectEqual(@as(usize, 12), parseResume(" 12 "));
}

test "resumeKey: truncates to buffer, copies title" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("Frankens", resumeKey("Frankenstein", &buf));
    var buf2: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Middlemarch", resumeKey("Middlemarch", &buf2));
}
