# Opal — Engineering Analysis

> Generated 2026-05-15 from a deep-read of the codebase at commit `b693ecc`. Findings are specific, not promotional. Update when claims become stale.

---

## Table of contents

1. [Snapshot](#1-snapshot)
2. [Code quality (overall)](#2-code-quality-overall)
3. [UI / UX](#3-ui--ux)
4. [Media pipeline — files, streams, URL routing](#4-media-pipeline--files-streams-url-routing)
5. [Multi-player architecture](#5-multi-player-architecture)
6. [Presentational layer — themes, polish, micro-interactions](#6-presentational-layer--themes-polish-micro-interactions)
7. [Real bugs found while writing this doc](#7-real-bugs-found-while-writing-this-doc)
8. [Prioritized improvement backlog](#8-prioritized-improvement-backlog)

---

## 1. Snapshot

- **~41,300 LOC** of Zig across `src/` (47 service modules, 243 public functions in `services/` alone).
- 13 UI modules, 7 player modules, 47 services, 17 core modules. Web sidecar (`web/`) is a separate Zig project.
- Single binary, single global allocator, single global `state.app`, immediate-mode UI via dvui.
- Native deps: mpv, libtorrent (via C++ wrapper .so), ONNX Runtime, sqlite-vec, SDL2.
- Zig 0.16.x with a project-local `core/io_global.zig` shim wrapping the new `Io` API.

**Verdict in one line.** Genuinely ambitious indie-grade product with real dev-experience polish, weakened by silent error handling, large files, hand-rolled HTTP, and a couple of hard-coded user paths that will break the build for anyone other than the author.

---

## 2. Code quality (overall)

### What's good

- **Memory discipline.** `DebugAllocator` with safety on; leaks reported at shutdown (`Clean shutdown: 0 memory leaks.`). Only **2** `@panic`/`unreachable` in the entire codebase — most Zig projects this size have 20+. That's restraint.
- **Zig 0.16 migration is clean.** [`src/core/io_global.zig`](../src/core/io_global.zig) wraps the new `Io` API with a process-wide threaded io so call sites stay terse. The migration would have been painful without this shim.
- **Pragmatic C++ isolation.** [`src/torrent_wrapper.cpp`](../src/torrent_wrapper.cpp) is compiled into a `.so` and linked dynamically — avoids GCC C++ ABI bleeding into the Zig binary.
- **Real product polish in tooling.** `dev.sh` keeps the old binary alive on build failure; session state survives restart; `just hot` uses native 0.16 `--watch -fincremental`.
- **Recent commits are thoughtful**, not noise: e.g. `dd678eb` (non-blocking search abort by detaching threads + termination checks), `c11b411` (debug log gating, tool-arg sanitization, process-management fix).

### What's not

- **791 silent `catch return` / `catch {}`** sites in `src/`. Some legitimate (mpv property gets, optional reads), but at that volume real bugs are hiding behind them — failures swallowed and reappearing as "why didn't X work?"
- **Files getting large.** [search.zig](../src/services/search.zig) 1,489 LOC, [ai_chat.zig](../src/services/ai_chat.zig) 1,386, [resolver.zig](../src/services/resolver.zig) 1,152, [main.zig](../src/main.zig) 1,101, [settings.zig](../src/ui/settings.zig) 2,805, [footer.zig](../src/ui/footer.zig) 1,192. The `appFrame()` function in main.zig is doing session restore, dropped-file handling, AI orchestration, dialog rendering, layout — splitting it would reduce cognitive load and rebuild surface area.
- **Hand-rolled HTTP server.** [remote.zig:44-69](../src/services/remote.zig#L44-L69) reads a single 4096-byte buffer, no `Content-Length`, no chunked support, no header continuation. Fine for the localhost web UI; fragile under any non-trivial client.
- **Fixed-size buffers** everywhere (`[2048]u8` URLs, `[256]u8` names, `[16][2048]u8` session slots, `[64]ResolvedItem`). Predictable, allocator-friendly — but truncation is silent. A long magnet link (lots of trackers) gets clipped without warning.
- **Bundled feature commits.** e.g. `9da621c` ships "Continue Watching row + subtitle picker + whisper auto-subs + menubar polish" in one commit. Bisect/rollback is worse.
- **Test coverage thin.** 9 test modules. Most service modules can't be tested standalone because of an io-shim cross-boundary issue noted in [`build.zig:197-200`](../build.zig#L197-L200). The `*_pure.zig` sibling pattern (`ai_intent_pure`, `resolver_rank`) is the right answer; it just hasn't been applied to most modules.
- **Global mutable state** (`state.app`, `resolver.results`, `search.search_results`) coordinated by manual mutex discipline. Works, but Zig gives nothing at compile time to enforce "this field is only written by thread X." One careless lock-free write and you have a heisenbug.
- **Naming drift.** Project is "Opal" (README, repo URL); binary, config dir, app name all use `zigzag`; doc comments reference "ZigZag". Cosmetic but signals legacy debt.

---

## 3. UI / UX

### Architecture

- **Immediate-mode** via dvui — entire UI re-rendered every frame from `state.app`. No retained widget tree to keep in sync.
- **Entry point:** `appFrame()` in [main.zig](../src/main.zig). Single function, ~400 lines, dispatches session restore → dropped files → AI events → header → tab bar → grid → drawer → footer → modals.
- **Layer model:** `header` (top, persistent) → `grid` (center, player cells) → `footer` (per-active-player controls + global tray) → `drawer` (right-side, tab-based feature surface) → modals (file-open, save/load workspace, metadata dialog).
- **Tabs in the drawer** are an enum: `Search, Downloads, TMDB, YouTube, Queue, Comics, Anime, History, RSS, Jellyfin, Plugins, Logs, Settings, AI`. 14 tabs is a *lot* — usability red flag below.

### Strengths

- **Cohesive design language.** Glassmorphic surfaces ([`theme.optGlassPanel`](../src/ui/theme.zig#L414)) with box shadows, accent glows, 6-level background depth (`bg_app → bg_header → bg_drawer → bg_surface → bg_card → bg_card_hover → bg_elevated`), 4 padding scales, 4 corner-radius scales — all centralized in one file.
- **Composable option presets.** `theme.optHeader()`, `optCard()`, `optGlowCard()`, `optPill()`, `optFloatingCard()`, `optAccentBtn()` etc. ([theme.zig:378+](../src/ui/theme.zig#L378)) mean a new widget defaults to consistent visuals without copy-paste. This is the right pattern.
- **Real interaction polish.**
  - Single-click → toggle pause. Double-click → fullscreen. ([grid.zig:288-309](../src/ui/grid.zig#L288-L309))
  - Drop a magnet on a player cell → loads into that cell ([grid.zig:310-315](../src/ui/grid.zig#L310-L315)).
  - Auto-mute of background players when active cell changes ([grid.zig:168-185](../src/ui/grid.zig#L168-L185)) — restores per-cell volume on focus. Most multi-pane media apps don't bother.
  - Two-step confirm for "Clear chat" with armed/disarmed visual state ([grid.zig:697-721](../src/ui/grid.zig#L697-L721)).
  - Animated indeterminate loading bar with sliding highlight ([grid.zig:524-547](../src/ui/grid.zig#L524-L547)) and pulsing icon color cycle ([grid.zig:486-493](../src/ui/grid.zig#L486-L493)).
  - "Dead Torrent" detection — 15 s without peers and no metadata triggers a friendly card with a Close button ([grid.zig:357-369](../src/ui/grid.zig#L357-L369)).
  - "Continue Watching" row scrubs filename junk (extension stripping, dot/underscore → space, multi-space collapse) before display ([grid.zig:843-889](../src/ui/grid.zig#L843-L889)). Small touch, big UX win.
- **AI context chip.** "Seeing: <current title>" + phase chip (Listening / Transcribing / Thinking / Speaking) gives the user a feedback loop on what the assistant has as context ([grid.zig:622-690](../src/ui/grid.zig#L622-L690)).
- **Workspaces.** Save/load named player layouts via modal — explicit power-user feature, not just a setting.

### Weaknesses

- **14-tab drawer.** `Search, Downloads, TMDB, YouTube, Queue, Comics, Anime, History, RSS, Jellyfin, Plugins, Logs, Settings, AI` is too many. Most users will memorize 3-4 and ignore the rest. Tabs are flat — no grouping (e.g. "Sources: TMDB/YouTube/Anime/RSS/Jellyfin" + "Library: History/Queue/Downloads"). A collapsible group structure or a command palette would scale better.
- **Modals re-implement chrome.** [`ui.zig:139-339`](../src/ui/ui.zig#L139-L339) renders the Save Workspace and Load Workspace modals with hand-rolled header/body boxes, close-buttons, and styling — duplicated. Should be a `renderModal(title, icon, body_fn, on_close)` helper. There's no reuse cost for two modals; there is for the dozen+ modals across the app.
- **Magic ID extras.** Throughout grid.zig and ui.zig you see `id_extra = mi + 70000`, `id_extra = i + 11000`, `id_extra = si + 43000`. Numerically-spaced id-extras are dvui's escape hatch for collision avoidance — but at this density it means widget identity is fragile and any insertion shifts ids. A constant table (`const ID = struct { const chat_bubble = 70000; ... };`) would make collisions trackable.
- **Inline styling.** Lots of `dvui.Color{ .r=20, .g=20, .b=20, .a=180 }` and `dvui.Rect.all(...)` literals inline instead of `theme.colors.*` / `theme.dims.*` (the very abstraction the codebase built). E.g. [grid.zig:411](../src/ui/grid.zig#L411), [grid.zig:464](../src/ui/grid.zig#L464). Theme switching can't reach them.
- **No keyboard discoverability.** I see keyboard handling in [input.zig](../src/ui/input.zig) but no in-app "?" overlay listing shortcuts. For a power-user app, hidden bindings = lost feature.
- **Responsiveness.** The auto-grid does an O(N) area-maximization to pick column count ([grid.zig:131-159](../src/ui/grid.zig#L131-L159)) — clever — but I see no breakpoint-aware drawer width or font scaling. On a 13" laptop screen with the drawer open, the player cells get squeezed.
- **AI loading icons cycle through only two glyphs** (`loader`, `zap`) with redundant cases ([grid.zig:475-484](../src/ui/grid.zig#L475-L484)) — looks animated at first glance, then reveals as a stutter once you watch it.
- **Toast notifications** show via `state.showToast(...)` and look polished, but I didn't find rate-limiting — a burst of events (e.g. session restore loading 16 items) could spam the screen.

### Verdict on UI/UX

Above-average for an indie app. The interaction polish (drop-target, mute-on-focus, dead-torrent card, filename cleanup) shows real care. The visual language is cohesive and theme-able. The drawback is **scale strain** — 14 tabs, oversized files, duplicated modal chrome, magic ids — none fatal, all paid for later.

---

## 4. Media pipeline — files, streams, URL routing

### Entry points

A media item can enter the app through:

1. **File-open dialog** ([ui.zig:32-137](../src/ui/ui.zig#L32-L137)). On macOS uses `osascript` AppleScript; on Linux uses `zenity`. Runs in a worker thread to avoid blocking the UI. Streams stdout/stderr reads explicitly (not `readAll` — pipe semantics differ).
2. **Drag-and-drop** onto a player cell ([main.zig:739-758](../src/main.zig#L739-L758)). M3U/M3U8 detection routes through the playlist module instead of `load_file` directly.
3. **URL paste** in the omnibar (header → `renderUrlInput`). The header auto-prepends `https://` if no scheme ([browser.zig:523-525](../src/services/browser.zig#L523-L525)).
4. **Magnet drop** on a player cell ([grid.zig:310-315](../src/ui/grid.zig#L310-L315)) — handled by `search.loadTorrentToPlayer`.
5. **Resume from Continue Watching** ([grid.zig:942-955](../src/ui/grid.zig#L942-L955)) — calls `browser.loadContent` with the saved path.
6. **Session restore on launch** ([main.zig:714-747](../src/main.zig#L714-L747)) — replays the last session's URLs paused.
7. **Search result → "play"** — populates and routes through the resolver pipeline.
8. **AI tool call** — e.g. "play the latest episode of X" → resolver → loadContent.
9. **JSON API on :41595** — external callers (web UI, scripts) can issue commands.

That's nine distinct ingestion paths. They all funnel through one central dispatcher: `browser.loadContent`.

### The central dispatcher: `browser.routeContent` → `loadContent`

[`browser.zig:710-800`](../src/services/browser.zig#L710-L800) classifies any URL into one of three providers:

- **`.mpv`** — video/audio extensions (`.mp4 .mkv .avi .webm .flv .mov .m4v .mp3 .flac .ogg .wav .aac .m4a .m3u8 .ts`) or known streaming domains (`youtube.com`, `twitch.tv`, `vimeo.com`, `crunchyroll.com`, ~25 sites including live cam sites for streamlink).
- **`.comic_viewer`** — known comic/manga domains (`mangadex.org`, `webtoons.com`, etc.) or image extensions (`.jpg .png .gif .webp`).
- **`.browser`** — everything else → Camoufox CDP screenshot streaming.

`loadContent` then:

1. Normalizes the URL ([extractors.zig](../src/services/extractors.zig)).
2. If it's a playlist URL → `extractors.extractPlaylist` (separate code path).
3. Sets `p.provider` on the active player.
4. Switches behavior:
   - `.mpv` → `p.load_file()` (libmpv `loadfile` command).
   - `.comic_viewer` → `comics.loadComic()`.
   - `.browser` → Camoufox bridge sends a navigate JSON command.

### Stream handling

| Source                 | How                                                                                            |
| ---------------------- | ---------------------------------------------------------------------------------------------- |
| Local file             | Direct `mpv_command(load_file)`.                                                               |
| HTTP(S) direct         | Same — libmpv handles HTTP.                                                                    |
| YouTube / video sites  | yt-dlp invoked via player; `applyYtdlFormat` ([player.zig:377](../src/player/player.zig#L377)). |
| Magnet / torrent file  | Custom libtorrent wrapper (`torrent_get_name`, `torrent_poll`); piece-priority for early playback. State exposed via `state.app.torrent_ses`. |
| HLS / DASH (`.m3u8/.ts`) | libmpv native.                                                                                |
| Live streams (Twitch / cam sites) | Streamlink subprocess; recording indicator in [grid.zig:427-448](../src/ui/grid.zig#L427-L448). |
| Camoufox (full web)    | Python subprocess bridge ([browser.zig:79-130](../src/services/browser.zig#L79-L130)) — CDP screenshots streamed as JPEG textures. |
| Jellyfin               | API + item-id passed as URL ([services/jellyfin.zig](../src/services/jellyfin.zig), UI in [jellyfin_ui.zig](../src/ui/jellyfin_ui.zig)). |
| Stremio addons         | HTTP via resolver.                                                                             |
| RSS feeds              | [services/rss.zig](../src/services/rss.zig).                                                   |
| Comics / manga         | [services/comics.zig](../src/services/comics.zig) — separate provider with paginated images. |

### Strengths

- **Single dispatcher.** One function (`loadContent`) decides the provider. New ingestion paths only need to produce a URL — they don't need to know about mpv vs. browser vs. comics.
- **Per-pane provider.** Each player cell holds its own provider state — you can have an mpv cell playing a torrent next to a Camoufox cell rendering a web page next to a comic viewer. This is genuinely uncommon.
- **Buffering UI is data-driven.** Torrent buffer % / DL rate / peers polled every frame from the wrapper and reflected in a glass overlay ([grid.zig:341-381](../src/ui/grid.zig#L341-L381)).
- **Watch history with auto-resume.** `tryResumePosition` on first frame ([player.zig:318](../src/player/player.zig#L318)); periodic position save every ~120 frames ([player.zig:275-277](../src/ui/grid.zig#L275-L277)).
- **Subtitle and chapter integration.** Chapter list with mm:ss + titles ([footer.zig:14-73](../src/ui/footer.zig#L14-L73)). Auto-subs via Whisper ([services/auto_subs.zig](../src/services/auto_subs.zig)).
- **Recording.** Streamlink-based capture with a pulsing REC indicator overlay.

### Weaknesses

- **URL classification is brittle.** `routeContent` is a hard-coded domain/extension list. New sites = code change. A pluggable extractor registry would be more maintainable.
- **Magnet detection is implicit.** A magnet doesn't match any case in `routeContent` so it falls through to `.browser` — only the *drop path* (`search.loadTorrentToPlayer`) and the URL-bar shortcut handle them. If a user pastes `magnet:?xt=...` into the omnibar it may not route correctly without an explicit pre-check.
- **No streaming-engine pluggability.** Adding "support Plex" or "support Emby" means modifying the dispatcher, not registering an extractor.
- **Camoufox bridge has hard-coded user paths** (see Bugs section).
- **No global cancel/back.** Once a torrent is loading, the only ways out are the "Close Stream" button inside the dead-torrent card or removing the cell — there's no universal "cancel current load" gesture.
- **m3u parsing is minimal** ([m3u.zig](../src/player/m3u.zig) is 182 LOC) — extended M3U directives (`#EXTINF`, `#EXTGRP`, `#EXT-X-VERSION`, etc.) coverage isn't obvious.

---

## 5. Multi-player architecture

This is one of the more interesting parts of Opal.

### Core idea

Multiple `MediaPlayer` instances live in `state.app.players`. Each holds its own mpv context, its own pixel buffer, its own browser state, its own torrent state. The UI lays them out in a grid; one is the *active* player (receives controls), the rest are muted but still rendering.

### Layout — auto vs manual

`computeGridColumns` ([grid.zig:125-166](../src/ui/grid.zig#L125-L166)) picks the column count:

- **Manual modes:** `cols_1`, `cols_2`, `cols_3`, `cols_4`.
- **Auto:** an area-maximizing search. For each candidate column count 1..N, compute cell width / height, fit 16:9 within it, pick the column count that maximizes visible video area. Clean and correct.

A fullscreen index (`state.app.fullscreen_player_idx`) overrides — that one cell takes the whole grid.

### Active-cell focus model

- Clicking any cell sets `state.app.active_player_idx`.
- Double-click toggles fullscreen.
- `muteBackgroundPlayers` ([grid.zig:168-185](../src/ui/grid.zig#L168-L185)) runs once per active-cell change, not per frame: restores the active cell's saved `cell_volume`, mutes all others. Each cell has its own persisted volume — switching focus restores it.
- Active cell gets a top-only 2px accent border ([grid.zig:206-213](../src/ui/grid.zig#L206-L213)).

### Per-cell features

- Independent **volume**, **speed**, **A-B loop**, **rotation**, **flip**.
- Independent **browser state** (URL, navigation history of 32 entries, link list of 128).
- Independent **provider** (`mpv` / `comic_viewer` / `browser`) — a cell can be any one at runtime.
- Independent **resume position** persisted to disk.
- Optional **cell-close X** in the top-right corner ([grid.zig:399-422](../src/ui/grid.zig#L399-L422)).

### Background rendering

A subtle but important detail in [grid.zig:225-240](../src/ui/grid.zig#L225-L240): even when a cell's provider isn't `.mpv`, the code still calls `mpv_render_context_update` and runs a render to drain the frame queue. Without this, mpv backpressure would stall after a few frames. This is exactly the kind of "I learned this the hard way" detail that doesn't appear in tutorials.

### Strengths

- **True heterogeneous panes.** Watch a torrent next to a web page next to a manga reader. Most multi-pane media apps only do multi-video.
- **Volume-on-focus.** A practical UX win — feels natural, no need to mute manually.
- **State-clean fullscreen.** Just an `?usize` field — no separate layout mode to maintain.

### Weaknesses

- **No PIP / floating windows.** Multi-player is always grid-tiled in the main window. No detach-this-cell-to-its-own-window.
- **No cross-cell sync.** Watch parties exist as a separate service ([watch_party.zig](../src/services/watch_party.zig)) but there's no in-process "sync these two local cells" — useful for A/B comparing the same video with different subtitles.
- **No master volume separate from cell volumes.** A global mixer slider is missing.
- **No cell-titles in the layout.** Cells are identified visually by the content; no overlaid label "Cell 2 — The Matrix" when multiple panes are playing similar-looking material.
- **Fixed-size browser history per cell** (`[32][2048]u8` = 64 KB per cell) — fine for 4 cells, but the structure scales linearly.

---

## 6. Presentational layer — themes, polish, micro-interactions

### Theme system

7 named presets, each a fully-specified `ThemeColors` struct (~30 color slots):

| Preset      | Accent          | Mood                  |
| ----------- | --------------- | --------------------- |
| `midnight`  | muted sky       | cool slate (default)  |
| `abyss`     | muted green     | pure black AMOLED     |
| `phantom`   | muted violet    | purple-tinted         |
| `nord`      | muted frost     | nord palette          |
| `solarized` | muted orange    | solarized dark        |
| `rose`      | muted rose      | dark rose             |
| `ember`     | muted amber     | dark warm             |

- Switch with `theme.setPreset(...)` ([theme.zig:303](../src/ui/theme.zig#L303)) — applies, persists via `state.markConfigDirty()`, re-applies to dvui's global theme.
- `theme.cycleTheme()` rotates through all presets.
- The palette is opinionated — every accent is *muted* rather than fully saturated. That's a real visual-design decision, not a default.

### Composable option presets

`theme.zig` exposes ~16 ready-made `dvui.Options` builders:

```
optHeader, optDrawer, optCard, optGlassPanel, optInput, optIconBtn,
optIconBtnDanger, optAccentBtn, optIconBtnAccent, optBadge,
optMutedLabel, optDimLabel, optPill, optFloatingCard, optDivider,
optSearchInput, optSurfaceCard, optGlowCard, optBtnGroupSep
```

This is the **single most polished aspect of the codebase**. Most Zig GUI apps end up with ad-hoc styling everywhere. Opal centralized it.

### Micro-interactions that punch above their weight

- **Pulsing loading bar with sliding highlight** ([grid.zig:524-547](../src/ui/grid.zig#L524-L547)).
- **Color-pulse on icons** during loading ([grid.zig:486-493](../src/ui/grid.zig#L486-L493)).
- **Recording REC pulse** with a red-tinted badge in cell top-left.
- **Dead-torrent detection** with timeout + actionable Close button.
- **Two-stage Clear Chat confirm.**
- **Continue Watching name scrubber** (file extension strip, dot→space, multi-space collapse).
- **"Seeing: <title>" AI context chip** so the user knows what the assistant has as context.
- **Phase status chip** (Listening / Transcribing / Thinking / Speaking) with color per phase.

### Where presentation cracks

- **Inline color literals.** Lots of `dvui.Color{ .r=22, .g=22, .b=32, .a=200 }` and `.r=40, .g=40, .b=55` *inside* grid.zig and ui.zig — code that should have used `theme.colors.bg_card` or similar. These literals won't respond to theme switching. Audit and refactor.
- **Inconsistent corner-radius use.** `theme.dims.rad_md` exists but you'll also see `dvui.Rect.all(6)`, `dvui.Rect.all(8)`, `dvui.Rect.all(10)` ad-hoc.
- **Mixed iconography.** Lucide icons via the `icons` package are used throughout, but the codebase still has stray emoji (📖, 🎵, ⏳, ❌, ●). For a polished native app I'd pick one and commit. Emoji renders differently on different platforms.
- **No empty-state design system.** Each empty state ("No workspaces yet", "Drop media or paste a URL", "Continue Watching" with 0 entries) is hand-rolled with slightly different vertical rhythm.
- **No motion system.** All animation is hand-coded `@mod(t, period)` in the consuming widget. No reusable easing helper. The Bezier ease-in-out blink that the loader does ([grid.zig:524-530](../src/ui/grid.zig#L524-L530)) should be one library function.

### Verdict on presentation

**Top-of-class for an indie native app**, marred by inline literals and emoji mixed with icons. The base layer (theme presets, options builders) is excellent — what's missing is one more pass to *use* it everywhere.

---

## 7. Real bugs found while writing this doc

1. **Hard-coded user paths in [browser.zig:27](../src/services/browser.zig#L27) and [browser.zig:60](../src/services/browser.zig#L60)**:
   ```zig
   const VENV_PYTHON   = "/home/pal/.config/zigzag/venv/bin/python3";
   const BRIDGE_SCRIPT = "/home/pal/Documents/stuffs/cmr/zigzag/scripts/camoufox_bridge.py";
   ```
   These break for any user not named `pal`. `core/paths.zig` exists precisely to fix this — use `paths.configDir(...)` and a relative script lookup.

2. **Session-restore loadfile noise (fixed this session).** Missing files from a previous session now skipped before calling `mpv_command(loadfile)` — see [main.zig:719-731](../src/main.zig#L719-L731).

3. **`remote.zig` first-line comment lies.** Says `API bridge on :9876, Web UI (Ziex) on :3000` but actual port is `41595` ([remote.zig:13](../src/services/remote.zig#L13)). Cosmetic but confusing.

4. **HTTP body assumption.** [remote.zig:44-47](../src/services/remote.zig#L44-L47) reads one 4096-byte buffer and treats it as the whole request. A larger POST body silently truncates.

5. **Spinner has only 2 distinct icons.** [grid.zig:475-484](../src/ui/grid.zig#L475-L484) maps 8 phases to two icons (`loader` and `zap`) in duplicated pairs — the "animation" is actually a 1-Hz blink, not the spin it visually suggests.

6. **Inline color literals defeat theme switching.** e.g. `bg_card` literal `{ .r=22, .g=22, .b=32, .a=200 }` in [grid.zig:903](../src/ui/grid.zig#L903) and many other places — `rose`/`ember`/`nord` themes won't reach them.

---

## 8. Prioritized improvement backlog

> Ordered by leverage (impact ÷ effort), highest first.

### Tier 1 — quick wins, big payoff

1. **Fix the `/home/pal/...` hardcodes in `browser.zig`.** ~10 minutes. Currently makes the Camoufox feature unusable for anyone but the author. Use `paths.configDir(...)` + relative `scripts/camoufox_bridge.py` lookup.
2. **Audit silent error handlers.** Pick the 50 highest-traffic `catch return` / `catch {}` sites and at minimum add `logs.pushLog("warn", ...)` to surface failures.
3. **Replace inline color/radius literals with `theme.*`.** Grep for `dvui.Color{` in `src/ui/*.zig` and `src/services/*.zig`; route through the existing tokens. Restores theme-switching coverage.
4. **Update `remote.zig` comment.** Fix `:9876 / Ziex` → actual `:41595`.
5. **Spinner fix.** Replace the duplicated phase mapping with `lucide.loader` rotated by `@mod(t, 360)` degrees, or pick 6-8 truly distinct frame icons.

### Tier 2 — structural, ~1 week each

6. **Split `main.zig`'s `appFrame()`** into named phase functions. Same behavior, massive readability + incremental-build win.
7. **Replace the hand-rolled HTTP parser in `remote.zig`** with `std.http.Server` (or a minimal proper parser that respects `Content-Length`).
8. **Add `*_pure.zig` siblings** for the next 5 highest-traffic service modules so they become testable.
9. **Extractor / route plugin registry.** Replace the hard-coded site list in `routeContent` with a registration API; lets users add new sources without recompiling the dispatcher.
10. **Modal helper.** `renderModal(title, icon, body_fn, on_close)` to kill the duplicated header/body chrome across the dozen+ modals.

### Tier 3 — UX investment

11. **Command palette / fuzzy global search.** Single keystroke to find any tab, any setting, any history item. Solves the 14-flat-tab problem more elegantly than tab reorganization.
12. **Keyboard shortcut overlay.** `?` shows a floating panel listing all bindings, grouped by context.
13. **Drawer tab grouping.** Cluster the 14 tabs into "Sources / Library / System".
14. **Toast rate-limiting.** Coalesce duplicate toasts; cap concurrent count.

### Tier 4 — strategic

15. **Detach-to-window for cells.** Real picture-in-picture / floating windows. The single-window grid is limiting once you have 3+ cells.
16. **Cross-cell sync** (local watch-party-on-self). Useful for subtitle A/B and re-encode comparison.
17. **Plugin / extractor API surface** documented in the docs/ folder so contributors can ship a new source without touching core.

---

*End of analysis.*
