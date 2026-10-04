# Opal web client architecture

The browser is a first-class Opal client. Product scope, parity levels, and the
remaining operation ledger live in [`WEB-UI-PARITY.md`](WEB-UI-PARITY.md); this
document records the runtime shape and security boundaries.

## Runtime

`remote.zig` owns the listener, authentication, and top-level dispatch.
Feature-owned modules handle static assets, Now Playing status, library state,
and transfers. Installed builds read `web/` from Opal's resource root; source
checkouts fall back to the repository files. There is no separate web build or
package manager.

The browser is also split by ownership: semantic markup in `index.html`, shared
styles in `styles/app.css`, and bounded classic-script feature bundles in
`js/`. `boot.js` is the only startup entry point, after every feature bundle is
loaded. This keeps the no-toolchain deployment while avoiding an inline
application monolith.

The shell is responsive and route-aware:

- four stable phone destinations plus a grouped More sheet;
- a persistent grouped sidebar on wide screens;
- hash routes with browser back/forward;
- keyboard shortcuts, spatial arrow-key focus, and overlay Back/Escape;
- hosted browser playback or companion control of the native player.

The web app manifest and service worker make the shell installable when served
from a secure context. The service worker caches only public UI assets. It
never caches `/api/*`, credentials, event streams, Now Playing artwork,
posters, subtitles, or media.
Offline mode therefore preserves navigation and reconnect guidance without
showing stale account data.

## Authentication and transport

The static shell, manifest, icon, service worker, and `/health` are public so a
new browser can bootstrap. User data and mutations require an authenticated
account session in `Authorization: Bearer …`.

First-admin registration additionally requires the one-time owner-only setup
capability created on the Opal host. Credentials are sent in POST bodies, never
query strings. Session and setup tokens are not injected into HTML, serialized
by status APIs, or logged.

Now Playing exposes only a non-secret artwork revision key. The browser loads
the current image through an authenticated same-origin route; the source URL
stays server-side because Plex and Jellyfin artwork URLs may carry credentials.
The proxy uses bounded native HTTP so those URLs do not appear in process
arguments.

Plain LAN HTTP is suitable only on a trusted network. Installability and secure
remote access require HTTPS, typically through the deployment/Tailscale setup.

## Command boundary

Browser mutations are authenticated POST requests into typed domain commands:

- player snapshot/action;
- queue snapshot/action;
- direct-download and torrent actions;
- library status and episode watched state.

The server owns validation, bounds, stale-item checks, and destructive
confirmation. The browser never submits raw mpv commands, SQL, filesystem
paths outside a bounded download root, or source implementation details.

## Reliability contract

API work is serialized at the server boundary to preserve shared-state
invariants. Long media streams and static assets bypass that lock. Pollers are
bounded and stopped when their page is hidden; playback status prefers SSE and
falls back to polling. The UI exposes loading, empty, error, offline, and
reconnecting states rather than treating a rendered page as proof of parity.

## Keyless verification (2026-10-05)

The web client was run for real with no TMDB key: a fresh profile (no `.env`, no
`TMDB_API_TOKEN`), the first admin registered with the setup token, then a
headless Chromium driven over the DevTools protocol (session cookie injected,
pages opened by hash route, DOM text read and screenshots taken, console errors
and HTTP >= 400 responses collected).

Checked and working without a key: Browse (Movies & TV, TV only, search, filters),
movie details (favorite and rating controls), show details with seasons and
episodes, mark an episode watched, Watching (rows, status, reopening a row's
details), Home (Continue, Coming up), the Playing page's calendar, Asian Drama
(on-air grid, title search, details, episode list), and Setup (the TMDB field is
labelled optional).

Mismatches found and fixed:

| Finding | Cause | Fix |
| --- | --- | --- |
| "Movies & TV" showed movies only | The keyless merge appended all series after all movies and the web grid shows the first 30 rows | The two catalogs are interleaved (`cinemeta_meta_pure.interleave`) |
| Posters of search results were missing (404 from `/poster`) | Cinemeta search returns IMDb artwork on `m.media-amazon.com`, which the poster proxy rejected | The proxy allows exactly that host's `/images/` tree (https, no query), same SSRF rules, tested |
| A show could not be added to Watching from the web | The show page had no Track action; only the desktop did | Show pages offer "Track show" (hidden once tracked); `/api/library/watched` now reports `tracked` for TV |
| A keyless show opened from Watching after a key was added would query TMDB with a hash id | The detail routes chose TMDB whenever a key existed | `/api/tv` and `/api/movie` (and the desktop detail view) answer from Cinemeta when the id is the catalog hash of a known IMDb id |

Not a defect: `needs_tmdb_key` is still present in `/api/drama` for older
clients and is always `false`.

Limits: tracking from a show page needs the show to be in the current Browse
results (the server reads title and artwork from there); from elsewhere the
server answers "library changed; refresh and retry". Stream addons and EZTV were
not exercised live (none installed in the test profile); their keyless IMDb
lookup is covered by unit tests of the title and episode-token parsing.
