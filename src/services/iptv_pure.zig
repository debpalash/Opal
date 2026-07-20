//! Pure parsing + decisions for the Live TV (IPTV) tab — the VIDEO twin of
//! radio_pure.zig. No app-state / dvui / atomics imports, so the logic ships
//! tested (registered as `test_iptv_pure` in build.zig).
//!
//! Data source: the iptv-org public directory `streams.json` — a flat JSON
//! array of stream objects:
//!   https://iptv-org.github.io/api/streams.json
//!   [{ "channel":null, "feed":null, "title":"Milennio TV",
//!      "url":"https://…/milenniotv.m3u8", "quality":"720p",
//!      "label":null, "user_agent":null, "referrer":null }, …]
//!
//! `url` is the playable HLS/m3u8 stream (mpv plays it natively). `channel` is
//! the id that joins the two sibling directories the UI enriches from:
//!   • logos.json    — { "channel":"BBCNews.uk", …, "url":"https://…/logo.png" }
//!                     → the card THUMBNAIL (see logoUrlForChannel).
//!   • channels.json — { "id":"BBCNews.uk", "country":"GB",
//!                       "categories":["news"], "is_nsfw":false, … }
//!                     → category + country meta and the PRECISE is_nsfw flag
//!                       (see channelCountry / channelCategory / channelIsNsfw).
//! ~12% of streams have a null `channel` and thus no logo/metadata, so the
//! popular list prefers identified channels (parseStreamsRanked). The title/url
//! isNsfw heuristic still runs at parse time as a cheap first gate (it also
//! covers null-channel adult streams channels.json can't describe); the precise
//! is_nsfw flag drops the rest after the join.
//!
//! The parser writes into a caller-provided fixed-buffer slice and returns the
//! number of channels filled — bounds-safe on a worker thread (a malformed feed
//! must never trip a slice panic → a worker panic aborts the whole app).

const std = @import("std");
/// App-wide stream-health classifier (shared with Radio) — see the re-exports
/// further down. Pure, so importing it keeps this module test-registerable.
const lh = @import("link_health_pure.zig");

// ── Fixed-buffer record (shared with state.zig; no dvui/atomics so std.mem.zeroes works). ──

pub const IptvChannel = struct {
    // Channel display name (streams.json `title`).
    name: [160]u8 = std.mem.zeroes([160]u8),
    name_len: usize = 0,
    // The playable HLS/m3u8 stream URL handed straight to mpv.
    url: [512]u8 = std.mem.zeroes([512]u8),
    url_len: usize = 0,
    // Quality label ("720p"/"1080p"/…); may be empty.
    quality: [8]u8 = std.mem.zeroes([8]u8),
    quality_len: usize = 0,
    // streams.json `channel` id (e.g. "BBCNews.uk") — the join key into
    // logos.json (thumbnail) and channels.json (category/country/is_nsfw). Empty
    // when the stream's channel is null (~12% of the feed), which is why the
    // popular list prefers identified channels: they're the ones that carry a
    // logo + metadata (see parseStreamsRanked).
    chan_id: [64]u8 = std.mem.zeroes([64]u8),
    chan_id_len: usize = 0,
    // Thumbnail URL joined from logos.json (empty → card falls back to a glyph).
    logo: [256]u8 = std.mem.zeroes([256]u8),
    logo_len: usize = 0,
    // Enrichment from channels.json (joined on chan_id). Populated when the
    // channels feed is reachable; empty otherwise.
    country: [64]u8 = std.mem.zeroes([64]u8),
    country_len: usize = 0,
    category: [48]u8 = std.mem.zeroes([48]u8),
    category_len: usize = 0,
    // channels.json `is_nsfw` — the PRECISE adult flag (vs. the title/url
    // heuristic isNsfw applies at parse time). Used to drop flagged channels
    // after the join when the app's NSFW filter is on.
    nsfw: bool = false,
    // Per-stream HTTP hints from streams.json. MANY CDNs 400/403 the request
    // unless the exact user_agent / referrer they expect is sent (~6% of the
    // feed), so these are handed to mpv on play (user-agent + Referer header).
    user_agent: [256]u8 = std.mem.zeroes([256]u8),
    user_agent_len: usize = 0,
    referrer: [256]u8 = std.mem.zeroes([256]u8),
    referrer_len: usize = 0,
};

// ══════════════════════════════════════════════════════════
// Shared JSON helpers (mirrors radio_pure.zig)
// ══════════════════════════════════════════════════════════

/// Decode the common JSON string escapes (\" \\ \/ \n \r \t \uXXXX) from `src`
/// into `dst`, returning bytes written (bounded by dst.len). iptv-org escapes
/// URL slashes as "\/", which would otherwise leave a broken stream URL.
/// Anything not a recognized escape is copied verbatim so we never corrupt.
pub fn jsonUnescape(src: []const u8, dst: []u8) usize {
    var out: usize = 0;
    var i: usize = 0;
    while (i < src.len and out < dst.len) {
        const ch = src[i];
        if (ch != '\\' or i + 1 >= src.len) {
            dst[out] = ch;
            out += 1;
            i += 1;
            continue;
        }
        switch (src[i + 1]) {
            '"' => {
                dst[out] = '"';
                out += 1;
                i += 2;
            },
            '\\' => {
                dst[out] = '\\';
                out += 1;
                i += 2;
            },
            '/' => {
                dst[out] = '/';
                out += 1;
                i += 2;
            },
            'n' => {
                dst[out] = '\n';
                out += 1;
                i += 2;
            },
            'r' => {
                dst[out] = '\r';
                out += 1;
                i += 2;
            },
            't' => {
                dst[out] = '\t';
                out += 1;
                i += 2;
            },
            'u' => {
                if (i + 6 <= src.len) {
                    if (std.fmt.parseInt(u21, src[i + 2 .. i + 6], 16)) |cp| {
                        var u8b: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &u8b) catch 0;
                        if (n > 0 and out + n <= dst.len) {
                            @memcpy(dst[out .. out + n], u8b[0..n]);
                            out += n;
                        }
                        i += 6;
                    } else |_| {
                        dst[out] = '\\';
                        out += 1;
                        i += 1;
                    }
                } else {
                    dst[out] = '\\';
                    out += 1;
                    i += 1;
                }
            },
            else => {
                dst[out] = '\\';
                out += 1;
                i += 1;
            },
        }
    }
    return out;
}

/// Find `key` (e.g. `"title":"`) in `scope`, then read the JSON string value up
/// to the next unescaped `"`, decoding escapes into `dst`. Returns bytes
/// written, or 0 if the key is absent (or its value is `null`, which has no
/// opening quote). Bounds-safe against a truncated value.
fn jsonStrField(scope: []const u8, key: []const u8, dst: []u8) usize {
    const at = std.mem.indexOf(u8, scope, key) orelse return 0;
    const start = at + key.len;
    var end = start;
    var esc = false;
    while (end < scope.len) : (end += 1) {
        if (esc) {
            esc = false;
        } else if (scope[end] == '\\') {
            esc = true;
        } else if (scope[end] == '"') {
            break;
        }
    }
    if (end > scope.len) return 0;
    return jsonUnescape(scope[start..@min(end, scope.len)], dst);
}

// ══════════════════════════════════════════════════════════
// Pure decisions (URL shape, m3u8 recognition, NSFW gate, query match)
// ══════════════════════════════════════════════════════════

/// True when `url` is an http/https stream mpv can open directly.
pub fn isHttpUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://");
}

/// Case-insensitive substring test.
fn containsCI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        } else return true;
    }
    return false;
}

/// Recognize an HLS/m3u8 playlist URL (path ends in `.m3u8`/`.m3u`, ignoring a
/// trailing `?query`/`#fragment`). Surfaced as an "HLS" badge in the UI, so the
/// tested logic is the shipped logic. mpv also plays non-m3u8 http streams, so
/// this is a display hint, NOT the accept gate (that's isHttpUrl).
/// Single implementation lives in link_health_pure.zig (shared with Radio).
pub const isM3u8 = lh.isM3u8;

/// Heuristic adult-content detector over the title + url. streams.json carries
/// no is_nsfw flag (that lives in channels.json, a separate ~10 MB file this v1
/// does not fetch), so the gate keys on explicit adult tokens. Deliberately
/// conservative to avoid false positives on benign names like "Adult Swim" or
/// "Adult Animation" — plain "adult" is NOT a trigger; only explicit tokens are.
pub fn isNsfw(title: []const u8, url: []const u8) bool {
    const tokens = [_][]const u8{
        "xxx",     "porn",  "brazzers", "playboy", "hustler",
        "penthouse", "hentai", "camsoda", "chaturbate", "redtube",
        "18+",     "adults only",
    };
    for (tokens) |t| {
        if (containsCI(title, t)) return true;
        if (containsCI(url, t)) return true;
    }
    return false;
}

/// Case-insensitive title filter for search. Empty query matches everything (so
/// the popular/all-channels load reuses the same accept path).
pub fn matchesQuery(title: []const u8, query: []const u8) bool {
    return containsCI(title, query);
}

/// Whole accept decision for one stream entry, routed from parseStreams so the
/// tested logic IS the shipped logic:
///   • a non-empty display name, AND
///   • a playable http(s) URL, AND
///   • passes the NSFW gate (unless `nsfw_allowed`), AND
///   • matches the (possibly empty) search query.
pub fn acceptEntry(title: []const u8, url: []const u8, quality: []const u8, nsfw_allowed: bool, query: []const u8) bool {
    _ = quality; // reserved (kept in the signature so callers pass full context)
    if (title.len == 0) return false;
    if (!isHttpUrl(url)) return false;
    if (!nsfw_allowed and isNsfw(title, url)) return false;
    if (!matchesQuery(title, query)) return false;
    return true;
}

// ══════════════════════════════════════════════════════════
// Browse filters (category / country / quality) + sort — PURE, tested
// ══════════════════════════════════════════════════════════

/// Minimum-quality bands over the stream's `quality` string ("720p"→720). A
/// stream with no quality label (tier 0) matches only `.any` — we never claim an
/// unknown stream is HD.
pub const QualityFilter = enum {
    any,
    sd,
    hd,
    fhd,

    pub fn accepts(self: QualityFilter, quality: []const u8) bool {
        if (self == .any) return true;
        const t = tierOf(quality);
        return switch (self) {
            .any => true,
            .sd => t > 0 and t < 720,
            .hd => t >= 720,
            .fhd => t >= 1080,
        };
    }

    /// Leading integer of a quality string ("1080p" → 1080, "" → 0).
    fn tierOf(q: []const u8) u32 {
        var n: u32 = 0;
        for (q) |ch| {
            if (ch >= '0' and ch <= '9') n = n * 10 + (ch - '0') else break;
        }
        return n;
    }

    pub fn fromIndex(i: u8) QualityFilter {
        return switch (i) {
            1 => .sd,
            2 => .hd,
            3 => .fhd,
            else => .any,
        };
    }
};

pub const SortMode = enum {
    relevance,
    name,
    country,

    pub fn fromIndex(i: u8) SortMode {
        return switch (i) {
            1 => .name,
            2 => .country,
            else => .relevance,
        };
    }
};

/// Active browse filters, snapshotted from state onto the worker.
pub const Filters = struct {
    query: []const u8 = "",
    category: []const u8 = "", // channels.json category code; "" = all
    country: []const u8 = "", // country code ("US"); "" = all
    quality: QualityFilter = .any,
    nsfw_allowed: bool = false,
};

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}

/// Whole accept decision for a stream given its joined channel metadata
/// (category/country from channels.json) and the active filters. The worker's
/// fill loop routes every candidate through here so the shipped filtering is the
/// tested filtering. `meta_nsfw` is the precise channels.json is_nsfw flag.
pub fn acceptChannel(ch: *const IptvChannel, category: []const u8, country: []const u8, meta_nsfw: bool, f: Filters) bool {
    if (!acceptEntry(ch.name[0..ch.name_len], ch.url[0..ch.url_len], ch.quality[0..ch.quality_len], f.nsfw_allowed, f.query)) return false;
    if (!f.nsfw_allowed and meta_nsfw) return false;
    if (f.category.len > 0 and !eqIgnoreCase(category, f.category)) return false;
    if (f.country.len > 0 and !eqIgnoreCase(country, f.country)) return false;
    if (!f.quality.accepts(ch.quality[0..ch.quality_len])) return false;
    return true;
}

/// Ordering for `sort` mode. relevance keeps feed/rank order (returns false so
/// the sort is stable no-op). Case-insensitive by name, or by country then name.
pub fn channelLessThan(mode: SortMode, a: *const IptvChannel, b: *const IptvChannel) bool {
    switch (mode) {
        .relevance => return false,
        .name => return lessCI(a.name[0..a.name_len], b.name[0..b.name_len]),
        .country => {
            const ca = a.country[0..a.country_len];
            const cb = b.country[0..b.country_len];
            if (!eqIgnoreCase(ca, cb)) return lessCI(ca, cb);
            return lessCI(a.name[0..a.name_len], b.name[0..b.name_len]);
        },
    }
}

fn lessCI(a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const x = std.ascii.toLower(a[i]);
        const y = std.ascii.toLower(b[i]);
        if (x != y) return x < y;
    }
    return a.len < b.len;
}

// ══════════════════════════════════════════════════════════
// Stream health — RE-EXPORTS of the app-wide classifier
// ══════════════════════════════════════════════════════════
// The implementation + tests moved to link_health_pure.zig so Live TV and Radio
// (and any future vertical) share ONE classifier. These aliases keep the legacy
// iptv-flavored names compiling for existing callers.

/// Result of probing a stream URL. Persisted as the int value in iptv_health.
pub const Health = lh.Status;
/// See link_health_pure.looksLikePlaylist.
pub const looksLikePlaylist = lh.looksLikePlaylist;
/// See link_health_pure.classify.
pub const classifyHealth = lh.classify;

// ══════════════════════════════════════════════════════════
// URL builder
// ══════════════════════════════════════════════════════════

/// `<base>/streams.json` for the installed iptv-org endpoint. A trailing slash
/// on `base` is trimmed so we never emit `//streams.json`. Returns "" only if
/// `dst` is too small.
pub fn buildStreamsUrl(base: []const u8, dst: []u8) []const u8 {
    return buildFileUrl(base, "streams.json", dst);
}

/// `<base>/logos.json` — the channel-id → logo-url directory (thumbnails).
pub fn buildLogosUrl(base: []const u8, dst: []u8) []const u8 {
    return buildFileUrl(base, "logos.json", dst);
}

/// `<base>/channels.json` — the channel-id → category/country/is_nsfw directory.
pub fn buildChannelsUrl(base: []const u8, dst: []u8) []const u8 {
    return buildFileUrl(base, "channels.json", dst);
}

fn buildFileUrl(base: []const u8, file: []const u8, dst: []u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, base, "/");
    return std.fmt.bufPrint(dst, "{s}/{s}", .{ trimmed, file }) catch "";
}

// ══════════════════════════════════════════════════════════
// streams.json → channels
// ══════════════════════════════════════════════════════════
// The worker drives the fill loop (it owns the logos/channels id→object maps,
// which are impure), but every DECISION it makes is a pure function tested here:
// StreamIter splits the feed, parseStreamObj reads one object's fields, and
// acceptChannel (above) gates on the joined metadata + filters. That keeps the
// filter/join logic tested even though the loop itself lives in iptv.zig.

/// Iterates an iptv-org streams.json array, yielding each stream OBJECT slice.
/// Objects are delimited by their `"channel":` marker (present once per object,
/// even when the value is null — so null-channel streams are NOT skipped, unlike
/// ObjIter's `"channel":"` key). Bounds-safe on any malformed/truncated feed.
pub const StreamIter = struct {
    json: []const u8,
    pos: usize = 0,
    const marker = "\"channel\":";

    pub fn next(self: *StreamIter) ?[]const u8 {
        const idx = std.mem.indexOfPos(u8, self.json, self.pos, marker) orelse return null;
        var obj_end = self.json.len;
        if (std.mem.indexOfPos(u8, self.json, idx + marker.len, marker)) |n| obj_end = n;
        self.pos = obj_end;
        return self.json[idx..obj_end];
    }
};

/// Fill name/url/quality/chan_id + the user_agent/referrer play hints from one
/// streams.json object slice. Resets `c` first; unset fields stay zero-length.
/// Bounds-safe. Returns whether the stream carries a channel id (the join key +
/// the identified-first ranking signal).
pub fn parseStreamObj(obj: []const u8, c: *IptvChannel) bool {
    c.* = .{};
    c.chan_id_len = jsonStrField(obj, "\"channel\":\"", &c.chan_id);
    c.url_len = jsonStrField(obj, "\"url\":\"", &c.url);
    c.name_len = jsonStrField(obj, "\"title\":\"", &c.name);
    c.quality_len = jsonStrField(obj, "\"quality\":\"", &c.quality);
    c.user_agent_len = jsonStrField(obj, "\"user_agent\":\"", &c.user_agent);
    c.referrer_len = jsonStrField(obj, "\"referrer\":\"", &c.referrer);
    return c.chan_id_len > 0;
}

const IdMode = enum { any, require_id, exclude_id };

/// Fill `out` with up to `out.len` streams from `json` passing `filters`,
/// IDENTIFIED-first: streams with a channel id (which carry a logo + metadata)
/// fill the window before null-channel ones, so the grid shows thumbnails, not a
/// wall of glyphs. Two ordered passes partition cleanly on channel-id presence,
/// so no stream is emitted twice. Returns the count written.
///
/// `ctx.enrich(c) bool` is the metadata JOIN: called for each identified stream
/// with `c.chan_id` filled, it fills `c.category`/`c.country`/`c.logo` from the
/// sibling directories and returns the precise is_nsfw flag. The worker passes a
/// map-backed ctx; tests pass a no-op. This is why the shipped fill loop IS the
/// tested loop — only the join plugs in.
pub fn fillRanked(json: []const u8, out: []IptvChannel, filters: Filters, ctx: anytype) usize {
    var count = fillPass(json, out, filters, .require_id, ctx);
    if (count < out.len) count += fillPass(json, out[count..], filters, .exclude_id, ctx);
    return count;
}

fn fillPass(json: []const u8, out: []IptvChannel, filters: Filters, id_mode: IdMode, ctx: anytype) usize {
    var count: usize = 0;
    var it = StreamIter{ .json = json };
    while (it.next()) |obj| {
        if (count >= out.len) break;
        var c = &out[count];
        const has_id = parseStreamObj(obj, c);
        switch (id_mode) {
            .any => {},
            .require_id => if (!has_id) continue,
            .exclude_id => if (has_id) continue,
        }
        // De-dup: a channel often has several stream objects (mirrors/qualities);
        // keep the FIRST per channel id so the grid shows one card, not N. Only
        // identified streams can be de-duped (null-channel ones have no key).
        if (has_id) {
            const id = c.chan_id[0..c.chan_id_len];
            var dup = false;
            var j: usize = 0;
            while (j < count) : (j += 1) {
                if (std.mem.eql(u8, out[j].chan_id[0..out[j].chan_id_len], id)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
        }
        // Join metadata (category/country/logo + precise nsfw) for identified
        // streams; null-channel streams carry none (so a category/country filter
        // correctly excludes them).
        const meta_nsfw = if (has_id) ctx.enrich(c) else false;
        if (!acceptChannel(c, c.category[0..c.category_len], c.country[0..c.country_len], meta_nsfw, filters)) continue;
        count += 1;
    }
    return count;
}

/// No-op join context for tests / the metadata-less path.
pub const NullMeta = struct {
    pub fn enrich(_: NullMeta, _: *IptvChannel) bool {
        return false;
    }
};

// ══════════════════════════════════════════════════════════
// Enrichment join — logos.json / channels.json → per-channel logo + metadata
// ══════════════════════════════════════════════════════════
// logos.json and channels.json are big flat arrays keyed by channel id. The
// worker walks each ONCE with ObjIter to build an id→object index (a scan per
// result over a 7–10 MB body would be seconds; the index makes each lookup
// O(1)), then pulls fields from the matched object slice with the extractors
// below. Splitting "locate the object" (ObjIter) from "read its fields"
// (…FromObj) keeps both halves pure and unit-tested, so the shipped join is the
// tested join.

/// Streams objects keyed by an id marker (`"id":"` for channels.json,
/// `"channel":"` for logos.json), yielding each object's id + full slice. The
/// object spans its own marker to the next one (or EOF) — the same delimiting
/// parseStreams uses — so field reads never bleed across records.
pub const ObjIter = struct {
    json: []const u8,
    marker: []const u8,
    pos: usize = 0,

    pub const Entry = struct { id: []const u8, obj: []const u8 };

    pub fn next(self: *ObjIter) ?Entry {
        const at = std.mem.indexOfPos(u8, self.json, self.pos, self.marker) orelse return null;
        const id_start = at + self.marker.len;
        var id_end = id_start;
        while (id_end < self.json.len and self.json[id_end] != '"') id_end += 1;
        const id = self.json[id_start..@min(id_end, self.json.len)];
        var obj_end = self.json.len;
        if (std.mem.indexOfPos(u8, self.json, id_end, self.marker)) |n| obj_end = n;
        self.pos = obj_end;
        return .{ .id = id, .obj = self.json[at..obj_end] };
    }
};

/// Marker for a logos.json entry (keyed by `channel`).
pub const LOGO_MARKER = "\"channel\":\"";
/// Marker for a channels.json entry (keyed by `id`).
pub const CHANNEL_MARKER = "\"id\":\"";

/// The logo image URL from a logos.json object slice (0 if none).
pub fn logoUrlFromObj(obj: []const u8, dst: []u8) usize {
    return jsonStrField(obj, "\"url\":\"", dst);
}

pub const ChannelMeta = struct {
    country_len: usize = 0,
    category_len: usize = 0,
    nsfw: bool = false,
};

/// country + first category + is_nsfw from a channels.json object slice.
/// `categories` is a JSON array; we surface its first element as the display
/// group. `is_nsfw` is the authoritative adult flag (vs. the title heuristic).
pub fn channelMetaFromObj(obj: []const u8, country_dst: []u8, category_dst: []u8) ChannelMeta {
    return .{
        .country_len = jsonStrField(obj, "\"country\":\"", country_dst),
        .category_len = jsonStrField(obj, "\"categories\":[\"", category_dst),
        .nsfw = std.mem.indexOf(u8, obj, "\"is_nsfw\":true") != null,
    };
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "isHttpUrl accepts http/https only" {
    try std.testing.expect(isHttpUrl("http://a/x.m3u8"));
    try std.testing.expect(isHttpUrl("https://a/x.m3u8"));
    try std.testing.expect(!isHttpUrl("rtmp://a/x"));
    try std.testing.expect(!isHttpUrl(""));
}

test "isNsfw flags explicit adult tokens but not 'Adult Swim'" {
    try std.testing.expect(isNsfw("Blue XXX TV", ""));
    try std.testing.expect(isNsfw("Some Channel", "https://x/porn/live.m3u8"));
    try std.testing.expect(isNsfw("Hentai Haven", ""));
    // Regression: benign names containing "adult" must NOT be filtered.
    try std.testing.expect(!isNsfw("Adult Swim Latin America Brazil", "https://a/as.m3u8"));
    try std.testing.expect(!isNsfw("Pluto TV Adult Animation", "https://a/pluto.m3u8"));
    try std.testing.expect(!isNsfw("Stingray Pop Adult", "https://a/s.m3u8"));
}

test "matchesQuery is a case-insensitive substring; empty = all" {
    try std.testing.expect(matchesQuery("BBC News HD", "news"));
    try std.testing.expect(matchesQuery("BBC News HD", "BBC"));
    try std.testing.expect(matchesQuery("anything", ""));
    try std.testing.expect(!matchesQuery("BBC News HD", "cnn"));
}

test "acceptEntry gates name/url/nsfw/query" {
    // Happy path.
    try std.testing.expect(acceptEntry("BBC", "https://a/x.m3u8", "720p", false, ""));
    // No name → reject.
    try std.testing.expect(!acceptEntry("", "https://a/x.m3u8", "720p", false, ""));
    // Non-http URL → reject.
    try std.testing.expect(!acceptEntry("BBC", "rtmp://a/x", "720p", false, ""));
    // NSFW rejected when filter on, allowed when off.
    try std.testing.expect(!acceptEntry("XXX Channel", "https://a/x.m3u8", "", false, ""));
    try std.testing.expect(acceptEntry("XXX Channel", "https://a/x.m3u8", "", true, ""));
    // Query filter.
    try std.testing.expect(acceptEntry("BBC News", "https://a/x.m3u8", "", false, "news"));
    try std.testing.expect(!acceptEntry("BBC News", "https://a/x.m3u8", "", false, "sports"));
}

test "buildStreamsUrl appends streams.json and trims a trailing slash" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://iptv-org.github.io/api/streams.json",
        buildStreamsUrl("https://iptv-org.github.io/api", &buf),
    );
    try std.testing.expectEqualStrings(
        "https://iptv-org.github.io/api/streams.json",
        buildStreamsUrl("https://iptv-org.github.io/api/", &buf),
    );
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqualStrings("", buildStreamsUrl("https://a", &tiny));
}

// Reference fill used by the tests (the worker mirrors this with a map-backed
// ctx instead of NullMeta).
fn fillTest(json: []const u8, out: []IptvChannel, filters: Filters) usize {
    return fillRanked(json, out, filters, NullMeta{});
}

test "fillRanked extracts title/url/quality/chan_id/hints from real-shaped JSON" {
    const json =
        \\[{"channel":null,"feed":null,"title":"Milennio TV","url":"https:\/\/v.example.com:19360\/milenniotv\/milenniotv.m3u8","quality":"720p","label":null,"user_agent":"UA1","referrer":"https:\/\/ref\/"},
        \\{"channel":"BBCNews.uk","feed":null,"title":"BBC News","url":"https:\/\/b\/news.m3u8","quality":"1080p","label":null}]
    ;
    var out: [8]IptvChannel = undefined;
    const n = fillTest(json, &out, .{});
    try std.testing.expectEqual(@as(usize, 2), n);
    // Identified channel ranked first.
    try std.testing.expectEqualStrings("BBC News", out[0].name[0..out[0].name_len]);
    try std.testing.expectEqualStrings("BBCNews.uk", out[0].chan_id[0..out[0].chan_id_len]);
    try std.testing.expectEqualStrings("1080p", out[0].quality[0..out[0].quality_len]);
    // Null-channel one backfilled, with url + play hints.
    try std.testing.expectEqualStrings("Milennio TV", out[1].name[0..out[1].name_len]);
    try std.testing.expectEqualStrings("https://v.example.com:19360/milenniotv/milenniotv.m3u8", out[1].url[0..out[1].url_len]);
    try std.testing.expectEqualStrings("UA1", out[1].user_agent[0..out[1].user_agent_len]);
    try std.testing.expectEqualStrings("https://ref/", out[1].referrer[0..out[1].referrer_len]);
    try std.testing.expectEqual(@as(usize, 0), out[1].chan_id_len);
}

test "fillRanked applies query, drops bad entries, honours NSFW" {
    const json =
        \\[{"channel":null,"title":"BBC News","url":"https:\/\/b\/news.m3u8","quality":"1080p"},
        \\{"channel":null,"title":"ESPN Sports","url":"https:\/\/e\/sport.m3u8","quality":"720p"},
        \\{"channel":null,"title":"No URL","url":null,"quality":"720p"},
        \\{"channel":null,"title":"XXX Live","url":"https:\/\/a\/xxx.m3u8","quality":"720p"}]
    ;
    var out: [8]IptvChannel = undefined;
    // Query "news" → only BBC News.
    try std.testing.expectEqual(@as(usize, 1), fillTest(json, &out, .{ .query = "news" }));
    try std.testing.expectEqualStrings("BBC News", out[0].name[0..out[0].name_len]);
    // No query, NSFW filter on → BBC + ESPN (null-url + XXX dropped).
    try std.testing.expectEqual(@as(usize, 2), fillTest(json, &out, .{}));
    // NSFW allowed → XXX comes back (3 total).
    try std.testing.expectEqual(@as(usize, 3), fillTest(json, &out, .{ .nsfw_allowed = true }));
}

test "fillRanked ranks identified-first without duplicating" {
    const json =
        \\[{"channel":null,"title":"Anon TV","url":"https:\/\/a\/anon.m3u8","quality":"720p"},
        \\{"channel":"BBCNews.uk","title":"BBC News","url":"https:\/\/b\/news.m3u8","quality":"1080p"},
        \\{"channel":null,"title":"Anon 2","url":"https:\/\/a\/anon2.m3u8","quality":"480p"}]
    ;
    var out: [8]IptvChannel = undefined;
    const n = fillTest(json, &out, .{});
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("BBC News", out[0].name[0..out[0].name_len]); // id'd first
    try std.testing.expect(out[1].chan_id_len == 0 and out[2].chan_id_len == 0);
    try std.testing.expectEqualStrings("Anon TV", out[1].name[0..out[1].name_len]);
    try std.testing.expectEqualStrings("Anon 2", out[2].name[0..out[2].name_len]);
}

test "fillRanked de-dupes multiple streams of the same channel" {
    // Three stream objects, two share BBCNews.uk (mirrors) → one card.
    const json =
        \\[{"channel":"BBCNews.uk","title":"BBC News HD","url":"https:\/\/a\/1.m3u8","quality":"1080p"},
        \\{"channel":"BBCNews.uk","title":"BBC News","url":"https:\/\/b\/2.m3u8","quality":"720p"},
        \\{"channel":"ESPN.us","title":"ESPN","url":"https:\/\/c\/3.m3u8","quality":"720p"}]
    ;
    var out: [8]IptvChannel = undefined;
    const n = fillTest(json, &out, .{});
    try std.testing.expectEqual(@as(usize, 2), n); // BBC once + ESPN
    try std.testing.expectEqualStrings("BBC News HD", out[0].name[0..out[0].name_len]); // first kept
    try std.testing.expectEqualStrings("ESPN", out[1].name[0..out[1].name_len]);
}

test "fillRanked regression: malformed JSON never panics" {
    var out: [8]IptvChannel = undefined;
    try std.testing.expectEqual(@as(usize, 0), fillTest("", &out, .{}));
    try std.testing.expectEqual(@as(usize, 0), fillTest("[", &out, .{}));
    try std.testing.expectEqual(@as(usize, 0), fillTest("[{\"channel\":", &out, .{}));
    _ = fillTest("\"channel\":null,\"url\":\"https:\\/\\/", &out, .{});
    _ = fillTest("[{\"channel\":null,\"title\":\"n\",\"url\":\"https://a\"}]", &out, .{});
}

test "the join ctx feeds category/country into acceptChannel (metadata filter)" {
    // A map-backed ctx like the worker's: tags the BBC stream Sports/GB.
    const Ctx = struct {
        pub fn enrich(_: @This(), c: *IptvChannel) bool {
            if (std.mem.eql(u8, c.chan_id[0..c.chan_id_len], "BBCNews.uk")) {
                @memcpy(c.category[0..6], "sports");
                c.category_len = 6;
                @memcpy(c.country[0..2], "GB");
                c.country_len = 2;
            }
            return false;
        }
    };
    const json =
        \\[{"channel":"BBCNews.uk","title":"BBC","url":"https:\/\/b\/n.m3u8","quality":"1080p"},
        \\{"channel":"ESPN.us","title":"ESPN","url":"https:\/\/e\/s.m3u8","quality":"720p"}]
    ;
    var out: [8]IptvChannel = undefined;
    // Country filter GB → only the enriched BBC stream (ESPN has no metadata).
    const n = fillRanked(json, &out, .{ .country = "gb" }, Ctx{});
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("BBC", out[0].name[0..out[0].name_len]);
}

test "QualityFilter bands by minimum tier; unknown matches only .any" {
    try std.testing.expect(QualityFilter.any.accepts(""));
    try std.testing.expect(QualityFilter.hd.accepts("720p"));
    try std.testing.expect(QualityFilter.hd.accepts("1080p"));
    try std.testing.expect(!QualityFilter.hd.accepts("480p"));
    try std.testing.expect(QualityFilter.fhd.accepts("1080p"));
    try std.testing.expect(!QualityFilter.fhd.accepts("720p"));
    try std.testing.expect(QualityFilter.sd.accepts("480p"));
    try std.testing.expect(!QualityFilter.sd.accepts("720p"));
    try std.testing.expect(!QualityFilter.hd.accepts("")); // unknown ≠ HD
}

test "acceptChannel gates category/country/quality on top of the base gate" {
    var c = IptvChannel{};
    @memcpy(c.name[0..3], "BBC");
    c.name_len = 3;
    @memcpy(c.url[0..16], "https://a/x.m3u8");
    c.url_len = 16;
    @memcpy(c.quality[0..5], "1080p");
    c.quality_len = 5;
    // Matches when filters agree.
    try std.testing.expect(acceptChannel(&c, "sports", "GB", false, .{ .category = "sports", .country = "gb", .quality = .hd }));
    // Wrong category / country / quality each reject.
    try std.testing.expect(!acceptChannel(&c, "news", "GB", false, .{ .category = "sports" }));
    try std.testing.expect(!acceptChannel(&c, "sports", "US", false, .{ .country = "gb" }));
    @memcpy(c.quality[0..4], "480p");
    c.quality_len = 4;
    try std.testing.expect(!acceptChannel(&c, "sports", "GB", false, .{ .quality = .hd }));
    // Precise is_nsfw flag rejects when the filter is on.
    c.quality_len = 5;
    try std.testing.expect(!acceptChannel(&c, "sports", "GB", true, .{}));
}

// looksLikePlaylist / classifyHealth / isM3u8 are tested in link_health_pure.zig
// (the single implementation these names alias). Kept here: one aliasing smoke
// test so a broken re-export fails fast.
test "health re-exports resolve to the shared classifier" {
    try std.testing.expectEqual(Health.live, classifyHealth(200, true, 500));
    try std.testing.expect(looksLikePlaylist("#EXTM3U"));
    try std.testing.expect(isM3u8("https://a/b.m3u8"));
}

test "channelLessThan sorts by name / country then name" {
    var a = IptvChannel{};
    @memcpy(a.name[0..3], "abc");
    a.name_len = 3;
    @memcpy(a.country[0..2], "US");
    a.country_len = 2;
    var b = IptvChannel{};
    @memcpy(b.name[0..3], "xyz");
    b.name_len = 3;
    @memcpy(b.country[0..2], "GB");
    b.country_len = 2;
    // Name: abc < xyz.
    try std.testing.expect(channelLessThan(.name, &a, &b));
    try std.testing.expect(!channelLessThan(.name, &b, &a));
    // Country: GB(b) < US(a).
    try std.testing.expect(channelLessThan(.country, &b, &a));
    // relevance is a stable no-op.
    try std.testing.expect(!channelLessThan(.relevance, &a, &b));
}

test "buildLogosUrl / buildChannelsUrl append the sibling files" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://iptv-org.github.io/api/logos.json",
        buildLogosUrl("https://iptv-org.github.io/api/", &buf),
    );
    try std.testing.expectEqualStrings(
        "https://iptv-org.github.io/api/channels.json",
        buildChannelsUrl("https://iptv-org.github.io/api", &buf),
    );
}

test "ObjIter + logoUrlFromObj join a logo url by channel id" {
    const logos =
        \\[{"channel":"002RadioTV.do","feed":null,"in_use":true,"tags":[],"width":334,"height":210,"format":"PNG","url":"https:\/\/i.imgur.com\/7oNe8xj.png"},
        \\{"channel":"BBCNews.uk","feed":null,"in_use":true,"tags":[],"width":512,"height":512,"format":"PNG","url":"https:\/\/i.imgur.com\/bbc.png"}]
    ;
    // Build the id→url map exactly as the worker does, then look one up.
    var found: [256]u8 = undefined;
    var found_len: usize = 0;
    var it = ObjIter{ .json = logos, .marker = LOGO_MARKER };
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.id, "BBCNews.uk")) found_len = logoUrlFromObj(e.obj, &found);
    }
    try std.testing.expectEqualStrings("https://i.imgur.com/bbc.png", found[0..found_len]);
}

test "ObjIter + channelMetaFromObj join country/category/is_nsfw by id" {
    const channels =
        \\[{"id":"002RadioTV.do","name":"002 Radio TV","alt_names":[],"network":null,"owners":[],"country":"DO","categories":["general"],"is_nsfw":false,"launched":null},
        \\{"id":"RedXXX.us","name":"Red XXX","alt_names":[],"country":"US","categories":["xxx"],"is_nsfw":true,"launched":null}]
    ;
    var country: [64]u8 = undefined;
    var category: [48]u8 = undefined;
    var it = ObjIter{ .json = channels, .marker = CHANNEL_MARKER };
    var seen_sfw = false;
    var seen_nsfw = false;
    while (it.next()) |e| {
        const m = channelMetaFromObj(e.obj, &country, &category);
        if (std.mem.eql(u8, e.id, "002RadioTV.do")) {
            try std.testing.expectEqualStrings("DO", country[0..m.country_len]);
            try std.testing.expectEqualStrings("general", category[0..m.category_len]);
            try std.testing.expect(!m.nsfw);
            seen_sfw = true;
        } else if (std.mem.eql(u8, e.id, "RedXXX.us")) {
            try std.testing.expectEqualStrings("xxx", category[0..m.category_len]);
            try std.testing.expect(m.nsfw); // precise flag, independent of the title heuristic
            seen_nsfw = true;
        }
    }
    try std.testing.expect(seen_sfw and seen_nsfw);
}
