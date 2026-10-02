# Opal maturity and performance audit

Completed implementation audit, 2026-10-03. This records implemented behavior and reproducible
checks; provider availability and device performance require separate measurements.

## Changes

| Surface | Gap found | Implemented behavior |
| --- | --- | --- |
| Anime | Successful HTTP error documents could destroy useful browse results | Validate the provider's complete catalog array before replacing cards; snapshot page and filter settings |
| Comics | Image decoding happened in the render path | Two bounded decode workers; generation-checked publication; GPU upload remains on the UI thread |
| Podcasts | Feeds stopped at 200 episodes; stale indices could play another page | Retain a bounded complete feed, expose 200-item pages and totals, validate playback/page generations |
| Audiobooks | Spaced login JSON failed; headless playback stayed loading; every file looped forever | Structural login parsing, audio/headless readiness, authoritative EOF handling and normal non-repeating file defaults |
| OPDS | Universal queries lacked independent server search | Use advertised supported Atom/OpenSearch GET templates without replacing Browse state; retain private action validation |
| Watching | Polls recopied and resorted the entire library | Cache projections by revision and selectors; return scoped unchanged responses and requested pages |
| Local library | Scanning shared the configuration transaction; pages lacked totals | Separate scanner connection, checked 128-row batches, explicit query failures and 64-item pages |
| Calendar | Workers mutated visible entries and artwork identities | Publish snapshots atomically; retain previous cards on failure; report partial/stale state |
| Artwork | Concurrent misses duplicated fetches; content was always labeled JPEG | Recheck cache under sharded locks, share the eight-fetch capacity and identify supported image signatures |
| Native lists | All rows were built during pointer scrolling | Measure visible rows with overscan; retain full keyboard action registration after Tab |
| Shutdown | A bootstrap download ignored quitting until the forced-exit deadline | Cancel bounded children and descendants, drain output and reap them; distinguish cancellation from timeout |
| Settings | Cached SQLite statements survived database closure | Scope reusable writers to a save and finalize every statement |
| Web assets/startup | Buffers were freed before transmission; packaged headless resources were missed; saved listener rows raced startup | Retain send buffers, resolve resources in shared startup, restore complete listener preferences before starting |
| Radio/music/comics actions | A stale numeric result index could select another item | Use station UUIDs, provider track IDs and copied comic reader identities; reject obsolete playback identities |
| Catalog/YouTube JSON | Fixed response buffers could overflow; row reads could mix publications | Single immutable snapshots, escaping-aware bounded buffers, truthful counts and real provider metadata |
| Offline shell | A loaded script was omitted from the cached shell | Cache every script referenced by the production document; verify the inventory automatically |
| Web requests | Non-success API responses could appear as empty results | Reject HTTP errors, preserve status codes and existing useful rows |

## Verification results

- The production JavaScript lifecycle suite passes 46 checks. Three new targeted
  checks fail against the preceding committed scripts.
- Six isolated audio/catalog cases pass: podcast paging and stale requests,
  mandatory page generation, authenticated advertised OPDS search, and
  Audiobookshelf login, generated-audio advancement and whole-book resume.
- TMDB's allocation-policy regression demonstrates that a 50 KiB response uses a
  50 KiB owned body instead of the previous 8 MiB allocation. This is a body-size
  comparison, not an app-wide memory benchmark.
- A synthetic 500-row pointer-scroll fixture builds nine rows. Keyboard mode
  deliberately registers the full bounded list.
- The integrated Zig unit suite passed after fixing a real worker shutdown race.
  The worker suite also passed 50 repeated runs (64,000 worker submissions).
- The final source-contract feature inventory passed 476 checks, with zero
  failures, zero warnings and 14 skipped checks using an isolated database. This inventory is not
  a substitute for runtime verification.
- Native and headless builds and the combined browse/TV/anime stateful gate passed.
- Three restart cases passed without forced shutdown; generated-audio EOF
  advancement passed three consecutive isolated runs.
- One live action-identity case passed nine rejection checks for missing,
  invalid, oversized and unavailable identities.
- Two isolated local-library cases passed, including 130 generated files,
  64-item paging, Unicode corrections, deletion and configuration persistence.
  Their short scans do not prove deterministic transaction overlap.
- Three static-asset runtime cases passed, including all 19 files, concurrent
  requests, packaged headless resource discovery and ETag comparisons.
- Public-provider metadata smoke checks passed in a fresh isolated instance:
  podcast search (50 results), radio search (30 results), comics catalog
  (20 results), and NASA RSS (200 episode audio URLs). These checks do not
  establish uptime or media playback.
- The live fixture port guard rejects existing wildcard listeners before
  startup, including the macOS collision case. Tests can use an isolated
  configured port. The port regressions pass, the five setup/auth cases pass,
  and active-work shutdown stress passes three iterations.
- Native process liveness was observed for eight seconds with a fresh profile.
  Rendering was not confirmed and the isolated process required forced cleanup
  after SIGTERM. This does not establish native UI or shutdown correctness.
- Desktop and 390-pixel mobile Watching layouts were inspected in ego-browser.
  Sign-in reloads the current page, and a healthy empty local index is shown
  correctly. No document-wide horizontal overflow was found in that view.
- Generated-audio playback now advances two 2-second tracks and sends one final
  book-progress update at 4 seconds. A 100-second book resumes at 62 seconds by
  opening its second file at 12 seconds. These are controlled local audio
  fixtures, not verification of external personal-server playback.

## Watching loopback measurement

An isolated fresh-XDG headless instance held 200 synthetic tracked shows and
returned a 96-item page. Forty warm alternating requests of each type produced:

| Response | Bytes | Median | p95 |
| --- | ---: | ---: | ---: |
| Full page | 35,298 | 1.097 ms | 1.161 ms |
| Scoped unchanged | 67 | 0.540 ms | 0.584 ms |

The unchanged response transferred 99.81% fewer bytes in this fixture. Every
sample checked its items, total and version. These are warm loopback request
measurements; they do not measure WAN latency or overall application speed.

## Search v2 — 2026-10-03

Native Search now has one expanding query field, Filters and compact sorting.
Content, availability, quality, seeds, size and provider facets affect the owned
result view; provider enablement stays a separate saved setting under Sources.
The web view consumes the same typed metadata and retains opaque action keys.

Results are copied only when their publication revision changes and drawn after
resolver locks are released. Pointer navigation renders the visible row range;
keyboard traversal retains the full bounded layout. Strong late results can
replace weaker candidates within the existing 96-row limit. Sorting ties and
row actions use stable identities. Cancel retains loaded rows; Clear cancels
the generation and resets the query, preventing stale workers from refilling it.

Unknown torrent content remains Video rather than a guessed movie/show. Reading
and metadata rows are excluded from Playable. Torrent queue actions retain the
risk guard. Alternate renditions require matching typed identities and preserve
episode/edition distinctions. Retry search currently reruns the enabled sources.

Full feature gate: 481 passed, 0 failed, 0 warnings, 14 optional checks skipped.
Native and headless builds and the unit gate passed. All 3 live static asset
socket tests passed, including the extracted Search module.
Focused policy tests: 19 passed. Web lifecycle regressions: 55 passed. Browser
layout checks used synthetic results at 1280 and 390 pixels: no horizontal
overflow, a 44-pixel query toolbar, correct filtering and removable filter chips.
These checks do not establish live provider uptime or native pixel correctness;
macOS screen capture access was disabled during this review.

## Coverage still requiring independent evidence

Actual external provider uptime; configured personal-server playback; native
poster/GPU behavior; performance on representative low-memory devices; oversized
metadata download scratch-file limits; and unvirtualized TV surfaces.

## Reproduction

```sh
zig build test
zig build test-browse test-tv-detail test-anime -Doptimize=ReleaseFast
node --test tests/test_web_lifecycle.mjs
python3 tests/test_features.py --results /tmp/opal-features.json
zig build -Dheadless=true --prefix /tmp/opal-maturity-headless
python3 tests/test_content_maturity_live.py --binary /tmp/opal-maturity-headless/bin/opal --port 41697
python3 tests/test_static_assets_live.py --binary /tmp/opal-maturity-headless/bin/opal --port 41699
python3 tests/test_local_library_live.py --binary /tmp/opal-maturity-headless/bin/opal --port 41700
python3 tests/test_browse_action_identity_live.py --binary /tmp/opal-maturity-headless/bin/opal --port 41703
python3 tests/test_shutdown_live.py --binary /tmp/opal-maturity-headless/bin/opal --port 41705
python3 tests/test_setup_token_live.py --binary /tmp/opal-maturity-headless/bin/opal --port 41706
python3 tests/bench_watching_live.py --binary /tmp/opal-maturity-headless/bin/opal --port 41702
```

The live suites create and clean isolated HOME/XDG directories and accounts.
Their ports must be free. They do not connect to an existing Opal process.
