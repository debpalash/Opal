"""One shared media/action identity across native and web.

src/services/media_identity_pure.zig owns kind, provider ids, episode
numbering, targets, actions, resume/watched, the JSON shape, and selection
tokens. These checks prove each surface routes through it instead of keeping
its own copy, and run the browser fixtures for the web half.

See tests/features/harness.py for the shared @test decorator + _src()."""
import re, shutil
import subprocess

from .harness import *  # noqa: F401,F403


@test("Media identity pure module is the tested source of truth", "Identity")
def test_identity_module_registered():
    pure = _src("src/services/media_identity_pure.zig")
    build = _src("build.zig")
    checks = {
        "registered in zig build test": 'b.path("src/services/media_identity_pure.zig")' in build
            and "test_media_identity_pure" in build,
        "TMDB/IMDb/TVDB normalisation tests": 'test "parseId: IMDb forms normalise to one value"' in pure
            and 'test "parseId: TMDB, TVDB, AniList and MAL forms carry their family"' in pure,
        "movie/TV namespace regression": 'test "compareTitle: TMDB movie and TV ids live in different namespaces"' in pure,
        "anime absolute vs season numbering": 'test "compare: season numbering vs anime absolute numbering"' in pure,
        "late-result regression": 'test "titleResult: a late lookup never lands on the next title' in pure
            and 'test "Selection: a late result for the previous title is rejected"' in pure,
        "watched uses server sync threshold": 'progress_rules.isFinished(position, duration)' in pure,
        "Play here uses browser playability": 'playback.classify(name)' in pure,
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "identity module incomplete: " + ", ".join(missing)
    return "pass", "parse/compare/key/actions/progress/JSON/selection tested in one pure module"


@test("Native and remote JSON render actions from one identity card", "Identity")
def test_identity_routed_native_and_remote():
    resolver = _src("src/services/resolver.zig")
    search = _src("src/services/search.zig")
    content = _src("src/services/search_content_pure.zig")
    remote = _src("src/services/remote.zig")
    projection = _src("src/services/remote_identity.zig")
    tmdb = _src("src/services/tmdb.zig")
    row = _between(search, "fn renderCompactRowMain(", "fn renderSearchResultContext(")
    checks = {
        "resolver builds the card": "pub fn identityCard(item: *const ResolvedItem)" in resolver
            and "mi.primaryFor(@tagName(item.source))" in resolver,
        "native row verbs from the card": "resolver.identityCard(item)" in row and "card.primary.label()" in row
            and "card.targets.queue" in row
            and '"open audio"' not in row and 'else "play"' not in row,
        "search grouping compares through identity": "media_identity.compareTitle(mediaIdentity(a), mediaIdentity(b))" in content
            and "fn validImdb(" not in content,
        "remote rows carry identity": '@import("remote_identity.zig").writeSearchRow(&w, item)' in remote
            and "mi.writeJson(w, resolver.identityCard(item))" in projection,
        "downloads carry explicit targets": '@import("remote_identity.zig").writeFile(&w, entry.name, is_dir)' in remote
            and ".here = mi.hereFor(name), .opal = !state.app.is_headless" in projection,
        "native TV lookup uses selection tokens": "media_identity.titleResult(tv_selection, res.token, waiting)" in tmdb
            and "tv_selection.clear();" in tmdb and "selectTv(item.id);" in tmdb,
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "identity routing gap: " + ", ".join(missing)
    return "pass", "native search, grouping, TV lookups and /api JSON share media_identity_pure"


@test("Web reads the shared identity instead of re-deriving it", "Identity")
def test_web_identity_reader():
    identity = _src("web/js/identity.js")
    search = _src("web/js/search.js")
    catalog = _src("web/js/catalog.js")
    details = _src("web/js/source-details.js")
    html = _src("web/index.html")
    static = _src("src/services/remote_static.zig")
    worker = _src("web/service-worker.js")
    checks = {
        "served and cached": '<script src="/js/identity.js"></script>' in html
            and '.route = "/js/identity.js"' in static and "'/js/identity.js'" in worker,
        "loaded before consumers": html.index("/js/identity.js") < html.index("/js/search.js"),
        "no local verb table": "source === 'comics' || source === 'novels'" not in search
            and "identityPrimaryAction(row?.identity)" in search,
        "no guessed tmdb grouping key": "`tmdb:${row.media}:${row.id}`" not in search and "mediaIdentityKey(row)" in search,
        "explicit download targets": "data-file-play" in catalog and "playInBrowser(streamUrl(rel), rel, rel)" in catalog,
        "source details selection token": "sourceDetailsSelection.isCurrent(selection)" in details,
        "selection contract": "isCurrent(token)" in identity and "isSameTitle(token)" in identity,
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "web identity gap: " + ", ".join(missing)
    if not shutil.which("node"):
        return "skip", "static checks pass; Node is unavailable for the browser fixtures"
    result = subprocess.run(["node", "--test", "--test-name-pattern=Shared identity", "tests/test_web_lifecycle.mjs"],
                            cwd=PROJECT_DIR, capture_output=True, text=True, timeout=60)
    # Node's test runner prints "# pass 5" (TAP) or "ℹ pass 5" (spec, Node 23+).
    if result.returncode or not re.search(r"^(?:#|ℹ) pass 5$", result.stdout, re.M):
        return "fail", (result.stderr + result.stdout)[-1800:]
    return "pass", "identity.js validates server cards; 5 browser fixtures (verbs, keys, targets, tokens, late drama list)"


@test("Web parity ledger records the identity model", "Identity")
def test_identity_parity_ledger():
    ledger = _src("docs/WEB-UI-PARITY.md")
    checks = {
        "section": "## Shared media identity" in ledger,
        "operation rows": all(op in ledger for op in ("identity.key", "identity.actions", "identity.targets", "Selection tokens")),
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "parity ledger missing: " + ", ".join(missing)
    return "pass", "WEB-UI-PARITY.md lists identity operations and their evidence"
