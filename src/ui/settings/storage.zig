const std = @import("std");
const dvui = @import("dvui");
const components = @import("../components.zig");
const paths = @import("../../core/paths.zig");
const state = @import("../../core/state.zig");
const theme = @import("../theme.zig");
const settings = @import("../settings.zig");
const sectionHeader = settings.sectionHeader;
const settingRow = settings.settingRow;

pub fn renderStorageTab() void {
    sectionHeader("Storage", "Downloads, library history and cached data", 50, @src());
    // Download Path
    settingRow("Download Path", 50, @src());
    {
        const path = state.app.save_path_buf[0..state.app.save_path_len];
        _ = dvui.label(@src(), "{s}", .{path}, .{
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
            .margin = .{ .x = 0, .y = theme.spacing.xxs, .w = 0, .h = theme.spacing.xs },
        });

        // Path presets (resolved at runtime) — segment.
        var dl_path_buf: [256]u8 = undefined;
        var vid_path_buf: [256]u8 = undefined;
        const dl_path = paths.defaultSavePath(&dl_path_buf);
        const vid_path = paths.videosSavePath(&vid_path_buf);
        // Third preset is "scratch space that survives until reboot". Hardcoding
        // /tmp offered Windows users a path that cannot exist; io.tmpDir maps to
        // %TEMP% there.
        var tmp_dir_buf: [512]u8 = undefined;
        var tmp_path_buf: [576]u8 = undefined;
        const tmp_path = std.fmt.bufPrint(
            &tmp_path_buf,
            "{s}/opal_torrents",
            .{@import("../../core/io_global.zig").tmpDir(&tmp_dir_buf)},
        ) catch "opal_torrents";
        const preset_paths = [_][]const u8{ dl_path, vid_path, tmp_path };
        const path_names = [_][]const u8{ "~/Downloads (default)", "~/Videos", "Temp (scratch)" };

        var sel: usize = path_names.len; // none-active sentinel
        for (preset_paths, 0..) |p, idx| {
            if (std.mem.eql(u8, path, p)) {
                sel = idx;
                break;
            }
        }
        if (components.segment(@src(), &path_names, sel)) |clicked| {
            const p = preset_paths[clicked];
            @memcpy(state.app.save_path_buf[0..p.len], p);
            state.app.save_path_len = p.len;
            // Create dir if it doesn't exist
            @import("../../core/io_global.zig").cwdMakePath(p) catch {};
            state.markConfigDirty();
        }
    }
    // Watch History Stats
    settingRow("Watch History", 51, @src());
    {
        const watch = @import("../../player/watch_history.zig");
        var count_buf: [48]u8 = undefined;
        const count_str = @import("opal-fmt").bufPrintZ(&count_buf, "{d} entries saved", .{watch.getCount()}) catch "?";
        _ = dvui.label(@src(), "{s}", .{count_str}, .{
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
        });

        // Two-step confirm — a single stray click used to run DELETE FROM
        // watch_history, irreversibly dropping every resume position.
        //
        // Wrapped in a horizontal row: confirmDangerButton sets gravity_y=0.5,
        // which in a VERTICAL parent centers the button in the remaining space
        // and floats it over the sections below (it overlapped the Disk usage
        // rows). Inside a horizontal row, gravity_y means "center in this row",
        // which is what it was written for.
        {
            var r = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer r.deinit();
            if (components.confirmDangerButton(@src(), "Clear Watch History", 0)) {
                watch.clearAll();
                state.showToast("Watch history cleared — restore below");
            }
        }
        // One-level undo: clearAll() snapshots into watch_history_backup.
        if (watch.backup_available) {
            if (dvui.button(@src(), "Restore last cleared history", .{}, .{
                .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
                .border = dvui.Rect.all(0),
                .corners = theme.dims.rad_md,
                .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
                .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = 0 },
            })) {
                watch.restoreBackup();
                state.showToast("Watch history restored");
            }
        }
    }

    // Encrypted content cache — instant cold-start views + SWR refresh.
    renderCacheSection();

    // What Opal is actually using the disk for.
    renderDiskUsageSection();
}

/// Storage → Disk usage: every store Opal owns, with a size and (where safe) a
/// remove action.
///
/// This replaced a static label that read "SQLite: ~/.config/opal/opal.db" —
/// which was wrong on Windows and Linux (the path is %APPDATA%\opal there, and
/// $XDG_CONFIG_HOME elsewhere), showed no size, and accounted for none of the
/// rest. A real install measured 1.3 GB while this page reported 0.3 MB.
///
/// Sizes come from a background scan (core/storage_usage.zig). The UI reads a
/// published snapshot and never touches the filesystem — walking a multi-GB tree
/// from the render path would stall the frame.
fn renderDiskUsageSection() void {
    const usage = @import("../../core/storage_usage.zig");
    const upure = @import("../../core/storage_usage_pure.zig");

    settingRow("Disk usage", 52, @src());

    // Scan once when the tab is first opened, then only on demand.
    if (!usage.scanned_once.load(.acquire) and !usage.scanning.load(.acquire)) usage.scanAsync();

    // Header: total + rescan.
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = theme.spacing.xxs, .w = 0, .h = theme.spacing.xs },
        });
        defer row.deinit();

        const busy = usage.scanning.load(.acquire);
        var total_buf: [48]u8 = undefined;
        var size_buf: [32]u8 = undefined;
        const total_str = if (busy)
            "Measuring…"
        else
            std.fmt.bufPrint(&total_buf, "{s} total", .{
                upure.formatBytes(usage.total_bytes, &size_buf),
            }) catch "?";
        _ = dvui.label(@src(), "{s}", .{total_str}, .{
            .color_text = @import("../color_compat.zig").wrap(if (busy) theme.colors.warning else theme.colors.text_primary),
            .gravity_y = 0.5,
        });
        if (busy) components.pollRefresh(100_000);
        {
            var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            sp.deinit();
        }
        if (!busy and dvui.button(@src(), "Rescan", .{}, .{
            .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
            .border = dvui.Rect.all(0),
            .corners = theme.dims.rad_md,
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
            .gravity_y = 0.5,
        })) usage.scanAsync();
    }

    // Snapshot `count` once: the worker publishes it last, but it can still
    // change between reads within this frame.
    const n = usage.count;
    if (n == 0) {
        _ = dvui.label(@src(), "{s}", .{if (usage.scanning.load(.acquire))
            "Measuring…"
        else
            "Nothing stored yet"}, .{ .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary) });
        return;
    }

    for (usage.entries[0..n], 0..) |*e, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = theme.spacing.xs },
        });
        defer row.deinit();

        // Label + note stacked on the left.
        {
            var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = i, .gravity_y = 0.5 });
            defer col.deinit();
            _ = dvui.label(@src(), "{s}", .{e.labelStr()}, .{
                .id_extra = i,
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
            });
            _ = dvui.label(@src(), "{s}", .{e.noteStr()}, .{
                .id_extra = i,
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
            });
        }
        {
            var sp = dvui.box(@src(), .{}, .{ .id_extra = i, .expand = .horizontal });
            sp.deinit();
        }

        // Size + share of the total.
        {
            var size_buf: [32]u8 = undefined;
            var lbl_buf: [56]u8 = undefined;
            const pct = upure.percentOf(e.bytes, usage.total_bytes);
            const s = std.fmt.bufPrint(&lbl_buf, "{s}  ({d}%)", .{
                upure.formatBytes(e.bytes, &size_buf), pct,
            }) catch "?";
            _ = dvui.label(@src(), "{s}", .{s}, .{
                .id_extra = i,
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
                .gravity_y = 0.5,
                .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
            });
        }

        // Remove action — absent entirely for user data (storage_usage.removeEntry
        // refuses it too, so this is defence in depth, not the only guard).
        if (upure.isRemovable(e.kind)) {
            if (upure.needsConfirm(e.kind)) {
                // Expensive to refetch → two-step confirm, same as elsewhere.
                if (components.confirmDangerButton(@src(), "Remove", @intCast(10 + i))) {
                    _ = usage.removeEntry(i);
                    state.showToast("Removed — will re-download when next needed");
                }
            } else if (dvui.button(@src(), "Clear", .{}, .{
                .id_extra = i,
                .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
                .border = dvui.Rect.all(0),
                .corners = theme.dims.rad_md,
                .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
                .gravity_y = 0.5,
            })) {
                _ = usage.removeEntry(i);
                state.showToast("Cache cleared");
            }
        }
    }

    // Where it all lives — resolved, not hardcoded.
    {
        var cfg_buf: [512]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{paths.configDir(&cfg_buf)}, .{
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
            .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 },
        });
    }
}

/// Storage → Cache section: the enable toggle, an on-disk size label, and a
/// "Clear cache" action. Encrypted content cache lives in
/// core/content_cache.zig; entries are AES/XChaCha-encrypted under a local key.
fn renderCacheSection() void {
    const content_cache = @import("../../core/content_cache.zig");
    settingRow("Content Cache", 53, @src());

    // Enable toggle — persisted like every other config bool.
    {
        const before = state.app.content_cache_enabled;
        components.toggleRow(
            @src(),
            "Cache content on disk (encrypted)",
            "Instant search & browse on cold start; refreshes in the background when stale",
            &state.app.content_cache_enabled,
        );
        if (state.app.content_cache_enabled != before) state.markConfigDirty();
    }

    // On-disk size label.
    {
        const bytes = content_cache.sizeBytes();
        var size_buf: [64]u8 = undefined;
        const mb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
        const size_str = std.fmt.bufPrint(&size_buf, "{d:.1} MB cached on disk", .{mb}) catch "?";
        _ = dvui.label(@src(), "{s}", .{size_str}, .{
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
            .margin = .{ .x = 0, .y = theme.spacing.xxs, .w = 0, .h = theme.spacing.xs },
        });
    }

    // Clear cache — two-step confirm (destructive; drops all cached entries).
    // Horizontal wrapper for the same gravity_y reason as Clear Watch History.
    {
        var r = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer r.deinit();
        if (components.confirmDangerButton(@src(), "Clear cache", 1)) {
            content_cache.clearAll();
            state.showToast("Content cache cleared");
        }
    }
}
