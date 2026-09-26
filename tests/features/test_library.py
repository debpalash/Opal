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
        checks[f"resume dispatch: {kind}"] = (
            "switch (library_pure.parseKind(kind))" in home and f'.{kind}' in home
        )
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
        "movie drops history entry": "removeByNameUi(r.idSlice())" in lib,
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

    if "hist_idx" in lib:
        return "fail", "movie actions still depend on a transient history index"
    return "pass", ("all three kinds removable from Watching; watched flags "
                    "preserved so re-adding does not reset progress")


@test("Home continue cards can be pinned or hidden safely", "Library")
def watch_items_are_removable():
    """Home uses one cross-media Continue rail. Pinning only changes its order;
    hiding only removes a card from Home and can be reversed from the header.
    Neither action deletes progress from the source or unified library row."""
    home = _src("src/ui/home.zig")
    store = _src("src/services/library_store.zig")
    dbz = _src("src/core/db.zig")

    checks = {
        "one cross-media rail": 'renderLibraryItemsRail(items[0..n], "Continue"' in home and "renderRecentlyPlayed" not in home,
        "schema stores home state": "home_hidden INTEGER" in dbz and "home_pinned INTEGER" in dbz,
        "pin mutation is narrow": "pub fn setHomePinned" in store and "SET home_pinned" in store,
        "hide mutation is narrow": "pub fn setHomeHidden" in store and "SET home_hidden" in store,
        "hidden cards excluded": "home_hidden=0" in store,
        "pinned cards sort first": "ORDER BY home_pinned DESC" in store,
        "pin control wired": "setHomePinned(" in home and "Pin to front" in home,
        "hide control wired": "setHomeHidden(" in home and "Remove from Home" in home,
        "private until hover": "renderPrivateTitle(" in home and "const revealed = !manage_continue or hovered" in home,
        "hidden cards restorable": "restoreHiddenContinue()" in home and "Restore hidden" in home,
        "no progress deletion": "DELETE FROM library_items" not in store,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "safe Home continue controls incomplete: " + ", ".join(missing)
    return "pass", "cross-media Continue cards pin/hide/restore without deleting progress"


@test("Verified movie history removal synchronizes by catalog identity", "Library")
def movie_history_removal_sync():
    db = _src("src/core/db.zig")
    wh = _src("src/player/watch_history.zig")
    player = _src("src/player/player.zig")
    history = _src("src/services/history.zig")
    trakt = _src("src/services/trakt.zig")
    simkl = _src("src/services/simkl.zig")
    library = _src("src/services/tv_library.zig")
    remote = _src("src/services/remote_library_api.zig")
    web = _src("web/js/integrations.js")
    main = _src("src/main.zig")
    checks = {
        "catalog id persisted": "catalog_tmdb_id INTEGER" in db
            and "catalog_tmdb_id" in history and "catalog_movie_tmdb_id" in player,
        "verified identity bound": "bindCatalogMovie(history_identity, p.catalog_tmdb_id)" in player
            and "pub fn bindCatalogMovie" in wh,
        "native removal syncs": "markUnwatchedMovie(catalog_tmdb_id)" in wh,
        "trakt removal": "pub fn markUnwatchedMovie" in trakt
            and '"/sync/history/remove"' in trakt,
        "simkl removal": "pub fn markUnwatchedMovie" in simkl
            and '"/sync/history/remove"' in simkl,
        "latest state wins": 'enqueueState("trakt", operation' in trakt
            and 'enqueueState("simkl", operation' in simkl,
        "web removal is UI-thread safe": "requestRemove(item.id)" in library
            and "pub fn requestRemove" in wh and "pub fn drainUi" in wh
            and 'watch_history.zig").drainUi()' in main,
        "response acknowledges mutation": "remove_applied.load(.acquire) >= ticket" in wh,
        "web exposes movie remove": "r.kind !== 'movie' ? '<button class=\"watch-remove\"" not in web
            and '<button class="watch-remove" data-action="remove">' in web
            and "action=remove&kind=" in web,
        "full identity accepted": "var id_buf: [512]u8" in remote,
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "movie history removal sync incomplete: " + ", ".join(missing)
    return "pass", "verified movie identity survives history persistence and drives exact provider removal"


@test("Movie favorites and personal ratings persist in the unified library", "Library")
def movie_preferences_persist():
    db = _src("src/core/db.zig")
    store = _src("src/services/library_store.zig")
    remote = _src("src/services/remote_library_api.zig")
    browser = _src("src/services/browser.zig")
    web = _src("web/js/catalog.js")
    checks = {
        "rating schema": "user_rating REAL DEFAULT -1" in db,
        "state preserves other fields": "pub fn getState" in store and "pub fn setRating" in store
            and "ON CONFLICT(kind,item_id) DO UPDATE SET user_rating" in store,
        "typed read and mutation routes": '"/library/item"' in remote
            and '"/library/item/action"' in remote and "requireMethod(stream, method, \"POST\")" in remote,
        "bounded half-step validation": "rating must be a half-step from 0 to 10" in remote,
        "movie detail favorite": "renderMovieLibraryActions" in web and "☆ Favorite" in web,
        "movie detail rating": "personalRatingOptions" in web and "Rated ${rating.value} / 10" in web,
        "mutations use POST helper": "apiMutation('/library/item/action?kind=movie" in web,
        "favorite can reopen": "opal://search/{s}" in remote and '"opal://search/"' in browser
            and "triggerSearch(query)" in browser,
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "movie preference persistence incomplete: " + ", ".join(missing)
    return "pass", "movie favorites and half-step ratings survive restart under stable TMDB identity"


@test("Local library is indexed, correctable, and duplicate-aware", "Library")
def local_library_index():
    db = _src("src/core/db.zig")
    service = _src("src/services/local_library.zig")
    resolver = _src("src/services/resolver.zig")
    main = _src("src/main.zig")
    remote = _src("src/services/remote_local_library_api.zig")
    page = _src("web/index.html")
    web = _src("web/js/integrations.js")
    native = _src("src/ui/local_library_ui.zig")
    watching = _src("src/services/tv_library.zig")
    checks = {
        "durable indexed schema": "CREATE TABLE IF NOT EXISTS local_media" in db
            and "idx_local_media_fingerprint" in db
            and "CREATE TABLE IF NOT EXISTS local_library_roots" in db,
        "bounded recursive scan": "MAX_FILES" in service and "MAX_DEPTH" in service
            and "never follow symlinks" in service,
        "sampled content identity": "readPositionalAll" in service and "first and last" not in service
            and "contentFingerprint" in service,
        "stale rows retired": "scan_token<>?2" in service,
        "offline roots preserved": "if (!rootAvailable(root_path)) continue" in service,
        "managed roots": all(marker in service for marker in (
            "pub fn addRoot", "pub fn listRoots", "pub fn removeRoot",
        )),
        "search avoids filesystem walk": 'library.search(q[0..qlen], false' in resolver
            and "cwdOpenDir(save_path" not in resolver,
        "startup refresh is off-thread": 'local_library.zig").scanAsync()' in main,
        "opaque remote rows": '\\"id\\":{d}' in remote and '\\"path\\":' not in remote,
        "typed corrections": "invalid metadata correction" in remote and "pub fn correct" in service,
        "management UI": all(marker in page + web for marker in (
            'id="local-scan"', 'id="local-query"', 'id="local-duplicates"',
            'id="local-root"', 'id="local-root-add"', "data-root-remove",
            "data-local-save", "Likely duplicates only", "apiFormMutation('/local-library/action'",
        )),
        "native manager": "local_library_ui.zig" in watching and all(marker in native for marker in (
            "library.scanAsync()", "library.addRoot", "library.removeRoot", "duplicates_only",
            "library.correct(edit_id", "Search indexed files",
        )),
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "local library lifecycle incomplete: " + ", ".join(missing)
    return "pass", "recursive local media is indexed once, searched instantly, corrected safely, and grouped by sampled identity"


@test("Universal results merge semantic duplicates with playback fallback", "Library")
def semantic_result_fallbacks():
    pure = _src("src/services/resolver_dedup_pure.zig")
    resolver = _src("src/services/resolver.zig")
    player = _src("src/player/player.zig")
    checks = {
        "semantic key is pure and tested": "pub fn semanticKey" in pure
            and "pub fn sameSemantic" in pure
            and "preserves editions" in pure,
        "transport identity still wins": "dedup.sameItem(current_url, url)" in resolver,
        "semantic merge is source bounded": "fallbackCompatible(items[d].source, scored_item.source)" in resolver,
        "best ranked candidate stays primary": "scored_item.score < items[d].score" in resolver
            and "ByScore.lessThan" in resolver,
        "runner-up retained": "scored_item.fallback_url" in resolver
            and "items[d].fallback_url_len == 0" in resolver,
        "fallback reaches player": ".fallback_url = item.fallback_url" in resolver
            and "fallback_recovery.takeOnFailure()" in player,
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "semantic fallback pipeline incomplete: " + ", ".join(missing)
    return "pass", "same-title direct streams merge; the best result plays first and the runner-up retries once"


@test("Card action row is never clipped out of its own card", "Library")
def card_action_row_fits():
    """The Watching page's Play and Remove controls were squeezed to zero height.

    media_card pinned min == max at POSTER_H + CHROME_H, and CHROME_H was
    documented as "title + status line + (progress bar | action button)" — an
    EITHER/OR. Every Watching row asks for BOTH: a progress bar and a
    Play/Remove row. The action row was laid out past the bottom of the box and
    collapsed to nothing. Measured on the running app: the card spanned y
    207..686 and the action row 686..686. That is why the page had no visible
    way to remove a show even though removeRow() was wired and the button had a
    tooltip. With the height sized for what the card carries, the same row
    measures 690..732 inside a card of 207..732.

    The rule that keeps it fixed: the height is a FLOOR, never a ceiling. If the
    estimate is low, or a theme/font change makes a row taller, the card grows
    instead of silently swallowing a control.
    """
    mc = _src("src/ui/media_card.zig")
    ez = _src("src/services/eztv_calendar.zig")
    render = _between(mc, "pub fn render(src: std.builtin.SourceLocation", "// ── Poster ──")

    checks = {
        "height depends on the card's contents": "pub fn cardHeight(has_progress: bool, has_actions: bool)" in mc,
        "action row is budgeted": "ACTION_H" in mc and "if (has_actions) ACTION_H else 0" in mc,
        "card height is a floor": ".min_size_content = .{ .w = width, .h = h }" in render,
        "card height is not a ceiling": ".max_size_content = .{ .w = width, .h = std.math.floatMax(f32) }" in render,
        "episode cards reserve landscape artwork": "if (card.landscape) 126 else POSTER_H" in render,
        # The rail that shows these cards must not re-impose the ceiling.
        "release rail does not clamp height": "media_card.cardHeight(false, true) + 12" in ez
                                              and ".max_size_content = .{ .w = std.math.floatMax(f32), .h = std.math.floatMax(f32) }" in ez,
        # The Watching page still asks for the remove control.
        "watching cards stay removable": ".removable = true," in _src("src/services/tv_library.zig"),
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "card can still clip its action row: " + ", ".join(missing)
    return "pass", "card sizes to its contents; action/remove row cannot be clipped"
