# Opal Anywhere — web companion spec

Goal: the phone-on-the-couch companion for a desktop Opal. Browse, queue,
and control playback from any device on the LAN — one Settings toggle, one
6-digit pairing code, zero manual servers.

## Phase 1 — foundation (SHIPPED)

**Serving.** `remote.zig` serves the single-file web app at `/` from
`Resources/web/index.html` (bundled by `scripts/build-app.sh`), falling back
to `web/index.html` in dev. No separate `cd web && zig build dev` needed.

**Reachability.** When Web Remote is enabled (Settings › Scripts — OFF by
default, persisted as `web_remote`), the server binds `0.0.0.0:41595` so
phones can reach it. Off = nothing listens (the neutral-ship posture).

**Pairing.** Bearer token is never injected into the page (the old
loopback-only injection is removed — with a LAN bind it would be a takeover
vector). Instead:

- A 6-digit pairing code is generated (crypto RNG) each time the server
  starts, shown in Settings next to the toggle with the LAN URL.
- The page's first-run screen asks for the code → `GET /pair?code=NNNNNN`
  (unauthenticated) → `{"token":"<32-hex>"}` → stored in `localStorage`.
- Brute-force guard: 300ms delay per failed attempt; 10 failures rotates
  the code.
- All `/api/*` routes stay behind `Authorization: Bearer`.

**Client (web/index.html, self-contained).** Mobile-first, theme tokens
ported to CSS variables (midnight palette). Three tabs:
- **Now Playing** — 1s polling of `/api/status`; seek bar (`/seek_pct`),
  play/pause (`/toggle`), ±10s (`/back`, `/fwd`), volume (`/vol`), mute.
- **Search** — `/api/search?q=` (universal), results with size/seeds/source,
  tap → `/api/load?url=` (plays on the desktop).
- **Activity** — `/api/downloads` (torrent progress) + `/api/queue`.

## Phase 2 — push + richer surfaces (NEXT)

- `GET /events` — SSE stream (status ticks, download progress, toast
  mirror) replacing polling; falls back to polling when absent.
- `/api/calendar` — expose tv_calendar entries (Coming-up on the phone).
- `/api/continue` — TV continue-watching rail with poster proxy
  (`/api/poster?path=` streaming the cached poster blobs; never hotlink
  TMDB from the phone).
- Audio/subtitle track pickers (`/next_sub`, `/next_audio` exist; add
  listing endpoints).
- PWA: `/manifest.json` + service worker → installable, home-screen icon.
- QR pairing: render the pair URL + code as a QR in Settings (needs a small
  pure-Zig QR encoder; the 6-digit flow stays as fallback).

## Phase 3 — native app polish track (parallel)

1. Consistency sweep: all paddings/radii through theme tokens; one
   segment/empty-state idiom everywhere.
2. Cmd+K command palette reusing omnibox intent classification.
3. Poster-grid keyboard navigation; `?` shortcut cheatsheet.
4. Seek-hover thumbnail previews.
5. Continue-watching progress bars on posters; skeleton shimmer.
6. ReleaseFast allocator switch; startup profiling.

## Security posture

- OFF by default; explicit opt-in, persisted.
- LAN bind only while enabled; disable tears the listener down.
- Token in `~/.config/opal/api.token` (0600), never served, never logged.
- Pairing code rotates on every server start and after 10 failed attempts.
- `/health` and `/` + `/pair` are the only unauthenticated routes.
