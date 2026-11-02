//! Bounded, cancellable catalog → issue directory → complete page manifest.
const std = @import("std");
const alloc = @import("../core/alloc.zig").allocator;
const config = @import("../core/source_config.zig");
const bounded = @import("../core/bounded_process.zig");
const workers = @import("../core/workers.zig");
pub const pure = @import("western_comics_pure.zig");
pub const Provider = pure.Provider;
const publishers = @import("western_publishers_pure.zig");
const Endpoints = struct {
    base: pure.Field(512) = .{},
    api: pure.Field(512) = .{},
    fn read(provider: Provider) ?@This() {
        var result: @This() = .{};
        result.base.len = (config.copyValue(@tagName(provider), "base", &result.base.bytes) orelse return null).len;
        if (provider == .ysk or provider == .globalcomix) result.api.len = (config.copyValue(@tagName(provider), "api", &result.api.bytes) orelse return null).len;
        return result;
    }
};
fn get(provider: Provider, endpoints: *const Endpoints, url: []const u8, out: []u8, cancel: ?bounded.CancelEpoch, form: ?[]const u8) ?[]const u8 {
    var headers: [4096]u8 = undefined;
    const origin = [_]@import("reliable_fetch.zig").Header{ .{ .name = "Origin", .value = endpoints.base.get() }, .{ .name = "X-Requested-With", .value = "XMLHttpRequest" } };
    const result = @import("source_request.zig").request(@tagName(provider), url, out, &headers, .{
        .base = if (provider == .ysk) endpoints.api.get() else endpoints.base.get(),
        .ttl_ms = if (form == null) 60_000 else 0,
        .transport = .{ .timeout_secs = 15, .connect_timeout_secs = 6, .user_agent = "Mozilla/5.0", .referer = endpoints.base.get(), .headers = &origin, .cancel_epoch = cancel, .post_body = form, .https_only = true },
    });
    return if (result.ok()) result.body else null;
}
pub fn search(provider: Provider, query: []const u8, page: u32, cancel: ?bounded.CancelEpoch, out: []pure.Item) usize {
    const endpoints = Endpoints.read(provider) orelse return 0;
    var address: [2048]u8 = undefined;
    const url = pure.searchUrl(&address, provider, endpoints.base.get(), endpoints.api.get(), query, page) orelse return 0;
    if (provider == .globalcomix) return searchGlobal(&endpoints, url, cancel, out);
    const buf = alloc.alloc(u8, 4 * 1024 * 1024) catch return 0;
    defer alloc.free(buf);
    const body = get(provider, &endpoints, url, buf, cancel, null) orelse return 0;
    if (provider == .imagecomics) return publishers.imageItems(body, endpoints.base.get(), query, page, out);
    if (provider != .ysk) return pure.htmlItems(body, provider, endpoints.base.get(), out);
    const doc = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return 0;
    defer doc.deinit();
    return pure.yskItems(doc.value, endpoints.base.get(), out);
}
pub const Book = struct {
    chapters: [512]pure.Issue = @splat(.{}),
    count: usize = 0,
    selected: usize = 0,
    pages: [128]pure.Page = @splat(.{}),
    page_count: usize = 0,
    referer: pure.Field(512) = .{},
    pub fn deinit(self: *@This()) void {
        alloc.destroy(self);
    }
};
pub const Error = error{ Unavailable, InvalidRoute, TooLarge, MissingIssue, NoPages, ConfirmationRequired, OutOfMemory };
pub fn load(value: []const u8, cancel: ?bounded.CancelEpoch) Error!*Book {
    const identity = pure.splitRoute(value) orelse return error.InvalidRoute;
    const provider = identity.provider;
    const endpoints = Endpoints.read(provider) orelse return error.Unavailable;
    if (!pure.series(provider, endpoints.base.get(), identity.work)) return error.InvalidRoute;
    const book = try alloc.create(Book);
    book.* = .{};
    errdefer book.deinit();
    const buf = try alloc.alloc(u8, 4 * 1024 * 1024);
    defer alloc.free(buf);
    var address: [2048]u8 = undefined;
    if (provider == .imagecomics or provider == .globalcomix) {
        try loadPublisher(book, identity, &endpoints, cancel, buf);
        return book;
    }
    if (provider == .ysk) {
        var page: u32 = 1;
        while (page <= 1000) : (page += 1) {
            const url = pure.yskIssueUrl(&address, endpoints.api.get(), identity.work, page) orelse return error.InvalidRoute;
            const body = get(provider, &endpoints, url, buf, cancel, null) orelse return error.Unavailable;
            const doc = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return error.Unavailable;
            defer doc.deinit();
            const total = pure.yskIssues(doc.value, endpoints.base.get(), &book.chapters, &book.count) orelse return error.TooLarge;
            if (page >= total) break;
        }
    } else {
        const body = get(provider, &endpoints, identity.work, buf, cancel, null) orelse return error.Unavailable;
        if (!pure.htmlIssues(body, provider, endpoints.base.get(), identity.work, &book.chapters, &book.count)) return error.TooLarge;
        if (provider == .xoxo) {
            var page: u32 = 1;
            var current_body = body;
            while (pure.xoxoHasNext(current_body, identity.work, page)) {
                page += 1;
                if (page > 1000) return error.TooLarge;
                const url = pure.xoxoIssueListUrl(&address, identity.work, page) orelse return error.InvalidRoute;
                const before = book.count;
                current_body = get(provider, &endpoints, url, buf, cancel, null) orelse return error.Unavailable;
                if (!pure.htmlIssues(current_body, provider, endpoints.base.get(), identity.work, &book.chapters, &book.count)) return error.TooLarge;
                if (before == book.count) return error.Unavailable;
            }
        }
        if (provider == .latestcomics) {
            // Copy the cursor before reusing the response buffer. No JavaScript
            // runs; only public pagination fields are read.
            if (pure.latestCursor(body)) |cursor| {
                var nonce: pure.Field(200) = .{};
                var category: pure.Field(10) = .{};
                _ = nonce.set(cursor.nonce);
                _ = category.set(cursor.category);
                const url = std.fmt.bufPrint(&address, "{s}/wp-admin/admin-ajax.php", .{std.mem.trimEnd(u8, endpoints.base.get(), "/")}) catch return error.InvalidRoute;
                var page: u32 = 2;
                while (page <= 1000) : (page += 1) {
                    var form_buf: [512]u8 = undefined;
                    const form = pure.latestForm(&form_buf, .{ .nonce = nonce.get(), .category = category.get() }, page) orelse return error.InvalidRoute;
                    const next = get(provider, &endpoints, url, buf, cancel, form) orelse return error.Unavailable;
                    const doc = std.json.parseFromSlice(std.json.Value, alloc, next, .{}) catch return error.Unavailable;
                    defer doc.deinit();
                    const batch = pure.latestBatch(doc.value) orelse return error.Unavailable;
                    const before = book.count;
                    if (!pure.htmlIssues(batch.body, provider, endpoints.base.get(), identity.work, &book.chapters, &book.count)) return error.TooLarge;
                    if (!batch.more) break;
                    if (book.count == before or page == 1000) return error.Unavailable;
                }
            }
        }
    }
    if (book.count == 0 or workers.isQuitting()) return error.Unavailable;
    pure.sortIssues(book.chapters[0..book.count]);
    if (identity.issue.len > 0) {
        var found = false;
        for (book.chapters[0..book.count], 0..) |*chapter, index| if (std.mem.eql(u8, chapter.url.get(), identity.issue)) {
            book.selected = index;
            found = true;
            break;
        };
        if (!found) return error.MissingIssue;
    }
    const issue = book.chapters[book.selected].url.get();
    const manifest = pure.imagesUrl(&address, provider, endpoints.api.get(), issue) orelse return error.InvalidRoute;
    const body = get(provider, &endpoints, manifest, buf, cancel, null) orelse return error.Unavailable;
    if (provider == .ysk) {
        const doc = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return error.Unavailable;
        defer doc.deinit();
        book.page_count = pure.yskPages(doc.value, &book.pages) orelse return error.TooLarge;
    } else book.page_count = pure.htmlPages(body, provider, &book.pages) orelse return error.TooLarge;
    if (book.page_count == 0) return error.NoPages;
    if (provider == .xoxo) {
        // This origin sometimes serves a successful HTML page at image URLs.
        // Fail clearly before scheduling an entire issue of futile downloads.
        const probe = @import("reliable_fetch.zig").fetch(book.pages[0].get(), buf[0..512], .{
            .range = "bytes=0-127",
            .timeout_secs = 8,
            .connect_timeout_secs = 4,
            .referer = issue,
            .user_agent = "Mozilla/5.0",
            .cancel_epoch = cancel,
            .keep_head_on_overflow = true,
            .https_only = true,
        }) orelse return error.NoPages;
        if (!@import("comics_pure.zig").acceptsPageBody(probe)) return error.NoPages;
    }
    _ = book.referer.set(if (provider == .ysk) endpoints.base.get() else issue);
    return book;
}

fn getGlobal(endpoints: *const Endpoints, url: []const u8, client: []const u8, out: []u8, cancel: ?bounded.CancelEpoch) ?[]const u8 {
    var headers: [4096]u8 = undefined;
    const result = @import("source_request.zig").request("globalcomix", url, out, &headers, .{
        .base = endpoints.api.get(),
        .transport = .{ .timeout_secs = 15, .connect_timeout_secs = 6, .user_agent = "Mozilla/5.0", .referer = endpoints.base.get(), .headers = &.{ .{ .name = "Origin", .value = endpoints.base.get() }, .{ .name = "X-Gc-Identmode", .value = "cookie" } }, .secret_headers = &.{.{ .name = "X-Gc-Client", .value = client }}, .cancel_epoch = cancel, .https_only = true },
    });
    return if (result.ok()) result.body else null;
}
fn searchGlobal(endpoints: *const Endpoints, url: []const u8, cancel: ?bounded.CancelEpoch, out: []pure.Item) usize {
    const buf = alloc.alloc(u8, 4 * 1024 * 1024) catch return 0;
    defer alloc.free(buf);
    const body = get(.globalcomix, endpoints, endpoints.base.get(), buf, cancel, null) orelse return 0;
    const public_client = publishers.globalClient(body) orelse return 0;
    var client: pure.Field(128) = .{};
    _ = client.set(public_client);
    const response = getGlobal(endpoints, url, client.get(), buf, cancel) orelse return 0;
    const doc = std.json.parseFromSlice(std.json.Value, alloc, response, .{}) catch return 0;
    defer doc.deinit();
    return publishers.globalItems(doc.value, endpoints.base.get(), out);
}
fn loadPublisher(book: *Book, identity: pure.Route, endpoints: *const Endpoints, cancel: ?bounded.CancelEpoch, buf: []u8) Error!void {
    const body = get(identity.provider, endpoints, identity.work, buf, cancel, null) orelse return error.Unavailable;
    if (identity.provider == .imagecomics) {
        if (std.mem.indexOf(u8, body, "Are you over 18?") != null) return error.ConfirmationRequired;
        book.page_count = publishers.imagePages(body, identity.work, &book.pages) orelse return error.TooLarge;
        if (book.page_count == 0) return error.NoPages;
        book.count = 1;
        _ = book.chapters[0].url.set(identity.work);
        _ = book.chapters[0].title.set("Image Comics · Free first issue");
        if (std.mem.indexOf(u8, body, "<title>")) |at| if (std.mem.indexOfPos(u8, body, at, "</title>")) |end| {
            book.chapters[0].title.len = @import("novels_pure.zig").htmlToText(body[at + 7 .. end], &book.chapters[0].title.bytes);
        };
    } else {
        const raw_client = publishers.globalClient(body) orelse return error.Unavailable;
        var client: pure.Field(128) = .{};
        _ = client.set(raw_client);
        {
            const state_body = publishers.globalState(body) orelse return error.Unavailable;
            const doc = std.json.parseFromSlice(std.json.Value, alloc, state_body, .{}) catch return error.Unavailable;
            defer doc.deinit();
            book.count = publishers.globalIssues(doc.value, endpoints.base.get(), identity.work, &book.chapters) orelse return error.TooLarge;
        }
        if (book.count == 0) return error.NoPages;
        pure.sortIssues(book.chapters[0..book.count]);
        if (identity.issue.len > 0) {
            var found = false;
            for (book.chapters[0..book.count], 0..) |*chapter, i| if (std.mem.eql(u8, chapter.url.get(), identity.issue)) {
                book.selected = i;
                found = true;
                break;
            };
            if (!found) return error.MissingIssue;
        }
        const issue = book.chapters[book.selected].url.get();
        const id_start = (std.mem.lastIndexOfScalar(u8, issue, '/') orelse return error.InvalidRoute) + 1;
        var address: [1024]u8 = undefined;
        const url = std.fmt.bufPrint(&address, "{s}/v1/readV2/{s}", .{ std.mem.trimEnd(u8, endpoints.api.get(), "/"), issue[id_start..] }) catch return error.InvalidRoute;
        const response = getGlobal(endpoints, url, client.get(), buf, cancel) orelse return error.Unavailable;
        const doc = std.json.parseFromSlice(std.json.Value, alloc, response, .{}) catch return error.Unavailable;
        defer doc.deinit();
        book.page_count = publishers.globalPages(doc.value, &book.pages) orelse return error.NoPages;
    }
    _ = book.referer.set(identity.work);
}
