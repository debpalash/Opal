//! Allocation-free routing and policy for remote playback-progress sync.
//! Network ownership lives in server_progress.zig; keeping stable identity
//! parsing here makes malformed persisted rows harmless and testable.
const std = @import("std");

pub const Provider = enum { audiobookshelf, jellyfin, plex };
pub const Event = enum { started, progress, paused, stopped };

pub const Route = struct {
    provider: Provider,
    item: []const u8,
};

pub fn parseIdentity(identity: []const u8) ?Route {
    const abs_prefix = "opal://audiobookshelf/";
    if (std.mem.startsWith(u8, identity, abs_prefix)) {
        const id = identity[abs_prefix.len..];
        if (validSimpleId(id, 64)) return .{ .provider = .audiobookshelf, .item = id };
        return null;
    }

    const jf_video = "opal://jellyfin/video/";
    const jf_audio = "opal://jellyfin/audio/";
    if (std.mem.startsWith(u8, identity, jf_video) or std.mem.startsWith(u8, identity, jf_audio)) {
        const prefix_len = if (std.mem.startsWith(u8, identity, jf_video)) jf_video.len else jf_audio.len;
        const id = identity[prefix_len..];
        if (validSimpleId(id, 64)) return .{ .provider = .jellyfin, .item = id };
        return null;
    }

    const plex_item_prefix = "opal://plex/item/";
    if (std.mem.startsWith(u8, identity, plex_item_prefix)) {
        const tail = identity[plex_item_prefix.len..];
        const marker = std.mem.indexOf(u8, tail, "/part/") orelse return null;
        const rating_key = tail[0..marker];
        const part = tail[marker + "/part".len ..];
        if (validRatingKey(rating_key) and validPlexPath(part))
            return .{ .provider = .plex, .item = rating_key };
        return null;
    }

    const plex_prefix = "opal://plex/";
    if (std.mem.startsWith(u8, identity, plex_prefix)) {
        const path = identity[plex_prefix.len - 1 ..];
        if (validPlexPath(path)) return .{ .provider = .plex, .item = path };
    }
    return null;
}

fn validRatingKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 32) return false;
    for (key) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

fn validSimpleId(id: []const u8, max_len: usize) bool {
    if (id.len == 0 or id.len > max_len) return false;
    for (id) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    }
    return true;
}

fn validPlexPath(path: []const u8) bool {
    if (path.len < 2 or path.len > 512 or path[0] != '/') return false;
    if (std.mem.indexOf(u8, path, "..") != null or std.mem.indexOfAny(u8, path, "?#\r\n") != null) return false;
    for (path) |ch| if (ch < 0x20 or ch == 0x7f) return false;
    return true;
}

pub fn validProgress(position: f64, duration: f64) bool {
    return std.math.isFinite(position) and std.math.isFinite(duration) and
        position > 1 and duration > 5 and duration < 315_576_000 and position <= duration + 60;
}

/// Avoid network churn while paused. Explicit switch/close saves set `force`.
pub fn shouldQueue(previous: ?f64, position: f64, duration: f64, force: bool) bool {
    if (!validProgress(position, duration)) return false;
    if (force) return true;
    const old = previous orelse return true;
    return @abs(position - old) >= 5.0;
}

pub fn isFinished(position: f64, duration: f64) bool {
    return validProgress(position, duration) and position / duration >= 0.95;
}

pub fn absProgressBody(position: f64, duration: f64, buf: []u8) ?[]const u8 {
    if (!validProgress(position, duration)) return null;
    return std.fmt.bufPrint(buf, "{{\"currentTime\":{d:.3},\"duration\":{d:.3},\"isFinished\":{s}}}", .{ position, duration, if (isFinished(position, duration)) "true" else "false" }) catch null;
}

pub fn jellyfinProgressBody(item: []const u8, event: Event, position: f64, duration: f64, buf: []u8) ?[]const u8 {
    if (!validSimpleId(item, 64)) return null;
    if (event != .started and !validProgress(position, duration)) return null;
    const pos_ticks: i64 = if (event == .started) 0 else @intFromFloat(position * 10_000_000.0);
    return switch (event) {
        .stopped => std.fmt.bufPrint(buf, "{{\"ItemId\":\"{s}\",\"PositionTicks\":{d},\"Failed\":false}}", .{ item, pos_ticks }) catch null,
        .started, .progress, .paused => std.fmt.bufPrint(buf, "{{\"ItemId\":\"{s}\",\"PositionTicks\":{d},\"IsPaused\":{s},\"IsMuted\":false,\"CanSeek\":true,\"PlayMethod\":\"DirectPlay\"}}", .{ item, pos_ticks, if (event == .paused) "true" else "false" }) catch null,
    };
}

pub fn plexTimelineUrl(server_raw: []const u8, rating_key: []const u8, event: Event, position: f64, duration: f64, buf: []u8) ?[]const u8 {
    if (!validRatingKey(rating_key) or server_raw.len == 0) return null;
    if (event != .started and !validProgress(position, duration)) return null;
    const server = std.mem.trimEnd(u8, server_raw, "/");
    const time_ms: i64 = if (event == .started) 0 else @intFromFloat(position * 1000.0);
    const duration_ms: i64 = if (event == .started) 0 else @intFromFloat(duration * 1000.0);
    const playback_state = switch (event) {
        .stopped => "stopped",
        .paused => "paused",
        else => "playing",
    };
    return std.fmt.bufPrint(buf, "{s}/:/timeline?ratingKey={s}&key=%2Flibrary%2Fmetadata%2F{s}&time={d}&duration={d}&state={s}&identifier=com.plexapp.plugins.library", .{ server, rating_key, rating_key, time_ms, duration_ms, playback_state }) catch null;
}

test "stable provider identities parse without credential material" {
    const abs = parseIdentity("opal://audiobookshelf/li_abc-123").?;
    try std.testing.expectEqual(Provider.audiobookshelf, abs.provider);
    try std.testing.expectEqualStrings("li_abc-123", abs.item);
    try std.testing.expectEqual(Provider.jellyfin, parseIdentity("opal://jellyfin/video/0123abcd").?.provider);
    try std.testing.expectEqualStrings("/library/parts/42/file.mkv", parseIdentity("opal://plex/library/parts/42/file.mkv").?.item);
    try std.testing.expectEqualStrings("42", parseIdentity("opal://plex/item/42/part/library/parts/7/file.mkv").?.item);
}

test "malformed provider identities are rejected" {
    try std.testing.expect(parseIdentity("https://example.test/video") == null);
    try std.testing.expect(parseIdentity("opal://audiobookshelf/a?token=secret") == null);
    try std.testing.expect(parseIdentity("opal://jellyfin/video/../../Users") == null);
    try std.testing.expect(parseIdentity("opal://plex/library/../secret") == null);
}

test "progress policy deduplicates paused samples and preserves seeks" {
    try std.testing.expect(shouldQueue(null, 20, 100, false));
    try std.testing.expect(!shouldQueue(20, 22, 100, false));
    try std.testing.expect(shouldQueue(20, 27, 100, false));
    try std.testing.expect(shouldQueue(80, 20, 100, false));
    try std.testing.expect(shouldQueue(20, 21, 100, true));
    try std.testing.expect(!shouldQueue(null, std.math.nan(f64), 100, true));
}

test "Audiobookshelf body is bounded JSON with finish state" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"currentTime\":40.000,\"duration\":100.000,\"isFinished\":false}",
        absProgressBody(40, 100, &buf).?,
    );
    try std.testing.expect(std.mem.endsWith(u8, absProgressBody(96, 100, &buf).?, "true}"));
}

test "Jellyfin lifecycle bodies use integer 100ns ticks" {
    var buf: [256]u8 = undefined;
    const started = jellyfinProgressBody("abc_123", .started, 0, 0, &buf).?;
    try std.testing.expect(std.mem.indexOf(u8, started, "\"PositionTicks\":0") != null);
    const progress = jellyfinProgressBody("abc_123", .progress, 12.5, 100, &buf).?;
    try std.testing.expect(std.mem.indexOf(u8, progress, "\"PositionTicks\":125000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, progress, "\"PlayMethod\":\"DirectPlay\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jellyfinProgressBody("abc_123", .paused, 12.5, 100, &buf).?, "\"IsPaused\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, jellyfinProgressBody("abc_123", .stopped, 12.5, 100, &buf).?, "\"Failed\":false") != null);
    try std.testing.expect(jellyfinProgressBody("../bad", .stopped, 12, 100, &buf) == null);
}

test "Plex timeline uses rating identity and integer milliseconds" {
    var buf: [512]u8 = undefined;
    const url = plexTimelineUrl("https://plex.test/", "42", .progress, 12.5, 100, &buf).?;
    try std.testing.expect(std.mem.indexOf(u8, url, "ratingKey=42") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "key=%2Flibrary%2Fmetadata%2F42") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "time=12500&duration=100000&state=playing") != null);
    try std.testing.expect(std.mem.indexOf(u8, plexTimelineUrl("https://plex.test", "42", .stopped, 90, 100, &buf).?, "state=stopped") != null);
    try std.testing.expect(std.mem.indexOf(u8, plexTimelineUrl("https://plex.test", "42", .paused, 90, 100, &buf).?, "state=paused") != null);
    try std.testing.expect(plexTimelineUrl("https://plex.test", "bad/key", .progress, 10, 100, &buf) == null);
}
