# Opal engineering snapshot

Updated: 2026-09-05. Canonical release version: 0.7.0 (`build.zig.zon`).

Opal is a modular-monolith media application with one active playback surface,
a DVUI desktop presentation, and an optional authenticated Web UI/headless
presentation. Both presentations consume the same in-process services and
SQLite-backed stores. The retired multi-player grid is no longer the product
model; `state.app.players` remains a transitional playback implementation detail.

## Current scale

- Approximately 146,000 lines of Zig in 288 files under `src/`.
- 187 service modules, 45 core modules, and 31 desktop UI modules.
- 12 routes at the task-oriented top level in `src/core/router.zig`.
- One native binary; `-Dheadless=true` replaces the desktop presentation and
  does not link SDL/DVUI.
- The Web UI is served by the native remote service from allowlisted assets in
  `web/`; it is not a separate Zig project.

Counts are deliberately approximate. `tests/features/test_architecture.py`
checks that the version/route documentation still points to canonical sources
instead of pinning a number that becomes stale after every feature.

## Product boundaries

The primary tasks are Home, Search, Browse, Watching, Downloads, Queue,
History, Playing, Assistant, Plugins, Settings, and Logs/System. Browse uses a
source filter; connectors are not top-level destinations. The complete mapping
is in [navigation.md](navigation.md).

The intended dependency direction is documented in
[architecture.md](architecture.md): domain/store → adapters/application
commands → desktop or remote presentation. Existing direct `state.app` access
and `DrawerTab` compatibility routing are migration debt, not the desired API.

## Runtime and concurrency

- `src/core/io_global.zig` owns the process-wide Zig 0.16 threaded-I/O runtime.
- `src/services/remote.zig` uses bounded per-connection workers. Feature locks
  protect snapshots; response bytes are written only after those locks release.
- `src/core/workers.zig` is the current shutdown admission/drain barrier.
  Migration toward the bounded process-owned supervisor is tracked separately;
  new detached workers should not be introduced.
- Provider results must be published as immutable/generation-tagged snapshots.

## Security boundaries

- Remote files are opened component-by-component below an already-open download
  root, without following symlinks.
- Browser sessions use an HttpOnly SameSite cookie; media/SSE URLs contain no
  bearer credential.
- Static HTML carries a restrictive Content Security Policy, and legacy markup
  renderers synchronously sanitize disconnected fragments before DOM publication.

## Testing

`zig build test` is the pure/unit tier. Python feature checks verify wiring and
are explicitly not substitutes for runtime tests. Docker CI boots an isolated
headless process and exercises authentication, hostile framing, deadlines, and
rate limits. New security/concurrency behavior belongs in that live tier.
