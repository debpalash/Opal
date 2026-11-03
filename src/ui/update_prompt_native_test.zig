//! Real native widgets; owned demo releases never contact the update service.
const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const updater = @import("../services/updater.zig");
const prompt = @import("update_prompt.zig");
const theme = @import("theme.zig");
const browser = @import("../services/browser.zig");
const workers = @import("../core/workers.zig");
const alloc = @import("../core/alloc.zig").allocator;
var phase: enum { browser, available, downloading, ready, failed } = .available;
var frame: usize = 0;
var click: enum { none, primary, later } = .none;
var observed: prompt.Action = .none;
fn setup() !void {
    frame = 0;
    observed = .none;
    theme.active_preset = .midnight;
    state.app.ui_scale = 1;
    state.app.page_shell_enabled = true;
    state.app.onboarded = true;
    state.app.router.current = .browse;
    state.app.browse_source = .Web;
    @import("shell.zig").setSidebarFixtureForTest(false);
    browser.resetTabsForTest();
}
fn draw() !void {
    @import("components.zig").beginFrame();
    @import("native_browser.zig").beginFrame();
    defer @import("native_browser.zig").endFrame();
    if (frame == 5 and click != .none) {
        const rect = if (click == .primary) prompt.primary_bounds else prompt.later_bounds;
        try std.testing.expect(rect.w > 0 and rect.h >= 24 * dvui.windowNaturalScale());
        _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = rect.center() });
        _ = try dvui.currentWindow().addEventMouseButton(.left, .press);
        _ = try dvui.currentWindow().addEventMouseButton(.left, .release);
    }
    try @import("shell.zig").render();
    if (phase != .browser) {
        var value: updater.Snapshot = .{ .has_update = true, .show_prompt = true };
        value.selection.version.set("0.9.3"); // Illustrative next release, never checked or downloaded.
        value.selection.mode = .bundle;
        value.selection.size = 100_000_000;
        value.downloaded = 67_000_000;
        value.is_downloading = phase == .downloading;
        value.is_ready = phase == .ready;
        if (phase == .failed) {
            const message = "Update download failed. Your app has not changed.";
            @memcpy(value.last_error_buf[0..message.len], message);
            value.last_error_len = message.len;
        }
        const action = prompt.renderSnapshot(value);
        if (action != .none) observed = action;
        if (frame >= 3) {
            const r = prompt.bounds;
            const viewport = dvui.windowRectPixels();
            try std.testing.expect(r.w > 0 and r.h > 0 and r.x >= 0 and r.y >= 0);
            try std.testing.expect(r.x + r.w <= viewport.w + 1 and r.y + r.h <= viewport.h + 1);
            const stack = dvui.currentWindow().subwindows.stack.items;
            for (stack) |sw| if (sw.id == prompt.popup_id.?) try std.testing.expect(!sw.modal);
        }
    }
    frame += 1;
}
fn cleanup() void {
    browser.resetTabsForTest();
    @import("shell.zig").setSidebarFixtureForTest(null);
    prompt.popup_id = null;
    prompt.bounds = .{};
}
test "Native updater renders real browser and corner notification states with clickable actions" {
    const logs = @import("../core/logs.zig");
    logs.logs_allocator = alloc;
    defer logs.deinit();
    workers.init();
    workers.beginShutdownAndDrain(0);
    defer workers.finishShutdown();
    // Public demo history in the test profile, never a user's real history.
    const db = @import("../core/db.zig");
    db.init();
    defer db.deinit();
    try std.testing.expect(db.get() != null);
    db.exec("DELETE FROM browser_history");
    db.exec("INSERT INTO browser_history(url,title,last_visit) VALUES ('https://www.youtube.com/','YouTube',3),('https://www.marvel.com/comics','Marvel Comics',2),('https://www.blender.org/','Blender',1)");
    const capture = @import("native_capture.zig");
    inline for (.{ .browser, .available, .downloading, .ready, .failed }, .{ "browser", "update-available", "update-downloading", "update-ready", "update-failed" }) |p, name| {
        phase = p;
        click = .none;
        for ([_]u32{ 375, 640, 1280 }) |width| try capture.capture(width, 800, name, setup, draw, cleanup);
    }
    for ([_]@TypeOf(phase){ .available, .ready, .downloading }) |p| {
        phase = p;
        click = if (p == .downloading) .later else .primary;
        try capture.capture(640, 800, "update-interaction", setup, draw, cleanup);
        const expected: prompt.Action = if (p == .available) .download else if (p == .ready) .restart else .later;
        try std.testing.expectEqual(expected, observed);
    }
}
