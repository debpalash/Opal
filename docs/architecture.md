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
