# Browse sources and verification

Opal separates catalog discovery, episode/chapter metadata, and playback. A
catalog entry or passing fixture test alone does not demonstrate that a source
can play a title. Source availability also depends on the network and region.

## Available paths

| Browse page | Discovery and reading/playback | Configuration |
| --- | --- | --- |
| Anime | Jikan and AniList metadata; exact episode releases through SubsPlease; direct AllAnime and AnimePahe adapters; NekoBT and Shana Project torrent searches; existing torrent/Stremio fallback | Install the desired playback sources in Sources. SubsPlease uses the torrent player. |
| Comics and manga | MangaDex popular titles and search; Weeb Central manga and ComicBookPlus public-domain comics; ReadAllComics, HeanCMS, MangaThemesia, Madara, and configured Suwayomi extensions | MangaDex is available by default. Other connectors need their installed endpoint or server. |
| Podcasts | gpodder.net plus Apple charts/search, deduplicated by RSS feed URL; direct RSS feed URLs; installable NASA, BBC Global News and NPR Up First feeds | No account needed. Paste an HTTP(S) RSS URL into podcast search to add a show to the results. |
| Radio | Radio Browser directory with alternate-host failover, station-name, genre and country search | No account needed. Search `tag:jazz` or `country:India`, or enter a station name. |
| Novels | Wikisource, Internet Archive, Royal Road, NovelFire and installed theme adapters | Royal Road and NovelFire require installed sources. The chapter list holds up to 400 chapters. |
| Torrents and movies | Existing indexes plus NekoBT, Shana Project and Public Domain Torrents | Install the desired sources; NekoBT and Shana are anime indexes, Public Domain Torrents is a movie catalog. |
| Music | JioSaavn, installed Audius public streams and existing personal-server clients; LRCLIB lyrics already supported | Install Audius, then select it in Music. Empty Audius search shows trending tracks. |
| Personal libraries | Existing OPDS, Suwayomi, Jellyfin, Plex, Subsonic and Audiobookshelf clients | Configure a server/account; these are not public catalogs. |

SubsPlease only resolves an exact series and episode that its search index
returns. It does not substitute a different episode if an older release is
absent. Resolution prefers the highest listed quality up to 1080p. Magnets still
need reachable peers; successful release lookup is not a playback guarantee.

## Checks performed on 2026-09-29

An isolated headless instance, separate from the user's configuration, loaded:

- 50 podcast shows from the combined directories.
- 30 radio stations, then 60 after loading the next page.
- 20 popular MangaDex results, then 40 after loading the next page.
- NASA's *Houston We Have a Podcast* from its RSS URL, with 200 playable episode
  entries (the current episode-list limit).

Additional source probes:

- SubsPlease search returned One Piece releases including episode 1180. This
  verifies the release metadata and magnet lookup; no torrent was downloaded
  as part of that probe.
- BBC and NPR RSS feeds responded with RSS documents.
- AnimePahe and AllAnime returned HTTP 403 from this network, including with a
  browser TLS client. Their repaired adapters remain dependent on provider access.
- Jikan returned HTTP 504 for MILGЯAM episode metadata. AniList remains the
  fallback for episode counts when individual episode metadata is unavailable.
- HiAnime search responded, but sampled episodes used a changed stream
  extractor format. It was not promoted to an installable connector.

## Earlier supplied links

The original research is in the sibling `opal-plugins` repository:

- `catalog/SCAN_LOG.md`: aggregator coverage, user-pasted Reddit lists and gaps.
- `catalog/anime-sources.json`: anime source candidates and exclusions.
- `catalog/reading-sources.json`: comics, manga, novels and books.
- `catalog/music-sources.json`: music and audio candidates.
- `catalog/torrent-sources.json` and `catalog/ddl-sources.json`: other candidates.

Those catalog files are research staging. An entry requires an implemented
connector and validation before it can be advertised as a working source.

## Sources added from the earlier inventory

The 2026-09-29 expansion implements eight candidates from the original links
and adds three official publisher feeds:

| Source | Verified application path |
| --- | --- |
| NekoBT | JSON search returned 50 One Piece release magnets. |
| Shana Project | Search returned 50 episode torrent links. |
| Public Domain Torrents | Catalog search resolved three torrent formats for the sampled movie; the torrent endpoint served BitTorrent metadata. |
| Royal Road | 20 search results; the sampled work opened three chapters and over 4,000 text characters. |
| NovelFire | 20 search results; the paginated directory filled the 400-chapter limit; the first chapter opened over 3,900 text characters. |
| Weeb Central | Manga search opened the oldest available chapter with 57 page URLs; the app served 345,017 bytes for the first image. |
| ComicBookPlus | Latest uploads opened a public-domain issue with 128 page URLs, reaching the reader limit; the app served 47,057 bytes for the first image. |
| Audius | 38 public stream entries; two sampled streams returned HTTP 206 with audio/mpeg bytes. |
| NASA, BBC Global News, NPR Up First | All three installed RSS shows appeared in podcast browse. |

Install entries in **Sources**. The adapters are inert until their endpoints
are installed. The new entries require a build containing these connectors.
ComicBookPlus search filters titles in fetched latest-upload pages, rather than
searching its full archive. Comics over 128 pages show a reader-limit warning.
No media playback or torrent content download was performed during validation.
One repeated NovelFire chapter fetch failed transiently; reopening the same
chapter succeeded. Provider access can still vary between requests.

Candidates still requiring work include MangaNato (HTTP 403 here), Erai-raws
(TLS failures/HTTP 502), Project AcgnX and BT4G (HTTP 403), and AnimeParadise
(asset/API inspection blocked with HTTP 403). WuxiaClick responded, but the
sampled query returned a generic listing; a proper search/chapter adapter remains
necessary. GetComics and KHInsider responded, but their download chains are not
implemented. These remain research entries rather than working source claims.

Validation for the expansion: native unit/browse suites and the headless build
passed; the feature suite reported 463 passed, 0 failed, 1 warning and 11
skipped. The web lifecycle suite reported 29 passed.
