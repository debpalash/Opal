"""Unified library read-model (library_items) — cross-vertical Continue/Favorites.

Every vertical writes progress/favorites into ONE denormalized table so the home
surface + a future device sync read one place instead of ~7 schemas. Pure logic
(percent/continue bands) is tested; the store wires the DB; watch_history mirrors
into it.

See tests/features/harness.py for the shared @test decorator."""
from .harness import *  # noqa: F401,F403


@test("Unified library read-model", "Storage")
def test_library():
    pure = _src("src/services/library_pure.zig")
    store = _src("src/services/library_store.zig")
    dbz = _src("src/core/db.zig")
    wh = _src("src/player/watch_history.zig")
    build = _src("build.zig")

    checks = {
        "table present": "CREATE TABLE IF NOT EXISTS library_items" in dbz,
        "table index": "idx_library_updated" in dbz,
        "pure record": "pub const LibraryItem = struct" in pure,
        "pure percent/continue": "pub fn percentOf" in pure and "pub fn isContinue" in pure,
        "store upsert progress": "pub fn upsertProgress" in store,
        "store set favorite": "pub fn setFavorite" in store,
        "store loaders": "pub fn loadContinue" in store and "pub fn loadFavorites" in store,
        # Progress upsert uses ON CONFLICT (so it preserves is_favorite, not REPLACE).
        "upsert preserves via ON CONFLICT": "ON CONFLICT(kind,item_id) DO UPDATE" in store,
        # watch_history mirrors playback progress into the read-model.
        "watch_history mirrors": "library_store" in wh and "upsertProgress(" in wh,
        "pure test registered": 'b.path("src/services/library_pure.zig")' in build,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "library read-model incomplete: " + ", ".join(missing)
    return "pass", "library_items read-model: table + pure + store (continue/favorites) + watch_history mirror"


@test("Library producers span the verticals", "Storage")
def test_library_producers():
    """Each vertical mirrors its OWN progress/favorite store into library_items,
    and home.zig can actually reopen every kind it writes. A row nothing can
    resume is worse than no row, so producer + dispatch are checked together."""
    home = _src("src/ui/home.zig")
    novels = _src("src/services/novels.zig")
    novels_pure = _src("src/services/novels_pure.zig")
    anime = _src("src/services/anime.zig")
    abs_ = _src("src/services/audiobookshelf.zig")
    iptv = _src("src/services/iptv_store.zig")
    comics = _src("src/services/comics.zig")
    podcasts = _src("src/services/podcasts.zig")

    # kind -> (producer source, the call that writes it)
    producers = {
        "iptv": iptv.count('setFavorite("iptv"') > 0,
        "novels": 'upsertProgress(\n        "novels"' in novels or '"novels",' in novels,
        "anime": '"anime",' in anime and "library_store" in anime,
        "audiobook": '"audiobook",' in abs_ and "library_store" in abs_,
        "comics": '"comics",' in comics and "library_store" in comics,
        "podcast": '"podcast",' in podcasts and "library_store" in podcasts,
    }

    checks = {f"producer: {k}": ok for k, ok in producers.items()}
    # Producers must go through library_store, not raw SQL.
    checks["novels via library_store"] = "library_store" in novels
    # Novel deep links are a tested pure format (no ad-hoc string surgery).
    checks["novel deep link pure"] = (
        "pub fn formatDeepLink" in novels_pure and "pub fn parseDeepLink" in novels_pure
    )
    checks["novel deep link routed"] = "pub fn openDeepLink" in novels
    # Anime resumes by MAL id through the existing jump path.
    checks["anime jump path"] = "pub fn jumpToAnime" in anime
    # home.zig's kind dispatch handles every producer kind above.
    for kind in producers:
        checks[f"resume dispatch: {kind}"] = f'"{kind}"' in home
    checks["dispatch calls novel opener"] = "openDeepLink(link)" in home
    checks["dispatch calls anime jump"] = "jumpToAnime(link)" in home
    # Comics + podcasts route through their own tested deep-link openers, not
    # the generic resumePlayback fallback (which would land in the web browser).
    checks["dispatch calls comic opener"] = "services/comics.zig" in home
    checks["dispatch calls podcast opener"] = "services/podcasts.zig" in home

    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "library producers incomplete: " + ", ".join(missing)
    return "pass", "producers wired: watch, iptv, novels, anime, audiobook, comics, podcast"


@test("Watching: items can be removed, without losing progress", "Library")
def test_watching_remove():
    """The Watching page had no way to drop anything from it.

    Its rows come from three different stores, so "remove" is a different call
    per kind — and the important property is that none of them destroys watch
    progress:

      tv     tvSetTracked(id, false)   — tvGetShows filters `tracked <> 0`
      anime  animeRemoveContinue(mal)  — deletes ONLY the continue row
      movie  watch_history.remove(idx) — drops that history entry

    Per-episode watched flags live in their own tables and are deliberately left
    alone, so removing a show and re-adding it later does not silently reset how
    far the user had got. That is the whole reason anime gets its own narrow
    delete instead of clearing its watched table too.
    """
    lib = _src("src/services/tv_library.zig")
    card = _src("src/ui/media_card.zig")
    dbz = _src("src/core/db.zig")

    checks = {
        "card exposes remove": "remove }" in card or "remove," in card.split("pub const Click")[1][:80],
        "remove is opt-in": "removable: bool = false" in card,
        "watching opts in": ".removable = true" in lib,
        "dispatch exists": "fn removeRow(" in lib,
        "tv un-tracks": "db.tvSetTracked(r.tmdb_id, false)" in lib,
        "anime drops continue row": "db.animeRemoveContinue(mal)" in lib,
        "movie drops history entry": "watch_history.zig\").remove(" in lib,
        "anime delete added": "pub fn animeRemoveContinue(" in dbz,
        # Narrow on purpose: only the continue row, never the watched flags.
        "anime delete is narrow": "DELETE FROM anime_continue WHERE mal_id = ?" in dbz,
        "progress preserved deliberately": "watched flags" in dbz or "watched flags" in lib,
        # The snapshot is cached; without invalidating it the card lingers.
        "snapshot invalidated": "library_dirty.store(true, .release)" in lib,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "watching remove incomplete: " + ", ".join(missing)

    # A movie row's hist_idx indexes a live array, so it must be guarded.
    if "if (r.hist_idx < 0) return;" not in lib:
        return "fail", "movie removal does not guard hist_idx < 0"
    return "pass", ("all three kinds removable from Watching; watched flags "
                    "preserved so re-adding does not reset progress")


@test("Watched/watching items can be removed one at a time", "Library")
def watch_items_are_removable():
    """There was no way to drop a single item — only Clear All.

    watch_history.remove() existed and NOTHING called it: the "Jump back in"
    rail on Home had no per-card affordance, and the only escape was Settings ›
    Clear All, which takes the entire history. Separately, the Continue Watching
    rail is built from renderPosterCard, and the watching toggle lived only in
    the list-view card (renderCard) — so the one row where you want to say "done
    with this" was the one row that could not.

    The ordering assertion matters as much as the button: dvui.clicked() consumes
    the press and a parent runs before its children, so a card that checks its
    own click before drawing the X swallows every click inside it and the X can
    never fire. Hover is read from the pointer position instead, and the card's
    click is checked last.
    """
    home = _src("src/ui/home.zig")
    tm = _src("src/services/tmdb.zig")
    wh = _src("src/player/watch_history.zig")

    rail = _between(home, "fn renderRecentlyPlayed()", "// ── Empty state ──")
    poster = _between(tm, "pub fn renderPosterCard(", "\nfn renderCard(")

    checks = {
        "remove() is actually called now": "wh.remove(i);" in rail,
        "remove() still deletes from the db": "DELETE FROM watch_history" in wh,
        # Structural: the X must be reachable, so the card cannot eat the click
        # first. Hover from geometry, click checked after the button.
        "hover does not consume the click": "card_r.contains(dvui.currentWindow().mouse_pt)" in rail,
        "card click checked after remove": rail.index("wh.remove(i);") < rail.index("dvui.clicked(card.data()"),
        # Removing compacts the array — every later entry shifts down.
        "iteration stops after removing": "break;" in rail[rail.index("wh.remove(i);"):rail.index("wh.remove(i);") + 200],
        # Continue Watching is poster cards; it needs the toggle the list has.
        "poster card can leave the watching list": "state.app.tmdb.watching" in poster
                                                   and "toggleList(&state.app.tmdb.watching" in poster,
        "the toggle persists": "store.saveLists();" in poster,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "per-item removal incomplete: " + ", ".join(missing)
    return "pass", "history rows remove individually; posters can leave Continue Watching"
