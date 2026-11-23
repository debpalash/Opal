//! Settings row: interface language. Kept out of settings.zig so the row is a
//! one-line call there. Locale names are autonyms (never translated).
const std = @import("std");
const dvui = @import("dvui");
const i18n = @import("../core/i18n.zig");
const state = @import("../core/state.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");

pub fn render() void {
    _ = dvui.label(@src(), "{s}", .{i18n.t(.settings_language)}, .{
        .color_text = @import("color_compat.zig").wrap(theme.colors.text_secondary),
        .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = theme.spacing.xs },
    });
    var labels: [i18n.locales.len + 1][]const u8 = undefined;
    labels[0] = i18n.t(.common_system_default);
    for (i18n.locales, 0..) |l, i| labels[i + 1] = l.name;
    const pref = i18n.preference();
    var selected: usize = 0;
    for (i18n.locales, 0..) |l, i| {
        if (std.ascii.eqlIgnoreCase(l.tag, pref)) selected = i + 1;
    }
    if (components.segment(@src(), &labels, selected)) |clicked| {
        i18n.setPreference(if (clicked == 0) "" else i18n.locales[clicked - 1].tag);
        state.markConfigDirty();
    }
    _ = dvui.label(@src(), "{s}", .{i18n.t(.settings_language_hint)}, .{
        .color_text = @import("color_compat.zig").wrap(theme.colors.text_tertiary),
    });
}
