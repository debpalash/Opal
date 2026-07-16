"""Anime site-framework engines — DooPlay (~25 sites) + AnimeStream (~20 sites).

Both are base-URL-driven, source_config-gated WordPress-theme scrapers that parse
a site's catalog/episode list and feed episode EMBED URLs to the video extractors
already on main (anime_extractors.resolveEmbed via anime.playEmbed). See
tests/features/harness.py for the shared @test decorator + helpers."""
from .harness import *  # noqa: F401,F403


@test("Anime site frameworks (DooPlay + AnimeStream)", "Player")
def test_anime_site_frameworks():
    build = _src("build.zig")
    doo = _src("src/services/anime_dooplay_pure.zig")
    ani = _src("src/services/anime_animestream_pure.zig")
    anime = _src("src/services/anime.zig")

    problems = []

    # 1) Both pure modules registered in the build.zig test step (tested == shipped).
    for mod in ("anime_dooplay_pure", "anime_animestream_pure"):
        if f"{mod}.zig" not in build or f"test_{mod}" not in build:
            problems.append(f"{mod} not registered in build.zig test step")

    # 2) DooPlay pure surface: URL builders + grid/details/episodes + the
    #    admin-ajax EMBED chain (player options → POST body → embed_url JSON).
    for sym in ("pub fn buildSearchUrl", "pub fn buildPopularUrl",
                "pub fn buildAjaxUrl", "pub fn buildAjaxBody", "pub fn parseEmbedUrl",
                "pub const GridIter", "pub fn parseDetails",
                "pub const EpisodeIter", "pub const PlayerOptionIter"):
        if sym not in doo:
            problems.append(f"anime_dooplay_pure missing {sym}")
    if "doo_player_ajax" not in doo:
        problems.append("dooplay admin-ajax action (doo_player_ajax) missing")
    if "admin-ajax.php" not in doo:
        problems.append("dooplay admin-ajax.php endpoint missing")
    if '"embed_url"' not in doo:
        problems.append("dooplay embed_url JSON parse missing")
    for attr in ("data-post", "data-nume", "data-type"):
        if attr not in doo:
            problems.append(f"dooplay player option {attr} not read")
    if "ul.episodios" not in doo and "episodios" not in doo:
        problems.append("dooplay ul.episodios episode selector missing")

    # 3) AnimeStream pure surface: episode list + server/embed extraction, and
    #    REUSE of manga_themesia_pure for the shared Themesia grid/details DOM.
    for sym in ("pub fn buildSearchUrl", "pub const EpisodeIter",
                "pub fn firstEmbed", "pub fn decodeServerOption"):
        if sym not in ani:
            problems.append(f"anime_animestream_pure missing {sym}")
    if '@import("manga_themesia_pure.zig")' not in ani:
        problems.append("animestream does not reuse manga_themesia_pure")
    if "mt.SearchIter" not in ani and "SearchIter = mt.SearchIter" not in ani:
        problems.append("animestream does not reuse the Themesia SearchIter")
    if "eplister" not in ani:
        problems.append("animestream .eplister episode selector missing")
    if "base64" not in ani.lower() and "std.base64" not in ani:
        problems.append("animestream base64 server-option decode missing")
    if "iframe" not in ani:
        problems.append("animestream iframe src extraction missing")

    # 4) anime.zig routes ALL parsing through the pure modules (no drift).
    if '@import("anime_dooplay_pure.zig")' not in anime:
        problems.append("anime.zig does not import anime_dooplay_pure")
    if '@import("anime_animestream_pure.zig")' not in anime:
        problems.append("anime.zig does not import anime_animestream_pure")
    for routed in ("dooplay.gridIter", "dooplay.episodeIter", "dooplay.playerOptionIter",
                   "dooplay.buildAjaxBody", "dooplay.parseEmbedUrl"):
        if routed not in anime:
            problems.append(f"anime.zig does not route through {routed}")
    for routed in ("animestream.searchIter", "animestream.episodeIter", "animestream.firstEmbed"):
        if routed not in anime:
            problems.append(f"anime.zig does not route through {routed}")

    # 5) source_config-gated — INERT until a base URL is installed.
    if 'get("dooplay", "base")' not in anime:
        problems.append("dooplay not gated behind source_config base key")
    if 'get("animestream", "base")' not in anime:
        problems.append("animestream not gated behind source_config base key")

    # 6) The play flow resolves the episode EMBED and hands it to playEmbed /
    #    resolveEmbed (the extractor stack already on main).
    if "scraperPlayThread" not in anime:
        problems.append("anime.zig missing the scraper episode→play worker")
    if "playEmbed(e)" not in anime and "playEmbed(embed" not in anime:
        problems.append("scraper play path does not call playEmbed with the embed URL")
    # playEmbed itself must drive resolveEmbed (the shared extractor entrypoint).
    if "resolveEmbed" not in anime:
        problems.append("anime.zig play path does not reach resolveEmbed")

    # 7) Both frameworks wired into the existing search→detail→episode→play flow.
    if "scraperSearchThread" not in anime or "loadEpisodesScraper" not in anime:
        problems.append("anime.zig missing scraper search / episode fetchers")
    if "results_are_scraper" not in anime:
        problems.append("anime.zig missing the scraper-card routing flag")

    if problems:
        return "fail", "; ".join(problems)
    return ("pass", "DooPlay + AnimeStream engines wired: two tested pure parsers "
            "registered + routed (search/details/episodes + embed extraction), "
            "DooPlay doo_player_ajax admin-ajax embed chain, AnimeStream .eplister + "
            "base64 iframe embed, source_config-gated, episode play → embed → playEmbed/"
            "resolveEmbed")
