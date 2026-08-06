# Changelog

What changed in each release, in the terms a user would notice.

Every section here becomes the **Highlights** block of the matching GitHub
Release — `scripts/release-notes.sh` extracts it by version heading and appends
the full commit list underneath, so the notes can never drift from the tag.
Add a section BEFORE tagging; a missing one ships a release that says so.

Headings are `## vX.Y.Z — YYYY-MM-DD`, newest first. The version token must
match the tag exactly.

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
