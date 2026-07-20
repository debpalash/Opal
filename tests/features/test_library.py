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
