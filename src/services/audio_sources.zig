//! Independent public audio searches; callers own results and publication.
const std = @import("std");
const alloc = @import("../core/alloc.zig").allocator;
const io = @import("../core/io_global.zig");
const fetch = @import("reliable_fetch.zig");
const source_request = @import("source_request.zig");
const CancelEpoch = @import("../core/bounded_process.zig").CancelEpoch;
pub const pure = @import("audio_sources_pure.zig");
pub const Provider = pure.Provider;
pub const Item = pure.Item;
pub const Reply = pure.Reply;
const MAX_BODY = 1024 * 1024;
pub fn defaultBase(provider: Provider) []const u8 {
    return switch (provider) {
        .openverse => "https://api.openverse.org",
        .netlabels => "https://archive.org",
        .somafm => "https://somafm.com",
    };
}
fn get(provider: Provider, base: []const u8, url: []const u8, body: []u8, deadline: i64, cancel: ?CancelEpoch) fetch.FetchResult {
    const left = deadline - io.monotonicMilliTimestamp();
    if (left <= 0) return .{ .failure = .transport };
    var headers: [4096]u8 = undefined;
    return source_request.request(@tagName(provider), url, body, &headers, .{
        .base = base,
        .ttl_ms = 60_000,
        .validate = switch (provider) {
            .openverse => validOpenverse,
            .somafm => validSoma,
            .netlabels => validArchive,
        },
        .transport = .{ .timeout_secs = @intCast(@max(1, @min(4, @divTrunc(left, 1000)))), .impersonate = false, .user_agent = @import("../core/app_meta.zig").user_agent_with_url, .cancel_epoch = cancel },
    });
}
fn validField(body: []const u8, field: []const u8, kind: std.meta.Tag(std.json.Value)) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const value = parsed.value.object.get(field) orelse return false;
    return std.meta.activeTag(value) == kind;
}
fn validOpenverse(body: []const u8) bool {
    return validField(body, "results", .array);
}
fn validSoma(body: []const u8) bool {
    return validField(body, "channels", .array);
}
fn validArchive(body: []const u8) bool {
    return validField(body, "response", .object) or validField(body, "files", .array);
}
fn failed(f: fetch.FetchResult) Reply {
    return .{ .status = if (f.failure == .truncated) .parse_failed else if (f.status == 429) .unavailable else .transport_failed };
}
/// base is an owned installed-source endpoint (empty uses official endpoint).
/// Netlabels performs at most two album metadata requests, all within 8 seconds.
pub fn searchInto(provider: Provider, query: []const u8, out: []Item, base: []const u8) Reply {
    return searchIntoWithCancellation(provider, query, out, base, null);
}
pub fn searchIntoWithCancellation(provider: Provider, query: []const u8, out: []Item, base: []const u8, cancel: ?CancelEpoch) Reply {
    if (out.len == 0) return .{};
    const endpoint = std.mem.trimEnd(u8, if (base.len == 0) defaultBase(provider) else base, "/");
    if (!pure.safeUrl(endpoint)) return .{ .status = .unavailable };
    var encoded: [2048]u8 = undefined;
    const q = pure.encode(&encoded, query) orelse return .{ .status = .failed };
    var url: [4096]u8 = undefined;
    const target = switch (provider) {
        .openverse => std.fmt.bufPrint(&url, "{s}/v1/audio/?q={s}&category=music&page_size={d}", .{ endpoint, q, @min(20, out.len) }),
        .somafm => std.fmt.bufPrint(&url, "{s}/channels.json", .{endpoint}),
        .netlabels => std.fmt.bufPrint(&url, "{s}/advancedsearch.php?q=collection%3Anetlabels%20AND%20mediatype%3Aaudio%20AND%20%28{s}%29&fl%5B%5D=identifier&rows=2&output=json", .{ endpoint, q }),
    } catch return .{ .status = .failed };
    const body = alloc.alloc(u8, MAX_BODY) catch return .{ .status = .failed };
    defer alloc.free(body);
    const deadline = io.monotonicMilliTimestamp() + 8000;
    const response = get(provider, endpoint, target, body, deadline, cancel);
    if (!response.ok()) return failed(response);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, response.body, .{ .allocate = .alloc_always }) catch return .{ .status = .parse_failed };
    defer parsed.deinit();
    switch (provider) {
        .openverse => return pure.parseOpenverse(parsed.value, out),
        .somafm => return pure.parseSoma(parsed.value, query, out),
        .netlabels => {
            const docs = pure.field(pure.field(parsed.value, "response"), "docs");
            if (docs != .array) return .{ .status = .parse_failed };
            var result: Reply = .{};
            var had_error = false;
            for (docs.array.items[0..@min(2, docs.array.items.len)]) |doc| {
                if (result.count == out.len) break;
                const id = pure.text(doc, "identifier");
                if (id.len == 0 or id.len > 256) {
                    had_error = true;
                    continue;
                }
                var eid: [768]u8 = undefined;
                const escaped = pure.encode(&eid, id) orelse continue;
                const metadata_url = std.fmt.bufPrint(&url, "{s}/metadata/{s}", .{ endpoint, escaped }) catch continue;
                const metadata = get(provider, endpoint, metadata_url, body, deadline, cancel);
                if (!metadata.ok()) {
                    had_error = true;
                    result.status = failed(metadata).status;
                    continue;
                }
                const item = std.json.parseFromSlice(std.json.Value, alloc, metadata.body, .{}) catch {
                    had_error = true;
                    result.status = .parse_failed;
                    continue;
                };
                defer item.deinit();
                const page = pure.parseNetlabel(item.value, id, out[result.count..]);
                if (page.status == .parse_failed) had_error = true;
                result.count += page.count;
                result.total += page.total;
            }
            // Album search is deliberately bounded; report partial instead of claiming catalog exhaustion.
            const albums_total = pure.number(pure.field(pure.field(parsed.value, "response"), "numFound"));
            if (result.count > 0) result.status = if (had_error or result.total > result.count or albums_total > 2) .partial else .done else if (!had_error) result.status = .no_results;
            return result;
        },
    }
}
