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
    if (state.app.onboarded or !state.app.config_loaded.load(.acquire) or state.app.is_headless) return;

    const source_config = @import("../core/source_config.zig");
    const plugin_repo = @import("../services/plugin_repo.zig");
    const ai_server = @import("../services/ai_server.zig");

    var open = true;
    var win = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &open,
    }, .{
        .min_size_content = .{ .w = 480, .h = 0 },
        .max_size_content = dvui.Options.MaxSize.width(520),
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

    // ── Branded header: the Opal gem + wordmark ──
    {
        var head = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer head.deinit();
        _ = dvui.image(@src(), .{
            .source = .{ .imageFile = .{ .bytes = @embedFile("opal_logo_64.png"), .name = "opal-onboard" } },
        }, .{
            .min_size_content = .{ .w = 34, .h = 34 },
            .max_size_content = .{ .w = 34, .h = 34 },
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        });
        _ = dvui.label(@src(), "Welcome to Opal", .{}, .{
            .color_text = theme.colors.text_primary,
            .font = dvui.themeGet().font_title,
            .gravity_y = 0.5,
        });
    }
    descLabel(1, "Three quick things and you're set — all of it is changeable later in Settings.");

    // ── 1. Sources ──
    {
        var card = stepCard(@src(), 1000);
        defer card.deinit();
        stepHeader(100, "Search sources");
        if (source_config.anyInstalled()) {
            doneRow(110, "Sources installed — search returns streams.");
        } else {
            descLabel(101, "Opal ships with no sources. Install the starter pack — 14 curated providers — so search and episode playback work.");
            if (buttonRow(120, "Install starter sources")) {
                const n = plugin_repo.installStarterPack();
                var tb: [64]u8 = undefined;
                state.showToast(std.fmt.bufPrint(&tb, "{d} sources installed", .{n}) catch "Sources installed");
            }
        }
    }

    // ── 2. TMDB (posters, seasons, trending) ──
    {
        var card = stepCard(@src(), 2000);
        defer card.deinit();
        stepHeader(200, "TMDB catalog key");
        if (state.app.tmdb.api_key_len > 0) {
            doneRow(210, "TMDB key found — Movies & TV browsing is live.");
        } else {
            descLabel(201, "Free key from themoviedb.org/settings/api — powers posters, seasons and trending.");
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = 202,
                .expand = .horizontal,
                .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = 0 },
            });
            defer row.deinit();
            var te = dvui.textEntry(@src(), .{
                .text = .{ .buffer = &tmdb_key_buf },
                .placeholder = "Paste API key / bearer token",
            }, .{
                .expand = .horizontal,
                .color_fill = theme.colors.bg_surface,
                .color_border = theme.colors.border_subtle,
                .border = dvui.Rect.all(1),
                .corner_radius = dvui.Rect.all(theme.radius.sm),
                .gravity_y = 0.5,
                .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
            });
            const entered = te.enter_pressed;
            te.deinit();
            if (accentButton(220, "Save") or entered) {
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
    }

    // ── 3. AI brain ──
    {
        var card = stepCard(@src(), 3000);
        defer card.deinit();
        stepHeader(300, "AI assistant (optional)");
        if (ai_server.firstCloudProviderWithKey()) |pi| {
            var lb: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&lb, "Cloud key found ({s}) — chat works out of the box.", .{ai_server.CLOUD_PROVIDERS[pi].name}) catch "Cloud AI ready.";
            doneRow(310, msg);
        } else {
            descLabel(301, "Add a cloud key to .env, or install a local model later — both in Settings › AI. Nothing downloads without you asking.");
        }
    }

    // ── Finish ──
    {
        var frow = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = theme.spacing.md, .w = 0, .h = 0 },
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

/// One step's container — a subtle elevated card so the three decisions read as
/// distinct, scannable blocks instead of a wall of text. Caller `defer`s deinit.
fn stepCard(src: std.builtin.SourceLocation, id: usize) *dvui.BoxWidget {
    return dvui.box(src, .{ .dir = .vertical }, .{
        .id_extra = id,
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.colors.bg_elevated,
        .corner_radius = dvui.Rect.all(theme.radius.md),
        .padding = dvui.Rect.all(theme.spacing.md),
        .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 },
    });
}

/// Section heading — bold. Inside a card, the card padding provides the spacing,
/// so only a small gap below to the description.
fn stepHeader(id: usize, title: []const u8) void {
    _ = dvui.label(@src(), "{s}", .{title}, .{
        .id_extra = id,
        .color_text = theme.colors.text_primary,
        .font = dvui.themeGet().font_heading,
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = 3 },
    });
}

/// Wrapping body text — a plain single-line label truncates with "…" at the
/// modal width; textLayout wraps to as many lines as needed.
fn descLabel(id: usize, text: []const u8) void {
    var tl = dvui.textLayout(@src(), .{}, .{
        .id_extra = id,
        .expand = .horizontal,
        .background = false,
        .padding = dvui.Rect.all(0),
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.xs },
    });
    tl.addText(text, .{ .color_text = theme.colors.text_secondary });
    tl.deinit();
}

/// A left-aligned accent action button in its own full-width row. Wrapping the
/// button in a horizontal row (rather than dropping it straight into the
/// vertical body with gravity_y) is what keeps it from overlapping the next
/// element — main-axis gravity in a vertical parent mis-positions the widget.
fn buttonRow(id: usize, label: []const u8) bool {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id,
        .expand = .horizontal,
    });
    defer row.deinit();
    const clicked = accentButton(id, label);
    var sp = dvui.box(@src(), .{}, .{ .id_extra = id + 1, .expand = .horizontal });
    sp.deinit();
    return clicked;
}

fn doneRow(id: usize, msg: []const u8) void {
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

fn accentButton(id: usize, label: []const u8) bool {
    return dvui.button(@src(), label, .{}, .{
        .id_extra = id,
        .color_fill = theme.colors.accent,
        .color_text = theme.colors.text_on_accent,
        .corner_radius = dvui.Rect.all(theme.radius.sm),
        .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
        .gravity_y = 0.5,
    });
}
