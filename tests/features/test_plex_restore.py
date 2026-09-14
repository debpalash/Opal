"""Plex — a restored session must actually load its library.

Regression for the blank-tab-on-restart bug: init() restored the persisted token
and stamped conn_state = .connected, so renderContent() skipped the sign-in panel
and drew the "Plex · <server>" header — but the ONLY caller of the section fetch
was connect(), the first-run PIN flow. fetchSections() itself had ZERO callers, so
section_count stayed 0 and every relaunch showed a connected-looking, permanently
empty library.

A pure unit test can't catch "this function is never called" — that's a wiring
property of the whole tree, so it's asserted here.

See tests/features/harness.py for the shared @test decorator + helpers."""
from .harness import *  # noqa: F401,F403

import re


def _callers(src, fn):
    """Count call sites of `fn` outside its own declaration.

    Matches `fn(` but not `fn fn(` (the decl) and not `.fn(` (a method on
    something else). A detached-thread spawn passes the bare name with no
    parens — `Thread.spawn(.{}, fn, .{})` — so that form counts too.
    """
    calls = len([
        m for m in re.finditer(r"(?<![.\w])" + re.escape(fn) + r"\s*\(", src)
        if not src[:m.start()].rstrip().endswith("fn")
    ])
    spawns = len(re.findall(r"spawn\([^)]*?,\s*" + re.escape(fn) + r"\s*,", src))
    return calls + spawns


@test("Plex restored session loads its library", "Plex")
def test_plex_restored_session_loads_library():
    svc = _src("src/services/plex.zig")
    pure = _src("src/services/plex_pure.zig")

    checks = {}

    # The bug itself: the section fetch must be reachable from the render path,
    # not only from the first-run PIN flow.
    checks["fetchSections has a caller"] = _callers(svc, "fetchSections") > 0
    checks["renderContent triggers the section load"] = (
        "shouldFetchSections" in svc and "fetchSections()" in svc
    )

    # It must NOT be a latch set before the fetch succeeds — that turns one
    # transient failure at launch into a blank tab for the whole run.
    checks["retry is backed off, not latched"] = "SECTIONS_RETRY_S" in pure
    checks["attempt timestamp is stamped"] = "sections_last_attempt_s" in svc
    checks["in-flight guard prevents a fetch per frame"] = "sections_loading" in svc

    # ...and it must latch on the fetch SUCCEEDING, not on "we got sections".
    # A server with zero libraries loads successfully and empty; a count-based
    # latch would re-curl /library/sections every retry window forever.
    checks["latches on success, not on section_count"] = "sections_loaded_once" in svc
    checks["empty library still counts as loaded"] = (
        "sections_loaded_once.store(true" in svc
    )
    # Signing out must clear it, or a different account lands on a blank library.
    checks["disconnect clears the load latch"] = (
        "sections_loaded_once.store(false" in svc
    )
    checks["a failed load is surfaced to the user"] = (
        'pushLog("warn", "plex"' in svc or "pushLog(\"warn\", \"plex\"" in svc
    )

    # Production must route through the tested predicate (no drift).
    checks["render path uses the pure predicate"] = "plex_pure.shouldFetchSections(" in svc

    # Stale-append guard: a section index alone can't distinguish "same fetch"
    # from "same section re-opened" (the A -> B -> A case).
    checks["generation counter exists"] = "view_gen" in svc
    checks["worker publish routes through the pure guard"] = "plex_pure.workerMayPublish(" in svc
    checks["generation is bumped on section switch"] = "view_gen.fetchAdd" in svc
    checks["bare index compare no longer gates the append"] = (
        "if (section_idx != active_section) return;" not in svc
    )

    # The generation guard alone does NOT cover the same-frame case: loadMore()
    # reads view_gen after fetchItems() bumped it, so a stale append inherits the
    # current generation and passes. fetchItems must therefore claim is_loading
    # and reset the cursor on the UI thread BEFORE spawning, or the same frame's
    # infinite-scroll block appends the new section at the old section's offset.
    fetch_items = svc.split("pub fn fetchItems(")[1].split("\npub fn ")[0] if "pub fn fetchItems(" in svc else ""
    checks["fetchItems resets before spawning (not in the worker)"] = (
        "beginSectionLoad()" in fetch_items
        and fetch_items.index("beginSectionLoad()") < fetch_items.index("spawn(runBrowseRequest")
    )
    checks["reset claims is_loading synchronously"] = "is_loading.store(true" in svc.split("fn beginSectionLoad()")[1][:200]
    checks["a failed spawn doesn't strand the tab loading"] = (
        "is_loading.store(false, .release); // never strand" in svc
    )

    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "plex restored-session load incomplete: " + ", ".join(missing)
    return "pass", (
        "restored token loads the library: fetchSections reachable from the render "
        "path, backed-off retry (not a pre-success latch), failure surfaced; "
        "stale-append guarded by a generation counter (A->B->A safe)"
    )


@test("Plex web playback uses stable identity and resume state", "Plex")
def test_plex_stable_web_playback():
    svc = _src("src/services/plex.zig")
    remote = _remote_api()
    web = _src("web/js/media.js")
    css = _src("web/styles/app.css")
    checks = {
        "server view state parsed": all(field in svc for field in ("viewOffset", "duration", "viewCount")),
        "stable rating-key action": "pub fn playByRatingKey" in svc,
        "rating key validated": "validRatingKey(rating_key)" in svc,
        "action resolves current item": "for (items[0..item_count])" in svc,
        "POST-only playback": 'requireMethod(stream, method, "POST")' in remote,
        "remote action takes id": 'getQueryParam(query, "id")' in remote and "playByRatingKey(id)" in remote,
        "remote emits resume state": all(field in remote for field in ("view_offset_ms", "duration_ms", "view_count")),
        "web does not play by index": "row.folder ? 'open_item' : 'play'" in web and "'/plex/play?idx='" not in web,
        "web labels resume": "'Resume'" in web,
        "web paints progress": "plex-progress" in web and ".plex-progress" in css,
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "Plex stable playback incomplete: " + ", ".join(missing)
    return "pass", "Plex web cards preserve resume state and execute playback by stable rating key"


@test("Plex TV and music hierarchy drills down", "Plex")
def test_plex_hierarchy():
    svc = _src("src/services/plex.zig")
    api = _src("src/services/remote_plex_api.zig")
    web = _src("web/js/media.js")
    checks = {
        "folder types classified": all(kind in svc for kind in ('"show"', '"season"', '"artist"', '"album"')),
        "children endpoint paginated": "/library/metadata/{s}/children?X-Plex-Container-Start" in svc,
        "bounded navigation": "MAX_NAV_DEPTH" in svc and "nav_depth >= MAX_NAV_DEPTH" in svc,
        "back refetches parent": "pub fn browseBack" in svc and "currentBrowseRequest()" in svc,
        "rapid requests copied": "spawn(runBrowseRequest" in svc and "spawnLegacy(S.run" not in svc,
        "stale page rejected": "view_gen.load(.acquire) != gen" in svc,
        "typed web actions": all(route in api for route in ('"/plex/open_item"', '"/plex/back"', '"/plex/play"')),
        "mutations require POST": 'requireMethod(stream, method, "POST")' in api,
        "web folder drilldown": "row.folder ? 'open_item' : 'play'" in web,
        "web back follows hierarchy": "apiMutation('/plex/back')" in web,
        "root sections stay reachable": "data-plex-section" in web and "active_section" in web,
        "native folder drilldown": "openChild(it.rating_key" in svc,
        "folder title remains server-owned": "if (!item.is_folder" in svc and "plex.openChild(id)" in api,
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "Plex hierarchy incomplete: " + ", ".join(missing)
    return "pass", "Plex shows→seasons→episodes and artists→albums→tracks drill down with bounded Back navigation"


@test("Plex watched state mutates by stable identity", "Plex")
def test_plex_watched_mutation():
    svc = _src("src/services/plex.zig")
    pure = _src("src/services/plex_pure.zig")
    api = _src("src/services/remote_plex_api.zig")
    web = _src("web/js/media.js")
    checks = {
        "documented token-free mutation URL": "watchedMutationUrl" in pure and '"scrobble" else "unscrobble"' in pure,
        "server uses PUT and header auth": ".method = .PUT" in svc and '"X-Plex-Token: {s}"' in svc,
        "owned optimistic mutation": "pub fn setWatched" in svc and "spawn(runWatchedMutation" in svc and "rollbackWatched" in svc,
        "stale rollback guarded": "watched_gen" in svc and "browse_generation" in svc,
        "typed web endpoint": '"/plex/action"' in api and '"played"' in api,
        "accessible web toggle": "plex-watched" in web and "Mark unwatched" in web and "apiMutation('/plex/action" in web,
        "native toggle": '"Mark watched"' in svc and "setWatched(" in svc,
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "Plex watched mutation incomplete: " + ", ".join(missing)
    return "pass", "Plex watched state is synchronized from native and web"


@test("Plex ratings synchronize from native and web", "Plex")
def test_plex_rating_mutation():
    svc = _src("src/services/plex.zig")
    pure = _src("src/services/plex_pure.zig")
    api = _src("src/services/remote_plex_api.zig")
    web = _src("web/js/media.js")
    checks = {
        "server rating parsed": 'm.object.get("userRating")' in svc,
        "bounded token-free URL": "pub fn ratingMutationUrl" in pure and 'identifier=com.plexapp.plugins.library&rating=' in pure,
        "PUT with header token": "runRatingMutation" in svc and ".method = .PUT" in svc and '"X-Plex-Token: {s}"' in svc,
        "independent generation rollback": "rating_gen" in svc and "rollbackRating" in svc,
        "typed bounded endpoint": 'std.mem.eql(u8, action, "rating")' in api and "parseFloat(f32" in api,
        "half-step web control": "plexRatingOptions" in web and "length:21" in web and "plex-rating" in web,
        "native control": "RATING_LABELS" in svc and "setRating(" in svc,
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "Plex rating mutation incomplete: " + ", ".join(missing)
    return "pass", "Plex 0–10 half-step ratings synchronize by stable identity"


@test("Plex favorites persist in Opal by stable identity", "Plex")
def test_plex_favorite_mutation():
    svc = _src("src/services/plex.zig")
    api = _src("src/services/remote_plex_api.zig")
    store = _src("src/services/library_store.zig")
    web = _src("web/js/media.js")
    checks = {
        "stable local lookup": "pub fn isFavorite" in store and 'isFavorite("plex"' in svc,
        "unified library persistence": 'setFavorite("plex"' not in svc and '"plex",\n            rating_key,' in svc,
        "typed endpoint": 'std.mem.eql(u8, action, "favorite")' in api and "plex.setFavorite(id, enabled)" in api,
        "projected state": 'favorite\\\":{s}' in api and "item.is_favorite" in api,
        "accessible web toggle": "plex-favorite" in web and "Add favorite" in web and "Remove favorite" in web,
        "details mutation": "&action=favorite&enabled=" in web,
        "native toggle": 'if (it.is_favorite) "Favorited" else "Favorite"' in svc,
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "Plex favorite persistence incomplete: " + ", ".join(missing)
    return "pass", "Plex favorites persist across browse rebuilds and join the unified Favorites rail"
