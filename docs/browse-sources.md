# Browse sources and verification

Opal separates catalog discovery, episode/chapter metadata, and playback. A
catalog entry or passing fixture test alone does not demonstrate that a source
can play a title. Source availability also depends on the network and region.

## Available paths

| Browse page | Discovery and reading/playback | Configuration |
| --- | --- | --- |
| Anime | Jikan and AniList metadata; exact episode releases through SubsPlease; direct AllAnime and AnimePahe adapters; existing torrent/Stremio fallback | Install the desired playback sources in Sources. SubsPlease uses the torrent player. |
| Comics and manga | MangaDex popular titles and search; ReadAllComics, HeanCMS, MangaThemesia, Madara, and configured Suwayomi extensions | MangaDex is available by default. Other connectors need their installed endpoint or server. |
| Podcasts | gpodder.net plus Apple charts/search, deduplicated by RSS feed URL; direct RSS feed URLs | No account needed. Paste an HTTP(S) RSS URL into podcast search to add a show to the results. |
| Radio | Radio Browser directory with alternate-host failover, station-name, genre and country search | No account needed. Search `tag:jazz` or `country:India`, or enter a station name. |
| Novels | Existing Wikisource, Internet Archive and installed source adapters | Source availability and file formats vary. |
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
