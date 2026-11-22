const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const components = @import("../components.zig");
const state = @import("../../core/state.zig");
const theme = @import("../theme.zig");
const settings = @import("../settings.zig");
const settingRow = settings.settingRow;

pub fn renderSubtitlesTab() void {
    const engine_mod = @import("../../player/subtitles.zig");
    const engine = &state.app.sub_engine;
    const has_key = state.app.opensub_api_key_len > 0;

    // Auto-download toggle — governs the on-play keyless fetch.
    {
        const before = state.app.auto_download_subs;
        components.toggleRow(@src(), "Auto-download subtitles", "Fetch the best match when a video has none — works without any key", &state.app.auto_download_subs);
        if (state.app.auto_download_subs != before) state.markConfigDirty();
    }

    // ── Babel: live captions, translation, recaps ──
    @import("../babel_ui.zig").settingsSection();

    // ── OpenSubtitles API Key ── (optional — keyless search works without it)
    settingRow("OpenSubtitles.com API Key", 42, @src());
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 24 },
        });
        defer row.deinit();

        var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.opensub_api_key }, .placeholder = "Optional — paste API key from opensubtitles.com", .password_char = "•" }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 250, .h = 20 },
            .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
            .color_border = @import("../color_compat.zig").wrap(theme.colors.border_subtle),
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
            .border = dvui.Rect.all(1),
            .corners = theme.dims.rad_sm,
        });
        const opensub_changed = te.text_changed;
        te.deinit();
        state.app.opensub_api_key_len = std.mem.indexOfScalar(u8, &state.app.opensub_api_key, 0) orelse 0;
        if (opensub_changed) state.markConfigDirty();
    }
    // Quiet one-liner — search works keyless out of the box; a key only ADDS.
    _ = dvui.label(@src(), "{s}", .{if (has_key)
        "Key set — opensubtitles.com results join the keyless providers."
    else
        "Add an OpenSubtitles.com key for more results (opensubtitles.com › Profile › API Consumers)."}, .{
        .id_extra = 4200,
        .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
        .margin = .{ .x = 0, .y = 2, .w = 0, .h = 8 },
    });

    // ── Subdl API Key ── (optional, FREE per-user key; ZIP downloads)
    const has_subdl = state.app.subdl_api_key_len > 0;
    settingRow("Subdl API Key", 44, @src());
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 24 },
        });
        defer row.deinit();

        var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.subdl_api_key }, .placeholder = "Optional — free key from subdl.com/panel/api", .password_char = "•" }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 250, .h = 20 },
            .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
            .color_border = @import("../color_compat.zig").wrap(theme.colors.border_subtle),
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
            .border = dvui.Rect.all(1),
            .corners = theme.dims.rad_sm,
        });
        const subdl_changed = te.text_changed;
        te.deinit();
        state.app.subdl_api_key_len = std.mem.indexOfScalar(u8, &state.app.subdl_api_key, 0) orelse 0;
        if (subdl_changed) state.markConfigDirty();
    }
    _ = dvui.label(@src(), "{s}", .{if (has_subdl)
        "Key set — Subdl results appear below when you search."
    else
        "Add a free Subdl key for a large legal DB (subdl.com › panel › API)."}, .{
        .id_extra = 4210,
        .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
        .margin = .{ .x = 0, .y = 2, .w = 0, .h = 8 },
    });

    // ── Subtitle Language ── (short codes via segment)
    settingRow("Search Language", 40, @src());
    {
        const langs = [_][]const u8{ "eng", "spa", "fre", "ger", "por", "ita", "rus", "chi", "jpn", "kor", "hin", "ara", "tur" };
        const lang_names = [_][]const u8{ "EN", "ES", "FR", "DE", "PT", "IT", "RU", "ZH", "JA", "KO", "HI", "AR", "TR" };
        const current = state.app.sub_lang_buf[0..state.app.sub_lang_len];
        var sel: usize = 0;
        for (langs, 0..) |l, idx| {
            if (std.mem.eql(u8, current, l)) {
                sel = idx;
                break;
            }
        }
        if (components.segment(@src(), &lang_names, sel)) |clicked| {
            const l = langs[clicked];
            @memcpy(state.app.sub_lang_buf[0..l.len], l);
            state.app.sub_lang_len = l.len;
            state.markConfigDirty();
            // Language changed — re-run the current subtitle search with it.
            engine_mod.refire(engine);
        }
    }

    // ── Search Subtitles ── (keyless engine first; keyed joins when set)
    settingRow("Search Subtitles", 43, @src());
    {
        const subs = @import("../../services/subtitles.zig");
        const engine_busy = engine.state == .searching or engine.state == .downloading;

        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = 24 },
        });
        defer row.deinit();

        var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.sub_search_buf }, .placeholder = "Movie/show name…" }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 200, .h = 20 },
            .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
            .color_border = @import("../color_compat.zig").wrap(theme.colors.border_subtle),
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
            .border = dvui.Rect.all(1),
            .corners = theme.dims.rad_sm,
        });
        const enter = te.enter_pressed;
        te.deinit();

        // Search button — primary affordance.
        const search_clicked = dvui.button(@src(), if (engine_busy) "..." else "Search", .{}, .{
            .id_extra = 4301,
            .color_fill = @import("../color_compat.zig").wrap(theme.colors.accent),
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_on_accent),
            .border = dvui.Rect.all(0),
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
            .margin = .{ .x = theme.spacing.xs, .y = 0, .w = 2, .h = 0 },
            .corners = theme.dims.rad_md,
        });

        // Auto-detect from player — secondary (text-only).
        if (dvui.button(@src(), "Auto", .{}, .{
            .id_extra = 4302,
            .color_fill = @import("../color_compat.zig").wrap(theme.transparent),
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
            .color_fill_hover = @import("../color_compat.zig").wrap(theme.colors.bg_hover),
            .color_fill_press = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
            .border = dvui.Rect.all(0),
            .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
            .margin = .{ .x = 2, .y = 0, .w = 0, .h = 0 },
            .corners = theme.dims.rad_md,
        })) {
            engine_mod.searchFromActivePlayer(engine);
            if (has_key and !subs.is_searching.load(.acquire)) subs.autoSearchFromPlayer(false);
        }

        if ((search_clicked or enter) and !engine_busy) {
            const q_len = std.mem.indexOfScalar(u8, &state.app.sub_search_buf, 0) orelse 0;
            if (q_len > 0) {
                engine_mod.searchQuery(engine, state.app.sub_search_buf[0..q_len]);
                const lang = if (state.app.sub_lang_len > 0) state.app.sub_lang_buf[0..state.app.sub_lang_len] else "eng";
                if (has_key and !subs.is_searching.load(.acquire)) {
                    subs.searchByQuery(state.app.sub_search_buf[0..q_len], lang);
                }
                // Subdl joins the keyed search when a Subdl key is configured.
                if (has_subdl and !subs.subdl_is_searching.load(.acquire)) {
                    subs.subdlSearch(state.app.sub_search_buf[0..q_len], lang);
                }
            }
        }
    }

    // ── Results — keyless engine first, keyed section appended ──
    {
        const subs = @import("../../services/subtitles.zig");
        const text_mod = @import("../../core/text.zig");

        // Live status while a worker runs (worker states have no UI wake of
        // their own — the spinner keeps the tab repainting).
        if (engine.state == .searching or engine.state == .downloading or subs.is_searching.load(.acquire) or subs.is_downloading.load(.acquire) or subs.subdl_is_searching.load(.acquire) or subs.subdl_is_downloading.load(.acquire)) {
            var lrow = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = 4401,
                .expand = .horizontal,
                .margin = .{ .x = 0, .y = 4, .w = 0, .h = 4 },
            });
            defer lrow.deinit();
            dvui.spinner(@src(), .{
                .color_text = @import("../color_compat.zig").wrap(theme.colors.accent),
                .min_size_content = .{ .w = 12, .h = 12 },
                .gravity_y = 0.5,
                .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
            });
            _ = dvui.label(@src(), "{s}", .{switch (engine.state) {
                .searching => "Scouring OpenSubtitles and Addic7ed…",
                .downloading => "Downloading subtitle…",
                else => "Checking opensubtitles.com…",
            }}, .{
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
                .gravity_y = 0.5,
            });
            components.pollRefresh(100_000);
        }

        // Keyless rows — source-tagged; no key required.
        if (engine.result_count > 0) {
            var count_buf: [48]u8 = undefined;
            const count_str = @import("opal-fmt").bufPrintZ(&count_buf, "{d} results \xC2\xB7 open providers", .{engine.result_count}) catch "results";
            _ = dvui.label(@src(), "{s}", .{count_str}, .{
                .id_extra = 4402,
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
                .margin = .{ .x = 0, .y = 6, .w = 0, .h = 2 },
            });

            for (0..engine.result_count) |ri| {
                const r = &engine.results[ri];
                var res_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = ri + 4500,
                    .expand = .horizontal,
                    .background = true,
                    .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_surface),
                    .corners = theme.dims.rad_sm,
                    .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.sm, .w = theme.spacing.sm, .h = theme.spacing.sm },
                    .margin = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
                });
                defer res_row.deinit();

                // Untrusted + worker-written: validate a copy before dvui
                // draws it (invalid UTF-8 panics the whole app).
                var nm_buf: [128]u8 = undefined;
                _ = dvui.label(@src(), "{s}", .{text_mod.safeUtf8Buf(r.movie_name[0..@min(r.movie_name_len, 90)], &nm_buf)}, .{
                    .id_extra = ri + 4600,
                    .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
                    .gravity_y = 0.5,
                    .expand = .horizontal,
                });

                // Language + source — quiet metadata chips.
                if (r.lang_len > 0) {
                    var lb: [16]u8 = undefined;
                    _ = dvui.label(@src(), "{s}", .{text_mod.safeUtf8Buf(r.lang[0..r.lang_len], &lb)}, .{
                        .id_extra = ri + 4700,
                        .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
                        .gravity_y = 0.5,
                        .margin = .{ .x = 6, .y = 0, .w = 4, .h = 0 },
                    });
                }
                _ = dvui.label(@src(), "{s}", .{engine_mod.sourceName(r.source)}, .{
                    .id_extra = ri + 4800,
                    .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
                    .gravity_y = 0.5,
                    .margin = .{ .x = 2, .y = 0, .w = 6, .h = 0 },
                });

                if (engine.loaded_idx == @as(i32, @intCast(ri))) {
                    _ = dvui.icon(@src(), "sub-loaded", icons.tvg.lucide.check, .{}, .{
                        .id_extra = ri + 4950,
                        .color_text = @import("../color_compat.zig").wrap(theme.colors.success),
                        .min_size_content = theme.iconSize(.xs),
                        .gravity_y = 0.5,
                        .margin = .{ .x = 2, .y = 0, .w = 2, .h = 0 },
                    });
                    _ = dvui.label(@src(), "Loaded", .{}, .{
                        .id_extra = ri + 4900,
                        .color_text = @import("../color_compat.zig").wrap(theme.colors.success),
                        .gravity_y = 0.5,
                    });
                } else if (engine.state == .downloading and engine.selected_idx == ri) {
                    dvui.spinner(@src(), .{
                        .id_extra = ri + 4900,
                        .color_text = @import("../color_compat.zig").wrap(theme.colors.accent),
                        .min_size_content = .{ .w = 12, .h = 12 },
                        .gravity_y = 0.5,
                    });
                } else {
                    // Download — accent, the single primary action per row.
                    if (dvui.button(@src(), "Get", .{}, .{
                        .id_extra = ri + 5000,
                        .color_fill = @import("../color_compat.zig").wrap(theme.colors.accent),
                        .color_text = @import("../color_compat.zig").wrap(theme.colors.text_on_accent),
                        .border = dvui.Rect.all(0),
                        .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
                        .corners = theme.dims.rad_sm,
                        .gravity_y = 0.5,
                    })) {
                        engine_mod.downloadIndex(engine, ri);
                    }
                }
            }
        } else if (engine.state == .failed) {
            _ = dvui.label(@src(), "Nothing surfaced from the open providers — try a shorter title or another language.", .{}, .{
                .id_extra = 4403,
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
                .margin = .{ .x = 0, .y = 4, .w = 0, .h = 4 },
            });
        }

        // Keyed section — only when a key is configured (no nagging without).
        if (has_key and (subs.result_count > 0 or (subs.search_error_len > 0 and !subs.is_searching.load(.acquire)))) {
            components.sectionHeader("OpenSubtitles.com");

            if (subs.search_error_len > 0 and subs.result_count == 0) {
                var err_buf: [128]u8 = undefined;
                const safe_err = text_mod.safeUtf8Buf(subs.search_error[0..subs.search_error_len], &err_buf);
                _ = dvui.label(@src(), "{s}", .{safe_err}, .{
                    .id_extra = 4400,
                    .color_text = @import("../color_compat.zig").wrap(theme.colors.warning),
                    .margin = .{ .x = 0, .y = 4, .w = 0, .h = 4 },
                });
            }

            for (0..subs.result_count) |ri| {
                const r = &subs.results[ri];
                // Calm: a spacing-only row separated by a faint fill tier — no
                // per-row border. (Encode the boundary once: fill, not border.)
                var res_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = ri + 5500,
                    .expand = .horizontal,
                    .background = true,
                    .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_surface),
                    .corners = theme.dims.rad_sm,
                    .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.sm, .w = theme.spacing.sm, .h = theme.spacing.sm },
                    .margin = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
                });
                defer res_row.deinit();

                // Language badge — demoted to secondary text (not accent).
                if (r.lang_len > 0) {
                    var lb: [16]u8 = undefined;
                    _ = dvui.label(@src(), "{s}", .{text_mod.safeUtf8Buf(r.language[0..r.lang_len], &lb)}, .{
                        .id_extra = ri + 5600,
                        .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
                        .gravity_y = 0.5,
                        .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
                    });
                }

                // Release name (truncated)
                if (r.release_len > 0) {
                    const show_len = @min(r.release_len, 60);
                    var rel_buf: [96]u8 = undefined;
                    _ = dvui.label(@src(), "{s}", .{text_mod.safeUtf8Buf(r.release[0..show_len], &rel_buf)}, .{
                        .id_extra = ri + 5700,
                        .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
                        .gravity_y = 0.5,
                    });
                }

                {
                    var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
                    sp.deinit();
                }

                // Download count — quiet metadata, no glyph.
                if (r.download_count > 0) {
                    var dc_buf: [16]u8 = undefined;
                    const dc_str = @import("opal-fmt").bufPrintZ(&dc_buf, "{d}", .{r.download_count}) catch "";
                    _ = dvui.label(@src(), "{s}", .{dc_str}, .{
                        .id_extra = ri + 5800,
                        .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
                        .gravity_y = 0.5,
                        .margin = .{ .x = 6, .y = 0, .w = 4, .h = 0 },
                    });
                }

                // HI badge
                if (r.hearing_impaired) {
                    _ = dvui.label(@src(), "CC", .{}, .{
                        .id_extra = ri + 5900,
                        .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
                        .gravity_y = 0.5,
                        .margin = .{ .x = 2, .y = 0, .w = 4, .h = 0 },
                    });
                }

                // Download button — accent, the single primary action per row.
                if (dvui.button(@src(), if (subs.is_downloading.load(.acquire)) "..." else "Get", .{}, .{
                    .id_extra = ri + 6000,
                    .color_fill = @import("../color_compat.zig").wrap(theme.colors.accent),
                    .color_text = @import("../color_compat.zig").wrap(theme.colors.text_on_accent),
                    .border = dvui.Rect.all(0),
                    .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
                    .corners = theme.dims.rad_sm,
                    .gravity_y = 0.5,
                })) {
                    if (!subs.is_downloading.load(.acquire) and r.file_id > 0) {
                        subs.downloadSubtitle(r.file_id);
                    }
                }
            }
        }

        // Subdl section — only when a Subdl key is configured (no nag without).
        if (has_subdl and (subs.subdl_result_count > 0 or (subs.subdl_error_len > 0 and !subs.subdl_is_searching.load(.acquire)))) {
            components.sectionHeader("Subdl");

            if (subs.subdl_error_len > 0 and subs.subdl_result_count == 0) {
                var err_buf: [128]u8 = undefined;
                const safe_err = text_mod.safeUtf8Buf(subs.subdl_error[0..subs.subdl_error_len], &err_buf);
                _ = dvui.label(@src(), "{s}", .{safe_err}, .{
                    .id_extra = 7100,
                    .color_text = @import("../color_compat.zig").wrap(theme.colors.warning),
                    .margin = .{ .x = 0, .y = 4, .w = 0, .h = 4 },
                });
            }

            for (0..subs.subdl_result_count) |ri| {
                const r = &subs.subdl_results[ri];
                var res_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = ri + 7200,
                    .expand = .horizontal,
                    .background = true,
                    .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_surface),
                    .corners = theme.dims.rad_sm,
                    .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.sm, .w = theme.spacing.sm, .h = theme.spacing.sm },
                    .margin = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
                });
                defer res_row.deinit();

                // Language badge — quiet secondary text.
                if (r.lang_len > 0) {
                    var lb: [16]u8 = undefined;
                    _ = dvui.label(@src(), "{s}", .{text_mod.safeUtf8Buf(r.lang[0..r.lang_len], &lb)}, .{
                        .id_extra = ri + 7300,
                        .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
                        .gravity_y = 0.5,
                        .margin = .{ .x = 0, .y = 0, .w = 6, .h = 0 },
                    });
                }

                // Release name (truncated).
                if (r.release_len > 0) {
                    const show_len = @min(r.release_len, 70);
                    var rel_buf: [96]u8 = undefined;
                    _ = dvui.label(@src(), "{s}", .{text_mod.safeUtf8Buf(r.release[0..show_len], &rel_buf)}, .{
                        .id_extra = ri + 7400,
                        .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
                        .gravity_y = 0.5,
                        .expand = .horizontal,
                    });
                }

                {
                    var sp_box = dvui.box(@src(), .{}, .{ .expand = .horizontal });
                    sp_box.deinit();
                }

                // Download button — accent, the single primary action per row.
                if (dvui.button(@src(), if (subs.subdl_is_downloading.load(.acquire)) "..." else "Get", .{}, .{
                    .id_extra = ri + 7500,
                    .color_fill = @import("../color_compat.zig").wrap(theme.colors.accent),
                    .color_text = @import("../color_compat.zig").wrap(theme.colors.text_on_accent),
                    .border = dvui.Rect.all(0),
                    .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
                    .corners = theme.dims.rad_sm,
                    .gravity_y = 0.5,
                })) {
                    if (!subs.subdl_is_downloading.load(.acquire)) {
                        subs.subdlDownload(ri);
                    }
                }
            }
        }
    }

    // ── Auto-download status ──
    settingRow("Auto-Download Status", 41, @src());
    {
        const status_text = switch (engine.state) {
            .idle => "Idle — fires when a video starts without subtitles",
            .searching => "Searching…",
            .found => "Found subtitles",
            .downloading => "Downloading…",
            .ready => "Loaded",
            .failed => "Not found",
        };
        _ = dvui.label(@src(), "{s}", .{status_text}, .{
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
        });
    }

    _ = dvui.label(@src(), "Shift+J = Search subs for current video | J = Cycle tracks", .{}, .{
        .id_extra = 4201,
        .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
        .margin = .{ .x = 0, .y = 8, .w = 0, .h = 0 },
    });
}
