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

The headless build may depend on domain, store, adapter, and application
modules. It must not require DVUI or desktop presentation modules for feature
logic; presentation selection belongs at the executable composition boundary.

Podcasts are the reference migration vertical. Its domain records live in
`podcasts_pure.zig`; networking/parsing and the feature store live in
`podcasts.zig`; desktop and remote presentations must consume snapshot helpers
instead of `state.app.podcasts` buffers directly.
