"""Regression checks for the adaptive, route-aware web app shell.

The capability parity tests prove that pages exist. These checks prove the
pages remain discoverable: a bounded phone navigation, a grouped desktop
sidebar, URL history, and the keyboard/accessibility contract around the More
sheet.
"""

from .harness import *  # noqa: F401,F403
import re


@test("Web and remote boundaries stay modular", "Architecture")
def test_web_remote_module_boundaries():
    html = _src("web/index.html")
    remote = _src("src/services/remote.zig")
    web_modules = (
        "core.js", "now-playing.js", "catalog.js", "playback.js",
        "integrations.js", "media.js", "discovery.js", "boot.js",
    )
    backend_modules = (
        "remote_http.zig", "remote_static.zig", "remote_status.zig",
        "remote_library_api.zig", "remote_transfer_api.zig",
    )
    checks = {
        "top router stays below 5k lines": len(remote.splitlines()) < 5000,
        "HTML is markup-sized": len(html.splitlines()) < 1000,
        "feature bundles are bounded": all(
            0 < len(_src(f"web/js/{name}").splitlines()) < 1000 for name in web_modules
        ),
        "feature bundles are explicit": all(f'/js/{name}' in html for name in web_modules),
        "styles are external": '/styles/app.css' in html and '<style>' not in html,
        "no inline application script": re.search(r'<script(?![^>]*src=)', html) is None,
        "backend feature modules are bounded": all(
            0 < len(_src(f"src/services/{name}").splitlines()) < 500 for name in backend_modules
        ),
        "router delegates": all(name in remote for name in (
            "remote_static.zig", "remote_status.zig", "remote_library_api.zig", "remote_transfer_api.zig",
        )),
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "module boundary regression: " + ", ".join(missing)
    return "pass", "HTML  <1k, JS modules <1k, router <5k, feature APIs <500 lines"


@test("Now Playing exposes rich state without leaking artwork credentials", "Web UI")
def test_web_now_playing_context_contract():
    ui = _web_app()
    remote = _remote_api()
    stream = _src("src/services/remote_stream.zig")
    status = _src("src/services/remote_status.zig")
    worker = _src("web/service-worker.js")
    state_order = [ui.find(token) for token in (
        "d.recovering ? 'Recovering'", "d.loading ? 'Loading'",
        "d.buffering ? 'Buffering'", "d.paused ? 'Paused'",
    )]
    checks = {
        "rich semantic hero": all(f'id="{name}"' in ui for name in (
            "np-art", "np-title", "np-sub", "np-meta", "np-presence", "np-overview",
        )),
        "stable status fields": all(f'\\"{field}\\"' in status for field in (
            "active", "loading", "buffering", "recovering", "subtitle", "overview",
            "kind", "year", "rating", "has_art", "art_key", "casting", "party_role", "party_peers",
        )),
        "state priority is explicit": all(index >= 0 for index in state_order)
            and state_order == sorted(state_order),
        "presence is rendered": "Watch party host" in ui and "Joined watch party" in ui
            and "Casting" in ui,
        "same-origin artwork only": "/now-playing/art?k=${encodeURIComponent(key)}" in ui
            and '\\"art_url\\"' not in status,
        "authenticated artwork route": '"/now-playing/art"' in remote
            and "handleNowPlayingArt" in stream and "players_mutex.lock()" in stream,
        "native bounded image fetch": 'core/http.zig").fetch' in stream
            and ".max_response = buf.len" in stream and 'curl' not in _between(stream, "fn serveProxied", "fn sendImage"),
        "private art bypasses PWA cache": "'/now-playing/art'" in worker,
        "status lock released before write": remote.index("players_mutex.lock();\n                const body")
            < remote.index("players_mutex.unlock();\n                const ev"),
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "Now Playing contract incomplete: " + ", ".join(missing)
    return "pass", "rich metadata + ordered playback state + live presence + credential-safe art"


@test("Web shell adapts without hiding parity pages", "Web UI")
def test_adaptive_web_shell():
    ui = _web_app()
    primary = _between(ui, '<div class="nav-section nav-primary">', '<button type="button" id="nav-more"')
    pages = re.findall(r'data-page="([a-z0-9]+)"', ui)
    checks = {
        "one route button per page": len(pages) == 24 and len(set(pages)) == 24,
        "bounded phone bar": set(re.findall(r'data-page="([a-z0-9]+)"', primary))
            == {"home", "browse", "search", "np"},
        "phone More sheet": 'id="nav-more"' in ui and 'id="nav-more-panel"' in ui
            and 'id="nav-close"' in ui and "function openMore()" in ui,
        "grouped capability families": all(
            label in ui for label in ("My Opal", "Video", "Audio", "Reading", "Servers &amp; System")
        ),
        "wide sidebar breakpoint": "@media (min-width:900px)" in ui
            and "width:var(--nav-w)" in ui and "border-right:1px solid var(--border)" in ui,
        "wide content canvas": "main{padding:14px 32px 40px;max-width:1360px}" in ui,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "adaptive web shell incomplete: " + ", ".join(missing)
    return "pass", "24 pages: 4-item phone bar + grouped More sheet / desktop sidebar"


@test("Web pages are deep-linked and keyboard reachable", "Web UI")
def test_routed_accessible_web_shell():
    ui = _web_app()
    checks = {
        "home is the first useful view": 'class="page on" id="page-home"' in ui
            and 'data-page="home" class="on"' in ui,
        "hash routes + browser history": all(
            frag in ui for frag in ("location.hash.slice(1)", "history[method]", "popstate", "hashchange")
        ),
        "current page semantics": "aria-current" in ui and 'aria-label="Main navigation"' in ui,
        "skip target": 'class="skip-link" href="#main-content"' in ui
            and 'id="main-content" tabindex="-1"' in ui,
        "More state is announced": 'aria-expanded="false"' in ui
            and 'aria-controls="nav-more-panel"' in ui and "navPanel.setAttribute('aria-hidden'" in ui,
        "Escape + focus trap": "e.key === 'Escape'" in ui and "e.key === 'Tab'" in ui
            and "navReturnFocus" in ui,
        "search shortcut": "e.key === '/'" in ui and "e.key.toLowerCase() === 'k'" in ui,
        "TV directional focus": "function moveSpatialFocus(key)" in ui
            and "spatialCandidates()" in ui and "scrollIntoView({block:'nearest'" in ui,
        "overlay back behavior": all(
            token in ui for token in ("$('show-back').click()", "$('player-close').click()", "$('yt-embed-close').click()")
        ),
        "visible keyboard focus": ":focus-visible" in ui and "outline:2px solid var(--accent)" in ui,
        "reduced motion": "@media (prefers-reduced-motion:reduce)" in ui,
        "dark native controls": "color-scheme:dark" in ui,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "routed/accessibility shell incomplete: " + ", ".join(missing)
    return "pass", "hash history + focus-safe More sheet + skip/search keyboard paths"


@test("Web exposes recommendations and living-room playback controls", "Web UI")
def test_web_recommendations_and_cast_controls():
    ui = _web_app()
    remote = _remote_api()
    checks = {
        "For You rail": 'id="home-recs"' in ui
            and "function loadRecommendations(refresh)" in ui
            and "api('/recommendations'" in ui,
        "recommendation refresh + play path": "?refresh=1" in ui
            and "prefillSearch(normQuery(r.title))" in ui,
        "async recommendation semantics": 'id="home-recs-status"' in ui
            and "aria-busy" in ui and "role=\"status\"" in ui,
        "cast device picker": 'id="cast-panel"' in ui
            and "function loadCastDevices()" in ui
            and "aria-pressed" in ui,
        "cast lifecycle": all(
            endpoint in ui for endpoint in ("/cast/devices", "/cast/scan", "/cast/start?idx=", "/cast/stop")
        ),
        "picture transforms": 'id="b-rotate"' in ui and 'id="b-flip"' in ui
            and "api('/rotate')" in ui and "api('/flip')" in ui,
        "server routes match": all(
            f'\"{endpoint}\"' in remote
            for endpoint in ("/recommendations", "/cast/devices", "/cast/scan", "/cast/start", "/cast/stop", "/rotate", "/flip")
        ),
        "toast announcements": "t.setAttribute('role', 'status')" in ui
            and "t.setAttribute('aria-live', 'polite')" in ui,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "web playback/discovery controls incomplete: " + ", ".join(missing)
    return "pass", "For You + cast device lifecycle + rotate/flip use the real remote API"


@test("Web search, open, queue, and watch party use full workflow APIs", "Web UI")
def test_web_discovery_and_party_workflows():
    ui = _web_app()
    remote = _remote_api()
    checks = {
        "merged search": "function renderUnifiedResults(" in ui
            and "api('/unified_search?q='" in ui and "api('/unified_search')" in ui,
        "source actions": all(
            action in ui for action in ("magnet", "yt_play", "tmdb_detail", "anime_detail", "jf_browse", "jf_play")
        ),
        "stream drill-down": "function runStreamSearch(" in ui
            and "function renderTorrentResults(" in ui,
        "open URL form": 'id="open-media-form"' in ui and "function remoteOpenUrl(" in ui
            and "api('/open?url='" in ui,
        "queue URL workflow": 'id="open-queue"' in ui and "function queueMedia(" in ui
            and "api('/ingest?type=queue&url='" in ui,
        "party status + chat": 'id="party-log"' in ui and 'id="party-chat-form"' in ui
            and "api('/party/status')" in ui and "'/party/chat?msg='" in ui,
        "party lifecycle": all(f"partyDo('{action}')" in ui for action in ("host", "leave"))
            and "partyDo('join'" in ui,
        "server contracts": all(
            f'\"{endpoint}\"' in remote
            for endpoint in ("/unified_search", "/open", "/ingest", "/party/status", "/party/chat", "/party/host", "/party/join", "/party/leave")
        ),
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "web discovery/watch-party workflows incomplete: " + ", ".join(missing)
    return "pass", "merged search actions + arbitrary open/queue + live watch-party chat"


@test("Web parity is planned and measured at operation depth", "Parity")
def test_operation_level_web_parity_plan():
    plan = _src("docs/WEB-UI-PARITY.md")
    checks = {
        "first-class goal": "first-class Opal client" in plan,
        "five maturity levels": all(f"| {level} |" in plan for level in range(5)),
        "honest baseline": "page-count test is only" in plan,
        "player operations": all(
            item in plan for item in ("Exact audio and subtitle", "Chapters", "Playback speed", "Screenshot", "A/B loop")
        ),
        "library operations": "Library scan/import" in plan and "Collections, playlists" in plan,
        "integration operations": "Complete Plex/Jellyfin" in plan and "Download/torrent pause" in plan,
        "e2e completion gate": "cannot reach level 4 through string matching alone" in plan,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "operation-level parity plan incomplete: " + ", ".join(missing)
    return "pass", "5-level operation contract across player, library, sources, and web quality"


@test("Web player uses one typed snapshot and bounded action contract", "Web UI")
def test_typed_full_web_player_contract():
    ui = _web_app()
    remote = _remote_api()
    pure = _src("src/services/player_api_pure.zig")
    build = _src("build.zig")
    checks = {
        "deep snapshot": "fn apiPlayerSnapshot(" in remote
            and "writePlayerChapters(" in remote and "writePlayerTracks(" in remote
            and "writePlayerAudioDevices(" in remote,
        "single mutation route": 'api_path, "/player/action"' in remote
            and "player_api.parse(action_name, value)" in remote,
        "POST-only mutations": 'requireMethod(stream, method, "POST")' in remote
            and "apiMutation('/player/action?'" in ui,
        "no raw command input": "browser input is never interpolated into an mpv command" in remote
            and "allowlist" in pure,
        "finite bounded values": "std.math.isFinite(parsed)" in pure
            and "parsed < min or parsed > max" in pure,
        "track/aspect/device validation": all(
            token in pure for token in ("audio-track", "subtitle-track", "16:9", "utf8ValidateSlice")
        ),
        "complete player deck": all(
            token in ui for token in (
                'id="b-player-tools"', "tool-speed", "tool-chapter", "tool-audio",
                "tool-subtitle", "tool-device", "tool-picture", "tool-eq", "tool-repeat", "tool-shuffle",
                "subtitle-delay", "playlist-next", "screenshot", "loop-a", "clip-export",
            )
        ),
        "advanced transforms": all(
            token in ui for token in ("tool-zoom", "tool-pan-x", "tool-pan-y", "tool-brightness", "tool-contrast", "tool-saturation", "tool-gamma")
        ),
        "pure tests in build gate": "test_player_api_pure" in build
            and 'src/services/player_api_pure.zig' in build,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "typed full web-player contract incomplete: " + ", ".join(missing)
    return "pass", "one typed seam covers tracks, chapters, speed, repeat/shuffle, AV, loops, capture"


@test("Web queue supports the full native management workflow", "Web UI")
def test_web_queue_management_contract():
    ui = _web_app()
    remote = _remote_api()
    queue = _src("src/services/queue.zig")
    checks = {
        "rich queue snapshot": "fn apiQueueSnapshot(" in remote
            and all(f'\\"{field}\\"' in remote for field in ("played", "duration", "source", "url")),
        "one queue action route": 'api_path, "/queue/action"' in remote
            and "fn apiQueueAction(" in remote,
        "POST-only mutations": 'requireMethod(stream, method, "POST")' in remote
            and "apiMutation('/queue/action?' + params)" in ui,
        "typed bounded action set": "pub const Action = enum" in queue
            and all(action in queue for action in ('@"clear-played"', '@"move-up"', '@"move-down"', "remove", "play"))
            and "std.meta.stringToEnum(q.Action, action_name)" in remote,
        "native behavior reused": "pub fn playQueueIndex(" in queue
            and "pub fn removeQueueIndex(" in queue
            and "playQueueItem(&queue_items[idx])" in queue and "q.apply(action, idx)" in remote,
        "complete management deck": all(
            token in ui for token in (
                'id="queue-clear-played"', 'id="queue-clear"',
                'data-action="play"', 'data-action="move-up"',
                'data-action="move-down"', 'data-action="remove"',
            )
        ),
        "destructive confirmation": "Clear every item from the queue?" in ui
            and "params.set('confirm', '1')" in ui and "clear requires confirm=1" in remote,
        "accessible live state": 'id="queue-status"' in ui
            and 'aria-live="polite"' in ui and 'aria-label="Move queue item ${idx + 1} up"' in ui,
        "one delegated client handler": "async function changeQueue(action, idx)" in ui
            and "button[data-action]" in ui,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "web queue management incomplete: " + ", ".join(missing)
    return "pass", "snapshot + POST play/remove/reorder/clear share the native queue implementation"


@test("Web can operate direct downloads and torrents", "Web UI")
def test_web_transfer_management_contract():
    ui = _web_app()
    remote = _remote_api()
    engine = _src("src/services/download_engine.zig")
    transfers = _src("src/services/transfers.zig")
    checks = {
        "typed direct-download seam": "pub const Action = enum" in engine
            and "pub fn apply(" in engine and "engine.apply(idx, token, action)" in remote,
        "stale-action token": all(token in remote for token in ('\\"idx\\"', '\\"token\\"', "download changed; refresh")),
        "POST-only action routes": all(
            any(f'{name}, "{path}"' in remote for name in ("api_path", "path"))
            for path in ("/downloads/action", "/torrents/action")
        ) and "apiMutation(`/${kind === 'torrent' ? 'torrents' : 'downloads'}/action?${params}`)" in ui,
        "native torrent adapters": all(
            name in transfers for name in ("setTorrentPaused", "setTorrentFilePriority", "removeTorrentById")
        ) and "pub const TorrentAction = enum" in transfers
            and "transfers.applyTorrentAction(id, action, file_idx, priority)" in remote,
        "direct download state": 'id="download-jobs"' in ui
            and all(field in remote for field in ("job.status", "job.rate", "job.etaSecs()", "job.errSlice()")),
        "one delegated client handler": "async function changeTransfer(button)" in ui
            and "button[data-transfer]" in ui,
        "full transfer controls": all(
            token in ui for token in ("'pause'", "'resume'", "'cancel'", "'dismiss'", 'data-action="priority"')
        ),
        "confirmed destructive operations": "params.set('confirm', '1')" in ui
            and "requires confirm=1" in remote and "cancel requires confirm=1" in remote,
        "all player loads use POST": "api('/load?url='" not in ui and "apiMutation('/load?url='" in ui,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "web transfer management incomplete: " + ", ".join(missing)
    return "pass", "typed download actions + live torrent/file controls use one delegated web handler"


@test("Web library owns status and episode progress", "Web UI")
def test_web_library_management_contract():
    ui = _web_app()
    remote = _remote_api()
    library = _src("src/services/tv_library.zig")
    pure = _src("src/services/tv_pure.zig")
    checks = {
        "rich shared snapshot": "fn library(" in remote
            and all(field in remote for field in ('\\"user_status\\"', '\\"syncing\\"', '\\"has_next\\"')),
        "read and mutation routes": all(
            f'path, "{path}"' in remote
            for path in ("/library", "/library/watched", "/library/action")
        ),
        "POST-only command endpoint": 'requireMethod(stream, method, "POST")' in remote
            and "apiMutation('/library/action?'" in ui,
        "one typed domain command": "pub const Command = union(Action)" in library
            and "pub fn apply(command: Command)" in library
            and "std.meta.stringToEnum(service.Action" in remote,
        "bounded episode identities": "pub fn validUserEpisode" in pure
            and "MAX_EPISODES_PER_SEASON" in pure and "tp.validUserEpisode" in library,
        "status and type filters": 'id="watch-filters"' in ui
            and 'id="watch-kind-filters"' in ui and 'data-f="dropped"' in ui,
        "library controls": all(
            token in ui for token in (
                'id="watch-refresh"', 'data-action="status"', 'data-action="watched"',
                'data-action="find-next"', 'data-action="remove"',
            )
        ),
        "episode watched/unwatched flow": "api('/library/watched?kind=tv&id='" in ui
            and "aria-pressed" in ui and "&value=' + button.dataset.value" in ui,
        "confirmed non-destructive removal": "Watch history is kept." in ui
            and "&confirm=1" in ui and "remove requires confirm=1" in remote,
        "delegated row handlers": "async function changeLibrary(params)" in ui
            and "$('watch-list').addEventListener('change'" in ui
            and "$('watch-list').addEventListener('click'" in ui,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "web library management incomplete: " + ", ".join(missing)
    return "pass", "typed status/watch commands + filters + show episode toggles share the native model"


@test("Web shell is installable without caching private media", "Web UI")
def test_web_pwa_contract():
    ui = _web_app()
    remote = _remote_api()
    manifest = _src("web/manifest.webmanifest")
    worker = _src("web/service-worker.js")
    mac_pack = _src("scripts/build-app.sh")
    nfpm = _src("packaging/nfpm.yaml")
    release = _src(".github/workflows/release.yml")
    checks = {
        "manifest wired": 'rel="manifest" href="/manifest.webmanifest"' in ui
            and '"display": "standalone"' in manifest and '"start_url": "/#home"' in manifest,
        "install affordance": 'id="pwa-install"' in ui and "beforeinstallprompt" in ui
            and "installPrompt.prompt()" in ui,
        "service worker registration": "navigator.serviceWorker.register('/service-worker.js')" in ui
            and "window.isSecureContext" in ui,
        "public shell cache only": "const SHELL" in worker and "'/index.html'" in worker
            and "url.pathname.startsWith('/api/')" in worker
            and all(path in worker for path in ("'/events'", "'/stream'", "'/transcode'", "'/poster'", "'/vtt'")),
        "offline fallback": "request.mode === 'navigate'" in worker
            and "Opal is offline" in worker and "caches.match('/index.html')" in worker,
        "reconnect state": 'id="network-status"' in ui and "setNetworkState('reconnecting')" in ui
            and "window.addEventListener('offline'" in ui,
        "static server routes": all(
            f'.route = "{path}"' in remote for path in ("/manifest.webmanifest", "/service-worker.js", "/icon.svg")
        ) and 'remote_static.zig").serve(stream, path)' in remote,
        "release assets stay together": 'cp -R "$ROOT/web/."' in mac_pack
            and "- src: web" in nfpm and release.count("cp -R web/.") >= 3,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "web PWA contract incomplete: " + ", ".join(missing)
    return "pass", "installable shell caches public assets only and reports offline/reconnect state"


@test("Web owns the source-plugin catalog lifecycle", "Web UI")
def test_web_plugin_lifecycle_contract():
    ui = _web_app()
    remote = _remote_api()
    repo = _src("src/services/plugin_repo.zig")
    native = _src("src/services/plugins.zig")
    checks = {
        "immutable catalog snapshots": "pub fn snapshotCopy(" in repo
            and "catalog_mutex" in repo and "snapshotCopy(&source_catalog)" in native
            and "repo.snapshotCopy(catalog)" in remote,
        "stable validated ids": "Operate on a stable source id" in repo
            and "copyId(" in repo and "pure.validId(val.string)" in repo
            and "findPluginLocked(id)" in repo,
        "typed lifecycle command": "pub const Action = enum { refresh, install, uninstall, update }" in repo
            and "pub fn apply(action: Action" in repo
            and "std.meta.stringToEnum(repo.Action, action_name)" in remote,
        "accurate catalog state": 'w.writeAll("{\\"sources\\":[")' in remote
            and '\\"installed\\":{s}' in remote and 'd.sources' in ui,
        "method and confirmation boundary": 'apiPlugins(stream, method, query, body)' in remote
            and 'requireMethod(stream, method, "GET")' in remote
            and "uninstall requires confirm=1" in remote
            and "params.set('confirm', '1')" in ui,
        "complete catalog controls": all(
            token in ui for token in (
                'id="plug-filter"', 'id="plug-installed"', 'id="plug-refresh"',
                'id="plug-update"', "changePlugin('refresh')", "changePlugin('update')",
            )
        ),
        "install and remove actions": 'data-action="${source.installed ? \'uninstall\' : \'install\'}"' in ui
            and "async function changePlugin(action, id)" in ui
            and "button[data-action][data-id]" in ui,
        "bounded refresh polling": "pluginPollRemaining = 12" in ui
            and "pluginPollRemaining--" in ui and "setTimeout(loadPlugins, 1200)" in ui,
        "credentials stay write-only": "has_debrid_key" in remote
            and "repo.debrid_key_buf[0.." not in remote,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "web source-plugin lifecycle incomplete: " + ", ".join(missing)
    return "pass", "stable-id source catalog supports refresh/filter/install/update/remove with real server state"
