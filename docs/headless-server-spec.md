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
| H1 | Dockerfile builds `-Dheadless`, non-root, healthcheck, volumes | **Builds green on GHCR** (my `docker.yml` + `.dockerignore` fix) |

**One codebase, ~one port, mostly built.** The gaps below are what remain.

## 2. The blocker: the `-Dheadless` binary is not actually GUI-free

`build.zig:96-104` still links dvui + SDL2 into the headless build ("full
dvui/SDL removal is follow-up; keep linked so the binary still runs"). dvui
bundles a **static** `libSDL2.a` that **dynamically** references
`libX11.so.6`, `libXext.so.6`, `libpulse.so.0` (confirmed in the GHCR build's
LLD output). The runtime image installs **none** of these.

**Consequence:** the container binary very likely fails at exec with
`libX11.so.6: cannot open shared object file`. H2/H3 were validated against the
*macOS* headless binary (works — macOS uses bundled frameworks); the actual
Linux container has never been run. **This must be fixed before the image is
usable.**

Two fixes, sequenced:

### Phase S0 — make the image run *today* (unblock, ~1 line)
Add the transitive `.so` deps to the runtime stage so the current fat binary
loads:
```dockerfile
# runtime stage apt list, until the slim build lands (Phase S1):
libx11-6 libxext6 libpulse0 libasound2
```
Then **verify in CI** the container actually starts and answers `/health` (see
§6). This is the correctness gate that was never run.

### Phase S1 — slim build: link no dvui/SDL/X11 (the real fix)
Make `-Dheadless` produce a binary with zero GUI linkage.

**build.zig changes** (`b.option "headless"` already exists at line 7):
```zig
if (!headless) {
    exe.root_module.linkSystemLibrary("SDL2", .{});           // ~line 99
    exe.root_module.addImport("dvui", dvui_dep.module("dvui_sdl2")); // ~line 104
} else {
    exe.root_module.addImport("dvui", b.createModule(.{
        .root_source_file = b.path("src/core/dvui_headless.zig"), // the stub
    }));
}
```
The stub (`src/core/dvui_headless.zig`) exposes only the dvui surface the
**headless-reachable** graph references. Windowed-only files (`ui/*`, grid,
drawer, header, footer, settings, `appFrame`) are simply never compiled in the
headless build because `headlessEntry` never references them — Zig only compiles
reachable code.

**Stub surface (audited — final).** 34 files import dvui, but the split is
favorable:
- **~30 service/UI-helper modules** (`search`, `tmdb`, `anime`, `youtube`,
  `queue`, `jellyfin`, `rss`, `logs`, `playlist`, …) touch dvui only inside
  *render* functions headless never calls. Zig's lazy per-decl analysis skips
  them entirely — they need the `dvui` module to **exist**, but **zero** stub
  symbols.
- **All of `ui/*`** plus `main.zig`'s `appFrame`/`appInit`/`dvui_app` are
  **never referenced** by the headless entry (`main == headlessEntry`), so they
  aren't compiled at all.
- **Only 4 files** sit in the guaranteed-compiled headless graph and force real
  dvui symbols: `main.zig` (top-level), `core/state.zig`, `core/poster.zig`,
  `player/player.zig`.

The stub (`src/core/dvui_headless.zig`) must therefore expose exactly **8
top-level names / ~14 symbols**:

| # | Symbol | Used by | Stub form |
|---|--------|---------|-----------|
| 1 | `App.panic`, `App.logFn` | `main.zig` `pub const panic` / `std_options.logFn` | real fns; **signatures must match** `root.panic` / `std.Options.logFn` (confirm against pinned dvui) — logFn → plain stderr |
| 2 | `Window` | `state.dvui_win: ?*dvui.Window` | opaque type (`opaque {}`) |
| 3 | `Texture`, `Texture.update(...)` | `state`/`player` texture fields | type + no-op method |
| 4 | `textureCreate(...)` | `poster.zig` | no-op returning a dummy `Texture` |
| 5 | `textureDestroyLater(...)` | `poster.zig` | no-op |
| 6 | `Color.PMA` (type), `Color.PMA.black` | `poster`/`player` pixel buffers | `extern struct { r,g,b,a: u8 }` + const |
| 7 | `refresh(win, src, id)` | worker-thread UI pokes (`state`, `poster`, `player`, `suwayomi_server`) | no-op |
| 8 | `c.stbi_load_from_memory`, `c.stbi_image_free` | `poster.zig` bg image decode | **the only non-trivial part** — see below |

**The one real decision (item 8):** `poster.zig` decodes images through dvui's
bundled stb_image. The stub's `c` namespace must therefore either **(a) vendor a
tiny `stb_image.h` compile** into the headless build (dvui already ships it —
reuse the same source), or **(b) repoint `poster.zig` at its own decoder**.
Recommend **(a)** — smallest change, no behavior drift. Also: `detectResourceRoot`
(`main.zig:245`) calls `c.sdl.SDL_GetBasePath` — guard it behind
`if (!build_options.headless)` (headless resolves the resource root from cwd/XDG
anyway).

**Fallback:** if compiling `-Dheadless` against the stub reveals a
`remote.zig`-reachable *data* function that transitively calls a dvui *widget*
(the audit found none, but it's only provable by building), comptime-gate that
call behind `if (!build_options.headless)` rather than widen the stub.

**Acceptance:** `zig build -Dheadless=true` produces a binary whose `ldd` shows
**no** libSDL2/libX11/libXext/libpulse; the stub is ~40–60 lines; desktop build
byte-identical to today; `zig build test` + `test_features.py` stay 0-fail.

## 3. Phase S2 — image hardening (mostly done; finish after S1)

Already in the Dockerfile: multi-stage, `-Dheadless -Doptimize=ReleaseSafe`,
non-root `opal` user, `/config /cache /media` volumes, `HEALTHCHECK /health`,
XDG env. Remaining:
- After S1, **remove** `libx11-6 libxext6 libpulse0 libasound2` (S0's stopgap)
  from the runtime stage; keep `libmpv2 libsqlite3-0 libtorrent-rasterbar2.0
  ffmpeg` (still used by torrent/stream) and `python3` (nova2 scrapers).
- Confirm `onnxruntime` handling: OCR/AI in a server is optional — decide
  whether to link it in the headless build or `-Docr=false`-style gate it out
  (smaller image). **Open decision, §7.**
- Pin the image to a non-root numeric UID for k8s `runAsNonRoot`.

## 4. Phase S3 — distribution

- **GHCR publish** — `docker.yml` ships `ghcr.io/debpalash/opal:latest|:sha`
  (done). **Left:** make the package public (manual, needs `write:packages`).
- **Multi-arch** — add `linux/arm64` to `docker/build-push-action` `platforms`
  (Raspberry Pi / Apple-silicon servers). Needs QEMU or native arm runners;
  the slim build (S1) makes arm64 far cheaper (no X11 stack to satisfy).
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
4. (S1) assert `ldd /usr/local/bin/opal | grep -E 'X11|SDL' == ∅` inside the
   image.
Feature suite: every new route keeps its `*_pure.zig` parse test + a
`test_features.py` wiring check (existing discipline).

## 7. Decisions (settled 2026-07-21)

1. **ONNX/OCR:** **off by default** in the server image (`-Docr` already gates it,
   build.zig:220, default off). A `-full` tag can add it later.
2. **mpv:** **keep** in headless (torrent stream/probe path uses it; it needs no
   GUI libs — only SDL/X11/dvui do).
3. **stb_image (§2 item 8):** **vendor dvui's stb source** into the headless
   build — no behavior drift vs. repointing poster.zig.
4. **arm64:** **after S1** — the slim build removes the X11 cross-satisfy pain,
   making arm64 cheap.

## 8. Execution order

**S0** (image runs — add .so deps + CI run-gate) → **S1** (slim build: build.zig
gate + dvui stub) → **S2** (drop stopgap deps, harden) → **S3** (multi-arch,
public GHCR) → **S4** (retire `web/app`, parity tier 2). S0 and the S1 audit can
start in parallel; S0 is a same-day unblock, S1 is the architecture work.

## 9. Left to do (this spec's follow-ups)
- Confirm `App.panic` / `App.logFn` signatures against the pinned dvui dep so
  the stub matches (§2 item 1).
- Decide §2 item 8 (vendor stb_image vs. repoint poster.zig) and §7 items
  (OCR gate default, keep mpv, arm64 timing).
- Land S0 + CI run-gate first (proves the image actually works) before S1.
