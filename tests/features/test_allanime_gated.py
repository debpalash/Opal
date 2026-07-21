"""AllAnime — gated source endpoint (migrated to opal-plugins).

AllAnime (api.allanime.day / allmanga.to) is the anime search provider in the
universal resolver. It's a scrape-class streaming source — the same class as
AnimePahe and the torrent engines, which ship gated behind a plugin install —
so it must NOT be hardcoded live in the binary the way the Jikan/AniList metadata
APIs are. This pins the extraction: the endpoint comes from source_config and no
allanime.day / allmanga.to host literal survives in the source.

See tests/features/harness.py for the shared @test decorator + helpers."""
from .harness import *  # noqa: F401,F403

import os
import json as _json


@test("AllAnime source is gated via opal-plugins", "Player")
def test_allanime_gated():
    resolver = _src("src/services/resolver.zig")
    anime = _src("src/services/anime.zig")
    scraper = _src("src/services/anime_scraper.zig")

    problems = []

    # 1) resolver.zig reads the endpoint from source_config, inert when absent.
    if 'get("allanime", "base")' not in resolver:
        problems.append("resolver not gated behind source_config allanime base")
    if 'get("allanime", "referer")' not in resolver:
        problems.append("resolver does not read the allanime referer from source_config")

    # 2) No source host literal left anywhere in the source (the whole point).
    for f, src in (("resolver.zig", resolver), ("anime.zig", anime),
                   ("anime_scraper.zig", scraper)):
        if "api.allanime.day" in src or "allmanga.to" in src:
            problems.append(f"{f} still hardcodes an allanime host literal")

    # 3) The decode helper takes the base as a param instead of hardcoding it.
    if "decodeSourceURL(allocator: std.mem.Allocator, encoded: []const u8, base:" not in scraper:
        problems.append("decodeSourceURL does not accept an injected base")

    # 4) Manifest entries present (bundled + per-plugin file reference).
    with open(os.path.join(PROJECT_DIR, "data", "plugins-manifest.json")) as fh:
        manifest = _json.load(fh)
    entry = next((p for p in manifest["plugins"] if p["id"] == "allanime"), None)
    if not (entry and entry.get("type") == "anime"):
        problems.append("bundled manifest missing allanime entry (type anime)")
    elif "api.allanime.day" not in entry["endpoints"].get("base", ""):
        problems.append("allanime manifest entry has no base endpoint")

    if problems:
        return "fail", "; ".join(problems)
    return ("pass", "allanime gated: resolver reads source_config base+referer, "
            "no host literal in source, decodeSourceURL base injected, manifest wired")
