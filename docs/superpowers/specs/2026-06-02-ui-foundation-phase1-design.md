# Phase 1 · Foundation — Design Spec

**Date:** 2026-06-02
**Parent:** `2026-06-02-ui-redesign-roadmap.md`
**Serves:** Priority ③ Consistency (and unlocks ①②④).
**Touches:** `src/ui/theme.zig`, `src/ui/components.zig`, new `src/ui/ids.zig`, plus a narrow `transparent`-token sweep across `src/ui/*.zig`.

> File/line citations come from the two foundation audits + `docs/analysis.md` (dated 2026-05-15, *pre* calm-redesign). Treat them as **directional**; the implementation plan re-locates exact sites at build time.

## 1. Goal & non-goals

**Goal:** Turn the design foundation from "2.5/5, screens hand-roll everything" into a complete, calm-flat token + primitive system, so phases 2–4 are written in component calls instead of bespoke `dvui.Options` literals.

**Delivers:**
- A cleaned, extended token set in `theme.zig` (transparent, focus, state, motion, type scale, spacing, radii).
- ~10 new primitives in `components.zig` that absorb the currently hand-rolled widgets.
- An `ids.zig` constant table replacing magic `id_extra` numbers.
- The `transparent` sweep: replace the 50+ inline `Color{0,0,0,0}`.

**Explicitly defers (not this phase):**
- The broad 225-site color/radius literal sweep → folded into each screen's **Phase 3** pass.
- Any IA / drawer / settings restructure → **Phase 2**.
- Any per-screen layout/polish → **Phase 3**.
- New themes, light mode, motion *transitions* on existing screens (Phase 1 ships the helper; screens adopt it in Phase 3).

## 2. Locked decisions

- **Calm-flat depth.** Surfaces = `bg_*` ramp + `border_subtle` + whitespace. **No drop shadows** except true floating overlays (menus, toasts) via a single `shadow_overlay` token. The glassmorphic option-presets (`optGlassPanel`, `optGlowCard`, accent-glow) are **marked deprecated, kept compiling**.
- **Additive + transparent sweep.** Add tokens/primitives; remove only provably-dead tokens; replace `Color{0,0,0,0}` now; defer the rest.
- **Follow calm/amber.** Keep all 7 presets and their muted accents; clean slots, don't expand.

## 3. Token changes — `theme.zig`

### 3.1 Add
| Token | Type / value | Replaces / enables |
|---|---|---|
| `transparent` | `Color{ .r=0,.g=0,.b=0,.a=0 }` | 50+ inline transparent literals |
| `focus` | per-preset; default = `accent` at full alpha | keyboard focus rings (roadmap Phase 3 / V2 Wave 2 #10) |
| `text_disabled` | per-preset; `text_tertiary` @ ~50% | disabled control text |
| `loading` | per-preset; `accent_dim` family | spinner / shimmer |
| `shadow_overlay` | one soft shadow spec (color+blur) | menus & toasts only (calm-flat exception) |

### 3.2 Motion (new namespace `theme.motion`)
```
durations: fast = 120ms, base = 200ms, slow = 320ms
easeInOut(t: f32) f32   // cubic; clamps [0,1]
pulse(t_ms, period_ms) f32   // 0..1 triangle, for loaders
```
Replaces hand-coded `@mod(t, period)` in `grid.zig` (loader, icon pulse) and is the basis for the real `spinner` primitive. Pure functions → unit-testable in a `*_pure.zig` sibling.

### 3.3 Remove (provably dead/duplicate — verify each is unused before deleting)
- `accent_glow`, `active_border` — alpha=0 in all 7 presets.
- `accent_primary` — identical to `accent`; collapse references to `accent`.
- `border_card`, `border_drawer` — identical to `border_subtle`; collapse.

### 3.4 Type scale (was: micro=11, small=11, body=13, title=17, display=24)
```
size:   micro=10, small=11, body=13, title=17, display=24
weight: regular, medium, semibold        // new
line_height: tight=1.15, normal=1.4      // new (ratio applied where dvui allows)
```
Fixes the `micro==small` redundancy; hierarchy now comes from weight + leading, not size alone.

### 3.5 Spacing & radii
- Spacing: keep `xs=4, sm=8, md=12, lg=16, xl=24, xxl=32`; **add `huge=48`** for major section breaks. (Deliberately *not* adding 20 — keep the scale tight.)
- Radii: keep `sm=3, md=6, lg=8, pill=999`; document them as the only allowed values (ad-hoc `Rect.all(n)` swept in Phase 3).

## 4. Component primitives — `components.zig`

Style rules for all: `src` first param; interactive widgets return `bool` (clicked/changed); container widgets return a struct with `.deinit()` (RAII, `defer`); all visuals from `tk`/`theme` tokens only; every looped-safe widget takes an `id_extra` discipline consistent with the just-landed `sectionheader_seq`/`divider_seq` pattern.

| Primitive | Signature (shape) | Behavior / calm styling | Absorbs (hand-rolled today) |
|---|---|---|---|
| `button` | `fn(src, label, kind: enum{primary,secondary,ghost,danger}, opts?) bool` | flat fill per kind; `focus` ring; `text_disabled` when disabled | bespoke `buttonIcon`+Options in `footer.zig`, `grid.zig`, `header.zig` |
| `card` | `fn(src) Card` (`.deinit()`) | `bg_surface` + `border_subtle` + `md` padding, **no shadow** | per-card `bg+border+padding` in `grid.zig`, `jellyfin_ui.zig` |
| `badge` | `fn(label, kind: enum{info,success,warn,err})` | tinted text pill | replaces/absorbs `statusPill`; ad-hoc badges in `metadata_dialog.zig` |
| `checkbox` | `fn(src, label, *bool) bool` | square check; row layout | settings/footer checkmarks |
| `radioGroup` | `fn(src, options, *usize) bool` | true radios (not segment hack) | `settings.zig` segment workarounds |
| `slider` | `fn(src, label, *f32, min, max) bool` | v2 calm slider; `accent` fill | legacy `ProgressBar` → thin alias kept |
| `modal` | `fn(src, title, *open) ?Modal` (`.deinit()`) | calm frame: dim scrim + `card` body + close; `shadow_overlay` | duplicated workspace/metadata modal chrome (`ui.zig`) |
| `menu` | `fn(src, trigger, items, *selected) bool` | dropdown wrapper; `shadow_overlay` | `footer.zig`'s 6 hand-rolled `floatingMenu` loops |
| `listItem` | `fn(src, opts) bool` | standard row: padding, hover, optional trailing | dense rows in `drawer.zig`, `footer.zig` |
| `spinner` | `fn(src, size)` | Lucide `loader` rotated by `motion.pulse`/angle | the 2-glyph blink bug (`grid.zig:475-484`) |

**Kept as-is / aliased (non-breaking):** `sectionHeader`, `divider`, `toggleRow`, `selectRow`, `segment`, `iconButton`, `emptyState`, `searchInput`, `tip`/`tipId`; `ProgressBar` (alias → `slider`), `statusPill` (alias → `badge`), `optInput`/`optIconBtnDanger`/`optDivider`.

## 5. `ids.zig` constant table

```zig
// Named id_extra bases — replaces magic +70000 / +11000 / +43000 numbers.
pub const ids = struct {
    pub const chat_bubble: usize = 70_000;
    pub const grid_cell:   usize = 11_000;
    pub const search_item: usize = 43_000;
    // … one named base per looped widget family; spaced by 1_000.
};
```
Adopted incrementally; makes the collision class we just fixed (`sectionHeader` duplicate-id) trackable by name.

## 6. Interfaces, isolation, composition

- `theme.zig` stays the single source of tokens; `components.zig` consumes via its existing local `tk` accessors (runtime-resolved so theme switching stays coherent). Screens **never** read raw `dvui.Color{}`/`Rect.all(n)`.
- Each primitive is independently understandable: clear inputs, a `bool`/RAII output, depends only on `theme`+`dvui`. A screen author can use `button`/`card`/`modal` without reading their internals.
- `motion` and the type-scale math live in pure functions (`theme_pure.zig` sibling) so they're unit-testable across the `io_global` boundary.

## 7. Non-breaking / migration guarantees

- Removals limited to tokens proven unused/identical (§3.3) — verified by grep before deletion.
- Every legacy helper retained as a compiling alias; no call site breaks in this phase.
- Deprecated glass presets stay; only their *recommended* status changes (doc comment).

## 8. Verification & testing

1. `zig build` clean after each sub-change (token add/remove, each primitive).
2. **Pure unit tests** (`zig build test`) for `motion.easeInOut`/`pulse` and type-scale math via a `*_pure.zig` sibling (respecting the `io_global` test boundary noted in `CLAUDE.md`).
3. **Runtime smoke**, using the same env-gated harness pattern already validated for the widget-ID fix: force a screen that exercises the new primitives to render across frames; assert **zero** `duplicate widget id` / errors / leaks in captured stderr; confirm a marker proves the render loop ran. Revert the harness.
4. **Theme-switch coherence:** cycle all 7 presets with the new tokens; confirm no missing-token panics and that `transparent`/`focus`/state tokens resolve per preset.
5. **Dead-token removal safety:** grep proves zero references before deleting `accent_glow`/`active_border`/`accent_primary`/`border_card`/`border_drawer`.

## 9. Risks

- **Hidden token use.** A removed token might be referenced indirectly → mitigated by grep-before-delete + clean build.
- **Primitive scope creep.** Ten primitives is a lot for one phase → land them in dependency order (`button`, `card`, `badge` first; `modal`, `menu`, `slider` next; `checkbox`, `radioGroup`, `listItem`, `spinner` last), each build-verified, so the phase can stop at any checkpoint with a coherent partial result.
- **Calm vs glass drift.** Keeping deprecated glass presets risks accidental reuse → doc comment + (optional, if "Additive + CI lint" is later chosen) a lint flag.

## 10. Acceptance criteria

- `theme.zig`: new tokens present and per-preset resolved; dead tokens gone; type scale + `huge` spacing + `motion` landed; build + `test` green.
- `components.zig`: the 10 primitives exist with the signatures above, calm-flat styling, token-only visuals, `id_extra`-safe; legacy aliases intact.
- `ids.zig`: present; at least the three documented bases in use.
- Zero inline `Color{0,0,0,0}` remain in `src/ui/` (transparent sweep complete); broader literal sweep explicitly deferred and noted.
- Runtime smoke: zero widget-id collisions / errors / leaks; all 7 presets render.
