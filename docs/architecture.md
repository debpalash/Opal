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

Wave 1 is reviewed on `v10-horizon`. Wave 2 begins with these ordered slices;
they are planned work, not claims of shipped behavior.

### Resilience (7.6)

`services/link_health.zig` already persists probe results and bounds concurrent
work. Its in-memory maps and attempted markers currently outlive the database
TTL. First make expiry observable without restarting, then feed the same
snapshot into resolver candidate ordering and playback fallback selection.
Preserve caller headers and exclude loopback proxies from remote-health probes.
Tests must advance an injected clock, expire a persisted result, and demonstrate
that ranking and fallback use the refreshed result. Next-episode pre-resolution
must own its input and cancel when the active series or profile changes.

### Commons (7.7)

Keep repository URLs user-configured. Verify the exact downloaded manifest
bytes before interpreting permissions or installing executable code. Trust and
permission grants belong to the host administrator; browser callers cannot
silently approve them. Implement signature verification and rejection fixtures
before adding repository UI. Shared moments must identify a media item and
bounded timestamp; local paths and peer credentials cannot enter the household
feed. Reuse existing paired-device authentication and profile isolation.

### Craft (7.8)

Continue the existing architecture boundary checks instead of adding a second
lint system. Document and verify both desktop and headless build commands with
separate output prefixes; a broad test may rebuild the default output and must
not replace the binary a live fixture is executing. Track remaining DVUI
shutdown warnings from actual logs before changing teardown order. Theme
changes must continue through the shared tokens and components.

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
not validate physical casting or another device. Visual layout, embedding and
translation/recap model output remain separate validation work.
