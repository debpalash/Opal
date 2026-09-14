# Next-level media product research

Research date: 2026-09-06. This is a first-pass product/integration audit, not a
certification that providers, devices, or all existing workflows work. External
claims below use primary project documentation. Local findings are based on the
named source files; recommendations and acceptance criteria are proposed work.

## Direction and boundaries

Opal can offer one coherent discovery, playback, reading, transfer, and library
experience without reimplementing every mature engine. The product advantage
should be trustworthy handoffs between those functions, with fast feedback,
recoverable failures, and the same account/library state in native and web
clients. More navigation destinations alone are not progress.

Two different ambitions need separate acceptance gates:

- **Excellent client:** connect to existing Jellyfin/Plex/Suwayomi services,
  respect their user permissions, negotiate playback, and synchronize progress.
- **Independent server:** own library scanning, metadata repair, users and access
  policy, streaming/transcoding capacity, storage quotas, backups, migrations,
  monitoring, and remote recovery. A server connector is not server replacement.

Opal already has an actual headless entry (`src/headless.zig`) and hosted stream
routes (`src/services/remote_stream.zig`). The old “scoping only” statement in
`docs/headless-scoping.md` is therefore stale. The existing
[`WEB-UI-PARITY.md`](WEB-UI-PARITY.md) is the more useful delivery contract: it
explicitly distinguishes page presence from an operable, persistent, secure,
end-to-end-tested workflow. Preserve that distinction in release claims.

## Benchmark capabilities and observed Opal boundaries

| Area | Primary-source benchmark | Local evidence and opportunity |
|---|---|---|
| Jellyfin / Plex | Playback must consider container, codec, subtitle and client compatibility; direct play and conversion have different costs. [Jellyfin playback](https://jellyfin.org/docs/general/post-install/transcoding/), [Plex direct play / direct stream](https://support.plex.tv/articles/200250387-streaming-media-direct-play-and-direct-stream/) | `jellyfin.zig::playItem` constructs a static stream URL; `plex.zig::play` uses a media part. These functions do not themselves negotiate server playback capabilities. Complete connection → details → tracks/quality → resume/progress → recovery contracts before claiming full client parity. |
| qBittorrent | Its documented scope includes per-file selection, queueing, peer/tracker management, RSS download filters, bandwidth scheduling, and a near-identical web interface. [Official feature list](https://www.qbittorrent.org/) | `src/torrent_wrapper.h` exposes pause/resume, file priority, download limiting, streaming ranges and reannounce. The inspected interface has no upload-limit setter, ratio policy, schedule, or explicit recheck operation. Audit wider transfer policy before adding controls; don't equate streaming a magnet with transfer-manager parity. |
| Stremio | The protocol separates `catalog`, `meta`, `stream`, and `subtitles`, with manifest resource/type/ID filtering and search/pagination extras. [Protocol](https://stremio.github.io/stremio-addon-sdk/protocol.html), [manifest contract](https://github.com/Stremio/stremio-addon-sdk/blob/master/docs/api/responses/manifest.md) | `src/services/stremio.zig` has catalog/install state and stream queries. Test manifest capability filtering, typed episode IDs, pagination, malformed responses, provider timeouts and isolation. A provider outage should degrade one source, not all search. |
| mpv / IINA | mpv exposes rich track, chapter, subtitle, seek and playback controls; IINA emphasizes platform-native Picture-in-Picture, system media controls, gestures and thumbnail preview. [mpv manual](https://mpv.io/manual/stable/), [IINA](https://iina.io/) | Opal uses libmpv and has typed web-player operations. Measure command acknowledgment, first frame, seek recovery and shutdown separately. Test the platform integrations on real OS runners rather than treating Linux rendering as proof of macOS/Windows polish. |
| yt-dlp | The project supports structured JSON output, format selection and progress templates, and publishes release checksum/signature files. [Official repository and usage](https://github.com/yt-dlp/yt-dlp) | `ytdlp.zig` manages bundled/system binaries, but its download worker writes straight to the active path, lacks HTTP failure/checksum/staging validation, and invokes `chmod` on every platform. `extractors.zig` and queue thumbnail backfill implicitly request Firefox cookies; the latter disables certificate validation. This is a reliability/privacy priority, not just a feature gap. |
| IPTV | Jellyfin's documented live-TV workflow includes M3U/tuners, guide mapping through XMLTV or a guide provider, and recordings. [Live broadcast](https://jellyfin.org/docs/general/server/live-tv/) | Opal has source ingestion, custom URLs, health, recents and favorites in `iptv*.zig`. No EPG/XMLTV, catch-up or time-shift implementation was found in a `src/`, `web/`, `tests/` text search. A large channel catalog is not a programme guide or DVR. |
| Comics / books | Komga owns server libraries for CBZ/CBR, EPUB and PDF. Suwayomi exposes server capabilities including OPDS/OPDS-PSE and explicitly notes that frontend support varies. [Komga introduction](https://komga.org/docs/introduction/), [Suwayomi server](https://github.com/Suwayomi/Suwayomi-Server) | `comics.zig` has page/resume and Suwayomi paths, plus separate `opds.zig` and `suwayomi_server.zig`. Validate page order, RTL/LTR, image limits, resume synchronization, failed-page retry and offline ownership before expanding scraper count. Standards-based library integration reduces coupling to site HTML. |
| Private remote access | Tailscale Serve is tailnet-private; Funnel makes a service internet-accessible. `TS_SERVE_CONFIG` supports config files; current Docker docs require mounting the containing directory for config-change detection. [Serve/Funnel boundary](https://tailscale.com/docs/features/tailscale-funnel), [Docker parameters](https://tailscale.com/docs/features/containers/docker/docker-params) | Opal's sidecar has no published host ports and shares its network namespace. However `deploy/docker-compose.tailscale.yml` mounts only the config file and uses `tailscale/tailscale:latest`. Add reproducible pinning, health checks and a documented reload/restart test. Keep app authentication; tailnet membership is not automatically application administration. |

“Tailcat” remains unidentified. There is no matching integration found in the
repository, and the name alone is insufficient to select a project, protocol,
or account. Ask for the exact project URL before planning that integration. Do
not silently substitute Tailscale, Tailchat, or another similarly named product.

## Prioritized delivery opportunities

1. **P0 — Make extraction private and deterministic.** Stop implicit browser
   cookie access, preserve TLS verification, and use a single bounded yt-dlp
   invocation policy. Cookie access should be an explicit, revocable choice
   limited to the intended profile/source; do not read the user's cookies during
   tests. Decide whether user yt-dlp config is supported or ignored rather than
   accidentally inheriting execution hooks. Test argv with a fake executable,
   stderr saturation, timeout/cancel, and shutdown while extracting.

2. **P0 — Make helper installation recoverable.** Stage a download beside the
   executable; reject HTTP failures; validate the selected release and integrity;
   execute a bounded version probe; publish atomically only after success. Keep
   the working binary on interrupted/failed updates. Use platform-native file
   permissions, and test Windows without assuming `chmod`. Reading a checksum
   from the same compromised source is not equivalent to independently verifying
   a signature; state the trust model accurately.

3. **P0 — Gate user-visible reliability with measured budgets.** Add a repeatable
   workload for launch, navigation, search cancellation, art loading, stream
   startup, seek, reader page advance and close. Record p50/p95 latency, CPU,
   resident memory, workers and subprocesses. Proposed initial UI target: action
   acknowledgment under 100 ms, independently of provider/network time. Test
   hundreds of navigation/play/stop cycles and assert no orphan playback after
   close. Establish baselines before promising final numerical budgets.

4. **P1 — Finish one shared media/action identity model.** Native and web should
   agree on media kind, provider IDs, show/season/episode, available playback
   targets, resume, watched state, queue and download actions. “Play here”,
   “Play on Opal”, and “Queue” must be explicit where more than one target exists.
   Test cross-device refresh/reconnect and prevent a late result from changing
   the newly selected title. Follow the existing operation-level parity ledger.

5. **P1 — Complete owned-server client workflows.** Build fixture servers for
   Jellyfin and Plex covering expired credentials, empty and large libraries,
   nested shows/seasons, multiple media versions, unsupported codecs/subtitles,
   progress reporting and reconnect. Per-install random device identity is now
   shared across Jellyfin video/music and Plex, with the actual app version.
   Plex now sends secret headers in-process through pooled native HTTP. Both
   direct-play paths put tokens in URLs at the mpv boundary. Persisted progress,
   sessions, workspaces, browser/download history, local AI memory and visible
   loading titles now use credential-free identities; v3 scrubs older rows and
   adapter deep links reconstruct credentials at playback time. Keep fixture
   coverage for screenshots, API snapshots and every newly-added cache.

6. **P1 — Make transfer management durable and safe.** Introduce typed policy
   and operations for upload/download limits, scheduling, seeding goals,
   queueing and verification only after determining existing coverage. Persist
   intent through restart. Separate removing an entry from deleting its data,
   require confirmation for the latter, and keep paths confined to configured
   roots. Exercise disk-full, permission errors, private torrents, stale IDs,
   cancellation, swarm stalls and seek while downloading with legal fixtures.

7. **P1 — Ship verified private remote deployment.** Fix directory mounting,
   pin reviewed images, and validate startup, HTTPS proxying, reconnect, SSE,
   seeking/range requests, key expiry, restart and admin bootstrap. Use an
   isolated test tailnet only with user authorization. A public Funnel, subnet
   route, exit node, changed ACL, or auth-key creation is a separate explicit
   network/security action—not an implied consequence of “test Tailscale”.

8. **P2 — Turn live TV into a guide workflow.** Start with opt-in M3U/XMLTV
   import, channel mapping and now/next programme cards, then programme search
   and favorites. Cover time zones/DST, stale guide data, reconnect, dead-stream
   feedback and request headers. Treat DVR/catch-up as a subsequent storage and
   scheduling subsystem with quotas, retention and clear source permissions.

9. **P2 — Give reading the same quality bar as watching.** Use bounded decoded
   image memory and a small neighboring-page cache. Test long series, huge
   pages, missing/corrupt pages, RTL, spread/scroll modes, zoom and resume across
   native/web. Synchronize progress against server identity and book/chapter ID,
   not display title. Treat archive paths and embedded links as untrusted.

10. **P2 — Earn independent-server replacement claims.** Add an explicit matrix
    for library imports, metadata corrections, multiple users, permissions,
    backups/restores, migrations, transcode limits and concurrent streams.
    Benchmark on a small NAS-class machine as well as a workstation. Keep
    deterministic provider fixtures in normal CI and optional real-provider/OS
    acceptance suites separately labeled. A green source-string feature test is
    useful regression evidence, but not proof that the user workflow works.

## Cross-cutting safety and scope

- Treat provider manifests, metadata, subtitles, archives, playlist URLs and
  artwork as untrusted input: enforce body/dimension/decompression limits,
  validate schemes and redirects, and apply SSRF controls at the hosted fetch
  boundary without breaking deliberately configured private media servers.
- Never expose raw mpv commands, arbitrary shell options, provider secrets, or
  unrestricted host paths through web parity. Browser capabilities differ from
  desktop capabilities; equivalent safe workflows matter more than identical
  implementation.
- Keep remote metadata and provider access opt-in where appropriate. “No API
  key needed” is not “offline” or “no third-party requests”. Explain where queries
  and IP addresses go, and do not promise every external source will remain
  available or lawful for every user.
- Prefer fixture-owned public-domain/test media and private, temporary state.
  This audit did not connect accounts, import libraries, access cookies, join a
  tailnet, enable public sharing, install dependencies, or run live providers.

## Completion evidence

A capability is ready when its normal, empty, loading, offline, denied, stale
and recovery paths are usable on phone, tablet and desktop; state survives the
promised lifecycle; keyboard/touch/assistive access works; server validation and
real interaction tests pass; and measured resource use stays within its agreed
budget. No finite test run establishes a “perfect app”; report the exact tested
matrix and remaining limitations instead of using absolute quality claims.
