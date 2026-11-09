//! iOS host frame. Startup, service ticks, page shell, pages and overlays are
//! the desktop implementations; this file only supplies safe-area layout, the
//! touch-sized player chrome and the UIKit callbacks.
const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");
const icons = @import("icons").tvg.lucide;
const io = @import("../core/io_global.zig");
const layout = @import("mobile_layout_pure.zig");
const host = @import("../mobile/host.zig");
var first_frame = true;

pub fn init() void {
    dvui.scroll_speed = 60;
    @import("../core/logs.zig").logs_allocator = @import("../core/alloc.zig").allocator;
    state.app.page_shell_enabled = true;
    // Desktop startup: workers, paths, DB, config, history, torrent session,
    // catalog warmup. Desktop-only helpers are gated inside coreInit.
    // Bundled resources (source catalog, CA roots) live in the app bundle;
    // desktop's detectResourceRoot probes do not apply on iOS.
    const res = std.mem.span(host.resourceDir());
    const n = @min(res.len, state.app.resource_root.len);
    @memcpy(state.app.resource_root[0..n], res[0..n]);
    state.app.resource_root_len = n;
    @import("../main.zig").coreInit() catch |err| std.log.err("coreInit: {t}", .{err});
    state.app.router.navigate(.home);
}

pub fn frame() !dvui.App.Result {
    @import("native_browser.zig").beginFrame();
    defer @import("native_browser.zig").endFrame();
    @import("../app_services.zig").tickEarly();
    @import("../app_services.zig").tickServices();
    @import("ui.zig").pollFileOpen();
    drainOpenRequest();
    @import("../app_services.zig").tickPlayers();
    for (dvui.events()) |event| {
        if (event.evt == .mouse) state.app.last_mouse_move_ms = io.milliTimestamp();
    }
    @import("../app_services.zig").tickPlayback();
    if (comptime host.ui_test_supported) if (host.uiTest()) @import("ios_uitest.zig").tick();
    @import("../core/config.zig").saveIfDirty();
    if (host.takeBack()) handleBack();

    var safe: layout.Insets = .{};
    var keyboard: f32 = 0;
    host.safeArea(&safe.top, &safe.bottom, &safe.left, &safe.right, &keyboard);
    const screen = dvui.windowRect();
    const viewport = layout.fit(screen.w, screen.h, safe);
    // Edge to edge; only the cutout and keyboard reserve space.
    const edges = layout.fit(screen.w, screen.h, layout.immersive(safe, keyboard)).insets;

    if (state.app.router.current == .player) {
        try renderPlayer(viewport, edges);
    } else {
        // The strip beside the Dynamic Island holds the shell's brand/menu
        // row (shell.cutout_band) instead of sitting empty.
        const shell = @import("shell.zig");
        shell.cutout_band = edges.top;
        shell.host_insets = .{ .top = 0, .bottom = edges.bottom, .left = edges.left, .right = edges.right };
        var root = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .background = true,
            .color_fill = .{ .color = theme.colors.bg_app },
            .padding = .{ .x = edges.left, .y = 0, .w = edges.right, .h = edges.bottom },
        });
        defer root.deinit();
        var scale_w = dvui.scale(@src(), .{ .scale = &state.app.ui_scale }, .{ .expand = .both });
        defer scale_w.deinit();
        @import("profiles_ui.zig").renderPicker();
        try @import("shell.zig").render();
    }
    renderOverlays();

    if (first_frame) {
        first_frame = false;
        host.ready();
    }
    return .ok;
}

/// UIKit picker/link callbacks only publish a bounded path. The owner frame
/// runs the same universal open as a desktop drop (files, URLs, magnets,
/// .torrent, comics, playlists); it creates the player on demand.
/// Android Back: same navigation as the on-screen back button, else background.
fn handleBack() void {
    const r = &state.app.router;
    switch (@import("../mobile/android_pure.zig").backAction(r.current == .player, r.canGoBack())) {
        .leave_player => r.leavePlayer(),
        .go_back => r.goBack(),
        .background => host.moveTaskToBack(),
    }
}

fn drainOpenRequest() void {
    var buf: [2048]u8 = undefined;
    var len: usize = 0;
    if (state.app.dropped_file_ready.load(.acquire)) {
        state.app.dropped_file_lock.lock();
        if (state.app.dropped_file_ready.swap(false, .acq_rel)) {
            len = @min(state.app.dropped_file_len, buf.len);
            @memcpy(buf[0..len], state.app.dropped_file_path[0..len]);
        }
        state.app.dropped_file_lock.unlock();
    }
    if (len == 0) return;
    state.app.last_mouse_move_ms = io.milliTimestamp();
    @import("../services/browser.zig").loadContent(buf[0..len]);
}

/// Player Back control, for the UI walk's simulated tap.
pub var back_button_rect: dvui.Rect.Physical = .{};

/// Full-bleed video. Transport sits on the bottom edge (the home indicator
/// auto-hides) and Back sits beside the Dynamic Island.
fn renderPlayer(viewport: layout.Viewport, edges: layout.Insets) !void {
    var stage = dvui.overlay(@src(), .{ .expand = .both, .min_size_content = .{ .w = viewport.width, .h = viewport.height }, .max_size_content = .{ .w = viewport.width, .h = viewport.height }, .background = true, .color_fill = .{ .color = theme.colors.bg_app } });
    defer stage.deinit();
    // Desktop renderPage(.player) minus its full-bleed overlays.
    try @import("grid.zig").renderGrid();
    {
        var controls = dvui.overlay(@src(), .{ .expand = .both, .margin = .{ .x = edges.left, .y = 0, .w = edges.right, .h = edges.bottom } });
        defer controls.deinit();
        @import("footer.zig").renderLiquidGlassOverlay();
        @import("footer.zig").renderStatsOverlay();
        @import("skip_overlay.zig").render();
    }
    const top = layout.bandOffset(edges.top, 32);
    var top_bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_y = 0, .padding = .{ .x = edges.left + 12, .y = top, .w = edges.right + 12, .h = 0 } });
    defer top_bar.deinit();
    var hit = dvui.box(@src(), .{}, .{});
    if (components.iconButton(@src(), icons.@"chevron-left", "Back to browsing", false)) state.app.router.leavePlayer();
    back_button_rect = hit.data().borderRectScale().r;
    hit.deinit();
    @import("shell.zig").setPlayerTopChrome(top_bar.data().borderRectScale().r);
}

/// Same floating layer as the desktop frame (main.zig), minus desktop-only
/// dialogs (dependency setup, updater, cheat sheet).
fn renderOverlays() void {
    // First run: same welcome as desktop, incl. "Install starter sources" —
    // without it a fresh install has no torrent indexers at all.
    @import("onboarding.zig").render();
    @import("metadata_dialog.zig").renderMetadataDialog();
    @import("../services/search.zig").renderNsfwModal();
    const settings = @import("settings.zig");
    settings.renderSettingsModal();
    settings.renderMediaInfo();
    @import("command_palette.zig").render();
    @import("footer.zig").renderSubPicker();
    @import("ui.zig").renderWorkspaceModals();
    @import("footer.zig").renderResumePrompt();
    @import("ui.zig").renderToast();
}
