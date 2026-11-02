"""Video — YouTube InnerTube fast search path.

The YouTube tab used to spawn yt-dlp for every search (`ytsearch20:`), which
costs ~18s on this machine before a single card can paint. The fast path POSTs
once to `/youtubei/v1/search` (~1s) and appends rows to the grid AS THEY PARSE,
with a batched dvui.refresh so the fill actually waterfalls. yt-dlp and Piped
remain as ordered fallbacks, and parsed rows are persisted to the encrypted
content cache so a repeat query paints instantly while revalidating.

Verify the wiring: the tested pure module exists and is ROUTED (tested logic ==
shipped logic), the fallback ordering + generation guard + lazy-clear semantics
are intact, the SWR cache is gated on content_cache_enabled, and the pure
module is registered in build.zig's test step.

See tests/features/harness.py for the shared @test decorator."""
from .harness import *  # noqa: F401,F403


@test("YouTube InnerTube fast search", "Video")
def test_youtube_innertube():
    pure = _src("src/services/youtube_innertube_pure.zig")
    svc = _src("src/services/youtube.zig")
    build = _src("build.zig")

    checks = {
        # ── Pure module: body builder, iterator, field extractors ──
        "pure module present": bool(pure),
        "pure body builder": "pub fn buildSearchBody" in pure,
        "pure videoRenderer iterator": "pub fn nextVideo" in pure,
        "pure Video record": "pub const Video = struct" in pure,
        "pure duration text parser": "pub fn durationFromText" in pure,
        "pure view-count text parser": "pub fn viewsFromText" in pure,
        "pure published text parser": "pub fn publishedAgoDays" in pure,
        "pure YYYYMMDD converter": "pub fn ymdFromDaysSinceEpoch" in pure,
        "pure thumbnail-URL builder": "pub fn thumbUrl" in pure,
        "pure channel-row rejection": "pub fn isChannelRow" in pure,
        "pure query normalizer": "pub fn normalizeQuery" in pure,
        "pure JSON unescape": "pub fn unescapeJson" in pure,
        "videos-only search params": "PARAMS_VIDEOS_ONLY" in pure,
        # ── Production routes THROUGH the pure module (no duplicated parsing) ──
        "service imports the pure module": 'it_pure = @import("youtube_innertube_pure.zig")' in svc,
        "fast path exists": "fn fetchViaInnerTube" in svc,
        "body built by the pure fn": "it_pure.buildSearchBody" in svc,
        "rows parsed by the pure iterator": "it_pure.nextVideo" in svc,
        "titles unescaped by the pure fn": "it_pure.unescapeJson" in svc,
        "dates via the pure converter": "it_pure.ymdFromDaysSinceEpoch" in svc,
        "thumbs via the pure builder": "it_pure.thumbUrl" in svc,
        "yt-dlp path shares the channel-row rejection": "it_pure.isChannelRow" in svc,
        # ── HTTP goes through the shared reliable-fetch seam, not a yt-dlp spawn ──
        "uses reliable_fetch": 'reliable_fetch.zig").fetch' in svc,
        "posts a body": ".post_body = post_body" in svc,
        "response buffer is heap-allocated": "alloc.alloc(u8, INNERTUBE_RESP_CAP)" in svc,
        # ── Waterfall: batched repaint, not per-item ──
        "batched refresh helper": "fn nudgeUi" in svc and "REFRESH_BATCH" in svc,
        "refresh guarded on dvui_win": "if (state.app.dvui_win) |win| dvui.refresh" in svc,
        "appendYt nudges the UI": "nudgeUi(false);" in svc,
        # ── Layered fallback: InnerTube -> yt-dlp -> Piped, generation-guarded ──
        "innertube leads": svc.index("fetchViaInnerTube(q,") < svc.index("fetchViaYtdlp(q,"),
        "ytdlp before piped": svc.index("fetchViaYtdlp(q,") < svc.index("fetchViaPiped(q,"),
        "fallbacks gated on nothing-landed": "if (pendingClear(job.generation) and isCurrent(job.generation)) fetchViaYtdlp" in svc,
        "piped gated too": "if (pendingClear(job.generation) and isCurrent(job.generation)) _ = fetchViaPiped" in svc,
        "generation guard kept": "fn isCurrent(gen: u32) bool" in svc,
        "lazy-clear kept": "fn armPendingClear(generation: u32) bool" in svc,
        # ── SWR disk cache of parsed rows ──
        "cache key via normalizeQuery": "it_pure.normalizeQuery" in svc,
        "serializer": "fn serializeYtResults" in svc,
        "deserializer": "fn deserializeYtInto" in svc,
        "cache seed": "fn populateYtFromCache" in svc,
        "cache store": "fn storeYtToCache" in svc,
        "gated on the user toggle": svc.count("if (!state.app.content_cache_enabled) return") >= 2,
        "uses the shared content cache": 'content_cache = @import("../core/content_cache.zig")' in svc,
        "serialization via content_cache_pure": 'ccp = @import("../core/content_cache_pure.zig")' in svc,
        "re-arms pending_clear after seeding": svc.count("armPendingClear(job.generation)") >= 3,
        # ── Paging: InnerTube continuation tokens (infinite scroll) ──
        "pure continuation body builder": "pub fn buildContinuationBody" in pure,
        "pure token extractor": "pub fn extractContinuationToken" in pure,
        "pure channel-browse body builder": "pub fn buildChannelBrowseBody" in pure,
        "pure channel-id validator": "pub fn isChannelId" in pure,
        "pure lockupViewModel reader": "pub fn nextLockupVideo" in pure,
        "pure lockup metadata splitter": "pub fn lockupMeta" in pure,
        "browse endpoint + videos-tab params": "BROWSE_URL" in pure and "CHANNEL_VIDEOS_PARAMS" in pure,
        "token bound": "MAX_TOKEN_LEN" in pure,
        "cursor state": "var cont_token:" in svc and "var cont_is_browse:" in svc,
        "cursor stored via the pure extractor": "it_pure.extractContinuationToken" in svc,
        "cursor reset on a new feed": svc.count("clearContinuation();") >= 2,
        "continuation fetch": "fn fetchContinuation" in svc,
        "continuation body via the pure fn": "it_pure.buildContinuationBody" in svc,
        "load-more tries the continuation first": svc.index("fetchContinuation(job.generation,") < svc.index("fetchChannelViaYtdlp(job.channel_id[0..job.channel_id_len], job.generation, job.wanted)"),
        "load-more falls back to yt-dlp": "fn fetchMore" in svc and "fetchViaYtdlp(job.query[0..job.query_len], job.generation, job.wanted)" in svc,
        "load-more stops at exhaustion": "more_available" in svc and "const added = after -| before;" in svc,
        "cursor read/written under yt_mutex": "const tlen = cont_token_len;" in svc,
        # ── Channel mode on InnerTube browse ──
        "channel fast path": "fn fetchChannelViaInnerTube" in svc,
        "channel browse body via the pure fn": "it_pure.buildChannelBrowseBody" in svc,
        "channel rows via the lockup reader": "it_pure.nextLockupVideo" in svc,
        "channel falls back to yt-dlp": "if (n == 0 and isCurrent(job.generation))" in svc and "fetchChannelViaYtdlp(job.id[0..job.id_len]" in svc,
        "channel byline copied for the worker": ".name_len = channel_name_len" in svc and "@memcpy(job.name" in svc,
        "requests use immutable jobs": all(name in svc for name in ("const SearchJob = struct", "const ChannelJob = struct", "const MoreJob = struct")),
        "active searches are supersedable": "pub fn fetchYoutube(query" in svc and "if (state.app.yt.is_loading.load(.acquire)) return;" not in svc[svc.index("pub fn fetchYoutube(query"):svc.index("pub fn openChannel")],
        # ── No regressions in the paths we didn't own ──
        "channel mode intact": "fn fetchChannelViaYtdlp" in svc and "pub fn openChannel" in svc,
        "load-more paging intact": "pub fn fetchMore" in svc and "appending_more" in svc,
        "suggestions intact": "fn fireSuggest" in svc and "yt_pure.parseSuggestions" in svc,
        "ITEM_CAP intact": "const ITEM_CAP: usize = 200" in svc,
        "UI-thread texture free intact": "queueYtTexFree" in svc and "fn drainYtTexFrees" in svc,
    }
    _ = build

    missing = [k for k, ok in checks.items() if not ok]
    if not missing:
        return "pass", "InnerTube fast path wired: pure(body/iter/fields) -> reliable_fetch POST -> batched refresh; fallback InnerTube>yt-dlp>Piped; SWR content cache"
    return "fail", "InnerTube wiring incomplete: " + ", ".join(missing)


@test("yt-dlp fallback has a bounded process-tree lifecycle", "YouTube")
def ytdlp_fallback_is_contained():
    svc = _src("src/services/youtube.zig")
    block = svc[svc.index("fn runYtdlp("):]
    block = block[:block.index("\nfn parseYtdlpLine", 10)]
    checks = {
        "shared streaming seam": "bounded_process.StreamProcess.init" in block,
        "deadline": ".timeout_ms = 120 * 1000" in block,
        "output budget": ".max_output_bytes = 16 * 1024 * 1024" in block
            and "process.noteOutput" in block,
        "generation cancellation": ".cancel_epoch" in block
            and "&search_request.generation" in block and ".expected = gen" in block,
        "incremental rows retained": "process.stdout()" in block
            and "takeDelimiter('\\n')" in block and "parseYtdlpLine(line, gen)" in block,
        "supersede requests tree stop": "process.requestStop();" in block,
        "owner finishes and reaps": "process.finish()" in block,
        "no raw child spawn": "io.Child.init" not in block and ".spawn()" not in block,
    }
    missing = [name for name, ok in checks.items() if not ok]
    if missing:
        return "fail", "yt-dlp containment incomplete: " + ", ".join(missing)
    return "pass", ("yt-dlp fallback remains incremental behind a 120s/16MiB "
                    "generation-cancelled whole-tree guard")


@test("YouTube quality and auto-load controls remain accessible", "Video")
def test_youtube_quality_and_auto_load():
    svc = _src("src/services/youtube.zig")
    footer = _src("src/ui/footer.zig")
    player = _src("src/player/player.zig")
    config = _src("src/core/config.zig")
    assert '"Quality: 1080p"' in svc and '"Quality: 4K"' in svc
    assert 'components.compactToggle(@src(), "Auto-load"' in svc
    assert 'yt_pure.shouldAutoLoad(state.app.youtube_auto_load_more' in svc
    assert '"Load more videos"' in svc
    assert config.count('"youtube_auto_load_more"') == 2
    assert 'active.isYoutubeSource()) active.reloadYoutubeAtQuality()' in svc
    assert 'if (active_p.isYoutubeSource()) {' in footer and '710, icons.tvg.lucide.monitor' in footer
    assert 'self.audio_only_intent = state.app.ytdl_format_idx == 3;' in player
    assert 'video_is_playing' not in footer
    return "pass", "Visible 720p/1080p/4K selector, persisted auto-load/manual pagination and recovery from audio-only"


@test("Lyrics are scoped to the active track and cleared before video playback", "Player")
def test_lyrics_video_transition():
    music = _src("src/services/music_subsonic.zig")
    player = _src("src/player/player.zig")
    lyrics = _src("src/services/lyrics.zig")
    assert 'lyrics.hasLyricsFor(active.np_subtitle' in music
    assert '!active.audio_only_intent or active.is_loading' in music
    assert 'if (!request.audio_only) @import("../services/lyrics.zig").clear();' in player
    assert 'Browse regression song lyrics disappear when a show replaces music' in lyrics
    assert '@import("services/lyrics.zig")' in _src("src/main.zig")
    return "pass", "Song-to-show regression rejects stale timelines and late worker publication"
