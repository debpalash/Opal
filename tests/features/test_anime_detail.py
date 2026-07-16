"""Browse — anime SEASONS/EPISODES detail view brought to TV-show parity.
See tests/features/harness.py for the shared @test decorator, helpers, and
run_all()."""
from .harness import *  # noqa: F401,F403


@test("Anime detail view parity", "Browse")
def test_anime_detail_parity():
    # The anime detail view was upgraded to match renderTvDetail:
    #   1. AnimeResult gained type/year/airing metadata (+ widened poster_url).
    #   2. parseJikanDataEx extracts them via the tested pure helper
    #      anime_pure.parseJikanMeta (tested logic == shipped logic).
    #   3. serializeAnime/deserializeAnime persist the new fields (same order).
    #   4. renderContent draws a rich header (poster + title + meta + synopsis)
    #      and horizontal episode rows (numbered tile + info column).
    st = _src("src/core/state.zig")
    pure = _src("src/services/anime_pure.zig")
    anime = _src("src/services/anime.zig")

    # AnimeResult struct slice (fields live between the struct header and the
    # next pub const) — keeps the [256] / atype checks scoped to AnimeResult.
    ar = _between(st, "pub const AnimeResult = struct {", "pub const DramaResult")

    checks = {
        # ── State: new metadata fields + widened poster buffers ──
        "AnimeResult has atype": "atype: [16]u8" in ar and "atype_len: usize" in ar,
        "AnimeResult has year": "year: u16" in ar,
        "AnimeResult has airing": "airing: bool" in ar,
        "AnimeResult poster_url [256]": "poster_url: [256]u8" in ar,
        "ContinueItem poster_url [256]": st.count("poster_url: [256]u8") >= 2,

        # ── Pure helper: type/year/airing extraction (routed + tested) ──
        "pure parseJikanMeta": "pub fn parseJikanMeta" in pure,
        "pure JikanMeta struct": "pub const JikanMeta" in pure
            and "atype" in pure and "year" in pure and "airing" in pure,
        "pure has meta tests": pure.count('test "parseJikanMeta') >= 3,

        # ── parseJikanDataEx routes through the pure helper (no drift) ──
        "parse routes through pure": "anime_pure.parseJikanMeta(obj_slice)" in anime,
        "parse stores atype": "&item.atype, &item.atype_len, meta.atype" in anime,
        "parse stores year": "item.year = meta.year" in anime,
        "parse stores airing": "item.airing = meta.airing" in anime,

        # ── Serialize / deserialize carry the new fields (same order) ──
        "serialize atype/year/airing": "w.blob(it.atype" in anime
            and "w.u16v(it.year)" in anime and "w.boolv(it.airing)" in anime,
        "deserialize atype/year/airing": "&it.atype, &it.atype_len, r.blob()" in anime
            and "it.year = r.u16v()" in anime and "it.airing = r.boolv()" in anime,

        # ── Rich header: poster (reused lazy tex) + title + meta + synopsis ──
        "header reuses lazy poster": "poster.uploadIfReady(&item.poster_pixels, item.poster_w, item.poster_h, &item.poster_tex)" in anime,
        "header meta type/year/eps": '"{s}{d} eps"' in anime,
        "header airing chip": '"Airing"' in anime,
        "header synopsis wrapped": "r.overview[0..@min(r.overview_len, r.overview.len)]" in anime,

        # ── Horizontal episode rows: numbered tile + info column ──
        "episode row horizontal": "horizontal (numbered tile" in anime and "ep_i + 2000" in anime,
        "episode numbered tile": "ep_i + 2100" in anime,
        "episode watched toggle persists": "toggleWatched(sel_idx, ep_num)" in anime,
        "episode title plays": "playEpisode(ep_str)" in anime,
        # Empty + loading states kept.
        "keeps no-episodes state": '"No episodes available"' in anime,
        "keeps loading indicator": '"Loading episode details..."' in anime,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if not missing:
        return "pass", "anime detail view at TV parity: rich header + horizontal episode rows + type/year/airing"
    return "fail", "anime detail parity incomplete: " + ", ".join(missing)
