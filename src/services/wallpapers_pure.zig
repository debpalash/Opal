//! Provider-independent wallpaper identity, bounded metadata and API adapters.
const std = @import("std");
pub const Source = enum { all, wallhaven, pexels, unsplash, gallery };
pub fn Field(comptime size: usize) type {
    return struct {
        bytes: [size]u8 = @splat(0),
        len: usize = 0,
        pub fn set(self: *@This(), value: []const u8) void {
            self.len = @min(value.len, size);
            @memcpy(self.bytes[0..self.len], value[0..self.len]);
        }
        pub fn text(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}
pub const Media = enum { image, gif, video };
pub fn mediaExtension(value: []const u8) ?[]const u8 {
    for ([_][]const u8{ "jpg", "jpeg", "png", "webp", "bmp", "gif", "mp4", "webm", "mov", "mkv", "m4v" }) |ext| if (std.ascii.eqlIgnoreCase(ext, value)) return ext;
    return null;
}
pub fn mediaKind(ext: []const u8) Media {
    if (std.mem.eql(u8, ext, "gif")) return .gif;
    for ([_][]const u8{ "mp4", "webm", "mov", "mkv", "m4v" }) |video| if (std.mem.eql(u8, ext, video)) return .video;
    return .image;
}
pub fn urlExtension(url: []const u8) ?[]const u8 {
    const end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    const dot = std.mem.lastIndexOfScalar(u8, url[0..end], '.') orelse return null;
    return mediaExtension(url[dot + 1 .. end]);
}
pub const Row = struct {
    media: Media = .image,
    extension: Field(8) = .{},
    source: Source = .wallhaven,
    title: Field(160) = .{},
    author: Field(128) = .{},
    preview: Field(1024) = .{},
    original: Field(2048) = .{},
    page: Field(1024) = .{},
    download_event: Field(512) = .{},
    width: u32 = 0,
    height: u32 = 0,
};
fn get(v: std.json.Value, key: []const u8) std.json.Value {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
fn str(v: std.json.Value) []const u8 {
    return if (v == .string) v.string else "";
}
fn num(v: std.json.Value) u32 {
    return if (v == .integer) @intCast(std.math.clamp(v.integer, 0, 100000)) else 0;
}
/// Signed CDN image URLs are valid media; credentials remain out of argv via
/// the shared reliable image transport. Search URLs use stricter publicUrl.
pub fn mediaUrl(value: []const u8) bool {
    const uri = std.Uri.parse(value) catch return false;
    return uri.host != null and uri.user == null and uri.password == null and
        (std.mem.eql(u8, uri.scheme, "https") or std.mem.eql(u8, uri.scheme, "http"));
}
pub fn publicUrl(value: []const u8) bool {
    return @import("source_request_pure.zig").publicUrl(value);
}
pub fn parse(allocator: std.mem.Allocator, source: Source, json: []const u8, out: []Row) !usize {
    const doc = try std.json.parseFromSlice(std.json.Value, allocator, json, .{ .allocate = .alloc_always });
    defer doc.deinit();
    const list = switch (source) {
        .wallhaven => get(doc.value, "data"),
        .pexels => get(doc.value, "photos"),
        .unsplash => if (doc.value == .array) doc.value else get(doc.value, "results"),
        .gallery => doc.value,
        .all => return error.InvalidProvider,
    };
    if (list != .array) return error.InvalidResponse;
    var count: usize = 0;
    var failed = false;
    for (list.array.items) |entry| {
        if (count == out.len) break;
        var row: Row = .{ .source = source };
        var data = entry;
        if (source == .gallery) {
            if (entry != .array) continue;
            const fields = entry.array.items;
            if (fields.len > 0 and fields[0] == .integer and fields[0].integer < 0) {
                failed = true;
                continue;
            }
            if (fields.len < 3) continue;
            if (fields[0] != .integer or fields[0].integer != 3) continue;
            data = fields[2];
            const ext = mediaExtension(str(get(data, "extension"))) orelse continue;
            row.media = mediaKind(ext);
            row.extension.set(ext);
            row.original.set(str(fields[1]));
            row.preview.set(str(get(data, "thumbnail")));
            if (!mediaUrl(row.preview.text())) row.preview.set(str(get(get(data, "thumbs"), "large")));
            if (!mediaUrl(row.preview.text())) row.preview.set(row.original.text());
            // Reuse each provider's thumbnail convention instead of fetching
            // multi-megabyte originals for a small grid cell.
            const category = str(get(data, "category"));
            if (std.mem.eql(u8, category, "flickr")) {
                const original = row.original.text();
                if (std.mem.lastIndexOfScalar(u8, original, '.')) |dot| {
                    if (std.mem.lastIndexOfScalar(u8, original[0..dot], '_')) |underscore| {
                        var small: [1024]u8 = undefined;
                        if (std.fmt.bufPrint(&small, "{s}_n{s}", .{ original[0..underscore], original[dot..] })) |url| row.preview.set(url) else |_| {}
                    }
                }
            } else if (std.mem.eql(u8, category, "artstation")) {
                const original = row.original.text();
                for ([_][]const u8{ "/8k/", "/4k/", "/large/", "/original/" }) |size| {
                    if (std.mem.indexOf(u8, original, size)) |at| {
                        var small: [1024]u8 = undefined;
                        if (std.fmt.bufPrint(&small, "{s}/small/{s}", .{ original[0..at], original[at + size.len ..] })) |url| row.preview.set(url) else |_| {}
                        break;
                    }
                }
            }
            row.page.set(str(get(data, "post_url")));
            if (row.page.len == 0) row.page.set(str(get(data, "short_url")));
            row.title.set(str(get(data, "title")));
            row.author.set(str(get(data, "username")));
        } else switch (source) {
            .wallhaven => {
                row.original.set(str(get(data, "path")));
                row.preview.set(str(get(get(data, "thumbs"), "large")));
                row.page.set(str(get(data, "url")));
                row.title.set(str(get(data, "resolution")));
                row.author.set("Wallhaven");
                row.width = num(get(data, "dimension_x"));
                row.height = num(get(data, "dimension_y"));
            },
            .pexels => {
                row.original.set(str(get(get(data, "src"), "original")));
                row.preview.set(str(get(get(data, "src"), "large")));
                row.page.set(str(get(data, "url")));
                row.title.set(str(get(data, "alt")));
                row.author.set(str(get(data, "photographer")));
            },
            .unsplash => {
                row.original.set(str(get(get(data, "urls"), "full")));
                row.preview.set(str(get(get(data, "urls"), "small")));
                row.page.set(str(get(get(data, "links"), "html")));
                row.download_event.set(str(get(get(data, "links"), "download_location")));
                row.title.set(str(get(data, "alt_description")));
                row.author.set(str(get(get(data, "user"), "name")));
            },
            else => unreachable,
        }
        if (row.extension.len == 0) row.extension.set(urlExtension(row.original.text()) orelse "jpg");
        if (row.width == 0) row.width = num(get(data, "width"));
        if (row.height == 0) row.height = num(get(data, "height"));
        if (!mediaUrl(row.original.text()) or !mediaUrl(row.preview.text())) continue;
        if (!publicUrl(row.page.text())) row.page.set(row.original.text());
        if (row.title.len == 0) row.title.set("Untitled image");
        var duplicate = false;
        for (out[0..count]) |*old| if (std.mem.eql(u8, old.original.text(), row.original.text())) {
            duplicate = true;
            break;
        };
        if (duplicate) continue;
        out[count] = row;
        count += 1;
    }
    if (count == 0 and failed) return error.SourceUnavailable;
    return count;
}
/// User-supplied search templates work with any gallery-dl search extractor.
/// Literal URLs bypass templates and let gallery-dl select from all extractors.
pub fn expand(template: []const u8, query: []const u8, out: []u8) ?[]const u8 {
    if (publicUrl(query)) {
        if (query.len > out.len) return null;
        @memcpy(out[0..query.len], query);
        return out[0..query.len];
    }
    const at = std.mem.indexOf(u8, template, "{query}") orelse return null;
    var encoded: [3072]u8 = undefined;
    const text = @import("audio_sources_pure.zig").encode(&encoded, query) orelse return null;
    const url = std.fmt.bufPrint(out, "{s}{s}{s}", .{ template[0..at], text, template[at + 7 ..] }) catch return null;
    return if (publicUrl(url)) url else null;
}
test "wallpapers reject malformed metadata and preserve real source URLs" {
    var rows: [4]Row = undefined;
    const json = "{\"data\":[{\"path\":\"https://w.wallhaven.cc/full/test.jpg\",\"url\":\"https://wallhaven.cc/w/test\",\"thumbs\":{\"large\":\"https://th.wallhaven.cc/test.jpg\"},\"dimension_x\":3840,\"dimension_y\":2160},{\"path\":\"file:///etc/passwd\"}]}";
    try std.testing.expectEqual(@as(usize, 1), try parse(std.testing.allocator, .wallhaven, json, &rows));
    try std.testing.expectEqual(@as(u32, 3840), rows[0].width);
    const gallery = "[[3,\"https://example.org/a.jpg\",{\"extension\":\"jpg\"}],[3,\"https://example.org/a.jpg\",{\"extension\":\"jpg\"}],[3,\"https://example.org/a.mp4\",{\"extension\":\"mp4\"}]]";
    try std.testing.expectEqual(@as(usize, 2), try parse(std.testing.allocator, .gallery, gallery, &rows));
    var buf: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("https://example.org/search?q=moon%20%26%20stars", expand("https://example.org/search?q={query}", "moon & stars", &buf).?);
    try std.testing.expect(expand("file:///{query}", "x", &buf) == null);
}

pub fn authConfig(allocator: std.mem.Allocator, existing: []const u8, site: []const u8, field: []const u8, value: []const u8) ![]u8 {
    if (site.len == 0 or field.len == 0) return error.InvalidCredential;
    for (site) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return error.InvalidCredential;
    for (field) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return error.InvalidCredential;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try std.json.parseFromSlice(std.json.Value, a, if (existing.len == 0) "{}" else existing, .{ .allocate = .alloc_always });
    var root = doc.value;
    if (root != .object) return error.InvalidCredential;
    var extract = root.object.get("extractor") orelse std.json.Value{ .object = .empty };
    if (extract != .object) return error.InvalidCredential;
    var settings = extract.object.get(site) orelse std.json.Value{ .object = .empty };
    if (settings != .object) return error.InvalidCredential;
    if (value.len == 0) {
        _ = settings.object.swapRemove(field);
    } else try settings.object.put(a, field, .{ .string = value });
    try extract.object.put(a, site, settings);
    try root.object.put(a, "extractor", extract);
    return std.json.Stringify.valueAlloc(allocator, root, .{ .whitespace = .indent_2 });
}
test "gallery-dl error records cannot masquerade as empty successful results" {
    var rows: [2]Row = undefined;
    try std.testing.expectError(error.SourceUnavailable, parse(std.testing.allocator, .gallery, "[[-1,{\"error\":\"HttpError\"}]]", &rows));
}
test "gallery credentials merge safely preserve other sites and remove empty values" {
    const a = std.testing.allocator;
    const first = try authConfig(a, "{}", "flickr", "api-key", "fixture-quote\"value");
    defer a.free(first);
    const second = try authConfig(a, first, "pixiv", "refresh-token", "fixture-token");
    defer a.free(second);
    const third = try authConfig(a, second, "flickr", "api-key", "");
    defer a.free(third);
    const doc = try std.json.parseFromSlice(std.json.Value, a, third, .{});
    defer doc.deinit();
    const extract = get(doc.value, "extractor");
    try std.testing.expectEqualStrings("fixture-token", str(get(get(extract, "pixiv"), "refresh-token")));
    try std.testing.expect(get(get(extract, "flickr"), "api-key") == .null);
    try std.testing.expectError(error.InvalidCredential, authConfig(a, "{}", "../site", "password", "x"));
}

test "signed gallery CDN images remain playable without accepting URL credentials" {
    var rows: [1]Row = undefined;
    try std.testing.expectEqual(@as(usize, 1), try parse(std.testing.allocator, .gallery, "[[3,\"https://cdn.example.org/image.jpg?token=signed-fixture\",{\"extension\":\"jpg\"}]]", &rows));
    try std.testing.expect(!mediaUrl("https://user:password@example.org/private.jpg"));
    try std.testing.expect(!publicUrl("https://example.org/search?token=secret"));
}

/// Navigate the current loaded collection, wrapping at either edge.
pub fn galleryIndex(current: usize, total: usize, direction: i32) ?usize {
    if (total == 0) return null;
    const index = @min(current, total - 1);
    return if (direction < 0) (if (index == 0) total - 1 else index - 1) else (index + 1) % total;
}
test "gallery navigation wraps loaded images and tolerates collection changes" {
    try std.testing.expectEqual(@as(?usize, null), galleryIndex(0, 0, 1));
    try std.testing.expectEqual(@as(?usize, 0), galleryIndex(0, 1, -1));
    try std.testing.expectEqual(@as(?usize, 191), galleryIndex(0, 192, -1));
    try std.testing.expectEqual(@as(?usize, 0), galleryIndex(191, 192, 1));
    try std.testing.expectEqual(@as(?usize, 2), galleryIndex(1, 192, 1));
    try std.testing.expectEqual(@as(?usize, 0), galleryIndex(100, 6, 1));
}

/// Prefetch two rows before the end, also filling a viewport shorter than a page.
pub fn shouldLoadNext(row_count: usize, pitch: f32, y: f32, height: f32, busy: bool, more: bool) bool {
    if (busy or !more or row_count == 0 or pitch <= 0 or height <= 0) return false;
    return @max(0, y) + height + pitch * 2 >= @as(f32, @floatFromInt(row_count)) * pitch;
}
test "wallpaper scroll prefetch waits for current page and stops at end" {
    try std.testing.expect(!shouldLoadNext(20, 200, 0, 800, false, true));
    try std.testing.expect(shouldLoadNext(20, 200, 2800, 800, false, true));
    try std.testing.expect(!shouldLoadNext(20, 200, 2800, 800, true, true));
    try std.testing.expect(!shouldLoadNext(20, 200, 2800, 800, false, false));
    try std.testing.expect(shouldLoadNext(2, 200, 0, 800, false, true));
    try std.testing.expect(!shouldLoadNext(2, 200, 0, 0, false, true));
}

test "gallery media accepts GIF and video without accepting executable extensions" {
    try std.testing.expectEqual(Media.gif, mediaKind(urlExtension("https://host/image.GIF?token=a").?));
    try std.testing.expectEqual(Media.video, mediaKind(urlExtension("https://host/loop.webm").?));
    try std.testing.expect(mediaExtension("exe") == null);
    var result: [3]Row = undefined;
    const count = try parse(std.testing.allocator, .gallery,
        \\[[3,"https://host/a.gif",{"extension":"gif"}],[3,"https://host/b.mp4",{"extension":"mp4","thumbnail":"https://host/thumb.jpg"}],[3,"https://host/a.exe",{"extension":"exe"}]]
    , &result);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(Media.gif, result[0].media);
    try std.testing.expectEqual(Media.video, result[1].media);
}
