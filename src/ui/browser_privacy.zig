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
var show_connection_details = false;
var show_authentication = false;
var editor_error: []const u8 = "";
pub const ConnectionLayout = struct {
    panel: dvui.Rect.Physical = .{},
    routes: [3]dvui.Rect.Physical = @splat(.{}),
    status: dvui.Rect.Physical = .{},
    add: dvui.Rect.Physical = .{},
    editor: dvui.Rect.Physical = .{},
    cancel: dvui.Rect.Physical = .{},
    host: dvui.Rect.Physical = .{},
    port: dvui.Rect.Physical = .{},
    authentication_visible: bool = false,
};
pub var connection_layout_for_test: ConnectionLayout = .{};
fn closeEditor() void {
    editing = false;
    show_authentication = false;
    editor_error = "";
    draft = .{};
    @memset(&port_buf, 0);
}
pub fn openSection(section: usize) void {
    closeEditor();
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
        if (clicked) {
            open = !open;
            closeEditor();
        }
        return;
    }
    if (!open) return;
    if (@import("builtin").is_test) connection_layout_for_test = .{};
    const panel_width = @max(0, @min(680, dvui.parentGet().data().contentRect().w - 26));
    // Expansion fills the parent even with max_size_content. Request a bounded
    // content width instead, then anchor the panel beneath the toolbar action.
    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{ .min_size_content = .{ .w = panel_width }, .max_size_content = dvui.Options.MaxSize.width(panel_width), .gravity_x = 1, .background = true, .color_fill = .{ .color = theme.colors.bg_surface }, .padding = dvui.Rect.all(12), .margin = .{ .y = 4, .h = 4 }, .corners = theme.dims.rad_sm, .border = dvui.Rect.all(1), .color_border = .{ .color = theme.colors.border_subtle } });
    defer panel.deinit();
    if (@import("builtin").is_test) connection_layout_for_test.panel = panel.data().borderRectScale().r;
    var header = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .h = 8 } });
    const labels = [_][]const u8{ "Extensions", "Privacy", "Connections" };
    const glyphs = [_][]const u8{ icons.puzzle, icons.@"shield-check", icons.network };
    for (labels, glyphs, 0..) |label, icon, index| {
        var item = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = index, .gravity_y = 0.5 });
        if (c.iconButton(@src(), icon, label, tab == index)) {
            if (tab != index) closeEditor();
            tab = index;
        }
        if (tab == index) note(@src(), label);
        item.deinit();
    }
    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    if (c.iconButton(@src(), icons.x, "Close browser settings", false)) {
        open = false;
        closeEditor();
    }
    header.deinit();
    if (!state.app.config_loaded.load(.acquire) and !@import("builtin").is_test) {
        note(@src(), "Loading browser settings…");
        return;
    }
    const preferred: f32 = if (tab != 2 or editing or show_connection_details) 320 else @min(320, @as(f32, if (panel_width < 450) 300 else 226) + @as(f32, @floatFromInt(privacy.prefs.profile_count)) * 56);
    const height = @min(preferred, dvui.windowRect().h * 0.45);
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
    var group = dvui.box(src, .{ .dir = .vertical }, .{ .expand = .horizontal, .margin = .{ .h = 6 } });
    defer group.deinit();
    _ = dvui.label(src, "{s}", .{label}, .{ .id_extra = 2, .color_text = .{ .color = theme.colors.text_secondary }, .font = dvui.themeGet().font_body.withSize(theme.font_size.small), .padding = .{ .h = 3 } });
    var entry = dvui.textEntry(src, .{ .text = .{ .buffer = buffer }, .password_char = if (secret) "*" else null }, .{ .id_extra = 1, .expand = .horizontal, .color_fill = .{ .color = theme.colors.bg_elevated }, .color_text = .{ .color = theme.colors.text_primary }, .color_border = .{ .color = theme.colors.border_strong }, .border = dvui.Rect.all(1), .corners = theme.dims.rad_sm, .padding = dvui.Rect.all(5) });
    if (@import("builtin").is_test) {
        if (std.mem.eql(u8, label, "Host")) connection_layout_for_test.host = entry.data().borderRectScale().r;
        if (std.mem.eql(u8, label, "Port")) connection_layout_for_test.port = entry.data().borderRectScale().r;
    }
    entry.deinit();
}
fn syncField(comptime n: usize, f: *@import("../services/wallpapers_pure.zig").Field(n)) void {
    f.len = std.mem.sliceTo(&f.bytes, 0).len;
}
fn beginEdit(index: ?usize) void {
    closeEditor();
    editing = true;
    edit_index = index;
    draft = if (index) |i| privacy.prefs.profiles[i] else .{};
    @memset(&port_buf, 0);
    _ = std.fmt.bufPrint(&port_buf, "{d}", .{draft.port}) catch {};
    show_authentication = draft.username.len > 0 or draft.password.len > 0;
}
var editing = false;
fn connectionStatus() void {
    const mode = privacy.prefs.proxy_mode;
    const tor_state = privacy.api.opal_security_tor_status();
    const verified = privacy.api.opal_security_pool_count();
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = true, .color_fill = .{ .color = theme.colors.bg_elevated }, .corners = theme.dims.rad_sm, .padding = dvui.Rect.all(10) });
    defer card.deinit();
    if (@import("builtin").is_test) connection_layout_for_test.status = card.data().borderRectScale().r;
    var heading = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    const title = switch (mode) {
        .system => "System connection",
        .tor => "Tor",
        .pool => "Verified pool",
        else => "Proxy connection",
    };
    _ = dvui.label(@src(), "{s}", .{title}, .{ .expand = .horizontal, .gravity_y = 0.5, .color_text = .{ .color = theme.colors.text_primary } });
    if (mode == .tor) {
        if (tor_state == 2) c.statusPill("Connected", .success) else if (tor_state < 0) c.statusPill("Blocked", .warn) else c.statusPill("Connecting", .info);
    } else if (mode == .pool) {
        if (verified > 0) c.statusPill("Ready", .success) else c.statusPill("Blocked", .warn);
    } else c.statusPill(if (mode == .system) "Default" else "Selected", .info);
    heading.deinit();
    switch (mode) {
        .system => note(@src(), "Uses your Mac’s network settings."),
        .tor => {
            var buffer: [256]u8 = undefined;
            if (tor_state == 1) note(@src(), std.fmt.bufPrint(&buffer, "Connecting to Tor · {d}%", .{privacy.api.opal_security_tor_progress()}) catch "Connecting…") else {
                const n = privacy.api.opal_security_tor_message(&buffer, buffer.len);
                note(@src(), buffer[0..n]);
            }
            if (tor_state != 1 and c.iconActionButton(@src(), icons.@"rotate-cw", "Reconnect", .secondary, 71903)) privacy.api.opal_security_tor_retry();
        },
        .pool => {
            var buffer: [96]u8 = undefined;
            note(@src(), if (verified > 0) std.fmt.bufPrint(&buffer, "{d} verified exits · browser traffic only", .{verified}) catch "Verified exits available" else if (privacy.prefs.profile_count == 0) "Add a proxy, then verify it to start browsing." else "Verify saved proxies to start browsing.");
            var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{});
            if (privacy.prefs.profile_count == 0) {
                if (c.iconActionButton(@src(), icons.plus, "Add proxy", .primary, 71904)) beginEdit(null);
            } else if (c.iconActionButton(@src(), icons.@"scan-line", "Verify", if (verified == 0) .primary else .secondary, 71905)) privacy.api.opal_security_pool_scan();
            if (c.iconButtonEx(@src(), icons.shuffle, "Rotate verified exit", false, verified > 1)) privacy.api.opal_security_pool_rotate();
            actions.deinit();
        },
        else => note(@src(), "This proxy applies to browser traffic only."),
    }
}
fn proxies() void {
    if (privacy.api.opal_browser_proxy_supported() == 0) {
        note(@src(), "Browser proxy profiles require macOS 14 or later.");
        return;
    }
    var chooser = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .h = 10 } });
    const modes = [_]pure.ProxyKind{ .system, .tor, .pool };
    const labels = [_][]const u8{ "System", "Tor", "Pool" };
    const glyphs = [_][]const u8{ icons.globe, icons.@"shield-check", icons.network };
    for (modes, labels, glyphs, 0..) |mode, label, icon, i| {
        var choice = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i });
        if (c.iconActionButton(@src(), icon, label, if (privacy.prefs.proxy_mode == mode) .primary else .secondary, i)) {
            privacy.prefs.proxy_mode = mode;
            closeEditor();
            privacy.changed();
        }
        if (@import("builtin").is_test) connection_layout_for_test.routes[i] = choice.data().borderRectScale().r;
        choice.deinit();
    }
    chooser.deinit();
    if (editing) {
        proxyEditor();
        return;
    }
    connectionStatus();
    var saved = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 8, .h = 4 } });
    _ = dvui.label(@src(), "Saved proxies", .{}, .{ .expand = .horizontal, .gravity_y = 0.5, .color_text = .{ .color = theme.colors.text_primary } });
    var add = dvui.box(@src(), .{ .dir = .horizontal }, .{});
    if (c.iconButtonEx(@src(), icons.plus, "Add proxy", false, privacy.prefs.profile_count < pure.max_profiles)) beginEdit(null);
    if (@import("builtin").is_test) connection_layout_for_test.add = add.data().borderRectScale().r;
    add.deinit();
    if (c.iconButton(@src(), icons.@"circle-help", "Connection details", show_connection_details)) show_connection_details = !show_connection_details;
    saved.deinit();
    if (privacy.prefs.profile_count == 0 and !editing and privacy.prefs.proxy_mode != .pool) note(@src(), "No saved proxies. Add one to connect or build a verified pool.");
    var remove: ?usize = null;
    for (0..privacy.prefs.profile_count) |i| {
        const p = &privacy.prefs.profiles[i];
        var r = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .expand = .horizontal, .background = true, .color_fill = .{ .color = theme.colors.bg_elevated }, .corners = theme.dims.rad_sm, .padding = dvui.Rect.all(6), .margin = .{ .h = 4 } });
        const active = privacy.prefs.active_profile == i and privacy.prefs.proxy_mode == p.kind;
        if (c.iconButton(@src(), if (active) icons.@"circle-check" else icons.@"arrow-right", "Use this proxy", active)) {
            privacy.prefs.active_profile = i;
            privacy.prefs.proxy_mode = p.kind;
            closeEditor();
            privacy.changed();
        }
        var name = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .gravity_y = 0.5 });
        _ = dvui.label(@src(), "{s}", .{p.name.text()}, .{ .expand = .horizontal, .color_text = .{ .color = theme.colors.text_primary }, .padding = dvui.Rect.all(0) });
        _ = dvui.label(@src(), "{s}:{d}", .{ p.host.text(), p.port }, .{ .expand = .horizontal, .font = dvui.themeGet().font_body.withSize(theme.font_size.small), .color_text = .{ .color = theme.colors.text_tertiary }, .padding = dvui.Rect.all(0) });
        name.deinit();
        const health = privacy.api.opal_security_pool_health(@intCast(i));
        if (health == 1) dvui.spinner(@src(), .{ .min_size_content = .{ .w = 14, .h = 14 }, .gravity_y = 0.5, .color_text = .{ .color = theme.colors.accent } }) else if (health == 2 or health == -1) dvui.icon(@src(), "", if (health == 2) icons.@"shield-check" else icons.@"circle-alert", .{}, .{ .min_size_content = .{ .w = 16, .h = 16 }, .gravity_y = 0.5, .color_text = .{ .color = if (health == 2) theme.colors.success else theme.colors.warning } });
        if (c.iconButton(@src(), icons.pencil, "Edit proxy", editing and edit_index == i)) beginEdit(i);
        if (c.iconButton(@src(), icons.@"trash-2", "Remove proxy", false)) remove = i;
        r.deinit();
    }
    if (remove) |i| {
        if (privacy.prefs.active_profile == i and privacy.prefs.proxy_mode == privacy.prefs.profiles[i].kind) privacy.prefs.proxy_mode = .system;
        if (privacy.prefs.active_profile > i) privacy.prefs.active_profile -= 1;
        for (i..privacy.prefs.profile_count - 1) |j| privacy.prefs.profiles[j] = privacy.prefs.profiles[j + 1];
        privacy.prefs.profile_count -= 1;
        privacy.prefs.profiles[privacy.prefs.profile_count] = .{};
        if (privacy.prefs.active_profile >= privacy.prefs.profile_count) privacy.prefs.active_profile = 0;
        closeEditor();
        privacy.changed();
    }
    if (show_connection_details) {
        note(@src(), "Browser traffic only. Proxy routes block local/intranet and literal IPv6 addresses; use System to access them.");
        note(@src(), "Pool verification uses HTTPS through saved proxies. Verified exits expire after six hours. Empty pools block traffic.");
    }
    if (editing) proxyEditor();
}
fn proxyEditor() void {
    if (!editing) return;
    var editor = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .background = true, .color_fill = .{ .color = theme.colors.bg_elevated }, .padding = dvui.Rect.all(10), .corners = theme.dims.rad_sm, .margin = .{ .y = 8 } });
    defer editor.deinit();
    if (@import("builtin").is_test) connection_layout_for_test.editor = editor.data().borderRectScale().r;
    var editor_title = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .h = 8 } });
    _ = dvui.label(@src(), "{s}", .{if (edit_index == null) "Add proxy" else "Edit proxy"}, .{ .expand = .horizontal, .gravity_y = 0.5, .color_text = .{ .color = theme.colors.text_primary } });
    var cancel = dvui.box(@src(), .{ .dir = .horizontal }, .{});
    if (c.iconButton(@src(), icons.x, "Cancel proxy changes", false)) closeEditor();
    if (@import("builtin").is_test) connection_layout_for_test.cancel = cancel.data().borderRectScale().r;
    cancel.deinit();
    editor_title.deinit();
    if (!editing) return;
    const kinds = [_]pure.ProxyKind{ .http, .https, .socks5 };
    const selected: usize = switch (draft.kind) {
        .https => 1,
        .socks5 => 2,
        else => 0,
    };
    if (c.segment(@src(), &.{ "HTTP", "HTTPS", "SOCKS5" }, selected)) |i| draft.kind = kinds[i];
    field(@src(), "Name", &draft.name.bytes, false);
    var address = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    field(@src(), "Host", &draft.host.bytes, false);
    var port = dvui.box(@src(), .{ .dir = .vertical }, .{ .min_size_content = .{ .w = 76 }, .max_size_content = dvui.Options.MaxSize.width(88), .margin = .{ .x = 8 } });
    field(@src(), "Port", &port_buf, false);
    port.deinit();
    address.deinit();
    if (c.iconActionButton(@src(), if (show_authentication) icons.@"chevron-down" else icons.@"chevron-right", "Authentication", .secondary, 71803)) show_authentication = !show_authentication;
    if (show_authentication) {
        if (@import("builtin").is_test) connection_layout_for_test.authentication_visible = true;
        var credentials = dvui.box(@src(), .{ .dir = if (editor.data().contentRect().w < 440) .vertical else .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 8 } });
        field(@src(), "Username", &draft.username.bytes, false);
        field(@src(), "Password", &draft.password.bytes, true);
        credentials.deinit();
    }
    if (editor_error.len > 0) c.bodyText(@src(), editor_error, theme.colors.danger);
    var buttons = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1, .margin = .{ .y = 10 } });
    defer buttons.deinit();
    if (c.iconActionButton(@src(), icons.check, "Save", .primary, 71801)) {
        syncField(48, &draft.name);
        syncField(256, &draft.host);
        syncField(128, &draft.username);
        syncField(128, &draft.password);
        draft.port = std.fmt.parseInt(u16, std.mem.sliceTo(&port_buf, 0), 10) catch 0;
        if (!pure.validProfile(&draft)) {
            editor_error = "Enter a name, a host without a URL scheme, and a port from 1 to 65535.";
            return;
        }
        const index = edit_index orelse privacy.prefs.profile_count;
        if (edit_index != null and privacy.prefs.active_profile == index and privacy.prefs.proxy_mode == privacy.prefs.profiles[index].kind) privacy.prefs.proxy_mode = draft.kind;
        privacy.prefs.profiles[index] = draft;
        if (edit_index == null) privacy.prefs.profile_count += 1;
        closeEditor();
        privacy.changed();
    }
    if (c.actionButton(@src(), "Cancel", .secondary, 71802)) closeEditor();
}

pub fn setPanelForTest(section: ?usize, editor: bool) void {
    if (!@import("builtin").is_test) @compileError("Browser panel fixtures are test-only");
    open = section != null;
    tab = section orelse 0;
    closeEditor();
    show_connection_details = false;
    if (editor) beginEdit(if (privacy.prefs.profile_count > 0) @as(usize, 0) else null);
}
