//! Public audio provider wire policy. No browse state, credentials or network.
const std = @import("std");
pub const SourceStatus = @import("resolver_lifecycle_pure.zig").SourceStatus;
pub const Provider = enum { openverse, netlabels, somafm };
pub const Kind = enum { music, radio };
pub const Item = struct {
    kind: Kind = .music,
    id: [256]u8 = @splat(0),
    id_len: usize = 0,
    title: [192]u8 = @splat(0),
    title_len: usize = 0,
    artist: [160]u8 = @splat(0),
    artist_len: usize = 0,
    cover: [512]u8 = @splat(0),
    cover_len: usize = 0,
    play_url: [1024]u8 = @splat(0),
    play_url_len: usize = 0,
    summary: [768]u8 = @splat(0),
    summary_len: usize = 0,
    license_url: [256]u8 = @splat(0),
    license_url_len: usize = 0,
    duration_ms: u64 = 0,
};
pub const Reply = struct { count: usize = 0, total: usize = 0, status: SourceStatus = .no_results };
pub fn field(v: std.json.Value, key: []const u8) std.json.Value {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
pub fn str(v: std.json.Value) []const u8 {
    return if (v == .string) v.string else "";
}
pub fn text(v: std.json.Value, key: []const u8) []const u8 {
    return str(field(v, key));
}
pub fn number(v: std.json.Value) usize {
    return if (v == .integer and v.integer >= 0) @intCast(v.integer) else 0;
}
pub fn copy(out: []u8, len: *usize, value: []const u8) void {
    len.* = @min(out.len, value.len);
    while (len.* > 0 and len.* < value.len and value[len.*] & 0xc0 == 0x80) len.* -= 1;
    @memcpy(out[0..len.*], value[0..len.*]);
}
pub fn safeUrl(url: []const u8) bool {
    const start: usize = if (std.mem.startsWith(u8, url, "https://")) 8 else if (std.mem.startsWith(u8, url, "http://")) 7 else return false;
    const end = std.mem.indexOfAnyPos(u8, url, start, "/?#") orelse url.len;
    if (end == start or std.mem.indexOfScalar(u8, url[start..end], '@') != null) return false;
    for (url) |c| if (c <= 32 or c == 127) return false;
    return true;
}
pub fn encode(out: []u8, input: []const u8) ?[]const u8 {
    const hex = "0123456789ABCDEF";
    var n: usize = 0;
    for (input) |c| {
        const plain = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
        const need: usize = if (plain) 1 else 3;
        if (n + need > out.len) return null;
        if (plain) {
            out[n] = c;
        } else {
            out[n] = '%';
            out[n + 1] = hex[c >> 4];
            out[n + 2] = hex[c & 15];
        }
        n += need;
    }
    return out[0..n];
}
fn putUrl(out: []u8, len: *usize, url: []const u8) bool {
    if (!safeUrl(url) or url.len > out.len) return false;
    copy(out, len, url);
    return true;
}
fn finish(count: usize, total: usize) Reply {
    return .{ .count = count, .total = total, .status = if (count == 0) .no_results else if (total > count) .partial else .done };
}
pub fn parseOpenverse(root: std.json.Value, out: []Item) Reply {
    const rows = field(root, "results");
    if (rows != .array) return .{ .status = .parse_failed };
    var n: usize = 0;
    for (rows.array.items) |v| {
        if (!std.mem.eql(u8, text(v, "category"), "music") or text(v, "id").len == 0 or text(v, "title").len == 0) continue;
        const mature = field(v, "mature");
        if (mature == .bool and mature.bool) continue;
        if (n == out.len) break;
        var i: Item = .{};
        if (!putUrl(&i.play_url, &i.play_url_len, text(v, "url"))) continue;
        copy(&i.id, &i.id_len, text(v, "id"));
        copy(&i.title, &i.title_len, text(v, "title"));
        copy(&i.artist, &i.artist_len, text(v, "creator"));
        _ = putUrl(&i.cover, &i.cover_len, text(v, "thumbnail"));
        _ = putUrl(&i.license_url, &i.license_url_len, text(v, "license_url"));
        const credit = std.fmt.bufPrint(&i.summary, "License: {s}. {s}", .{ text(v, "license_url"), text(v, "attribution") }) catch null;
        if (credit) |value| i.summary_len = value.len else copy(&i.summary, &i.summary_len, text(v, "license_url"));
        i.duration_ms = number(field(v, "duration"));
        out[n] = i;
        n += 1;
    }
    return finish(n, number(field(root, "result_count")));
}
fn contains(value: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (query.len > value.len) return false;
    for (0..value.len - query.len + 1) |p| if (std.ascii.eqlIgnoreCase(value[p..][0..query.len], query)) return true;
    return false;
}
pub fn parseSoma(root: std.json.Value, query: []const u8, out: []Item) Reply {
    const rows = field(root, "channels");
    if (rows != .array) return .{ .status = .parse_failed };
    var n: usize = 0;
    var total: usize = 0;
    for (rows.array.items) |v| {
        if (!contains(text(v, "title"), query) and !contains(text(v, "description"), query) and !contains(text(v, "genre"), query) and !contains(text(v, "lastPlaying"), query)) continue;
        const playlists = field(v, "playlists");
        if (playlists != .array) continue;
        var chosen: []const u8 = "";
        for (playlists.array.items) |p| {
            const url = text(p, "url");
            if (!safeUrl(url)) continue;
            if (chosen.len == 0) chosen = url;
            if (std.mem.eql(u8, text(p, "format"), "mp3") and std.mem.eql(u8, text(p, "quality"), "highest")) {
                chosen = url;
                break;
            }
        }
        if (chosen.len == 0 or text(v, "id").len == 0) continue;
        total += 1;
        if (n == out.len) continue;
        var i: Item = .{ .kind = .radio };
        if (!putUrl(&i.play_url, &i.play_url_len, chosen)) continue;
        copy(&i.id, &i.id_len, text(v, "id"));
        copy(&i.title, &i.title_len, text(v, "title"));
        copy(&i.artist, &i.artist_len, text(v, "lastPlaying"));
        copy(&i.summary, &i.summary_len, text(v, "description"));
        _ = putUrl(&i.cover, &i.cover_len, text(v, "largeimage"));
        out[n] = i;
        n += 1;
    }
    return finish(n, total);
}
pub fn parseNetlabel(root: std.json.Value, expected_id: []const u8, out: []Item) Reply {
    const meta = field(root, "metadata");
    const files = field(root, "files");
    if (files != .array or !std.mem.eql(u8, text(meta, "identifier"), expected_id)) return .{ .status = .parse_failed };
    var eid: [768]u8 = undefined;
    const identifier = encode(&eid, expected_id) orelse return .{ .status = .parse_failed };
    var n: usize = 0;
    var total: usize = 0;
    for (files.array.items) |f| {
        const name = text(f, "name");
        if (!std.mem.endsWith(u8, name, ".mp3") or name.len > 512) continue;
        total += 1;
        if (n == out.len) continue;
        var encoded: [1536]u8 = undefined;
        const filename = encode(&encoded, name) orelse continue;
        var url: [2048]u8 = undefined;
        const target = std.fmt.bufPrint(&url, "https://archive.org/download/{s}/{s}", .{ identifier, filename }) catch continue;
        var i: Item = .{};
        if (!putUrl(&i.play_url, &i.play_url_len, target)) continue;
        const key = std.fmt.bufPrint(&i.id, "{s}/{s}", .{ expected_id, name }) catch continue;
        i.id_len = key.len;
        const title = text(f, "title");
        copy(&i.title, &i.title_len, if (title.len > 0) title else name[0 .. name.len - 4]);
        copy(&i.artist, &i.artist_len, text(meta, "creator"));
        const cover = std.fmt.bufPrint(&url, "https://archive.org/services/img/{s}", .{identifier}) catch "";
        _ = putUrl(&i.cover, &i.cover_len, cover);
        _ = putUrl(&i.license_url, &i.license_url_len, text(meta, "licenseurl"));
        const summary = std.fmt.bufPrint(&i.summary, "Album: {s}. License: {s}", .{ text(meta, "title"), text(meta, "licenseurl") }) catch "";
        i.summary_len = summary.len;
        out[n] = i;
        n += 1;
    }
    return finish(n, total);
}
test "public audio URL rejects credentials controls and non media schemes" {
    try std.testing.expect(safeUrl("https://host/song.mp3"));
    try std.testing.expect(!safeUrl("https://user:secret@host/song"));
    try std.testing.expect(!safeUrl("file:///tmp/a"));
    try std.testing.expect(!safeUrl("https://host/a\n"));
}
test "Openverse retains real full stream attribution and rejects sound effects" {
    const p = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"result_count\":2,\"results\":[{\"id\":\"1\",\"title\":\"Jazz\",\"creator\":\"Artist\",\"category\":\"music\",\"url\":\"https://cdn/song.mp3\",\"attribution\":\"Artist CC BY\",\"duration\":200000},{\"id\":\"2\",\"category\":\"sound_effect\"}]}", .{});
    defer p.deinit();
    var rows: [2]Item = undefined;
    const r = parseOpenverse(p.value, &rows);
    try std.testing.expectEqual(@as(usize, 1), r.count);
    try std.testing.expect(std.mem.indexOf(u8, rows[0].summary[0..rows[0].summary_len], "Artist CC BY") != null);
    try std.testing.expectEqual(@as(u64, 200000), rows[0].duration_ms);
}
test "Soma chooses supplied highest MP3 and exposes bounded catalog count" {
    const p = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"channels\":[{\"id\":\"groove\",\"title\":\"Groove Jazz\",\"playlists\":[{\"url\":\"https://api.somafm.com/g.pls\",\"format\":\"mp3\",\"quality\":\"highest\"}]}]}", .{});
    defer p.deinit();
    var rows: [1]Item = undefined;
    try std.testing.expectEqual(@as(usize, 1), parseSoma(p.value, "jazz", &rows).count);
    try std.testing.expectEqualStrings("https://api.somafm.com/g.pls", rows[0].play_url[0..rows[0].play_url_len]);
    try std.testing.expectEqual(@as(usize, 0), parseSoma(p.value, "classical", &rows).count);
}
test "Netlabels uses individual MP3 tracks not archive or alternate encodings" {
    const p = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"metadata\":{\"identifier\":\"album\",\"title\":\"Release\",\"licenseurl\":\"https://creativecommons.org/licenses/by/4.0/\"},\"files\":[{\"name\":\"01 song.mp3\"},{\"name\":\"01 song.flac\"},{\"name\":\"album.zip\"}]}", .{});
    defer p.deinit();
    var rows: [2]Item = undefined;
    try std.testing.expectEqual(@as(usize, 1), parseNetlabel(p.value, "album", &rows).count);
    try std.testing.expectEqualStrings("https://archive.org/download/album/01%20song.mp3", rows[0].play_url[0..rows[0].play_url_len]);
    try std.testing.expectEqual(SourceStatus.parse_failed, parseNetlabel(p.value, "other", &rows).status);
}
