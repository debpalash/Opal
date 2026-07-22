"""Auto-split from tests/test_features.py — Page Shell (part 3) tests.
Byte-for-byte identical test bodies; see tests/features/harness.py for the
shared @test decorator, helpers, and run_all()."""
from .harness import *  # noqa: F401,F403
import os, sys, subprocess, sqlite3, socket, time, json  # noqa: F401

@test("Watching library: all kinds, next-up, user status", "Page Shell")
def test_tv_tracking():
    # TV tracking used to be ~80% built and quietly wrong: next-up could not
    # cross a season, tv_continue stored the LAST WATCHED episode (so every
    # consumer re-derived "what's next" and none agreed), there was no
    # per-episode resume, and nothing clamped next-up to what had actually aired.
    pure = _src("src/services/tv_pure.zig")
    lib = _src("src/services/tv_library.zig")
    dbz = _src("src/core/db.zig")
    tm = _src("src/services/tmdb.zig")
    cal = _src("src/services/tv_calendar.zig")
    pl = _src("src/player/player.zig")
    st = _src("src/core/state.zig")
    sh = _src("src/ui/shell.zig")
    rt = _src("src/core/router.zig")
    checks = {
        # The engine, and the fact that production routes through it.
        "pure engine": ("pub fn nextUp(" in pure
                        and "pub fn progress(" in pure
                        and "pub fn statusOf(" in pure),
        "aired clamp exists": "last_aired" in pure and "fn airedInSeason(" in pure,
        "specials excluded": "SPECIALS_SEASON" in pure,
        "library routes through pure": "tp.nextUp(" in lib and "tp.progress(" in lib,
        # Cross-season next-up needs every watched row + the season map, not the
        # 120-bool window of whichever season happens to be open.
        "season map persisted": "CREATE TABLE IF NOT EXISTS tv_seasons" in dbz,
        "tracked shows table": "CREATE TABLE IF NOT EXISTS tv_shows" in dbz,
        "watched loaded across seasons": "pub fn tvLoadWatchedAll(" in dbz,
        "detail resume is cross-season": "fn tvNextUp()" in tm and "nextUpFor(" in tm,
        # Per-episode resume, keyed by real episode identity.
        "episode resume columns": ("ALTER TABLE tv_watched ADD COLUMN position_secs" in dbz
                                   and "pub fn tvSavePosition(" in dbz
                                   and "pub fn tvGetPosition(" in dbz),
        "player binds the episode": "playing_episode" in pl and "tvSavePosition(" in pl,
        "player resumes the episode": "tvGetPosition(" in pl,
        # The binding is to a specific stream URL, not a bare "an episode is
        # playing" flag. Without the URL guard, playing a movie after an episode
        # writes the movie's position into the episode's row and then resumes the
        # movie at the episode's timestamp. Both save and resume must be gated.
        "episode binding is url-guarded": ("pub fn matches(" in st
                                           and pl.count("pe.matches(") >= 2
                                           and "pe.armed" in pl),
        # 64-bit columns: updated_at is a ms timestamp (~1.75e12) and would
        # silently truncate through columnInt's i32, wrecking the sort order.
        "int64 column reader": "pub fn columnInt64(" in dbz,
        # Untracking must never destroy watch history.
        "untrack keeps history": ("pub fn tvSetTracked(" in dbz
                                  and "DELETE FROM tv_watched" not in dbz),
        # User-settable status, next to the show name, changeable at any time.
        # It lives in a generic library_status table (not a tv_shows column)
        # because anime keys off a MAL id and a movie off its name.
        "status chips on detail": "pub fn renderStatusChips(" in tm,
        "user status beats derived": "pub fn effectiveStatus(" in pure and "r.user = " in lib,
        "generic status table": ("CREATE TABLE IF NOT EXISTS library_status" in dbz
                                 and "pub fn librarySetStatus(" in dbz
                                 and "pub fn libraryGetStatus(" in dbz),
        "auto-track on watch": "tvTouchShow(" in tm,
        # The Watching library is not TV-only.
        "all kinds aggregated": ("fn addTvRows(" in lib and "fn addAnimeRows(" in lib
                                 and "fn addMovieRows(" in lib),
        "kind chips": "tp.kindCountsFor(" in lib and "kind_filter" in lib,
        # A TV episode also lands in watch_history under its release name; listing
        # it as a "movie" would duplicate the show under a worse identity.
        "episodes excluded from movies": "subs.parse(name, &qbuf, &showbuf).is_tv" in lib,
        # "No next episode" != "caught up". With no season map we don't KNOW, and
        # saying "Caught up" hid the user's next episode (Silo: caught up at 0/10).
        "unknown never reads as caught up": ('"Not synced yet"' in pure
                                             and "if (r.prog.total == 0)" in pure),
        # Opening a show persists its season map, so "unknown" stops being
        # reachable for anything the user has actually looked at.
        "detail open persists season map": "tvUpsertSeasons(tmdb_id" in tm,
        # One fetch, one truth: the calendar no longer makes its own /3/tv/{id}
        # call, and no longer derives its own idea of what is unseen.
        "calendar consumes, not fetches": ("fn worker() void" not in cal
                                           and "e.unseen = next_up != null" in cal),
        "calendar fed by the sync": "cal.stage(" in lib,
        # The page.
        "watching route": "watching," in rt and ".watching =>" in sh,
        # Both chip rows and the visibility rule come from the tested pure module.
        "filter chips from pure": "tp.countsFor(" in lib and "tp.visible(" in lib,
        # Each row costs 2 queries; polling 200 shows at 2Hz would be ~800 q/s.
        "snapshot is dirty-driven, not polled": ("library_dirty" in lib
                                                 and "last_build_ms" not in lib),
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "missing: " + ", ".join(missing)
    return "pass", "TV+anime+movies in one library; aired-clamped next-up; user-set status"


@test("Player control bar: drop-ups + FF fullscreen", "Page Shell")
def test_player_dropups():
    # The control-bar pickers (aspect / audio / subs / language / files) were
    # MODAL dialogs: a dimming backdrop over the video, a title bar, a close
    # button. The scrim dimmed the very thing you were adjusting. They are now
    # backdrop-less panels anchored ABOVE the chip that opened them.
    pk = _src("src/ui/pickers.zig")
    ft = _src("src/ui/footer.zig")
    dp = _src("src/ui/dropup_pure.zig")
    bz = _src("build.zig")
    checks = {
        # Placement is pure + unit-tested; the UI only executes it.
        "pure placement": "pub fn place(" in dp and "pub fn contains(" in dp,
        "pure registered": "dropup_pure.zig" in bz,
        "pickers route through pure": "dropup.place(" in pk,
        # The whole point: no backdrop, and no window chrome.
        "no modals left": "modal = true" not in pk,
        "explicitly non-modal": ".modal = false" in pk,
        "no window title bars": "windowHeader" not in pk,
        # Anchored to the chip that opened it, so it drops UP from that chip.
        "chip anchor recorded": "picker_anchor" in ft and "recordAnchor(" in ft,
        "panel anchors to the chip": "footer.anchorFor(" in pk,
        # With no backdrop there is nothing to swallow a stray click, so Esc must work.
        "esc dismisses": "pub fn handleDropUpKeys(" in pk and "pickers.handleDropUpKeys();" in ft,
        # FF button now toggles fullscreen, reusing the same path the 'f' key drives.
        "ff toggles fullscreen": ("fullscreen_player_idx" in ft
                                  and 'components.tip(@src(), wd, if (is_fs) "Exit fullscreen (f)"' in ft),
        "ff no longer seeks": '"seek 10"' not in ft,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "missing: " + ", ".join(missing)
    return "pass", "backdrop-less drop-ups anchored above their chip; FF toggles fullscreen"


@test("Player: prev/next episode buttons", "Page Shell")
def test_episode_transport():
    # When a tracked TV episode is playing, the control bar gets prev/next EPISODE
    # buttons. Distinct from mpv's playlist-prev/next (a different thing, only
    # shown when there is an mpv playlist) and absent entirely for movies, where
    # "next episode" is meaningless.
    ft = _src("src/ui/footer.zig")
    lib = _src("src/services/tv_library.zig")
    pure = _src("src/services/tv_pure.zig")
    checks = {
        "neighbour logic is pure": ("pub fn episodeAfter(" in pure
                                    and "pub fn episodeBefore(" in pure),
        "library exposes neighbours": ("pub fn neighborEpisode(" in lib
                                       and "pub fn playNeighborEpisode(" in lib),
        "buttons in the control bar": '"ep-prev"' in ft and '"ep-next"' in ft,
        # Only for a tracked episode -- never for a movie / one-off file.
        "gated on a tracked episode": "tv_lib.playingEpisode()" in ft,
        "routes through the library": "tv_lib.playNeighborEpisode(" in ft,
        # "Next" must never offer an episode that hasn't aired -- that sends the
        # resolver hunting for a file that does not exist.
        "next is aired-clamped": "last_aired" in _between(lib, "pub fn neighborEpisode", "pub fn playNeighborEpisode"),
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "missing: " + ", ".join(missing)
    return "pass", "prev/next episode in the transport, aired-clamped, TV-only"


@test("Latest releases render as show cards", "Page Shell")
def test_release_cards():
    # "Latest releases" on Watching used to be a list of raw torrent rows next to a
    # grid of poster cards -- two renderers for the same shows, which is how one
    # page ends up looking like two apps. There is now ONE card (ui/media_card.zig)
    # and both surfaces call it.
    mc = _src("src/ui/media_card.zig")
    ez = _src("src/services/eztv_calendar.zig")
    ezp = _src("src/services/eztv_calendar_pure.zig")
    lib = _src("src/services/tv_library.zig")
    checks = {
        "one shared card": "pub fn render(" in mc and "pub const Card = struct" in mc,
        "library uses it": "media_card.render(" in lib,
        "releases use it": "media_card.render(" in ez,
        # One card per SHOW, not one per torrent: two releases of the same episode
        # (different groups/qualities) must not become two cards.
        "grouped by show": "pub fn groupShows(" in ezp and "pure.groupShows(" in ez,
        # The feed carries no artwork and no tmdb id, so each show is resolved.
        "artwork resolved": ("pub fn firstTvResult(" in ezp
                            and "pure.firstTvResult(" in ez
                            and "/3/search/tv?query=" in ez),
        # A stray & or # in a show name would truncate the query.
        "query encoded": "pub fn encodeQuery(" in ezp and "pure.encodeQuery(" in ez,
        # Poster slots keyed by show, never by list position -- the card list is
        # rebuilt every 15 min and a detached poster worker holds a slot pointer.
        "poster slots keyed by show": "fn posterFor(show: []const u8)" in ez,
        # The show-name parse reuses the tested SxxEyy filename parser.
        "reuses the tested name parser": "subs.parse(title, &qbuf, buf)" in ez,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "missing: " + ", ".join(missing)
    return "pass", "one shared poster card; releases grouped per show + artwork resolved"


@test("C toggles subtitles (not the comic viewer)", "Page Shell")
def test_c_toggles_subs():
    # C used to force the active player into the comic viewer, which blanked the
    # picture mid-video. That was a manual override of a decision the app already
    # makes for itself: browser.loadContent routes comic/image URLs to the comic
    # viewer via the unit-tested browser_pure.routeContent, and the Plugins page
    # sets it too -- so nothing is orphaned by taking the key.
    inp = _src("src/ui/input.zig")
    st = _src("src/ui/settings.zig")
    checks = {
        "C toggles subtitle visibility": '"cycle sub-visibility"' in inp,
        "C no longer hijacks the provider": "provider = .comic_viewer" not in inp,
        # Distinct from V / J, which CYCLE the track. Toggling visibility and
        # cycling tracks are different actions and both must survive.
        "V/J still cycle the track": inp.count('"cycle sub"') >= 2,
        # The Settings shortcut list must not lie about what the key does.
        "help text updated": ('"Toggle Subtitles On/Off"' in st
                              and '"Switch Cell to Comic"' not in st),
        # The comic viewer is still reachable the way it actually should be.
        "comic viewer still routed by URL": "comic_viewer" in _src("src/services/browser_pure.zig"),
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "missing: " + ", ".join(missing)
    return "pass", "C toggles sub-visibility; comic viewer still auto-routed by URL"


@test("Nav Donate Button", "Page Shell")
def test_nav_donate_button():
    # The button itself is dvui draw code (GUI-only, not unit-testable), so this
    # pins the wiring instead: one URL constant, the chip lives in header.zig,
    # the shell calls it, it reuses the existing openExternal launcher (no second
    # process-spawn helper), and the omnibox gave up width to make room for it.
    hdr = _src("src/ui/header.zig")
    shell = _src("src/ui/shell.zig")
    settings = _src("src/ui/settings.zig")
    checks = {
        "single URL constant": hdr.count("pub const DONATE_URL") == 1,
        "chip in header": "pub fn donateButton()" in hdr and "lucide.heart" in hdr,
        "shell call site": "header.donateButton();" in shell,
        "reuses openExternal": ("pub fn openExternal" in settings
                                and 'openExternal(DONATE_URL)' in hdr),
        # A donate chip that spawns its own child process = duplicated launcher.
        "no second launcher": "Child.init(" not in hdr,
        # Room for the chip came from the omnibox cap, not from overlapping it.
        # The omnibox is now a fixed, responsive width (no .expand), tighter than
        # the old 640 so the nav row fits the chip + right-side actions.
        "omnibox narrowed": ".max_size_content = .{ .w = if (narrow)" in shell,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "donate button wiring incomplete: " + ", ".join(missing)
    return "pass", "donate chip: header.zig → openExternal, omnibox width-capped"


@test("EZTV Release Calendar (neutral + live)", "Page Shell")
def test_eztv_calendar():
    # The section is dvui draw code + a detached worker (GUI/thread-only), so
    # this pins the two things that can silently rot: the NEUTRALITY contract
    # (no endpoint may be hardcoded in the binary — it must come from the
    # installed eztv source plugin, else the module stays inert) and the LIVE
    # refresh contract (periodic re-fetch, countdown recomputed per frame).
    svc = _src("src/services/eztv_calendar.zig")
    pur = _src("src/services/eztv_calendar_pure.zig")
    build = _src("build.zig")
    if not svc or not pur:
        return "fail", "eztv_calendar.zig / eztv_calendar_pure.zig missing"

    manifest_path = os.path.join(PROJECT_DIR, "data", "plugins-manifest.json")
    eztv = {}
    if os.path.exists(manifest_path):
        with open(manifest_path) as f:
            for p in json.load(f).get("plugins", []):
                if p.get("id") == "eztv":
                    eztv = p.get("endpoints", {})

    # The endpoints live in the manifest, never in src/. Scan BOTH new files for
    # any hardcoded eztv host (the whole point of source_config gating).
    hardcoded = [h for h in ("eztvx.to", "eztv.re", "eztv.ag", "eztv.it")
                 if h in svc or h in pur]

    checks = {
        # ── Neutrality ──
        "manifest declares calendar":  eztv.get("calendar", "").startswith("http"),
        "manifest declares countdown": eztv.get("countdown", "").startswith("http"),
        "manifest declares api":       eztv.get("api", "").startswith("http"),
        "no hardcoded eztv host in src": not hardcoded,
        "gated on installed plugin":   'source_config.has("eztv")' in svc,
        "endpoints read from plugin":  'source_config.get("eztv", field)' in svc,
        # Inert = render nothing: renderSection bails before drawing anything.
        "renders nothing when inert":  svc.count("if (!source_config.has(\"eztv\")) return;") >= 1,

        # ── The two-call mount contract the Watching page uses ──
        "pub fn refreshTick":          "pub fn refreshTick() void" in svc,
        "pub fn renderSection":        "pub fn renderSection() void" in svc,

        # ── Live, not once-per-session ──
        "named refresh interval":      "pub const REFRESH_INTERVAL_MS" in svc,
        # Gated on an explicit DEADLINE, not `last_fetch + INTERVAL`. eztv drops
        # TLS connections intermittently on DPI-throttled links; stamping the
        # full interval on a dead fetch blanked the section for 15 minutes after
        # a single reset. A failure now backs off seconds and doubles.
        "deadline-gated refetch":      "if (now < next_fetch_ms.load(.acquire)) return;" in svc,
        # The rail's whole failure mode is ISP DPI resetting the eztv TLS
        # connection. It built its curl argv by hand and never consulted
        # proxyArgs(), so turning the bypass setting on changed nothing here.
        # Measured on a DPI-throttled link: 9/15 direct vs 15/15 through the
        # sidecar.
        "honours the dpi bypass":      ('@import("dpi_bypass.zig").proxyArgs()' in svc
                                        and "argv[argc] = url;" in svc),
        "failure backs off":           ("fn armNext(ok: bool)" in svc
                                        and "pure.nextDelayMs(streak, RETRY_BASE_MS, REFRESH_INTERVAL_MS)" in svc
                                        and "defer armNext(ok);" in svc),
        "clock via io_global":         "io.milliTimestamp()" in svc,
        "no std.time":                 "std.time." not in svc,
        # A countdown baked at fetch time freezes on screen. It must be derived
        # from the stored epoch at the RENDER site, every frame. (Asserted on the
        # behaviour -- `now_s` fed in at render, from a stored epoch -- not on the
        # loop variable's name, which was `r` when releases were rows and is `cd`
        # now that they're cards.)
        "countdown per frame":         ("pure.releaseLabel(now_s," in svc
                                        and "released_epoch" in svc
                                        and "const now_s = io.timestamp();" in svc),

        # ── Threading / memory ──
        "busy guard":                  "loading.load(.acquire)" in svc and "loading.store(true, .release)" in svc,
        "detached worker":             "std.Thread.spawn" in svc and ".detach()" in svc,
        "big body on the heap":        "alloc.alloc(u8, BODY_CAP)" in svc and "defer alloc.free(body)" in svc,
        "publish count last":          "front.store(back, .release); // publish LAST" in svc,
        # The invalid-free trap: alloc(cap) then returning buf[0..n] is an
        # invalid free under the global DebugAllocator. The parser sidesteps it
        # entirely by writing into a caller-owned slice and touching no
        # allocator at all (so there is no buffer to mis-size).
        "parser allocates nothing":    not any(t in pur for t in
                                               ("alloc.zig", "allocator", ".alloc(", "realloc")),
        "parser fills caller buffer":  "pub fn parseFeed(body: []const u8, out: []Release) usize" in pur,
        # std.http SEGVs on some ISP TLS resets (tmdb_api.zig:275) — the fetch
        # must shell out to curl through the io_global child wrapper.
        "curl, never std.http":        ('"curl"' in svc and "io.Child.init" in svc
                                        and "std.http.Client" not in svc),

        # ── Pure logic is tested and production routes through it ──
        # sizeLabel was dropped with the row layout -- a poster card has no place
        # for a file size, and a tested pure fn that nothing ships is dead weight.
        # groupShows/firstTvResult/encodeQuery are what the card path needs.
        "pure fns used in prod":       all(f in svc for f in ("pure.buildFeedUrl", "pure.parseFeed",
                                                              "pure.releaseLabel", "pure.episodeTag",
                                                              "pure.groupShows", "pure.firstTvResult",
                                                              "pure.encodeQuery")),
        "pure module has tests":       pur.count('test "') >= 5,
        "registered in build.zig":     "src/services/eztv_calendar_pure.zig" in build,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "eztv calendar contract broken: " + ", ".join(missing[:4])
    return "pass", "neutral (source_config-gated), 15-min refresh, per-frame countdown"
