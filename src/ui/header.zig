const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const c = @import("../core/c.zig");
const state = @import("../core/state.zig");
const player = @import("../player/player.zig");
const logs = @import("../core/logs.zig");
const search = @import("../services/search.zig");
const transfers = @import("../services/transfers.zig");
const theme = @import("theme.zig");
const metadata_dialog = @import("metadata_dialog.zig");
const components = @import("components.zig");

pub fn handleClipboardPaste() void {
    const clip_text = dvui.clipboardText();
    if (clip_text.len == 0) return;

    // Auto-create a player if none exists
    if (state.app.players.items.len == 0) {
        if (player.MediaPlayer.init(@import("../core/alloc.zig").allocator)) |new_p| {
            state.app.players.append(@import("../core/alloc.zig").allocator, new_p) catch {
                new_p.deinit(@import("../core/alloc.zig").allocator);
                return;
            };
            state.app.active_player_idx = 0;
        } else |_| { return; }
    }

    if (state.app.players.items.len == 0) return;
    if (state.app.active_player_idx >= state.app.players.items.len) {
        state.app.active_player_idx = state.app.players.items.len - 1;
    }

    if (std.mem.startsWith(u8, clip_text, "magnet:?")) {
        const searcher = @import("../services/search.zig");
        searcher.loadTorrentToPlayer(clip_text);
    } else if (@import("../services/projectjav.zig").isProjectJavUrl(clip_text)) {
        @import("../services/projectjav.zig").fetchTorrents(clip_text);
        logs.pushLog("info", "paste", "Fetching ProjectJav torrents...", false);
    } else {
        // Use smart routing to pick mpv/comic/browser
        const browser = @import("../services/browser.zig");
        browser.loadContent(clip_text[0..clip_text.len]);

        if (std.mem.startsWith(u8, clip_text, "http://") or std.mem.startsWith(u8, clip_text, "https://")) {
            logs.pushLog("info", "paste", "Routing pasted URL...", false);
        } else {
            logs.pushLog("info", "paste", "Loading file", false);
        }
    }
}

// ══════════════════════════════════════════════════════════════════
// Ephemeral header state (must live outside state.zig per constraint).
// `stream_key_open` toggles the click-to-reveal popover; the modal
// floating window closes itself on click-out via its `open_flag`.
// ══════════════════════════════════════════════════════════════════
const HeaderState = struct {
    var stream_key_open: bool = false;
};

// Tracks URL-input focus across frames so the outer box can show the accent
// focus ring (resting = hairline). One-frame lag, matching components.searchInput.
const UrlInputState = struct {
    var had_focus: bool = false;
};

/// Truncate a URL-ish string into a stack buffer using `first8…last8`
/// when it's longer than the limit. Keeps magnet hashes and HTTP paths
/// from leaking the middle (which is where IDs/tokens often live).
fn truncMiddle(out: []u8, src: []const u8, max_chars: usize) []const u8 {
    if (src.len <= max_chars) {
        const n = @min(src.len, out.len);
        @memcpy(out[0..n], src[0..n]);
        return out[0..n];
    }
    const head: usize = 8;
    const tail: usize = 8;
    const ellipsis = "…";
    var idx: usize = 0;
    const h = @min(head, out.len);
    @memcpy(out[idx..][0..h], src[0..h]);
    idx += h;
    if (idx + ellipsis.len <= out.len) {
        @memcpy(out[idx..][0..ellipsis.len], ellipsis);
        idx += ellipsis.len;
    }
    const t = @min(tail, out.len - idx);
    if (src.len >= t) {
        @memcpy(out[idx..][0..t], src[src.len - t ..]);
        idx += t;
    }
    return out[0..idx];
}

/// Compute the active player's stream token (16 hex chars) or null.
fn activeStreamToken() ?[]const u8 {
    if (state.app.players.items.len == 0) return null;
    if (state.app.active_player_idx >= state.app.players.items.len) return null;
    const p = state.app.players.items[state.app.active_player_idx];
    if (!p.proxy_handle.isValid()) return null;
    return p.proxy_handle.token[0..];
}

pub fn renderHeader() void {
    // Outer toolbar — fixed 44px height, single source of horizontal padding.
    var header_hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_app,
        .color_border = theme.colors.border_subtle,
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
        .min_size_content = .{ .w = 0, .h = 44 },
        .max_size_content = .{ .w = 99999, .h = 44 },
    });
    defer header_hbox.deinit();

    // TODO(drag-handle): dvui has no public hint to mark a main-window
    // region as the OS drag area. The title cluster below would be a good
    // candidate once a platform path lands (NSWindow setMovableByWindowBackground
    // on macOS, _NET_WM_MOVERESIZE on X11, etc.).

    // ════════════════════════════════════════
    // ZONE 1 — Left: logo + title
    // ════════════════════════════════════════
    {
        var left = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .gravity_y = 0.5,
            .padding = .{ .x = 0, .y = 0, .w = theme.spacing.lg, .h = 0 },
        });
        defer left.deinit();

        // Logo / brand mark — quiet, not the view's accent.
        dvui.icon(@src(), "brand", icons.tvg.lucide.@"zap", .{}, .{
            .color_text = theme.colors.text_secondary,
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 16, .h = 16 },
            .max_size_content = .{ .w = 16, .h = 16 },
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        });

        // Title: now-playing basename, secondary by default; primary
        // when media is active (the closest stand-in for "premium" we have).
        renderTitleLabel();
    }

    // ════════════════════════════════════════
    // ZONE 2 — Center: primary actions
    //   add/remove screen, file-open, workspace save/load,
    //   url paste/drop input
    // ════════════════════════════════════════
    {
        var center = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .gravity_y = 0.5,
            .padding = .{ .x = 0, .y = 0, .w = theme.spacing.lg, .h = 0 },
        });
        defer center.deinit();

        // Screen mgmt cluster.
        if (components.iconButton(@src(), icons.tvg.lucide.@"plus", "Add screen", false)) {
            if (state.app.players.items.len < 16) {
                if (player.MediaPlayer.init(@import("../core/alloc.zig").allocator)) |p| {
                    state.app.players.append(@import("../core/alloc.zig").allocator, p) catch {};
                    state.app.active_player_idx = state.app.players.items.len - 1;
                } else |_| {}
            }
        }
        spacerSm(@src());
        if (components.iconButton(@src(), icons.tvg.lucide.@"minus", "Remove screen", false)) {
            if (state.app.players.items.len > 0) {
                if (state.app.players.pop()) |p| {
                    if (p.current_url_len > 0 and p.current_url_len <= 2048) {
                        state.pushClosedUrl(p.current_url[0..p.current_url_len]);
                    }
                    p.deinit(@import("../core/alloc.zig").allocator);
                }
                if (state.app.active_player_idx >= state.app.players.items.len) {
                    state.app.active_player_idx = if (state.app.players.items.len > 0) state.app.players.items.len - 1 else 0;
                }
            }
        }

        spacerSm(@src());
        {
            const ui = @import("ui.zig");
            ui.pollFileOpen();
            if (components.iconButton(@src(), icons.tvg.lucide.@"folder-open", "Open file", false)) {
                ui.triggerFileOpen();
            }
        }

        spacerSm(@src());
        if (components.iconButton(@src(), icons.tvg.lucide.@"save", "Save workspace", state.app.ws_save_open)) {
            state.app.ws_save_open = !state.app.ws_save_open;
            state.app.ws_load_open = false;
            if (state.app.ws_save_open) {
                @memset(&state.app.ws_name_input, 0);
            }
        }
        spacerSm(@src());
        if (components.iconButton(@src(), icons.tvg.lucide.@"upload", "Load workspace", state.app.ws_load_open)) {
            const workspace = @import("workspace.zig");
            workspace.scanWorkspaces();
            state.app.ws_load_open = !state.app.ws_load_open;
            state.app.ws_save_open = false;
        }

        // URL input — expands to fill remaining width when not docked in the grid.
        {
            var pad = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = theme.spacing.sm, .h = 0 } });
            pad.deinit();
        }
        if (!shouldUrlInputBeInGrid()) {
            renderUrlInput(false);
        } else {
            var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            sp.deinit();
        }
    }

    // ════════════════════════════════════════
    // ZONE 3 — Right: feature toggles + stream-key chip + chrome
    // ════════════════════════════════════════
    {
        var right = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .gravity_y = 0.5,
        });
        defer right.deinit();

        // Feature toggles cluster.
        if (components.iconButton(@src(), icons.tvg.lucide.@"link", "Sync playback across screens", state.app.seek_sync)) {
            state.app.seek_sync = !state.app.seek_sync;
            state.markConfigDirty();
        }
        spacerSm(@src());
        if (components.iconButton(@src(), icons.tvg.lucide.@"cpu", "Hardware decode", state.app.hwdec_enabled)) {
            state.app.hwdec_enabled = !state.app.hwdec_enabled;
            state.markConfigDirty();
            const hw_val = if (state.app.hwdec_enabled) "auto" else "no";
            for (state.app.players.items) |p| {
                var hw_cmd: [64]u8 = undefined;
                if (std.fmt.bufPrintZ(&hw_cmd, "set hwdec {s}", .{hw_val})) |cmd| {
                    _ = c.mpv.mpv_command_string(p.mpv_ctx, cmd.ptr);
                } else |_| {}
            }
        }
        spacerSm(@src());
        if (components.iconButton(@src(), icons.tvg.lucide.@"eye-off", "Incognito mode", state.app.incognito_mode)) {
            state.app.incognito_mode = !state.app.incognito_mode;
            if (state.app.incognito_mode) {
                state.showToast("Incognito ON");
            } else {
                state.showToast("Incognito OFF");
            }
        }

        // Zone gap before chrome cluster.
        {
            var gap = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = theme.spacing.lg, .h = 0 } });
            gap.deinit();
        }

        // Stream-key chip — single button; on click toggles a click-to-reveal popover.
        if (activeStreamToken() != null) {
            if (components.iconButton(@src(), icons.tvg.lucide.@"key", "Stream Key (reveal)", HeaderState.stream_key_open)) {
                HeaderState.stream_key_open = !HeaderState.stream_key_open;
            }
            spacerSm(@src());
        }

        // Drawer toggle.
        const drawer_icon = if (state.app.drawer_open)
            icons.tvg.lucide.@"panel-right-close"
        else
            icons.tvg.lucide.@"panel-right-open";
        if (components.iconButton(@src(), drawer_icon, "Toggle drawer", state.app.drawer_open)) {
            state.app.drawer_open = !state.app.drawer_open;
        }

        // Cheatsheet / info popover toggle.
        spacerSm(@src());
        if (components.iconButton(@src(), icons.tvg.lucide.@"info", "Keyboard shortcuts", state.app.cheatsheet_open)) {
            state.app.cheatsheet_open = !state.app.cheatsheet_open;
        }

        // Voice / conversation mode.
        spacerSm(@src());
        renderVoiceButton();

        // Theme cycler.
        spacerSm(@src());
        if (components.iconButton(@src(), icons.tvg.lucide.@"palette", "Cycle theme", false)) {
            theme.cycleTheme();
            state.showToast(theme.presetName(theme.active_preset));
        }

        // Settings.
        spacerSm(@src());
        const settings_active = state.app.drawer_open and state.app.drawer_tab == .Settings;
        if (components.iconButton(@src(), icons.tvg.lucide.@"settings", "Settings", settings_active)) {
            if (settings_active) {
                state.app.drawer_open = false;
            } else {
                state.app.drawer_open = true;
                state.app.drawer_tab = .Settings;
            }
        }
    }

    // ════════════════════════════════════════
    // STREAM-KEY POPOVER (modal floating window — closes on click-out via dvui).
    // ════════════════════════════════════════
    if (HeaderState.stream_key_open) renderStreamKeyPopover();
}

/// 8px horizontal gap — between buttons within a single zone.
/// Caller passes @src() so each spacer gets a unique widget id (dvui would
/// otherwise complain about duplicate IDs since this function is called many
/// times from one parent).
fn spacerSm(src: std.builtin.SourceLocation) void {
    var s = dvui.box(src, .{}, .{ .min_size_content = .{ .w = theme.spacing.sm, .h = 0 } });
    s.deinit();
}

/// Now-playing basename: secondary by default, primary when media loaded.
fn renderTitleLabel() void {
    var clean_buf: [80]u8 = undefined;
    var clean_len: usize = 0;
    var media_loaded = false;

    if (state.app.players.items.len > 0 and state.app.active_player_idx < state.app.players.items.len) {
        const p = state.app.players.items[state.app.active_player_idx];
        media_loaded = p.current_url_len > 0 or p.texture != null;
        if (p.current_url_len > 0 and p.current_url_len <= 2048) {
            const full_path = p.current_url[0..p.current_url_len];
            var basename: []const u8 = full_path;
            if (std.mem.lastIndexOfScalar(u8, full_path, '/')) |slash| {
                basename = full_path[slash + 1 ..];
            } else if (std.mem.lastIndexOfScalar(u8, full_path, '\\')) |bslash| {
                basename = full_path[bslash + 1 ..];
            }
            // For http(s):// or magnet: URLs, prefer middle-truncated full URL
            // over basename (which is often the same hash or 'stream').
            const looks_like_url =
                std.mem.startsWith(u8, full_path, "magnet:") or
                std.mem.startsWith(u8, full_path, "http://") or
                std.mem.startsWith(u8, full_path, "https://");
            if (looks_like_url and basename.len > 32) {
                const t = truncMiddle(&clean_buf, full_path, 28);
                clean_len = t.len;
            } else {
                // Strip extension (last dot if extension <= 5 chars).
                var name_end: usize = basename.len;
                {
                    var last_dot: ?usize = null;
                    for (basename, 0..) |bch, bci| {
                        if (bch == '.') last_dot = bci;
                    }
                    if (last_dot) |dot| {
                        if (basename.len - dot <= 6) name_end = dot;
                    }
                }
                // Replace dots/underscores with spaces, collapse repeats.
                for (basename[0..name_end]) |bch| {
                    if (clean_len >= clean_buf.len - 4) break;
                    const out_ch: u8 = if (bch == '.' or bch == '_') ' ' else bch;
                    if (out_ch == ' ' and clean_len > 0 and clean_buf[clean_len - 1] == ' ') continue;
                    clean_buf[clean_len] = out_ch;
                    clean_len += 1;
                }
                while (clean_len > 0 and clean_buf[clean_len - 1] == ' ') clean_len -= 1;
            }
        }
    }

    if (clean_len == 0) {
        _ = dvui.label(@src(), "Opal", .{}, .{
            .gravity_y = 0.5,
            .color_text = theme.colors.text_secondary,
        });
        return;
    }

    // Truncate display to ~60 chars + ellipsis.
    const max_display: usize = 60;
    var name_buf: [80]u8 = undefined;
    const truncated = clean_len > max_display;
    const display_slice = clean_buf[0..@min(clean_len, max_display)];
    const written: []const u8 = if (truncated)
        (std.fmt.bufPrint(&name_buf, "{s}…", .{display_slice}) catch display_slice)
    else
        (std.fmt.bufPrint(&name_buf, "{s}", .{display_slice}) catch display_slice);
    _ = dvui.label(@src(), "{s}", .{written}, .{
        .gravity_y = 0.5,
        .color_text = if (media_loaded) theme.colors.text_primary else theme.colors.text_secondary,
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    });
}

/// Voice / conversation mode button — phase-aware color override on top
/// of the standard iconButton hover/active treatment.
fn renderVoiceButton() void {
    const voice = @import("../services/ai_voice.zig");
    const voice_icon = if (voice.conv_phase == .speaking)
        icons.tvg.lucide.@"volume-2"
    else if (voice.conv_phase == .listening or voice.is_recording)
        icons.tvg.lucide.@"mic"
    else
        icons.tvg.lucide.@"headphones";

    if (components.iconButton(@src(), voice_icon, "Voice / conversation mode", voice.conversation_active)) {
        voice.toggleConversation();
    }
}

/// Stream-key reveal popover.  Renders a small modal floating window with
/// the 16-hex token + Copy button.  Closes on click-out via `open_flag`.
fn renderStreamKeyPopover() void {
    var win = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &HeaderState.stream_key_open,
    }, .{
        .min_size_content = .{ .w = 320, .h = 130 },
        .color_fill = theme.colors.bg_surface,
        .corner_radius = dvui.Rect.all(theme.radius.lg),
    });
    defer win.deinit();

    win.dragAreaSet(dvui.windowHeader("Stream Key", "", &HeaderState.stream_key_open));

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = theme.spacing.lg, .y = theme.spacing.md, .w = theme.spacing.lg, .h = theme.spacing.md },
    });
    defer body.deinit();

    _ = dvui.label(@src(), "Per-stream auth token for this player's local HTTP proxy. Treat it like a password — anyone with this key can read the active stream.", .{}, .{
        .color_text = theme.colors.text_tertiary,
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.sm },
    });

    const token_slice = activeStreamToken() orelse {
        _ = dvui.label(@src(), "No active stream.", .{}, .{
            .color_text = theme.colors.text_tertiary,
        });
        return;
    };

    // Token row: distinguished by fill-tier alone (no border).
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_elevated,
        .corner_radius = dvui.Rect.all(theme.radius.md),
        .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.sm, .h = theme.spacing.sm },
    });
    defer row.deinit();

    _ = dvui.label(@src(), "{s}", .{token_slice}, .{
        .gravity_y = 0.5,
        .color_text = theme.colors.text_primary,
    });
    { var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal }); sp.deinit(); }

    if (components.iconButton(@src(), icons.tvg.lucide.@"copy", "Copy to clipboard", false)) {
        dvui.clipboardTextSet(token_slice);
        state.showToast("Stream key copied");
    }
}

pub fn shouldUrlInputBeInGrid() bool {
    if (state.app.players.items.len == 0) return true;
    if (state.app.active_player_idx >= state.app.players.items.len) return true;
    const p = state.app.players.items[state.app.active_player_idx];
    if (p.provider != .mpv) return false;
    if (p.is_loading) return false;
    if (p.current_torrent_id >= 0) return false;
    if (p.texture != null) return false;
    return true;
}

pub fn renderUrlInput(is_large: bool) void {
    const transparent = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

    // Resting = hairline; focus = accent ring. Lags one frame (matches the
    // foundation's components.searchInput convention).
    const has_focus = UrlInputState.had_focus;

    var box_opts = dvui.Options{
        .background = true,
        .color_fill = theme.colors.bg_input,
        .corner_radius = dvui.Rect.all(theme.radius.md),
        .border = dvui.Rect.all(1),
        .color_border = if (has_focus) theme.colors.accent else theme.colors.border_subtle,
        .padding = .{ .x = 2, .y = 1, .w = 2, .h = 1 },
        .margin = .{ .x = 1, .y = 0, .w = 1, .h = 0 },
    };
    if (is_large) {
        box_opts.min_size_content = .{ .w = 480, .h = 56 };
        box_opts.max_size_content = .{ .w = 620, .h = 56 };
        box_opts.padding = .{ .x = 10, .y = 6, .w = 8, .h = 6 };
        box_opts.margin = .{ .x = 0, .y = 18, .w = 0, .h = 0 };
        box_opts.gravity_x = 0.5;
    } else {
        box_opts.expand = .horizontal;
    }

    var url_bar = dvui.box(@src(), .{ .dir = .horizontal }, box_opts);
    defer url_bar.deinit();

    var te_opts = dvui.Options{
        .expand = .both,
        .color_fill = transparent,
        .color_border = transparent,
        .color_text = theme.colors.text_primary,
        .color_text_press = theme.colors.text_primary,
        .background = false,
        .border = dvui.Rect.all(0),
        .corner_radius = dvui.Rect.all(0),
        .padding = if (is_large) .{ .x = 10, .y = 12, .w = 6, .h = 12 } else .{ .x = 6, .y = 3, .w = 4, .h = 3 },
        .gravity_y = 0.5,
    };
    if (!is_large) {
        te_opts.min_size_content = .{ .w = 200, .h = 18 };
    }

    var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.magnet_buf }, .placeholder = if (is_large) "Paste link, drop file, or ask AI…" else "Paste, drop, or ask…" }, te_opts);
    const enter_pressed = te.enter_pressed;
    if (dvui.focusedWidgetIdInCurrentSubwindow()) |fid| {
        UrlInputState.had_focus = te.data().id == fid;
    } else {
        UrlInputState.had_focus = false;
    }
    te.deinit();

    // Inline play button
    var play_wd: dvui.WidgetData = undefined;
    const clicked_load = dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"play", .{}, .{}, .{
        .data_out = &play_wd,
        .gravity_y = 0.5,
        .color_text = theme.colors.accent,
        .color_fill = transparent,
        .border = dvui.Rect.all(0),
        .padding = .{ .x = 5, .y = 4, .w = 3, .h = 4 },
    });
    if (!is_large) components.tip(@src(), play_wd, "Load URL / magnet");

    // Inline paste button
    var paste_wd: dvui.WidgetData = undefined;
    if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"clipboard-paste", .{}, .{}, .{
        .data_out = &paste_wd,
        .gravity_y = 0.5,
        .color_text = theme.colors.text_tertiary,
        .color_fill = transparent,
        .border = dvui.Rect.all(0),
        .padding = .{ .x = 3, .y = 4, .w = 5, .h = 4 },
    })) {
        handleClipboardPaste();
    }
    if (!is_large) components.tip(@src(), paste_wd, "Paste from clipboard");

    // Inline mic button — push-to-talk / record
    {
        const voice = @import("../services/ai_voice.zig");
        const ai_chat_mod = @import("../services/ai_chat.zig");
        const mic_color: dvui.Color = if (voice.is_recording)
            theme.colors.danger
        else
            theme.colors.text_tertiary;
        var mic_wd: dvui.WidgetData = undefined;
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"mic", .{}, .{}, .{
            .data_out = &mic_wd,
            .gravity_y = 0.5,
            .color_text = mic_color,
            .color_fill = transparent,
            .border = dvui.Rect.all(0),
            .padding = .{ .x = 6, .y = 6, .w = 6, .h = 6 },
            .min_size_content = .{ .w = 18, .h = 18 },
        })) {
            @import("../core/logs.zig").pushLog("info", "mic", "button clicked", true);
            voice.toggleMicRecording();
            ai_chat_mod.is_bubble_open = true;
        }
        if (!is_large) components.tip(@src(), mic_wd, "Mic / push-to-talk");

        // Emergency stop when anything is active
        const is_active = voice.conversation_active or voice.is_recording or voice.is_speaking or ai_chat_mod.is_generating.load(.acquire);
        if (is_active) {
            var stop_wd: dvui.WidgetData = undefined;
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"square", .{}, .{}, .{
                .data_out = &stop_wd,
                .gravity_y = 0.5,
                .color_text = theme.colors.danger,
                .color_fill = transparent,
                .border = dvui.Rect.all(0),
                .padding = .{ .x = 3, .y = 4, .w = 3, .h = 4 },
            })) {
                ai_chat_mod.stopAll();
            }
            if (!is_large) components.tip(@src(), stop_wd, "Stop");
        }
    }

    // Auto-expand chat bubble on input transition (empty → non-empty) OR voice start.
    // Collapse on input-clear transition (non-empty → empty) when idle.
    {
        const ExpandState = struct {
            var last_text_len: usize = 0;
            var last_conv_phase: @import("../services/ai_voice.zig").ConvPhase = .idle;
        };
        const voice = @import("../services/ai_voice.zig");
        const ai_chat_mod = @import("../services/ai_chat.zig");
        const first_zero = std.mem.indexOfScalar(u8, &state.app.magnet_buf, 0) orelse state.app.magnet_buf.len;
        const text_became_nonempty = ExpandState.last_text_len == 0 and first_zero > 0;
        const voice_started = ExpandState.last_conv_phase == .idle and voice.conv_phase != .idle;
        const text_became_empty = ExpandState.last_text_len > 0 and first_zero == 0;
        const has_activity = first_zero > 0 or voice.conv_phase != .idle or voice.is_recording or ai_chat_mod.is_generating.load(.acquire);

        if (text_became_nonempty or voice_started) ai_chat_mod.is_bubble_open = true;
        if (text_became_empty and !has_activity and ai_chat_mod.message_count == 0) ai_chat_mod.is_bubble_open = false;

        ExpandState.last_text_len = first_zero;
        ExpandState.last_conv_phase = voice.conv_phase;
    }

    // Handle Enter / Play click
    if (clicked_load or enter_pressed) {
        const len = std.mem.indexOfScalar(u8, &state.app.magnet_buf, 0) orelse state.app.magnet_buf.len;
        if (len > 0) {
            const text = state.app.magnet_buf[0..len];

            // Unified input: route to AI chat if not URL/magnet/path. Media goes to player.
            const looks_like_media =
                std.mem.startsWith(u8, text, "magnet:") or
                std.mem.startsWith(u8, text, "http://") or
                std.mem.startsWith(u8, text, "https://") or
                std.mem.startsWith(u8, text, "file://") or
                std.mem.startsWith(u8, text, "/") or
                std.mem.startsWith(u8, text, "~/") or
                std.mem.startsWith(u8, text, "./") or
                std.mem.startsWith(u8, text, "ftp://") or
                std.mem.startsWith(u8, text, "rtmp://") or
                std.mem.startsWith(u8, text, "rtsp://");

            if (!looks_like_media) {
                const ai_chat = @import("../services/ai_chat.zig");
                const copy_len = @min(len, ai_chat.input_buf.len - 1);
                @memset(&ai_chat.input_buf, 0);
                @memcpy(ai_chat.input_buf[0..copy_len], text[0..copy_len]);
                ai_chat.input_len = copy_len;
                // Chat renders inline in empty player card — no floating window.
                // trySendMessage auto-starts apfel/llama-server if not running.
                ai_chat.trySendMessage();
                @memset(&state.app.magnet_buf, 0);
                return;
            }

            var null_term_uri: [2048]u8 = undefined;
            @memcpy(null_term_uri[0..len], text);
            null_term_uri[len] = 0;

            // Auto-create a player if none exists
            if (state.app.players.items.len == 0) {
                if (player.MediaPlayer.init(@import("../core/alloc.zig").allocator)) |new_p| {
                    state.app.players.append(@import("../core/alloc.zig").allocator, new_p) catch {
                        new_p.deinit(@import("../core/alloc.zig").allocator);
                    };
                    state.app.active_player_idx = 0;
                } else |_| {}
            }

            if (state.app.active_player_idx < state.app.players.items.len) {
                if (std.mem.startsWith(u8, null_term_uri[0..len], "magnet:?")) {
                    const tid = c.mpv.torrent_add_magnet(state.app.torrent_ses, @ptrCast(&null_term_uri[0]), state.getSavePath());
                    if (tid >= 0) {
                        state.app.pending_magnet_tid = tid;
                        state.app.pending_magnet_player_idx = state.app.active_player_idx;
                        state.app.pending_has_metadata = false;
                        @memcpy(state.app.pending_source_url[0..len], null_term_uri[0..len]);
                        state.app.pending_source_url_len = len;
                        for (&state.app.pending_files_selection) |*b| b.* = true;
                        state.app.drawer_open = false;
                        @memset(&state.app.magnet_buf, 0);
                        state.showToast("Magnet added — fetching metadata...");
                    } else {
                        state.showToast("Failed to add magnet link");
                    }
                } else if (@import("../services/projectjav.zig").isProjectJavUrl(null_term_uri[0..len])) {
                    @import("../services/projectjav.zig").fetchTorrents(null_term_uri[0..len]);
                    @memset(&state.app.magnet_buf, 0);
                    state.showToast("Fetching torrents...");
                } else {
                    @memset(&state.app.magnet_buf, 0);
                    state.showToast("Routing content...");
                    const browser = @import("../services/browser.zig");
                    browser.loadContent(null_term_uri[0..len]);
                }
            }
        }
    }
}

/// Slim tab strip below the header — only rendered when 2+ players exist.
pub fn renderTabBar() void {
    if (state.app.players.items.len < 2) return;

    var tab_bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_app,
        .color_border = theme.colors.border_subtle,
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .padding = .{ .x = theme.spacing.xs, .y = 0, .w = theme.spacing.xs, .h = 0 },
    });
    defer tab_bar.deinit();

    for (state.app.players.items, 0..) |p, i| {
        const is_active = i == state.app.active_player_idx;

        // Extract cleaned name from URL
        var tab_label: []const u8 = "Empty";
        var clean_buf: [40]u8 = undefined;
        var clean_len: usize = 0;

        if (p.current_url_len > 0 and p.current_url_len <= 2048) {
            const full = p.current_url[0..p.current_url_len];
            var basename: []const u8 = full;
            if (std.mem.lastIndexOfScalar(u8, full, '/')) |sl| {
                basename = full[sl + 1 ..];
            }
            // Strip extension
            var name_end: usize = basename.len;
            {
                var ld: ?usize = null;
                for (basename, 0..) |bch, bi| { if (bch == '.') ld = bi; }
                if (ld) |d| { if (basename.len - d <= 6) name_end = d; }
            }
            // Replace dots/underscores
            for (basename[0..@min(name_end, clean_buf.len)]) |bch| {
                if (clean_len >= clean_buf.len - 1) break;
                const out: u8 = if (bch == '.' or bch == '_') ' ' else bch;
                if (out == ' ' and clean_len > 0 and clean_buf[clean_len - 1] == ' ') continue;
                clean_buf[clean_len] = out;
                clean_len += 1;
            }
            while (clean_len > 0 and clean_buf[clean_len - 1] == ' ') clean_len -= 1;
            if (clean_len > 0) {
                // Truncate to ~25 chars
                tab_label = clean_buf[0..@min(clean_len, 25)];
            }
        }

        // Tab button — active = accent TEXT only (no fill, no underline box).
        const transparent = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
        if (dvui.button(@src(), tab_label, .{}, .{
            .id_extra = i,
            .color_fill = transparent,
            .color_text = if (is_active) theme.colors.accent else theme.colors.text_tertiary,
            .color_border = transparent,
            .border = dvui.Rect.all(0),
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
            .margin = .{ .x = 1, .y = 0, .w = 1, .h = 0 },
        })) {
            state.app.active_player_idx = i;
        }
    }
}
