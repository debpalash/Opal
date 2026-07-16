"""Auto-split from tests/test_features.py — Page Shell (part 1) tests.
Byte-for-byte identical test bodies; see tests/features/harness.py for the
shared @test decorator, helpers, and run_all()."""
from .harness import *  # noqa: F401,F403
import os, sys, subprocess, sqlite3, socket, time, json  # noqa: F401

@test("Page Router", "Page Shell")
def test_page_router():
    p = os.path.join(PROJECT_DIR, "src/core/router.zig")
    if not os.path.exists(p):
        return "fail", "router.zig missing"
    c = open(p).read()
    if "pub const Route" in c and "pub const History" in c and "fn navigate" in c:
        return "pass", "Route + History (navigate/back/forward)"
    return "fail", "router incomplete"


@test("Page Shell Wired", "Page Shell")
def test_page_shell():
    shell = os.path.join(PROJECT_DIR, "src/ui/shell.zig")
    main = open(os.path.join(PROJECT_DIR, "src/main.zig")).read()
    if (os.path.exists(shell)
            and "page_shell_enabled" in main
            and "shell.zig" in main):
        return "pass", "shell + flag branch in appFrame"
    return "fail", "page shell not wired"


@test("No Dead drawer_tab Writes", "Page Shell")
def test_no_dead_drawer_tab():
    # Services must navigate via state.navigateToTab (router-aware), never write
    # the dead state.app.drawer_tab (which the shell no longer reads to pick a page).
    sdir = os.path.join(PROJECT_DIR, "src/services")
    offenders = []
    for root, _, files in os.walk(sdir):
        for f in files:
            if not f.endswith(".zig"):
                continue
            p = os.path.join(root, f)
            for i, line in enumerate(open(p).read().splitlines(), 1):
                if "state.app.drawer_tab =" in line:
                    offenders.append(f"{os.path.relpath(p, PROJECT_DIR)}:{i}")
    if offenders:
        return "fail", "dead drawer_tab write: " + ", ".join(offenders[:4])
    return "pass", "services navigate via navigateToTab"


@test("Omnibox → Unified Search", "Page Shell")
def test_omnibox_search():
    shell = open(os.path.join(PROJECT_DIR, "src/ui/shell.zig")).read()
    search = open(os.path.join(PROJECT_DIR, "src/services/search.zig")).read()
    if "submitQuery" in shell and "pub fn submitQuery" in search and "navigate(.search)" in shell:
        return "pass", "omnibox routes plain queries to unified search"
    return "fail", "omnibox not wired to unified search"


@test("Playback Navigates to Player", "Page Shell")
def test_play_navigates():
    st = open(os.path.join(PROJECT_DIR, "src/core/state.zig")).read()
    browser = open(os.path.join(PROJECT_DIR, "src/services/browser.zig")).read()
    if "pub fn gotoPlayer" in st and "gotoPlayer()" in browser:
        return "pass", "load helpers reveal the Player route"
    return "fail", "playback doesn't navigate to player"


@test("Home Distinct From Browse", "Page Shell")
def test_home_distinct():
    shell = open(os.path.join(PROJECT_DIR, "src/ui/shell.zig")).read()
    home_path = os.path.join(PROJECT_DIR, "src/ui/home.zig")
    if not os.path.exists(home_path):
        return "fail", "home.zig dashboard missing"
    home = open(home_path).read()
    # Home must route to home.zig (not alias the TMDB browse content).
    if ".home => @import(\"home.zig\").render()" not in shell:
        return "fail", "home route still aliases TMDB content"
    # 2026-07 console redesign: Home is the agentic console — hero prompt +
    # centered rails (continue/trending/for-you), NOT a metrics dashboard.
    if ("Continue Watching" in home and "Trending tonight" in home
            and "renderHero" in home and "Time in app" not in home):
        return "pass", "Home is the media console (hero + rails, no stats dashboard)"
    return "fail", "home console lacks hero/rails or still has the stats dashboard"


@test("Usage Metrics Persisted", "Page Shell")
def test_usage_metrics():
    cfg = open(os.path.join(PROJECT_DIR, "src/core/config.zig")).read()
    st = open(os.path.join(PROJECT_DIR, "src/core/state.zig")).read()
    if "usage_seconds_total" in st and 'setKey("usage_seconds"' in cfg and "accrueUsage" in cfg:
        return "pass", "lifetime in-app time accrued + persisted"
    return "fail", "usage metrics not wired"


@test("TMDB Filters Single Toolbar", "Page Shell")
def test_tmdb_toolbar():
    tm = open(os.path.join(PROJECT_DIR, "src/services/tmdb.zig")).read()
    # The old multi-row layout (renderCategoryBar / renderSubTabs / gallery
    # toolbar) is collapsed into one renderToolbar(count).
    if "fn renderToolbar(" in tm and "fn renderCategoryBar(" not in tm:
        return "pass", "filter rows collapsed into one toolbar"
    return "fail", "TMDB still uses stacked filter rows"


@test("Free-Text UTF-8 Safe", "Page Shell")
def test_utf8_guard():
    # Fixed-buffer titles/names can truncate mid-codepoint; dvui's text layout
    # asserts valid UTF-8. A shared safeUtf8() guard must wrap dvui-rendered
    # free text in every network-fed renderer.
    txt = os.path.join(PROJECT_DIR, "src/core/text.zig")
    if not os.path.exists(txt) or "pub fn safeUtf8(" not in open(txt).read():
        return "fail", "core/text.zig safeUtf8 helper missing"
    renderers = {
        "src/services/tmdb.zig": "safeUtf8(item.title",
        "src/services/youtube.zig": "safeUtf8(item.title",
        "src/ui/jellyfin_ui.zig": "safeUtf8(item.name",
        "src/services/comics.zig": "safeUtf8(state.app.comic.title",
        "src/services/search.zig": "safeUtf8(item.name",
    }
    missing = [f for f, needle in renderers.items()
               if needle not in open(os.path.join(PROJECT_DIR, f)).read()]
    if missing:
        return "fail", "UTF-8 guard missing in: " + ", ".join(missing)
    return "pass", "all network-fed renderers UTF-8 guarded"


@test("Anime Threads Detached", "Page Shell")
def test_anime_detach():
    an = open(os.path.join(PROJECT_DIR, "src/services/anime.zig")).read()
    # Discarded `_ = std.Thread.spawn(...)` handles leak the pthread; every
    # spawn must store + detach (or join).
    if "_ = std.Thread.spawn(" not in an:
        return "pass", "all anime threads detached (no leaked handles)"
    return "fail", "an anime thread handle is discarded without detach"


@test("Podcasts Tab Wired", "Page Shell")
def test_podcasts_wired():
    # New media class: search (iTunes) → show → RSS episodes → stream audio.
    # Verify the tab is present end-to-end: enum + routing + service + parser +
    # remote API + web tab, and that the enclosure URL reaches mpv.
    st = _src("src/core/state.zig")
    drawer = _src("src/ui/drawer.zig")
    shell = _src("src/ui/shell.zig")
    svc = _src("src/services/podcasts.zig")
    pure = _src("src/services/podcasts_pure.zig")
    rem = _src("src/services/remote.zig")
    web = _src("web/index.html")
    checks = {
        # REGRESSION — a 6.9 MB feed against a 1 MB cap hung the app permanently.
        # readAll() stops when the buffer is full and leaves the rest in the pipe;
        # curl then blocks in write(2), where it can never reach its own --max-time
        # check, so child.wait() waits forever on a process that cannot exit. The
        # worker thread hung on "Loading…" — and because loadEpisodes() early-returns
        # while episodes_loading is set, EVERY later podcast click was a silent no-op
        # for the rest of the session.
        "drains curl's pipe (no deadlock)": "while ((io.read(so, &sink) catch 0) > 0) {}" in svc,
        # episodes[] holds 200, but a 1 MB cap only ever reached the newest 61.
        "episode cap fills the array": "4 * 1024 * 1024" in svc,
        "enum variant": "Podcasts," in st and "podcasts: struct" in st,
        "drawer route": ".Podcasts =>" in drawer and "podcasts.zig" in drawer,
        "shell label+icon": '.Podcasts => "Podcasts"' in shell and "lucide.podcast" in shell,
        "service search→episodes→play": all(
            f"pub fn {fn}" in svc for fn in ("searchPodcasts", "loadEpisodes", "playEpisode")
        ),
        "itunes endpoint": "itunes.apple.com/search?media=podcast" in svc,
        "enclosure→mpv": "loadContentDirect" in svc,
        "pure parsers": "pub fn parseItunes" in pure and "pub fn parseRssEpisodes" in pure,
        "remote routes": '/podcasts/search' in rem and '/podcasts/play' in rem,
        "web tab": 'id="page-podcasts"' in web and "loadPodcasts(" in web,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if not missing:
        return "pass", "podcasts tab wired: enum→nav→service→pure→remote→web"
    return "fail", "podcasts wiring incomplete: " + ", ".join(missing)


@test("Radio Tab Wired", "Page Shell")
def test_radio_wired():
    # New media class: search (RadioBrowser) → station list → stream audio.
    # Verify the tab is present end-to-end: enum + routing + service + parser,
    # and that url_resolved reaches mpv plus the click-count ping fires.
    st = _src("src/core/state.zig")
    drawer = _src("src/ui/drawer.zig")
    shell = _src("src/ui/shell.zig")
    svc = _src("src/services/radio.zig")
    pure = _src("src/services/radio_pure.zig")
    checks = {
        "enum variant": "Radio," in st and "radio: struct" in st,
        "drawer route": ".Radio =>" in drawer and "radio.zig" in drawer,
        "shell label+icon": '.Radio => "Radio"' in shell and "lucide.radio" in shell,
        "service search→play": all(
            f"pub fn {fn}" in svc for fn in ("searchRadio", "playStation")
        ),
        "radiobrowser endpoint": "all.api.radio-browser.info/json/stations/search" in svc,
        "url_resolved→mpv": "url_resolved" in svc and "loadContentDirect" in svc,
        "click-count ping": "/json/url/" in svc,
        "pure parser": "pub fn parseStations" in pure,
        "threads detached": "_ = std.Thread.spawn(" not in svc,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if not missing:
        return "pass", "radio tab wired: enum→nav→service→pure (url_resolved→mpv)"
    return "fail", "radio wiring incomplete: " + ", ".join(missing)


@test("Podcasts/Radio Open Populated", "Page Shell")
def test_podcasts_radio_default_content():
    # Both pages used to open empty (search box only). They now fetch a default
    # grid of popular content once per session, off the UI thread, through the
    # SAME API + parser + click handler the search path uses. Verify: the pure
    # URL builders/parsers exist and the service routes through them, the fetch
    # is latched + backgrounded, and cards reuse the shared poster daemon.
    pod = _src("src/services/podcasts.zig")
    pod_pure = _src("src/services/podcasts_pure.zig")
    rad = _src("src/services/radio.zig")
    rad_pure = _src("src/services/radio_pure.zig")
    st = _src("src/core/state.zig")
    checks = {
        # ── Podcasts: Apple top-shows chart → iTunes /lookup → parseItunes ──
        "podcast pure builders": all(
            f"pub fn {fn}" in pod_pure
            for fn in ("buildTopChartUrl", "parseTopChartIds", "buildLookupUrl")
        ),
        "podcast routes through pure": all(
            f"pure.{fn}(" in pod
            for fn in ("buildTopChartUrl", "parseTopChartIds", "buildLookupUrl")
        ),
        # The chart supplies ids only; /lookup returns search's result objects,
        # so the EXISTING parser must be what fills results[] (no 2nd parser).
        "podcast reuses parseItunes": "pure.parseItunes(" in pod,
        "podcast one-shot latch": "popular_fetched" in pod and "pub fn loadPopularOnce" in pod,
        "podcast fetch is backgrounded": "std.Thread.spawn(.{}, popularWorker" in pod,
        # ── Radio: RadioBrowser /topvote → the same parseStations ──
        "radio pure builder": "pub fn buildTopVoteUrl" in rad_pure,
        "radio topvote endpoint": "stations/topvote/" in rad_pure,
        "radio routes through pure": "pure.buildTopVoteUrl(" in rad,
        "radio reuses parseStations": "pure.parseStations(" in rad,
        "radio one-shot latch": "popular_fetched" in rad and "pub fn loadPopularOnce" in rad,
        "radio fetch is backgrounded": "std.Thread.spawn(.{}, popularWorker" in rad,
        # Both curl helpers allocate `cap` bytes and hand back only what was read.
        # Returning `buf[0..n]` is an INVALID FREE under the global DebugAllocator
        # (it checks free size against alloc size) and aborts the process on launch
        # — 49584 freed against 524288 allocated. The buffer must be shrunk to `n`.
        "curl shrinks buffer to the read length": all(
            "alloc.realloc(buf, n)" in s and "return buf[0..n];" not in s
            for s in (pod, rad)
        ),
        # ── Cards: artwork via the shared poster daemon, existing click path ──
        "podcast cards click loadEpisodes": "if (clicked) loadEpisodes(i)" in pod,
        "radio cards click playStation": "if (clicked) playStation(i)" in rad,
        "poster daemon reused": all(
            "poster.fetchAsync(" in s and "poster.uploadIfReady(" in s for s in (pod, rad)
        ),
        # Pages kick the fetch from their own render root, not a shared shell.
        "kicked from renderContent": all("loadPopularOnce();" in s for s in (pod, rad)),
        # Both podcasts + radio declare the popular-chart flag (>= 2 — other
        # catalog tabs, e.g. VNDB, legitimately declare their own sibling flag).
        "state flag": st.count("showing_popular: bool") >= 2,
        # Detached threads only — a discarded handle leaks the pthread.
        "threads detached": all("_ = std.Thread.spawn(" not in s for s in (pod, rad)),
    }
    missing = [k for k, ok in checks.items() if not ok]
    if not missing:
        return "pass", "podcasts+radio open populated (top charts, reused fetchers/parsers/click paths)"
    return "fail", "default content incomplete: " + ", ".join(missing)


@test("Comics MangaDex Source", "Page Shell")
def test_comics_mangadex_source():
    # The Comics tab shipped with ONE source (readallcomics) whose endpoint lives
    # in source_config — so on a fresh install it is INERT and the tab is empty.
    # MangaDex is a keyless, documented public API (api.mangadex.org): no key slot,
    # no source_config entry, works out of the box.
    #
    # A MangaDex card can't be read by the generic curl+HTML scraper (its pages
    # come from a 3-call JSON chain), so cards carry a `mangadex:<uuid>` route URL
    # that fetchComicThread dispatches on BEFORE the scraper. Verify that seam, and
    # that every URL/JSON decision routes through the unit-tested pure module.
    svc = _src("src/services/comics.zig")
    pure = _src("src/services/comics_pure.zig")
    build = _src("build.zig")
    checks = {
        # ── Source registered in the selector ──
        "source enum variant": "const Source = enum { all, readallcomics, mangadex }" in svc,
        "source chip": 'renderSourceChip("MangaDex", 3, .mangadex)' in svc,
        # ── Keyless: the endpoint is a constant, NOT a source_config lookup ──
        "keyless api const": 'pub const MD_API = "https://api.mangadex.org"' in pure,
        "no source_config gate": 'source_config.zig").get("mangadex"' not in svc,
        # ── Pure module owns URL building + JSON parsing ──
        "pure builders": all(
            f"pub fn {fn}" in pure
            for fn in (
                "buildSearchUrl",
                "buildFeedUrl",
                "buildAtHomeUrl",
                "buildCoverUrl",
                "buildPageUrl",
                "buildRouteUrl",
                "mangaIdFromRoute",
                "parseMangaEntry",
                "parseAtHome",
                "firstChapterId",
            )
        ),
        # Production MUST call the pure fns (so the tested logic is the shipped logic).
        "service routes through pure": all(
            f"pure.{fn}(" in svc
            for fn in (
                "buildSearchUrl",
                "buildFeedUrl",
                "buildAtHomeUrl",
                "buildCoverUrl",
                "buildPageUrl",
                "buildRouteUrl",
                "mangaIdFromRoute",
                "parseMangaEntry",
                "parseAtHome",
                "firstChapterId",
            )
        ),
        # The existing percent-encoder now delegates to the tested one (no drift).
        "encoder routes through pure": "return pure.percentEncodeQuery(input, out);" in svc,
        # ── Reader seam: mangadex: route dispatched before the HTML scraper ──
        "route scheme": 'pub const MD_SCHEME = "mangadex:"' in pure,
        "reader dispatch": "if (pure.mangaIdFromRoute(url)) |manga_id|" in svc,
        "reader stages pages": "fn loadMangadexPages(manga_id: []const u8) bool" in svc,
        # Reuses the shared page-download pipeline rather than a second downloader.
        "reuses downloadPages": "downloadPages(gen);" in svc,
        # ── Security: ids are interpolated into a request path → must be validated ──
        "id validation gate": "pub fn isValidId" in pure,
        # ── Networking: curl only. std.http SEGVs on some ISP TLS resets, so the
        #    client type must never be constructed (a *mention* in a comment
        #    explaining why we avoid it is fine — match on real usage).
        "curl not std.http": "std.http.Client" not in svc and '"curl"' in svc,
        # Detached threads only — a discarded handle leaks the pthread.
        "threads detached": "_ = std.Thread.spawn(" not in svc,
        # ── Pure module registered in the `zig build test` step ──
        "test registered": 'b.path("src/services/comics_pure.zig")' in build,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if not missing:
        return "pass", "comics: MangaDex source wired (keyless API → route URL → JSON reader chain)"
    return "fail", "mangadex wiring incomplete: " + ", ".join(missing)


@test("Brand Is Opal", "Page Shell")
def test_brand_is_opal():
    # User-facing brand unified to "Opal — Play everything". Guard the display
    # surfaces against regressing to the old "ZigZag Media Console" wording.
    main = _src("src/main.zig")
    web = _src("web/index.html")
    tools = _src("src/services/ai_tools.zig")
    checks = {
        "window title": 'title = "Opal' in main and "ZigZag Media Console" not in main,
        "web title/brand": "Opal — Play everything" in web and "ZigZag — Remote" not in web,
        "assistant identity": "You are Opal" in tools and "You are ZigZag AI" not in tools,
    }
    missing = [k for k, v in checks.items() if not v]
    if not missing:
        return "pass", "display brand = Opal / Play everything"
    return "fail", f"brand regressed: {missing}"


@test("Web UI API Base Port", "Page Shell")
def test_web_api_base_port():
    # Web UI is served on :3000 but the JSON API lives on :41595 — index.html
    # must target the API port, not location.origin (which is the :3000 server).
    html = _src("web/index.html")
    if not html:
        return "skip", "web/index.html not present"
    if ":41595" in html and "const API = location.origin;" not in html:
        return "pass", "web UI targets API :41595 (not location.origin)"
    return "fail", "web UI API base still points at the static server"


@test("Plugin Manager Wired", "Page Shell")
def test_plugin_manager():
    # qBittorrent-style source-endpoint manager: fetch opal-plugins manifest →
    # Install writes ~/.config/opal/plugins/sources/<id>.json (read by
    # source_config) → the built-in connector goes live.
    pr = _src("src/services/plugin_repo.zig")
    pg = _src("src/services/plugins.zig")
    ok = (
        "pub fn refresh()" in pr
        and "pub fn install(" in pr
        and "pub fn uninstall(" in pr
        and "api.github.com/repos" in pr
        and "source_config.reload()" in pr
        and "renderSourcePlugins" in pg
    )
    debrid = (
        "debridKey()" in pr
        and "applyDebrid" in _src("src/services/stremio.zig")
        and "loadInstalledAddons" in _src("src/services/resolver.zig")
    )
    if not ok:
        return "fail", "plugin manager not wired"
    if not debrid:
        return "fail", "debrid not wired"
    return "pass", "fetch/install/uninstall + UI + debrid wired"


@test("Bundled Plugin Manifest", "Page Shell")
def test_bundled_manifest():
    # The Plugins page must show the source list instantly + offline: a checked-in
    # plugins-manifest.json is loaded via loadLocalManifest() before the network
    # refresh, bundled into the .app by build-app.sh, and read from resourceRoot.
    import json
    mpath = os.path.join(PROJECT_DIR, "plugins-manifest.json")
    if not os.path.exists(mpath):
        return "fail", "plugins-manifest.json missing at repo root"
    try:
        m = json.load(open(mpath))
    except Exception as e:
        return "fail", f"manifest not valid JSON: {e}"
    plugins = m.get("plugins")
    if not isinstance(plugins, list) or len(plugins) == 0:
        return "fail", "manifest has no plugins[]"
    for p in plugins:
        if not p.get("id") or not p.get("type"):
            return "fail", f"plugin missing id/type: {p!r}"
    if "zigzag" in json.dumps(m):
        return "fail", "manifest still references legacy 'zigzag' path"
    # Wiring: loaded before refresh, and bundled by the packager.
    pg = _src("src/services/plugins.zig")
    pr = _src("src/services/plugin_repo.zig")
    sh = _src("scripts/build-app.sh")
    if "loadLocalManifest()" not in pg:
        return "fail", "loadLocalManifest() not called from Plugins page"
    if "pub fn loadLocalManifest" not in pr:
        return "fail", "loadLocalManifest not defined"
    if "plugins-manifest.json" not in sh:
        return "fail", "build-app.sh does not bundle plugins-manifest.json"
    return "pass", f"{len(plugins)} plugins, offline-loaded + bundled"
