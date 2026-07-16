//! Pure helpers for the OPDS reading-server client — no I/O / state / dvui
//! imports, so the parsing + routing logic ships tested (registered as
//! `test_opds_pure` in build.zig).
//!
//! OPDS 1.2 is an Atom (XML) catalog protocol spoken by Komga, Kavita,
//! Calibre-Web and LANraragi. A feed is a list of `<entry>` blocks; each entry
//! carries a `<title>`, an `<id>`, and one or more `<link>`s whose `rel`
//! distinguishes a navigation subsection from a downloadable acquisition and a
//! cover image. All of that parsing — plus HTTP Basic-auth header construction,
//! relative→absolute href resolution, and the content-type → reader-route
//! decision — lives here so both the desktop service and any future companion
//! route through the same tested code and can never drift.

const std = @import("std");

// ══════════════════════════════════════════════════════════
// Link classification
// ══════════════════════════════════════════════════════════

pub const Rel = enum { navigation, acquisition, image, thumbnail, pse, other };

/// Classify an OPDS `<link rel="…">` value.
///   • rel="subsection"                              → navigation (drill in)
///   • rel="http://vaemendis.net/opds-pse/stream"    → pse (page-streaming)
///   • rel="http://opds-spec.org/acquisition[/*]"    → acquisition (downloadable)
///   • rel="http://opds-spec.org/image/thumbnail"    → thumbnail (small cover)
///   • rel="http://opds-spec.org/image"              → image (full cover)
/// Order matters: PSE is tested first (documents intent — its rel contains none
/// of the words below); then "thumbnail" before the bare "image" substring
/// (thumbnail rel contains "/image/").
pub fn classifyRel(rel: []const u8) Rel {
    if (rel.len == 0) return .other;
    if (std.mem.indexOf(u8, rel, "opds-pse/stream") != null) return .pse;
    if (std.mem.indexOf(u8, rel, "subsection") != null) return .navigation;
    if (std.mem.indexOf(u8, rel, "acquisition") != null) return .acquisition;
    if (std.mem.indexOf(u8, rel, "image/thumbnail") != null) return .thumbnail;
    if (std.mem.indexOf(u8, rel, "/image") != null) return .image;
    // Some feeds use rel="thumbnail" alone.
    if (std.mem.eql(u8, rel, "thumbnail")) return .thumbnail;
    return .other;
}

// ══════════════════════════════════════════════════════════
// OPDS-PSE (Page Streaming Extension) — http://vaemendis.net/opds-pse/
// ══════════════════════════════════════════════════════════
//
// Komga / Kavita expose CBZ/CBR books as a per-page image stream: the entry
// carries an extra acquisition link with rel="http://vaemendis.net/opds-pse/
// stream", a `pse:count="N"` total-page attribute, and a templated href holding
// the `{pageNumber}` placeholder. Each page is fetched as an image (JPEG/PNG) at
// the substituted URL under the same HTTP Basic-auth. Unlike a plain page-image
// server (which we scrape for <img> tags), these pages require auth on EVERY
// fetch, so the page URLs are enumerated here and driven through the comics
// reader with the auth header attached.

/// Placeholder the PSE href template carries; substituted with the page index.
pub const PSE_MARKER = "{pageNumber}";

/// Read the `pse:count` (total pages) attribute from a PSE `<link>` tag. Tolerant
/// of namespace-prefix variance: tries the canonical `pse:count` first, then a
/// bare `count` (some servers drop the prefix). Returns null when absent/unparsable.
pub fn parsePseCount(tag: []const u8) ?u32 {
    const raw = attr(tag, "pse:count") orelse attr(tag, "count") orelse return null;
    return std.fmt.parseInt(u32, std.mem.trim(u8, raw, " \t"), 10) catch null;
}

/// Substitute the `{pageNumber}` placeholder in a PSE href `template` with a
/// 0-indexed page `index`, writing the concrete page-image URL into `out`.
/// Returns null when the template has no placeholder or the result overflows.
pub fn pageUrl(template: []const u8, index: usize, out: []u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, template, PSE_MARKER) orelse return null;
    const head = template[0..at];
    const tail = template[at + PSE_MARKER.len ..];
    return std.fmt.bufPrint(out, "{s}{d}{s}", .{ head, index, tail }) catch null;
}

// ══════════════════════════════════════════════════════════
// Reader routing
// ══════════════════════════════════════════════════════════

pub const ReaderRoute = enum {
    /// CBZ/CBR/image content → the in-app comics/manga page reader.
    comics,
    /// EPUB/PDF → hand to the OS (no in-app ebook renderer).
    external,
    /// Anything we can neither render nor sensibly hand off.
    unsupported,
};

/// Decide how to open an acquisition given its MIME `content_type`.
/// EPUB/PDF are checked first (external) so an EPUB — which is technically a
/// zip — is never mis-routed to the comics reader by the zip/comicbook rule.
pub fn readerRoute(content_type: []const u8) ReaderRoute {
    var buf: [96]u8 = undefined;
    const ct = lowerInto(content_type, &buf);
    if (ct.len == 0) return .unsupported;
    // Ebooks → external viewer.
    if (std.mem.indexOf(u8, ct, "epub") != null) return .external;
    if (std.mem.indexOf(u8, ct, "pdf") != null) return .external;
    // Comics / images → in-app reader. comicbook = Komga/Kavita CBZ/CBR types
    // ("application/vnd.comicbook+zip", "application/vnd.comicbook-rar"),
    // x-cbz/x-cbr = LANraragi/older servers.
    if (std.mem.startsWith(u8, ct, "image/")) return .comics;
    if (std.mem.indexOf(u8, ct, "comicbook") != null) return .comics;
    if (std.mem.indexOf(u8, ct, "cbz") != null) return .comics;
    if (std.mem.indexOf(u8, ct, "cbr") != null) return .comics;
    // A bare zip acquisition (some Calibre-Web comic entries) → comics.
    if (std.mem.indexOf(u8, ct, "zip") != null) return .comics;
    if (std.mem.indexOf(u8, ct, "x-rar") != null) return .comics;
    return .unsupported;
}

fn lowerInto(in: []const u8, out: []u8) []const u8 {
    const n = @min(in.len, out.len);
    for (0..n) |i| out[i] = std.ascii.toLower(in[i]);
    return out[0..n];
}

// ══════════════════════════════════════════════════════════
// HTTP Basic auth
// ══════════════════════════════════════════════════════════

/// Build a full `Authorization: Basic <base64(user:pass)>` header line into
/// `buf`. The core/http.zig transport splits an auth_header on its first ':'
/// into name/value, and base64 never contains a ':' — so the split is safe.
/// Returns null if the encoded header would overflow `buf`.
pub fn basicAuthHeader(user: []const u8, pass: []const u8, buf: []u8) ?[]const u8 {
    var cred_buf: [512]u8 = undefined;
    const cred = std.fmt.bufPrint(&cred_buf, "{s}:{s}", .{ user, pass }) catch return null;
    const enc = std.base64.standard.Encoder;
    const enc_len = enc.calcSize(cred.len);
    const prefix = "Authorization: Basic ";
    if (prefix.len + enc_len > buf.len) return null;
    @memcpy(buf[0..prefix.len], prefix);
    _ = enc.encode(buf[prefix.len .. prefix.len + enc_len], cred);
    return buf[0 .. prefix.len + enc_len];
}

// ══════════════════════════════════════════════════════════
// Relative → absolute href resolution
// ══════════════════════════════════════════════════════════

fn schemeOf(url: []const u8) ?[]const u8 {
    const se = std.mem.indexOf(u8, url, "://") orelse return null;
    return url[0..se];
}

fn originOf(url: []const u8) ?[]const u8 {
    const se = std.mem.indexOf(u8, url, "://") orelse return null;
    var i = se + 3;
    while (i < url.len and url[i] != '/' and url[i] != '?' and url[i] != '#') : (i += 1) {}
    return url[0..i];
}

fn stripQuery(url: []const u8) []const u8 {
    var u = url;
    if (std.mem.indexOfScalar(u8, u, '?')) |q| u = u[0..q];
    if (std.mem.indexOfScalar(u8, u, '#')) |h| u = u[0..h];
    return u;
}

/// Resolve an entry/link `href` against the URL of the feed it came from.
/// Handles absolute (http/https), scheme-relative (`//host/…`), root-relative
/// (`/path`) and document-relative (`path`) forms. Returns null on overflow /
/// unparseable base.
pub fn resolveHref(base_url: []const u8, href: []const u8, buf: []u8) ?[]const u8 {
    if (href.len == 0) return null;

    // Already absolute.
    if (std.mem.startsWith(u8, href, "http://") or std.mem.startsWith(u8, href, "https://")) {
        if (href.len > buf.len) return null;
        @memcpy(buf[0..href.len], href);
        return buf[0..href.len];
    }

    // Scheme-relative "//host/path".
    if (std.mem.startsWith(u8, href, "//")) {
        const scheme = schemeOf(base_url) orelse "https";
        return std.fmt.bufPrint(buf, "{s}:{s}", .{ scheme, href }) catch null;
    }

    // Root-relative "/path".
    if (href[0] == '/') {
        const origin = originOf(base_url) orelse return null;
        return std.fmt.bufPrint(buf, "{s}{s}", .{ origin, href }) catch null;
    }

    // Document-relative "path" → base directory + href.
    const stripped = stripQuery(base_url);
    if (std.mem.indexOf(u8, stripped, "://")) |se| {
        const host_start = se + 3;
        // Last '/' at or after the host start marks the directory boundary.
        var last: ?usize = null;
        var i = host_start;
        while (i < stripped.len) : (i += 1) {
            if (stripped[i] == '/') last = i;
        }
        if (last) |l| {
            return std.fmt.bufPrint(buf, "{s}{s}", .{ stripped[0 .. l + 1], href }) catch null;
        }
        // No path segment — join at the origin root.
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ stripped, href }) catch null;
    }
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ stripped, href }) catch null;
}

// ══════════════════════════════════════════════════════════
// Feed parsing
// ══════════════════════════════════════════════════════════

pub const OpdsEntry = struct {
    title: [256]u8 = std.mem.zeroes([256]u8),
    title_len: usize = 0,
    /// Primary click target, resolved to an absolute URL: the subsection feed
    /// (navigation) or the acquisition download (leaf).
    href: [512]u8 = std.mem.zeroes([512]u8),
    href_len: usize = 0,
    /// True when the primary link is a navigation subsection (drill in) rather
    /// than a downloadable acquisition.
    is_navigation: bool = false,
    /// Acquisition MIME type (empty for navigation entries) — drives readerRoute.
    content_type: [96]u8 = std.mem.zeroes([96]u8),
    content_type_len: usize = 0,
    /// Cover image URL (absolute), or empty when the entry has no image link.
    cover: [512]u8 = std.mem.zeroes([512]u8),
    cover_len: usize = 0,
    /// OPDS-PSE page-stream href TEMPLATE (absolute, `{pageNumber}` preserved),
    /// or empty when the entry is not page-streamable. See the PSE section above.
    pse_url: [512]u8 = std.mem.zeroes([512]u8),
    pse_url_len: usize = 0,
    /// Total page count advertised by the PSE link (`pse:count`); 0 when absent.
    pse_count: u32 = 0,

    pub fn titleSlice(self: *const OpdsEntry) []const u8 {
        return self.title[0..self.title_len];
    }
    pub fn hrefSlice(self: *const OpdsEntry) []const u8 {
        return self.href[0..self.href_len];
    }
    pub fn contentTypeSlice(self: *const OpdsEntry) []const u8 {
        return self.content_type[0..self.content_type_len];
    }
    pub fn coverSlice(self: *const OpdsEntry) []const u8 {
        return self.cover[0..self.cover_len];
    }
    pub fn pseUrlSlice(self: *const OpdsEntry) []const u8 {
        return self.pse_url[0..self.pse_url_len];
    }
    /// True when the entry carries a usable PSE page stream (a template with a
    /// `{pageNumber}` placeholder AND a positive page count) — i.e. it should be
    /// read via authenticated per-page streaming rather than the <img> scraper.
    pub fn isPseStreamable(self: *const OpdsEntry) bool {
        return self.pse_count > 0 and
            self.pse_url_len > 0 and
            std.mem.indexOf(u8, self.pse_url[0..self.pse_url_len], PSE_MARKER) != null;
    }
};

/// Extract the text between the first `<title>` and `</title>` in `xml`,
/// decoding the handful of XML entities OPDS feeds emit. Returns "" if absent.
pub fn feedTitle(xml: []const u8) []const u8 {
    return tagText(xml, xml.len);
}

/// Text of the first `<title …>…</title>` within `xml[0..limit]` (undecoded
/// slice into `xml`). Used for both the feed heading and each entry title.
fn tagText(xml: []const u8, limit: usize) []const u8 {
    const hay = xml[0..@min(limit, xml.len)];
    const open = std.mem.indexOf(u8, hay, "<title") orelse return "";
    // Skip to the '>' that closes the opening tag (attributes tolerated).
    const gt = std.mem.indexOfScalarPos(u8, hay, open, '>') orelse return "";
    const start = gt + 1;
    const close = std.mem.indexOfPos(u8, hay, start, "</title>") orelse return "";
    if (close < start) return "";
    return hay[start..close];
}

/// Read the value of an XML attribute `name="…"` inside a single tag slice.
fn attr(tag: []const u8, name: []const u8) ?[]const u8 {
    var search: [64]u8 = undefined;
    if (name.len + 1 > search.len) return null;
    @memcpy(search[0..name.len], name);
    search[name.len] = '=';
    const key = search[0 .. name.len + 1];
    const at = std.mem.indexOf(u8, tag, key) orelse return null;
    var p = at + key.len;
    if (p >= tag.len) return null;
    const quote = tag[p];
    if (quote != '"' and quote != '\'') return null;
    p += 1;
    const end = std.mem.indexOfScalarPos(u8, tag, p, quote) orelse return null;
    return tag[p..end];
}

/// Decode the minimal XML entity set OPDS titles use into `out`; returns the
/// byte length written (clamped to `out`).
fn decodeXmlEntities(in: []const u8, out: []u8) usize {
    var o: usize = 0;
    var i: usize = 0;
    while (i < in.len and o < out.len) {
        if (in[i] == '&') {
            const rest = in[i..];
            if (std.mem.startsWith(u8, rest, "&amp;")) {
                out[o] = '&';
                o += 1;
                i += 5;
                continue;
            } else if (std.mem.startsWith(u8, rest, "&lt;")) {
                out[o] = '<';
                o += 1;
                i += 4;
                continue;
            } else if (std.mem.startsWith(u8, rest, "&gt;")) {
                out[o] = '>';
                o += 1;
                i += 4;
                continue;
            } else if (std.mem.startsWith(u8, rest, "&quot;")) {
                out[o] = '"';
                o += 1;
                i += 6;
                continue;
            } else if (std.mem.startsWith(u8, rest, "&#39;") or std.mem.startsWith(u8, rest, "&apos;")) {
                out[o] = '\'';
                o += 1;
                i += if (rest[1] == '#') @as(usize, 5) else @as(usize, 6);
                continue;
            }
        }
        out[o] = in[i];
        o += 1;
        i += 1;
    }
    return o;
}

/// Extract the feed-level `<link rel="next" href="…"/>` (Atom/OPDS pagination
/// — RFC 5005 style paging that Komga/Kavita/Calibre-Web emit) and resolve it
/// against `base_url` into `buf`. Returns null when the feed has no next page
/// (the terminal page of a paginated catalog), the href overflows `buf`, or
/// the base URL can't be resolved against.
///
/// Feed-level `<link>`s (self/next/prev/last) are declared as direct children
/// of `<feed>`, either before the first `<entry>` or after the last one —
/// never interspersed among entries. Rather than a full XML tree, this scans
/// once for the first/last entry boundary and skips any `<link>` that falls
/// inside it, so a per-entry link that happens to carry `rel="next"` (not a
/// real OPDS convention, but not disallowed either) can never be mistaken for
/// feed-level pagination.
pub fn feedNextHref(xml: []const u8, base_url: []const u8, buf: []u8) ?[]const u8 {
    const first_entry = std.mem.indexOf(u8, xml, "<entry");
    var last_entry_end: usize = 0;
    if (first_entry != null) {
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, xml, pos, "<entry")) |e_at| {
            const e_end = std.mem.indexOfPos(u8, xml, e_at, "</entry>") orelse xml.len;
            last_entry_end = if (e_end < xml.len) e_end + "</entry>".len else xml.len;
            pos = last_entry_end;
        }
    }

    var lp: usize = 0;
    while (std.mem.indexOfPos(u8, xml, lp, "<link")) |l_at| {
        const l_close = std.mem.indexOfScalarPos(u8, xml, l_at, '>') orelse break;
        lp = l_close + 1;
        if (first_entry) |fe| {
            if (l_at >= fe and l_at < last_entry_end) continue; // entry-scoped, not feed-level
        }
        const tag = xml[l_at .. l_close + 1];
        const rel = attr(tag, "rel") orelse continue;
        if (!std.mem.eql(u8, rel, "next")) continue;
        const href = attr(tag, "href") orelse continue;
        return resolveHref(base_url, href, buf);
    }
    return null;
}

/// Parse an Atom OPDS feed into `out`, resolving every href against `base_url`.
/// Returns the number of entries written (bounded by out.len). Allocation-free
/// and truncation-safe: a malformed / cut-off feed yields the entries parsed so
/// far and never reads out of bounds.
pub fn parseFeed(xml: []const u8, base_url: []const u8, out: []OpdsEntry) usize {
    var count: usize = 0;
    var pos: usize = 0;

    while (count < out.len) {
        const e_rel = std.mem.indexOfPos(u8, xml, pos, "<entry") orelse break;
        // Entry ends at </entry>, or (truncated feed) at end-of-buffer.
        const e_end = std.mem.indexOfPos(u8, xml, e_rel, "</entry>") orelse xml.len;
        const block = xml[e_rel..e_end];
        pos = if (e_end < xml.len) e_end + "</entry>".len else xml.len;

        var ent = OpdsEntry{};

        // Title (decoded).
        const raw_title = tagText(block, block.len);
        if (raw_title.len > 0) {
            ent.title_len = decodeXmlEntities(raw_title, &ent.title);
        }

        // Walk every <link …> tag in the block, classifying each.
        var lp: usize = 0;
        var have_primary = false;
        while (std.mem.indexOfPos(u8, block, lp, "<link")) |l_at| {
            const l_close = std.mem.indexOfScalarPos(u8, block, l_at, '>') orelse break;
            const tag = block[l_at .. l_close + 1];
            lp = l_close + 1;

            const href = attr(tag, "href") orelse continue;
            const rel = attr(tag, "rel") orelse "";
            const kind = classifyRel(rel);

            switch (kind) {
                .navigation => {
                    // First navigation link wins as the primary target.
                    if (!have_primary) {
                        if (resolveHref(base_url, href, &ent.href)) |abs| {
                            ent.href_len = abs.len;
                            ent.is_navigation = true;
                            have_primary = true;
                        }
                    }
                },
                .acquisition => {
                    // An acquisition always overrides a navigation guess (leaf
                    // entries can carry an OPDS-catalog alternate link too); the
                    // FIRST acquisition link is the one we open.
                    if (!have_primary or ent.is_navigation) {
                        if (resolveHref(base_url, href, &ent.href)) |abs| {
                            ent.href_len = abs.len;
                            ent.is_navigation = false;
                            have_primary = true;
                            if (attr(tag, "type")) |ty| {
                                const n = @min(ty.len, ent.content_type.len);
                                @memcpy(ent.content_type[0..n], ty[0..n]);
                                ent.content_type_len = n;
                            }
                        }
                    }
                },
                .image => {
                    // Full cover preferred over a thumbnail; overwrite either.
                    if (resolveHref(base_url, href, &ent.cover)) |abs| ent.cover_len = abs.len;
                },
                .thumbnail => {
                    // Only take a thumbnail if no full image has been seen.
                    if (ent.cover_len == 0) {
                        if (resolveHref(base_url, href, &ent.cover)) |abs| ent.cover_len = abs.len;
                    }
                },
                .pse => {
                    // Page-streaming link: keep the templated href verbatim
                    // ({pageNumber} preserved — resolveHref copies it through) plus
                    // its total-page count. The plain acquisition link normally
                    // stays the primary download/route seam; but some servers hang
                    // the PSE rel on the ONLY link, so if we have no primary yet
                    // seed one here (a comic content-type from the link's own
                    // `type`) so the entry survives and routes to the reader.
                    if (resolveHref(base_url, href, &ent.pse_url)) |abs| {
                        ent.pse_url_len = abs.len;
                        ent.pse_count = parsePseCount(tag) orelse 0;
                        if (!have_primary) {
                            @memcpy(ent.href[0..abs.len], abs);
                            ent.href_len = abs.len;
                            ent.is_navigation = false;
                            have_primary = true;
                            const ty = attr(tag, "type") orelse "image/jpeg";
                            const n = @min(ty.len, ent.content_type.len);
                            @memcpy(ent.content_type[0..n], ty[0..n]);
                            ent.content_type_len = n;
                        }
                    }
                },
                .other => {},
            }
        }

        // Skip entries with no usable link (e.g. a stray feed-level <entry>).
        if (ent.href_len == 0) continue;

        out[count] = ent;
        count += 1;
    }
    return count;
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

const testing = std.testing;

test "classifyRel distinguishes nav / acquisition / image / thumbnail / pse" {
    try testing.expectEqual(Rel.navigation, classifyRel("subsection"));
    try testing.expectEqual(Rel.acquisition, classifyRel("http://opds-spec.org/acquisition"));
    try testing.expectEqual(Rel.acquisition, classifyRel("http://opds-spec.org/acquisition/open-access"));
    try testing.expectEqual(Rel.thumbnail, classifyRel("http://opds-spec.org/image/thumbnail"));
    try testing.expectEqual(Rel.image, classifyRel("http://opds-spec.org/image"));
    try testing.expectEqual(Rel.thumbnail, classifyRel("thumbnail"));
    try testing.expectEqual(Rel.pse, classifyRel("http://vaemendis.net/opds-pse/stream"));
    try testing.expectEqual(Rel.other, classifyRel("self"));
    try testing.expectEqual(Rel.other, classifyRel(""));
}

test "pageUrl substitutes {pageNumber} 0-indexed" {
    var buf: [256]u8 = undefined;
    // 0-indexed: page 0 is the first page.
    try testing.expectEqualStrings(
        "/opds/v1.2/books/42/pages/0?zero_based=true",
        pageUrl("/opds/v1.2/books/42/pages/{pageNumber}?zero_based=true", 0, &buf).?,
    );
    try testing.expectEqualStrings(
        "https://komga.example/api/v1/books/9/pages/17",
        pageUrl("https://komga.example/api/v1/books/9/pages/{pageNumber}", 17, &buf).?,
    );
    // A template with no placeholder yields null (not a silent wrong URL).
    try testing.expect(pageUrl("/books/9/pages/first", 0, &buf) == null);
    // Overflow is reported, not clobbered.
    var tiny: [4]u8 = undefined;
    try testing.expect(pageUrl("/a/{pageNumber}/b", 3, &tiny) == null);
}

test "parsePseCount reads pse:count (and bare count fallback), tolerates missing" {
    try testing.expectEqual(@as(u32, 20), parsePseCount("<link pse:count=\"20\" href=\"x\"/>").?);
    // Namespace-less fallback.
    try testing.expectEqual(@as(u32, 7), parsePseCount("<link count=\"7\" href=\"x\"/>").?);
    // Absent / unparsable → null (no crash).
    try testing.expect(parsePseCount("<link href=\"x\"/>") == null);
    try testing.expect(parsePseCount("<link pse:count=\"\" href=\"x\"/>") == null);
    try testing.expect(parsePseCount("<link pse:count=\"NaN\"/>") == null);
}

test "parseFeed: Komga OPDS-PSE entry (separate stream link + acquisition)" {
    // A live-shaped Komga entry: cover thumbnail, a plain CBZ acquisition, and the
    // OPDS-PSE page-streaming link carrying pse:count + a {pageNumber} template.
    const xml =
        \\<feed xmlns="http://www.w3.org/2005/Atom" xmlns:pse="http://vaemendis.net/opds-pse/ns">
        \\  <title>Berserk</title>
        \\  <entry>
        \\    <title>Volume 1</title>
        \\    <link rel="http://opds-spec.org/image/thumbnail" href="/api/v1/books/42/thumbnail" type="image/jpeg"/>
        \\    <link rel="http://opds-spec.org/acquisition" href="/api/v1/books/42/file" type="application/vnd.comicbook+zip"/>
        \\    <link rel="http://vaemendis.net/opds-pse/stream" href="/api/v1/books/42/pages/{pageNumber}?zero_based=true" type="image/jpeg" pse:count="24"/>
        \\  </entry>
        \\</feed>
    ;
    var entries: [4]OpdsEntry = undefined;
    const n = parseFeed(xml, "https://komga.example/opds/v1.2/series/1", &entries);
    try testing.expectEqual(@as(usize, 1), n);
    const e = entries[0];
    // Plain acquisition remains the primary route target + content type.
    try testing.expect(!e.is_navigation);
    try testing.expectEqualStrings("https://komga.example/api/v1/books/42/file", e.hrefSlice());
    try testing.expectEqual(ReaderRoute.comics, readerRoute(e.contentTypeSlice()));
    // PSE stream parsed: absolute template with {pageNumber} preserved + count.
    try testing.expect(e.isPseStreamable());
    try testing.expectEqual(@as(u32, 24), e.pse_count);
    try testing.expectEqualStrings(
        "https://komga.example/api/v1/books/42/pages/{pageNumber}?zero_based=true",
        e.pseUrlSlice(),
    );
    // …and the page-URL builder rides that template (0-indexed).
    var pbuf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "https://komga.example/api/v1/books/42/pages/0?zero_based=true",
        pageUrl(e.pseUrlSlice(), 0, &pbuf).?,
    );
}

test "parseFeed: PSE-only entry survives (rel hung on the sole link)" {
    // Some servers expose ONLY the streaming link — no plain acquisition. The
    // entry must still route to the reader (comic content-type seeded from the
    // link's own type) rather than being dropped for having no primary href.
    const xml =
        \\<feed xmlns:pse="http://vaemendis.net/opds-pse/ns">
        \\  <entry>
        \\    <title>Solo</title>
        \\    <link rel="http://vaemendis.net/opds-pse/stream" href="/books/9/pages/{pageNumber}" type="image/png" pse:count="3"/>
        \\  </entry>
        \\</feed>
    ;
    var entries: [2]OpdsEntry = undefined;
    const n = parseFeed(xml, "https://kavita.example/opds", &entries);
    try testing.expectEqual(@as(usize, 1), n);
    const e = entries[0];
    try testing.expect(e.isPseStreamable());
    try testing.expectEqual(@as(u32, 3), e.pse_count);
    try testing.expectEqual(ReaderRoute.comics, readerRoute(e.contentTypeSlice()));
    try testing.expectEqualStrings("https://kavita.example/books/9/pages/{pageNumber}", e.pseUrlSlice());
}

test "parseFeed: non-PSE comic entry is NOT streamable (scraper fallback)" {
    // A plain image/CBZ acquisition without a PSE link keeps the existing route:
    // isPseStreamable() is false, so opds hands the raw URL to the <img> scraper.
    const xml =
        \\<feed>
        \\  <entry>
        \\    <title>Plain</title>
        \\    <link rel="http://opds-spec.org/acquisition" href="/a.cbz" type="application/vnd.comicbook+zip"/>
        \\  </entry>
        \\</feed>
    ;
    var entries: [2]OpdsEntry = undefined;
    const n = parseFeed(xml, "https://s.example/opds/root", &entries);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expect(!entries[0].isPseStreamable());
    try testing.expectEqual(@as(u32, 0), entries[0].pse_count);
}

test "parseFeed: malformed PSE (missing count / truncated) does not crash" {
    // PSE link present but no count → not streamable (pse_count stays 0), yet the
    // entry still parses via its acquisition link. And a truncated stream link
    // must never read out of bounds.
    const xml =
        \\<feed xmlns:pse="http://vaemendis.net/opds-pse/ns">
        \\  <entry>
        \\    <title>NoCount</title>
        \\    <link rel="http://opds-spec.org/acquisition" href="/a.cbz" type="application/vnd.comicbook+zip"/>
        \\    <link rel="http://vaemendis.net/opds-pse/stream" href="/books/1/pages/{pageNumber}" type="image/jpeg"/>
        \\  </entry>
        \\  <entry><title>Cut</title><link rel="http://vaemendis.net/opds-pse/stream" href="/books/2/pages/{pageNum
    ;
    var entries: [4]OpdsEntry = undefined;
    const n = parseFeed(xml, "https://s.example/opds", &entries);
    try testing.expect(n >= 1);
    // First entry: PSE href captured but count 0 → NOT streamable.
    try testing.expect(!entries[0].isPseStreamable());
    try testing.expectEqual(@as(u32, 0), entries[0].pse_count);
    try testing.expectEqualStrings("https://s.example/a.cbz", entries[0].hrefSlice());
}

test "readerRoute routes comics vs ebooks vs unsupported" {
    try testing.expectEqual(ReaderRoute.comics, readerRoute("application/vnd.comicbook+zip"));
    try testing.expectEqual(ReaderRoute.comics, readerRoute("application/vnd.comicbook-rar"));
    try testing.expectEqual(ReaderRoute.comics, readerRoute("application/x-cbz"));
    try testing.expectEqual(ReaderRoute.comics, readerRoute("image/jpeg"));
    try testing.expectEqual(ReaderRoute.comics, readerRoute("application/zip"));
    // EPUB is a zip but must route external, not comics.
    try testing.expectEqual(ReaderRoute.external, readerRoute("application/epub+zip"));
    try testing.expectEqual(ReaderRoute.external, readerRoute("application/pdf"));
    try testing.expectEqual(ReaderRoute.external, readerRoute("APPLICATION/EPUB+ZIP")); // case-insensitive
    try testing.expectEqual(ReaderRoute.unsupported, readerRoute("text/plain"));
    try testing.expectEqual(ReaderRoute.unsupported, readerRoute(""));
}

test "basicAuthHeader base64-encodes user:pass" {
    var buf: [128]u8 = undefined;
    // "opal:secret" → b3BhbDpzZWNyZXQ=
    const hdr = basicAuthHeader("opal", "secret", &buf).?;
    try testing.expectEqualStrings("Authorization: Basic b3BhbDpzZWNyZXQ=", hdr);
    // No ':' in the base64 payload → safe for the header name/value split.
    const val = hdr["Authorization:".len..];
    try testing.expect(std.mem.indexOfScalar(u8, val, ':') == null);
    // Overflow is reported, not clobbered.
    var tiny: [8]u8 = undefined;
    try testing.expect(basicAuthHeader("opal", "secret", &tiny) == null);
}

test "resolveHref handles absolute / root-relative / doc-relative / scheme-relative" {
    var buf: [256]u8 = undefined;
    // Absolute passes through.
    try testing.expectEqualStrings(
        "https://komga.example/opds/v1.2/books/1/file",
        resolveHref("https://komga.example/opds/v1.2/catalog", "https://komga.example/opds/v1.2/books/1/file", &buf).?,
    );
    // Root-relative resolves against the origin.
    try testing.expectEqualStrings(
        "https://komga.example/opds/v1.2/series/9",
        resolveHref("https://komga.example/opds/v1.2/catalog?foo=1", "/opds/v1.2/series/9", &buf).?,
    );
    // Document-relative resolves against the feed directory.
    try testing.expectEqualStrings(
        "https://calibre.example/opds/nav/authors",
        resolveHref("https://calibre.example/opds/nav/root", "authors", &buf).?,
    );
    // Scheme-relative borrows the base scheme.
    try testing.expectEqualStrings(
        "http://host/x",
        resolveHref("http://host/opds", "//host/x", &buf).?,
    );
    // Empty href → null.
    try testing.expect(resolveHref("http://host/opds", "", &buf) == null);
}

test "parseFeed extracts nested navigation feed" {
    const xml =
        \\<?xml version="1.0"?>
        \\<feed xmlns="http://www.w3.org/2005/Atom">
        \\  <title>Komga OPDS</title>
        \\  <entry>
        \\    <title>All series</title>
        \\    <id>urn:series</id>
        \\    <link rel="subsection" href="/opds/v1.2/series" type="application/atom+xml;profile=opds-catalog;kind=navigation"/>
        \\  </entry>
        \\  <entry>
        \\    <title>Libraries</title>
        \\    <link rel="subsection" href="libraries" type="application/atom+xml"/>
        \\  </entry>
        \\</feed>
    ;
    try testing.expectEqualStrings("Komga OPDS", feedTitle(xml));
    var entries: [8]OpdsEntry = undefined;
    const n = parseFeed(xml, "https://komga.example/opds/v1.2/catalog", &entries);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("All series", entries[0].titleSlice());
    try testing.expect(entries[0].is_navigation);
    try testing.expectEqualStrings("https://komga.example/opds/v1.2/series", entries[0].hrefSlice());
    // Document-relative "libraries" resolved against the catalog directory.
    try testing.expectEqualStrings("https://komga.example/opds/v1.2/libraries", entries[1].hrefSlice());
}

test "parseFeed extracts acquisition entry with cover + type" {
    const xml =
        \\<feed>
        \\  <title>Berserk</title>
        \\  <entry>
        \\    <title>Berserk &#39;Vol.&amp;1&#39;</title>
        \\    <link rel="http://opds-spec.org/image/thumbnail" href="/covers/1/thumb.jpg" type="image/jpeg"/>
        \\    <link rel="http://opds-spec.org/image" href="/covers/1/full.jpg" type="image/jpeg"/>
        \\    <link rel="http://opds-spec.org/acquisition" href="/books/1/file" type="application/vnd.comicbook+zip"/>
        \\  </entry>
        \\</feed>
    ;
    var entries: [4]OpdsEntry = undefined;
    const n = parseFeed(xml, "https://komga.example/opds/", &entries);
    try testing.expectEqual(@as(usize, 1), n);
    const e = entries[0];
    // XML entities decoded in the title.
    try testing.expectEqualStrings("Berserk 'Vol.&1'", e.titleSlice());
    try testing.expect(!e.is_navigation);
    try testing.expectEqualStrings("https://komga.example/books/1/file", e.hrefSlice());
    try testing.expectEqualStrings("application/vnd.comicbook+zip", e.contentTypeSlice());
    // Full image wins over the thumbnail even though the thumbnail came first.
    try testing.expectEqualStrings("https://komga.example/covers/1/full.jpg", e.coverSlice());
    try testing.expectEqual(ReaderRoute.comics, readerRoute(e.contentTypeSlice()));
}

test "parseFeed: entry with multiple acquisition links keeps the first, missing cover ok" {
    const xml =
        \\<feed>
        \\  <entry>
        \\    <title>Multi</title>
        \\    <link rel="http://opds-spec.org/acquisition" href="/a.cbz" type="application/vnd.comicbook+zip"/>
        \\    <link rel="http://opds-spec.org/acquisition/open-access" href="/a.epub" type="application/epub+zip"/>
        \\  </entry>
        \\</feed>
    ;
    var entries: [4]OpdsEntry = undefined;
    const n = parseFeed(xml, "https://s.example/opds/root", &entries);
    try testing.expectEqual(@as(usize, 1), n);
    // href="/a.cbz" is root-relative → resolved against the origin.
    try testing.expectEqualStrings("https://s.example/a.cbz", entries[0].hrefSlice());
    try testing.expectEqualStrings("application/vnd.comicbook+zip", entries[0].contentTypeSlice());
    try testing.expectEqual(@as(usize, 0), entries[0].cover_len); // no image link
}

test "feedNextHref finds a feed-level rel=next link declared before entries" {
    const xml =
        \\<?xml version="1.0"?>
        \\<feed xmlns="http://www.w3.org/2005/Atom">
        \\  <title>Series</title>
        \\  <link rel="self" href="/opds/v1.2/series?page=2"/>
        \\  <link rel="next" href="/opds/v1.2/series?page=3"/>
        \\  <link rel="prev" href="/opds/v1.2/series?page=1"/>
        \\  <entry>
        \\    <title>Vol 1</title>
        \\    <link rel="http://opds-spec.org/acquisition" href="/books/1/file" type="application/vnd.comicbook+zip"/>
        \\  </entry>
        \\</feed>
    ;
    var buf: [256]u8 = undefined;
    const next = feedNextHref(xml, "https://komga.example/opds/v1.2/series?page=2", &buf).?;
    try testing.expectEqualStrings("https://komga.example/opds/v1.2/series?page=3", next);
}

test "feedNextHref finds a feed-level rel=next link declared after entries" {
    const xml =
        \\<feed>
        \\  <entry>
        \\    <title>Vol 1</title>
        \\    <link rel="http://opds-spec.org/acquisition" href="/books/1/file" type="application/vnd.comicbook+zip"/>
        \\  </entry>
        \\  <link rel="next" href="page3.xml"/>
        \\</feed>
    ;
    var buf: [256]u8 = undefined;
    const next = feedNextHref(xml, "https://s.example/opds/page2.xml", &buf).?;
    try testing.expectEqualStrings("https://s.example/opds/page3.xml", next);
}

test "feedNextHref returns null on the terminal page (no rel=next)" {
    const xml =
        \\<feed>
        \\  <link rel="self" href="/opds/v1.2/series?page=3"/>
        \\  <link rel="prev" href="/opds/v1.2/series?page=2"/>
        \\  <entry><title>Last</title><link rel="http://opds-spec.org/acquisition" href="/books/9/file" type="application/vnd.comicbook+zip"/></entry>
        \\</feed>
    ;
    var buf: [256]u8 = undefined;
    try testing.expect(feedNextHref(xml, "https://s.example/opds/v1.2/series?page=3", &buf) == null);
}

test "feedNextHref ignores a stray rel=next-like link scoped inside an entry" {
    const xml =
        \\<feed>
        \\  <entry>
        \\    <title>X</title>
        \\    <link rel="next" href="/should/not/count"/>
        \\    <link rel="http://opds-spec.org/acquisition" href="/books/1/file" type="application/vnd.comicbook+zip"/>
        \\  </entry>
        \\</feed>
    ;
    var buf: [256]u8 = undefined;
    try testing.expect(feedNextHref(xml, "https://s.example/opds", &buf) == null);
}

test "parseFeed: truncated / malformed XML does not crash and yields partial" {
    // Second entry is cut off mid-tag (no </entry>, no closing '>').
    const xml =
        \\<feed>
        \\  <entry><title>Good</title><link rel="subsection" href="/x"/></entry>
        \\  <entry><title>Cut</title><link rel="subsection" href="/y
    ;
    var entries: [8]OpdsEntry = undefined;
    const n = parseFeed(xml, "https://s.example/opds", &entries);
    // The first entry parses; the truncated one has an unterminated link tag so
    // it may be dropped — the invariant is simply "no crash, bounded result".
    try testing.expect(n >= 1);
    try testing.expectEqualStrings("Good", entries[0].titleSlice());

    // Total garbage → zero entries, no crash.
    try testing.expectEqual(@as(usize, 0), parseFeed("not xml at all <<<>>>", "http://h/o", &entries));
    try testing.expectEqual(@as(usize, 0), parseFeed("", "http://h/o", &entries));
}
