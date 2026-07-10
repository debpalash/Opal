const std = @import("std");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const io_global = @import("../core/io_global.zig");
const anilist_pure = @import("anilist_pure.zig");

// ══════════════════════════════════════════════════════════
// AniList Sync — anime watch progress via GraphQL API
// ══════════════════════════════════════════════════════════

const ANILIST_API = "https://graphql.anilist.co";

pub var access_token: [256]u8 = std.mem.zeroes([256]u8);
pub var access_token_len: usize = 0;
pub var enabled: bool = false;

/// Update watch progress for an anime on AniList.
/// `media_id` is the AniList media ID, `episode` is the episode number.
pub fn updateProgress(media_id: i64, episode: i32) void {
    if (!enabled or access_token_len == 0 or media_id <= 0) return;

    if (std.Thread.spawn(.{}, struct {
        fn worker(mid: i64, ep: i32) void {
            const alloc = @import("../core/alloc.zig").allocator;

            var gql_buf: [512]u8 = undefined;
            const gql = std.fmt.bufPrintZ(&gql_buf,
                \\{{"query":"mutation {{ SaveMediaListEntry(mediaId: {d}, progress: {d}, status: CURRENT) {{ id progress }} }}"}}
            , .{ mid, ep }) catch return;

            var auth_buf: [300]u8 = undefined;
            const auth = std.fmt.bufPrintZ(&auth_buf, "Authorization: Bearer {s}", .{access_token[0..access_token_len]}) catch return;

            var child = io_global.Child.init(&.{
                "curl", "-s", "-X", "POST", ANILIST_API,
                "-H", "Content-Type: application/json",
                "-H", "Accept: application/json",
                "-H", auth,
                "-d", gql,
            }, alloc);
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Ignore;
            child.spawn() catch {
                logs.pushLog("warn", "anilist", "Failed to update progress", false);
                return;
            };
            const result = child.wait() catch return;
            if (result.exited == 0) {
                logs.pushLog("info", "anilist", "AniList progress updated", false);
            }
        }
    }.worker, .{ media_id, episode })) |t| t.detach() else |_| {}
}

/// Fetch AniList metadata for a batch of MAL ids in ONE keyless GraphQL query.
/// `ids_csv` is a comma-separated list of MAL ids (e.g. "1535,9999"). Writes the
/// raw JSON response into `out` and returns the byte count (0 on any failure).
/// The caller parses `out` with `anilist_pure.Iter`.
///
/// SFW-gated: when `sfw` is true the `media(...)` selector carries
/// `isAdult: false`, so AniList itself drops adult entries — the same intent as
/// the anime tab's Jikan `sfw=true` param (see anime_pure.sfwSuffix). Runs on
/// the caller's (worker) thread; does no allocation of its own beyond curl.
pub fn fetchMetaByMalIds(ids_csv: []const u8, sfw: bool, out: []u8) usize {
    if (ids_csv.len == 0) return 0;
    const alloc = @import("../core/alloc.zig").allocator;

    var gql_buf: [2048]u8 = undefined;
    const gql = std.fmt.bufPrintZ(&gql_buf,
        \\{{"query":"query {{ Page(perPage: 50) {{ media(idMal_in: [{s}], type: ANIME{s}) {{ id idMal averageScore title {{ romaji english }} coverImage {{ large }} episodes seasonYear description(asHtml: false) }} }} }}"}}
    , .{ ids_csv, anilist_pure.adultGate(sfw) }) catch return 0;

    var child = io_global.Child.init(&.{
        "curl",   "-s",                          "-X",                   "POST", ANILIST_API,
        "-H",     "Content-Type: application/json", "-H",                "Accept: application/json",
        "-d",     gql,
    }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return 0;

    const n = if (child.stdout) |*s| io_global.readAll(s, out) catch 0 else 0;
    _ = child.wait() catch {};
    return n;
}

/// Search AniList for an anime by title, return media ID.
pub fn searchAnime(title: []const u8, out_id: *i64) void {
    if (title.len == 0) return;
    const alloc = @import("../core/alloc.zig").allocator;

    var esc: [256]u8 = undefined;
    var ei: usize = 0;
    for (title) |ch| {
        if (ei + 2 >= esc.len) break;
        if (ch == '"') { esc[ei] = '\\'; ei += 1; esc[ei] = '"'; ei += 1; }
        else { esc[ei] = ch; ei += 1; }
    }

    var gql_buf: [512]u8 = undefined;
    const gql = std.fmt.bufPrintZ(&gql_buf,
        \\{{"query":"{{ Media(search: \"{s}\", type: ANIME) {{ id title {{ romaji english }} }} }}"}}
    , .{esc[0..ei]}) catch return;

    var child = io_global.Child.init(&.{
        "curl", "-s", "-X", "POST", ANILIST_API,
        "-H", "Content-Type: application/json",
        "-H", "Accept: application/json",
        "-d", gql,
    }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return;

    var out: [4096]u8 = undefined;
    const n = if (child.stdout) |*s| io_global.readAll(s, &out) catch 0 else 0;
    _ = child.wait() catch {};

    if (n < 10) return;
    // Extract "id":NNNN from response
    if (std.mem.indexOf(u8, out[0..n], "\"id\":")) |idx| {
        const start = idx + 5;
        var end = start;
        while (end < n and out[end] >= '0' and out[end] <= '9') end += 1;
        if (end > start) {
            out_id.* = std.fmt.parseInt(i64, out[start..end], 10) catch 0;
        }
    }
}
