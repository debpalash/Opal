const dvui = @import("dvui");
const icons = @import("icons");
const brands = @import("../brands.zig");
const components = @import("../components.zig");
const state = @import("../../core/state.zig");
const theme = @import("../theme.zig");
const settings = @import("../settings.zig");
const labelText = settings.labelText;
const openExternal = settings.openExternal;
const sectionHeader = settings.sectionHeader;

/// About-section link chip: icon + label, opens `url` externally on click.
fn aboutLink(id: usize, icon: []const u8, label: []const u8, url: []const u8, icon_color: dvui.Color) void {
    var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id,
        .background = true,
        .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_surface),
        .corners = dvui.CornerRect.all(theme.radius.pill),
        .padding = .{ .x = theme.spacing.md, .y = 4, .w = theme.spacing.md, .h = 4 },
        .margin = .{ .x = 0, .y = 2, .w = theme.spacing.sm, .h = 2 },
        .gravity_y = 0.5,
    });
    defer chip.deinit();
    var hovered = false;
    const clicked = dvui.clicked(chip.data(), .{ .hovered = &hovered });
    if (hovered) chip.data().options.color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_hover);
    chip.drawBackground();

    dvui.icon(@src(), "about-link", icon, .{}, .{
        .id_extra = id,
        .color_text = @import("../color_compat.zig").wrap(icon_color),
        .min_size_content = .{ .w = 13, .h = 13 },
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = theme.spacing.xs, .h = 0 },
    });
    _ = dvui.label(@src(), "{s}", .{label}, .{
        .id_extra = id,
        .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
        .gravity_y = 0.5,
    });

    if (clicked) openExternal(url);
}
pub fn renderAboutTab() void {
    // Extracted from the Playback tab into its own page. btn_* mirror the
    // Playback tab's local button tokens the block references.
    const btn_inactive = theme.colors.bg_elevated;

    // ── About / Updater ── (no card chrome; whitespace + the brand row)
    sectionHeader("About", "Version, updates, credits & support", 25, @src());
    {
        const updater = @import("../../services/updater.zig");
        const update = updater.snapshot();
        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.sm },
        });
        defer card.deinit();

        // Logo / wordmark row.
        {
            var brand = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.sm },
            });
            defer brand.deinit();

            // The Opal gem (assets/logo.svg → embedded PNG), not a stock glyph.
            _ = dvui.image(@src(), .{
                .source = .{ .imageFile = .{ .bytes = @embedFile("../opal_logo_64.png"), .name = "opal-about" } },
            }, .{
                .min_size_content = .{ .w = 28, .h = 28 },
                .max_size_content = .{ .w = 28, .h = 28 },
                .gravity_y = 0.5,
                .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
            });
            // Wordmark — display font (22).
            var wmf = dvui.themeGet().font_body;
            wmf.size = theme.font_size.display;
            _ = dvui.label(@src(), "Opal", .{}, .{
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
                .font = wmf,
                .gravity_y = 0.5,
            });
            // Tagline.
            _ = dvui.label(@src(), "Play everything", .{}, .{
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
                .gravity_y = 0.5,
                .margin = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 },
            });
        }

        // Positioning line + the short pitch (mirrors the README hero).
        _ = dvui.label(@src(), "The evolved media player for the next decades of entertainment.", .{}, .{
            .id_extra = 2505,
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 2 },
        });
        _ = dvui.label(@src(), "Local-first, an mpv heart, and an AI that never leaves your machine.\nNo accounts · no telemetry · no cloud — your history is a SQLite file you own.", .{}, .{
            .id_extra = 2506,
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.sm },
        });

        // Version row
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer row.deinit();
            _ = dvui.label(@src(), "Version", .{}, .{ .color_text = @import("../color_compat.zig").wrap(labelText()), .gravity_y = 0.5 });
            _ = dvui.label(@src(), "  v{s}", .{updater.APP_VERSION}, .{ .id_extra = 2510, .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary), .gravity_y = 0.5 });
            {
                var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
                spacer.deinit();
            }
            if (update.is_checking) {
                _ = dvui.label(@src(), "Checking…", .{}, .{ .id_extra = 2511, .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary), .gravity_y = 0.5 });
                components.pollRefresh(100_000);
            } else if (dvui.button(@src(), "Check for Updates", .{}, .{
                .id_extra = 2512,
                .color_fill = @import("../color_compat.zig").wrap(btn_inactive),
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
                .border = dvui.Rect.all(0),
                .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
                .corners = theme.dims.rad_md,
            })) {
                updater.checkAsync();
            }
        }

        // The first-run welcome remains available after setup from About.
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 2520, .expand = .horizontal });
            defer row.deinit();
            _ = dvui.label(@src(), "Welcome guide", .{}, .{ .id_extra = 2521, .color_text = @import("../color_compat.zig").wrap(labelText()), .gravity_y = 0.5 });
            {
                var spacer = dvui.box(@src(), .{}, .{ .id_extra = 2522, .expand = .horizontal });
                spacer.deinit();
            }
            if (dvui.button(@src(), "Replay Guide", .{}, .{
                .id_extra = 2523,
                .color_fill = @import("../color_compat.zig").wrap(btn_inactive),
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
                .border = dvui.Rect.all(0),
                .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
                .corners = theme.dims.rad_md,
            })) {
                @import("../onboarding.zig").replay();
            }
        }

        // Credits line — who built it, under what terms.
        _ = dvui.label(@src(), "Crafted by Palash Deb (@debpalash) · free and open source, GPL-3.0", .{}, .{
            .id_extra = 2530,
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
            .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = 0 },
        });

        // Real links — GitHub, license, and the donate pair. Each opens in
        // the system browser (the old pills here were dead decorations).
        components.divider();
        {
            var links = dvui.flexbox(@src(), .{ .justify_content = .start }, .{
                .expand = .horizontal,
                .margin = .{ .x = 0, .y = 4, .w = 0, .h = 0 },
            });
            defer links.deinit();
            aboutLink(2540, brands.icon(.github), "GitHub", "https://github.com/debpalash/Opal", theme.colors.text_secondary);
            aboutLink(2541, icons.tvg.lucide.scale, "License (GPL-3.0)", "https://www.gnu.org/licenses/gpl-3.0.html", theme.colors.text_secondary);
            aboutLink(2542, icons.tvg.lucide.heart, "Donate · PayPal", "https://paypal.me/palashCoder", theme.colors.danger);
            aboutLink(2543, icons.tvg.lucide.coffee, "Buy me a Ko-fi", "https://ko-fi.com/debpalash", theme.colors.warning);
        }
        // Sponsors keep Opal free — no telemetry to monetize, no accounts to
        // upsell. Donations above are the whole business model.
        _ = dvui.label(@src(), "Sponsors keep Opal independent — every Ko-fi and PayPal donation funds development directly.", .{}, .{
            .id_extra = 2545,
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
            .margin = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
        });

        // Credits — the shoulders this stands on, plus TMDB's required notice.
        components.divider();
        _ = dvui.label(@src(), "Built with Zig · dvui · mpv · SDL2 · libtorrent · SQLite + sqlite-vec · ONNX Runtime · whisper.cpp", .{}, .{
            .id_extra = 2546,
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
        });
        _ = dvui.label(@src(), "Catalog feeds from Cinemeta. Optional metadata from TMDB — this product uses the TMDB API but is not endorsed or certified by TMDB.", .{}, .{
            .id_extra = 2547,
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
            .margin = .{ .x = 0, .y = 2, .w = 0, .h = theme.spacing.xs },
        });

        const auto_check_before = state.app.auto_check_updates;
        components.toggleRow(@src(), "Check for updates automatically", "Show an update card; downloads and restarts always wait for you", &state.app.auto_check_updates);
        if (auto_check_before != state.app.auto_check_updates) state.markConfigDirty();
        if (update.has_update) {
            components.divider();
            _ = dvui.label(@src(), "Opal v{s} is available", .{update.latestTag()}, .{ .color_text = .{ .color = theme.colors.accent } });
            if (components.actionButton(@src(), if (update.is_ready) "Update ready" else if (update.is_downloading) "Show download" else "View update", .primary, 2522)) updater.show();
        } else if (update.last_check_ts > 0 and !update.is_checking and update.last_error_len == 0) {
            components.bodyText(@src(), "Up to date", theme.colors.success);
        }
        if (update.last_error_len > 0) components.bodyText(@src(), update.lastError(), theme.colors.warning);
    }
}
