# UI Navigation & IA (Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Risk gating:** Each task is labeled **safe-autonomous** or **needs-approval**. An executor running unattended must implement only the **safe-autonomous** tasks (1–7) and STOP before Task 8. Task 8 (`settings.zig` split) is a large, high-risk refactor and runs **only with explicit human approval**.

**Goal:** Make Opal's navigation legible: group the 14 drawer tabs into named **Sources / Library / System** groups, unify the hand-rolled modal chrome onto the Phase-1 `components.modal` primitive, add a **command palette** and bind the conventional **`?`** key to the existing shortcut overlay — all additive and non-breaking, so each lands independently.

**Architecture:** Additive. A `DrawerGroup` data table drives rail layout without touching the `DrawerTab` enum or the body-routing switch. The two workspace modals + the cheat sheet are converted *in place* to `components.modal` / calm tokens (open-flag booleans unchanged). A new `src/ui/command_palette.zig` overlay (modeled on the settings-search filter pattern) is dispatched from `appFrame()` and opened by Ctrl/Cmd+K. The `?` key is added to `processGlobalInputs` next to the existing Shift+I. The risky `settings.zig` split is isolated as an approval-gated final task.

**Tech Stack:** Zig 0.16.x, dvui (immediate-mode), `theme.zig` tokens, `components.zig` primitives, `io_global` wrappers.

**Spec:** `docs/superpowers/specs/2026-06-03-ui-nav-ia-phase2-design.md`

**Conventions (from the roadmap §Constraints — no `CLAUDE.md` exists on this branch):** use `io_global` wrappers (not `std.fs`/`std.time`); single global allocator (`@import("../core/alloc.zig").allocator`); `id_extra` discipline for any widget emitted in a loop or from a shared `@src()` (see the landed `divider_seq`/`sectionheader_seq`/`badge_seq` pattern in `components.zig`); pure tests only for modules that don't cross the `io_global` boundary; **no `zigzag`→`opal` rename**. **Commits:** this plan commits locally at each task for checkpointing; do **not** push. If the user prefers, stage-only and let them commit.

**Real primitive signatures (verified in `src/ui/components.zig` — do NOT invent variants):**
- `modal(src: SourceLocation, title: []const u8, open: *bool) ?Modal` → returns the frame; caller renders body then `m.deinit()`. Draws title + close-X, flips `open.*` via dvui `open_flag`. (`components.zig:807`)
- `menu(src, options: []const []const u8, selected: *usize) bool` (`components.zig:780`)
- `listItem(src, id_extra: usize, leading_icon: ?[]const u8, label: []const u8, trailing: []const u8) bool` (`components.zig:716`)
- `searchInput(src, buf: []u8, len: *usize, placeholder: []const u8) bool` (`components.zig:479`)
- `card(src) Card` → `var c = components.card(@src()); defer c.deinit();` (`components.zig:577`)
- `sectionHeader(label: []const u8) void` (`components.zig:133`)
- `button(src, label, kind: ButtonKind) bool` where `ButtonKind = .primary|.secondary|.ghost|.danger` (`components.zig:543`)
- `emptyState(icon, title, hint) void` (`components.zig:436`)
- `iconButton(src, icon, tooltip, active: bool) bool` (`components.zig:378`)

**Verification recipe (reused by every task) — call this "VERIFY":**
```bash
# 1. build  (rc 0 = green; ignore SDL2 'ld.lld ... neither ET_REL' warnings and the
#    cosmetic 'compile exe zigzag Debug native failure' label — only nonzero rc / Zig
#    'error:' lines are real)
zig build 2>&1 | tail -8; echo "build rc=$?"
# 2. render smoke (no foreground sleep — timeout handles wall time; harness kills busy-loops)
rm -f /tmp/zz.log
timeout --preserve-status 5 env DISPLAY=:1 ./zig-out/bin/zigzag > /tmp/zz.log 2>&1 || true
echo "errors:"; grep -vi "0 memory leaks" /tmp/zz.log | grep -ci "error\|panic\|leak"   # expect 0
```
Expected every time: **build rc=0** and **errors: 0**.

> **`zig build test` caveat:** `zig build test` has a KNOWN pre-existing failure in the `src/core/paths.zig` module (libc `getenv`) **unrelated to this UI work**. Do NOT treat it as a Phase 2 regression. None of the Tasks 1–8 add pure-testable logic that crosses the `io_global` boundary, so VERIFY (build + render-smoke) is the gate; run `zig build test` only to confirm you did not *increase* the failure count beyond the known `paths.zig` one.

---

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `src/ui/drawer.zig` (modify) | Add `DrawerGroup` table; route rail group rendering through it. | 1 |
| `src/ui/ui.zig` (modify) | Convert the two workspace modals to `components.modal`; delete hand-rolled chrome. | 2, 3, 4 |
| `src/ui/command_palette.zig` (new) | Calm-flat command palette overlay (searchInput + filtered listItem nav list). | 5 |
| `src/main.zig` (modify) | One dispatch line for the palette in `appFrame()`. | 5 |
| `src/core/state.zig` (modify) | One ephemeral-free `command_palette_open: bool` flag (or keep palette state module-local — see Task 5). | 5 |
| `src/ui/input.zig` (modify) | Ctrl/Cmd+K → open palette; `?` (Shift+/) → toggle cheat sheet. | 6, 7 |
| `src/ui/settings.zig` (modify) | Re-skin `renderCheatSheet` onto calm tokens. | 7 |
| `settings_root.zig` + per-tab modules (new) | **Approval-gated** settings split. | 8 |

---

## Task 1: Drawer group table (Sources / Library / System)

**Risk: safe-autonomous.** Additive data table; no enum reorder, no body-routing change.

**Files:**
- Modify: `src/ui/drawer.zig` (rail block `189-234`; helpers `renderRailTab` `277`, `railGroupGap` `351`)

- [ ] **Step 1: Add the group model**

Near the top of `drawer.zig` (after the rail layout consts ~`32-45`), add:
```zig
/// A named drawer group — drives rail layout + (future) palette grouping.
/// References existing `state.DrawerTab` tags by name; NEVER reorders the enum
/// (reorder would drift @intFromEnum-persisted config). Sources/Library/System
/// per the Phase 2 IA spec.
const RailEntry = struct {
    tab: state.DrawerTab,
    icon: @TypeOf(icons.tvg.lucide.@"search"),
    label: []const u8,
    id: usize,
};
const DrawerGroup = struct {
    name: []const u8,
    entries: []const RailEntry,
};

const drawer_groups = [_]DrawerGroup{
    .{ .name = "Sources", .entries = &.{
        .{ .tab = .Search,   .icon = icons.tvg.lucide.@"search",   .label = "Search",   .id = 0 },
        .{ .tab = .TMDB,     .icon = icons.tvg.lucide.@"film",     .label = "TMDB",     .id = 3 },
        .{ .tab = .YouTube,  .icon = icons.tvg.lucide.@"play",     .label = "YouTube",  .id = 4 },
        .{ .tab = .Anime,    .icon = icons.tvg.lucide.@"zap",      .label = "Anime",    .id = 5 },
        .{ .tab = .Comics,   .icon = icons.tvg.lucide.@"image",    .label = "Comics",   .id = 6 },
        .{ .tab = .RSS,      .icon = icons.tvg.lucide.@"rss",      .label = "RSS",      .id = 7 },
        .{ .tab = .Jellyfin, .icon = icons.tvg.lucide.@"server",   .label = "Jellyfin", .id = 8 },
    } },
    .{ .name = "Library", .entries = &.{
        .{ .tab = .Downloads, .icon = icons.tvg.lucide.@"download", .label = "Downloads", .id = 1 },
        .{ .tab = .Queue,     .icon = icons.tvg.lucide.@"list",     .label = "Queue",     .id = 2 },
        .{ .tab = .History,   .icon = icons.tvg.lucide.@"clock",    "History" ,           .id = 9 },
    } },
    .{ .name = "System", .entries = &.{
        .{ .tab = .AI,       .icon = icons.tvg.lucide.@"brain",    .label = "AI",       .id = 14 },
        .{ .tab = .Plugins,  .icon = icons.tvg.lucide.@"package",  .label = "Plugins",  .id = 11 },
        .{ .tab = .Settings, .icon = icons.tvg.lucide.@"settings", .label = "Settings", .id = 13 },
    } },
};
```
> If `@TypeOf(icons.tvg.lucide.@"search")` is awkward for the struct field, match the inferred type the way `renderRailTab` already accepts it: `icon_data: anytype`. In that case make the field `icon: [:0]const u8` if the lucide values are sentinel slices, or store the icon as `anytype` is not allowed in a struct — fall back to `[]const u8` and pass through unchanged. The build will tell you the concrete type; copy whatever `renderRailTab`'s existing `icon_data` callers pass. **Fix the `"History"` line to `.label = "History"` (typo guard).**

- [ ] **Step 2: Drive the rail loop from the table**

Replace the hand-listed `renderRailTab(...)` calls in the rail block (`drawer.zig:189-211`, the "Group 1/2/3" comment region) with a loop over `drawer_groups`, keeping `railGroupGap` between groups:
```zig
        for (drawer_groups, 0..) |grp, gi| {
            for (grp.entries) |e| {
                renderRailTab(e.tab, e.icon, e.label, e.id);
            }
            if (gi + 1 < drawer_groups.len) railGroupGap(gi);
        }
```
Leave the bottom-rail group (`drawer.zig:216-233`: Logs/Expand/Close via `renderBottomIcon`) **unchanged** — it is action-rail, not tabs. Leave the body-routing `switch` (`drawer.zig:248-264`) **unchanged**.

- [ ] **Step 3: VERIFY** → build rc=0, errors 0. Manually confirm in the render log the drawer still opens and all 14 tabs route (no panic on tab switch). The visual grouping is now Sources(7)/Library(3)/System(3) instead of the old Find&Manage/Sources/Configure clusters.

- [ ] **Step 4: Commit**
```bash
git add src/ui/drawer.zig
git commit -m "feat(ui): group drawer tabs into Sources/Library/System via a data table"
```

---

## Task 2: Convert the Save Workspace modal to `components.modal`

**Risk: safe-autonomous.** In-place chrome replacement; open flag unchanged.

**Files:**
- Modify: `src/ui/ui.zig` (`renderWorkspaceModals`, Save block `145-248`)

- [ ] **Step 1: Replace the hand-rolled frame + header with the primitive**

In `renderWorkspaceModals`, replace the Save block. The `dvui.floatingWindow(...)` + the entire header box (`ui.zig:159-189`) collapse into one `components.modal` call; keep the **body** widgets (name label, `textEntry`, Save/Cancel buttons) verbatim:
```zig
    if (components.modal(@src(), "Save Workspace", &state.app.ws_save_open)) |*m| {
        var body = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .padding = .{ .x = theme.spacing.lg, .y = theme.spacing.md, .w = theme.spacing.lg, .h = theme.spacing.md },
        });

        _ = dvui.label(@src(), "Workspace name:", .{}, .{
            .color_text = theme.colors.text_secondary,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.xs },
        });

        var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.ws_name_input } }, .{
            .expand = .horizontal,
            .color_fill = theme.colors.bg_elevated,
            .color_text = theme.colors.text_primary,
            .color_border = theme.colors.border_subtle,
            .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
        });
        const enter_pressed = te.enter_pressed;
        te.deinit();

        { var gap = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = 0, .h = theme.spacing.sm } }); gap.deinit(); }

        var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        if (components.button(@src(), "Save", .primary) or enter_pressed) {
            const name_len = std.mem.indexOfScalar(u8, &state.app.ws_name_input, 0) orelse state.app.ws_name_input.len;
            if (name_len > 0) {
                workspace.saveWorkspaceNamed(@import("../core/alloc.zig").allocator, state.app.ws_name_input[0..name_len]);
                state.app.ws_save_open = false;
            }
        }
        { var s = dvui.box(@src(), .{}, .{ .expand = .horizontal }); s.deinit(); }
        if (components.button(@src(), "Cancel", .ghost)) {
            state.app.ws_save_open = false;
        }
        btn_row.deinit();

        body.deinit();
        m.deinit();
    }
```
> `components.modal` already draws the title bar + close-X and flips `state.app.ws_save_open` via `open_flag`, so the entire hand-rolled header (`ui.zig:159-189`) is deleted. The old `if (state.app.ws_save_open) { var win = dvui.floatingWindow(... ); defer win.deinit(); ... }` wrapper is fully replaced by the `if (components.modal(...)) |*m|` form (the primitive's `if (!open.*) return null;` does the gating). **Do not keep the old `defer win.deinit()`** — `m.deinit()` owns teardown.

- [ ] **Step 2: VERIFY** → build rc=0, errors 0. In the render log confirm no `duplicate widget id` and no panic. (Open path can't be auto-driven; the smoke proves it compiles + renders the frame without the modal flag set.)

- [ ] **Step 3: Commit**
```bash
git add src/ui/ui.zig
git commit -m "refactor(ui): convert Save Workspace modal to components.modal chrome"
```

---

## Task 3: Convert the Load Workspace modal to `components.modal`

**Risk: safe-autonomous.** Same pattern as Task 2.

**Files:**
- Modify: `src/ui/ui.zig` (Load block `253-338`)

- [ ] **Step 1: Replace frame + header; keep the list body**
```zig
    if (components.modal(@src(), "Load Workspace", &state.app.ws_load_open)) |*m| {
        var body = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .padding = .{ .x = theme.spacing.lg, .y = theme.spacing.md, .w = theme.spacing.lg, .h = theme.spacing.md },
        });

        if (state.app.ws_count == 0) {
            _ = dvui.label(@src(), "No saved workspaces yet.", .{}, .{
                .color_text = theme.colors.text_secondary,
                .gravity_x = 0.5,
                .margin = .{ .x = 0, .y = theme.spacing.md, .w = 0, .h = theme.spacing.xs },
            });
            _ = dvui.label(@src(), "Save one first with the save button.", .{}, .{
                .color_text = theme.colors.text_tertiary,
                .gravity_x = 0.5,
                .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.md },
            });
        } else {
            for (0..state.app.ws_count) |wi| {
                const name = state.app.ws_names[wi][0..state.app.ws_name_lens[wi]];
                if (components.listItem(@src(), wi, icons.tvg.lucide.@"folder", name, "")) {
                    workspace.loadWorkspaceNamed(@import("../core/alloc.zig").allocator, name);
                    state.app.ws_load_open = false;
                }
            }
        }

        body.deinit();
        m.deinit();
    }
```
> `components.listItem(@src(), wi, …)` passes the loop index `wi` as `id_extra` — this is exactly the discipline the primitive expects for looped rows (see its doc-comment `components.zig:713-715`). It replaces the old hand-styled `dvui.button` rows (`ui.zig:319-335`) and their `border_card`/`bg_card`/`text_main`/`divider` legacy tokens.

- [ ] **Step 2: VERIFY** → build rc=0, errors 0.

- [ ] **Step 3: Commit**
```bash
git add src/ui/ui.zig
git commit -m "refactor(ui): convert Load Workspace modal to components.modal + listItem"
```

---

## Task 4: Prune now-dead modal helpers + confirm no orphan tokens

**Risk: safe-autonomous.** Cleanup only.

**Files:**
- Modify: `src/ui/ui.zig`

- [ ] **Step 1: Confirm the legacy chrome is fully gone**

After Tasks 2–3, grep `ui.zig` for the patterns the conversions were meant to delete:
```bash
grep -n "bg_header\|border_card\|text_main\|text_muted\|windowHeader" src/ui/ui.zig   # expect: no matches in renderWorkspaceModals
grep -cn "floatingWindow" src/ui/ui.zig                                                # expect: 0 inside renderWorkspaceModals
```
If any `dvui.floatingWindow(` remains inside `renderWorkspaceModals`, that modal was not converted — finish it before committing.

- [ ] **Step 2: Remove unused imports if now-orphaned**

Check whether any top-of-file `const … = @import(...)` in `ui.zig` is now unused after the chrome deletion (Zig errors on unused locals but tolerates unused top-level imports; remove genuinely dead ones for cleanliness only — do NOT remove `components`, `theme`, `state`, `icons`, or `workspace`). When unsure, leave it; an unused import never breaks the build.

- [ ] **Step 3: VERIFY** → build rc=0, errors 0.

- [ ] **Step 4: Commit**
```bash
git add src/ui/ui.zig
git commit -m "chore(ui): drop dead hand-rolled workspace-modal chrome"
```

---

## Task 5: Command palette overlay (`command_palette.zig`)

**Risk: safe-autonomous.** New file + one dispatch line + one state flag; additive.

**Files:**
- Create: `src/ui/command_palette.zig`
- Modify: `src/core/state.zig` (add `command_palette_open: bool = false` next to `cheatsheet_open` at `state.zig:169`)
- Modify: `src/main.zig` (dispatch in `appFrame()` overlay block, after `settings.renderCheatSheet();` at `main.zig:1051`)

- [ ] **Step 1: Add the state flag**

In `state.zig`, beside `cheatsheet_open: bool = false,` (`state.zig:169`), add:
```zig
    command_palette_open: bool = false,
```

- [ ] **Step 2: Create the palette**
```zig
const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");

// Ephemeral palette state (module-local, mirroring header.zig's HeaderState).
const PaletteState = struct {
    var query_buf: [128]u8 = std.mem.zeroes([128]u8);
    var query_len: usize = 0;
};

/// A navigation/chrome command. `tab` non-null = jump to that drawer tab;
/// otherwise `action` runs.
const Command = struct {
    label: []const u8,
    icon: []const u8,
    tab: ?state.DrawerTab = null,
    action: ?*const fn () void = null,
};

fn actToggleTheme() void {
    theme.cycleTheme();
    state.showToast(theme.presetName(theme.active_preset));
}
fn actShortcuts() void {
    state.app.cheatsheet_open = true;
}

fn commands() []const Command {
    const C = struct {
        const list = [_]Command{
            .{ .label = "Go: Search",    .icon = icons.tvg.lucide.@"search",   .tab = .Search },
            .{ .label = "Go: Downloads", .icon = icons.tvg.lucide.@"download", .tab = .Downloads },
            .{ .label = "Go: Queue",     .icon = icons.tvg.lucide.@"list",     .tab = .Queue },
            .{ .label = "Go: History",   .icon = icons.tvg.lucide.@"clock",    .tab = .History },
            .{ .label = "Go: TMDB",      .icon = icons.tvg.lucide.@"film",     .tab = .TMDB },
            .{ .label = "Go: YouTube",   .icon = icons.tvg.lucide.@"play",     .tab = .YouTube },
            .{ .label = "Go: Anime",     .icon = icons.tvg.lucide.@"zap",      .tab = .Anime },
            .{ .label = "Go: Comics",    .icon = icons.tvg.lucide.@"image",    .tab = .Comics },
            .{ .label = "Go: RSS",       .icon = icons.tvg.lucide.@"rss",      .tab = .RSS },
            .{ .label = "Go: Jellyfin",  .icon = icons.tvg.lucide.@"server",   .tab = .Jellyfin },
            .{ .label = "Go: AI",        .icon = icons.tvg.lucide.@"brain",    .tab = .AI },
            .{ .label = "Go: Plugins",   .icon = icons.tvg.lucide.@"package",  .tab = .Plugins },
            .{ .label = "Go: Settings",  .icon = icons.tvg.lucide.@"settings", .tab = .Settings },
            .{ .label = "Go: Logs",      .icon = icons.tvg.lucide.@"terminal", .tab = .Logs },
            .{ .label = "Cycle Theme",       .icon = icons.tvg.lucide.@"palette", .action = actToggleTheme },
            .{ .label = "Keyboard Shortcuts",.icon = icons.tvg.lucide.@"info",    .action = actShortcuts },
        };
    };
    return &C.list;
}

fn matches(label: []const u8, q: []const u8) bool {
    if (q.len == 0) return true;
    // case-insensitive substring (mirrors settings.zig matchesSearch intent)
    var i: usize = 0;
    outer: while (i + q.len <= label.len) : (i += 1) {
        var j: usize = 0;
        while (j < q.len) : (j += 1) {
            if (std.ascii.toLower(label[i + j]) != std.ascii.toLower(q[j])) continue :outer;
        }
        return true;
    }
    return false;
}

fn runCommand(cmd: Command) void {
    if (cmd.tab) |t| {
        state.app.drawer_open = true;
        state.app.drawer_tab = t;
    } else if (cmd.action) |a| {
        a();
    }
    state.app.command_palette_open = false;
    @memset(&PaletteState.query_buf, 0);
    PaletteState.query_len = 0;
}

pub fn render() void {
    if (!state.app.command_palette_open) return;

    var win = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &state.app.command_palette_open,
    }, .{
        .min_size_content = .{ .w = 460, .h = 360 },
        .color_fill = theme.colors.bg_surface,
        .color_border = theme.colors.border_subtle,
        .border = dvui.Rect.all(1),
        .corner_radius = dvui.Rect.all(theme.radius.lg),
    });
    defer win.deinit();

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = theme.spacing.md, .y = theme.spacing.md, .w = theme.spacing.md, .h = theme.spacing.md },
    });
    defer body.deinit();

    _ = components.searchInput(@src(), &PaletteState.query_buf, &PaletteState.query_len, "Type a command…");

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .color_fill = theme.transparent });
    defer scroll.deinit();

    const q = PaletteState.query_buf[0..PaletteState.query_len];
    var any = false;
    for (commands(), 0..) |cmd, i| {
        if (!matches(cmd.label, q)) continue;
        any = true;
        if (components.listItem(@src(), i, cmd.icon, cmd.label, "")) {
            runCommand(cmd);
            return; // list/state changed
        }
    }
    if (!any) {
        components.emptyState(icons.tvg.lucide.@"search-x", "No commands", "Try a different search");
    }
}
```
> Signatures used are exact: `searchInput(src, []u8, *usize, []const u8) bool`, `listItem(src, usize, ?[]const u8, []const u8, []const u8) bool` (the icon is a non-null `[]const u8` here), `emptyState([]const u8 ×3)`. The `actToggleTheme` body mirrors the header's theme-cycle (`header.zig:294-297`). If `icons.tvg.lucide.@"search-x"` doesn't exist in this icon set, fall back to `@"search"` — the build will say.

- [ ] **Step 3: Dispatch in `appFrame()`**

In `main.zig`, after `settings.renderCheatSheet();` (`main.zig:1051`), add:
```zig
    @import("ui/command_palette.zig").render();
```

- [ ] **Step 4: VERIFY** → build rc=0, errors 0. The palette is gated `if (!state.app.command_palette_open) return;` so the smoke run (flag false) just proves it compiles + links cleanly.

- [ ] **Step 5: Commit**
```bash
git add src/ui/command_palette.zig src/core/state.zig src/main.zig
git commit -m "feat(ui): command palette overlay (nav + chrome commands)"
```

---

## Task 6: Bind Ctrl/Cmd+K to open the command palette

**Risk: safe-autonomous.** One keybinding; integrates with the existing staged-Esc close.

**Files:**
- Modify: `src/ui/input.zig` (`processGlobalInputs`, in the `if (mod.control())` block ~`input.zig:46-60`)

- [ ] **Step 1: Add the keybind**

Inside the `if (mod.control()) { … }` block in `processGlobalInputs` (alongside the existing `.comma`/`.o`/`.q` handlers at `input.zig:47-59`), add:
```zig
                if (key == .k) {
                    state.app.command_palette_open = !state.app.command_palette_open;
                    dvui.refresh(null, @src(), null);
                    continue;
                }
```
> This lives in the *always-active* control block (before the "text entry focused ⇒ suppress single-key shortcuts" guard at `input.zig:63`), so Ctrl/Cmd+K works even from a focused input. Esc already closes modal floating windows via dvui's `open_flag` + the staged-close chain (`input.zig:31-43`), so no separate close binding is needed.

- [ ] **Step 2: VERIFY** → build rc=0, errors 0.

- [ ] **Step 3: Commit**
```bash
git add src/ui/input.zig
git commit -m "feat(ui): bind Ctrl/Cmd+K to toggle the command palette"
```

---

## Task 7: Bind `?` to the shortcut overlay + calm re-skin

**Risk: safe-autonomous.** One keybind + presentation-only token swap.

**Files:**
- Modify: `src/ui/input.zig` (the no-modifier `switch (key)` block ~`input.zig:169-287`)
- Modify: `src/ui/settings.zig` (`renderCheatSheet` `2110-2240`)

- [ ] **Step 1: Bind `?` (Shift+/)**

The `?` glyph is **Shift + slash**. Add a handler. Because `?` requires Shift, it must sit *outside* the `if (!mod.shift() …)` no-modifier block. Place it next to the existing Shift+I cheat-sheet toggle path — add, in the always-active region (e.g. right after the Escape/Ctrl block, before the text-focus guard at `input.zig:63`, so `?` opens help even while typing is debatable; to match Shift+I which is suppressed while typing, instead add it in the no-modifier-OR-shift area):
```zig
            // ? (Shift+/) = Keyboard shortcuts overlay (same target as Shift+I)
            if (key == .slash and mod.shift() and !mod.control() and !mod.alt()) {
                if (dvui.focusedWidgetId() == null) {
                    state.app.cheatsheet_open = !state.app.cheatsheet_open;
                    dvui.refresh(null, @src(), null);
                    continue;
                }
            }
```
> Verify the key enum name in this dvui tree: it is `dvui.enums.Key.slash` (the same family as `.comma`/`.period`/`.left_bracket` already used in `input.zig:397-398,377`). If `.slash` is spelled differently here, grep `input.zig` neighbors — `.left_bracket` and `.right_bracket` confirm the punctuation-key naming convention. The `focusedWidgetId() == null` guard mirrors the existing single-key suppression so `?` typed into a text field still types a literal `?`.

- [ ] **Step 2: Calm re-skin of `renderCheatSheet`**

In `settings.zig:2110-2240`, swap the legacy tokens to calm ones (presentation only — keep the shortcut/keyword tables and layout intact):
- frame `color_fill = theme.colors.bg_drawer` → `theme.colors.bg_surface`; add `.color_border = theme.colors.border_subtle, .border = dvui.Rect.all(1), .corner_radius = dvui.Rect.all(theme.radius.lg)` (replacing `border_drawer` at `settings.zig:2119`).
- key labels `color_text = theme.colors.accent` → `theme.colors.accent_primary` (both shortcut keys `settings.zig:2189` and keyword keys `settings.zig:2201,2231`).
- description text `color_text = theme.colors.text_main` → `theme.colors.text_primary` (`settings.zig:2195,2237`).

Leave `dvui.windowHeader(...)` (`settings.zig:2123`) and the `dvui.scale` (`settings.zig:2125-2127`) as-is — converting the cheat sheet to `components.modal` is *not* in scope here (it would drop the draggable window header). This task is a token swap + the `?` keybind only.

- [ ] **Step 3: VERIFY** → build rc=0, errors 0. The overlay is reachable by Shift+I, the header info icon, and now `?`.

- [ ] **Step 4: Commit**
```bash
git add src/ui/input.zig src/ui/settings.zig
git commit -m "feat(ui): bind '?' to the shortcut overlay and re-skin it onto calm tokens"
```

---

## Task 8: Split `settings.zig` into `_root` + per-tab modules  ⚠️

**Risk: needs-approval — HIGH-RISK, LARGE REFACTOR. Execute ONLY with explicit human approval.** An unattended executor must STOP after Task 7 and surface this task for review. Do not start it autonomously.

**Why it's gated:** `settings.zig` is **2767 lines** (`settings.zig` is the single largest UI file) and is imported by the drawer body router (`drawer.zig:261-263`) and `appFrame` overlays (`main.zig:1049-1053`). It owns `renderSettingsModal`/`renderSettingsContent`/`renderAIContent`/`renderCheatSheet`/`renderDepsModal`/`renderMediaInfo` plus the 8-tab `SettingsTab` nav and every per-tab section renderer. A bad split silently breaks settings persistence or the AI panel. This is surface-area, not logic — but the surface is huge.

**Files (proposed — finalize with the approver):**
- Create: `src/ui/settings_root.zig` (the modal shell, search box, `nav_tabs` table `settings.zig:120-132`, `navTabRow`, `renderRightPane`, and the `switch (state.app.settings_tab)` dispatch).
- Create one module per `SettingsTab` (`state.zig:18`): `settings_general.zig`, `settings_playback.zig`, `settings_subtitles.zig`, `settings_network.zig`, `settings_storage.zig`, `settings_scripts.zig`, `settings_langlearn.zig`, `settings_fileassoc.zig` — each exporting the section renderers currently inlined for that tab.
- Keep `settings.zig` as a **thin re-export facade** so existing call sites (`drawer.zig`, `main.zig`) keep working unchanged:
  ```zig
  pub const renderSettingsModal   = @import("settings_root.zig").renderSettingsModal;
  pub const renderSettingsContent = @import("settings_root.zig").renderSettingsContent;
  pub const renderAIContent       = @import("settings_root.zig").renderAIContent;
  pub const renderCheatSheet      = @import("settings_cheatsheet.zig").renderCheatSheet;
  // …deps/mediaInfo likewise
  ```

- [ ] **Step 0 (BLOCKING): obtain explicit approval.** If not granted, skip this task entirely and finish the plan at Task 7.
- [ ] **Step 1:** Carve the modal shell + nav into `settings_root.zig`; leave the facade re-exporting it. VERIFY (build rc=0, errors 0).
- [ ] **Step 2:** Move ONE tab's section renderers into its module; update the dispatch switch to call the new module; keep `sectionHeader`/`bigTitle` helpers shared (re-export or duplicate the tiny ones). VERIFY after each tab — one tab per commit so a regression is bisectable.
- [ ] **Step 3:** Repeat per tab. After each: VERIFY + `git commit -m "refactor(ui): extract settings <Tab> into settings_<tab>.zig"`.
- [ ] **Step 4:** Re-skin each tab's sections onto `components.card` hierarchy (the V2-ROADMAP Wave 2 #6 card-hierarchy goal) — optionally, only if the approver wants it in this phase; otherwise defer card hierarchy to Phase 3 screen-polish.
- [ ] **Step 5 (final):** Confirm `settings.zig` is now only a re-export facade; full VERIFY + `zig build test` (expect only the known `paths.zig` failure, no new ones). Confirm the settings drawer tab, the Ctrl+, modal, and the AI tab all still render via the render log.
- [ ] **Step 6:** Commit `refactor(ui): settings.zig becomes a thin re-export facade over per-tab modules`.

---

## Self-review notes (coverage vs spec)

- Spec §3.1 group taxonomy → **Task 1** (data table; no enum reorder; body switch untouched).
- Spec §3.2 modal unification → **Tasks 2–4** (Save, Load, prune). Stream-key popover + cheat-sheet `windowHeader` deliberately **not** converted to `components.modal` (drag-area behavior) — only the cheat sheet is *re-skinned* in Task 7.
- Spec §3.3 command palette → **Tasks 5–6** (overlay + Ctrl/Cmd+K). Reuses `searchInput`+`listItem`+`emptyState` real signatures; navigation-only, does not touch the unified input router (`input.zig:484`).
- Spec §3.4 `?` overlay → **Task 7** (Shift+/ keybind + calm re-skin of the existing `renderCheatSheet`).
- Spec §2.5 settings split → **Task 8**, isolated, approval-gated, one-tab-per-commit for bisectability.
- All tasks additive + independently buildable + committable; risk class on each. VERIFY (build + render-smoke) is the gate; `zig build test`'s known `paths.zig` failure is explicitly excluded from regression counting.
