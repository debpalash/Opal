# UI Foundation (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Opal's UI foundation from "screens hand-roll everything" into a complete calm-flat token + primitive system, so redesign phases 2–4 are written in component calls instead of bespoke `dvui.Options`.

**Architecture:** Additive, non-breaking. Add derived token accessors + a pure `motion` math module to `theme.zig`/`theme_pure.zig`; grow `components.zig` with 10 primitives modeled on the existing v2 helpers (`toggleRow`, `selectRow`, `iconButton`, `ProgressBar`); add an `ids.zig` constant table; do the `transparent` literal sweep. A Debug+env-gated component gallery provides runtime verification (immediate-mode widgets can't be unit-tested across the `io_global` boundary, so pure math gets `zig build test` and primitives get build-clean + zero-collision render smoke).

**Tech Stack:** Zig 0.16.x, dvui (immediate-mode), `theme.zig` tokens, `io_global` wrappers.

**Spec:** `docs/superpowers/specs/2026-06-02-ui-foundation-phase1-design.md`

**Conventions (from `CLAUDE.md`):** use `io_global` wrappers (not `std.fs`/`std.time`); single global allocator; `id_extra` discipline for any widget emitted in a loop or from a shared `@src()` (see the landed `divider_seq`/`sectionheader_seq` pattern); pure tests only for modules that don't cross the `io_global` boundary. **Commits:** this plan commits locally at each task for checkpointing; do **not** push. If the user prefers, stage-only and let them commit.

**Verification recipe (reused by every primitive task) — call this "RENDER-SMOKE":**
```bash
# 1. build
zig build 2>&1 | tail -5; echo "rc=$?"
# 2. run the Debug gallery for a moment, capturing stderr
rm -f /tmp/zz_gallery.log
ZZ_GALLERY=1 ./zig-out/bin/zigzag > /tmp/zz_gallery.log 2>&1 &
n=0; s=0; while [ $n -lt 8000000 ]; do s=$((s+n)); n=$((n+1)); done   # elapse wall time (no foreground sleep)
/usr/bin/pkill -f "zig-out/bin/zigzag"
# 3. assert
echo "marker:";     /usr/bin/grep -c "ZZGALLERY: rendered" /tmp/zz_gallery.log     # expect >= 1
echo "collisions:"; /usr/bin/grep -c "duplicate widget id" /tmp/zz_gallery.log      # expect 0
echo "errors:";     /usr/bin/grep -ci "error\|panic\|leak" /tmp/zz_gallery.log      # expect 0
```
Expected every time: `marker >= 1`, `collisions: 0`, `errors: 0`.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/ui/theme_pure.zig` (new) | Pure, testable math: motion easing/pulse, type-scale helpers. No dvui, no io_global. |
| `src/ui/theme.zig` (modify) | Add `transparent`/`shadow_overlay` consts, derived `focus()`/`text_disabled()`/`loading()` accessors, `motion` re-export, type-scale `weight`/`line_height`, `spacing.huge`; remove dead tokens. |
| `src/ui/components.zig` (modify) | Add 10 primitives + legacy aliases. |
| `src/ui/ids.zig` (new) | Named `id_extra` base constants. |
| `src/ui/components_gallery.zig` (new) | Debug+env-gated overlay rendering every primitive ≥2× under one parent (collision scenario) for RENDER-SMOKE. |
| `src/main.zig` (modify) | One Debug+env-gated call to the gallery in `appFrame()`. |
| `build.zig` (modify) | Register `theme_pure.zig` in the `zig build test` step. |

---

## Task 1: Pure motion + type-scale math (`theme_pure.zig`) with unit tests

**Files:**
- Create: `src/ui/theme_pure.zig`
- Modify: `build.zig` (add to the test step, mirroring the existing `*_pure.zig` entries named in `CLAUDE.md`, e.g. `ai_intent_pure.zig` / `resolver_rank.zig`)

- [ ] **Step 1: Write the failing tests + module skeleton**

Create `src/ui/theme_pure.zig`:
```zig
const std = @import("std");

/// Standard motion durations (milliseconds).
pub const duration = struct {
    pub const fast: f32 = 120;
    pub const base: f32 = 200;
    pub const slow: f32 = 320;
};

/// Cubic ease-in-out over a normalized t in [0,1].
pub fn easeInOut(t: f32) f32 {
    const x = std.math.clamp(t, 0.0, 1.0);
    if (x < 0.5) return 4 * x * x * x;
    const f = -2 * x + 2;
    return 1 - (f * f * f) / 2;
}

/// Triangle wave in [0,1]: 0 at phase 0, 1 at the midpoint, back to 0.
/// `t_ms` is an absolute time; `period_ms` the cycle length.
pub fn pulse(t_ms: f32, period_ms: f32) f32 {
    if (period_ms <= 0) return 0;
    const phase = @mod(t_ms, period_ms) / period_ms; // 0..1
    return 1 - @abs(2 * phase - 1);
}

/// Line-height in pixels for a font size + ratio (e.g. 1.4).
pub fn lineHeightPx(size_px: f32, ratio: f32) f32 {
    return size_px * ratio;
}

test "easeInOut endpoints and midpoint" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), easeInOut(0.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), easeInOut(1.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), easeInOut(0.5), 1e-6);
}

test "easeInOut clamps out-of-range input" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), easeInOut(-3.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), easeInOut(9.0), 1e-6);
}

test "pulse triangle wave" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), pulse(0, 200), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), pulse(100, 200), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), pulse(200, 200), 1e-6);
    try std.testing.expectEqual(@as(f32, 0), pulse(50, 0)); // guard period<=0
}

test "lineHeightPx" {
    try std.testing.expectApproxEqAbs(@as(f32, 18.2), lineHeightPx(13, 1.4), 1e-4);
}
```

- [ ] **Step 2: Register the module in `build.zig`'s test step**

Find the existing test-module registration (the block that adds `*_pure.zig` siblings to the `test` step — search `build.zig` for `_pure.zig` or `addTest`). Add an entry for `src/ui/theme_pure.zig` in the same shape as the existing ones. Do not invent a new pattern — copy a neighboring entry and change the path.

- [ ] **Step 3: Run the tests to verify they pass**

Run: `zig build test 2>&1 | tail -20; echo "rc=$?"`
Expected: `rc=0`, no failures (the `theme_pure` tests are included).

- [ ] **Step 4: Commit**
```bash
git add src/ui/theme_pure.zig build.zig
git commit -m "feat(ui): pure motion + type-scale math (theme_pure) with tests"
```

---

## Task 2: Token additions in `theme.zig`

**Files:**
- Modify: `src/ui/theme.zig` (token area ~24–79 for consts; `spacing`/`font_size` structs ~462–488)

- [ ] **Step 1: Add the new tokens + accessors**

Near the top-level token declarations in `theme.zig` (where `colors`/`spacing`/`radius`/`font_size` live), add:
```zig
pub const motion = @import("theme_pure.zig"); // duration.*, easeInOut, pulse, lineHeightPx

/// Fully transparent — replaces inline `dvui.Color{ .r=0,.g=0,.b=0,.a=0 }`.
pub const transparent = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

/// Single soft shadow spec — the ONLY shadow in the calm-flat system,
/// reserved for true floating overlays (menus, toasts, modals).
pub const shadow_overlay = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 90 };

/// Keyboard focus-ring color — derived from the active accent.
pub inline fn focus() dvui.Color { return colors.accent; }

/// Disabled control text — derived from the active text ramp (≈50%).
pub inline fn textDisabled() dvui.Color {
    var col = colors.text_tertiary;
    col.a = @intFromFloat(@as(f32, @floatFromInt(col.a)) * 0.5);
    return col;
}

/// Loading / shimmer tint — derived from the active accent.
pub inline fn loading() dvui.Color { return colors.accent_dim; }
```
> Derived accessors avoid editing all 7 preset literals (non-breaking). If `colors.accent`/`text_tertiary`/`accent_dim` are named differently in this tree, use the actual field names — the build will tell you.

- [ ] **Step 2: Extend the spacing + type scale**

In the `spacing` struct add `huge`; in `font_size` fix `micro` and add weight/line-height tokens:
```zig
// in `pub const spacing = .{ ... }`:
pub const huge: f32 = 48;

// in the font-size area:
pub const font_size = .{
    .micro = 10, .small = 11, .body = 13, .title = 17, .display = 24,
};
pub const font_weight = enum { regular, medium, semibold };
pub const line_height = .{ .tight = 1.15, .normal = 1.4 };
```
Match the existing declaration style in this file (it may use `= struct {…}` vs anonymous struct — keep whatever is there; only add fields/lower `micro` to 10).

- [ ] **Step 3: Build + theme-cycle smoke**

Run: `zig build 2>&1 | tail -5; echo "rc=$?"`
Expected: `rc=0`.
Then run RENDER-SMOKE (gallery doesn't exist yet, so just assert the app starts clean):
```bash
rm -f /tmp/zz.log; ./zig-out/bin/zigzag > /tmp/zz.log 2>&1 &
n=0;s=0;while [ $n -lt 6000000 ]; do s=$((s+n)); n=$((n+1)); done
/usr/bin/pkill -f zig-out/bin/zigzag
/usr/bin/grep -ci "error\|panic\|leak" /tmp/zz.log   # expect 0
```

- [ ] **Step 4: Commit**
```bash
git add src/ui/theme.zig
git commit -m "feat(ui): add transparent/focus/state/motion tokens, type scale, spacing.huge"
```

---

## Task 3: `ids.zig` constant table

**Files:**
- Create: `src/ui/ids.zig`

- [ ] **Step 1: Create the table**
```zig
//! Named id_extra bases — replaces magic `+70000` / `+11000` numbers so the
//! widget-id collision class (see components.divider/sectionHeader) is
//! trackable by name. Spaced by 1_000; never overlap two families.
pub const grid_cell:   usize = 11_000;
pub const search_item: usize = 43_000;
pub const chat_bubble: usize = 70_000;
```

- [ ] **Step 2: Build**

Run: `zig build 2>&1 | tail -5; echo "rc=$?"`
Expected: `rc=0` (file compiles; adoption at call sites is incremental and happens in Phase 3 screen passes — do not sweep now).

- [ ] **Step 3: Commit**
```bash
git add src/ui/ids.zig
git commit -m "feat(ui): add ids.zig named id_extra base table"
```

---

## Task 4: `transparent` literal sweep

**Files:**
- Modify: every `src/ui/*.zig` that inlines `dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 }`

- [ ] **Step 1: Find all sites**

Run: `/usr/bin/grep -rn "\.r = 0, \.g = 0, \.b = 0, \.a = 0" src/ui/ | wc -l` and `/usr/bin/grep -rln "\.r = 0, \.g = 0, \.b = 0, \.a = 0" src/ui/`
Expected: a list of files (~the 50+ sites from the audit, incl. `components.zig`, `footer.zig`, `grid.zig`, `header.zig`, `jellyfin_ui.zig`, `ui.zig`).

- [ ] **Step 2: Replace each with the token**

In each file, replace `dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 }` with `theme.transparent`. (Every `src/ui/*.zig` already imports `theme`. In `theme.zig` itself, if any, use the bare `transparent`.) Whitespace variants exist — also grep `.a=0` forms: `/usr/bin/grep -rn "r = 0, .g = 0, .b = 0, .a = 0\|r=0,.g=0,.b=0,.a=0" src/ui/`.

- [ ] **Step 3: Verify none remain + build**

Run: `/usr/bin/grep -rn "\.r = 0, \.g = 0, \.b = 0, \.a = 0\|r=0,.g=0,.b=0,.a=0" src/ui/ | wc -l` → expect `0`.
Run: `zig build 2>&1 | tail -5; echo "rc=$?"` → expect `rc=0`.

- [ ] **Step 4: Commit**
```bash
git add src/ui/
git commit -m "refactor(ui): replace inline transparent Color literals with theme.transparent"
```

---

## Task 5: Component gallery harness (`components_gallery.zig`)

**Files:**
- Create: `src/ui/components_gallery.zig`
- Modify: `src/main.zig` (`appFrame()`, after the existing `dvui.currentWindow().debug.widget_id = .zero;` line)

- [ ] **Step 1: Create the gallery**
```zig
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const theme = @import("theme.zig");
const components = @import("components.zig");

/// Debug-only visual QA surface for the v2 primitives. Gated by the
/// `ZZ_GALLERY` env var so it never shows in normal use. Renders each
/// primitive at least twice under one parent — the exact scenario that
/// surfaces duplicate-widget-id collisions — and prints a one-shot marker
/// proving the render loop executed (used by the RENDER-SMOKE recipe).
var printed_marker: bool = false;

pub fn render() void {
    if (comptime builtin.mode != .Debug) return;
    const io_global = @import("../core/io_global.zig");
    if (io_global.getenv("ZZ_GALLERY") == null) return;
    dvui.refresh(null, @src(), null); // force continuous frames while open

    var win = dvui.floatingWindow(@src(), .{ .modal = false }, .{
        .min_size_content = .{ .w = 420, .h = 600 },
        .color_fill = theme.colors.bg_drawer,
        .color_border = theme.colors.border_subtle,
        .border = dvui.Rect.all(1),
        .corner_radius = dvui.Rect.all(8),
    });
    defer win.deinit();

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .color_fill = theme.transparent });
    defer scroll.deinit();

    components.sectionHeader("Gallery");
    // Primitives are appended here by later tasks.

    if (!printed_marker) {
        printed_marker = true;
        std.debug.print("ZZGALLERY: rendered\n", .{});
    }
}
```
> If `dvui.scrollArea`'s signature differs in this tree, match the one used in `settings.zig`/`drawer.zig` (search for `scrollArea(`). The build will confirm.

- [ ] **Step 2: Hook it into `appFrame()`**

In `src/main.zig`, immediately after the line `dvui.currentWindow().debug.widget_id = .zero;`, add:
```zig
    @import("ui/components_gallery.zig").render();
```

- [ ] **Step 3: Build + run the empty gallery (RENDER-SMOKE)**

Run the full RENDER-SMOKE recipe from the header.
Expected: `marker >= 1`, `collisions: 0`, `errors: 0`.

- [ ] **Step 4: Commit**
```bash
git add src/ui/components_gallery.zig src/main.zig
git commit -m "feat(ui): debug component gallery harness for primitive verification"
```

---

## Task 6: `button` primitive

**Files:**
- Modify: `src/ui/components.zig` (append near the v2 helpers), `src/ui/components_gallery.zig`

- [ ] **Step 1: Implement `button`**

Append to `components.zig`:
```zig
pub const ButtonKind = enum { primary, secondary, ghost, danger };

/// Flat calm button. `primary` = accent fill; `secondary` = bg_elevated;
/// `ghost` = transparent; `danger` = error-tinted. Returns true on click.
pub fn button(
    src: std.builtin.SourceLocation,
    label: []const u8,
    kind: ButtonKind,
) bool {
    const fill = switch (kind) {
        .primary   => tk.accent_primary(),
        .secondary => tk.bg_elevated(),
        .ghost     => theme.transparent,
        .danger    => tk.semantic_error(),
    };
    const fg = switch (kind) {
        .primary, .danger => tk.text_on_accent(),
        .secondary        => tk.text_primary(),
        .ghost            => tk.text_secondary(),
    };
    return dvui.button(src, label, .{}, .{
        .color_fill = fill,
        .color_text = fg,
        .border = dvui.Rect.all(0),
        .corner_radius = tk.rad_md,
        .padding = .{ .x = tk.sp_lg, .y = tk.sp_sm, .w = tk.sp_lg, .h = tk.sp_sm },
    });
}
```

- [ ] **Step 2: Add to the gallery (≥2 instances under one parent)**

In `components_gallery.zig`, after `components.sectionHeader("Gallery");`, before the marker block:
```zig
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .margin = dvui.Rect.all(theme.spacing.sm) });
        defer row.deinit();
        _ = components.button(@src(), "Primary", .primary);
        _ = components.button(@src(), "Secondary", .secondary);
        _ = components.button(@src(), "Ghost", .ghost);
        _ = components.button(@src(), "Danger", .danger);
    }
```

- [ ] **Step 3: RENDER-SMOKE** → `marker>=1, collisions:0, errors:0`.

- [ ] **Step 4: Commit**
```bash
git add src/ui/components.zig src/ui/components_gallery.zig
git commit -m "feat(ui): button primitive (primary/secondary/ghost/danger)"
```

---

## Task 7: `card` primitive

**Files:** Modify `src/ui/components.zig`, `src/ui/components_gallery.zig`

- [ ] **Step 1: Implement `card` (RAII container, calm-flat: subtle border, NO shadow)**
```zig
pub const Card = struct {
    box: *dvui.BoxWidget,
    pub fn deinit(self: *Card) void { self.box.deinit(); }
};

/// Calm-flat surface: bg_surface + 1px border_subtle + md padding. No shadow.
/// Usage: `var c = components.card(@src()); defer c.deinit();`
pub fn card(src: std.builtin.SourceLocation) Card {
    const b = dvui.box(src, .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = tk.bg_surface(),
        .color_border = tk.border_subtle(),
        .border = dvui.Rect.all(1),
        .corner_radius = tk.rad_md,
        .padding = dvui.Rect.all(tk.sp_md),
        .margin = .{ .x = 0, .y = tk.sp_xs, .w = 0, .h = tk.sp_xs },
    });
    return .{ .box = b };
}
```
> `dvui.box` returns `*dvui.BoxWidget` here (it's stored in a `var` and `.deinit()`-ed throughout this file). If the concrete type name differs, use `@TypeOf(dvui.box(...))` or match the existing `var x = dvui.box(...)` usage — the build confirms.

- [ ] **Step 2: Gallery (≥2 cards)**
```zig
    {
        var c1 = components.card(@src()); _ = dvui.label(@src(), "Card one", .{}, .{ .color_text = theme.colors.text_primary }); c1.deinit();
        var c2 = components.card(@src()); _ = dvui.label(@src(), "Card two", .{}, .{ .color_text = theme.colors.text_primary }); c2.deinit();
    }
```

- [ ] **Step 3: RENDER-SMOKE** → all green.

- [ ] **Step 4: Commit**
```bash
git add src/ui/components.zig src/ui/components_gallery.zig
git commit -m "feat(ui): card primitive (calm-flat surface)"
```

---

## Task 8: `badge` primitive (+ `statusPill` alias)

**Files:** Modify `src/ui/components.zig`, `src/ui/components_gallery.zig`

- [ ] **Step 1: Implement `badge`, alias `statusPill`**

Add `badge` (a renamed, kept-behavior `statusPill`) and turn `statusPill` into a thin alias so existing callers keep working:
```zig
pub const BadgeKind = enum { info, success, warn, err };

/// Small status label — colored text only (calm: no box/border/fill).
pub fn badge(label: []const u8, kind: BadgeKind) void {
    const fg = switch (kind) {
        .info    => tk.text_secondary(),
        .success => tk.semantic_success(),
        .warn    => tk.semantic_warn(),
        .err     => tk.semantic_error(),
    };
    var pill = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .padding = .{ .x = tk.sp_sm, .y = tk.sp_xs, .w = tk.sp_sm, .h = tk.sp_xs },
        .margin = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
    });
    defer pill.deinit();
    _ = dvui.label(@src(), "{s}", .{label}, .{ .color_text = fg, .font = fontAt(tk.fs_small) });
}
```
Then replace the existing `pub fn statusPill(...)` body with a delegating alias (keep its `enum {...}` param mapping to `BadgeKind`):
```zig
pub fn statusPill(label: []const u8, kind: enum { info, success, warn, err }) void {
    badge(label, switch (kind) { .info => .info, .success => .success, .warn => .warn, .err => .err });
}
```

- [ ] **Step 2: Gallery (all four kinds + confirm `statusPill` still compiles)**
```zig
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .margin = dvui.Rect.all(theme.spacing.sm) });
        defer row.deinit();
        components.badge("Info", .info);
        components.badge("OK", .success);
        components.badge("Warn", .warn);
        components.badge("Err", .err);
        components.statusPill("Legacy", .info);
    }
```

- [ ] **Step 3: RENDER-SMOKE** → all green. Also confirm no caller broke: `zig build 2>&1 | tail -5; echo rc=$?` → `rc=0`.

- [ ] **Step 4: Commit**
```bash
git add src/ui/components.zig src/ui/components_gallery.zig
git commit -m "feat(ui): badge primitive; statusPill becomes a thin alias"
```

---

## Task 9: `checkbox` primitive

**Files:** Modify `src/ui/components.zig`, `src/ui/components_gallery.zig`

- [ ] **Step 1: Implement `checkbox`**
```zig
/// Square checkbox + label on one clickable row. Returns true on the frame
/// the value toggles.
pub fn checkbox(
    src: std.builtin.SourceLocation,
    label: []const u8,
    value: *bool,
) bool {
    var changed = false;
    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .padding = .{ .x = tk.sp_sm, .y = tk.sp_xs, .w = tk.sp_sm, .h = tk.sp_xs },
    });
    if (dvui.clicked(row.data(), .{})) { value.* = !value.*; changed = true; }
    row.drawBackground();

    var bx = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .gravity_y = 0.5,
        .background = true,
        .color_fill = if (value.*) tk.accent_primary() else theme.transparent,
        .color_border = if (value.*) tk.accent_primary() else tk.border_strong(),
        .border = dvui.Rect.all(1),
        .corner_radius = tk.rad_sm,
        .min_size_content = .{ .w = 16, .h = 16 },
        .max_size_content = .{ .w = 16, .h = 16 },
        .margin = .{ .x = 0, .y = 0, .w = tk.sp_sm, .h = 0 },
    });
    if (value.*) {
        dvui.icon(@src(), "check", icons.tvg.lucide.@"check", .{}, .{
            .color_text = tk.text_on_accent(),
            .min_size_content = .{ .w = 14, .h = 14 },
            .gravity_x = 0.5, .gravity_y = 0.5,
        });
    }
    bx.deinit();

    _ = dvui.label(@src(), "{s}", .{label}, .{
        .gravity_y = 0.5,
        .color_text = tk.text_primary(),
        .font = fontAt(tk.fs_body),
    });
    row.deinit();
    return changed;
}
```

- [ ] **Step 2: Gallery (≥2 checkboxes, persistent state)**
```zig
    {
        const G = struct { var a: bool = false; var b: bool = true; };
        var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .margin = dvui.Rect.all(theme.spacing.sm) });
        defer col.deinit();
        _ = components.checkbox(@src(), "Enable A", &G.a);
        _ = components.checkbox(@src(), "Enable B", &G.b);
    }
```

- [ ] **Step 3: RENDER-SMOKE** → all green.

- [ ] **Step 4: Commit**
```bash
git add src/ui/components.zig src/ui/components_gallery.zig
git commit -m "feat(ui): checkbox primitive"
```

---

## Task 10: `radioGroup` primitive

**Files:** Modify `src/ui/components.zig`, `src/ui/components_gallery.zig`

- [ ] **Step 1: Implement `radioGroup`**
```zig
/// Vertical radio list. `selected` is the chosen index. Returns true when the
/// selection changes this frame. Each option row is id_extra-disambiguated.
pub fn radioGroup(
    src: std.builtin.SourceLocation,
    options: []const []const u8,
    selected: *usize,
) bool {
    var changed = false;
    if (selected.* >= options.len and options.len > 0) selected.* = 0;
    var col = dvui.box(src, .{ .dir = .vertical }, .{ .expand = .horizontal });
    defer col.deinit();

    for (options, 0..) |opt, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .padding = .{ .x = tk.sp_sm, .y = tk.sp_xs, .w = tk.sp_sm, .h = tk.sp_xs },
        });
        if (dvui.clicked(row.data(), .{})) { selected.* = i; changed = true; }
        row.drawBackground();

        const on = i == selected.*;
        var dot = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .gravity_y = 0.5,
            .background = true,
            .color_fill = if (on) tk.accent_primary() else theme.transparent,
            .color_border = if (on) tk.accent_primary() else tk.border_strong(),
            .border = dvui.Rect.all(1),
            .corner_radius = tk.rad_pill,
            .min_size_content = .{ .w = 14, .h = 14 },
            .max_size_content = .{ .w = 14, .h = 14 },
            .margin = .{ .x = 0, .y = 0, .w = tk.sp_sm, .h = 0 },
        });
        dot.deinit();

        _ = dvui.label(@src(), "{s}", .{opt}, .{
            .id_extra = i,
            .gravity_y = 0.5,
            .color_text = tk.text_primary(),
            .font = fontAt(tk.fs_body),
        });
        row.deinit();
    }
    return changed;
}
```

- [ ] **Step 2: Gallery**
```zig
    {
        const G = struct { var sel: usize = 0; const opts = [_][]const u8{ "Low", "Medium", "High" }; };
        _ = components.radioGroup(@src(), &G.opts, &G.sel);
    }
```

- [ ] **Step 3: RENDER-SMOKE** → all green.

- [ ] **Step 4: Commit**
```bash
git add src/ui/components.zig src/ui/components_gallery.zig
git commit -m "feat(ui): radioGroup primitive"
```

---

## Task 11: `slider` primitive (+ `ProgressBar` alias)

**Files:** Modify `src/ui/components.zig`, `src/ui/components_gallery.zig`

- [ ] **Step 1: Implement `slider`; make `ProgressBar` delegate**
```zig
/// Calm labeled slider mapping `value` within [min,max]. Returns true on change.
pub fn slider(
    src: std.builtin.SourceLocation,
    label: []const u8,
    value: *f32,
    min: f32,
    max: f32,
) bool {
    var box = dvui.box(src, .{ .dir = .vertical }, .{ .expand = .horizontal, .margin = .{ .x = 0, .y = tk.sp_xs, .w = 0, .h = tk.sp_xs } });
    defer box.deinit();
    if (label.len > 0) {
        _ = dvui.label(@src(), "{s}", .{label}, .{ .color_text = tk.text_secondary(), .font = fontAt(tk.fs_small) });
    }
    const span = if (max > min) max - min else 1;
    var frac = std.math.clamp((value.* - min) / span, 0.0, 1.0);
    const changed = dvui.slider(@src(), .{ .fraction = &frac }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 10, .h = 8 },
        .color_fill = tk.bg_elevated(),
        .color_text = tk.accent_primary(),
        .corner_radius = tk.rad_sm,
    });
    if (changed) value.* = min + frac * span;
    return changed;
}
```
Replace the legacy `ProgressBar` body with a delegating alias (read-only progress = a disabled-looking slider; keep the signature):
```zig
pub fn ProgressBar(src: std.builtin.SourceLocation, fraction: f32, label: []const u8, id_extra: usize) void {
    _ = id_extra;
    var f = std.math.clamp(fraction, 0.0, 1.0);
    _ = slider(src, label, &f, 0.0, 1.0);
}
```
> If `dvui.slider`'s exact field set differs from what `ProgressBar` originally used, copy the original call's options verbatim — the original is preserved in git history of this same function.

- [ ] **Step 2: Gallery (≥2 sliders + a ProgressBar)**
```zig
    {
        const G = struct { var vol: f32 = 0.4; var bright: f32 = 0.7; };
        _ = components.slider(@src(), "Volume", &G.vol, 0.0, 1.0);
        _ = components.slider(@src(), "Brightness", &G.bright, 0.0, 1.0);
        components.ProgressBar(@src(), 0.33, "Download", 0);
    }
```

- [ ] **Step 3: RENDER-SMOKE** + `zig build` (confirm existing `ProgressBar` callers still compile) → all green.

- [ ] **Step 4: Commit**
```bash
git add src/ui/components.zig src/ui/components_gallery.zig
git commit -m "feat(ui): v2 slider primitive; ProgressBar delegates to it"
```

---

## Task 12: `listItem` primitive

**Files:** Modify `src/ui/components.zig`, `src/ui/components_gallery.zig`

- [ ] **Step 1: Implement `listItem`**
```zig
/// Standard clickable row: hover lift, md padding, optional leading icon +
/// trailing text. Returns true on click. Caller passes a unique `id_extra`
/// when emitting in a loop.
pub fn listItem(
    src: std.builtin.SourceLocation,
    id_extra: usize,
    leading_icon: ?[]const u8,
    label: []const u8,
    trailing: []const u8,
) bool {
    var hovered = false;
    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .background = true,
        .color_fill = if (hovered) tk.bg_hover() else theme.transparent,
        .corner_radius = tk.rad_sm,
        .padding = .{ .x = tk.sp_md, .y = tk.sp_sm, .w = tk.sp_md, .h = tk.sp_sm },
        .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
    });
    const clicked = dvui.clicked(row.data(), .{ .hovered = &hovered });
    row.drawBackground();

    if (leading_icon) |ic| {
        dvui.icon(@src(), "li", ic, .{}, .{
            .id_extra = id_extra,
            .color_text = tk.text_secondary(),
            .min_size_content = .{ .w = 16, .h = 16 }, .max_size_content = .{ .w = 16, .h = 16 },
            .gravity_y = 0.5, .margin = .{ .x = 0, .y = 0, .w = tk.sp_sm, .h = 0 },
        });
    }
    _ = dvui.label(@src(), "{s}", .{label}, .{ .id_extra = id_extra, .gravity_y = 0.5, .color_text = tk.text_primary(), .font = fontAt(tk.fs_body) });
    { var s = dvui.box(@src(), .{}, .{ .id_extra = id_extra, .expand = .horizontal }); s.deinit(); }
    if (trailing.len > 0) {
        _ = dvui.label(@src(), "{s}", .{trailing}, .{ .id_extra = id_extra, .gravity_y = 0.5, .color_text = tk.text_tertiary(), .font = fontAt(tk.fs_small) });
    }
    row.deinit();
    return clicked;
}
```

- [ ] **Step 2: Gallery (loop → exercises id_extra discipline)**
```zig
    {
        const names = [_][]const u8{ "First", "Second", "Third" };
        for (names, 0..) |nm, i| {
            _ = components.listItem(@src(), i, icons.tvg.lucide.@"file", nm, "›");
        }
    }
```
> Add `const icons = @import("icons");` to the gallery's imports if not present.

- [ ] **Step 3: RENDER-SMOKE** → all green (loop with one `@src()` must show **0** collisions — proves the `id_extra` discipline).

- [ ] **Step 4: Commit**
```bash
git add src/ui/components.zig src/ui/components_gallery.zig
git commit -m "feat(ui): listItem primitive"
```

---

## Task 13: `spinner` primitive (motion-driven)

**Files:** Modify `src/ui/components.zig`, `src/ui/components_gallery.zig`

- [ ] **Step 1: Implement `spinner` (3 phased dots — fixes the 2-glyph blink)**
```zig
/// Indeterminate loader: three dots whose opacity phases via theme.motion.pulse.
/// Reads wall time from io_global (no std.time). Consumers should be on a
/// continuously-refreshing frame for it to animate.
pub fn spinner(src: std.builtin.SourceLocation) void {
    const io_global = @import("../core/io_global.zig");
    const t: f32 = @floatFromInt(@as(u64, @bitCast(io_global.milliTimestamp())));
    var row = dvui.box(src, .{ .dir = .horizontal }, .{ .gravity_x = 0.5, .gravity_y = 0.5 });
    defer row.deinit();
    const period: f32 = 900;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const phase = t + @as(f32, @floatFromInt(i)) * (period / 3.0);
        const a: u8 = @intFromFloat(80 + 175 * theme.motion.pulse(phase, period));
        var dot = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .background = true,
            .color_fill = dvui.Color{ .r = tk.accent_primary().r, .g = tk.accent_primary().g, .b = tk.accent_primary().b, .a = a },
            .corner_radius = tk.rad_pill,
            .min_size_content = .{ .w = 6, .h = 6 }, .max_size_content = .{ .w = 6, .h = 6 },
            .margin = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
        });
        dot.deinit();
    }
}
```
> `io_global.milliTimestamp()` is the project's time wrapper (see `CLAUDE.md`). If it returns a different integer type, adjust the `@bitCast`/`@floatFromInt` accordingly — the build confirms.

- [ ] **Step 2: Gallery**
```zig
    { components.spinner(@src()); }
```

- [ ] **Step 3: RENDER-SMOKE** → all green.

- [ ] **Step 4: Commit**
```bash
git add src/ui/components.zig src/ui/components_gallery.zig
git commit -m "feat(ui): motion-driven spinner primitive"
```

---

## Task 14: `menu` primitive (wraps `dvui.dropdown`)

**Files:** Modify `src/ui/components.zig`, `src/ui/components_gallery.zig`

- [ ] **Step 1: Implement `menu`**

Model on the proven `dvui.dropdown` call already in `selectRow`:
```zig
/// Calm dropdown menu. `selected` is the chosen index; returns true on change.
/// Wraps dvui.dropdown so the 6 hand-rolled footer menus can converge here.
pub fn menu(
    src: std.builtin.SourceLocation,
    options: []const []const u8,
    selected: *usize,
) bool {
    if (options.len == 0) return false;
    if (selected.* >= options.len) selected.* = 0;
    return dvui.dropdown(src, options, .{ .choice = selected }, .{}, .{
        .min_size_content = .{ .w = 120, .h = 24 },
        .color_fill = tk.bg_elevated(),
        .color_text = tk.text_primary(),
        .corner_radius = tk.rad_md,
        .padding = .{ .x = tk.sp_md, .y = tk.sp_xs, .w = tk.sp_md, .h = tk.sp_xs },
    });
}
```

- [ ] **Step 2: Gallery (≥2 menus)**
```zig
    {
        const G = struct { var a: usize = 0; var b: usize = 1; const opts = [_][]const u8{ "Auto", "16:9", "4:3" }; };
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .margin = dvui.Rect.all(theme.spacing.sm) });
        defer row.deinit();
        _ = components.menu(@src(), &G.opts, &G.a);
        _ = components.menu(@src(), &G.opts, &G.b);
    }
```

- [ ] **Step 3: RENDER-SMOKE** → all green.

- [ ] **Step 4: Commit**
```bash
git add src/ui/components.zig src/ui/components_gallery.zig
git commit -m "feat(ui): menu primitive wrapping dvui.dropdown"
```

---

## Task 15: `modal` primitive (wraps `dvui.floatingWindow`)

**Files:** Modify `src/ui/components.zig`, `src/ui/components_gallery.zig`

- [ ] **Step 1: Implement `modal` (RAII; calm frame + title + close X)**

Model on the workspace modals in `ui.zig:146-189`:
```zig
pub const Modal = struct {
    win: @TypeOf(dvui.floatingWindow(@src(), .{}, .{})),
    pub fn deinit(self: *Modal) void { self.win.deinit(); }
};

/// Calm modal frame. Returns null when `open.* == false`. When non-null, the
/// caller renders the body, then calls `.deinit()`. A title bar with a close X
/// is drawn automatically; clicking it (or the scrim) flips `open.*` via
/// dvui's `open_flag`.
pub fn modal(
    src: std.builtin.SourceLocation,
    title: []const u8,
    open: *bool,
) ?Modal {
    if (!open.*) return null;
    var win = dvui.floatingWindow(src, .{ .modal = true, .open_flag = open }, .{
        .min_size_content = .{ .w = 380, .h = 140 },
        .color_fill = tk.bg_surface(),
        .color_border = tk.border_subtle(),
        .border = dvui.Rect.all(1),
        .corner_radius = tk.rad_lg,
    });

    var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .padding = .{ .x = tk.sp_lg, .y = tk.sp_md, .w = tk.sp_md, .h = tk.sp_md },
    });
    _ = dvui.label(@src(), "{s}", .{title}, .{ .gravity_y = 0.5, .color_text = tk.text_primary(), .font = fontAt(tk.fs_title) });
    { var s = dvui.box(@src(), .{}, .{ .expand = .horizontal }); s.deinit(); }
    if (dvui.buttonIcon(@src(), "close", icons.tvg.lucide.@"x", .{}, .{}, .{
        .color_text = tk.text_secondary(),
        .color_fill = theme.transparent,
        .border = dvui.Rect.all(0),
        .gravity_y = 0.5,
    })) {
        open.* = false;
    }
    hdr.deinit();

    return .{ .win = win };
}
```
> `@TypeOf(dvui.floatingWindow(...))` captures the concrete window type without naming it. If the compiler rejects the comptime call in the struct field, name the type explicitly by checking `ui.zig`'s `var win = dvui.floatingWindow(...)` (it is `*dvui.FloatingWindowWidget` or similar).

- [ ] **Step 2: Gallery (toggle + body)**
```zig
    {
        const G = struct { var open: bool = true; };
        if (components.modal(@src(), "Example Modal", &G.open)) |*m| {
            var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .padding = dvui.Rect.all(theme.spacing.lg) });
            _ = dvui.label(@src(), "Modal body content.", .{}, .{ .color_text = theme.colors.text_secondary });
            body.deinit();
            m.deinit();
        }
    }
```

- [ ] **Step 3: RENDER-SMOKE** → all green (the modal renders above the gallery; marker still prints).

- [ ] **Step 4: Commit**
```bash
git add src/ui/components.zig src/ui/components_gallery.zig
git commit -m "feat(ui): modal primitive wrapping dvui.floatingWindow"
```

---

## Task 16: Remove provably-dead tokens

**Files:** Modify `src/ui/theme.zig`

- [ ] **Step 1: Confirm zero references before deleting**

Run for each candidate:
```bash
for t in accent_glow active_border; do echo "== $t =="; /usr/bin/grep -rn "$t" src/ | /usr/bin/grep -v "theme.zig:"; done
```
Expected: **no output** outside `theme.zig` for `accent_glow` and `active_border` (they're alpha=0 in all presets).
> `accent_primary`, `border_card`, `border_drawer` collapses are **deferred to Phase 3** (they have live references — a rename sweep, not a delete). Do NOT touch them here.

- [ ] **Step 2: Delete the two fields**

Remove `accent_glow` and `active_border` from the `ThemeColors` struct definition AND from each of the 7 preset literals (`midnight`, `abyss`, `phantom`, `nord`, `solarized`, `rose`, `ember`). The Zig compiler will error on any preset still setting a removed field or any preset missing a still-present field — use that to verify completeness.

- [ ] **Step 3: Build + test**

Run: `zig build 2>&1 | tail -10; echo "rc=$?"` → `rc=0`.
Run: `zig build test 2>&1 | tail -5; echo "rc=$?"` → `rc=0`.
Run RENDER-SMOKE → all green.

- [ ] **Step 4: Commit**
```bash
git add src/ui/theme.zig
git commit -m "refactor(ui): remove dead theme tokens (accent_glow, active_border)"
```

---

## Task 17: Final verification + foundation note

**Files:** Modify `src/ui/components.zig` (header comment), create `docs/COMPONENTS.md` (optional quick-reference)

- [ ] **Step 1: Full build + test + smoke matrix**
```bash
zig build 2>&1 | tail -5; echo "build rc=$?"
zig build test 2>&1 | tail -5; echo "test rc=$?"
```
Expected: both `rc=0`. Then RENDER-SMOKE → `marker>=1, collisions:0, errors:0`.

- [ ] **Step 2: Theme-coherence check across all 7 presets**

Temporarily cycle presets is out of scope to script; instead confirm no preset references a removed token and `focus()/textDisabled()/loading()` resolve: `zig build 2>&1 | tail -5` (compile is the guarantee since accessors read live `colors.*`).

- [ ] **Step 3: Write the one-paragraph foundation note**

Prepend to `components.zig`'s top comment a pointer:
```zig
// v2 primitives (calm-flat): button, card, badge, checkbox, radioGroup, slider,
// listItem, spinner, menu, modal + sectionHeader/divider/toggleRow/selectRow/
// segment/iconButton/searchInput/emptyState/tip. Tokens live in theme.zig;
// never inline dvui.Color{} / Rect.all(n) in screens — use theme.* / tk.*.
```
(Optionally create `docs/COMPONENTS.md` listing each primitive's signature for Phase 2/3 authors.)

- [ ] **Step 4: Final commit**
```bash
git add src/ui/components.zig docs/COMPONENTS.md 2>/dev/null || git add src/ui/components.zig
git commit -m "docs(ui): Phase 1 foundation complete — primitive index"
```

---

## Self-review notes (coverage vs spec)

- Spec §3.1 tokens → Task 2. §3.2 motion → Tasks 1–2. §3.3 removals → Task 16 (with accent_primary/border collapses correctly deferred, matching "additive/non-breaking"). §3.4 type scale → Task 2. §3.5 spacing/radii → Task 2.
- Spec §4 primitives (all 10) → Tasks 6–15, each with legacy aliases kept (statusPill, ProgressBar). §5 ids.zig → Task 3. §6 transparent sweep → Task 4.
- Spec §8 verification → RENDER-SMOKE (mirrors the validated widget-ID-fix harness) + `zig build test` for pure math (Task 1). Dead-token grep-gate → Task 16 Step 1.
- Deferred per spec: broad 225-site literal sweep (Phase 3), accent_primary/border alias collapse (Phase 3), focus-ring application to buttons (Phase 3).
