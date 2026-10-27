//! Household profiles UI (ROADMAP 7.3): the "Who's watching?" picker shown at
//! launch / on switch, the avatar menu in the top bar, Settings > Profiles, and
//! the kid-mode lock on Settings and source management.
//!
//! Every colour is a theme token read per frame (profile colours map to
//! accent/success/warning/danger/text_secondary); buttons and toggles come from
//! components.zig; icons are lucide.

const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const theme = @import("theme.zig");
const components = @import("components.zig");
const state = @import("../core/state.zig");
const profiles = @import("../services/profiles.zig");
const pure = @import("../services/profiles_pure.zig");

// ── UI-thread state ──────────────────────────────────────────────────────────
var switch_open: bool = false;
var target: [pure.ID_MAX]u8 = std.mem.zeroes([pure.ID_MAX]u8);
var target_len: usize = 0;
var pin_buf: [pure.PIN_MAX + 1]u8 = std.mem.zeroes([pure.PIN_MAX + 1]u8);
var message: [96]u8 = std.mem.zeroes([96]u8);
var message_len: usize = 0;

// Settings > Profiles
var new_name: [pure.NAME_MAX + 1]u8 = std.mem.zeroes([pure.NAME_MAX + 1]u8);
var new_pin: [pure.PIN_MAX + 1]u8 = std.mem.zeroes([pure.PIN_MAX + 1]u8);
var new_kid: bool = false;
var edit_id: [pure.ID_MAX]u8 = std.mem.zeroes([pure.ID_MAX]u8);
var edit_len: usize = 0;
var edit_name: [pure.NAME_MAX + 1]u8 = std.mem.zeroes([pure.NAME_MAX + 1]u8);
var edit_pin: [pure.PIN_MAX + 1]u8 = std.mem.zeroes([pure.PIN_MAX + 1]u8);

fn zText(buf: []const u8) []const u8 {
    return buf[0 .. std.mem.indexOfScalar(u8, buf, 0) orelse buf.len];
}

fn setMessage(text: []const u8) void {
    const n = @min(text.len, message.len);
    @memcpy(message[0..n], text[0..n]);
    message_len = n;
}

/// Profile colour -> theme token (per frame, so presets apply).
pub fn colorOf(c: pure.Color) dvui.Color {
    return switch (c) {
        .accent => theme.colors.accent,
        .green => theme.colors.success,
        .amber => theme.colors.warning,
        .red => theme.colors.danger,
        .slate => theme.colors.text_secondary,
    };
}

const COLOR_LABELS = [_][]const u8{ "Opal", "Green", "Amber", "Red", "Slate" };

/// Round avatar with the name's first letter.
fn avatar(p: *const pure.Profile, size: f32, id_extra: usize) void {
    var circle = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = id_extra,
        .background = true,
        .color_fill = colorOf(p.color),
        .corner_radius = dvui.Rect.all(theme.radius.pill),
        .min_size_content = .{ .w = size, .h = size },
        .max_size_content = .{ .w = size, .h = size },
        .gravity_x = 0.5,
        .gravity_y = 0.5,
    });
    defer circle.deinit();
    const name = p.nameText();
    const initial_len: usize = if (name.len == 0) 0 else (std.unicode.utf8ByteSequenceLength(name[0]) catch 1);
    var f = dvui.themeGet().font_body;
    f.size = if (size >= 40) theme.font_size.display else theme.font_size.body;
    _ = dvui.labelNoFmt(@src(), name[0..@min(initial_len, name.len)], .{ .align_x = 0.5, .align_y = 0.5 }, .{
        .id_extra = id_extra,
        .color_text = theme.colors.text_on_accent,
        .font = f,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
    });
}

// ── Picker ───────────────────────────────────────────────────────────────────

/// Open the switcher (avatar menu), optionally preselecting a profile.
pub fn openSwitcher(id: ?[]const u8) void {
    switch_open = true;
    @memset(&pin_buf, 0);
    message_len = 0;
    target_len = 0;
    if (id) |v| selectTarget(v);
}

fn selectTarget(id: []const u8) void {
    const n = @min(id.len, target.len);
    @memcpy(target[0..n], id[0..n]);
    target_len = n;
    @memset(&pin_buf, 0);
    message_len = 0;
    // No PIN needed -> go straight away.
    if (profiles.pinSourceFor(id)) |src| {
        if (src == .none) attemptSwitch();
    }
}

fn attemptSwitch() void {
    const id = target[0..target_len];
    switch (profiles.requestSwitch(id, zText(&pin_buf))) {
        .switching => setMessage("Switching profile..."),
        .same => {
            switch_open = false;
            target_len = 0;
        },
        .not_found => {
            setMessage("That profile no longer exists");
            target_len = 0;
        },
        .pin_required => |src| setMessage(if (src == .owner) "Enter the main profile's PIN to leave kid mode" else "Enter PIN"),
        .bad_pin => setMessage("Wrong PIN"),
        .locked_ms => |ms| {
            var b: [64]u8 = undefined;
            setMessage(std.fmt.bufPrint(&b, "Too many tries - wait {d}s", .{@divTrunc(ms + 999, 1000)}) catch "Too many tries");
        },
        .storage => setMessage("Could not save the profile choice"),
    }
    @memset(&pin_buf, 0);
}

/// Called every frame from appFrame (above the shell). Enforces kid mode and
/// draws the picker when the launch needs one or the switcher is open.
pub fn renderPicker() void {
    profiles.enforce();
    const at_launch = profiles.pickerNeeded();
    if (!at_launch and !switch_open) return;
    if (profiles.restartRequested()) {
        message_len = 0;
    }

    var open_flag = true;
    const size = theme.fitWindowSize(.{ .w = 560, .h = 360 }, .{ .w = 300, .h = 260 });
    var win = dvui.floatingWindow(@src(), .{ .modal = true, .open_flag = &open_flag }, .{
        .min_size_content = size,
        .color_fill = theme.colors.bg_surface,
        .corner_radius = dvui.Rect.all(theme.radius.lg),
    });
    defer win.deinit();
    if (!at_launch) win.dragAreaSet(dvui.windowHeader("Switch profile", "", &open_flag));

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = dvui.Rect.all(theme.spacing.xl),
    });
    defer body.deinit();

    var title_font = dvui.themeGet().font_body;
    title_font.size = theme.font_size.display;
    _ = dvui.labelNoFmt(@src(), "Who's watching?", .{ .align_x = 0.5 }, .{
        .gravity_x = 0.5,
        .font = title_font,
        .color_text = theme.colors.text_primary,
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.lg },
    });

    var list: [pure.MAX_PROFILES]pure.Profile = undefined;
    const n = profiles.snapshot(&list);
    const running = profiles.runningProfile();
    {
        var tiles = dvui.flexbox(@src(), .{ .justify_content = .center }, .{ .expand = .horizontal });
        defer tiles.deinit();
        for (list[0..n], 0..) |*p, i| {
            const selected = target_len > 0 and std.mem.eql(u8, target[0..target_len], p.idText());
            var bw: dvui.ButtonWidget = undefined;
            bw.init(@src(), .{}, .{
                .id_extra = i,
                .color_fill = if (selected) theme.colors.bg_elevated else theme.transparent,
                .color_fill_hover = theme.colors.bg_hover,
                .color_fill_press = theme.colors.bg_elevated,
                .corner_radius = dvui.Rect.all(theme.radius.md),
                .padding = dvui.Rect.all(theme.spacing.sm),
                .margin = dvui.Rect.all(theme.spacing.xs),
                .min_size_content = .{ .w = 96, .h = 0 },
            });
            bw.processEvents();
            bw.drawBackground();
            {
                var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = i, .gravity_x = 0.5 });
                defer col.deinit();
                avatar(p, 56, i);
                _ = dvui.labelNoFmt(@src(), p.nameText(), .{ .align_x = 0.5 }, .{
                    .id_extra = i,
                    .gravity_x = 0.5,
                    .color_text = if (std.mem.eql(u8, p.idText(), running.idText())) theme.colors.accent else theme.colors.text_primary,
                    .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = 0 },
                });
                if (p.kid or p.hasPin()) {
                    var badges = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .gravity_x = 0.5 });
                    defer badges.deinit();
                    if (p.kid) dvui.icon(@src(), "Kid profile", icons.tvg.lucide.baby, .{}, .{ .id_extra = i, .color_text = theme.colors.text_secondary, .min_size_content = theme.iconSize(.xs) });
                    if (p.hasPin()) dvui.icon(@src(), "PIN", icons.tvg.lucide.lock, .{}, .{ .id_extra = i + 100, .color_text = theme.colors.text_secondary, .min_size_content = theme.iconSize(.xs) });
                }
            }
            bw.drawFocus();
            const clicked = bw.clicked();
            bw.deinit();
            if (clicked and !profiles.restartRequested()) selectTarget(p.idText());
        }
    }

    // PIN row for the selected profile, when its switch needs one.
    if (target_len > 0 and !profiles.restartRequested()) {
        const src = profiles.pinSourceFor(target[0..target_len]) orelse .none;
        if (src != .none) {
            _ = dvui.labelNoFmt(@src(), if (src == .owner) "Main profile PIN" else "PIN", .{}, .{
                .color_text = theme.colors.text_secondary,
                .gravity_x = 0.5,
                .margin = .{ .x = 0, .y = theme.spacing.md, .w = 0, .h = theme.spacing.xs },
            });
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5 });
            defer row.deinit();
            var te = dvui.textEntry(@src(), .{
                .text = .{ .buffer = pin_buf[0..pure.PIN_MAX] },
                .password_char = "*",
                .placeholder = "4-8 digits",
            }, .{
                .min_size_content = .{ .w = 140, .h = 20 },
                .color_fill = theme.colors.bg_elevated,
                .color_border = theme.colors.border_subtle,
                .color_text = theme.colors.text_primary,
                .border = dvui.Rect.all(1),
                .corner_radius = theme.dims.rad_sm,
                .gravity_y = 0.5,
            });
            const enter = te.enter_pressed;
            te.deinit();
            if (components.actionButton(@src(), "Unlock", .primary, 7301) or enter) attemptSwitch();
        }
    }

    if (message_len > 0 or profiles.restartRequested()) {
        _ = dvui.labelNoFmt(@src(), if (profiles.restartRequested()) "Switching profile..." else message[0..message_len], .{ .align_x = 0.5 }, .{
            .gravity_x = 0.5,
            .color_text = theme.colors.text_secondary,
            .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 },
        });
    }

    if (!open_flag and !at_launch) {
        switch_open = false;
        target_len = 0;
        @memset(&pin_buf, 0);
    }
}

// ── Top-bar avatar menu ──────────────────────────────────────────────────────

/// Avatar + name in the top bar; the menu switches profile or opens
/// Settings > Profiles. Hidden while only one unlocked profile exists.
pub fn avatarMenu() void {
    if (profiles.count() <= 1 and !profiles.runningProfile().hasPin()) return;
    const running = profiles.runningProfile();
    var m = dvui.menu(@src(), .horizontal, .{ .gravity_y = 0.5 });
    defer m.deinit();
    if (dvui.menuItemIcon(@src(), running.nameText(), icons.tvg.lucide.@"circle-user", .{ .submenu = true }, .{
        .color_text = colorOf(running.color),
        .color_fill = theme.transparent,
        .color_fill_hover = theme.colors.bg_hover,
        .corner_radius = theme.dims.rad_sm,
        .min_size_content = theme.iconSize(.sm),
        .padding = dvui.Rect.all(6),
    })) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{
            .color_fill = theme.colors.bg_surface,
            .color_border = theme.colors.border_subtle,
        });
        defer fw.deinit();
        var col = dvui.menu(@src(), .vertical, .{
            .background = true,
            .color_fill = theme.colors.bg_surface,
            .border = dvui.Rect.all(1),
            .color_border = theme.colors.border_subtle,
            .corner_radius = theme.dims.rad_md,
        });
        defer col.deinit();
        var list: [pure.MAX_PROFILES]pure.Profile = undefined;
        const n = profiles.snapshot(&list);
        for (list[0..n], 0..) |*p, i| {
            const is_running = std.mem.eql(u8, p.idText(), running.idText());
            if (dvui.menuItemLabel(@src(), p.nameText(), .{}, .{
                .id_extra = 7400 + i,
                .expand = .horizontal,
                .color_text = if (is_running) theme.colors.accent else theme.colors.text_primary,
            }) != null) {
                fw.close();
                if (!is_running) openSwitcher(p.idText());
            }
        }
        if (!running.kid and dvui.menuItemLabel(@src(), "Manage profiles", .{}, .{
            .expand = .horizontal,
            .color_text = theme.colors.text_secondary,
        }) != null) {
            fw.close();
            state.app.settings_tab = .Profiles;
            state.app.router.navigate(.settings);
        }
    }
}

// ── Kid lock ─────────────────────────────────────────────────────────────────

/// Kid profiles cannot open Settings, source/plugin management, AI setup or
/// logs. Renders a locked notice and returns true when `tab` is blocked.
pub fn blocksTab(tab: state.DrawerTab) bool {
    if (!profiles.runningIsKid()) return false;
    switch (tab) {
        .Settings, .Plugins, .AI, .Logs => {},
        else => return false,
    }
    return blocksKid();
}

/// Route-level variant (Plugins/sources, Agents): locked notice for kid
/// profiles; returns true when the caller must not render the page.
pub fn blocksKid() bool {
    if (!profiles.runningIsKid()) return false;
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = dvui.Rect.all(theme.spacing.xl) });
    defer box.deinit();
    components.emptyState(icons.tvg.lucide.lock, "Locked in kid mode", "Ask a grown-up to switch profile to change settings or sources.");
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5 });
    defer row.deinit();
    if (components.actionButton(@src(), "Switch profile", .secondary, 7302)) openSwitcher(null);
    return true;
}

// ── Settings > Profiles ──────────────────────────────────────────────────────

fn editError(e: profiles.EditError) []const u8 {
    return switch (e) {
        error.Forbidden => "Only the main profile can do that",
        error.NotFound => "Profile not found",
        error.NameEmpty => "Enter a name",
        error.NameTooLong => "Name is too long (24 max)",
        error.NameBadCharacter => "Name has unsupported characters",
        error.NameTaken => "Another profile already has that name",
        error.BadPin => "PIN must be 4-8 digits",
        error.Full => "Profile limit reached (8)",
        error.Default => "The main profile cannot be changed that way",
        error.Running => "Switch to another profile first",
        error.Storage => "Could not save profiles",
    };
}

fn sectionLabel(text: []const u8, id_extra: usize) void {
    _ = dvui.labelNoFmt(@src(), text, .{}, .{
        .id_extra = id_extra,
        .color_text = theme.colors.text_secondary,
        .margin = .{ .x = 0, .y = theme.spacing.md, .w = 0, .h = theme.spacing.xs },
    });
}

fn field(buf: []u8, placeholder: []const u8, password: bool, id_extra: usize) void {
    var te = dvui.textEntry(@src(), .{
        .text = .{ .buffer = buf },
        .placeholder = placeholder,
        .password_char = if (password) "*" else null,
    }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .min_size_content = .{ .w = 160, .h = 20 },
        .color_fill = theme.colors.bg_elevated,
        .color_border = theme.colors.border_subtle,
        .color_text = theme.colors.text_primary,
        .border = dvui.Rect.all(1),
        .corner_radius = theme.dims.rad_sm,
    });
    te.deinit();
}

fn capIndex(cap: u8) usize {
    for (pure.CAP_CHOICES, 0..) |c, i| if (c == cap) return i;
    return 2; // 12
}

pub fn renderSettingsTab() void {
    const running = profiles.runningProfile();
    const owner = running.isDefault() and !running.kid;
    _ = dvui.labelNoFmt(@src(), "Each profile has its own history, library, favorites, recommendations and device sync. Switching restarts Opal into that profile.", .{}, .{
        .color_text = theme.colors.text_tertiary,
        .expand = .horizontal,
    });

    var list: [pure.MAX_PROFILES]pure.Profile = undefined;
    const n = profiles.snapshot(&list);
    for (list[0..n], 0..) |*p, i| {
        const pid = p.idText();
        const is_running = std.mem.eql(u8, pid, running.idText());
        const editable = pure.canEdit(&running, pid);
        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = i,
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_elevated,
            .color_border = theme.colors.border_subtle,
            .border = dvui.Rect.all(1),
            .corner_radius = theme.dims.rad_sm,
            .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 },
            .padding = dvui.Rect.all(theme.spacing.sm),
        });
        defer card.deinit();
        {
            var head = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .expand = .horizontal });
            defer head.deinit();
            avatar(p, 28, 200 + i);
            var b: [96]u8 = undefined;
            const label = std.fmt.bufPrint(&b, "{s}{s}{s}{s}", .{
                p.nameText(),
                if (p.isDefault()) "  (main)" else "",
                if (p.kid) "  (kid)" else "",
                if (is_running) "  - active" else "",
            }) catch p.nameText();
            _ = dvui.labelNoFmt(@src(), label, .{}, .{
                .id_extra = i,
                .expand = .horizontal,
                .gravity_y = 0.5,
                .color_text = theme.colors.text_primary,
                .margin = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 },
            });
            if (p.hasPin()) dvui.icon(@src(), "PIN set", icons.tvg.lucide.lock, .{}, .{ .id_extra = i, .color_text = theme.colors.text_secondary, .gravity_y = 0.5, .min_size_content = theme.iconSize(.sm) });
            if (!is_running and components.actionButton(@src(), "Switch", .secondary, 7500 + i)) {
                openSwitcher(pid);
            }
            if (editable and components.iconButton(@src(), icons.tvg.lucide.pencil, "Edit", edit_len > 0 and std.mem.eql(u8, edit_id[0..edit_len], pid))) {
                if (edit_len > 0 and std.mem.eql(u8, edit_id[0..edit_len], pid)) {
                    edit_len = 0;
                } else {
                    @memcpy(edit_id[0..pid.len], pid);
                    edit_len = pid.len;
                    @memset(&edit_name, 0);
                    @memcpy(edit_name[0..p.name_len], p.nameText());
                    @memset(&edit_pin, 0);
                }
            }
        }

        if (!(editable and edit_len > 0 and std.mem.eql(u8, edit_id[0..edit_len], pid))) continue;

        // ── Editor ──
        sectionLabel("Name", 7600 + i);
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .expand = .horizontal });
            defer row.deinit();
            field(edit_name[0..pure.NAME_MAX], "Name", false, 7610 + i);
            if (components.actionButton(@src(), "Rename", .secondary, 7620 + i)) {
                if (profiles.rename(.ui, pid, zText(&edit_name))) |_| state.showToast("Renamed") else |e| state.showToast(editError(e));
            }
        }
        sectionLabel("Colour", 7630 + i);
        if (components.segment(@src(), &COLOR_LABELS, @intFromEnum(p.color))) |ci| {
            profiles.setColor(.ui, pid, @enumFromInt(ci)) catch |e| state.showToast(editError(e));
        }
        sectionLabel(if (p.hasPin()) "Change PIN (empty clears it)" else "Set a PIN", 7640 + i);
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i + 50, .expand = .horizontal });
            defer row.deinit();
            field(edit_pin[0..pure.PIN_MAX], "4-8 digits", true, 7650 + i);
            if (components.actionButton(@src(), if (zText(&edit_pin).len == 0) "Clear PIN" else "Save PIN", .secondary, 7660 + i)) {
                if (profiles.setPin(.ui, pid, zText(&edit_pin))) |_| {
                    state.showToast(if (zText(&edit_pin).len == 0) "PIN cleared" else "PIN saved");
                } else |e| state.showToast(editError(e));
                @memset(&edit_pin, 0);
            }
        }
        if (owner and !p.isDefault()) {
            var kid = p.kid;
            components.toggleRow(@src(), "Kid profile", "Forces the NSFW filter, caps age ratings, hides Settings and sources. Leaving it needs the main profile's PIN.", &kid);
            var unrated = p.allow_unrated;
            var cap = p.max_age;
            if (kid) {
                sectionLabel("Highest age rating allowed", 7670 + i);
                const cap_labels = [_][]const u8{ "7", "10", "12", "13", "16", "18" };
                if (components.segment(@src(), &cap_labels, capIndex(if (p.kid) p.max_age else pure.KID_DEFAULT_CAP))) |ci| cap = pure.CAP_CHOICES[ci];
                components.toggleRow(@src(), "Allow unrated titles", "Titles with no known age rating stay hidden unless this is on", &unrated);
            }
            if (kid != p.kid or unrated != p.allow_unrated or (kid and cap != p.max_age)) {
                const eff_cap = if (kid and !p.kid) pure.KID_DEFAULT_CAP else cap;
                profiles.setKidOptions(.ui, pid, kid, eff_cap, unrated) catch |e| state.showToast(editError(e));
            }
            {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i + 70, .expand = .horizontal, .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 } });
                defer row.deinit();
                if (!is_running and components.confirmDangerButton(@src(), "Delete profile and its data", 7680 + i)) {
                    if (profiles.delete(.ui, pid)) |_| {
                        edit_len = 0;
                        state.showToast("Profile deleted");
                    } else |e| state.showToast(editError(e));
                }
            }
        }
    }

    if (!owner) return;
    sectionLabel("Add a profile", 7700);
    field(new_name[0..pure.NAME_MAX], "Name", false, 7701);
    field(new_pin[0..pure.PIN_MAX], "PIN (optional, 4-8 digits)", true, 7702);
    components.toggleRow(@src(), "Kid profile", "Starts capped at age 12; unrated titles hidden", &new_kid);
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 } });
    defer row.deinit();
    if (components.actionButton(@src(), "Create profile", .primary, 7703)) {
        const color: pure.Color = @enumFromInt(@as(u3, @intCast(profiles.count() % COLOR_LABELS.len)));
        if (profiles.create(.ui, zText(&new_name), color, new_kid, zText(&new_pin))) |_| {
            @memset(&new_name, 0);
            @memset(&new_pin, 0);
            new_kid = false;
            state.showToast("Profile created");
        } else |e| state.showToast(editError(e));
    }
    if (!running.hasPin() and n > 1) {
        _ = dvui.labelNoFmt(@src(), "Tip: set a PIN on the main profile so kid profiles cannot switch out.", .{}, .{
            .color_text = theme.colors.warning,
            .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 },
        });
    }
}
