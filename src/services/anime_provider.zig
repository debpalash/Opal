//! Source-configured direct playback. Search -> exact show -> release session
//! -> host extractor, following the provider flow used by curd/anipy.
const std = @import("std");
const alloc = @import("../core/alloc.zig").allocator;
const pure = @import("anime_catalog_pure.zig");
const extractors = @import("anime_extractors.zig");
const Gate = @import("../core/latest_request.zig").Gate;
const rf = @import("reliable_fetch.zig");

pub fn resolvePahe(name: []const u8, alias: []const u8, ep: usize, gate: *const Gate, generation: u32) ?extractors.Resolved {
    var base_buf: [256]u8 = undefined;
    const configured = @import("../core/source_config.zig").copyValue("animepahe", "base", &base_buf) orelse return null;
    if (ep == 0) return null;
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
        const body = transport.fetch(url, scratch, .{ .referer = base, .timeout_secs = 8, .cancel_epoch = .{ .epoch32 = .{ .value = &gate.generation, .expected = generation } } }) orelse continue;
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
        const body = transport.fetch(url, scratch, .{ .referer = base, .timeout_secs = 8, .cancel_epoch = .{ .epoch32 = .{ .value = &gate.generation, .expected = generation } } }) orelse return null;
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
    const body = transport.fetch(url, scratch, .{ .referer = base, .timeout_secs = 8, .cancel_epoch = .{ .epoch32 = .{ .value = &gate.generation, .expected = generation } } }) orelse return null;
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
    var base_buf: [256]u8 = undefined;
    const configured = sc.copyValue("allanime", "base", &base_buf) orelse return null;
    const base = base_buf[0..configured.len];
    var ref_buf: [256]u8 = undefined;
    const ref = sc.copyValue("allanime", "referer", &ref_buf) orelse blk: {
        @memcpy(ref_buf[0..base.len], base);
        break :blk ref_buf[0..base.len];
    };
    return resolveAllAt(base, ref_buf[0..ref.len], name, alias, ep, gate, generation, .{});
}

fn graph(base: []const u8, referer: []const u8, query: []const u8, variables: anytype, scratch: []u8, transport: Transport, gate: *const Gate, generation: u32) ?[]const u8 {
    const json = std.json.Stringify.valueAlloc(alloc, variables, .{}) catch return null;
    defer alloc.free(json);
    var vb: [4096]u8 = undefined;
    var qb: [4096]u8 = undefined;
    var ub: [8192]u8 = undefined;
    const encode = @import("../core/http.zig").urlEncode;
    const url = std.fmt.bufPrint(&ub, "{s}/api?variables={s}&query={s}", .{ std.mem.trimEnd(u8, base, "/"), encode(json, &vb), encode(query, &qb) }) catch return null;
    return transport.fetch(url, scratch, .{ .referer = referer, .timeout_secs = 8, .cancel_epoch = .{ .epoch32 = .{ .value = &gate.generation, .expected = generation } } });
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
        const body = graph(base, referer, "query($search:SearchInput,$limit:Int,$page:Int,$translationType:VaildTranslationTypeEnumType){shows(search:$search,limit:$limit,page:$page,translationType:$translationType){edges{_id name}}}", .{ .search = .{ .query = term, .allowAdult = false, .allowUnknown = false }, .limit = 20, .page = 1, .translationType = "sub" }, scratch, transport, gate, generation) orelse continue;
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
    const body = graph(base, referer, "query($showId:String!,$translationType:VaildTranslationTypeEnumType!,$episodeString:String!){episode(showId:$showId,translationType:$translationType,episodeString:$episodeString){sourceUrls}}", .{ .showId = id_buf[0..id_len], .translationType = "sub", .episodeString = episode }, scratch, transport, gate, generation) orelse return null;
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
            const detail = transport.fetch(decoded, scratch, .{ .referer = referer, .timeout_secs = 8, .cancel_epoch = .{ .epoch32 = .{ .value = &gate.generation, .expected = generation } } }) orelse continue;
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
    var base_buf: [256]u8 = undefined;
    const configured = @import("../core/source_config.zig").copyValue("subsplease", "base", &base_buf) orelse return null;
    const base = std.mem.trimEnd(u8, base_buf[0..configured.len], "/");
    const scratch = alloc.alloc(u8, 4 * 1024 * 1024) catch return null;
    defer alloc.free(scratch);
    for ([_][]const u8{ name, alias }) |term| {
        if (!gate.isCurrent(generation)) return null;
        if (term.len == 0) continue;
        var encoded: [512]u8 = undefined;
        var ub: [1024]u8 = undefined;
        const url = std.fmt.bufPrint(&ub, "{s}/api/?f=search&tz=UTC&s={s}", .{ base, @import("../core/http.zig").urlEncode(term, &encoded) }) catch continue;
        const body = fetchSource(url, scratch, .{ .referer = base, .timeout_secs = 8, .cancel_epoch = .{ .epoch32 = .{ .value = &gate.generation, .expected = generation } } }) orelse continue;
        const doc = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch continue;
        defer doc.deinit();
        const magnet = pure.subsPleaseRelease(doc.value, name, alias, ep) orelse continue;
        if (!gate.isCurrent(generation) or magnet.len > out.len) return null;
        @memcpy(out[0..magnet.len], magnet);
        return out[0..magnet.len];
    }
    return null;
}

/// Installed HiAnime source: exact show, requested episode, advertised video stream.
pub fn resolveHiAnime(name: []const u8, alias: []const u8, ep: usize, gate: *const Gate, generation: u32) ?extractors.Resolved {
    var base_buf: [256]u8 = undefined;
    const raw = @import("../core/source_config.zig").copyValue("hianime", "base", &base_buf) orelse return null;
    return resolveHiAt(std.mem.trimEnd(u8, base_buf[0..raw.len], "/"), name, alias, ep, gate, generation, .{ .fetch = fetchHiSource });
}

fn resolveHiAt(base: []const u8, name: []const u8, alias: []const u8, ep: usize, gate: *const Gate, generation: u32, transport: Transport) ?extractors.Resolved {
    const hp = @import("anime_hianime_pure.zig");
    if (ep == 0 or !gate.isCurrent(generation)) return null;
    const scratch = alloc.alloc(u8, 1024 * 1024) catch return null;
    defer alloc.free(scratch);
    var slug_buf: [160]u8 = undefined;
    var slug_len: usize = 0;
    var ub: [2048]u8 = undefined;
    for ([_][]const u8{ name, alias }) |term| {
        if (!gate.isCurrent(generation)) return null;
        if (term.len == 0 or term.len > 256) continue;
        var enc: [1024]u8 = undefined;
        const url = std.fmt.bufPrint(&ub, "{s}/search?keyword={s}", .{ base, @import("../core/http.zig").urlEncode(term, &enc) }) catch continue;
        const body = transport.fetch(url, scratch, .{ .referer = base, .timeout_secs = 8, .cancel_epoch = .{ .epoch32 = .{ .value = &gate.generation, .expected = generation } } }) orelse continue;
        const slug = hp.showSlug(body, name, alias) orelse continue;
        @memcpy(slug_buf[0..slug.len], slug);
        slug_len = slug.len;
        break;
    }
    if (slug_len == 0 or !gate.isCurrent(generation)) return null;
    const slug = slug_buf[0..slug_len];
    const dash = std.mem.lastIndexOfScalar(u8, slug, '-') orelse return null;
    const episodes_url = std.fmt.bufPrint(&ub, "{s}/api/theme/episode/list/{s}", .{ base, slug[dash + 1 ..] }) catch return null;
    const episode_body = transport.fetch(episodes_url, scratch, .{ .referer = base, .timeout_secs = 8, .cancel_epoch = .{ .epoch32 = .{ .value = &gate.generation, .expected = generation } } }) orelse return null;
    if (!gate.isCurrent(generation)) return null;
    const episode_doc = std.json.parseFromSlice(std.json.Value, alloc, episode_body, .{}) catch return null;
    defer episode_doc.deinit();
    const id = hp.episodeId(pure.string(pure.field(episode_doc.value, "html")), ep) orelse return null;
    const servers_url = std.fmt.bufPrint(&ub, "{s}/api/theme/episode/servers?episodeId={s}", .{ base, id }) catch return null;
    const server_body = transport.fetch(servers_url, scratch, .{ .referer = base, .timeout_secs = 8, .cancel_epoch = .{ .epoch32 = .{ .value = &gate.generation, .expected = generation } } }) orelse return null;
    if (!gate.isCurrent(generation)) return null;
    const server_doc = std.json.parseFromSlice(std.json.Value, alloc, server_body, .{}) catch return null;
    defer server_doc.deinit();
    var embed_buf: [1024]u8 = undefined;
    const embed_url = hp.embed(pure.string(pure.field(server_doc.value, "html")), &embed_buf) orelse return null;
    const embed_body = transport.fetch(embed_url, scratch, .{ .referer = base, .timeout_secs = 8, .cancel_epoch = .{ .epoch32 = .{ .value = &gate.generation, .expected = generation } } }) orelse return null;
    if (!gate.isCurrent(generation)) return null;
    const decoded = alloc.alloc(u8, 256 * 1024) catch return null;
    defer alloc.free(decoded);
    const config = hp.configJson(embed_body, decoded) orelse return null;
    const config_doc = std.json.parseFromSlice(std.json.Value, alloc, config, .{}) catch return null;
    defer config_doc.deinit();
    const stream = hp.streamUrl(config_doc.value) orelse return null;
    if (!gate.isCurrent(generation)) return null;
    return directStream(stream, "https://zokoanime.video/");
}

fn fetchHiSource(url: []const u8, scratch: []u8, opts: rf.Opts) ?[]const u8 {
    var base_buf: [256]u8 = undefined;
    const raw = @import("../core/source_config.zig").copyValue("hianime", "base", &base_buf) orelse return null;
    var same: [2048]u8 = undefined;
    if (@import("content_html_pure.zig").sourceUrl(&same, base_buf[0..raw.len], url) == null) return fetchSource(url, scratch, opts);
    var headers: [2048]u8 = undefined;
    const result = @import("source_request.zig").request("hianime", url, scratch, &headers, .{ .base = base_buf[0..raw.len], .ttl_ms = 30_000, .validate = validHiMetadata, .transport = opts });
    return if (result.ok()) result.body else null;
}

test "Anime provider HiAnime independent playback resolves real requested identity and cancels between hops" {
    const Fixture = struct {
        var calls: usize = 0;
        var cancel_gate: ?*Gate = null;
        fn fetch(url: []const u8, _: []u8, opts: rf.Opts) ?[]const u8 {
            calls += 1;
            const epoch = opts.cancel_epoch orelse return null;
            switch (epoch) {
                .epoch32 => |e| if (e.value.load(.acquire) != e.expected) return null,
                else => return null,
            }
            if (cancel_gate) |gate| {
                _ = gate.generation.fetchAdd(1, .acq_rel);
                return "stale";
            }
            if (std.mem.indexOf(u8, url, "/search?") != null) return "<a href='/example-1335' title='Example'>Example</a>";
            if (std.mem.indexOf(u8, url, "/episode/list/1335") != null) return "{\"html\":\"<a data-number='1' data-id='1'></a><a data-number='2' data-id='2'></a>\"}";
            if (std.mem.indexOf(u8, url, "episodeId=2") != null) return "{\"html\":\"<div data-type='sub' data-server-name='ZokoAnime' data-hash='aHR0cHM6Ly96b2tvYW5pbWUudmlkZW8vc3RyZWFtL21hbC8yMC8yL3N1Yg=='></div>\"}";
            if (std.mem.eql(u8, url, "https://zokoanime.video/stream/mal/20/2/sub")) return "window.__P=\"FFYSGRYPX08KERBdBQtAWxcCEUgKQxYAF1lZVB9GTwZGWF1PHw==\"";
            return null;
        }
    };
    const app = &@import("../core/state.zig").app;
    const browse_count = app.anime.result_count;
    defer app.anime.result_count = browse_count;
    app.anime.result_count = 1;
    var gate: Gate = .{};
    var loading = std.atomic.Value(bool).init(false);
    const generation = gate.begin(&loading);
    const result = resolveHiAt("https://site.test", "Example", "", 2, &gate, generation, .{ .fetch = Fixture.fetch }) orelse return error.MissingStream;
    try std.testing.expectEqualStrings("https://video.test/ep2.m3u8", result.streamUrl());
    try std.testing.expectEqualStrings("https://zokoanime.video/", result.refererStr());
    try std.testing.expectEqual(@as(usize, 4), Fixture.calls);
    try std.testing.expectEqual(@as(usize, 1), app.anime.result_count);
    Fixture.calls = 0;
    Fixture.cancel_gate = &gate;
    defer Fixture.cancel_gate = null;
    try std.testing.expect(resolveHiAt("https://site.test", "Example", "", 2, &gate, generation, .{ .fetch = Fixture.fetch }) == null);
    try std.testing.expectEqual(@as(usize, 1), Fixture.calls);
    try std.testing.expectEqual(@as(usize, 1), app.anime.result_count);
}

fn validHiMetadata(body: []const u8) bool {
    if (std.mem.indexOf(u8, body, "film-name") != null and std.mem.indexOf(u8, body, "Just a moment") == null) return true;
    const doc = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return false;
    defer doc.deinit();
    const status = pure.field(doc.value, "status");
    return status == .bool and status.bool and pure.field(doc.value, "html") == .string;
}
