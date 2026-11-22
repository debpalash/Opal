const std = @import("std");
const dvui = @import("dvui");
const components = @import("../components.zig");
const logs = @import("../../core/logs.zig");
const state = @import("../../core/state.zig");
const theme = @import("../theme.zig");
const settings = @import("../settings.zig");
const sectionHeader = settings.sectionHeader;

// ── Live TV (IPTV) settings ──
// The catalog is fed by curated public IPTV directories (iptv-org etc.) plus an
// optional user M3U. Install/uninstall + ingest all live in services/iptv.zig;
// this tab is purely UI over that API. Custom-URL text is backed by a settings-
// local buffer prefilled once from the saved config (see below).
var livetv_url_buf: [512]u8 = std.mem.zeroes([512]u8);
var livetv_name_buf: [81]u8 = std.mem.zeroes([81]u8);
var livetv_url_prefilled: bool = false;
var livetv_edit_slot: ?usize = null;
var livetv_migrate_legacy: bool = false;
// Whether to flag the custom playlist as adult (all its channels NSFW-gated).
var livetv_adult: bool = false;
var source_config_checked: bool = false;

pub fn renderLiveTvTab() void {
    const iptv = @import("../../services/iptv.zig");
    const sources = @import("../../services/iptv_sources.zig");
    const source_config = @import("../../core/source_config.zig");

    // ── Catalog header: total channels + manual refresh ──
    sectionHeader("Channels", "Live TV pulled from public IPTV directories", 10, @src());
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = theme.spacing.sm },
        });
        defer row.deinit();

        var count_buf: [64]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "{d} channels in your catalog", .{iptv.catalogTotal()}) catch "channels";
        _ = dvui.label(@src(), "{s}", .{count_str}, .{
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
            .gravity_y = 0.5,
        });
        {
            var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            sp.deinit();
        }
        if (iptv.isIngesting()) {
            _ = dvui.label(@src(), "Updating…", .{}, .{
                .color_text = @import("../color_compat.zig").wrap(theme.colors.warning),
                .gravity_y = 0.5,
                .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
            });
            components.pollRefresh(100_000);
        }
        if (dvui.button(@src(), "Refresh now", .{}, .{
            .color_fill = @import("../color_compat.zig").wrap(theme.colors.accent),
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_on_accent),
            .border = dvui.Rect.all(0),
            .corners = theme.dims.rad_sm,
            .padding = .{ .x = 12, .y = 5, .w = 12, .h = 5 },
            .gravity_y = 0.5,
        })) {
            iptv.refreshAllSources(true);
            state.showToast("Refreshing Live TV channels…");
        }
    }

    // Hard product invariant — surfaced, never a toggle.
    _ = dvui.label(@src(), "Adult channels are always filtered out.", .{}, .{
        .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
        .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = 0 },
    });

    // ── Curated sources ──
    sectionHeader("Sources", "Toggle a directory on to install and ingest its channels", 20, @src());
    for (sources.SOURCES, 0..) |s, i| {
        if (std.mem.eql(u8, s.id, sources.CUSTOM_ID)) continue; // custom handled below
        const id_base = 200 + i * 10;
        const installed = source_config.has(s.id);

        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = id_base,
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = theme.spacing.sm },
        });
        defer row.deinit();

        // Left column: name + a muted meta line (region · note · channels).
        {
            var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = id_base + 1, .gravity_y = 0.5 });
            defer col.deinit();

            _ = dvui.label(@src(), "{s}", .{s.name}, .{
                .id_extra = id_base + 2,
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
            });

            var cbuf: [40]u8 = undefined;
            const chan_txt: []const u8 = if (installed)
                (std.fmt.bufPrint(&cbuf, "{d} channels", .{iptv.sourceChannelCount(s.id)}) catch "")
            else if (s.approx > 0)
                (std.fmt.bufPrint(&cbuf, "~{d} channels", .{s.approx}) catch "")
            else
                "";

            var mbuf: [256]u8 = undefined;
            const meta: []const u8 = blk: {
                if (s.note.len > 0 and chan_txt.len > 0)
                    break :blk std.fmt.bufPrint(&mbuf, "{s} · {s} · {s}", .{ s.region, s.note, chan_txt }) catch s.region;
                if (s.note.len > 0)
                    break :blk std.fmt.bufPrint(&mbuf, "{s} · {s}", .{ s.region, s.note }) catch s.region;
                if (chan_txt.len > 0)
                    break :blk std.fmt.bufPrint(&mbuf, "{s} · {s}", .{ s.region, chan_txt }) catch s.region;
                break :blk s.region;
            };
            _ = dvui.label(@src(), "{s}", .{meta}, .{
                .id_extra = id_base + 3,
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
                .margin = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
            });
        }

        {
            var sp = dvui.box(@src(), .{}, .{ .id_extra = id_base + 4, .expand = .horizontal });
            sp.deinit();
        }

        // Right: install toggle. Accent fill = installed; neutral = off.
        if (dvui.button(@src(), if (installed) "On" else "Off", .{}, .{
            .id_extra = id_base + 5,
            .color_fill = @import("../color_compat.zig").wrap(if (installed) theme.colors.accent else theme.colors.bg_elevated),
            .color_text = @import("../color_compat.zig").wrap(if (installed) theme.colors.text_on_accent else theme.colors.text_secondary),
            .border = dvui.Rect.all(0),
            .corners = theme.dims.rad_sm,
            .padding = .{ .x = 14, .y = 5, .w = 14, .h = 5 },
            .gravity_y = 0.5,
        })) {
            if (installed) {
                iptv.uninstallSource(s.id);
                state.showToast("Removed a Live TV source");
            } else {
                iptv.installSource(s.id);
                if (source_config.has(s.id)) {
                    state.showToast("Live TV source enabled · ingesting channels");
                    logs.pushLog("info", "iptv", "Live TV source configured; fetching public playlist via HTTPS", false);
                } else {
                    state.showToastTyped("Could not install Live TV source · see Logs", .err);
                    logs.pushLog("error", "iptv", "Live TV source configuration write failed", true);
                }
            }
        }
    }

    // ── Custom playlist ──
    sectionHeader("Custom playlists", "Add and manage up to eight M3U / M3U8 sources", 30, @src());
    {
        var custom_id_buf: [32]u8 = undefined;
        for (0..iptv.MAX_CUSTOM_SOURCES) |slot| {
            const id = iptv.customSourceId(slot, &custom_id_buf);
            const saved_url = source_config.get(id, "url") orelse continue;
            const saved_name = source_config.get(id, "name") orelse "Custom playlist";
            var source_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 400 + slot, .expand = .horizontal });
            defer source_row.deinit();
            _ = dvui.label(@src(), "{s} · {d} channels", .{ saved_name, iptv.sourceChannelCount(id) }, .{
                .id_extra = 420 + slot,
                .expand = .horizontal,
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
            });
            if (dvui.button(@src(), "Edit", .{}, .{ .id_extra = 440 + slot, .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated) })) {
                @memset(&livetv_name_buf, 0);
                @memset(&livetv_url_buf, 0);
                @memcpy(livetv_name_buf[0..@min(saved_name.len, livetv_name_buf.len - 1)], saved_name[0..@min(saved_name.len, livetv_name_buf.len - 1)]);
                @memcpy(livetv_url_buf[0..@min(saved_url.len, livetv_url_buf.len - 1)], saved_url[0..@min(saved_url.len, livetv_url_buf.len - 1)]);
                livetv_adult = std.mem.eql(u8, source_config.get(id, "adult") orelse "", "1");
                livetv_edit_slot = slot;
                livetv_migrate_legacy = false;
            }
            if (dvui.button(@src(), "Remove", .{}, .{ .id_extra = 460 + slot, .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated), .color_text = @import("../color_compat.zig").wrap(theme.colors.danger) })) {
                _ = iptv.removeCustomSource(slot);
                if (livetv_edit_slot == slot) livetv_edit_slot = null;
                state.showToast("Removed custom playlist");
                break;
            }
        }

        // Prefill the old single slot once so saving migrates it without loss.
        if (!livetv_url_prefilled) {
            if (source_config.get(sources.CUSTOM_ID, "url")) |saved| {
                const n = @min(saved.len, livetv_url_buf.len - 1);
                @memcpy(livetv_url_buf[0..n], saved[0..n]);
                const legacy_name = "Imported playlist";
                @memcpy(livetv_name_buf[0..legacy_name.len], legacy_name);
                livetv_adult = std.mem.eql(u8, source_config.get(sources.CUSTOM_ID, "adult") orelse "", "1");
                livetv_migrate_legacy = true;
            }
            livetv_url_prefilled = true;
        }

        var name_entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = &livetv_name_buf }, .placeholder = "Playlist name" }, .{
            .id_extra = 299,
            .expand = .horizontal,
            .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
            .corners = theme.dims.rad_sm,
        });
        name_entry.deinit();

        {
            var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &livetv_url_buf }, .placeholder = "https://provider/playlist.m3u8" }, .{
                .id_extra = 300,
                .expand = .horizontal,
                .min_size_content = .{ .w = 250, .h = 20 },
                .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
                .color_border = @import("../color_compat.zig").wrap(theme.colors.border_subtle),
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
                .border = dvui.Rect.all(1),
                .corners = theme.dims.rad_sm,
            });
            te.deinit();
        }

        if (!source_config_checked) {
            source_config_checked = true;
            if (!livetv_url_prefilled) livetv_adult = false;
        }
        _ = dvui.checkbox(@src(), &livetv_adult, "Adult (18+) playlist — hidden unless NSFW filter is off", .{
            .id_extra = 305,
        });

        var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = 301,
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = 0 },
        });
        defer btn_row.deinit();

        if (dvui.button(@src(), if (livetv_edit_slot != null) "Save changes" else "Add playlist", .{}, .{
            .id_extra = 302,
            .color_fill = @import("../color_compat.zig").wrap(theme.colors.accent),
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_on_accent),
            .border = dvui.Rect.all(0),
            .corners = theme.dims.rad_sm,
            .padding = .{ .x = 12, .y = 5, .w = 12, .h = 5 },
        })) {
            const raw = livetv_url_buf[0 .. std.mem.indexOfScalar(u8, &livetv_url_buf, 0) orelse livetv_url_buf.len];
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            const raw_name = livetv_name_buf[0 .. std.mem.indexOfScalar(u8, &livetv_name_buf, 0) orelse livetv_name_buf.len];
            const name = std.mem.trim(u8, raw_name, " \t\r\n");
            const slot = livetv_edit_slot orelse iptv.firstFreeCustomSlot();
            if (slot) |target| {
                if (iptv.setCustomSource(target, name, trimmed, livetv_adult)) {
                    if (livetv_migrate_legacy) iptv.setCustomUrl("", false);
                    @memset(&livetv_name_buf, 0);
                    @memset(&livetv_url_buf, 0);
                    livetv_edit_slot = null;
                    livetv_migrate_legacy = false;
                    state.showToast("Saved custom playlist");
                } else state.showToastTyped("Enter a name and valid HTTP(S) playlist URL", .err);
            } else state.showToastTyped("Remove a playlist before adding another", .err);
        }
        if (dvui.button(@src(), "Cancel", .{}, .{
            .id_extra = 303,
            .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
            .border = dvui.Rect.all(0),
            .corners = theme.dims.rad_sm,
            .padding = .{ .x = 12, .y = 5, .w = 12, .h = 5 },
            .margin = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 },
        })) {
            @memset(&livetv_url_buf, 0);
            @memset(&livetv_name_buf, 0);
            livetv_adult = false;
            livetv_edit_slot = null;
            livetv_migrate_legacy = false;
        }
    }
}
