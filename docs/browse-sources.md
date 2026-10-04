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
| Novels | Wikisource, Internet Archive, Royal Road, NovelFire and installed theme adapters | Royal Road and NovelFire require installed sources. Chapter directories use bounded 400-row windows with previous/next traversal. |
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
  entries in its first episode page (subsequent pages were added in the maturity work below).

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
sampled query returned a generic listing at that time; a working installed-only search/chapter adapter is now available (see the GitHub source expansion below). Earlier candidate status remains historical.
GetComics and KHInsider responded, but their download chains are not
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
| OPDS | Independent search for configured catalogs advertising a supported Atom/OpenSearch GET template; unsupported or missing templates report unavailable | Open the connected reader item |
| Audiobookshelf | Independent search across permitted connected libraries | Open actual audio tracks or downloaded episodes |
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
| Read novels without losing the selected work | Reader workers copy work identity; older requests cannot replace newer text or clear its loading state | 400 rows per chapter window; absolute chapter navigation and work-scoped exact-URL resume. Whole-directory responses are bounded to 4 MiB; blocked/truncated responses report failure. Bounded text is labelled when truncated |
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
track selection, automatic advancement and book-wide resume across files. The
original provider-contract research did not verify connected personal-server
playback; isolated runtime verification is recorded below.

## Checks for the 2026-10-02 loading changes

- Native `zig build` passed after integration, including the refresh retry cooldown.
- JavaScript syntax checks passed for `catalog.js`, `media.js` and `integrations.js`.
- Zig formatting and `git diff --check` passed.
- Regression tests and interactive playback checks were not run for these changes.
- Personal-server search/playback has not been verified against a configured account.

The maturity work below adds independent advertised OPDS search and verifies
Audiobookshelf lifecycle behavior with isolated fixtures. Provider outages and
access restrictions remain external availability conditions.

## Maturity follow-up on 2026-10-02

See [the maturity audit](maturity-audit.md) for implementation details and
reproducible checks. Podcast feeds now expose their complete retained episode
count and 200-item pages within the existing 4 MiB feed bound. Playback actions
validate the rendered page's generation.

Six isolated runtime cases passed, including advertised authenticated OPDS search
without replacing Browse state, structural Audiobookshelf login, actual generated
audio advancing across two files, and whole-book resume into the second file.
Radio actions now use stable station UUIDs, and comics actions copy the selected
reader identity. These fixtures establish those contracts; they do not establish
external provider uptime or configured personal-server availability.

## Universal content search coverage (2026-10-03)

Universal search projects content works separately from their source options.
Positive typed catalog identities and matching IMDb identities retain their media
kind. Movie releases attach only with an exact normalized title and matching
positive year. Explicit `Sxx` / `SxxExx` releases can attach to a uniquely matching
TV title without a year; known same-title remakes remain ambiguous even when a
facet hides one. Ambiguous releases remain independently actionable.

The shared wave retains at most 192 rows. At capacity, an underrepresented
category can reclaim rows from categories containing more than eight rows;
within represented categories, relevance selects replacements. This protects
late catalog arrivals from torrent saturation without promising every provider
result will fit. Searches fetch bounded first pages; universal pagination across
all providers is not implemented.

| Content | Independent universal search providers | Conditions and limits |
| --- | --- | --- |
| Movies and shows | TMDB or keyless Cinemeta; installed Nova2 torrent engines, YTS, EZTV, configured Torznab; configured Stremio, local files, Jellyfin and Plex | Catalog search runs independently of playable-source toggles. Release quality and swarm health rank source options, rather than substituting for content identity. Personal services require configuration. |
| Anime | Jikan, with AniList fallback; installed AllAnime; anime torrent engines through the shared torrent search | Metadata search retains real title, cover, synopsis, year and rating. Metadata opens Anime discovery; it is not a verified playable stream. Up to twelve metadata rows are admitted per adapter. |
| Comics and manga | Keyless MangaDex; installed ReadAllComics | MangaDex retains its real cover and stable reader identity, and opens Comics discovery. The other Comics Browse adapters are not yet universal workers. |
| Books and novels | Wikisource, Internet Archive English DjVuTXT works, Gutenberg, public-access Open Library works, installed Royal Road and NovelFire; configured OPDS | Royal Road and NovelFire use the existing Browse listing parser with owned query/endpoint buffers and at most twelve works each. Challenge pages are parser failures, not successful empty listings. No Browse query or results are overwritten. Restricted Open Library lending items are excluded. |
| Visual novels | VNDB | Metadata discovery only; no game download or playback claim. |
| Audiobooks | Configured Audiobookshelf; Internet Archive audio | Audiobookshelf uses allowed libraries and real file metadata. Actual service availability depends on the configured server. |
| Music | Public JioSaavn; installed Audius; configured Subsonic; connected Jellyfin Audio and Plex tracks | Independent queries do not replace Music Browse state. A shared **16-result** budget is divided fairly among configured providers. Requests are bounded to four seconds and 512 KiB each. Private actions retain provider IDs and bind the searched server/library namespace; playback obtains fresh credentials. Private artwork URLs are withheld. |
| Podcasts | Apple Podcasts and gpodder; installed RSS feeds | Independent searches retain exact feed identities and share a **16-result** budget. At most four installed feeds are inspected per query, with two-second requests; additional installed feeds produce a partial-source status. The two public directories share the remaining budget, with four-second requests. Open a show in Podcasts and choose an episode to play. |
| Radio and live TV | Radio Browser; installed/configured IPTV | Each adapter contributes up to 16 results and retains actual station/channel stream identities. |
| Video and previews | YouTube search, Internet Archive video, NASA video, Wikimedia Commons video; explicit official TMDB trailer lookup | Preview lookup requires a current opaque result key and generation. TMDB previews require credentials and a verified official YouTube video; unavailable credentials or trailers remain explicit outcomes. Preview playback does not stand in for the full work. |
| Images and articles | Cover/backdrop metadata only; no standalone universal image or article adapter | NASA and Commons workers currently request video. Existing RSS records expose torrent magnets, rather than an article reader contract. |
| Installed executable plugins | Trusted installed plugin search workers | Coverage depends on each plugin's actual search contract and installation. An installed source configuration alone does not imply a universal worker exists. |

Reading cards carry covers only when supplied by the actual listing/provider;
authors and summaries are not invented for HTML listings that omit them. Other
installed novel Browse adapters (Madara, LightNovelWP, ReadWN and ReadNovelFull)
are not yet universal workers.

Search cache identity includes schema, source mask and an opaque fingerprint of
installed source configuration. Queries are hashed into bounded keys; endpoint
URLs and credentials are not emitted as cache-key text. A wave captures its
initial scope and skips cache writes when that scope changes while workers run.
Connected personal-library configuration outside the installed-source table is
not represented by that fingerprint. Account-bound Jellyfin, Plex, OPDS and
Audiobookshelf results, private music identities, installed executable plugin
results and unclassified Stremio session transports are therefore excluded from
the persisted search cache. They remain live search results and are fetched
afresh for each query. Public catalog/artwork and explicitly public Archive,
NASA, Commons, JioSaavn and Audius rows remain eligible. The cache policy version
invalidates earlier cached account rows. External provider uptime, personal
account access and full interactive playback are separate validation requirements.

### Visual search behavior and checks

The desktop omnibox submits a global query from every Browse page. All-content
results use artwork shelves; selecting a content category expands its results
into a wrapping grid. Cards reveal contextual details, saved-title controls,
and source comparisons. Unmatched releases remain separately actionable.
Saved titles reopen through global search rather than an expired stream URL.

Official trailer playback starts only on request, muted. Desktop uses a separate
libmpv context; the web client uses a validated YouTube privacy-enhanced embed.
Changing the query, selection, route, or closing the preview stops it. Trailer
lookup requires a TMDB key. Audio samples are not fabricated when a provider
does not supply a verified sample.

Reproducible checks:

```sh
zig build test
node --test tests/test_web_lifecycle.mjs
zig build test-search-gallery
python3 tests/test_features.py --database /tmp/opal-feature-fixture.sqlite --results /tmp/opal-feature-results.json
```

The optional native gallery check renders a hidden SDL window with generated
offline artwork; `OPAL_GALLERY_ART_DIR` can supply local poster fixtures and
`OPAL_GALLERY_CAPTURE_DIR` can retain PNG captures. It exercises shelves, filtered
grids, and scrolling at 1360×1000 and 640×800. No provider request or playback
occurs. Web regressions cover grouping, stale actions, filters, saving, and
verified preview lifecycle. Isolated API cases in
`tests/test_content_maturity_live.py` additionally cover preview/cancel generation
validation and saved-title persistence.

### GitHub source expansion — 2026-10-03

Seven new installed providers raise the bundled catalog to **85 entries**.
Install the sources you want from **Sources**; these connectors remain inactive
without their endpoint definition. Existing SubsPlease gains keyword search
without a second provider identity. The remote endpoint catalog is synchronized
with the app so refreshing does not discard bundled additions.

| Source | Content and action | Verified provider response |
| --- | --- | --- |
| DMHY | Anime release magnets, built-in torrent player | 79 unique Naruto magnets |
| ACG.RIP | Anime `.torrent` releases, built-in torrent player | 30 Naruto releases with byte sizes |
| SubsPlease (enhanced) | Keyword release magnets and existing episode lookup | 90 Naruto quality variants |
| Standard Ebooks | Books, author, JPEG cover, chapter reader | 7 works, 65 TOC entries, real XHTML prose |
| WuxiaClick | Novels, summaries, chapter reader | 12 works, 56 chapters, real prose |
| Openverse | Licensed full music with creator and license attribution | Real MP3 byte range, HTTP 206 |
| Archive Netlabels | Music releases and individual MP3 tracks | Real MP3 byte range, HTTP 206 |
| SomaFM | Independent live radio with station artwork | Official playlist and real MP3 stream bytes |

Research uses primary repositories and independently implemented protocol
adapters. No downloaded repository scripts were executed or copied:

- [Prowlarr definitions](https://github.com/Prowlarr/Indexers/tree/ecede5c247d8e31fa156ff49a8921c78327c5b5d/definitions/v11)
  and [Jackett definitions](https://github.com/Jackett/Jackett/tree/32d7cb94c7c9b3e38327014ad1029c04ac4b2cbc/src/Jackett.Common/Definitions): DMHY and ACG.RIP feed contracts.
- [Standard Ebooks website](https://github.com/standardebooks/web/tree/2428ad7ac3d48bf8701a9af27326a59968807484)
  (CC0) and [LightNovel Crawler WuxiaClick contract](https://github.com/lncrawl/lightnovel-crawler/blob/59b0382d51927953aa8120c5de62dab23ce3f731/sources/en/w/wuxiaclick.py)
  (GPL-3.0, research only).
- [Openverse](https://github.com/WordPress/openverse),
  [Internet Archive client](https://github.com/jjjake/internetarchive), and
  [SomaFM client](https://github.com/bshogol/shojey): public metadata/audio protocols.
- [FMHY reading inventory](https://github.com/fmhy/edit/blob/25c15c4d722068ea2179fb6c05071f11662aab96/docs/reading.md)
  and [audio inventory](https://github.com/fmhy/edit/blob/25c15c4d722068ea2179fb6c05071f11662aab96/docs/audio.md)
  independently list the selected reading services and SomaFM.

Torrent feeds do not expose trustworthy swarm counts; unknown counts remain
unknown. ACG.RIP `.torrent` URLs play but cannot use the magnet-only queue.
WuxiaClick advertises WebP covers: native and web now render these. Native covers,
comic pages and browser frames share bounded libwebp decoding. Reading uses
400-chapter windows with previous/next navigation and absolute chapter identities;
books longer than a window continue loading chapters. Resume is scoped to source
and canonical work URL, retaining the exact chapter URL when a directory changes. Audio catalogs use bounded requests and full
provider audio, with no fabricated previews. Provider uptime can still vary.
NovelHall, NovelFull, ScribbleHub, ccMixter, and weak LibriVox/Deezer probes were
excluded from this batch after blocked, timed-out, or unusable responses.

The earlier supplied links remain in the sibling source repository's
`catalog/SCAN_LOG.md` and `catalog/{anime,reading,music,torrent,ddl}-sources.json`.
Those are research inventories; catalog presence alone does not mean a working
Opal adapter. Torrent research provenance is in `engines/source-provenance.json`; reading and
audio research is in `data/source-research.json`.

Opt-in isolated app checks (fresh HOME/XDG; no user profile changes):

```sh
zig build -Dheadless=true --prefix /tmp/opal-sources-headless
python3 tests/test_github_reading_live.py --binary /tmp/opal-sources-headless/bin/opal --port 41707 --live-providers
python3 tests/test_github_audio_live.py --binary /tmp/opal-sources-headless/bin/opal --port 41709
python3 tests/test_github_torrent_sources.py
```

The reading check contacts real providers; audio app checks use owned local
metadata and silence fixtures. The audio byte probes above are separate live
provider evidence. Universal reader actions preserve Browse search state.


### ComicFury, Waveform and HiAnime (2026-10-03)

These additions require their installed source configuration. ComicFury's actual
public search returns owned title/cover/reader identities in Browse and universal
Search. The reader opens the oldest public batch and supports adjacent batches
from the provider's comic IDs; each batch is capped at 128 images. A full advertised
PNG was verified HTTP 200 (792,452 bytes, 2480×3508). Contract research:
[ComicFury extension](https://github.com/keiyoushi/extensions-source/blob/4c8cda759ae7f9948fecacb5eec2b47b011ccf51/src/all/comicfury/src/eu/kanade/tachiyomi/extension/all/comicfury/ComicFury.kt)
(Apache-2.0; no implementation copied).

Waveform uses the publisher's [Megaphone RSS feed](https://feeds.megaphone.fm/STU4418364045)
and the existing native/web episode selector and Opal player. The 2.03 MiB feed
fits the 4 MiB limit; a real episode returned HTTP 206, audio/mpeg, and 1,024 ID3
bytes. Episode windows remain capped at 200 rows with pagination. RSS parsing now
skips image/HTML enclosures and selects audio instead; publishers without enclosure
MIME types remain compatible.

HiAnime is a direct playback fallback, not a website playback action. It matches
an exact series title/alias and requested episode, then consumes the advertised
subtitled ZokoAnime server and bounded video configuration. Naruto episode 1
returned HTTP 200 for the master and 800p VOD playlists; the first media segment's
HEAD returned HTTP 200, video/mp2t (238,008 bytes). The stream requires Referer
`https://zokoanime.video/`. Only this verified server/sub mode is supported; missing
servers, malformed responses, cancellations and unavailable media fall through to
other providers. Contract research:
[ani-cli](https://github.com/pystardust/ani-cli/blob/3ad53631ef2433b0c26e25ab011a5b149706c120/ani-cli)
(GPL-3.0; original Opal implementation). Live HTTP evidence establishes provider
reachability, not uninterrupted playback or future availability.

Public metadata uses bounded requests, configured mirrors, brief caching and
source health; credentialed or media responses are not cached there. These
providers do not expose trustworthy availability/swarm counts. Detailed provenance
and probe limits are recorded in `data/source-research.json`.

### Public source reliability

Public audio, ComicFury, HiAnime metadata and installed reading search use a shared
bounded request seam. It retries only configured mirrors, preserving each request
path; it never invents domains. Source settings show unchecked, checking, ready,
cached, backup, unavailable and cancelled outcomes. Unchecked means no observation
has been made, not a successful health check.

The metadata cache holds at most eight entries of at most 1 MiB each, for the
adapter's short TTL. Source configuration changes invalidate it. Credentialed,
range and POST requests are excluded from caching and mirror forwarding. Public
search workers attach their owning generation to supervised requests; superseding
or cancelling a search terminates stale curl work. Shutdown terminates supervised
requests as well. Provider schema failures are not cached by validating adapters.

Deterministic checks:

```sh
zig build test-native-images
python3 tests/test_source_reliability_live.py --binary /tmp/opal-v2-headless/bin/opal
python3 tests/test_novel_windows_live.py --binary /tmp/opal-v2-headless/bin/opal
```

The source catalog is a set of installable choices. Provider uptime, regional
restrictions and unsupported embed hosts can still limit any individual source;
no installation or status label guarantees every title is available.


Isolated category action check:

```sh
python3 tests/test_github_categories_live.py --binary /tmp/opal-v2-headless/bin/opal --port 41712 --live-providers
```

Verified 2/2: ComicFury universal Search returned 12 works, opened six oldest
reader pages, preserved Browse results and served a real 439,024-byte PNG through
Opal's page API. The podcast test uses owned synthetic RSS and silence WAV and
verifies Opal's actual decoder is active with a positive duration; it proves the
new enclosure selection without streaming the live publisher episode.


### Verified public webcomics (2026-10-04)

Install **xkcd** or **Saturday Morning Breakfast Cereal** to enable their native
Comics source chips, web Comics source selector and independent universal Search
adapters. Both actions open
Opal's existing native/web comic reader with the publisher's complete main image;
searching does not replace Comics Browse results. Universal cards retain real
artwork, creator and hover text where supplied. Neither is an audio/video source.

| Source | Actual search scope | Reader | Bound |
| --- | --- | --- | --- |
| xkcd | Official title archive substring or exact comic number | Official numbered JSON advertises full static image | Six search rows; eight-second metadata budget |
| SMBC | Titles in the publisher's recent RSS feed | Direct work HTML `img#cc-comic`, including older saved URLs | Six search rows; recent feed reported partial |

The filtered native Browse chips expose the same bounded discovery. There is no
invented Load More for these providers. Refine the query for additional matches.
xkcd interactive comics are represented by their advertised static image; SMBC
bonus panels remain on the publisher website. Source presence does not guarantee
provider uptime.

Primary contracts: [xkcd official JSON](https://xkcd.com/json.html),
[xkcd archive](https://xkcd.com/archive/), and
[SMBC publisher RSS](https://www.smbc-comics.com/comic/rss). Maintained GitHub
references are pinned in `data/source-research.json` (Keiyoushi, Apache-2.0,
contract research only; independent Opal implementation).

Both metadata and advertised image paths returned success in bounded live probes.
The retained integration fixture uses original generated PNG pixels, verifies
universal search to opaque action to Opal reader, exact served image bytes and
unchanged Browse results:

```sh
python3 tests/test_webcomic_sources_live.py --binary /path/to/opal --port 41807
```

Rechecking earlier user links also found KHInsider search reachable while two album
pages returned 403, Manganato search 403, and AnimeParadise without a verified API
route. These were not added as working sources. LRCLIB is already a lyrics
adapter, so its reachable API does not count as an additional playback source.
