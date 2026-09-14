# Opal quality programme

Started 2026-09-06. Active objective: a coherent, dependable all-in-one media
client and server, with practical desktop/web workflow parity. This is a
delivery ledger, not a claim that every capability below is implemented.

## Working contract

- Ship thin, tested end-to-end improvements; do not replace working engines or
  redesign every screen simultaneously.
- Reuse shared commands, identities and immutable snapshots across native/web.
- Separate source-presence checks, unit tests, integration tests, actual visual
  inspection, real-device checks and performance measurements in reports.
- Tests use isolated state and legal fixtures. Never modify a running user's
  library, consume browser cookies, connect accounts or expose network services
  as an incidental test step.
- New paid services, public sharing, tailnet/ACL changes and destructive storage
  operations require explicit user decisions. “Tailcat” needs an exact URL.
- Preserve established Opal theme tokens, readable content-first layouts and
  reduced-motion behavior. Do not turn the app into a feature-marketing page.

## Acceptance targets and current Windows baseline

| Dimension | Initial gate |
| --- | --- |
| Interaction | p95 visible acknowledgment within 100 ms; provider time measured separately |
| Rendering | Target 16.7 ms frame budget on documented reference hardware; benchmark large lists |
| Web launch | Useful shell within 1.5 s on controlled LAN; test cold and warm cache |
| Close | No orphan audio/processes; target p95 under 2 s, enforce documented bounded fallback |
| Resources | Record idle CPU/RSS, peak decoded art, workers, FDs and subprocesses; no unbounded growth over 100 lifecycle cycles |
| Responsive UI | 320/375/768/1024/1440 widths, short landscape, text enlargement and keyboard access |
| Failures | Loading, empty, offline, denied, stale response, timeout, retry, cancellation and restart |
| Parity | An operation reaches level 4 only with complete behavior/security/persistence and browser evidence; see WEB-UI-PARITY.md |

Measured 2026-09-13 on the current Windows development machine, installed
ReleaseFast build: visible/responsive startup p95 171 ms, close p95 771 ms,
local MP4 first-frame p95 121 ms, and the reference YouTube URL median 3.02 s
(p95 3.19 s).
Provider/network time remains reported separately from local application time.

The Windows baseline is now established; a lower-powered target is still needed
before budgets are tightened. External provider availability and hardware
decoding capability cannot be guaranteed by a passing unit test.

## Whole-product audit map

Every row remains an open audit until its operations have evidence. A working
route is not a completed row.

| Area | Required workflows / stress cases |
| --- | --- |
| Home / Watching | Cross-media continue, exact identity, art fallback, progress, watched/status, large libraries |
| Search / Browse | Cancel and replace query, provider isolation, dedup, filters, pagination, explicit playback target |
| Player | Direct play/transcode, audio/subtitle/chapter selection, seek/speed, fallback, PiP/cast, fatal error/retry |
| TV / anime | Details → season → episode, specials, large shows, resume/next, metadata failures and mixed source IDs |
| Downloads / torrents | Pause/resume/cancel, limits, file priorities, disk full, restart, recheck/seeding policy, safe deletion |
| Queue / History | Reorder/remove/repeat/shuffle, exact resume, private URLs, persistence and cross-device state |
| Jellyfin / Plex | Connect, identity, auth expiry, browse/search, version/track negotiation, progress/favorites, recovery |
| IPTV / radio | Source import, headers, live health, reconnect, favorites; guide/XMLTV and recording are separate missing workflows |
| YouTube / yt-dlp | Hermetic extraction, opt-in authentication, formats, background art, safe helper installation, cancellation |
| Music / podcasts / audiobooks | Albums/chapters, queue, progress, downloads, lyrics, source connections and recoverable errors |
| Comics / novels / OPDS | Page order/RTL/spreads, huge/corrupt pages, zoom, prefetch budget, chapter/book identity and resume |
| Assistant / voice | Optional dependency state, cancellation, model memory, permission prompts, input fallback, unavailable backends |
| Plugins / sources | Install/remove/update, trust/permissions, credentials, health and process lifecycle |
| Settings / logs | Discoverability, validation, secret redaction, accessible controls, diagnostic export and reset boundaries |
| Web / remote | Auth lifecycle, SSE/polling, stale requests, browser-local vs host playback, PWA/offline, device/session control |
| Headless / deployment | Startup/bootstrap, storage/backup/migrations, quotas, concurrent streams, TLS proxy/Tailscale and updates |

## Delivery sequence

1. **Safety and measurement foundation:** worker/network shutdown races,
   stale web responses, request lifecycles, extraction privacy, safe test
   harness, reproducible behavior checks and initial performance workload.
2. **One media workflow:** shared identities/actions, resume/queue/transfer
   handoffs, consistent loading/error/retry, full detail and playback paths.
3. **Owned integrations:** Jellyfin/Plex fixtures, safe helper updates,
   private deployment, source health and explicit credential consent.
4. **Transfer and reading depth:** durable transfer policy, bounded image
   memory, complete comic/book navigation and progress synchronization.
5. **Live TV and independent server depth:** guide ingestion, then recording
   policy; library ownership, users, backups and resource limits.
6. **Polish and sustained validation:** every route/device/permission state,
   accessibility, lower-powered hardware, long-running soak and platform CI.

## Current batch

| Work item | Status / evidence |
| --- | --- |
| Competitor/integration first-pass research | Complete; primary references and gaps in next-level-research.md |
| Legacy worker admission after shutdown drain | Fixed; deterministic barrier regression red before / green after |
| TV/movie/season stale responses and wrong-show watched actions | Implementation + deterministic web tests in review |
| SSE/fallback polling on reconnect/sign-out | Implementation + deterministic web tests in review |
| Test database safety and repeatable reports | Read-only DB, fixture/report overrides, fresh result runs; behavioral tests |
| HTTP watchdog/socket ownership | Owned watchdog, portable socket shutdown and cleanup boundary implemented; compile/lifecycle evidence |
| Implicit browser-cookie/TLS bypass in extraction | Fixed; isolated yt-dlp config, no implicit cookies, TLS stays enabled; pure policy tests |
| Baseline performance / full operation inventory | Windows startup/close/local/URL playback measured; broader resource and route baselines remain open |
| One-click player popover dismissal | Outside presses pass through to Back/Settings/Close/other pickers; full native test suite |
| Idle shutdown sidecar policy | Voice/search/comics process sweeps are demand-driven; installed close p95 reduced to 771 ms |
| Durable preference lifecycle | Early changes remain dirty until storage is ready; SQLite closes after its final consumer |
| Per-stream recovery policy | Complete; torrent piece waits recover after 15 seconds, proxy stop cancels within one 25 ms poll, incomplete bodies reconnect, and mpv retains a finite 20-second backstop |
| Actionable playback failure | Exhausted loads leave the spinner, show Retry/Close, and preserve the full URL, agent, headers and timeout policy |
| Resource regression gate | Idle peak 108.4 MB working set / 1,966 handles; clean close leaves no observed child process |
| Cold preference integrity | Settings remain read-only until async restore publishes readiness; query failure falls back to usable defaults |
| Route-bound player surfaces | Leaving Now Playing closes pickers/info/stats/playlist so hidden modals cannot consume a later first click |
| Windows TV integration gate | Test runner now inherits required MSYS2 runtime DLL path; headless production TV-detail tests pass |
| Aero Snap contract | Installed benchmark asserts caption/sizing styles plus native HTCAPTION hit-test; current run has zero failures |
| Recoverable yt-dlp updates | HTTPS-only staged download, official asset SHA-256, bounded process-tree probes and atomic publish preserve the working helper on every failure; Python discovery and version checks also have strict output/deadline limits |
| Stable server identity | One random SQLite-persisted install ID now identifies Jellyfin video/music and Plex requests; adapters report the actual app version |
| Recoverable Jellyfin auth | HTTP 401/403 is distinguished from transport failure, expired secrets are cleared, and disconnected sources remain reachable for sign-in |
| Fast recoverable Plex | Plex library traffic uses pooled native HTTP instead of one curl process per page; 401/403 clears expired secrets and returns to sign-in |
| Recoverable Audiobookshelf auth | Login errors distinguish rejection from outage; expired tokens and transient password buffers are cleared before returning to sign-in |
| Credential-safe media identity | Playback URLs are split from persisted identity; signed/userinfo URLs are scrubbed from history, sessions, downloads, browser records, AI memory and workspaces, with a v3 in-place migration and pure policy tests |
| Protected credentials at rest | Windows API keys, proxy/cache keys, account tokens and recognized installed-source credentials use current-user DPAPI envelopes; valid legacy plaintext is migrated and corrupt ciphertext never becomes a live credential |
| Authenticated source resume | Jellyfin, Plex and Audiobookshelf persist validated `opal://` adapter deep links, reconstruct live tokened URLs only at playback time, and apply provider-authoritative resume seconds once media is ready |
| Non-blocking server progress | Audiobookshelf progress plus Jellyfin/Plex start-pause-heartbeat-stop use one serialized, deduplicating worker with provider cadence/retry backoff; close grants a hidden 120 ms final-delivery window, then normal cancellation wins |
| Reduced-motion accessibility | Persistent setting collapses route, drawer, panel, toggle, prompt and notification animations to immediate transitions |
| Non-interfering playback telemetry | First-frame publication wakes the UI before reporting; timing-log persistence is coalesced on an owned worker, so antivirus/disk latency cannot delay the frame being measured |
| Self-hosted version recovery | Jellyfin targets the server-ordered media source and Plex skips unusable versions; both keep immediate direct play, carry tokens in request headers, and retry one alternate only before playback starts. Exhausted Jellyfin paths negotiate HLS through bounded `PlaybackInfo`; exhausted Plex versions use its universal HLS transcoder. Neither recovery URL retains the account token |
| Adaptive fast-start playback | Local files bypass forced demuxer caching, ordinary network media no longer waits on a fixed initial-cache gate, torrent proxy loads retain that safety gate, and embedded libmpv skips unused input/terminal/console initialization. Live HLS no longer starts ten segments behind the edge; after the first painted frame and the narrow config/script barrier, one renderer-free libmpv core is prepared off-thread while cache/history/source startup continues, removing unrelated I/O from the first Recents/Home click |
| Explicit optional-model lifecycle | Startup performs no model network transfers. Whisper, Sherpa STT, Piper, Kokoro and streaming ASR expose explicit Download actions with accurate sizes and live state. Downloads are HTTPS-only, staged, exit/size checked, SHA-256 pinned when upstream publishes a digest, validated for every runtime-required file, and atomically published with no Unix-shell dependency |
| Confined transfer disk actions | Play, reveal, verify, drill-down and destructive delete resolve only a validated single entry beneath the configured download root. Traversal, absolute/UNC/device/alternate-stream syntax and root-prefix collisions are rejected by unit-tested pure policy; removing a transfer remains separate from deleting bytes |
| One-click cold torrent handoff | Magnets and `.torrent` files opened during delayed DHT/session initialization are retained in a mutex-protected bounded FIFO, acknowledged immediately, and automatically flushed one per UI frame when the engine publishes ready. Ordinary rapid actions are not collapsed or discarded, overflow is explicit, and the user is never told to click again |
| Privacy-safe torrent restart | Accepted active torrents persist as canonical info-hash-only v1/v2/hybrid magnets plus their paused/running intent. Tracker URLs, passkeys, names, web seeds and peers never reach SQLite; restart rejoins swarms without opening a player or changing route, deduplicates through libtorrent, captures pre-DB adds, and explicit removal erases intent before invalidating the handle. A bounded, hash-validated, atomically replaced libtorrent fast-resume checkpoint records modified piece/file-priority state off the UI thread every 10 seconds and at clean close, avoiding needless full-file rechecks |
| Recoverable torrent errors | Transfer status includes libtorrent's real error state instead of treating every valid handle as healthy. Errored rows expose an in-place recheck/resume action through both native and remote transfer APIs without deleting existing bytes |
| Deterministic durable queue | Queue SQLite initialization and migration run off the first-frame/first-click path on a serialized connection, with cold-start and full-playlist additions retained in a bounded FIFO and batch-committed. Explicit positions make new items append; reorder and auto-advance resolve stable row identity; Queue/M3U share persisted repeat/shuffle policy and seed; desktop/web expose previous, next, repeat and shuffle; remote actions execute on the UI thread and return a bounded completion receipt; thumbnail jobs/results have isolated ownership; legacy order is preserved once; inputs/storage are bounded; and resources/DB close after worker drain |
| Typed playback ownership | Every replace load is explicitly owned by direct, playlist, queue or torrent playback. Direct media clears stale queue/playlist/torrent state, async resolution and recovery retain the staged owner, queue advance follows its stable row ID, and internal torrent proxy/file loads preserve torrent ownership instead of accidentally disabling its stream lifecycle |
| Actionable hardware fallback | Opal observes mpv's authoritative `hwdec-current` state and reports software fallback once per load only after a real video size exists; unavailable/early property states, audio, an explicit software preference, and active GPU decoding do not trigger a false warning |
| Portable quality inventory | Windows runs in UTF-8, source paths are normalized, POSIX-only execution probes are separated from static contracts, and an explicit missing `--database` path is populated from the shipped schema as a disposable fixture; current isolated report: 433 passed, 0 failed, 12 environment/optional-component skips, 0 warnings |
| Adaptive non-blocking omnibox | Shell and embedded/legacy entry boxes share one intent contract: links/files open, plain text searches the visible Browse source when supported and otherwise fans into universal search, `?` searches local memory, and `>`/questions invoke the assistant. Source-specific dispatch is service-owned instead of duplicated across UI modules; embedding/recall runs on a generation-safe owned worker and only the newest result enters the resolver from the UI thread |
| Bounded universal discovery | One ranked result model covers local files, Jellyfin, installed plugins, torrents, anime, YouTube, comics, live TV, music, radio and podcasts with cross-source deduplication, typed per-source failures and stale-while-revalidate cache seeding. Every fan-out task is retained by the bounded worker supervisor, so rapid superseding searches cannot leak detached native handles |
| Actionable web playback failure | The shared status/player snapshots expose a bounded escaped failure reason; desktop and web Retry use one typed action and preserve playback owner, credential-free identity, provider restore link, request headers and torrent loopback policy |
| Bounded untrusted image decode | One shared decoder probes headers before stb allocation and rejects invalid/overflowing dimensions. Covers are capped at 24 MiB, while browser frames and long comic pages use explicit 128 MiB class budgets; no production provider calls raw stb decode directly. A CAS reservation gate keeps the global eight-fetch memory/network ceiling exact across concurrent providers; shared and plugin fetch workers are retained by the process supervisor, and plugin image transport is bounded so oversized responses cannot wedge a pipe wait |
| Non-blocking first playback click | Recent/Home rendering performs no filesystem probes. A click arriving before configuration/script readiness or during libmpv prewarm is copied into a bounded owned request; both readiness transitions wake the frame loop and hand it off without blocking the UI thread or requiring another click. The shared Play seam starts trigger-to-frame timing before that handoff, so `timing.log` includes the complete visible wait |
| Non-blocking playback enrichment | Taste events are buffered behind a single-flusher latch whose idle publication is linearized with enqueue, preventing lost wakeups; vector ingestion and the per-play time preference use owned workers, so SQLite enrichment never delays `loadfile`; persistence sinks reject incognito activity |
| Fast deterministic media switching | The outgoing URL, position, and episode binding are copied before player state changes; the new request reaches mpv before SQLite/server resume bookkeeping. Resume writes use one owned worker and a fixed, same-media-coalescing queue behind a per-identity latest-sequence gate, so periodic saves neither block frame presentation, create thread buildup, nor reorder progress. `load-issued` is stamped at the real mpv/resolver handoff |
| Safe live-stream resolution | Streamlink helpers run in contained process trees with a 30-second deadline, strict output cap, supersession cancellation and shutdown cancellation. Workers publish fixed snapshots only; the UI thread validates a process-unique player/load identity before committing HLS output, so closing or replacing a player cannot become a stale-pointer write |
| Dense TV episode browsing | TV detail uses one compact title/status hierarchy and season toolbar, a centered reading-width canvas, two-column desktop episode catalogue, aligned title/actions and bounded synopsis previews. Upcoming and undated entries use small inert tiles with explicit Upcoming/TBA state instead of empty full-size artwork and misleading Play controls; narrow layouts retain full-width playable artwork. |
| Event-driven TV detail state | Status, cross-season Resume and aired-frontier state are projected in one database pass and shared by every control. A monotonic library revision invalidates the UI snapshot after real mutations or metadata sync, eliminating per-frame SQLite scans and allocations while keeping watched/status changes immediate. |
| Typed universal catalog discovery | Movie and TV metadata is restored to the shared resolver without stealing priority from playable results. Native and web clients carry provider identity into details, keyless Cinemeta supports both shows and movies, and the versioned cold cache preserves torrent size/leech safety metadata alongside catalog identity. |
| Installed-plugin universal discovery | Trusted installed content plugins join the shared resolver without adding filter clutter. Search execution is capped, deadline-bounded, strictly parsed, fully joined, content-trust checked, and playback routes through stable plugin/item identity rather than mutable tab state. |
| Executable-plugin permission review | The web client inventories installed executable plugins, exposes capabilities and execution mode, and requires explicit review before native or unsafe execution. Approval is stored outside plugin bundles and bound to plugin ID plus a canonical full-tree digest, so renamed copies and updates fail closed. |
| Durable Trakt delivery | Watched movie/episode commits enter a deduplicated SQLite outbox instead of being discarded while another request is active. HTTP failures are detected, retried with bounded backoff across restarts, and surfaced with queue count plus an explicit retry action. Device authorization follows provider interval/expiry values and is owned and cancellation-safe; rotating refresh tokens are encrypted and replaced atomically on 401. Account state crosses threads through a locked snapshot, revoked credentials become an explicit reconnect state, and a stale response cannot erase a newer token. |
| AniList account and progress sync | The official desktop/PIN OAuth flow is exposed without returning stored tokens to the browser. Long JWTs are encrypted at rest on Windows, AniList IDs survive browse caching, episode playback enters the durable outbox, and queued progress has visible retry/revoke controls. |
| SIMKL account and watched sync | SIMKL's current PIN protocol respects provider polling intervals and mandatory client/app identity. Tokens are encrypted and write-only, completed TV episodes enter the shared durable outbox, HTTP status is interpreted explicitly, and a revoked 401 becomes visible reconnect-required state without dropping queued work. |
| Deterministic AI subtitle generation | ffmpeg and Whisper run in contained process trees with hard deadlines, shutdown cancellation and media-change cancellation. Completed SRT files cross a UI-thread handoff and attach only when both the process-unique player pointer and monotonic load serial still match, preventing a late transcript from appearing on replacement media. |
| Web subtitle workflow | The rich player snapshot includes source-tagged keyless subtitle results plus local generation state. Search, bounded-index download/use and Whisper generation cross the existing typed POST-only action allowlist; busy/stale selections fail explicitly and the responsive web deck polls one coherent workflow state. |
| Universal Plex discovery | A connected Plex server participates in shared native/web search through a caller-owned result projection. Cached actions retain credential-free identity, exact resume state and an alternate direct-play part; live credentials are reconstructed only at playback and existing transcode recovery remains the final fallback. |

## Test commands

Fast checks:

```sh
zig build test -Doptimize=ReleaseSafe -Dcpu=x86_64_v2
python3 tests/test_feature_harness.py
node tests/test_web_lifecycle.mjs
```

Windows startup baseline (installed build, app initially closed):

```powershell
powershell -ExecutionPolicy Bypass -File scripts/measure-startup.ps1 -Runs 5
powershell -ExecutionPolicy Bypass -File scripts/measure-playback.ps1 -Media assets/media/browse.mp4 -Runs 5
powershell -ExecutionPolicy Bypass -File scripts/measure-playback.ps1 -Media 'https://www.youtube.com/watch?v=HHUQvEWQLfI' -Runs 3 -FirstFrameBudgetMs 4000
powershell -ExecutionPolicy Bypass -File scripts/measure-resources.ps1 -SampleSeconds 8
```

The metric is process creation to a visible, responsive window. This includes
the hidden-first-frame protection, so it catches regressions that reintroduce
the empty black/white-border startup surface rather than merely timing appInit.

Feature checks without inspecting the user's installed profile or overwriting
the tracked dashboard report:

```sh
python3 tests/test_features.py --database /tmp/opal-quality-fixture/opal.db --results /tmp/opal-quality-report.json
```

A nonexistent explicit fixture is created from the shipped `db.zig` schema and
seeded with deterministic non-secret values; an existing fixture is opened
read-only and never modified. Use the isolated native live tests for actual
extension loading, authentication, library and session behavior. Missing
dependencies/skips remain visible in the report. Never count a skipped
environment test as a pass.

Native build and isolated behavior tiers:

```sh
zig build -Doptimize=ReleaseSafe -Dcpu=x86_64_v2
zig build -Dheadless=true -Doptimize=ReleaseSafe -Dcpu=x86_64_v2 --prefix /tmp/opal-quality-headless
zig build test-tv-detail -Dheadless=true -Doptimize=ReleaseSafe -Dcpu=x86_64_v2
python3 tests/test_tv_library_live.py --binary /tmp/opal-quality-headless/bin/opal
python3 tests/test_session_close_live.py --binary /tmp/opal-quality-headless/bin/opal
python3 tests/test_updater_live.py --binary /tmp/opal-quality-headless/bin/opal
```

The live runner refuses a busy server port; supply required runtime library
paths for a bare Linux binary. Browser/GUI tests may need explicit execution
approval and an isolated display. Real account/tailnet integration remains
unverified until an authorized test environment is available.
