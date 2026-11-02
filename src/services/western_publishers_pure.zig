//! Public publisher catalogs and complete, freely accessible issues.
const std = @import("std");
const model = @import("western_comics_pure.zig");
const html = @import("content_html_pure.zig");
const text = @import("novels_pure.zig");
pub fn member(value: std.json.Value, key: []const u8) std.json.Value {
    return if (value == .object) value.object.get(key) orelse .null else .null;
}
pub fn string(value: std.json.Value) []const u8 {
    return if (value == .string) value.string else "";
}
fn number(value: std.json.Value) i64 {
    return if (value == .integer) value.integer else 0;
}
fn yes(value: std.json.Value) bool {
    return value == .bool and value.bool;
}
fn webImage(url: []const u8) bool {
    if (url.len > 512 or std.mem.indexOfAny(u8, url, "\r\n\t ") != null) return false;
    const uri = std.Uri.parse(url) catch return false;
    return std.mem.eql(u8, uri.scheme, "https") and uri.host != null and uri.user == null and uri.password == null;
}
pub fn imageItems(body: []const u8, base: []const u8, query: []const u8, page: u32, out: []model.Item) usize {
    if (page == 0 or page > 1000) return 0;
    var it: html.AnchorIter = .{ .html = body, .path = "/read/" };
    var matches: usize = 0;
    var count: usize = 0;
    while (it.next()) |anchor| {
        // Each catalog entry has one cover anchor plus separate text links.
        if (!webImage(anchor.cover)) continue;
        var address: [512]u8 = undefined;
        const work = html.sourceUrl(&address, base, anchor.url) orelse continue;
        var item: model.Item = .{};
        const identity = model.route(&item.route.bytes, .imagecomics, base, work, "") orelse continue;
        item.route.len = identity.len;
        item.title.len = text.htmlToText(anchor.title, &item.title.bytes);
        if (item.title.len == 0 or (query.len > 0 and std.ascii.findIgnoreCase(item.title.get(), query) == null)) continue;
        if (matches < (page - 1) * 20) {
            matches += 1;
            continue;
        }
        if (count == @min(out.len, 20)) break;
        _ = item.cover.set(anchor.cover);
        out[count] = item;
        count += 1;
        matches += 1;
    }
    return count;
}
pub fn imagePages(body: []const u8, work: []const u8, out: []model.Page) ?usize {
    const slash = (std.mem.lastIndexOfScalar(u8, work, '/') orelse return null) + 1;
    const name = work[slash..];
    var prefix_buf: [512]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "https://cdn.imagecomics.com/files/read/{s}/", .{name}) catch return null;
    var pos: usize = 0;
    var count: usize = 0;
    while (std.mem.indexOfPos(u8, body, pos, "<img")) |at| {
        const end = std.mem.indexOfScalarPos(u8, body, at, '>') orelse return null;
        pos = end + 1;
        const src = html.attr(body[at..pos], "src") orelse continue;
        if (!std.mem.startsWith(u8, src, prefix)) continue;
        if (!webImage(src) or count == out.len) return null;
        if (!out[count].set(src)) return null;
        count += 1;
    }
    return count;
}
pub fn globalState(body: []const u8) ?[]const u8 {
    const marker = "window.__INITIAL_STATE__ = ";
    const start = (std.mem.indexOf(u8, body, marker) orelse return null) + marker.len;
    const end = std.mem.indexOfPos(u8, body, start, "</script>") orelse return null;
    return std.mem.trim(u8, body[start..end], " \r\n\t;");
}
pub fn globalQuery(root: std.json.Value, name: []const u8) std.json.Value {
    const queries = member(root, "queries");
    if (queries != .array) return .null;
    for (queries.array.items) |query| {
        const key = member(query, "queryKey");
        if (key != .array or key.array.items.len == 0 or !std.mem.eql(u8, string(key.array.items[0]), name)) continue;
        return member(member(member(query, "state"), "data"), "data");
    }
    return .null;
}
/// This is the website's public anonymous-client identifier, refreshed from
/// publisher HTML. It is never a user's account token or a bundled constant.
pub fn globalClient(body: []const u8) ?[]const u8 {
    const marker = "\"api_key\":\"";
    const start = (std.mem.indexOf(u8, body, marker) orelse return null) + marker.len;
    const end = std.mem.indexOfScalarPos(u8, body, start, '"') orelse return null;
    const value = body[start..end];
    if (value.len < 5 or value.len > 128 or !std.mem.startsWith(u8, value, "gck_")) return null;
    for (value) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return null;
    return value;
}
fn payload(root: std.json.Value) std.json.Value {
    return member(root, "payload");
}
pub fn globalItems(root: std.json.Value, base: []const u8, out: []model.Item) usize {
    const rows = member(member(member(payload(root), "results"), "series"), "items");
    if (rows != .array) return 0;
    var count: usize = 0;
    for (rows.array.items) |row| {
        if (count == out.len) break;
        const total = number(member(row, "total_published_releases"));
        if (!yes(member(row, "is_free")) and (total == 0 or number(member(row, "count_gold")) >= total)) continue;
        var address: [512]u8 = undefined;
        const work = html.sourceUrl(&address, base, string(member(row, "url"))) orelse continue;
        var item: model.Item = .{};
        const identity = model.route(&item.route.bytes, .globalcomix, base, work, "") orelse continue;
        item.route.len = identity.len;
        item.title.len = text.htmlToText(string(member(row, "name")), &item.title.bytes);
        if (item.title.len == 0) continue;
        const cover = string(member(row, "cover_image_url"));
        if (webImage(cover)) _ = item.cover.set(cover);
        out[count] = item;
        count += 1;
    }
    return count;
}
pub fn globalIssues(root: std.json.Value, base: []const u8, work: []const u8, out: []model.Issue) ?usize {
    const data = payload(globalQuery(root, "get-comic-releases"));
    const rows = member(data, "results");
    const pages = number(member(member(data, "pagination"), "total_pages"));
    if (rows != .array or pages > 1) return null;
    var count: usize = 0;
    for (rows.array.items) |row| {
        if (!yes(member(row, "is_free")) or !yes(member(row, "is_public_now")) or number(member(row, "premium_only")) != 0) continue;
        const total = number(member(row, "page_count"));
        if (total <= 0 or number(member(row, "free_page_count")) != total) continue;
        var address: [512]u8 = undefined;
        // The series HTML advertises this canonical reader route; read_url
        // in the API uses a separate /read/{uuid}/1 alias without the series.
        const key = string(member(row, "key"));
        const url = std.fmt.bufPrint(&address, "{s}/r/{s}", .{ work, key }) catch continue;
        if (!model.issueOwned(.globalcomix, base, work, url)) continue;
        if (count == out.len) return null;
        var issue: model.Issue = .{ .number = @floatFromInt(number(member(row, "order"))) };
        _ = issue.url.set(url);
        issue.title.len = text.htmlToText(string(member(row, "title")), &issue.title.bytes);
        if (issue.title.len == 0) _ = issue.title.set("Free issue");
        out[count] = issue;
        count += 1;
    }
    return count;
}
pub fn globalPages(root: std.json.Value, out: []model.Page) ?usize {
    const release = member(payload(root), "results");
    const rows = member(release, "page_objects");
    const total = number(member(release, "page_count"));
    if (!yes(member(release, "is_free")) or number(member(release, "premium_only")) != 0 or total <= 0 or number(member(release, "free_page_count")) != total) return null;
    if (rows != .array or rows.array.items.len > out.len or rows.array.items.len != total) return null;
    // Page order is authoritative; never infer image URLs or expand paid ranges.
    for (rows.array.items) |row| {
        if (yes(member(row, "display_paid_access_block")) or yes(member(row, "is_page_paid"))) return null;
        const order = number(member(row, "order"));
        if (order <= 0 or order > total) return null;
        var url = string(member(row, "desktop_image_url"));
        if (url.len == 0) url = string(member(row, "mobile_image_url"));
        if (!webImage(url) or !out[@intCast(order - 1)].set(url)) return null;
    }
    // Detect duplicate/missing page orders using the small bounded manifest.
    for (1..@intCast(total + 1)) |order| {
        var found: usize = 0;
        for (rows.array.items) |row| if (number(member(row, "order")) == order) {
            found += 1;
        };
        if (found != 1) return null;
    }
    return @intCast(total);
}

test "Image Comics filters full catalog before pagination and preserves publisher page order" {
    const body = "<a href='/read/story'><img src='https://cdn.imagecomics.com/cover.jpg' alt='Story'></a><a href='/read/story'>Story</a><a href='/read/other'><img src='https://cdn.imagecomics.com/other.jpg' alt='Other'></a>";
    var rows: [3]model.Item = @splat(.{});
    try std.testing.expectEqual(@as(usize, 1), imageItems(body, "https://imagecomics.com", "story", 1, &rows));
    try std.testing.expectEqualStrings("Story", rows[0].title.get());
    try std.testing.expectEqual(@as(usize, 0), imageItems(body, "https://imagecomics.com", "story", 2, &rows));
    var pages: [2]model.Page = @splat(.{});
    const images = "<img src='https://cdn.imagecomics.com/cover.jpg'><img src='https://cdn.imagecomics.com/files/read/story/001.jpeg'><img src='https://cdn.imagecomics.com/files/read/other/001.jpeg'><img src='https://cdn.imagecomics.com/files/read/story/002.jpeg'>";
    try std.testing.expectEqual(@as(usize, 2), imagePages(images, "https://imagecomics.com/read/story", &pages).?);
    try std.testing.expect(imagePages(images, "https://imagecomics.com/read/story", pages[0..1]) == null);
}
test "GlobalComix public client identifiers reject injected headers" {
    try std.testing.expectEqualStrings("gck_example", globalClient("{\"api_key\":\"gck_example\"}").?);
    try std.testing.expect(globalClient("{\"api_key\":\"gck_bad\\r\\nAuthorization\"}") == null);
    try std.testing.expect(globalClient("{\"api_key\":\"user_secret\"}") == null);
    try std.testing.expectEqualStrings("{}", globalState("<script>window.__INITIAL_STATE__ = {}; </script>").?);
}
test "GlobalComix rejects paid and incomplete issues instead of showing a free preview as a whole book" {
    const body = "{\"payload\":{\"results\":{\"is_free\":true,\"page_count\":2,\"free_page_count\":2,\"page_objects\":[{\"order\":2,\"desktop_image_url\":\"https://cdn.test/2.jpg\"},{\"order\":1,\"desktop_image_url\":\"https://cdn.test/1.jpg\"}]}}}";
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    var pages: [2]model.Page = @splat(.{});
    try std.testing.expectEqual(@as(usize, 2), globalPages(parsed.value, &pages).?);
    try std.testing.expectEqualStrings("https://cdn.test/1.jpg", pages[0].get());
    try std.testing.expect(globalPages(parsed.value, pages[0..1]) == null);
    const paid = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"payload\":{\"results\":{\"is_free\":false,\"page_count\":2,\"free_page_count\":1,\"page_objects\":[]}}}", .{});
    defer paid.deinit();
    try std.testing.expect(globalPages(paid.value, &pages) == null);
}

test "GlobalComix search omits paid-only series and directories omit paid or partial releases" {
    const search = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"payload\":{\"results\":{\"series\":{\"items\":[{\"name\":\"Free series\",\"url\":\"/c/story\",\"total_published_releases\":3,\"count_gold\":2},{\"name\":\"Paid only\",\"url\":\"/c/paid\",\"total_published_releases\":3,\"count_gold\":3}]}}}}", .{});
    defer search.deinit();
    var items: [3]model.Item = @splat(.{});
    try std.testing.expectEqual(@as(usize, 1), globalItems(search.value, "https://g.test", &items));
    const directory = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"queries\":[{\"queryKey\":[\"get-comic-releases\",\"1\"],\"state\":{\"data\":{\"data\":{\"payload\":{\"pagination\":{\"total_pages\":1},\"results\":[{\"is_free\":true,\"is_public_now\":true,\"page_count\":2,\"free_page_count\":2,\"key\":\"f63f8ee9-03dc-4eae-afdd-c30adebbd194\",\"title\":\"Issue 1\",\"order\":1},{\"is_free\":false,\"is_public_now\":true,\"page_count\":20,\"free_page_count\":2},{\"is_free\":true,\"is_public_now\":true,\"page_count\":20,\"free_page_count\":2}]}}}}}]}", .{});
    defer directory.deinit();
    var issues: [3]model.Issue = @splat(.{});
    try std.testing.expectEqual(@as(usize, 1), globalIssues(directory.value, "https://g.test", "https://g.test/c/story", &issues).?);
    try std.testing.expectEqualStrings("https://g.test/c/story/r/f63f8ee9-03dc-4eae-afdd-c30adebbd194", issues[0].url.get());
    try std.testing.expect(model.splitRoute("imagecomics:https://imagecomics.com/read/skyward") != null);
    try std.testing.expect(model.splitRoute("globalcomix:https://g.test/c/story|https://g.test/c/other/r/f63f8ee9-03dc-4eae-afdd-c30adebbd194") == null);
}
