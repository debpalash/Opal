//! Bounded independent official comic discovery, never mutates Browse state.
const std = @import("std");
const alloc = @import("../core/alloc.zig").allocator;
const io = @import("../core/io_global.zig");
const request = @import("source_request.zig");
const epoch = @import("../core/bounded_process.zig").CancelEpoch;
pub const pure = @import("webcomic_sources_pure.zig");
pub const Item = pure.Item;
pub const Provider = pure.Provider;
pub const Reply = struct { count: usize = 0, total: usize = 0, status: @import("resolver_lifecycle_pure.zig").SourceStatus = .no_results };
fn validArchive(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "middleContainer") != null;
}
fn validRss(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "<rss") != null and std.mem.indexOf(u8, body, "</rss>") != null;
}
fn validPage(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "cc-comic") != null;
}
fn validJson(body: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return false;
    defer parsed.deinit();
    const fields = @import("audio_sources_pure.zig");
    return fields.number(fields.field(parsed.value, "num")) > 0 and fields.text(parsed.value, "img").len > 0 and fields.text(parsed.value, "safe_title").len > 0;
}
fn validWordpress(body: []const u8) bool {
    const doc = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return false;
    defer doc.deinit();
    return doc.value == .array or (doc.value == .object and doc.value.object.contains("id") and doc.value.object.contains("content"));
}
fn get(provider: Provider, base: []const u8, path: []const u8, out: []u8, deadline: i64, cancel: ?epoch) ?[]const u8 {
    const left = deadline - io.monotonicMilliTimestamp();
    if (left <= 0) return null;
    var address: [2048]u8 = undefined;
    const url = std.fmt.bufPrint(&address, "{s}{s}", .{ std.mem.trimEnd(u8, base, "/"), path }) catch return null;
    var headers: [4096]u8 = undefined;
    const response = request.request(@tagName(provider), url, out, &headers, .{ .base = base, .ttl_ms = 120_000, .validate = if (provider == .poorlydrawnlines) validWordpress else if (provider == .xkcd) (if (std.mem.endsWith(u8, path, "info.0.json")) validJson else validArchive) else (if (std.mem.eql(u8, path, "/comic/rss")) validRss else validPage), .transport = .{ .timeout_secs = @intCast(@max(1, @min(4, @divTrunc(left, 1000)))), .cancel_epoch = cancel, .user_agent = @import("../core/app_meta.zig").user_agent_with_url } });
    return if (response.ok()) response.body else null;
}
pub fn searchInto(provider: Provider, base: []const u8, query: []const u8, out: []Item, cancel: ?epoch) Reply {
    if (!@import("audio_sources_pure.zig").safeUrl(base)) return .{ .status = .unavailable };
    const body = alloc.alloc(u8, 1024 * 1024) catch return .{ .status = .failed };
    defer alloc.free(body);
    const deadline = io.monotonicMilliTimestamp() + 8000;
    if (provider == .poorlydrawnlines) {
        var encoded: [1024]u8 = undefined;
        const q = @import("audio_sources_pure.zig").encode(&encoded, query) orelse return .{ .status = .failed };
        var path: [1536]u8 = undefined;
        const url = std.fmt.bufPrint(&path, "/wp-json/wp/v2/posts?per_page=6&search={s}&_fields=id,link,title,content", .{q}) catch return .{ .status = .failed };
        const data = get(provider, base, url, body, deadline, cancel) orelse return .{ .status = .transport_failed };
        const doc = std.json.parseFromSlice(std.json.Value, alloc, data, .{}) catch return .{ .status = .parse_failed };
        defer doc.deinit();
        const listing = pure.parseWordpressPosts(doc.value, base, out);
        return .{ .count = listing.count, .total = listing.total, .status = if (!listing.valid) .parse_failed else if (listing.count == 0) .no_results else .done };
    }
    const data = get(provider, base, if (provider == .xkcd) "/archive/" else "/comic/rss", body, deadline, cancel) orelse return .{ .status = .transport_failed };
    const listing = if (provider == .xkcd) pure.parseArchive(data, query, out) else pure.parseSmbc(data, base, query, out);
    if (!listing.valid) return .{ .status = .parse_failed };
    if (provider == .smbc) return .{ .count = listing.count, .total = listing.total, .status = if (listing.count == 0) .no_results else .partial };
    var count: usize = 0;
    var failed = false;
    for (0..listing.count) |i| {
        const id = out[i].number;
        var path: [64]u8 = undefined;
        const url = std.fmt.bufPrint(&path, "/{d}/info.0.json", .{id}) catch continue;
        const metadata = get(provider, base, url, body, deadline, cancel) orelse {
            failed = true;
            continue;
        };
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, metadata, .{}) catch {
            failed = true;
            continue;
        };
        defer parsed.deinit();
        const row = pure.parseXkcd(parsed.value, id, base) orelse {
            failed = true;
            continue;
        };
        out[count] = row;
        count += 1;
    }
    return .{ .count = count, .total = listing.total, .status = if (count > 0) if (failed or listing.total > count) .partial else .done else if (failed) .transport_failed else .no_results };
}
/// Resolve an opaque provider route into publisher's full main panel.
pub fn load(provider: Provider, base: []const u8, route: []const u8, cancel: ?epoch) ?Item {
    const body = alloc.alloc(u8, 1024 * 1024) catch return null;
    defer alloc.free(body);
    const deadline = io.monotonicMilliTimestamp() + 8000;
    if (provider == .poorlydrawnlines) {
        const id = std.fmt.parseInt(u32, route, 10) catch return null;
        var path: [100]u8 = undefined;
        const url = std.fmt.bufPrint(&path, "/wp-json/wp/v2/posts/{d}?_fields=id,link,title,content", .{id}) catch return null;
        const data = get(provider, base, url, body, deadline, cancel) orelse return null;
        const doc = std.json.parseFromSlice(std.json.Value, alloc, data, .{}) catch return null;
        defer doc.deinit();
        return pure.parseWordpressPost(doc.value, base, id);
    }
    if (provider == .xkcd) {
        const id = pure.numberFromPath(route) orelse return null;
        var path: [64]u8 = undefined;
        const url = std.fmt.bufPrint(&path, "/{d}/info.0.json", .{id}) catch return null;
        const metadata = get(provider, base, url, body, deadline, cancel) orelse return null;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, metadata, .{}) catch return null;
        defer parsed.deinit();
        return pure.parseXkcd(parsed.value, id, base);
    }
    var owned: [512]u8 = undefined;
    const url = pure.htmlSource(&owned, base, route) orelse return null;
    const b = std.mem.trimEnd(u8, base, "/");
    if (!std.mem.startsWith(u8, url[b.len..], "/comic/")) return null;
    const data = get(provider, base, url[b.len..], body, deadline, cancel) orelse return null;
    return pure.parseSmbcPage(data, base, url);
}
