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
    fetch: *const fn ([]const u8, []u8, rf.Opts) ?[]const u8 = rf.fetch,
    extract: *const fn ([]const u8) ?extractors.Resolved = extractors.resolveEmbed,
};

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
