const std = @import("std");
const dvui = @import("dvui");
const components = @import("../components.zig");
const paths = @import("../../core/paths.zig");
const state = @import("../../core/state.zig");
const theme = @import("../theme.zig");
const settings = @import("../settings.zig");
const absField = settings.absField;
const openExternal = settings.openExternal;
const settingRow = settings.settingRow;

// ══════════════════════════════════════════════════════════
// Web UI & Remote Access
// ══════════════════════════════════════════════════════════
//
// The desktop half of the access controls that also live in the web UI
// (Setup › Access). Both drive the SAME state — `state.app.web_remote_enabled`,
// `remote.bind_mode`, `remote.port`, and the `users`/`sessions` tables — so
// they can never disagree.
//
// This page exists because the web version is unreachable in exactly the case
// you most need it: server off, password forgotten, or bound to a port you
// can't guess. The desktop already implies physical access to the machine (and
// to ~/.config/opal/api.token), so password reset here does NOT require the old
// password — same trust model as the api.token route in remote.zig.

/// Scratch input buffers for this page. Module-level fixed arrays per the
/// project's no-alloc-in-UI convention; cleared after a successful action so a
/// password never lingers in memory longer than the interaction.
var webui_user_buf: [96]u8 = std.mem.zeroes([96]u8);
var webui_pw_buf: [128]u8 = std.mem.zeroes([128]u8);
var webui_pw2_buf: [128]u8 = std.mem.zeroes([128]u8);
var webui_port_buf: [8]u8 = std.mem.zeroes([8]u8);
var webui_port_seeded: bool = false;
var webui_user_seeded: bool = false;
var webui_token_revealed: bool = false;
var webui_account_status: [160]u8 = std.mem.zeroes([160]u8);
var webui_account_status_len: usize = 0;
var webui_account_status_ok: bool = false;

fn zLen(buf: []const u8) usize {
    return std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
}

fn setWebUiAccountStatus(message: []const u8, ok: bool) void {
    const n = @min(message.len, webui_account_status.len - 1);
    @memcpy(webui_account_status[0..n], message[0..n]);
    webui_account_status[n] = 0;
    webui_account_status_len = n;
    webui_account_status_ok = ok;
    state.showToastTyped(message, if (ok) .success else .err);
}

fn webuiAccountField(label: []const u8, buf: []u8, password: bool, id: usize) bool {
    _ = dvui.label(@src(), "{s}", .{label}, .{
        .id_extra = id,
        .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
        .padding = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = theme.spacing.xxs },
    });
    var te = dvui.textEntry(@src(), .{
        .text = .{ .buffer = buf },
        .password_char = if (password) "•" else null,
    }, .{
        .id_extra = id,
        .expand = .horizontal,
        .min_size_content = .{ .w = 250, .h = 20 },
        .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
        .color_border = @import("../color_compat.zig").wrap(theme.colors.border_subtle),
        .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
        .border = dvui.Rect.all(1),
        .corners = theme.dims.rad_sm,
    });
    const submitted = te.enter_pressed;
    te.deinit();
    return submitted;
}

// ── Phone pairing QR (issue #46) ──
// The LAN URL — with the one-time setup code in the fragment while no account
// exists yet — encoded by core/qr_pure and shown as a texture, so reaching Opal
// from a phone is one scan instead of typing an IP, a port and 64 hex digits.
// Encoded once per distinct URL (hash-keyed) rather than every frame.
const qr_scale: u8 = 4;
const qr_quiet: u8 = 4;
const qr_max_edge: usize = (@import("../../core/qr_pure.zig").max_size + 2 * @as(usize, qr_quiet)) * qr_scale;
var webui_qr_px: [qr_max_edge * qr_max_edge * 4]u8 align(4) = undefined;
var webui_qr_tex: ?dvui.Texture = null;
var webui_qr_key: u64 = 0;

fn renderPhoneQr() void {
    const remote = @import("../../services/remote.zig");
    const remote_url = @import("../../services/remote_url_pure.zig");
    const qr = @import("../../core/qr_pure.zig");
    const note_opts = dvui.Options{
        .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
        .margin = .{ .x = 0, .y = theme.spacing.xxs, .w = 0, .h = 6 },
    };

    if (remote.bind_mode != .lan) {
        _ = dvui.label(@src(), "To open Opal on your phone, set Network below to LAN — a QR code to scan appears here.", .{}, note_opts);
        return;
    }
    const ip = remote.lanIp();
    var url_buf: [192]u8 = undefined;
    var setup: [remote.SETUP_TOKEN_HEX_LEN]u8 = undefined;
    const has_setup = remote.setupToken(&setup);
    const url: ?[]const u8 = (if (has_setup) remote_url.webUiLanSetupUrl(ip, remote.port, &setup, &url_buf) else null) orelse
        remote_url.webUiLanUrl(ip, remote.port, &url_buf);
    const u = url orelse {
        _ = dvui.label(@src(), "No LAN address found — connect this machine to Wi-Fi or Ethernet to pair a phone.", .{}, note_opts);
        return;
    };

    const key = std.hash.Wyhash.hash(0, u);
    if (webui_qr_tex == null or key != webui_qr_key) {
        if (webui_qr_tex) |t| dvui.textureDestroyLater(t);
        webui_qr_tex = null;
        webui_qr_key = key;
        var m: qr.Matrix = .{};
        if (qr.encode(u, &m)) |_| {
            if (qr.paintRgba(&m, qr_scale, qr_quiet, .{ 0, 0, 0, 255 }, .{ 255, 255, 255, 255 }, &webui_qr_px)) |edge| {
                const n = edge * edge;
                const pma: []dvui.Color.PMA = @as([*]dvui.Color.PMA, @ptrCast(@alignCast(&webui_qr_px)))[0..n];
                // Nearest: a QR must stay crisp; bilinear smearing between
                // modules is exactly what makes phone cameras miss the read.
                webui_qr_tex = dvui.textureCreate(pma, .{ .width = @intCast(edge), .height = @intCast(edge), .interpolation = .nearest, .format = .rgba_32, .wrap_u = .clamp, .wrap_v = .clamp }) catch null;
            }
        } else |_| {}
    }

    _ = dvui.label(@src(), "{s}", .{if (has_setup)
        "Scan with your phone on the same network — it opens Opal and carries your one-time setup code."
    else
        "Scan with your phone on the same network to open Opal's web remote."}, note_opts);
    if (webui_qr_tex) |tex| {
        _ = dvui.image(@src(), .{ .source = .{ .texture = tex } }, .{
            .min_size_content = .{ .w = 184, .h = 184 },
            .max_size_content = .{ .w = 184, .h = 184 },
            .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = theme.spacing.sm },
        });
    }
    var plain_buf: [96]u8 = undefined;
    if (remote_url.webUiLanUrl(ip, remote.port, &plain_buf)) |plain| {
        _ = dvui.label(@src(), "{s}", .{plain}, .{
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
        });
    }
}

/// Connect coding agents (Claude Code, Codex, Gemini CLI, ...) to Opal's MCP
/// server. Agents reach Opal through the same loopback Web API as everything
/// else, so "agent access" is that switch plus copy-paste setup for the client;
/// `opal-mcp` itself enforces the tier policy and writes the audit log.
const builtin_os_linux = @import("builtin").os.tag == .linux;

fn renderAgentAccess() void {
    const remote = @import("../../services/remote.zig");
    const setup = @import("../../services/agent_setup_pure.zig");
    const io_g = @import("../../core/io_global.zig");

    _ = dvui.label(@src(), "Let coding agents search, play and manage downloads through Opal. Agents connect with the opal-mcp program; it only talks to this machine unless the Web UI is shared on your network.", .{}, .{
        .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
        .margin = .{ .x = 0, .y = theme.spacing.xxs, .w = 0, .h = 6 },
    });

    const before = state.app.web_remote_enabled;
    const hint: []const u8 = if (!state.app.web_remote_enabled)
        "Off"
    else if (remote.bind_mode == .lan)
        "On, but the API is also reachable on your network"
    else
        "On, this computer only";
    components.toggleRow(@src(), "Allow coding agents", hint, &state.app.web_remote_enabled);
    if (state.app.web_remote_enabled != before) {
        state.markConfigDirty();
        if (state.app.web_remote_enabled) {
            remote.start();
            state.showToast("Agent access on");
        } else {
            remote.stop();
            state.showToast("Agent access off");
        }
    }

    {
        const follow_before = state.app.wanted_follow_tv;
        components.toggleRow(@src(), "Follow tracked shows", "Download the newest aired episode of each show you track, automatically", &state.app.wanted_follow_tv);
        if (state.app.wanted_follow_tv != follow_before) {
            @import("../../services/wanted.zig").setFollowTv(state.app.wanted_follow_tv);
            state.showToast(if (state.app.wanted_follow_tv) "Following tracked shows" else "Stopped following shows");
        }
    }

    {
        const ask_before = state.app.ask_enabled;
        const ask_agent = @import("../../services/ask.zig").installedAgent();
        const ask_hint: []const u8 = if (ask_agent == null)
            "Needs Claude Code or Codex on your PATH. Questions typed with > or ending in ? are answered by your coding agent using Opal's tools; downloads only start when you click a button. Uses your agent credit, up to 25 cents per question, within the operator's daily limit"
        else if (ask_agent.? == .codex)
            "Questions typed with > or ending in ? are answered by Codex using Opal's tools; downloads only start when you click a button. Counted at 25 cents per question against the operator's daily limit"
        else
            "Questions typed with > or ending in ? are answered by Claude Code using Opal's tools; downloads only start when you click a button. Uses your agent credit, up to 25 cents per question, within the operator's daily limit";
        components.toggleRow(@src(), "Ask Opal (uses your coding agent)", ask_hint, &state.app.ask_enabled);
        if (state.app.ask_enabled != ask_before) {
            state.markConfigDirty();
            state.showToast(if (state.app.ask_enabled) "Ask Opal on" else "Ask Opal off");
        }
        if (state.app.ask_enabled) {
            const fast_before = state.app.ask_fast;
            components.toggleRow(@src(), "Fast answers (Claude Haiku)", "Cheaper and quicker, a little less careful with tools. Off uses Claude Sonnet. Codex uses its own default model", &state.app.ask_fast);
            if (state.app.ask_fast != fast_before) state.markConfigDirty();
        }
    }

    {
        const op_before = state.app.operator_enabled;
        components.toggleRow(@src(), "Background operator", "Lets Opal quietly ask a coding agent to fix problems it cannot solve alone: other titles for a wanted item, a moved source address. Uses your agent credit within a daily limit; changes to sources wait for your approval", &state.app.operator_enabled);
        if (state.app.operator_enabled != op_before) {
            @import("../../services/operator.zig").setEnabled(state.app.operator_enabled);
            state.showToast(if (state.app.operator_enabled) "Background operator on" else "Background operator off");
        }
        if (state.app.operator_enabled) {
            const picks_before = state.app.operator_picks_enabled;
            components.toggleRow(@src(), "Use my watch history for picks", "Sends the titles (never file paths) of what you recently watched, favourited or follow to your coding agent, once a day, to fill the Home row \"Picked for you\". Every recommendation is checked against a real catalogue before it is shown. Off by default", &state.app.operator_picks_enabled);
            if (state.app.operator_picks_enabled != picks_before) {
                state.markConfigDirty();
                state.showToast(if (state.app.operator_picks_enabled) "Picks will use your watch history" else "Picks no longer use your watch history");
            }
        }
    }

    {
        const tasks_before = state.app.agent_tasks_enabled;
        components.toggleRow(@src(), "Run scheduled agent tasks", "Lets saved prompts run a coding agent on a timer, unattended. Uses your agent credit; each task has a daily cap", &state.app.agent_tasks_enabled);
        if (state.app.agent_tasks_enabled != tasks_before) {
            @import("../../services/agent_tasks.zig").setMasterEnabled(state.app.agent_tasks_enabled);
            state.showToast(if (state.app.agent_tasks_enabled) "Scheduled agent tasks on" else "Scheduled agent tasks off");
        }
    }

    // Before the horizontal button row below, which stays the parent until the
    // end of this function and would lay anything after it out to its right.
    renderBrowserLink();

    var exe_buf: [512]u8 = undefined;
    var path_buf: [600]u8 = undefined;
    const exe_dir = io_g.selfExeDirPath(&exe_buf) catch "";
    const is_win = @import("builtin").os.tag == .windows;
    const mcp_path = setup.mcpBinaryPath(&path_buf, exe_dir, is_win) orelse "opal-mcp";

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = 6 },
    });
    defer row.deinit();
    var text_buf: [768]u8 = undefined;
    if (components.actionButton(@src(), "Copy Claude Code command", .primary, 9301)) {
        if (setup.claudeCommand(&text_buf, mcp_path)) |t| {
            dvui.clipboardTextSet(t);
            state.showToast("Run it in a terminal to add Opal to Claude Code");
        } else state.showToast("Install path has a quote; use the JSON config");
    }
    if (components.actionButton(@src(), "Copy Codex config", .secondary, 9302)) {
        if (setup.codexToml(&text_buf, mcp_path)) |t| {
            dvui.clipboardTextSet(t);
            state.showToast("Paste into ~/.codex/config.toml");
        }
    }
    if (components.actionButton(@src(), "Copy JSON config", .secondary, 9303)) {
        if (setup.jsonConfig(&text_buf, mcp_path)) |t| {
            dvui.clipboardTextSet(t);
            state.showToast("MCP config copied");
        }
    }

    if (builtin_os_linux) {
        _ = dvui.label(@src(), "Open an agent in your terminal, already connected to Opal:", .{}, .{
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
            .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = theme.spacing.xxs },
        });
        var launch_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = theme.spacing.xxs, .w = 0, .h = 6 },
        });
        defer launch_row.deinit();
        const launcher = @import("../../services/agent_launch.zig");
        inline for (.{ launcher.Agent.claude, launcher.Agent.codex, launcher.Agent.gemini }, 0..) |agent, i| {
            var label_buf: [48]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "Launch {s}", .{agent.title()}) catch "Launch";
            if (components.actionButton(@src(), label, .secondary, 9310 + i)) {
                state.showToast(launcher.launch(agent).message());
            }
        }
    }

    var cfg_buf: [512]u8 = undefined;
    var audit_buf: [640]u8 = undefined;
    if (setup.auditLogPath(&audit_buf, paths.configDir(&cfg_buf))) |audit| {
        _ = dvui.label(@src(), "Every agent call is logged to {s}", .{audit}, .{
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
            .margin = .{ .x = 0, .y = theme.spacing.xxs, .w = 0, .h = 6 },
        });
        if (components.actionButton(@src(), "Copy log path", .secondary, 9304)) {
            dvui.clipboardTextSet(audit);
            state.showToast("Audit log path copied");
        }
    }
}

/// "Browser" card: pair the Opal Connect extension, list paired browsers,
/// revoke one. The pairing code is minted here, by a click, and never leaves
/// this process except by being typed into the extension: there is no HTTP route
/// that starts pairing, so an agent cannot do it.
fn renderBrowserLink() void {
    const link = @import("../../services/browser_link.zig");
    const link_pure = @import("../../services/browser_link_pure.zig");
    const io_g = @import("../../core/io_global.zig");

    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = theme.spacing.md, .w = 0, .h = theme.spacing.sm },
    });
    defer card.deinit();

    components.sectionHeader("Browser");
    _ = dvui.label(@src(), "Pair your own browser with the Opal Connect extension. It finds the real stream behind a page and plays it here with the right Referer. A paired browser can only send streams to Opal; it cannot change settings, downloads or sources.", .{}, .{
        .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
        .margin = .{ .x = 0, .y = theme.spacing.xxs, .w = 0, .h = 6 },
    });
    if (!state.app.web_remote_enabled) {
        _ = dvui.label(@src(), "The extension reaches Opal through its local API: turn on \"Allow coding agents\" above first.", .{}, .{
            .color_text = @import("../color_compat.zig").wrap(theme.colors.warning),
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
        });
    }

    const view = link.pairingView();
    if (view.active) {
        // Re-arm once a second so the countdown moves under the gated frame loop.
        const tick_id = card.data().id;
        if (dvui.timerDoneOrNone(tick_id)) dvui.timer(tick_id, 1_000_000);

        var big = dvui.themeGet().font_body;
        big.size = theme.font_size.title * 1.6;
        _ = dvui.label(@src(), "{s}", .{view.code[0..]}, .{
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
            .font = big,
            .margin = .{ .x = 0, .y = theme.spacing.xxs, .w = 0, .h = theme.spacing.xxs },
        });
        _ = dvui.label(@src(), "Enter this code in the extension's setup page. Expires in {d}:{d:0>2}. Five wrong tries cancel it.", .{ @as(u32, @intCast(@divTrunc(view.remaining, 60))), @as(u32, @intCast(@mod(view.remaining, 60))) }, .{
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
        });
    }

    {
        var prow = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = theme.spacing.xxs, .w = 0, .h = 6 },
        });
        defer prow.deinit();
        if (components.actionButton(@src(), if (view.active) "New code" else "Pair a browser", .primary, 9330)) {
            if (!link.startPairing()) state.showToast("No entropy source: could not make a code");
        }
        if (view.active and components.actionButton(@src(), "Cancel", .secondary, 9331)) link.cancelPairing();
    }

    // The second consent for the "Share this page" button in the extension: a page
    // is readable by agents only when it was shared with the agents box ticked AND
    // this is on. Only this switch changes it; no route and no tool can.
    {
        const before = state.app.browser_share_agents;
        components.toggleRow(@src(), "Let agents read shared pages", "Agents can read the title, text and detected streams of a page you share from your browser, and play those streams. Off by default. The text is untrusted: agents are told so", &state.app.browser_share_agents);
        if (state.app.browser_share_agents != before) {
            state.markConfigDirty();
            state.showToast(if (state.app.browser_share_agents) "Agents can read pages you share" else "Agents can no longer read shared pages");
        }
    }

    // Same rule for the open tabs: Opal's switch AND the user's own opt-in in the
    // extension (it asks for the optional tabs permission when they turn it on there).
    {
        const before = state.app.browser_share_tabs;
        components.toggleRow(@src(), "Share tab list with agents", "Agents can see the titles and sites (host and path, never the full address) of the tabs open in a paired browser, but only if you also allow it in the Opal Connect panel. Off by default. Tab titles are untrusted text: agents are told so", &state.app.browser_share_tabs);
        if (state.app.browser_share_tabs != before) {
            state.markConfigDirty();
            state.showToast(if (state.app.browser_share_tabs) "Agents can see your tab list once the browser allows it" else "Agents can no longer see your tabs");
        }
    }

    var rows: [link_pure.MAX_LINKS]link.Link = undefined;
    const n = link.list(&rows);
    if (n == 0) {
        _ = dvui.label(@src(), "No paired browsers.", .{}, .{
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
            .margin = .{ .x = 0, .y = theme.spacing.xxs, .w = 0, .h = theme.spacing.xs },
        });
        return;
    }
    _ = dvui.label(@src(), "Paired browsers", .{}, .{
        .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
        .margin = .{ .x = 0, .y = theme.spacing.xxs, .w = 0, .h = theme.spacing.xxs },
    });
    const now = io_g.timestamp();
    for (rows[0..n], 0..) |*row, i| {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = i,
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = theme.spacing.xxs, .w = 0, .h = theme.spacing.xxs },
        });
        defer line.deinit();
        var seen_buf: [48]u8 = undefined;
        const ago = now - row.last_seen;
        const seen: []const u8 = if (ago < 90)
            "active now"
        else if (ago < 3600)
            std.fmt.bufPrint(&seen_buf, "seen {d} min ago", .{@divTrunc(ago, 60)}) catch ""
        else if (ago < 86400)
            std.fmt.bufPrint(&seen_buf, "seen {d} h ago", .{@divTrunc(ago, 3600)}) catch ""
        else
            std.fmt.bufPrint(&seen_buf, "seen {d} d ago", .{@divTrunc(ago, 86400)}) catch "";
        // Button first: a label that expands to the row's width would push it
        // out of view in a narrow window.
        if (components.actionButton(@src(), "Revoke", .danger, 9340 + i)) {
            if (link.revoke(row.id)) state.showToast("Browser revoked: it can no longer reach Opal");
        }
        _ = dvui.label(@src(), "{s} ({s}), {s}", .{ row.labelSlice(), row.browserSlice(), seen }, .{
            .id_extra = i,
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
            .gravity_y = 0.5,
            .margin = .{ .x = theme.spacing.sm, .y = 0, .w = 0, .h = 0 },
        });
    }
}

pub fn renderWebUiTab() void {
    const remote = @import("../../services/remote.zig");
    const access = @import("../../services/access_pure.zig");
    const auth_store = @import("../../services/auth_store.zig");

    // ── Server ──
    settingRow("Web UI Server", 90, @src());
    {
        var hint_buf: [96]u8 = undefined;
        const hint: []const u8 = if (!state.app.web_remote_enabled) "Off" else blk: {
            const ip = remote.lanIp();
            break :blk if (ip.len > 0)
                (std.fmt.bufPrint(&hint_buf, "http://{s}:{d}", .{ ip, remote.port }) catch "on")
            else
                "on";
        };
        const before = state.app.web_remote_enabled;
        components.toggleRow(@src(), "Enable Web UI", hint, &state.app.web_remote_enabled);
        if (state.app.web_remote_enabled != before) {
            state.markConfigDirty(); // persisted (web_remote) — survives restarts
            if (state.app.web_remote_enabled) {
                remote.start();
                state.showToast("Web UI started");
            } else {
                remote.stop();
                state.showToast("Web UI stopped");
            }
        }

        if (state.app.web_remote_enabled) {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .margin = .{ .x = 0, .y = theme.spacing.xs, .w = 0, .h = 6 },
            });
            defer row.deinit();
            if (components.actionButton(@src(), "Open in Browser", .primary, 9001)) {
                var url_buf: [160]u8 = undefined;
                const remote_url = @import("../../services/remote_url_pure.zig");
                var setup: [remote.SETUP_TOKEN_HEX_LEN]u8 = undefined;
                const url = if (remote.setupToken(&setup))
                    remote_url.webUiSetupUrl(remote.port, &setup, &url_buf)
                else
                    remote_url.webUiUrl(remote.port, &url_buf);
                if (url) |u| openExternal(u);
            }
            if (components.actionButton(@src(), "Copy Address", .secondary, 9002)) {
                var addr_buf: [96]u8 = undefined;
                const ip = remote.lanIp();
                const addr = if (ip.len > 0)
                    (std.fmt.bufPrint(&addr_buf, "http://{s}:{d}", .{ ip, remote.port }) catch "")
                else
                    (std.fmt.bufPrint(&addr_buf, "http://127.0.0.1:{d}", .{remote.port}) catch "");
                dvui.clipboardTextSet(addr);
                state.showToast("Address copied");
            }
        }
        if (state.app.web_remote_enabled) renderPhoneQr();
    }

    // ── Account ──
    settingRow("Account", 91, @src());
    {
        var status_buf: [96]u8 = undefined;
        const users = auth_store.userCount();
        const status = if (users == 0)
            "No account yet — set one here, or create it on first visit."
        else
            (std.fmt.bufPrint(&status_buf, "{d} account(s) · {d} signed-in device(s)", .{
                users, auth_store.liveSessionCount(),
            }) catch "");
        _ = dvui.label(@src(), "{s}", .{status}, .{
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
            .margin = .{ .x = 0, .y = theme.spacing.xxs, .w = 0, .h = 6 },
        });

        // Prefill with the existing account. An empty field made "Set Password"
        // a dead click unless you already knew the username — the button just
        // toasted "Enter a username" and nothing happened.
        if (!webui_user_seeded) {
            webui_user_seeded = true;
            if (auth_store.firstUsername(webui_user_buf[0 .. webui_user_buf.len - 1])) |n|
                webui_user_buf[n.len] = 0;
        }
        _ = webuiAccountField("Username", &webui_user_buf, false, 9101);
        _ = webuiAccountField("New password (8+ characters)", &webui_pw_buf, true, 9102);
        const enter_submitted = webuiAccountField("Confirm password", &webui_pw2_buf, true, 9103);

        var brow = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 6 },
        });
        defer brow.deinit();

        const button_submitted = components.actionButton(@src(), if (users == 0) "Create Account" else "Set Password", .primary, 9003);
        if (button_submitted or enter_submitted) {
            const uname = webui_user_buf[0..zLen(&webui_user_buf)];
            const pw = webui_pw_buf[0..zLen(&webui_pw_buf)];
            const pw2 = webui_pw2_buf[0..zLen(&webui_pw2_buf)];
            // Same rules as the web page — one tested implementation. "current"
            // is empty because the desktop is the recovery path (see header).
            const verdict = access.checkPasswordChange("", pw, pw2);
            if (uname.len == 0) {
                setWebUiAccountStatus("Enter a username", false);
            } else if (verdict != .ok) {
                setWebUiAccountStatus(verdict.message(), false);
            } else if (auth_store.userIdByName(uname)) |uid| {
                if (auth_store.setPassword(uid, pw) and auth_store.authenticate(uname, pw) == uid) {
                    // A password change that left old logins alive would not
                    // actually revoke anything.
                    const dropped = auth_store.revokeAllSessions(null);
                    var t_buf: [64]u8 = undefined;
                    setWebUiAccountStatus(std.fmt.bufPrint(&t_buf, "Password changed · {d} device(s) signed out", .{dropped}) catch "Password changed", true);
                    @memset(&webui_pw_buf, 0);
                    @memset(&webui_pw2_buf, 0);
                } else setWebUiAccountStatus("Password was not changed", false);
            } else if (users == 0) {
                // First run only — mirrors /api/auth/register, which closes
                // registration once any account exists.
                if (auth_store.createFirstAdmin(uname, pw)) |_| {
                    remote.invalidateSetupToken();
                    setWebUiAccountStatus("Administrator account created — sign in from the Web UI", true);
                    @memset(&webui_pw_buf, 0);
                    @memset(&webui_pw2_buf, 0);
                } else |e| setWebUiAccountStatus(switch (e) {
                    error.SetupClosed => "Account setup is already complete",
                    error.Invalid => "Username 3-32 chars [a-zA-Z0-9._-], password 8+",
                    error.Db => "Database error",
                }, false);
            } else {
                // Previously this fell through to createUser, so a typo in the
                // username silently made a SECOND admin account instead of
                // resetting the one you meant.
                var t_buf: [96]u8 = undefined;
                setWebUiAccountStatus(std.fmt.bufPrint(&t_buf, "No account named \"{s}\"", .{uname}) catch "No such account", false);
            }
        }

        if (webui_account_status_len > 0) {
            _ = dvui.label(@src(), "{s}", .{webui_account_status[0..webui_account_status_len]}, .{
                .id_extra = 9104,
                .color_text = @import("../color_compat.zig").wrap(if (webui_account_status_ok) theme.colors.success else theme.colors.danger),
                .margin = .{ .x = 0, .y = theme.spacing.xxs, .w = 0, .h = theme.spacing.sm },
            });
        }

        if (users == 0 and components.actionButton(@src(), "Copy Setup Code", .secondary, 9005)) {
            var setup: [remote.SETUP_TOKEN_HEX_LEN]u8 = undefined;
            if (remote.setupToken(&setup)) {
                dvui.clipboardTextSet(&setup);
                state.showToast("One-time setup code copied");
            } else {
                state.showToast("Setup code unavailable");
            }
        }

        if (components.actionButton(@src(), "Sign Out All Devices", .danger, 9004)) {
            const dropped = auth_store.revokeAllSessions(null);
            var t_buf: [64]u8 = undefined;
            state.showToast(std.fmt.bufPrint(&t_buf, "{d} device(s) signed out", .{dropped}) catch "Signed out");
        }
    }

    // ── API token ──
    settingRow("API Token", 92, @src());
    {
        _ = dvui.label(@src(), "For the browser extension and automation. Rotating it breaks anything still using the old token.", .{}, .{
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
            .margin = .{ .x = 0, .y = theme.spacing.xxs, .w = 0, .h = 6 },
        });
        var mask_buf: [64]u8 = undefined;
        const tok = remote.tokenHex();
        const shown = if (webui_token_revealed) tok else access.maskToken(tok, &mask_buf);
        _ = dvui.label(@src(), "{s}", .{if (shown.len > 0) shown else "unavailable"}, .{
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
        });

        var trow = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 0, .y = 0, .w = 0, .h = 6 },
        });
        defer trow.deinit();
        if (components.actionButton(@src(), if (webui_token_revealed) "Hide" else "Show", .secondary, 9005)) {
            webui_token_revealed = !webui_token_revealed;
        }
        if (components.actionButton(@src(), "Copy", .secondary, 9006)) {
            dvui.clipboardTextSet(tok);
            state.showToast("API token copied");
        }
        if (components.actionButton(@src(), "Rotate", .danger, 9007)) {
            if (remote.rotateToken()) {
                state.showToast("Token rotated — re-pair the extension");
            } else state.showToast("No entropy source — token unchanged");
        }
    }

    // ── Agent access ──
    settingRow("Agent Access", 95, @src());
    renderAgentAccess();

    // ── Network ──
    settingRow("Network", 93, @src());
    {
        if (!webui_port_seeded) {
            webui_port_seeded = true;
            _ = @import("opal-fmt").bufPrintZ(&webui_port_buf, "{d}", .{remote.port}) catch {};
        }

        const lan = remote.bind_mode == .lan;
        _ = dvui.label(@src(), "{s}", .{if (lan)
            "LAN — any device on your network can reach Opal (sign-in still required)."
        else
            "This machine only — 127.0.0.1, not reachable from the network."}, .{
            .color_text = @import("../color_compat.zig").wrap(if (lan) theme.colors.warning else theme.colors.text_secondary),
            .margin = .{ .x = 0, .y = theme.spacing.xxs, .w = 0, .h = 6 },
        });

        // components.segment, not two hand-rolled buttons: this is a
        // single-select, and the shared control already handles the active
        // fill, hover, keyboard focus and theme tokens. The hand-rolled pair
        // also used a "●" bullet, which is not in the UI font and rendered
        // as tofu (same class of bug as the old "▶"/"←" glyphs).
        if (components.segment(@src(), &.{ "LAN", "This machine only" }, if (lan) 0 else 1)) |pick| {
            const mode: access.BindMode = if (pick == 0) .lan else .loopback;
            if (mode != remote.bind_mode) {
                remote.applyBinding(mode, remote.port);
                state.markConfigDirty();
                state.showToast(if (mode == .lan) "Now reachable on your LAN" else "Now loopback-only");
            }
        }

        // Field on its own line, button on the next — every other action group
        // on this page wraps its buttons in a horizontal row, and a button
        // dropped straight into the vertical column is exactly what mispositions
        // (see the gravity_y note in components.actionButton).
        absField("Port", &webui_port_buf, false, 9301);
        {
            var prow = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = theme.spacing.xs },
            });
            defer prow.deinit();
            if (components.actionButton(@src(), "Apply Port", .primary, 9008)) {
                const txt_port = webui_port_buf[0..zLen(&webui_port_buf)];
                if (access.parsePort(txt_port)) |p| {
                    remote.applyBinding(remote.bind_mode, p);
                    state.markConfigDirty();
                    var t_buf: [48]u8 = undefined;
                    state.showToast(std.fmt.bufPrint(&t_buf, "Now serving on port {d}", .{p}) catch "Port applied");
                } else state.showToast("Port must be 1024-65535");
            }
        }
    }
    renderDeviceSyncSection();
}

/// Settings > Web UI > Device sync: pair with up to MAX_PEERS other Opals over
/// their JSON API (services/library_sync.zig) to exchange progress, favorites,
/// ratings and removals. Pull-then-push; cursors persist per peer, and rows
/// relay between peers (A -> this -> B) without echoing back to their sender.
fn renderDeviceSyncSection() void {
    const lsync = @import("../../services/library_sync.zig");
    const lsync_pure = @import("../../services/library_sync_pure.zig");
    const ls = &state.app.lsync;

    settingRow("Device Sync", 96, @src());
    _ = dvui.label(@src(), "Keep progress, favorites and ratings in step with your other Opals. Use each one's Web UI address and API token.", .{}, .{
        .id_extra = 9400,
        .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
    });

    {
        const auto_before = ls.auto;
        components.toggleRow(@src(), "Sync automatically", "Every 10 minutes while Opal is open", &ls.auto);
        if (ls.auto != auto_before) state.markConfigDirty();
    }

    const busy = lsync.isBusy();
    var remove_idx: ?usize = null;
    for (ls.peers[0..ls.peer_count], 0..) |*p, i| {
        const base: usize = 9410 + i * 10;
        var card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = i,
            .expand = .horizontal,
            .background = true,
            .color_fill = @import("../color_compat.zig").wrap(theme.colors.bg_elevated),
            .color_border = @import("../color_compat.zig").wrap(theme.colors.border_subtle),
            .border = dvui.Rect.all(1),
            .corners = theme.dims.rad_sm,
            .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = 0 },
            .padding = dvui.Rect.all(theme.spacing.sm),
        });
        defer card.deinit();

        var title_buf: [48]u8 = undefined;
        _ = dvui.label(@src(), "{s}", .{std.fmt.bufPrint(&title_buf, "Device {d}", .{i + 1}) catch "Device"}, .{
            .id_extra = base,
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_primary),
        });
        const before = std.hash.Wyhash.hash(0, &p.url) ^ std.hash.Wyhash.hash(1, &p.token);
        absField("Address", &p.url, false, base + 1);
        absField("API token", &p.token, true, base + 2);
        if (std.hash.Wyhash.hash(0, &p.url) ^ std.hash.Wyhash.hash(1, &p.token) != before) state.markConfigDirty();

        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = base,
                .expand = .horizontal,
                .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = theme.spacing.xs },
            });
            defer row.deinit();
            const peer_busy = lsync.peerBusy(p);
            if (components.actionButton(@src(), if (peer_busy) "Syncing..." else "Sync Now", .primary, base + 3) and !peer_busy) {
                _ = lsync.syncNow(i);
            }
            if (components.confirmDangerButton(@src(), "Remove", base + 4)) remove_idx = i;
            // Continuum: take over whatever that device is playing, at its position.
            const handoff = @import("../../services/handoff.zig");
            if (components.actionButton(@src(), if (handoff.busy()) "Handing off..." else "Bring Playback Here", .secondary, base + 7) and !handoff.busy()) {
                _ = handoff.startPeerJob(i, true);
            }
        }

        var line_buf: [96]u8 = undefined;
        const last_line: []const u8 = if (p.last_sync <= 0) "Never synced" else blk: {
            const ago = @max(0, @import("../../core/io_global.zig").timestamp() - p.last_sync);
            break :blk if (ago < 60)
                "Last sync: just now"
            else if (ago < 3600)
                std.fmt.bufPrint(&line_buf, "Last sync: {d} min ago", .{@divTrunc(ago, 60)}) catch "Last sync: earlier"
            else if (ago < 86400)
                std.fmt.bufPrint(&line_buf, "Last sync: {d} h ago", .{@divTrunc(ago, 3600)}) catch "Last sync: earlier"
            else
                std.fmt.bufPrint(&line_buf, "Last sync: {d} d ago", .{@divTrunc(ago, 86400)}) catch "Last sync: earlier";
        };
        _ = dvui.label(@src(), "{s}", .{last_line}, .{
            .id_extra = base + 5,
            .color_text = @import("../color_compat.zig").wrap(theme.colors.text_secondary),
        });
        if (p.status_len > 0) {
            _ = dvui.label(@src(), "{s}", .{p.status[0..p.status_len]}, .{
                .id_extra = base + 6,
                .color_text = @import("../color_compat.zig").wrap(theme.colors.text_tertiary),
            });
        }
    }
    if (remove_idx) |i| {
        lsync_pure.removePeer(&ls.peers, &ls.peer_count, i);
        state.markConfigDirty();
    }

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .margin = .{ .x = 0, .y = theme.spacing.sm, .w = 0, .h = theme.spacing.xs },
    });
    defer row.deinit();
    if (ls.peer_count < lsync_pure.MAX_PEERS and components.actionButton(@src(), "Add Device", .secondary, 9460)) {
        _ = lsync_pure.addPeer(&ls.peers, &ls.peer_count);
        state.markConfigDirty();
    }
    // Peers already running are skipped by syncNow; the rest start in parallel.
    if (ls.peer_count > 1 and components.actionButton(@src(), if (busy) "Syncing..." else "Sync All", .secondary, 9461)) {
        _ = lsync.syncNow(null);
    }
}
