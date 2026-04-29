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

pub fn renderHeader() void {
    // Shared icon-only button style
    const ico = struct {
        fn btn(active: bool, wd: *dvui.WidgetData) dvui.Options {
            return .{
                .data_out = wd,
                .gravity_y = 0.5,
                .color_fill = if (active) theme.colors.accent else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .color_text = if (active) dvui.Color{ .r = 10, .g = 10, .b = 16, .a = 255 } else theme.colors.text_muted,
                .corner_radius = dvui.Rect.all(6),
                .border = dvui.Rect.all(0),
                .padding = .{ .x = 5, .y = 4, .w = 5, .h = 4 },
                .margin = .{ .x = 1, .y = 0, .w = 1, .h = 0 },
            };
        }
        fn ghost(wd: *dvui.WidgetData) dvui.Options {
            return .{
                .data_out = wd,
                .gravity_y = 0.5,
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .color_text = theme.colors.text_muted,
                .corner_radius = dvui.Rect.all(6),
                .border = dvui.Rect.all(0),
                .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
                .margin = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            };
        }
        fn danger(wd: *dvui.WidgetData) dvui.Options {
            return .{
                .data_out = wd,
                .gravity_y = 0.5,
                .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .color_text = dvui.Color{ .r = 180, .g = 60, .b = 60, .a = 200 },
                .corner_radius = dvui.Rect.all(6),
                .border = dvui.Rect.all(0),
                .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
                .margin = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            };
        }
    };



    var header_hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_header,
        .color_border = dvui.Color{ .r = 30, .g = 30, .b = 42, .a = 255 },
        .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
    });
    defer header_hbox.deinit();

    var wd: dvui.WidgetData = undefined;

    // ════════════════════════════════════════
    // ZONE 2: Player Controls (icon-only)
    // ════════════════════════════════════════
    if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"plus", .{}, .{}, ico.ghost(&wd))) {
        if (state.app.players.items.len < 16) {
            if (player.MediaPlayer.init(@import("../core/alloc.zig").allocator)) |p| {
                state.app.players.append(@import("../core/alloc.zig").allocator, p) catch {};
                state.app.active_player_idx = state.app.players.items.len - 1;
            } else |_| {}
        }
    }
    components.tip(@src(), wd, "Add screen");

    if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"minus", .{}, .{}, ico.danger(&wd))) {
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
    components.tip(@src(), wd, "Remove screen");

    {
        const ui = @import("ui.zig");
        ui.pollFileOpen();
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"folder-open", .{}, .{}, ico.ghost(&wd))) {
            ui.triggerFileOpen();
        }
        components.tip(@src(), wd, "Open file");
    }

    if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"save", .{}, .{}, ico.btn(state.app.ws_save_open, &wd))) {
        state.app.ws_save_open = !state.app.ws_save_open;
        state.app.ws_load_open = false;
        if (state.app.ws_save_open) {
            @memset(&state.app.ws_name_input, 0);
        }
    }
    components.tip(@src(), wd, "Save workspace");

    if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"upload", .{}, .{}, ico.btn(state.app.ws_load_open, &wd))) {
        const workspace = @import("workspace.zig");
        workspace.scanWorkspaces();
        state.app.ws_load_open = !state.app.ws_load_open;
        state.app.ws_save_open = false;
    }
    components.tip(@src(), wd, "Load workspace");

    { var s = dvui.box(@src(), .{}, theme.optBtnGroupSep()); s.deinit(); }

    // ════════════════════════════════════════
    // ZONE 3: Center URL Input (dominant)
    // ════════════════════════════════════════
    if (!shouldUrlInputBeInGrid()) {
        renderUrlInput(false);
    } else {
        var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
        sp.deinit();
    }


    // ════════════════════════════════════════
    // NOW PLAYING: Centered filename
    // ════════════════════════════════════════
    if (state.app.players.items.len > 0 and state.app.active_player_idx < state.app.players.items.len) {
        const p = state.app.players.items[state.app.active_player_idx];
        if (p.current_url_len > 0 and p.current_url_len <= 2048) {
            const full_path = p.current_url[0..p.current_url_len];
            // Extract basename
            var basename: []const u8 = full_path;
            if (std.mem.lastIndexOfScalar(u8, full_path, '/')) |slash| {
                basename = full_path[slash + 1 ..];
            } else if (std.mem.lastIndexOfScalar(u8, full_path, '\\')) |bslash| {
                basename = full_path[bslash + 1 ..];
            }
            // Truncate for display
            const display_len = @min(basename.len, 50);
            const display = basename[0..display_len];
            const suffix: []const u8 = if (basename.len > 50) "…" else "";
            var name_buf: [64]u8 = undefined;
            if (std.fmt.bufPrintZ(&name_buf, "{s}{s}", .{ display, suffix })) |name| {
                _ = dvui.label(@src(), "{s}", .{name}, .{
                    .gravity_y = 0.5,
                    .color_text = theme.colors.text_muted,
                    .margin = .{ .x = 4, .y = 0, .w = 4, .h = 0 },
                });
            } else |_| {}
        }
    }

    { var s = dvui.box(@src(), .{}, theme.optBtnGroupSep()); s.deinit(); }

    // ════════════════════════════════════════
    // ZONE 4: Feature Toggles (icon-only pills)
    // ════════════════════════════════════════
    if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"link", .{}, .{}, ico.btn(state.app.seek_sync, &wd))) {
        state.app.seek_sync = !state.app.seek_sync;
        state.markConfigDirty();
    }
    components.tip(@src(), wd, "Sync playback");

    if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"cpu", .{}, .{}, ico.btn(state.app.hwdec_enabled, &wd))) {
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
    components.tip(@src(), wd, "Hardware decode");

    if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"eye-off", .{}, .{}, ico.btn(state.app.incognito_mode, &wd))) {
        state.app.incognito_mode = !state.app.incognito_mode;
        if (state.app.incognito_mode) {
            state.showToast("🕶 Incognito ON");
        } else {
            state.showToast("Incognito OFF");
        }
    }
    components.tip(@src(), wd, "Incognito mode");

    { var s = dvui.box(@src(), .{}, theme.optBtnGroupSep()); s.deinit(); }

    // ════════════════════════════════════════
    // ZONE 5: Drawer toggle (rail is canonical module switcher)
    // ════════════════════════════════════════
    const drawer_icon = if (state.app.drawer_open)
        icons.tvg.lucide.@"panel-right-close"
    else
        icons.tvg.lucide.@"panel-right-open";
    if (dvui.buttonIcon(@src(), "", drawer_icon, .{}, .{}, ico.btn(state.app.drawer_open, &wd))) {
        state.app.drawer_open = !state.app.drawer_open;
    }
    components.tip(@src(), wd, "Toggle drawer");

    { var s = dvui.box(@src(), .{}, theme.optBtnGroupSep()); s.deinit(); }

    // ════════════════════════════════════════
    // ZONE 6: Settings (far right)
    // ════════════════════════════════════════
    // (AI chat bot icon removed — chat lives inline with input surface.)

    // Info button — toggles keyword shortcuts popover
    {
        if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"info", .{}, .{}, ico.btn(state.app.cheatsheet_open, &wd))) {
            state.app.cheatsheet_open = !state.app.cheatsheet_open;
        }
        components.tip(@src(), wd, "Keyword shortcuts");
    }

    // Voice mode toggle — persistent, color reflects phase
    {
        const voice = @import("../services/ai_voice.zig");
        const voice_icon = if (voice.conv_phase == .speaking)
            icons.tvg.lucide.@"volume-2"
        else if (voice.conv_phase == .listening or voice.is_recording)
            icons.tvg.lucide.@"mic"
        else
            icons.tvg.lucide.@"headphones";
        const active_color: dvui.Color = switch (voice.conv_phase) {
            .speaking => .{ .r = 100, .g = 220, .b = 130, .a = 255 }, // green
            .listening => .{ .r = 255, .g = 120, .b = 120, .a = 255 }, // red pulse
            .thinking => .{ .r = 255, .g = 200, .b = 80, .a = 255 }, // amber
            .idle, .transcribing => theme.colors.accent,
        };
        var voice_opts = ico.btn(voice.voice_mode, &wd);
        if (voice.voice_mode) voice_opts.color_text = active_color;
        if (dvui.buttonIcon(@src(), "", voice_icon, .{}, .{}, voice_opts)) {
            voice.voice_mode = !voice.voice_mode;
        }
        components.tip(@src(), wd, "Voice / conversation mode");
    }

    if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"palette", .{}, .{}, ico.ghost(&wd))) {
        theme.cycleTheme();
        state.showToast(theme.presetName(theme.active_preset));
    }
    components.tip(@src(), wd, "Theme");

    if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"settings", .{}, .{}, ico.btn(state.app.drawer_open and state.app.drawer_tab == .Settings, &wd))) {
        if (state.app.drawer_open and state.app.drawer_tab == .Settings) {
            state.app.drawer_open = false;
        } else {
            state.app.drawer_open = true;
            state.app.drawer_tab = .Settings;
        }
    }
    components.tip(@src(), wd, "Settings");
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

    var box_opts = dvui.Options{
        .background = true,
        .color_fill = dvui.Color{ .r = 18, .g = 18, .b = 26, .a = 255 },
        .corner_radius = dvui.Rect.all(8),
        .border = dvui.Rect.all(1),
        .color_border = dvui.Color{ .r = 40, .g = 40, .b = 55, .a = 180 },
        .padding = .{ .x = 2, .y = 1, .w = 2, .h = 1 },
        .margin = .{ .x = 1, .y = 0, .w = 1, .h = 0 },
    };
    if (is_large) {
        box_opts.min_size_content = .{ .w = 480, .h = 56 };
        box_opts.max_size_content = .{ .w = 620, .h = 56 };
        box_opts.padding = .{ .x = 10, .y = 6, .w = 8, .h = 6 };
        box_opts.margin = .{ .x = 0, .y = 18, .w = 0, .h = 0 };
        box_opts.gravity_x = 0.5;
        box_opts.corner_radius = dvui.Rect.all(14);
        box_opts.color_fill = dvui.Color{ .r = 20, .g = 20, .b = 28, .a = 255 };
        box_opts.color_border = theme.colors.accent;
        box_opts.border = dvui.Rect.all(1);
        box_opts.box_shadow = .{
            .color = theme.colors.accent,
            .offset = .{ .x = 0, .y = 0 },
            .fade = 22.0,
        };
    } else {
        box_opts.expand = .horizontal;
    }

    var url_bar = dvui.box(@src(), .{ .dir = .horizontal }, box_opts);
    defer url_bar.deinit();

    var te_opts = dvui.Options{
        .expand = .both,
        .color_fill = transparent,
        .color_border = transparent,
        .color_text = theme.colors.text_main,
        .color_text_press = theme.colors.text_main,
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
        .color_text = theme.colors.text_muted,
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
            .{ .r = 255, .g = 120, .b = 120, .a = 255 }
        else
            theme.colors.text_muted;
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
        const is_active = voice.conversation_active or voice.is_recording or voice.is_speaking or ai_chat_mod.is_generating;
        if (is_active) {
            var stop_wd: dvui.WidgetData = undefined;
            if (dvui.buttonIcon(@src(), "", icons.tvg.lucide.@"square", .{}, .{}, .{
                .data_out = &stop_wd,
                .gravity_y = 0.5,
                .color_text = .{ .r = 255, .g = 120, .b = 120, .a = 255 },
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
        const has_activity = first_zero > 0 or voice.conv_phase != .idle or voice.is_recording or ai_chat_mod.is_generating;

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

