# Opal Web UI parity plan

## Goal

The browser is a first-class Opal client, not a remote-control afterthought.
Anything a user can safely do in the native app must be discoverable and
operable in the web UI on desktop, tablet, and phone. A capability is only
"at parity" when its complete user workflow works, not merely when a page and
an HTTP route exist.

Two native-only exceptions remain intentional:

- operating-system file-association registration;
- configuration that grants Opal permission to execute arbitrary local scripts.

Everything else is in scope. Local-file picking uses the browser's file APIs or
an explicit upload/open flow instead of exposing the host filesystem.

## What parity means

Every operation is measured at five levels. The current page-count test is only
level 1 and must not be presented as complete product parity.

| Level | Contract | Evidence |
|---|---|---|
| 0 | Missing | Recorded with an owner and next slice |
| 1 | Discoverable | Responsive navigation or contextual control |
| 2 | Readable | Real server state, loading, empty, and error states |
| 3 | Operable | The same mutation/action as native, with validation |
| 4 | Trustworthy | Refresh/reconnect persistence, authorization, keyboard and touch access, plus browser end-to-end coverage |

"Full parity" means every safe native operation is level 4. A page with one
happy-path button does not cover every operation behind that native page.

## Baseline (2026-08-13)

- The existing surface ledger classifies 46 broad capabilities and 24 web
  destinations. It protects route/page presence but not operation depth.
- The web app already has a large real surface: hosted playback and transcode,
  universal media search primitives, downloads/torrents, queue/history, TMDB,
  YouTube, live TV, anime, music/radio/podcasts, comics/novels, Plex, Jellyfin,
  Audiobookshelf, OPDS, RSS, AI, plugins, Trakt, settings, access control, logs,
  and watch parties.
- The main usability blocker was a 24-item horizontal phone tab bar. It is now
  an adaptive media-center shell: four stable phone destinations plus grouped
  More, and a grouped desktop sidebar. All 24 routes are deep-linkable.
- Typed operation slices now cover the player deck, playlist rules, queue,
  transfers, and the first library mutations. These call the same domain
  operations as native code rather than maintaining browser-only state.

## Delivery waves

### Wave 0 — usable application shell (landed)

- [x] Home-first information architecture
- [x] Four-item phone navigation plus grouped More sheet
- [x] Persistent grouped desktop sidebar and wide content canvas
- [x] URL routes, browser back/forward, current-page semantics
- [x] Skip link, visible focus, focus trap, Escape, reduced motion
- [x] Responsive visual validation at phone and desktop viewports

### Wave 1 — discovery and couch workflows (in progress)

- [x] Home recommendations with refresh and playable handoff
- [x] Cast scan, device selection, active state, and stop
- [x] Rotate and flip from Now Playing
- [ ] One merged search result model across torrent, TMDB, YouTube, anime,
      Jellyfin, Plex, local/server libraries, and installed plugins
- [x] Open or queue an arbitrary URL/magnet with an optional title
- [x] Watch-party status, peer count, chat history/send, host, join, and leave
- [ ] Consistent Play here / Play on Opal / Queue actions on every playable card

### Wave 2 — full player deck

- [x] Exact audio and subtitle track lists and selection (not cycle-only)
- [x] Chapters, previous/next playlist item, and explicit time seeking
- [x] Playback speed, aspect ratio, zoom/pan, subtitle delay
- [x] Screenshot, A/B loop, clip export, and close-player action
- [x] Picture presets and brightness/contrast/saturation/gamma
- [x] Audio output device and equalizer presets
- [ ] Online/AI subtitle search, selection, download, and generation state
- [x] Player queue add/play/remove/reorder/clear with live played state
- [x] Playlist previous/next, repeat, and shuffle share native playlist rules
- [x] Explicit next-episode selection and exact search handoff
- [x] Now-playing metadata/art, loading/buffering/recovery state, and live
      cast/watch-party presence
- [ ] Fatal playback error reason and explicit retry action

These controls use one typed player snapshot and bounded action schema rather
than one ad-hoc route per button. The server owns validation and rejects raw
commands, non-finite numbers, out-of-range values, and unknown actions.

### Wave 3 — library ownership

- [ ] Unified details view for movies, shows, seasons, episodes, audio, books,
      podcasts, comics, and source-specific items — movies and shows now share
      one panel (`openDetails` → `/api/movie` + `/api/tv`) with overview,
      metadata, and a Find-streams action row; remaining kinds still pending
- [x] Exact TV/anime episode watched/unwatched state from library and show pages
- [x] Automatic/plan/watching/completed/dropped status mutations and safe
      TV/anime untracking that keeps watch history
- [x] Type/status filters and bounded metadata refresh state
- [ ] Favorite, rating, continue/resume, and synchronized movie-history removal
- [ ] Collections, playlists, queue add/remove/reorder/play, bulk actions
- [ ] Library scan/import, metadata corrections, duplicate handling
- [ ] Cross-source semantic deduplication and fallback stream candidates
- [ ] Persisted filters, sorting, view mode, pagination, and virtualized grids

### Wave 4 — source and integration ownership

- [ ] Complete Plex/Jellyfin connection, library, search, details, playback,
      progress/favorite mutations, and failure recovery
- [x] Source endpoint catalog with accurate installed state, grouping/filtering,
      bounded refresh, version update, install/remove, and integration config
- [ ] Source health, permission review, diagnostics, and executable-plugin
      lifecycle in the web client
- [ ] Trakt/AniList/SIMKL authorization, sync state, conflicts, and retry queue
- [ ] Debrid, Suwayomi, Audiobookshelf, OPDS, IPTV, RSS, and custom source CRUD
- [x] Download/torrent pause, resume, cancel, per-file priority, rate limits,
      file lists, progress, ETA, and errors
- [ ] Transfer history cleanup, reveal-on-host, and explicit disk deletion

### Wave 5 — web-native product quality

- [x] Installable PWA shell, public-asset-only offline navigation, reconnect state
- [ ] Multiple users/profiles, session/device management, capability-scoped auth
- [ ] Screen-reader pass, 200% zoom/reflow, localization-ready strings
- [x] TV/remote directional focus, activation, overlay Back/Escape behavior,
      and large-screen sidebar layout
- [ ] Performance budgets: useful shell under 1.5 s on LAN, interaction under
      100 ms, no unbounded polling, bounded DOM lists and payloads

## Operation contract

The parity gate will be expanded from the existing broad `COVERED` dictionary
to a registry with one row per user operation:

```text
id · native evidence · API read/action · web control · persistence/security · e2e flow · status
```

Rules:

1. Native route/settings enums continue to guard navigation completeness.
2. Player commands, queue/library mutations, and source actions get explicit
   registry rows; newly added native operations fail classification until they
   are covered, intentionally excluded, or recorded as a gap.
3. A row cannot reach level 4 through string matching alone. It needs a browser
   flow against a deterministic API fixture; destructive/server mutations also
   need server-side tests.
4. The dashboard reports operation coverage by area and level. It never folds
   intentional native-only operations into the denominator.

## Fast execution loop

Work in thin end-to-end slices, in this order:

1. Reuse a real existing API and finish its UI, state, accessibility, and test.
2. Batch missing server operations behind a typed domain endpoint (player,
   library, downloads, integration), rather than growing unrelated route flags.
3. Add contract checks and one deterministic browser flow in the same change.
4. Validate phone, tablet, desktop, keyboard, reconnect, empty, loading, error,
   and authorization states before marking level 4.

The unified details/action model now covers movies and TV through one panel
(`openDetails`), fed by Browse, unified search (media-typed rows), Watching,
and the calendar. The next highest-leverage slice extends that panel to the
remaining kinds (audio, books, podcasts, comics, source items) and adds
people/related-content metadata, so source verticals reuse the player, queue,
transfer, and library command seams instead of growing one-off controls.

## Maintainability budgets

Parity work must deepen feature modules instead of extending application
monoliths. Automated architecture checks enforce these current ceilings:

- `src/services/remote.zig` stays below 5,000 lines and only coordinates shared
  authentication, locking, and legacy route families;
- web HTML stays below 1,000 lines, with no inline application CSS or JS;
- each browser feature bundle stays below 1,000 lines;
- new remote feature handlers stay below 500 lines and expose one small
  `handle(...)` or projection interface.

The limits are guardrails, not targets. A file approaching a limit gets split
by domain ownership before another capability is added.
