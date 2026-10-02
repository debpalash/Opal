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

## Universal search coverage

Loading improvements dated 2026-10-02. The validation results above describe
the earlier source expansion, not this set of changes.

Universal search runs independent requests against the selected search sources.
It does not call a Browse tab's search function or replace that tab's query and
results. Source buttons show fetching, results, no matches, partial results,
transport/parse failures, or unavailable configuration separately. Results
already returned remain usable while slower sources finish.

| Content | Universal search | Result action |
| --- | --- | --- |
| Movies and television | TMDB when configured, public Cinemeta otherwise; Cinemeta also backs up failed TMDB catalog requests | Show details or find playback sources; a metadata hit is not a playable stream |
| Torrents | Installed Nova2 indexes, YTS, configured Torznab/Prowlarr/Jackett, installed EZTV, cached RSS magnets | Resolve the listed magnet or source detail page |
| Anime | Installed anime connector plus torrent/Stremio providers | Open anime discovery; playback still requires an accessible source |
| Comics and manga | Installed comic connector and trusted executable source plugins | Open the comics reader |
| Novels | Independent Wikisource and Internet Archive readable-text searches, plus compatible installed executable plugins | Open the built-in reader by copied work identity |
| Visual novels | Independent public VNDB lookup with the existing cover filter | Open VNDB details; Opal does not run or download a visual novel from a metadata result |
| Drama | Movie/TV catalog searches include drama titles; playback uses the normal configured resolver | Catalog details or source discovery; no dedicated drama streaming scraper is built in |
| YouTube | Independent bounded yt-dlp search | Play the canonical video URL |
| Live television | Loaded IPTV catalog matched against the query | Play with the channel's required headers |
| Music, radio and podcasts | Independent public provider requests | Play audio or open a podcast's episode view |
| Personal video libraries | Connected Jellyfin and Plex server searches | Play the server item; credentials stay out of universal result URLs |
| Local files | Configured download directory | Play the existing local file |
| Installed source plugins | Trusted executable plugins implementing the search protocol | Open the supplied stream or resolve the plugin item |
| OPDS and Audiobookshelf | Their configured Browse libraries remain separate from universal query fan-out | Browse the connected library page |
| Web | URL navigation in the web browser, rather than a media catalog provider | Open a website |

Catalog results retain real provider covers, descriptions, ratings and genres
when supplied. Empty fields remain unknown. VNDB's provider rating uses a
100-point scale; universal cards convert it to the shared ten-point scale.
Arbitrary executable-plugin scores are not converted into ratings because their
units are unspecified. Search caches include the enrichment and use a new
format key so older cache rows cannot decode as new results.

Wikisource, Internet Archive and VNDB queries are bounded to twelve records per
provider; YouTube discovery requests ten records. These limits prevent a single
catalog from occupying every universal result slot. Browse pagination remains
the path for exploring a larger catalog.

## Provider contract research for loading improvements

The [Stremio catalog request contract](https://github.com/Stremio/stremio-addon-sdk/blob/master/docs/api/requests/defineCatalogHandler.md)
distinguishes search and catalog pagination, and its
[metadata contract](https://github.com/Stremio/stremio-addon-sdk/blob/master/docs/api/responses/meta.md)
defines optional artwork, descriptions, release dates and IMDb ratings.
Cinemeta responses provide those fields directly; a local HTTP inspection
returned 49 movie records with the expected metadata. This inspection verifies
the response shape, not playback of all listed titles.

The [MediaWiki search API](https://www.mediawiki.org/wiki/API:Search) provides
Wikisource titles and snippets without a reader-side search mutation. The
[VNDB HTTPS API](https://api.vndb.org/kana) provides public visual-novel metadata
and image flags. Direct request inspections returned two Wikisource search
records and two VNDB metadata records. These inspections do not replace app
build checks or interactive verification.

Failure handling now preserves existing movie/TV cards when refresh fails,
marks cache freshness after successful publication, and distinguishes rejected
Plex authentication from a genuine empty server search. Independent VNDB detail
requests preserve the Browse grid and discard superseded detail responses.
Upstream outages, access restrictions and absent server configuration remain
reported conditions; they cannot be repaired by adding an unverified mirror.

## Loading and reader promise gaps addressed

| Promise | Change | Practical limit |
| --- | --- | --- |
| Useful discovery results | Real covers, authors, years, snippets, summaries and ratings reach native and web views | A missing provider field stays empty |
| Keep browsing beyond the first page | Wikisource uses the server continuation; comics and audio advance by consumed provider rows | Fixed result buffers still bound a session |
| Read a manga series | MangaDex has a chapter picker and previous/next navigation; the web reader requests pages that actually finished downloading | 100 chapter rows per feed window, a client navigation bound of 10,000 rows, and 128 pages per chapter |
| Read novels without losing the selected work | Reader workers copy work identity; older requests cannot replace newer text or clear its loading state | 400 chapters and bounded text per work; truncated text is labelled |
| Reliable connected reading catalogs | OPDS checks HTTP success and complete Atom envelopes, decodes next links, deduplicates pages, and snapshots request credentials | Unprefixed OPDS 1.x Atom feeds; 300 entries and a 4 MiB response limit |
| Retain usable television catalogs | IPTV source replacement deletes and inserts in one transaction, rolling back failed replacements | Stream reachability still depends on the broadcaster |
| Accurate search actions | Catalog entries open details and reading entries open readers; queue actions require a usable playback identity | Metadata does not guarantee an accessible stream |
| Correct artwork while results change | Shared cover slots suppress images from superseded rows, including rows with no artwork | Failed images use a fallback |

Provider contracts used for these changes include the official
[MangaDex OpenAPI](https://api.mangadex.org/docs/static/api.yaml),
[Internet Archive advanced search](https://archive.org/advancedsearch.php),
[OPDS 1.2 specification](https://github.com/opds-community/specs/blob/master/opds-1.2.md),
[Radio Browser API](https://api.radio-browser.info/),
[Audius API](https://docs.audius.org/api/), and
[Audiobookshelf API](https://api.audiobookshelf.org/).
Personal-server playback still requires verification against a configured server.


Connected Audiobookshelf searches use the upstream
[library search controller](https://github.com/advplyr/audiobookshelf/blob/master/server/controllers/LibraryController.js)
and [expanded book search response](https://github.com/advplyr/audiobookshelf/blob/master/server/utils/queries/libraryItemsBookFilters.js)
contracts: `GET /api/libraries/{id}/search?q=...&limit=6`, with `book` or
`podcast` matches wrapping `libraryItem` metadata. Up to sixteen permitted
libraries are searched concurrently; universal search surfaces at most twelve
items across them. Responses and each request are bounded. Authentication stays
in headers, and only stable item identities enter universal results.

Opening an Audiobookshelf result fetches expanded file metadata rather than
passing its download archive to the media player. Native and web views offer
actual audio tracks or downloaded podcast episodes, with up to 128 selectable
files and explicit returned/total/truncation information. Single-file books can
start immediately and use book-wide server resume. Multi-file playback uses
manual track selection; automatic track advancement and book-wide resume across
files are not implemented. No connected personal-server search or playback was
verified during this provider-contract research.

## Checks for the 2026-10-02 loading changes

- Native `zig build` passed after integration, including the refresh retry cooldown.
- JavaScript syntax checks passed for `catalog.js`, `media.js` and `integrations.js`.
- Zig formatting and `git diff --check` passed.
- Regression tests and interactive playback checks were not run for these changes.
- Personal-server search/playback has not been verified against a configured account.

Remaining functional gaps include independent OPDS server search, automatic
Audiobookshelf track advancement, and server resume across multi-file books.
Provider outages and access restrictions remain external availability conditions.
