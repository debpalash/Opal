//! Pure parsing for the `lists` anime source plugin — no app-state imports, so
//! the logic ships tested (see build.zig test step).
//!
//! Source: the debpalash/lists repo (AniList ↔ MAL ↔ AniDB id mappings). The
//! plugin supplies only a `base` URL; the connector in services/anime.zig fetches
//! `<base>/anime-airing.json` and routes the bytes through `parseAiring` here.
//!
//! Real schema (one element of the top-level array, verbatim from the repo):
//!
//!   {
//!     "idAL": 21, "idAniDB": 69, "idMal": 21,
//!     "titles": { "romaji": "ONE PIECE", "english": "ONE PIECE", "native": "ONE PIECE" },
//!     "type": "TV",
//!     "cover": "https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx21-ELSYx3yMPcKM.jpg",
//!     "nsfw": false,
//!     "nextEpisode": { "episodeNumber": 1170, "date": 1784470560 }
//!   }
//!
//! Every nullable field in that shape really is null somewhere in the live data
//! (316 entries at time of writing): `idMal` null ×21, `idAniDB` null ×190,
//! `titles.english` null ×192, `nextEpisode` null ×187, `nsfw` true ×102. The
//! tests below feed those exact cases.

const std = @import("std");

/// One airing entry, mapped onto the fields state.app.anime.results[] carries.
/// Fixed-size buffers (CLAUDE.md) sized from the live data: covers max 87 bytes,
/// titles max 96 bytes, MAL ids max 5 digits.
pub const Item = struct {
    /// MAL id — the anime index's primary key (episode lists, watch tracking and
    /// Continue-Watching all key on it). Entries without one are DROPPED.
    mal_id: [16]u8 = std.mem.zeroes([16]u8),
    mal_id_len: usize = 0,
    title: [128]u8 = std.mem.zeroes([128]u8),
    title_len: usize = 0,
    poster_url: [128]u8 = std.mem.zeroes([128]u8),
    poster_url_len: usize = 0,
    /// Episodes aired so far (see episodesAired).
    episodes: u16 = 0,
    /// Next episode number, 0 when the source doesn't know one.
    next_ep: u16 = 0,
    /// Unix seconds the next episode airs, 0 when unknown. Sort key.
    next_ep_at: i64 = 0,
    /// Pre-rendered airtime badge ("Ep 1170 · Jul 19"), sized for the existing
    /// state.app.anime.broadcast[N][40] parallel array the Calendar cards use.
    badge: [40]u8 = std.mem.zeroes([40]u8),
    badge_len: usize = 0,
};

/// What the Jikan path already uses when an anime's episode count is unknown
/// (services/anime.zig parseJikanDataEx). Reused here so a lists card behaves
/// identically: loadEpisodes() pre-fills this many numbered slots before the
/// real episode list arrives from Jikan.
pub const UNKNOWN_EPISODES: u16 = 100;

/// Episodes aired so far, derived from the *next* episode number.
///
/// `next_ep == 0` means the source carries no `nextEpisode` object (a finished
/// or indefinitely-scheduled title) → unknown → the same 100 the Jikan parser
/// falls back to. `next_ep == 1` is a premiere: zero episodes have aired, and
/// that is a real answer, not an unknown.
pub fn episodesAired(next_ep: u16) u16 {
    if (next_ep == 0) return UNKNOWN_EPISODES;
    return next_ep - 1;
}

/// english → romaji → native, first non-empty. AniList leaves `english` null for
/// 192 of the 316 live entries, so the fallback chain is the common path.
pub fn pickTitle(english: []const u8, romaji: []const u8, native: []const u8) []const u8 {
    if (english.len > 0) return english;
    if (romaji.len > 0) return romaji;
    return native;
}

const MONTHS = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// Render the airtime badge for a card: `Ep 1170 · Jul 19` (UTC).
///
/// Returns 0 (no badge) when there is no scheduled next episode. Pure date math
/// via std.time.epoch — no clock read, so it's testable and Zig-0.16 safe (the
/// banned call is std.time.timestamp(), not the epoch calendar helpers).
pub fn fmtBadge(next_ep: u16, at: i64, out: []u8) usize {
    if (next_ep == 0 or at <= 0) return 0;
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(at) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const mi = md.month.numeric(); // 1-12
    if (mi < 1 or mi > 12) return 0;
    const s = std.fmt.bufPrint(out, "Ep {d} \u{00B7} {s} {d}", .{
        next_ep,
        MONTHS[mi - 1],
        @as(u16, md.day_index) + 1,
    }) catch return 0;
    return s.len;
}

/// Sort key: soonest-airing first, then everything with no schedule, each group
/// keeping the source order (the repo is ordered by AniList id, which is stable).
fn sortsBefore(_: void, a: Item, b: Item) bool {
    const a_sched = a.next_ep_at > 0;
    const b_sched = b.next_ep_at > 0;
    if (a_sched != b_sched) return a_sched;
    if (!a_sched) return false; // both unscheduled — keep source order
    return a.next_ep_at < b.next_ep_at;
}

fn strOf(v: ?std.json.Value) []const u8 {
    const val = v orelse return "";
    return switch (val) {
        .string => |s| s,
        else => "", // JSON null (or anything else) → absent
    };
}

fn intOf(v: ?std.json.Value) i64 {
    const val = v orelse return 0;
    return switch (val) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}

fn copyInto(dst: []u8, dst_len: *usize, src: []const u8) void {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    dst_len.* = n;
}

/// Parse `anime-airing.json` into `out`, soonest-airing first.
///
/// Drops entries that can't drive the anime index:
///   • no `idMal`      — nothing downstream (episodes, watch tracking, Continue)
///                       can key on the row.
///   • no title        — a blank card.
///   • no `cover`      — a posterless card.
///   • `nsfw: true` when `nsfw_filter` is on (Settings › Behavior), matching the
///     `sfw=true` the Jikan path already asks for.
///
/// ALL candidates are collected and sorted before the `out.len` cut, so the grid
/// gets the 100 soonest-airing shows rather than the 100 lowest AniList ids.
/// Returns the number of items written. `allocator` is used only for the
/// transient parse tree + candidate list; nothing is retained.
pub fn parseAiring(
    allocator: std.mem.Allocator,
    json: []const u8,
    nsfw_filter: bool,
    out: []Item,
) usize {
    if (out.len == 0) return 0;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return 0;
    defer parsed.deinit();
    if (parsed.value != .array) return 0;

    var cands: std.ArrayList(Item) = .empty;
    defer cands.deinit(allocator);

    for (parsed.value.array.items) |entry| {
        if (entry != .object) continue;
        const obj = entry.object;

        // idMal — required.
        const id_mal = intOf(obj.get("idMal"));
        if (id_mal <= 0) continue;

        // nsfw — the field is a bool in the live data; treat anything else as false.
        if (nsfw_filter) {
            if (obj.get("nsfw")) |n| {
                if (n == .bool and n.bool) continue;
            }
        }

        var title: []const u8 = "";
        if (obj.get("titles")) |t| {
            if (t == .object) {
                title = pickTitle(
                    strOf(t.object.get("english")),
                    strOf(t.object.get("romaji")),
                    strOf(t.object.get("native")),
                );
            }
        }
        if (title.len == 0) continue;

        const cover = strOf(obj.get("cover"));
        if (cover.len == 0) continue;

        var it: Item = .{};
        copyInto(&it.title, &it.title_len, title);
        copyInto(&it.poster_url, &it.poster_url_len, cover);

        var id_buf: [16]u8 = undefined;
        const id_s = std.fmt.bufPrint(&id_buf, "{d}", .{id_mal}) catch continue;
        copyInto(&it.mal_id, &it.mal_id_len, id_s);

        if (obj.get("nextEpisode")) |ne| {
            if (ne == .object) {
                const n = intOf(ne.object.get("episodeNumber"));
                if (n > 0 and n <= std.math.maxInt(u16)) it.next_ep = @intCast(n);
                it.next_ep_at = intOf(ne.object.get("date"));
            }
        }
        it.episodes = episodesAired(it.next_ep);
        it.badge_len = fmtBadge(it.next_ep, it.next_ep_at, &it.badge);

        cands.append(allocator, it) catch break;
    }

    std.sort.insertion(Item, cands.items, {}, sortsBefore);

    const n = @min(cands.items.len, out.len);
    @memcpy(out[0..n], cands.items[0..n]);
    return n;
}

// ══════════════════════════════════════════════════════════
// Tests — fed by a verbatim snippet of the live schema.
// ══════════════════════════════════════════════════════════

/// Real bytes from https://raw.githubusercontent.com/debpalash/lists/main/anime-airing.json
/// (trimmed to 5 entries, otherwise untouched). Covers: english title present,
/// english null → romaji fallback, nextEpisode null, idMal null, nsfw true.
const SAMPLE =
    \\[{"idAL":21,"idAniDB":69,"idMal":21,"titles":{"romaji":"ONE PIECE","english":"ONE PIECE","native":"ONE PIECE"},"type":"TV","cover":"https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx21-ELSYx3yMPcKM.jpg","nsfw":false,"nextEpisode":{"episodeNumber":1170,"date":1784470560}},
    \\{"idAL":235,"idAniDB":266,"idMal":235,"titles":{"romaji":"Meitantei Conan","english":"Detective Conan","native":"名探偵コナン"},"type":"TV","cover":"https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx235-MyYT7K3chBdO.jpg","nsfw":false,"nextEpisode":{"episodeNumber":1207,"date":1784365200}},
    \\{"idAL":1199,"idAniDB":3626,"idMal":1199,"titles":{"romaji":"Nintama Rantarou","english":null,"native":"忍たま乱太郎"},"type":"TV","cover":"https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx1199-qguxpAkhdzap.png","nsfw":false,"nextEpisode":null},
    \\{"idAL":127977,"idAniDB":null,"idMal":null,"titles":{"romaji":"Anime Kaisha de Hanasu Koto ka yo","english":null,"native":"アニメ会社で話すことかよ"},"type":"ONA","cover":"https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx127977-7Hg0sELK1kAW.png","nsfw":false,"nextEpisode":null},
    \\{"idAL":9999,"idAniDB":1,"idMal":9999,"titles":{"romaji":"Ecchi Show","english":"Ecchi Show","native":"えっち"},"type":"OVA","cover":"https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx9999-x.jpg","nsfw":true,"nextEpisode":{"episodeNumber":3,"date":1784300000}}]
;

test "parseAiring maps the real schema and sorts soonest-airing first" {
    var out: [10]Item = undefined;
    const n = parseAiring(std.testing.allocator, SAMPLE, false, &out);

    // 5 entries in, 4 out: the idMal:null row is dropped (nothing downstream can
    // key on it). nsfw is kept — the filter is off.
    try std.testing.expectEqual(@as(usize, 4), n);

    // Sorted by next-airing: Ecchi (1784300000) < Conan (1784365200) < One Piece
    // (1784470560) < Nintama (no schedule → last).
    try std.testing.expectEqualStrings("9999", out[0].mal_id[0..out[0].mal_id_len]);
    try std.testing.expectEqualStrings("235", out[1].mal_id[0..out[1].mal_id_len]);
    try std.testing.expectEqualStrings("21", out[2].mal_id[0..out[2].mal_id_len]);
    try std.testing.expectEqualStrings("1199", out[3].mal_id[0..out[3].mal_id_len]);
    try std.testing.expectEqual(@as(i64, 0), out[3].next_ep_at);

    // english present → english; english null → romaji.
    try std.testing.expectEqualStrings("Detective Conan", out[1].title[0..out[1].title_len]);
    try std.testing.expectEqualStrings("Nintama Rantarou", out[3].title[0..out[3].title_len]);

    // cover → poster_url, verbatim (no JSON-escaped slashes in this source).
    try std.testing.expectEqualStrings(
        "https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx21-ELSYx3yMPcKM.jpg",
        out[2].poster_url[0..out[2].poster_url_len],
    );

    // nextEpisode 1170 → 1169 aired; nextEpisode null → unknown → Jikan's 100.
    try std.testing.expectEqual(@as(u16, 1170), out[2].next_ep);
    try std.testing.expectEqual(@as(u16, 1169), out[2].episodes);
    try std.testing.expectEqual(@as(u16, 0), out[3].next_ep);
    try std.testing.expectEqual(UNKNOWN_EPISODES, out[3].episodes);

    // Badge for the card meta row; unscheduled rows get none.
    try std.testing.expectEqualStrings("Ep 1170 \u{00B7} Jul 19", out[2].badge[0..out[2].badge_len]);
    try std.testing.expectEqual(@as(usize, 0), out[3].badge_len);
}

test "parseAiring honors the NSFW filter" {
    var out: [10]Item = undefined;
    const n = parseAiring(std.testing.allocator, SAMPLE, true, &out);
    // The nsfw:true entry (9999) is gone; the idMal:null one is still dropped.
    try std.testing.expectEqual(@as(usize, 3), n);
    for (out[0..n]) |it| {
        try std.testing.expect(!std.mem.eql(u8, "9999", it.mal_id[0..it.mal_id_len]));
    }
    // Soonest-first still holds among what's left.
    try std.testing.expectEqualStrings("235", out[0].mal_id[0..out[0].mal_id_len]);
}

test "parseAiring clamps to out.len AFTER sorting (soonest wins, not lowest id)" {
    var out: [1]Item = undefined;
    const n = parseAiring(std.testing.allocator, SAMPLE, false, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    // Lowest AniList id in the file is 21 (One Piece); the soonest airing is 9999.
    // Sorting before the cut is the whole point — a pre-cut would yield "21".
    try std.testing.expectEqualStrings("9999", out[0].mal_id[0..out[0].mal_id_len]);
}

test "parseAiring survives junk, empty and non-array payloads" {
    var out: [4]Item = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseAiring(std.testing.allocator, "", false, &out));
    try std.testing.expectEqual(@as(usize, 0), parseAiring(std.testing.allocator, "not json", false, &out));
    try std.testing.expectEqual(@as(usize, 0), parseAiring(std.testing.allocator, "[]", false, &out));
    // A 404 page from the raw host is a JSON object, not an array.
    try std.testing.expectEqual(@as(usize, 0), parseAiring(std.testing.allocator, "{\"message\":\"Not Found\"}", false, &out));
    // Right shape, but every row unusable (no id / no cover / no title).
    try std.testing.expectEqual(@as(usize, 0), parseAiring(
        std.testing.allocator,
        "[{\"idMal\":null},{\"idMal\":7,\"titles\":{\"romaji\":\"X\"}},{\"idMal\":8,\"cover\":\"u\"}]",
        false,
        &out,
    ));
    // out.len == 0 must not write anywhere.
    var empty: [0]Item = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseAiring(std.testing.allocator, SAMPLE, false, &empty));
}

test "pickTitle falls back english → romaji → native" {
    try std.testing.expectEqualStrings("E", pickTitle("E", "R", "N"));
    try std.testing.expectEqualStrings("R", pickTitle("", "R", "N"));
    try std.testing.expectEqualStrings("N", pickTitle("", "", "N"));
    try std.testing.expectEqualStrings("", pickTitle("", "", ""));
}

test "episodesAired: premiere is 0, unknown is Jikan's 100" {
    try std.testing.expectEqual(UNKNOWN_EPISODES, episodesAired(0)); // no nextEpisode
    try std.testing.expectEqual(@as(u16, 0), episodesAired(1)); // premiere — 0 aired
    try std.testing.expectEqual(@as(u16, 11), episodesAired(12));
}

test "fmtBadge renders UTC date, and nothing without a schedule" {
    var buf: [40]u8 = undefined;
    try std.testing.expectEqualStrings("Ep 1207 \u{00B7} Jul 18", buf[0..fmtBadge(1207, 1784365200, &buf)]);
    try std.testing.expectEqualStrings("Ep 1 \u{00B7} Jan 1", buf[0..fmtBadge(1, 0 + 1, &buf)]);
    try std.testing.expectEqual(@as(usize, 0), fmtBadge(0, 1784365200, &buf)); // no episode number
    try std.testing.expectEqual(@as(usize, 0), fmtBadge(5, 0, &buf)); // no date
    // Must fit the state.app.anime.broadcast[N] slot it is copied into.
    try std.testing.expect(fmtBadge(65535, 1784365200, &buf) <= 40);
}
