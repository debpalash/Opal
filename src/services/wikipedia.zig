const std = @import("std");
const dvui = @import("dvui");
const http = @import("../core/http.zig");
const pure = @import("wikipedia_pure.zig");

// ══════════════════════════════════════════════════════════
// Trivia blurb for the torrent-buffering loading screen.
//
// IMDB has no public API for its trivia section, so Wikipedia's REST
// "page summary" endpoint (lead-paragraph extract) is the closest free
// equivalent. A bare title often collides with an unrelated Wikipedia
// page (e.g. "Silo" the storage structure vs. the TV series), so we try
// a disambiguated title first, then fall back to the bare title.
// ══════════════════════════════════════════════════════════

/// Fetch a short trivia blurb for `title` and write it into `out_buf`.
/// Spawns a detached worker; `fetching_flag` guards against re-entry and is
/// cleared when the worker finishes (success or failure). On any failure
/// `out_len` is simply left at 0 — callers already have a TMDB overview to
/// show as a fallback while (or if) this never lands.
pub fn fetchTrivia(title: []const u8, is_tv: bool, out_buf: *[400]u8, out_len: *usize, fetching_flag: *bool) void {
    if (title.len == 0 or fetching_flag.*) return;
    fetching_flag.* = true;

    const Ctx = struct {
        title: [128]u8,
        title_len: usize,
        is_tv: bool,
        out_buf: *[400]u8,
        out_len: *usize,
        fetching_flag: *bool,
    };
    var ctx: Ctx = undefined;
    ctx.title_len = @min(title.len, ctx.title.len);
    @memcpy(ctx.title[0..ctx.title_len], title[0..ctx.title_len]);
    ctx.is_tv = is_tv;
    ctx.out_buf = out_buf;
    ctx.out_len = out_len;
    ctx.fetching_flag = fetching_flag;

    if (std.Thread.spawn(.{}, struct {
        fn worker(c: Ctx) void {
            defer c.fetching_flag.* = false;
            const t = c.title[0..c.title_len];

            var resp_buf: [8192]u8 = undefined;
            if (fetchSummary(t, c.is_tv, &resp_buf)) |extract| {
                const n = @min(extract.len, c.out_buf.len);
                @memcpy(c.out_buf[0..n], extract[0..n]);
                c.out_len.* = n;
                dvui.refresh(null, @src(), null);
            }
        }
    }.worker, .{ctx})) |th| {
        th.detach();
    } else |_| {
        fetching_flag.* = false;
    }
}

fn fetchSummary(title: []const u8, is_tv: bool, resp_buf: []u8) ?[]const u8 {
    var disamb_buf: [160]u8 = undefined;
    const disamb = pure.disambiguatedTitle(title, is_tv, &disamb_buf);

    if (fetchOne(disamb, resp_buf)) |extract| return extract;
    return fetchOne(title, resp_buf);
}

fn fetchOne(title: []const u8, resp_buf: []u8) ?[]const u8 {
    var underscored: [160]u8 = undefined;
    const under = pure.spacesToUnderscores(title, &underscored);

    var enc_buf: [480]u8 = undefined;
    const encoded = http.urlEncode(under, &enc_buf);

    var url_buf: [560]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://en.wikipedia.org/api/rest_v1/page/summary/{s}", .{encoded}) catch return null;

    const body = http.fetch(url, resp_buf, .{
        .timeout_secs = 6,
        .max_response = resp_buf.len,
        .accept = "application/json",
    }) orelse return null;

    return pure.extractSummary(body);
}
