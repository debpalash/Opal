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
const ai_tab = @import("settings/ai.zig");
const general_tab = @import("settings/general.zig");
const about_tab = @import("settings/about.zig");
const playback_tab = @import("settings/playback.zig");
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
        .General => general_tab.renderGeneralTab(),
        .Playback => playback_tab.renderPlaybackTab(),
        .Network => network_tab.renderNetworkTab(),
        .Subtitles => subtitles_tab.renderSubtitlesTab(),
        .Storage => storage_tab.renderStorageTab(),
        .WebUi => webui_tab.renderWebUiTab(),
        .Scripts => scripts_tab.renderScriptsTab(),
        .AI => ai_tab.renderAIContentBody(),
        .LangLearn => lang_learn_tab.renderLangLearnTab(),
        .FileAssoc => file_assoc_tab.renderFileAssocTab(),
        .LiveTv => live_tv_tab.renderLiveTvTab(),
        .Profiles => @import("profiles_ui.zig").renderSettingsTab(),
        .About => about_tab.renderAboutTab(),
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

    ai_tab.renderAIContentBody();
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
pub inline fn mutedText() dvui.Color {
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
