//! Browser controls share Opal's theme and leave room for the native page.
const std = @import("std");
const dvui = @import("dvui");
const c = @import("components.zig");
const theme = @import("theme.zig");
const state = @import("../core/state.zig");
const privacy = @import("../services/browser_privacy.zig");
const pure = privacy.pure;
const icons = @import("icons").tvg.lucide;
var open = false;
var tab: usize = 0;
var edit_index: ?usize = null;
var draft: pure.Profile = .{};
var port_buf: [8]u8 = @splat(0);
pub fn openSection(section: usize) void {
    open = true;
    tab = @min(section, 2);
    state.wakeUi();
}
fn note(src: std.builtin.SourceLocation, text: []const u8) void {
    c.bodyText(src, text, theme.colors.text_secondary);
}
pub fn render(part: @import("../services/native_browser.zig").Chrome) void {
    if (part == .start) {
        @import("browser_start.zig").render();
        return;
    }
    if (part == .toolbar) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 0.5 });
        defer row.deinit();
        const clicked = c.iconButton(@src(), icons.puzzle, "Extensions and privacy", open);
        if (clicked) open = !open;
        return;
    }
    if (!open) return;
    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = true, .color_fill = .{ .color = theme.colors.bg_surface }, .padding = dvui.Rect.all(10), .margin = .{ .y = 4, .h = 4 }, .corners = theme.dims.rad_sm });
    defer panel.deinit();
    var header = dvui.box(@src(), .{ .dir = if (dvui.windowRect().w < 420) .vertical else .horizontal }, .{ .expand = .horizontal });
    const labels = [_][]const u8{ "Extensions", "Privacy", "Connections" };
    const glyphs = [_][]const u8{ icons.puzzle, icons.@"shield-check", icons.network };
    for (labels, glyphs, 0..) |label, icon, index| {
        var item = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = index, .gravity_y = 0.5 });
        if (c.iconButton(@src(), icon, label, tab == index)) tab = index;
        if (tab == index) note(@src(), label);
        item.deinit();
    }
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    if (c.iconButton(@src(), icons.x, "Close browser settings", false)) open = false;
    header.deinit();
    if (!state.app.config_loaded.load(.acquire) and !@import("builtin").is_test) {
        note(@src(), "Loading browser settings…");
        return;
    }
    const height = @min(@as(f32, 320), dvui.windowRect().h * 0.45);
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
    if (!privacy.prefs.ubol_installed) {
        note(@src(), "uBlock Origin Lite");
        note(@src(), "Blocks ads and trackers. Installing allows it to read and filter websites in Opal.");
        switch (privacy.downloadStatus()) {
            .downloading, .ready => note(@src(), "Downloading the verified official extension…"),
            .failed => {
                note(@src(), "Download or verification failed.");
                if (c.actionButton(@src(), "Retry install", .primary, 71302)) privacy.retryUbol();
            },
            .idle => if (c.actionButton(@src(), "Install uBlock Origin Lite", .primary, 71303)) privacy.installUbol(),
        }
    } else {
        extensionControls(0, "uBlock Origin Lite", &privacy.prefs.ubol_enabled, &privacy.prefs.ubol_private);
    }
    for (0..privacy.prefs.extension_count) |i| {
        const row = &privacy.prefs.extensions[i];
        var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = @intCast(71400 + i), .expand = .horizontal, .padding = .{ .y = 6, .h = 6 } });
        extensionControls(i + 1, row.name.text(), &row.enabled, &row.private);
        if (c.iconButton(@src(), icons.@"trash-2", "Remove extension", false)) {
            privacy.removeExtension(i);
            box.deinit();
            break;
        }
        box.deinit();
    }
    var add = dvui.box(@src(), .{ .dir = .horizontal }, .{ .margin = .{ .y = 8 }, .expand = .horizontal });
    if (privacy.prefs.extension_count < 7 and c.iconButton(@src(), icons.plus, "Add extension…", false)) privacy.api.opal_extension_pick();
    note(@src(), "Add extension");
    add.deinit();
    note(@src(), "Add a WebKit-compatible extension ZIP or unpacked folder. Firefox and Chrome-only extensions may use unsupported APIs.");
}
fn extensionControls(slot: usize, title: []const u8, enabled: *bool, private: *bool) void {
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = slot, .expand = .horizontal, .background = true, .color_fill = .{ .color = theme.colors.bg_elevated }, .corners = theme.dims.rad_sm, .padding = dvui.Rect.all(12), .margin = .{ .h = 6 } });
    defer card.deinit();
    var header = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    dvui.icon(@src(), "", if (slot == 0) icons.@"shield-check" else icons.puzzle, .{}, .{ .min_size_content = .{ .w = 20, .h = 20 }, .gravity_y = 0.5, .color_text = .{ .color = theme.colors.accent }, .margin = .{ .w = 8 } });
    _ = dvui.label(@src(), "{s}", .{title}, .{ .expand = .horizontal, .gravity_y = 0.5, .color_text = .{ .color = theme.colors.text_primary } });
    if (c.iconButton(@src(), icons.power, if (enabled.*) "Disable extension" else "Enable extension", enabled.*)) {
        enabled.* = !enabled.*;
        privacy.changed();
    }
    header.deinit();
    const status = privacy.extensionStatus(slot);
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();
    _ = dvui.label(@src(), "{s}", .{if (state.app.incognito_mode and !private.*) "Off in private browsing" else if (!enabled.*) "Disabled" else if (status.code == 2) "Enabled" else if (status.code < 0) "Needs attention" else "Starting…"}, .{ .expand = .horizontal, .gravity_y = 0.5, .color_text = .{ .color = if (enabled.* and status.code == 2) theme.colors.accent else theme.colors.text_secondary } });
    if (c.iconButton(@src(), icons.@"eye-off", "Allow in private browsing", private.*)) {
        private.* = !private.*;
        privacy.changed();
    }
    if (status.code == 2) {
        if (c.iconButton(@src(), icons.@"sliders-horizontal", "Open controls", false)) privacy.api.opal_extension_action(@intCast(slot), 0);
        if (c.iconButton(@src(), icons.settings, "Settings", false)) privacy.api.opal_extension_action(@intCast(slot), 1);
    }
    if (c.iconButton(@src(), icons.@"rotate-cw", "Reload extension", false)) privacy.reloadExtension(slot);
    if (status.code < 0 and status.message[0] != 0) note(@src(), std.mem.sliceTo(&status.message, 0));
}
fn protections() void {
    const old_ads = privacy.prefs.block_ads;
    const old_trackers = privacy.prefs.block_trackers;
    const old_cookies = privacy.prefs.clean_tracking_cookies;
    const old_rtc = privacy.prefs.block_webrtc;
    const old_https = privacy.prefs.https_only;
    c.toggleRow(@src(), "Block known advertising domains", "Native protection works alongside installed extensions.", &privacy.prefs.block_ads);
    c.toggleRow(@src(), "Block known tracking domains", null, &privacy.prefs.block_trackers);
    c.toggleRow(@src(), "Remove known tracking cookies", "Removes analytics cookies such as _ga and _fbp. Other cookies stay available for sign-in.", &privacy.prefs.clean_tracking_cookies);
    c.toggleRow(@src(), "Block WebRTC", "Disables peer connections after reload. Always enabled on the Tor route.", &privacy.prefs.block_webrtc);
    c.toggleRow(@src(), "HTTPS only", "Blocks insecure HTTP pages and requests.", &privacy.prefs.https_only);
    if (old_ads != privacy.prefs.block_ads or old_trackers != privacy.prefs.block_trackers or old_cookies != privacy.prefs.clean_tracking_cookies or old_rtc != privacy.prefs.block_webrtc or old_https != privacy.prefs.https_only) privacy.changed();
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
    var connection = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    if (c.actionButton(@src(), "Tor", if (privacy.prefs.proxy_mode == .tor) .primary else .secondary, 71900)) {
        privacy.prefs.proxy_mode = .tor;
        privacy.changed();
    }
    if (c.actionButton(@src(), "Verified pool", if (privacy.prefs.proxy_mode == .pool) .primary else .secondary, 71901)) {
        privacy.prefs.proxy_mode = .pool;
        privacy.changed();
    }
    if (c.iconButton(@src(), icons.@"scan-line", "Verify saved proxies through HTTPS", false)) privacy.api.opal_security_pool_scan();
    if (c.iconButton(@src(), icons.shuffle, "Rotate to another verified exit", false)) privacy.api.opal_security_pool_rotate();
    connection.deinit();
    if (privacy.prefs.proxy_mode == .tor) {
        var status: [256]u8 = undefined;
        const n = privacy.api.opal_security_tor_message(&status, status.len);
        note(@src(), status[0..n]);
        if (privacy.api.opal_security_tor_status() == 1) {
            var progress: [64]u8 = undefined;
            note(@src(), std.fmt.bufPrint(&progress, "Connecting: {d}%", .{privacy.api.opal_security_tor_progress()}) catch "Connecting…");
        }
        if (c.iconButton(@src(), icons.@"rotate-cw", "Reconnect Tor", false)) privacy.api.opal_security_tor_retry();
        note(@src(), "Routes this browser through Tor while Opal is open. Other app traffic uses its own connection.");
    }
    note(@src(), "Pool checks use HTTPS through each saved proxy. Verified exits expire after six hours; empty pools block traffic.");
    for (0..privacy.prefs.profile_count) |i| {
        const p = &privacy.prefs.profiles[i];
        var r = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = @intCast(71720 + i), .expand = .horizontal });
        if (c.actionButton(@src(), p.name.text(), if (privacy.prefs.active_profile == i and privacy.prefs.proxy_mode == p.kind) .primary else .secondary, 71740 + i)) {
            privacy.prefs.active_profile = i;
            privacy.prefs.proxy_mode = p.kind;
            privacy.changed();
        }
        note(@src(), switch (privacy.api.opal_security_pool_health(@intCast(i))) {
            1 => "Checking…",
            2 => "Verified",
            -1 => "Unavailable",
            else => "Unchecked",
        });
        if (c.actionButton(@src(), "Edit", .secondary, 71760 + i)) {
            beginEdit(i);
            editing = true;
        }
        if (c.actionButton(@src(), "Remove", .danger, 71780 + i)) {
            if (privacy.prefs.active_profile == i and privacy.prefs.proxy_mode == p.kind) privacy.prefs.proxy_mode = .system;
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
        if (edit_index != null and privacy.prefs.active_profile == index and privacy.prefs.proxy_mode == privacy.prefs.profiles[index].kind) privacy.prefs.proxy_mode = draft.kind;
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
