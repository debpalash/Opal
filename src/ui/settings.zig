const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("theme.zig");
const c = @import("../core/c.zig");
const logs = @import("../core/logs.zig");
const paths = @import("../core/paths.zig");
const fileassoc = @import("settings_fileassoc.zig");

// ══════════════════════════════════════════════════════════
// Premium Settings Modal — always-centered dark overlay
// ══════════════════════════════════════════════════════════

pub fn renderSettingsModal() void {
    if (!state.app.settings_open) return;
    state.markConfigDirty(); // auto-save any setting changes
    
    // Use floatingWindow for proper modal behavior (blocks input behind, movable)
    var win = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &state.app.settings_open,
    }, .{
        .expand = .both,
        .min_size_content = .{ .w = 600, .h = 400 },
        .color_fill = theme.colors.bg_drawer,
        .color_border = theme.colors.border_card,
        .border = dvui.Rect.all(1),
        .corner_radius = dvui.Rect.all(12),
    });
    defer win.deinit();
    
    // ── Custom dark header (replaces windowHeader which forces light theme) ──
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = theme.colors.bg_header,
            .padding = .{ .x = 12, .y = 8, .w = 8, .h = 8 },
            .color_border = theme.colors.bg_header_border,
            .border = .{ .x = 0, .y = 0, .w = 0, .h = 1 },
        });
        defer hdr.deinit();
        
        dvui.icon(@src(), "", icons.tvg.lucide.@"settings", .{}, .{
            .color_text = theme.colors.accent,
            .gravity_y = 0.5,
        });
        _ = dvui.label(@src(), " Settings", .{}, .{
            .color_text = theme.colors.text_main,
            .gravity_y = 0.5,
        });
        
        { var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal }); spacer.deinit(); }
        
        if (dvui.buttonIcon(@src(), "Close", icons.tvg.lucide.@"x", .{}, .{}, .{
            .color_text = theme.colors.text_muted,
            .color_fill = dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .border = dvui.Rect.all(0),
            .gravity_y = 0.5,
        })) {
            state.app.settings_open = false;
        }
    }
    
    // Scale contents
    var settings_scale: f32 = 1.5;
    var scale_w = dvui.scale(@src(), .{ .scale = &settings_scale }, .{ .expand = .both });
    defer scale_w.deinit();
    
    // ── Tab bar with icon + text ──
    {
        var tab_container = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
            .margin = .{ .x = 4, .y = 4, .w = 4, .h = 0 },
            .background = true,
            .color_fill = theme.colors.bg_app,
            .corner_radius = dvui.Rect.all(8),
        });
        defer tab_container.deinit();
        
        // Each tab rendered individually with icon + text via button
        const tabs = .{
            .{ state.SettingsTab.General, "General", icons.tvg.lucide.@"sliders-horizontal" },
            .{ state.SettingsTab.Playback, "Playback", icons.tvg.lucide.@"play" },
            .{ state.SettingsTab.Network, "Network", icons.tvg.lucide.@"globe" },
            .{ state.SettingsTab.Subtitles, "Subs", icons.tvg.lucide.@"captions" },
            .{ state.SettingsTab.Storage, "Storage", icons.tvg.lucide.@"hard-drive" },
            .{ state.SettingsTab.Scripts, "Scripts", icons.tvg.lucide.@"file-code" },
            .{ state.SettingsTab.LangLearn, "Lang", icons.tvg.lucide.@"languages" },
            .{ state.SettingsTab.FileAssoc, "File Types", icons.tvg.lucide.@"file-cog" },
        };
        
        inline for (tabs, 0..) |tab, idx| {
            const is_active = state.app.settings_tab == tab[0];
            const tab_text_color = if (is_active) theme.colors.bg_app else theme.colors.text_muted;
            const tab_bg_color = if (is_active) theme.colors.accent else dvui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
            
            if (dvui.buttonIcon(@src(), tab[1], tab[2], .{}, .{}, .{
                .id_extra = idx,
                .color_fill = tab_bg_color,
                .color_text = tab_text_color,
                .margin = .{ .x = 0, .y = 0, .w = 2, .h = 0 },
                .padding = .{ .x = 8, .y = 5, .w = 8, .h = 5 },
                .corner_radius = dvui.Rect.all(99),
            })) {
                state.app.settings_tab = tab[0];
            }
        }
    }
    
    // ── Tab content (scrollable, dark bg) ──
    {
        var scroll = dvui.scrollArea(@src(), .{}, .{
            .expand = .both,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
            .background = true,
            .color_fill = theme.colors.bg_drawer,
        });
        defer scroll.deinit();
        
        var content = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
        });
        defer content.deinit();
        
        switch (state.app.settings_tab) {
            .General   => renderGeneralTab(),
            .Playback  => renderPlaybackTab(),
            .Network   => renderNetworkTab(),
            .Subtitles => renderSubtitlesTab(),
            .Storage   => renderStorageTab(),
            .Scripts   => renderScriptsTab(),
            .LangLearn => renderLangLearnTab(),
            .FileAssoc => renderFileAssocTab(),
        }
    }
}

// ══════════════════════════════════════════════════════════
// Design System Helpers
// ══════════════════════════════════════════════════════════

const card_bg = dvui.Color{ .r = 24, .g = 24, .b = 32, .a = 255 };
const card_border = dvui.Color{ .r = 45, .g = 45, .b = 60, .a = 180 };
const muted_text = dvui.Color{ .r = 120, .g = 120, .b = 145, .a = 255 };
const label_text = dvui.Color{ .r = 210, .g = 210, .b = 225, .a = 255 };

fn sectionHeader(comptime title: []const u8, comptime subtitle: []const u8, id_extra: usize, src: std.builtin.SourceLocation) void {
    // Accent-bordered section header
    var hdr = dvui.box(src, .{ .dir = .vertical }, .{
        .id_extra = id_extra + 900,
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_surface,
        .color_border = theme.colors.accent,
        .border = .{ .x = 3, .y = 0, .w = 0, .h = 0 },
        .corner_radius = .{ .x = 4, .y = 0, .w = 0, .h = 4 },
        .padding = .{ .x = 10, .y = 6, .w = 6, .h = 6 },
        .margin = .{ .x = 0, .y = 10, .w = 0, .h = 4 },
    });
    defer hdr.deinit();

    _ = dvui.label(src, title, .{}, .{
        .id_extra = id_extra,
        .color_text = theme.colors.text_main,
    });
    if (subtitle.len > 0) {
        _ = dvui.label(src, subtitle, .{}, .{
            .id_extra = id_extra + 1,
            .color_text = theme.colors.text_dim,
            .margin = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
        });
    }
}

fn settingRow(comptime label_text_str: []const u8, id_extra: usize, src: std.builtin.SourceLocation) void {
    _ = dvui.label(src, label_text_str, .{}, .{
        .id_extra = id_extra,
        .color_text = label_text,
        .margin = .{ .x = 0, .y = 4, .w = 0, .h = 4 },
    });
}

fn renderGeneralTab() void {
    // ── Interface Card ──
    sectionHeader("Interface", "Customize how ZigZag looks and feels", 10, @src());
    {
        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = card_bg,
            .color_border = card_border,
            .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(8),
            .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
        });
        defer card.deinit();
        
        // UI Scale
        _ = dvui.label(@src(), "UI Scale", .{}, .{ .color_text = muted_text, .margin = .{ .x = 0, .y = 0, .w = 0, .h = 4 } });
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
            });
            defer row.deinit();
            
            const scales = [_]f32{ 1.0, 1.1, 1.2, 1.3, 1.5, 1.7, 2.0 };
            for (scales, 0..) |s, idx| {
                var lbl: [8]u8 = undefined;
                const txt = std.fmt.bufPrintZ(&lbl, "{d:.1}x", .{s}) catch "?";
                const is_active = @abs(state.app.ui_scale - s) < 0.05;
                if (dvui.button(@src(), txt, .{}, .{
                    .id_extra = idx,
                    .color_fill = if (is_active) theme.colors.accent else dvui.Color{ .r = 35, .g = 35, .b = 48, .a = 255 },
                    .color_text = if (is_active) dvui.Color{ .r = 10, .g = 10, .b = 16, .a = 255 } else muted_text,
                    .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
                    .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
                    .corner_radius = dvui.Rect.all(6),
                })) {
                    state.app.ui_scale = s;
                }
            }
        }
        
        // Separator
        {
            var sep = dvui.box(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .{ .w = 0, .h = 1 }, .background = true, .color_fill = card_border, .margin = .{ .x = 0, .y = 8, .w = 0, .h = 8 } });
            sep.deinit();
        }
        
        // Grid Layout
        _ = dvui.label(@src(), "Grid Layout", .{}, .{ .id_extra = 11, .color_text = muted_text, .margin = .{ .x = 0, .y = 0, .w = 0, .h = 4 } });
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
            });
            defer row.deinit();
            
            const modes = [_]state.GridMode{ .auto, .cols_1, .cols_2, .cols_3, .cols_4 };
            const mode_names = [_][]const u8{ "Auto", "1 Col", "2 Col", "3 Col", "4 Col" };
            for (modes, 0..) |m, idx| {
                const is_active = state.app.grid_mode == m;
                if (dvui.button(@src(), mode_names[idx], .{}, .{
                    .id_extra = idx,
                    .color_fill = if (is_active) theme.colors.accent else dvui.Color{ .r = 35, .g = 35, .b = 48, .a = 255 },
                    .color_text = if (is_active) dvui.Color{ .r = 10, .g = 10, .b = 16, .a = 255 } else muted_text,
                    .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
                    .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
                    .corner_radius = dvui.Rect.all(6),
                })) {
                    state.app.grid_mode = m;
                }
            }
        }
        
        // Separator
        { var sep = dvui.box(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .{ .w = 0, .h = 1 }, .background = true, .color_fill = card_border, .margin = .{ .x = 0, .y = 8, .w = 0, .h = 8 } }); sep.deinit(); }
        
        // Theme Picker
        _ = dvui.label(@src(), "Theme", .{}, .{ .id_extra = 1500, .color_text = muted_text, .margin = .{ .x = 0, .y = 0, .w = 0, .h = 4 } });
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
            });
            defer row.deinit();
            
            const presets = [_]theme.ThemePreset{ .midnight, .abyss, .phantom, .nord, .solarized, .rose, .ember };
            for (presets, 0..) |preset, idx| {
                const is_active = theme.active_preset == preset;
                const pc = theme.getThemeColors(preset);
                const name = theme.presetName(preset);
                
                // Button with accent color preview
                if (dvui.button(@src(), name, .{}, .{
                    .id_extra = idx + 1510,
                    .color_fill = if (is_active) pc.accent else dvui.Color{ .r = 35, .g = 35, .b = 48, .a = 255 },
                    .color_text = if (is_active) pc.bg_app else pc.accent,
                    .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
                    .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
                    .corner_radius = dvui.Rect.all(6),
                })) {
                    theme.setPreset(preset);
                    state.showToast(name);
                }
            }
        }
    }
    
    // ── Behavior Card ──
    sectionHeader("Behavior", "Toggles that control app behavior", 12, @src());
    {
        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = card_bg,
            .color_border = card_border,
            .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(8),
            .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
        });
        defer card.deinit();
        
        // Seek Sync toggle
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer row.deinit();
            _ = dvui.label(@src(), "Seek Sync", .{}, .{ .color_text = label_text, .gravity_y = 0.5 });
            _ = dvui.label(@src(), "  Sync all player positions", .{}, .{ .id_extra = 120, .color_text = muted_text, .gravity_y = 0.5 });
            { var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal }); spacer.deinit(); }
            const sync_label = if (state.app.seek_sync) "ON" else "OFF";
            if (dvui.button(@src(), sync_label, .{}, .{
                .color_fill = if (state.app.seek_sync) theme.colors.accent else dvui.Color{ .r = 55, .g = 45, .b = 45, .a = 220 },
                .color_text = if (state.app.seek_sync) dvui.Color{ .r = 10, .g = 10, .b = 16, .a = 255 } else dvui.Color{ .r = 160, .g = 100, .b = 100, .a = 255 },
                .padding = .{ .x = 14, .y = 5, .w = 14, .h = 5 },
                .corner_radius = dvui.Rect.all(12),
            })) {
                state.app.seek_sync = !state.app.seek_sync;
            }
        }
        
        // Separator
        { var sep = dvui.box(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .{ .w = 0, .h = 1 }, .background = true, .color_fill = card_border, .margin = .{ .x = 0, .y = 6, .w = 0, .h = 6 } }); sep.deinit(); }
        
        // NSFW Filter toggle
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer row.deinit();
            _ = dvui.label(@src(), "NSFW Filter", .{}, .{ .color_text = label_text, .gravity_y = 0.5 });
            _ = dvui.label(@src(), "  Hide adult content in search", .{}, .{ .id_extra = 130, .color_text = muted_text, .gravity_y = 0.5 });
            { var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal }); spacer.deinit(); }
            const nsfw_label = if (state.app.nsfw_filter_enabled) "ON" else "OFF";
            if (dvui.button(@src(), nsfw_label, .{}, .{
                .color_fill = if (state.app.nsfw_filter_enabled) theme.colors.accent else dvui.Color{ .r = 55, .g = 45, .b = 45, .a = 220 },
                .color_text = if (state.app.nsfw_filter_enabled) dvui.Color{ .r = 10, .g = 10, .b = 16, .a = 255 } else dvui.Color{ .r = 160, .g = 100, .b = 100, .a = 255 },
                .padding = .{ .x = 14, .y = 5, .w = 14, .h = 5 },
                .corner_radius = dvui.Rect.all(12),
            })) {
                state.app.nsfw_filter_enabled = !state.app.nsfw_filter_enabled;
            }
        }
    }
    
    // ── TMDB API Card ──
    sectionHeader("TMDB Integration", "Connect to The Movie Database for rich metadata", 14, @src());
    {
        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = card_bg,
            .color_border = card_border,
            .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(8),
            .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 },
        });
        defer card.deinit();
        
        _ = dvui.label(@src(), "API Key", .{}, .{ .id_extra = 140, .color_text = muted_text, .margin = .{ .x = 0, .y = 0, .w = 0, .h = 4 } });
        var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.tmdb.api_key } }, .{
            .id_extra = 142,
            .expand = .horizontal,
            .min_size_content = .{ .w = 300, .h = 20 },
            .color_fill = dvui.Color{ .r = 15, .g = 15, .b = 22, .a = 255 },
            .color_border = card_border,
            .color_text = label_text,
            .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(6),
        });
        te.deinit();
        state.app.tmdb.api_key_len = std.mem.indexOfScalar(u8, &state.app.tmdb.api_key, 0) orelse 0;
        _ = dvui.label(@src(), "Free key from themoviedb.org/settings/api", .{}, .{
            .id_extra = 143,
            .color_text = dvui.Color{ .r = 80, .g = 140, .b = 200, .a = 200 },
            .margin = .{ .x = 0, .y = 4, .w = 0, .h = 0 },
        });
    }
}

fn renderPlaybackTab() void {
    const btn_active = theme.colors.accent;
    const btn_inactive = dvui.Color{ .r = 35, .g = 35, .b = 48, .a = 255 };
    const btn_text_active = dvui.Color{ .r = 10, .g = 10, .b = 16, .a = 255 };

    // ── Video Processing Card ──
    sectionHeader("Video Processing", "GPU acceleration and image quality", 20, @src());
    {
        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal, .background = true, .color_fill = card_bg,
            .color_border = card_border, .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(8),
            .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
        });
        defer card.deinit();
        
        // HW Decode toggle row
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer row.deinit();
            _ = dvui.label(@src(), "Hardware Decoding", .{}, .{ .color_text = label_text, .gravity_y = 0.5 });
            { var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal }); spacer.deinit(); }
            const hw_l = if (state.app.hwdec_enabled) "ON" else "OFF";
            if (dvui.button(@src(), hw_l, .{}, .{
                .color_fill = if (state.app.hwdec_enabled) btn_active else dvui.Color{ .r = 55, .g = 45, .b = 45, .a = 220 },
                .color_text = if (state.app.hwdec_enabled) btn_text_active else dvui.Color{ .r = 160, .g = 100, .b = 100, .a = 255 },
                .padding = .{ .x = 14, .y = 5, .w = 14, .h = 5 }, .corner_radius = dvui.Rect.all(12),
            })) {
                state.app.hwdec_enabled = !state.app.hwdec_enabled;
                for (state.app.players.items) |p| {
                    _ = c.mpv.mpv_set_option_string(p.mpv_ctx, "hwdec", if (state.app.hwdec_enabled) "auto" else "no");
                }
            }
        }
        { var sep = dvui.box(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .{ .w = 0, .h = 1 }, .background = true, .color_fill = card_border, .margin = .{ .x = 0, .y = 6, .w = 0, .h = 6 } }); sep.deinit(); }
        // Deband toggle row
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer row.deinit();
            _ = dvui.label(@src(), "Deband Filter", .{}, .{ .color_text = label_text, .gravity_y = 0.5 });
            { var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal }); spacer.deinit(); }
            const db_l = if (state.app.deband_enabled) "ON" else "OFF";
            if (dvui.button(@src(), db_l, .{}, .{
                .color_fill = if (state.app.deband_enabled) btn_active else dvui.Color{ .r = 55, .g = 45, .b = 45, .a = 220 },
                .color_text = if (state.app.deband_enabled) btn_text_active else dvui.Color{ .r = 160, .g = 100, .b = 100, .a = 255 },
                .padding = .{ .x = 14, .y = 5, .w = 14, .h = 5 }, .corner_radius = dvui.Rect.all(12),
            })) {
                state.app.deband_enabled = !state.app.deband_enabled;
                for (state.app.players.items) |p| {
                    _ = c.mpv.mpv_set_option_string(p.mpv_ctx, "deband", if (state.app.deband_enabled) "yes" else "no");
                }
            }
        }
        { var sep = dvui.box(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .{ .w = 0, .h = 1 }, .background = true, .color_fill = card_border, .margin = .{ .x = 0, .y = 6, .w = 0, .h = 6 } }); sep.deinit(); }
        // Auto-Advance toggle row
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer row.deinit();
            _ = dvui.label(@src(), "Auto-Advance", .{}, .{ .color_text = label_text, .gravity_y = 0.5 });
            _ = dvui.label(@src(), "  Play next on end", .{}, .{ .id_extra = 260, .color_text = muted_text, .gravity_y = 0.5 });
            { var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal }); spacer.deinit(); }
            const aa_l = if (state.app.auto_advance) "ON" else "OFF";
            if (dvui.button(@src(), aa_l, .{}, .{
                .color_fill = if (state.app.auto_advance) btn_active else dvui.Color{ .r = 55, .g = 45, .b = 45, .a = 220 },
                .color_text = if (state.app.auto_advance) btn_text_active else dvui.Color{ .r = 160, .g = 100, .b = 100, .a = 255 },
                .padding = .{ .x = 14, .y = 5, .w = 14, .h = 5 }, .corner_radius = dvui.Rect.all(12),
            })) {
                state.app.auto_advance = !state.app.auto_advance;
            }
        }
        { var sep = dvui.box(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .{ .w = 0, .h = 1 }, .background = true, .color_fill = card_border, .margin = .{ .x = 0, .y = 6, .w = 0, .h = 6 } }); sep.deinit(); }
        // Scaler selector
        _ = dvui.label(@src(), "Video Scaler", .{}, .{ .id_extra = 250, .color_text = muted_text, .margin = .{ .x = 0, .y = 0, .w = 0, .h = 4 } });
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer row.deinit();
            const sn = [_][]const u8{ "EWA Lanczos (HQ)", "Bilinear (Fast)", "Spline36" };
            const sv = [_][]const u8{ "ewa_lanczossharp", "bilinear", "spline36" };
            for (sn, 0..) |name, idx| {
                const is_a = state.app.video_scaler == @as(u8, @intCast(idx));
                if (dvui.button(@src(), name, .{}, .{
                    .id_extra = idx, .color_fill = if (is_a) btn_active else btn_inactive,
                    .color_text = if (is_a) btn_text_active else muted_text,
                    .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
                    .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 }, .corner_radius = dvui.Rect.all(6),
                })) {
                    state.app.video_scaler = @intCast(idx);
                    for (state.app.players.items) |p| { _ = c.mpv.mpv_set_option_string(p.mpv_ctx, "scale", @ptrCast(sv[idx].ptr)); }
                }
            }
        }
    }
    
    // ── Audio Card ──
    sectionHeader("Audio Equalizer", "Quick presets for different content types", 22, @src());
    {
        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal, .background = true, .color_fill = card_bg,
            .color_border = card_border, .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(8),
            .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
        });
        defer card.deinit();
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        const en = [_][]const u8{ "Flat", "Bass+", "Voice", "Cinema", "Loud" };
        const ec = [_][]const u8{ "af set \"\"", "af set superequalizer=1b=6:2b=5:3b=4:4b=2", "af set superequalizer=3b=3:4b=4:5b=5:6b=4:7b=3", "af set superequalizer=1b=4:2b=3:6b=2:7b=3:8b=4", "af set loudnorm" };
        for (en, 0..) |name, idx| {
            const is_a = state.app.eq_preset == idx;
            if (dvui.button(@src(), name, .{}, .{
                .id_extra = idx, .color_fill = if (is_a) btn_active else btn_inactive,
                .color_text = if (is_a) btn_text_active else muted_text,
                .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
                .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 }, .corner_radius = dvui.Rect.all(6),
            })) {
                state.app.eq_preset = idx;
                for (state.app.players.items) |p| { _ = c.mpv.mpv_command_string(p.mpv_ctx, @ptrCast(ec[idx].ptr)); }
            }
        }
    }
    
    // ── Streaming Card ──
    sectionHeader("Streaming", "yt-dlp backend for web streams", 23, @src());
    {
        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal, .background = true, .color_fill = card_bg,
            .color_border = card_border, .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(8),
            .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
        });
        defer card.deinit();
        _ = dvui.label(@src(), "Stream Quality", .{}, .{ .id_extra = 230, .color_text = muted_text, .margin = .{ .x = 0, .y = 0, .w = 0, .h = 4 } });
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer row.deinit();
            const qn = [_][]const u8{ "720p", "1080p", "4K", "Audio" };
            for (qn, 0..) |name, idx| {
                const is_a = state.app.ytdl_format_idx == idx;
                if (dvui.button(@src(), name, .{}, .{
                    .id_extra = idx, .color_fill = if (is_a) btn_active else btn_inactive,
                    .color_text = if (is_a) btn_text_active else muted_text,
                    .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
                    .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 }, .corner_radius = dvui.Rect.all(6),
                })) {
                    state.app.ytdl_format_idx = idx;
                    for (state.app.players.items) |p| { p.applyYtdlFormat(); }
                }
            }
        }
        { var sep = dvui.box(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .{ .w = 0, .h = 1 }, .background = true, .color_fill = card_border, .margin = .{ .x = 0, .y = 8, .w = 0, .h = 8 } }); sep.deinit(); }
        // yt-dlp status row
        {
            const ytdlp = @import("../services/ytdlp.zig");
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer row.deinit();
            _ = dvui.label(@src(), "yt-dlp", .{}, .{ .color_text = label_text, .gravity_y = 0.5 });
            if (ytdlp.isDownloading()) {
                _ = dvui.label(@src(), "  Downloading...", .{}, .{ .id_extra = 2900, .color_text = theme.colors.accent, .gravity_y = 0.5 });
            } else if (ytdlp.getPath() != null) {
                _ = dvui.label(@src(), "  Installed ✓", .{}, .{ .id_extra = 2900, .color_text = theme.colors.success, .gravity_y = 0.5 });
                { var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal }); spacer.deinit(); }
                if (dvui.button(@src(), "Update", .{}, .{ .id_extra = 2901, .color_fill = btn_inactive, .color_text = theme.colors.accent, .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 }, .corner_radius = dvui.Rect.all(6) })) { ytdlp.update(); }
            } else {
                _ = dvui.label(@src(), "  Not installed", .{}, .{ .id_extra = 2900, .color_text = theme.colors.warning, .gravity_y = 0.5 });
                { var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal }); spacer.deinit(); }
                if (dvui.button(@src(), "Download", .{}, .{ .id_extra = 2902, .color_fill = btn_active, .color_text = btn_text_active, .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 }, .corner_radius = dvui.Rect.all(6) })) { ytdlp.ensureAvailable(); }
            }
        }
    }
    
    // ── Shortcuts Card ──
    sectionHeader("Keyboard Shortcuts", "", 21, @src());
    {
        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal, .background = true, .color_fill = card_bg,
            .color_border = card_border, .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(8),
            .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 },
        });
        defer card.deinit();
        _ = dvui.label(@src(), "Space=Pause  Arrows=Seek  Up/Down=Vol  M=Mute", .{}, .{ .id_extra = 2100, .color_text = muted_text });
        _ = dvui.label(@src(), "+/-=Zoom  0=Reset  Shift+Arrows=Pan", .{}, .{ .id_extra = 2101, .color_text = muted_text });
        _ = dvui.label(@src(), "V=Subs  K=SubDelay  []=Speed  L=Loop  R=Rotate  T=Flip", .{}, .{ .id_extra = 2102, .color_text = muted_text });
        _ = dvui.label(@src(), "A=AI  D=Drawer  Shift+I=Info  Ctrl+O=Open  Ctrl+Q=Quit", .{}, .{ .id_extra = 2103, .color_text = muted_text });
    }

    // ── Video Filters Card ──
    sectionHeader("Video Filters", "Brightness, contrast, saturation, gamma", 24, @src());
    {
        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal, .background = true, .color_fill = card_bg,
            .color_border = card_border, .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(8),
            .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 },
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
        });
        defer card.deinit();

        // Each filter: label + step buttons
        const filters = [_]struct { name: []const u8, prop: []const u8, idx: usize }{
            .{ .name = "Brightness", .prop = "brightness", .idx = 0 },
            .{ .name = "Contrast", .prop = "contrast", .idx = 1 },
            .{ .name = "Saturation", .prop = "saturation", .idx = 2 },
            .{ .name = "Gamma", .prop = "gamma", .idx = 3 },
        };

        for (filters) |f| {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = f.idx + 3000, .expand = .horizontal,
                .padding = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
            });
            defer row.deinit();

            _ = dvui.label(@src(), "{s}", .{f.name}, .{
                .id_extra = f.idx + 3010, .color_text = label_text,
                .min_size_content = .{ .w = 90, .h = 0 }, .gravity_y = 0.5,
            });

            // "−" button
            if (dvui.button(@src(), "−", .{}, .{
                .id_extra = f.idx + 3020,
                .color_fill = btn_inactive, .color_text = muted_text,
                .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
                .corner_radius = dvui.Rect.all(4),
                .margin = .{ .x = 4, .y = 0, .w = 2, .h = 0 },
            })) {
                var cmd_buf: [64]u8 = undefined;
                if (std.fmt.bufPrintZ(&cmd_buf, "add {s} -5", .{f.prop})) |cmd| {
                    if (state.app.active_player_idx < state.app.players.items.len) {
                        _ = c.mpv.mpv_command_string(state.app.players.items[state.app.active_player_idx].mpv_ctx, cmd.ptr);
                    }
                } else |_| {}
            }

            // Current value
            {
                var val: i64 = 0;
                if (state.app.active_player_idx < state.app.players.items.len) {
                    _ = c.mpv.mpv_get_property(state.app.players.items[state.app.active_player_idx].mpv_ctx, @ptrCast(f.prop.ptr), c.mpv.MPV_FORMAT_INT64, &val);
                }
                var val_buf: [12]u8 = undefined;
                const val_str = std.fmt.bufPrintZ(&val_buf, "{d}", .{val}) catch "0";
                _ = dvui.label(@src(), "{s}", .{val_str}, .{
                    .id_extra = f.idx + 3030, .color_text = theme.colors.text_main,
                    .min_size_content = .{ .w = 30, .h = 0 }, .gravity_x = 0.5, .gravity_y = 0.5,
                });
            }

            // "+" button
            if (dvui.button(@src(), "+", .{}, .{
                .id_extra = f.idx + 3040,
                .color_fill = btn_inactive, .color_text = muted_text,
                .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
                .corner_radius = dvui.Rect.all(4),
                .margin = .{ .x = 2, .y = 0, .w = 0, .h = 0 },
            })) {
                var cmd_buf: [64]u8 = undefined;
                if (std.fmt.bufPrintZ(&cmd_buf, "add {s} 5", .{f.prop})) |cmd| {
                    if (state.app.active_player_idx < state.app.players.items.len) {
                        _ = c.mpv.mpv_command_string(state.app.players.items[state.app.active_player_idx].mpv_ctx, cmd.ptr);
                    }
                } else |_| {}
            }
        }

        // Reset all button
        {
            var sep = dvui.box(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .{ .w = 0, .h = 1 }, .background = true, .color_fill = card_border, .margin = .{ .x = 0, .y = 6, .w = 0, .h = 6 } }); sep.deinit();
        }
        if (dvui.button(@src(), "Reset All Filters", .{}, .{
            .id_extra = 3099,
            .color_fill = dvui.Color{ .r = 60, .g = 35, .b = 35, .a = 220 },
            .color_text = theme.colors.danger,
            .padding = .{ .x = 12, .y = 5, .w = 12, .h = 5 },
            .corner_radius = dvui.Rect.all(6),
        })) {
            if (state.app.active_player_idx < state.app.players.items.len) {
                const p = state.app.players.items[state.app.active_player_idx];
                _ = c.mpv.mpv_command_string(p.mpv_ctx, "set brightness 0");
                _ = c.mpv.mpv_command_string(p.mpv_ctx, "set contrast 0");
                _ = c.mpv.mpv_command_string(p.mpv_ctx, "set saturation 0");
                _ = c.mpv.mpv_command_string(p.mpv_ctx, "set gamma 0");
            }
        }
    }

    // ── Clip Export Card ──
    sectionHeader("Capture", "Screenshot and clip export", 25, @src());
    {
        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal, .background = true, .color_fill = card_bg,
            .color_border = card_border, .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(8),
            .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 },
        });
        defer card.deinit();

        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();

        // Screenshot button
        if (dvui.button(@src(), "Screenshot (P)", .{}, .{
            .id_extra = 3200,
            .color_fill = btn_active, .color_text = btn_text_active,
            .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
            .corner_radius = dvui.Rect.all(6),
            .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
        })) {
            if (state.app.active_player_idx < state.app.players.items.len) {
                _ = c.mpv.mpv_command_string(state.app.players.items[state.app.active_player_idx].mpv_ctx, "screenshot");
                state.showToast("Screenshot saved");
            }
        }

        // Screenshot without subs
        if (dvui.button(@src(), "Screenshot (no subs)", .{}, .{
            .id_extra = 3201,
            .color_fill = btn_inactive, .color_text = muted_text,
            .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
            .corner_radius = dvui.Rect.all(6),
            .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
        })) {
            if (state.app.active_player_idx < state.app.players.items.len) {
                _ = c.mpv.mpv_command_string(state.app.players.items[state.app.active_player_idx].mpv_ctx, "screenshot video");
                state.showToast("Screenshot (video-only) saved");
            }
        }

        // Clip export hint
        if (dvui.button(@src(), "Clip (L -> set loop)", .{}, .{
            .id_extra = 3202,
            .color_fill = btn_inactive, .color_text = muted_text,
            .padding = .{ .x = 12, .y = 6, .w = 12, .h = 6 },
            .corner_radius = dvui.Rect.all(6),
        })) {
            state.showToast("Press L to set A-B loop, then export");
        }
    }
}

fn renderNetworkTab() void {
    // Download Speed Limit
    settingRow("Download Speed Limit", 30, @src());
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 24 },
        });
        defer row.deinit();
        
        const limits = [_]i32{ 0, 1*1024*1024, 2*1024*1024, 5*1024*1024, 10*1024*1024, 20*1024*1024 };
        const limit_names = [_][]const u8{ "No Limit", "1 MB/s", "2 MB/s", "5 MB/s", "10 MB/s", "20 MB/s" };
        
        for (limits, 0..) |l, idx| {
            const is_active = state.app.download_rate_limit == l;
            if (dvui.button(@src(), limit_names[idx], .{}, .{
                .id_extra = idx,
                .color_fill = if (is_active) theme.colors.accent_hover else dvui.Color{ .r=0, .g=0, .b=0, .a=0 },
                .color_text = if (is_active) theme.colors.bg_header else theme.colors.text_muted,
                .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
                .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
            })) {
                state.app.download_rate_limit = l;
                c.mpv.torrent_set_download_limit(state.app.torrent_ses, l);
            }
        }
    }
    
    // Tracker info
    settingRow("Custom Trackers", 31, @src());
    _ = dvui.label(@src(), "8 public trackers auto-added to every torrent", .{}, .{
        .color_text = theme.colors.text_muted,
    });
    _ = dvui.label(@src(), "opentrackr, stealth, torrent.eu, dler, exodus, demonii...", .{}, .{
        .color_text = theme.colors.text_muted,
    });
    
    // Proxy URL
    settingRow("Proxy (yt-dlp)", 32, @src());
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 24 },
        });
        defer row.deinit();
        
        var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.proxy_url } }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 250, .h = 20 },
            .color_fill = theme.colors.bg_input,
            .color_border = theme.colors.border_input,
            .color_text = theme.colors.text_main,
            .border = dvui.Rect.all(1),
            .corner_radius = theme.dims.rad_sm,
        });
        te.deinit();
        
        // Update proxy_url_len from null-terminated buffer
        state.app.proxy_url_len = std.mem.indexOfScalar(u8, &state.app.proxy_url, 0) orelse 0;
    }
    _ = dvui.label(@src(), "e.g. socks5://127.0.0.1:1080 — used for yt-dlp and playlist extraction", .{}, .{
        .color_text = theme.colors.text_muted,
    });
}

fn renderSubtitlesTab() void {
    // ── OpenSubtitles API Key ──
    settingRow("OpenSubtitles API Key", 42, @src());
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 24 },
        });
        defer row.deinit();

        var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.opensub_api_key }, .placeholder = "Paste API key from opensubtitles.com" }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 250, .h = 20 },
            .color_fill = theme.colors.bg_input,
            .color_border = theme.colors.border_input,
            .color_text = theme.colors.text_main,
            .border = dvui.Rect.all(1),
            .corner_radius = theme.dims.rad_sm,
        });
        te.deinit();
        state.app.opensub_api_key_len = std.mem.indexOfScalar(u8, &state.app.opensub_api_key, 0) orelse 0;
    }
    _ = dvui.label(@src(), "Get free key: opensubtitles.com → Profile → API Consumers", .{}, .{
        .id_extra = 4200,
        .color_text = theme.colors.text_muted,
        .margin = .{ .x = 0, .y = 2, .w = 0, .h = 8 },
    });

    // ── Subtitle Language ──
    settingRow("Search Language", 40, @src());
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 24 },
        });
        defer row.deinit();
        
        const langs = [_][]const u8{ "eng", "spa", "fre", "ger", "por", "ita", "rus", "chi", "jpn", "kor", "hin", "ara", "tur" };
        const lang_names = [_][]const u8{ "EN", "ES", "FR", "DE", "PT", "IT", "RU", "ZH", "JA", "KO", "HI", "AR", "TR" };
        const current = state.app.sub_lang_buf[0..state.app.sub_lang_len];
        
        for (langs, 0..) |l, idx| {
            const is_active = std.mem.eql(u8, current, l);
            if (dvui.button(@src(), lang_names[idx], .{}, .{
                .id_extra = idx,
                .color_fill = if (is_active) theme.colors.accent_hover else dvui.Color{ .r=0, .g=0, .b=0, .a=0 },
                .color_text = if (is_active) theme.colors.bg_header else theme.colors.text_muted,
                .margin = .{ .x = 0, .y = 0, .w = 3, .h = 0 },
                .padding = .{ .x = 6, .y = 4, .w = 6, .h = 4 },
            })) {
                @memcpy(state.app.sub_lang_buf[0..l.len], l);
                state.app.sub_lang_len = l.len;
            }
        }
    }

    // ── Search Subtitles ──
    settingRow("Search Subtitles", 43, @src());
    {
        const subs = @import("../services/subtitles.zig");

        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 24 },
        });
        defer row.deinit();

        var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.sub_search_buf }, .placeholder = "Movie/show name..." }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 200, .h = 20 },
            .color_fill = theme.colors.bg_input,
            .color_border = theme.colors.border_input,
            .color_text = theme.colors.text_main,
            .border = dvui.Rect.all(1),
            .corner_radius = theme.dims.rad_sm,
        });
        const enter = te.enter_pressed;
        te.deinit();

        // Search button
        const search_clicked = dvui.button(@src(), if (subs.is_searching) "..." else "Search", .{}, .{
            .id_extra = 4301,
            .color_fill = theme.colors.accent_hover,
            .color_text = theme.colors.bg_header,
            .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
            .margin = .{ .x = 4, .y = 0, .w = 2, .h = 0 },
            .corner_radius = dvui.Rect.all(6),
        });

        // Auto-detect from player
        if (dvui.button(@src(), "Auto", .{}, .{
            .id_extra = 4302,
            .color_fill = dvui.Color{ .r=0, .g=0, .b=0, .a=0 },
            .color_text = theme.colors.accent,
            .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
            .margin = .{ .x = 2, .y = 0, .w = 0, .h = 0 },
            .corner_radius = dvui.Rect.all(6),
        })) {
            subs.autoSearchFromPlayer();
        }

        if ((search_clicked or enter) and !subs.is_searching) {
            const q_len = std.mem.indexOfScalar(u8, &state.app.sub_search_buf, 0) orelse 0;
            if (q_len > 0) {
                const lang = if (state.app.sub_lang_len > 0) state.app.sub_lang_buf[0..state.app.sub_lang_len] else "en";
                subs.searchByQuery(state.app.sub_search_buf[0..q_len], lang);
            }
        }
    }

    // ── Results ──
    {
        const subs = @import("../services/subtitles.zig");

        if (subs.search_error_len > 0) {
            _ = dvui.label(@src(), "{s}", .{subs.search_error[0..subs.search_error_len]}, .{
                .id_extra = 4400,
                .color_text = theme.colors.warning,
                .margin = .{ .x = 0, .y = 4, .w = 0, .h = 4 },
            });
        }

        if (subs.is_searching) {
            _ = dvui.label(@src(), "Searching...", .{}, .{
                .id_extra = 4401,
                .color_text = theme.colors.accent,
                .margin = .{ .x = 0, .y = 4, .w = 0, .h = 4 },
            });
        }

        if (subs.result_count > 0) {
            var count_buf: [32]u8 = undefined;
            const count_str = std.fmt.bufPrintZ(&count_buf, "{d} results", .{subs.result_count}) catch "results";
            _ = dvui.label(@src(), "{s}", .{count_str}, .{
                .id_extra = 4402,
                .color_text = theme.colors.text_muted,
                .margin = .{ .x = 0, .y = 6, .w = 0, .h = 2 },
            });

            for (0..subs.result_count) |ri| {
                const r = &subs.results[ri];
                var res_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = ri + 4500,
                    .expand = .horizontal,
                    .background = true,
                    .color_fill = theme.colors.bg_card,
                    .color_border = theme.colors.divider,
                    .border = dvui.Rect.all(1),
                    .corner_radius = dvui.Rect.all(6),
                    .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 },
                    .margin = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
                });
                defer res_row.deinit();

                // Language badge
                if (r.lang_len > 0) {
                    _ = dvui.label(@src(), "{s}", .{r.language[0..r.lang_len]}, .{
                        .id_extra = ri + 4600,
                        .color_text = theme.colors.accent,
                        .gravity_y = 0.5,
                        .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
                    });
                }

                // Release name (truncated)
                if (r.release_len > 0) {
                    const show_len = @min(r.release_len, 60);
                    _ = dvui.label(@src(), "{s}", .{r.release[0..show_len]}, .{
                        .id_extra = ri + 4700,
                        .color_text = theme.colors.text_main,
                        .gravity_y = 0.5,
                    });
                }

                { var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal }); sp.deinit(); }

                // Download count
                if (r.download_count > 0) {
                    var dc_buf: [16]u8 = undefined;
                    const dc_str = std.fmt.bufPrintZ(&dc_buf, "↓{d}", .{r.download_count}) catch "";
                    _ = dvui.label(@src(), "{s}", .{dc_str}, .{
                        .id_extra = ri + 4800,
                        .color_text = theme.colors.text_dim,
                        .gravity_y = 0.5,
                        .margin = .{ .x = 6, .y = 0, .w = 4, .h = 0 },
                    });
                }

                // HI badge
                if (r.hearing_impaired) {
                    _ = dvui.label(@src(), "CC", .{}, .{
                        .id_extra = ri + 4900,
                        .color_text = theme.colors.warning,
                        .gravity_y = 0.5,
                        .margin = .{ .x = 2, .y = 0, .w = 4, .h = 0 },
                    });
                }

                // Download button
                if (dvui.button(@src(), if (subs.is_downloading) "..." else "⬇", .{}, .{
                    .id_extra = ri + 5000,
                    .color_fill = theme.colors.accent_hover,
                    .color_text = theme.colors.bg_header,
                    .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
                    .corner_radius = dvui.Rect.all(4),
                    .gravity_y = 0.5,
                })) {
                    if (!subs.is_downloading and r.file_id > 0) {
                        subs.downloadSubtitle(r.file_id);
                    }
                }
            }
        }
    }

    // ── Auto-download status ──
    settingRow("Auto-Download Status", 41, @src());
    {
        const sub_state = state.app.sub_engine.state;
        const subtitles_engine = @import("../player/subtitles.zig");
        const status_text = switch (sub_state) {
            subtitles_engine.SubState.idle => "Idle",
            subtitles_engine.SubState.searching => "Searching...",
            subtitles_engine.SubState.found => "Found subtitles",
            subtitles_engine.SubState.downloading => "Downloading...",
            subtitles_engine.SubState.ready => "Loaded",
            subtitles_engine.SubState.failed => "Not found",
        };
        _ = dvui.label(@src(), "{s}", .{status_text}, .{
            .color_text = theme.colors.text_muted,
        });
    }
    
    _ = dvui.label(@src(), "Shift+J = Search subs for current video | J = Cycle tracks", .{}, .{
        .id_extra = 4201,
        .color_text = theme.colors.text_muted,
        .margin = .{ .x = 0, .y = 8, .w = 0, .h = 0 },
    });
}

fn renderStorageTab() void {
    // Download Path
    settingRow("Download Path", 50, @src());
    {
        const path = state.app.save_path_buf[0..state.app.save_path_len];
        _ = dvui.label(@src(), "{s}", .{path}, .{
            .color_text = theme.colors.text_main,
            .margin = .{ .x = 0, .y = 2, .w = 0, .h = 4 },
        });
        
        // Path presets
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 24 },
        });
        defer row.deinit();
        
        // Path presets (resolved at runtime)
        var dl_path_buf: [256]u8 = undefined;
        var vid_path_buf: [256]u8 = undefined;
        const dl_path = paths.defaultSavePath(&dl_path_buf);
        const vid_path = paths.videosSavePath(&vid_path_buf);
        const preset_paths = [_][]const u8{ dl_path, vid_path, "/tmp/zigzag_torrents" };
        const path_names = [_][]const u8{ "~/Downloads (default)", "~/Videos", "/tmp (tmpfs)" };
        
        for (preset_paths, 0..) |p, idx| {
            const is_active = std.mem.eql(u8, path, p);
            if (dvui.button(@src(), path_names[idx], .{}, .{
                .id_extra = idx,
                .color_fill = if (is_active) theme.colors.accent_hover else dvui.Color{ .r=0, .g=0, .b=0, .a=0 },
                .color_text = if (is_active) theme.colors.bg_header else theme.colors.text_muted,
                .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
                .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
            })) {
                @memcpy(state.app.save_path_buf[0..p.len], p);
                state.app.save_path_len = p.len;
                // Create dir if it doesn't exist
                @import("../core/io_global.zig").cwdMakePath(p) catch {};
            }
        }
    }
    // Watch History Stats
    settingRow("Watch History", 51, @src());
    {
        const watch = @import("../player/watch_history.zig");
        var count_buf: [48]u8 = undefined;
        const count_str = std.fmt.bufPrintZ(&count_buf, "{d} entries saved", .{watch.getCount()}) catch "?";
        _ = dvui.label(@src(), "{s}", .{count_str}, .{
            .color_text = theme.colors.text_muted,
        });
        
        if (dvui.button(@src(), "Clear Watch History", .{}, .{
            .color_fill = dvui.Color{ .r=80, .g=30, .b=30, .a=200 },
            .color_text = theme.colors.danger,
            .padding = .{ .x = 12, .y = 4, .w = 12, .h = 4 },
        })) {
            watch.clearAll();
            state.showToast("Watch history cleared");
        }
    }

    // Database info
    settingRow("Database", 52, @src());
    _ = dvui.label(@src(), "SQLite: ~/.config/zigzag/zigzag.db", .{}, .{
        .color_text = theme.colors.text_muted,
    });
}

fn renderLangLearnTab() void {
    settingRow("Language Learning Mode", 60, @src());
    {
        const label = if (state.app.lang_learn_enabled) "[ON] Enabled" else "[OFF] Disabled";
        if (dvui.button(@src(), label, .{}, .{
            .color_fill = if (state.app.lang_learn_enabled) theme.colors.accent_hover else dvui.Color{ .r=60, .g=56, .b=54, .a=200 },
            .color_text = if (state.app.lang_learn_enabled) theme.colors.bg_header else theme.colors.text_muted,
            .padding = .{ .x = 12, .y = 4, .w = 12, .h = 4 },
        })) {
            state.app.lang_learn_enabled = !state.app.lang_learn_enabled;
            const lang_learn = @import("../services/lang_learn.zig");
            lang_learn.onToggle(state.app.lang_learn_enabled);
        }
    }

    // Translation Target Language
    settingRow("Translate To", 64, @src());
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 24 },
        });
        defer row.deinit();
        
        const lang_codes = [_][]const u8{ "en", "es", "fr", "de", "it", "pt", "ru", "ja", "ko", "zh-CN", "ar", "hi", "tr", "vi" };
        const lang_labels = [_][]const u8{ "EN", "ES", "FR", "DE", "IT", "PT", "RU", "JA", "KO", "ZH", "AR", "HI", "TR", "VI" };
        const current_tl = state.app.translate_lang_buf[0..state.app.translate_lang_len];
        
        for (lang_codes, 0..) |code, idx| {
            const is_active = std.mem.eql(u8, current_tl, code);
            if (dvui.button(@src(), lang_labels[idx], .{}, .{
                .id_extra = idx + 200,
                .color_fill = if (is_active) theme.colors.accent_hover else dvui.Color{ .r=0, .g=0, .b=0, .a=0 },
                .color_text = if (is_active) theme.colors.bg_header else theme.colors.text_muted,
                .margin = .{ .x = 0, .y = 0, .w = 2, .h = 0 },
                .padding = .{ .x = 5, .y = 3, .w = 5, .h = 3 },
            })) {
                @memcpy(state.app.translate_lang_buf[0..code.len], code);
                state.app.translate_lang_len = code.len;
            }
        }
    }

    // Translation toggle
    settingRow("Translation", 66, @src());
    {
        const label = if (state.app.translate_enabled) "[ON] Enabled" else "[OFF] Disabled";
        if (dvui.button(@src(), label, .{}, .{
            .color_fill = if (state.app.translate_enabled) theme.colors.accent_hover else dvui.Color{ .r=60, .g=56, .b=54, .a=200 },
            .color_text = if (state.app.translate_enabled) theme.colors.bg_header else theme.colors.text_muted,
            .padding = .{ .x = 12, .y = 4, .w = 12, .h = 4 },
        })) {
            state.app.translate_enabled = !state.app.translate_enabled;
        }
    }

    // Subtitle Track Selector
    settingRow("Active Subtitle Track", 65, @src());
    {
        if (state.app.active_player_idx < state.app.players.items.len) {
            const p = state.app.players.items[state.app.active_player_idx];
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .min_size_content = .{ .w = 0, .h = 24 },
            });
            defer row.deinit();

            const track_labels = [_][]const u8{ "None", "Track 1", "Track 2", "Track 3", "Track 4", "Track 5" };
            for (track_labels, 0..) |tl, idx| {
                if (dvui.button(@src(), tl, .{}, .{
                    .id_extra = idx + 300,
                    .color_fill = dvui.Color{ .r=0, .g=0, .b=0, .a=0 },
                    .color_text = theme.colors.text_muted,
                    .margin = .{ .x = 0, .y = 0, .w = 3, .h = 0 },
                    .padding = .{ .x = 6, .y = 3, .w = 6, .h = 3 },
                })) {
                    var cmd_buf: [64]u8 = undefined;
                    if (idx == 0) {
                        _ = c.mpv.mpv_command_string(p.mpv_ctx, "set sid no");
                    } else {
                        if (std.fmt.bufPrintZ(&cmd_buf, "set sid {d}", .{idx})) |cmd| {
                            _ = c.mpv.mpv_command_string(p.mpv_ctx, cmd.ptr);
                        } else |_| {}
                    }
                }
            }
        } else {
            _ = dvui.label(@src(), "No active player", .{}, .{ .color_text = theme.colors.text_muted });
        }
    }

    // ASR Toggle
    settingRow("Speech Recognition (ASR)", 67, @src());
    {
        const label = if (state.app.asr_enabled) "[ON] Enabled" else "[OFF] Disabled";
        if (dvui.button(@src(), label, .{}, .{
            .color_fill = if (state.app.asr_enabled) theme.colors.accent_hover else dvui.Color{ .r=60, .g=56, .b=54, .a=200 },
            .color_text = if (state.app.asr_enabled) theme.colors.bg_header else theme.colors.text_muted,
            .padding = .{ .x = 12, .y = 4, .w = 12, .h = 4 },
        })) {
            state.app.asr_enabled = !state.app.asr_enabled;
        }
    }
    _ = dvui.label(@src(), "Auto-transcribe audio when no subtitles available (Cohere 2B)", .{}, .{
        .id_extra = 9001,
        .color_text = theme.colors.text_muted,
    });

    // Dubbing Toggle
    settingRow("Audio Dubbing", 68, @src());
    {
        const label = if (state.app.dubbing_enabled) "[ON] Enabled" else "[OFF] Disabled";
        if (dvui.button(@src(), label, .{}, .{
            .color_fill = if (state.app.dubbing_enabled) dvui.Color{ .r=180, .g=120, .b=40, .a=230 } else dvui.Color{ .r=60, .g=56, .b=54, .a=200 },
            .color_text = if (state.app.dubbing_enabled) theme.colors.bg_header else theme.colors.text_muted,
            .padding = .{ .x = 12, .y = 4, .w = 12, .h = 4 },
        })) {
            state.app.dubbing_enabled = !state.app.dubbing_enabled;
            if (state.app.dubbing_enabled) state.app.dub_last_hash = 0;
        }
    }
    _ = dvui.label(@src(), "Translate subtitles and speak via TTS (lowers video volume)", .{}, .{
        .id_extra = 9002,
        .color_text = theme.colors.text_muted,
    });

    // Voice Selector
    settingRow("TTS Voice", 61, @src());
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 24 },
        });
        defer row.deinit();
        
        const voices = [_][]const u8{ "Bella", "Jasper", "Luna", "Bruno", "Rosie", "Hugo", "Kiki", "Leo" };
        for (voices, 0..) |voice, idx| {
            const current = state.app.tts_voice_buf[0..state.app.tts_voice_len];
            const is_active = std.mem.eql(u8, current, voice);
            if (dvui.button(@src(), voice, .{}, .{
                .id_extra = idx,
                .color_fill = if (is_active) theme.colors.accent_hover else dvui.Color{ .r=0, .g=0, .b=0, .a=0 },
                .color_text = if (is_active) theme.colors.bg_header else theme.colors.text_muted,
                .margin = .{ .x = 0, .y = 0, .w = 3, .h = 0 },
                .padding = .{ .x = 6, .y = 3, .w = 6, .h = 3 },
            })) {
                @memcpy(state.app.tts_voice_buf[0..voice.len], voice);
                state.app.tts_voice_len = voice.len;
            }
        }
    }

    // Speed Control
    settingRow("Speech Speed", 62, @src());
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 24 },
        });
        defer row.deinit();
        
        const speeds = [_]f32{ 0.5, 0.75, 1.0, 1.25, 1.5 };
        const speed_labels = [_][]const u8{ "0.5x", "0.75x", "1.0x", "1.25x", "1.5x" };
        for (speeds, 0..) |spd, idx| {
            const is_active = @abs(state.app.tts_speed - spd) < 0.05;
            if (dvui.button(@src(), speed_labels[idx], .{}, .{
                .id_extra = idx,
                .color_fill = if (is_active) theme.colors.accent_hover else dvui.Color{ .r=0, .g=0, .b=0, .a=0 },
                .color_text = if (is_active) theme.colors.bg_header else theme.colors.text_muted,
                .margin = .{ .x = 0, .y = 0, .w = 3, .h = 0 },
                .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 },
            })) {
                state.app.tts_speed = spd;
            }
        }
    }

    // Server Status
    settingRow("TTS Server", 63, @src());
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .gravity_y = 0.5,
        });
        defer row.deinit();
        
        if (state.app.tts_server_ok) {
            _ = dvui.label(@src(), "[OK] Running", .{}, .{ .color_text = theme.colors.success });
        } else {
            _ = dvui.label(@src(), "[--] Not running", .{}, .{ .color_text = theme.colors.text_muted });
        }
        
        { var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal }); spacer.deinit(); }
        
        const lang_learn = @import("../services/lang_learn.zig");
        if (!state.app.tts_server_ok) {
            if (dvui.button(@src(), "Start Server", .{}, .{
                .color_fill = theme.colors.accent_hover,
                .color_text = theme.colors.bg_header,
                .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
            })) {
                lang_learn.startServer();
            }
        } else {
            if (dvui.button(@src(), "Stop Server", .{}, .{
                .color_fill = dvui.Color{ .r=60, .g=30, .b=30, .a=200 },
                .color_text = theme.colors.danger,
                .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
            })) {
                lang_learn.stopServer();
            }
        }
    }
    _ = dvui.label(@src(), "KittenTTS (80MB) | Cohere ASR (2B) | Google Translate", .{}, .{
        .color_text = theme.colors.text_muted,
    });
}

fn renderScriptsTab() void {
    const scripts = @import("../services/scripts.zig");

    // Trigger scan on first open
    if (!state.app.scripts_scanned) {
        scripts.scanScripts();
    }

    // ── SponsorBlock Master Toggle ──
    settingRow("SponsorBlock (YouTube)", 70, @src());
    {
        const label = if (state.app.sponsorblock_enabled) "[ON] Skipping Sponsors" else "[OFF] Disabled";
        if (dvui.button(@src(), label, .{}, .{
            .color_fill = if (state.app.sponsorblock_enabled) theme.colors.accent_hover else dvui.Color{ .r = 60, .g = 56, .b = 54, .a = 200 },
            .color_text = if (state.app.sponsorblock_enabled) theme.colors.bg_header else theme.colors.text_muted,
            .padding = .{ .x = 12, .y = 4, .w = 12, .h = 4 },
        })) {
            state.app.sponsorblock_enabled = !state.app.sponsorblock_enabled;
        }
    }

    // ── Web Remote Control ──
    settingRow("Web Remote Control", 72, @src());
    {
        const remote = @import("../services/remote.zig");
        const label = if (state.app.web_remote_enabled) "[ON] http://0.0.0.0:41595" else "[OFF] Disabled";
        if (dvui.button(@src(), label, .{}, .{
            .color_fill = if (state.app.web_remote_enabled) theme.colors.accent_hover else dvui.Color{ .r = 60, .g = 56, .b = 54, .a = 200 },
            .color_text = if (state.app.web_remote_enabled) theme.colors.bg_header else theme.colors.text_muted,
            .padding = .{ .x = 12, .y = 4, .w = 12, .h = 4 },
        })) {
            state.app.web_remote_enabled = !state.app.web_remote_enabled;
            if (state.app.web_remote_enabled) {
                remote.start();
                state.showToast("Web Remote started on :41595");
            } else {
                remote.stop();
                state.showToast("Web Remote stopped");
            }
        }
    }

    // ── Watch Party ──
    settingRow("Watch Party (LAN Sync)", 73, @src());
    {
        const party = @import("../services/watch_party.zig");
        var status_buf: [64]u8 = undefined;
        const status = party.statusText(&status_buf);
        _ = dvui.label(@src(), "{s}", .{status}, .{
            .color_text = switch (party.role) {
                .none => theme.colors.text_muted,
                .host => theme.colors.accent,
                .client => theme.colors.text_main,
            },
            .margin = .{ .x = 0, .y = 2, .w = 0, .h = 4 },
        });

        var row_layout = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = 2, .w = 0, .h = 6 },
        });

        if (party.role == .none) {
            // Host button
            if (dvui.button(@src(), "Host Party", .{}, .{
                .color_fill = theme.colors.accent_hover,
                .color_text = theme.colors.bg_header,
                .padding = .{ .x = 12, .y = 4, .w = 12, .h = 4 },
                .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
            })) {
                party.hostParty();
            }

            // Join input + button
            _ = dvui.label(@src(), "Join:", .{}, .{
                .color_text = theme.colors.text_muted,
                .padding = .{ .x = 6, .y = 4, .w = 2, .h = 4 },
            });
            var host_ip_input = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.party_host_ip_buf } }, .{
                .expand = .horizontal,
                .min_size_content = .{ .w = 120, .h = 20 },
                .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
                .color_fill = dvui.Color{ .r = 15, .g = 15, .b = 22, .a = 255 },
                .border = dvui.Rect.all(1),
                .corner_radius = dvui.Rect.all(6),
            });
            const ip_enter = host_ip_input.enter_pressed;
            host_ip_input.deinit();
            const ip_len = std.mem.indexOfScalar(u8, &state.app.party_host_ip_buf, 0) orelse 0;
            if (ip_len > 0) {
                const clicked_join = dvui.button(@src(), "Join", .{}, .{
                    .color_fill = dvui.Color{ .r = 80, .g = 160, .b = 80, .a = 255 },
                    .color_text = theme.colors.bg_header,
                    .padding = .{ .x = 12, .y = 4, .w = 12, .h = 4 },
                    .margin = .{ .x = 6, .y = 0, .w = 0, .h = 0 },
                });
                if (clicked_join or ip_enter) {
                    party.joinParty(state.app.party_host_ip_buf[0..ip_len]);
                }
            }
        } else {
            // Leave button
            if (dvui.button(@src(), "Leave Party", .{}, .{
                .color_fill = dvui.Color{ .r = 180, .g = 60, .b = 60, .a = 255 },
                .color_text = theme.colors.text_main,
                .padding = .{ .x = 12, .y = 4, .w = 12, .h = 4 },
            })) {
                party.leaveParty();
            }
        }
        row_layout.deinit();

        // ── Chat ──
        if (party.role != .none) {
            { var sep = dvui.box(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .{ .w = 0, .h = 1 }, .background = true, .color_fill = card_border, .margin = .{ .x = 0, .y = 6, .w = 0, .h = 6 } }); sep.deinit(); }

            _ = dvui.label(@src(), "Chat", .{}, .{
                .id_extra = 7400, .color_text = label_text,
                .margin = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
            });

            // Chat messages (last 8)
            {
                var chat_box = dvui.box(@src(), .{ .dir = .vertical }, .{
                    .id_extra = 7500, .expand = .horizontal,
                    .background = true,
                    .color_fill = dvui.Color{ .r = 12, .g = 12, .b = 18, .a = 255 },
                    .corner_radius = dvui.Rect.all(4),
                    .padding = .{ .x = 6, .y = 4, .w = 6, .h = 4 },
                    .min_size_content = .{ .w = 0, .h = 80 },
                    .max_size_content = .{ .w = std.math.floatMax(f32), .h = 100 },
                });
                defer chat_box.deinit();

                const start = if (party.chat_count > 8) party.chat_count - 8 else 0;
                for (start..party.chat_count) |ci| {
                    const msg = party.chat_msgs[ci][0..party.chat_msg_lens[ci]];
                    const is_sys = msg.len > 2 and msg[0] == '>' and msg[1] == '>';
                    _ = dvui.label(@src(), "{s}", .{msg}, .{
                        .id_extra = ci + 7600,
                        .color_text = if (is_sys) theme.colors.text_muted else theme.colors.text_main,
                    });
                }
            }

            // Input row
            {
                var chat_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = 7700, .expand = .horizontal,
                    .margin = .{ .x = 0, .y = 4, .w = 0, .h = 0 },
                });
                defer chat_row.deinit();

                var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &party.chat_input } }, .{
                    .expand = .horizontal,
                    .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
                    .color_fill = dvui.Color{ .r = 15, .g = 15, .b = 22, .a = 255 },
                    .border = dvui.Rect.all(1),
                    .corner_radius = dvui.Rect.all(4),
                });
                const chat_enter = te.enter_pressed;
                te.deinit();

                const clicked_send = dvui.button(@src(), "Send", .{}, .{
                    .id_extra = 7710,
                    .color_fill = theme.colors.accent,
                    .color_text = dvui.Color.white,
                    .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
                    .margin = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
                    .corner_radius = dvui.Rect.all(4),
                });
                if (clicked_send or chat_enter) {
                    party.sendChat();
                }
            }

            // Sync URL button (host only)
            if (party.role == .host) {
                if (dvui.button(@src(), "Sync Current Video to All", .{}, .{
                    .id_extra = 7720,
                    .color_fill = dvui.Color{ .r = 40, .g = 120, .b = 180, .a = 255 },
                    .color_text = dvui.Color.white,
                    .padding = .{ .x = 12, .y = 5, .w = 12, .h = 5 },
                    .margin = .{ .x = 0, .y = 6, .w = 0, .h = 0 },
                    .corner_radius = dvui.Rect.all(6),
                })) {
                    if (state.app.active_player_idx < state.app.players.items.len) {
                        const p = state.app.players.items[state.app.active_player_idx];
                        if (p.current_url_len > 0) {
                            party.broadcastLoad(p.current_url[0..p.current_url_len]);
                        }
                    }
                }
            }
        }
    }

    // ── Installed Scripts ──
    settingRow("Installed Scripts", 71, @src());

    if (state.app.script_count == 0) {
        _ = dvui.label(@src(), "No scripts found in ~/.config/mpv/scripts/ or ~/.config/zigzag/scripts/", .{}, .{
            .color_text = theme.colors.text_muted,
            .margin = .{ .x = 0, .y = 4, .w = 0, .h = 8 },
        });
    } else {
        var scroll = dvui.scrollArea(@src(), .{}, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 120 },
            .max_size_content = .{ .w = 0, .h = 180 },
        });
        defer scroll.deinit();

        for (0..state.app.script_count) |i| {
            const name = state.app.script_names[i][0..state.app.script_name_lens[i]];
            const enabled = state.app.script_enabled[i];

            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = i,
                .expand = .horizontal,
                .padding = .{ .x = 4, .y = 3, .w = 4, .h = 3 },
            });
            defer row.deinit();

            // Toggle button
            const toggle_label = if (enabled) "[ON]" else "[OFF]";
            if (dvui.button(@src(), toggle_label, .{}, .{
                .id_extra = i + 7000,
                .color_fill = if (enabled) theme.colors.accent_hover else dvui.Color{ .r = 50, .g = 46, .b = 44, .a = 200 },
                .color_text = if (enabled) theme.colors.bg_header else theme.colors.text_muted,
                .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
                .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
            })) {
                state.app.script_enabled[i] = !state.app.script_enabled[i];
                scripts.saveScriptState(i);
            }

            // Script name
            _ = dvui.labelNoFmt(@src(), name, .{}, .{
                .id_extra = i + 7100,
                .color_text = if (enabled) theme.colors.text_main else theme.colors.text_muted,
            });
        }
    }

    // ── Recommended Scripts ──
    settingRow("Recommended Scripts", 72, @src());
    _ = dvui.label(@src(), "One-click install popular mpv scripts", .{}, .{
        .color_text = theme.colors.text_muted,
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
    });

    for (scripts.recommended_scripts, 0..) |rec, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i + 8000,
            .expand = .horizontal,
            .padding = .{ .x = 4, .y = 3, .w = 4, .h = 3 },
        });
        defer row.deinit();

        // Check if already installed
        var installed = false;
        for (0..state.app.script_count) |si| {
            const sn = state.app.script_names[si][0..state.app.script_name_lens[si]];
            if (std.mem.eql(u8, sn, rec.filename)) {
                installed = true;
                break;
            }
        }

        if (installed) {
            _ = dvui.label(@src(), "  Installed  ", .{}, .{
                .id_extra = i + 8100,
                .color_text = theme.colors.success,
                .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
            });
        } else {
            if (dvui.button(@src(), "Install", .{}, .{
                .id_extra = i + 8100,
                .color_fill = theme.colors.accent,
                .color_text = theme.colors.bg_header,
                .padding = .{ .x = 8, .y = 2, .w = 8, .h = 2 },
                .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
            })) {
                scripts.installScript(i);
            }
        }

        _ = dvui.label(@src(), "{s}", .{rec.name}, .{
            .id_extra = i + 8200,
            .color_text = theme.colors.text_main,
            .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 },
        });

        _ = dvui.label(@src(), "{s}", .{rec.description}, .{
            .id_extra = i + 8300,
            .color_text = theme.colors.text_muted,
        });
    }

    // Info footer
    _ = dvui.label(@src(), "Scripts load on next player creation. Restart app to apply changes.", .{}, .{
        .id_extra = 8999,
        .color_text = theme.colors.text_muted,
        .margin = .{ .x = 0, .y = 12, .w = 0, .h = 0 },
    });
}

// ══════════════════════════════════════════════════════════
// Keyboard Cheat Sheet (? key)
// ══════════════════════════════════════════════════════════

pub fn renderCheatSheet() void {
    if (!state.app.cheatsheet_open) return;
    
    var win = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &state.app.cheatsheet_open,
    }, .{
        .min_size_content = .{ .w = 650, .h = 520 },
        .color_fill = theme.colors.bg_drawer,
        .color_border = theme.colors.border_drawer,
    });
    defer win.deinit();
    
    win.dragAreaSet(dvui.windowHeader("Keyboard Shortcuts", "", &state.app.cheatsheet_open));
    
    var settings_scale: f32 = 1.4;
    var scale_w = dvui.scale(@src(), .{ .scale = &settings_scale }, .{ .expand = .both });
    defer scale_w.deinit();
    
    const shortcuts = [_][2][]const u8{
        .{ "Space", "Play / Pause" },
        .{ "F", "Toggle Fullscreen" },
        .{ "Left / Right", "Seek -10s / +10s" },
        .{ "Up / Down", "Volume +5 / -5" },
        .{ "M", "Mute" },
        .{ "J / Shift+J", "Cycle Subs / Search Subs" },
        .{ "A", "Cycle Audio Track" },
        .{ "N / Shift+N", "Next / Prev Episode" },
        .{ "[ / ]", "Decrease / Increase Speed" },
        .{ "Backspace", "Reset Speed to 1.0x" },
        .{ ", / .", "Frame Back / Forward" },
        .{ "L", "Set A-B Loop (press 3x)" },
        .{ "+ / -", "Zoom In / Out" },
        .{ "0", "Reset Zoom & Pan" },
        .{ "Shift+Arrows", "Pan Video" },
        .{ "R", "Rotate Video" },
        .{ "T", "Flip Video" },
        .{ "P", "Screenshot" },
        .{ "Ctrl+I", "Media Info Panel" },
        .{ "S", "Toggle Search Drawer" },
        .{ "D", "Toggle Downloads Drawer" },
        .{ "H", "Toggle Watch History" },
        .{ "G", "Cycle Grid Mode" },
        .{ "Y", "Toggle Seek Sync" },
        .{ "I", "Toggle Incognito Mode" },
        .{ "B", "Switch Cell to Browser" },
        .{ "C", "Switch Cell to Comic" },
        .{ "Z", "Toggle Video Fill Mode" },
        .{ "Ctrl+Arrows", "Swap Cell Position" },
        .{ "1-9", "Select Player Cell" },
        .{ "Ctrl+,", "Settings" },
        .{ "Ctrl+T", "New Player Tab" },
        .{ "Ctrl+W", "Close Player Tab" },
        .{ "Ctrl+Shift+T", "Restore Closed Tab" },
        .{ "Ctrl+L", "Language Learning Mode" },
        .{ "Ctrl+S", "Save Subtitle Flashcard" },
        .{ "Ctrl+O", "Open File Dialog" },
        .{ "Ctrl+Q", "Quit" },
        .{ "Ctrl+V", "Paste URL / Magnet" },
        .{ "P", "Toggle Playlist Drawer" },
        .{ "?", "This Cheat Sheet" },
        .{ "Esc", "Close Overlay / Drawer" },
    };
    
    for (shortcuts, 0..) |sc, idx| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = idx,
            .expand = .horizontal,
            .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
        });
        defer row.deinit();

        // Key label (fixed width feel via padding)
        _ = dvui.label(@src(), "{s}", .{sc[0]}, .{
            .id_extra = idx,
            .color_text = theme.colors.accent,
            .min_size_content = .{ .w = 140, .h = 0 },
        });

        _ = dvui.label(@src(), "{s}", .{sc[1]}, .{
            .id_extra = idx + 1000,
            .color_text = theme.colors.text_main,
        });
    }

    // ── AI chat keyword shortcuts ──
    _ = dvui.label(@src(), "AI Keywords (type in input)", .{}, .{
        .color_text = theme.colors.accent,
        .margin = .{ .y = 16 },
    });

    const kw = [_][2][]const u8{
        .{ "play X", "Search + play best match" },
        .{ "watch X", "Same as play" },
        .{ "find X", "Search only, don't auto-play" },
        .{ "search X", "Same as find" },
        .{ "recommend me X", "TMDB-based recommendations" },
        .{ "next episode", "Play next episode of current show" },
        .{ "replay", "Restart last played item" },
        .{ "pause / play", "Instant: control current player" },
        .{ "seek 30s / -30s", "Instant: jump in timeline" },
        .{ "volume up / down", "Instant: adjust volume" },
        .{ "fullscreen", "Instant: toggle fullscreen" },
        .{ "mute", "Instant: toggle mute" },
        .{ "magnet:…", "Direct magnet load, no AI" },
        .{ "http(s)://…", "URL load (video / stream)" },
        .{ "/path/to/file", "Local file load" },
        .{ "anything else", "Conversational AI response" },
    };
    for (kw, 0..) |k, idx| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = idx + 5000,
            .expand = .horizontal,
            .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
        });
        defer row.deinit();
        _ = dvui.label(@src(), "{s}", .{k[0]}, .{
            .id_extra = idx,
            .color_text = theme.colors.accent,
            .min_size_content = .{ .w = 180, .h = 0 },
        });
        _ = dvui.label(@src(), "{s}", .{k[1]}, .{
            .id_extra = idx + 6000,
            .color_text = theme.colors.text_main,
        });
    }
}

// ══════════════════════════════════════════════════════════
// Dependency Setup Modal — first-run install hints
// ══════════════════════════════════════════════════════════

pub fn renderDepsModal() void {
    if (!state.app.deps_modal_open) return;
    const deps = @import("../core/deps.zig");
    const s = deps.check();
    if (s.apfel and s.ffmpeg and s.whisper) { state.app.deps_modal_open = false; return; }

    var win = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &state.app.deps_modal_open,
    }, .{
        .min_size_content = .{ .w = 540, .h = 360 },
        .color_fill = theme.colors.bg_drawer,
        .color_border = theme.colors.accent,
    });
    defer win.deinit();

    win.dragAreaSet(dvui.windowHeader("Setup — Missing Dependencies", "", &state.app.deps_modal_open));

    var pad_scale: f32 = 1.2;
    var scale_w = dvui.scale(@src(), .{ .scale = &pad_scale }, .{ .expand = .both });
    defer scale_w.deinit();

    _ = dvui.label(@src(), "Opal works best with these installed:", .{}, .{
        .color_text = theme.colors.text_main,
        .margin = .{ .x = 8, .y = 6, .w = 8, .h = 10 },
    });

    const rows = [_]struct { name: []const u8, desc: []const u8, ok: bool }{
        .{ .name = "apfel", .desc = "LLM backend (Apple Intelligence)", .ok = s.apfel },
        .{ .name = "ffmpeg", .desc = "Mic capture for voice mode", .ok = s.ffmpeg },
        .{ .name = "whisper-cpp", .desc = "Speech-to-text for voice mode", .ok = s.whisper },
        .{ .name = "ggml-tiny.en.bin", .desc = "STT model (auto-downloaded)", .ok = s.whisper_model },
    };

    for (rows, 0..) |r, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .expand = .horizontal,
            .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
        });
        defer row.deinit();

        _ = dvui.label(@src(), "{s}", .{if (r.ok) "✓" else "✗"}, .{
            .id_extra = i,
            .color_text = if (r.ok)
                dvui.Color{ .r = 100, .g = 200, .b = 130, .a = 255 }
            else
                dvui.Color{ .r = 220, .g = 100, .b = 100, .a = 255 },
            .min_size_content = .{ .w = 20, .h = 0 },
        });
        _ = dvui.label(@src(), "{s}", .{r.name}, .{
            .id_extra = i + 1000,
            .color_text = theme.colors.accent,
            .min_size_content = .{ .w = 140, .h = 0 },
        });
        _ = dvui.label(@src(), "{s}", .{r.desc}, .{
            .id_extra = i + 2000,
            .color_text = theme.colors.text_muted,
        });
    }

    // Install one-liner
    var cmd_buf: [256]u8 = undefined;
    const cmd = deps.installCmd(&cmd_buf, s);
    if (cmd.len > 0) {
        _ = dvui.label(@src(), "Install the missing pieces:", .{}, .{
            .color_text = theme.colors.text_main,
            .margin = .{ .x = 8, .y = 14, .w = 8, .h = 4 },
        });
        var code_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = dvui.Color{ .r = 18, .g = 18, .b = 26, .a = 255 },
            .color_border = dvui.Color{ .r = 50, .g = 50, .b = 70, .a = 200 },
            .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(6),
            .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
            .margin = .{ .x = 8, .y = 0, .w = 8, .h = 0 },
        });
        defer code_row.deinit();

        _ = dvui.label(@src(), "{s}", .{cmd}, .{
            .color_text = dvui.Color{ .r = 180, .g = 220, .b = 180, .a = 255 },
            .expand = .horizontal,
            .gravity_y = 0.5,
        });

        if (dvui.button(@src(), "Copy", .{}, .{
            .color_fill = theme.colors.accent,
            .color_text = dvui.Color.white,
            .corner_radius = dvui.Rect.all(4),
            .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 },
            .gravity_y = 0.5,
        })) {
            dvui.clipboardTextSet(cmd);
            state.showToast("Copied — paste in Terminal");
        }
    }

    // Don't show again checkbox (stored in config via deps_modal_checked)
    _ = dvui.label(@src(), "Voice mode degrades gracefully if missing — safe to skip.", .{}, .{
        .color_text = theme.colors.text_muted,
        .margin = .{ .x = 8, .y = 16, .w = 8, .h = 0 },
    });
}

// ══════════════════════════════════════════════════════════
// Media Info Panel (I key)
// ══════════════════════════════════════════════════════════

pub fn renderMediaInfo() void {
    if (!state.app.media_info_open) return;
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    
    const p = state.app.players.items[state.app.active_player_idx];
    
    var win = dvui.floatingWindow(@src(), .{
        .open_flag = &state.app.media_info_open,
    }, .{
        .min_size_content = .{ .w = 420, .h = 320 },
        .color_fill = dvui.Color{ .r = 20, .g = 22, .b = 28, .a = 240 },
        .color_border = theme.colors.border_drawer,
    });
    defer win.deinit();
    
    win.dragAreaSet(dvui.windowHeader("Media Info", "", &state.app.media_info_open));
    
    var info_scale: f32 = 1.3;
    var scale_w = dvui.scale(@src(), .{ .scale = &info_scale }, .{ .expand = .both });
    defer scale_w.deinit();

    // Query mpv properties
    const props = [_][2][]const u8{
        .{ "filename", "File" },
        .{ "video-codec", "Video Codec" },
        .{ "audio-codec-name", "Audio Codec" },
        .{ "width", "Width" },
        .{ "height", "Height" },
        .{ "video-params/pixelformat", "Pixel Format" },
        .{ "container-fps", "FPS" },
        .{ "video-bitrate", "Video Bitrate" },
        .{ "audio-bitrate", "Audio Bitrate" },
        .{ "audio-params/samplerate", "Sample Rate" },
        .{ "audio-params/channel-count", "Channels" },
        .{ "duration", "Duration" },
        .{ "file-size", "File Size" },
        .{ "hwdec-current", "HW Decode" },
    };

    for (props, 0..) |prop, idx| {
        const val_ptr: ?[*:0]u8 = @ptrCast(c.mpv.mpv_get_property_string(p.mpv_ctx, @ptrCast(prop[0].ptr)));
        
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = idx,
            .expand = .horizontal,
            .padding = .{ .x = 4, .y = 1, .w = 4, .h = 1 },
        });
        defer row.deinit();
        
        _ = dvui.label(@src(), "{s}", .{prop[1]}, .{
            .id_extra = idx,
            .color_text = theme.colors.text_muted,
            .min_size_content = .{ .w = 120, .h = 0 },
        });
        
        if (val_ptr) |vp| {
            const val_str = std.mem.span(vp);
            _ = dvui.label(@src(), "{s}", .{val_str}, .{
                .id_extra = idx + 500,
                .color_text = theme.colors.text_main,
            });
            c.mpv.mpv_free(vp);
        } else {
            _ = dvui.label(@src(), "-", .{}, .{
                .id_extra = idx + 500,
                .color_text = theme.colors.text_muted,
            });
        }
    }
}

fn renderFileAssocTab() void {
    sectionHeader("Default File Associations", "Register ZigZag as the default handler for media, torrents, and comics", 70, @src());
    fileassoc.render();
}
