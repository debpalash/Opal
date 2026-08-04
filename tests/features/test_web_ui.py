"""Headless web UI (web/index.html) — feature-parity wiring checks.

The web UI is a single-file vanilla-JS SPA served by remote.zig on :41595. It has
no build step and can't be unit-tested, so we assert each vertical is *wired*:
a nav tab (`data-page`), a `page-` section, and the API route(s) it calls. As new
verticals reach the web UI for headless/desktop parity, add a row to VERTICALS.

See tests/features/harness.py for the shared @test decorator + _src()."""
from .harness import *  # noqa: F401,F403
import os


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
    "ai":       ("ai",       "page-ai",       ["/ai/send", "/ai"]),
    "music":    ("music",    "page-music",    ["/music/search", "/music"]),
    "radio":    ("radio",    "page-radio",    ["/radio/search", "/radio"]),
    "comics":   ("comics",   "page-comics",   ["/comics/search", "/comics/results", "/comics/load"]),
    # /novels/{open,chapter} are built by concat ('/novels/' + kind), so the
    # literal "/novels/chapter" never appears — assert the base and the poll.
    "novels":   ("novels",   "page-novels",   ["/novels/search", "/novels/open", "/novels'"]),
    "drama":    ("drama",    "page-drama",    ["/drama", "/drama/play"]),
    "vndb":     ("vndb",     "page-vndb",     ["/vndb/search", "/vndb"]),
    "abs":      ("abs",      "page-abs",      ["/abs/login", "/abs"]),
    "opds":     ("opds",     "page-opds",     ["/opds/connect", "/opds"]),
    "plex":     ("plex",     "page-plex",     ["/plex/connect", "/plex"]),
    "logs":     ("logs",     "page-logs",     ["/logs?limit=", "/logs/clear"]),
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
        # Hosted still plays inline; the companion now honours the "Play here"
        # destination via dispatchPlay instead of always handing off to mpv.
        "watch both modes": "function openStreamUrl(" in ui
            and "if (HOSTED) return openStreamUrl(url, b.dataset.name);" in ui
            and "dispatchPlay(url, b.dataset.name" in ui
            and "/load?url=" in ui,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "Live TV incomplete: " + ", ".join(missing)
    return "pass", "Live TV: /api/livetv catalog paging + web tab (search, load-more, watch)"


@test("Web UI add-download + source catalog", "Web UI")
def test_web_ui_downloads_and_sources():
    ui = _src("web/index.html")
    rm = _src("src/services/remote.zig")
    checks = {
        # Activity: paste a URL or magnet. Magnets -> /load (torrent session),
        # plain URLs -> the segmented HTTP downloader.
        "add-download box": 'id="dl-url"' in ui and 'id="dl-go"' in ui,
        "magnet vs url routing": "/^magnet:/i.test(u)" in ui and "/download/url?url=" in ui
            and "'/load?url='" in ui,
        "download route exists": '"/download/url"' in rm,
        # Setup: browse + install from the bundled comic/novel source catalog.
        "source catalog ui": 'id="srcs-list"' in ui and "function loadSources(" in ui
            and "/source/catalog" in ui,
        "catalog filter": 'id="srcs-q"' in ui and "function renderSources(" in ui,
        "install wires source/add": "/source/add?framework=" in ui,
        "catalog routes exist": '"/source/catalog"' in rm and '"/source/add"' in rm,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "download/source UI incomplete: " + ", ".join(missing)
    return "pass", "Activity add-download (url+magnet) + Setup source catalog install"


@test("Web UI AI copilot tab + /api/ai route", "Web UI")
def test_web_ui_ai():
    ui = _src("web/index.html")
    rm = _src("src/services/remote.zig")
    checks = {
        # Server: async send + poll, mirroring the other verticals.
        "route dispatch": '"/ai"' in rm and "fn apiAi(" in rm,
        "send + clear": '"/ai/send"' in rm and '"/ai/clear"' in rm and "chat.sendMessage()" in rm,
        "transcript + phase": "chat.message_count" in rm and "phaseLabel(chat.phase)" in rm,
        # Playable picks the model resolved come back with the transcript.
        "playable results": "chat.chat_result_count" in rm and "chat_results[r]" in rm,
        # A 50-msg transcript can exceed 100KB — must not sit on the thread stack.
        "response heap-allocated": "alloc.alloc(u8, 192 * 1024)" in rm,
        # Web: tab, transcript, ask, results.
        "tab wired": 'data-page="ai"' in ui and 'id="page-ai"' in ui and "function loadAi(" in ui,
        "ask + poll": "function askAi(" in ui and "/ai/send?q=" in ui and "aiWatch" in ui,
        "renders transcript": "function renderAi(" in ui and 'class="msg' in ui,
        "watcher cleanup": "clearInterval(aiWatch)" in ui,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "AI tab incomplete: " + ", ".join(missing)
    return "pass", "AI copilot: /api/ai send+poll transcript, phase, playable picks + web tab"


@test("Web UI Music + Radio tabs and routes", "Web UI")
def test_web_ui_music_radio():
    ui = _src("web/index.html")
    rm = _src("src/services/remote.zig")
    checks = {
        # Routes: async search + poll + play-by-index, like the other verticals.
        "music route": "fn apiMusic(" in rm and '"/music/search"' in rm and '"/music/play"' in rm
            and "music.searchMusic(" in rm and "music.playSong(" in rm,
        "radio route": "fn apiRadio(" in rm and '"/radio/search"' in rm and '"/radio/play"' in rm
            and "radio.searchRadio(" in rm and "radio.playStation(" in rm,
        # GET seeds the once-per-session popular list.
        "radio seeds popular": "radio.loadPopularOnce()" in rm,
        # Direct stream URLs so a hosted browser can play them itself.
        "music exposes stream url": "s.play_url[0..s.play_url_len]" in rm,
        "radio prefers resolved url": "url_resolved_len > 0" in rm,
        # Big result arrays -> heap, not the spawned-thread stack.
        "responses heap-allocated": rm.count("alloc.alloc(u8, 96 * 1024)") >= 2,
        # Web tabs.
        "music tab": 'data-page="music"' in ui and 'id="page-music"' in ui and "function runMusic(" in ui,
        "radio tab": 'data-page="radio"' in ui and 'id="page-radio"' in ui and "function runRadio(" in ui,
        # Hosted plays the stream URL inline; the companion routes through the
        # playback destination (Play here vs desktop) rather than always mpv.
        "hosted vs companion play": "if (HOSTED && u) return openStreamUrl(u, t);" in ui
            and ui.count("dispatchPlay(u, t,") >= 2
            and "/music/play?idx=" in ui and "/radio/play?idx=" in ui,
        "watchers cleaned": "clearInterval(muWatch)" in ui and "clearInterval(raWatch)" in ui,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "music/radio incomplete: " + ", ".join(missing)
    return "pass", "Music + Radio: search/poll/play routes + tabs (hosted plays stream URL)"


@test("Header Web UI toggle button (start/stop + auto-open)", "Web UI")
def test_header_web_ui_button():
    hdr = _src("src/ui/header.zig")
    sh = _src("src/ui/shell.zig")
    rm = _src("src/services/remote.zig")
    pure = _src("src/services/remote_url_pure.zig")
    bz = _src("build.zig")
    checks = {
        "button defined": "pub fn renderWebUiButton() void" in hdr,
        # THE regression this test exists for: header.zig's renderHeader only
        # runs when page_shell_enabled is off. A button wired solely into that
        # legacy header is invisible in the default UI. It must be called from
        # shell.zig's nav cluster, which is what actually renders.
        "wired into the live page shell": "header.renderWebUiButton();" in sh,
        # Guarded: a missing call must report as this named check, not blow up
        # the whole test with a bare "substring not found".
        "shell cluster, not the overflow menu": (
            0 <= sh.find("header.renderWebUiButton();") < sh.find("fn renderOverflowItems()")
        ),
        "globe icon": "icons.tvg.lucide.globe" in hdr,
        # Same persisted switch as Settings > Web Remote, so the two stay in sync.
        "shares settings flag": "state.app.web_remote_enabled" in hdr and "state.markConfigDirty()" in hdr,
        "starts and stops": "remote.start()" in hdr and "remote.stop()" in hdr,
        # Opening the browser must wait for the bind, not just the spawn.
        "listening flag exists": "pub fn isListening() bool" in rm and "listening.store(true, .release)" in rm,
        "defers open until listening": "remote.isListening()" in hdr and "open_pending" in hdr,
        "bounded wait": "open_wait_frames" in hdr and "dvui.refresh(" in hdr,
        "opens a browser": "settings.openExternal(url)" in hdr,
        # URL/label logic lives in the tested pure module, not inline in the UI.
        "routes through pure module": "remote_url.webUiUrl(" in hdr and "remote_url.webUiTooltip(" in hdr,
        "pure url is loopback": '"http://127.0.0.1:{d}/"' in pure,
        "pure module tested": "test_remote_url_pure" in bz,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "header Web UI button incomplete: " + ", ".join(missing)
    return "pass", "Header globe toggle: start/stop web remote + opens 127.0.0.1:41595 once listening"


@test("Web UI Access page: password, sessions, token, bind", "Web UI")
def test_web_ui_access_page():
    ui = _src("web/index.html")
    rm = _src("src/services/remote.zig")
    st = _src("src/services/auth_store.zig")
    pure = _src("src/services/access_pure.zig")
    cfg = _src("src/core/config.zig")
    bz = _src("build.zig")
    checks = {
        # Routes exist and sit BEHIND the bearer gate — every one mutates auth
        # state, so reaching them unauthenticated would be the whole ballgame.
        "access routes": 'startsWith(u8, path, "/api/access/")' in rm and "fn handleAccess(" in rm,
        "gated after bearer check": (
            0 <= rm.find("if (!isAuthorized(presented))") < rm.find('startsWith(u8, path, "/api/access/")')
        ),
        "all five sub-routes": all(
            f'sub, "{s}"' in rm for s in ("status", "password", "revoke-all", "token", "token/rotate", "bind")
        ),
        # Store operations backing them.
        "store ops": all(
            f"pub fn {f}(" in st
            for f in ("userIdForSession", "usernameForId", "userIdByName", "setPassword",
                      "liveSessionCount", "revokeAllSessions")
        ),
        # Session callers must prove the old password; api.token callers are the
        # machine-local recovery path and may reset without it.
        "session proves current pw": "current password is incorrect" in rm,
        "token caller resets by name": "userIdByName(uname)" in rm,
        # A password change that left old logins alive would not revoke access.
        "pw change revokes others": (
            0 <= rm.find("setPassword(target_uid") < rm.find("revokeAllSessions(if (caller_uid == null)")
        ),
        # Rotation must not silently widen the 0600 token file.
        "rotate reuses persistToken": "fn persistToken() void" in rm and "persistToken();" in rm
            and "pub fn rotateToken() bool" in rm,
        # Bind: reply must be written BEFORE the listener is torn down.
        "bind replies before restart": (
            0 <= rm.find('"{{\\"ok\\":true,\\"bind\\"') < rm.find("applyBinding(mode, new_port)")
        ),
        "bind persisted": '"web_bind"' in cfg and '"web_port"' in cfg,
        # Decision logic lives in the tested pure module.
        "routes through pure module": all(
            f"access_pure.{f}" in rm
            for f in ("maskToken", "checkPasswordChange", "bindModeFromString", "parsePort")
        ),
        "pure module tested": "test_access_pure" in bz,
        # Web page: markup + handlers for each group.
        "access markup": all(
            f'id="{i}"' in ui
            for i in ("acc-pw-save", "acc-revoke", "acc-token-rotate", "acc-bind-save", "acc-port")
        ),
        "loads with setup page": "loadAccess();" in ui and "async function loadAccess(" in ui,
        "adapts to caller class": "accViaToken" in ui and "via_token" in ui,
        "warns when LAN-exposed": "acc-bind-warn" in ui and "Anyone on your network" in ui,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "Access page incomplete: " + ", ".join(missing)
    return "pass", "Access page: pw change/reset, revoke-all, token rotate, bind mode+port (all bearer-gated)"


@test("Play-latest button: TV show page (desktop + web)", "Web UI")
def test_play_latest_episode():
    ui = _src("web/index.html")
    rm = _src("src/services/remote.zig")
    tmdb = _src("src/services/tmdb.zig")
    lib = _src("src/services/tv_library.zig")
    pure = _src("src/services/tv_pure.zig")
    checks = {
        # One source of truth for "latest aired + watched", shared by both UIs.
        "shared lookup": "pub fn lastAiredFor(" in lib and "tp.isWatched(watched[0..nw], la)" in lib,
        "pure label + tests": "pub fn recentEpisodeLabel(" in pure
            and "pub fn isWatched(" in pure
            and 'test "recentEpisodeLabel: watched and unwatched"' in pure,
        # It must NOT be nextUp: the newest episode can already be watched, in
        # which case nextUp is null and the button would vanish.
        "distinct from nextUp": 'test "recent vs nextUp: the latest aired episode can already be watched"' in pure,
        # Desktop: button in the TV detail header row, reusing playEpisodeOf.
        "desktop button": '"tv-latest"' in tmdb and "lastAiredFor(t.tv_id)" in tmdb
            and "recentEpisodeLabel(latest.ep, latest.watched" in tmdb,
        "desktop plays the episode": 0 <= tmdb.find("latest.ep.season") and "playEpisodeOf(" in tmdb,
        # Web: route + top row.
        "route": '"/tv/recent"' in rm and "fn apiTvRecent(" in rm,
        "route reports watched": '"watched":{s}' in rm and "lastAiredFor(id)" in rm,
        # Unknown frontier is an honest {"found":false}, not a guessed episode.
        "unknown frontier honest": '{"found":false}' in rm,
        "web row": 'id="show-latest"' in ui and "async function loadLatest(" in ui
            and "latest-badge" in ui,
        "web hides when not found": "if (!d || !d.found) return;" in ui,
        # Top button and the per-episode rows must resolve identically.
        "same search path as Find": "prefillSearch(q)" in ui and "normQuery(showTitle)" in ui,
        "loads with the show page": "loadLatest(id);" in ui,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "play-latest incomplete: " + ", ".join(missing)
    return "pass", "Play-latest: shared lastAiredFor+isWatched, desktop button, web row + /api/tv/recent"


@test("TV play buttons give instant feedback (no silent clicks)", "Web UI")
def test_play_button_feedback():
    tmdb = _src("src/services/tmdb.zig")
    pure = _src("src/services/tv_pure.zig")
    checks = {
        # Shared busy rule, tested.
        "pure playAction": "pub fn playAction(" in pure and "pub const PlayAction" in pure
            and 'test "playAction: busy swaps the label AND blocks the click"' in pure,
        # A flag that outlives the 3.5s toast.
        "pending flag": "pub var episode_play_pending" in tmdb
            and "episode_play_pending.store(true, .release)" in tmdb,
        "cleared by the worker": "episode_play_pending.store(false, .release)" in tmdb,
        # The three paths that used to be silent now all speak.
        "repeat click toasts": "Already finding a stream" in tmdb,
        "impossible click toasts": "still syncing this show" in tmdb,
        "no bare `if (S.busy) return;`": "if (S.busy) return;" not in tmdb,
        # Both buttons show the busy state and stop acting.
        "buttons read the flag": "episode_play_pending.load(.acquire)" in tmdb,
        "spinner while busy": tmdb.count("dvui.spinner(@src()") >= 3,
        "clicks gated on clickable": "res_clicked and act.clickable" in tmdb
            and "lat_clicked and lat_act.clickable" in tmdb,
        # Without this the busy state waits for an incidental event — the
        # original symptom.
        # Must repaint right after arming, or the busy state waits for an
        # incidental event — the original symptom. Window-scoped rather than
        # whitespace-exact so reformatting doesn't break the check.
        "repaints on click": "dvui.refresh(" in tmdb[
            tmdb.find("episode_play_pending.store(true, .release)"):
            tmdb.find("episode_play_pending.store(true, .release)") + 400
        ],
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "play-button feedback incomplete: " + ", ".join(missing)
    return "pass", "Play buttons: Finding… + spinner while resolving, toasts on repeat/impossible clicks"


@test("Desktop Settings has a Web UI tab (not buried under AI & Scripts)", "Web UI")
def test_desktop_webui_settings_tab():
    st = _src("src/core/state.zig")
    sg = _src("src/ui/settings.zig")
    checks = {
        # A first-class sidebar destination, not a section inside another tab.
        "tab in enum": "WebUi" in st and "pub const SettingsTab = enum" in st,
        "sidebar row": '.tab = .WebUi, .label = "Web UI"' in sg,
        "title + dispatch": '.WebUi => "Web UI & Remote Access"' in sg
            and ".WebUi => renderWebUiTab()" in sg
            and "fn renderWebUiTab() void" in sg,
        "searchable": '.WebUi => &.{ "Web UI"' in sg,
        # The old toggle moved rather than being duplicated — two switches for
        # one server is how the two surfaces start disagreeing.
        "not duplicated in Scripts": sg.count("toggleRow(@src(), \"Enable Web UI\"") == 1
            and "Web Remote Control" not in sg,
        # Every control the web Access page has, mirrored.
        "enable + open": "remote.start()" in sg and "remote.stop()" in sg
            and "Open in Browser" in sg and "webUiUrl(remote.port" in sg,
        "account ops": "auth_store.createUser(" in sg and "auth_store.setPassword(" in sg
            and "auth_store.revokeAllSessions(null)" in sg,
        "token ops": "remote.tokenHex()" in sg and "remote.rotateToken()" in sg
            and "access.maskToken(" in sg,
        # Single-select goes through the shared segmented control (themed,
        # keyboard-focusable) rather than hand-rolled buttons — see the theming
        # RULE in CLAUDE.md.
        "bind + port": 'components.segment(@src(), &.{ "LAN", "This machine only" }' in sg
            and "remote.applyBinding(mode, remote.port)" in sg
            and "access.parsePort(" in sg,
        # Shared tested rules, not a re-implementation.
        "reuses pure rules": "access.checkPasswordChange(" in sg,
        # A password change must invalidate existing logins.
        "pw change revokes": 0 <= sg.find("auth_store.setPassword(uid, pw)")
            < sg.find("auth_store.revokeAllSessions(null)"),
        # Passwords must not linger in the module-level scratch buffers.
        "clears password buffers": sg.count("@memset(&webui_pw_buf, 0)") >= 2,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "desktop Web UI tab incomplete: " + ", ".join(missing)
    return "pass", "Settings › Web UI: enable/open, account create+reset, revoke-all, token, bind+port"


@test("Settings > Web UI: password reset is not a dead click", "Web UI")
def test_webui_password_reset_usable():
    """Three bugs shipped in the first cut of this page:
      1. Username started empty, so "Set Password" only ever toasted
         "Enter a username" unless you already knew it.
      2. A username that didn't match fell through to createUser, silently
         making a SECOND admin account instead of resetting the intended one.
      3. The createUser error path `return`ed mid-render, aborting the rest of
         the settings page for that frame."""
    sg = _src("src/ui/settings.zig")
    st = _src("src/services/auth_store.zig")
    checks = {
        "store exposes first account": "pub fn firstUsername(" in st
            and "ORDER BY id ASC LIMIT 1" in st,
        "username prefilled": "webui_user_seeded" in sg
            and "auth_store.firstUsername(" in sg,
        # Creation only on a genuinely empty install, matching /api/auth/register.
        "create only on first run": "} else if (users == 0) {" in sg
            and "auth_store.createUser(uname, pw, true)" in sg,
        "unknown name reports, never creates": 'No account named' in sg,
        # No mid-render return in the error path.
        "no mid-render return": "error.Db => \"Database error\",\n                });\n                return;" not in sg,
        # Reset still revokes, and still shares the tested rules.
        "revokes on reset": "auth_store.revokeAllSessions(null)" in sg,
        "shared validation": "access.checkPasswordChange(" in sg,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "password reset flow incomplete: " + ", ".join(missing)
    return "pass", "Password reset: username prefilled, unknown name refused, create gated to first run"


@test("Web Watching library (desktop .watching parity)", "Web UI")
def test_web_watching_library():
    ui = _src("web/index.html")
    rm = _src("src/services/remote.zig")
    lib = _src("src/services/tv_library.zig")
    checks = {
        "route": '"/library"' in rm and "fn apiLibrary(" in rm,
        # rows/order were UI-thread-owned; the server thread must copy under a lock.
        "thread-safe snapshot": "pub fn snapshotCopy(" in lib
            and "snapshot_mutex" in lib
            and "buildSnapshotLocked()" in lib,
        # A Row is ~600B x 200 — never on a spawned thread's stack.
        "heap-allocated": "alloc.alloc(tp.Row, tp.MAX_SHOWS)" in rm,
        # Same order as the desktop, so the two lists agree.
        "desktop display order": "rows[order[i]]" in lib,
        # The filter chips need the status TAG, not the display label.
        "emits status tag": r'\"state\":\"{s}\"' in rm
            and "effectiveStatus(r.user, r.status)" in rm,
        "page filters on tag": "r.state === watchFilter" in ui,
        "page + nav": 'id="page-watch"' in ui and 'data-page="watch"' in ui
            and "async function loadWatch(" in ui,
        # TV rows reuse the existing drill-down (season list + Play-latest).
        "reuses show drilldown": "openShow(r.tmdb_id, r.name)" in ui,
        "progress bar": "wbar" in ui,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "Watching page incomplete: " + ", ".join(missing)
    return "pass", "Watching: /api/library (locked snapshot, desktop order) + filter chips + drill-down"


@test("Web Settings page (registry-driven, desktop parity)", "Web UI")
def test_web_settings_page():
    ui = _src("web/index.html")
    rm = _src("src/services/remote.zig")
    pure = _src("src/services/settings_api_pure.zig")
    bz = _src("build.zig")
    checks = {
        "pure registry + tests": "pub const KEYS = [_]Key{" in pure
            and 'test "registry: names unique, every key labelled and grouped"' in pure
            and "test_settings_api_pure" in bz,
        # One registry drives GET, POST and the page — a key can't be
        # settable-but-invisible or shown-but-unsettable.
        "route reads registry": "fn apiSettings(" in rm and "for (sap.KEYS" in rm
            and "sap.find(key)" in rm,
        "validates via pure fns": "sap.parseBool(" in rm and "sap.parseInt(" in rm
            and "sap.parseText(" in rm,
        # Rejecting beats clamping: storing something other than what was asked
        # for and reporting success is a silent data bug.
        # The JSON literals are escaped in the Zig source (\"…\"), so match
        # the message text rather than a quoted form that never appears.
        "rejects invalid": "invalid value for this setting" in rm
            and "unknown setting" in rm
            and "parseInt: rejects rather than clamps" in pure,
        # hwdec must reach live players, like the desktop toggle.
        "hwdec pushed to players": "set hwdec {s}" in rm,
        "persists": "state.markConfigDirty()" in rm,
        # Old 4-field /settings shape kept so an older client isn't broken.
        "legacy shape preserved": "Legacy top-level booleans" in rm,
        # Page builds controls from kind/group, so new keys appear for free.
        "page renders registry": "async function loadSettings(" in ui
            and "k.kind === 'boolean'" in ui and 'id="cfg-list"' in ui,
        # Report AFTER re-reading, or loadSettings() eats the error.
        "reports after refresh": "if (!r.ok) await loadSettings();" in ui,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "Settings page incomplete: " + ", ".join(missing)
    return "pass", "Settings: registry-driven /api/settings (validate+reject) + grouped web controls"


@test("Web Home hub, Plugins manager and Watch Party (desktop parity)", "Web UI")
def test_web_home_plugins_party():
    ui = _src("web/index.html")
    rm = _src("src/services/remote.zig")
    checks = {
        # Home: counts + continue, composed with the pre-existing calendar rail.
        "home route": '"/home"' in rm and "fn apiHome(" in rm,
        "home reuses library order": "lib.snapshotCopy(rowbuf)" in rm,
        "home page": 'id="page-home"' in ui and 'data-page="home"' in ui
            and "async function loadHome(" in ui,
        # One rail, mirrored — not a second fetch with its own label logic.
        "calendar mirrored not re-derived": "async function loadCalendarInto(" in ui
            and "dst.innerHTML = src.innerHTML" in ui,
        # Plugins: list + integration config.
        "plugins route": '"/plugins"' in rm and "fn apiPlugins(" in rm,
        # Credentials must never be echoed back to the browser.
        # JSON keys are escaped in Zig source (\"has_token\"), so match the bare
        # name; and assert the secret buffer is never READ back out (it appears
        # only in the write table, as &repo.debrid_key_buf).
        "credentials not echoed": "has_token" in rm and "has_debrid_key" in rm
            and "repo.debrid_key_buf[0.." not in rm,
        "plugins page": 'id="plug-list"' in ui and "async function loadPlugins(" in ui,
        # Blank credential field means "leave alone", not "wipe".
        "blank keeps credential": "if ($('plug-token').value)" in ui,
        # Watch party.
        "party route": '"/party"' in rm and "fn apiParty(" in rm,
        "party validates action": "action must be host, join or leave" in rm
            and "missing ip" in rm,
        "party page": 'id="party-host"' in ui and 'id="party-join"' in ui
            and 'id="party-leave"' in ui,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "home/plugins/party incomplete: " + ", ".join(missing)
    return "pass", "Home hub + Plugins manager + Watch Party wired to /home, /plugins, /party"


@test("Web UI plays media in the browser (Play here destination)", "Web UI")
def test_web_play_here():
    """The browser used to be a remote control whenever the desktop app was up:
    every play handed off to mpv and the page showed nothing. PLAY_HERE makes
    the page a real player for media a browser can actually decode."""
    ui = _src("web/index.html")
    rm = _src("src/services/remote.zig")
    pure = _src("src/services/playback_target_pure.zig")
    bz = _src("build.zig")
    checks = {
        "pure rules + tests": "pub fn classify(" in pure and "pub const Playability" in pure
            and "test_playback_target_pure" in bz,
        # No transcoder: refuse with a reason instead of a black <video>.
        "refuses unsupported": "classify: containers browsers do not play" in pure
            and "playabilityReason" in ui,
        # An .mp4 carrying H.265 is still unplayable — extension alone is not enough.
        "codec markers checked": "BAD_CODEC_MARKERS" in pure and "BAD_CODEC" in ui,
        # THE regression: classifying the /stream URL saw "/stream" with no
        # extension and let an MKV through.
        "classifies name not wrapper url": "callers must pass the media NAME" in pure
            and "classifyName || url" in ui,
        # <video src> cannot send a header, so media routes take ?t=.
        "stream url carries token": "function streamUrl(" in ui and "&t=" in ui,
        # The web page holds a SESSION token; /stream used to accept only the
        # machine api.token, so a logged-in user could not stream at all.
        "stream accepts sessions": "if (!isAuthorized(t))" in rm,
        # Every play path goes through one dispatcher.
        "single dispatcher": ui.count("dispatchPlay(") >= 5,
        "destination toggle persists": "opal_play_here" in ui and "function setPlayHere(" in ui,
        # HLS: Safari natively, others get the honest message.
        "hls handled separately": "NATIVE_HLS" in ui and "'hls'" in ui,
        # Live torrents stream off disk while downloading.
        "torrent files route": '"/torrent/files"' in rm and "fn apiTorrentFiles(" in rm,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "play-here incomplete: " + ", ".join(missing)
    return "pass", "Play here: direct-play with codec refusal, session-token /stream, 5 play paths routed"


@test("Torrent per-file streaming + pluggable HLS", "Web UI")
def test_torrent_files_and_hls():
    ui = _src("web/index.html")
    rm = _src("src/services/remote.zig")
    checks = {
        # Route + its refusals.
        "route": '"/torrent/files"' in rm and "fn apiTorrentFiles(" in rm,
        "route validates id": "no such torrent" in rm and "missing id" in rm,
        # These wrapper accessors write into a caller buffer and return void —
        # treating them as pointer-returning was a compile error, keep it fixed.
        "uses out-buffer accessors": "c.mpv.torrent_get_file_name(ses, idx, i, &fname_buf" in rm,
        # Single-file torrents have no folder; multi-file do.
        "builds stream-relative path": '"\\",\\"rel\\":\\""' in rm or 'rel' in rm,
        # UI: expand a torrent, play one file.
        "file list ui": "function wireTorrentFiles(" in ui and "tor-files" in ui
            and "/torrent/files?id=" in ui,
        # Classify the file NAME, never the /stream wrapper URL.
        "classifies file name": "dispatchPlay(streamUrl(f.rel), f.name" in ui
            and ", f.name);" in ui,
        # Streaming a partial file can stall — say so rather than let it die.
        "warns on partial": "playback may stall" in ui,
        # hls.js: vendored as a SEPARATE file and feature-tested.
        "hls feature-tested": "window.Hls" in ui and "function openHls(" in ui,
        "hls loaded from vendor": 'src="vendor/hls.min.js"' in ui,
        # 543KB inlined would swamp the page — index.html must stay small.
        "hls not inlined": len(ui) < 400_000,
        "vendor file present": os.path.exists(os.path.join(PROJECT_DIR, "web/vendor/hls.min.js")),
        "bundled into the app": "web/vendor" in _src("scripts/build-app.sh"),
        # A live shim must be torn down or it keeps fetching segments.
        "hls torn down on close": "v._hls.destroy()" in ui,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "torrent-files/hls incomplete: " + ", ".join(missing)
    return "pass", "Torrent per-file play via /stream + hls.js vendored separately (feature-tested)"


@test("On-the-fly transcode route (KNOWN: leaks a blocked encoder)", "Web UI")
def test_transcode_route():
    """ffmpeg → fragmented MP4 so MKV/H.265 can play in a browser.

    KNOWN LIMITATION, verified not fixed: when the viewer disappears mid-stream
    the socket write blocks (SO_SNDTIMEO does not surface through the threaded
    Io layer), so the loop never reaches child.kill(). A watchdog thread was
    added and did NOT reap it in testing. The orphan sits blocked at 0% CPU —
    an fd/process leak, not a CPU leak. Do not treat this as done."""
    rm = _src("src/services/remote.zig")
    rs = _src("src/services/remote_stream.zig")
    checks = {
        "route + auth family": '"/transcode"' in rm and "handleTranscode(stream, rel, start_secs)" in rm,
        "handler": "pub fn handleTranscode(" in rs,
        # Fragmented MP4 is what makes a still-being-produced file playable.
        "fragmented mp4": "frag_keyframe+empty_moov" in rs,
        # No Range on a stream that does not exist yet; seek restarts the encode.
        "no range, seek by restart": "Accept-Ranges: none" in rs and '"-ss"' in rs,
        # A Finder-launched .app has no Homebrew on PATH — resolve absolutely.
        "absolute ffmpeg path": "FFMPEG_CANDIDATES" in rs
            and "/opt/homebrew/bin/ffmpeg" in rs,
        "availability advertised": '"/transcode/available"' in rm and "haveFfmpeg()" in rm,
        # Cleanup attempt is present even though it is not yet sufficient.
        "cleanup attempted": "TranscodeGuard" in rs and "terminateProcess(self.pid)" in rs,
        "limitation documented": "does not surface through the threaded Io" in rs,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "transcode incomplete: " + ", ".join(missing)
    return "warn", "Transcode works; KNOWN leak — abandoned stream leaves a blocked ffmpeg"


@test("web/index.html inline JavaScript parses", "Web UI")
def test_web_ui_js_syntax():
    """Every other web test here is a string match, so none of them can see a
    SYNTAX error. A script tag was once spliced into the middle of a code
    comment (an insertion matched a literal '<script>' *inside* a comment),
    which shredded a function and left the whole page dead — `$ is not
    defined`, nothing worked — and the suite stayed green.

    Parses the inline blocks with node when available; falls back to a brace/
    paren balance check so the test still means something without node."""
    import re, shutil, subprocess, tempfile, os
    ui = _src("web/index.html")
    blocks = re.findall(r"<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>", ui, re.S)
    if not blocks:
        return "fail", "no inline <script> blocks found in web/index.html"
    js = "\n;\n".join(blocks)

    node = shutil.which("node")
    if node:
        with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
            f.write(js)
            path = f.name
        try:
            r = subprocess.run([node, "--check", path], capture_output=True, text=True, timeout=30)
            if r.returncode != 0:
                first = (r.stderr or "").strip().splitlines()
                detail = " | ".join(first[:3]) if first else "node --check failed"
                return "fail", "inline JS syntax error: " + detail
        finally:
            os.unlink(path)
        return "pass", f"{len(blocks)} inline script block(s), {len(js)} bytes — node --check clean"

    # No node: a balance check still catches the splice-into-comment class of
    # damage, which leaves brackets unmatched.
    depth = {"{": 0, "(": 0, "[": 0}
    pairs = {"}": "{", ")": "(", "]": "["}
    in_s = None
    i = 0
    while i < len(js):
        c = js[i]
        if in_s:
            if c == "\\":
                i += 2
                continue
            if c == in_s:
                in_s = None
        elif c in "\"'`":
            in_s = c
        elif c == "/" and i + 1 < len(js) and js[i + 1] == "/":
            i = js.find("\n", i)
            if i < 0:
                break
        elif c == "/" and i + 1 < len(js) and js[i + 1] == "*":
            i = js.find("*/", i) + 2
            continue
        elif c in depth:
            depth[c] += 1
        elif c in pairs:
            depth[pairs[c]] -= 1
        i += 1
    bad = [k for k, v in depth.items() if v != 0]
    if bad:
        return "fail", "inline JS brackets unbalanced: " + ", ".join(bad)
    return "warn", "node not installed — only a bracket-balance check ran"
