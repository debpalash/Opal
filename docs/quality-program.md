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

## Acceptance targets (not yet measured guarantees)

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

Budgets need baseline measurements on this machine and a lower-powered target
before being tightened. External provider availability and hardware decoding
capability cannot be guaranteed by a passing unit test.

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
| HTTP watchdog/socket ownership | Investigation and repair in progress |
| Implicit browser-cookie/TLS bypass in extraction | Consent audit complete; repair in progress |
| Baseline performance / full operation inventory | Pending, not inferred from source presence |

## Test commands

Fast checks:

```sh
zig build test -Doptimize=ReleaseSafe -Dcpu=x86_64_v2
python3 tests/test_feature_harness.py
node tests/test_web_lifecycle.mjs
```

Feature checks without inspecting the user's installed profile or overwriting
the tracked dashboard report:

```sh
python3 tests/test_features.py --database /tmp/opal-quality-fixture/opal.db --results /tmp/opal-quality-report.json
```

A nonexistent fixture intentionally skips database diagnostics; it does not
prove schema behavior. Use the isolated native live tests for actual schema,
authentication, library and session behavior. Missing dependencies/skips remain
visible in the report. Never count a skipped environment test as a pass.

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
