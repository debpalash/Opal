# Opal headless server — execution spec (v2)

**Supersedes** the planning in `headless-scoping.md` and consolidates the
shipped work tracked in `headless-hosting-spec.md`. This is the authoritative
plan for finishing the Docker/web-UI server story.

## 0. Decision recap (settled — do not relitigate)

- **One codebase, one feature set, two build flavors.** The desktop app and the
  server are the *same* source; a compile-time flag (`-Dheadless=true`) swaps the
  entry point only. There is **no second codebase** and **no second version to
  maintain**.
- **Not a runtime `--headless` flag on one binary.** Impossible here: dvui's
  `App` interface comptime-requires `root.main == dvui.App.main` *exactly*
  (`main.zig` documents this), so a runtime dispatcher cannot conditionally call
  it. The compile-time entry swap is the only workable model.
- **Server artifact name:** ship the headless build as `opal` inside the image
  (the image *is* the boundary); optionally publish a `opal-server` alias in
  releases for clarity. TBD, low priority.
- **Playback model (settled in H2):** hosted "play" = **stream the file to the
  browser** (`<video>` + HTTP Range), not local mpv render. Direct-play only; no
  live transcode in v1.

## 1. Current state (accurate as of this spec)

| Phase | What | Status |
|---|---|---|
| H0 | Headless entry serves web UI + JSON API on **:41595**, prints web URL + first-run hint to stdout | **Shipped** |
| H2 | Browser playback: `/api/stream` HTTP Range + SRT→VTT `/vtt` | **Shipped** (smoked on the macOS headless binary) |
| H3 | Web parity tier 1: browse, TV drill-down, calendar, torrents, history, first-run setup | **Shipped** |
| H1 | Dockerfile builds `-Dheadless`, non-root, healthcheck, volumes | **Builds green on GHCR** (`docker.yml` + `.dockerignore` fix) |
| S0 | Image actually *runs*: runtime `.so` deps + a CI gate that starts the container and hits `/health` | **Shipped** |
| S1 | Slim build: no dvui/SDL/X11 link (§2) | **Shipped** |
| S2 | Drop the S0 stopgap packages; `ldd` grep is a hard CI gate | **Shipped** |
| S3 | Multi-arch: amd64 + arm64 on native runners, per-arch smoke, one manifest | **Shipped** |
| S4 | Parity tier 2 — 21 web verticals (Comics/Novels/Drama/VNDB/ABS/OPDS/Plex/Logs) | **Shipped** |

**One codebase, one port, mostly built.** The gaps below are what remain.

## 2. Phase S1 — the slim build (**SHIPPED**)

The `-Dheadless` binary now links **no GUI stack at all**.

`build.zig` swaps the dvui module for `src/core/dvui_headless.zig` and skips the
SDL2 link. On macOS it also stops compiling `src/macos/media_remote.m` (the Now
Playing card), which was the last thing pulling in the ObjC runtime + Foundation
— the desktop build had been getting those transitively from dvui's bundled
SDL2.

**Why the stub is small.** Zig only analyzes *reachable* decls. `main ==
headlessEntry` never references `appFrame`, so all of `ui/*` and every `render*`
in `services/*` is never compiled. Roughly 60 modules `@import("dvui")`; they
need the module to **exist** and reference **zero** symbols from it. Only five
files in the headless graph touch real ones: `main.zig`, `core/state.zig`,
`core/poster.zig`, `player/player.zig`, `services/comics.zig`.

The stub therefore exposes: `App.panic`/`App.logFn` (std fallbacks), `Window`
(opaque), `Texture` + `update`/`destroyLater`, `textureCreate` (fails —
`?Texture` fields just stay null), `textureDestroyLater`, `Color`/`Color.PMA`
(layout must match: `player.zig` allocates frame buffers as `[]Color.PMA`),
`refresh` (no-op), `current_window` (always null), and `c.stbi_*`.

**The one real dependency:** `poster.zig` decodes cover art through
`dvui.c.stbi_load_from_memory`. build.zig compiles dvui's **own** vendored
`vendor/stb/stb_image_impl.c` for the stub, so the decoder is the same source as
the desktop build — no behavior drift.

**Three call sites were comptime-gated** rather than widening the stub (the rule:
prefer `if (build_options.headless) return;` at the caller):

| Call site | Why it is reachable headless |
|---|---|
| `ui/theme.zig applyToDvui` | `coreInit` calls `setTheme()`; it already returned early off the UI thread, now comptime |
| `services/tmdb.zig resetGalleryScroll` | reachable from `fetchDiscover`; pure gallery scroll state |
| `player/media_remote.zig` | `clear()` runs from `appDeinit`; already had an `os.tag != .macos` guard, now `enabled = macos and !headless` |

**Measured (macOS, debug):**

| | desktop | headless |
|---|---|---|
| linked libs | 16 frameworks incl. Cocoa/AppKit/OpenGL/Metal/MediaPlayer | `libmpv`, `libsqlite3`, `libtorrent_wrapper`, `libSystem` |
| binary | 50 MB | 16 MB |

The Docker runtime stage no longer installs `libx11-6 libxext6 libxrandr2 libxi6
libxcursor1 libxfixes3 libxrender1 libpulse0 libasound2 libgl1` (the S0
stopgap), and `docker.yml`'s container smoke **fails the build** if `ldd` ever
shows `sdl|libx11|libxext|libgl|libpulse|libasound` again. That grep is the
acceptance test — if it trips, find what re-introduced the GUI link rather than
reinstating the packages.

Desktop linkage and binary size are unchanged.

## 3. Phase S2 — image hardening

Already in the Dockerfile: multi-stage, `-Dheadless -Doptimize=ReleaseSafe`,
non-root `opal` user, `/config /cache /media` volumes, `HEALTHCHECK /health`,
XDG env. The S0 stopgap packages are **gone** (S1 made them unnecessary), leaving
`libmpv2 libsqlite3-0 libtorrent-rasterbar2.0 ffmpeg` (torrent/stream) and
`python3` (nova2 scrapers). Remaining:
- Confirm `onnxruntime` handling: OCR/AI in a server is optional — decide
  whether to link it in the headless build or `-Docr=false`-style gate it out
  (smaller image). **Open decision, §7.**
- Pin the image to a non-root numeric UID for k8s `runAsNonRoot`.

## 4. Phase S3 — distribution

- **GHCR publish** — `docker.yml` ships `ghcr.io/debpalash/opal:latest|:sha`
  (done). **Left:** make the package public (manual, needs `write:packages`).
- **Multi-arch** — **shipped.** `linux/amd64` + `linux/arm64` build in parallel
  on NATIVE runners (`ubuntu-24.04-arm`), not QEMU: this image compiles the Zig
  app and libtorrent from source, which is exactly where emulated multi-arch
  builds time out. Each arch smoke-tests its own image (including a `uname -m`
  assertion) before anything is published; both push by digest and a single
  merge job stitches them into one manifest list, because two jobs pushing the
  same tag would overwrite rather than join.
- **compose** — `deploy/docker-compose.yml` already points at the image build;
  add a `image: ghcr.io/debpalash/opal:latest` variant for pull-don't-build.

## 5. Phase S4 — web UI: single canonical surface + parity tier 2

**Consolidation (settled in H0):** the web UI is `web/index.html` (single file,
~50 KB, 982 lines) served by `remote.zig` at `:41595/`. The old `web/app/*` Zig
project (`:3000`) is vestigial (`web/app/main.zig` is 13 lines) — **formally
retire it**: delete `web/app`, `web/build.zig*`, keep only `web/index.html`, and
drop any `:3000` references in docs. One process, one port, Jellyfin-shaped.

**Parity tier 2 (H4 carryover):**
- Settings-over-API subset: sources starter-pack install, TMDB key, save path,
  rate limit — full first-run from the browser (routes largely exist:
  `/api/setup{,/sources,/tmdb}`).
- `SSE /events` to replace web-UI polling (shared with the LAN companion).
- Queue reorder in the web UI (the one deferred H3 item; `/api/queue/move`
  exists — the Opal Connect extension already uses it).
- Reverse-proxy guidance: TLS termination, per-device tokens, front-door auth,
  request rate limiting → `docs/headless-deploy.md`.

## 6. Test gates (CI, Linux — the only real validation)

macOS cannot validate the container. Add to `docker.yml` (or a new job) after
the image builds:
1. `docker run -d -p 41595:41595 <img>`; poll `/health` until 200 (start-period
   ≤ 30 s) — **this is the S0/S1 correctness gate that never ran.**
2. First-run `POST /api/auth/register` → assert a session token; then use it
   comes back.
3. `GET /` → 200 + contains the web-app marker.
4. assert `ldd /usr/local/bin/opal` matches no
   `sdl|libx11|libxext|libgl|libpulse|libasound` — **shipped, and it fails the
   build rather than warning.**
Feature suite: every new route keeps its `*_pure.zig` parse test + a
`test_features.py` wiring check (existing discipline).

## 7. Decisions (settled 2026-07-21)

1. **ONNX/OCR:** **off by default** in the server image (`-Docr` already gates it,
   build.zig:220, default off). A `-full` tag can add it later.
2. **mpv:** **keep** in headless (torrent stream/probe path uses it; it needs no
   GUI libs — only SDL/X11/dvui do).
3. **stb_image:** **vendor dvui's stb source** into the headless build — no
   behavior drift vs. repointing poster.zig. ✅ shipped (build.zig compiles
   `dvui_dep.path("vendor/stb/stb_image_impl.c")` into the stub module).
4. **arm64:** **after S1** — the slim build removes the X11 cross-satisfy pain,
   making arm64 cheap. S1 is done; arm64 is the next distribution step.

## 8. Execution order

**S0** (image runs — add .so deps + CI run-gate) → **S1** (slim build: build.zig
gate + dvui stub) → **S2** (drop stopgap deps, harden) → **S3** (multi-arch,
public GHCR) → **S4** (retire `web/app`, parity tier 2). S0 and the S1 audit can
start in parallel; S0 is a same-day unblock, S1 is the architecture work.

## 9. Left to do (this spec's follow-ups)
- **S2:** pin a numeric non-root UID for k8s `runAsNonRoot`; decide the ONNX/OCR
  `-full` tag.
- **S4:** retire `web/app` (parity tier 2 itself is done — 21 verticals).
- **Verify on real hardware:** the arm64 image is CI-smoked but has not been run
  on an actual Raspberry Pi / Apple-silicon server.
- **Server verticals unsmoked:** Plex, Audiobookshelf and OPDS routes are wired
  and answer correctly when unconfigured, but nothing has exercised them against
  a live server.
