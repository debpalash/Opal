# Contributing to Opal

Thanks for your interest in contributing to **Opal** — the blazing-fast, decentralized, local-first intelligent media runtime. ("Play everything.")

> **Naming note:** The project is **Opal**, but the binary, app name, and on-disk config directory all use the legacy name **`zigzag`** (`~/.config/zigzag/`, `~/.cache/zigzag/`). **Do not** rename `zigzag` → `opal` in code or config paths — too many on-disk paths depend on it.

---

## Table of contents

- [Development setup](#development-setup)
- [Build, run, and test commands](#build-run-and-test-commands)
- [Coding conventions](#coding-conventions)
- [Testing is required](#testing-is-required)
- [Commit style](#commit-style)
- [Pull request process](#pull-request-process)
- [License & sign-off](#license--sign-off)

---

## Development setup

Opal is a native desktop app written in **Zig 0.16.x** with an immediate-mode [dvui](https://github.com/david-vanderson/dvui) GUI. It links several heavy native dependencies.

### Prerequisites

- **Zig 0.16.x** (required — earlier/later majors will not build).
  - macOS toolchain: `/opt/homebrew/bin/zig`.
- A C/C++ toolchain (`g++`, used to build `src/torrent_wrapper.cpp`).

### macOS

```sh
brew install zig mpv sqlite onnxruntime sdl2 libtorrent-rasterbar
# Voice features (optional):
brew install ffmpeg whisper-cpp
```

The macOS build hard-codes `/opt/homebrew/{lib,include}`.

### Linux / Wayland

The bundled SDL2 is X11-only, so use the system SDL2 and force the Wayland driver:

```sh
make run    # forces -fsys=sdl2 + SDL_VIDEODRIVER=wayland
```

### Clone

```sh
git clone https://github.com/debpalash/Opal.git
cd Opal
zig build run
```

### Heavy native dependencies

Linked at build time — failures here usually mean a missing system package:

- `mpv`, `sqlite3`, `onnxruntime`, `SDL2` (system or bundled)
- `libtorrent-rasterbar` — wrapped by `src/torrent_wrapper.cpp` → `libtorrent_wrapper.so` (compiled by a step inside `build.zig`; recompiles only when the `.cpp` is newer). The wrapper isolates the C++ ABI.
- `sqlite-vec` (vendored C in `src/core/sqlite/`)
- `ort/ocr_ort.c` — PP-OCR ONNX pipeline
- macOS frameworks: CoreServices, AVFoundation, Cocoa, etc.

---

## Build, run, and test commands

| Command | What it does |
| --- | --- |
| `zig build run` | Debug build + launch (slow first build, fast incremental). |
| `./dev.sh` | **HMR loop.** Watches `src/ tools/ build.zig*`, rebuilds on change, keeps the old binary running on build failure. Session state survives restart. Flags: `-r` ReleaseFast, `-v` verbose, `-- <args>` passthrough. |
| `just hot` | Native Zig 0.16 `--watch -fincremental` (millisecond rebuilds, but bails on C / `build.zig` changes). |
| `just release` / `zig build -Doptimize=ReleaseFast` | ReleaseFast build. |
| `zig build test` (or `just test`) | **Pure-Zig unit tests only** — fast, no app build. |
| `just test-all` (== `python3 tests/test_features.py`) | **Comprehensive gate.** DB schema, config/memory, theming, instant commands, AI, voice helpers, ASR smoke — and folds in the Zig unit tests. Writes `tests/results.json` (viewable in `tests/dashboard.html`). |
| `just fmt` | Format. |
| `just clean` | Clean build artifacts. |
| `just app` / `just app-run` | Build the `Opal.app` bundle (`scripts/build-app.sh`). |
| `just menubar` | Build the menubar helper. |

Build options: `-Dheadless`, `-fsys=sdl2`.

The companion **web UI** lives in `web/` as an independent Zig project (`zig build dev`, serves on `:3000`, talks to the remote JSON API on `:41595`).

---

## Coding conventions

These are hard requirements. Code that ignores them will be asked to change in review. See `CLAUDE.md` for the full set.

### Zig 0.16 `Io` shim — use `io_global` wrappers

Zig 0.16 routes `std.fs`, `std.time`, `std.process.Child`, etc. through an `Io` instance. We avoid threading `io` through every signature via a process-wide threaded Io in [`src/core/io_global.zig`](src/core/io_global.zig).

- **Always prefer** the wrappers there: `cwdOpenFile`, `openFileAbsolute`, `cwdStatFile`, `getenv`, `timestamp`, `milliTimestamp`, `sleep`, …
- **Don't** use `std.fs.cwd()`, `std.time.timestamp()`, `std.posix.getenv()`, or `std.Thread.sleep()` — they don't exist in 0.16. If you truly need a directory handle, use `std.Io.Dir.cwd()` with `io_global.io()`.

### Single global allocator

Use `@import("core/alloc.zig").allocator` **everywhere** — a thread-safe `DebugAllocator` with safety on. Leaks are reported at shutdown (`Clean shutdown: 0 memory leaks.`). **Do not** introduce a second/per-module allocator.

When doing sequential `allocator.dupe()` calls, free earlier successful allocations on later failure:

```zig
const a = alloc.dupe(u8, x) catch continue;
const b = alloc.dupe(u8, y) catch { alloc.free(a); continue; };
```

### Fixed-size buffers, not slices

State structs (see [`src/core/state.zig`](src/core/state.zig)) use `[N]u8` + `len` fields rather than allocated slices — this avoids alloc churn and makes session save/restore trivial. Match the existing pattern when adding state.

### Global app state

`state.app` (see [`src/core/state.zig`](src/core/state.zig)) is the single mutable hub. Workers mutate it under their own atomics / mutexes via [`src/core/sync.zig`](src/core/sync.zig). The UI thread reads it each frame.

### Logging

Use `@import("core/logs.zig").pushLog(level, prefix, text, is_error)` — a ring buffer rendered in the in-app Logs tab — instead of `std.debug.print` for anything a user might want to see. Wrap any raw `std.debug.print` in `if (builtin.mode == .Debug)`.

### Paths

Use [`src/core/paths.zig`](src/core/paths.zig) (XDG-compliant). Config in `~/.config/zigzag/`, cache in `~/.cache/zigzag/`. **Never** hard-code `/home/...` or `~`.

### Thread safety

- **Atomic flags.** Module-level `bool`s shared between the UI thread and background threads MUST use `std.atomic.Value(bool)` with `.acquire`/`.release` ordering:

  ```zig
  var is_busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
  // Read:  is_busy.load(.acquire)
  // Write: is_busy.store(true, .release)
  ```

- **Mutex protection.** Use `@import("../core/sync.zig").Mutex` for shared data structures. Snapshot under the lock, then release before doing UI work: `mutex.lock(); const snap = shared_val; mutex.unlock();`
- **Thread-spawned buffers.** Never allocate >64 KB on a spawned thread's stack (macOS default stack is 512 KB) — heap-allocate with `alloc.alloc` + `defer alloc.free`. Never pass pointers into mutable arrays to detached threads — copy by value or look up by ID.
- **Player access guard.** Always check `state.app.active_player_idx < state.app.players.items.len` before indexing `state.app.players.items[...]`. Never rely on `.items.len > 0` alone.
- **`struct { var }` pattern.** The worker function MUST use `@This()` to reference struct fields (not the outer `const S` binding); add a `var busy: bool = false;` guard to prevent concurrent spawns; copy all input data into struct statics **before** spawning the thread.

### Untrusted text → dvui `safeUtf8`

A large amount of Opal's displayed text comes from untrusted network sources (scrapers, torrent indexers, TMDB/anime/comics APIs, AI output). When rendering such text into dvui widgets, route it through the project's UTF-8 sanitizer (`safeUtf8`) so malformed/invalid byte sequences can't corrupt layout or crash the renderer. Never pass raw scraped/remote bytes straight into a dvui label.

### URL encoding

All URL query parameters must percent-encode at minimum: space, `&`, `=`, `#`, `?`, `%`, `+`.

### Scope discipline

Don't add features, scope creep, or speculative abstractions to a bug fix.

---

## Testing is required

**Every feature or fix must add or update a test in the same change. No exceptions.** A PR that changes behavior without a corresponding test will not be merged.

### The rule

- **Pure logic** → extract it into a `*_pure.zig` sibling with Zig `test { ... }` blocks, **register the module in `build.zig`**, and route the production code path through the tested function. See existing examples: `ai_intent_pure.zig`, `resolver_rank.zig`, `tmdb_pure.zig`.
  - This pattern also sidesteps a 0.16 limitation: a standalone test module **cannot** `@import` a module that pulls `core/io_global.zig` across the `src/` boundary. If a new test fails to build with a cross-boundary `@import("../core/...")`, factor the pure logic into a `*_pure.zig` sibling (or skip the standalone test, as `voice_backend.zig` does).
- **Feature / integration behavior** → add or update a check in [`tests/test_features.py`](tests/test_features.py), the single comprehensive suite (DB schema, config/memory, theming, instant commands, AI, voice helper scripts, STT/ASR smoke).

### The gate

Before every commit, both of these must pass with **0 failures**:

```sh
zig build test                  # pure-Zig unit modules (fast)
python3 tests/test_features.py  # comprehensive suite (== just test-all)
```

Interpreting results:

- **`fail`** = a real regression. Fix it before committing.
- **`skip`** = an optional component isn't present (voice ML deps, a running server). Skips are acceptable.

Report the pass/fail/skip tally in your PR description. `tests/test_features.py` writes `tests/results.json` (viewable in `tests/dashboard.html`).

---

## Commit style

- Use **Conventional Commits**: `type(scope): summary`. Common types: `feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `chore`. Examples from recent history:
  - `fix(tmdb): string-aware results splitter + TV seasons diagnostics`
  - `perf(poster): cap concurrent poster fetches at 8 across all providers`
- Keep the summary imperative and under ~72 chars; explain the *why* in the body when it isn't obvious.
- Make focused commits — one logical change each. Don't mix a bug fix with unrelated reformatting.
- Never commit generated artifacts or local config.

---

## Pull request process

1. **Fork** and **branch** off `main` (don't push directly to `main`): `git checkout -b feat/my-feature`.
2. Make your change, **add/update the required test(s)**, and run `just fmt`.
3. Run the full gate: `zig build test` **and** `python3 tests/test_features.py` — both at 0 fail.
4. Open a PR against `debpalash/Opal:main` (use the `gh` CLI for GitHub operations).
5. In the PR description, include:
   - What changed and why.
   - The test you added/updated.
   - The pass/fail/skip tally from the gate.
6. Keep PRs small and reviewable. Address review feedback with follow-up commits.

### Reporting issues

- Use GitHub Issues.
- Include your OS, Zig version, and steps to reproduce.
- For crashes, include the stack trace if available.

---

## License & sign-off

By contributing, you agree that your contributions are licensed under the **project license (GPL-3.0)**.

> Opal links **libmpv** (GPL), so the combined work is governed by the GPL. Contributions are accepted under **GPL-3.0** accordingly.

All commits must be **signed off** under the [Developer Certificate of Origin (DCO)](https://developercertificate.org/). Add a `Signed-off-by` line by committing with `-s`:

```sh
git commit -s -m "fix(scope): short summary"
```

This appends:

```
Signed-off-by: Your Name <your.email@example.com>
```

certifying that you have the right to submit the contribution under the project's license.
