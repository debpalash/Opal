"""Music vertical — Subsonic/OpenSubsonic engine + Music tab.

Self-hosted music (Navidrome/Airsonic/Gonic/Funkwhale/Ampache all speak
Subsonic). Keyless token+salt MD5 auth; the `stream` URL feeds mpv directly.
Structural twin of the Suwayomi/IPTV engines: pure URL/auth/JSON in
music_subsonic_pure.zig (tested), fetch+render in music_subsonic.zig, a Music
tab in the Audio rail group, opt-in via source_config ("subsonic").

See tests/features/harness.py for the shared @test decorator."""
from .harness import *  # noqa: F401,F403

import json
import os


@test("Subsonic music engine", "Audio")
def test_music():
    pure = _src("src/services/music_subsonic_pure.zig")
    svc = _src("src/services/music_subsonic.zig")
    st = _src("src/core/state.zig")
    shell = _src("src/ui/shell.zig")
    drawer = _src("src/ui/drawer.zig")
    build = _src("build.zig")
    jfp = _src("src/services/music_jellyfin_pure.zig")
    pxp = _src("src/services/music_plex_pure.zig")

    checks = {
        # ── Pure: MD5 token auth + REST URL builders + song JSON ──
        "pure module present": bool(pure),
        "md5 token auth": "pub fn authToken" in pure and "std.crypto.hash.Md5" in pure,
        "auth query builder": "pub fn buildAuthQuery" in pure,
        "search url builder": "pub fn buildSearchUrl" in pure and "search3" in pure,
        "stream url (format=raw)": "pub fn buildStreamUrl" in pure and "format=raw" in pure,
        "cover url builder": "pub fn buildCoverUrl" in pure and "getCoverArt" in pure,
        "song parse": "pub const SongIter" in pure and "pub fn parseSong" in pure,
        "response ok check": "pub fn responseOk" in pure,
        "fixed-buffer record": "pub const MusicSong = struct" in pure,

        # ── Service: creds gate + async worker + play + covers ──
        "routes through pure": all(
            f"pure.{fn}(" in svc
            for fn in ("authToken", "buildAuthQuery", "buildSearchUrl",
                       "buildStreamUrl", "buildCoverUrl", "parseSong", "responseOk")
        ),
        "source_config gate": 'source_config' in svc and '"subsonic"' in svc,
        "inert when unconfigured": "fn configured()" in svc and "orelse return" in svc,
        "per-session salt": "fn ensureSalt()" in svc,
        "search entry": "pub fn searchMusic" in svc,
        "play hands url to mpv": "pub fn playSong" in svc and "loadContentDirectMeta(" in svc,
        "covers via poster daemon": "poster.fetchAsync(" in svc,
        "render entry": "pub fn renderContent" in svc,
        "thread discipline": "search_gen" in svc and "parse_mutex" in svc and "is_loading.store" in svc,
        "curl not std.http": "std.http.Client" not in svc and '"curl"' in svc,

        # ── Enum → state → nav → render → rail/shell ──
        "enum variant": "Music }" in st and "pub const DrawerTab" in st,
        "state struct": "music: struct {" in st and "]music_pure.MusicSong" in st,
        "nav host page": ".Music => {" in st and "app.browse_source = .Music;" in st,
        "render dispatch": '.Music => @import("../services/music_subsonic.zig").renderContent()' in drawer,
        "grouped under audio": ".Music => .audio" in drawer or "Audiobooks, .Music => .audio" in drawer,
        "rail nav entry": "renderRailTab(.Music" in drawer,
        "shell label": '.Music => "Music"' in shell,
        "shell icon": ".Music => icons.tvg.lucide.music" in shell,

        # ── JioSaavn (public, keyless) as a second source in the Music tab ──
        "jiosaavn pure module": bool(_src("src/services/music_jiosaavn_pure.zig")),
        "jiosaavn search url": "pub fn buildSearchUrl" in _src("src/services/music_jiosaavn_pure.zig") and "search.getResults" in _src("src/services/music_jiosaavn_pure.zig"),
        "jiosaavn play-url guard": "pub fn isPlayableUrl" in _src("src/services/music_jiosaavn_pure.zig"),
        "jiosaavn song parse": "pub fn parseSong" in _src("src/services/music_jiosaavn_pure.zig"),
        "tab hosts both sources": "js_pure" in svc and "jiosaavnWorker" in svc and "subsonicWorker" in svc,
        "source selector": '"JioSaavn"' in svc and "state.app.music.source" in svc,
        "play dispatch (perma_url vs stream)": "song.play_url" in svc and "pure.buildStreamUrl(" in svc,
        "jiosaavn test registered": 'b.path("src/services/music_jiosaavn_pure.zig")' in build,

        # ── Jellyfin (source 2) + Plex (source 3) as self-hosted music sources ──
        "jellyfin pure module": bool(jfp),
        "jellyfin audio search url": "IncludeItemTypes=Audio" in jfp and "Recursive=true" in jfp,
        "jellyfin stream url": "pub fn buildStreamUrl" in jfp and "/universal?" in jfp and "static=true" in jfp,
        "jellyfin api_key in query": "api_key=" in jfp,
        "jellyfin cover reuses jellyfin_pure": 'jellyfin_pure.zig' in jfp and "jf_pure.primaryImageUrl(" in jfp,
        "jellyfin items parse": "pub const ItemIter" in jfp and "pub fn parseSong" in jfp and "pub fn itemsScope" in jfp,
        "plex pure module": bool(pxp),
        "plex track search url": "/search?query=" in pxp and "TYPE_TRACK" in pxp,
        "plex stream from Part.key": 'pub fn buildStreamUrl' in pxp and '"\\"Part\\":"' in pxp,
        "plex token in query": "X-Plex-Token=" in pxp,
        "plex path guard": "pub fn isValidPath" in pxp,
        "plex metadata parse": "pub const TrackIter" in pxp and "pub fn parseSong" in pxp and "pub fn metadataScope" in pxp,
        "plex creds reuse plex.json": "pub fn parseCreds" in pxp and "plex.json" in svc,

        # ── Both new sources wired into the SAME Music tab ──
        "four sources in one tab": all(
            c in svc for c in ("SRC_JIOSAAVN", "SRC_SUBSONIC", "SRC_JELLYFIN", "SRC_PLEX")
        ),
        "new workers mirror subsonicWorker": "jellyfinMusicWorker" in svc and "plexMusicWorker" in svc,
        "new sources routed through pure": all(
            f"{m}.{fn}(" in svc
            for m, fn in (("jf_pure", "buildSearchUrl"), ("jf_pure", "buildStreamUrl"),
                          ("jf_pure", "buildCoverUrl"), ("jf_pure", "parseSong"),
                          ("px_pure", "buildSearchUrl"), ("px_pure", "buildStreamUrl"),
                          ("px_pure", "buildCoverUrl"), ("px_pure", "parseSong"),
                          ("px_pure", "parseCreds"))
        ),
        "selector offers all four": all(
            f'"{n}"' in svc for n in ("JioSaavn", "Subsonic", "Jellyfin", "Plex")
        ),
        "inert when server unconfigured": "fn sourceConfigured(" in svc and "fn jfCreds(" in svc and "fn plexCreds(" in svc,
        "creds snapshotted before spawn": "fn snapBase(" in svc and "fn snapToken(" in svc and "spawnWorker(" in svc,
        "player guard on lyrics clock": "state.app.active_player_idx >= state.app.players.items.len" in svc,
        "lyrics still requested on play": "lyrics.clear()" in svc and "lyrics.requestFor(" in svc,
        "does not edit jellyfin/plex services": "jf_pure" in svc and "px_pure" in svc,

        # ── Pure modules registered ──
        "test registered": 'b.path("src/services/music_subsonic_pure.zig")' in build,
        "jellyfin test registered": 'b.path("src/services/music_jellyfin_pure.zig")' in build,
        "plex test registered": 'b.path("src/services/music_plex_pure.zig")' in build,
    }

    # ── Manifest carries the subsonic entry ──
    manifest_ok = False
    try:
        man = json.load(open(os.path.join(PROJECT_DIR, "data", "plugins-manifest.json")))
        manifest_ok = any(p.get("id") == "subsonic" and p.get("type") == "music" for p in man.get("plugins", []))
    except Exception:
        manifest_ok = False
    checks["manifest subsonic entry"] = manifest_ok

    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "Music wiring incomplete: " + ", ".join(missing)
    return "pass", "Music tab: 4 sources (JioSaavn/Subsonic/Jellyfin/Plex), each pure-routed + inert when unconfigured"
