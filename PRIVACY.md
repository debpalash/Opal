# Privacy Policy

**Opal — Play everything** (config dir: `opal`)

_Last updated: 2026-06-26_

Opal is a **local-first** desktop media runtime. It is built so that your data
stays on your machine. **There is no telemetry, no analytics, no crash
reporting, no advertising SDK, and no phone-home to the maintainers.** No usage
data, no identifiers, and no content of any kind is ever sent to the people who
make Opal. We do not operate a server that receives your data, because there
isn't one.

This document explains exactly what Opal stores, where it stores it, what
network requests it makes (and only when), and how to delete everything.

---

## TL;DR

- **No telemetry / analytics / tracking.** Audited; none is present.
- **Your data lives on your disk** under `~/.config/opal` and
  `~/.cache/opal` (plus your chosen downloads folder).
- **Network requests happen only for features you use** — TMDB, Jellyfin,
  YouTube, torrent trackers/indexers, scraper sites, and optional AI/voice
  backends. When you talk to those services, **their** privacy policies apply,
  not ours.
- **The remote API and web UI run locally** on your machine/LAN, not on any
  cloud we control.
- **Nothing is sent to the Opal maintainers, ever.**

---

## What Opal stores, and where

All persistent data lives under your XDG config and cache directories. Opal
never writes to hidden cloud locations.

### Configuration — `~/.config/opal/`

| File / item | Contents |
| --- | --- |
| `config.tsv` | Your app settings and preferences |
| TMDB v4 bearer token | Stored locally; required only if you use TMDB browse/search |
| OpenSubtitles / Jellyfin / Trakt / AniList / SIMKL keys | Stored locally; only if you configure those integrations |
| `api.token` (mode `0600`) | Bearer token for the local remote JSON API |
| `plugins/<name>/` | Any third-party content-source plugins you install |

### Local database — `~/.config/opal/opal.db` (SQLite)

A single local SQLite database holds:

- `watch_history`, `watch_sessions`, anime/TV "watched" and "continue" state
- `search_history`, `download_history`
- `tmdb_items` / `tmdb_lists`, `poster_cache` (browse caches)
- `aimemory` + `vec_aimemory` — local AI assistant memory, including
  768-dimension embeddings stored via **sqlite-vec**
- `conversation_log` — your local AI chat history
- `user_preferences` — taste vectors / recommendation signals

This database is **local-only**. It is never uploaded.

### Cache — `~/.cache/opal/`

Transient data: poster images, thumbnails, and other regenerable caches. Safe
to delete at any time.

### Downloads — `~/Downloads/opal` (default, configurable)

Media you download or stream via torrents/other sources is written here.

---

## Network requests Opal makes

Opal is offline-friendly. With one minor exception noted below, network
requests are **user-initiated** — they happen only because you used a feature
that needs them. When Opal contacts a third-party service, that request goes
**directly from your machine to that service**; Opal does not proxy it through
us, and the service's own privacy policy governs that interaction.

### Requests that fire automatically on launch

Two outbound requests can occur at startup without an explicit per-use action.
They are flagged in the source as candidates for opt-in:

1. **Update check** — a request to GitHub Releases to see if a newer Opal
   version exists.
2. **yt-dlp download** — a one-time download of the `yt-dlp` binary from GitHub
   if it is missing (used for YouTube playback).

Neither sends any personal data about you to the maintainers; both contact
GitHub, whose privacy policy applies.

### Requests that happen only when you use the relevant feature

- **TMDB** (`api.themoviedb.org`, `image.tmdb.org`) — movie/TV metadata and
  posters; requires your own TMDB token.
- **Jellyfin** — your own configured Jellyfin server.
- **YouTube** — Piped instances and/or `yt-dlp`/Google for search and playback.
  Note: YouTube extraction may use browser cookies for authenticated requests;
  this sends those cookies to the host yt-dlp contacts.
- **OpenSubtitles** — subtitle search/download.
- **Torrent indexers / scraper sites** — the bundled search engines and content
  scrapers contact their respective sites only when you search/resolve.
- **BitTorrent (libtorrent)** — when you stream/download a torrent, your client
  joins the DHT and connects to trackers and peers. **This exposes your IP
  address to the swarm**, as with any BitTorrent client. Consider a VPN if this
  matters to you.
- **Stremio add-ons / RSS feeds** — only the add-ons/feeds you configure.
- **AI assistant tools** — e.g. the `read_webpage` tool fetches a URL you ask
  about (via the Jina reader); the local LLM/embedding/voice servers run on
  `127.0.0.1`. Optional ML model downloads (whisper / sherpa / Gemma GGUF /
  Kokoro, etc.) are pulled on demand from HuggingFace/GitHub only when you
  enable them in Settings.

You are in control: if you do not use a feature, its network calls do not
happen.

---

## Local servers (run on your machine)

Some features expose **local** network services. These run on your own
hardware — they are not hosted by the maintainers — but you should be aware of
their network exposure:

| Service | Bind address | Notes |
| --- | --- | --- |
| Remote JSON API | `0.0.0.0:41595` | Bearer-token auth; reachable on your LAN |
| Web UI | `:3000` | Companion local web interface |
| Watch-party (when hosting) | `0.0.0.0:41596` | No auth; LAN co-watch |
| AI llama-server | `127.0.0.1:41592` | Loopback only |
| Embedding server | `:41593` | Local |
| Language server | `:41594` | Local |
| Voice backend | `:8000` | Local |
| Stream proxy | loopback | Per-stream random token |

Services bound to `0.0.0.0` are reachable by other devices on your local
network. If that is a concern, restrict them via your firewall and avoid
hosting on untrusted networks.

---

## What we do NOT do

- We do **not** collect telemetry, analytics, or usage metrics.
- We do **not** include crash/error reporting that sends data off-device.
- We do **not** embed advertising or third-party tracking SDKs.
- We do **not** operate any account system or backend that receives your data.
- We do **not** sell, share, or transmit your data to anyone — there is no
  mechanism in Opal to do so.

---

## How to delete your data

Because everything is local, deleting your data is straightforward.

- **Clear caches** (safe, regenerable):

  ```sh
  rm -rf ~/.cache/opal
  ```

- **Delete history, AI memory, and the local database:**

  ```sh
  rm -f ~/.config/opal/opal.db
  ```

- **Remove all configuration, tokens, keys, and plugins:**

  ```sh
  rm -rf ~/.config/opal
  ```

- **Remove everything Opal stored, including downloads:**

  ```sh
  rm -rf ~/.config/opal ~/.cache/opal ~/Downloads/opal
  ```

  (Adjust the downloads path if you configured a custom location.)

After deletion, Opal will start fresh on next launch as if newly installed.

You may also delete individual tokens/keys by removing the corresponding files
in `~/.config/opal/`, or clear specific tables in `opal.db` with any SQLite
tool if you want fine-grained control.

---

## Third-party services and plugins

When you use Opal to reach a third-party service (TMDB, Jellyfin, YouTube,
torrent sites, AI/voice endpoints, Stremio add-ons, etc.), your data is handled
according to **that service's** privacy policy. Opal cannot control what those
services log or retain.

Installed plugins are executables that run on your machine and may make their
own network requests. Review any plugin you install — native binaries run
without sandboxing, and a Lua plugin can request unsandboxed execution via
`allow_unsafe`. Only install plugins you trust.

---

## Changes to this policy

This policy may be updated as Opal evolves. The authoritative version lives in
the project repository: <https://github.com/debpalash/Opal>.

## Contact

Privacy questions or concerns: open an issue at
<https://github.com/debpalash/Opal/issues>.
