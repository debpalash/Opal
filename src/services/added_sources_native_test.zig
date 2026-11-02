//! Optional live-response replay through the shipped parsers. Public provider
//! responses are kept outside the repository; normal CI uses pure fixtures.
const std = @import("std");
const io = @import("../core/io_global.zig");
const alloc = @import("../core/alloc.zig").allocator;
fn read(root: []const u8, name: []const u8) ![]u8 {
    var path: [1024]u8 = undefined;
    return io.cwdReadFileAlloc(try std.fmt.bufPrint(&path, "{s}/{s}.response", .{ root, name }), alloc, 4 * 1024 * 1024);
}
test "Browse regression added source recorded live responses" {
    const root = io.getenv("OPAL_LIVE_SOURCE_FIXTURES") orelse return error.SkipZigTest;
    const wallpaper = @import("wallpapers_pure.zig");
    const rows = try alloc.alloc(wallpaper.Row, 24);
    defer alloc.free(rows);
    for ([_]struct { source: wallpaper.Source, file: []const u8 }{ .{ .source = .mixkit, .file = "mixkit" }, .{ .source = .commons, .file = "commons-video" } }) |provider| {
        const body = try read(root, provider.file);
        defer alloc.free(body);
        const count = try wallpaper.parse(alloc, provider.source, body, rows);
        try std.testing.expect(count > 0);
        for (rows[0..count]) |row| {
            try std.testing.expectEqual(wallpaper.Media.video, row.media);
            try std.testing.expect(wallpaper.mediaUrl(row.original.text()));
            try std.testing.expect(wallpaper.mediaUrl(row.preview.text()));
        }
        std.debug.print("Live response replay: {s}, {d} playable video rows\n", .{ @tagName(provider.source), count });
    }
    const webcomic = @import("webcomic_sources_pure.zig");
    const comics = try alloc.alloc(webcomic.Item, 12);
    defer alloc.free(comics);
    const panels = try read(root, "pdl-search");
    defer alloc.free(panels);
    const doc = try std.json.parseFromSlice(std.json.Value, alloc, panels, .{});
    defer doc.deinit();
    const listing = webcomic.parseWordpressPosts(doc.value, "https://poorlydrawnlines.com", comics);
    try std.testing.expect(listing.valid and listing.count > 0);
    std.debug.print("Live response replay: Poorly Drawn Lines, {d} complete comic panels\n", .{listing.count});
    const reading = @import("search_reading_pure.zig");
    const books = try alloc.alloc(reading.Item, 12);
    defer alloc.free(books);
    const catalog = try read(root, "rnf-search-full");
    defer alloc.free(catalog);
    const found = reading.parseInto(catalog, "https://readnovelfull.com", .readnovelfull, books);
    try std.testing.expect(found.valid_listing and found.count > 0);
    const expanded = @import("expanded_reading_pure.zig");
    const detail = try read(root, "rnf-work");
    defer alloc.free(detail);
    var address: [1024]u8 = undefined;
    try std.testing.expect(expanded.readNovelFullChaptersUrl(&address, "https://readnovelfull.com", detail) != null);
    const directory = try read(root, "rnf-toc");
    defer alloc.free(directory);
    var it: expanded.html.AnchorIter = .{ .html = directory, .path = "/chapter-" };
    var chapter_count: usize = 0;
    while (it.next()) |item| {
        if (expanded.readNovelFullChapter(&address, "https://readnovelfull.com", "https://readnovelfull.com/world-defying-dan-god-v1.html", item.url) != null) chapter_count += 1;
    }
    try std.testing.expect(chapter_count > 400);
    const chapter = try read(root, "rnf-chapter");
    defer alloc.free(chapter);
    const text = @import("novel_sources_pure.zig").chapterContentHtml(chapter, .readnovelfull) orelse return error.NoChapterContent;
    try std.testing.expect(text.len > 1000);
    std.debug.print("Live response replay: ReadNovelFull, {d} works, {d} numbered chapters and full prose body\n", .{ found.count, chapter_count });
}

test "Browse regression western source recorded catalog issue and full page responses" {
    const root = io.getenv("OPAL_LIVE_SOURCE_FIXTURES") orelse return error.SkipZigTest;
    const western = @import("western_comics_pure.zig");
    const rows = try alloc.alloc(western.Item, 24);
    defer alloc.free(rows);
    const issues = try alloc.alloc(western.Issue, 512);
    defer alloc.free(issues);
    const pages = try alloc.alloc(western.Page, 128);
    defer alloc.free(pages);
    const providers = [_]struct { source: western.Provider, prefix: []const u8, base: []const u8, work: []const u8 }{
        .{ .source = .latestcomics, .prefix = "latest", .base = "https://www.latestcomics.com", .work = "https://www.latestcomics.com/en/comic/invincible-2003.html" },
        .{ .source = .ysk, .prefix = "ysk", .base = "https://www.ysk-comics.com", .work = "https://www.ysk-comics.com/comic/Invincible-2003" },
        .{ .source = .xoxo, .prefix = "xoxo", .base = "https://xoxocomic.com", .work = "https://xoxocomic.com/comic/invincible" },
    };
    for (providers) |provider| {
        var name: [64]u8 = undefined;
        const catalog = try read(root, try std.fmt.bufPrint(&name, "{s}-search", .{provider.prefix}));
        defer alloc.free(catalog);
        var count: usize = 0;
        if (provider.source == .ysk) {
            const doc = try std.json.parseFromSlice(std.json.Value, alloc, catalog, .{});
            defer doc.deinit();
            count = western.yskItems(doc.value, provider.base, rows);
        } else count = western.htmlItems(catalog, provider.source, provider.base, rows);
        try std.testing.expect(count > 0);
        var matched = false;
        for (rows[0..count]) |*row| {
            try std.testing.expect(row.title.len > 0 and row.cover.len > 0);
            const route = western.splitRoute(row.route.get()).?;
            if (std.mem.eql(u8, route.work, provider.work)) matched = true;
        }
        try std.testing.expect(matched);
        var issue_count: usize = 0;
        if (provider.source == .ysk) {
            for ([_][]const u8{ "ysk-issues", "ysk-issues-2" }) |file| {
                const response = try read(root, file);
                defer alloc.free(response);
                const doc = try std.json.parseFromSlice(std.json.Value, alloc, response, .{});
                defer doc.deinit();
                _ = western.yskIssues(doc.value, provider.base, issues, &issue_count) orelse return error.InvalidIssueBatch;
            }
            try std.testing.expectEqual(@as(usize, 13), issue_count);
        } else {
            const work = try read(root, try std.fmt.bufPrint(&name, "{s}-work", .{provider.prefix}));
            defer alloc.free(work);
            try std.testing.expect(western.htmlIssues(work, provider.source, provider.base, provider.work, issues, &issue_count));
            if (provider.source == .latestcomics) {
                try std.testing.expect(western.latestCursor(work) != null);
                const more = try read(root, "latest-more");
                defer alloc.free(more);
                const doc = try std.json.parseFromSlice(std.json.Value, alloc, more, .{});
                defer doc.deinit();
                const batch = western.latestBatch(doc.value).?;
                const before = issue_count;
                try std.testing.expect(western.htmlIssues(batch.body, provider.source, provider.base, provider.work, issues, &issue_count));
                try std.testing.expect(issue_count > before);
            }
        }
        if (provider.source == .xoxo) {
            const first = try read(root, "xoxo-work");
            defer alloc.free(first);
            try std.testing.expect(western.xoxoHasNext(first, provider.work, 1));
            for (2..5) |page| {
                const response = try read(root, try std.fmt.bufPrint(&name, "xoxo-issues-{d}", .{page}));
                defer alloc.free(response);
                try std.testing.expect(western.htmlIssues(response, provider.source, provider.base, provider.work, issues, &issue_count));
                try std.testing.expectEqual(page < 4, western.xoxoHasNext(response, provider.work, @intCast(page)));
            }
            try std.testing.expect(issue_count >= 145);
        }
        try std.testing.expect(issue_count > 0);
        western.sortIssues(issues[0..issue_count]);
        const manifest = try read(root, try std.fmt.bufPrint(&name, "{s}-pages", .{provider.prefix}));
        defer alloc.free(manifest);
        var page_count: usize = 0;
        if (provider.source == .ysk) {
            const doc = try std.json.parseFromSlice(std.json.Value, alloc, manifest, .{});
            defer doc.deinit();
            page_count = western.yskPages(doc.value, pages) orelse return error.InvalidPageManifest;
        } else page_count = western.htmlPages(manifest, provider.source, pages) orelse return error.InvalidPageManifest;
        try std.testing.expect(page_count > 1);
        std.debug.print("Live response replay: {s}, {d} works, {d} issues, {d} complete pages\n", .{ provider.source.label(), count, issue_count, page_count });
    }
}

test "Browse regression western optional live metadata pipeline in isolated config" {
    if (io.getenv("OPAL_LIVE_WESTERN_LOAD") == null) return error.SkipZigTest;
    // The opt-in caller must explicitly supply an isolated profile.
    const directory = io.getenv("XDG_CONFIG_HOME") orelse return error.MissingIsolatedConfig;
    if (!std.mem.startsWith(u8, directory, "/tmp/opal-western-live-")) return error.UnsafeTestConfig;
    const workers = @import("../core/workers.zig");
    const config = @import("../core/source_config.zig");
    const western = @import("western_comics.zig");
    workers.init();
    defer {
        workers.beginShutdownAndDrain(0);
        @import("source_request.zig").deinit();
        workers.finishShutdown();
        workers.init(); // The shared browse test runner continues after this case.
    }
    const sources = [_]struct { provider: western.Provider, endpoints: []const u8, route: []const u8, minimum: usize }{
        .{ .provider = .latestcomics, .endpoints = "{\"base\":\"https://www.latestcomics.com\"}", .route = "latestcomics:https://www.latestcomics.com/en/comic/invincible-2003.html", .minimum = 144 },
        .{ .provider = .ysk, .endpoints = "{\"base\":\"https://www.ysk-comics.com\",\"api\":\"https://api.ysk-comics.com/api/v1\"}", .route = "ysk:https://www.ysk-comics.com/comic/Invincible-2003", .minimum = 13 },
        .{ .provider = .imagecomics, .endpoints = "{\"base\":\"https://imagecomics.com\"}", .route = "imagecomics:https://imagecomics.com/read/skyward", .minimum = 1 },
        .{ .provider = .globalcomix, .endpoints = "{\"base\":\"https://globalcomix.com\",\"api\":\"https://api.globalcomix.com\"}", .route = "globalcomix:https://globalcomix.com/c/exciting-comics", .minimum = 2 },
    };
    var generation: std.atomic.Value(u32) = .init(1);
    const cancel: @import("../core/bounded_process.zig").CancelEpoch = .{ .epoch32 = .{ .value = &generation, .expected = 1 } };
    for (sources) |source| {
        try std.testing.expect(config.install(@tagName(source.provider), source.endpoints));
        const book = try western.load(source.route, cancel);
        defer book.deinit();
        try std.testing.expect(book.count >= source.minimum and book.page_count > 0);
        for (book.chapters[0 .. book.count - 1], book.chapters[1..book.count]) |*a, *b| try std.testing.expect(a.number <= b.number);
        std.debug.print("Live production reader: {s}, {d} issues, {d} pages, selected {s}\n", .{ source.provider.label(), book.count, book.page_count, book.chapters[book.selected].title.get() });
    }
}

test "Browse regression western publisher recorded complete reader responses" {
    const root = io.getenv("OPAL_PUBLISHER_FIXTURES") orelse return error.SkipZigTest;
    const publisher = @import("western_publishers_pure.zig");
    const model = @import("western_comics_pure.zig");
    const items = try alloc.alloc(model.Item, 24);
    defer alloc.free(items);
    const pages = try alloc.alloc(model.Page, 128);
    defer alloc.free(pages);
    const issues = try alloc.alloc(model.Issue, 512);
    defer alloc.free(issues);
    const catalog = try read(root, "image-catalog");
    defer alloc.free(catalog);
    try std.testing.expectEqual(@as(usize, 1), publisher.imageItems(catalog, "https://imagecomics.com", "skyward", 1, items));
    try std.testing.expectEqualStrings("Skyward", items[0].title.get());
    const images = try read(root, "image-pages");
    defer alloc.free(images);
    try std.testing.expectEqual(@as(usize, 30), publisher.imagePages(images, "https://imagecomics.com/read/skyward", pages).?);
    const search = try read(root, "global-search");
    defer alloc.free(search);
    const search_doc = try std.json.parseFromSlice(std.json.Value, alloc, search, .{});
    defer search_doc.deinit();
    const found = publisher.globalItems(search_doc.value, "https://globalcomix.com", items);
    try std.testing.expect(found > 0);
    var matched = false;
    for (items[0..found]) |*item| if (std.mem.indexOf(u8, item.route.get(), "/c/exciting-comics") != null) {
        matched = true;
    };
    try std.testing.expect(matched);
    const work = try read(root, "global-work");
    defer alloc.free(work);
    try std.testing.expect(publisher.globalClient(work) != null);
    const state_body = publisher.globalState(work) orelse return error.InvalidPublisherState;
    const state_doc = try std.json.parseFromSlice(std.json.Value, alloc, state_body, .{});
    defer state_doc.deinit();
    try std.testing.expectEqual(@as(usize, 2), publisher.globalIssues(state_doc.value, "https://globalcomix.com", "https://globalcomix.com/c/exciting-comics", issues).?);
    const manifest = try read(root, "global-pages");
    defer alloc.free(manifest);
    const manifest_doc = try std.json.parseFromSlice(std.json.Value, alloc, manifest, .{});
    defer manifest_doc.deinit();
    try std.testing.expectEqual(@as(usize, 36), publisher.globalPages(manifest_doc.value, pages).?);
    std.debug.print("Publisher replay: Image Comics complete 30-page issue; GlobalComix 2 complete free issues / 59 releases, 36 pages\n", .{});
}
