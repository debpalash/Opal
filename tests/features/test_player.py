"""Auto-split from tests/test_features.py — Player / Browse / Anime / Co-Watcher / Remote / Library / Downloads / Search tests.
Byte-for-byte identical test bodies; see tests/features/harness.py for the
shared @test decorator, helpers, and run_all()."""
from .harness import *  # noqa: F401,F403
import os, sys, subprocess, sqlite3, socket, time, json  # noqa: F401

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
        "adaptive render size": "dwidth" in gr and "textureDestroyLater" in gr,
    }
    missing = [k for k, v in checks.items() if not v]
    if not missing:
        return "pass", "coming-up rail + eztv availability + hwdec/native-size render wired"
    return "fail", f"missing: {missing}"


@test("Web Companion: Pairing + LAN Bind + Bundled Page", "Remote")
def test_web_companion():
    # Phase 1 of docs/web-companion.md: /pair code exchange is the ONLY way to
    # get the token (no injection into the unauthenticated page), server binds
    # LAN when the opt-in toggle is on, page served from Resources/web with a
    # dev fallback, Settings shows LAN URL + pairing code, build bundles it.
    rm = _src("src/services/remote.zig")
    stg = _src("src/ui/settings.zig")
    sh = open(os.path.join(PROJECT_DIR, "scripts/build-app.sh")).read()
    web = open(os.path.join(PROJECT_DIR, "web/index.html")).read()
    checks = {
        "pair route": '"/pair"' in rm and "regeneratePairCode" in rm,
        "brute-force guard": "MAX_PAIR_FAILS" in rm and "sleep(300" in rm,
        "no token injection": "replaceOwned" not in rm,
        "lan bind": '"0.0.0.0"' in rm and "127.0.0.1" not in _between(rm, "fn serverLoop", "std.debug.print"),
        "bundled serving": "resourceRoot" in rm and "web/index.html" in rm,
        "settings pairing ui": "pairingCode" in stg and "lanIp" in stg,
        "build bundles web": "Resources/web" in sh,
        "client pairs": "/pair?code=" in web and "localStorage" in web and "__ZIGZAG_API_TOKEN__" not in web,
    }
    missing = [k for k, v in checks.items() if not v]
    if not missing:
        return "pass", "pairing-code auth + LAN bind + bundled mobile page wired"
    return "fail", f"missing: {missing}"


@test("Hosted Mode: Stream/VTT/Poster + Docker + Perf Fixes", "Remote")
def test_hosted_mode_and_perf():
    # Headless hosting (docs/headless-hosting-spec.md H1+H2+H3 slice) and the
    # production CPU fixes from the 2026-07-10 profiling session.
    rs = _src("src/services/remote_stream.zig")
    rp = _src("src/services/remote_stream_pure.zig")
    rm = _src("src/services/remote.zig")
    hl = _src("src/headless.zig")
    al = _src("src/core/alloc.zig")
    gr = _src("src/ui/grid.zig")
    pl = _src("src/player/player.zig")
    dk = open(os.path.join(PROJECT_DIR, "Dockerfile")).read()
    ci = open(os.path.join(PROJECT_DIR, ".github/workflows/ci.yml")).read()
    web = open(os.path.join(PROJECT_DIR, "web/index.html")).read()
    checks = {
        "range streaming": "parseRange" in rp and "206 Partial Content" in rs,
        "srt→vtt": "srtToVtt" in rp and "handleVtt" in rs,
        "traversal guard": "safeRelPath" in rp and "safeRelPath" in rs,
        "query-token media auth": '"/stream"' in rm and 'getQueryParam(query, "t")' in rm,
        "parity routes": '"/calendar"' in rm and '"/tv"' in rm and '"/host"' in rm and '"/torrents"' in rm,
        "thread-per-conn + api mutex": "api_mutex" in rm and "Thread.spawn(.{}, Handler.run" in rm,
        "headless serves web": "web_remote_enabled = true" in hl and "pairingCode()" in hl,
        "docker headless build": "-Dheadless=true" in dk and "OPAL_PAIR_CODE" in dk and "3000" not in dk,
        "ci gate": "docker-headless" in ci and "/pair?code=123456" in ci,
        "hosted web player": "openPlayer" in web and "/stream?file=" in web and "/vtt?file=" in web,
        "web torrent progress": "pollTorrents" in web,
        "browser-first setup": '"/setup/sources"' in rm and "installStarterPack" in rm and "loadSetup" in web,
        "sse push": '"/events"' in rm and "text/event-stream" in rm and "buildStatusJson" in rm and "EventSource" in web,
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
    with open(os.path.join(PROJECT_DIR, "plugins-manifest.json")) as fh:
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
        "zig macos guard": "builtin.os.tag != .macos" in z,
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
