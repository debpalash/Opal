//! UI-position restore across restarts — live-state glue.
//!
//! Captures page / Browse source / Settings section / search text / TV detail /
//! main scroll into `<profile data dir>/ui_restore.txt`, and puts it back once
//! on launch after config has loaded. All policy (what to restore, staleness,
//! id/enum validation, scroll settling) is in core/ui_restore_pure.zig.
//!
//! Why a file and not the config table: dev.sh SIGKILLs the old binary 0.5 s
//! after SIGTERM, before appDeinit reaches config.save() (it waits for the
//! worker drain). The snapshot is written on change (polled once a second),
//! refreshed every minute, and once more at the start of appDeinit — so a
//! rebuild, a crash or a slow shutdown all keep the position.
//!
//! UI thread only: every function here runs from appFrame/appDeinit or from a
//! page render, so the module statics need no locking.

const std = @import("std");
const state = @import("../core/state.zig");
const io = @import("../core/io_global.zig");
const paths = @import("../core/paths.zig");
const alloc = @import("../core/alloc.zig").allocator;
const pure = @import("../core/ui_restore_pure.zig");
const Route = @import("../core/router.zig").Route;
const scroll = @import("../core/ui_restore_scroll.zig");

const FILE_NAME = "ui_restore.txt";
var restore_done = false;
/// Page a restored scroll belongs to; navigating away cancels it.
var pending_route: Route = .home;

var last_body: [pure.MAX_ENCODED]u8 = undefined;
var last_body_len: usize = 0;
var last_write_s: i64 = 0;
var last_check_s: i64 = 0;

fn filePath(buf: []u8, suffix: []const u8) ?[]const u8 {
    var dir_buf: [512]u8 = undefined;
    const dir = paths.profileDataDir(&dir_buf);
    return std.fmt.bufPrint(buf, "{s}/{s}{s}", .{ dir, FILE_NAME, suffix }) catch null;
}

/// Per frame from appFrame. Restores once config is loaded, then keeps the
/// on-disk snapshot current. `launched_with_target`: a file/URL argument.
pub fn tick(launched_with_target: bool) void {
    if (!restore_done) {
        if (!state.app.config_loaded.load(.acquire)) return;
        restore_done = true;
        restore(launched_with_target);
        return;
    }
    const now = io.timestamp();
    if (now == last_check_s) return;
    last_check_s = now;
    // Navigating away cancels a scroll that never got its content.
    if (scroll.pending_target != .none and state.app.router.current != pending_route) scroll.cancel();
    persist(now, false);
}

/// Start of appDeinit: stamp the quit time so the staleness window is measured
/// from the exit, not from the last navigation.
pub fn captureOnQuit() void {
    if (!restore_done) return; // never overwrite an unrestored snapshot with Home
    persist(io.timestamp(), true);
}

fn restore(launched_with_target: bool) void {
    var path_buf: [600]u8 = undefined;
    const path = filePath(&path_buf, "") orelse return;
    const raw = io.cwdReadFileAlloc(path, alloc, pure.MAX_ENCODED) catch return;
    defer alloc.free(raw);
    const snap = pure.decode(raw) orelse return;
    const r = &state.app.router;
    const env: pure.Env = .{
        .now = io.timestamp(),
        .dev_reload = io.getenv("OPAL_DEV_RELOAD") != null,
        .launched_with_target = launched_with_target or state.app.players.items.len > 0,
        .already_navigated = r.current != .home or r.back_len > 0,
        .onboarding = !state.app.onboarded,
        .incognito = state.app.incognito_mode,
    };
    const p = pure.plan(Route, state.DrawerTab, state.SettingsTab, snap, env);
    if (p.isEmpty()) return;

    const search = @import("../services/search.zig");
    if (p.settings) |s| state.app.settings_tab = s;
    if (p.query.len > 0) {
        if (p.rerun_search) search.submitQuery(p.query) else search.setUniversalQuery(p.query);
    }
    if (p.tv_id != 0) {
        // Navigates to Browse/TMDB itself and refetches seasons/episodes.
        @import("../services/tmdb.zig").openTvDetailById(p.tv_id, p.tv_name, "");
    } else if (p.route) |route| {
        if (p.browse) |b| {
            state.app.browse_source = b;
            state.app.drawer_tab = b;
        }
        r.navigate(route);
    }
    if (p.scroll_target != .none) {
        scroll.arm(p.scroll_target, p.scroll_y);
        pending_route = r.current;
    }
    var log_buf: [96]u8 = undefined;
    @import("../core/logs.zig").pushLog("info", "restore", std.fmt.bufPrint(&log_buf, "Restored {s}{s}", .{
        @tagName(r.current), if (p.tv_id != 0) " + detail" else "",
    }) catch "Restored UI position", false);
}

fn snapshot(saved_at: i64) pure.Snapshot {
    const route = @tagName(state.app.router.current);
    const browse = @tagName(state.app.browse_source);
    const t = &state.app.tmdb;
    const detail_open = state.app.router.current == .browse and state.app.browse_source == .TMDB and
        t.tv_detail_open and pure.validTmdbId(t.tv_id);
    const target = pure.scrollTargetFor(route, browse, detail_open);
    const search_buf = &@import("../services/search.zig").search_buf;
    const query_len = std.mem.indexOfScalar(u8, search_buf, 0) orelse search_buf.len;
    return .{
        .saved_at = saved_at,
        .route = route,
        .browse = browse,
        .settings = @tagName(state.app.settings_tab),
        .tv_id = if (detail_open) t.tv_id else 0,
        .tv_name = if (detail_open) t.tv_name[0..@min(t.tv_name_len, t.tv_name.len)] else "",
        .scroll_y = scroll.current(target),
        .query = search_buf[0..query_len],
    };
}

fn persist(now: i64, force: bool) void {
    if (state.app.incognito_mode or state.app.is_headless) return;
    var body_buf: [pure.MAX_ENCODED]u8 = undefined;
    const body = pure.encode(snapshot(0), &body_buf);
    if (body.len == 0) return;
    const changed = !std.mem.eql(u8, body, last_body[0..last_body_len]);
    if (!force and !pure.shouldPersist(changed, now, last_write_s)) return;

    var line_buf: [pure.MAX_ENCODED]u8 = undefined;
    const line = pure.encode(snapshot(now), &line_buf);
    var path_buf: [600]u8 = undefined;
    var tmp_buf: [600]u8 = undefined;
    const path = filePath(&path_buf, "") orelse return;
    const tmp = filePath(&tmp_buf, ".tmp") orelse return;
    io.cwdWriteFile(.{ .sub_path = tmp, .data = line }) catch return;
    io.renameAbsolute(tmp, path) catch return;
    @memcpy(last_body[0..body.len], body);
    last_body_len = body.len;
    last_write_s = now;
}
