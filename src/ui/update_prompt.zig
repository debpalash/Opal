//! A non-blocking, bottom-right update card. Download and Restart are explicit.
const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme.zig");
const c = @import("components.zig");
const icons = @import("icons").tvg.lucide;
const updater = @import("../services/updater.zig");
const state = @import("../core/state.zig");
pub var popup_id: ?dvui.Id = null;
pub var bounds: dvui.Rect.Physical = .{};
pub var primary_bounds: dvui.Rect.Physical = .{};
pub var later_bounds: dvui.Rect.Physical = .{};
pub const Action = enum { none, later, check, download, restart, release, notes };
pub fn render() void {
    popup_id = null;
    bounds = .{};
    const value = updater.snapshot();
    if (!value.show_prompt or state.app.is_headless or !state.app.onboarded) return;
    const stack = dvui.currentWindow().subwindows.stack.items;
    if (stack.len > 1) for (stack[1..]) |sw| if (sw.used and sw.modal) return;
    switch (renderSnapshot(value)) {
        .none => {},
        .later => updater.dismiss(),
        .check => updater.checkAsync(),
        .notes => updater.openRelease(),
        .download => updater.downloadAndOpenAsync(),
        .restart => updater.restartAndInstall(),
        .release => {
            updater.openRelease();
            updater.dismiss();
        },
    }
}
pub fn renderSnapshot(value: updater.Snapshot) Action {
    var result: Action = .none;
    const window = dvui.windowRect();
    const width = @max(180, @min(360, window.w - 24));
    const height: f32 = @as(f32, if (value.last_error_len > 0) 290 else if (value.is_downloading) 270 else 240) + @as(f32, if (width < 360) 20 else 0);
    var rect: dvui.Rect = .{ .x = @max(12, window.w - width - 16), .y = @max(12, window.h - height - 78), .w = width, .h = height };
    var open = true;
    var popup = dvui.floatingWindow(@src(), .{ .modal = false, .rect = &rect, .open_flag = &open, .resize = .none, .window_avoid = .none, .stay_above_parent_window = true }, .{ .padding = dvui.Rect.all(16), .background = true, .color_fill = .{ .color = theme.colors.bg_surface }, .border = dvui.Rect.all(1), .color_border = .{ .color = theme.colors.border_subtle }, .corners = theme.dims.rad_lg });
    defer popup.deinit();
    popup_id = popup.data().id;
    bounds = popup.data().borderRectScale().r;
    var header = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .h = 10 } });
    dvui.icon(@src(), "Update", if (value.is_ready) icons.@"circle-check" else icons.download, .{}, .{ .min_size_content = .{ .w = 20, .h = 20 }, .gravity_y = 0.5, .color_text = .{ .color = theme.colors.accent }, .margin = .{ .w = 8 } });
    dvui.labelNoFmt(@src(), if (value.is_checking) "Checking for updates" else if (!value.has_update) "Could not check for updates" else if (value.is_ready) "Ready to restart" else if (value.is_downloading) "Downloading update" else "Update available", .{}, .{ .font = dvui.themeGet().font_heading, .expand = .horizontal, .color_text = .{ .color = theme.colors.text_primary }, .gravity_y = 0.5 });
    if (c.iconButton(@src(), icons.x, "Remind me later", false)) result = .later;
    header.deinit();
    var version: [128]u8 = undefined;
    if (value.has_update) {
        var version_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        c.bodyText(@src(), std.fmt.bufPrint(&version, "Opal v{s}  ·  Current v{s}", .{ value.latestTag(), updater.APP_VERSION }) catch "Opal update", theme.colors.text_secondary);
        _ = dvui.spacer(@src(), .{ .expand = .horizontal });
        if (c.iconButton(@src(), icons.@"book-open", "What's new", false)) result = .notes;
        version_row.deinit();
    }
    if (value.is_downloading) {
        var label: [64]u8 = undefined;
        const fraction: f32 = if (value.selection.size > 0) @as(f32, @floatFromInt(value.downloaded)) / @as(f32, @floatFromInt(value.selection.size)) else 0;
        c.ProgressBar(@src(), fraction, if (value.selection.size > 0) (std.fmt.bufPrint(&label, "{d:.0}% downloaded", .{std.math.clamp(fraction, 0, 1) * 100}) catch "Downloading…") else "Downloading…", 79101);
        c.bodyText(@src(), "You can keep using Opal.", theme.colors.text_secondary);
        c.pollRefresh(100_000);
    } else if (value.is_ready) {
        c.bodyText(@src(), if (value.selection.mode == .bundle) "Restart to install and reopen the new app." else "Your update is ready to install.", theme.colors.text_secondary);
    } else if (value.has_update) c.bodyText(@src(), if (value.selection.mode == .website) "Update using your package manager or download." else "Download now. Restart when you're ready.", theme.colors.text_secondary);
    if (value.last_error_len > 0) c.bodyText(@src(), value.lastError(), theme.colors.warning);
    _ = dvui.spacer(@src(), .{ .expand = .vertical });
    var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 8 } });
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    const later = c.actionButton(@src(), if (value.is_downloading) "Hide" else "Later", .secondary, 79102);
    if (@import("builtin").is_test) later_bounds = c.action_bounds_for_test;
    if (later) result = .later;
    if (!value.is_downloading and !value.is_checking) {
        const action = c.actionButton(@src(), if (!value.has_update) "Try again" else if (value.is_ready) (if (value.selection.mode == .bundle) "Restart" else "Open installer") else if (value.selection.mode == .website) "View release" else "Update", .primary, 79103);
        if (@import("builtin").is_test) primary_bounds = c.action_bounds_for_test;
        if (action) result = if (!value.has_update) .check else if (value.is_ready) .restart else if (value.selection.mode == .website) .release else .download;
    }
    actions.deinit();
    if (!open) result = .later;
    return result;
}
