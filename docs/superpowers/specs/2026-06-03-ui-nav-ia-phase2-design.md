# Opal UI Redesign — Phase 2: Navigation & IA (Design Spec)

**Date:** 2026-06-03
**Status:** Specced; awaiting plan execution.
**Phase:** 2 of 4 (see `docs/superpowers/specs/2026-06-02-ui-redesign-roadmap.md`).
**Builds on:** Phase 1 (`docs/superpowers/plans/2026-06-02-ui-foundation-phase1.md`) — the calm-flat primitive set in `src/ui/components.zig` and hardened tokens in `src/ui/theme.zig` / `src/ui/ids.zig` are now landed and are the building blocks for everything below.
**Plan:** `docs/superpowers/plans/2026-06-03-ui-nav-ia-phase2.md`

> Continues the locked v2 direction. This is **not** a greenfield redesign and does not relitigate the calm/amber, whitespace-defined, card-chrome-gone direction. Phase 2 serves roadmap priority ② **Clarify hierarchy & IA**: *structure before surface.*

---

## 1. Scope (inherited from the roadmap Phase 2 row)

| Item | Roadmap source | This phase |
|---|---|---|
| Group the drawer tabs (Sources / Library / System) | Phase 2 row; analysis §3 | **Yes — Task 1** |
| Command palette | analysis §8 Tier 3 #11 | **Yes — Tasks 5–6** |
| `renderModal` unification | Tier 2 #10 | **Yes — Tasks 2–4** |
| `?` shortcut overlay | Tier 3 #12 | **Yes — Task 7** |
| Split `settings.zig` into `_root` + per-tab modules with card hierarchy | V2-ROADMAP Wave 2 #6 | **Deferred — Task 8, flagged high-risk / needs-approval.** The safe tasks (1–7) land independently. |

**Non-goals this phase** (per roadmap "Out of scope" + "structure before surface"): no broad inline-literal sweep, no spinner/empty-state/motion passes (Phase 3), no new theme presets, no responsive breakpoints (Phase 4), no `footer.zig` dropdown→`components.menu` migration (Phase 3 hotspot pass).

---

## 2. Current-state findings (real file:line references)

### 2.1 Drawer tabs: 14, flat enum, visually grouped but not data-grouped

- The tab set is a flat enum: `src/core/state.zig:17`
  `DrawerTab = enum { Search, Downloads, TMDB, YouTube, Queue, Comics, Anime, History, RSS, Jellyfin, Plugins, Logs, Settings, AI }` — **14 tabs**.
- The rail in `src/ui/drawer.zig:189-211` *already* visually clusters them into three comment-labelled groups with `railGroupGap()` separators:
  - **"Find & Manage"** (`drawer.zig:189-194`): Search, Downloads, Queue, History
  - **"Sources"** (`drawer.zig:197-203`): TMDB, YouTube, Anime, Comics, RSS, Jellyfin
  - **"Configure"** (`drawer.zig:207-210`): AI, Plugins, Settings
- Bottom-rail group (`drawer.zig:216-233`): Logs (Console), Expand, Close — handled via `BottomAction` union (`drawer.zig:363-367`), not the tab enum.
- The grouping today is **comments + `railGroupGap(id)`** (`drawer.zig:351-359`), each gap a 16px (`GROUP_GAP = theme.spacing.lg`) blank box. There is **no named group abstraction**: a reader/maintainer can't query "which group is this tab in," and the body-routing `switch` (`drawer.zig:248-264`) is an independent flat list. The roadmap's requested **Sources / Library / System** taxonomy is close to but not identical to the in-code "Find & Manage / Sources / Configure" labels.
- `renderRailTab` (`drawer.zig:277-347`) and `railGroupGap` (`drawer.zig:351-359`) are the load-bearing helpers; magic id offsets (`id + 1000`, `id + 3000`, `id + 5000`, `id + 9000`) live here and overlap the new `ids.zig` family bases conceptually (Phase 1 added `grid_cell`/`search_item`/`chat_bubble` only — drawer offsets are not yet centralized).

### 2.2 Hand-rolled modal chrome (the unification target)

Four floating windows re-implement title-bar + close-X + frame by hand instead of using `components.modal`:

- **Save Workspace modal** — `src/ui/ui.zig:145-248`. Hand-rolls: `dvui.floatingWindow(.modal=true, .open_flag=&state.app.ws_save_open)` (`ui.zig:146-155`), a header box with icon + `" Save Workspace"` label + spacer + close-X `buttonIcon` (`ui.zig:159-189`), then a body. Uses **legacy tokens**: `theme.colors.bg_drawer`, `theme.colors.border_card`, `theme.colors.bg_header`, `theme.colors.text_main`, `theme.colors.text_muted`, inline `corner_radius = dvui.Rect.all(12)`.
- **Load Workspace modal** — `src/ui/ui.zig:253-338`. Same hand-rolled header pattern (`ui.zig:267-297`).
- **Stream-Key popover** — `src/ui/header.zig:420-471`. Uses `dvui.windowHeader(...)` (`header.zig:431`) — a *different* chrome path than the workspace modals, so chrome is inconsistent across the app.
- **Cheat-Sheet** — `src/ui/settings.zig:2110-2240`. Also `dvui.windowHeader(...)` (`settings.zig:2123`), legacy `border_drawer` token, 1.4× `dvui.scale`.

`components.modal(src, title, *bool) ?Modal` (`components.zig:807-841`) was authored in Phase 1 *specifically* to replace this: it draws the calm frame + title + close-X and flips `open.*` via dvui's `open_flag`. The workspace modals are the cleanest first conversion (self-contained bodies, boolean open flags `state.app.ws_save_open` / `state.app.ws_load_open` already exist in state).

### 2.3 `?` / shortcut discoverability

- A shortcut overlay **already exists**: `renderCheatSheet()` (`settings.zig:2110-2240`), gated by `state.app.cheatsheet_open` (`state.zig:169`), dispatched at `main.zig:1051`.
- It is opened only via **Shift+I** (`input.zig:204-205`) and the header "info" icon (`header.zig:284-286`). The conventional **`?`** key is **not bound** — the roadmap's "`?` shortcut overlay" is therefore an *addition of the `?` keybinding* onto the existing overlay, plus a calm-flat re-skin, **not** a new overlay from scratch.
- The keymap that the overlay documents lives in `input.zig:20-465` (`processGlobalInputs`). The overlay's literal shortcut table is hardcoded in `settings.zig:2129-2176`; it is presentation-only and currently uses legacy tokens (`theme.colors.accent`, `theme.colors.text_main`).

### 2.4 No command palette today

- There is no command-palette state, render function, or keybinding anywhere (`grep` for `command_palette` / `palette` returns nothing). The closest existing fuzzy-filter UI is the **settings search** (`settings.zig:116`, `searchInput` + `matchesSearch`/`sectionMatchesSearch` at `settings.zig:134-171`) — a good local precedent for a filtered list driven by a text buffer.
- The unified input box (`input.zig:484-703`) already routes free text to AI vs. media; a palette is a *navigation* surface (jump to a drawer tab / run a chrome action), distinct from that content router. Ctrl/Cmd+K is free (no binding in `input.zig`).

### 2.5 settings.zig is the 2.6k-line wall (deferred split)

- `src/ui/settings.zig` is **2767 lines** and owns: the settings modal+content (`renderSettingsModal` `settings.zig:58`, `renderSettingsContent` `settings.zig:72`), AI content (`renderAIContent` `settings.zig:297`), the cheat sheet (`settings.zig:2110`), deps modal (`settings.zig:2246`), media info (`settings.zig:2693`), the 8-tab nav (`nav_tabs` `settings.zig:120-132`, `SettingsTab` `state.zig:18`), and every per-tab section renderer.
- Splitting into `settings_root.zig` + per-tab modules is a **large, mechanical-but-risky** refactor touching one of the highest-traffic files and its many `@import("settings.zig")` callers (drawer body routing `drawer.zig:261-263`, `main.zig:1049-1052`). It is **deferred to a single optional final task** so the additive tasks ship first.

---

## 3. Target IA

### 3.1 Drawer group taxonomy (Sources / Library / System)

Replace the three comment-only clusters with a **named group model** that *both* the rail and (optionally) a palette can read. Mapping the 14 tabs to the roadmap's taxonomy:

| Group | Tabs | Rationale |
|---|---|---|
| **Sources** | Search, TMDB, YouTube, Anime, Comics, RSS, Jellyfin | Where content is discovered/pulled in. (Search is content discovery → Sources.) |
| **Library** | Downloads, Queue, History | What the user already has / is acquiring / has watched. |
| **System** | AI, Plugins, Settings, Logs | Configuration + diagnostics. (Logs moves into the named model but stays rendered in the bottom rail.) |

This is a **superset-compatible re-label** of today's clusters: it keeps the same `railGroupGap` visual rhythm, just sourced from a `const DrawerGroup` table instead of inline comments. The body-routing `switch` (`drawer.zig:248-264`) is unchanged (additive: the group table drives only rail layout). **No `DrawerTab` enum reorder** (reordering risks config-persistence drift via `@intFromEnum`); the group table references existing enum tags by name.

### 3.2 Modal chrome: one primitive

All four hand-rolled modals converge on `components.modal(@src(), title, open)` (`components.zig:807-841`):
```
if (components.modal(@src(), "Save Workspace", &state.app.ws_save_open)) |*m| {
    // body…
    m.deinit();
}
```
The primitive owns the frame (calm `bg_surface` + 1px `border_subtle` + `rad_lg`), the title bar, and the close-X. Bodies keep their existing widgets; only the surrounding chrome is deleted. Phase 2 converts the **two workspace modals** (lowest risk) and the **cheat sheet** (Task 7 re-skin). The stream-key popover is left for Phase 3 (it uses `windowHeader` drag-area behavior that `components.modal` does not yet model — out of scope to avoid regressing the drag affordance).

### 3.3 Command palette

A new calm-flat overlay: a top-anchored `dvui.floatingWindow` (modal, `open_flag`) containing a `components.searchInput` + a filtered `components.listItem` list. Entries are **navigation commands** (jump to each of the 14 drawer tabs + a few chrome actions: Cycle Theme, Toggle Drawer, Open File, Keyboard Shortcuts). Selecting an item performs its action and closes the palette. State is a single ephemeral module-local struct (mirroring `HeaderState` in `header.zig:58-60`), opened by **Ctrl/Cmd+K** and **Esc**-closable via the existing staged-close chain (`input.zig:31-43`).

### 3.4 `?` overlay

Bind **`?`** (Shift+/ ⇒ `dvui.enums.Key.slash` with `mod.shift()`) to toggle `state.app.cheatsheet_open` in `processGlobalInputs` (`input.zig`), alongside the existing Shift+I. Re-skin `renderCheatSheet` (`settings.zig:2110`) onto calm tokens (`text_primary`/`text_secondary`/`accent_primary`, `theme.transparent`) — a presentation-only edit, no behavior change.

---

## 4. Decisions

1. **Group model is a data table, not an enum reorder.** A `DrawerGroup` struct + `groups: []const DrawerGroup` table in `drawer.zig` (or a new tiny `drawer_groups.zig`) references existing `state.DrawerTab` tags. Zero enum churn ⇒ zero config-migration risk.
2. **Modal unification is incremental and reversible.** Convert one modal per task; each is independently buildable and the legacy hand-rolled version is preserved in git history. Stream-key popover explicitly excluded (drag-area behavior).
3. **`?` reuses the existing cheat sheet.** No second overlay; we add a keybinding + a calm re-skin. This avoids divergence between two shortcut lists.
4. **Command palette is navigation, not content.** It does not touch the unified input router (`input.zig:484`). It is additive: a new file `src/ui/command_palette.zig` + one dispatch line in `main.zig` + one keybind in `input.zig`.
5. **settings.zig split is a separate, approval-gated task.** Everything else ships without it.

---

## 5. Locked design direction (inherited — applies to every task)

- **Calm-flat surfaces:** subtle borders + whitespace; **no drop shadows** except true floating overlays (the palette/modals are overlays, so they may use the single `theme.shadow_overlay` token if desired — but default to border-only to match Phase 1's modal).
- **Muted amber-default accent:** use `theme.colors.accent_primary` via the `tk.*` accessors; never inline accent literals.
- **Non-breaking by default:** new state fields, new files, and the group table are additive; legacy modal bodies are *replaced in place* (no API break, the open-flag booleans are unchanged).
- **Constraints:** `io_global` wrappers (not `std.fs`/`std.time`); single global allocator (`@import("../core/alloc.zig").allocator`); `id_extra` discipline for any looped widget; **no `zigzag`→`opal` rename**; pure-Zig tests only off the `io_global` boundary. (Note: no `CLAUDE.md` exists at repo root on this branch; these constraints are sourced from the roadmap §Constraints.)

---

## 6. Verification environment (for the plan's executors)

- **Build green** = `zig build` exits **rc 0**. Benign noise to ignore: SDL2 `ld.lld … neither ET_REL …` warnings and a cosmetic `compile exe zigzag Debug native failure` label. Only a **nonzero exit** or Zig `error:` lines are real failures.
- **RENDER-SMOKE:** `timeout --preserve-status 5 env DISPLAY=:1 ./zig-out/bin/zigzag > /tmp/zz.log 2>&1 || true` then `grep -vi "0 memory leaks" /tmp/zz.log | grep -ci "error\|panic\|leak"` ⇒ expect **0**. No foreground `sleep`/busy-loops (the harness kills them).
- **`zig build test`** has a **known pre-existing failure** in `src/core/paths.zig` (libc `getenv`) unrelated to UI — executors must **not** treat it as a Phase 2 regression.

---

## 7. Coverage map (spec → plan tasks)

- §3.1 group taxonomy → **Task 1** (safe).
- §3.2 modal unification → **Task 2** (save), **Task 3** (load), **Task 4** (delete dead chrome / verify).
- §3.3 command palette → **Task 5** (overlay file + state), **Task 6** (keybind + dispatch).
- §3.4 `?` overlay → **Task 7** (keybind + cheat-sheet re-skin).
- §2.5 settings split → **Task 8** (high-risk, needs-approval, optional final).
