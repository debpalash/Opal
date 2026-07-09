# Opal headless hosting — execution spec

Goal: a Docker-hosted Opal with ONLY the web UI (qbittorrent-nox model):
one port, one binary, browser-first. Web UI reaches feature parity with the
desktop wherever parity makes sense for a server (see "the playback pivot").

Builds on docs/web-companion.md (pairing, LAN bind, bundled page) and the
existing headless scaffolding (src/headless.zig, Dockerfile, compose,
docs/headless-deploy.md).

## The playback pivot (core architectural decision)

On the desktop, "play" means mpv renders in the app. In a hosted container
there is no display — mpv playback parity is meaningless. Hosted "play" must
mean: **stream the file to the browser** (`<video>` + HTTP Range). Torrents
already download server-side; the web UI becomes the player. Everything else
(search, sources, queue, calendar, watched-tracking) IS meaningful parity and
mostly has API routes already.

## Phase H0 — headless serves the web UI (DONE 2026-07-10)

- headless entry force-enables Web Remote (desktop default is OFF; a
  headless box has no Settings toggle) and prints the web URL + pairing
  code + token path to stdout for `docker logs`.
- Single port: the web UI is served at `:41595/` by remote.zig — the old
  separate `:3000` dev server is no longer part of the hosted story.
- Verified live: banner → GET / 200 → /health ok → /pair with the printed
  code returns the token.

## Phase H1 — Docker image actually ships (IMPLEMENTED 2026-07-10 — awaiting first CI run)

The Dockerfile exists but has never been gated on a Linux host.

1. Build with `-Dheadless=true` (compile-time entry; today's Dockerfile does
   a normal build and relies on runtime detect).
2. Trim: drop `:3000` from Dockerfile/compose/docs; bundle
   `web/index.html`, `plugins-manifest.json`, `engines/` into the image;
   confirm python3 present for nova2.
3. Runtime hardening: non-root user, `HEALTHCHECK curl -f /health`,
   `OPAL_PAIR_CODE` env override (fixed code for reverse-proxy setups),
   volumes per headless-deploy.md.
4. Gate: GitHub Actions job (ubuntu) that `docker build`s and smoke-tests
   `/health` + `/pair` inside the container. This is the ONLY reliable
   verification path — macOS cannot validate the image.
5. Slim-build stretch: `-Dheadless` currently still links SDL/dvui/OCR.
   A no-SDL link needs build.zig surgery; do it only after the image gates
   green (image size, not correctness).

## Phase H2 — browser playback (SHIPPED 2026-07-10 — live-smoked: 206 Range, VTT, auth, traversal)

1. `GET /api/stream?file=<rel>` — HTTP Range streaming from the downloads
   dir (`206 Partial Content`, `Accept-Ranges`, content-type by extension;
   path-traversal guarded like apiDownloads). Serves while the torrent is
   still downloading (sequential pieces already prioritized for streaming).
2. Web UI: tapping a downloads/search item in hosted mode opens an inline
   `<video>` player (Activity tab → Player sheet) instead of `/load`.
   Detection: `/api/settings` gains `"headless":true`.
3. Subtitle sidecars: serve `.srt/.vtt` next to the file as `<track>`
   (SRT→VTT conversion is ~40 pure lines, tested).
4. Transcode is OUT of scope (no ffmpeg live transcode in v1) — direct-play
   only; note incompatible codecs in the UI.

## Phase H3 — web feature parity, tier 1 (SHIPPED 2026-07-10)

Done: Browse (poster proxy), TV drill-down (/api/tv passthrough + smart-play
prefill), Coming-up (/api/calendar), live torrents (/api/torrents), history
rerun, and browser-first setup (/api/setup{,/sources,/tmdb} + Setup tab) so a
fresh container is self-service. Queue reorder is the one deferred item.

### Original plan

| Surface        | Server work                                   | Web work |
|----------------|-----------------------------------------------|----------|
| TMDB browse    | `/api/tmdb` exists; add `/api/poster?path=`   | Browse tab w/ poster grid |
|                | proxy from the poster disk cache              | |
| TV drill-down  | new `/api/tv?id=` → seasons/episodes JSON     | show page + episode list |
|                | (server-side fetch via tmdb_api + tmdb_pure — | + smart-play button |
|                | no UI-thread state)                           | |
| Coming up      | `/api/calendar` from tv_calendar entries      | rail on Now Playing tab |
| Queue mgmt     | add/remove/reorder routes (queue.zig)         | swipe actions |
| Torrents       | active-torrent list route (progress/seeds)    | live progress cards |
| History        | `/api/history` exists                         | already listed; add tap-to-replay |

## Phase H4 — parity tier 2 + hosting hardening

- Settings subset over API: sources install (starter pack), TMDB key,
  rate limit, save path. Enables full first-run from the browser.
- Jellyfin / anime / comics / RSS tabs (routes exist).
- SSE `/events` (shared with the LAN companion — replaces polling).
- Reverse-proxy guidance (TLS, auth in front), per-device tokens,
  request rate limiting.

## Testing discipline

- Every new route: pure parse/format logic in a `*_pure.zig` with tests;
  route wiring checks in tests/test_features.py.
- H1 gate lives in CI (Linux); H2 stream route gets a curl Range smoke in
  the feature suite (runs against a spawned headless binary on macOS too).

## Execution order

H1 (image gates green) → H2 (browser playback) → H3 (parity tier 1) → H4.
H1 and H2 are independent enough to interleave; H2 is testable on macOS
without Docker via the headless binary.
