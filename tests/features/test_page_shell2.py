"""Auto-split from tests/test_features.py — Page Shell (part 2) tests.
Byte-for-byte identical test bodies; see tests/features/harness.py for the
shared @test decorator, helpers, and run_all()."""
from .harness import *  # noqa: F401,F403
import os, sys, subprocess, sqlite3, socket, time, json  # noqa: F401

@test("Added Torrent Engines Wired", "Page Shell")
def test_added_torrent_engines():
    # The 11 ported nova2 torrent engines: each needs (a) an engine .py whose
    # class name == module name == id (nova2 imports getattr(module, id)), and
    # (b) a matching torrent entry in the bundled manifest so it's installable.
    import json, os, re
    ids = ["therarbg", "torrentdownloads", "rutor", "glotorrents", "bitsearch",
           "torrentgalaxy", "academictorrents", "ilcorsaronero", "tokyotoshokan", "torrentfunk",
           "knaben"]
    eng_dir = os.path.join(PROJECT_DIR, "engines", "engines")
    m = json.load(open(os.path.join(PROJECT_DIR, "plugins-manifest.json")))
    torrent_ids = {p["id"] for p in m["plugins"] if p.get("type") == "torrent"}
    missing_eng, bad_class, missing_manifest = [], [], []
    for eid in ids:
        p = os.path.join(eng_dir, f"{eid}.py")
        if not os.path.exists(p):
            missing_eng.append(eid); continue
        src = open(p).read()
        # class name must equal the module/id (nova2 getattr contract)
        if not re.search(rf"^class {re.escape(eid)}\b", src, re.M):
            bad_class.append(eid)
        if "prettyPrinter" not in src:
            bad_class.append(eid + "(no prettyPrinter)")
        if eid not in torrent_ids:
            missing_manifest.append(eid)
    if missing_eng:
        return "fail", f"engine .py missing: {missing_eng}"
    if bad_class:
        return "fail", f"class!=module / no prettyPrinter: {bad_class}"
    if missing_manifest:
        return "fail", f"no manifest entry: {missing_manifest}"
    return "pass", f"{len(ids)} engines placed, class==module, manifest-wired"


@test("Polish Tokens Adopted", "Page Shell")
def test_polish_tokens():
    # Phase 3 polish (GUI-only): nav + sub-tab icons use the iconSize token (was
    # raw 15/14px literals that differed between adjacent nav surfaces), and the
    # soft drop shadow is a single theme token instead of copied {0,0,0,160}.
    th = _src("src/ui/theme.zig")
    sh = _src("src/ui/shell.zig")
    ft = _src("src/ui/footer.zig")
    if "pub const shadow_soft" not in th:
        return "fail", "theme.shadow_soft token missing"
    if "theme.iconSize(.sm)" not in sh:
        return "fail", "nav icons not on iconSize token"
    if "theme.shadow_soft" not in ft or "0, .g = 0, .b = 0, .a = 160" in ft:
        return "fail", "footer still uses raw shadow literals"
    return "pass", "nav iconSize + shadow token adopted"


@test("Motion Tokens + Transitions Wired", "Page Shell")
def test_motion_transitions():
    # Phase 2 motion (GUI-only — verified by presence): a single motion-token
    # source of truth (durations + easings) drives transitions, and the app now
    # uses dvui's animation APIs (previously 0 usage): route fade-in, toast
    # fade-in, and a control-bar chrome fade instead of a hard pop.
    th = _src("src/ui/theme.zig")
    sh = _src("src/ui/shell.zig")
    ft = _src("src/ui/footer.zig")
    if "pub const motion = struct" not in th or "dvui.easing" not in th:
        return "fail", "theme.motion tokens missing"
    if "dvui.animate(" not in sh or "@intFromEnum(r)" not in sh:
        return "fail", "route fade not wired in shell.zig"
    if "dvui.animate(" not in ft:
        return "fail", "toast fade not wired in footer.zig"
    if "dvui.alpha(chrome_vis)" not in ft:
        return "fail", "control-bar chrome fade not wired in footer.zig"
    return "pass", "motion tokens + route/toast/chrome transitions wired"


@test("Page Shell Immersive Hides Nav", "Page Shell")
def test_shell_immersive_navbar():
    # On the Player route, the page-shell top nav (and compact bottom tabs) must
    # auto-hide during immersive playback (fullscreen or idle-while-watching), so
    # the video gets the whole window. Decision reuses the unit-tested pure
    # chrome_autohide.shouldHideChrome; this checks the shell wiring.
    sh = _src("src/ui/shell.zig")
    ok = (
        "shouldHideChrome" in sh
        and "renderTopNav(compact" in sh   # now takes a responsive `narrow` arg too
        and "if (!immersive)" in sh
        and "nav_alpha" in sh                          # phase 4: nav fades instead of popping
        and "router.current == .player" in sh          # scoped so browsing keeps the nav
        and "fullscreen_player_idx != null" in sh
        and "and !immersive) renderBottomTabs" in sh    # compact bottom tabs hide too
    )
    if not ok:
        return "fail", "shell top nav not gated on immersive playback"
    return "pass", "top nav + bottom tabs auto-hide on immersive Player route"


@test("Interaction States Render (Hover/Focus/Confirm)", "Page Shell")
def test_interaction_states():
    # Phase 4: hover/focus states must be applied AFTER dvui.clicked() reports
    # hover (plain boxes draw their background at creation, so the old
    # `if (hovered)` ternaries at init were provably dead code), transparent-
    # fill buttons must spell out explicit hover fills (dvui derives hover by
    # lightening the fill, and lighten(transparent) is still transparent), and
    # destructive actions go through the two-step confirmDangerButton.
    cp = _src("src/ui/components.zig")
    sh = _src("src/ui/shell.zig")
    dr = _src("src/ui/drawer.zig")
    stg = _src("src/ui/settings.zig")
    if "color_fill_hover" not in cp or "confirmDangerButton" not in cp:
        return "fail", "components missing hover fills / confirm button"
    if "options.color_fill = tk.bg_hover()" not in cp:
        return "fail", "post-clicked hover repaint missing in components"
    if "navRowInteract" not in sh:
        return "fail", "shell nav rows missing hover/focus/keyboard interaction"
    if "confirmDangerButton" not in dr or "confirmDangerButton" not in stg:
        return "fail", "destructive clears not confirm-gated"
    return "pass", "hover repaint + focus rings + confirm-gated destructive actions"


@test("Color Aliases Collapsed To Canonical Tokens", "Page Shell")
def test_color_alias_collapse():
    # Phase 4: the duplicated color aliases (two divergent text ramps, 7-way
    # identical border token, 5-way elevated-bg token) are collapsed — the
    # legacy names must be GONE from ThemeColors and from all call sites.
    th = _src("src/ui/theme.zig")
    struct_body = th.split("ThemeColors = struct")[1].split("};")[0]
    for legacy in ("text_main", "text_muted", "text_dim", "accent_primary",
                   "semantic_error", "border_input", "bg_card", "bg_drawer",
                   "bg_input", "active_border"):
        if legacy + ":" in struct_body:
            return "fail", f"legacy color alias still defined: {legacy}"
    import subprocess
    r = subprocess.run(["grep", "-rn", "colors.text_main\|colors.semantic_\|colors.bg_input\|colors.accent_primary",
                        "src/"], capture_output=True, text=True)
    hits = [l for l in r.stdout.splitlines() if ".zig:" in l]
    if hits:
        return "fail", f"legacy alias call sites remain: {hits[:3]}"
    if "pub const transparent" not in th:
        return "fail", "theme.transparent shared token missing"
    return "pass", "canonical tokens only; legacy aliases deleted"


@test("Compact Type Ramp Drives dvui Fonts", "Page Shell")
def test_typography_unified():
    # Phase 4: one type ramp. applyToDvui routes dvui's font_body/heading/title
    # through theme.font_size, so labels that use themeGet() fonts and
    # components that use fontAt() finally agree; ramp is the compact one.
    th = _src("src/ui/theme.zig")
    if "font_body.withSize(font_size.body)" not in th:
        return "fail", "dvui font_body not routed through the token ramp"
    if "font_heading.withSize(font_size.title)" not in th or "font_title.withSize(font_size.display)" not in th:
        return "fail", "dvui heading/title fonts not routed through tokens"
    if "body: f32 = 11" not in th:
        return "fail", "type ramp is not the compact one (body should be 11)"
    return "pass", "compact ramp drives dvui + component fonts"


@test("Browse Sub-Tabs Own Their Row", "Page Shell")
def test_subtab_layout():
    # Phase 4 regression guard: the route fade (AnimateWidget) wraps a SINGLE
    # child; pages with sub-tabs render two siblings, which used to each get
    # the full page rect and draw interleaved (Browse toolbar over sub-tabs).
    sh = _src("src/ui/shell.zig")
    if "var page_col = dvui.box" not in sh:
        return "fail", "route fade missing the single-child column wrapper"
    if "scrollArea" not in sh.split("fn subTabs")[1].split("fn ")[0]:
        return "fail", "sub-tab strip not in a height-reserving scroll strip"
    return "pass", "fade wraps one column; sub-tabs reserve their row"


@test("Plex Client Wired", "Page Shell")
def test_plex_wired():
    # Plex client: PIN auth → server discovery → library browse → direct-play,
    # with a .Plex nav tab.
    px = _src("src/services/plex.zig")
    dr = _src("src/ui/drawer.zig")
    en = _src("src/core/state.zig")
    ok = (
        "api/v2/pins" in px
        and "api/v2/resources" in px
        and "/library/sections" in px
        and "pub fn renderContent()" in px
        and "X-Plex-Token" in px
        and ".Plex =>" in dr
        and "Plex," in en.split("DrawerTab = enum")[1].split("}")[0]
        and 'plex.zig").init()' in _src("src/main.zig")
    )
    return ("pass", "PIN auth + discovery + browse + play + tab wired") if ok else ("fail", "plex not fully wired")


@test("Trakt Sync Wired", "Page Shell")
def test_trakt_wired():
    # Trakt was dead code missing client_secret (auth couldn't complete). Now:
    # device flow w/ secret + persistence, a Connect UI, and id-based mark-watched
    # wired to TMDB episode play.
    tr = _src("src/services/trakt.zig")
    pg = _src("src/services/plugins.zig")
    tm = _src("src/services/tmdb.zig")
    ok = (
        "client_secret" in tr
        and "markWatchedEpisode" in tr
        and "pub fn init()" in tr
        and tr.count("client_secret") >= 4  # decl + save + load + token poll
        and "renderTrakt" in pg
        and "markWatchedEpisode" in tm
        and "trakt.zig\").init()" in _src("src/main.zig")
    )
    return ("pass", "device-flow + persistence + mark-watched wired") if ok else ("fail", "trakt not fully wired")


@test("Keyless Subtitle Fetch Works E2E", "Page Shell")
def test_keyless_subtitle_fetch_e2e():
    # Three real bugs fixed so auto-download actually lands an SRT:
    #  1. uppercase queries 302 to a broken host → urlEncode must lowercase
    #  2. OpenSubtitles JSON escapes slashes (\/) → unescapeJsonSlashes on the URL
    #  3. the redirect + gzip broke std.http → httpGet uses curl (-L --compressed)
    eng = open(os.path.join(PROJECT_DIR, "src/player/subtitles.zig")).read()
    pure = open(os.path.join(PROJECT_DIR, "src/services/subtitles_pure.zig")).read()
    if "ch + 32" not in eng:
        return "fail", "urlEncode no longer lowercases (uppercase → broken 302 redirect)"
    if "unescapeJsonSlashes" not in eng or "unescapeJsonSlashes" not in pure:
        return "fail", "download URL no longer unescapes JSON \\/ (Uri.parse rejects it)"
    if '"curl"' not in eng or "--compressed" not in eng:
        return "fail", "httpGet no longer uses curl (std.http chokes on the OS redirect)"
    return "pass", "lowercase query + URL unescape + curl fetch — auto-download lands an SRT"


@test("Keyless Subtitle Providers Wired", "Page Shell")
def test_keyless_subtitle_providers():
    # Auto-subs must work with NO API key via public engines: the legacy
    # rest.opensubtitles.org (movies+TV, gzipped) plus Gestdown/Addic7ed
    # (api.gestdown.info, TV, direct SRT). Gestdown APPENDS its matches to the
    # merged, source-tagged result list (primary first) instead of only
    # rescuing an empty primary. Non-torrent playback triggers the keyless
    # engine from the FILE_LOADED handler.
    eng = open(os.path.join(PROJECT_DIR, "src/player/subtitles.zig")).read()
    player = open(os.path.join(PROJECT_DIR, "src/player/player.zig")).read()
    if "rest.opensubtitles.org" not in eng:
        return "fail", "keyless legacy OpenSubtitles REST provider missing"
    if "api.gestdown.info" not in eng or "gestdownAppend" not in eng:
        return "fail", "Gestdown keyless append provider missing"
    if "MAX_RESULTS = 15" not in eng:
        return "fail", "merged result list no longer holds 15 entries"
    if "source: SubSource" not in eng or "pub fn sourceName" not in eng:
        return "fail", "results lost their provider source tag"
    # Engine parses provider JSON through the unit-tested pure module.
    if "osRestResults" not in eng or "gestdownSubs" not in eng:
        return "fail", "engine no longer routes parsing through subtitles_pure"
    # Manual UI entries: query search + per-row worker download.
    if "pub fn searchQuery" not in eng or "pub fn downloadIndex" not in eng:
        return "fail", "engine lost its manual searchQuery/downloadIndex entry points"
    if "startSearch(&state.app.sub_engine" not in player or "current_torrent_id < 0" not in player:
        return "fail", "non-torrent playback no longer triggers the keyless engine"
    build = open(os.path.join(PROJECT_DIR, "build.zig")).read()
    if "subtitles_pure.zig" not in build:
        return "fail", "subtitles_pure parser tests unregistered"
    return "pass", "keyless chain: rest.opensubtitles.org + Gestdown merged (15 tagged results), fired on any playback"


@test("Subdl Subtitle Provider Wired", "Page Shell")
def test_subdl_provider():
    # Subdl (api.subdl.com) is a KEYED wave-2 provider parallel to
    # OpenSubtitles.com: free per-user key, ZIP downloads extracted in-process
    # via std.zip. Ships inert — no key ⇒ no fetch. Verify the whole chain:
    # state key + config persistence + pure parser (tested) + provider funcs +
    # in-process ZIP extraction + Settings UI field.
    state = open(os.path.join(PROJECT_DIR, "src/core/state.zig")).read()
    cfg = open(os.path.join(PROJECT_DIR, "src/core/config.zig")).read()
    pure = open(os.path.join(PROJECT_DIR, "src/services/subtitles_pure.zig")).read()
    svc = open(os.path.join(PROJECT_DIR, "src/services/subtitles.zig")).read()
    ui = open(os.path.join(PROJECT_DIR, "src/ui/settings.zig")).read()

    # Key plumbing: fixed buffer in state, persisted both ways in config.
    if "subdl_api_key" not in state or "subdl_api_key_len" not in state:
        return "fail", "subdl_api_key not added to state.zig"
    if 'setKey("subdl_api_key"' not in cfg or '"subdl_api_key"' not in cfg:
        return "fail", "subdl_api_key not persisted/loaded in config.zig"

    # Pure, unit-tested parser + language mapper; production routes through them.
    if "pub fn subdlSubs" not in pure or "pub fn subdlLangCode" not in pure:
        return "fail", "subdlSubs/subdlLangCode missing from subtitles_pure.zig"
    if "sp.subdlSubs" not in svc or "sp.subdlLangCode" not in svc:
        return "fail", "provider no longer routes parsing through subtitles_pure"

    # Provider entry points + inert-without-key guard.
    if "pub fn subdlSearch" not in svc or "pub fn subdlDownload" not in svc:
        return "fail", "subdlSearch/subdlDownload entry points missing"
    if "state.app.subdl_api_key_len == 0" not in svc:
        return "fail", "Subdl search no longer no-ops without a key (not inert)"
    if "api.subdl.com/api/v1/subtitles" not in svc:
        return "fail", "Subdl search endpoint missing"
    if "https://dl.subdl.com" not in svc:
        return "fail", "Subdl download host missing"

    # ZIP handling: in-process extraction via std.zip (no external unzip dep).
    if "std.zip.extract" not in svc:
        return "fail", "Subdl ZIP no longer extracted via std.zip"

    # Settings UI: masked key field + free-key hint + results wiring.
    if "subdl_api_key" not in ui or "subdl.com/panel/api" not in ui:
        return "fail", "Settings → Subtitles missing Subdl key field / free-key hint"
    if "subs.subdlSearch" not in ui or "subs.subdlDownload" not in ui:
        return "fail", "Settings tab not wired to Subdl search/download"

    return "pass", "keyed Subdl: state+config key, pure parser, api.subdl.com search, std.zip download, Settings UI — inert without key"


@test("Auto-Download Subtitles On Play", "Page Shell")
def test_auto_download_subs():
    # A video with no embedded/sidecar sub track should trigger an automatic
    # OpenSubtitles fetch of the best match. Wiring: mpv FILE_LOADED handler
    # checks for a sub track and calls subtitles.autoFetchForPlayer(); doSearch
    # chains into doDownload when auto_mode is set; gated by a persisted toggle.
    player = open(os.path.join(PROJECT_DIR, "src/player/player.zig")).read()
    cfg = open(os.path.join(PROJECT_DIR, "src/core/config.zig")).read()
    # FILE_LOADED handler checks for an existing sub track and, when there's
    # none, fires the keyless engine (gated by the persisted toggle).
    if "MPV_EVENT_FILE_LOADED" not in player:
        return "fail", "player has no FILE_LOADED handler"
    if "auto_download_subs" not in player or "startSearch(&state.app.sub_engine" not in player:
        return "fail", "FILE_LOADED no longer auto-triggers the subtitle engine on the toggle"
    if "auto_download_subs" not in cfg:
        return "fail", "auto_download_subs toggle not persisted in config"
    # The auto path must still chain search → download (manual UI searches
    # set auto_load=false and wait for a per-row downloadIndex instead).
    eng = open(os.path.join(PROJECT_DIR, "src/player/subtitles.zig")).read()
    if "auto_load" not in eng or "engine.auto_load" not in eng:
        return "fail", "engine lost the auto_load search→download chain flag"
    return "pass", "FILE_LOADED with no sub track auto-fires the keyless engine (toggle-gated)"


@test("Sub Picker Lists Keyless Results", "Page Shell")
def test_sub_picker_keyless_results():
    # The two browsable subtitle lists (footer Find Subtitles modal + Settings
    # › Subtitles) must render the KEYLESS engine's merged results — source-
    # tagged rows with a per-row Download — with no API key required. A key
    # only APPENDS an opensubtitles.com section; without one the hint is a
    # subtle one-liner, never a blocking banner.
    footer = open(os.path.join(PROJECT_DIR, "src/ui/footer.zig")).read()
    settings = open(os.path.join(PROJECT_DIR, "src/ui/settings.zig")).read()
    if "pub fn renderSubPicker" not in footer:
        return "fail", "footer lost renderSubPicker"
    picker = footer.split("pub fn renderSubPicker")[1].split("\npub fn ")[0]
    if "state.app.sub_engine" not in picker:
        return "fail", "footer picker no longer renders the keyless engine results"
    if "downloadIndex" not in picker:
        return "fail", "footer picker rows lost the per-row keyless Download"
    if "sourceName" not in picker:
        return "fail", "footer picker rows lost their provider source chip"
    if "loaded_idx" not in picker:
        return "fail", "footer picker no longer marks the loaded subtitle row"
    if "opensub_api_key_len > 0" not in picker:
        return "fail", "keyed opensubtitles.com section is no longer gated on the key"
    if "for more results" not in picker:
        return "fail", "no-key hint one-liner missing from the picker"
    # Footer chip kicks the keyless search when opening the picker.
    if "searchFromActivePlayer(&state.app.sub_engine)" not in footer:
        return "fail", "footer Subs chip no longer kicks the keyless search"
    # Settings list mirrors the same wiring.
    if "searchQuery(engine" not in settings and "searchQuery(&state.app.sub_engine" not in settings:
        return "fail", "Settings search no longer routes through the keyless engine"
    if "sourceName" not in settings or "downloadIndex" not in settings:
        return "fail", "Settings result rows lost keyless source tags / download"
    # Language change re-fires the search.
    if "refire" not in footer or "refire" not in settings:
        return "fail", "language change no longer re-fires the subtitle search"
    return "pass", "footer + Settings lists render keyless source-tagged rows; key only appends"


@test("Anime Tab Honors NSFW Filter", "Page Shell")
def test_anime_nsfw_filter():
    # Settings › NSFW toggle must govern anime browsing, not just search:
    # every Jikan grid URL carries sfw=true and the parser drops Rx/R+ rated
    # entries (anime_pure.jikanRatingIsAdult, unit-tested).
    anime = open(os.path.join(PROJECT_DIR, "src/services/anime.zig")).read()
    if "sfwSuffix(state.app.nsfw_filter_enabled)" not in anime:
        return "fail", "Jikan URLs no longer append the sfw param from the NSFW toggle"
    if anime.count("sfwSuffix(state.app.nsfw_filter_enabled)") < 15:
        return "fail", "some Jikan grid URL sites lost the sfw param (expected 15+)"
    if "jikanRatingIsAdult(obj_slice)" not in anime:
        return "fail", "parser no longer drops Rx/R+ entries when the filter is on"
    build = open(os.path.join(PROJECT_DIR, "build.zig")).read()
    if "anime_pure.zig" not in build:
        return "fail", "anime_pure tests unregistered from zig build test"
    return "pass", "sfw=true on all Jikan URLs + Rx/R+ parser drop, gated on the toggle"


@test("NSFW Control Is Settings-Only", "Page Shell")
def test_nsfw_settings_only():
    # The NSFW filter is toggled from Settings ONLY — browse/search tabs must not
    # carry their own toggle. They still HONOR the global flag (that's tested
    # elsewhere), but must never FLIP it.
    settings = open(os.path.join(PROJECT_DIR, "src/ui/settings.zig")).read()
    if 'toggleRow(@src(), "NSFW Filter"' not in settings:
        return "fail", "Settings lost the NSFW Filter toggle (the only intended control)"

    # No browse-facing module may write the flag (assignment), only read it.
    flip = "state.app.nsfw_filter_enabled = "
    offenders = []
    for rel in ("src/services/search.zig", "src/services/anime.zig",
                "src/services/vndb.zig", "src/services/iptv.zig"):
        if flip in open(os.path.join(PROJECT_DIR, rel)).read():
            offenders.append(rel)
    if offenders:
        return "fail", "browse tab still flips the NSFW flag (settings-only): " + ", ".join(offenders)
    return "pass", "NSFW filter is controlled from Settings only; browse tabs read but never flip it"


@test("Unified Downloads List", "Page Shell")
def test_unified_downloads():
    # Downloads is ONE merged list (torrents + files + history) with filter
    # chips — not three tabs. The merge/dedup/status/sort decisions must come
    # from the unit-tested pure module, and the renderer must only execute them.
    tr = _src("src/services/transfers.zig")
    pure = _src("src/services/transfers_pure.zig")
    hdr = _src("src/torrent_wrapper.h")
    cpp = _src("src/torrent_wrapper.cpp")
    checks = {
        "pure merge engine": "pub fn buildRows(" in pure and "pub fn matchStrength(" in pure,
        "renderer uses pure merge": "tp.buildRows(" in tr and "tp.sortOrder(" in tr,
        "filter chips (not tabs)": "var filter: tp.Filter" in tr and "tab_idx" not in tr,
        "old tab renderers gone": ("renderFilesInline" not in tr
                                   and "renderActiveInline" not in tr
                                   and "renderHistoryInline" not in tr),
        "one unified list": "fn renderUnifiedList()" in tr and "tp.matchesFilter(" in tr,
        "chip counts from pure": "tp.countsFor(" in tr,
        # An index would be invalidated by every 2Hz rebuild — expansion is keyed
        # by identity (infohash / disk entry / normalized name).
        "expansion keyed by identity": ("expanded_key" in tr
                                        and "expanded_torrent_id" not in tr),
        # torrent_poll is side-effecting (streaming deadline window) but used to
        # run every frame at ~60Hz; the snapshot throttles it to 2Hz.
        "snapshot throttled to 2Hz": "last_build_ms" in tr and "rows_dirty" in tr,
        "infohash getter (C++)": ("int torrent_get_infohash(" in hdr
                                  and 'extern "C" int torrent_get_infohash(' in cpp
                                  and "info_hashes().get_best()" in cpp),
        "renderer reads the infohash": "torrent_get_infohash(" in tr,
        # Names from libtorrent/disk are untrusted bytes; invalid UTF-8 panics dvui.
        "untrusted names validated": "safeUtf8Buf(displayName(" in tr,
        # "Remove" must never delete disk bytes; deleting files is a separate,
        # explicitly confirmed action in the expanded panel.
        "remove ≠ delete from disk": ("confirmDangerButton(@src(), \"Remove\"" in tr
                                      and "Delete files from disk" in tr),
        # Dropping the proxy teardown leaks an accept-loop thread + a port.
        "proxy torn down on remove": "stream_proxy.stopProxy(p.proxy_handle)" in tr,
        "folder drill-down kept": "browse_subdir_len" in tr and "← Up" in tr,
    }
    missing = [k for k, v in checks.items() if not v]
    if missing:
        return "fail", "missing: " + ", ".join(missing)
    return "pass", "one merged list: pure dedup + chips + union actions + infohash join"
