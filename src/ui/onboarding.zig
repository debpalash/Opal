//! First-run onboarding — one modal, three decisions, then out of the way.
//! Opal ships neutral (no sources, no keys, no AI backend), which used to
//! mean three separate "why is this empty" traps: an empty search page, an
//! empty Movies & TV tab, and a dead chat. This wizard front-loads all
//! three. Shown once: `state.app.onboarded` persists via config ("onboarded");
//! existing installs are grandfathered on config load.

const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");

var tmdb_key_buf: [300]u8 = std.mem.zeroes([300]u8);

pub fn render() void {
    if (state.app.onboarded or !state.app.config_loaded or state.app.is_headless) return;

    const source_config = @import("../core/source_config.zig");
    const plugin_repo = @import("../services/plugin_repo.zig");
    const ai_server = @import("../services/ai_server.zig");

    var open = true;
    var win = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &open,
    }, .{
        .min_size_content = .{ .w = 520, .h = 0 },
        .max_size_content = dvui.Options.MaxSize.width(560),
        .color_fill = theme.colors.bg_surface,
        .border = dvui.Rect.all(1),
        .color_border = theme.colors.border_subtle,
        .corner_radius = dvui.Rect.all(theme.radius.lg),
    });
    defer win.deinit();
    // Closing the window (X / esc) counts as "skip" — don't nag every frame.
    if (!open) finish();

    var pad = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = dvui.Rect.all(theme.spacing.lg),
    });
    defer pad.deinit();

    _ = dvui.label(@src(), "Welcome to Opal", .{}, .{
        .color_text = theme.colors.text_primary,
        .font = dvui.themeGet().font_title,
    });
    _ = dvui.label(@src(), "Three quick things and you're set. All of this can be changed later in Settings.", .{}, .{
        .color_text = theme.colors.text_secondary,
        .margin = .{ .x = 0, .y = 2, .w = 0, .h = theme.spacing.md },
    });

    // ── 1. Sources ──
    stepHeader("1", "Search sources", 100);
    if (source_config.anyInstalled()) {
        doneRow("Sources installed — search will return streams.", 110);
    } else {
        _ = dvui.label(@src(), "Opal ships with no sources. Install the starter pack (14 curated providers) so search and episode playback work.", .{}, .{
            .color_text = theme.colors.text_secondary,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.xs },
        });
        if (accentButton("Install starter sources", 120)) {
            const n = plugin_repo.installStarterPack();
            var tb: [64]u8 = undefined;
            state.showToast(std.fmt.bufPrint(&tb, "{d} sources installed", .{n}) catch "Sources installed");
        }
    }

    // ── 2. TMDB (posters, seasons, trending) ──
    stepHeader("2", "TMDB catalog key", 200);
    if (state.app.tmdb.api_key_len > 0) {
        doneRow("TMDB key found — Movies & TV browsing is live.", 210);
    } else {
        _ = dvui.label(@src(), "Free key from themoviedb.org/settings/api — powers posters, seasons and trending.", .{}, .{
            .color_text = theme.colors.text_secondary,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.xs },
        });
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        var te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &tmdb_key_buf },
            .placeholder = "Paste API key / bearer token",
        }, .{
            .expand = .horizontal,
            .color_fill = theme.colors.bg_elevated,
            .color_border = theme.colors.border_subtle,
            .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(theme.radius.sm),
            .gravity_y = 0.5,
        });
        const entered = te.enter_pressed;
        te.deinit();
        if (accentButton("Save", 220) or entered) {
            const klen = std.mem.indexOfScalar(u8, &tmdb_key_buf, 0) orelse 0;
            if (klen > 0) {
                const n = @min(klen, state.app.tmdb.api_key.len);
                @memcpy(state.app.tmdb.api_key[0..n], tmdb_key_buf[0..n]);
                state.app.tmdb.api_key_len = n;
                state.markConfigDirty();
                state.showToast("TMDB key saved");
            }
        }
    }

    // ── 3. AI brain ──
    stepHeader("3", "AI assistant", 300);
    if (ai_server.firstCloudProviderWithKey()) |pi| {
        var lb: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&lb, "Cloud key found ({s}) — chat works out of the box. A local model can be installed later in Settings › AI.", .{ai_server.CLOUD_PROVIDERS[pi].name}) catch "Cloud AI ready.";
        doneRow(msg, 310);
    } else {
        _ = dvui.label(@src(), "Optional. Add a cloud API key to .env, or install a local model later — both in Settings › AI. Nothing downloads without you asking.", .{}, .{
            .color_text = theme.colors.text_secondary,
        });
    }

    // ── Finish ──
    {
        var frow = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = theme.spacing.lg, .w = 0, .h = 0 },
        });
        defer frow.deinit();
        var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
        sp.deinit();
        if (dvui.button(@src(), "Get started", .{}, .{
            .color_fill = theme.colors.accent,
            .color_text = theme.colors.text_on_accent,
            .corner_radius = dvui.Rect.all(theme.radius.md),
            .padding = .{ .x = theme.spacing.lg, .y = theme.spacing.sm, .w = theme.spacing.lg, .h = theme.spacing.sm },
        })) {
            finish();
        }
    }
}

fn finish() void {
    state.app.onboarded = true;
    state.markConfigDirty();
}

fn stepHeader(num: []const u8, title: []const u8, id: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id,
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = theme.spacing.md, .w = 0, .h = 2 },
    });
    defer row.deinit();
    var badge = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id,
        .background = true,
        .color_fill = theme.colors.bg_elevated,
        .corner_radius = dvui.Rect.all(theme.radius.pill),
        .min_size_content = .{ .w = 20, .h = 20 },
        .max_size_content = .{ .w = 20, .h = 20 },
        .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
    });
    _ = dvui.label(@src(), "{s}", .{num}, .{
        .id_extra = id,
        .color_text = theme.colors.accent,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .expand = .both,
    });
    badge.deinit();
    _ = dvui.label(@src(), "{s}", .{title}, .{
        .id_extra = id,
        .color_text = theme.colors.text_primary,
        .font = dvui.themeGet().font_heading,
        .gravity_y = 0.5,
    });
}

fn doneRow(msg: []const u8, id: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = id, .expand = .horizontal });
    defer row.deinit();
    dvui.icon(@src(), "ob-done", @import("icons").tvg.lucide.@"circle-check-big", .{}, .{
        .id_extra = id,
        .color_text = theme.colors.success,
        .min_size_content = theme.iconSize(.sm),
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = theme.spacing.xs, .h = 0 },
    });
    _ = dvui.label(@src(), "{s}", .{msg}, .{
        .id_extra = id,
        .color_text = theme.colors.text_secondary,
        .gravity_y = 0.5,
    });
}

fn accentButton(label: []const u8, id: usize) bool {
    return dvui.button(@src(), label, .{}, .{
        .id_extra = id,
        .color_fill = theme.colors.accent,
        .color_text = theme.colors.text_on_accent,
        .corner_radius = dvui.Rect.all(theme.radius.sm),
        .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
        .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = 0 },
        .gravity_y = 0.5,
    });
}
