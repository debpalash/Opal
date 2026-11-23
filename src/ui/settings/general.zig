const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const components = @import("../components.zig");
const state = @import("../../core/state.zig");
const theme = @import("../theme.zig");
const settings = @import("../settings.zig");
const sectionHeader = settings.sectionHeader;
const settingRow = settings.settingRow;

pub fn renderGeneralTab() void {
    // ── Interface ── (whitespace-separated, no card chrome)
    sectionHeader("Interface", "Customize how Opal looks and feels", 10, @src());

    // UI Scale — Auto is the default and never drops below 1.0×. DVUI handles
    // a reported OS scale; when Linux reports only a placeholder 1×, validated
    // panel data may scale upward. Sub-1× choices remain explicit manual
    // density overrides, while point-based breakpoints adapt the layout.
    settingRow("UI Scale", 100, @src());
    {
        const scales = [_]f32{ 0.6, 0.7, 0.8, 0.9, 1.0, 1.2, 1.4, 1.6, 2.0 };
        const scale_labels = [_][]const u8{ "Auto (1.0x+)", "0.6x", "0.7x", "0.8x", "0.9x", "1.0x", "1.2x", "1.4x", "1.6x", "2.0x" };
        // Index 0 = Auto; manual values are offset by one.
        var sel: usize = 0;
        if (!state.app.ui_scale_auto) {
            for (scales, 0..) |s, idx| {
                if (@abs(state.app.ui_scale - s) < 0.05) {
                    sel = idx + 1;
                    break;
                }
            }
        }
        if (components.segment(@src(), &scale_labels, sel)) |clicked| {
            if (clicked == 0) {
                state.app.ui_scale_auto = true;
                state.app.ui_scale = @import("../../core/display_info.zig").defaultScale(dvui.windowNaturalScale());
            } else {
                state.app.ui_scale_auto = false;
                state.app.ui_scale = scales[clicked - 1];
            }
            state.markConfigDirty();
        }
    }

    // Grid Layout — short ramp via segment.
    {
        const before = state.app.reduce_motion;
        components.toggleRow(@src(), "Reduce motion", "Make route, panel, toggle and notification transitions immediate", &state.app.reduce_motion);
        if (state.app.reduce_motion != before) {
            theme.setReducedMotion(state.app.reduce_motion);
            state.markConfigDirty();
        }
    }

    settingRow("Grid Layout", 11, @src());
    {
        const modes = [_]state.GridMode{ .auto, .cols_1, .cols_2, .cols_3, .cols_4 };
        const mode_names = [_][]const u8{ "Auto", "1 Col", "2 Col", "3 Col", "4 Col" };
        var sel: usize = 0;
        for (modes, 0..) |m, idx| {
            if (state.app.grid_mode == m) {
                sel = idx;
                break;
            }
        }
        if (components.segment(@src(), &mode_names, sel)) |clicked| {
            state.app.grid_mode = modes[clicked];
            state.markConfigDirty();
        }
    }

    // Theme — segment of preset names (no per-preset accent swatches; one
    // accent, carried by the active segment's calm fill).
    settingRow("Theme", 1500, @src());
    {
        const presets = [_]theme.ThemePreset{ .midnight, .abyss, .phantom, .nord, .solarized, .rose, .ember };
        const preset_names = [_][]const u8{ "Midnight", "Abyss", "Phantom", "Nord", "Solarized", "Rosé", "Ember" };
        var sel: usize = 0;
        for (presets, 0..) |preset, idx| {
            if (theme.active_preset == preset) {
                sel = idx;
                break;
            }
        }
        if (components.segment(@src(), &preset_names, sel)) |clicked| {
            theme.setPreset(presets[clicked]);
            state.showToast(theme.presetName(presets[clicked]));
            state.markConfigDirty();
        }
    }

    // Audio visualiser — radio, podcasts and music have no video track, so mpv
    // synthesises one from the audio (see player/visualizer_pure.zig). Takes effect
    // on the next audio file: the filter graph is applied when mpv reports the file
    // has no video.
    settingRow("Audio visualizer", 1501, @src());
    {
        const vis = @import("../../player/visualizer_pure.zig");
        const player = @import("../../player/player.zig");
        const styles = [_]vis.Style{ .off, .bars, .waves, .spectrum, .scope };
        // Same strings as Style.label() — config persists the label, so a rename
        // here without one there would silently reset everyone to the default.
        const names = [_][]const u8{ "Off", "Bars", "Waveform", "Spectrum", "Scope" };
        var sel: usize = 1;
        for (styles, 0..) |st, idx| {
            if (player.vis_style == st) {
                sel = idx;
                break;
            }
        }
        if (components.segment(@src(), &names, sel)) |clicked| {
            player.vis_style = styles[clicked];
            state.showToast(names[clicked]);
            state.markConfigDirty();
        }
    }

    // ── Behavior ──
    sectionHeader("Behavior", "Toggles that control app behavior", 12, @src());

    // Seek Sync toggle — pure bool flip, no side effects.
    {
        const before = state.app.seek_sync;
        components.toggleRow(@src(), "Seek Sync", "Sync all player positions", &state.app.seek_sync);
        if (state.app.seek_sync != before) state.markConfigDirty();
    }

    // NSFW Filter toggle — pure bool flip.
    {
        const before = state.app.nsfw_filter_enabled;
        components.toggleRow(@src(), "NSFW Filter", "Hide adult content in search, anime, and Live TV", &state.app.nsfw_filter_enabled);
        if (state.app.nsfw_filter_enabled != before) state.markConfigDirty();
    }

    {
        const before = state.app.continue_hide_nsfw;
        components.toggleRow(@src(), "Hide NSFW from Continue", "Filter adult titles and source links from Continue", &state.app.continue_hide_nsfw);
        if (before != state.app.continue_hide_nsfw) state.markConfigDirty();
        const private_before = state.app.continue_private;
        components.toggleRow(@src(), "Blur Continue until hover", "Hide covers and titles on Home for shared screens", &state.app.continue_private);
        if (private_before != state.app.continue_private) state.markConfigDirty();
    }

    // Personalized suggestions (local-only) — gates the taste engine
    // (services/activity.zig): activity recording AND the Home "For You" row.
    // Everything stays on-device; "Clear taste data" drops the logged rows.
    {
        const before = state.app.taste_enabled;
        components.toggleRow(@src(), "Personalized suggestions (local-only)", "Learn from your activity on this device to improve the For You row", &state.app.taste_enabled);
        if (state.app.taste_enabled != before) state.markConfigDirty();
        if (dvui.button(@src(), "Clear taste data", .{}, .{
            .color_fill = @import("../color_compat.zig").wrap(theme.transparent),
            .color_fill_hover = @import("../color_compat.zig").wrap(theme.colors.bg_hover),
            .color_text = @import("../color_compat.zig").wrap(theme.colors.accent),
            .border = dvui.Rect.all(0),
            .corners = dvui.CornerRect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
        })) {
            @import("../../services/activity.zig").clearTasteData();
            state.showToast("Taste data cleared");
        }
    }

    // ── TMDB Integration ──
    sectionHeader("TMDB (Advanced, optional)", "Not needed: Opal loads movies, TV, calendars and subtitles without it", 14, @src());

    settingRow("TMDB key", 140, @src());
    {
        var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.tmdb.api_key }, .placeholder = "Optional: your own themoviedb.org token", .password_char = "•" }, .{
            .id_extra = 142,
            .expand = .horizontal,
            .min_size_content = .{ .w = 300, .h = 20 },
            .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
            .color_border = @import("../color_compat.zig").wrap(theme.colors.border_subtle),
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
            .border = dvui.Rect.all(1),
            .corners = theme.dims.rad_sm,
        });
        const tmdb_changed = te.text_changed;
        te.deinit();
        const tmdb_was_default = state.app.tmdb.api_key_is_default;
        state.app.tmdb.api_key_len = std.mem.indexOfScalar(u8, &state.app.tmdb.api_key, 0) orelse 0;
        if (tmdb_changed) {
            // Any edit turns the field into a real user key (persisted, overrides
            // the built-in default).
            state.app.tmdb.api_key_is_default = false;
            state.markConfigDirty();
        }
        _ = dvui.label(@src(), "{s}", .{if (tmdb_was_default and !tmdb_changed)
            "Using Opal's built-in key — paste your own to override."
        else
            "Advanced, optional. Only adds richer metadata (cast, extra artwork, trailers). Everything works without it."}, .{
            .id_extra = 143,
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
            .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = 0 },
        });
    }

    // ── OMDb Ratings ── (optional — adds real IMDb / RT / Metacritic scores to
    // the detail view; TMDB can't provide these. Inert until a key is set.)
    sectionHeader("OMDb Ratings", "Real IMDb, Rotten Tomatoes & Metacritic scores on the detail view", 15, @src());

    settingRow("API Key", 150, @src());
    {
        const has_omdb = state.app.omdb_api_key_len > 0;
        const omdb_was_default = state.app.omdb_api_key_is_default;
        var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.omdb_api_key }, .placeholder = "Optional — paste free key from omdbapi.com", .password_char = "•" }, .{
            .id_extra = 152,
            .expand = .horizontal,
            .min_size_content = .{ .w = 300, .h = 20 },
            .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
            .color_border = @import("../color_compat.zig").wrap(theme.colors.border_subtle),
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
            .border = dvui.Rect.all(1),
            .corners = theme.dims.rad_sm,
        });
        const omdb_changed = te.text_changed;
        te.deinit();
        state.app.omdb_api_key_len = std.mem.indexOfScalar(u8, &state.app.omdb_api_key, 0) orelse 0;
        if (omdb_changed) {
            state.app.omdb_api_key_is_default = false;
            state.markConfigDirty();
        }
        _ = dvui.label(@src(), "{s}", .{if (omdb_was_default and !omdb_changed)
            "Using Opal's built-in key — paste your own to override."
        else if (has_omdb)
            "Key set — IMDb / RT / Metacritic scores show on movie & show pages."
        else
            "Free key (1,000/day) from omdbapi.com/apikey.aspx — leave blank to disable."}, .{
            .id_extra = 153,
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
            .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = 0 },
        });
    }
    // ── TheTVDB ── (fallback for anime/obscure shows when TMDB has no match or
    // incomplete seasons; user-supplied key only, stored as a secret.)
    sectionHeader("TheTVDB", "Fallback metadata for anime and obscure shows", 16, @src());
    settingRow("API Key", 160, @src());
    {
        var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.tvdb_api_key }, .placeholder = "Optional — your own thetvdb.com v4 key", .password_char = "•" }, .{
            .id_extra = 162,
            .expand = .horizontal,
            .min_size_content = .{ .w = 300, .h = 20 },
            .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
            .color_border = @import("../color_compat.zig").wrap(theme.colors.border_subtle),
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
            .border = dvui.Rect.all(1),
            .corners = theme.dims.rad_sm,
        });
        const tvdb_changed = te.text_changed;
        te.deinit();
        state.app.tvdb_api_key_len = std.mem.indexOfScalar(u8, &state.app.tvdb_api_key, 0) orelse state.app.tvdb_api_key.len;
        if (tvdb_changed) state.markConfigDirty();
        _ = dvui.label(@src(), "{s}", .{if (state.app.tvdb_api_key_len > 0)
            "Key set — TheTVDB fills shows and seasons TMDB is missing."
        else
            "Leave blank to disable. No key ships with Opal."}, .{
            .id_extra = 163,
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
            .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = 0 },
        });
    }
    sectionHeader("Plugins", "Manage sources and content plugins", 9, @src());
    {
        var links = dvui.flexbox(@src(), .{}, .{ .expand = .horizontal });
        defer links.deinit();
        const controls = @import("../browse_filters.zig");
        if (controls.item(@src(), .{ .id = 9001, .label = "Sources", .icon = icons.tvg.lucide.plug, .presentation = .icon_label })) {
            state.app.plugin_tab = .sources;
            state.navigateToTab(.Plugins);
        }
        if (controls.item(@src(), .{ .id = 9002, .label = "Content plugins", .icon = icons.tvg.lucide.puzzle, .presentation = .icon_label })) {
            state.app.plugin_tab = .content;
            state.navigateToTab(.Plugins);
        }
    }
}
