# Headless / server mode — scoping

Goal: run Opal as a **headless media server** (Docker / Linux box, no display),
controlled via the existing **remote JSON API (`:41595`)** and **web UI (`:3000`)**
— the capability needed to actually replace Jellyfin / Plex on a server.

Status: **scoping only** (no code yet). Captures the blockers + a phased plan
so the build can land incrementally and green-gated.

## The core blocker

The app's entry is the dvui App framework:

```zig
// src/main.zig
pub const dvui_app: dvui.App = .{ .initFn = appInit, .frameFn = appFrame, ... };
pub const main = dvui.App.main;   // <-- creates an SDL window + runs the render loop
```

`dvui.App.main` **creates an SDL window and runs the render loop**, so it
hard-requires a display server (X11/Wayland). On a headless box SDL window
creation fails and the app can't start at all. (Note from CLAUDE.md: the
*bundled* SDL is X11-only — the headless path must avoid SDL entirely, not just
skip the window.)

## What's entangled (and what's already independent)

- **UI-coupled, in `appInit(win: *dvui.Window)`**: window ref for size/pos
  persistence, `SDL_AddEventWatch` for file drops, the per-frame `appFrame`
  render. These are display-only.
- **UI-independent startup, but currently called from the UI path**: db / config
  / paths init, `remote.zig.start()` (JSON API `:41595`), the STT/TTS/voice
  Python servers, `llama-server`, the libtorrent session (`torrent_init`),
  watch-history / tmdb-store load. None of these need a window — they just
  happen to be kicked off inside `appInit` / early `appFrame`.
- **Control surface already exists**: the remote JSON API (`/load`, `/status`,
  `/search`, `/queue`, `/jellyfin/*`, `/anime/play`, …) + the web UI are exactly
  the headless control plane. This is the big win — most of "headless control"
  is already built.

## Phased plan

1. **Factor `coreInit()`** out of `appInit` — everything window-independent
   (db/config/paths, remote API, servers, torrent session, library loads).
   `appInit` calls `coreInit()` then does the window-only bits. No behavior
   change in windowed mode (verify build + 0 test failures).
2. **Add a headless entry.** Replace `pub const main = dvui.App.main` with:
   ```zig
   pub fn main() !void {
       if (isHeadless()) return headlessMain();   // OPAL_HEADLESS=1, or Linux && no DISPLAY/WAYLAND_DISPLAY
       return dvui.App.main();
   }
   ```
   `headlessMain()` = `coreInit()` + keep the remote API serving + a serve loop
   (sleep / pump background work) + clean shutdown on SIGINT/SIGTERM. No SDL, no
   `appFrame`.
3. **Playback model — NEEDS A DECISION.** mpv currently renders video into a
   texture for the local UI. On a server there's no local screen, so options:
   (a) **control + stream only** — the server resolves/downloads and exposes
   streams to clients via the existing `stream_proxy` / web UI (no local mpv
   video render); (b) mpv audio-only for voice/Co-Watcher features; (c) full
   transcode/stream pipeline (largest). Recommended first target: **(a)** —
   it's the Jellyfin/Plex shape and reuses `stream_proxy`.
4. **Docker packaging.** Image needs the native deps the build links: `mpv`,
   `sqlite3`, `onnxruntime`, `libtorrent-rasterbar`, `ffmpeg` (+ the Python
   voice deps if voice is wanted) — but **not** SDL / X11 / Mesa for the
   headless target. (Windowed desktop build keeps SDL.)

## Risks / open questions
- Cleanly bypassing `dvui.App.main` without losing its signal handling / arena
  setup (replicate the minimal bits in `headlessMain`).
- Any code paths that assume an mpv GL/render context or a focused dvui widget
  must be guarded off in headless.
- Decision (3): which playback model for the server? (control+stream vs
  transcode) — gates the size of the build.

## Not doing yet
No code this cycle — this note is the deliverable. Implementation starts at
step 1 (the safe `coreInit()` factor) once the playback-model decision (3) is made.
