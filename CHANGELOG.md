# Changelog

What changed in each release, in the terms a user would notice.

Every section here becomes the **Highlights** block of the matching GitHub
Release — `scripts/release-notes.sh` extracts it by version heading and appends
the full commit list underneath, so the notes can never drift from the tag.
Add a section BEFORE tagging; a missing one ships a release that says so.

Headings are `## vX.Y.Z — YYYY-MM-DD`, newest first. The version token must
match the tag exactly.

## v0.7.0 — 2026-09-05

- **Closing Opal is immediate and final, even during active playback.** Native
  window close, `Ctrl+W`, and `Ctrl+Q` now share one bounded teardown path;
  playback stops before the surface disappears, raw SDL/Wayland close events
  cannot leave a windowless stream behind, and stuck workers cannot keep the
  process alive indefinitely.
- **Background work no longer races the UI during shutdown.** Resolver, search,
  poster, HTTP, and stream-proxy work receives cancellation before teardown,
  UI refreshes carry the real window, and the worker supervisor drains owned
  tasks before shared state is released.
- **Linux AppImages launch through an explicit runtime entry point.** The
  release pipeline now packages the expected AppRun launcher and validates the
  resulting image, alongside the existing tarball, DEB, RPM, and `.run`
  formats.
- **The keyless Movies & TV flow is documented end to end.** A new guide shows
  how Cinemeta browsing, search, posters, and TV season/episode navigation work
  without a TMDB key, with clearer privacy and provider-boundary documentation.

## v0.6.6 — 2026-08-28

- **Movies and TV now work without a catalog API key.** The built-in Cinemeta
  feed supplies trending, popular, top-rated, genre-filtered and searched
  cards, while TMDB remains an optional metadata upgrade rather than a setup
  requirement.
- **TV cards open a real season and episode browser in keyless mode.** Series
  metadata, episode names, summaries, dates and thumbnails flow into the same
  desktop and web drill-down used by TMDB-backed shows.
- **Poster loading is reliable again.** Absolute Metahub artwork is accepted by
  the guarded proxy, and WebP-only poster responses are requested through a
  decoder-compatible JPEG endpoint instead of becoming permanent placeholders.
- **Browse behaves properly from phones to ultrawide desktops.** Navigation no
  longer disappears during resize, Movies & TV gains compact filters and live
  search, cards adapt to available space, and the source menu follows the
  active theme instead of opening a bright white popup.
- **The Web UI is safer under hostile and concurrent input.** Text and HTML
  attributes use separate encoders, session and API response boundaries are
  hardened, and a real Chromium test proves provider markup cannot reach the
  live DOM.
- **Background work has clearer ownership.** Critical workers are supervised
  through shutdown, remote writes release player state first, and Podcast and
  Jellyfin readers publish immutable snapshots instead of racing live state.
- **Linux setup and display defaults are friendlier.** The installer is
  rootless by default, HiDPI scaling respects the whole panel, and font metrics
  no longer clip titles on Linux.
- **Release and project pages are easier to trust and navigate.** Download and
  playback paths received additional validation, and the website now exposes
  crawlable changelog, comparison and SEO pages.

## v0.6.5 — 2026-08-11

- **Torrent search works from the desktop app again.** Python's process pool
  crashed when nova2 was launched through Zig's child runtime, so every
  installed torrent source appeared to return zero results. Opal's bounded
  search path now uses network threads, while the qBittorrent-compatible CLI
  keeps its process pool. A dedicated CI job executes this exact Zig-to-Python
  seam so it cannot silently regress.
- **Torrent files selected by hand start sooner and keep working.** A chosen
  episode now gets the same head-first priority as the automatic pick, old
  buffer gates are released when switching files, and mpv no longer adds a
  second three-second startup buffer on top of Opal's readiness gate.
- **Startup and shutdown are safer.** Background services and process watchers
  now have explicit lifetimes, responsive stop paths, and one owner for each
  child-process handle instead of detached workers racing teardown.
- **Windows title-bar behaviour is native again.** Double-click maximizes and
  restores, maximize respects the current monitor's work area instead of
  covering the taskbar, and normal PowerShell builds locate their MSYS2 shell
  and toolchain without hand-editing `PATH`.
- **Windows releases can sign the whole payload.** When Azure Artifact Signing
  is enabled, the pipeline signs every executable and DLL, verifies that none
  were missed, then signs the MSI itself—covering the modules Windows 11 Smart
  App Control evaluates, not only `opal.exe`.
- **Opal Connect 0.4 has a real setup flow and a useful side panel.** It finds
  a local Opal, signs in or creates the first account without asking users to
  find a token file, and adds live torrents, downloads, recent searches,
  casting and watch-party controls, keyboard shortcuts, and the real Opal logo.
- **The new Opal website makes releases easier to install.** The download flow
  exposes every published format, detects the visitor's platform, retains
  no-JavaScript links, and adds install help, screenshots, comparisons, search
  metadata, and a proper project home at opal.palash.dev.
- **Browser transcoding no longer takes Opal down.** ffmpeg's stdout now has one
  close owner, eliminating the double-close that could panic the app or close
  an unrelated client socket during "Play here".

## v0.6.4 — 2026-08-06

- **Torrents play a second time.** The metadata cache rebuilt the info dict on
  write, which changed the info-hash, so every replay of an already-cached
  torrent stalled at 0%. It now stores the original bencoded info dict
  byte-for-byte.
- **An unlimited download rate means unlimited.** The setting wrote `-1` to
  libtorrent, which reaches the bandwidth manager as a negative quota; and the
  rate field mixed KB/s with bytes/s, so a `4096` typed in Settings became
  4 KB/s. Both fixed, with the conversion behind a tested pure function.
- **"Play here" in the browser transcodes instead of refusing.** MKV, AVI, TS
  and H.265-in-MP4 releases now stream through ffmpeg as fragmented MP4.
  Only what nothing can play (a disc image) is still turned away.
- **The Watching page got its Play and Remove buttons back.** They had been
  drawn past the bottom edge of their own card and clipped away — a card that
  carries both a progress bar and an action row is now sized for both.
- **Remove watched items one at a time**, from Watching and from the Home
  "Jump back in" row.
- **Double-tap `F` for real fullscreen.** It used to expand the player inside
  the window only; nothing had ever called `SDL_SetWindowFullscreen`.
- **The releases calendar backfills yesterday** by paging the EZTV API, and
  buckets into three days instead of one.
- **Windows**: the headless build compiles again.

## v0.6.3 — 2026-07-29

- Re-cut of v0.6.2 so Windows users get a build: v0.6.2's own ISA gate rejected
  the Windows exe over a single isolated instruction, which turned out to be a
  PE misdecode rather than real AVX-512 contamination. Same code otherwise.

## v0.6.2 — 2026-07-28

- **Storage page**: see what Opal actually stores and reclaim it.
- Fixed the two bugs reported against the shipped release (#21, #22).
- **Windows and Linux portability**: `/tmp` writes were silently dead on
  Windows, and every sidecar (Suwayomi included) now starts on both. Added a
  Windows CI smoke run so this stops regressing.
- Upcoming sorts by popularity rather than release date.
- Danger buttons no longer float over the Storage rows.

## v0.6.1 — 2026-07-26

- **Windows: fixed the four bugs behind "crashes on almost anything" (#21).**
- **Every HTTPS fetch works again** — the HTTP client never loaded a CA bundle,
  so seeding the clock alone left TLS broken.
- The arm64 Docker image builds and runs; IPTV reconnect was half-disabled.

## v0.6.0 — 2026-07-22

- **Movies and TV work out of the box** — default TMDB/OMDb keys ship with the
  release, no sign-up before the first search.
- **Accounts for the headless/web build**: register and sign in from the web UI,
  with a session-aware bearer gate replacing the old pairing screen.
- **Web UI parity, tier 2**: Comics, Novels, Drama, VNDB, Audiobookshelf, OPDS,
  Plex, Music, Radio, Live TV, YouTube, the AI copilot, and the Logs tab.
- **Headless deployment**: Caddy TLS and Tailscale access profiles.
- The browser extension is now **Opal Connect**, with cross-browser builds.

## v0.5.0 — 2026-07-21

- **Live TV** (iptv-org) as a first-class source in the Video group.
- **DPI-bypass proxy sidecar** with a Settings toggle — reaches sources that a
  filtering ISP blocks; enabled on Windows too.
- Browse's 15 sources fold into collapsible groups.
- YouTube search and channel paging.

## v0.4.1 — 2026-07-18

- **Windows**: DPI scaling, the console window, plugins, and the custom title
  bar all fixed; the formula builds from source there.
- Plex: a restored session loads its library again.
- Loading a `.torrent` file no longer dead-ends in the web browser.

## v0.4.0 — 2026-07-17

- **Comics, manga and novels at scale**: Madara (~332 sites), MangaThemesia
  (~143), plus lightnovelwp/readwn engines (~120) — one framework per site
  family rather than one scraper per site.
- **Anime video extractors** (MegaCloud/HiAnime, StreamWish, Dood, Mp4Upload …)
  hand off straight to mpv.
- **Anti-block fetching**: source scrapers route through an anti-detect browser
  when they hit Cloudflare or a captcha.
- **Encrypted persistent content cache** with stale-while-revalidate — cold
  start shows content immediately, then refreshes.
- **Opal Connect**, a cross-browser extension: play/read/download/scrape into
  the local app, and add the site you are on as a source.
- Infinite scroll across drama/vndb/novels/jellyfin/plex/opds/audiobookshelf/radio.

## v0.3.0 — 2026-07-14

- **Watching library** — what you are part-way through, in one place.
- **Full-duplex voice mode** with live partial transcripts.
- Winamp-style audio visualizers, including mirrored gradient bars.
- Torrent streaming starts in seconds instead of hanging.
- The three download tabs merged into one list.
- Paged onboarding tour, replayable from Settings.
- The installer no longer needs Xcode.

## v0.2.0 — 2026-07-11

- **Podcasts** as a new media class — search, browse, stream, with cover art
  and now-playing metadata.
- **Internet radio** via RadioBrowser, also a new media class.
- **More sources**: Stremio addon pack, Knaben aggregator, NASA, Wikimedia
  Commons, Internet Archive audio.
- **OMDb ratings** (IMDb / Rotten Tomatoes / Metacritic) on the detail view.
- Keyless subtitle providers extended (Subdl, Stremio OpenSubtitles-v3).
- Broad performance pass: virtualized grids, poster failure latches, cheaper
  per-frame polling.
- Persisted Settings toggles now actually take effect.

## v0.1.2 — 2026-07-05

- Packaging and installer fixes on top of v0.1.1.

## v0.1.1 — 2026-07-04

- **Keyless subtitles**, end to end: several public engines, no API key, with a
  browsable UI and auto-download when a video has none.
- Fixed the launch crash on opening a file (SQLite is now opened serialized).
- **Windows**: resolved the issue #3 launch failure (MINGW64 CRT + DLL harvest).
- macOS: the bundle is user-writable, so the Gatekeeper workaround no longer
  needs `sudo`.

## v0.1.0 — 2026-07-03

First public release. A pure-Zig desktop media browser and AI copilot: chat-first
home, search across many sources, TMDB-backed Movies & TV, an mpv-based player
with resume, a voice-driven agentic console, and a one-command installer with
checksums. Experimental Windows build (exe/zip/msi) alongside macOS and Linux.
