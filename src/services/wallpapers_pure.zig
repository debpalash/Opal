//! Provider-independent wallpaper identity, bounded metadata and API adapters.
const std = @import("std");
pub const Source = enum { all, wallhaven, pexels, unsplash, gallery, mixkit, commons, saved };
pub const MediaFilter = enum { all, images, videos };
pub fn accepts(filter: MediaFilter, media: Media) bool {
    return switch (filter) {
        .all => true,
        .images => media == .image,
        .videos => media != .image,
    };
}
pub fn Field(comptime size: usize) type {
    return struct {
        bytes: [size]u8 = @splat(0),
        len: usize = 0,
        pub fn set(self: *@This(), value: []const u8) void {
            self.len = @min(value.len, size);
            if (self.len < value.len) while (self.len > 0 and value[self.len] & 0xc0 == 0x80) {
                self.len -= 1;
            };
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
    motion_preview: Field(2048) = .{},
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
    if (source == .mixkit) return parseMixkit(allocator, json, out);
    if (source == .commons) return parseCommons(allocator, json, out);
    if (source == .saved) return parseSaved(allocator, json, out);
    const doc = try std.json.parseFromSlice(std.json.Value, allocator, json, .{ .allocate = .alloc_always });
    defer doc.deinit();
    const list = switch (source) {
        .wallhaven => get(doc.value, "data"),
        .pexels => get(doc.value, "photos"),
        .unsplash => if (doc.value == .array) doc.value else get(doc.value, "results"),
        .gallery => doc.value,
        .all, .mixkit, .commons, .saved => return error.InvalidProvider,
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

pub fn videoSearchUrl(source: Source, query: []const u8, page: u32, out: []u8) ?[]const u8 {
    var encoded: [3072]u8 = undefined;
    if (source == .mixkit) {
        var slug: [1024]u8 = undefined;
        const text = if (query.len == 0) "nature" else query;
        if (text.len > slug.len) return null;
        for (text, 0..) |ch, i| slug[i] = if (ch == ' ') '-' else std.ascii.toLower(ch);
        const q = @import("audio_sources_pure.zig").encode(&encoded, slug[0..text.len]) orelse return null;
        return std.fmt.bufPrint(out, "https://mixkit.co/free-stock-video/discover/{s}/?page={d}", .{ q, page }) catch null;
    }
    if (source == .commons) {
        var search: [1200]u8 = undefined;
        const text = std.fmt.bufPrint(&search, "filetype:video {s}", .{if (query.len == 0) "landscape" else query}) catch return null;
        const q = @import("audio_sources_pure.zig").encode(&encoded, text) orelse return null;
        return std.fmt.bufPrint(out, "https://commons.wikimedia.org/w/api.php?action=query&generator=search&gsrsearch={s}&gsrnamespace=6&gsrlimit=24&gsroffset={d}&prop=imageinfo&iiprop=url%7Csize%7Cmime%7Cextmetadata&iiurlwidth=640&format=json", .{ q, (page -| 1) * 24 }) catch null;
    }
    return null;
}
fn mediaHost(url: []const u8, host: []const u8) bool {
    if (!mediaUrl(url)) return false;
    const uri = std.Uri.parse(url) catch return false;
    return std.ascii.eqlIgnoreCase(uri.host.?.percent_encoded, host);
}
fn parseMixkit(allocator: std.mem.Allocator, body: []const u8, out: []Row) !usize {
    const html = @import("content_html_pure.zig");
    var pos: usize = 0;
    var count: usize = 0;
    while (std.mem.indexOfPos(u8, body, pos, "<script")) |at| {
        const end = std.mem.indexOfScalarPos(u8, body, at, '>') orelse break;
        const close = std.mem.indexOfPos(u8, body, end + 1, "</script>") orelse break;
        pos = close + 9;
        if (!std.mem.eql(u8, html.attr(body[at .. end + 1], "type") orelse "", "application/ld+json")) continue;
        const doc = std.json.parseFromSlice(std.json.Value, allocator, body[end + 1 .. close], .{}) catch continue;
        defer doc.deinit();
        const graph = get(doc.value, "@graph");
        if (graph != .array) continue;
        for (graph.array.items) |entry| {
            if (count == out.len) return count;
            if (!std.mem.eql(u8, str(get(entry, "@type")), "VideoObject")) continue;
            const free = get(entry, "isAccessibleForFree");
            if (free != .bool or !free.bool) continue;
            const original = str(get(entry, "contentUrl"));
            const thumb = str(get(entry, "thumbnailUrl"));
            const detail = str(get(entry, "@id"));
            if (original.len > 2048 or thumb.len > 1024 or detail.len > 1024) continue;
            if (!mediaHost(original, "assets.mixkit.co") or !mediaHost(thumb, "assets.mixkit.co") or !std.mem.startsWith(u8, detail, "https://mixkit.co/free-stock-video/")) continue;
            const ext = urlExtension(original) orelse continue;
            if (mediaKind(ext) != .video) continue;
            var row: Row = .{ .source = .mixkit, .media = .video };
            row.original.set(original);
            row.preview.set(thumb);
            const preview_url = str(get(entry, "embedUrl"));
            if (mediaHost(preview_url, "assets.mixkit.co") and mediaKind(urlExtension(preview_url) orelse "") == .video) row.motion_preview.set(preview_url);
            row.page.set(detail[0 .. std.mem.indexOfScalar(u8, detail, '#') orelse detail.len]);
            row.title.set(str(get(entry, "name")));
            row.author.set("Mixkit · Free video license");
            row.extension.set(ext);
            row.width = num(get(entry, "width"));
            row.height = num(get(entry, "height"));
            out[count] = row;
            count += 1;
        }
    }
    return count;
}
fn parseCommons(allocator: std.mem.Allocator, body: []const u8, out: []Row) !usize {
    const doc = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer doc.deinit();
    const pages = get(get(doc.value, "query"), "pages");
    if (pages != .object) return if (get(doc.value, "query") == .null) error.InvalidResponse else 0;
    var it = pages.object.iterator();
    var count: usize = 0;
    while (it.next()) |entry| {
        if (count == out.len) break;
        const page = entry.value_ptr.*;
        const infos = get(page, "imageinfo");
        if (infos != .array or infos.array.items.len == 0) continue;
        const info = infos.array.items[0];
        if (!std.mem.startsWith(u8, str(get(info, "mime")), "video/")) continue;
        const original = str(get(info, "url"));
        const thumb = str(get(info, "thumburl"));
        if (original.len > 2048 or thumb.len > 1024) continue;
        if (!mediaHost(original, "upload.wikimedia.org") or (!mediaHost(thumb, "upload.wikimedia.org") and !mediaHost(thumb, "thumb.wikimedia.org"))) continue;
        const ext = urlExtension(original) orelse continue;
        if (mediaKind(ext) != .video) continue;
        var row: Row = .{ .source = .commons, .media = .video };
        row.original.set(original);
        row.preview.set(thumb);
        row.page.set(str(get(info, "descriptionurl")));
        if (!mediaHost(row.page.text(), "commons.wikimedia.org")) continue;
        const title = str(get(page, "title"));
        row.title.set(if (std.mem.startsWith(u8, title, "File:")) title[5..] else title);
        const meta = get(info, "extmetadata");
        var author: [128]u8 = undefined;
        const name_len = @import("novels_pure.zig").htmlToText(str(get(get(meta, "Artist"), "value")), &author);
        row.author.set(if (name_len > 0) author[0..name_len] else "Wikimedia Commons");
        row.extension.set(ext);
        row.width = num(get(info, "width"));
        row.height = num(get(info, "height"));
        out[count] = row;
        count += 1;
    }
    return count;
}

pub const SavedRow = struct {
    source: Source,
    media: Media,
    title: []const u8,
    author: []const u8,
    preview: []const u8,
    original: []const u8,
    motion_preview: []const u8,
    page: []const u8,
    extension: []const u8,
    width: u32,
    height: u32,
    pub fn from(row: *const Row) SavedRow {
        return .{ .source = row.source, .media = row.media, .title = row.title.text(), .author = row.author.text(), .preview = row.preview.text(), .original = row.original.text(), .motion_preview = row.motion_preview.text(), .page = row.page.text(), .extension = row.extension.text(), .width = row.width, .height = row.height };
    }
};
fn parseSaved(allocator: std.mem.Allocator, body: []const u8, out: []Row) !usize {
    const doc = try std.json.parseFromSlice([]SavedRow, allocator, body, .{ .ignore_unknown_fields = true });
    defer doc.deinit();
    var count: usize = 0;
    for (doc.value) |saved| {
        if (count == out.len) break;
        if ((!mediaUrl(saved.original) and !std.fs.path.isAbsolute(saved.original)) or saved.original.len > 2048) continue;
        const ext = mediaExtension(saved.extension) orelse continue;
        if (mediaKind(ext) != saved.media) continue;
        var row: Row = .{ .source = saved.source, .media = saved.media, .width = saved.width, .height = saved.height };
        row.title.set(saved.title);
        row.author.set(saved.author);
        row.preview.set(saved.preview);
        row.original.set(saved.original);
        row.motion_preview.set(saved.motion_preview);
        row.page.set(saved.page);
        row.extension.set(ext);
        out[count] = row;
        count += 1;
    }
    return count;
}

test "video wallpaper providers preserve advertised originals and fast previews without running page scripts" {
    const html = "<script type='application/ld+json'>{\"@graph\":[{\"@type\":\"VideoObject\",\"isAccessibleForFree\":true,\"contentUrl\":\"https://assets.mixkit.co/videos/1/1-1080.mp4\",\"embedUrl\":\"https://assets.mixkit.co/videos/1/1-360.mp4\",\"thumbnailUrl\":\"https://assets.mixkit.co/videos/1/1.jpg\",\"@id\":\"https://mixkit.co/free-stock-video/forest-1/#video\",\"name\":\"Forest\"}]}</script>";
    var out: [2]Row = undefined;
    try std.testing.expectEqual(@as(usize, 1), try parse(std.testing.allocator, .mixkit, html, &out));
    try std.testing.expectEqual(Media.video, out[0].media);
    try std.testing.expectEqualStrings("https://assets.mixkit.co/videos/1/1-1080.mp4", out[0].original.text());
    try std.testing.expectEqualStrings("https://assets.mixkit.co/videos/1/1-360.mp4", out[0].motion_preview.text());
    try std.testing.expectEqualStrings("https://mixkit.co/free-stock-video/forest-1/", out[0].page.text());
    try std.testing.expect(!accepts(.images, out[0].media));
    try std.testing.expect(accepts(.videos, out[0].media));
    const saved = try std.json.Stringify.valueAlloc(std.testing.allocator, &[_]SavedRow{SavedRow.from(&out[0])}, .{});
    defer std.testing.allocator.free(saved);
    try std.testing.expectEqual(@as(usize, 1), try parse(std.testing.allocator, .saved, saved, out[1..]));
    try std.testing.expectEqualStrings(out[0].original.text(), out[1].original.text());
    try std.testing.expectEqualStrings(out[0].motion_preview.text(), out[1].motion_preview.text());
}
test "video provider query encoding and Commons full video metadata" {
    var address: [4096]u8 = undefined;
    try std.testing.expectEqualStrings("https://mixkit.co/free-stock-video/discover/rain-forest/?page=2", videoSearchUrl(.mixkit, "Rain Forest", 2, &address).?);
    const url = videoSearchUrl(.commons, "sea & sky", 2, &address).?;
    try std.testing.expect(std.mem.indexOf(u8, url, "sea%20%26%20sky") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "gsroffset=24") != null);
    const json = "{\"query\":{\"pages\":{\"1\":{\"title\":\"File:Ocean.webm\",\"imageinfo\":[{\"url\":\"https://upload.wikimedia.org/a/ocean.webm\",\"thumburl\":\"https://thumb.wikimedia.org/a/thumb.jpg\",\"descriptionurl\":\"https://commons.wikimedia.org/wiki/File:Ocean.webm\",\"mime\":\"video/webm\",\"width\":1920,\"height\":1080}]}}}}";
    var out: [1]Row = undefined;
    try std.testing.expectEqual(@as(usize, 1), try parse(std.testing.allocator, .commons, json, &out));
    try std.testing.expectEqualStrings("Ocean.webm", out[0].title.text());
    try std.testing.expectEqual(@as(u32, 1920), out[0].width);
}
test "wallpaper metadata truncation preserves UTF-8 characters" {
    var field: Field(4) = .{};
    field.set("abc日");
    try std.testing.expectEqualStrings("abc", field.text());
    field.set("日ab");
    try std.testing.expectEqualStrings("日a", field.text());
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
