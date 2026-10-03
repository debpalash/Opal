# Performance and workflow validation

The October 4 measurements found unnecessary text work in the native Search
gallery and stalled requests that could outlive cancellation. The gallery now
skips offscreen text shaping while retaining geometry and every Details keyboard
control. Native HTTP requests own cancellable tasks through DNS, connection,
TLS, headers and body reads; resources are joined before returning.

## Native scrolling and request cancellation

These measurements use the same macOS 26.4.1 Apple Silicon machine, Zig 0.16
Debug build, hidden native SDL window without vsync, 192 owned movie rows,
preloaded textures, eight warmup frames and 120 measured scroll frames at each
size. Frame time includes rendering submission and excludes PNG capture.

| Window | Before p50 / p95 | After p50 / p95 |
| --- | --- | --- |
| 1360 × 1000 | 32.506 / 33.453 ms | 11.599 / 12.874 ms |
| 640 × 800 | 20.183 / 21.136 ms | 9.314 / 10.000 ms |

The fixture asserts scrolling actually moves and text work is limited to a
subset of the rows. It retains keyboard focus checks and narrow-window PNG
captures. Hidden rendering does not measure monitor presentation or establish
an FPS guarantee on another machine.

A TLS server that accepts TCP and never responds previously exceeded a
one-second request budget, returning after its three-second fixture release.
It now returns in approximately 1,006 ms. Epoch cancellation and shutdown
interrupt the same stall in approximately 165–168 ms. Native DNS tests cover
real localhost, IPv4/IPv6, simultaneous lookups, failed names and a simulated
pending native resolver with teardown before return. Windows and macOS use
cancellable platform resolver APIs; Linux retains Zig's cancellable resolver.

The native transport decodes gzip and deflate into the caller's bounded buffer.
The limit applies to decoded bytes; oversized compressed responses fail and
their connections are excluded from reuse. Loopback tests verify exact decoded
JSON and a successful next request after an expansion-limit rejection.

Streaming downloads use joined tasks for probes and each segment attempt.
Opening probes have a 20-second budget; segments reconnect after 30 seconds
without network progress. Rate limiting and file writes do not count as network
stalls. Loopback fixtures cover TLS/header stalls, cancel/pause/shutdown during
body reads, partial progress, exact Range resume, and recovery after a changed
ETag. Healthy downloads retain unlimited overall duration.

## Measured local workflows

The retained benchmark starts an isolated headless application, authenticates
through its real API, searches owned metadata, proxies actual image bytes and
plays generated 16-second media. External HTTPS is rejected by an owned proxy.
Final sequential paired reports: [baseline](benchmarks/2026-10-04/workflows-final-paired-baseline.json)
and [current](benchmarks/2026-10-04/workflows-final-paired-current.json).
The earlier [baseline](benchmarks/2026-10-04/workflows-baseline.json) and
[current](benchmarks/2026-10-04/workflows-current.json) reports remain retained.
No owned compiler ran during the final pair; the user's native Opal remained
running. Baseline ran first, then current, rather than a randomized crossover.

| Workflow | Samples | Baseline p50 / p95 | Current p50 / p95 |
| --- | --- | --- | --- |
| Fresh profile to health response | 5 | 209.854 / 213.878 ms | 211.653 / 214.684 ms |
| Existing profile to health response | 5 | 214.429 / 216.159 ms | 215.135 / 217.165 ms |
| First owned search result | 20 | 40.499 / 46.704 ms | 42.321 / 55.879 ms |
| Open to advancing playback | 20 | 429.139 / 535.200 ms | 426.697 / 536.512 ms |
| First artwork proxy response | 20 | 7.853 / 9.035 ms | 8.180 / 8.425 ms |
| Repeated artwork proxy response | 20 | 0.712 / 0.838 ms | 0.762 / 0.841 ms |
| Paused seek acknowledgement | 20 | 101.492 / 109.182 ms | 103.906 / 108.825 ms |

Median ready RSS was 53,440 KiB before and 53,536 KiB after, across five
profiles. After the 20-search and media sequence, the single workload profile
used 84,640 / 128,224 KiB before and 85,280 / 128,688 KiB after. These single
workload memory samples do not establish a repeatable memory change.

Startup polling has 100 ms resolution; other polling uses 5 ms. Fresh profile
does not empty the OS filesystem cache. Playback readiness validates duration
and advancing position; it does not measure the first visible video frame.
Artwork timings measure encoded proxy bytes; the native WebP fixture separately
checks decoder and renderer pixels. Local timings do not predict public source
latency or availability. Earlier advancing-playback medians were approximately
212–220 ms in both binaries; the final pair measured approximately 427–429 ms
in both. That variation does not demonstrate a new Browse playback regression.
The small differences in this pair require repeated comparisons before drawing
a performance conclusion; the measurements do not establish causality for
provider resume fixes or guarantee absolute performance.

## Reproduce the checks

```sh
zig build -Dheadless=true --prefix /tmp/opal-workflow-bench
python3 tests/bench_media_workflows_live.py \
  --binary /tmp/opal-workflow-bench/bin/opal --port 41831 \
  --repetitions 20 --startup-pairs 5 --results /tmp/opal-workflow-bench.json
zig build test-native-http test-native-downloads test-search-performance
zig build test-native-ui
```

Linux, macOS and Windows CI run native HTTP and download tests, the complete native UI
fixture suite, and the generated Jellyfin/Plex and comic reader workflows.
Linux uses Xvfb; Linux and Windows use software SDL so layout checks do not
depend on a runner GPU. PNG artifacts require visual review; their existence
alone does not establish correct layout. CI does not verify physical GPU
performance, OS window chrome, private accounts or third-party uptime.

See [personal server workflows](media-server-workflows.md) for playback scope
and [source research](browse-sources.md) for verified sources and their limits.

## Playback ownership and crash regression

The October 4 macOS abort reached `Texture.destroyLater` from a TV torrent
resolver worker through `consumePendingPlay`. A native fixture reproduced the
panic between UI frames using a real GPU texture. Workers now copy and queue
torrent/direct playback before accessing the player list. The native frame or
headless owner loop performs player creation, metadata application and texture
retirement. Metadata queued for an existing player is validated against its
lifetime and load serial; each request owns its title, artwork and catalog context.

The same fixture suite verifies cold-start torrent FIFO metadata, direct-play
resume and queue identity, stale player rejection, and clearing an abandoned
movie identity before music playback. A separate real-mpv case reproduced a
rejected seek discarding the provider resume position. That position now remains
armed until mpv accepts the command.

An earlier headless binary reproduced one zero-position Jellyfin resume in eight
runs. The updated owner queue passed sixteen Debug and sixteen ReleaseSafe
repetitions, including reconnection. Those runs did not establish the exact cause
of the earlier intermittent failure; the rejected-seek regression independently
verifies the retry behavior.

```sh
zig build test-native-torrent-handoff
python3 tests/test_media_servers_live.py --binary /path/to/opal
```

## Browse threading audit

The 17 normal catalog loaders reached through the desktop Browse router dispatch
network work to workers. The shared HTTP connection pool permits concurrent
requests; it does not serialize every fetch behind an application mutex.
The Suwayomi connection test also returns after submitting a worker; a delayed
response cannot overwrite a newer Disconnect message. Local Library loads roots
and search rows into an owned worker snapshot, keyed by query, duplicate filter
and committed index revision, rather than issuing SQL on every frame.

| Path | Current request scheduling |
| --- | --- |
| Universal Search | Category backends overlap; some backends still aggregate providers sequentially. |
| Movies & TV, keyless All | Movie and series requests overlap, then merge owned lists. |
| Comics All, Novels All | Up to four joined provider lanes; first useful rows publish immediately, append pagination uses the same bound, stale network requests cancel. |
| Podcasts | Independent installed RSS feeds and Apple/gpodder directories overlap within four joined lanes. Fast shows appear before slow siblings finish. |
| Radio | Radio Browser and installed SomaFM overlap; deduplicated results append progressively. |
| Music discovery | Up to four independent similar-artist album jobs, while MusicBrainz’s one-request-per-second limit and dependent seed lookup remain enforced. |
| IPTV ingestion, universal music | Some independent feeds/providers still aggregate sequentially inside their workers. |
| YouTube | InnerTube, yt-dlp and Piped form an ordered fallback chain. |
| Gutenberg OPDS Discover | Its three advertised Popular, Latest and Random sections merge in bounded parallel waves, with independent continuation cursors. |
| Selected personal library, generic OPDS, source-specific Music | One selected server/source is queried; navigation and dependent pages remain ordered. |

Rendering, layout and GPU uploads remain on the UI thread. Some one-shot local
cache/SQLite reads and browser-bridge pipe writes are synchronous. This audit
does not establish that every frame callback is nonblocking. The single browser-challenge page uses an untagged response protocol: cancellation can abort startup/admission, but an already issued scrape drains safely for up to 45 seconds before releasing the page. A future scoped protocol can shorten that delay; browser-bridge pipe writes also need an owned queue.

## Browse loading and progressive publication

Native catalog placeholders share the cover grid geometry, active theme and a single 25 Hz animation timer. Reduced motion disables that timer. Web browse shows static silhouettes immediately, replaces them with the first useful results, and polls every 300 ms through the existing nonoverlapping, visibility-gated watcher. Empty, error and loading states are distinct; older YouTube and VNDB search responses cannot replace newer searches.

Owned loopback fixtures on October 4 measured Comics first publication at 128 ms and Novels at 70 ms while a second provider’s body remained deliberately stalled. Both old sockets closed within one second after a new search; a failed provider preserved useful sibling results. These are deterministic local workflow measurements, not external-provider latency guarantees. Installed podcast fixtures separately proved overlapping requests, fast-first publication, merging after release and stale-wave exclusion.

The desktop loading fixture captures eleven states (including both anime modes and Gutenberg) at 1360×1000 and 640×800 and asserts real skeleton widgets are emitted without an animation timer under reduced motion. Web visual checks cover all ten browse surfaces at both widths, including partial publication and reduced motion, with no horizontal overflow or page errors. Contact sheets keep review compact.

```sh
zig build test-browse-fanout
python3 tests/test_browse_parallel_live.py --binary /path/to/opal
python3 tests/test_audio_browse_progressive_live.py --binary /path/to/opal
node --test tests/test_web_lifecycle.mjs
```
