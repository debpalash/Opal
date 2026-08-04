"""Desktop ⇄ web UI feature parity.

Opal's goal is one all-in-one media system where the web companion is *almost*
on par with the desktop app. This module makes that measurable instead of
anecdotal:

  * COVERED — desktop capabilities the web UI already has. Asserted, so a web
    page or its API route can never silently regress.
  * GAPS — desktop capabilities the web UI does not have yet. Reported as a
    warn with a live count, so the number is visible every run and shrinks as
    the gaps close. Not a fail: parity is a direction, not a released promise.

Sources of truth: `src/core/router.zig` (Route / PluginTab), `state.zig`
(SettingsTab), the `data-page` buttons in `web/index.html`, and the route
literals in `src/services/remote.zig`.

See tests/features/harness.py for the shared @test decorator + _src()."""
from .harness import *  # noqa: F401,F403
import re


# Desktop capability → (web data-page, required API route fragments).
# Every row here is a promise the web UI already keeps.
COVERED = {
    "search":            ("search", ["/search"]),
    "browse (TMDB)":     ("browse", ["/tmdb"]),
    "now playing":       ("np",     ["/status"]),
    "downloads":         ("act",    ["/downloads"]),
    "queue":             ("act",    ["/queue"]),
    "history":           ("act",    ["/history"]),
    "torrents":          ("act",    ["/torrents"]),
    "assistant (AI)":    ("ai",     ["/ai/send"]),
    "logs (system)":     ("logs",   ["/logs"]),
    "anime":             ("anime",  ["/anime/search"]),
    "podcasts":          ("podcasts", ["/podcasts/search"]),
    "music":             ("music",  ["/music/search"]),
    "radio":             ("radio",  ["/radio/search"]),
    "comics":            ("comics", ["/comics/search"]),
    "novels":            ("novels", ["/novels/search"]),
    "drama":             ("drama",  ["/drama"]),
    "visual novels":     ("vndb",   ["/vndb/search"]),
    "audiobooks":        ("abs",    ["/abs/login"]),
    "opds":              ("opds",   ["/opds/connect"]),
    "plex":              ("plex",   ["/plex/connect"]),
    "jellyfin":          ("jf",     ["/jellyfin/login"]),
    "rss":               ("rss",    ["/rss"]),
    "youtube":           ("yt",     ["/youtube/search"]),
    "live tv":           ("tv",     ["/livetv"]),
    "coming-up calendar": (None,    ["/calendar"]),
    "source catalog install": ("setup", ["/source/catalog", "/source/add"]),
    # /api/auth/* and /api/access/* are dispatched by PREFIX, then matched on
    # the sub-path — so they never appear as `api_path, "/…"` literals. Match
    # the prefix plus one sub-route each.
    "account auth":      ("setup", ['"/api/auth/"', 'sub, "login"']),
    # Shipped in the Access page (Setup › Access).
    "web access control": ("setup", ['"/api/access/"', 'sub, "password"',
                                     'sub, "revoke-all"', 'sub, "bind"']),
    "tv latest episode": (None,    ["/tv/recent"]),
    # Closed 2026-08-03: desktop route .watching now has a web equivalent.
    "watching library": ("watch", ["/library"]),
    # Closed 2026-08-03: one registry-driven API + page covers these tabs.
    "playback settings": ("setup", ["/settings"]),
    "subtitle settings": ("setup", ["/settings"]),
    "network settings":  ("setup", ["/settings"]),
    # Closed 2026-08-04: the registry grew Storage / AI & Voice / Language.
    "storage settings":  ("setup", ["/settings"]),
    "ai & voice settings": ("setup", ["/settings"]),
    "language learning": ("setup", ["/settings"]),
    "home hub":          ("home",  ["/home"]),
    "plugins manager":   ("setup", ["/plugins"]),
    "watch party":       ("setup", ["/party"]),
}

# Desktop capabilities with no web equivalent yet. `why` is what a user loses.
GAPS = {
    "file associations": "Desktop Settings › File Types (default handler registration). Desktop-only by nature.",
}


def _web_pages(ui):
    return set(re.findall(r'data-page="([a-z0-9]+)"', ui))


def _api_routes(rm):
    return set(re.findall(r'api_path, "(/[a-z0-9/_-]+)"', rm))


@test("Desktop ⇄ web parity: covered capabilities stay covered", "Parity")
def test_parity_covered():
    ui = _src("web/index.html")
    rm = _src("src/services/remote.zig")
    pages, routes = _web_pages(ui), _api_routes(rm)

    broken = []
    for cap, (page, frags) in COVERED.items():
        if page and page not in pages:
            broken.append(f"{cap}: missing nav page '{page}'")
        for f in frags:
            # Most routes are `api_path, "/x"` literals. Prefix-dispatched
            # families and concat-built paths are given as raw source fragments,
            # so fall back to a substring check before declaring one missing.
            if f not in routes and f not in rm and f'"{f}' not in rm:
                broken.append(f"{cap}: missing API route {f}")
    if broken:
        return "fail", f"parity regression ({len(broken)}): " + "; ".join(broken[:6])
    return "pass", f"{len(COVERED)} desktop capabilities mirrored in the web UI ({len(pages)} nav pages)"


@test("Desktop ⇄ web parity: remaining gaps (tracked)", "Parity")
def test_parity_gaps():
    ui = _src("web/index.html")
    rm = _src("src/services/remote.zig")
    pages, routes = _web_pages(ui), _api_routes(rm)

    # A gap that has quietly been closed should be promoted into COVERED rather
    # than lingering here — flag that too, so the list can't rot.
    # Only consider entries still listed as gaps — a promoted one lives in
    # COVERED now and must not be reported forever.
    evidence = {
        "watching library": "watch" in pages or any("/library" in r for r in routes),
        "home hub":         "home" in pages or any("/foryou" in r for r in routes),
        "plugins manager":  "plugins" in pages,
    }
    closed = [g for g, found in evidence.items() if found and g in GAPS]

    total = len(COVERED) + len(GAPS)
    pct = round(100 * len(COVERED) / total)
    if closed:
        return "warn", (f"parity {pct}% ({len(COVERED)}/{total}) — these gaps look CLOSED, "
                        f"promote them into COVERED: {', '.join(closed)}")
    return "warn", (f"parity {pct}% ({len(COVERED)}/{total}) — {len(GAPS)} gaps remain: "
                    + ", ".join(sorted(GAPS)))
