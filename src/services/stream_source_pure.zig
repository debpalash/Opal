//! Bounded transport contract shared by executable plugins and Stremio.
const std = @import("std");
pub const Source = struct {
    url: [8192]u8 = @splat(0),
    url_len: usize = 0,
    title: [256]u8 = @splat(0),
    title_len: usize = 0,
    language: [64]u8 = @splat(0),
    language_len: usize = 0,
    quality: [32]u8 = @splat(0),
    quality_len: usize = 0,
    user_agent: [512]u8 = @splat(0),
    user_agent_len: usize = 0,
    header_fields: [2048]u8 = @splat(0),
    header_fields_len: usize = 0,
    /// Swarm size an addon reports in its row text (a U+1F464 marker, e.g. "<bust> 368"); 0 = unknown.
    seeds: u16 = 0,
    /// Stremio `fileIdx`: the file inside a multi-file torrent this row means
    /// (the episode in a season pack). -1 = unspecified. Also carried on the
    /// magnet as BEP 53 `&so=N`, which is what reaches the player.
    file_idx: i32 = -1,
};

/// Upper bound for a believable torrent file index.
pub const max_file_index: u32 = 99_999;

/// A row's `fileIdx` when it is a sane non-negative integer.
pub fn fileIndex(value: std.json.Value) ?u32 {
    if (value != .object) return null;
    const f = value.object.get("fileIdx") orelse return null;
    if (f != .integer or f.integer < 0 or f.integer > max_file_index) return null;
    return @intCast(f.integer);
}

/// The single file a magnet selects via BEP 53 `so=N`. A list or range
/// ("0,2", "4-6") is not one file, so it selects nothing here.
pub fn magnetFileIndex(url: []const u8) ?u32 {
    if (url.len < 8 or !std.ascii.eqlIgnoreCase(url[0..8], "magnet:?")) return null;
    var it = std.mem.splitScalar(u8, url[8..], '&');
    while (it.next()) |param| {
        if (!std.mem.startsWith(u8, param, "so=")) continue;
        const digits = param[3..];
        if (digits.len == 0 or digits.len > 5) return null;
        for (digits) |c| if (!std.ascii.isDigit(c)) return null;
        return std.fmt.parseInt(u32, digits, 10) catch null;
    }
    return null;
}

/// Which torrent file the player opens once metadata lists the files; -1 = none
/// pinned (caller falls back to its own rule). A filename that matches the
/// armed episode outranks the source's index; the source's index (a search
/// row's fileIdx) counts only when that file is playable media.
pub fn pinnedTorrentFile(episode_match: i32, requested: i32, requested_playable: bool) i32 {
    if (episode_match >= 0) return episode_match;
    if (requested >= 0 and requested_playable) return requested;
    return -1;
}

/// Record `idx` on the source and, for a magnet with no `so=` yet, on the URL.
fn setFileIndex(s: *Source, idx: u32) void {
    s.file_idx = @intCast(idx);
    const url = s.url[0..s.url_len];
    if (url.len < 8 or !std.ascii.eqlIgnoreCase(url[0..8], "magnet:?")) return;
    if (std.mem.indexOf(u8, url, "&so=") != null or std.mem.startsWith(u8, url[8..], "so=")) {
        s.file_idx = if (magnetFileIndex(url)) |own| @intCast(own) else -1;
        return;
    }
    const added = std.fmt.bufPrint(s.url[s.url_len..], "&so={d}", .{idx}) catch {
        s.file_idx = -1; // the URL is what plays; never claim an index it lacks
        return;
    };
    s.url_len += added.len;
}

/// First non-blank line of an addon's multi-line row text. Torrentio packs
/// "release name\n<seeds> <size>" into one field; only the release name
/// identifies the title.
pub fn firstLine(text: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, text, "\r\n");
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len > 0) return trimmed;
    }
    return "";
}

/// The text after `marker` on the line that carries it ("<page> Release.Name.mkv").
pub fn markedLine(text: []const u8, marker: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, text, "\r\n");
    while (it.next()) |line| {
        const at = std.mem.indexOf(u8, line, marker) orelse continue;
        const rest = std.mem.trim(u8, line[at + marker.len ..], " \t");
        if (rest.len > 0) return rest;
    }
    return "";
}

/// Seeder count from the U+1F464 "<bust> N" marker torrent addons put in their row text.
pub fn seedsFromText(text: []const u8) u16 {
    const at = std.mem.indexOf(u8, text, "\xF0\x9F\x91\xA4") orelse return 0;
    var i = at + 4;
    while (i < text.len and text[i] == ' ') i += 1;
    var n: u32 = 0;
    var digits: usize = 0;
    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
        n = @min(n * 10 + (text[i] - '0'), std.math.maxInt(u16));
        digits += 1;
    }
    return if (digits == 0) 0 else @intCast(n);
}

/// Append the addon's `sources: ["tracker:udp://…"]` entries to a bare
/// info-hash magnet. Without them the swarm is found over DHT alone.
fn appendTrackers(s: *Source, value: std.json.Value) void {
    const sources = value.object.get("sources") orelse return;
    if (sources != .array) return;
    var added: usize = 0;
    for (sources.array.items) |entry| {
        if (added == 8) break;
        if (entry != .string or !std.mem.startsWith(u8, entry.string, "tracker:")) continue;
        const tracker = entry.string["tracker:".len..];
        if (tracker.len == 0 or tracker.len > 200) continue;
        const start = s.url_len;
        var w = start;
        const prefix = "&tr=";
        if (w + prefix.len + tracker.len * 3 > s.url.len) break;
        @memcpy(s.url[w..][0..prefix.len], prefix);
        w += prefix.len;
        var ok = true;
        for (tracker) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
                s.url[w] = c;
                w += 1;
            } else if (c <= 32 or c == 127) {
                ok = false;
                break;
            } else {
                _ = std.fmt.bufPrint(s.url[w..][0..3], "%{X:0>2}", .{c}) catch unreachable;
                w += 3;
            }
        }
        if (!ok) continue;
        s.url_len = w;
        added += 1;
    }
}

fn string(v: std.json.Value, key: []const u8) []const u8 {
    if (v != .object) return "";
    const f = v.object.get(key) orelse return "";
    return if (f == .string) f.string else "";
}
fn put(dst: []u8, len: *usize, value: []const u8) bool {
    if (value.len > dst.len) return false;
    @memcpy(dst[0..value.len], value);
    len.* = value.len;
    return true;
}
fn safe(value: []const u8) bool {
    for (value) |c| if (c < 32 or c == 127 or c == ',') return false;
    return true;
}
fn header(s: *Source, name: []const u8, value: []const u8) bool {
    if (value.len == 0) return true;
    if (!safe(value)) return false;
    if (std.ascii.eqlIgnoreCase(name, "User-Agent")) return put(&s.user_agent, &s.user_agent_len, value);
    // Only transport identity headers are accepted. Never accept arbitrary
    // option names, Host, connection controls, or newline injection.
    const canonical = if (std.ascii.eqlIgnoreCase(name, "Referer")) "Referer" else if (std.ascii.eqlIgnoreCase(name, "Origin")) "Origin" else return true;
    const sep: []const u8 = if (s.header_fields_len > 0) "," else "";
    const result = std.fmt.bufPrint(s.header_fields[s.header_fields_len..], "{s}{s}: {s}", .{ sep, canonical, value }) catch return false;
    s.header_fields_len += result.len;
    return true;
}
pub fn fromValue(value: std.json.Value) ?Source {
    if (value != .object) return null;
    var s: Source = .{};
    var url = string(value, "url");
    if (url.len == 0) url = string(value, "stream_url");
    if (url.len == 0) {
        const hash = string(value, "infoHash");
        if (hash.len != 40) return null;
        for (hash) |c| if (!std.ascii.isHex(c)) return null;
        const magnet = std.fmt.bufPrint(&s.url, "magnet:?xt=urn:btih:{s}", .{hash}) catch return null;
        s.url_len = magnet.len;
        if (fileIndex(value)) |idx| setFileIndex(&s, idx);
        appendTrackers(&s, value);
    } else {
        if (!(std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "magnet:?"))) return null;
        for (url) |c| if (c <= 32 or c == 127) return null;
        if (!std.mem.startsWith(u8, url, "magnet:?")) {
            const uri = std.Uri.parse(url) catch return null;
            if (uri.host == null or uri.host.?.percent_encoded.len == 0) return null;
        }
        if (!put(&s.url, &s.url_len, url)) return null;
        if (fileIndex(value)) |idx| setFileIndex(&s, idx);
    }
    // Torrentio/TorrentsDB name the release in `title`; Comet/Torz mark it with
    // a U+1F4C4 page marker inside `description`; MediaFusion only in behaviorHints.filename.
    // `name` is the addon + quality badge ("Peerflix 4K") and can never match
    // the searched title, so it is the last resort.
    const description = string(value, "description");
    const row_text = if (string(value, "title").len > 0) string(value, "title") else description;
    var title = firstLine(string(value, "title"));
    if (title.len == 0) title = markedLine(description, "\xF0\x9F\x93\x84");
    if (title.len == 0) if (value.object.get("behaviorHints")) |hints| {
        title = firstLine(string(hints, "filename"));
    };
    if (title.len == 0) title = firstLine(description);
    if (title.len == 0) title = firstLine(string(value, "name"));
    s.seeds = seedsFromText(row_text);
    _ = put(&s.title, &s.title_len, title[0..@min(title.len, s.title.len)]);
    const language = string(value, "language");
    _ = put(&s.language, &s.language_len, language[0..@min(language.len, s.language.len)]);
    const quality = string(value, "quality");
    _ = put(&s.quality, &s.quality_len, quality[0..@min(quality.len, s.quality.len)]);
    var headers = value.object.get("headers");
    if (value.object.get("behaviorHints")) |hints| {
        if (hints == .object) if (hints.object.get("proxyHeaders")) |proxy| {
            if (proxy == .object) headers = proxy.object.get("request");
        };
    }
    if (headers) |h| {
        if (h != .object) return null;
        var it = h.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) return null;
            if (!header(&s, entry.key_ptr.*, entry.value_ptr.string)) return null;
        }
    }
    if (!header(&s, "Referer", string(value, "referer")) or !header(&s, "Origin", string(value, "origin")) or !header(&s, "User-Agent", string(value, "user_agent"))) return null;
    return s;
}
pub fn parseResolve(allocator: std.mem.Allocator, json: []const u8) ?Source {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return null;
    defer parsed.deinit();
    return fromValue(parsed.value);
}
pub fn parseStreams(allocator: std.mem.Allocator, json: []const u8, out: []Source) ?usize {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const rows = parsed.value.object.get("streams") orelse return null;
    if (rows != .array) return null;
    var count: usize = 0;
    for (rows.array.items) |row| {
        if (count == out.len) break;
        out[count] = fromValue(row) orelse continue;
        count += 1;
    }
    return count;
}

test "structured stream JSON preserves escaped URLs and isolates row metadata" {
    var out: [3]Source = undefined;
    const n = parseStreams(std.testing.allocator,
        \\{"streams": [{"url": "https:\/\/media.test/a?x=1&y=2", "title": "First", "language":"en", "behaviorHints":{"proxyHeaders":{"request":{"Referer":"https://page.test/","User-Agent":"Fixture"}}}}, {"url":"https://media.test/b", "title":"Second"}, {"infoHash":"0123456789012345678901234567890123456789"}]}
    , &out).?;
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("https://media.test/a?x=1&y=2", out[0].url[0..out[0].url_len]);
    try std.testing.expectEqualStrings("Fixture", out[0].user_agent[0..out[0].user_agent_len]);
    try std.testing.expectEqualStrings("Referer: https://page.test/", out[0].header_fields[0..out[0].header_fields_len]);
    try std.testing.expectEqualStrings("Second", out[1].title[0..out[1].title_len]);
    try std.testing.expectEqual(@as(usize, 0), out[1].header_fields_len);
    try std.testing.expect(std.mem.startsWith(u8, out[2].url[0..out[2].url_len], "magnet:?"));
}
test "long signed URLs survive intact; overflow and injection fail closed" {
    var url: [9000]u8 = @splat('a');
    @memcpy(url[0..19], "https://media.test/");
    var json: [9500]u8 = undefined;
    const accepted = std.fmt.bufPrint(&json, "{{\"url\":\"{s}\"}}", .{url[0..6000]}) catch unreachable;
    try std.testing.expectEqual(@as(usize, 6000), parseResolve(std.testing.allocator, accepted).?.url_len);
    const rejected = std.fmt.bufPrint(&json, "{{\"url\":\"{s}\"}}", .{&url}) catch unreachable;
    try std.testing.expect(parseResolve(std.testing.allocator, rejected) == null);
    try std.testing.expect(parseResolve(std.testing.allocator, "{\"url\":\"https://x/a\",\"headers\":{\"Referer\":\"a\\r\\nHost: evil\"}}") == null);
    try std.testing.expect(parseResolve(std.testing.allocator, "{\"url\":\"file:///secret\"}") == null);
}

test "malformed rows and invalid hashes never masquerade as direct streams" {
    var out: [3]Source = undefined;
    const json = "{\"streams\":[{\"externalUrl\":\"https://page.test/\"},{\"infoHash\":\"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\"},{\"url\":\"https://media.test/good\"}]}";
    try std.testing.expectEqual(@as(usize, 1), parseStreams(std.testing.allocator, json, &out).?);
    try std.testing.expect(parseStreams(std.testing.allocator, "{\"streams\":{}}", &out) == null);
    try std.testing.expect(parseResolve(std.testing.allocator, "{\"url\":\"https:///missing-host\"}") == null);
    try std.testing.expect(parseResolve(std.testing.allocator, "{\"url\":\"https://media.test/a\",\"headers\":{\"Origin\":\"https://a,Host: b\"}}") == null);
}

test "addon rows: release name comes from title or description, never the badge" {
    var out: [5]Source = undefined;
    // Captured row shapes: Torrentio (title), Peerflix (description + trackers).
    const json =
        \\{"streams":[
        \\{"name":"Torrentio\n4k HDR","title":"Dune 2021 2160p WEBRip\n\ud83d\udc64 368 6.9 GB ThePirateBay","infoHash":"0123456789abcdef0123456789abcdef01234567","fileIdx":0},
        \\{"name":"Peerflix 4K","description":"DUNE [4K UHDremux][2160p]\nDune 4Kremux2160.mkv\n  \ud83d\udc64 23 68.65 GB Peerflix","infoHash":"b7f1efd0509327df2fdc91d49747f7ca044df297","sources":["tracker:udp://tracker.opentrackr.org:1337/announce","dht:b7f1efd0509327df2fdc91d49747f7ca044df297"]},
        \\{"name":"Only Name","url":"https://media.test/v.mp4"},
        \\{"name":"[P2P]\nTorz\n4k","description":"BluRay HEVC\n9.5 GB \ud83d\udc64 97\n\ud83d\udcc4 Breaking Bad  S01E01  Pilot.mkv","infoHash":"a584351126afcf50d32be068f3c9a62550d41ecc"},
        \\{"name":"MediaFusion P2P 2160P","description":"BluRay REMUX hevc\n86 GB","behaviorHints":{"filename":"Dune 2021 2160p BluRay Remux-SGF mkv"},"infoHash":"c0a8b35b73e64426f1c409f09b82ace89742b0d0"}
        \\]}
    ;
    try std.testing.expectEqual(@as(usize, 5), parseStreams(std.testing.allocator, json, &out).?);
    try std.testing.expectEqualStrings("Breaking Bad  S01E01  Pilot.mkv", out[3].title[0..out[3].title_len]);
    try std.testing.expectEqual(@as(u16, 97), out[3].seeds);
    try std.testing.expectEqualStrings("Dune 2021 2160p BluRay Remux-SGF mkv", out[4].title[0..out[4].title_len]);
    try std.testing.expectEqualStrings("Dune 2021 2160p WEBRip", out[0].title[0..out[0].title_len]);
    try std.testing.expectEqual(@as(u16, 368), out[0].seeds);
    try std.testing.expectEqualStrings("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&so=0", out[0].url[0..out[0].url_len]);
    try std.testing.expectEqualStrings("DUNE [4K UHDremux][2160p]", out[1].title[0..out[1].title_len]);
    try std.testing.expectEqual(@as(u16, 23), out[1].seeds);
    try std.testing.expectEqualStrings("magnet:?xt=urn:btih:b7f1efd0509327df2fdc91d49747f7ca044df297&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce", out[1].url[0..out[1].url_len]);
    try std.testing.expectEqualStrings("Only Name", out[2].title[0..out[2].title_len]);
    try std.testing.expectEqual(@as(u16, 0), out[2].seeds);
    try std.testing.expectEqual(@as(u16, 65535), seedsFromText("\xF0\x9F\x91\xA4 99999999"));
    try std.testing.expectEqual(@as(u16, 0), seedsFromText("\xF0\x9F\x91\xA4 many"));
}

/// Equal media URLs are interchangeable only with the same HTTP identity.
pub fn sameIdentity(a: *const Source, b: *const Source) bool {
    return std.mem.eql(u8, a.user_agent[0..a.user_agent_len], b.user_agent[0..b.user_agent_len]) and
        std.mem.eql(u8, a.header_fields[0..a.header_fields_len], b.header_fields[0..b.header_fields_len]);
}
test "dedup keeps different provider HTTP identities separate" {
    const plain = parseResolve(std.testing.allocator, "{\"url\":\"https://cdn.test/a\"}").?;
    const protected = parseResolve(std.testing.allocator, "{\"url\":\"https://cdn.test/a\",\"referer\":\"https://player.test/\"}").?;
    try std.testing.expect(!sameIdentity(&plain, &protected));
    try std.testing.expect(sameIdentity(&protected, &protected));
}

test "regression: season-pack fileIdx reaches the magnet instead of being dropped" {
    var out: [6]Source = undefined;
    // Row shapes captured from torrentio /stream/anime/kitsu:1:1.json (2026-11):
    // one season pack, the requested episode is file 1, not the first/largest.
    const json =
        \\{"streams":[
        \\{"name":"Torrentio\n4k","title":"Cowboy Bebop S01 pack\nCowboy Bebop 01 Asteroid Blues.mkv\n\ud83d\udc64 11","infoHash":"625c297f0bd93eeb4ff2f51e34a2b0f3d685f867","fileIdx":1,"sources":["tracker:udp://t.test:1337/announce"]},
        \\{"title":"single file","infoHash":"0123456789abcdef0123456789abcdef01234567"},
        \\{"title":"bad idx","infoHash":"0123456789abcdef0123456789abcdef01234567","fileIdx":-3},
        \\{"title":"string idx","infoHash":"0123456789abcdef0123456789abcdef01234567","fileIdx":"2"},
        \\{"title":"direct","url":"https://media.test/v.mkv","fileIdx":4},
        \\{"title":"own so","url":"magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&so=7","fileIdx":2}
        \\]}
    ;
    try std.testing.expectEqual(@as(usize, 6), parseStreams(std.testing.allocator, json, &out).?);
    try std.testing.expectEqual(@as(i32, 1), out[0].file_idx);
    try std.testing.expectEqualStrings(
        "magnet:?xt=urn:btih:625c297f0bd93eeb4ff2f51e34a2b0f3d685f867&so=1&tr=udp%3A%2F%2Ft.test%3A1337%2Fannounce",
        out[0].url[0..out[0].url_len],
    );
    try std.testing.expectEqual(@as(?u32, 1), magnetFileIndex(out[0].url[0..out[0].url_len]));
    for (out[1..4]) |row| {
        try std.testing.expectEqual(@as(i32, -1), row.file_idx);
        try std.testing.expectEqual(@as(?u32, null), magnetFileIndex(row.url[0..row.url_len]));
    }
    // A direct URL keeps the index as data but its URL is untouched.
    try std.testing.expectEqual(@as(i32, 4), out[4].file_idx);
    try std.testing.expectEqualStrings("https://media.test/v.mkv", out[4].url[0..out[4].url_len]);
    // A magnet that already selects a file keeps its own selection.
    try std.testing.expectEqual(@as(i32, 7), out[5].file_idx);
    try std.testing.expect(std.mem.endsWith(u8, out[5].url[0..out[5].url_len], "&so=7"));
}

test "magnetFileIndex reads one BEP 53 file and nothing else" {
    try std.testing.expectEqual(@as(?u32, 12), magnetFileIndex("magnet:?xt=urn:btih:abc&so=12&tr=x"));
    try std.testing.expectEqual(@as(?u32, 0), magnetFileIndex("MAGNET:?so=0&xt=urn:btih:abc"));
    try std.testing.expectEqual(@as(?u32, null), magnetFileIndex("magnet:?xt=urn:btih:abc"));
    try std.testing.expectEqual(@as(?u32, null), magnetFileIndex("magnet:?xt=urn:btih:abc&so=0,2"));
    try std.testing.expectEqual(@as(?u32, null), magnetFileIndex("magnet:?xt=urn:btih:abc&so=4-6"));
    try std.testing.expectEqual(@as(?u32, null), magnetFileIndex("magnet:?xt=urn:btih:abc&so="));
    try std.testing.expectEqual(@as(?u32, null), magnetFileIndex("magnet:?xt=urn:btih:abc&so=999999"));
    try std.testing.expectEqual(@as(?u32, null), magnetFileIndex("magnet:?xt=urn:btih:abc&iso=3"));
    try std.testing.expectEqual(@as(?u32, null), magnetFileIndex("https://x.test/a?so=3"));
}

test "pinnedTorrentFile: episode filename, then a playable requested file, else none" {
    try std.testing.expectEqual(@as(i32, 4), pinnedTorrentFile(-1, 4, true));
    try std.testing.expectEqual(@as(i32, -1), pinnedTorrentFile(-1, 4, false)); // .exe / out of range
    try std.testing.expectEqual(@as(i32, 2), pinnedTorrentFile(2, 4, true));
    try std.testing.expectEqual(@as(i32, -1), pinnedTorrentFile(-1, -1, false));
}
