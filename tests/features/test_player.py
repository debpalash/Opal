"""Auto-split from tests/test_features.py — Player / Browse / Anime / Co-Watcher / Remote / Library / Downloads / Search tests.
Byte-for-byte identical test bodies; see tests/features/harness.py for the
shared @test decorator, helpers, and run_all()."""
from .harness import *  # noqa: F401,F403
import os, sys, subprocess, sqlite3, socket, time, json  # noqa: F401

@test("Typed Playback Load Seam", "Player")
def test_typed_playback_load_seam():
    player = _src("src/player/player.zig")
    pure = _src("src/player/playback_load_pure.zig")
    browser = _src("src/services/browser.zig")
    build = _src("build.zig")

    # A raw mpv media command anywhere outside the production adapter bypasses
    # the mandatory UA/header reset and can leak one host's Cookie/Referer into
    # the next. Keep this source-wide so new integrations are covered too.
    offenders = []
    src_root = os.path.join(PROJECT_DIR, "src")
    for root, _, files in os.walk(src_root):
        for name in files:
            if not name.endswith(".zig"):
                continue
            path = os.path.join(root, name)
            rel = os.path.relpath(path, PROJECT_DIR)
            text = open(path, encoding="utf-8").read()
            if ('"loadfile"' in text or 'loadfile \\"' in text) and rel != "src/player/player.zig":
                offenders.append(rel)

    checks = {
        "one raw implementation": player.count('"loadfile"') == 1,
        "no bypassing callers": not offenders,
        "typed modes": "pub const Mode = enum" in pure and "replace" in pure and "append" in pure,
        "replace clears; every entry owns options": ('if (request.mode == .replace)' in pure
                              and 'sink.setOption("user-agent", "libmpv")' in pure
                              and 'sink.setOption("http-header-fields", "")' in pure
                              and "sink.loadFile(request.url, request.mode" in pure
                              and "FileOptions" in pure),
        "append does not mutate current stream":
            "append attaches entry options without mutating the current global options" in pure,
        "production adapter": "playback_load.dispatch(&sink, request)" in player,
        "browser request mode": "mode: player.LoadMode = .replace" in browser,
        "central health hook": "health_kind" in browser and "link_health.zig" in browser,
        "pure test registered": "src/player/playback_load_pure.zig" in build,
    }
    missing = [key for key, ok in checks.items() if not ok]
    if not missing:
        return "pass", "replace clears legacy globals; per-entry options preserve append isolation; no raw bypass"
    return "fail", f"missing: {missing}; raw offenders: {offenders}"


@test("Single-Media Mode", "Player")
def test_single_media():
    main = _src("src/main.zig")
    inp = _src("src/ui/input.zig")
    hdr = _src("src/ui/header.zig")
    # Frame-top collapse keeps exactly one player; Ctrl+T retired; Add screen gone.
    if ("players.items.len > 1" in main and "orderedRemove" in main
            and "Single-player mode" in inp and "Add screen" not in hdr):
        return "pass", "collapse-to-one + multistream affordances removed"
    return "fail", "single-media invariant not fully wired"


@test("Browser in Web Tab", "Player")
def test_browser_web_tab():
    st = _src("src/core/state.zig")
    dr = _src("src/ui/drawer.zig")
    br = _src("src/services/browser.zig")
    # Browser is a Browse>Web tab (not a player pane); .browser provider removed.
    if ("AI, Web" in st and ".Web =>" in dr and "renderContent" in br
            and "comic_viewer }" in st):
        return "pass", "browser routed to Browse>Web; provider .browser dropped"
    return "fail", "browser-in-web-tab not wired"


@test("Co-Watcher look_at_screen", "Co-Watcher")
def test_look_at_screen():
    tools = _src("src/services/ai_tools.zig")
    ctx = _src("src/services/ai_context.zig")
    ocr = _src("src/services/frame_ocr.zig")
    if ("look_at_screen" in tools and "executeLookAtScreen" in tools
            and "look_at_screen" in ctx and "pub fn ocrCurrentFrame" in ocr):
        return "pass", "look_at_screen tool + frame OCR wired"
    return "fail", "look_at_screen not fully wired"


@test("Proactive Co-Watcher Triggers", "Co-Watcher")
def test_proactive_cowatch():
    cw = _src("src/services/co_watch.zig")
    pl = _src("src/player/player.zig")
    if ("pub fn onPlaybackEvent" in cw and "sensitivity" in cw
            and "onPlaybackEvent(.paused)" in pl and "onPlaybackEvent(.rewound)" in pl
            and '"time-pos"' in pl):
        return "pass", "pause/rewind triggers + time-pos observe wired"
    return "fail", "proactive co-watcher triggers not wired"


@test("Spoiler Firewall", "Co-Watcher")
def test_spoiler_firewall():
    sp = _src("src/services/spoiler.zig")
    cw = _src("src/services/co_watch.zig")
    tools = _src("src/services/ai_tools.zig")
    if ("pub fn clampLine" in sp and "pub fn flagsSpoiler" in sp
            and "flagsSpoiler" in cw and "clampLine" in tools):
        return "pass", "clamp + leak-check enforced in co_watch and tool"
    return "fail", "spoiler firewall not fully wired"


@test("Card Views Live Search + Polish", "Browse")
def test_card_views_polish():
    # Anime / YouTube / Comics browse views upgraded to TMDB-grade: debounced
    # live search (generation-guarded), card-size control, hover. Comics gains a
    # real cover-image grid (covers parsed from source, async fetch→texture).
    an = _src("src/services/anime.zig")
    yt = _src("src/services/youtube.zig")
    cm = _src("src/services/comics.zig")
    checks = {
        "anime live search": "search_gen" in an and "last_edit_ms" in an,
        "youtube live search": "search_gen" in yt and "last_edit_ms" in yt,
        "comics live search": "search_gen" in cm and "last_edit_ms" in cm,
        "anime card size": "card_w" in an,
        "youtube card size": "card_w" in yt,
        "comics cover grid": ("sr_cover_tex" in cm and "fetchCover" in cm
                              and "renderCoverCard" in cm),
    }
    missing = [k for k, v in checks.items() if not v]
    if not missing:
        return "pass", "live search + card-size + comics cover grid wired across all 3 views"
    return "fail", f"missing: {missing}"


@test("TV Seasons/Episodes/Tracking", "Browse")
def test_tv_seasons():
    # TMDB TV-show drill-down: click a TV card → seasons → episodes → resolver
    # play, with persisted episode watched-tracking.
    st = _src("src/core/state.zig")
    db = _src("src/core/db.zig")
    tm = _src("src/services/tmdb.zig")
    checks = {
        "state types": ("TvSeason" in st and "TvEpisode" in st
                        and "tv_detail_open" in st and "tv_episode_watched" in st),
        "db tracking": ("tvMarkWatched" in db and "tvLoadWatched" in db
                        and "tv_watched" in db and "tv_continue" in db),
        "detail view": "openTvDetail" in tm and "renderTvDetail" in tm,
        "season/episode fetch": "/tv/" in tm and "/season/" in tm,
        "tracking wired": "tvMarkWatched" in tm and "tvLoadWatched" in tm,
    }
    missing = [k for k, v in checks.items() if not v]
    if not missing:
        return "pass", "tv seasons → episodes → resolver play + episode tracking wired"
    return "fail", f"missing: {missing}"


@test("Deferred Watch Commit + Smart Episode Play + Onboarding", "Browse")
def test_watch_commit_smart_play_onboarding():
    # 1) Clicking ▶ must NOT mark watched — the commit is armed and fires from
    #    the player's time-pos stream after ~2min (tvWatchCommitDue, pure).
    # 2) Episode play auto-plays the top-ranked CONFIDENT source (pickBest,
    #    pure) and falls back to the Search picker otherwise.
    # 3) First-run wizard: starter source pack + TMDB key + AI note; onboarded
    #    flag persisted; pre-wizard installs grandfathered.
    tm = _src("src/services/tmdb.zig")
    pl = _src("src/player/player.zig")
    st = _src("src/core/state.zig")
    rk = _src("src/services/resolver_rank.zig")
    ob = _src("src/ui/onboarding.zig")
    pr = _src("src/services/plugin_repo.zig")
    cfg = _src("src/core/config.zig")
    mn = _src("src/main.zig")
    checks = {
        "no click-time mark": "tvMarkWatched" not in _between(tm, "fn playTvEpisode", "\nfn "),
        "pending watch state": "pending_watch" in st and "armed" in st,
        "commit on playback": "tvWatchCommitDue" in pl and "commitPendingWatch" in pl,
        # The commit marks the episode watched, scrobbles to Trakt, and AUTO-TRACKS
        # the show. It used to upsert tv_continue (which stored the LAST WATCHED
        # episode); that table is superseded by tv_shows, and "what's next" is now
        # derived by tv_pure rather than stored — see the TV Tracking test.
        "commit does db+trakt+track": ("tvMarkWatched" in _between(tm, "pub fn commitPendingWatch", "\nfn ")
                                       and "markWatchedEpisode" in _between(tm, "pub fn commitPendingWatch", "\nfn ")
                                       and "tvTouchShow" in _between(tm, "pub fn commitPendingWatch", "\nfn ")),
        "smart pick pure": "pub fn pickBest" in rk and "PickCand" in rk,
        "smart play wired": "smartPlayEpisode" in tm and "pickBest" in tm and "setUniversalQuery" in tm,
        "wizard": "installStarterPack" in ob and "onboarded" in ob,
        "starter pack": "pub fn installStarterPack" in pr and "torrentio" in pr,
        "persist + grandfather": '"onboarded"' in cfg and "anyInstalled" in cfg,
        "wizard rendered": "onboarding.zig" in mn,
    }
    missing = [k for k, v in checks.items() if not v]
    if not missing:
        return "pass", "deferred watch commit + confident auto-play + first-run wizard wired"
    return "fail", f"missing: {missing}"


@test("Onboarding: paged feature tour + replay from Settings", "Browse")
def test_onboarding_tour():
    # The first-run wizard used to only *configure* the app (sources/TMDB/AI)
    # and was a one-shot — nothing ever explained what Opal could do, and once
    # dismissed it was unreachable. It's now a paged wizard: page 0 = setup,
    # then a short feature tour, reopenable from Settings › About.
    #
    # Paging is GUI code (dvui immediate mode), so the pure Back/Next/clamp
    # decisions live in onboarding_pure.zig and the modal routes through them —
    # guard that the routing stays in place so the tested logic is the shipped
    # logic (no drift back to inline arithmetic).
    ob = _src("src/ui/onboarding.zig")
    obp = _src("src/ui/onboarding_pure.zig")
    se = _src("src/ui/settings.zig")
    bz = _src("build.zig")
    checks = {
        # Pure nav module exists, is exercised, and is registered as a unit test.
        "pure nav fns": all(f"pub fn {f}" in obp for f in ("isLast", "clamp", "next", "prev")),
        "pure nav tested": obp.count('test "') >= 4,
        "pure nav registered": "src/ui/onboarding_pure.zig" in bz,
        # The modal routes paging through the pure module (not inline math).
        "routes through pure": 'onboarding_pure.zig' in ob and "nav.isLast" in ob and "nav.next" in ob and "nav.prev" in ob,
        # The tour itself: pages, per-page features, dots, and Back/Next nav.
        "tour pages": "const TOUR" in ob and "TourPage" in ob and "PAGE_COUNT" in ob,
        "tour renders": "fn tourPage" in ob and "fn pageDots" in ob and "fn navFooter" in ob,
        "next/finish split": '"Get started"' in ob and '"Next"' in ob and '"Back"' in ob,
        # Reopenable — replay() resets to page 0 and clears the onboarded flag.
        "replay exported": "pub fn replay" in ob and "state.app.onboarded = false" in ob,
        "replay wired in settings": "onboarding.zig" in se and "replay()" in se,
        # finish() must reset the page or a replay resumes mid-tour.
        "finish resets page": "page = 0;" in _between(ob, "fn finish", "\n}"),
    }
    missing = [k for k, v in checks.items() if not v]
    if not missing:
        return "pass", "paged tour + pure nav + replay from Settings › About"
    return "fail", f"missing: {missing}"


@test("TV Calendar: Coming-Up Rail + EZTV Availability + HW Decode", "Browse")
def test_tv_calendar_and_hwdec():
    # Coming-up rail: TMDB next/last-episode-to-air parsing, countdown labels,
    # EZTV get-torrents availability (neutral-gated on the eztv source), Home
    # rail + click-through. Plus the playback-CPU fixes: hw decode ON by
    # default (legacy auto-persisted hwdec=0 migrated via hwdec2) and the SW
    # render targeting native video size instead of fixed 1920x1080.
    calp = _src("src/services/tv_calendar_pure.zig")
    cal = _src("src/services/tv_calendar.zig")
    hm = _src("src/ui/home.zig")
    st = _src("src/core/state.zig")
    cfg = _src("src/core/config.zig")
    gr = _src("src/ui/grid.zig")
    checks = {
        "pure parsers": ("parseEpisodeToAir" in calp and "eztvEpisodeSeeds" in calp
                         and "countdownLabel" in calp and "imdbDigits" in calp),
        # The calendar no longer fetches /3/tv/{id} itself — tv_library's sync
        # worker makes that call once for every tracked show and stages the rail
        # from the same document, so the rail and My Shows cannot disagree about
        # what is next.
        "service wired": ("pub fn stage(" in cal and "next_episode_to_air" in cal
                          and 'has("eztv")' in cal),
        "home rail": "renderComingUpRail" in hm and "refreshOnce" in hm,
        "click-through": "openTvDetailById" in hm,
        "hwdec default on": "hwdec_enabled: bool = true" in st,
        "hwdec migration": '"hwdec2"' in cfg,
        "adaptive render size": ("playbackSnapshot" in gr
                                 and "renderSize" in gr
                                 and "textureDestroyLater" in gr
                                 and 'mpv_get_property(p.mpv_ctx, "dwidth"' not in gr),
    }
    missing = [k for k, v in checks.items() if not v]
    if not missing:
        return "pass", "coming-up rail + eztv availability + hwdec/native-size render wired"
    return "fail", f"missing: {missing}"


@test("Web Companion: Account Auth + LAN Bind + Bundled Page", "Remote")
def test_web_companion():
    # The pairing code is gone (test_headless_auth.py owns the account system).
    # This covers the rest of the companion story: server binds LAN when the
    # opt-in toggle is on, the page is served from Resources/web with a dev
    # fallback, Settings shows the LAN URL + an account hint, build bundles it.
    rm = _remote_api()
    stg = _src("src/ui/settings.zig")
    sh = open(os.path.join(PROJECT_DIR, "scripts/build-app.sh")).read()
    web = _web_app()
    checks = {
        # Pairing is fully removed server-side.
        "no pair route": '"/pair"' not in rm and "regeneratePairCode" not in rm
            and "pairingCode" not in rm and "MAX_PAIR_FAILS" not in rm,
        "no token injection": "replaceOwned" not in rm,
        # The bind address is now selectable (web UI › Setup › Access), so the
        # literal no longer lives in serverLoop — but LAN must stay the DEFAULT,
        # since reaching Opal from a phone is the whole point of Web Remote.
        # Assert that via the enum's default rather than a hardcoded string.
        "lan bind": 'bind_mode: access_pure.BindMode = .lan' in rm
            and "bind_mode.address()" in _between(rm, "fn serverLoop", "std.debug.print")
            and '.lan => "0.0.0.0"' in open(os.path.join(PROJECT_DIR, "src/services/access_pure.zig")).read(),
        "bundled serving": "resourceRoot" in rm and "web/index.html" in rm,
        # Was: a hint telling you to go create an account in a browser. The
        # desktop Settings › Web UI tab now creates it directly, which is
        # strictly stronger — and is the only recovery path when the password
        # is forgotten or the server is off. Still no pairing code anywhere.
        "settings account controls": "lanIp" in stg and "pairingCode" not in stg
            and "auth_store.createFirstAdmin(" in stg and "Create Account" in stg,
        "build bundles web": "Resources/web" in sh,
        # The web UI authenticates via accounts, not a pairing code.
        "client uses accounts": "/api/auth/status" in web and "/api/auth/" in web
            and "submitAuth" in web and "HttpOnly" in rm
            and "localStorage.setItem('opal_token'" not in web and 'id="pair-code"' not in web,
    }
    missing = [k for k, v in checks.items() if not v]
    if not missing:
        return "pass", "account auth (no pairing) + LAN bind + bundled page"
    return "fail", f"missing: {missing}"


@test("Hosted Mode: Stream/VTT/Poster + Docker + Perf Fixes", "Remote")
def test_hosted_mode_and_perf():
    # Headless hosting (docs/headless-hosting-spec.md H1+H2+H3 slice) and the
    # production CPU fixes from the 2026-07-10 profiling session.
    rs = _src("src/services/remote_stream.zig")
    rp = _src("src/services/remote_stream_pure.zig")
    rm = _remote_api()
    hl = _src("src/headless.zig")
    al = _src("src/core/alloc.zig")
    gr = _src("src/ui/grid.zig")
    pl = _src("src/player/player.zig")
    dk = open(os.path.join(PROJECT_DIR, "Dockerfile")).read()
    ci = open(os.path.join(PROJECT_DIR, ".github/workflows/ci.yml")).read()
    docker_smoke = _src("scripts/docker-smoke.sh")
    web = _web_app()
    checks = {
        "range streaming": "parseRange" in rp and "206 Partial Content" in rs,
        "srt→vtt": "srtToVtt" in rp and "handleVtt" in rs,
        "traversal guard": "safeRelPath" in rp and "secure_path.openRegularAt" in rs,
        "query-token media auth": '"/stream"' in rm and 'getQueryParam(query, "t")' in rm,
        "parity routes": '"/calendar"' in rm and '"/tv"' in rm and '"/host"' in rm and '"/torrents"' in rm,
        "thread-per-conn + api mutex": "api_mutex" in rm and "Thread.spawn(.{}, Handler.run" in rm,
        "headless serves web": "web_remote_enabled = true" in hl and "create your admin account" in hl,
        "docker headless build": "-Dheadless=true" in dk and "3000" not in dk,
        "ci gate": "docker-headless" in ci and "scripts/docker-smoke.sh" in ci
            and "/api/auth/register" in docker_smoke,
        "hosted web player": "openPlayer" in web and "/stream?file=" in web and "/vtt?file=" in web,
        "web transfer progress": "pollTransfers" in web,
        "browser-first setup": '"/setup/sources"' in rm and "installStarterPack" in rm and "loadSetup" in web,
        "sse push": '"/events"' in rm and "text/event-stream" in rm
            and 'remote_status.zig").build' in rm and "EventSource" in web,
        "queue reorder": '"/queue/move"' in rm and "moveQueueItem" in _src("src/services/queue.zig") and "qmv" in web,
        # Perf: release allocator, non-blocking mpv render, no built-in Lua VMs.
        "release allocator": "smp_allocator" in al,
        "no mpv render block": "MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME" in gr,
        "mpv lua trimmed": "load-osd-console" in pl and "load-stats-overlay" in pl,
    }
    missing = [k for k, v in checks.items() if not v]
    if not missing:
        return "pass", "hosted streaming + docker gate + CPU fixes wired"
    return "fail", f"missing: {missing}"


@test("Anime Seasons/Calendar/Tracking", "Browse")
def test_anime_netflix_experience():
    # Netflix/Apple-TV+ anime browse: mode toolbar, Seasonal (/seasons),
    # Calendar (/schedules), franchise relations rail, and persisted episode
    # tracking + Continue-Watching.
    st = _src("src/core/state.zig")
    db = _src("src/core/db.zig")
    an = _src("src/services/anime.zig")
    checks = {
        "state modes": ("AnimeMode" in st and "AnimeSeasonSel" in st
                        and "ContinueItem" in st and "episode_watched" in st),
        "db tracking": ("animeMarkWatched" in db and "animeGetContinue" in db
                        and "anime_watched" in db and "anime_continue" in db),
        "seasonal fetch": "/seasons/" in an,
        "calendar fetch": "/schedules" in an,
        "relations rail": "/relations" in an,
        "tracking wired": ("animeMarkWatched" in an and "animeLoadWatched" in an
                           and "animeUpsertContinue" in an),
    }
    missing = [k for k, v in checks.items() if not v]
    if not missing:
        return "pass", "modes + seasonal + calendar + relations + episode tracking wired"
    return "fail", f"missing: {missing}"


@test("Anime Lists Source Plugin", "Anime")
def test_anime_lists_plugin():
    # AniList<->MAL id maps + a currently-airing feed wired into the anime index.
    # It is a METADATA source, so it ships with a working default endpoint and an
    # installed `lists` plugin merely OVERRIDES it. It was originally gated behind
    # a plugin install like a torrent index, which meant the chip rendered NOTHING
    # on every machine (no plugin ships installed) -- the neutrality rule is about
    # infringing endpoints, and Jikan and AniList, the other two anime metadata
    # APIs, are both hardcoded.
    # The data was consolidated from the former debpalash/lists repo into
    # debpalash/opal-plugins (lists/ subdir); the base URL points there now.
    import json as _json
    an = _src("src/services/anime.zig")
    pure = _src("src/services/anime_lists_pure.zig")
    bz = _src("build.zig")
    with open(os.path.join(PROJECT_DIR, "data", "plugins-manifest.json")) as fh:
        manifest = _json.load(fh)
    entry = next((p for p in manifest["plugins"] if p["id"] == "lists"), None)

    checks = {
        # Registered through the EXISTING source-plugin contract (plugin_repo.zig
        # reads this manifest; install writes ~/.config/opal/plugins/sources/<id>.json).
        "manifest entry": entry is not None and entry.get("type") == "anime",
        "manifest endpoint": bool(entry and "opal-plugins/main/lists" in entry["endpoints"]["base"]),
        # Plugin can still override the endpoint...
        "source_config override": 'get("lists", "base")' in an,
        # ...but a machine with no plugin installed MUST still get data. A null
        # listsBase() hides the chip entirely, which is the bug this pins.
        "works with no plugin installed": ("LISTS_DEFAULT_BASE" in an
                                           and "opal-plugins/main/lists" in an),
        # Fetch: curl (never std.http), off the UI thread, into the shared grid.
        "fetches airing feed": "anime-airing.json" in an,
        "curl not std.http": "curl" in an and "std.http" not in an,
        "detached worker": "listsThread" in an and "search_gen" in an,
        # SWR disk cache so it isn't refetched every launch.
        "cached": "cacheStoreForUrl" in an and "cacheLoadForUrl" in an,
        "ttl": "LISTS_TTL_S" in an,
        # Parsing lives in the tested pure sibling, registered in build.zig.
        "pure parser": "pub fn parseAiring" in pure,
        "prod routes through pure": "lists_pure.parseAiring" in an,
        "pure real schema": '"idMal"' in pure and "nextEpisode" in pure,
        "pure registered": "anime_lists_pure.zig" in bz,
    }
    missing = [k for k, v in checks.items() if not v]
    if not missing:
        return "pass", "lists plugin: manifest → source_config → cached airing grid (pure-parsed)"
    return "fail", f"missing: {missing}"


@test("Now-Playing Media Bar", "Player")
def test_now_playing_bar():
    # Persistent bottom now-playing bar (Spotify-style): transport + scrubber +
    # playlist, shown across tabs when media is active; torrent strip preserved.
    f = _src("src/ui/footer.zig")
    if ("renderNowPlayingBar" in f and "activeMediaPlayer" in f
            and "renderTorrentActivityStrip" in f
            and "playlistDropdownMenu" in f and "active_player_idx <" in f):
        return "pass", "now-playing bar: transport+scrubber+playlist, guarded; torrent strip kept"
    return "fail", "now-playing media bar not wired"


@test("Live-ASR Foundation", "Co-Watcher")
def test_live_asr_foundation():
    la = _src("src/services/live_asr.zig")
    st = _src("src/core/state.zig")
    cfg = _src("src/core/config.zig")
    # Wiring guard only: module + state flag + config persistence present.
    # (The no-mic-capture safety lives in the worker code itself, which is a
    # logs.pushLog no-op; a keyword grep can't tell code from the doc comments
    # that legitimately mention ffmpeg/avfoundation when describing the blocker.)
    if "pub fn setEnabled" in la and "live_asr_enabled" in st and "live_asr" in cfg:
        return "pass", "off-by-default foundation wired (module/state/config)"
    return "fail", "live-ASR foundation not wired"


@test("Player Resume Wired", "Player")
def test_player_resume():
    p = _src("src/player/player.zig")
    if ("pub fn load_file" in p and "pub fn saveCurrentPosition" in p
            and "pub fn tryResumePosition" in p):
        return "pass", "load_file + save/resume position present"
    return "fail", "player load/resume not wired"


@test("Multi-Source Search Wired", "Search")
def test_multi_source_search():
    s = _src("src/services/search.zig")
    if ("pub fn submitQuery" in s and "pub fn triggerSearch" in s
            and "pub fn loadTorrentToPlayer" in s):
        return "pass", "universal + torrent + magnet load paths present"
    return "fail", "search paths not wired"


@test("Queue Persistence Wired", "Library")
def test_queue_wired():
    q = _src("src/services/queue.zig")
    if "pub fn addToQueue" in q and "pub fn playNextUnplayed" in q and "queue_count" in q:
        return "pass", "addToQueue + playNextUnplayed + count present"
    return "fail", "queue not wired"


@test("Transfers Content Wired", "Downloads")
def test_transfers_wired():
    t = _src("src/services/transfers.zig")
    if "pub fn renderTransfersContent" in t:
        return "pass", "transfers content renderer present"
    return "fail", "transfers not wired"


@test("Audio Visualizer", "Player")
def test_audio_visualizer():
    # Radio / podcasts / music have no video track, so mpv synthesises one:
    # `lavfi-complex` runs the audio through an ffmpeg filter that EMITS a video
    # stream (showwaves / showfreqs / showspectrum / avectorscope). ffmpeg does the
    # FFT — no PCM is plumbed into dvui and no audio thread of our own.
    # Strip comments before grepping for banned filters — the module comment
    # EXPLAINS the `gradients`/`nullsrc` hazard by name, and a naive substring match
    # flags the fixed code as broken. (Made this exact mistake once already.)
    def _code(text):
        out = []
        for line in text.splitlines():
            ls = line.lstrip()
            if ls.startswith("//"):
                continue
            out.append(line.split("//")[0] if "//" in line else line)
        return "\n".join(out)

    pl = _src("src/player/player.zig")
    pure_all = _src("src/player/visualizer_pure.zig")
    pure = pure_all
    # ...and only the IMPLEMENTATION, not the test block below it — the Zig test
    # asserts these filters are absent, so the literals legitimately appear there.
    pure_code = _code(pure_all.split("// ── Tests ──")[0])
    st = _src("src/ui/settings.zig")
    cfg = _src("src/core/config.zig")
    bz = _src("build.zig")

    checks = {
        "filter graph builder is pure": "pub fn lavfiComplex" in pure,
        "styles: waves/bars/spectrum/scope": all(f in pure for f in
                                                 ("showwaves", "showfreqs", "showspectrum", "avectorscope")),
        # A graph without `asplit [ao]` renders a lovely visualiser and plays NO
        # SOUND. Every style must keep the audio wired to the speakers.
        "audio still reaches the speakers": "asplit [ao]" in pure,
        # The accent reaches ffmpeg as three DECIMAL NUMBERS (u8 -> 0-255), so a
        # theme colour has no way to inject filter syntax. Safe by construction
        # rather than by a validator being correct.
        "colour cannot inject into the graph": "fn gradient(r: u8, g: u8, b: u8" in pure,
        # REGRESSION — the pretty way to build the gradient (a `gradients` source
        # plus a `nullsrc` stripe mask) HANGS mpv: infinite sources never EOF, so a
        # 3s file plays forever, podcasts never end and the next track never starts.
        # Everything must be derived from [aid1] alone.
        "no source filters (they hang playback)": ("gradients" not in pure_code
                                                   and "nullsrc" not in pure_code),
        # Upscaling 48 bars to 576px sets a 12:1 sample aspect and mpv stretches the
        # picture to 576x2640 unless the SAR is reset.
        "square pixels (setsar)": "setsar=1" in pure,
        # The graph maps [aid1] to [ao] AND [vo] — left set, it would replace a real
        # video file's picture with a waveform.
        "cleared on every load": 'mpv_set_property_string(self.mpv_ctx, "lavfi-complex", "")' in pl,
        # Setting the graph GIVES mpv a video track, so the "vid" observer fires
        # again — without the latch this re-sets the graph forever.
        "applied once per file (latch)": "vis_applied" in pl,
        "applied only when audio-only": "if (p.cached_vid_no) applyVisualizer(p)" in pl,
        "selectable in Settings": "Audio visualizer" in st,
        "persisted across restarts": '"audio_vis"' in cfg,
        "pure module is unit-tested": "visualizer_pure.zig" in bz,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "missing: " + ", ".join(bad)
    return "pass", "mpv lavfi-complex visualizer: 4 styles, audio preserved, colour validated"


@test("YouTube browse: suggestions + channels + player nav", "Browse")
def test_youtube_browse():
    yt = _src("src/services/youtube.zig")
    ytp = _src("src/services/youtube_pure.zig")
    st = _src("src/core/state.zig")
    bz = _src("build.zig")
    checks = {
        # Search suggestions: Google autocomplete parsed by a TESTED pure fn and
        # rendered through dvui's SuggestionWidget (arrow keys / Enter / Esc).
        "suggest parser is pure + routed": ("pub fn parseSuggestions" in ytp
                                            and "yt_pure.parseSuggestions(" in yt),
        "suggest endpoint built pure": "pub fn suggestUrl" in ytp and "yt_pure.suggestUrl(" in yt,
        "dropdown wired": "dvui.suggestion(" in yt and "addChoiceLabel(" in yt,
        # A stale suggestion list for an older query must never be shown/kept.
        "suggestions generation-guarded": "sugg_gen" in yt and "sugg_mutex" in yt,
        # Channels: id captured from both fetch paths, click opens the channel's
        # uploads, back button restores the search, id validated before argv.
        "channel id in state": "channel_id" in st and "%(channel_id)s" in yt,
        "channel click opens uploads": "openChannel(" in yt and "labelClick" in yt,
        "channel url validated pure": ("pub fn channelVideosUrl" in ytp
                                       and "yt_pure.channelVideosUrl(" in yt),
        "channel back button": "exitChannel" in yt,
        # SWR refresh re-runs the SEARCH — inside channel view that would
        # silently dump the user back to results.
        "swr gated in channel view": "!channel_mode.load(.acquire) and" in yt,
        # Play lands the user on the player, not just behind a closed drawer.
        "play goes to player view": "state.gotoPlayer()" in yt,
        # Durations: "1:15:03", not "75:03" — and no "+07" sign artifact (Zig
        # zero-pads signed ints with a forced sign).
        "hour-aware duration pure + routed": ("pub fn formatDuration" in ytp
                                              and yt.count("yt_pure.formatDuration(") >= 1),
        "pure module is unit-tested": "youtube_pure.zig" in bz,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "missing: " + ", ".join(bad)
    return "pass", "suggestions dropdown + clickable channels + play→player wired"


@test("YouTube card: sticky icon actions, compact footer", "Browse")
def test_youtube_card_footer():
    """Regression + redesign: the Play/Queue buttons were clipped to a sliver on
    any card whose title wrapped to two lines, because they lived in the fixed-
    height footer below the title. Fix: they're now ICON-only buttons stuck to
    the THUMBNAIL (thumbActionIcon), independent of the footer, so a tall title
    can never clip them. The footer carries only the (compact) title + meta."""
    yt = _src("src/services/youtube.zig")
    checks = {
        # Sticky thumbnail-anchored icon buttons (no text), Play + Queue.
        "sticky icon action helper": "fn thumbActionIcon(" in yt,
        "play + queue icons wired": "thumbActionIcon(idx + 171, icons.tvg.lucide.play, true)" in yt
            and "thumbActionIcon(idx + 172, icons.tvg.lucide.plus, false)" in yt,
        "actions anchored bottom-left of thumb": ".gravity_x = 0.0," in yt and ".gravity_y = 1.0," in yt,
        # Thumbnail is a plain box now (a wrapping button would eat the icon
        # clicks — parent processes events before children).
        "thumbnail not a button": "var thumb = dvui.box(@src()" in yt,
        # No text-button actions row in the footer any more.
        "footer actions row removed": 'dvui.button(@src(), "Play"' not in yt
            and 'dvui.button(@src(), "Queue"' not in yt,
        # Compact fonts: title at body size, meta smaller.
        "compact title font": "fn titleFont()" in yt
            and "font_heading.withSize(theme.font_size.body)" in yt,
        "compact meta font": "fn metaFont()" in yt and ".font = metaFont()," in yt,
        # Footer height reserved from the SAME title font, title clamped to 2 lines.
        "footer reserves title font": "const title = titleFont();" in yt
            and "2.0 * title.lineHeight()" in yt,
        "title clamped to two lines": ".h = 2.0 * titleFont().lineHeight()" in yt,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "card redesign: " + ", ".join(bad)
    return "pass", "Play/Queue are sticky thumbnail icon buttons; compact footer can't clip them"


@test("macOS Now Playing media keys", "Player")
def test_macos_now_playing():
    # Native MPNowPlayingInfoCenter + MPRemoteCommandCenter bridge: the ObjC
    # file, build wiring (compile .m + link MediaPlayer, macOS-guarded), Zig
    # externs matching the .m symbols, and the frame-loop poll/update + exit
    # clear in main.zig. Real media-key presses need a manual check.
    m = _src("src/macos/media_remote.m")
    z = _src("src/player/media_remote.zig")
    zp = _src("src/player/media_remote_pure.zig")
    bz = _src("build.zig")
    mn = _src("src/main.zig")
    externs = ("opal_media_remote_init", "opal_media_remote_poll",
               "opal_nowplaying_update", "opal_nowplaying_clear")
    checks = {
        "objc centers": "MPNowPlayingInfoCenter" in m and "MPRemoteCommandCenter" in m,
        "objc handlers ack": "MPRemoteCommandHandlerStatusSuccess" in m,
        "objc commands": all(s in m for s in
            ("playCommand", "pauseCommand", "togglePlayPauseCommand",
             "changePlaybackPositionCommand", "skipForwardCommand", "skipBackwardCommand")),
        "build compiles .m": "src/macos/media_remote.m" in bz,
        "build links framework": 'linkFramework("MediaPlayer"' in bz,
        "externs match .m": all(s in m and s in z for s in externs),
        # macOS AND not headless — the server build stops compiling
        # media_remote.m (build.zig Phase S1), so the externs must be
        # comptime-unreachable there too.
        "zig macos guard": "const enabled = builtin.os.tag == .macos and !@import(\"build_options\").headless;" in z
            and "if (!enabled) return;" in z,
        "zig player guard": "active_player_idx >= state.app.players.items.len" in z,
        "pure decode/clamp routed": "clampSeekTarget" in zp and "clampSeekTarget" in z
            and "pure.decode" in z,
        "frame poll wired": 'media_remote.zig").frameTick()' in mn,
        "exit clear wired": 'media_remote.zig").clear()' in mn,
    }
    missing = [k for k, v in checks.items() if not v]
    if not missing:
        return "pass", "ObjC bridge + MediaPlayer link + frame poll/update + exit clear wired"
    return "fail", f"now-playing wiring missing: {missing}"


@test("Playlist: shuffle/repeat/reorder/save", "Player")
def test_playlist_roundtrip():
    # Pure advance engine registered in the unit-test step.
    if "src/player/playlist_pure.zig" not in _src("build.zig"):
        return "fail", "playlist_pure.zig not registered in build.zig test step"
    # player.zig routes end-of-file through the playlist advance path...
    if "playlist_ui.advance(p" not in _src("src/player/player.zig"):
        return "fail", "player.zig auto-advance does not route through playlist.advance"
    # ...and that path decides indices via the tested pure functions.
    pl = _src("src/player/playlist.zig")
    if "pure.nextIndex(" not in pl or "pure.prevIndex(" not in pl:
        return "fail", "playlist.zig does not route through playlist_pure nextIndex/prevIndex"
    if "buildShuffleOrder(" not in pl:
        return "fail", "shuffle order not built via playlist_pure.buildShuffleOrder"
    # Drawer UI: shuffle toggle, repeat cycle, reorder, save.
    for marker, what in (("playlist_shuffle", "shuffle toggle"),
                         ("playlist_repeat", "repeat cycle"),
                         ("moveEntry(", "reorder buttons"),
                         ("savePlaylist()", "save button")):
        if marker not in pl:
            return "fail", f"playlist.zig missing {what} ({marker})"
    # M3U writer exists and the save path routes through it.
    m = _src("src/player/m3u.zig")
    if "pub fn serialize" not in m or "appendEntryLines(" not in m:
        return "fail", "m3u.zig writer (serialize/appendEntryLines) missing"
    if "serialize(alloc)" not in pl:
        return "fail", "playlist save does not route through m3u serialize()"
    # Repeat/shuffle persisted like auto_advance.
    c = _src("src/core/config.zig")
    if "playlist_repeat" not in c or "playlist_shuffle" not in c:
        return "fail", "playlist repeat/shuffle not persisted in config"
    return "pass", "pure advance engine wired into player + drawer UI + m3u save"


@test("Downloader: segments/resume/limit/queue", "Transfers")
def test_http_downloader():
    # IDM-class HTTP downloader: segmented Range downloads, sidecar resume,
    # retry/backoff, a global token-bucket speed limit and a FIFO scheduler.
    # The engine must ROUTE through the unit-tested pure module (no drift).
    pure = _src("src/services/download_pure.zig")
    eng = _src("src/services/download_engine.zig")
    glue = _src("src/services/downloads.zig")
    tr = _src("src/services/transfers.zig")
    st = _src("src/core/state.zig")
    cfg = _src("src/core/config.zig")
    bz = _src("build.zig")
    checks = {
        # Pure module registered + engine routes through it.
        "pure module unit-tested": "download_pure.zig" in bz,
        "segment plan routed": "planSegments(" in pure and "dp.planSegments(" in eng,
        "segment count heuristic routed": "pickSegmentCount(" in pure and "dp.pickSegmentCount(" in eng,
        "token bucket routed": "pub fn take(" in pure and "dp.take(" in eng,
        "backoff routed": "pub fn backoffMs(" in pure and "dp.backoffMs(" in eng,
        "rolling speed window routed": "SpeedWindow" in pure and "speed.rate(" in eng,
        # Transport: real Range + If-Range validation strings.
        "range requests": '"Range"' in eng and "bytes={d}-{d}" in eng,
        "if-range validation": '"If-Range"' in eng,
        "range probe": "bytes=0-0" in eng and "partial_content" in eng,
        # Persistence: sidecar written during download, parsed on restart.
        "sidecar persistence": ".opal-part.json" in eng and "writePartMeta" in pure,
        "sidecar restore on launch": "restoreSidecar" in glue and "parsePartMeta" in glue,
        # Retry + stall detection.
        "per-segment retry budget": "MAX_RETRIES" in eng and "retryWait" in eng,
        "stalled segment reconnect": "STALL_MS" in eng and "seg_kick" in eng,
        # Config keys: segment count / max concurrent / shared speed limit.
        "config keys": ("http_dl_segments" in st and "http_dl_max_concurrent" in st
                        and 'setKey("http_dl_segments"' in cfg
                        and 'setKey("http_dl_max_concurrent"' in cfg),
        "speed limit wired": "cfg_rate_bps" in eng and "download_rate_limit" in glue,
        # Scheduler: capped concurrency, FIFO queue with a visible Queued state.
        "fifo scheduler": "cfg_max_concurrent" in eng and "fn schedule(" in eng,
        "queued state visible": '"Queued"' in tr and ".queued" in eng,
        # UI: rows in the transfers view with segment mini-bars, pause/resume.
        "transfer rows render": "renderHttpRows" in tr and "seg_frac" in tr,
        "pause/resume buttons": "engine.pause(" in tr and "engine.resumeDl(" in tr,
        # Positional (pwrite-style) writes into a preallocated part file.
        "positional writes": "writePositionalAll" in eng and "setLength" in eng,
        # Paste-a-URL entry point in the transfers control bar (clipboard →
        # startUrl for http(s); magnets diverted to the torrent path).
        "paste-url affordance": ('"＋ URL"' in tr and "dvui.clipboardText()" in tr
                                 and "httpdl.startUrl(clip)" in tr),
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "missing: " + ", ".join(missing)
    return "pass", "segmented Range engine + sidecar resume + token bucket + FIFO queue"


@test("Audio delay + device picker", "Player")
def test_audio_delay_device_picker():
    inp = _src("src/ui/input.zig")
    st = _src("src/ui/settings.zig")
    pk = _src("src/ui/pickers.zig")
    ft = _src("src/ui/footer.zig")
    pure = _src("src/player/av_device_pure.zig")
    bz = _src("build.zig")
    checks = {
        # Ctrl+= / Ctrl+- nudge lip-sync by ±100ms, Ctrl+0 resets — with a
        # toast showing the resulting value (mirrors the speed keys).
        "audio-delay keys wired": ("add audio-delay 0.1" in inp
                                   and "add audio-delay -0.1" in inp
                                   and "set audio-delay 0" in inp),
        "cheat sheet documents it": ("Audio Delay +100ms / -100ms" in st
                                     and "Reset Audio Delay" in st),
        # Output device picker: drop-up reads mpv's audio-device-list and sets
        # audio-device; active device highlighted ("auto" default).
        "picker reads device list": ("audio-device-list" in pk
                                     and '"audio-device"' in pk),
        "picker chip + popover in footer": ("audio_device" in ft
                                            and "renderAudioDevicePickerPopover" in ft),
        "settings Playback entry point": ("Audio Output" in st
                                          and "audio-device-list" in st),
        # JSON parsing is pure (escaped quotes, truncation, capacity clamps)
        # and BOTH call sites route through it — no drift.
        "pure parser exists + tested": ("pub fn parseAudioDevices" in pure
                                        and "truncated JSON must not crash" in pure),
        "call sites route through parser": ("parseAudioDevices(" in pk
                                            and "parseAudioDevices(" in st),
        "registered in zig build test": "av_device_pure.zig" in bz,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "missing: " + ", ".join(bad)
    return "pass", "audio-delay keys + cheat sheet + device picker via pure JSON parser"


@test("Scam torrent flagging + block", "Search")
def test_scam_torrent_flagging():
    # Heuristics live in a TESTED pure module; both result views badge risky
    # rows and every load path (play, double-click, queue, drag) is guarded.
    rp = _src("src/services/torrent_risk_pure.zig")
    sz = _src("src/services/search.zig")
    rz = _src("src/services/resolver.zig")
    bz = _src("build.zig")
    checks = {
        "pure module unit-tested": "torrent_risk_pure.zig" in bz,
        "assess is pure + routed": ("pub fn assess" in rp
                                    and sz.count("torrent_risk_pure.zig") >= 2
                                    and sz.count(".assess(") >= 2),
        # exe/scr/archive bait, password bait, implausible-size all present.
        "exe heuristic": '"exe"' in rp and '"scr"' in rp,
        "archive heuristic": '"rar"' in rp and '"zip"' in rp,
        "password bait": "password" in rp,
        "size heuristic": "5 * 1024 * 1024" in rp,
        # Central guard: universal row clicks/play all funnel through playItem.
        "playItem central guard": "Blocked scam torrent" in rz,
        # Torrent-tab card: play, double-click, queue, and drag all guarded.
        "torrent tab guards": sz.count("Blocked scam torrent") >= 4,
        "drag guarded": "risk.risk != .block" in sz,
        # Visible flags in both views, with the reason spelled out on cards.
        "universal flag chip": '"Scam?"' in sz,
        "card reason label": "playback disabled" in sz,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "missing: " + ", ".join(bad)
    return "pass", "pure heuristics routed; badges + play/queue/drag blocks in both views"


@test("VirusTotal hash lookup", "Security")
def test_virustotal_lookup():
    vtp = _src("src/services/virustotal_pure.zig")
    se = _src("src/services/search.zig")
    tr = _src("src/services/transfers.zig")
    bz = _src("build.zig")
    checks = {
        # Pure module: btih extraction (hex + base32) + URL builders, unit-tested.
        "pure module registered in build.zig": "virustotal_pure.zig" in bz,
        "pure fns exported": ("pub fn infoHashFromMagnet" in vtp
                              and "pub fn searchUrl" in vtp
                              and "pub fn fileUrl" in vtp),
        # Torrent search context menu routes through the TESTED pure extractor.
        "search menu item": "Check on VirusTotal" in se,
        "menu routes through pure fn": "infoHashFromMagnet(" in se and "searchUrl(" in se,
        "no-hash fallback toast": "No info-hash in this result" in se,
        # Downloads: user action streams the file through BOTH digests with a
        # heap buffer (multi-GB files — never slurped, never stack-allocated).
        "transfers action": "Verify on VirusTotal" in tr,
        "streams sha256+md5": ("sha2.Sha256" in tr and "hash.Md5" in tr
                               and "alloc.alloc(u8, 256 * 1024)" in tr),
        "busy guard + hashing state": "VtHash.busy" in tr and "Hashing…" in tr,
        "opens report via pure url": "fileUrl(" in tr and "openExternal(" in tr,
        # STRICTLY user-triggered deep links: the app must never call the VT
        # API itself — only virustotal.com/gui/... pages opened in the browser.
        "deep links only, no VT API": ("virustotal.com/gui" in vtp
                                       and "www.virustotal.com/api" not in vtp
                                       and "www.virustotal.com/api" not in se
                                       and "www.virustotal.com/api" not in tr),
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "missing: " + ", ".join(bad)
    return "pass", "user-triggered VT deep links: magnet btih + file sha256/md5"


@test("Anime-Skip auto-skip", "Player")
def test_anime_skip():
    pure = _src("src/services/anime_skip_pure.zig")
    svc = _src("src/services/anime_skip.zig")
    bz = _src("build.zig")
    st = _src("src/core/state.zig")
    cfg = _src("src/core/config.zig")
    setg = _src("src/ui/settings.zig")
    mn = _src("src/main.zig")
    pl = _src("src/player/player.zig")
    an = _src("src/services/anime.zig")
    ft = _src("src/ui/footer.zig")
    checks = {
        # Pure module registered + routed (tested logic IS shipped logic).
        "pure module in build.zig": "anime_skip_pure.zig" in bz,
        "pure exports builders/decision": ("pub fn buildRequestBody" in pure
                                           and "pub fn parseResponse" in pure
                                           and "pub fn buildSkipSegments" in pure
                                           and "pub fn shouldSkip" in pure),
        "point->range conversion routed": "buildSkipSegments(" in svc,
        "parse routed": "parseResponse(" in svc,
        "shouldSkip routed": "shouldSkip(" in svc,
        # Service hits the exact API contract.
        "graphql endpoint": "api.anime-skip.com/graphql" in svc,
        "X-Client-ID header": "X-Client-ID" in svc,
        "findEpisodeByName query": "findEpisodeByName" in pure,
        # Seek reuses the player's absolute-seek path + shows a toast.
        "seek absolute path": "absolute" in svc and "mpv_command_string" in svc,
        "skip toast": "Skipped" in svc,
        # Config keys persisted (save + load) — mirrors sponsorblock.
        "state master + per-type bools": ("anime_skip_enabled" in st
                                          and "anime_skip_intro" in st
                                          and "anime_skip_recap" in st
                                          and "anime_skip_credits" in st
                                          and "anime_skip_preview" in st),
        "config save keys": "setKey(\"anime_skip_enabled\"" in cfg,
        "config load keys": "\"anime_skip_intro\"" in cfg,
        # Defaults: intro/recap ON, credits/preview OFF.
        "defaults intro+recap on": ("anime_skip_intro: bool = true" in st
                                    and "anime_skip_recap: bool = true" in st),
        "defaults credits+preview off": ("anime_skip_credits: bool = false" in st
                                        and "anime_skip_preview: bool = false" in st),
        # Settings UI section with master + per-type toggles.
        "settings section": "Anime Skip" in setg and "anime-skip.com" in setg,
        "settings toggles": ("&state.app.anime_skip_enabled" in setg
                            and "&state.app.anime_skip_intro" in setg),
        # tick() wired into the frame loop.
        "tick wired in main loop": "anime_skip.zig\").tick()" in mn,
        # Anime-only gating: per-player arm consumed on file load, set by anime.
        "per-player gating flag": "anime_skip_active" in pl,
        "arm consumed on load": "onFileLoad(self)" in pl,
        "anime load triggers fetch": "onEpisodeLoad(" in an,
        # Manual "Skip" affordance in the control bar — appears only inside a
        # known segment (currentSkippable) and seeks past it (skipNow), routed
        # through the pure type->label mapping.
        "pure exports skip button label": "pub fn skipButtonLabel" in pure,
        "footer offers manual skip": ("anime_skip.currentSkippable()" in ft
                                      and "anime_skip.skipNow()" in ft),
        "footer label routed through pure": "skipButtonLabel(" in ft,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "missing: " + ", ".join(bad)
    return "pass", "anime-skip: findEpisodeByName → point→range → gated auto-seek"


@test("Torrent file loading", "Player")
def test_torrent_file_loading():
    # Bug: opening a .torrent FILE dead-ended. Two-part root cause — (1) the
    # router had no torrent route so a .torrent fell through to the catch-all
    # `.web` and was handed to the in-app web browser, and (2) the C++ wrapper
    # only exposed torrent_add_magnet, with no add-from-file API at all.
    cpp = _src("src/torrent_wrapper.cpp")
    hdr = _src("src/torrent_wrapper.h")
    pure = _src("src/services/browser_pure.zig")
    br = _src("src/services/browser.zig")
    se = _src("src/services/search.zig")
    checks = {
        "C API in .cpp": 'extern "C" int torrent_add_file(' in cpp,
        "C API in .h": "int torrent_add_file(TorrentSession" in hdr,
        "torrent route exists": "torrent }" in pure and "return .torrent" in pure,
        "loadContent dispatches torrent": "route == .torrent" in br
            and "addTorrentFileToEngine" in br,
        "engine entry point": "pub fn addTorrentFileToEngine" in se
            and "c.mpv.torrent_add_file(" in se,
        # Both add paths must share the player setup — no duplicated ~70 lines.
        # The one-and-only `p.is_torrent = true` is the load-bearing assertion:
        # a second copy means the setup drifted back apart.
        "shared attachTorrentToPlayer": "fn attachTorrentToPlayer(" in se
            and "attachTorrentToPlayer(tid, magnet_link)" in se
            and "attachTorrentToPlayer(tid, path)" in se
            and se.count("p.is_torrent = true") == 1,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "missing: " + ", ".join(bad)
    return "pass", "torrent_add_file C API + .torrent route + shared player attach"


@test("Play queue row layout", "Player")
def test_queue_row_layout():
    """Regression: the queue's move/play/remove buttons were invisible on most rows.

    dvui's horizontal BoxWidget does not squeeze children — rectFor hands each
    child its FULL min size and subtracts from the remaining budget, so once the
    budget hits zero every LATER sibling is handed a zero-width rect. The row is
    [thumb][title/meta][actions] and the title box held UNCAPPED labels, whose
    min width is the whole rendered text width. Long titles therefore consumed
    the row and starved the action strip. The cap must stay on the labels.
    """
    q = _src("src/services/queue.zig")
    pure = _src("src/services/queue_layout_pure.zig")
    build = _src("build.zig")

    checks = {
        "pure module present": bool(pure),
        "actions width helper": "pub fn actionsW" in pure and "pub fn iconButtonW" in pure,
        "title budget helper": "pub fn titleCapW" in pure,
        "clamped, never negative": "MIN_TITLE_W" in pure and "@max(MIN_TITLE_W" in pure,
        "first-frame fallback": "FALLBACK_ROW_W" in pure,
        "has tests": pure.count('test "') >= 6,
        "test registered": 'b.path("src/services/queue_layout_pure.zig")' in build,

        # Production must route through the tested arithmetic, not re-derive it.
        "queue imports the pure module": 'queue_layout_pure.zig' in q,
        "row width read from parent": "dvui.parentGet().data().contentRect().w" in q,
        "actions reserved from live font": "layout.actionsW(" in q
            and "font_body.textHeight()" in q,
        "title cap applied": "layout.titleCapW(" in q,
        # The load-bearing assertion: both labels AND their box carry a cap.
        # Drop any one of them and the strip is starved again.
        "labels capped": q.count("max_size_content = .{ .w = title_w") >= 3,

        # The old byte-count truncation measured bytes, not pixels, so it neither
        # contained wide text nor scaled with the font — and could split a
        # multi-byte UTF-8 codepoint, rendering a replacement glyph.
        "byte truncation gone": "max_title" not in q and "title[0..@min(title.len" not in q,
        # 78px could not fit its own four buttons at the theme font, and being a
        # constant it did not grow with UI scale.
        "hardcoded 78px reservation gone": ".w = 78," not in q,

        # Header row has the same [label][...][buttons] shape and the same risk.
        "header label capped": ".w = 140," in q,
    }

    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "queue layout regression: " + ", ".join(bad)
    return "pass", "queue rows reserve the action strip; titles ellipsize to a scale-aware cap"


@test("Scrubber paints its layers instead of sizing widgets", "Player")
def test_scrubber_paint_layers():
    """Two regressions in one fix.

    (a) The five scrub layers were dvui boxes sized with
        `min_size_content.w = track_rect.w * frac`. A child's min size
        propagates to the parent's derived min (dvui takes max(specified,
        derived)), so the band ratcheted toward the whole row and squeezed the
        trailing duration to 0px — measured w=92.8 on frame 2, w=0.0 on frame 3
        with the string still correct. Users saw no total duration.

    (b) dvui's slider paints its filled portion with
        `color_bar orelse theme.highlight.fill` — it ignores color_fill. Left
        unset, that default blue bar covered all five Opal-styled layers, so
        the buffered fill, accent played fill and chapter pips were computed
        and painted every frame and then hidden."""
    ft = _src("src/ui/footer.zig")
    fp = _src("src/ui/footer_pure.zig")
    bz = _src("build.zig")

    scrub = ft.split("fn renderScrubber")[1].split("\nfn ")[0]

    checks = {
        # Pure geometry exists, is registered, and names the regression.
        "pure fillBar": "pub fn fillBar(" in fp,
        "pure markerAt": "pub fn markerAt(" in fp,
        "pure registered": "footer_pure.zig" in bz,
        "centering test": "fillBar centers the track" in fp,
        "no-overhang test": "markerAt spans flush-left to flush-right" in fp,
        "nan guard test": "fillBar refuses to emit a NaN rect" in fp,
        # Production paints through the pure geometry.
        "paints via fillBar": "footer_pure.fillBar(" in scrub,
        "paints via markerAt": "footer_pure.markerAt(" in scrub,
        "uses Rect.fill": "r.fill(dvui.Rect.Physical.all(" in scrub,
        # (a) No layer may reintroduce a track-width min size — that is the bug.
        "no track-width min": "min_size_content = .{ .w = track_rect.w" not in scrub,
        # (b) The seek slider must stay invisible, color_bar included.
        "slider color_bar transparent": ".color_bar = invisible" in scrub,
        "slider stays input-only": ".color_fill = invisible" in scrub and ".background = false" in scrub,
        # The trailing duration still routes through the tested formatter.
        "duration formatted purely": "footer_pure.formatTrailing(" in scrub,
        # REGRESSION: the row pinned max_size_content.h = 26, which clipped its
        # OWN text — the elapsed/total clocks lost their descenders and the
        # hover-time chip was cut off top and bottom. 26 must stay a floor.
        "row height is a floor": ".min_size_content = .{ .w = 0, .h = 26 }" in scrub,
        "row height is not capped": ".max_size_content = .{ .w = 0, .h = 26 }" not in scrub,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "scrubber paint/duration fix incomplete: " + ", ".join(missing)
    return "pass", ("scrub layers painted via tested footer_pure geometry (no min-size "
                    "propagation, so the trailing duration keeps its width) and the seek "
                    "slider is fully transparent including color_bar")


@test("Control bar v2 affordances are wired, not just tested", "Player")
def test_control_bar_v2_wired():
    """footer_pure.zig grew a tested pure layer for the v2 control bar, but
    twelve of its functions were never called from footer.zig — tested logic
    that shipped nothing. Each one now drives real UI:

      timeLabelWidth   both clocks reserve their widest string, so the seek
                       band stops twitching sideways at 9:59 -> 10:00
      hoverChipWidth / centeredGravityX
                       the hover preview is centred on the pointer and clamped
                       inside the track (it used to drift a chip-width off at
                       exactly the two ends people scrub to)
      bufferedAheadEnd the contiguous downloaded run AHEAD of the playhead,
                       which is what predicts a stall; total completion does not
      volumeLevel      speaker glyph tracks the level, not just the mute flag
      transportState / transportLabel / transportBusy
                       "Loading..." vs "Buffering..." vs a deliberate pause
      barLayout        sheds control groups widest-first so the close button is
                       never clipped off the end in a small grid cell"""
    ft = _src("src/ui/footer.zig")
    fp = _src("src/ui/footer_pure.zig")

    wired = [
        "timeLabelWidth", "hoverChipWidth", "centeredGravityX", "bufferedAheadEnd",
        "fillSegment", "volumeLevel", "transportState", "transportLabel",
        "transportBusy", "barLayout",
    ]
    missing = [fn for fn in wired if f"footer_pure.{fn}(" not in ft]
    if missing:
        return "fail", "pure fns tested but never called from footer.zig: " + ", ".join(missing)

    # Every exported pure fn must be reachable from production, directly or via
    # another pure fn — otherwise it is coverage that ships nothing.
    import re
    exported = re.findall(r"^pub fn (\w+)\(", fp, re.M)
    orphans = []
    for fn in exported:
        if f"footer_pure.{fn}(" in ft:
            continue
        # transitively used inside footer_pure by a shipped function?
        if len(re.findall(rf"\b{fn}\(", fp)) > 1:
            continue
        orphans.append(fn)
    if orphans:
        return "fail", "unreachable pure fns (delete or wire them): " + ", ".join(orphans)

    checks = {
        # barLayout must gate real groups, not be computed and ignored.
        "layout computed": "footer_pure.barLayout(bar_pt)" in ft,
        "gates volume": "if (fit.volume_slider)" in ft,
        "gates chips": "if (fit.secondary_chips)" in ft,
        "gates badges": "if (fit.status_badges)" in ft,
        "gates skips": "fit.skip_buttons" in ft,
        # Width measured in on-screen points, same rule as the shell.
        "width in points": "layoutPoints(" in ft and "state.app.ui_scale" in ft,
        # Thresholds record the measurement that set them.
        "thresholds measured": "clipped the close button" in fp,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        return "fail", "control bar v2 wiring incomplete: " + ", ".join(bad)
    return "pass", (f"all {len(exported)} footer_pure exports reachable from production; "
                    "barLayout sheds volume -> chips -> badges -> skips so the close "
                    "button survives at 460pt (verified on screen at 1200/850/700/460)")


@test("Loading screen shows art + rotating facts for every source", "Player")
def test_loading_screen_infotainment():
    """The buffering screen was a hourglass plus, for TMDB movie/TV plays only,
    a poster and ONE static paragraph. Three problems:

      (a) The art field held a bare TMDB path fragment and the renderer pasted
          the TMDB image base in front of it, so an absolute cover URL from
          Subsonic/Jellyfin/Plex/JioSaavn was unusable — music could never show
          album art here, only the hourglass.
      (b) One paragraph sat unchanged for the whole wait. A torrent resolve
          plus first-parts buffering runs tens of seconds.
      (c) Nothing on the screen identified WHAT was loading beyond the title —
          no year, no score, no episode code, no artist."""
    gr = _src("src/ui/grid.zig")
    lp = _src("src/ui/loading_pure.zig")
    st = _src("src/core/state.zig")
    pl = _src("src/player/player.zig")
    tm = _src("src/services/tmdb.zig")
    mu = _src("src/services/music_subsonic.zig")
    bz = _src("build.zig")

    checks = {
        # Pure layer exists, registered, and drives production.
        "pure registered": "loading_pure.zig" in bz,
        "pure posterUrl": "pub fn posterUrl(" in lp,
        "pure splitFacts": "pub fn splitFacts(" in lp,
        "pure cardIndex": "pub fn cardIndex(" in lp,
        "pure metaLine": "pub fn metaLine(" in lp,
        "render uses posterUrl": "lpure.posterUrl(" in gr,
        "render uses splitFacts": "lpure.splitFacts(" in gr,
        "render uses cardIndex": "lpure.cardIndex(" in gr,
        "render uses metaLine": "lpure.metaLine(" in gr,
        # (a) One art field that takes a fragment OR an absolute URL, and the
        # TMDB base is no longer pasted on at the call site.
        "art field widened": "pending_play_art: [256]u8" in st and "loading_art: [256]u8" in pl,
        "no hardcoded tmdb base in render": "image.tmdb.org" not in gr,
        "music stashes cover": "coverUrlFor(song" in mu and "stashPendingPlayFull(" in mu,
        # REGRESSION: media reaches a player two ways — the torrent path and the
        # direct-URL path (music, Jellyfin, every stream). The stash was only
        # consumed on the torrent path, so a direct-play source could stash art
        # that was never picked up and never shown.
        "one stash consumer": "pub fn consumePendingPlay(" in st,
        "torrent path consumes": "state.consumePendingPlay(p);" in _src("src/services/search.zig"),
        "direct path consumes": "pub fn playDirect(" in _src("src/services/browser.zig")
            and "state.consumePendingPlay(p);" in _src("src/services/browser.zig"),
        # Podcasts, radio, IPTV, Audiobookshelf and the browser extension all
        # already hand loadContentDirectMeta an art URL + title. Deriving the
        # loading context from those covers every one of them without editing
        # two dozen call sites; a caller that stashed richer data still wins.
        "art falls back to now-playing": "fn stashFromNowPlaying(" in _src("src/services/browser.zig"),
        "explicit stash wins": "if (state.app.pending_play_title_len > 0" in _src("src/services/browser.zig"),
        "one cover resolver": "pub fn coverUrlFor(" in mu,
        # (b) Cards rotate and can be paged by hand.
        "deck state": "loading_card_manual" in pl and "loading_card_since_ms" in pl,
        "pager rendered": '"fact-prev"' in gr and '"fact-next"' in gr,
        "no unsigned underflow": "cards.count - 1" in gr,
        # (c) Meta line fed by every source that knows more than a title.
        "kind + year + rating stashed": "pending_play_kind" in st and "pending_play_rating" in st,
        "movie passes year+rating": "item.rating," in tm,
        "episode passes code": '"S{d}E{d}"' in tm,
        # Regression guards from the pure tests.
        "absolute-url test": "posterUrl expands a TMDB fragment and passes an absolute URL through" in lp,
        "abbreviation test": "splitFacts does not break on abbreviations or decimals" in lp,
        "unrated test": "metaLine omits an unrated score instead of printing zero" in lp,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "loading screen enhancement incomplete: " + ", ".join(missing)
    return "pass", ("loading screen resolves art for any source (TMDB fragment or absolute "
                    "cover URL), shows a kind/year/score/artist meta line, and rotates "
                    "summary facts on a pageable deck")


@test("Loading screen: contained art, readable type, real progress", "Player")
def test_loading_screen_progress():
    """A user screenshot of the buffering screen showed four things wrong:

      (a) the w500 poster was drawn with `.expand = .both`, i.e. upscaled ~3x
          across the whole cell — soft, colour-cast, and it swamped the text;
      (b) the summary ended mid-word with a bare stump, because the [400]u8
          buffer it lives in had simply been cut;
      (c) the only progress indicator was a STATIC hourglass glyph — no rate,
          no peers, no buffer percentage, no elapsed time, so a working load
          and a hung one looked identical;
      (d) the fact deck loading_pure supports was only reachable on one path.

    Every layout/format decision behind the fix lives in loading_pure with
    tests; the dvui draw calls themselves are GUI-only and are not covered."""
    gr = _src("src/ui/grid.zig")
    lp = _src("src/ui/loading_pure.zig")

    checks = {
        # (a) Art is contained at native scale, never stretched to the cell.
        "pure posterFit": "pub fn posterFit(" in lp,
        "render uses posterFit": "lpure.posterFit(" in gr,
        "no full-bleed art": ".source = .{ .texture = p.loading_poster_tex.? } }, .{\n                                .id_extra = i + 3010,\n                                .expand = .both," not in gr,
        "upscale regression test": "posterFit contains, preserves aspect, and never upscales" in lp,
        # (b) Word-boundary truncation with a real ellipsis, upstream cut aware.
        "pure ellipsize": "pub fn ellipsizeWords(" in lp,
        "pure filledBuffer": "pub fn filledBuffer(" in lp,
        "render ellipsizes title": "lpure.ellipsizeWords(" in gr,
        "render flags upstream cut": "lpure.filledBuffer(" in gr,
        "real ellipsis not three dots": 'ELLIPSIS = "\\u{2026}"' in lp,
        "mid-word regression test": "ellipsizeWords cuts at a word boundary, never mid-word" in lp,
        "utf8 truncation test": "ellipsizeWords never splits a UTF-8 codepoint" in lp,
        # (c) Real progress: phase, buffer %, rate, swarm, elapsed, piece bar.
        "pure phase": "pub fn phaseOf(" in lp and "pub fn phaseLabel(" in lp,
        "pure statusLine": "pub fn statusLine(" in lp,
        "pure rate": "pub fn formatRate(" in lp,
        "pure elapsed": "pub fn formatElapsed(" in lp,
        "pure percent clamp": "pub fn percentOf(" in lp and "pub fn clampPercent(" in lp,
        "pure piece buckets": "pub fn pieceBuckets(" in lp,
        "render shows phase": "lpure.phaseLabel(" in gr and "lpure.phaseOf(" in gr,
        "render shows swarm": "lpure.statusLine(" in gr,
        "render shows buffer pct": "lpure.percentOf(" in gr and "lpure.clampPercent(" in gr,
        "render polls swarm": "torrent_get_num_peers" in gr and "torrent_get_piece_map" in gr,
        "render draws piece bar": "lpure.pieceBuckets(" in gr,
        # A missing value is omitted, never printed as a zero that reads as a
        # stall — the whole point of the readout.
        "omits unknown rate": 'formatRate omits a rate it does not have' in lp,
        "omits unknown swarm": "statusLine drops every element it does not have" in lp,
        "never rounds up to 100": "percentOf clamps and refuses to round a partial buffer up to 100" in lp,
        # Bars are PAINTED: a child min_size_content ratchets the parent's
        # derived minimum and silently clips sibling text (footer.zig hit this).
        "bars painted, not widgets": "fpure.fillBar(" in gr and "rr.fill(" in gr,
        "no per-frame C polling": "now_ms - Swarm.at_ms[slot] > 500" in gr,
        # (d) Responsive: the screen lives in a grid cell that can be small.
        "pure layout breakpoints": "pub fn layout(" in lp and "BREAK_FACTS_W" in lp,
        "render uses layout": "lpure.layout(" in gr and "lay.poster" in gr and "lay.facts" in gr,
        "layout regression test": "layout sheds poster then facts as the cell shrinks" in lp,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "loading screen polish incomplete: " + ", ".join(missing)
    return "pass", ("art contained at native scale, word-boundary ellipsis, and a live "
                    "phase/buffer/rate/peers/elapsed readout with a painted piece bar; "
                    "all decisions routed through loading_pure (dvui draws are GUI-only)")


@test("Picture presets: auto-HDR detection wired end to end", "Player")
def test_picture_presets():
    """One switch for colour/contrast/shadows, with an HDR-aware Auto.

    Opal renders via `vo=libmpv` + MPV_RENDER_API_TYPE_SW: mpv rasterises to a
    CPU buffer that SDL blits, so there is no swapchain to hand HDR metadata to
    and `target-colorspace-hint` has nothing to act on -- true HDR passthrough is
    not reachable from this architecture. What IS reachable, and is what people
    actually complain about, is that HDR material shown through an SDR path
    looks flat and grey because it was graded for a far higher peak luminance.

    The preset drives the same four equalizer properties Opal's Video Filters
    settings already drive, so this is a new way to set existing controls rather
    than a second pipeline.
    """
    avp = _src("src/player/av_pure.zig")
    ply = _src("src/player/player.zig")
    ftr = _src("src/ui/footer.zig")
    cfg = _src("src/core/config.zig")
    st = _src("src/core/state.zig")
    bld = _src("build.zig")

    checks = {
        # Pure policy, tested next to the values it defines.
        "preset enum": "pub const PicturePreset = enum" in avp,
        "values fn": "pub fn pictureValues(" in avp,
        "hdr detection": "pub fn isHdrVideo(" in avp,
        "auto resolution": "pub fn resolveAuto(" in avp,
        "corrupt config -> auto": "pub fn picturePresetFromInt(" in avp,
        # The gamut/dynamic-range distinction is the easy thing to get wrong.
        "bt.2020 alone is not HDR": "WIDE GAMUT" in avp or "gamut hint" in avp,
        "regression test for it": "bt.1886" in avp and "bt.2020" in avp,
        # Applied where colour metadata first exists, and on user change.
        "applied on file load": "applyPicturePreset(p);" in ply
                                and "MPV_EVENT_FILE_LOADED" in ply,
        "reads video-params": '"video-params/gamma"' in ply,
        "routes through pure": "av_pure.resolveAuto(" in ply,
        "clamps before setting": "av_pure.clampVideoFilter(" in ply,
        # Reachable from the transport bar, not buried in Settings.
        "control on the player bar": "picture_preset" in ftr,
        "applies to every player": "players.items) |p| player.applyPicturePreset" in ftr,
        # Persisted.
        "state field": "picture_preset: usize" in st,
        "config saves": 'setKey("picture_preset"' in cfg,
        "config loads via pure": "picturePresetFromInt(" in cfg,
        # Unit tests registered.
        "av_pure tests registered": "av_pure.zig" in bld,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "picture preset wiring incomplete: " + ", ".join(missing)
    return "pass", ("6 presets, Auto keyed off the transfer function (not the "
                    "gamut), applied on load + on change, persisted")


@test("Playback extras: only upstream mpv options, all opt-in", "Player")
def test_playback_extras():
    """Adopted from JJenkx/mpv-atmos-patched's tuning guide -- selectively.

    That project's headline features live in its OWN patched mpv+FFmpeg and are
    unreachable from a system mpv. Verified against the installed build on
    2026-08-01 with `mpv --list-options`:

        prefetch-playlist              present   -> adopted
        audio-spdif                    present   -> adopted
        audio-exclusive                present   -> adopted
        demuxer-cache-unselected-subs  ABSENT    -> not adopted
        http-segmented-connections     ABSENT    -> not adopted

    Setting an option mpv does not know is not harmless: mpv refuses to start
    with an unknown option, so a fork-only flag here would break playback
    outright on every system build.

    All three default OFF because each trades something real -- prefetch costs a
    second concurrent download (on a torrent, another swarm), passthrough is
    silence on hardware that cannot decode the bitstream, and exclusive mode
    mutes everything else on the machine.
    """
    ply = _src("src/player/player.zig")
    st = _src("src/core/state.zig")
    cfg = _src("src/core/config.zig")
    setg = _src("src/ui/settings.zig")

    FORK_ONLY = ("demuxer-cache-unselected-subs", "demuxer-cache-unselected-audio",
                 "http-segmented-connections", "http-segmented-chunk-size",
                 "http-segmented-auto-size", "prefetch-demuxer-max-bytes",
                 "http-segmented-prefetch-connections")
    # Comments name these to explain why they are excluded, so scan code only.
    ply_code = "\n".join(l for l in ply.splitlines()
                         if not l.lstrip().startswith("//"))
    leaked = [o for o in FORK_ONLY if o in ply_code]
    if leaked:
        return "fail", ("fork-only mpv options would break a system mpv at "
                        "startup: " + ", ".join(leaked))

    # TrueHD must not be advertised: upstream mpv cannot emit the MAT framing
    # Atmos needs, so offering it would promise silence.
    spdif = _re.search(r'"audio-spdif", "([^"]+)"', ply)
    if not spdif:
        return "fail", "audio-spdif not wired"
    if "truehd" in spdif.group(1).lower():
        return "fail", ("audio-spdif advertises truehd, which upstream mpv "
                        "cannot emit (that is why the atmos fork exists)")

    checks = {
        "prefetch wired": '"prefetch-playlist", "yes"' in ply,
        "exclusive wired": '"audio-exclusive", "yes"' in ply,
        "prefetch gated": "if (state.app.prefetch_playlist)" in ply,
        "passthrough gated": "if (state.app.audio_passthrough)" in ply,
        "exclusive gated": "if (state.app.audio_exclusive)" in ply,
        # Defaults must be off, or a toggle turns itself on for everyone.
        "prefetch defaults off": "prefetch_playlist: bool = false" in st,
        "passthrough defaults off": "audio_passthrough: bool = false" in st,
        "exclusive defaults off": "audio_exclusive: bool = false" in st,
        "persisted": all(f'setKey("{k}"' in cfg for k in
                         ("prefetch_playlist", "audio_passthrough", "audio_exclusive")),
        "loaded": all(f'"{k}")' in cfg for k in
                      ("prefetch_playlist", "audio_passthrough", "audio_exclusive")),
        "reachable in Settings": "Playback Extras" in setg,
        # These are read as options at init, so the UI must not imply they are live.
        "next-file caveat surfaced": "next file you open" in setg,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "playback extras incomplete: " + ", ".join(missing)
    return "pass", (f"3 upstream options (spdif={spdif.group(1)}), all default off, "
                    "no fork-only flags that would break a system mpv")


@test("Download limit: 0 means unlimited all the way to libtorrent", "Torrents")
def download_limit_unlimited_is_zero():
    """"No Limit" used to throttle instead of removing the throttle.

    settings_pack.hpp is explicit for `download_rate_limit`: "A value of 0 means
    unlimited." The wrapper translated <= 0 into **-1** — the convention for
    torrent_handle::set_download_limit(), not for this settings key. libtorrent
    hands a negative figure to the bandwidth manager, which then has nothing to
    hand out, so picking "No Limit" in any of the three pickers (Settings >
    Network, the footer cycle, the Transfers row) silently crippled the session
    while the UI kept showing "No Limit".

    Zig keeps 0 as the encoding end to end (sanitizeDownloadLimit) so no second
    translation gets invented at the FFI boundary again.
    """
    cpp = _src("src/torrent_wrapper.cpp")
    av = _src("src/player/av_pure.zig")
    st = _src("src/core/state.zig")

    setter = _between(cpp, "void torrent_set_download_limit(", "\n}")
    checks = {
        "wrapper never sends -1": "-1" not in setter,
        "wrapper passes 0 through as unlimited": "limit_bytes_per_sec > 0 ? limit_bytes_per_sec : 0" in setter,
        "zig collapses negatives to 0": "return if (v > 0) v else 0;" in av,
        # Applying 0 must reach the FFI, or "unlimited" can never clear a cap
        # that is already in force.
        "apply path does not skip zero": "if (lim <= 0) return;" not in st,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "unlimited-is-zero contract broken: " + ", ".join(missing)
    return "pass", "0 = unlimited from config through state to settings_pack"


@test("Download limit: the web API speaks KB/s, state speaks bytes/s", "Web UI")
def download_limit_units_converted():
    """The field is labelled KB/s and the value was stored as bytes/s.

    Typing 4096 into "Download limit (KB/s)" set the session to 4096 BYTES/s — a
    1024x throttle that looks exactly like a dead network, and reads back as
    "1048576 KB/s" after the desktop sets 1 MB/s. Both directions now go through
    the pure converters.
    """
    sap = _src("src/services/settings_api_pure.zig")
    rm = _remote_api()

    checks = {
        "converters exist": "pub fn rateBytesToKb(" in sap and "pub fn rateKbToBytes(" in sap,
        "label still promises KB/s": "Download limit (KB/s" in sap,
        "read converts to KB/s": "sap.rateBytesToKb(state.app.download_rate_limit)" in rm,
        "write converts to bytes/s": "sap.rateKbToBytes(n)" in rm,
        # A limit set from the web must take effect now, like the desktop
        # pickers, not on the next launch.
        "write applies to the live session": "state.applyDownloadLimitIfReady();" in rm,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "KB/s conversion incomplete: " + ", ".join(missing)
    return "pass", "KB/s on the wire, bytes/s in state, applied live"


@test("/api/load reports failure instead of a phantom success", "Web UI")
def api_load_honest_result():
    """It answered ok:true for a request it had ignored.

    /load read `url` from the query string only, so a POSTed body matched
    nothing — and it still replied {"ok":true,"action":"load"}. A client saw
    success while the player never moved. It now reads body-then-query (same
    helper as the credential routes) and says so when there is no url.
    """
    rm = _remote_api()
    body = _between(rm, 'api_path, "/load")', "// ── Status")
    checks = {
        "reads body then query": 'credParam(body, query, "url"' in body,
        "missing url is an error": '"error\\":\\"missing url' in body.replace('\\"', '\\"') or "missing url" in body,
        "empty url is an error": "empty url" in body,
        # The connection thread mutates player state; the UI loop must be told.
        "wakes the ui": "state.wakeUi();" in body,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "/load result handling incomplete: " + ", ".join(missing)
    return "pass", "body-or-query url, honest ok:false, UI woken"


@test("Torrent metadata cache round-trips its info-hash", "Torrents")
def torrent_metadata_cache_hash_stable():
    """Playing the same torrent twice used to be impossible.

    torrent_add_magnet caches metadata at <save_path>/<info-hash>.torrent and
    re-attaches it on a later add of the same magnet. The writer built that file
    with `create_torrent(*ti).generate()`, which does NOT preserve the info-hash:
    libtorrent 2.x rebuilds the info dict and emits v2 "file tree" structure for a
    v1 torrent. add_torrent then rejected the add with "mismatching info-hash",
    the Zig side reported "invalid or duplicate magnet", and that magnet stayed
    unplayable until the user deleted the file by hand. Verified against a local
    seeder: cold add plays, and the re-add with a cache present now plays too.

    Two halves, both required: write the ORIGINAL info section so the hash cannot
    drift, and refuse (and delete) a cache that does not match, so the caches
    already written by the old code heal themselves.
    """
    cpp = _src("src/torrent_wrapper.cpp")
    writer = _between(cpp, "static bool write_metadata_cache(", "\n}")
    checks = {
        "writer exists": bool(writer),
        # The original bencoded info dict, verbatim — the only thing that hashes
        # back to the same value.
        "writes the original info section": "info_section()" in writer
                                            and '"d4:info"' in writer,
        "no regenerate on the write path": "create_torrent" not in writer
                                           and "ct.generate()" not in cpp,
        "cache is validated before use": "cache_matches(atp, *cached_ti)" in cpp,
        "mismatched cache is deleted": "std::remove(cached_path.c_str())" in cpp,
        # A v1 magnet leaves v2 zeroed; a blanket == would reject a good hybrid.
        "match compares only the pinned versions": "want.has_v2() && got.has_v2()" in cpp
                                                   and "want.has_v1() && got.has_v1()" in cpp,
        # ready_flag must follow the metadata actually attached.
        "ready flag keyed on attached metadata": "if (atp.ti) {" in cpp,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "metadata cache can still poison a re-add: " + ", ".join(missing)
    return "pass", "cache writes the original info section and is verified on read"


@test("F F double-tap toggles fullscreen; one F does not", "Player")
def fullscreen_needs_a_double_tap():
    """A single F used to throw the window into fullscreen.

    F sits under the left hand right next to the transport keys, so a stray
    press was easy and the consequence was the whole window changing mode. It
    now needs a deliberate double-tap, matching double-click on the video — and
    sharing the same tracker, so the two gestures cannot drift apart in window
    length or edge-case handling (target change, triple-tap, backwards clock).

    Escape is deliberately untouched: leaving a mode should stay a single press.
    """
    ip = _src("src/ui/input_pure.zig")
    inp = _src("src/ui/input.zig")
    grid = _src("src/ui/grid.zig")
    setg = _src("src/ui/settings.zig")
    build = _src("build.zig")

    f_branch = _between(inp, "                    .f => {", "                    },")
    checks = {
        "pure gesture module exists": "pub const DoubleTap = struct" in ip
                                      and "pub const DOUBLE_TAP_MS" in ip,
        "registered for unit tests": "src/ui/input_pure.zig" in build,
        # The key handler must go through the tracker, not toggle directly.
        "F routes through the gesture": "S.gesture.tap(" in f_branch,
        "F only toggles on completion": "fullscreen_player_idx = state.app.active_player_idx"
                                        in f_branch and "if (S.gesture.tap(" in f_branch,
        # One implementation, not two.
        "mouse path shares the tracker": "DblClick.gesture.tap(" in grid,
        "no hand-rolled 500ms left": "now_ms - DblClick.last_click_ms < 500" not in grid,
        # Escape still exits in one press.
        "escape still single-press": "state.app.fullscreen_player_idx = null;" in
                                     _between(inp, "if (key == .escape)", "continue;"),
        "cheat sheet says double-tap": '"F F", "Toggle Fullscreen (double-tap)"' in setg,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "double-tap fullscreen incomplete: " + ", ".join(missing)
    return "pass", "F F toggles fullscreen via the shared double-tap tracker"


@test("Fullscreen puts the OS window fullscreen, not just the layout", "Player")
def fullscreen_reaches_the_window():
    """"Fullscreen" only ever expanded the player inside a normal window.

    fullscreen_player_idx meant "give this player the whole grid and hide the
    chrome". Nothing in the app had ever called SDL_SetWindowFullscreen, so every
    route to it — F F, double-clicking the video, the AI `fullscreen` action, the
    /fullscreen instant command — left the title bar, the dock and everything
    behind the window exactly where they were.

    The window is reconciled to the state once per frame rather than at each call
    site: they all move the same flag, Escape clears it too, and one reconcile
    cannot fall out of step the way five scattered SDL calls would.
    """
    mn = _src("src/main.zig")
    block = _between(mn, "Put the OS WINDOW into fullscreen", "player.updateTorrentBackgroundTasks();")
    checks = {
        "the SDL call exists at all": "SDL_SetWindowFullscreen" in mn,
        "driven by the shared state flag": "state.app.fullscreen_player_idx != null" in block,
        # Desktop fullscreen borrows the current resolution: no mode-change
        # flash, and exiting cannot strand the desktop at the video's size.
        "uses FULLSCREEN_DESKTOP": "SDL_WINDOW_FULLSCREEN_DESKTOP" in block,
        # One SDL call per real change, not one per frame.
        "latched against re-applying": "want != FsState.applied" in block,
        # A refused change must not be recorded as done.
        "latches only on success": "== 0) {" in block and "FsState.applied = want;" in block,
        # No call site should start poking SDL directly again.
        # Count the CALL, not the name — the comment above it names the
        # function too, and matching that made this read as two call sites.
        "no second call site": mn.count("c.sdl.SDL_SetWindowFullscreen(") == 1
                               and "SDL_SetWindowFullscreen(" not in _src("src/ui/input.zig")
                               and "SDL_SetWindowFullscreen(" not in _src("src/ui/grid.zig"),
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "window fullscreen not wired: " + ", ".join(missing)
    return "pass", "one per-frame reconcile drives SDL from fullscreen_player_idx"
