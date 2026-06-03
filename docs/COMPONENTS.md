# UI Component Index (Phase 1 foundation)

v2 calm-flat primitives in `src/ui/components.zig`. Tokens live in `src/ui/theme.zig`
(runtime colors via `tk.*()` accessors; comptime spacing/radii/fonts via `tk.sp_*`,
`tk.rad_*`, `tk.fs_*`). **Never** inline `dvui.Color{}` or `Rect.all(n)` in screens —
always go through `theme.*` / `tk.*`.

## Primitives

| Primitive | Signature | Returns |
|-----------|-----------|---------|
| `button` | `button(src, label, kind: ButtonKind)` | `bool` (clicked) |
| `card` | `card(src)` | `Card` (call `.deinit()`) |
| `badge` | `badge(label, kind: BadgeKind)` | `void` |
| `statusPill` | `statusPill(label, kind: {info,success,warn,err})` | `void` (legacy alias) |
| `checkbox` | `checkbox(src, label, value: *bool)` | `bool` (changed) |
| `radioGroup` | `radioGroup(src, options: []const []const u8, selected: *usize)` | `bool` (changed) |
| `slider` | `slider(src, label, value: *f32, min, max)` | `bool` (changed) |
| `listItem` | `listItem(src, id_extra, leading_icon: ?[]const u8, label, trailing)` | `bool` (clicked) |
| `spinner` | `spinner(src)` | `void` |
| `menu` | `menu(src, options: []const []const u8, selected: *usize)` | `bool` (changed) |
| `modal` | `modal(src, title, open: *bool)` | `?Modal` (call `.deinit()`) |

## Composites / helpers

| Helper | Signature | Returns |
|--------|-----------|---------|
| `sectionHeader` | `sectionHeader(label)` | `void` |
| `divider` | `divider()` | `void` |
| `toggleRow` | `toggleRow(src, label, hint: ?[]const u8, value: *bool)` | `void` |
| `selectRow` | `selectRow(src, label, options, selected: *usize)` | `void` |
| `segment` | `segment(src, options, selected: usize)` | `?usize` (new index) |
| `iconButton` | `iconButton(src, icon, tooltip, active: bool)` | `bool` (clicked) |
| `searchInput` | `searchInput(src, buf: []u8, len: *usize, placeholder)` | `bool` (changed) |
| `emptyState` | `emptyState(icon, title, hint)` | `void` |
| `tip` | `tip(src, wd, text)` / `tipId(src, wd, text, id_extra)` | `void` |
| `ProgressBar` | `ProgressBar(src, fraction: f32, label, id_extra)` | `void` (legacy) |

## Tokens (`tk.*` in components.zig → `theme.colors.*`)

- Colors (runtime): `accent_primary()`, `accent_dim()`, `bg_deep()`, `bg_surface()`,
  `bg_elevated()`, `bg_hover()`, `bg_muted()`, `text_primary()`, `text_secondary()`,
  `text_tertiary()`, `text_on_accent()`, `semantic_success()`, `semantic_warn()`,
  `semantic_error()`, `border_subtle()`, `border_strong()`.
- Spacing (comptime): `sp_xs sp_sm sp_md sp_lg sp_xl sp_xxl`.
- Radii (comptime): `rad_sm rad_md rad_lg rad_pill`.
- Font sizes (comptime): `fs_micro fs_small fs_body fs_title fs_display`; `fontAt(size)`.

7 theme presets: midnight / abyss / phantom / nord / solarized / rose / ember.
