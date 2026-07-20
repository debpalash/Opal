"""Universal search fan-out + the glue landed alongside it.

Before this, a universal search only reached the video verticals — a query for
a song, a station or a podcast returned nothing even though the app can play
all three. The resolver now fans out to JioSaavn / RadioBrowser / iTunes as
first-class sources, each with its own toolbar pill, status atomic and result
chip. Also covered here: synced lyrics (lrclib) and the generalized mpv
per-request header path, both of which shipped in the same change.

See tests/features/harness.py for the shared @test decorator."""
from .harness import *  # noqa: F401,F403


@test("Universal search audio fan-out", "Search")
def test_universal_search_fanout():
    res = _src("src/services/resolver.zig")
    srch = _src("src/services/search.zig")
    chat = _src("src/services/ai_chat.zig")

    checks = {
        # ── Source identity ──
        "music/radio/podcast source types": all(
            f"    {s}," in res for s in ("livetv", "music", "radio", "podcast")
        ),
        "toolbar pills declared": "stremio, rss, livetv, music, radio, podcast }" in res,
        # The mask must be derived from the enum, not a hand-written literal —
        # a hardcoded 0xFF silently left every new pill off.
        "mask derived from enum": "ALL_SOURCE_BITS" in res and '@typeInfo(SourceBit).@"enum".fields.len' in res,
        "no hardcoded 0xFF mask": "init(0xFF)" not in res and "m & 0xFF == 0" not in res,

        # ── Workers ──
        "music worker": "fn resolveMusic(" in res,
        "radio worker": "fn resolveRadio(" in res,
        "podcast worker": "fn resolvePodcasts(" in res,
        "live tv worker": "fn resolveLiveTv(" in res,
        # The tab entry point mutates state.app.iptv; the fan-out must not.
        "live tv uses tab-independent entry": "iptv.searchInto(" in res and "searchIptv(" not in res,
        "live tv carries play hints": "item.http_ua" in res and "item.http_referrer" in res,
        "play hints survive the cache": res.count("http_ua") >= 5,
        "routes through pure parsers": all(
            m in res for m in ("music_jiosaavn_pure.zig", "radio_pure.zig", "podcasts_pure.zig")
        ),
        "workers spawned": all(
            f"if (sourceOn(.{b})) Spawn.go(resolve" in res for b in ("livetv", "music", "radio", "podcast")
        ),
        "status atomics": all(
            f"pub var status_{s} = std.atomic.Value(SourceStatus)" in res
            for s in ("livetv", "music", "radio", "podcast")
        ),
        # A worker missing from checkAllDone leaves the spinner running forever.
        "checkAllDone covers them": all(
            f"status_{s}.load(.acquire) != .searching" in res
            for s in ("livetv", "music", "radio", "podcast")
        ),
        "per-source cap": "AUDIO_MAX" in res,
        # Heap, not the 512KB worker stack (CLAUDE.md thread-safety rule).
        "heap response buffers": res.count("alloc.alloc(u8, 512 * 1024)") >= 3,

        # ── Ranking: a song must not outrank the episode you asked for ──
        "audio ranked below video": ".livetv => 21" in res and ".music => 22" in res and ".podcast => 24" in res and ".radio => 26" in res,
        "audio penalized for movie/show intent": (
            "item.source == .music or item.source == .radio or item.source == .podcast" in res
        ),

        # ── Result cap widened so late finishers aren't starved ──
        "MAX_RESULTS constant": "pub const MAX_RESULTS: usize = 96;" in res,
        "no stale 64 cap": "result_count >= 64" not in res,
        "cache blob resized": "SEARCH_BLOB_CAP: usize = 512 * 1024" in res,

        # ── Playback routing ──
        "music/radio play direct": ".youtube, .stremio, .local, .music, .radio => {" in res,
        "live tv replays its headers": ".livetv => {" in res and "loadContentDirectMetaHeaders(" in res and "originFromReferer(" in res,
        "podcast opens its tab": ".podcast => {" in res and "state.navigateToTab(.Podcasts)" in res,

        # ── UI surfaces (an unhandled switch arm is a compile error, but the
        #    pills/summary rows are data literals that silently omit) ──
        "filter pills rendered": all(
            f'.bit = .{b}, .st = resolver.status_{b}' in srch
            for b in ("livetv", "music", "radio", "podcast")
        ),
        "result chips labelled": all(
            f'.{s} => "{s.capitalize()}"' in srch for s in ("music", "radio")
        ),
        "no-hits summary rows": all(
            f'.bit = .{b} }}' in srch or f'.bit = .{b},' in srch
            for b in ("livetv", "music", "radio", "podcast")
        ),
        "sourceBitOf maps them": all(f".{s} => .{s}," in srch for s in ("livetv", "music", "radio", "podcast")),
        "ai chat labels": all(f'.{s} => "{s.capitalize()}"' in chat for s in ("music", "radio")),
    }

    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "Fan-out incomplete: " + ", ".join(missing)
    return "pass", "Universal search reaches live tv/music/radio/podcasts; cap 96; audio ranked below video"


@test("Synced lyrics (lrclib)", "Audio")
def test_synced_lyrics():
    pure = _src("src/services/lyrics_pure.zig")
    svc = _src("src/services/lyrics.zig")
    music = _src("src/services/music_subsonic.zig")
    build = _src("build.zig")

    checks = {
        "pure module present": bool(pure),
        "get url builder": "pub fn buildLrclibUrl" in pure and "lrclib.net/api/get" in pure,
        "search fallback url": "pub fn buildLrclibSearchUrl" in pure and "/api/search" in pure,
        "percent-encoded": "percentEncode" in pure,
        "synced + plain extract": "pub fn extractSyncedLyrics" in pure and "pub fn extractPlainLyrics" in pure,
        "lrc parse": "pub fn parseLrc" in pure and "pub const LyricLine" in pure,
        "active line lookup": "pub fn activeLineAt" in pure,
        "has tests": pure.count('test "') >= 6,

        "service routes through pure": "pure.parseLrc(" in svc and "pure.buildLrclibUrl(" in svc,
        "fetch entry": "pub fn requestFor" in svc,
        "dedupe key": "loaded_key" in svc,
        "atomic fetching flag": "std.atomic.Value(bool)" in svc,
        "mutex guarded": "sync.zig" in svc and "Mutex" in svc,
        "heap buffers on worker": "alloc.alloc(" in svc,
        "reliable fetch seam": "reliable_fetch.zig" in svc,

        "music tab requests lyrics": "lyrics.requestFor(" in music and "lyrics.clear()" in music,
        "panel rendered": "renderLyrics" in music,
        "player idx guarded": (
            "active_player_idx < state.app.players.items.len" in music
            or "active_player_idx >= state.app.players.items.len) return" in music
        ),

        "test registered": 'b.path("src/services/lyrics_pure.zig")' in build,
    }

    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "Lyrics wiring incomplete: " + ", ".join(missing)
    return "pass", "lrclib synced lyrics: pure(url/extract/lrc/active) -> worker -> highlighted panel"


@test("mpv per-request HTTP headers", "Player")
def test_mpv_http_headers():
    pure = _src("src/player/http_headers_pure.zig")
    player = _src("src/player/player.zig")
    iptv = _src("src/services/iptv.zig")
    build = _src("build.zig")

    checks = {
        "pure module present": bool(pure),
        "header struct": "pub const HttpHeader = struct" in pure,
        "joiner": "pub fn buildHeaderFields" in pure,
        # mpv splits http-header-fields on ',' with no escaping — a value
        # containing one would corrupt every following header.
        "comma-unsafe values dropped": "','" in pure and ("\\r" in pure or "'\\r'" in pure),
        "origin derivation": "pub fn originFromReferer" in pure,
        "has tests": pure.count('test "') >= 6,

        "generalized loader": "pub fn loadStreamWithHttpHeaders" in player,
        "single code path": player.count('mpv_set_option_string(ctx, "http-header-fields"') <= 2,
        "routes through pure": "buildHeaderFields(" in player,
        "legacy signatures kept": "pub fn loadStreamWithHttp(" in player and "pub fn loadStreamWithHeaders(" in player,

        "iptv sends origin": "originFromReferer(" in iptv,
        "test registered": 'b.path("src/player/http_headers_pure.zig")' in build,
    }

    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "Header wiring incomplete: " + ", ".join(missing)
    return "pass", "mpv headers generalized: Referer+Origin+arbitrary, comma-safe, one code path"
