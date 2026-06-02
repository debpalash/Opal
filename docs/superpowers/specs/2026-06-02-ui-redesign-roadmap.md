# Opal UI Redesign — Roadmap

**Date:** 2026-06-02
**Status:** Approved decomposition; Phase 1 specced in full (see `2026-06-02-ui-foundation-phase1-design.md`).
**Builds on:** `docs/V2-ROADMAP.md`, `docs/V2-PANEL.md`, `docs/analysis.md` (§3 UI/UX, §6 presentation, §8 backlog), and the recent "calm / amber, whitespace-defined, card-chrome-gone" work on `main`.

> This is **not** a greenfield redesign. A v2 direction already exists and the recent calm/amber pass is executing against it. This roadmap continues that direction; it does not relitigate it.

## Goal

A coherent, low-debt UI across all 13 `src/ui/*.zig` modules, serving four priorities the user selected:

1. **Elevate visual polish**
2. **Clarify hierarchy & IA**
3. **Unify consistency**
4. **Rethink core flows**

## Why phase it

The work spans 13 modules (~10.3k LOC; `settings.zig` alone is 2.6k). It is too large for one spec. Each phase below is an independent **spec → plan → implementation** cycle. Ordering follows the v2 roadmap's own principle: *small + load-bearing first, big reshapes last.*

## Current-state findings (from two audits + existing docs)

- **Foundation maturity ≈ 2.5/5.** 41 color tokens (some dead/duplicate); a 4px spacing scale that **225+ hardcoded dimensions** ignore; `Color{0,0,0,0}` inlined 50+ times with no token; a 5-size type scale with no line-height/weight; **no elevation / motion / state systems**; **~10 primitives missing** (button, card, badge, checkbox, radio, v2 slider, modal frame, menu, list-item, spinner) that screens hand-roll.
- **IA strain.** Drawer carries far too many tabs (analysis §3 enumerates 14: `Search, Downloads, TMDB, YouTube, Queue, Comics, Anime, History, RSS, Jellyfin, Plugins, Logs, Settings, AI`); flat, ungrouped. Modals re-implement chrome (`ui.zig` workspace modals). Magic `id_extra` numbers (`+70000`, `+11000`). No keyboard-shortcut discoverability.
- **Polish gaps.** Inline color/radius literals defeat theme-switching; emoji mixed with Lucide icons; no empty-state system; spinner is a 2-glyph 1-Hz blink, not a spin; no motion/easing helper.
- **Hotspots (worst hierarchy/density/debt):** `footer.zig` (6+ dropdowns crammed into ~44–60px), `settings.zig` (2.6k-line wall, no card hierarchy), `drawer.zig` (dense rows, weak tab affordance), `grid.zig` (crowded cell overlays), `header.zig` (packed 44px, off-grid padding).

## The four phases

| Phase | Priority served | Scope summary | Order rationale |
|---|---|---|---|
| **1 · Foundation** | ③ Consistency (unlocks ①②④) | Harden `theme.zig` tokens (transparent/focus/state/motion, type scale, spacing, radii); grow `components.zig` into a real primitive set; `ids.zig` constant table; transparent-token sweep | Highest leverage, lowest risk; phases 2–4 become a few lines instead of bespoke styling |
| **2 · Navigation & IA** | ② Hierarchy/IA | Group the drawer tabs (Sources / Library / System) + command palette (analysis §8 Tier 3 #11); `renderModal` unification (Tier 2 #10); `?` shortcut overlay (Tier 3 #12); split & restructure `settings.zig` into `_root` + per-tab modules with card hierarchy (V2-ROADMAP Wave 2 #6) | Structure before surface |
| **3 · Screen polish** | ① Visual polish | Apply the foundation to the 5 hotspots; keyboard focus rings everywhere (Wave 2 #10 / panel #13); spinner fix; empty-state + motion passes; broad inline-literal sweep (deferred from Phase 1); snap to the spacing grid | Surface polish lands cleanly once 1+2 exist |
| **4 · Core flows** | ④ Rethink flows | home→play, voice/chat overlays end-to-end, multi-player UX, responsive/breakpoint-aware drawer width & font scaling | Biggest reshapes last, on a stable base |

## Locked design direction (applies to all phases)

- **Calm-flat surfaces:** subtle borders + whitespace define structure; **no drop shadows** except on true floating overlays (menus, toasts). The older glassmorphic option-presets are **deprecated but retained** (not deleted) to avoid breakage.
- **Muted accent, amber default:** keep the 7 hot-swappable presets and their deliberately-muted accents; clean their token slots, don't expand the set.
- **Non-breaking by default:** new tokens/primitives are additive; only provably-dead tokens are removed; legacy helpers stay as thin aliases.

## Constraints (from `CLAUDE.md` / project rules)

- No rename `zigzag` → `opal`; no second allocator; use `io_global` wrappers; `std.atomic` + `sync.Mutex` thread-safety conventions; `id_extra` discipline for looped widgets.
- Pure-Zig unit tests only for modules that don't cross the `io_global` boundary; factor pure logic into `*_pure.zig` where a standalone test is wanted.
- Do not commit unless explicitly asked.

## Out of scope (whole redesign, for now — YAGNI)

- Light mode / system-theme detection; new theme presets; i18n string externalization (V2 Wave 4 #16); mobile/touch layouts; detach-to-window PiP (analysis §8 Tier 4).

## Deliverable cadence

Each phase: a dated design spec under `docs/superpowers/specs/`, then a `writing-plans` implementation plan, then execution with review checkpoints. **Phase 1 is fully specced now**; phases 2–4 remain roadmap entries until reached.
