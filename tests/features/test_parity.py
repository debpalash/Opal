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
    # Closed 2026-08-04. Debrid already had inputs on the Setup page but its
    # writes were never persisted (saveDebrid/saveToken had no caller on the API
    # path), so it only looked covered until a restart.
    "debrid link":       ("setup", ["/plugins"]),
    "trakt sync":        ("setup", ["/trakt"]),
    "suwayomi config":   ("setup", ["/suwayomi"]),
    # Closed 2026-08-04: theme / UI scale / personalized suggestions joined the
    # settings registry. The TMDB and OMDb API keys stay desktop-only — registry
    # values ride in a query string and nothing secret may.
    "general settings":  ("setup", ["/settings"]),
    "about":             ("setup", ["/about"]),
    # Closed 2026-08-04, the last two.
    "live tv settings":  ("setup", ["/livetv/sources"]),
    "web ui settings":   ("setup", ["/webui"]),
}

# Desktop capabilities with no web equivalent yet. `why` is what a user loses.
#
# Audited 2026-08-04 against the source enums below. Seven of these were not in
# either list before — the two lists were hand-maintained and nothing checked
# them against router.zig / state.zig, so a desktop tab could exist with no web
# equivalent and no entry here, and parity still read 98%. It was really 83%.
GAPS = {}

# Desktop capabilities a browser cannot have, by nature — counted separately so
# the parity percentage measures *closable* distance rather than being pinned
# below 100% forever by something no amount of work can close.
NOT_APPLICABLE = {
    "file associations": "Registering the OS default handler for media files. A web page cannot do this.",
    # Deliberately never exposed, not merely unbuilt.
    "scripts settings": "Settings › Scripts configures which local executables Opal runs. Exposing that to a remote session is a remote-code-execution surface, so it stays desktop-only.",
}

# Every desktop navigation surface, read out of the source enums, mapped to the
# capability name it is classified under. The completeness test below fails if
# an enum variant is missing here, or if its name lands in none of the three
# buckets — which is exactly the rot that hid the seven gaps above.
DESKTOP_SURFACES = {
    # src/core/router.zig :: Route
    "Route": {
        "home": "home hub", "search": "search", "browse": "browse (TMDB)",
        "watching": "watching library", "downloads": "downloads", "queue": "queue",
        "history": "history", "player": "now playing", "assistant": "assistant (AI)",
        "settings": "playback settings", "plugins": "plugins manager",
        "system": "logs (system)",
    },
    # src/core/state.zig :: SettingsTab
    "SettingsTab": {
        "General": "general settings", "Playback": "playback settings",
        "Network": "network settings", "Subtitles": "subtitle settings",
        "Storage": "storage settings", "WebUi": "web ui settings",
        "Scripts": "scripts settings", "AI": "ai & voice settings",
        "LangLearn": "language learning", "FileAssoc": "file associations",
        "LiveTv": "live tv settings", "About": "about",
    },
    # src/core/router.zig :: PluginTab
    "PluginTab": {
        "sources": "source catalog install", "suwayomi": "suwayomi config",
        "debrid": "debrid link", "trakt": "trakt sync", "content": "plugins manager",
    },
}


def _web_pages(ui):
    return set(re.findall(r'data-page="([a-z0-9]+)"', ui))


def _api_routes(rm):
    return set(re.findall(r'api_path, "(/[a-z0-9/_-]+)"', rm))


@test("Desktop ⇄ web parity: covered capabilities stay covered", "Parity")
def test_parity_covered():
    ui = _web_app()
    rm = _remote_api()
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
    ui = _web_app()
    rm = _remote_api()
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

    # N/A items are excluded from the denominator: parity measures closable
    # distance, and pinning the metric below 100% with something unclosable
    # makes it useless as a target.
    total = len(COVERED) + len(GAPS)
    pct = round(100 * len(COVERED) / total)
    if closed:
        return "warn", (f"parity {pct}% ({len(COVERED)}/{total}) — these gaps look CLOSED, "
                        f"promote them into COVERED: {', '.join(closed)}")
    if not GAPS:
        # Reached 2026-08-04. A warn here would be permanent noise; the covered
        # test above is what stops any of this regressing, and the completeness
        # test is what stops a NEW desktop surface landing unclassified.
        return "pass", (f"parity {pct}% ({len(COVERED)}/{total}) — no gaps; "
                        f"{len(NOT_APPLICABLE)} capabilities are desktop-only by nature")
    return "warn", (f"parity {pct}% ({len(COVERED)}/{total}) — {len(GAPS)} gaps remain: "
                    + ", ".join(sorted(GAPS)))


def _enum_variants(src, name):
    """Variant names of `pub const <name> = enum {...}` — one-line or block."""
    m = re.search(r"pub const " + name + r" = enum \{(.*?)\}", src, re.S)
    if not m:
        return []
    body = re.sub(r"//[^\n]*", "", m.group(1))          # strip doc/line comments
    return [v.strip() for v in body.split(",") if v.strip()]


@test("Desktop ⇄ web parity: every desktop surface is classified", "Parity")
def test_parity_completeness():
    # The guard the parity metric was missing. COVERED/GAPS are hand-written, so
    # before this a new desktop tab could ship with no web equivalent and no
    # entry in either list, leaving the percentage untouched. Audited 2026-08-04:
    # seven surfaces were unclassified that way and the real figure was 83%, not
    # 98%. Deriving the desktop side from the enums is what makes the number mean
    # something.
    router = _src("src/core/router.zig")
    state = _src("src/core/state.zig")
    known = set(COVERED) | set(GAPS) | set(NOT_APPLICABLE)

    found = {
        "Route": _enum_variants(router, "Route"),
        "PluginTab": _enum_variants(router, "PluginTab"),
        "SettingsTab": _enum_variants(state, "SettingsTab"),
    }

    problems = []
    for enum_name, variants in found.items():
        if not variants:
            problems.append(f"{enum_name}: could not parse the enum from source")
            continue
        mapped = DESKTOP_SURFACES.get(enum_name, {})
        for v in variants:
            if v not in mapped:
                problems.append(f"{enum_name}.{v} is unclassified — add it to DESKTOP_SURFACES")
            elif mapped[v] not in known:
                problems.append(f"{enum_name}.{v} → '{mapped[v]}' is in no bucket")
    if problems:
        return "fail", f"unclassified desktop surfaces ({len(problems)}): " + "; ".join(problems[:6])

    n = sum(len(v) for v in found.values())
    return "pass", f"all {n} desktop surfaces across 3 enums are classified"


@test("Web API: plugin credentials post in a body, and persist", "Parity")
def test_plugin_credentials():
    # Two defects behind the "debrid link" gap, both invisible from the UI:
    #
    # 1. The debrid key and the GitHub token were sent as query parameters, the
    #    one place a secret ends up in a server log or a browser history.
    #    credParam() reads the body first, so handleApi now threads it through.
    # 2. Neither was ever persisted. None of these live in config.tsv, so
    #    markConfigDirty() did nothing for them — saveDebrid() was called only
    #    from the desktop UI and saveToken() had no caller anywhere. A key
    #    entered from the web UI survived until the next restart and no further.
    rm = _remote_api()
    ui = _web_app()
    checks = {
        "handleApi receives the request":
            "fn handleApi(stream: std.Io.net.Stream, api_path: []const u8, query: []const u8, request: []const u8)" in rm,
        "body extracted for credential routes": "const body = requestBody(request);" in rm,
        "apiPlugins reads the body first": 'credParam(body, query, "key"' in rm,
        "debrid writes persist": "repo.saveDebrid()" in rm,
        "token writes persist": "repo.saveToken()" in rm,
        "web UI posts secrets in a body":
            "'key=' + encodeURIComponent(k) + '&value=' + encodeURIComponent(v)" in ui,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "missing: " + ", ".join(bad)
    return "pass", "plugin credentials travel in the POST body and are written to disk"


@test("Web API: trakt / suwayomi / about routes are read-safe", "Parity")
def test_new_plugin_routes():
    # Each of these closes a parity gap, and each withholds something on
    # purpose — the pattern the /plugins GET already followed for the debrid key.
    rm = _remote_api()
    ui = _web_app()
    checks = {
        "trakt route": 'api_path, "/trakt"' in rm and "fn apiTrakt(" in rm,
        "suwayomi route": 'api_path, "/suwayomi"' in rm and "fn apiSuwayomi(" in rm,
        "about route": 'api_path, "/about"' in rm,
        # The Trakt access token must never leave the machine: device auth means
        # the browser only ever needs the short activation code.
        "trakt withholds the access token":
            "has_client_id" in rm and "access_token\\\":" not in rm,
        # An update is a software install; a remote session may ask for a check
        # but must not trigger the download.
        "about does not expose the downloader":
            "downloadAndOpenAsync" not in rm,
        "web UI has all three cards":
            'id="trakt-hint"' in ui and 'id="suwa-hint"' in ui and 'id="about-hint"' in ui,
        "web UI loads them on the setup page":
            "loadTrakt();" in ui and "loadSuwayomi();" in ui and "loadAbout();" in ui,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "missing: " + ", ".join(bad)
    return "pass", "trakt/suwayomi/about exposed, tokens and the updater withheld"


@test("Web API: live tv sources + web ui kill switch", "Parity")
def test_livetv_and_webui_routes():
    # The last two gaps. Both write, so both need a guard the others did not:
    # the source list may only name entries from the compiled-in SOURCES table,
    # and turning the web UI off ends the caller's own session.
    rm = _remote_api()
    ui = _web_app()
    checks = {
        "livetv sources route": 'api_path, "/livetv/sources"' in rm and "fn apiLiveTvSources(" in rm,
        # Without this an arbitrary id would be written straight into
        # source_config by a caller who picked the name.
        "source ids validated against SOURCES": "sources.byId(id) == null" in rm,
        "custom playlist requires http(s)":
            'std.mem.startsWith(u8, url, "http://")' in rm and 'url must be http(s)' in rm,
        "webui route": 'api_path, "/webui"' in rm,
        "kill switch needs confirm": '"confirm"' in rm and "confirm=1" in rm,
        # stop() tears down the listener the reply is being written to, so the
        # order matters: answer, then stop.
        "webui answers before stopping":
            'stopping' in rm and rm.index('stopping') < rm.index("            stop();"),
        "web UI has both cards": 'id="ltv-list"' in ui and 'id="webui-off"' in ui,
        "web UI warns before self-disconnect": "lose its connection" in ui,
        # The source rows are built from server data — build them as text nodes.
        "source rows are not built with innerHTML":
            "label.textContent = s.name" in ui,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "missing: " + ", ".join(bad)
    return "pass", "live tv sources validated against the table; kill switch confirm-gated"


@test("Web UI: the source catalog never truncates silently", "Parity")
def test_source_catalog_paging():
    # It rendered `.slice(0, 40)` of 306 sources and appended "N shown" ONLY when
    # a filter was active. Unfiltered you saw 40 rows with nothing saying they
    # were a subset, and the other 266 were unreachable unless you guessed a
    # name. It also made Setup ~12,000px tall, pushing every card below it out of
    # reach. The rule in this repo is that a bounded view states its bound.
    ui = _web_app()
    checks = {
        "catalog no longer hard-slices": "s.name || '').toLowerCase().includes(q)).slice(0, 40)" not in ui,
        # The downloads list had the identical bug — first 40 of however many,
        # with nothing saying so, so a 41st download did not exist to the page.
        "downloads states its cap": "more not shown" in ui,
        "pages through the catalog": "SRC_PAGE" in ui and "srcShown += SRC_PAGE" in ui,
        # The unfiltered branch must carry the count too — that was the bug.
        "states the bound when unfiltered": "sources in the catalog · showing" in ui,
        "states the bound when filtered": "· showing ${rows.length}" in ui,
        "remainder is reachable": "Show ${Math.min(SRC_PAGE" in ui,
        # Typing a filter must go back to page one, or the old offset hides
        # matches that are now near the top.
        "filter resets paging": "srcShown = SRC_PAGE; renderSources();" in ui,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "catalog paging: " + ", ".join(bad)
    return "pass", "catalog pages in chunks and always states how many of how many"


@test("Web API: /load routes a magnet to the torrent engine, not mpv", "Parity")
def test_load_magnet_routing():
    # Verified live on 2026-08-04: POSTing a magnet to /api/load logged
    #   [file] Cannot open file 'magnet:?xt=urn:btih:...': File name too long
    # because the handler called ap.load_file() unconditionally, so mpv treated
    # the whole URI as a path. Tapping ANY torrent result in the web UI did
    # nothing at all — and the parity route check could not see it, because the
    # route existed and answered {"ok":true} while doing nothing useful.
    #
    # The desktop has always branched on the scheme (ui/header.zig for
    # drop/paste, services/search.zig for a result click). The fix routes
    # through the same entry point rather than reimplementing player/session
    # setup, so the two cannot drift.
    rm = _remote_api()
    m = _re.search(r'api_path, "/load"\)\).*?\n    \} else if', rm, _re.S)
    if not m:
        return "fail", "remote.zig has no /load handler"
    body = m.group(0)
    if 'std.mem.startsWith(u8, decoded, "magnet:")' not in body:
        return "fail", "/load does not branch on the magnet: scheme — mpv will get the URI as a path"
    if "loadTorrentToPlayer(" not in body:
        return "fail", "/load does not reuse search.loadTorrentToPlayer — the desktop path"
    # The non-magnet branch must still exist; http(s) URLs go to the player.
    if "ap.load_file(" not in body:
        return "fail", "/load lost its plain-URL branch"
    return "pass", "/load sends magnets to the torrent engine and everything else to the player"


@test("Web UI: Setup folds into sections; torrent pct has resolution", "Parity")
def test_setup_folding_and_pct():
    # Both found by driving the running app on 2026-08-04.
    #
    # Setup had grown to ~10,500px — eleven sections stacked flat, so anything
    # past the third was a scroll expedition. Folding is applied in JS over the
    # existing markup rather than by restructuring it, and the nodes are MOVED
    # into a wrapper rather than recreated, so every id the loaders resolve by
    # getElementById still points at the same element.
    #
    # And /api/torrents reported pct as a u8. On a 129 MB torrent moving at
    # ~1 KB/s that read "0%" for the first 1.3 MB — about twenty minutes — while
    # pieces were genuinely landing, so a slow torrent and a dead one looked
    # identical. That distinction is the entire job of the number.
    ui = _web_app()
    rm = _remote_api()
    checks = {
        "fold helper exists": "function foldSetup(" in ui,
        "fold runs on the setup page": "foldSetup();" in ui,
        "fold styles present": ".fold-body.shut{display:none}" in ui,
        # Recreating nodes would break every getElementById the loaders use.
        "fold moves nodes rather than rebuilding": "body.append(el)" in ui and "innerHTML" not in
            ui[ui.index("function foldSetup("):ui.index("// ── Live TV sources")],
        "first section stays open": "if (!first) { head.classList.add('shut')" in ui,
        # Each handler must close over its OWN header/body pair. Hoisting them
        # out of the loop made every header toggle the LAST section — clicking
        # "Plugins" opened "Access". Only a real click in a browser showed it.
        "handlers close over their own section":
            "const head = el;" in ui and "myBody.classList.toggle('shut')" in ui,
        "pct keeps a decimal": '\\"pct\\":{d:.1}' in rm,
        "pct no longer truncated to u8": "@as(u8, @intFromFloat(std.math.clamp(progress" not in rm,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "missing: " + ", ".join(bad)
    return "pass", "Setup folds by section; torrent pct reports one decimal"
