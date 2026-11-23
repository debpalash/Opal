"""Kid-mode maturity caps (server-side) and the TheTVDB v4 fallback.

Kids: one age scale for film + TV ratings (maturity_pure.zig), per-profile cap,
NSFW forced on, lists filtered where they are produced (catalog, search,
resolver catalog rows, recommendations, picks), over-cap titles refused by the
native open gate and the web API (403), loosening edits need the parent PIN.

TVDB: user-supplied key (secret config, never logged), used only when TMDB has
no match or an incomplete season; matching + merge are pure with fixture JSON
tests (tvdb_pure.zig); network calls are rate-limited and UNVERIFIED without a
key.

See tests/features/harness.py for the shared @test decorator."""
import os
import subprocess
import sys
from .harness import *  # noqa: F401,F403


def _zig_test(source, test_filter):
    result = subprocess.run(
        [sys.executable, os.path.join(PROJECT_DIR, "scripts", "zig-test.py"), source] + (["--test-filter", test_filter] if test_filter else []),
        cwd=PROJECT_DIR, capture_output=True, text=True, timeout=300)
    out = (result.stdout or "") + (result.stderr or "")
    if result.returncode:
        return "fail", out[-1500:]
    return None


def _fail(checks, what):
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", what + " incomplete: " + ", ".join(missing)
    return None


@test("Kids: unknown rating hidden, one film/TV age scale (unit tests run)", "Kids")
def test_kids_maturity_pure():
    for flt in ("unknown rating is hidden for kids", "film and TV ratings land on one age scale", "filter keeps allowed rows"):
        r = _zig_test("src/services/maturity_pure.zig", flt)
        if r:
            return r
    build = _src("build.zig")
    mat = _src("src/services/profiles_maturity.zig")
    checks = {
        "registered in build.zig": 'b.path("src/services/maturity_pure.zig")' in build,
        "service routes lists through the pure filter": "mp.filterInPlace(" in mat,
        "service routes playback through the pure decision": "mp.playDecision(" in mat,
    }
    return _fail(checks, "maturity pure") or ("pass", "ran maturity_pure regressions; filter + play decision shipped through it")


@test("Kids: catalog, search, rails and recommendations filtered at the source", "Kids")
def test_kids_lists_filtered():
    api = _src("src/services/tmdb_api.zig")
    worker = _between(api, "fn fetchTmdb(", "\nfn buildCinemetaUrl")
    seed = _between(api, "pub fn seedBrowseFromCache", "\n}\n")
    catalog_search = _between(api, "pub fn searchCatalogInto", "\n}\n")
    snapshot = _between(_src("src/services/remote_catalog_api.zig"), "fn sendSnapshot", "\n}\n")
    recs = _between(_src("src/services/recommendations.zig"), "fn addRec(", "\n        }\n")
    picks = _between(_src("src/services/operator_picks.zig"), "pub fn enabled()", "\n}\n")
    checks = {
        "browse/search pages filtered before publish + cache":
            "filterStaged(&staged)" in worker
            and worker.find("filterStaged(&staged)") < worker.find("putBrowseCache(staged.items"),
        "cache seed paints only proven rows": "visibleCached(&it)" in seed,
        "resolver catalog rows filtered": "filterSliceBlocking(" in catalog_search,
        "web catalog snapshot re-checks": "visibleCached(item)" in snapshot,
        "recommendations filtered": "idVisibleBlocking(id)" in recs,
        "unrated picks hidden": "unratedVisible()" in picks,
    }
    return _fail(checks, "kid list filtering") or ("pass", "grid/search/trending rail, resolver rows, web catalog, For You, picks")


@test("Kids: web API refuses over-cap titles and exposes the cap", "Kids")
def test_kids_api_enforced():
    details = _src("src/services/remote_details_api.zig")
    prof_api = _src("src/services/remote_profiles_api.zig")
    access = _src("src/services/access_pure.zig")
    catalog_js = _src("web/js/catalog.js")
    gate = _between(details, "fn maturityGate", "\n}\n")
    tv = _between(details, "pub fn tvDetails", "\n}\n")
    movie = _between(details, "pub fn movieDetails", "\n}\n")
    checks = {
        "403 gate": '"403 Forbidden"' in gate and "apiDecision(" in gate,
        "tv details gated before any fetch": "maturityGate(stream, query, .series, id)" in tv
            and tv.find("maturityGate(") < tv.find("useKeyless("),
        "movie details gated before any fetch": "maturityGate(stream, query, .movie, id)" in movie
            and movie.find("maturityGate(") < movie.find("useKeyless("),
        "cap + check route": '"/profiles/maturity"' in prof_api and "apiDecision(" in prof_api,
        "cap edit route": '"/profiles/kid"' in prof_api and "setKidOptions(.admin_api" in prof_api,
        "cap edit is host administration": '"/profiles/kid"' in _between(access, "const host_routes", "};"),
        "native open gate kept": 'profiles_maturity.zig").allowTmdb(item)' in _src("src/services/tmdb.zig"),
        "web UI stops on 403": "error?.status === 403" in catalog_js and "blockedByProfile(" in catalog_js,
    }
    r = _fail(checks, "kid API enforcement")
    if r:
        return r
    r = _zig_test("src/services/access_pure.zig", "household profile management")
    return r or ("pass", "movie/tv details 403 over cap; /profiles/maturity + admin /profiles/kid; access test ran")


@test("Kids: loosening the cap or leaving kid mode needs the parent PIN", "Kids")
def test_kids_parent_pin():
    for flt in ("only loosening edits need the parent PIN",):
        r = _zig_test("src/services/maturity_pure.zig", flt)
        if r:
            return r
    r = _zig_test("src/services/profiles_pure.zig", "parent pin check")
    if r:
        return r
    svc = _src("src/services/profiles.zig")
    set_kid = _between(svc, "pub fn setKidOptions", "\n}\n")
    ui = _src("src/ui/profiles_ui.zig")
    web = _src("web/js/profiles.js")
    checks = {
        "edit checks loosening then PIN": "maturity.loosens(" in set_kid and "checkParentPinLocked(parent_pin)" in set_kid,
        "PIN check through the pure backoff": "pure.checkPin(" in _between(svc, "fn checkParentPinLocked", "\n}\n"),
        "profile UI asks for it": "Main profile PIN" in ui and "mp.loosens(prev, next)" in ui,
        "profile UI offers the rating tiers": "mp.TIER_SHORT" in ui and "components.segment(" in ui,
        "web form is 401-safe (no unpair)": "/api/profiles/kid" in web and "networkFetch(" in _between(web, "profile-kid-form').onsubmit", "};"),
        "settings.zig untouched by this feature": "TIER_SHORT" not in _src("src/ui/settings.zig"),
        "NSFW stays forced for kids": "state.app.nsfw_filter_enabled = true" in _between(svc, "pub fn enforce", "\n}\n"),
    }
    return _fail(checks, "parent PIN") or ("pass", "loosening edits gated by owner PIN + backoff (UI, API, web)")


@test("TVDB: matching + season merge pure with fixture JSON tests", "TVDB")
def test_tvdb_pure():
    r = _zig_test("src/services/tvdb_pure.zig", "")
    if r:
        return r
    pure = _src("src/services/tvdb_pure.zig")
    build = _src("build.zig")
    checks = {
        "registered in build.zig": 'b.path("src/services/tvdb_pure.zig")' in build,
        "fixtures present": "FIXTURE_SEARCH" in pure and "FIXTURE_EPISODES" in pure and "FIXTURE_TMDB_SEASON" in pure,
        "tests present": pure.count('test "') >= 8,
    }
    return _fail(checks, "tvdb pure") or ("pass", "ran tvdb_pure: login/token, search ranking, ids, episodes, completeness, merge")


@test("TVDB: user key is a secret, never logged, never shipped", "TVDB")
def test_tvdb_key():
    cfg = _src("src/core/config.zig")
    st = _src("src/core/state.zig")
    svc = _src("src/services/tvdb.zig")
    remote = _src("src/services/remote.zig")
    access = _src("src/services/access_pure.zig")
    build = _src("build.zig")
    setup = _src("src/services/remote_tvdb_api.zig")
    log_lines = [l for l in svc.splitlines() if "pushLog(" in l]
    checks = {
        "secret bit": '"tvdb_api_key"' in _between(cfg, "fn secretBit", "\n}\n"),
        "saved sealed": 'setSecretKey("tvdb_api_key"' in cfg,
        "loaded through the secret envelope": "loadSecretValue(key, val, &state.app.tvdb_api_key" in cfg,
        "state field": "tvdb_api_key: [128]u8" in st,
        "no shipped default": "tvdb_default" not in build and "tvdb_default" not in st,
        "no key/token in logs": all("{s}" not in l and "key[" not in l and "token[" not in l for l in log_lines),
        "key only from the POST body": "credParam(body, \"\", \"key\"" in setup and 'requireMethod(stream, method, "POST")' in setup
            and 'remote_tvdb_api.zig").handleSetup(' in remote,
        "setup is host administration": '"/setup/tvdb"' in _between(access, "const host_routes", "};"),
        "inert without a key": "if (!hasKey()" in _between(svc, "pub fn completeSeason", "\n}\n")
            and "if (!hasKey()" in _between(svc, "pub fn searchFallback", "\n}\n"),
    }
    return _fail(checks, "tvdb key") or ("pass", "secret config + env, POST-only setup, no logging, inert without key")


@test("TVDB: fallback wired for no-match search and incomplete seasons (rate-limited)", "TVDB")
def test_tvdb_wiring():
    svc = _src("src/services/tvdb.zig")
    tmdb = _src("src/services/tmdb.zig")
    api = _src("src/services/tmdb_api.zig")
    details = _src("src/services/remote_details_api.zig")
    ep_thread = _between(tmdb, "fn fetchEpisodesThread", "\n}\n")
    checks = {
        "every request rate-limited": svc.count('rate_limit.acquire("tvdb"') >= 2,
        "pure decides completeness + merge": "pure.seasonIncomplete(" in svc and "pure.writeMergedSeason(" in svc,
        "pure ranks search matches": "pure.rankCandidates(" in svc and "pure.catalogId(" in svc,
        "native episodes filled": "tvdb.zig\").completeSeason(" in ep_thread,
        "web season route filled": "tvdb.zig\").completeSeason(" in _between(details, "fn sendSeasonJson", "\n}\n"),
        "browse search falls back": "tvdb.zig\").searchFallback(" in _between(api, "fn fetchTmdb(", "\nfn buildCinemetaUrl"),
        "resolver catalog falls back": "tvdb.zig\").searchFallback(" in _between(api, "pub fn searchCatalogInto", "\n}\n"),
        "fallback rows still pass the kid filter":
            _between(api, "fn fetchTmdb(", "\nfn buildCinemetaUrl").find("searchFallback(") < _between(api, "fn fetchTmdb(", "\nfn buildCinemetaUrl").find("filterStaged("),
    }
    r = _fail(checks, "tvdb wiring")
    return r or ("pass", "episodes (native + web) and no-match search; network UNVERIFIED without a key")
