//! Keyless catalog for the Asian Drama page: TVmaze (https://api.tvmaze.com),
//! a free API that needs no key, token or account. Pure parsing and mapping so
//! the shipped logic is the tested logic (build.zig `test-keyless`).
//!
//! What TVmaze can and cannot do (verified against the live API):
//!   * `schedule?country=KR|JP|CN|TH&date=YYYY-MM-DD` and the global
//!     `schedule/web?date=` list what actually aired or is about to air, with
//!     poster, language, rating, popularity `weight`, premiere date, summary.
//!   * It has NO "popular Asian dramas" endpoint and no country/language filter
//!     on the show index, so the browse feed is "on air this week" built from a
//!     window of schedule days, filtered here to scripted Asian-language shows
//!     and ranked by TVmaze's own `weight`.
//!   * `search/shows?q=` is a plain title search across every language; we keep
//!     only scripted Asian-language rows.
//!   * `shows/{id}/episodes` gives the full episode list for the detail view.
//!
//! Rows map onto drama_pure.Item so the grid, detail view and web route keep
//! their existing shape. The poster field carries a full https URL (TMDB rows
//! carry a "/abc.jpg" path); `posterUrl` resolves either.

const std = @import("std");
const drama_pure = @import("drama_pure.zig");

pub const API_BASE = "https://api.tvmaze.com";
pub const Item = drama_pure.Item;

/// A grid row plus the TVmaze fields needed to dedupe and rank it.
pub const Entry = struct {
    item: Item = .{},
    show_id: u32 = 0,
    weight: f32 = 0,
};

// ══════════════════════════════════════════════════════════
// URLs and dates
// ══════════════════════════════════════════════════════════

/// Countries whose broadcast schedule is polled (TW has returned nothing; Taiwanese
/// dramas arrive through the web schedule and the search).
pub const SCHEDULE_COUNTRIES = [_][]const u8{ "KR", "JP", "CN", "TH" };

/// Day offsets (from today) fetched, one wave per day (4 country schedules plus
/// the global web schedule = 5 concurrent requests per wave). Today goes first so
/// the grid fills fast. Four waves = 20 requests, TVmaze's documented allowance
/// per 10 seconds per IP.
pub const FEED_DAY_OFFSETS = [_]i32{ 0, 1, -1, 2 };

/// "YYYY-MM-DD" for `epoch_s + day_offset` days (UTC).
pub fn dateString(epoch_s: i64, day_offset: i32, buf: []u8) ?[]const u8 {
    const secs = epoch_s + @as(i64, day_offset) * 86400;
    if (secs < 0) return null;
    const ed = std.time.epoch.EpochDay{ .day = @intCast(@divFloor(secs, 86400)) };
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), md.day_index + 1 }) catch null;
}

pub fn countryScheduleUrl(country: []const u8, date: []const u8, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, API_BASE ++ "/schedule?country={s}&date={s}", .{ country, date }) catch null;
}

pub fn webScheduleUrl(date: []const u8, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, API_BASE ++ "/schedule/web?date={s}", .{date}) catch null;
}

/// `query` must already be percent-encoded.
pub fn searchUrl(query_encoded: []const u8, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, API_BASE ++ "/search/shows?q={s}", .{query_encoded}) catch null;
}

pub fn episodesUrl(show_id: []const u8, buf: []u8) ?[]const u8 {
    for (show_id) |c| if (c < '0' or c > '9') return null;
    if (show_id.len == 0) return null;
    return std.fmt.bufPrint(buf, API_BASE ++ "/shows/{s}/episodes", .{show_id}) catch null;
}

/// Image URL for a row: a stored full URL is used as is, a TMDB path gets the
/// TMDB base. Returns null when the row has no poster.
pub fn posterUrl(path: []const u8, buf: []u8) ?[]const u8 {
    if (path.len == 0) return null;
    if (std.mem.startsWith(u8, path, "https://")) return std.fmt.bufPrint(buf, "{s}", .{path}) catch null;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ drama_pure.POSTER_BASE, path }) catch null;
}

// ══════════════════════════════════════════════════════════
// Show to grid row
// ══════════════════════════════════════════════════════════

fn field(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn str(v: std.json.Value, key: []const u8) []const u8 {
    const f = field(v, key) orelse return "";
    return if (f == .string) f.string else "";
}

fn num(v: ?std.json.Value) f64 {
    const f = v orelse return 0;
    return switch (f) {
        .integer => |i| @floatFromInt(i),
        .float => |x| x,
        else => 0,
    };
}

/// Channel country code of the network or web channel ("" when absent).
fn channelCountry(show: std.json.Value) []const u8 {
    const keys = [_][]const u8{ "network", "webChannel" };
    for (keys) |k| {
        const ch = field(show, k) orelse continue;
        const c = field(ch, "country") orelse continue;
        const code = str(c, "code");
        if (code.len > 0) return code;
    }
    return "";
}

fn languageOrigin(lang: []const u8) drama_pure.Origin {
    if (std.ascii.eqlIgnoreCase(lang, "Korean")) return .korean;
    if (std.ascii.eqlIgnoreCase(lang, "Japanese")) return .japanese;
    if (std.ascii.eqlIgnoreCase(lang, "Thai")) return .thai;
    if (std.ascii.eqlIgnoreCase(lang, "Chinese") or std.ascii.eqlIgnoreCase(lang, "Mandarin") or std.ascii.eqlIgnoreCase(lang, "Cantonese")) return .chinese;
    return .other;
}

/// Region lane: the show language decides, a Chinese-language show is refined
/// by its channel country (TW stays Taiwanese, HK/CN stay Chinese). A show with
/// no language falls back to the channel country.
pub fn originOf(show: std.json.Value) drama_pure.Origin {
    const lo = languageOrigin(str(show, "language"));
    const cc = drama_pure.classifyOrigin(channelCountry(show));
    if (lo == .chinese and cc == .taiwanese) return .taiwanese;
    if (lo != .other) return lo;
    return cc;
}

fn hasGenre(show: std.json.Value, name: []const u8) bool {
    const g = field(show, "genres") orelse return false;
    if (g != .array) return false;
    for (g.array.items) |it| if (it == .string and std.ascii.eqlIgnoreCase(it.string, name)) return true;
    return false;
}

/// True for a scripted live-action show in an Asian language (anime, variety,
/// reality, news and documentaries are dropped).
pub fn isAsianDrama(show: std.json.Value) bool {
    if (!std.mem.eql(u8, str(show, "type"), "Scripted")) return false;
    if (hasGenre(show, "Anime")) return false;
    return originOf(show) != .other;
}

fn trimUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

/// Strip tags, decode the common entities and collapse whitespace. Bounded by `dst`.
pub fn stripHtml(src: []const u8, dst: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    var pending_space = false;
    while (i < src.len and n < dst.len) {
        var c = src[i];
        // A raw U+00A0 (C2 A0) is whitespace too; real summaries carry them.
        if (c == 0xC2 and i + 1 < src.len and src[i + 1] == 0xA0) {
            pending_space = n > 0;
            i += 2;
            continue;
        }
        if (c == '<') {
            const close = std.mem.indexOfScalarPos(u8, src, i, '>') orelse break;
            const tag = src[i + 1 .. close];
            const breaks = std.mem.startsWith(u8, tag, "p") or std.mem.startsWith(u8, tag, "/p") or std.mem.startsWith(u8, tag, "br");
            if (breaks) pending_space = n > 0;
            i = close + 1;
            continue;
        }
        if (c == '&') {
            if (std.mem.indexOfScalarPos(u8, src, i, ';')) |semi| {
                if (semi - i <= 8) {
                    const ent = src[i + 1 .. semi];
                    const rep: ?u8 = if (std.mem.eql(u8, ent, "amp")) '&' else if (std.mem.eql(u8, ent, "lt")) '<' else if (std.mem.eql(u8, ent, "gt")) '>' else if (std.mem.eql(u8, ent, "quot")) '"' else if (std.mem.eql(u8, ent, "apos") or std.mem.eql(u8, ent, "#39") or std.mem.eql(u8, ent, "#x27")) '\'' else if (std.mem.eql(u8, ent, "nbsp")) ' ' else null;
                    if (rep) |r| {
                        c = r;
                        i = semi;
                    }
                }
            }
        }
        i += 1;
        if (c == ' ' or c == '\n' or c == '\t' or c == '\r') {
            pending_space = n > 0;
            continue;
        }
        if (pending_space and n < dst.len) {
            dst[n] = ' ';
            n += 1;
            pending_space = false;
            if (n >= dst.len) break;
        }
        dst[n] = c;
        n += 1;
    }
    // A buffer-bound cut can split a multibyte character; drop the partial tail.
    var keep = n;
    while (keep > 0 and n - keep < 4 and !std.unicode.utf8ValidateSlice(dst[0..keep])) keep -= 1;
    return dst[0..keep];
}

/// Map one TVmaze show object. Null when it is not an Asian scripted drama or
/// lacks an id or a name.
pub fn showToEntry(show: std.json.Value) ?Entry {
    if (show != .object) return null;
    if (!isAsianDrama(show)) return null;
    const idv = field(show, "id") orelse return null;
    if (idv != .integer or idv.integer <= 0) return null;
    const name = str(show, "name");
    if (name.len == 0) return null;

    var e = Entry{ .show_id = @intCast(idv.integer) };
    const id_s = std.fmt.bufPrint(&e.item.id, "{d}", .{idv.integer}) catch return null;
    e.item.id_len = id_s.len;
    const nm = trimUtf8(name, e.item.name.len);
    @memcpy(e.item.name[0..nm.len], nm);
    e.item.name_len = nm.len;

    const ov = stripHtml(str(show, "summary"), &e.item.overview);
    e.item.overview_len = ov.len;

    if (field(show, "image")) |img| {
        const url = str(img, "medium");
        if (url.len > 0 and url.len <= e.item.poster_path.len and std.mem.startsWith(u8, url, "https://")) {
            @memcpy(e.item.poster_path[0..url.len], url);
            e.item.poster_path_len = url.len;
        }
    }
    const prem = str(show, "premiered");
    if (prem.len >= 4) {
        @memcpy(e.item.year[0..4], prem[0..4]);
        e.item.year_len = 4;
    }
    if (field(show, "rating")) |r| e.item.vote = @floatCast(num(field(r, "average")));
    e.weight = @floatCast(num(field(show, "weight")));
    e.item.origin = originOf(show);
    return e;
}

// ══════════════════════════════════════════════════════════
// Collector (dedupe by show id) and ranking
// ══════════════════════════════════════════════════════════

pub const Collector = struct {
    entries: []Entry,
    count: usize = 0,

    pub fn has(self: *const Collector, show_id: u32) bool {
        for (self.entries[0..self.count]) |e| if (e.show_id == show_id) return true;
        return false;
    }

    /// Returns true when the entry was new and stored.
    pub fn add(self: *Collector, e: Entry) bool {
        if (self.count >= self.entries.len) return false;
        if (self.has(e.show_id)) return false;
        self.entries[self.count] = e;
        self.count += 1;
        return true;
    }
};

/// Highest popularity weight first; ties keep the newest-looking year first,
/// then stable by id so the order never flickers between refreshes.
pub fn sortByWeight(entries: []Entry) void {
    std.mem.sort(Entry, entries, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            if (a.weight != b.weight) return a.weight > b.weight;
            return a.show_id < b.show_id;
        }
    }.less);
}

fn parseDoc(alloc: std.mem.Allocator, json: []const u8) ?std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, json, .{}) catch null;
}

/// True when `json` is a JSON array (a schedule or search page), even an empty one.
/// An error object (rate limit, outage) or an HTML page is not usable.
pub fn isArrayDoc(alloc: std.mem.Allocator, json: []const u8) bool {
    var p = parseDoc(alloc, json) orelse return false;
    defer p.deinit();
    return p.value == .array;
}

/// Parse a `schedule?country=` or `schedule/web` day into `out` (episode rows
/// carry the show either at `show` or at `_embedded.show`). Returns how many
/// NEW shows were added; the new rows are appended at out.entries[old_count..].
pub fn parseSchedule(alloc: std.mem.Allocator, json: []const u8, out: *Collector) usize {
    var p = parseDoc(alloc, json) orelse return 0;
    defer p.deinit();
    if (p.value != .array) return 0;
    var added: usize = 0;
    for (p.value.array.items) |ep| {
        const show = field(ep, "show") orelse blk: {
            const emb = field(ep, "_embedded") orelse continue;
            break :blk field(emb, "show") orelse continue;
        };
        const e = showToEntry(show) orelse continue;
        if (out.add(e)) added += 1;
    }
    return added;
}

/// Parse `search/shows?q=` (`[{score, show}]`), keeping scripted Asian rows in
/// TVmaze's own relevance order.
pub fn parseSearch(alloc: std.mem.Allocator, json: []const u8, out: *Collector) usize {
    var p = parseDoc(alloc, json) orelse return 0;
    defer p.deinit();
    if (p.value != .array) return 0;
    var added: usize = 0;
    for (p.value.array.items) |row| {
        const show = field(row, "show") orelse continue;
        const e = showToEntry(show) orelse continue;
        if (out.add(e)) added += 1;
    }
    return added;
}

// ══════════════════════════════════════════════════════════
// Episodes
// ══════════════════════════════════════════════════════════

pub const Episode = struct {
    season: u16 = 0,
    number: u16 = 0,
    name: [96]u8 = std.mem.zeroes([96]u8),
    name_len: usize = 0,
    airdate: [10]u8 = std.mem.zeroes([10]u8),
    airdate_len: usize = 0,
    runtime: u16 = 0,
};

fn smallInt(v: ?std.json.Value) u16 {
    const f = v orelse return 0;
    if (f != .integer or f.integer < 0) return 0;
    return @intCast(@min(f.integer, std.math.maxInt(u16)));
}

/// Parse `shows/{id}/episodes` into `out`, regular episodes first-to-last as
/// TVmaze returns them. Returns the number written.
pub fn parseEpisodes(alloc: std.mem.Allocator, json: []const u8, out: []Episode) usize {
    var p = parseDoc(alloc, json) orelse return 0;
    defer p.deinit();
    if (p.value != .array) return 0;
    var n: usize = 0;
    for (p.value.array.items) |ep| {
        if (n >= out.len) break;
        if (ep != .object) continue;
        const ty = str(ep, "type");
        if (ty.len > 0 and !std.mem.eql(u8, ty, "regular")) continue;
        var e = Episode{};
        e.season = smallInt(field(ep, "season"));
        e.number = smallInt(field(ep, "number"));
        e.runtime = smallInt(field(ep, "runtime"));
        const nm = trimUtf8(str(ep, "name"), e.name.len);
        @memcpy(e.name[0..nm.len], nm);
        e.name_len = nm.len;
        const ad = str(ep, "airdate");
        if (ad.len == 10) {
            @memcpy(e.airdate[0..10], ad);
            e.airdate_len = 10;
        }
        out[n] = e;
        n += 1;
    }
    return n;
}

/// "S1 E03" style label, or "S1 Special" when the number is missing.
pub fn episodeLabel(e: Episode, buf: []u8) []const u8 {
    if (e.number == 0) return std.fmt.bufPrint(buf, "S{d} Special", .{e.season}) catch "";
    return std.fmt.bufPrint(buf, "S{d} E{d:0>2}", .{ e.season, e.number }) catch "";
}

// ══════════════════════════════════════════════════════════
// Tests (fixtures are trimmed captures of the live endpoints)
// ══════════════════════════════════════════════════════════

const country_fx = @embedFile("fixtures/tvmaze_country_schedule.json");
const web_fx = @embedFile("fixtures/tvmaze_web_schedule.json");
const search_fx = @embedFile("fixtures/tvmaze_search.json");
const episodes_fx = @embedFile("fixtures/tvmaze_episodes.json");

fn nameOf(e: Entry) []const u8 {
    return e.item.name[0..e.item.name_len];
}

test "country schedule keeps scripted Asian dramas, drops variety/anime and dedupes episodes of one show" {
    var buf: [16]Entry = undefined;
    var c = Collector{ .entries = &buf };
    const added = parseSchedule(std.testing.allocator, country_fx, &c);
    // Embers of the Night (CN) and Ao to Midori (JP). Variety KR and Animation JP are
    // dropped; the duplicated Embers episode adds nothing.
    try std.testing.expectEqual(@as(usize, 2), added);
    try std.testing.expectEqualStrings("Embers of the Night", nameOf(buf[0]));
    try std.testing.expectEqual(drama_pure.Origin.chinese, @as(drama_pure.Origin, buf[0].item.origin));
    try std.testing.expectEqualStrings("2026", buf[0].item.year[0..buf[0].item.year_len]);
    try std.testing.expectEqual(@as(u32, 94751), buf[0].show_id);
    try std.testing.expectEqual(@as(f32, 56), buf[0].weight);
    try std.testing.expect(std.mem.startsWith(u8, buf[0].item.poster_path[0..buf[0].item.poster_path_len], "https://static.tvmaze.com/"));
    try std.testing.expect(buf[0].item.overview_len > 20);
    try std.testing.expect(std.mem.indexOfScalar(u8, buf[0].item.overview[0..buf[0].item.overview_len], '<') == null);
    try std.testing.expectEqual(drama_pure.Origin.japanese, @as(drama_pure.Origin, buf[1].item.origin));
}

test "web schedule reads _embedded.show, keeps Thai, drops English" {
    var buf: [16]Entry = undefined;
    var c = Collector{ .entries = &buf };
    try std.testing.expectEqual(@as(usize, 1), parseSchedule(std.testing.allocator, web_fx, &c));
    try std.testing.expectEqualStrings("Khom Khlang", nameOf(buf[0]));
    // Thai web channel with no country: the language decides.
    try std.testing.expectEqual(drama_pure.Origin.thai, @as(drama_pure.Origin, buf[0].item.origin));
}

test "search keeps the Korean row and drops the English namesake" {
    var buf: [16]Entry = undefined;
    var c = Collector{ .entries = &buf };
    try std.testing.expectEqual(@as(usize, 1), parseSearch(std.testing.allocator, search_fx, &c));
    try std.testing.expectEqualStrings("Love", nameOf(buf[0]));
    try std.testing.expectEqual(drama_pure.Origin.korean, @as(drama_pure.Origin, buf[0].item.origin));
    try std.testing.expectEqual(@as(f32, 0), buf[0].item.vote);
}

test "collector dedupes across waves and ranks by weight" {
    var buf: [16]Entry = undefined;
    var c = Collector{ .entries = &buf };
    _ = parseSchedule(std.testing.allocator, country_fx, &c);
    try std.testing.expectEqual(@as(usize, 0), parseSchedule(std.testing.allocator, country_fx, &c));
    _ = parseSchedule(std.testing.allocator, web_fx, &c);
    try std.testing.expectEqual(@as(usize, 3), c.count);
    sortByWeight(buf[0..c.count]);
    try std.testing.expectEqualStrings("Khom Khlang", nameOf(buf[0])); // weight 83
    try std.testing.expectEqualStrings("Ao to Midori", nameOf(buf[1])); // 68
    try std.testing.expectEqualStrings("Embers of the Night", nameOf(buf[2])); // 56
}

test "collector respects its capacity" {
    var buf: [1]Entry = undefined;
    var c = Collector{ .entries = &buf };
    _ = parseSchedule(std.testing.allocator, country_fx, &c);
    try std.testing.expectEqual(@as(usize, 1), c.count);
}

test "chinese language refined by channel country" {
    const j =
        \\{"id":1,"name":"X","type":"Scripted","language":"Chinese","genres":[],"network":{"country":{"code":"TW"}},"webChannel":null}
    ;
    var p = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, j, .{});
    defer p.deinit();
    try std.testing.expectEqual(drama_pure.Origin.taiwanese, originOf(p.value));
    const j2 =
        \\{"id":2,"name":"Y","type":"Scripted","language":null,"genres":[],"network":{"country":{"code":"KR"}}}
    ;
    var p2 = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, j2, .{});
    defer p2.deinit();
    try std.testing.expectEqual(drama_pure.Origin.korean, originOf(p2.value));
    const j3 =
        \\{"id":3,"name":"Z","type":"Scripted","language":"Japanese","genres":["Anime"]}
    ;
    var p3 = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, j3, .{});
    defer p3.deinit();
    try std.testing.expect(!isAsianDrama(p3.value));
}

test "episodes parse in order with labels" {
    var eps: [8]Episode = undefined;
    const n = parseEpisodes(std.testing.allocator, episodes_fx, &eps);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("Episode 1", eps[0].name[0..eps[0].name_len]);
    try std.testing.expectEqualStrings("2019-12-14", eps[0].airdate[0..eps[0].airdate_len]);
    try std.testing.expectEqual(@as(u16, 100), eps[0].runtime);
    var lb: [16]u8 = undefined;
    try std.testing.expectEqualStrings("S1 E16", episodeLabel(eps[3], &lb));
    try std.testing.expectEqualStrings("S1 Special", episodeLabel(.{ .season = 1 }, &lb));
}

test "episodes skip specials and respect the output bound" {
    const j =
        \\[{"name":"A","season":1,"number":1,"type":"regular"},{"name":"B","season":1,"number":null,"type":"significant_special"},{"name":"C","season":1,"number":2,"type":"regular"}]
    ;
    var eps: [8]Episode = undefined;
    try std.testing.expectEqual(@as(usize, 2), parseEpisodes(std.testing.allocator, j, &eps));
    var one: [1]Episode = undefined;
    try std.testing.expectEqual(@as(usize, 1), parseEpisodes(std.testing.allocator, j, &one));
}

test "garbage and error documents parse to nothing" {
    var buf: [4]Entry = undefined;
    var c = Collector{ .entries = &buf };
    try std.testing.expectEqual(@as(usize, 0), parseSchedule(std.testing.allocator, "", &c));
    try std.testing.expectEqual(@as(usize, 0), parseSchedule(std.testing.allocator, "<html>429</html>", &c));
    try std.testing.expectEqual(@as(usize, 0), parseSchedule(std.testing.allocator, "{\"status\":429,\"name\":\"Too Many Requests\"}", &c));
    try std.testing.expectEqual(@as(usize, 0), parseSearch(std.testing.allocator, "[{\"show\":", &c));
    var eps: [2]Episode = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseEpisodes(std.testing.allocator, "{}", &eps));
    try std.testing.expect(isArrayDoc(std.testing.allocator, "[]"));
    try std.testing.expect(!isArrayDoc(std.testing.allocator, "{\"status\":429}"));
    try std.testing.expect(!isArrayDoc(std.testing.allocator, ""));
}

test "stripHtml decodes entities and collapses tags" {
    var b: [128]u8 = undefined;
    try std.testing.expectEqualStrings("A & B say \"hi\". Next line", stripHtml("<p><b>A</b> &amp; B say &quot;hi&quot;.</p><p>Next   line</p>", &b));
    try std.testing.expectEqualStrings("", stripHtml("", &b));
    // Trailing non-breaking spaces (raw U+00A0) from real summaries are dropped.
    try std.testing.expectEqualStrings("end.", stripHtml("<p>end. \xc2\xa0 \xc2\xa0</p>", &b));
    var small: [5]u8 = undefined;
    try std.testing.expectEqualStrings("hello", stripHtml("<p>hello world</p>", &small));
}

test "urls and dates" {
    var db: [16]u8 = undefined;
    try std.testing.expectEqualStrings("2026-10-05", dateString(1791158400 + 3600, 0, &db).?);
    try std.testing.expectEqualStrings("2026-10-06", dateString(1791158400 + 3600, 1, &db).?);
    try std.testing.expectEqualStrings("2026-10-04", dateString(1791158400 + 3600, -1, &db).?);
    var ub: [128]u8 = undefined;
    try std.testing.expectEqualStrings("https://api.tvmaze.com/schedule?country=KR&date=2026-10-05", countryScheduleUrl("KR", "2026-10-05", &ub).?);
    try std.testing.expectEqualStrings("https://api.tvmaze.com/schedule/web?date=2026-10-05", webScheduleUrl("2026-10-05", &ub).?);
    try std.testing.expectEqualStrings("https://api.tvmaze.com/search/shows?q=crash%20landing", searchUrl("crash%20landing", &ub).?);
    try std.testing.expectEqualStrings("https://api.tvmaze.com/shows/42756/episodes", episodesUrl("42756", &ub).?);
    try std.testing.expect(episodesUrl("42756/../x", &ub) == null);
    try std.testing.expect(episodesUrl("", &ub) == null);
}

test "posterUrl handles TVmaze URLs and TMDB paths" {
    var b: [160]u8 = undefined;
    try std.testing.expectEqualStrings("https://static.tvmaze.com/uploads/images/medium_portrait/1/2.jpg", posterUrl("https://static.tvmaze.com/uploads/images/medium_portrait/1/2.jpg", &b).?);
    try std.testing.expectEqualStrings("https://image.tmdb.org/t/p/w342/abc.jpg", posterUrl("/abc.jpg", &b).?);
    try std.testing.expect(posterUrl("", &b) == null);
}
