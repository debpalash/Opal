const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");

pub const alloc = @import("../core/alloc.zig").allocator;

// ══════════════════════════════════════════════════════════
// Genre ID → Name Mapping
// ══════════════════════════════════════════════════════════

const GenreEntry = struct { id: i32, name: []const u8 };
const genre_map = [_]GenreEntry{
    .{ .id = 28, .name = "Action" },                .{ .id = 12, .name = "Adventure" },
    .{ .id = 16, .name = "Animation" },             .{ .id = 35, .name = "Comedy" },
    .{ .id = 80, .name = "Crime" },                 .{ .id = 99, .name = "Documentary" },
    .{ .id = 18, .name = "Drama" },                 .{ .id = 10751, .name = "Family" },
    .{ .id = 14, .name = "Fantasy" },               .{ .id = 36, .name = "History" },
    .{ .id = 27, .name = "Horror" },                .{ .id = 10402, .name = "Music" },
    .{ .id = 9648, .name = "Mystery" },             .{ .id = 10749, .name = "Romance" },
    .{ .id = 878, .name = "Sci-Fi" },               .{ .id = 53, .name = "Thriller" },
    .{ .id = 10752, .name = "War" },                .{ .id = 37, .name = "Western" },
    .{ .id = 10759, .name = "Action & Adventure" }, .{ .id = 10762, .name = "Kids" },
    .{ .id = 10763, .name = "News" },               .{ .id = 10764, .name = "Reality" },
    .{ .id = 10765, .name = "Sci-Fi & Fantasy" },   .{ .id = 10766, .name = "Soap" },
    .{ .id = 10767, .name = "Talk" },               .{ .id = 10768, .name = "War & Politics" },
};

fn genreName(id: i32) ?[]const u8 {
    for (genre_map) |g| {
        if (g.id == id) return g.name;
    }
    return null;
}

// ══════════════════════════════════════════════════════════
// JSON Helpers
// ══════════════════════════════════════════════════════════

pub fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    const ki = std.mem.indexOf(u8, json, key) orelse return null;
    const after = json[ki + key.len ..];
    var i: usize = 0;
    while (i < after.len and (after[i] == ' ' or after[i] == ':')) i += 1;
    if (i >= after.len or after[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < after.len and after[i] != '"') {
        if (after[i] == '\\') i += 1;
        i += 1;
    }
    return after[start..i];
}

pub fn extractJsonInt(json: []const u8, key: []const u8) i32 {
    const ki = std.mem.indexOf(u8, json, key) orelse return 0;
    const after = json[ki + key.len ..];
    var i: usize = 0;
    while (i < after.len and (after[i] == ' ')) i += 1;
    var result: i32 = 0;
    while (i < after.len and after[i] >= '0' and after[i] <= '9') : (i += 1) {
        result = result * 10 + @as(i32, @intCast(after[i] - '0'));
    }
    return result;
}

pub fn extractJsonFloat(json: []const u8, key: []const u8) f32 {
    const ki = std.mem.indexOf(u8, json, key) orelse return 0;
    const after = json[ki + key.len ..];
    var i: usize = 0;
    while (i < after.len and (after[i] == ' ')) i += 1;
    const start = i;
    while (i < after.len and (after[i] == '.' or (after[i] >= '0' and after[i] <= '9'))) i += 1;
    if (i == start) return 0;
    return std.fmt.parseFloat(f32, after[start..i]) catch 0;
}

pub fn formatDate(out_buf: *[16]u8, iso: []const u8) []const u8 {
    if (iso.len < 10) return iso;
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const mm = std.fmt.parseInt(u8, iso[5..7], 10) catch return iso;
    if (mm < 1 or mm > 12) return iso;
    const result = std.fmt.bufPrint(out_buf, "{s} {s}, {s}", .{ months[mm - 1], iso[8..10], iso[0..4] }) catch return iso;
    return result;
}

// ══════════════════════════════════════════════════════════
// Response Parsing
// ══════════════════════════════════════════════════════════

/// Parses into `out`. Worker threads pass a LOCAL list and stage it via
/// tmdb_api's pending swap — never the live `state.app.tmdb.results` that the
/// UI thread iterates mid-frame (that race was the renderCatalogRail
/// out-of-bounds crash).
pub fn parseTmdbResponse(body: []const u8, out: *std.ArrayListUnmanaged(state.TmdbItem)) void {
    if (std.mem.indexOf(u8, body, "\"results\":[") == null) {
        parseAndAddItem(body, out) catch {};
        return;
    }
    // String-aware split (tmdb_pure.splitResultObjects, unit-tested): a '{'/'}'
    // inside a title/overview must not desync the brace counter, else later
    // results get mis-sliced and parseAndAddItem reads the wrong top-level "id"
    // (the "FROM"/"House of the Dragon" TV-detail bug). 64 ≥ a TMDB page (20).
    var objs: [64][]const u8 = undefined;
    const n = @import("tmdb_pure.zig").splitResultObjects(body, &objs);
    for (objs[0..n]) |obj| parseAndAddItem(obj, out) catch {};
}

/// Parse Cinemeta catalog records into the existing catalog-card model. This
/// keeps favorites, watchlists, grid rendering, and poster loading provider
/// agnostic while allowing a zero-key movie/TV feed.
pub fn parseCinemetaResponse(body: []const u8, out: *std.ArrayListUnmanaged(state.TmdbItem)) void {
    var objs: [64][]const u8 = undefined;
    const n = @import("cinemeta_pure.zig").splitMetaObjects(body, &objs);
    for (objs[0..n]) |obj| parseAndAddCinemetaItem(obj, out);
}

fn copyInto(dst: []u8, len: *usize, src: []const u8) void {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    len.* = n;
}

fn parseCinemetaGenres(json: []const u8, item: *state.TmdbItem) void {
    const key = "\"genre\":[";
    const ki = std.mem.indexOf(u8, json, key) orelse return;
    const after = json[ki + key.len ..];
    const end = std.mem.indexOfScalar(u8, after, ']') orelse return;
    var pos: usize = 0;
    var i: usize = 0;
    while (i < end and pos < item.genre_text.len) {
        if (after[i] != '"') {
            i += 1;
            continue;
        }
        i += 1;
        const start = i;
        while (i < end and after[i] != '"') : (i += 1) {}
        if (i <= start) continue;
        if (pos > 0 and pos + 2 <= item.genre_text.len) {
            @memcpy(item.genre_text[pos .. pos + 2], ", ");
            pos += 2;
        }
        const take = @min(i - start, item.genre_text.len - pos);
        @memcpy(item.genre_text[pos .. pos + take], after[start .. start + take]);
        pos += take;
        i += 1;
    }
    item.genre_text_len = pos;
}

fn parseAndAddCinemetaItem(json: []const u8, out: *std.ArrayListUnmanaged(state.TmdbItem)) void {
    var item = state.TmdbItem{};
    const imdb_id = extractJsonString(json, "\"imdb_id\":") orelse
        extractJsonString(json, "\"id\":") orelse "";
    item.id = extractJsonInt(json, "\"moviedb_id\":");
    if (item.id == 0 and imdb_id.len > 0) item.id = @import("cinemeta_pure.zig").stableId(imdb_id);

    if (extractJsonString(json, "\"name\":")) |name| copyInto(&item.title, &item.title_len, name);
    if (extractJsonString(json, "\"year\":")) |year| copyInto(&item.year, &item.year_len, year);
    if (extractJsonString(json, "\"released\":")) |released| {
        if (item.year_len == 0 and released.len >= 4) copyInto(&item.year, &item.year_len, released[0..4]);
        if (released.len >= 10) {
            var date_buf: [16]u8 = undefined;
            copyInto(&item.release_date, &item.release_date_len, formatDate(&date_buf, released[0..10]));
        }
    }
    if (extractJsonString(json, "\"imdbRating\":")) |rating|
        item.rating = std.fmt.parseFloat(f32, rating) catch 0;
    if (extractJsonString(json, "\"description\":")) |desc| copyInto(&item.overview, &item.overview_len, desc);
    if (extractJsonString(json, "\"type\":")) |kind| {
        if (std.mem.eql(u8, kind, "series"))
            copyInto(&item.media_type, &item.media_type_len, "tv")
        else
            copyInto(&item.media_type, &item.media_type_len, "movie");
    }
    parseCinemetaGenres(json, &item);
    if (extractJsonString(json, "\"poster\":")) |poster| copyInto(&item.poster_path, &item.poster_path_len, poster);
    if (item.title_len > 0 and item.id != 0) out.append(alloc, item) catch {};
}

fn parseAndAddItem(json_obj: []const u8, out: *std.ArrayListUnmanaged(state.TmdbItem)) !void {
    var item = state.TmdbItem{};

    item.id = extractJsonInt(json_obj, "\"id\":");

    if (extractJsonString(json_obj, "\"title\":")) |title| {
        const tlen = @min(title.len, 127);
        @memcpy(item.title[0..tlen], title[0..tlen]);
        item.title_len = tlen;
    } else if (extractJsonString(json_obj, "\"name\":")) |name| {
        const nlen = @min(name.len, 127);
        @memcpy(item.title[0..nlen], name[0..nlen]);
        item.title_len = nlen;
    }

    if (extractJsonString(json_obj, "\"release_date\":")) |date| {
        if (date.len >= 4) {
            @memcpy(item.year[0..4], date[0..4]);
            item.year_len = 4;
        }
        if (date.len >= 10) {
            var date_buf: [16]u8 = undefined;
            const fdate = formatDate(&date_buf, date[0..10]);
            const flen = @min(fdate.len, 15);
            @memcpy(item.release_date[0..flen], fdate[0..flen]);
            item.release_date_len = flen;
        }
    } else if (extractJsonString(json_obj, "\"first_air_date\":")) |date| {
        if (date.len >= 4) {
            @memcpy(item.year[0..4], date[0..4]);
            item.year_len = 4;
        }
        if (date.len >= 10) {
            var date_buf2: [16]u8 = undefined;
            const fdate = formatDate(&date_buf2, date[0..10]);
            const flen = @min(fdate.len, 15);
            @memcpy(item.release_date[0..flen], fdate[0..flen]);
            item.release_date_len = flen;
        }
    }

    item.rating = extractJsonFloat(json_obj, "\"vote_average\":");

    if (extractJsonString(json_obj, "\"overview\":")) |ov| {
        const olen = @min(ov.len, 511);
        @memcpy(item.overview[0..olen], ov[0..olen]);
        item.overview_len = olen;
    }

    if (extractJsonString(json_obj, "\"media_type\":")) |mt| {
        const mlen = @min(mt.len, 7);
        @memcpy(item.media_type[0..mlen], mt[0..mlen]);
        item.media_type_len = mlen;
    } else {
        if (extractJsonString(json_obj, "\"first_air_date\":") != null) {
            @memcpy(item.media_type[0..2], "tv");
            item.media_type_len = 2;
        } else {
            @memcpy(item.media_type[0..5], "movie");
            item.media_type_len = 5;
        }
    }

    parseGenreIds(json_obj, &item);

    if (extractJsonString(json_obj, "\"poster_path\":")) |p| {
        const plen = @min(p.len, 63);
        @memcpy(item.poster_path[0..plen], p[0..plen]);
        item.poster_path_len = plen;
    }

    if (item.title_len > 0) {
        out.append(alloc, item) catch {};
    }
}

fn parseGenreIds(json: []const u8, item: *state.TmdbItem) void {
    const key = "\"genre_ids\":[";
    const ki = std.mem.indexOf(u8, json, key) orelse return;
    const after = json[ki + key.len ..];
    const end = std.mem.indexOfScalar(u8, after, ']') orelse return;
    const arr = after[0..end];

    var genre_buf: [64]u8 = std.mem.zeroes([64]u8);
    var gpos: usize = 0;
    var nums = std.mem.splitScalar(u8, arr, ',');
    var first = true;
    while (nums.next()) |num_str| {
        const trimmed = std.mem.trim(u8, num_str, " ");
        if (trimmed.len == 0) continue;
        const gid = std.fmt.parseInt(i32, trimmed, 10) catch continue;
        if (genreName(gid)) |name| {
            if (!first and gpos + 2 < genre_buf.len) {
                @memcpy(genre_buf[gpos .. gpos + 2], ", ");
                gpos += 2;
            }
            const nlen = @min(name.len, genre_buf.len - gpos);
            if (nlen == 0) break;
            @memcpy(genre_buf[gpos .. gpos + nlen], name[0..nlen]);
            gpos += nlen;
            first = false;
        }
    }
    if (gpos > 0) {
        @memcpy(item.genre_text[0..gpos], genre_buf[0..gpos]);
        item.genre_text_len = gpos;
    }
}
