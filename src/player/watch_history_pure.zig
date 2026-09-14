//! Pure (io-free, state-free) helpers for seconds-accurate, path-keyed resume.
//! watch_history.zig / history.zig / player.zig / main.zig route their resume
//! decisions through these so the tested logic IS the shipped logic.

const std = @import("std");

/// Don't offer to resume anything shorter than this into playback — restarting
/// costs nothing and a sub-30s "resume" reads as a glitch.
pub const MIN_RESUME_SECS: f64 = 30.0;

/// At or past this fraction of the duration the item counts as finished.
pub const FINISHED_FRACTION: f64 = 0.95;

/// True when a seconds-accurate saved position is worth resuming:
/// at least MIN_RESUME_SECS in, and (when the duration is known) not
/// effectively finished. Unknown duration (<= 0) only gates on the floor.
pub fn resumeEligible(position_secs: f64, duration_secs: f64) bool {
    if (!(position_secs >= MIN_RESUME_SECS)) return false; // rejects NaN too
    if (duration_secs > 0 and position_secs >= FINISHED_FRACTION * duration_secs) return false;
    return true;
}

/// How a playback link is keyed in watch_history.
pub const KeyKind = enum {
    local_abs, // absolute filesystem path (or file:// URL) — key by path
    local_rel, // relative filesystem path — resolve to absolute, then key by path
    remote, // stream / torrent / URL — keep the legacy name key
};

/// Classify a playback link for key selection. Anything with a URI scheme
/// (magnet:, http://, ytdl://, ...) is remote; "/..." and "file://..." are
/// local; everything else is a relative local path.
pub fn classifyLink(link: []const u8) KeyKind {
    if (link.len == 0) return .remote;
    if (link[0] == '/') return .local_abs;
    if (std.mem.startsWith(u8, link, "file://")) return .local_abs;
    if (std.mem.startsWith(u8, link, "magnet:")) return .remote;
    if (std.mem.indexOf(u8, link, "://") != null) return .remote;
    if (std.mem.indexOfScalar(u8, link, ':')) |colon| {
        // RFC URI scheme, excluding a Windows drive prefix such as C:\\.
        if (colon > 1 and std.ascii.isAlphabetic(link[0])) {
            for (link[1..colon]) |ch| {
                if (!(std.ascii.isAlphanumeric(ch) or ch == '+' or ch == '-' or ch == '.')) break;
            } else return .remote;
        }
    }
    return .local_rel;
}

/// Filesystem path for a local link: "/abs/path" as-is, "file:///abs/path"
/// stripped of its scheme. Null for anything that isn't a local file.
pub fn localFsPath(link: []const u8) ?[]const u8 {
    if (link.len == 0) return null;
    if (link[0] == '/') return link;
    if (std.mem.startsWith(u8, link, "file://")) {
        const rest = link["file://".len..];
        if (rest.len > 0 and rest[0] == '/') return rest;
        return null;
    }
    return null;
}

/// Legacy-fallback decision: prefer the path-keyed hit; fall back to the
/// legacy name-keyed hit so pre-migration entries still resume once.
pub fn pickPosition(path_pos: f64, legacy_pos: f64) f64 {
    return if (path_pos > 0) path_pos else legacy_pos;
}

/// Display name for a history entry: local-path names collapse to their
/// basename ("/Users/x/Movies/Foo.mkv" → "Foo.mkv"); everything else as-is.
pub fn displayName(name: []const u8) []const u8 {
    if (name.len == 0 or name[0] != '/') return name;
    const idx = std.mem.lastIndexOfScalar(u8, name, '/') orelse return name;
    if (idx + 1 >= name.len) return name; // trailing slash — keep as-is
    return name[idx + 1 ..];
}

/// A persistence-safe media target. `identity` is stable enough to key resume
/// progress; `reopen` is non-empty only when saving it cannot retain credentials
/// or an expiring signature. Both slices point at `input` or `buf`.
pub const PersistedTarget = struct {
    identity: []const u8 = "",
    reopen: []const u8 = "",
};

/// Strip secrets from targets before they cross a persistence/export boundary.
/// Local files and query-free public URLs remain reopenable. Generic HTTP query
/// strings, URL userinfo, fragments and non-HTTP query data are never stored.
/// YouTube video IDs are the narrow exception: they are canonical public media
/// identity, not authorization material.
pub fn persistedTarget(input: []const u8, buf: []u8) PersistedTarget {
    if (input.len == 0) return .{};
    if (classifyLink(input) != .remote) return .{ .identity = input, .reopen = input };

    if (startsWithIgnoreCase(input, "http://") or startsWithIgnoreCase(input, "https://")) {
        if (canonicalYoutube(input, buf)) |safe|
            return .{ .identity = safe, .reopen = safe };
        return safeHttpTarget(input, buf);
    }
    if (startsWithIgnoreCase(input, "magnet:")) return safeMagnetTarget(input, buf);
    if (std.mem.indexOf(u8, input, "://") != null) return safeHttpTarget(input, buf);

    if (std.mem.indexOfScalar(u8, input, ':')) |colon| {
        const end = colon + 1;
        if (end > buf.len) return .{};
        @memcpy(buf[0..end], input[0..end]);
        return .{ .identity = buf[0..end] };
    }

    const cut = firstOf(input, "?#") orelse input.len;
    if (cut == input.len) return .{ .identity = input, .reopen = input };
    if (cut == 0 or cut > buf.len) return .{};
    @memcpy(buf[0..cut], input[0..cut]);
    return .{ .identity = buf[0..cut] };
}

/// Browser/bookmark history may legitimately need ordinary query strings.
/// Preserve those, but collapse URLs carrying authorization-shaped material to
/// the same safe identity used by playback history.
pub fn credentialSafeIdentity(input: []const u8, buf: []u8) []const u8 {
    if (!hasCredentialMaterial(input)) return input;
    return persistedTarget(input, buf).identity;
}

pub fn hasCredentialMaterial(input: []const u8) bool {
    const scheme_end = std.mem.indexOf(u8, input, "://") orelse return false;
    const auth_start = scheme_end + 3;
    const auth_end = firstOfFrom(input, "/?#", auth_start) orelse input.len;
    if (std.mem.indexOfScalar(u8, input[auth_start..auth_end], '@') != null) return true;
    const q = std.mem.indexOfScalar(u8, input, '?') orelse return false;
    var params = std.mem.splitScalar(u8, input[q + 1 ..], '&');
    while (params.next()) |param| {
        const end = std.mem.indexOfAny(u8, param, "=#") orelse param.len;
        const key = param[0..end];
        const sensitive = [_][]const u8{
            "token", "api_key", "apikey", "access_token", "auth", "authorization",
            "password", "passwd", "signature", "sig", "policy", "key-pair-id",
            "x-plex-token",
        };
        for (sensitive) |candidate| if (std.ascii.eqlIgnoreCase(key, candidate)) return true;
        if (key.len >= 6 and std.ascii.eqlIgnoreCase(key[0..6], "x-amz-")) return true;
    }
    return false;
}

fn safeHttpTarget(input: []const u8, buf: []u8) PersistedTarget {
    const scheme_end = std.mem.indexOf(u8, input, "://") orelse return .{};
    const authority_start = scheme_end + 3;
    const authority_end = firstOfFrom(input, "/?#", authority_start) orelse input.len;
    const cut = firstOfFrom(input, "?#", authority_start) orelse input.len;
    const authority = input[authority_start..authority_end];
    const at = std.mem.lastIndexOfScalar(u8, authority, '@');
    const host_start = if (at) |i| authority_start + i + 1 else authority_start;
    const had_query = std.mem.indexOfScalar(u8, input, '?') != null;
    const had_userinfo = at != null;

    const prefix_len = authority_start;
    const tail_len = cut - host_start;
    if (host_start >= cut or prefix_len + tail_len > buf.len) return .{};
    @memcpy(buf[0..prefix_len], input[0..prefix_len]);
    @memcpy(buf[prefix_len .. prefix_len + tail_len], input[host_start..cut]);
    const safe = buf[0 .. prefix_len + tail_len];
    return .{
        .identity = safe,
        .reopen = if (!had_query and !had_userinfo) safe else "",
    };
}

fn safeMagnetTarget(input: []const u8, buf: []u8) PersistedTarget {
    const query = std.mem.indexOfScalar(u8, input, '?') orelse return .{ .identity = "magnet:", .reopen = "" };
    var params = std.mem.splitScalar(u8, input[query + 1 ..], '&');
    while (params.next()) |param| {
        if (!startsWithIgnoreCase(param, "xt=urn:btih:")) continue;
        const value = param[3..];
        if (value.len <= "urn:btih:".len or value.len > 80) continue;
        for (value["urn:btih:".len..]) |ch| {
            if (!std.ascii.isAlphanumeric(ch)) break;
        } else {
            const prefix = "magnet:?xt=";
            if (prefix.len + value.len > buf.len) return .{};
            @memcpy(buf[0..prefix.len], prefix);
            @memcpy(buf[prefix.len .. prefix.len + value.len], value);
            const safe = buf[0 .. prefix.len + value.len];
            return .{ .identity = safe, .reopen = safe };
        }
    }
    return .{ .identity = "magnet:", .reopen = "" };
}

fn canonicalYoutube(input: []const u8, buf: []u8) ?[]const u8 {
    const scheme_end = std.mem.indexOf(u8, input, "://") orelse return null;
    const auth_start = scheme_end + 3;
    const auth_end = firstOfFrom(input, "/?#", auth_start) orelse input.len;
    var host = input[auth_start..auth_end];
    if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| host = host[at + 1 ..];
    const is_short = std.ascii.eqlIgnoreCase(host, "youtu.be");
    const is_youtube = std.ascii.eqlIgnoreCase(host, "youtube.com") or
        std.ascii.eqlIgnoreCase(host, "www.youtube.com") or
        std.ascii.eqlIgnoreCase(host, "m.youtube.com");
    if (!is_short and !is_youtube) return null;

    var id: []const u8 = "";
    if (is_short) {
        if (auth_end >= input.len or input[auth_end] != '/') return null;
        const end = firstOfFrom(input, "?#/", auth_end + 1) orelse input.len;
        id = input[auth_end + 1 .. end];
    } else {
        const q = std.mem.indexOfScalar(u8, input, '?') orelse return null;
        var params = std.mem.splitScalar(u8, input[q + 1 ..], '&');
        while (params.next()) |param| {
            if (param.len > 2 and std.ascii.eqlIgnoreCase(param[0..2], "v=")) {
                const raw_id = param[2..];
                id = raw_id[0 .. firstOf(raw_id, "#") orelse raw_id.len];
                break;
            }
        }
    }
    if (!validYoutubeId(id)) return null;
    const prefix = "https://www.youtube.com/watch?v=";
    if (prefix.len + id.len > buf.len) return null;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len .. prefix.len + id.len], id);
    return buf[0 .. prefix.len + id.len];
}

fn validYoutubeId(id: []const u8) bool {
    if (id.len != 11) return false;
    for (id) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_')) return false;
    return true;
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    return haystack.len >= prefix.len and std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

fn firstOf(haystack: []const u8, needles: []const u8) ?usize {
    return firstOfFrom(haystack, needles, 0);
}

fn firstOfFrom(haystack: []const u8, needles: []const u8, start: usize) ?usize {
    var i = start;
    while (i < haystack.len) : (i += 1) {
        if (std.mem.indexOfScalar(u8, needles, haystack[i]) != null) return i;
    }
    return null;
}

test "resumeEligible: 30s floor and 95% ceiling" {
    try std.testing.expect(resumeEligible(43.0 * 60.0 + 12.0, 7200));
    try std.testing.expect(!resumeEligible(29.9, 7200)); // too early
    try std.testing.expect(resumeEligible(30.0, 7200)); // floor is inclusive
    try std.testing.expect(!resumeEligible(6900, 7200)); // >= 95% → finished
    try std.testing.expect(resumeEligible(6839, 7200)); // just under 95%
    try std.testing.expect(!resumeEligible(0, 7200));
    try std.testing.expect(!resumeEligible(-5, 7200));
    // Unknown duration: only the floor applies.
    try std.testing.expect(resumeEligible(120, 0));
    try std.testing.expect(!resumeEligible(10, 0));
    // NaN position must never be eligible.
    try std.testing.expect(!resumeEligible(std.math.nan(f64), 7200));
}

test "classifyLink: path vs URL key selection" {
    try std.testing.expectEqual(KeyKind.local_abs, classifyLink("/Users/x/movie.mkv"));
    try std.testing.expectEqual(KeyKind.local_abs, classifyLink("file:///Users/x/movie.mkv"));
    try std.testing.expectEqual(KeyKind.local_rel, classifyLink("clips/movie.mkv"));
    try std.testing.expectEqual(KeyKind.remote, classifyLink("magnet:?xt=urn:btih:abc"));
    try std.testing.expectEqual(KeyKind.remote, classifyLink("https://example.com/v.m3u8"));
    try std.testing.expectEqual(KeyKind.remote, classifyLink("ytdl://dQw4w9WgXcQ"));
    try std.testing.expectEqual(KeyKind.remote, classifyLink("data:text/plain,hello"));
    try std.testing.expectEqual(KeyKind.local_rel, classifyLink("C:\\Media\\movie.mkv"));
    try std.testing.expectEqual(KeyKind.remote, classifyLink(""));
}

test "localFsPath strips file:// and passes bare absolute paths" {
    try std.testing.expectEqualStrings("/a/b.mkv", localFsPath("/a/b.mkv").?);
    try std.testing.expectEqualStrings("/a/b.mkv", localFsPath("file:///a/b.mkv").?);
    try std.testing.expect(localFsPath("https://x/y.mp4") == null);
    try std.testing.expect(localFsPath("magnet:?xt=abc") == null);
    try std.testing.expect(localFsPath("") == null);
    try std.testing.expect(localFsPath("file://") == null);
}

test "displayName: basename for local paths, untouched otherwise" {
    try std.testing.expectEqualStrings("Foo.mkv", displayName("/Users/x/Movies/Foo.mkv"));
    try std.testing.expectEqualStrings("Show S01E02", displayName("Show S01E02"));
    try std.testing.expectEqualStrings("https://x/y.mp4", displayName("https://x/y.mp4"));
    try std.testing.expectEqualStrings("/ends/with/", displayName("/ends/with/"));
    try std.testing.expectEqualStrings("", displayName(""));
}

test "pickPosition: path key wins, legacy name key resumes old entries" {
    try std.testing.expectEqual(@as(f64, 123.5), pickPosition(123.5, 42.0));
    try std.testing.expectEqual(@as(f64, 42.0), pickPosition(0, 42.0));
    try std.testing.expectEqual(@as(f64, 0), pickPosition(0, 0));
}

test "persistedTarget keeps safe targets and strips signed HTTP secrets" {
    var buf: [512]u8 = undefined;
    var got = persistedTarget("C:\\Media\\movie.mkv", &buf);
    try std.testing.expectEqualStrings("C:\\Media\\movie.mkv", got.identity);
    try std.testing.expectEqualStrings(got.identity, got.reopen);

    got = persistedTarget("https://user:pass@media.test/video.m3u8?token=secret#frag", &buf);
    try std.testing.expectEqualStrings("https://media.test/video.m3u8", got.identity);
    try std.testing.expectEqualStrings("", got.reopen);

    got = persistedTarget("https://media.test/public.mp4#chapter", &buf);
    try std.testing.expectEqualStrings("https://media.test/public.mp4", got.identity);
    try std.testing.expectEqualStrings(got.identity, got.reopen);
}

test "persistedTarget canonicalizes public YouTube identity" {
    var buf: [128]u8 = undefined;
    const expected = "https://www.youtube.com/watch?v=HHUQvEWQLfI";
    var got = persistedTarget("https://youtube.com/watch?list=private-ish&v=HHUQvEWQLfI&t=30", &buf);
    try std.testing.expectEqualStrings(expected, got.identity);
    try std.testing.expectEqualStrings(expected, got.reopen);
    got = persistedTarget("https://youtu.be/HHUQvEWQLfI?si=tracking", &buf);
    try std.testing.expectEqualStrings(expected, got.identity);
    try std.testing.expectEqualStrings(expected, got.reopen);
}

test "persistedTarget retains only magnet content identity" {
    var buf: [256]u8 = undefined;
    const got = persistedTarget("magnet:?xt=urn:btih:ABCDEF0123456789&tr=https://tracker.test/a?passkey=secret", &buf);
    try std.testing.expectEqualStrings("magnet:?xt=urn:btih:ABCDEF0123456789", got.identity);
    try std.testing.expectEqualStrings(got.identity, got.reopen);
}

test "persistedTarget does not retain opaque URI payloads" {
    var buf: [128]u8 = undefined;
    const got = persistedTarget("data:text/plain,private payload", &buf);
    try std.testing.expectEqualStrings("data:", got.identity);
    try std.testing.expectEqualStrings("", got.reopen);
}

test "credentialSafeIdentity preserves normal browser queries but strips auth" {
    var buf: [256]u8 = undefined;
    const search = "https://example.test/search?q=opal&page=2";
    try std.testing.expectEqualStrings(search, credentialSafeIdentity(search, &buf));
    try std.testing.expect(hasCredentialMaterial("https://user:pass@example.test/a"));
    try std.testing.expect(hasCredentialMaterial("https://example.test/a?X-Plex-Token=secret"));
    try std.testing.expectEqualStrings(
        "https://example.test/a",
        credentialSafeIdentity("https://example.test/a?X-Plex-Token=secret", &buf),
    );
}
