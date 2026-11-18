//! Pure decisions for querying Stremio addons: which installed addons can
//! answer a stream request at all, and what one addon's HTTP outcome means for
//! the source as a whole. No I/O — stremio.zig / resolver.zig route through it.
const std = @import("std");
const lifecycle = @import("resolver_lifecycle_pure.zig");

/// Response bound for one addon's stream list. Torrentio answers a popular
/// movie with ~300 KB of JSON; the old 64 KB buffer turned that into a
/// transport failure and the best addon contributed nothing.
pub const max_stream_response: usize = 1024 * 1024;

fn listHas(list: ?std.json.Value, needle: []const u8) ?bool {
    const v = list orelse return null;
    if (v != .array) return null;
    for (v.array.items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, needle)) return true;
    }
    return false;
}

fn prefixMatches(list: ?std.json.Value, id: []const u8) ?bool {
    const v = list orelse return null;
    if (v != .array) return null;
    for (v.array.items) |item| {
        if (item == .string and std.mem.startsWith(u8, id, item.string)) return true;
    }
    return false;
}

/// Whether an addon manifest declares a `stream` resource for this media type
/// and id. null = not a manifest. Catalog/meta/subtitle addons (Cinemeta,
/// OpenSubtitles, Kitsu, …) answer a stream URL with 404; asking them anyway
/// reported the whole source as a transport failure.
pub fn servesStream(allocator: std.mem.Allocator, manifest: []const u8, media_type: []const u8, id: []const u8) ?bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, manifest, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const root = parsed.value.object;
    const resources = root.get("resources") orelse return null;
    if (resources != .array) return null;
    for (resources.array.items) |res| {
        var types = root.get("types");
        var prefixes = root.get("idPrefixes");
        if (res == .string) {
            if (!std.mem.eql(u8, res.string, "stream")) continue;
        } else if (res == .object) {
            const name = res.object.get("name") orelse continue;
            if (name != .string or !std.mem.eql(u8, name.string, "stream")) continue;
            if (res.object.get("types")) |t| types = t;
            if (res.object.get("idPrefixes")) |p| prefixes = p;
        } else continue;
        if (listHas(types, media_type) == false) continue;
        if (prefixMatches(prefixes, id) == false) continue;
        return true;
    }
    return false;
}

/// What one addon's stream request contributes to the source status.
/// `status` is the HTTP status, or null when no response head arrived.
/// A 404 is the protocol's "nothing for this id", not a broken transport, and
/// 401/403 means the addon wants configuration (debrid key) — neither may
/// outrank a healthy addon's results as a network error.
pub fn streamHttpOutcome(status: ?u16) lifecycle.SourceStatus {
    const code = status orelse return .transport_failed;
    return switch (code) {
        200...299 => .done,
        401, 403, 429 => .unavailable,
        404, 410 => .no_results,
        else => .transport_failed,
    };
}

/// Manifest URL → addon base ("…/manifest.json" stripped).
pub fn addonBase(url: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, url, "/manifest.json") orelse url.len;
    return std.mem.trimEnd(u8, url[0..end], "/");
}

/// "{base}/stream/{type}/{id}.json" — the one stream request shape.
pub fn streamUrl(buf: []u8, base: []const u8, media_type: []const u8, id: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/stream/{s}/{s}.json", .{ addonBase(base), media_type, id }) catch null;
}

/// IMDb stream id: "tt…" for a movie, "tt…:S:E" for a series episode.
pub fn imdbStreamId(buf: []u8, imdb: []const u8, is_series: bool, season: i32, episode: i32) ?[]const u8 {
    if (is_series and season > 0 and episode > 0)
        return std.fmt.bufPrint(buf, "{s}:{d}:{d}", .{ imdb, season, episode }) catch null;
    return std.fmt.bufPrint(buf, "{s}", .{imdb}) catch null;
}

// ── Kitsu ids (anime) ─────────────────────────────────────
// Addons such as Torrentio declare idPrefixes ["tt","kitsu"] and address anime
// as "kitsu:<id>:<episode>". One catalog search turns a title into that id.

/// The anime-kitsu addon's search catalog (keyless, ~10-30 KB per answer).
pub const kitsu_catalog_base = "https://anime-kitsu.strem.fun";
pub const max_kitsu_response: usize = 256 * 1024;
pub const kitsu_timeout_secs: u32 = 6;
/// Probe id for "does this addon serve the kitsu prefix at all".
pub const kitsu_probe_id = "kitsu:1:1";

/// Kitsu is asked only when the IMDb route has nothing to query with, or the
/// caller already knows the title is anime. An IMDb hit keeps its own path.
pub fn wantsKitsu(imdb_found: bool, intent: []const u8) bool {
    return !imdb_found or std.ascii.eqlIgnoreCase(intent, "anime");
}

/// The IMDb route returned no stream rows and Kitsu has not been asked yet.
/// Regression: no caller passed the anime intent and TMDB usually finds a tt id
/// for anime, so the Kitsu route was unreachable for the titles that need it.
pub fn wantsKitsuFallback(rows: usize, kitsu_tried: bool) bool {
    return rows == 0 and !kitsu_tried;
}

test "regression: an IMDb route with no rows falls back to Kitsu once" {
    try std.testing.expect(wantsKitsuFallback(0, false));
    try std.testing.expect(!wantsKitsuFallback(0, true));
    try std.testing.expect(!wantsKitsuFallback(3, false));
}

/// Alternative names Kitsu uses for season `season` of `title`:
/// "T Season 2", "T 2nd Season", "T 2". Index past the last returns null.
pub fn kitsuSeasonVariant(buf: []u8, title: []const u8, season: i32, variant: usize) ?[]const u8 {
    const t = std.mem.trim(u8, title, " \t");
    if (t.len == 0 or season < 2) return null;
    const suffix: []const u8 = switch (@mod(season, 100)) {
        11, 12, 13 => "th",
        else => switch (@mod(season, 10)) {
            1 => "st",
            2 => "nd",
            3 => "rd",
            else => "th",
        },
    };
    return switch (variant) {
        0 => std.fmt.bufPrint(buf, "{s} Season {d}", .{ t, season }) catch null,
        1 => std.fmt.bufPrint(buf, "{s} {d}{s} Season", .{ t, season, suffix }) catch null,
        2 => std.fmt.bufPrint(buf, "{s} {d}", .{ t, season }) catch null,
        else => null,
    };
}

test "kitsuSeasonVariant covers the naming styles Kitsu uses" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Re Zero Season 2", kitsuSeasonVariant(&b, "Re Zero", 2, 0).?);
    try std.testing.expectEqualStrings("Re Zero 2nd Season", kitsuSeasonVariant(&b, "Re Zero", 2, 1).?);
    try std.testing.expectEqualStrings("Re Zero 3rd Season", kitsuSeasonVariant(&b, "Re Zero", 3, 1).?);
    try std.testing.expectEqualStrings("X 12th Season", kitsuSeasonVariant(&b, "X", 12, 1).?);
    try std.testing.expectEqualStrings("Re Zero 2", kitsuSeasonVariant(&b, "Re Zero", 2, 2).?);
    try std.testing.expect(kitsuSeasonVariant(&b, "Re Zero", 2, 3) == null);
    try std.testing.expect(kitsuSeasonVariant(&b, "Re Zero", 1, 0) == null);
}

/// Kitsu lists each season as its own entry ("Attack on Titan Season 2"), so a
/// later season is looked up by that name; episodes then count from 1 again.
pub fn kitsuLookupTitle(buf: []u8, title: []const u8, season: i32) ?[]const u8 {
    const trimmed = std.mem.trim(u8, title, " \t");
    if (trimmed.len == 0) return null;
    if (season > 1) return std.fmt.bufPrint(buf, "{s} Season {d}", .{ trimmed, season }) catch null;
    return std.fmt.bufPrint(buf, "{s}", .{trimmed}) catch null;
}

/// Catalog search URL; the title is one percent-encoded path segment.
pub fn kitsuSearchUrl(buf: []u8, title: []const u8) ?[]const u8 {
    const head = kitsu_catalog_base ++ "/catalog/anime/kitsu-anime-list/search=";
    const tail = ".json";
    if (title.len == 0 or buf.len < head.len + tail.len) return null;
    @memcpy(buf[0..head.len], head);
    var w: usize = head.len;
    for (title) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '~') {
            if (w + 1 + tail.len > buf.len) return null;
            buf[w] = c;
            w += 1;
        } else {
            if (w + 3 + tail.len > buf.len) return null;
            _ = std.fmt.bufPrint(buf[w..][0..3], "%{X:0>2}", .{c}) catch return null;
            w += 3;
        }
    }
    @memcpy(buf[w..][0..tail.len], tail);
    return buf[0 .. w + tail.len];
}

pub const KitsuMatch = struct { id: u32, is_movie: bool };

/// Same title once case, spacing and punctuation are ignored
/// ("Your Name." == "your name"). Never a prefix or substring match.
fn sameAnimeTitle(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    var seen = false;
    while (true) {
        while (i < a.len and !(std.ascii.isAlphanumeric(a[i]) or a[i] >= 0x80)) i += 1;
        while (j < b.len and !(std.ascii.isAlphanumeric(b[j]) or b[j] >= 0x80)) j += 1;
        if (i == a.len or j == b.len) return seen and i == a.len and j == b.len;
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[j])) return false;
        seen = true;
        i += 1;
        j += 1;
    }
}

fn kitsuNumber(meta: std.json.ObjectMap) ?u32 {
    const id = meta.get("id") orelse return null;
    if (id != .string or !std.mem.startsWith(u8, id.string, "kitsu:")) return null;
    const n = std.fmt.parseInt(u32, id.string["kitsu:".len..], 10) catch return null;
    return if (n == 0) null else n;
}

/// The Kitsu entry whose name or alias IS `title`, out of a catalog search
/// body. The search is fuzzy (q=cowboy bebop also returns "Be-Bop Highschool"),
/// so never "the first result": a wrong id streams another show.
pub fn pickKitsu(allocator: std.mem.Allocator, body: []const u8, title: []const u8) ?KitsuMatch {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const metas = parsed.value.object.get("metas") orelse return null;
    if (metas != .array) return null;
    for (metas.array.items) |meta| {
        if (meta != .object) continue;
        const id = kitsuNumber(meta.object) orelse continue;
        var hit = false;
        if (meta.object.get("name")) |name| {
            if (name == .string and sameAnimeTitle(name.string, title)) hit = true;
        }
        if (!hit) if (meta.object.get("aliases")) |aliases| {
            if (aliases == .array) for (aliases.array.items) |alias| {
                if (alias == .string and sameAnimeTitle(alias.string, title)) {
                    hit = true;
                    break;
                }
            };
        };
        if (!hit) continue;
        const kind = meta.object.get("type");
        return .{ .id = id, .is_movie = if (kind) |k| k == .string and std.mem.eql(u8, k.string, "movie") else false };
    }
    return null;
}

/// "kitsu:<id>" for a film, "kitsu:<id>:<episode>" otherwise. A series query
/// with no episode asks for episode 1 (the protocol has no "whole show" id).
pub fn kitsuStreamId(buf: []u8, match: KitsuMatch, episode: i32) ?[]const u8 {
    if (match.is_movie) return std.fmt.bufPrint(buf, "kitsu:{d}", .{match.id}) catch null;
    return std.fmt.bufPrint(buf, "kitsu:{d}:{d}", .{ match.id, @max(episode, 1) }) catch null;
}

/// Media types to try, in order, for a Kitsu id: addons file it under "anime"
/// (Torrentio) or under the plain movie/series type.
pub fn kitsuTypes(is_movie: bool) [2][]const u8 {
    return if (is_movie) .{ "movie", "anime" } else .{ "anime", "series" };
}

test "regression: anime resolves to a kitsu stream id when there is no IMDb id" {
    const a = std.testing.allocator;
    // Trimmed from anime-kitsu.strem.fun …/search=cowboy%20bebop.json (2026-11).
    const body =
        \\{"metas":[
        \\{"id":"kitsu:5817","type":"series","animeType":"OVA","name":"Be-Bop Highschool","aliases":["Be-Bop Highschool","Be-Bop High School"]},
        \\{"id":"kitsu:1","kitsu_id":"1","imdb_id":"tt0213338","type":"series","animeType":"TV","name":"Cowboy Bebop","aliases":["Cowboy Bebop"]},
        \\{"id":"kitsu:2","type":"movie","animeType":"movie","name":"Cowboy Bebop: Knockin' on Heaven's Door","aliases":["Cowboy Bebop: The Movie","Cowboy Bebop: Tengoku no Tobira"]},
        \\{"id":"tt123","type":"series","name":"Cowboy Bebop"}
        \\],"cacheMaxAge":43200}
    ;
    var id_buf: [32]u8 = undefined;
    var url_buf: [256]u8 = undefined;

    const show = pickKitsu(a, body, "cowboy bebop").?;
    try std.testing.expectEqual(@as(u32, 1), show.id);
    try std.testing.expect(!show.is_movie);
    const show_id = kitsuStreamId(&id_buf, show, 5).?;
    try std.testing.expectEqualStrings("kitsu:1:5", show_id);
    try std.testing.expectEqualStrings(
        "https://torrentio.strem.fun/stream/anime/kitsu:1:5.json",
        streamUrl(&url_buf, "https://torrentio.strem.fun/manifest.json", kitsuTypes(false)[0], show_id).?,
    );
    try std.testing.expectEqualStrings("kitsu:1:1", kitsuStreamId(&id_buf, show, 0).?);

    const film = pickKitsu(a, body, "Cowboy Bebop The Movie").?; // alias, punctuation-insensitive
    try std.testing.expectEqual(@as(u32, 2), film.id);
    try std.testing.expectEqualStrings("kitsu:2", kitsuStreamId(&id_buf, film, 3).?);
    try std.testing.expectEqualStrings("movie", kitsuTypes(true)[0]);

    // Fuzzy neighbours, prefixes and non-kitsu ids are never accepted.
    try std.testing.expectEqual(@as(?KitsuMatch, null), pickKitsu(a, body, "cowboy"));
    try std.testing.expectEqual(@as(?KitsuMatch, null), pickKitsu(a, body, "bebop"));
    try std.testing.expectEqual(@as(?KitsuMatch, null), pickKitsu(a, "{\"metas\":[]}", "cowboy bebop"));
    try std.testing.expectEqual(@as(?KitsuMatch, null), pickKitsu(a, "<html>", "cowboy bebop"));
    try std.testing.expectEqual(@as(?KitsuMatch, null), pickKitsu(a, body, " .. "));

    // The addon must declare the kitsu prefix to be asked at all.
    const torrentio = "{\"resources\":[{\"name\":\"stream\",\"types\":[\"movie\",\"series\",\"anime\"],\"idPrefixes\":[\"tt\",\"kitsu\"]}],\"types\":[\"movie\",\"series\",\"anime\",\"other\"]}";
    const watchhub = "{\"resources\":[\"stream\"],\"types\":[\"movie\",\"series\"],\"idPrefixes\":[\"tt\"]}";
    try std.testing.expectEqual(@as(?bool, true), servesStream(a, torrentio, "anime", show_id));
    try std.testing.expectEqual(@as(?bool, true), servesStream(a, torrentio, "anime", kitsu_probe_id));
    try std.testing.expectEqual(@as(?bool, false), servesStream(a, watchhub, "anime", show_id));
    try std.testing.expectEqual(@as(?bool, false), servesStream(a, watchhub, "series", show_id));

    try std.testing.expect(wantsKitsu(false, "auto"));
    try std.testing.expect(wantsKitsu(true, "anime"));
    try std.testing.expect(!wantsKitsu(true, "auto")); // the tt path is left alone
    try std.testing.expect(!wantsKitsu(true, "tv"));
}

test "kitsu lookup title and search URL are bounded and percent-encoded" {
    var buf: [256]u8 = undefined;
    var tbuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://anime-kitsu.strem.fun/catalog/anime/kitsu-anime-list/search=Fate%2Fstay%20night%3A%20UBW%20%26%20%3F%23%25%2B%3D.json",
        kitsuSearchUrl(&buf, "Fate/stay night: UBW & ?#%+=").?,
    );
    try std.testing.expectEqualStrings("Attack on Titan Season 2", kitsuLookupTitle(&tbuf, " Attack on Titan ", 2).?);
    try std.testing.expectEqualStrings("Attack on Titan", kitsuLookupTitle(&tbuf, "Attack on Titan", 1).?);
    try std.testing.expectEqualStrings("Attack on Titan", kitsuLookupTitle(&tbuf, "Attack on Titan", 0).?);
    try std.testing.expect(kitsuLookupTitle(&tbuf, "  ", 1) == null);
    try std.testing.expect(kitsuSearchUrl(&buf, "") == null);
    var small: [80]u8 = undefined;
    try std.testing.expect(kitsuSearchUrl(&small, "a title that cannot fit in the buffer") == null);
    const long: [300]u8 = @splat('x');
    try std.testing.expect(kitsuSearchUrl(&buf, &long) == null);
}

test "stream ids and URLs for the IMDb route keep their protocol shape" {
    var id_buf: [48]u8 = undefined;
    var url_buf: [128]u8 = undefined;
    const ep = imdbStreamId(&id_buf, "tt0903747", true, 1, 5).?;
    try std.testing.expectEqualStrings("tt0903747:1:5", ep);
    try std.testing.expectEqualStrings("https://addon.test/cfg/stream/series/tt0903747:1:5.json", streamUrl(&url_buf, "https://addon.test/cfg/manifest.json", "series", ep).?);
    try std.testing.expectEqualStrings("tt0903747", imdbStreamId(&id_buf, "tt0903747", true, 0, 0).?);
    try std.testing.expectEqualStrings("tt1160419", imdbStreamId(&id_buf, "tt1160419", false, 1, 5).?);
    var tiny: [8]u8 = undefined;
    try std.testing.expect(streamUrl(&tiny, "https://addon.test", "movie", "tt1") == null);
}

test "servesStream: only addons declaring a matching stream resource are queried" {
    const a = std.testing.allocator;
    // Captured manifest shapes (trimmed) from the live addons, 2026-11.
    const torrentio = "{\"resources\":[{\"name\":\"stream\",\"types\":[\"movie\",\"series\",\"anime\"],\"idPrefixes\":[\"tt\",\"kitsu\"]}],\"types\":[\"movie\",\"series\",\"anime\",\"other\"]}";
    const cinemeta = "{\"resources\":[\"catalog\",\"meta\",\"addon_catalog\"],\"types\":[\"movie\",\"series\"],\"idPrefixes\":[\"tt\"]}";
    const opensubs = "{\"resources\":[\"subtitles\"],\"types\":[\"movie\",\"series\"],\"idPrefixes\":[\"tt\"]}";
    const watchhub = "{\"resources\":[\"stream\"],\"types\":[\"movie\",\"series\"],\"idPrefixes\":[\"tt\"]}";
    const usatv = "{\"resources\":[\"catalog\",\"stream\",\"meta\"],\"types\":[\"tv\"],\"idPrefixes\":[\"ustv\"]}";
    const publicdomain = "{\"resources\":[\"catalog\",\"stream\"],\"types\":[\"movie\"],\"idPrefixes\":[\"tt\"]}";
    const mediafusion = "{\"resources\":[\"catalog\",{\"idPrefixes\":[\"tt\",\"tmdb:\"],\"name\":\"stream\",\"types\":[\"movie\",\"series\",\"tv\"]},{\"idPrefixes\":[\"mf\"],\"name\":\"meta\",\"types\":[\"movie\"]}],\"types\":[\"movie\",\"series\",\"tv\",\"events\"]}";
    const aiostreams_unconfigured = "{\"resources\":[],\"types\":[]}";

    try std.testing.expectEqual(@as(?bool, true), servesStream(a, torrentio, "movie", "tt1160419"));
    try std.testing.expectEqual(@as(?bool, true), servesStream(a, torrentio, "series", "tt0903747"));
    try std.testing.expectEqual(@as(?bool, false), servesStream(a, cinemeta, "movie", "tt1160419"));
    try std.testing.expectEqual(@as(?bool, false), servesStream(a, opensubs, "movie", "tt1160419"));
    try std.testing.expectEqual(@as(?bool, true), servesStream(a, watchhub, "series", "tt0903747"));
    try std.testing.expectEqual(@as(?bool, false), servesStream(a, usatv, "movie", "tt1160419"));
    try std.testing.expectEqual(@as(?bool, true), servesStream(a, publicdomain, "movie", "tt1160419"));
    try std.testing.expectEqual(@as(?bool, false), servesStream(a, publicdomain, "series", "tt0903747"));
    try std.testing.expectEqual(@as(?bool, true), servesStream(a, mediafusion, "movie", "tt1160419"));
    try std.testing.expectEqual(@as(?bool, false), servesStream(a, mediafusion, "movie", "kitsu:1"));
    try std.testing.expectEqual(@as(?bool, false), servesStream(a, aiostreams_unconfigured, "movie", "tt1160419"));
    try std.testing.expectEqual(@as(?bool, null), servesStream(a, "<!DOCTYPE html>", "movie", "tt1"));
    try std.testing.expectEqual(@as(?bool, null), servesStream(a, "{\"err\":\"not found\"}", "movie", "tt1"));
}

test "regression: one dead or non-stream addon does not fail the whole stremio source" {
    // q=dune: Torrentio produced rows; Cinemeta 404, Comet 403 and a refused
    // connection were each reported as transport_failed.
    try std.testing.expectEqual(lifecycle.SourceStatus.no_results, streamHttpOutcome(404));
    try std.testing.expectEqual(lifecycle.SourceStatus.unavailable, streamHttpOutcome(403));
    try std.testing.expectEqual(lifecycle.SourceStatus.transport_failed, streamHttpOutcome(null));
    try std.testing.expectEqual(lifecycle.SourceStatus.transport_failed, streamHttpOutcome(502));
    try std.testing.expectEqual(lifecycle.SourceStatus.done, streamHttpOutcome(200));

    // 404-only addons beside a producing addon leave the source clean.
    var reported = lifecycle.SourceStatus.searching;
    reported = lifecycle.mergeReported(reported, streamHttpOutcome(404));
    try std.testing.expectEqual(lifecycle.SourceStatus.done, lifecycle.finalize(reported, true));
    // A genuinely dead addon beside a producing one is partial, never failed.
    reported = lifecycle.mergeReported(reported, streamHttpOutcome(null));
    try std.testing.expectEqual(lifecycle.SourceStatus.partial, lifecycle.finalize(reported, true));
    // Nothing produced and only clean misses: no_results, not a network error.
    try std.testing.expectEqual(lifecycle.SourceStatus.no_results, lifecycle.finalize(streamHttpOutcome(404), false));
}

test "addonBase strips the manifest suffix and configured path survives" {
    try std.testing.expectEqualStrings("https://torrentio.strem.fun", addonBase("https://torrentio.strem.fun/manifest.json"));
    try std.testing.expectEqualStrings("https://torrentio.strem.fun/realdebrid=k", addonBase("https://torrentio.strem.fun/realdebrid=k/manifest.json"));
    try std.testing.expectEqualStrings("https://addon.test", addonBase("https://addon.test/"));
    try std.testing.expect(max_stream_response >= 512 * 1024);
}
