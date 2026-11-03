//! Browser controls share Opal's theme and leave room for the native page.
const std = @import("std");
const dvui = @import("dvui");
const c = @import("components.zig");
const theme = @import("theme.zig");
const state = @import("../core/state.zig");
const privacy = @import("../services/browser_privacy.zig");
const pure = privacy.pure;
var open = false;
var tab: usize = 0;
var edit_index: ?usize = null;
var draft: pure.Profile = .{};
var port_buf: [8]u8 = @splat(0);
fn note(src: std.builtin.SourceLocation, text: []const u8) void {
    c.bodyText(src, text, theme.colors.text_secondary);
}
pub fn render(part: @import("../services/native_browser.zig").Chrome) void {
    if (part == .toolbar) {
        if (c.actionButton(@src(), "Extensions", if (open) .primary else .secondary, 71300)) open = !open;
        return;
    }
    if (!open) return;
    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = true, .color_fill = .{ .color = theme.colors.bg_surface }, .padding = dvui.Rect.all(10), .margin = .{ .y = 4, .h = 4 }, .corners = theme.dims.rad_sm });
    defer panel.deinit();
    var header = dvui.box(@src(), .{ .dir = if (dvui.windowRect().w < 420) .vertical else .horizontal }, .{ .expand = .horizontal });
    if (c.segment(@src(), &.{ "Extensions", "Privacy", "Proxies" }, tab)) |index| tab = index;
    if (c.actionButton(@src(), "Done", .secondary, 71301)) open = false;
    header.deinit();
    if (!state.app.config_loaded.load(.acquire) and !@import("builtin").is_test) {
        note(@src(), "Loading browser settings…");
        return;
    }
    const height = @min(@as(f32, 280), dvui.windowRect().h * 0.45);
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .{ .h = height }, .max_size_content = .{ .w = std.math.floatMax(f32), .h = height } });
    defer scroll.deinit();
    var contents = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
    defer contents.deinit();
    switch (tab) {
        0 => extensions(),
        1 => protections(),
        else => proxies(),
    }
}
fn extensions() void {
    if (!privacy.extensionsAvailable()) {
        note(@src(), "Browser extensions require macOS 15.4 or later. Canvas and proxy controls are available in their tabs.");
        return;
    }
    note(@src(), "uBlock Origin Lite");
    note(@src(), "Blocks ads and trackers. Installing allows it to read and filter websites in Opal.");
    if (!privacy.prefs.ubol_installed) {
        switch (privacy.downloadStatus()) {
            .downloading, .ready => note(@src(), "Downloading the verified official extension…"),
            .failed => {
                note(@src(), "Download or verification failed.");
                if (c.actionButton(@src(), "Retry install", .primary, 71302)) privacy.retryUbol();
            },
            .idle => if (c.actionButton(@src(), "Install uBlock Origin Lite", .primary, 71303)) privacy.installUbol(),
        }
    } else {
        extensionControls(0, &privacy.prefs.ubol_enabled, &privacy.prefs.ubol_private);
    }
    for (0..privacy.prefs.extension_count) |i| {
        const row = &privacy.prefs.extensions[i];
        var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = @intCast(71400 + i), .expand = .horizontal, .padding = .{ .y = 6, .h = 6 } });
        note(@src(), row.name.text());
        extensionControls(i + 1, &row.enabled, &row.private);
        if (c.actionButton(@src(), "Remove", .danger, 71430 + i)) {
            privacy.removeExtension(i);
            box.deinit();
            break;
        }
        box.deinit();
    }
    if (privacy.prefs.extension_count < 7 and c.actionButton(@src(), "Add extension…", .secondary, 71304)) privacy.api.opal_extension_pick();
    note(@src(), "Add a WebKit-compatible extension ZIP or unpacked folder. Firefox and Chrome-only extensions may use unsupported APIs.");
}
fn extensionControls(slot: usize, enabled: *bool, private: *bool) void {
    const before = enabled.*;
    const before_private = private.*;
    c.toggleRow(@src(), "Enabled", null, enabled);
    c.toggleRow(@src(), "Allow in private browsing", null, private);
    if (before != enabled.* or before_private != private.*) privacy.changed();
    const status = privacy.extensionStatus(slot);
    note(@src(), if (state.app.incognito_mode and !private.*) "Off in private browsing" else if (!enabled.*) "Disabled" else if (status.message[0] != 0) std.mem.sliceTo(&status.message, 0) else "Starting…");
    var row = dvui.box(@src(), .{ .dir = if (dvui.windowRect().w < 420) .vertical else .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();
    if (status.code == 2) {
        if (c.actionButton(@src(), "Open controls", .secondary, 71500 + slot * 4)) privacy.api.opal_extension_action(@intCast(slot), 0);
        if (c.actionButton(@src(), "Settings", .secondary, 71501 + slot * 4)) privacy.api.opal_extension_action(@intCast(slot), 1);
    }
    if (c.actionButton(@src(), "Reload", .secondary, 71502 + slot * 4)) privacy.reloadExtension(slot);
}
fn protections() void {
    const before = privacy.prefs.canvas;
    c.toggleRow(@src(), "Protect canvas readback", "Prevents sites reading canvas pixels for fingerprinting. Drawing still works; allow trusted editors below when exports are needed.", &privacy.prefs.canvas);
    if (before != privacy.prefs.canvas) privacy.changed();
    const b = &state.app.browser;
    const host = @import("../services/browser_pure.zig").urlHost(b.url_buf[0..b.url_len]);
    if (pure.validHost(host)) {
        note(@src(), host);
        var allowed = pure.hostAllowed(&privacy.prefs, host);
        const old_allowed = allowed;
        c.toggleRow(@src(), "Allow canvas on this site", null, &allowed);
        if (allowed != old_allowed) {
            if (allowed) {
                const n = privacy.prefs.canvas_exception_count;
                if (n < privacy.prefs.canvas_exceptions.len) {
                    privacy.prefs.canvas_exceptions[n].set(host);
                    privacy.prefs.canvas_exception_count += 1;
                    privacy.changed();
                } else state.showToast("Remove a canvas exception before adding another");
            } else {
                for (privacy.prefs.canvas_exceptions[0..privacy.prefs.canvas_exception_count], 0..) |*entry, i| if (std.ascii.eqlIgnoreCase(entry.text(), host)) {
                    for (i..privacy.prefs.canvas_exception_count - 1) |j| privacy.prefs.canvas_exceptions[j] = privacy.prefs.canvas_exceptions[j + 1];
                    privacy.prefs.canvas_exception_count -= 1;
                    privacy.changed();
                    break;
                };
            }
        }
    }
    for (0..privacy.prefs.canvas_exception_count) |i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = @intCast(71600 + i), .expand = .horizontal });
        note(@src(), privacy.prefs.canvas_exceptions[i].text());
        if (c.actionButton(@src(), "Remove", .secondary, 71630 + i)) {
            for (i..privacy.prefs.canvas_exception_count - 1) |j| privacy.prefs.canvas_exceptions[j] = privacy.prefs.canvas_exceptions[j + 1];
            privacy.prefs.canvas_exception_count -= 1;
            privacy.changed();
            row.deinit();
            break;
        }
        row.deinit();
    }
    note(@src(), "Protection changes reload the current page. This blocks canvas readback; it does not make browsing anonymous.");
}
fn field(src: std.builtin.SourceLocation, label: []const u8, buffer: []u8, secret: bool) void {
    note(src, label);
    var entry = dvui.textEntry(src, .{ .text = .{ .buffer = buffer }, .password_char = if (secret) "*" else null }, .{ .id_extra = 1, .expand = .horizontal, .color_fill = .{ .color = theme.colors.bg_elevated }, .color_text = .{ .color = theme.colors.text_primary }, .color_border = .{ .color = theme.colors.border_strong }, .border = dvui.Rect.all(1), .corners = theme.dims.rad_sm, .padding = dvui.Rect.all(5) });
    entry.deinit();
}
fn syncField(comptime n: usize, f: *@import("../services/wallpapers_pure.zig").Field(n)) void {
    f.len = std.mem.sliceTo(&f.bytes, 0).len;
}
fn beginEdit(index: ?usize) void {
    edit_index = index;
    draft = if (index) |i| privacy.prefs.profiles[i] else .{};
    @memset(&port_buf, 0);
    _ = std.fmt.bufPrint(&port_buf, "{d}", .{draft.port}) catch {};
}
var editing = false;
fn proxies() void {
    if (privacy.api.opal_browser_proxy_supported() == 0) {
        note(@src(), "Browser proxy profiles require macOS 14 or later.");
        return;
    }
    note(@src(), "These profiles affect only Opal's browser. Local/intranet and literal IPv6 addresses are blocked while a profile is active; select System proxy to access them.");
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    if (c.actionButton(@src(), "System proxy", if (privacy.prefs.proxy_mode == .system) .primary else .secondary, 71700)) {
        privacy.prefs.proxy_mode = .system;
        privacy.changed();
    }
    row.deinit();
    for (0..privacy.prefs.profile_count) |i| {
        const p = &privacy.prefs.profiles[i];
        var r = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = @intCast(71720 + i), .expand = .horizontal });
        if (c.actionButton(@src(), p.name.text(), if (privacy.prefs.active_profile == i and privacy.prefs.proxy_mode != .system) .primary else .secondary, 71740 + i)) {
            privacy.prefs.active_profile = i;
            privacy.prefs.proxy_mode = p.kind;
            privacy.changed();
        }
        if (c.actionButton(@src(), "Edit", .secondary, 71760 + i)) {
            beginEdit(i);
            editing = true;
        }
        if (c.actionButton(@src(), "Remove", .danger, 71780 + i)) {
            if (privacy.prefs.active_profile == i) privacy.prefs.proxy_mode = .system;
            if (privacy.prefs.active_profile > i) privacy.prefs.active_profile -= 1;
            for (i..privacy.prefs.profile_count - 1) |j| privacy.prefs.profiles[j] = privacy.prefs.profiles[j + 1];
            privacy.prefs.profile_count -= 1;
            privacy.prefs.profiles[privacy.prefs.profile_count] = .{};
            if (privacy.prefs.active_profile >= privacy.prefs.profile_count) privacy.prefs.active_profile = 0;
            privacy.changed();
            editing = false;
            r.deinit();
            break;
        }
        r.deinit();
    }
    if (!editing and privacy.prefs.profile_count < pure.max_profiles and c.actionButton(@src(), "Add proxy profile", .secondary, 71800)) {
        beginEdit(null);
        editing = true;
    }
    if (!editing) return;
    const kinds = [_]pure.ProxyKind{ .http, .https, .socks5 };
    const selected: usize = switch (draft.kind) {
        .https => 1,
        .socks5 => 2,
        else => 0,
    };
    if (c.segment(@src(), &.{ "HTTP", "HTTPS", "SOCKS5" }, selected)) |i| draft.kind = kinds[i];
    field(@src(), "Name", &draft.name.bytes, false);
    field(@src(), "Host", &draft.host.bytes, false);
    field(@src(), "Port", &port_buf, false);
    field(@src(), "Username (optional)", &draft.username.bytes, false);
    field(@src(), "Password (optional)", &draft.password.bytes, true);
    if (c.actionButton(@src(), "Save profile", .primary, 71801)) {
        syncField(48, &draft.name);
        syncField(256, &draft.host);
        syncField(128, &draft.username);
        syncField(128, &draft.password);
        draft.port = std.fmt.parseInt(u16, std.mem.sliceTo(&port_buf, 0), 10) catch 0;
        if (!pure.validProfile(&draft)) {
            state.showToast("Enter a name, a hostname without a URL scheme, and a port from 1 to 65535");
            return;
        }
        const index = edit_index orelse privacy.prefs.profile_count;
        privacy.prefs.profiles[index] = draft;
        if (edit_index == null) privacy.prefs.profile_count += 1;
        editing = false;
        @memset(&draft.password.bytes, 0);
        privacy.changed();
    }
    if (c.actionButton(@src(), "Cancel", .secondary, 71802)) {
        editing = false;
        @memset(&draft.password.bytes, 0);
    }
}

pub fn setPanelForTest(section: ?usize, editor: bool) void {
    if (!@import("builtin").is_test) @compileError("Browser panel fixtures are test-only");
    open = section != null;
    tab = section orelse 0;
    editing = editor;
    if (editor) beginEdit(if (privacy.prefs.profile_count > 0) @as(usize, 0) else null);
}
