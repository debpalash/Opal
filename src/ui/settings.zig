const brands = @import("brands.zig");
const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const theme = @import("theme.zig");
const components = @import("components.zig");
const c = @import("../core/c.zig");
const logs = @import("../core/logs.zig");
const paths = @import("../core/paths.zig");
const fileassoc = @import("settings_fileassoc.zig");
const network_tab = @import("settings/network.zig");
const subtitles_tab = @import("settings/subtitles.zig");
const storage_tab = @import("settings/storage.zig");
const live_tv_tab = @import("settings/live_tv.zig");
const lang_learn_tab = @import("settings/lang_learn.zig");
const scripts_tab = @import("settings/scripts.zig");
const file_assoc_tab = @import("settings/file_assoc.zig");
const webui_tab = @import("settings/webui.zig");

// Run an osascript "Run in Terminal" launch off the render thread so the frame
// never blocks waiting on Terminal.app. The script string is copied into a
// module-static buffer (guarded by `busy`) before spawning the detached thread —
// never hand the spawned thread a stack slice (see CLAUDE.md thread-safety notes).
const TerminalLauncher = struct {
    var busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    const LaunchState = enum(u8) { idle, launching, opened, failed };
    var status: std.atomic.Value(LaunchState) = std.atomic.Value(LaunchState).init(.idle);
    var script_buf: [512]u8 = undefined;
    var script_len: usize = 0;

    fn worker() void {
        defer busy.store(false, .release);
        const script = TerminalLauncher.script_buf[0..TerminalLauncher.script_len];
        var osa = @import("../core/io_global.zig").Child.init(
            &.{ "osascript", "-e", script },
            @import("../core/alloc.zig").allocator,
        );
        osa.stdout_behavior = .Ignore;
        osa.stderr_behavior = .Ignore;
        const term = osa.spawnAndWait() catch {
            status.store(.failed, .release);
            logs.pushLog("error", "deps", "Could not open Terminal to run dependency command", true);
            state.wakeUi();
            return;
        };
        const ok = switch (term) {
            .exited => |code| code == 0,
            else => false,
        };
        status.store(if (ok) .opened else .failed, .release);
        logs.pushLog(if (ok) "info" else "error", "deps", if (ok) "Dependency command sent to Terminal; waiting for installed dependency detection (Terminal runs separately)" else "Terminal did not accept dependency command", !ok);
        state.wakeUi();
    }

    /// Copy `script` into the static buffer and launch it on a detached thread.
    /// No-op (returns false) if a launch is already in flight.
    fn launch(script: []const u8) bool {
        if (busy.swap(true, .acquire)) return false;
        status.store(.launching, .release);
        const n = @min(script.len, TerminalLauncher.script_buf.len);
        @memcpy(TerminalLauncher.script_buf[0..n], script[0..n]);
        TerminalLauncher.script_len = n;
        const t = @import("../core/workers.zig").spawnLegacy(worker, .{}) catch {
            busy.store(false, .release);
            status.store(.failed, .release);
            return false;
        };
        @import("../core/workers.zig").release(t);
        return true;
    }
};

// ══════════════════════════════════════════════════════════
// Settings — lives inside the drawer as a tab
// ══════════════════════════════════════════════════════════
//
// Layout:
//   ┌──────────────┬────────────────────────────────────┐
//   │ search box   │  Big tab title                     │
//   │ ────────────┐│                                    │
//   │ ▎ Player    ││  ── Section header ─               │
//   │   Subtitles ││  [card with rows]                  │
//   │   AI        ││                                    │
//   │   ...       ││  Changes saved automatically.      │
//   └──────────────┴────────────────────────────────────┘
//
// Tokens:
//   spacing:  xs=4  sm=8  md=12  lg=16  xl=24  xxl=32
//   radius:   sm=4  md=8  lg=12   pill=99
//   font:     micro=10 small=11 body=13 title=15 display=22
// TODO: needs theme.spacing / theme.radius / theme.font_size namespaces

// File-local search query buffer for the left-nav search box.
var search_buf: [128]u8 = std.mem.zeroes([128]u8);
var search_len: usize = 0;

/// Lowercase, case-insensitive substring match used for nav filtering.
fn matchesSearch(label: []const u8) bool {
    if (search_len == 0) return true;
    const q = search_buf[0..search_len];
    // Case-insensitive contains: walk label and compare char-by-char
    if (q.len > label.len) return false;
    var i: usize = 0;
    while (i + q.len <= label.len) : (i += 1) {
        var j: usize = 0;
        var ok = true;
        while (j < q.len) : (j += 1) {
            const a = std.ascii.toLower(label[i + j]);
            const b = std.ascii.toLower(q[j]);
            if (a != b) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

/// Legacy entry point — opens the drawer to the Settings tab.
/// Called from places that set `settings_open = true`.
pub fn renderSettingsModal() void {
    if (!state.app.settings_open) return;
    // Redirect to the Settings page (works in both shell and legacy drawer).
    // No markConfigDirty here: merely opening settings changes no persisted
    // state, and the flag forced a needless full config rewrite to SQLite.
    state.navigateToTab(.Settings);
    state.app.settings_open = false;
}

/// Drawer-hosted settings content — rendered by drawer.zig
/// when drawer_tab == .Settings.
///
/// Two-column layout: left nav (search + vertical tab list) and right
/// pane (scrollable content, centered at max-width 720 px).
pub fn renderSettingsContent() void {
    // NOTE: Do NOT mark the config dirty here. Doing so unconditionally every
    // frame rewrites the entire config to SQLite every 2s while Settings is
    // open. markConfigDirty() is instead called at the specific control sites
    // below that actually mutate persisted state.

    // Outer horizontal split: left nav + right content.
    var outer = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .background = true,
        .color_fill = @import("color_compat.zig").wrap(theme.colors.bg_deep),
    });
    defer outer.deinit();

    // The settings state is restored on the background init worker. Do not
    // expose mutable defaults for the few milliseconds before that completes:
    // an immediate click could otherwise be overwritten by the disk value.
    if (!state.app.config_loaded.load(.acquire)) {
        components.emptyState(icons.tvg.lucide.loader, "Loading preferences", "Your saved settings will be ready in a moment");
        return;
    }

    // Responsive: collapse the left nav to an icon-only rail when the settings
    // region is narrow (small window / drawer / device). rect.w is 0 on the
    // very first paint → default to the expanded layout (no collapse flash).
    const region_w = outer.data().rect.w;
    const compact = region_w > 1 and region_w < 640;

    renderLeftNav(compact);
    renderRightPane(compact);
}

// ── Left navigator (search box + vertical tab list) ──

fn renderLeftNav(compact: bool) void {
    // Sidebar column — icon rail when compact, icon+label list otherwise.
    var nav = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = if (compact) 48 else 136, .h = 0 },
        .max_size_content = .{ .w = if (compact) 56 else 152, .h = std.math.floatMax(f32) },
        .expand = .vertical,
        .background = true,
        .color_fill = @import("color_compat.zig").wrap(theme.colors.bg_surface),
        .color_border = @import("color_compat.zig").wrap(theme.colors.border_subtle),
        .border = .{ .x = 0, .y = 0, .w = 1, .h = 0 },
        .padding = .{
            .x = if (compact) theme.spacing.xs else theme.spacing.sm,
            .y = theme.spacing.md,
            .w = if (compact) theme.spacing.xs else theme.spacing.sm,
            .h = theme.spacing.md,
        },
    });
    defer nav.deinit();

    // ── Search box ── (hidden in compact rail — no room for the field)
    if (!compact) {
        var sb_wrap = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.sm },
        });
        defer sb_wrap.deinit();
        _ = components.searchInput(@src(), &search_buf, &search_len, "Find…");
    }

    // Keep every category reachable without scrolling the settings themselves.
    var categories = dvui.scrollArea(@src(), .{ .horizontal = .none, .vertical = .auto, .vertical_bar = .auto_overlay }, .{ .expand = .both, .background = false });
    defer categories.deinit();
    // ── Tab list ──
    const nav_tabs = [_]struct {
        tab: state.SettingsTab,
        label: []const u8,
        icon: []const u8,
    }{
        .{ .tab = .General, .label = "General", .icon = icons.tvg.lucide.@"sliders-horizontal" },
        .{ .tab = .Profiles, .label = "Profiles", .icon = icons.tvg.lucide.@"users-round" },
        .{ .tab = .Playback, .label = "Playback", .icon = icons.tvg.lucide.play },
        .{ .tab = .Subtitles, .label = "Subtitles", .icon = icons.tvg.lucide.captions },
        .{ .tab = .Network, .label = "Network", .icon = icons.tvg.lucide.wifi },
        .{ .tab = .Storage, .label = "Storage", .icon = icons.tvg.lucide.@"hard-drive" },
        .{ .tab = .WebUi, .label = "Web UI", .icon = icons.tvg.lucide.globe },
        .{ .tab = .Scripts, .label = "AI & Scripts", .icon = icons.tvg.lucide.sparkles },
        .{ .tab = .AI, .label = "AI & Voice", .icon = icons.tvg.lucide.@"message-square-text" },
        .{ .tab = .LangLearn, .label = "Language", .icon = icons.tvg.lucide.languages },
        .{ .tab = .FileAssoc, .label = "File Types", .icon = icons.tvg.lucide.@"file-cog" },
        .{ .tab = .LiveTv, .label = "Live TV", .icon = icons.tvg.lucide.tv },
        .{ .tab = .About, .label = "About", .icon = icons.tvg.lucide.info },
    };

    var any_match = false;
    for (nav_tabs, 0..) |nt, idx| {
        if (comptime @import("../core/platform_pure.zig").mobile) {
            if (nt.tab == .WebUi or nt.tab == .Scripts or nt.tab == .FileAssoc) continue;
        }
        // Filter by search query — also surface the tab if a section/setting
        // inside it would match (cheap heuristic: also match against the tab
        // name itself). Compact rail ignores search (no field shown).
        if (!compact and !matchesSearch(nt.label) and !sectionMatchesSearch(nt.tab)) continue;
        any_match = true;
        navTabRow(nt.tab, nt.label, nt.icon, idx, compact);
    }

    if (!any_match) {
        _ = dvui.label(@src(), "No matches", .{}, .{
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_tertiary),
            .padding = .{
                .x = theme.spacing.md,
                .y = theme.spacing.sm,
                .w = theme.spacing.md,
                .h = theme.spacing.sm,
            },
        });
        if (dvui.button(@src(), "Clear search", .{}, .{
            .color_fill = @import("color_compat.zig").wrap(theme.transparent),
            .color_fill_hover = @import("color_compat.zig").wrap(theme.colors.bg_hover),
            .color_text = @import("color_compat.zig").wrap(theme.colors.accent),
            .border = dvui.Rect.all(0),
            .corners = dvui.CornerRect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
        })) {
            @memset(&search_buf, 0);
            search_len = 0;
        }
    }
}

/// Heuristic: do any well-known section titles within `tab` match the search?
/// Keeps tabs visible while typing without scanning every label.
fn sectionMatchesSearch(tab: state.SettingsTab) bool {
    if (search_len == 0) return true;
    const sections: []const []const u8 = switch (tab) {
        .General => &.{ "Interface", "Behavior", "TMDB", "Theme", "Scale", "Grid", "NSFW", "Seek Sync", "API Key", "Plugins", "Sources", "Content plugins" },
        .Playback => &.{ "Video Processing", "Audio Equalizer", "Playback Extras", "Prefetch", "Passthrough", "Exclusive", "Audio Output", "Device", "Streaming", "Shortcuts", "Filters", "Capture", "Hardware", "Decode", "Deband", "Interpolation", "Brightness", "Contrast", "Saturation", "Gamma", "Screenshot", "Auto-advance", "Resume" },
        .About => &.{ "About", "Version", "Update", "Credits", "License", "Donate", "Sponsors", "Links", "TMDB" },
        .Subtitles => &.{ "OpenSubtitles", "Subdl", "Language", "Search", "API Key", "Font", "Delay", "Whisper" },
        .Network => &.{ "Torrent", "Memory", "RAM", "Buffer", "Streaming", "Download", "Trackers", "Proxy", "Speed", "Limit", "Port", "Browser", "Engine", "Camoufox", "CloakBrowser", "Audiobookshelf", "Audiobook", "OPDS", "Reading", "Komga", "Kavita", "Calibre" },
        .Storage => &.{ "Download Path", "Watch History", "Database", "Cache", "Clear" },
        .WebUi => &.{ "Web UI", "Web Remote", "Remote", "Access", "Password", "Sessions", "Devices", "API Token", "Token", "Port", "Bind", "LAN", "Loopback" },
        .Scripts => &.{ "SponsorBlock", "AI Backend", "Watch Party", "Scripts", "Gemma", "Apple Intelligence", "Model", "Voice" },
        .AI => &.{ "Voice Backend", "STT", "TTS", "Whisper", "Kokoro", "MLX", "Sherpa", "Co-Watcher", "Models", "Dependencies" },
        .LangLearn => &.{ "Translate", "ASR", "Dubbing", "TTS", "Voice", "Speed", "Flashcard", "Transcribe" },
        .FileAssoc => &.{ "File Associations", "Default Handler", "Register", "Video", "Audio", "Torrent", "Playlist", "Comics" },
        .LiveTv => &.{ "Live TV", "IPTV", "Channels", "Playlist" },
        .Profiles => &.{ "Profiles", "Household", "Kid", "PIN", "Switch" },
    };
    for (sections) |s| if (matchesSearch(s)) return true;
    return false;
}

/// Render a single tab row in the left nav. Whole row is clickable; an icon
/// sits left of the label (label hidden in the compact rail, tooltip instead).
fn navTabRow(tab: state.SettingsTab, label: []const u8, icon: []const u8, id_extra: usize, compact: bool) void {
    const is_active = state.app.settings_tab == tab;
    var hovered: bool = false;

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = if (compact) 40 else 34 },
        .background = true,
        .color_fill = @import("color_compat.zig").wrap(if (is_active) theme.colors.bg_elevated else theme.transparent),
        .color_border = @import("color_compat.zig").wrap(if (is_active) theme.colors.accent else theme.transparent),
        .border = if (is_active and !compact) .{ .x = 2, .y = 0, .w = 0, .h = 0 } else dvui.Rect.all(0),
        .corners = dvui.CornerRect.all(theme.radius.sm),
        .padding = .{
            .x = if (compact) theme.spacing.xs else theme.spacing.sm,
            .y = theme.spacing.xs,
            .w = if (compact) theme.spacing.xs else theme.spacing.sm,
            .h = theme.spacing.xs,
        },
        .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
        .gravity_x = if (compact) 0.5 else 0,
    });
    defer row.deinit();

    // Whole-row click target. Keyboard: tab stop + Enter/Space activates.
    const rid = row.data().id;
    dvui.tabIndexSet(rid, null, null);
    const row_focused = dvui.focusedWidgetId() == rid;
    if (row_focused) {
        for (dvui.events()) |*e| {
            if (e.handled) continue;
            if (e.evt == .key and e.evt.key.action == .down and e.evt.key.matchBind("activate")) {
                e.handle(@src(), row.data());
                state.app.settings_tab = tab;
            }
        }
    }
    if (dvui.clicked(row.data(), .{ .hovered = &hovered })) {
        state.app.settings_tab = tab;
    }
    // Hover lift — must be applied AFTER hover is known; the ternary that
    // referenced `hovered` at box creation was provably dead code (boxes draw
    // their background inside dvui.box()).
    if (hovered and !is_active) row.data().options.color_fill = @import("color_compat.zig").wrap(theme.colors.bg_hover);
    row.drawBackground();
    if (row_focused) row.data().focusBorder();

    const fg = if (is_active) theme.colors.text_primary else theme.colors.text_secondary;

    dvui.icon(@src(), label, icon, .{}, .{
        .id_extra = id_extra,
        .gravity_y = 0.5,
        .color_text = @import("color_compat.zig").wrap(fg),
        .min_size_content = theme.iconSize(.sm),
        .max_size_content = .{ .w = 16, .h = 16 },
    });

    if (compact) {
        // Tooltip carries the label when the text is hidden. Use components.tipId
        // (offsets the src column per id_extra) — a raw dvui.tooltip sharing this
        // @src() across all 8 tabs would collide on one FloatingTooltip id.
        components.tipId(@src(), row.data().*, label, id_extra);
    } else {
        _ = dvui.label(@src(), "  {s}", .{label}, .{
            .id_extra = id_extra,
            .gravity_y = 0.5,
            .color_text = @import("color_compat.zig").wrap(fg),
        });
    }
}

// ── Right pane (scrollable content area) ──

fn renderRightPane(compact: bool) void {
    var pane = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = @import("color_compat.zig").wrap(theme.colors.bg_deep),
    });
    defer pane.deinit();

    // Crossfade tab switches — the inner settings navigation popped instantly
    // while every shell route fades with the same motion tokens.
    var tab_fade = dvui.animate(@src(), .{ .kind = .alpha, .duration = theme.motionDuration(theme.motion.base), .easing = theme.motion.enter }, .{
        .id_extra = @backingInt(state.app.settings_tab),
        .expand = .both,
    });
    defer tab_fade.deinit();

    // Per-tab scroll offset: without id_extra all 8 tabs shared ONE persisted
    // dvui scroll position, so switching from deep in Playback opened Storage
    // pre-scrolled to Playback's offset.
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .id_extra = @backingInt(state.app.settings_tab),
        .expand = .both,
        .background = false,
    });
    defer scroll.deinit();

    // Centred max-width container.
    var centre = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .gravity_x = 0.5,
    });
    defer centre.deinit();

    var content = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = 0, .h = 0 },
        .max_size_content = .{ .w = 840, .h = std.math.floatMax(f32) },
        .expand = .horizontal,
        // Compact: lg horizontal / md vertical instead of xl all-round, so the
        // pane breathes less and controls (segments) get more usable width.
        .padding = .{
            .x = theme.spacing.lg,
            .y = theme.spacing.md,
            .w = theme.spacing.lg,
            .h = theme.spacing.md,
        },
    });
    defer content.deinit();

    if (state.app.settings_tab == .About) bigTitle("About Opal");

    if (state.app.settings_tab == .General or
        state.app.settings_tab == .Playback or
        state.app.settings_tab == .Network or
        state.app.settings_tab == .AI or
        state.app.settings_tab == .Scripts or
        state.app.settings_tab == .About or
        state.app.settings_tab == .LiveTv) renderInstallActivity(compact);
    switch (state.app.settings_tab) {
        .General => renderGeneralTab(),
        .Playback => renderPlaybackTab(),
        .Network => network_tab.renderNetworkTab(),
        .Subtitles => subtitles_tab.renderSubtitlesTab(),
        .Storage => storage_tab.renderStorageTab(),
        .WebUi => webui_tab.renderWebUiTab(),
        .Scripts => scripts_tab.renderScriptsTab(),
        .AI => renderAIContentBody(),
        .LangLearn => lang_learn_tab.renderLangLearnTab(),
        .FileAssoc => file_assoc_tab.renderFileAssocTab(),
        .LiveTv => live_tv_tab.renderLiveTvTab(),
        .Profiles => @import("profiles_ui.zig").renderSettingsTab(),
        .About => renderAboutTab(),
    }

    // ── Footer: auto-save indicator ──
    // Config is auto-saved when a control mutates state (each control site
    // calls state.markConfigDirty), so a discreet always-visible message is
    // honest. No new state plumbing.
    {
        var footer = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = theme.spacing.xl, .w = 0, .h = 0 },
            .padding = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 },
        });
        defer footer.deinit();
        {
            var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            sp.deinit();
        }
        _ = dvui.label(@src(), "Changes saved automatically.", .{}, .{
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_tertiary),
            .gravity_y = 0.5,
        });
    }
}

/// Big display title rendered once at the top of each tab.
fn bigTitle(title: []const u8) void {
    var f = dvui.themeGet().font_body;
    // Compact: title size (17), not display (24). 24 overflowed the narrow
    // settings pane and clipped ("General Setti…"); 17 fits and reads cleaner.
    f.size = theme.font_size.title;
    _ = dvui.label(@src(), "{s}", .{title}, .{
        .color_text = @import("color_compat.zig").wrap(theme.colors.text_primary),
        .font = f,
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.md },
    });
}

/// Drawer-hosted AI tab (legacy .assistant route) — wraps the shared body in
/// its own header + scroll + centred column.
pub fn renderAIContent() void {
    // Scrollable content
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        .padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 },
        .background = true,
        .color_fill = @import("color_compat.zig").wrap(theme.colors.bg_surface),
    });
    defer scroll.deinit();

    // Centered max-width column so controls stay readable on wide windows.
    var centre = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_x = 0.5 });
    defer centre.deinit();
    var content = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .max_size_content = .{ .w = 760, .h = std.math.floatMax(f32) },
    });
    defer content.deinit();

    renderAIContentBody();
}

/// The AI & Voice control sections themselves — reused by BOTH the legacy
/// .assistant route (via renderAIContent) and the Settings › AI & Voice tab
/// (which supplies its own bigTitle + scroll + centred column, so this must
/// NOT add its own chrome). This is why the "Assistant" nav entry could move
/// into Settings without duplicating the page.
fn renderAIContentBody() void {
    // ── Voice Backend ──
    aiSectionWithIcon(icons.tvg.lucide.mic, "Voice Backend", "STT + TTS engine for mic / conversation mode", 24, @src());
    {
        const vb = @import("../services/voice_backend.zig");
        {
            var choices = dvui.flexbox(@src(), .{}, .{ .expand = .horizontal });
            defer choices.deinit();
            for (vb.allKinds(), 0..) |kind, i| {
                const name = switch (kind) {
                    .whisper_cpp_plus_say => "Whisper",
                    .sherpa_onnx => "Sherpa ONNX",
                    .apple_native => "Apple voice",
                    .speaches => "Speaches",
                    .mlx_whisper => "MLX Whisper",
                    .parakeet_tdt_v2 => "Parakeet v2 · EN",
                    .parakeet_tdt_v3 => "Parakeet v3",
                };
                var wd: dvui.WidgetData = undefined;
                if (dvui.button(@src(), name, .{}, .{
                    .id_extra = 4000 + i,
                    .data_out = &wd,
                    .color_fill = @import("color_compat.zig").wrap(if (kind == vb.active_kind) theme.colors.bg_elevated else theme.transparent),
                    .color_text = @import("color_compat.zig").wrap(if (kind == vb.active_kind) theme.colors.accent else theme.colors.text_secondary),
                    .padding = dvui.Rect.all(8),
                    .margin = dvui.Rect.all(2),
                    .corners = theme.dims.rad_sm,
                })) {
                    vb.active_kind = kind;
                    vb.voice_backend_explicit = true;
                    state.markConfigDirty();
                    state.showToast("Voice backend changed");
                }
                components.tipId(@src(), wd, vb.backendFor(kind).name, i);
            }
        }

        // MLX Whisper setup
        if (vb.active_kind == .mlx_whisper) {
            const deps = @import("../core/deps.zig");
            const dep_status = deps.check();

            var mlx_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .margin = .{ .y = 6 },
                .padding = .{ .x = 20 },
            });
            defer mlx_row.deinit();

            if (dep_status.mlx_whisper_model and dep_status.mlx_whisper_cli) {
                components.statusPill("Ready", .success);
            } else if (deps.mlx_whisper_downloading) {
                // Worker-written buffer — snapshot + validate so a torn multi-
                // byte write ("Installing uv…") can't hand dvui invalid UTF-8.
                const status_len = std.mem.indexOfScalar(u8, &deps.mlx_whisper_status, 0) orelse 0;
                var status_snap: [128]u8 = undefined;
                const status_txt = if (status_len > 0) @import("../core/text.zig").safeUtf8Buf(deps.mlx_whisper_status[0..status_len], &status_snap) else "Setting up…";
                _ = dvui.label(@src(), "{s}", .{status_txt}, .{
                    .color_text = @import("color_compat.zig").wrap(theme.colors.warning),
                    .gravity_y = 0.5,
                });
                components.pollRefresh(100_000);
            } else {
                if (dvui.button(@src(), "Set up (~1.6GB)", .{}, .{
                    .color_fill = @import("color_compat.zig").wrap(theme.colors.accent),
                    .color_text = @import("color_compat.zig").wrap(theme.colors.text_on_accent),
                    .border = dvui.Rect.all(0),
                    .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
                    .corners = theme.dims.rad_md,
                })) {
                    deps.fetchMlxWhisperModelAsync();
                    state.showToast("Setting up MLX Whisper (venv + model)…");
                }
            }
        }
    }

    // ── Kokoro Voice Picker ──
    {
        const deps = @import("../core/deps.zig");
        const vb = @import("../services/voice_backend.zig");
        if (deps.check().sherpa_kokoro_model) {
            aiSectionWithIcon(icons.tvg.lucide.@"audio-lines", "Kokoro Voice", "Pick a speaker ID from the Kokoro pack (0–53)", 18, @src());
            // Calm: spacing-only row, no card chrome. −/+ steppers are neutral
            // bg_elevated fills; Preview is the single accent affordance.
            var kcard = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .padding = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = theme.spacing.sm },
            });
            defer kcard.deinit();

            var label_buf: [32]u8 = undefined;
            const lbl = std.fmt.bufPrint(&label_buf, "sid = {d}", .{vb.kokoro_sid}) catch "sid = ?";
            _ = dvui.label(@src(), "{s}", .{lbl}, .{
                .color_text = @import("color_compat.zig").wrap(theme.colors.text_primary),
                .min_size_content = .{ .w = 80, .h = 0 },
                .gravity_y = 0.5,
            });

            if (dvui.button(@src(), "−", .{}, .{
                .color_fill = @import("color_compat.zig").wrap(theme.colors.bg_elevated),
                .color_text = @import("color_compat.zig").wrap(theme.colors.text_secondary),
                .border = dvui.Rect.all(0),
                .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
                .corners = theme.dims.rad_sm,
                .margin = .{ .w = theme.spacing.xs },
                .gravity_y = 0.5,
            })) {
                if (vb.kokoro_sid > 0) {
                    vb.kokoro_sid -= 1;
                    state.markConfigDirty();
                }
            }
            if (dvui.button(@src(), "+", .{}, .{
                .color_fill = @import("color_compat.zig").wrap(theme.colors.bg_elevated),
                .color_text = @import("color_compat.zig").wrap(theme.colors.text_secondary),
                .border = dvui.Rect.all(0),
                .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
                .corners = theme.dims.rad_sm,
                .margin = .{ .w = theme.spacing.xs },
                .gravity_y = 0.5,
            })) {
                if (vb.kokoro_sid < 53) {
                    vb.kokoro_sid += 1;
                    state.markConfigDirty();
                }
            }
            {
                var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
                sp.deinit();
            }
            if (dvui.button(@src(), "Preview", .{}, .{
                .color_fill = @import("color_compat.zig").wrap(theme.colors.accent),
                .color_text = @import("color_compat.zig").wrap(theme.colors.text_on_accent),
                .border = dvui.Rect.all(0),
                .padding = .{ .x = theme.spacing.lg, .y = theme.spacing.xs, .w = theme.spacing.lg, .h = theme.spacing.xs },
                .corners = theme.dims.rad_md,
                .gravity_y = 0.5,
            })) {
                const b = vb.active();
                b.speak("Opal voice preview.");
            }
        }
    }

    // ── Co-Watcher ── (voice-mode feature, so it lives with the voice engine.
    // The language-learning rows that used to sit here duplicated the whole
    // Settings › Language tab with drifted hint copy — they now live ONLY
    // there, one pointer row below.)

    // Proactive Co-Watcher sensitivity — the AI may speak ONE short, spoiler-
    // safe remark about what is on screen when you pause or rewind in voice
    // mode. Quiet by default; this control just assigns the module var.
    aiSectionWithIcon(icons.tvg.lucide.@"message-square-text", "Co-Watcher", "The AI comments while you watch (voice mode)", 60, @src());

    _ = dvui.label(@src(), "AI comments on what you missed when you pause or rewind (voice mode)", .{}, .{
        .id_extra = 651,
        .color_text = @import("color_compat.zig").wrap(theme.colors.text_tertiary),
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.sm },
    });
    {
        const co_watch = @import("../services/co_watch.zig");
        const cw_labels = [_][]const u8{ "Off", "Quiet", "Balanced", "Chatty" };
        const sel: usize = switch (co_watch.sensitivity) {
            .off => 0,
            .quiet => 1,
            .balanced => 2,
            .chatty => 3,
        };
        if (components.segment(@src(), &cw_labels, sel)) |clicked| {
            co_watch.sensitivity = switch (clicked) {
                0 => .off,
                1 => .quiet,
                2 => .balanced,
                else => .chatty,
            };
            state.markConfigDirty();
        }
    }

    // Pointer to the single home of the language-learning controls.
    _ = dvui.label(@src(), "Subtitle translation, ASR, dubbing, and TTS voice live in Settings › Language.", .{}, .{
        .color_text = @import("color_compat.zig").wrap(theme.colors.text_tertiary),
        .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 },
    });

    // ── Models Management ──
    aiSectionWithIcon(icons.tvg.lucide.@"hard-drive", "Models & Dependencies", "Install, update, or remove AI models", 80, @src());
    // Opens the "Setup" checklist modal on demand. This used to auto-pop at
    // first run; it now lives here so it never nags at startup.
    if (dvui.button(@src(), "Open setup checklist…", .{}, .{
        .color_fill = @import("color_compat.zig").wrap(theme.colors.bg_elevated),
        .color_text = @import("color_compat.zig").wrap(theme.colors.text_secondary),
        .corners = theme.dims.rad_sm,
        .padding = .{ .x = 12, .y = 7, .w = 12, .h = 7 },
        .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.sm },
    })) {
        state.app.deps_modal_open = true;
    }
    {
        const deps = @import("../core/deps.zig");
        const ds = deps.check();
        // Download sizes reflect the pinned upstream release assets.
        if (modelRow("Whisper Tiny (75MB)", icons.tvg.lucide.@"audio-waveform", ds.whisper_model, deps.whisper_model_downloading.load(.acquire), 5000, @src())) {
            deps.fetchWhisperModelAsync();
            state.showToast("Downloading Whisper Tiny (75 MB)");
        }
        if (modelRow("Sherpa STT (113MB)", icons.tvg.lucide.mic, ds.sherpa_model, deps.sherpa_model_downloading.load(.acquire), 5001, @src())) {
            deps.fetchSherpaWhisperAsync();
            state.showToast("Downloading Sherpa STT (113 MB)");
        }
        if (modelRow("Piper TTS (64MB)", icons.tvg.lucide.@"volume-2", ds.sherpa_tts_model, deps.sherpa_tts_downloading.load(.acquire), 5002, @src())) {
            deps.fetchSherpaTtsAsync();
            state.showToast("Downloading Piper TTS (64 MB)");
        }
        if (modelRow("Kokoro TTS (305MB)", icons.tvg.lucide.@"audio-lines", ds.sherpa_kokoro_model, deps.sherpa_kokoro_downloading.load(.acquire), 5003, @src())) {
            deps.fetchSherpaKokoroAsync();
            state.showToast("Downloading Kokoro TTS (305 MB)");
        }
        if (modelRow("Stream ASR (296MB)", icons.tvg.lucide.radio, ds.sherpa_stream_model, deps.sherpa_stream_downloading.load(.acquire), 5004, @src())) {
            deps.fetchSherpaStreamAsync();
            state.showToast("Downloading Stream ASR (296 MB)");
        }
        // MLX Whisper (~1.6GB) — custom row with live status
        {
            const mlx_installed = ds.mlx_whisper_model and ds.mlx_whisper_cli;
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = 5005,
                .expand = .horizontal,
                .padding = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = theme.spacing.sm },
            });
            defer row.deinit();

            dvui.icon(@src(), "", icons.tvg.lucide.cpu, .{}, .{
                .id_extra = 5015,
                .color_text = @import("color_compat.zig").wrap(if (mlx_installed) theme.colors.accent else mutedText()),
                .gravity_y = 0.5,
                .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
            });
            _ = dvui.label(@src(), "MLX Whisper (1.6GB)", .{}, .{
                .id_extra = 5025,
                .color_text = @import("color_compat.zig").wrap(labelText()),
                .gravity_y = 0.5,
            });
            {
                var sp = dvui.box(@src(), .{}, .{ .id_extra = 5035, .expand = .horizontal });
                sp.deinit();
            }

            if (deps.mlx_whisper_downloading) {
                const slen = std.mem.indexOfScalar(u8, &deps.mlx_whisper_status, 0) orelse 0;
                var ssnap: [128]u8 = undefined;
                const stxt = if (slen > 0) @import("../core/text.zig").safeUtf8Buf(deps.mlx_whisper_status[0..slen], &ssnap) else "Setting up…";
                _ = dvui.label(@src(), "{s}", .{stxt}, .{
                    .id_extra = 5045,
                    .color_text = @import("color_compat.zig").wrap(theme.colors.warning),
                    .gravity_y = 0.5,
                });
                components.pollRefresh(100_000);
            } else if (mlx_installed) {
                components.statusPill("Installed", .success);
            } else {
                components.statusPill("Not installed", .info);
            }
        }

        // NVIDIA Parakeet TDT — sherpa-onnx int8 exports (URLs verified
        // against the k2-fsa release assets). The largest Parakeet TDT with a
        // sherpa export is 0.6B; there is no 1.1b export.
        parakeetModelRow("Parakeet TDT 0.6B v2 · English (480MB)", ds.parakeet_v2_model, deps.parakeet_v2_downloading.load(.acquire), false, 5006);
        parakeetModelRow("Parakeet TDT 0.6B v3 · 25 languages (490MB)", ds.parakeet_v3_model, deps.parakeet_v3_downloading.load(.acquire), true, 5007);
    }
    _ = dvui.label(@src(), "Model operation: HTTPS curl › verify staged download › extract (archive models). MLX Whisper also installs uv, a Python venv, and mlx-whisper.", .{}, .{ .color_text = @import("color_compat.zig").wrap(theme.colors.text_tertiary) });
}

/// One NVIDIA Parakeet model row: name + Installed pill / live download
/// spinner / Download button. Requires the sherpa-onnx CLI (same engine the
/// sherpa rows use).
fn parakeetModelRow(comptime name: []const u8, installed: bool, downloading: bool, v3: bool, id_extra: usize) void {
    const deps = @import("../core/deps.zig");
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .padding = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = theme.spacing.sm },
    });
    defer row.deinit();

    dvui.icon(@src(), "", icons.tvg.lucide.@"audio-waveform", .{}, .{
        .id_extra = id_extra + 10,
        .color_text = @import("color_compat.zig").wrap(if (installed) theme.colors.accent else theme.colors.text_secondary),
        .min_size_content = theme.iconSize(.sm),
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
    });
    _ = dvui.label(@src(), name, .{}, .{
        .id_extra = id_extra + 20,
        .color_text = @import("color_compat.zig").wrap(theme.colors.text_primary),
        .gravity_y = 0.5,
    });
    {
        var sp = dvui.box(@src(), .{}, .{ .id_extra = id_extra + 30, .expand = .horizontal });
        sp.deinit();
    }
    if (downloading) {
        dvui.spinner(@src(), .{
            .id_extra = id_extra + 40,
            .color_text = @import("color_compat.zig").wrap(theme.colors.warning),
            .min_size_content = theme.iconSize(.sm),
            .gravity_y = 0.5,
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        });
        _ = dvui.label(@src(), "Downloading…", .{}, .{
            .id_extra = id_extra + 50,
            .color_text = @import("color_compat.zig").wrap(theme.colors.warning),
            .gravity_y = 0.5,
        });
    } else if (installed) {
        components.statusPill("Installed", .success);
    } else {
        if (dvui.button(@src(), "Download", .{}, .{
            .id_extra = id_extra + 60,
            .color_fill = @import("color_compat.zig").wrap(theme.colors.accent),
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_on_accent),
            .border = dvui.Rect.all(0),
            .corners = theme.dims.rad_sm,
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
            .gravity_y = 0.5,
        })) {
            deps.fetchParakeetAsync(v3);
            state.showToast("Downloading Parakeet TDT — watch the row for progress");
        }
    }
}

// ══════════════════════════════════════════════════════════
// Design System Helpers
// ══════════════════════════════════════════════════════════
//
// These keep their original signatures so the per-tab bodies stay
// unchanged, but internally they now route to the canonical tokens
// (theme.colors.text_primary, bg_surface, border_subtle, …) and / or
// delegate to components.zig.

// Token accessors — runtime-resolved from the active theme so the surface
// stays coherent with the rest of the calmed UI. Card chrome is gone
// (sections are defined by whitespace + sectionHeader); these two map the
// former muted/label colors onto the canonical text ramp.
inline fn mutedText() dvui.Color {
    return theme.colors.text_secondary;
}
pub inline fn labelText() dvui.Color {
    return theme.colors.text_primary;
}

/// Section header used inside a tab content pane.  Wraps
/// `components.sectionHeader` (uppercase, tracked-out, text_tertiary)
/// and renders an optional subtitle beneath it.  Spacing: `xl` top
/// margin so consecutive sections sit on the same rhythm as
/// the spec's "between any two sectionHeader → row group: theme.spacing.xl".
// NOTE: call sites pass an id_extra, but the values aren't unique within a tab
// (e.g. two "25"s both live in renderPlaybackTab), so they can't reliably
// disambiguate. Like components.divider()/sectionHeader(), a monotonic seq is
// the robust way to keep each header's wrap box + subtitle label unique.
var sectionheader_seq: usize = 0;

/// Reset the per-frame id sequence. Called from main.zig appFrame alongside
/// components.beginFrame() — see the rationale there (never-reset counters
/// force a first-frame dvui refresh every frame → permanent full-rate repaint).
pub fn beginFrame() void {
    sectionheader_seq = 0;
}

/// Open a URL in the system browser (macOS `open`, Windows `cmd /c start`,
/// elsewhere `xdg-open`). Public so other UI modules (e.g. the top-nav Donate
/// button in header.zig) reuse this one launcher instead of re-rolling it.
pub fn openExternal(url: []const u8) void {
    if (comptime @import("builtin").abi.isAndroid()) {
        // ACTION_VIEW via SDL; http(s) only, NUL-terminated copy.
        const link = @import("../mobile/android_pure.zig").externalUrl(url) orelse return;
        var z: [2100]u8 = undefined;
        @memcpy(z[0..link.len], link);
        z[link.len] = 0;
        _ = c.sdl.SDL_OpenURL(@ptrCast(&z));
        return;
    }
    const io = @import("../core/io_global.zig");
    // Named locals (not prong temporaries): Child.init stores the slice and
    // spawn() reads it later, so argv must outlive the switch expression.
    // The empty "" fills start's window-title slot so the URL isn't eaten by it.
    const win_argv = [_][]const u8{ "cmd", "/c", "start", "", url };
    const mac_argv = [_][]const u8{ "open", url };
    const xdg_argv = [_][]const u8{ "xdg-open", url };
    const argv: []const []const u8 = switch (@import("builtin").os.tag) {
        .macos => &mac_argv,
        .windows => &win_argv,
        else => &xdg_argv,
    };
    var child = io.Child.init(argv, @import("../core/alloc.zig").allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch {
        state.showToast("Could not open the link");
        return;
    };
    _ = child.wait() catch {}; // `open` returns immediately after handing off
}

/// About-section link chip: icon + label, opens `url` externally on click.
fn aboutLink(id: usize, icon: []const u8, label: []const u8, url: []const u8, icon_color: dvui.Color) void {
    var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id,
        .background = true,
        .color_fill = @import("color_compat.zig").wrap(theme.colors.bg_surface),
        .corners = dvui.CornerRect.all(theme.radius.pill),
        .padding = .{ .x = theme.spacing.md, .y = 4, .w = theme.spacing.md, .h = 4 },
        .margin = .{ .x = 0, .y = 2, .w = theme.spacing.sm, .h = 2 },
        .gravity_y = 0.5,
    });
    defer chip.deinit();
    var hovered = false;
    const clicked = dvui.clicked(chip.data(), .{ .hovered = &hovered });
    if (hovered) chip.data().options.color_fill = @import("color_compat.zig").wrap(theme.colors.bg_hover);
    chip.drawBackground();

    dvui.icon(@src(), "about-link", icon, .{}, .{
        .id_extra = id,
        .color_text = @import("color_compat.zig").wrap(icon_color),
        .min_size_content = .{ .w = 13, .h = 13 },
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = theme.spacing.xs, .h = 0 },
    });
    _ = dvui.label(@src(), "{s}", .{label}, .{
        .id_extra = id,
        .color_text = @import("color_compat.zig").wrap(theme.colors.text_secondary),
        .gravity_y = 0.5,
    });

    if (clicked) openExternal(url);
}
pub fn sectionHeader(comptime title: []const u8, comptime subtitle: []const u8, id_extra: usize, src: std.builtin.SourceLocation) void {
    sectionheader_seq +%= 1;
    var wrap = dvui.box(src, .{ .dir = .vertical }, .{ .id_extra = id_extra, .expand = .horizontal });
    defer wrap.deinit();
    if (state.app.settings_tab == .About) {
        components.sectionHeader(title);
        if (subtitle.len > 0) dvui.labelNoFmt(@src(), subtitle, .{}, .{ .color_text = @import("color_compat.zig").wrap(theme.colors.text_tertiary), .margin = .{ .h = theme.spacing.sm } });
        return;
    }
    const glyph = if (std.mem.indexOf(u8, title, "Audio") != null) icons.tvg.lucide.volume else if (std.mem.indexOf(u8, title, "Video") != null) icons.tvg.lucide.film else if (std.mem.indexOf(u8, title, "Plugins") != null) icons.tvg.lucide.puzzle else if (std.mem.indexOf(u8, title, "Interface") != null) icons.tvg.lucide.palette else if (std.mem.indexOf(u8, title, "Streaming") != null) icons.tvg.lucide.wifi else if (std.mem.indexOf(u8, title, "Shortcuts") != null) icons.tvg.lucide.keyboard else if (std.mem.indexOf(u8, title, "Capture") != null) icons.tvg.lucide.camera else icons.tvg.lucide.@"sliders-horizontal";
    @import("service_surfaces.zig").section(@src(), title, subtitle, glyph);
}

/// Inline single-line label used above a control row.  Color is
/// `text_secondary`.  Spacing: small top / bottom rhythm so adjacent
/// rows don't crowd.
pub fn settingRow(comptime label_text_str: []const u8, id_extra: usize, src: std.builtin.SourceLocation) void {
    _ = dvui.label(src, label_text_str, .{}, .{
        .id_extra = id_extra,
        .color_text = @import("color_compat.zig").wrap(theme.colors.text_secondary),
        .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = theme.spacing.xs },
    });
}

fn aiSectionWithIcon(icon_data: anytype, comptime title: []const u8, comptime subtitle: []const u8, id_extra: usize, src: std.builtin.SourceLocation) void {
    var wrap = dvui.box(src, .{ .dir = .vertical }, .{ .id_extra = id_extra + 900, .expand = .horizontal });
    defer wrap.deinit();
    @import("service_surfaces.zig").section(@src(), title, subtitle, icon_data);
}

fn modelRow(comptime name: []const u8, icon_data: anytype, installed: bool, downloading: bool, id_extra: usize, src: std.builtin.SourceLocation) bool {
    // Calm: a spacing-only row (no card fill / border / radius). The icon
    // tint + a text-only status pill carry the state.
    var row = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .padding = dvui.Rect.all(10),
        .margin = .{ .y = 3, .h = 3 },
        .background = true,
        .color_fill = @import("color_compat.zig").wrap(theme.colors.bg_surface),
        .border = dvui.Rect.all(1),
        .color_border = @import("color_compat.zig").wrap(theme.colors.border_subtle),
        .corners = dvui.CornerRect.all(8),
    });
    defer row.deinit();

    // Icon
    dvui.icon(src, "", icon_data, .{}, .{
        .id_extra = id_extra + 10,
        .color_text = @import("color_compat.zig").wrap(if (installed) theme.colors.accent else mutedText()),
        .gravity_y = 0.5,
        .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
    });
    // Name
    _ = dvui.label(src, name, .{}, .{
        .id_extra = id_extra + 20,
        .color_text = @import("color_compat.zig").wrap(labelText()),
        .gravity_y = 0.5,
    });
    // Spacer
    {
        var sp = dvui.box(src, .{}, .{ .id_extra = id_extra + 30, .expand = .horizontal });
        sp.deinit();
    }
    // Status — text-only pill.
    if (downloading) {
        components.statusPill("Downloading", .warn);
    } else if (installed) {
        components.statusPill("Installed", .success);
    } else {
        return dvui.button(src, "Download", .{}, .{
            .id_extra = id_extra + 60,
            .color_fill = @import("color_compat.zig").wrap(theme.colors.accent),
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_on_accent),
            .border = dvui.Rect.all(0),
            .corners = theme.dims.rad_sm,
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
            .gravity_y = 0.5,
        });
    }
    return false;
}

// ── Shared selects (used by both the AI drawer tab and the Language tab) ──
// All preserve their exact persistence behavior — they write the same buffers
// / fields and call markConfigDirty on change, just through the calm
// components.segment() instead of a row of filled pills.

const translate_codes = [_][]const u8{ "en", "es", "fr", "de", "it", "pt", "ru", "ja", "ko", "zh-CN", "ar", "hi", "tr", "vi" };
const translate_labels = [_][]const u8{ "EN", "ES", "FR", "DE", "IT", "PT", "RU", "JA", "KO", "ZH", "AR", "HI", "TR", "VI" };
const tts_voices = [_][]const u8{ "Bella", "Jasper", "Luna", "Bruno", "Rosie", "Hugo", "Kiki", "Leo" };
const tts_speeds = [_]f32{ 0.5, 0.75, 1.0, 1.25, 1.5 };
const tts_speed_labels = [_][]const u8{ "0.5x", "0.75x", "1.0x", "1.25x", "1.5x" };

/// Translate-to language picker — writes the code into `buf`/`len`.
pub fn langSegment(buf: []u8, len: *usize, id_base: usize) void {
    _ = id_base;
    const current = buf[0..len.*];
    var sel: usize = 0;
    for (translate_codes, 0..) |code, idx| {
        if (std.mem.eql(u8, current, code)) {
            sel = idx;
            break;
        }
    }
    if (components.segment(@src(), &translate_labels, sel)) |clicked| {
        const code = translate_codes[clicked];
        @memcpy(buf[0..code.len], code);
        len.* = code.len;
        state.markConfigDirty();
    }
}

/// TTS voice picker — writes the voice name into tts_voice_buf/len.
pub fn ttsVoiceSegment(id_base: usize) void {
    _ = id_base;
    const current = state.app.tts_voice_buf[0..state.app.tts_voice_len];
    var sel: usize = 0;
    for (tts_voices, 0..) |voice, idx| {
        if (std.mem.eql(u8, current, voice)) {
            sel = idx;
            break;
        }
    }
    if (components.segment(@src(), &tts_voices, sel)) |clicked| {
        const voice = tts_voices[clicked];
        @memcpy(state.app.tts_voice_buf[0..voice.len], voice);
        state.app.tts_voice_len = voice.len;
        state.markConfigDirty();
    }
}

/// TTS speech-speed picker — writes the float into tts_speed.
pub fn ttsSpeedSegment(id_base: usize) void {
    _ = id_base;
    var sel: usize = 0;
    for (tts_speeds, 0..) |spd, idx| {
        if (@abs(state.app.tts_speed - spd) < 0.05) {
            sel = idx;
            break;
        }
    }
    if (components.segment(@src(), &tts_speed_labels, sel)) |clicked| {
        state.app.tts_speed = tts_speeds[clicked];
        state.markConfigDirty();
    }
}

/// Installation logs are redacted at the ring seam. Show recent outcomes here
/// so completion/failure remains visible even after a short-lived toast fades.
fn renderInstallActivity(compact: bool) void {
    _ = compact;
    const source_repo = @import("../services/plugin_repo.zig");
    if (source_repo.status.load(.acquire) != .err) return;
    var activity = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = @import("color_compat.zig").wrap(theme.colors.bg_surface),
        .corners = theme.dims.rad_sm,
        .padding = dvui.Rect.all(theme.spacing.sm),
    });
    defer activity.deinit();
    components.bodyText(@src(), "Couldn't refresh sources. Previously available sources can still be used.", theme.colors.warning);
    var actions = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal });
    defer actions.deinit();
    if (components.actionButton(@src(), "Retry", .secondary, 11201)) _ = source_repo.refresh();
    if (components.actionButton(@src(), "View details", .secondary, 11202)) state.navigateToTab(.Logs);
}

fn renderGeneralTab() void {
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
                state.app.ui_scale = @import("../core/display_info.zig").defaultScale(dvui.windowNaturalScale());
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
        const vis = @import("../player/visualizer_pure.zig");
        const player = @import("../player/player.zig");
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
            .color_fill = @import("color_compat.zig").wrap(theme.transparent),
            .color_fill_hover = @import("color_compat.zig").wrap(theme.colors.bg_hover),
            .color_text = @import("color_compat.zig").wrap(theme.colors.accent),
            .border = dvui.Rect.all(0),
            .corners = dvui.CornerRect.all(theme.radius.sm),
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
        })) {
            @import("../services/activity.zig").clearTasteData();
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
            .color_fill = @import("color_compat.zig").wrap(theme.colors.bg_elevated),
            .color_border = @import("color_compat.zig").wrap(theme.colors.border_subtle),
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_primary),
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
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_tertiary),
            .margin = .{ .x = 0, .y = 4, .w = 0, .h = 0 },
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
            .color_fill = @import("color_compat.zig").wrap(theme.colors.bg_elevated),
            .color_border = @import("color_compat.zig").wrap(theme.colors.border_subtle),
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_primary),
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
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_tertiary),
            .margin = .{ .x = 0, .y = 4, .w = 0, .h = 0 },
        });
    }
    sectionHeader("Plugins", "Manage sources and content plugins", 9, @src());
    {
        var links = dvui.flexbox(@src(), .{}, .{ .expand = .horizontal });
        defer links.deinit();
        const controls = @import("browse_filters.zig");
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

fn renderAboutTab() void {
    // Extracted from the Playback tab into its own page. btn_* mirror the
    // Playback tab's local button tokens the block references.
    const btn_inactive = theme.colors.bg_elevated;

    // ── About / Updater ── (no card chrome; whitespace + the brand row)
    sectionHeader("About", "Version, updates, credits & support", 25, @src());
    {
        const updater = @import("../services/updater.zig");
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
                .source = .{ .imageFile = .{ .bytes = @embedFile("opal_logo_64.png"), .name = "opal-about" } },
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
                .color_text = @import("color_compat.zig").wrap(theme.colors.text_primary),
                .font = wmf,
                .gravity_y = 0.5,
            });
            // Tagline.
            _ = dvui.label(@src(), "Play everything", .{}, .{
                .color_text = @import("color_compat.zig").wrap(theme.colors.text_secondary),
                .gravity_y = 0.5,
                .margin = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 },
            });
        }

        // Positioning line + the short pitch (mirrors the README hero).
        _ = dvui.label(@src(), "The evolved media player for the next decades of entertainment.", .{}, .{
            .id_extra = 2505,
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_primary),
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 2 },
        });
        _ = dvui.label(@src(), "Local-first, an mpv heart, and an AI that never leaves your machine.\nNo accounts · no telemetry · no cloud — your history is a SQLite file you own.", .{}, .{
            .id_extra = 2506,
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_secondary),
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = theme.spacing.sm },
        });

        // Version row
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer row.deinit();
            _ = dvui.label(@src(), "Version", .{}, .{ .color_text = @import("color_compat.zig").wrap(labelText()), .gravity_y = 0.5 });
            _ = dvui.label(@src(), "  v{s}", .{updater.APP_VERSION}, .{ .id_extra = 2510, .color_text = @import("color_compat.zig").wrap(theme.colors.text_secondary), .gravity_y = 0.5 });
            {
                var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
                spacer.deinit();
            }
            if (update.is_checking) {
                _ = dvui.label(@src(), "Checking…", .{}, .{ .id_extra = 2511, .color_text = @import("color_compat.zig").wrap(theme.colors.text_secondary), .gravity_y = 0.5 });
                components.pollRefresh(100_000);
            } else if (dvui.button(@src(), "Check for Updates", .{}, .{
                .id_extra = 2512,
                .color_fill = @import("color_compat.zig").wrap(btn_inactive),
                .color_text = @import("color_compat.zig").wrap(theme.colors.text_primary),
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
            _ = dvui.label(@src(), "Welcome guide", .{}, .{ .id_extra = 2521, .color_text = @import("color_compat.zig").wrap(labelText()), .gravity_y = 0.5 });
            {
                var spacer = dvui.box(@src(), .{}, .{ .id_extra = 2522, .expand = .horizontal });
                spacer.deinit();
            }
            if (dvui.button(@src(), "Replay Guide", .{}, .{
                .id_extra = 2523,
                .color_fill = @import("color_compat.zig").wrap(btn_inactive),
                .color_text = @import("color_compat.zig").wrap(theme.colors.text_primary),
                .border = dvui.Rect.all(0),
                .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
                .corners = theme.dims.rad_md,
            })) {
                @import("onboarding.zig").replay();
            }
        }

        // Credits line — who built it, under what terms.
        _ = dvui.label(@src(), "Crafted by Palash Deb (@debpalash) · free and open source, GPL-3.0", .{}, .{
            .id_extra = 2530,
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_tertiary),
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
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_tertiary),
            .margin = .{ .x = 0, .y = 2, .w = 0, .h = 0 },
        });

        // Credits — the shoulders this stands on, plus TMDB's required notice.
        components.divider();
        _ = dvui.label(@src(), "Built with Zig · dvui · mpv · SDL2 · libtorrent · SQLite + sqlite-vec · ONNX Runtime · whisper.cpp", .{}, .{
            .id_extra = 2546,
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_secondary),
        });
        _ = dvui.label(@src(), "Catalog feeds from Cinemeta. Optional metadata from TMDB — this product uses the TMDB API but is not endorsed or certified by TMDB.", .{}, .{
            .id_extra = 2547,
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_tertiary),
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

fn renderPlaybackTab() void {
    // One accent, token fills. `btn_*` kept for the few primary actions that
    // remain in this tab (download / install). Inactive segments are handled
    // by components.segment() now.
    const btn_active = theme.colors.accent;
    const btn_inactive = theme.colors.bg_elevated;
    const btn_text_active = theme.colors.text_on_accent;

    // ── Video Processing ──
    sectionHeader("Video Processing", "GPU acceleration and image quality", 20, @src());

    // HW Decode — neutral toggle row; applies mpv option on change.
    {
        const before = state.app.hwdec_enabled;
        components.toggleRow(@src(), "Hardware Decoding", "GPU video decode (auto)", &state.app.hwdec_enabled);
        if (state.app.hwdec_enabled != before) {
            for (state.app.players.items) |p| {
                _ = c.mpv.mpv_set_option_string(p.mpv_ctx, "hwdec", @import("../player/hwdec_feedback_pure.zig").optionValue(state.app.hwdec_enabled, @import("builtin").abi.isAndroid(), false));
            }
            state.markConfigDirty();
        }
    }

    // Deband — neutral toggle row; applies mpv option on change.
    {
        const before = state.app.deband_enabled;
        components.toggleRow(@src(), "Deband Filter", "Smooth color banding", &state.app.deband_enabled);
        if (state.app.deband_enabled != before) {
            for (state.app.players.items) |p| {
                _ = c.mpv.mpv_set_option_string(p.mpv_ctx, "deband", if (state.app.deband_enabled) "yes" else "no");
            }
            state.markConfigDirty();
        }
    }

    // Auto-Advance toggle row — pure bool flip, no side effects.
    {
        const before = state.app.auto_advance;
        components.toggleRow(@src(), "Auto-Advance", "Play next on end", &state.app.auto_advance);
        if (state.app.auto_advance != before) state.markConfigDirty();
    }

    // ── Skip intros & credits ── (any media). Sources, by priority:
    // anime-skip.com crowdsourced markers (anime) > chapter titles > intros /
    // credits matched across a season's local episodes by audio fingerprint.
    // Replaces the old anime-only "Auto-Skip (Anime)" toggle; its config key
    // anime_skip_enabled is kept in sync (= mode != Off) for older builds.
    sectionHeader("Skip Intros & Credits", "anime-skip.com, chapter titles, or matched across a season's episodes", 24, @src());
    settingRow("Skip intros & credits", 251, @src());
    {
        const skip_policy = @import("../services/skip_policy_pure.zig");
        const opts = [_][]const u8{ skip_policy.modeLabel(.off), skip_policy.modeLabel(.button), skip_policy.modeLabel(.auto) };
        if (components.segment(@src(), &opts, @min(state.app.skip_mode, 2))) |picked| {
            const m = skip_policy.modeFromInt(@intCast(picked));
            if (@backingInt(m) != state.app.skip_mode) {
                state.app.skip_mode = @backingInt(m);
                state.app.skip_mode_loaded = true;
                state.app.anime_skip_enabled = skip_policy.legacyEnabled(m);
                state.markConfigDirty();
            }
        }
    }
    if (state.app.skip_mode == 2) {
        {
            const before = state.app.anime_skip_intro;
            components.toggleRow(@src(), "Skip Intro", "Opening / OP", &state.app.anime_skip_intro);
            if (state.app.anime_skip_intro != before) state.markConfigDirty();
        }
        {
            const before = state.app.anime_skip_recap;
            components.toggleRow(@src(), "Skip Recap", "\"Previously on…\" segments", &state.app.anime_skip_recap);
            if (state.app.anime_skip_recap != before) state.markConfigDirty();
        }
        {
            const before = state.app.anime_skip_credits;
            components.toggleRow(@src(), "Skip Credits", "Ending / ED (otherwise a Next episode button)", &state.app.anime_skip_credits);
            if (state.app.anime_skip_credits != before) state.markConfigDirty();
        }
        {
            const before = state.app.anime_skip_preview;
            components.toggleRow(@src(), "Skip Preview", "Next-episode preview", &state.app.anime_skip_preview);
            if (state.app.anime_skip_preview != before) state.markConfigDirty();
        }
    }

    // Video Scaler — segment.
    settingRow("Video Scaler", 250, @src());
    {
        const sn = [_][]const u8{ "EWA Lanczos (HQ)", "Bilinear (Fast)", "Spline36" };
        const sv = [_][]const u8{ "ewa_lanczossharp", "bilinear", "spline36" };
        const sel: usize = @intCast(@min(state.app.video_scaler, sn.len - 1));
        if (components.segment(@src(), &sn, sel)) |clicked| {
            state.app.video_scaler = @intCast(clicked);
            for (state.app.players.items) |p| {
                _ = c.mpv.mpv_set_option_string(p.mpv_ctx, "scale", @ptrCast(sv[clicked].ptr));
            }
            state.markConfigDirty();
        }
    }

    // ── Audio Equalizer ──
    sectionHeader("Audio Equalizer", "Quick presets for different content types", 22, @src());
    {
        const av_pure = @import("../player/av_pure.zig");
        const en = [_][]const u8{ "Flat", "Bass+", "Voice", "Cinema", "Loud" };
        const sel: usize = @min(state.app.eq_preset, en.len - 1);
        if (components.segment(@src(), &en, sel)) |clicked| {
            state.app.eq_preset = clicked;
            // Same spec that player.zig replays at init (shared av_pure mapping).
            var eq_buf: [96]u8 = undefined;
            const eq_cmd = @import("opal-fmt").bufPrintZ(&eq_buf, "af set \"{s}\"", .{av_pure.eqFilterSpec(clicked)}) catch "af set \"\"";
            for (state.app.players.items) |p| {
                _ = c.mpv.mpv_command_string(p.mpv_ctx, eq_cmd.ptr);
            }
            state.markConfigDirty();
        }
    }

    // ── Playback extras ──
    // Upstream-mpv options, each off by default because each trades something.
    // They take effect on the NEXT file opened: mpv reads them as options at
    // player init, and re-applying them live would mean tearing down the audio
    // chain mid-playback.
    sectionHeader("Playback Extras", "Applied to the next file you open", 25, @src());
    {
        const before_pf = state.app.prefetch_playlist;
        components.toggleRow(@src(), "Prefetch next in playlist", "Instant next-episode start. Costs a second concurrent download — on a torrent, a whole extra swarm.", &state.app.prefetch_playlist);
        const before_pt = state.app.audio_passthrough;
        components.toggleRow(@src(), "Audio passthrough (AC3/DTS/E-AC3)", "Bitstream to an AV receiver instead of decoding. Silence if your output cannot decode it. TrueHD/Atmos needs a patched mpv and is not offered.", &state.app.audio_passthrough);
        const before_ex = state.app.audio_exclusive;
        components.toggleRow(@src(), "Exclusive audio device", "Bit-perfect output. Nothing else on the machine can make a sound while a player is open.", &state.app.audio_exclusive);
        if (before_pf != state.app.prefetch_playlist or
            before_pt != state.app.audio_passthrough or
            before_ex != state.app.audio_exclusive)
        {
            state.markConfigDirty();
            state.showToast("Applies to the next file you open");
        }
    }
    // ── Audio Output ──
    sectionHeader("Audio Output", "Route sound to a specific output device", 26, @src());
    {
        const av_device = @import("../player/av_device_pure.zig");
        // Device list + active device, cached: `audio-device-list` is a
        // blocking mpv query and this tab renders every frame while open.
        // JSON parsing is pure and unit-tested (av_device_pure.zig).
        const Cache = struct {
            var last_ms: i64 = 0;
            var ctx_key: usize = 0;
            var devices: [av_device.max_devices]av_device.AudioDevice = undefined;
            var count: usize = 0;
            var cur_buf: [av_device.name_cap]u8 = undefined;
            var cur_len: usize = 0;
        };
        if (state.app.active_player_idx < state.app.players.items.len) {
            const ap = state.app.players.items[state.app.active_player_idx];
            const now = @import("../core/io_global.zig").milliTimestamp();
            const key = @intFromPtr(ap.mpv_ctx);
            if (!(Cache.ctx_key == key and now - Cache.last_ms < 1000)) {
                Cache.ctx_key = key;
                Cache.last_ms = now;
                Cache.count = 0;
                const list_c = c.mpv.mpv_get_property_string(ap.mpv_ctx, "audio-device-list");
                if (list_c != null) {
                    Cache.count = av_device.parseAudioDevices(std.mem.span(list_c), &Cache.devices);
                    c.mpv.mpv_free(@ptrCast(list_c));
                }
                Cache.cur_len = 0;
                const cur_c = c.mpv.mpv_get_property_string(ap.mpv_ctx, "audio-device");
                if (cur_c != null) {
                    const span = std.mem.span(cur_c);
                    const n = @min(span.len, Cache.cur_buf.len);
                    @memcpy(Cache.cur_buf[0..n], span[0..n]);
                    Cache.cur_len = n;
                    c.mpv.mpv_free(@ptrCast(cur_c));
                }
            }
            const cur: []const u8 = if (Cache.cur_len > 0) Cache.cur_buf[0..Cache.cur_len] else "auto";
            var di: usize = 0;
            while (di < Cache.count) : (di += 1) {
                const d = &Cache.devices[di];
                const is_cur = std.mem.eql(u8, cur, d.nameSlice());
                if (dvui.button(@src(), @import("../core/text.zig").safeUtf8(d.label()), .{}, .{
                    .id_extra = di + 3300,
                    .expand = .horizontal,
                    .color_fill = @import("color_compat.zig").wrap(if (is_cur) btn_inactive else theme.transparent),
                    .color_text = @import("color_compat.zig").wrap(if (is_cur) theme.colors.accent else labelText()),
                    .color_fill_hover = @import("color_compat.zig").wrap(theme.colors.bg_hover),
                    .color_fill_press = @import("color_compat.zig").wrap(theme.colors.bg_elevated),
                    .border = dvui.Rect.all(0),
                    .corners = theme.dims.rad_sm,
                    .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
                    .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
                })) {
                    var name_z: [av_device.name_cap + 1]u8 = undefined;
                    @memcpy(name_z[0..d.name_len], d.name[0..d.name_len]);
                    name_z[d.name_len] = 0;
                    for (state.app.players.items) |p| {
                        _ = c.mpv.mpv_set_property_string(p.mpv_ctx, "audio-device", @ptrCast(&name_z));
                    }
                    @memset(&state.app.audio_device_buf, 0);
                    @memcpy(state.app.audio_device_buf[0..d.name_len], d.name[0..d.name_len]);
                    state.app.audio_device_len = d.name_len;
                    state.markConfigDirty();
                    @memcpy(Cache.cur_buf[0..d.name_len], d.name[0..d.name_len]);
                    Cache.cur_len = d.name_len;
                    var toast_buf: [192]u8 = undefined;
                    const msg = std.fmt.bufPrint(&toast_buf, "Audio output: {s}", .{d.label()}) catch "Audio output changed";
                    state.showToast(msg);
                }
            }
            if (Cache.count == 0) {
                _ = dvui.label(@src(), "No output devices reported yet.", .{}, .{ .id_extra = 3390, .color_text = @import("color_compat.zig").wrap(mutedText()) });
            }
        } else {
            _ = dvui.label(@src(), "Open a player to pick an output device.", .{}, .{ .id_extra = 3391, .color_text = @import("color_compat.zig").wrap(mutedText()) });
        }
    }

    // ── Streaming ──
    sectionHeader("Streaming", "yt-dlp backend for web streams", 23, @src());

    settingRow("Stream Quality", 230, @src());
    {
        const qn = [_][]const u8{ "720p", "1080p", "4K", "Audio" };
        const sel: usize = @min(state.app.ytdl_format_idx, qn.len - 1);
        if (components.segment(@src(), &qn, sel)) |clicked| {
            state.app.ytdl_format_idx = clicked;
            for (state.app.players.items) |p| {
                p.applyYtdlFormat();
            }
            state.markConfigDirty();
        }
    }
    // yt-dlp status + version + actions
    {
        const ytdlp = @import("../services/ytdlp.zig");
        ytdlp.ensureVersion(); // kick a one-shot background `--version` query
        const btn_opts = dvui.Options{ .color_fill = @import("color_compat.zig").wrap(btn_inactive), .color_text = @import("color_compat.zig").wrap(theme.colors.accent), .border = dvui.Rect.all(0), .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs }, .corners = theme.dims.rad_md };

        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        _ = dvui.label(@src(), "yt-dlp", .{}, .{ .color_text = @import("color_compat.zig").wrap(labelText()), .gravity_y = 0.5 });

        // Version (when resolved).
        if (ytdlp.versionReady() and ytdlp.versionString().len > 0) {
            var vb: [40]u8 = undefined;
            const v = std.fmt.bufPrint(&vb, "v{s}", .{ytdlp.versionString()}) catch "";
            _ = dvui.label(@src(), "{s}", .{v}, .{ .id_extra = 2903, .color_text = @import("color_compat.zig").wrap(theme.colors.text_tertiary), .gravity_y = 0.5, .margin = .{ .x = 8, .y = 0, .w = 0, .h = 0 } });
        }

        {
            var spacer = dvui.box(@src(), .{}, .{ .expand = .horizontal });
            spacer.deinit();
        }

        if (ytdlp.isDownloading()) {
            components.statusPill("Updating", .info);
            components.pollRefresh(100_000);
        } else if (!ytdlp.versionReady()) {
            components.statusPill("Checking…", .info);
            components.pollRefresh(100_000);
        } else if (ytdlp.versionString().len > 0) {
            // Works (system or bundled).
            components.statusPill("Installed", .success);
            if (dvui.button(@src(), "Open folder", .{}, btn_opts.override(.{ .id_extra = 2904 }))) {
                var db: [512]u8 = undefined;
                openExternal(ytdlp.binaryDir(&db));
            }
            if (dvui.button(@src(), "Update", .{}, btn_opts.override(.{ .id_extra = 2901 }))) {
                ytdlp.update();
            }
        } else {
            components.statusPill("Not installed", .warn);
            if (dvui.button(@src(), "Download", .{}, .{ .id_extra = 2902, .color_fill = @import("color_compat.zig").wrap(btn_active), .color_text = @import("color_compat.zig").wrap(btn_text_active), .border = dvui.Rect.all(0), .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs }, .corners = theme.dims.rad_md })) {
                ytdlp.ensureAvailable();
            }
        }
    }
    // yt-dlp path (small, for transparency + so "Open folder" is unambiguous).
    {
        const ytdlp = @import("../services/ytdlp.zig");
        _ = dvui.label(@src(), "{s}", .{ytdlp.binary()}, .{
            .id_extra = 2910,
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_tertiary),
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
        });
    }
    _ = dvui.label(@src(), "Install operation: HTTPS curl to staged file › SHA-256 verification › --version probe › publish.", .{}, .{ .color_text = @import("color_compat.zig").wrap(theme.colors.text_tertiary) });

    // ── Keyboard Shortcuts ── (quiet text, no card chrome)
    sectionHeader("Keyboard Shortcuts", "", 21, @src());
    {
        _ = dvui.label(@src(), "Space=Pause  Arrows=Seek  Up/Down=Vol  M=Mute", .{}, .{ .id_extra = 2100, .color_text = @import("color_compat.zig").wrap(mutedText()) });
        _ = dvui.label(@src(), "+/-=Zoom  0=Reset  Shift+Arrows=Pan", .{}, .{ .id_extra = 2101, .color_text = @import("color_compat.zig").wrap(mutedText()) });
        _ = dvui.label(@src(), "V=Subs  K=SubDelay  Ctrl+=/-=AudioDelay  []=Speed  L=Loop  R=Rotate  T=Flip", .{}, .{ .id_extra = 2102, .color_text = @import("color_compat.zig").wrap(mutedText()) });
        _ = dvui.label(@src(), "A=AI  D=Drawer/Library  Shift+I=Shortcuts  Ctrl+I=Info  Ctrl+O=Open  Ctrl+Q=Quit", .{}, .{ .id_extra = 2103, .color_text = @import("color_compat.zig").wrap(mutedText()) });
    }

    // ── Video Filters ── (no card chrome)
    sectionHeader("Video Filters", "Brightness, contrast, saturation, gamma", 24, @src());
    {
        const av_pure = @import("../player/av_pure.zig");
        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
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

        // The persisted state field backing each filter row, by idx. Written by
        // the ± buttons and replayed at player init (player.zig), so filters now
        // survive restart / apply to newly-opened files.
        const VF = struct {
            fn field(idx: usize) *i32 {
                return switch (idx) {
                    0 => &state.app.vf_brightness,
                    1 => &state.app.vf_contrast,
                    2 => &state.app.vf_saturation,
                    else => &state.app.vf_gamma,
                };
            }
        };

        for (filters) |f| {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = f.idx + 3000,
                .expand = .horizontal,
                .padding = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
            });
            defer row.deinit();

            _ = dvui.label(@src(), "{s}", .{f.name}, .{
                .id_extra = f.idx + 3010,
                .color_text = @import("color_compat.zig").wrap(labelText()),
                .min_size_content = .{ .w = 90, .h = 0 },
                .gravity_y = 0.5,
            });

            // "−" button
            if (dvui.button(@src(), "−", .{}, .{
                .id_extra = f.idx + 3020,
                .color_fill = @import("color_compat.zig").wrap(btn_inactive),
                .color_text = @import("color_compat.zig").wrap(mutedText()),
                .border = dvui.Rect.all(0),
                .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
                .corners = theme.dims.rad_sm,
                .margin = .{ .x = theme.spacing.xs, .y = 0, .w = 2, .h = 0 },
            })) {
                const fld = VF.field(f.idx);
                fld.* = av_pure.clampVideoFilter(fld.* - 5);
                for (state.app.players.items) |pl| @import("../player/player.zig").applyVideoGrade(pl);
                state.markConfigDirty();
            }

            // Current value — throttled: mpv property reads take the core lock
            // synchronously, and 4 per frame while Settings sat open added
            // frame-time jitter to active playback. Refresh at most ~4×/s
            // (clicks read fresh next tick anyway).
            {
                // The manual offset lives in state (mpv's eq props are no-ops
                // under SW render), so read it directly — no mpv IPC.
                const val: i32 = VF.field(f.idx).*;
                var val_buf: [12]u8 = undefined;
                const val_str = @import("opal-fmt").bufPrintZ(&val_buf, "{d}", .{val}) catch "0";
                _ = dvui.label(@src(), "{s}", .{val_str}, .{
                    .id_extra = f.idx + 3030,
                    .color_text = @import("color_compat.zig").wrap(theme.colors.text_primary),
                    .min_size_content = .{ .w = 30, .h = 0 },
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                });
            }

            // "+" button
            if (dvui.button(@src(), "+", .{}, .{
                .id_extra = f.idx + 3040,
                .color_fill = @import("color_compat.zig").wrap(btn_inactive),
                .color_text = @import("color_compat.zig").wrap(mutedText()),
                .border = dvui.Rect.all(0),
                .padding = .{ .x = theme.spacing.sm, .y = theme.spacing.xs, .w = theme.spacing.sm, .h = theme.spacing.xs },
                .corners = theme.dims.rad_sm,
                .margin = .{ .x = 2, .y = 0, .w = 0, .h = 0 },
            })) {
                const fld = VF.field(f.idx);
                fld.* = av_pure.clampVideoFilter(fld.* + 5);
                for (state.app.players.items) |pl| @import("../player/player.zig").applyVideoGrade(pl);
                state.markConfigDirty();
            }
        }

        // Reset all button
        components.divider();
        if (dvui.button(@src(), "Reset All Filters", .{}, .{
            .id_extra = 3099,
            .color_fill = @import("color_compat.zig").wrap(theme.colors.bg_elevated),
            .color_text = @import("color_compat.zig").wrap(theme.colors.danger),
            .border = dvui.Rect.all(0),
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
            .corners = theme.dims.rad_md,
        })) {
            state.app.vf_brightness = 0;
            state.app.vf_contrast = 0;
            state.app.vf_saturation = 0;
            state.app.vf_gamma = 0;
            for (state.app.players.items) |pl| @import("../player/player.zig").applyVideoGrade(pl);
            state.markConfigDirty();
        }
    }

    // ── Capture ── (no card chrome)
    sectionHeader("Capture", "Screenshot and clip export", 25, @src());
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 },
        });
        defer row.deinit();

        // Screenshot button — the single primary action.
        if (dvui.button(@src(), "Screenshot (P)", .{}, .{
            .id_extra = 3200,
            .color_fill = @import("color_compat.zig").wrap(btn_active),
            .color_text = @import("color_compat.zig").wrap(btn_text_active),
            .border = dvui.Rect.all(0),
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
            .corners = theme.dims.rad_md,
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        })) {
            if (state.app.active_player_idx < state.app.players.items.len) {
                _ = c.mpv.mpv_command_string(state.app.players.items[state.app.active_player_idx].mpv_ctx, "screenshot");
                state.showToast("Screenshot saved");
            }
        }

        // Screenshot without subs
        if (dvui.button(@src(), "Screenshot (no subs)", .{}, .{
            .id_extra = 3201,
            .color_fill = @import("color_compat.zig").wrap(btn_inactive),
            .color_text = @import("color_compat.zig").wrap(mutedText()),
            .border = dvui.Rect.all(0),
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
            .corners = theme.dims.rad_md,
            .margin = .{ .x = 0, .y = 0, .w = theme.spacing.sm, .h = 0 },
        })) {
            if (state.app.active_player_idx < state.app.players.items.len) {
                _ = c.mpv.mpv_command_string(state.app.players.items[state.app.active_player_idx].mpv_ctx, "screenshot video");
                state.showToast("Screenshot (video-only) saved");
            }
        }

        // Clip export
        {
            const has_loop = if (state.app.active_player_idx < state.app.players.items.len) blk: {
                const ap = state.app.players.items[state.app.active_player_idx];
                break :blk ap.loop_a >= 0 and ap.loop_b >= 0;
            } else false;

            const clip_label = if (has_loop) "Export Clip" else "Clip (L › set loop)";
            if (dvui.button(@src(), clip_label, .{}, .{
                .id_extra = 3202,
                .color_fill = @import("color_compat.zig").wrap(if (has_loop) btn_active else btn_inactive),
                .color_text = @import("color_compat.zig").wrap(if (has_loop) btn_text_active else mutedText()),
                .border = dvui.Rect.all(0),
                .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.md, .h = theme.spacing.sm },
                .corners = theme.dims.rad_md,
            })) {
                if (state.app.active_player_idx < state.app.players.items.len) {
                    state.app.players.items[state.app.active_player_idx].exportClip();
                }
            }
        }
    }
}

pub fn absField(label: []const u8, buf: []u8, password: bool, id: usize) void {
    _ = dvui.label(@src(), "{s}", .{label}, .{
        .id_extra = id,
        .color_text = @import("color_compat.zig").wrap(theme.colors.text_secondary),
        .padding = .{ .x = 0, .y = 4, .w = 0, .h = 2 },
    });
    var te = dvui.textEntry(@src(), .{
        .text = .{ .buffer = buf },
        .password_char = if (password) "•" else null,
    }, .{
        .id_extra = id,
        .expand = .horizontal,
        .min_size_content = .{ .w = 250, .h = 20 },
        .color_fill = @import("color_compat.zig").wrap(theme.colors.bg_elevated),
        .color_border = @import("color_compat.zig").wrap(theme.colors.border_subtle),
        .color_text = @import("color_compat.zig").wrap(theme.colors.text_primary),
        .border = dvui.Rect.all(1),
        .corners = theme.dims.rad_sm,
    });
    te.deinit();
}

// ══════════════════════════════════════════════════════════
// Keyboard Cheat Sheet (? key)
// ══════════════════════════════════════════════════════════

pub fn renderCheatSheet() void {
    if (!state.app.cheatsheet_open) return;

    const dialog_size = theme.fitWindowSize(.{ .w = 650, .h = 520 }, .{ .w = 280, .h = 200 });

    var win = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &state.app.cheatsheet_open,
    }, .{
        .min_size_content = dialog_size,
        .color_fill = @import("color_compat.zig").wrap(theme.colors.bg_surface),
        .color_border = @import("color_compat.zig").wrap(theme.colors.border_subtle),
    });
    defer win.deinit();

    win.dragAreaSet(dvui.windowHeader("Keyboard Shortcuts", "", &state.app.cheatsheet_open));

    // Scroll area — without it the ~60-row list (at 1.4× scale) exceeded any
    // normal window height and dvui simply clipped the bottom half of the
    // shortcuts plus the whole AI Keywords section, unreachable.
    var sheet_scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = false });
    defer sheet_scroll.deinit();

    var settings_scale: f32 = 1.2;
    var scale_w = dvui.scale(@src(), .{ .scale = &settings_scale }, .{ .expand = .horizontal });
    defer scale_w.deinit();

    const shortcuts = [_][2][]const u8{
        .{ "Ctrl/Cmd+K", "Find a Page or Action" },
        .{ "Ctrl/Cmd+[ / ]", "Back / Forward" },
        .{ "Space", "Play / Pause" },
        .{ "F F", "Toggle Fullscreen (double-tap)" },
        .{ "Left / Right", "Seek -10s / +10s" },
        .{ "Up / Down", "Volume +5 / -5" },
        .{ "M", "Mute" },
        .{ "J / Shift+J", "Cycle Subs / Search Subs" },
        .{ "U", "Cycle Audio Track" },
        .{ "V", "Cycle Subtitle Track" },
        .{ "K / Shift+K", "Sub Delay +100ms / -100ms" },
        .{ "Ctrl+= / Ctrl+-", "Audio Delay +100ms / -100ms" },
        .{ "Ctrl+0", "Reset Audio Delay" },
        .{ "N / Shift+N", "Next / Prev Episode" },
        .{ "[ / ]", "Decrease / Increase Speed" },
        .{ "Backspace", "Reset Speed to 1.0x" },
        .{ ", / .", "Frame Back / Forward" },
        .{ "L", "Set A-B Loop (press 3x)" },
        .{ "PgUp / PgDn", "Previous / Next Chapter" },
        .{ "+ / -", "Zoom In / Out" },
        .{ "0", "Reset Zoom & Pan" },
        .{ "Shift+Arrows", "Pan Video" },
        .{ "R", "Rotate Video" },
        .{ "T", "Flip Video" },
        .{ "Shift+P", "Screenshot" },
        .{ "Shift+S", "Stats for Nerds" },
        .{ "Ctrl+I", "Media Info Panel" },
        .{ "A", "Toggle AI Bubble" },
        .{ "S", "Search" },
        .{ "D", "Drawer (classic) / Library" },
        .{ "H", "Watch History" },
        .{ "G", "Cycle Grid Mode" },
        .{ "Y", "Toggle Seek Sync" },
        .{ "I", "Toggle Incognito Mode" },
        .{ "B", "Switch Cell to Browser" },
        .{ "C", "Toggle Subtitles On/Off" },
        .{ "Z", "Toggle Video Fill Mode" },
        .{ "Ctrl+Arrows", "Swap Cell Position" },
        .{ "1-9", "Select Player Cell" },
        .{ "Ctrl+,", "Settings" },
        .{ "Ctrl+W", "Close Player Tab" },
        .{ "Ctrl+Shift+T", "Restore Closed Tab" },
        .{ "Ctrl+L", "Language Learning Mode" },
        .{ "Ctrl+S", "Save Subtitle Flashcard" },
        .{ "Ctrl+O", "Open File Dialog" },
        .{ "Ctrl+Q", "Quit" },
        .{ "Ctrl+V", "Paste URL / Magnet" },
        .{ "P", "Toggle Playlist Drawer" },
        .{ "Shift+I", "This Cheat Sheet" },
        .{ "Esc", "Close Overlay / Fullscreen" },
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
            .color_text = @import("color_compat.zig").wrap(theme.colors.accent),
            .min_size_content = .{ .w = 140, .h = 0 },
        });

        _ = dvui.label(@src(), "{s}", .{sc[1]}, .{
            .id_extra = idx + 1000,
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_primary),
        });
    }

    // ── AI chat keyword shortcuts ──
    _ = dvui.label(@src(), "AI Keywords (type in input)", .{}, .{
        .color_text = @import("color_compat.zig").wrap(theme.colors.accent),
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
            .color_text = @import("color_compat.zig").wrap(theme.colors.accent),
            .min_size_content = .{ .w = 180, .h = 0 },
        });
        _ = dvui.label(@src(), "{s}", .{k[1]}, .{
            .id_extra = idx + 6000,
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_primary),
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
    // Auto-dismiss when core deps are green. sherpa-onnx is optional
    // (better-quality backend); don't block on it. The LLM-backend leg of
    // this check is backend-aware: apfel users need the apfel binary,
    // Gemma users need llama-server + the GGUF model (validated in the
    // Gemma rows below and via ai_server state).
    const ai_server = @import("../services/ai_server.zig");
    ai_server.checkPaths(); // lazy detection — idempotent; not run at boot
    const llm_ready = switch (ai_server.backend_kind) {
        .apfel => s.apfel,
        .gemma_llama => ai_server.llama_server_exists and ai_server.model_exists,
        .cloud => ai_server.cloudConfigured(),
    };
    if (llm_ready and s.ffmpeg and s.whisper and s.whisper_model) {
        state.app.deps_modal_open = false;
        state.showToast("All set — voice mode ready");
        return;
    }

    const dialog_size = theme.fitWindowSize(.{ .w = 580, .h = 400 }, .{ .w = 280, .h = 200 });
    var win = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &state.app.deps_modal_open,
    }, .{
        .min_size_content = dialog_size,
        .color_fill = @import("color_compat.zig").wrap(theme.colors.bg_surface),
        .color_border = @import("color_compat.zig").wrap(theme.colors.accent),
        .corners = theme.dims.rad_xl,
    });
    defer win.deinit();

    win.dragAreaSet(dvui.windowHeader("Setup", "", &state.app.deps_modal_open));

    // Scrollable — on short windows the bottom rows (and their Download
    // buttons) were silently clipped.
    var deps_scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = false });
    defer deps_scroll.deinit();

    var pad_scale: f32 = 1.15;
    var scale_w = dvui.scale(@src(), .{ .scale = &pad_scale }, .{ .expand = .horizontal });
    defer scale_w.deinit();

    var pad = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .padding = .{ .x = 16, .y = 12, .w = 16, .h = 12 },
    });
    defer pad.deinit();

    _ = dvui.label(@src(), "Opal works best with these installed:", .{}, .{
        .color_text = @import("color_compat.zig").wrap(theme.colors.text_primary),
        .margin = .{ .y = 4 },
    });

    const DepRow = struct {
        name: []const u8,
        desc: []const u8,
        ok: bool,
        pending: bool = false, // model being downloaded
    };
    const deps_mod = @import("../core/deps.zig");
    const sherpa_dl = deps_mod.sherpa_model_downloading.load(.acquire);
    const tts_dl = deps_mod.sherpa_tts_downloading.load(.acquire);
    const stream_dl = deps_mod.sherpa_stream_downloading.load(.acquire);
    const kokoro_dl = deps_mod.sherpa_kokoro_downloading.load(.acquire);
    const rows = [_]DepRow{
        .{ .name = "apfel", .desc = "LLM backend (Apple Intelligence)", .ok = s.apfel },
        .{ .name = "ffmpeg", .desc = "Mic capture for voice mode", .ok = s.ffmpeg },
        .{ .name = "whisper-cpp", .desc = "STT engine (default)", .ok = s.whisper },
        .{ .name = "ggml-tiny.en", .desc = if (deps_mod.whisper_model_downloading.load(.acquire)) "Downloading Whisper Tiny…" else "download from Models & Dependencies", .ok = s.whisper_model, .pending = deps_mod.whisper_model_downloading.load(.acquire) },
        .{ .name = "sherpa-onnx", .desc = "STT engine (optional — streaming + VITS TTS)", .ok = s.sherpa_onnx },
        .{ .name = "sherpa STT model", .desc = if (sherpa_dl) "Downloading sherpa whisper-tiny…" else "click Download", .ok = s.sherpa_model, .pending = sherpa_dl },
        .{ .name = "sherpa TTS model", .desc = if (tts_dl) "Downloading Piper-VITS en_US-lessac-medium…" else "click Download", .ok = s.sherpa_tts_model, .pending = tts_dl },
        .{ .name = "sherpa streaming", .desc = if (stream_dl) "Downloading streaming Zipformer…" else "click Download", .ok = s.sherpa_stream_model, .pending = stream_dl },
        .{ .name = "sherpa Kokoro", .desc = if (kokoro_dl) "Downloading Kokoro (~305MB)…" else "premium TTS, 53+ voices", .ok = s.sherpa_kokoro_model, .pending = kokoro_dl },
    };

    for (rows, 0..) |r, i| {
        // Calm: no zebra striping — rows separated by whitespace alone.
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .expand = .horizontal,
            .padding = .{ .x = 4, .y = 6, .w = 4, .h = 6 },
            .margin = .{ .y = 1 },
        });
        defer row.deinit();

        // Status icon — lucide glyph, colored by semantic token. Pending rows
        // get a real SPINNER (self-refreshing) instead of a frozen
        // loader-circle glyph, which also keeps the modal's "installs show up
        // live" promise honest under the gated frame loop.
        if (r.pending) {
            dvui.spinner(@src(), .{
                .id_extra = i,
                .color_text = @import("color_compat.zig").wrap(theme.colors.warning),
                .min_size_content = .{ .w = 18, .h = 18 },
                .gravity_y = 0.5,
                .margin = .{ .w = 10 },
            });
        } else {
            const icon_data = if (r.ok)
                icons.tvg.lucide.@"circle-check-big"
            else
                icons.tvg.lucide.@"circle-x";
            _ = dvui.icon(@src(), "", icon_data, .{}, .{
                .id_extra = i,
                .color_text = @import("color_compat.zig").wrap(if (r.ok) theme.colors.success else theme.colors.danger),
                .min_size_content = .{ .w = 18, .h = 18 },
                .gravity_y = 0.5,
                .margin = .{ .w = 10 },
            });
        }
        _ = dvui.label(@src(), "{s}", .{r.name}, .{
            .id_extra = i + 1000,
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_primary),
            .min_size_content = .{ .w = 140, .h = 0 },
            .gravity_y = 0.5,
        });
        _ = dvui.label(@src(), "{s}", .{if (r.pending) "Downloading…" else r.desc}, .{
            .id_extra = i + 2000,
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_secondary),
            .gravity_y = 0.5,
            .expand = .horizontal,
        });

        // Per-model Download buttons — only when CLI present + model missing + not already downloading.
        if (!r.ok and !r.pending and s.sherpa_onnx) {
            if (std.mem.eql(u8, r.name, "sherpa STT model")) {
                if (dvui.button(@src(), "Download", .{}, .{
                    .id_extra = i,
                    .color_fill = @import("color_compat.zig").wrap(theme.colors.accent),
                    .color_text = @import("color_compat.zig").wrap(theme.colors.text_on_accent),
                    .border = dvui.Rect.all(0),
                    .corners = theme.dims.rad_sm,
                    .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
                    .gravity_y = 0.5,
                })) {
                    deps_mod.fetchSherpaWhisperAsync();
                    state.showToast("Downloading sherpa whisper-tiny — ~40MB");
                }
            } else if (std.mem.eql(u8, r.name, "sherpa TTS model")) {
                if (dvui.button(@src(), "Download", .{}, .{
                    .id_extra = i,
                    .color_fill = @import("color_compat.zig").wrap(theme.colors.accent),
                    .color_text = @import("color_compat.zig").wrap(theme.colors.text_on_accent),
                    .border = dvui.Rect.all(0),
                    .corners = theme.dims.rad_sm,
                    .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
                    .gravity_y = 0.5,
                })) {
                    deps_mod.fetchSherpaTtsAsync();
                    state.showToast("Downloading Piper VITS — ~40MB");
                }
            } else if (std.mem.eql(u8, r.name, "sherpa streaming")) {
                if (dvui.button(@src(), "Download", .{}, .{
                    .id_extra = i,
                    .color_fill = @import("color_compat.zig").wrap(theme.colors.accent),
                    .color_text = @import("color_compat.zig").wrap(theme.colors.text_on_accent),
                    .border = dvui.Rect.all(0),
                    .corners = theme.dims.rad_sm,
                    .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
                    .gravity_y = 0.5,
                })) {
                    deps_mod.fetchSherpaStreamAsync();
                    state.showToast("Downloading streaming Zipformer — ~80MB");
                }
            } else if (std.mem.eql(u8, r.name, "sherpa Kokoro")) {
                if (dvui.button(@src(), "Download", .{}, .{
                    .id_extra = i,
                    .color_fill = @import("color_compat.zig").wrap(theme.colors.accent),
                    .color_text = @import("color_compat.zig").wrap(theme.colors.text_on_accent),
                    .border = dvui.Rect.all(0),
                    .corners = theme.dims.rad_sm,
                    .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
                    .gravity_y = 0.5,
                })) {
                    deps_mod.fetchSherpaKokoroAsync();
                    state.showToast("Downloading Kokoro — ~330MB (grab coffee)");
                }
            }
        }
    }

    // ── Gemma backend rows (llama-server + model) ──
    // Only surfaces when the user has picked the Gemma backend. Keeps the
    // modal clean for apfel users on macOS. `ai_server` is already imported
    // earlier in this function for the auto-dismiss gate.
    {
        if (ai_server.backend_kind == .gemma_llama) {
            // Force a fresh detection each render so the rows reflect post-install reality.
            if (!ai_server.checked_paths) ai_server.checkPaths();

            // Model row reflects the picker's current selection.
            const am = ai_server.activeModel();
            var mdesc_buf: [96]u8 = undefined;
            const mdesc = if (ai_server.model_downloading)
                (std.fmt.bufPrint(&mdesc_buf, "Downloading {s} ({s})…", .{ am.name, am.size_label }) catch "Downloading…")
            else
                (std.fmt.bufPrint(&mdesc_buf, "GGUF model ({s}) — one-time download", .{am.size_label}) catch "GGUF model — one-time download");

            const rows_base = [_]struct {
                name: []const u8,
                desc: []const u8,
                ok: bool,
                pending: bool,
                action: enum { install_server, download_model },
            }{
                .{
                    .name = "llama-server",
                    .desc = if (ai_server.server_installing) "Installing via Homebrew…" else "LLM runtime (brew install llama.cpp)",
                    .ok = ai_server.llama_server_exists,
                    .pending = ai_server.server_installing,
                    .action = .install_server,
                },
                .{
                    .name = am.name,
                    .desc = mdesc,
                    .ok = ai_server.model_exists,
                    .pending = ai_server.model_downloading,
                    .action = .download_model,
                },
            };

            for (rows_base, 0..) |r, gi| {
                // Calm: no zebra striping.
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = 9000 + gi,
                    .expand = .horizontal,
                    .padding = .{ .x = 4, .y = 6, .w = 4, .h = 6 },
                    .margin = .{ .y = 1 },
                });
                defer row.deinit();

                const icon_data = if (r.ok)
                    icons.tvg.lucide.@"circle-check-big"
                else if (r.pending)
                    icons.tvg.lucide.@"loader-circle"
                else
                    icons.tvg.lucide.@"circle-x";
                const icon_color = if (r.ok)
                    theme.colors.success
                else if (r.pending)
                    theme.colors.warning
                else
                    theme.colors.danger;

                _ = dvui.icon(@src(), "", icon_data, .{}, .{
                    .id_extra = 9000 + gi,
                    .color_text = @import("color_compat.zig").wrap(icon_color),
                    .min_size_content = .{ .w = 18, .h = 18 },
                    .gravity_y = 0.5,
                    .margin = .{ .w = 10 },
                });
                _ = dvui.label(@src(), "{s}", .{r.name}, .{
                    .id_extra = 9100 + gi,
                    .color_text = @import("color_compat.zig").wrap(theme.colors.text_primary),
                    .min_size_content = .{ .w = 140, .h = 0 },
                    .gravity_y = 0.5,
                });
                _ = dvui.label(@src(), "{s}", .{r.desc}, .{
                    .id_extra = 9200 + gi,
                    .color_text = @import("color_compat.zig").wrap(theme.colors.text_secondary),
                    .gravity_y = 0.5,
                    .expand = .horizontal,
                });

                if (!r.ok and !r.pending) {
                    const btn_label = switch (r.action) {
                        .install_server => "Install",
                        .download_model => "Download",
                    };
                    if (dvui.button(@src(), btn_label, .{}, .{
                        .id_extra = 9300 + gi,
                        .color_fill = @import("color_compat.zig").wrap(theme.colors.accent),
                        .color_text = @import("color_compat.zig").wrap(theme.colors.text_on_accent),
                        .border = dvui.Rect.all(0),
                        .corners = theme.dims.rad_sm,
                        .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
                        .gravity_y = 0.5,
                    })) {
                        switch (r.action) {
                            .install_server => ai_server.installLlamaServer(),
                            .download_model => ai_server.startModelDownload(),
                        }
                    }
                }
            }

            // Start / Stop button once both pieces are ready.
            if (ai_server.llama_server_exists and ai_server.model_exists) {
                var act_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .padding = .{ .x = 4, .y = 8, .w = 4, .h = 4 },
                });
                defer act_row.deinit();
                const running = ai_server.server_running;
                const btn = if (running) "Stop Gemma Server" else "Start Gemma Server";
                if (dvui.button(@src(), btn, .{}, .{
                    .color_fill = @import("color_compat.zig").wrap(if (running) theme.colors.bg_elevated else theme.colors.accent),
                    .color_text = @import("color_compat.zig").wrap(if (running) theme.colors.danger else theme.colors.text_on_accent),
                    .border = dvui.Rect.all(0),
                    .corners = theme.dims.rad_md,
                    .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
                })) {
                    if (running) ai_server.stopServer() else ai_server.startServer();
                }
            }
        }
    }

    // Install one-liner + actions row
    var cmd_buf: [256]u8 = undefined;
    const cmd = deps.installCmd(&cmd_buf, s);
    if (cmd.len > 0 and @import("builtin").os.tag == .macos) {
        _ = dvui.label(@src(), "Install missing with Homebrew:", .{}, .{
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_primary),
            .margin = .{ .y = 14 },
        });
        // Code block — a single fill tier delimits it (no border).
        var code_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = @import("color_compat.zig").wrap(theme.colors.bg_elevated),
            .corners = theme.dims.rad_md,
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.sm, .w = theme.spacing.sm, .h = theme.spacing.sm },
            .margin = .{ .y = 4 },
        });
        defer code_row.deinit();

        _ = dvui.label(@src(), "{s}", .{cmd}, .{
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_secondary),
            .expand = .horizontal,
            .gravity_y = 0.5,
        });

        // Run in Terminal — launch Terminal.app with AppleScript + pre-fill command
        if (dvui.button(@src(), "Run", .{}, .{
            .color_fill = @import("color_compat.zig").wrap(theme.colors.accent),
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_on_accent),
            .border = dvui.Rect.all(0),
            .corners = theme.dims.rad_sm,
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
            .margin = .{ .w = 4 },
            .gravity_y = 0.5,
        })) {
            // `osascript -e 'tell app "Terminal" to do script "CMD"'`
            var script_buf: [512]u8 = undefined;
            const script = std.fmt.bufPrint(
                &script_buf,
                "tell application \"Terminal\" to do script \"{s}\"",
                .{cmd},
            ) catch "";
            if (script.len > 0) {
                // Launch on a detached thread so the frame never blocks.
                if (TerminalLauncher.launch(script)) {
                    logs.pushLog("info", "deps", cmd, false);
                    state.showToast("Opening Terminal; installation runs there");
                } else {
                    state.showToastTyped("Could not open Terminal · see Logs", .err);
                }
            }
        }

        if (dvui.button(@src(), "Copy", .{}, .{
            .color_fill = @import("color_compat.zig").wrap(theme.colors.bg_elevated),
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_primary),
            .border = dvui.Rect.all(0),
            .corners = theme.dims.rad_sm,
            .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
            .gravity_y = 0.5,
        })) {
            dvui.clipboardTextSet(cmd);
            state.showToast("Copied to clipboard");
        }
    }
    if (@import("builtin").os.tag != .macos and (!s.ffmpeg or !s.whisper)) {
        _ = dvui.label(@src(), "Install missing ffmpeg / whisper-cpp with your system package manager. No automatic system installer is available here.", .{}, .{ .color_text = @import("color_compat.zig").wrap(theme.colors.text_secondary) });
    }
    const terminal_state = TerminalLauncher.status.load(.acquire);
    if (terminal_state != .idle) {
        _ = dvui.label(@src(), "Dependency command: {s}", .{switch (terminal_state) {
            .launching => "Opening Terminal…",
            .opened => "Sent to Terminal · verify installed rows above",
            .failed => "Terminal launch failed · see Logs",
            .idle => unreachable,
        }}, .{ .color_text = @import("color_compat.zig").wrap(if (terminal_state == .failed) theme.colors.danger else theme.colors.text_secondary) });
        if (terminal_state == .launching) components.pollRefresh(100_000);
    }
    _ = dvui.label(@src(), "Model downloads: HTTPS curl › verify › extract staged archive (no shell for source plugins).", .{}, .{ .color_text = @import("color_compat.zig").wrap(theme.colors.text_tertiary) });
    if (dvui.button(@src(), "View installation logs", .{}, .{ .color_fill = @import("color_compat.zig").wrap(theme.colors.bg_elevated), .color_text = @import("color_compat.zig").wrap(theme.colors.accent) })) {
        state.app.deps_modal_open = false;
        state.navigateToTab(.Logs);
    }

    // Footer row: auto-recheck hint + skip button
    var footer = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .margin = .{ .y = 14 },
    });
    defer footer.deinit();

    _ = dvui.label(@src(), "Checking continuously — installs show up live.", .{}, .{
        .color_text = @import("color_compat.zig").wrap(theme.colors.text_tertiary),
        .gravity_y = 0.5,
    });
    {
        var sp = dvui.box(@src(), .{}, .{ .expand = .horizontal });
        sp.deinit();
    }
    if (dvui.button(@src(), "Skip for now", .{}, .{
        .color_fill = @import("color_compat.zig").wrap(theme.transparent),
        .color_fill_hover = @import("color_compat.zig").wrap(theme.colors.bg_hover),
        .color_fill_press = @import("color_compat.zig").wrap(theme.colors.bg_elevated),
        .color_text = @import("color_compat.zig").wrap(theme.colors.text_secondary),
        .border = dvui.Rect.all(0),
        .padding = .{ .x = theme.spacing.md, .y = theme.spacing.xs, .w = theme.spacing.md, .h = theme.spacing.xs },
        .gravity_y = 0.5,
    })) {
        state.app.deps_modal_open = false;
    }
}

// ══════════════════════════════════════════════════════════
// Media Info Panel (I key)
// ══════════════════════════════════════════════════════════

pub fn renderMediaInfo() void {
    if (!state.app.media_info_open) return;
    if (state.app.active_player_idx >= state.app.players.items.len) return;

    const p = state.app.players.items[state.app.active_player_idx];

    const dialog_size = theme.fitWindowSize(.{ .w = 420, .h = 320 }, .{ .w = 240, .h = 180 });
    var win = dvui.floatingWindow(@src(), .{
        .open_flag = &state.app.media_info_open,
    }, .{
        .min_size_content = dialog_size,
        .color_fill = @import("color_compat.zig").wrap(theme.colors.bg_surface),
        .color_border = @import("color_compat.zig").wrap(theme.colors.border_subtle),
    });
    defer win.deinit();

    win.dragAreaSet(dvui.windowHeader("Media Info", "", &state.app.media_info_open));

    var info_scale: f32 = 1.3;
    var scale_w = dvui.scale(@src(), .{ .scale = &info_scale }, .{ .expand = .both });
    defer scale_w.deinit();

    // Query mpv properties — SNAPSHOTTED at most 2×/s. Each string read is a
    // synchronous allocation under mpv's core lock; 14 per frame contended
    // with the demux/render threads during playback and added frame jitter.
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
    const Snap = struct {
        var bufs: [props.len][96]u8 = undefined;
        var lens: [props.len]usize = @splat(0);
        var last_ms: i64 = 0;
        var last_ctx: usize = 0;
    };
    const now_ms = @import("../core/io_global.zig").milliTimestamp();
    const ctx_key = @intFromPtr(p.mpv_ctx);
    if (now_ms - Snap.last_ms > 500 or Snap.last_ctx != ctx_key) {
        Snap.last_ms = now_ms;
        Snap.last_ctx = ctx_key;
        for (props, 0..) |prop, idx| {
            const val_ptr: ?[*:0]u8 = @ptrCast(c.mpv.mpv_get_property_string(p.mpv_ctx, @ptrCast(prop[0].ptr)));
            if (val_ptr) |vp| {
                const span = std.mem.span(vp);
                const n = @min(span.len, Snap.bufs[idx].len);
                @memcpy(Snap.bufs[idx][0..n], span[0..n]);
                Snap.lens[idx] = n;
                c.mpv.mpv_free(vp);
            } else {
                Snap.lens[idx] = 0;
            }
        }
    }
    // Tick a frame every 500ms while the panel is open so the snapshot stays
    // fresh even under the gated frame loop (re-arm pattern, 2 frames/s).
    const tick_id = win.data().id;
    if (dvui.timerDoneOrNone(tick_id)) dvui.timer(tick_id, 500_000);

    for (props, 0..) |prop, idx| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = idx,
            .expand = .horizontal,
            .padding = .{ .x = 4, .y = 1, .w = 4, .h = 1 },
        });
        defer row.deinit();

        _ = dvui.label(@src(), "{s}", .{prop[1]}, .{
            .id_extra = idx,
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_secondary),
            .min_size_content = .{ .w = 120, .h = 0 },
        });

        if (Snap.lens[idx] > 0) {
            // mpv strings (filename!) are untrusted — trim to valid UTF-8.
            _ = dvui.label(@src(), "{s}", .{@import("../core/text.zig").safeUtf8(Snap.bufs[idx][0..Snap.lens[idx]])}, .{
                .id_extra = idx + 500,
                .color_text = @import("color_compat.zig").wrap(theme.colors.text_primary),
            });
        } else {
            _ = dvui.label(@src(), "-", .{}, .{
                .id_extra = idx + 500,
                .color_text = @import("color_compat.zig").wrap(theme.colors.text_secondary),
            });
        }
    }
}

pub fn renderMusicConnection() void {
    // ── Music server (Subsonic / OpenSubsonic) — Navidrome / Airsonic / … ──
    settingRow("Music server (Subsonic)", 35, @src());
    _ = dvui.label(@src(), "Navidrome · Airsonic · Gonic · Funkwhale · Ampache — your music library", .{}, .{
        .id_extra = 3500,
        .color_text = @import("color_compat.zig").wrap(theme.colors.text_tertiary),
    });
    {
        const music = @import("../services/music_subsonic.zig");
        music.prefillConfig();
        // Server URL
        _ = dvui.label(@src(), "Server URL", .{}, .{ .id_extra = 3501, .color_text = @import("color_compat.zig").wrap(theme.colors.text_secondary) });
        {
            var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.music.cfg_base }, .placeholder = "http://localhost:4533" }, .{
                .id_extra = 3502,
                .expand = .horizontal,
                .min_size_content = .{ .w = 250, .h = 20 },
                .color_fill = @import("color_compat.zig").wrap(theme.colors.bg_elevated),
                .color_border = @import("color_compat.zig").wrap(theme.colors.border_subtle),
                .color_text = @import("color_compat.zig").wrap(theme.colors.text_primary),
                .border = dvui.Rect.all(1),
                .corners = theme.dims.rad_sm,
            });
            te.deinit();
        }
        // Username / Password
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 3503, .expand = .horizontal, .min_size_content = .{ .w = 0, .h = 26 } });
            defer row.deinit();
            var ute = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.music.cfg_user }, .placeholder = "username" }, .{
                .id_extra = 3504,
                .expand = .horizontal,
                .min_size_content = .{ .w = 120, .h = 20 },
                .color_fill = @import("color_compat.zig").wrap(theme.colors.bg_elevated),
                .color_border = @import("color_compat.zig").wrap(theme.colors.border_subtle),
                .color_text = @import("color_compat.zig").wrap(theme.colors.text_primary),
                .border = dvui.Rect.all(1),
                .corners = theme.dims.rad_sm,
            });
            ute.deinit();
            var pte = dvui.textEntry(@src(), .{ .text = .{ .buffer = &state.app.music.cfg_pass }, .placeholder = "password", .password_char = "•" }, .{
                .id_extra = 3505,
                .expand = .horizontal,
                .min_size_content = .{ .w = 120, .h = 20 },
                .color_fill = @import("color_compat.zig").wrap(theme.colors.bg_elevated),
                .color_border = @import("color_compat.zig").wrap(theme.colors.border_subtle),
                .color_text = @import("color_compat.zig").wrap(theme.colors.text_primary),
                .border = dvui.Rect.all(1),
                .corners = theme.dims.rad_sm,
                .margin = .{ .x = 8, .y = 0, .w = 0, .h = 0 },
            });
            pte.deinit();
        }
        if (dvui.button(@src(), "Save", .{}, .{
            .id_extra = 3506,
            .color_fill = @import("color_compat.zig").wrap(theme.colors.accent),
            .color_text = @import("color_compat.zig").wrap(theme.colors.text_on_accent),
            .corners = theme.dims.rad_sm,
            .padding = .{ .x = 12, .y = 5, .w = 12, .h = 5 },
        })) {
            music.saveConfig();
        }
    }
}
