# Contributor architecture

Opal remains a modular monolith. Features should follow this dependency flow:

```text
pure domain types/rules
        ↓
feature-owned store (commands + immutable snapshots)
        ↓
network/database/process adapters
        ↓
application commands
       ↙ ↘
desktop UI  remote/API presentation
```

Rules:

1. Domain and store modules do not import DVUI or `ui/`.
2. Adapters may depend on domain/store interfaces, never desktop presentation.
3. Desktop and remote code consume the same commands and snapshots.
4. A worker builds private results and publishes one generation atomically under
   its feature lock. Readers copy a snapshot; they never retain a pointer into a
   worker-owned mutable buffer.
5. Acquire feature locks before `players_mutex`; never take a feature/state lock
   while writing to a socket. No lock may be held across process/network I/O.
6. Process work is admitted through the owned supervisor and joined before
   services, shared I/O, or the allocator are destroyed.

`workers.spawn` is the default bounded, joinable path. `workers.spawnLegacy`
is the single documented compatibility exception for code that still needs a
native thread handle: callers either join it or relinquish it through
`workers.release`, while bounded admission and the shutdown barrier track the
task through its actual completion. Application modules must not call
`std.Thread.spawn` or raw `.detach()` directly; those operations live only in
the supervisor and its fixed work-pool implementation.

The headless build may depend on domain, store, adapter, and application
modules. It must not require DVUI or desktop presentation modules for feature
logic; presentation selection belongs at the executable composition boundary.

Podcasts are the reference migration vertical. Its domain records live in
`podcasts_pure.zig`; networking/parsing and the feature store live in
`podcasts.zig`; desktop and remote presentations must consume snapshot helpers
instead of `state.app.podcasts` buffers directly.

## Enforced migration boundary

`python3 scripts/check_architecture.py` checks actual imports in core, services,
and application modules. Existing presentation imports are recorded as exact
edges in `architecture-exceptions.json`; new edges fail, and resolved exceptions
must be removed. The feature gate exercises this checker. The backlog is not a
claim that every existing service is already UI-free. Extract rendering feature
by feature, following Podcasts, rather than adding new dependencies to the list.

Desktop and headless execution share `application/playback_update.zig`. Worker
completion and playback recovery belong there, never solely in a widget or
desktop frame. Both hosts retain their own presentation and input handling.

Shared SQLite transactions use `db.beginTransaction()`. Its guard owns SQLite's
recursive connection mutex through checked commit or rollback, excluding even
raw SQLite callers. Acquire feature snapshots first; never acquire a feature
lock, await a worker, or perform network/process work inside a transaction.
Finish/finalize statements before releasing the guard. Dedicated scan/queue
connections retain their own transaction ownership.

Shared playback metadata and loading decisions live in `src/core/loading_pure.zig`.
The native loading screen and remote services consume the same pure module;
services do not import the UI to identify media kinds or resolve poster URLs.

## Horizon wave 2 implementation boundaries

Wave 1 is reviewed on `v10-horizon`; `v11-resilience-commons-craft` adds the
following implementation.

### Resilience (7.6)

`services/link_health.zig` persists timestamped results and expires them both
when loading SQLite rows and during in-memory reads. In-flight reservations
prevent duplicate probes and are released on completion. Resolver scores and
playback fallback order consume this cache. Header-dependent requests preserve
their original order because anonymous probes cannot assess their credentials.
The cache and worker cap bound background work; no synchronous network probe
runs on the playback thread.

`next_episode.zig` starts one owned pre-resolution job after 60% of a playing
episode. It selects the next aired episode across seasons and warms the existing
EZTV/Torznab resolver cache. A media generation suppresses obsolete publication;
in-flight network calls retain their existing timeouts. This reduces repeated
search work; it does not guarantee zero-wait playback or warm every provider.

### Commons (7.7)

Repositories are user-added URLs with pinned Ed25519 publisher keys. The exact
manifest bytes are verified before parsing. An install confirmation contains
the displayed revision's SHA-256 digest. Installation requires the machine API
token or an explicit native host action; it never grants executable trust.
The runtime and catalog verifier share a typed permission parser. Lua entrypoints
remain subject to existing content approval and sandbox policy. Declarative
panels display bounded text only. No remote HTML or JavaScript is evaluated.

Moments export at most 120 seconds of the current local media. Private files
live in owner-only directories on POSIX; the household feed exposes opaque IDs, titles,
creator profile and timestamps. Playback uses the signed stream lifecycle,
including stop-on-close. Sending reuses authenticated Opal handoff. Child
profiles cannot use the feed; physical casting remains a separate integration.

### Craft (7.8)

The shared theme already defines contrast-checked palettes, interaction states,
focus and elevation tokens. New native controls use these components. Build
commands keep desktop and headless outputs separate so a broad test cannot
replace a running live fixture's binary. Torrent-wrapper linkage uses a
pkg-config fallback only on failure, avoiding duplicate library arguments.
Native startup, idle SIGTERM and clean teardown were exercised with an isolated
profile; captured logs contained no DVUI deinit warnings. No speculative
teardown change was needed. Architecture import checks remain the common gate.

### Wave 2 live tests

```sh
zig build -Dheadless=true -Doptimize=ReleaseFast --prefix /tmp/opal-wave2-live
python3 tests/test_wave2_live.py --binary /tmp/opal-wave2-live/bin/opal
python3 tests/test_fingerprint_live.py --binary /tmp/opal-wave2-live/bin/opal
python3 tests/test_babel_model_live.py --binary /tmp/opal-wave2-live/bin/opal --model /absolute/path/to/model.gguf
python3 tests/test_babel_model_live.py --binary /tmp/opal-wave2-live/bin/opal --model /absolute/path/to/model.gguf --embeddings
zig build -Doptimize=ReleaseFast --prefix /tmp/opal-wave2-desktop
python3 tests/test_native_shutdown_live.py --binary /tmp/opal-wave2-desktop/bin/opal --port 42989
```

The add-on fixture requires OpenSSL Ed25519 support and ffmpeg. Model tests own
one loopback llama-server, isolate configuration and use a local provider
adapter so Opal cannot stop another model process. Translation was checked with
Qwen3-1.7B Q4_K_M. Its mean-pooled embeddings verify vector-index integration,
not retrieval quality; use a dedicated embedding model for quality evaluation.
The fingerprint fixture generates two videos sharing an intro, verifies stored
audio fingerprints and executes the skip without chapter metadata.

### Verified wave 1 test entry points

Run `zig build test` and `python3 tests/test_features.py` for the standard gate.
`node --test tests/test_horizon_web.mjs` exercises Recall rendering, opaque play
ids, stale search responses, stream cleanup/request ordering and profile PIN
errors. It is also called by the feature gate.

Build an isolated live-test binary:

```sh
zig build -Dheadless=true -Doptimize=ReleaseFast --prefix /tmp/opal-horizon-live-build
python3 tests/test_horizon_live.py --binary /tmp/opal-horizon-live-build/bin/opal --port 42984
python3 tests/test_horizon_media_live.py --binary /tmp/opal-horizon-live-build/bin/opal --port 42985 --model /absolute/path/to/ggml-tiny.en.bin
zig build -Doptimize=ReleaseFast --prefix /tmp/opal-horizon-desktop-build
```

The media smoke requires macOS `say`, ffmpeg and whisper-cli. It synthesizes its
own media and symlinks a supplied model into an isolated profile. Both live
scripts own their server process and temporary profile, reject occupied ports,
and clean up afterward. The media test uses the same host for handoff; it does
not validate physical casting or another device. Visual layout, physical casting and recap model output remain separate
validation work. Translation and vector integration have the tests above.
