"""Headless web UI (web/index.html) — feature-parity wiring checks.

The web UI is a single-file vanilla-JS SPA served by remote.zig on :41595. It has
no build step and can't be unit-tested, so we assert each vertical is *wired*:
a nav tab (`data-page`), a `page-` section, and the API route(s) it calls. As new
verticals reach the web UI for headless/desktop parity, add a row to VERTICALS.

See tests/features/harness.py for the shared @test decorator + _src()."""
from .harness import *  # noqa: F401,F403


# Each vertical: the nav data-page id, the page section id, and route fragments
# the page must reference. Extend this as parity tabs land.
VERTICALS = {
    "search":   ("search",   "page-search",   ["/search", "/load"]),
    "browse":   ("browse",   "page-browse",   ["/tmdb"]),
    "anime":    ("anime",    "page-anime",    ["/anime/search", "/anime/episodes", "/anime/play"]),
    "podcasts": ("podcasts", "page-podcasts", ["/podcasts/search", "/podcasts/play"]),
    "jellyfin": ("jf",       "page-jf",       ["/jellyfin/login", "/jellyfin/browse"]),
    "rss":      ("rss",      "page-rss",      ["/rss"]),
    "activity": ("act",      "page-act",      ["/torrents", "/queue", "/downloads", "/history"]),
    "youtube":  ("yt",       "page-yt",       ["/youtube/search", "/youtube"]),
    "livetv":   ("tv",       "page-tv",       ["/livetv"]),
}


@test("Web UI vertical parity wiring", "Web UI")
def test_web_ui_verticals():
    ui = _src("web/index.html")
    if not ui:
        return "fail", "web/index.html missing"

    missing = []
    for name, (page, section, routes) in VERTICALS.items():
        if f'data-page="{page}"' not in ui:
            missing.append(f"{name}: nav button data-page={page}")
        if f'id="{section}"' not in ui:
            missing.append(f"{name}: section {section}")
        for r in routes:
            # routes are called via the api('/...') helper
            if f"'{r}" not in ui and f'"{r}' not in ui and f"({r}" not in ui:
                missing.append(f"{name}: route {r}")

    if missing:
        return "fail", "web UI parity gaps: " + "; ".join(missing)
    return "pass", f"{len(VERTICALS)} verticals wired (nav + section + routes)"


@test("Web UI YouTube tab", "Web UI")
def test_web_ui_youtube():
    ui = _src("web/index.html")
    checks = {
        "nav button": 'data-page="yt"' in ui,
        "page section": 'id="page-yt"' in ui,
        "search wired": "/youtube/search?q=" in ui and "function runYt(" in ui,
        "results poll": "api('/youtube')" in ui and "function renderYt(" in ui,
        # In-browser embed (works hosted AND companion) + desktop /load fallback.
        "embed player": "openYtEmbed(" in ui and "youtube-nocookie.com/embed/" in ui,
        "companion fallback": "youtube.com/watch?v=" in ui,
        # Watcher cleaned up on tab-leave like the other settle-watchers.
        "watcher cleanup": "clearInterval(ytWatch)" in ui,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "YouTube tab incomplete: " + ", ".join(missing)
    return "pass", "YouTube: search + poll + in-browser embed + /load fallback"


@test("Web UI Live TV tab + /api/livetv route", "Web UI")
def test_web_ui_livetv():
    ui = _src("web/index.html")
    rm = _src("src/services/remote.zig")
    checks = {
        # Server: pages the SQLite catalog, NSFW-filtered like the desktop tab.
        "route dispatch": '"/livetv"' in rm and "fn apiLiveTv(" in rm,
        "pages the catalog": "queryPage(rows, offset" in rm and "cat.count(q)" in rm,
        "nsfw follows setting": "nsfw_allowed = !state.app.nsfw_filter_enabled" in rm,
        # IptvChannel is ~1.6KB — a stack page would blow the thread budget.
        "page heap-allocated": "alloc.alloc(ipure.IptvChannel" in rm,
        # Web: search + paging + watch.
        "tab wired": 'data-page="tv"' in ui and 'id="page-tv"' in ui and "function loadTv(" in ui,
        "search + paging": "function runTv(" in ui and "tvOffset" in ui and 'id="tv-more"' in ui,
        # Hosted plays the stream URL in-browser; companion hands it to mpv.
        "watch both modes": "function openStreamUrl(" in ui and "if (HOSTED) openStreamUrl(" in ui
            and "/load?url=" in ui,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "Live TV incomplete: " + ", ".join(missing)
    return "pass", "Live TV: /api/livetv catalog paging + web tab (search, load-more, watch)"
