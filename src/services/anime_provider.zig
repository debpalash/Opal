//! Source-configured direct playback. Search -> exact show -> release session
//! -> host extractor, following the provider flow used by curd/anipy.
const std = @import("std");
const alloc = @import("../core/alloc.zig").allocator;
const pure = @import("anime_catalog_pure.zig");
const extractors = @import("anime_extractors.zig");
const Gate = @import("../core/latest_request.zig").Gate;
const rf = @import("reliable_fetch.zig");

pub fn resolvePahe(name: []const u8, alias: []const u8, ep: usize, gate: *const Gate, generation: u32) ?extractors.Resolved {
    const configured = @import("../core/source_config.zig").get("animepahe", "base") orelse return null;
    var base_buf: [256]u8 = undefined;
    if (configured.len > base_buf.len or ep == 0) return null;
    @memcpy(base_buf[0..configured.len], configured);
    return resolveAt(std.mem.trimEnd(u8, base_buf[0..configured.len], "/"), name, alias, ep, gate, generation, .{});
}

const Transport = struct {
    fetch: *const fn ([]const u8, []u8, rf.Opts) ?[]const u8 = fetchSource,
    extract: *const fn ([]const u8) ?extractors.Resolved = extractors.resolveEmbed,
};

fn fetchSource(url: []const u8, scratch: []u8, opts: rf.Opts) ?[]const u8 {
    var headers: [16 * 1024]u8 = undefined;
    const response = rf.request(url, scratch, &headers, opts);
    if (response.ok()) return response.body;
    var message: [160]u8 = undefined;
    const host_start: usize = if (std.mem.indexOf(u8, url, "://")) |i| i + 3 else 0;
    const host_end = std.mem.indexOfScalarPos(u8, url, host_start, '/') orelse url.len;
    const authority = url[host_start..host_end];
    const safe_host = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority[at + 1 ..] else authority;
    const host = safe_host[0..@min(80, safe_host.len)];
    const line = std.fmt.bufPrint(&message, "Source {s}: HTTP {d}, {s}", .{ host, response.status, @tagName(response.failure) }) catch "Anime source request failed";
    @import("../core/logs.zig").pushLog("warn", "anime", line, false);
    return null;
}

fn resolveAt(base: []const u8, name: []const u8, alias: []const u8, ep: usize, gate: *const Gate, generation: u32, transport: Transport) ?extractors.Resolved {
    const scratch = alloc.alloc(u8, 1024 * 1024) catch return null;
    defer alloc.free(scratch);
    var show_buf: [128]u8 = undefined;
    var show_len: usize = 0;
    for ([_][]const u8{ name, alias }) |query| {
        if (!gate.isCurrent(generation)) return null;
        if (query.len == 0) continue;
        var encoded: [512]u8 = undefined;
        var ub: [1024]u8 = undefined;
        const url = std.fmt.bufPrint(&ub, "{s}/api?m=search&q={s}", .{ base, @import("../core/http.zig").urlEncode(query, &encoded) }) catch continue;
        const body = transport.fetch(url, scratch, .{ .referer = base, .timeout_secs = 8 }) orelse continue;
        const doc = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch continue;
        defer doc.deinit();
        const show = pure.paheShow(doc.value, name, alias) orelse continue;
        const session = pure.string(pure.field(show, "session"));
        if (session.len > show_buf.len) continue;
        @memcpy(show_buf[0..session.len], session);
        show_len = session.len;
        break;
    }
    if (show_len == 0) return null;
    const show = show_buf[0..show_len];
    var page: usize = 1;
    var release_buf: [128]u8 = undefined;
    var release_len: usize = 0;
    // First page supplies per_page. Jump to the requested ordinal, including
    // shows whose provider numbering starts at 13/25 rather than 1.
    for (0..2) |_| {
        if (!gate.isCurrent(generation)) return null;
        var ub: [1024]u8 = undefined;
        const url = std.fmt.bufPrint(&ub, "{s}/api?m=release&id={s}&sort=episode_asc&page={d}", .{ base, show, page }) catch return null;
        const body = transport.fetch(url, scratch, .{ .referer = base, .timeout_secs = 8 }) orelse return null;
        const doc = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return null;
        defer doc.deinit();
        const release = pure.paheRelease(doc.value, ep, page) orelse return null;
        if (release.page != page) {
            page = release.page;
            continue;
        }
        const session = release.session orelse return null;
        if (session.len == 0 or session.len > release_buf.len) return null;
        @memcpy(release_buf[0..session.len], session);
        release_len = session.len;
        break;
    }
    if (release_len == 0 or !gate.isCurrent(generation)) return null;
    var ub: [1024]u8 = undefined;
    const url = std.fmt.bufPrint(&ub, "{s}/play/{s}/{s}", .{ base, show, release_buf[0..release_len] }) catch return null;
    const body = transport.fetch(url, scratch, .{ .referer = base, .timeout_secs = 8 }) orelse return null;
    var rest = body;
    var tried: usize = 0;
    while (std.mem.indexOf(u8, rest, "data-src=\"")) |at| {
        rest = rest[at + 10 ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse break;
        const embed = rest[0..end];
        rest = rest[end + 1 ..];
        if (!gate.isCurrent(generation) or tried >= 4) return null;
        if (!std.mem.startsWith(u8, embed, "https://")) continue;
        tried += 1;
        if (transport.extract(embed)) |resolved| return resolved;
    }
    return null;
}

test "Anime playback AnimePahe resolves provider sessions rather than numeric watch URLs" {
    const Fixture = struct {
        var calls: usize = 0;
        fn fetch(url: []const u8, _: []u8, _: rf.Opts) ?[]const u8 {
            calls += 1;
            if (std.mem.indexOf(u8, url, "m=search") != null) return
            \\{"data":[{"title":"Example Season 2","session":"wrong"},{"title":"Example","session":"show-session"}]}
            ;
            if (std.mem.endsWith(u8, url, "m=release&id=show-session&sort=episode_asc&page=1")) return
            \\{"per_page":2,"data":[{"episode":13,"session":"ep13"},{"episode":14,"session":"ep14"}]}
            ;
            if (std.mem.endsWith(u8, url, "m=release&id=show-session&sort=episode_asc&page=2")) return
            \\{"per_page":2,"data":[{"episode":15,"session":"ep15"}]}
            ;
            if (std.mem.endsWith(u8, url, "/play/show-session/ep15")) return "<button data-src=\"https://kwik.cx/e/fixture\">Play</button>";
            return null;
        }
        fn extract(url: []const u8) ?extractors.Resolved {
            if (!std.mem.eql(u8, url, "https://kwik.cx/e/fixture")) return null;
            var result: extractors.Resolved = .{};
            const stream = "https://video.test/playlist.m3u8";
            @memcpy(result.stream_url[0..stream.len], stream);
            result.stream_len = stream.len;
            return result;
        }
    };
    var gate: Gate = .{};
    var loading = std.atomic.Value(bool).init(false);
    const gen = gate.begin(&loading);
    const stream = resolveAt("https://provider.test", "Example", "", 3, &gate, gen, .{ .fetch = Fixture.fetch, .extract = Fixture.extract }) orelse return error.MissingStream;
    try std.testing.expectEqualStrings("https://video.test/playlist.m3u8", stream.streamUrl());
    try std.testing.expectEqual(@as(usize, 4), Fixture.calls);
    gate.cancel(&loading);
    try std.testing.expect(resolveAt("https://provider.test", "Example", "", 3, &gate, gen, .{ .fetch = Fixture.fetch, .extract = Fixture.extract }) == null);
    try std.testing.expectEqual(@as(usize, 4), Fixture.calls);
}

/// Resolve an installed AllAnime source through show ID -> episode -> stream.
/// Resolver search rows are title records, never playable episode URLs.
pub fn resolveAllAnime(name: []const u8, alias: []const u8, ep: usize, gate: *const Gate, generation: u32) ?extractors.Resolved {
    const sc = @import("../core/source_config.zig");
    const configured = sc.get("allanime", "base") orelse return null;
    var base_buf: [256]u8 = undefined;
    if (configured.len > base_buf.len) return null;
    @memcpy(base_buf[0..configured.len], configured);
    const base = base_buf[0..configured.len];
    var ref_buf: [256]u8 = undefined;
    const ref = sc.get("allanime", "referer") orelse base;
    if (ref.len > ref_buf.len) return null;
    @memcpy(ref_buf[0..ref.len], ref);
    return resolveAllAt(base, ref_buf[0..ref.len], name, alias, ep, gate, generation, .{});
}

fn graph(base: []const u8, referer: []const u8, query: []const u8, variables: anytype, scratch: []u8, transport: Transport) ?[]const u8 {
    const json = std.json.Stringify.valueAlloc(alloc, variables, .{}) catch return null;
    defer alloc.free(json);
    var vb: [4096]u8 = undefined;
    var qb: [4096]u8 = undefined;
    var ub: [8192]u8 = undefined;
    const encode = @import("../core/http.zig").urlEncode;
    const url = std.fmt.bufPrint(&ub, "{s}/api?variables={s}&query={s}", .{ std.mem.trimEnd(u8, base, "/"), encode(json, &vb), encode(query, &qb) }) catch return null;
    return transport.fetch(url, scratch, .{ .referer = referer, .timeout_secs = 8 });
}

fn directStream(url: []const u8, referer: []const u8) ?extractors.Resolved {
    if ((!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) or url.len > 1024 or referer.len > 256) return null;
    var result: extractors.Resolved = .{};
    @memcpy(result.stream_url[0..url.len], url);
    result.stream_len = url.len;
    @memcpy(result.referer[0..referer.len], referer);
    result.referer_len = referer.len;
    return result;
}

fn resolveAllAt(base: []const u8, referer: []const u8, name: []const u8, alias: []const u8, ep: usize, gate: *const Gate, generation: u32, transport: Transport) ?extractors.Resolved {
    if (ep == 0 or !gate.isCurrent(generation)) return null;
    const scratch = alloc.alloc(u8, 1024 * 1024) catch return null;
    defer alloc.free(scratch);
    var id_buf: [128]u8 = undefined;
    var id_len: usize = 0;
    for ([_][]const u8{ name, alias }) |term| {
        if (term.len == 0 or !gate.isCurrent(generation)) continue;
        const body = graph(base, referer, "query($search:SearchInput,$limit:Int,$page:Int,$translationType:VaildTranslationTypeEnumType){shows(search:$search,limit:$limit,page:$page,translationType:$translationType){edges{_id name}}}", .{ .search = .{ .query = term, .allowAdult = false, .allowUnknown = false }, .limit = 20, .page = 1, .translationType = "sub" }, scratch, transport) orelse continue;
        const doc = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch continue;
        defer doc.deinit();
        const edges = pure.field(pure.field(pure.field(doc.value, "data"), "shows"), "edges");
        if (edges != .array) continue;
        for (edges.array.items) |row| {
            const title = pure.string(pure.field(row, "name"));
            const id = pure.string(pure.field(row, "_id"));
            if ((pure.titleMatches(title, name) or pure.titleMatches(title, alias)) and id.len > 0 and id.len <= id_buf.len) {
                @memcpy(id_buf[0..id.len], id);
                id_len = id.len;
                break;
            }
        }
        if (id_len > 0) break;
    }
    if (id_len == 0 or !gate.isCurrent(generation)) return null;
    var eb: [16]u8 = undefined;
    const episode = std.fmt.bufPrint(&eb, "{d}", .{ep}) catch return null;
    const body = graph(base, referer, "query($showId:String!,$translationType:VaildTranslationTypeEnumType!,$episodeString:String!){episode(showId:$showId,translationType:$translationType,episodeString:$episodeString){sourceUrls}}", .{ .showId = id_buf[0..id_len], .translationType = "sub", .episodeString = episode }, scratch, transport) orelse return null;
    const doc = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return null;
    defer doc.deinit();
    const sources = pure.field(pure.field(pure.field(doc.value, "data"), "episode"), "sourceUrls");
    if (sources != .array) return null;
    for (sources.array.items[0..@min(8, sources.array.items.len)]) |source| {
        if (!gate.isCurrent(generation)) return null;
        const raw = pure.string(pure.field(source, "sourceUrl"));
        if (raw.len == 0) continue;
        const decoded = if (std.mem.startsWith(u8, raw, "--"))
            @import("anime_scraper.zig").decodeSourceURL(alloc, raw, base) catch continue
        else
            alloc.dupe(u8, raw) catch continue;
        defer alloc.free(decoded);
        if (std.mem.indexOf(u8, decoded, ".m3u8") != null or std.mem.indexOf(u8, decoded, ".mp4") != null) {
            if (directStream(decoded, referer)) |result| return result;
        }
        if (std.mem.indexOf(u8, decoded, "/clock.json?") != null) {
            const detail = transport.fetch(decoded, scratch, .{ .referer = referer, .timeout_secs = 8 }) orelse continue;
            const links_doc = std.json.parseFromSlice(std.json.Value, alloc, detail, .{}) catch continue;
            defer links_doc.deinit();
            const links = pure.field(links_doc.value, "links");
            if (links != .array) continue;
            for (links.array.items) |link| {
                const url = pure.string(pure.field(link, "link"));
                const headers = pure.field(link, "headers");
                const header_ref = pure.string(pure.field(headers, "Referer"));
                if (directStream(url, if (header_ref.len > 0) header_ref else referer)) |result| return result;
            }
        } else if (transport.extract(decoded)) |result| return result;
    }
    return null;
}

test "Anime playback AllAnime resolves exact show and requested episode before playback" {
    const Fixture = struct {
        var calls: usize = 0;
        fn fetch(url: []const u8, _: []u8, _: rf.Opts) ?[]const u8 {
            calls += 1;
            if (std.mem.indexOf(u8, url, "episodeString") != null) {
                if (std.mem.indexOf(u8, url, "%222%22") == null) return null;
                return "{\"data\":{\"episode\":{\"sourceUrls\":[{\"sourceUrl\":\"https://video.test/ep2.m3u8\"}]}}}";
            }
            return "{\"data\":{\"shows\":{\"edges\":[{\"_id\":\"wrong\",\"name\":\"Example 2\"},{\"_id\":\"right\",\"name\":\"Example\"}]}}}";
        }
    };
    var gate: Gate = .{};
    var loading = std.atomic.Value(bool).init(false);
    const generation = gate.begin(&loading);
    const stream = resolveAllAt("https://source.test", "https://site.test", "Example", "", 2, &gate, generation, .{ .fetch = Fixture.fetch }) orelse return error.MissingStream;
    try std.testing.expectEqualStrings("https://video.test/ep2.m3u8", stream.streamUrl());
    try std.testing.expectEqualStrings("https://site.test", stream.refererStr());
    try std.testing.expectEqual(@as(usize, 2), Fixture.calls);
    gate.cancel(&loading);
    try std.testing.expect(resolveAllAt("https://source.test", "", "Example", "", 2, &gate, generation, .{ .fetch = Fixture.fetch }) == null);
}

/// An installed release index provides an exact episode magnet without relying
/// on generic title ranking or scraping a video host's player page.
pub fn resolveSubsPlease(name: []const u8, alias: []const u8, ep: usize, gate: *const Gate, generation: u32, out: []u8) ?[]const u8 {
    const configured = @import("../core/source_config.zig").get("subsplease", "base") orelse return null;
    var base_buf: [256]u8 = undefined;
    if (configured.len > base_buf.len) return null;
    @memcpy(base_buf[0..configured.len], configured);
    const base = std.mem.trimEnd(u8, base_buf[0..configured.len], "/");
    const scratch = alloc.alloc(u8, 4 * 1024 * 1024) catch return null;
    defer alloc.free(scratch);
    for ([_][]const u8{ name, alias }) |term| {
        if (!gate.isCurrent(generation)) return null;
        if (term.len == 0) continue;
        var encoded: [512]u8 = undefined;
        var ub: [1024]u8 = undefined;
        const url = std.fmt.bufPrint(&ub, "{s}/api/?f=search&tz=UTC&s={s}", .{ base, @import("../core/http.zig").urlEncode(term, &encoded) }) catch continue;
        const body = fetchSource(url, scratch, .{ .referer = base, .timeout_secs = 8 }) orelse continue;
        const doc = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch continue;
        defer doc.deinit();
        const magnet = pure.subsPleaseRelease(doc.value, name, alias, ep) orelse continue;
        if (!gate.isCurrent(generation) or magnet.len > out.len) return null;
        @memcpy(out[0..magnet.len], magnet);
        return out[0..magnet.len];
    }
    return null;
}
