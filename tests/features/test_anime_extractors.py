"""Anime video extractors — the Aniyomi "lib/" layer (embed → playable stream).
See tests/features/harness.py for the shared @test decorator, helpers, and
run_all()."""
from .harness import *  # noqa: F401,F403


@test("Anime video extractors", "Player")
def test_anime_extractors():
    # An extractor turns a streaming-host EMBED URL into a real m3u8/mp4 + the
    # headers mpv needs. Verify: the pure module is registered + routed (tested
    # logic == shipped logic), the P.A.C.K.E.R unpacker + every host extractor is
    # present, the MegaCloud/HiAnime getSources chain (nonce + XRW + getSources)
    # is wired, the yt-dlp delegate list exists, and playEmbed passes the Referer
    # to mpv via http-header-fields before loadfile.
    pure = _src("src/services/anime_extractors_pure.zig")
    drv = _src("src/services/anime_extractors.zig")
    anime = _src("src/services/anime.zig")
    player = _src("src/player/player.zig")
    build = _src("build.zig")

    checks = {
        # ── Pure module: present + registered in `zig build test` ──
        "pure module present": bool(pure),
        "pure registered in build": 'b.path("src/services/anime_extractors_pure.zig")' in build,

        # ── P.A.C.K.E.R unpacker (unlocks StreamWish/Filemoon/VidHide/Mp4Upload) ──
        "unpackPacked present": "pub fn unpackPacked(" in pure,
        "packer canonical-token guard": "encodeToken(" in pure and "decodeToken(" in pure,
        "unpackPacked tested": "P.A.C.K.E.R payload to its source" in pure,

        # ── Per-host extractors (pure) ──
        "streamwish/filemoon/vidhide via m3u8 url": "pub fn extractUrlContaining(" in pure,
        "mp4upload mp4 extraction tested": "Mp4Upload-style mp4 extraction" in pure,
        "streamtape token join": "pub fn extractStreamTape(" in pure,
        "streamtape tested": "StreamTape two-part token join" in pure,
        "dood pass_md5 extract": "pub fn extractDoodPath(" in pure,
        "dood assembly": "pub fn assembleDoodUrl(" in pure,
        "dood tested": "DoodStream pass_md5 extraction + assembly" in pure,

        # ── MegaCloud / HiAnime getSources chain ──
        "megacloud sourceId": "pub fn megacloudSourceId(" in pure,
        "megacloud nonce scrape": "pub fn megacloudNonce(" in pure,
        "megacloud getSources url": "pub fn megacloudGetSourcesUrl(" in pure,
        "megacloud getSources path": "/embed-2/ajax/e-1/getSources" in pure,
        "megacloud _k param": "&_k=" in pure,
        "megacloud json parse": "pub fn parseGetSources(" in pure,
        "megacloud plaintext (skip encrypted)": "encrypted" in pure and "encrypted response is flagged" in pure,
        "megacloud captions subs": '"\\"captions\\""' in pure or '"captions"' in pure,

        # ── Host classification + yt-dlp delegate list ──
        "classifyHost present": "pub fn classifyHost(" in pure,
        "shouldDelegateToYtdlp present": "pub fn shouldDelegateToYtdlp(" in pure,
        "delegate youtube": '"youtube.com"' in pure,
        "delegate dailymotion": '"dailymotion.com"' in pure,
        "delegate okru": '"ok.ru"' in pure,
        "delegate vk": '"vk.com"' in pure,
        "delegate sibnet": '"sibnet.ru"' in pure,
        "delegate list tested": "yt-dlp delegate list" in pure,

        # ── Driver: fetch + route through pure ──
        "driver present": bool(drv),
        "driver resolveEmbed": "pub fn resolveEmbed(" in drv,
        "driver routes classifyHost": "pure.classifyHost(" in drv,
        "driver routes unpackPacked": "pure.unpackPacked(" in drv,
        "driver routes parseGetSources": "pure.parseGetSources(" in drv,
        "driver uses scrapeFetch": "scrape.scrapeFetch(" in drv,
        "driver XRW header": "X-Requested-With: XMLHttpRequest" in drv,
        "driver delegate sentinel": ".delegate = true" in drv,

        # ── Wiring: playEmbed → Referer via http-header-fields → loadfile → subs ──
        "player loadStreamWithHeaders": "pub fn loadStreamWithHeaders(" in player,
        "player sets http-header-fields": '"http-header-fields"' in player,
        "anime playEmbed public": "pub fn playEmbed(" in anime,
        "playEmbed calls resolveEmbed": "resolveEmbed(embed)" in anime,
        "playEmbed loads with referer": "loadStreamWithHeaders(" in anime,
        "playEmbed attaches subs": "sub-add" in anime,
        "playEmbed reveals player": "state.gotoPlayer()" in anime,
        "playEmbed player-idx guard": "active_player_idx < state.app.players.items.len" in anime,
        "playEmbed off UI thread": "std.Thread.spawn(.{}, S.worker" in anime,
    }

    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "anime-extractor wiring incomplete: " + ", ".join(missing)

    return "pass", (
        "extractors wired: pure(unpackPacked + streamwish/mp4upload/streamtape/dood/"
        "megacloud, routed) → driver(resolveEmbed, scrapeFetch/curl+XRW, yt-dlp "
        "delegate) → playEmbed(Referer via http-header-fields, sub-add, gotoPlayer)"
    )
