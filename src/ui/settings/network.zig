const std = @import("std");
const dvui = @import("dvui");
const c = @import("../../core/c.zig");
const components = @import("../components.zig");
const state = @import("../../core/state.zig");
const theme = @import("../theme.zig");
const settings = @import("../settings.zig");
const absField = settings.absField;
const renderMusicConnection = settings.renderMusicConnection;
const sectionHeader = settings.sectionHeader;
const settingRow = settings.settingRow;

pub fn renderNetworkTab() void {
    sectionHeader("Transfers", "Torrent storage and download limits", 3000, @src());
    {
        const before = state.app.torrent_memory_only;
        components.toggleRow(@src(), "Stream torrents in memory", "Use RAM for new torrents; closing a stream releases its buffer.", &state.app.torrent_memory_only);
        if (before != state.app.torrent_memory_only) {
            state.applyTorrentStorageIfReady();
            state.markConfigDirty();
        }
        if (state.app.torrent_memory_only) {
            settingRow("RAM buffer per torrent", 3001, @src());
            const sizes = [_]i32{ 128, 256, 512 };
            const names = [_][]const u8{ "128 MiB", "256 MiB", "512 MiB" };
            var selected: usize = 1;
            for (sizes, 0..) |size, i| {
                if (size == state.app.torrent_memory_limit_mib) selected = i;
            }
            if (components.segment(@src(), &names, selected)) |i| {
                state.app.torrent_memory_limit_mib = sizes[i];
                state.applyTorrentStorageIfReady();
                state.markConfigDirty();
            }
            _ = dvui.label(@src(), "Older data is discarded. Seeking back may buffer again. Player memory is additional; the OS may swap RAM to disk.", .{}, .{ .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary) });
        }
    }

    // Download Speed Limit — short ramp via segment.
    settingRow("Download Speed Limit", 30, @src());
    {
        const limits = [_]i32{ 0, 1 * 1024 * 1024, 2 * 1024 * 1024, 5 * 1024 * 1024, 10 * 1024 * 1024, 20 * 1024 * 1024 };
        const limit_names = [_][]const u8{ "No Limit", "1 MB/s", "2 MB/s", "5 MB/s", "10 MB/s", "20 MB/s" };
        var sel: usize = 0;
        for (limits, 0..) |l, idx| {
            if (state.app.download_rate_limit == l) {
                sel = idx;
                break;
            }
        }
        if (components.segment(@src(), &limit_names, sel)) |clicked| {
            state.app.download_rate_limit = limits[clicked];
            c.mpv.torrent_set_download_limit(state.torrentSession(), limits[clicked]);
            state.markConfigDirty();
        }
    }

    sectionHeader(if (@import("../../services/native_browser.zig").supported) "Source browser engine" else "Browser engine", if (@import("../../services/native_browser.zig").supported) "Used by sources that need a browser to fetch pages. The browser page uses the built-in macOS browser." else "Used for web pages. Installation downloads about 200 MB; the selected engine starts on the next browser open.", 33, @src());
    {
        const browser = @import("../../services/browser.zig");
        const engines = [_]browser.Engine{ .camoufox, .cloakbrowser };
        const engine_names = [_][]const u8{ "Camoufox", "CloakBrowser" };
        var sel: usize = 0;
        for (engines, 0..) |e, idx| {
            if (browser.active_engine == e) {
                sel = idx;
                break;
            }
        }
        if (components.segment(@src(), &engine_names, sel)) |clicked| {
            if (browser.active_engine != engines[clicked]) {
                browser.active_engine = engines[clicked];
                state.markConfigDirty();
                // Takes effect on the next browser open — stop any running
                // bridge so it relaunches with the newly selected engine.
                browser.killBridge();
            }
        }
        // Per-engine install status + install action for the selected engine.
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 3301, .expand = .horizontal });
            defer row.deinit();
            dvui.labelNoFmt(@src(), if (browser.engineReady(browser.active_engine)) "Installed" else "Not installed", .{}, .{
                .id_extra = 3302,
                .expand = .horizontal,
                .color_text = @import("../color_compat.zig").wrap(if (browser.engineReady(browser.active_engine)) theme.colors.accent else theme.colors.text_secondary),
                .gravity_y = 0.5,
            });
            if (!browser.engineReady(browser.active_engine)) {
                if (dvui.button(@src(), "Install", .{}, .{
                    .id_extra = 3303,
                    .margin = .{ .x = 10, .y = 0, .w = 0, .h = 0 },
                    .color_fill = @import("../color_compat.zig").wrap(theme.colors.accent),
                    .color_text = @import("../color_compat.zig").wrap(theme.colors.text_on_accent),
                    .corners = theme.dims.rad_sm,
                    .padding = .{ .x = 10, .y = 3, .w = 10, .h = 3 },
                })) {
                    browser.installEngine();
                }
            }
        }
        const install_state = browser.installStatus();
        if (install_state != .idle) {
            _ = dvui.label(@src(), "Last browser installation: {s}", .{switch (install_state) {
                .running => "Working…",
                .failed => "Failed · see Logs",
                .done => "Completed",
                .idle => unreachable,
            }}, .{ .color_text = @import("../color_compat.zig").wrap(if (install_state == .failed) theme.colors.danger else theme.colors.text_secondary) });
            if (install_state == .running) components.pollRefresh(100_000);
        }
    }

    // Proxy URL
    sectionHeader("Proxy", "Used for yt-dlp and playlist extraction. For example: socks5://127.0.0.1:1080", 32, @src());
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 24 },
        });
        defer row.deinit();

        var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.proxy_url } }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 250, .h = 20 },
            .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
            .color_border = @import("../color_compat.zig").wrap(theme.colors.border_subtle),
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
            .border = dvui.Rect.all(1),
            .corners = theme.dims.rad_sm,
        });
        const proxy_changed = te.text_changed;
        te.deinit();

        // Update proxy_url_len from null-terminated buffer
        state.app.proxy_url_len = std.mem.indexOfScalar(u8, &state.app.proxy_url, 0) orelse 0;
        // Was a write-only field: stored, persisted, and read by nothing.
        state.applyTorrentProxyIfReady();
        if (proxy_changed) state.markConfigDirty();
    }
    // ── Bypass ISP blocking (DPI) ──────────────────────────────────────────
    // Toggles a loopback proxy sidecar (zig-bypassdpi) that fragments the TLS
    // ClientHello so an ISP can't block a source by its SNI hostname.
    sectionHeader("Connectivity", "Proxy tools and connection status", 34, @src());
    {
        const dpi = @import("../../services/dpi_bypass.zig");

        const before = state.app.dpi_bypass_enabled;
        components.toggleRow(@src(), "Bypass ISP blocking (DPI)", "Fragment the TLS handshake to defeat SNI-based blocking", &state.app.dpi_bypass_enabled);
        if (state.app.dpi_bypass_enabled != before) {
            if (state.app.dpi_bypass_enabled) dpi.start() else dpi.stop();
            state.markConfigDirty();
        }

        // Mode selector — maps to the sidecar's --mode (sni | split:1).
        const modes = [_][]const u8{ "sni", "split:1" };
        const mode_names = [_][]const u8{ "SNI", "Split" };
        const cur_mode = if (state.app.dpi_bypass_mode_len > 0)
            state.app.dpi_bypass_mode[0..state.app.dpi_bypass_mode_len]
        else
            "sni";
        var mode_sel: usize = 0;
        for (modes, 0..) |m, idx| {
            if (std.mem.eql(u8, m, cur_mode)) {
                mode_sel = idx;
                break;
            }
        }
        if (components.segment(@src(), &mode_names, mode_sel)) |clicked| {
            const nm = modes[clicked];
            @memcpy(state.app.dpi_bypass_mode[0..nm.len], nm);
            state.app.dpi_bypass_mode_len = nm.len;
            state.markConfigDirty();
            // Restart so the new mode takes effect immediately.
            if (state.app.dpi_bypass_enabled) {
                dpi.stop();
                dpi.start();
            }
        }

        // Status line.
        var sbuf: [64]u8 = undefined;
        const status = if (dpi.isRunning())
            std.fmt.bufPrint(&sbuf, "Running on 127.0.0.1:{d}", .{dpi.port()}) catch "Running"
        else
            "Stopped";
        _ = dvui.label(@src(), "{s}", .{status}, .{
            .id_extra = 3400,
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
        });
        _ = dvui.label(@src(), "Efficacy depends on your ISP's DPI. If one mode does not unblock a site, try the other.", .{}, .{
            .id_extra = 3401,
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
        });
    }

    // ── Reading server (OPDS) — Komga / Kavita / Calibre-Web / LANraragi ──
    // Mirrors the Jellyfin connection surface: catalog URL + Basic-auth creds +
    // a Test Connection button (opds.connect fetches the root feed).
    settingRow("Reading server (OPDS)", 34, @src());
    _ = dvui.label(@src(), "Komga · Kavita · Calibre-Web · LANraragi — manga, comics & ebooks", .{}, .{
        .id_extra = 3400,
        .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
    });
    {
        const opds = @import("../../services/opds.zig");
        // Catalog URL
        _ = dvui.label(@src(), "Catalog URL", .{}, .{ .id_extra = 3401, .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary) });
        {
            var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.opds.server_url } }, .{
                .id_extra = 3402,
                .expand = .horizontal,
                .min_size_content = .{ .w = 250, .h = 20 },
                .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
                .color_border = @import("../color_compat.zig").wrap(theme.colors.border_subtle),
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
                .border = dvui.Rect.all(1),
                .corners = theme.dims.rad_sm,
            });
            const changed = te.text_changed;
            te.deinit();
            state.app.opds.server_url_len = std.mem.indexOfScalar(u8, &state.app.opds.server_url, 0) orelse state.app.opds.server_url.len;
            if (changed) state.markConfigDirty();
        }
        // Username / Password
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 3403, .expand = .horizontal, .min_size_content = .{ .w = 0, .h = 26 } });
            defer row.deinit();
            var ute = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.opds.user_buf } }, .{
                .id_extra = 3404,
                .expand = .horizontal,
                .min_size_content = .{ .w = 120, .h = 20 },
                .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
                .color_border = @import("../color_compat.zig").wrap(theme.colors.border_subtle),
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
                .border = dvui.Rect.all(1),
                .corners = theme.dims.rad_sm,
            });
            const uchanged = ute.text_changed;
            ute.deinit();
            var pte = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.opds.pass_buf }, .password_char = "•" }, .{
                .id_extra = 3405,
                .expand = .horizontal,
                .min_size_content = .{ .w = 120, .h = 20 },
                .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
                .color_border = @import("../color_compat.zig").wrap(theme.colors.border_subtle),
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
                .border = dvui.Rect.all(1),
                .corners = theme.dims.rad_sm,
                .margin = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 },
            });
            const pchanged = pte.text_changed;
            pte.deinit();
            if (uchanged or pchanged) state.markConfigDirty();
        }
        // Test Connection + status
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 3406, .expand = .horizontal });
            defer row.deinit();
            const busy = state.app.opds.is_loading.load(.acquire);
            if (dvui.button(@src(), if (busy) "Connecting…" else "Test Connection", .{}, .{
                .id_extra = 3407,
                .color_fill = @import("../color_compat.zig").wrap(theme.colors.accent),
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_on_accent),
                .corners = theme.dims.rad_sm,
                .padding = .{ .x = theme.spacing.md, .y = 5, .w = theme.spacing.md, .h = 5 },
            }) and !busy) {
                state.markConfigDirty();
                opds.testConnection();
            }
            const status: []const u8 = if (state.app.opds.fetch_error and state.app.opds.error_msg_len > 0)
                state.app.opds.error_msg[0..state.app.opds.error_msg_len]
            else if (state.app.opds.connected)
                "Connected"
            else
                "Not connected";
            _ = dvui.label(@src(), "{s}", .{status}, .{
                .id_extra = 3408,
                .color_text = @import("../color_compat.zig").wrap(if (state.app.opds.fetch_error) theme.colors.danger else theme.colors.text_secondary),
                .gravity_y = 0.5,
                .margin = .{ .x = 10, .y = 0, .w = 0, .h = 0 },
            });
        }
    }

    renderMusicConnection();

    // ── Music discovery (ListenBrainz + MusicBrainz) ──
    // OFF by default. Every other music source only plays what you already
    // have; this is the only one that suggests something new. No API key —
    // ListenBrainz is keyless and its data is CC0 — but it does mean
    // outbound requests, so the user opts in explicitly.
    {
        const before = state.app.music_discovery_enabled;
        components.toggleRow(
            @src(),
            "Music discovery",
            "Suggest albums from artists similar to what you play, via ListenBrainz and MusicBrainz. No account or API key; off means no requests.",
            &state.app.music_discovery_enabled,
        );
        if (before != state.app.music_discovery_enabled) {
            @import("../../core/config.zig").save();
            if (state.app.music_discovery_enabled) @import("../../services/music_discovery.zig").refresh();
        }
    }

    // The Live TV custom-playlist box moved to Settings → Live TV
    // (renderLiveTvTab), which ingests it into the channel catalog rather
    // than the retired public-directory override.

    renderAudiobookshelfSection();
}

/// Audiobookshelf connection section (URL / user / pass + Test Connection).
/// Mirrors the Jellyfin login form but lives in Network settings; the actual
/// login worker + persistence live in services/audiobookshelf.zig.
fn renderAudiobookshelfSection() void {
    const abs = @import("../../services/audiobookshelf.zig");

    settingRow("Audiobookshelf Server", 40, @src());
    _ = dvui.label(@src(), "Self-hosted audiobooks/podcasts — streams straight into the player.", .{}, .{
        .id_extra = 4000,
        .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
    });

    if (state.app.abs.connected) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 4001, .expand = .horizontal });
        defer row.deinit();
        _ = dvui.label(@src(), "Connected: {s}", .{state.app.abs.server_url[0..state.app.abs.server_url_len]}, .{
            .id_extra = 4002,
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
            .gravity_y = 0.5,
        });
        if (dvui.button(@src(), "Disconnect", .{}, .{
            .id_extra = 4003,
            .margin = .{ .x = 10, .y = 0, .w = 0, .h = 0 },
            .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
            .corners = theme.dims.rad_sm,
            .padding = .{ .x = 10, .y = 3, .w = 10, .h = 3 },
        })) abs.disconnect();
        return;
    }

    absField("Server URL", &state.app.abs.server_url, false, 4010);
    absField("Username", &state.app.abs.login_user_buf, false, 4011);
    absField("Password", &state.app.abs.login_pass_buf, true, 4012);
    state.app.abs.server_url_len = std.mem.indexOfScalar(u8, &state.app.abs.server_url, 0) orelse state.app.abs.server_url_len;

    if (state.app.abs.login_error_len > 0) {
        _ = dvui.label(@src(), "{s}", .{state.app.abs.login_error[0..state.app.abs.login_error_len]}, .{
            .id_extra = 4013,
            .color_text = @import("../color_compat.zig").wrap(theme.colors.danger),
        });
    }

    if (state.app.abs.is_loading.load(.acquire)) {
        _ = dvui.label(@src(), "Connecting…", .{}, .{ .id_extra = 4014, .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary) });
    } else if (dvui.button(@src(), "Test Connection", .{}, .{
        .id_extra = 4015,
        .color_fill = @import("../color_compat.zig").wrap(theme.colors.accent),
        .color_text = @import("../color_compat.zig").wrap(theme.colors.text_on_accent),
        .corners = theme.dims.rad_sm,
        .padding = .{ .x = theme.spacing.md, .y = 5, .w = theme.spacing.md, .h = 5 },
        .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = 0 },
    })) {
        abs.authenticate();
    }
}
