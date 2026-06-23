# Opal — Page-Shell Redesign (website-like, chat-first native app)

**Date:** 2026-06-23
**Status:** Design + plan for review (no code yet).
**Builds on:** `2026-06-02-ui-redesign-roadmap.md` (esp. Phase 2 Navigation/IA + Phase 4 Core flows) and the recent calm/amber + compact-settings work on `main`.
**Decision driving this doc:** rebuild the **native** dvui app around a *page/router model* (drop the drawer), with a **chat-first omnibox** as the primary way to navigate, search, and play — "ChatGPT for media."

> Not a greenfield rewrite. We keep the engine (mpv players, torrents, AI servers, `remote.zig` API), the theme tokens, and `components.zig`. We replace the **navigation shell** and the **drawer IA** with pages.

---

## 1. Goal & principles

Turn the app from a *drawer-of-14-tabs over a video grid* into a *website*: a small set of **pages** reached from a top nav + an omnibox, with browser-style **back/forward**, and a **persistent player** so media keeps playing while you browse.

Principles:
- **Omnibox-first.** One input does everything: chat, search, paste-to-play, navigate. (Reuses the existing `ai_intent` pipeline to classify intent.)
- **Pages, not panels.** A single content region swaps full pages; no fixed side drawer.
- **Playback never stops on navigation.** Player is a persistent layer (full page ↔ docked mini-player), Spotify/YouTube-style.
- **Responsive.** Top nav collapses to a bottom tab bar / hamburger below a width breakpoint (reuse the `outer.data().rect.w` idiom already used in settings + grid).
- **Non-breaking, phased.** Land behind a flag; keep the drawer working until pages reach parity. Honor `CLAUDE.md` rules (no rename, `io_global`, single allocator, `id_extra` discipline, calm-flat/amber direction).

---

## 2. Current state (what we replace)

Top-level frame today (`src/main.zig` `appFrame` ~L994–1040):

```
app_box (vertical) → scale(ui_scale)
  if !fullscreen: renderHeader() + renderTabBar()
  main_row (horizontal):
      grid_area (vertical, expand): renderGrid() [mpv players] + lang-learn bar
      drawer.renderDrawer()        [fixed-width right panel]
  if !fullscreen: renderGlobalBottomTray()
  + floating modals (metadata, nsfw, settings-redirect, …)
```

Navigation state (`src/core/state.zig`):
- `DrawerTab = enum { Search, Downloads, TMDB, YouTube, Queue, Comics, Anime, History, RSS, Jellyfin, Plugins, Logs, Settings, AI }` (14, flat) + `drawer_open`, `drawer_tab`.
- Per-section sub-views already exist (`TmdbView`, `JfView`, `settings_tab`).

The drawer content renderers (`drawer.zig`, `settings.zig`, `jellyfin_ui.zig`, …) are **reusable as page bodies** — we change *where/how* they're hosted, not their internals (much).

---

## 3. Information architecture (14 tabs → 6 pages)

| Page (route) | Absorbs today's tabs | Notes |
|---|---|---|
| **Home** | (new) | Hub: continue-watching, recommendations (`/recommendations`), proactive AI greeting, quick links. The landing route. |
| **Search** | Search | Universal results (`/unified_search`): TMDB + torrent + YouTube + jellyfin + anime, grouped. Omnibox feeds it. |
| **Browse** | TMDB, YouTube, Anime, Comics, RSS | Source sub-nav (segmented top tabs within the page). |
| **Library** | Queue, History, Downloads, Jellyfin | Sub-nav: Queue / History / Downloads / Jellyfin. |
| **Player** | (the video grid) | Full playback page; multi-player grid lives here. Mini-player elsewhere. |
| **Assistant** | AI | Full ChatGPT-style conversation. The omnibox is its always-present entry point. |
| **Settings** | Settings | Already compacted + responsive (done). Becomes a page. |
| **System** | Plugins, Logs | Low-traffic; grouped under a "System" route (or a Settings sub-tab). |

Top nav shows the primary set (Home · Search · Browse · Library · Assistant), with Player surfaced via the mini-player and Settings/System via a right-aligned menu. Final grouping is tunable; the router supports any set.

---

## 4. The player problem (the crux for a media app)

Pages swap, but **mpv playback must persist**. Design:

- **Player is a persistent layer**, not a page body. It owns the mpv render region across frames regardless of route.
- **Two presentations**, driven by route + state:
  - **Player route / fullscreen** → the player layer expands to fill the content region (today's grid behavior, multi-player supported).
  - **Any other route while playing** → the player layer renders as a **docked mini-player** (bottom bar: thumbnail of active player + title + transport + "expand"). Browsing continues; audio/video keep going.
- **Active player** drives the mini-player (existing `active_player_idx` guard rules apply). Multi-player grid stays on the Player route for Phase 1; mini-player reflects the active one.
- Fullscreen behavior (`fullscreen_player_idx`) is unchanged — it already bypasses chrome.

This is the single highest-risk area (mpv render region must resize cleanly between full and mini). Prototype this first (see Phase 1).

---

## 5. Navigation shell & routing

**New `Route` model in `state.zig`** (additive; keep `DrawerTab` until migration completes):

```zig
pub const Route = enum { home, search, browse, library, player, assistant, settings, system };
// + a small back/forward history ring:
//   route: Route = .home,
//   route_back: [16]Route, route_back_len, route_fwd: [16]Route, route_fwd_len
//   (fixed buffers per the project's no-alloc state convention)
```

Navigation helpers (pure, testable → candidate for `nav_pure.zig`): `navigate(Route)`, `goBack()`, `goForward()` operating on the rings.

**New shell** replaces the `main_row` split in `appFrame`:

```
app_box (vertical)
  scale(ui_scale)
  TopNav:  [brand] [back][fwd]  [ OMNIBOX (grows) ]  [player-status] [theme] [settings]
  ContentRegion (expand):  renderPage(state.app.route)
  PlayerLayer:  full (route==.player) | mini-player bar (playing & route!=.player) | hidden
  Toasts / floating overlays (unchanged)
```

Responsive: when `content.rect.w < breakpoint`, TopNav collapses links into a bottom tab bar + the omnibox stays; sub-nav segments wrap (the `segment()` flexbox fix already does this).

---

## 6. The omnibox (chat-first spine)

A single persistent input (evolves today's "Paste link, drop file, or ask AI…" box). On submit, classify with the existing **`ai_intent`** pipeline and route:

| Intent | Action |
|---|---|
| URL / file | load into player → navigate `.player` |
| play "X" | resolver → play → `.player` |
| search query | `.search` with results |
| recommendation / browse_genre / nav | `.browse` / `.home` section / contextual nav |
| question / chat | `.assistant` (full conversation), streamed |

Voice (mic) feeds the same omnibox (push-to-talk already works). This makes the assistant the universal driver without forcing users into a chat page.

---

## 7. Migration strategy (non-breaking)

1. Add `Route` + nav helpers + a `feature.page_shell` flag (off by default).
2. Build the shell + Home + Player layer behind the flag; old drawer stays default.
3. Port drawer-tab bodies to page bodies one IA group at a time (Library → Browse → Search → Assistant → Settings/System). Bodies mostly move verbatim (they're already self-contained renderers).
4. When pages reach parity, flip the flag default → on; keep `DrawerTab` paths compiled but unreferenced for one release, then remove.
5. `remote.zig` already mirrors this IA (its routes map 1:1 to pages) — keep the web UI and native pages in sync via the shared API where practical.

---

## 8. Phased plan

| Phase | Scope | Exit criteria |
|---|---|---|
| **P0 · Foundation** | `Route` enum + back/fwd rings (`nav_pure.zig` + unit tests); `feature.page_shell` flag; shell skeleton (TopNav + ContentRegion) rendering a placeholder Home behind the flag. | Flag on → top nav + empty pages navigate; flag off → identical to today. |
| **P1 · Player layer** | Persistent player: full on `.player`, **mini-player** elsewhere; expand/collapse; mpv region resize verified. | Start playback, navigate away → mini-player keeps playing; expand restores full. |
| **P2 · Omnibox routing** | Wire omnibox → `ai_intent` → route table (§6); voice into omnibox. | Typing a link plays; a query opens Search; a question opens Assistant. |
| **P3 · Page bodies** | Port Library, Browse, Search, Assistant, Settings, System from drawer renderers. | All 14 old tabs reachable as pages at parity. |
| **P4 · Polish & responsive** | Bottom-tab collapse, back/forward affordances, empty states, motion, breakpoints; flip flag default on. | Narrow window → mobile-like; drawer removed from default path. |

Each phase: spec-aligned, builds clean, and extends the standard gate (`just test-all`).

---

## 9. Risks & open questions

- **mpv mini-player resize** (P1) — highest risk; prototype before committing to the IA.
- **Multi-player UX** in a page model — Phase 1 keeps the grid on the Player page; richer multi-window UX deferred (roadmap Phase 4).
- **Back/forward semantics** — does "play" push history? Proposal: navigation pushes; transient overlays don't.
- **Top nav vs. left rail** — doc assumes a website-style top nav; a slim left rail is a drop-in alternative if testing shows it navigates better. Router is agnostic.
- **Discoverability** without a drawer — mitigated by Home-as-hub + omnibox + a `?`/command-palette (roadmap Phase 2).

---

## 10. Test plan

Extend `tests/test_features.py` (the standard gate) as pages land:
- `nav_pure.zig` unit tests (navigate/back/forward ring behavior) via `zig build test`.
- Static guards: `Route` enum present; each page has a renderer; omnibox routes through `ai_intent`; `feature.page_shell` flag exists.
- Parity checklist: every former `DrawerTab` maps to a reachable page.
- Player-layer behavior is GUI-only → manual verify note (can't assert headlessly).

---

## 11. Out of scope (for now)

In-browser video streaming (HLS/transcode), full multi-window compositor UX, and replacing the `web/` companion — all deferred. This doc is about the **native** page shell only.
