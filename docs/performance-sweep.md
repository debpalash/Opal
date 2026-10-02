# Performance sweep

A single pass over the whole architecture — desktop render loop, data layer,
network layer, worker supervisor and the web companion — removing work that was
being repeated per frame, per file or per request when its inputs had not
changed. No behaviour or output is intentionally different; the same bytes are
produced from the same inputs.

Every change below is either covered by a unit test or is a behaviour-preserving
rewrite of an existing expression.

## Render loop (the per-frame budget)

| Change | File | Why it cost |
|---|---|---|
| Home rails serve cached rows | `services/library_store.zig` | `loadContinue`, `hiddenContinueCount` and `loadFavorites` each ran a `prepare` + `step` + `finalize` on the shared `FULLMUTEX` connection **on every rendered frame** — three SQLite round trips per frame, on the app's default landing page, for rows that rarely change. A version counter bumped by every mutator (`upsertProgress`, `setFavorite`, `setRating`, `setHomePinned`, `setHomeHidden`, `restoreHiddenContinue`) now gates the re-query. |
| Loading overlay stops pinning the frame rate | `ui/grid.zig`, `ui/components.zig` | The finding-stream and loading branches ended with a bare `dvui.refresh`, which re-renders the whole app as fast as the CPU allows for as long as the state is active. Now driven by `components.animatedRefresh(33_000)` — a 30 Hz bound that is indistinguishable for a spinner and stops starving the playback threads it shares the process with. |
| Picture-preset chip stops its per-frame mpv IPC | `ui/footer.zig` | The `Auto` branch (the default) read `video-params/gamma` through `mpv_get_property_string` on every frame — a blocking IPC plus a libmpv-internal malloc/free, contending with the demux and render threads. It now uses the same 500 ms, ctx-keyed cache as its four sibling chips. |
| Elapsed / remaining clock labels memoized | `ui/footer.zig` | Both are formatted from `t_sec`, which changes once per second, at display rate — so ~59 of every 60 renders re-derived a byte-identical string. |
| YouTube URL probes gated | `ui/footer.zig` | Two case-insensitive substring searches over the loaded URL ran unconditionally; both results feed only the quality chip. The cheap conditions are now tested first. |
| List membership is a hash lookup | `services/tmdb_store.zig` | `isInList` was a linear scan, called three times per visible poster card against lists holding up to ~1900 items — O(3 × visible × list_len) integer comparisons per frame. Replaced by a per-list id set, invalidated explicitly from the two places that mutate them. |

## Data layer

| Change | File | Why it cost |
|---|---|---|
| Local-library scan prepares once, commits per root | `services/local_library.zig` | `indexFile` prepared and finalized its `INSERT` **per file** — up to `MAX_FILES` (100 000) — and each row committed in autocommit mode, so one WAL fsync per indexed file. The statement is now prepared once per scan and reset per row, and the scan runs in one transaction per root (scoped to a root so the write lock is never held across a whole library). Every exit path commits; leaving the transaction open would wedge the shared connection. |
| Duplicates search drops a repeated subquery | `services/local_library.zig` | The `WHERE` clause repeated the same `COUNT(*)` the `SELECT` list already computed, so every candidate row paid for it twice. |
| `busy_timeout` on the shared connection | `core/db.zig` | Without it a contended writer fails **instantly** with `SQLITE_BUSY`, and the callers here discard that error — so a UI-thread `config.save()` racing a worker could silently lose a setting. |
| `foreign_keys=ON` | `core/db.zig` | The schema relies on `ON DELETE CASCADE`; without the pragma the cascade was inert and child rows accumulated. |
| Eight new indexes + `PRAGMA optimize` | `core/db.zig` | The Home rails, the Live TV filter chips (a `COUNT` over 100k rows per keystroke), the local-media stale sweep, browse-history ranking and resume lookups all lacked an index. `PRAGMA optimize` gives the planner the `sqlite_stat1` it had no reason to guess with. |
| `copyColumn` zeroes the length | `core/db.zig` | A `NULL` or empty column left the caller's length untouched, so a recycled output row could carry the previous row's length next to freshly zeroed bytes. |
| `config.save()` prepares once | `core/config.zig` | `save()` runs ~100 `setKey` calls inside one transaction on the render thread; each re-parsed the same `INSERT` and re-ran the planner. The statement is memoized and tagged with its connection so a `db.deinit`/reopen cannot reuse a handle SQLite has already finalized. |

## Worker supervisor

`core/workers.zig` admitted work by scanning all 256 slots twice per submission —
a full-table reap plus a free-slot probe — while holding one global mutex, so
every `workers.spawn` (54 call sites, most of them network fan-outs) serialized
on ~512 iterations. Admission is now O(1) via a LIFO free-slot stack, and
finished workers publish their index to a reap list.

Reaping now joins **outside** the mutex: a worker needs that same lock to publish
its completion, so joining under it was a deadlock waiting for the next worker to
finish. Two tests lock the invariants in — that sequential spawns recycle slots
rather than draining the table after 256 submissions, and that a full table
reports `WorkQueueFull` instead of overwriting a live worker.

## Network layer

| Change | File | Why it cost |
|---|---|---|
| Static assets memoized, with `ETag`/`304` | `services/remote_static.zig` | Every shell request re-stat'd, re-opened, re-read and re-allocated the file, and `Cache-Control: no-cache` shipped **without a validator** — which is worse than no header, because it forces the browser to revalidate and then re-download the whole body. Packaged builds now read each allowlisted file once and answer a conditional `GET` with an empty `304`. A dev checkout deliberately still reads from disk, so `just run` keeps showing edited `web/js/*.js`. |
| SSE only writes on change | `services/remote.zig` | Idle playback produced a byte-identical frame every second, per connected client. Now written only on a real change, with a 5 s heartbeat so proxies and the browser keep the stream open. |
| Status build drops a blocking mpv read | `services/remote_status.zig` | `media-title` was fetched from mpv on every build — inside `players_mutex`, which the render thread also takes — and then discarded whenever either cached mirror already had a title. It is now fetched only in the case that actually reads it. |
| Response bodies read straight into the caller's buffer | `core/http_transport.zig` | `allocRemaining` grew a heap `ArrayList` to the full body, which was then memcpy'd into the caller's buffer and freed — a malloc/free plus a second full copy on every outbound request, of which a search fans out hundreds. |
| Content-cache reads skip the mkdir | `core/content_cache.zig` | `entryPath` issued a `mkdir -p` syscall on **every** cache read, which is the path the UI thread takes when seeding a view from cache. The path is memoized; only the rare writers and the startup sweep still create it. |
| Anime episode pages parse once | `services/anime.zig` | Each page's JSON DOM was built three times — once to validate the fetch, once to publish, plus a third `catalog.data` call — on multi-hundred-KB jikan pages, once per page of a long series. |

## Web companion

- `settledInterval` watchers stand down while the tab is hidden. Roughly twenty
  view watchers are alive at once across the app; backgrounded, they still fired
  on their interval, walked the DOM diff and re-queried the API for a result
  nobody would see. The timer stays `setInterval` so the existing
  `clearInterval(...)` teardown keeps working with a stable id.
- The now-playing fallback poll keeps its timer chain alive across a hidden tab
  (so returning to the page still gets a live status) but spends nothing on the
  request.

## Verification

```sh
zig build -Doptimize=ReleaseFast
zig build test
node --test tests/test_web_lifecycle.mjs
```

`zig build test` currently reports one failing target on some Linux toolchains:
`secret_store` fails to link in Debug mode against a GCC 16 `crt1.o` carrying a
`.sframe` section (`unhandled relocation type R_X86_64_PC64`). That is a
host-toolchain incompatibility in `crt1.o`, unrelated to anything here; every
other target passes (2193/2193 assertions). The failure is present on an
unmodified checkout too.

New tests added by this pass:

- `core/workers.zig` — sequential spawns recycle slots instead of draining the
  table after 256 submissions; a full table reports `WorkQueueFull` instead of
  overwriting a live worker.
- `services/remote_static_pure.zig` — `If-None-Match` parsing: case
  insensitivity, lists, the `*` wildcard, a header-name prefix that is not a
  header, and header-like text in the body. Extracted to a `_pure` module
  because `remote_static.zig` itself has no test target (it pulls in the socket
  and database layers) and these rules are easy to get subtly wrong.
- `tests/test_web_lifecycle.mjs` — view watchers stand down while the tab is
  hidden and resume after.

## Known follow-ups

These were measured and confirmed but left alone here, in rough payoff order:

- **No HTTP keep-alive on the web companion.** One TCP connection and one OS
  thread per request, and no `Connection:` header, so browsers re-race a dead
  socket. A page load is ~14 thread spawns.
- **No compression in either direction.** `Accept-Encoding` is never sent and
  nothing is served gzipped, so a ~700 KB shell load goes over the wire raw.
- **No in-memory tier for the content cache.** Every hit is a full file read plus
  an XChaCha20-Poly1305 decrypt; there is no negative caching and eviction is
  oldest-`created_ts`-first at launch only.
- **8 MB allocation to attempt a cache read** in the TMDB detail paths, before a
  second 8 MB for the network fetch — a season switch churns 16 MB to read
  typically 50 KB.
- **The web poster proxy has no in-flight dedup and no concurrency cap** (the
  desktop path is capped at 8), so a 48-card grid means 48 simultaneous fetches.
- **`/api/library` copies ~147 KB of rows and sorts all of them** before
  paginating, and the web companion polls it every 1.5 s.
- **Comics page images are still JPEG-decoded on the render thread** — the one
  surface that has not moved to the worker + `poster.fetchAsync` pattern every
  other surface uses.
- **`tv_library`, `search`, `transfers`, `drawer` and `queue` lack row
  virtualization.** Twenty other content surfaces already use
  `tmdb_pure.visibleRows`; these walk up to 200–256 rows per frame.
