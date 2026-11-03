//! Real WebKit and Cocoa desktop surfaces in an isolated hidden SDL window.
const std = @import("std");
const dvui = @import("dvui");
const io = @import("../core/io_global.zig");
const alloc = @import("../core/alloc.zig").allocator;
const native = @import("../services/native_browser.zig");
const state = @import("../core/state.zig");
const theme = @import("theme.zig");
extern fn opal_wallpaper_start(path: [*:0]const u8, fill: c_int) c_int;
extern fn opal_wallpaper_stop() void;
extern fn opal_wallpaper_test_desktop() c_int;
extern fn opal_browser_test_visible() c_int;
extern fn opal_browser_test_snapshot(path: [*:0]const u8) void;
extern fn opal_browser_test_snapshot_result() c_int;
fn frame(window: *dvui.Window, index: usize, show: bool) !void {
    try window.begin(@as(i128, @intCast(index + 1)) * 16_666_667);
    @import("native_browser.zig").beginFrame();
    if (show) @import("../services/browser.zig").renderContent();
    @import("native_browser.zig").endFrame();
    _ = try window.end(.{});
}
test "Native embedded browser renders HTML and extracts actual DOM text" {
    var backend = try dvui.backend.initWindow(.{ .io = io.io(), .org = "debpalash", .app = "Opal-browser-fixture", .persist_window_geometry = false, .size = .{ .w = 800, .h = 600 }, .vsync = false, .title = "Opal isolated WebKit fixture", .hidden = true });
    defer backend.deinit();
    var window = try dvui.Window.init(@src(), alloc, backend.backend(), .{});
    defer window.deinit();
    defer native.deinit();
    defer state.app.command_palette_open = false;
    const old_private = state.app.incognito_mode;
    state.app.incognito_mode = true;
    defer state.app.incognito_mode = old_private;
    theme.markUiThread();
    for (0..8) |i| try frame(&window, i, true);
    try std.testing.expectEqual(@as(c_int, 1), opal_browser_test_visible());
    try std.testing.expectEqual(@as(c_int, 1), native.api.opal_browser_test_attached());
    const Fixture = struct {
        const html = "<html><head><title>Opal embedded fixture</title></head><body><input value='Native typing'><button onclick=\"document.body.dataset.clicked='yes'\">Click</button><p>Native WebKit page</p><script>document.querySelector('button').click();document.title += document.body.dataset.clicked === 'yes' ? ' interactive' : ' broken';</script></body></html>";
        fn serve(listener: *std.Io.net.Server) void {
            const stream = listener.accept(io.io()) catch return;
            defer stream.close(io.io());
            var in: [2048]u8 = undefined;
            var reader = stream.reader(io.io(), &in);
            while (true) {
                const line = reader.interface.takeDelimiterInclusive('\n') catch return;
                if (std.mem.eql(u8, line, "\r\n")) break;
            }
            var out: [2048]u8 = undefined;
            var writer = stream.writer(io.io(), &out);
            writer.interface.print("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ html.len, html }) catch return;
            writer.interface.flush() catch {};
        }
    };
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io.io(), .{ .reuse_address = true });
    defer server.deinit(io.io());
    var response = try io.io().concurrent(Fixture.serve, .{&server});
    defer _ = response.cancel(io.io());
    var requested_buf: [128]u8 = undefined;
    const requested = try std.fmt.bufPrint(&requested_buf, "http://127.0.0.1:{d}/native", .{server.socket.address.getPort()});
    const browser = @import("../services/browser.zig");
    browser.navigate(requested);
    _ = browser.takeBridgeViewRequest();
    try frame(&window, 8, true);
    var url: [2048]u8 = @splat(0);
    var title: [256]u8 = @splat(0);
    var err: [256]u8 = @splat(0);
    var loading: c_int = 0;
    var found: c_int = -1;
    var loaded = false;
    for (0..1000) |_| {
        native.api.opal_browser_test_pump();
        _ = native.api.opal_browser_poll(&url, url.len, &title, title.len, &err, err.len, &loading, &found);
        if (std.mem.eql(u8, std.mem.sliceTo(&title, 0), "Opal embedded fixture interactive") and loading == 0) {
            loaded = true;
            break;
        }
    }
    try std.testing.expect(loaded);
    try std.testing.expectEqualStrings(requested, std.mem.sliceTo(&url, 0));
    native.api.opal_browser_read();
    var text: [8192]u8 = undefined;
    var read = false;
    for (0..300) |_| {
        native.api.opal_browser_test_pump();
        const flags = native.api.opal_browser_poll(&url, url.len, &title, title.len, &err, err.len, &loading, &found);
        if (flags & 32 != 0) {
            const n = native.api.opal_browser_reader(&text, text.len);
            try std.testing.expect(std.mem.indexOf(u8, text[0..n], "Native WebKit page") != null);
            read = true;
            break;
        }
    }
    try std.testing.expect(read);
    native.api.opal_browser_find("Native WebKit", 0);
    var match = false;
    for (0..300) |_| {
        native.api.opal_browser_test_pump();
        const flags = native.api.opal_browser_poll(&url, url.len, &title, title.len, &err, err.len, &loading, &found);
        if (flags & 16 != 0) {
            match = found == 1;
            break;
        }
    }
    try std.testing.expect(match);
    // Navigation away and global controls must never be covered by the native child.
    try frame(&window, 9, false);
    try std.testing.expectEqual(@as(c_int, 0), opal_browser_test_visible());
    try frame(&window, 10, true);
    try std.testing.expectEqual(@as(c_int, 1), opal_browser_test_visible());
    state.app.command_palette_open = true;
    try frame(&window, 11, true);
    try std.testing.expectEqual(@as(c_int, 0), opal_browser_test_visible());
    state.app.command_palette_open = false;
    try frame(&window, 12, true);
    if (io.getenv("OPAL_NATIVE_BROWSER_SNAPSHOT")) |path| {
        var path_z: [2048:0]u8 = @splat(0);
        if (path.len >= path_z.len) return error.PathTooLong;
        @memcpy(path_z[0..path.len], path);
        opal_browser_test_snapshot(&path_z);
        for (0..300) |_| {
            native.api.opal_browser_test_pump();
            if (opal_browser_test_snapshot_result() != 0) break;
        }
        try std.testing.expectEqual(@as(c_int, 1), opal_browser_test_snapshot_result());
    }
}
extern fn opal_wallpaper_status() c_int;
test "Native embedded browser companion wallpaper is below icons and never takes focus" {
    const workers = @import("../core/workers.zig");
    workers.init();
    defer workers.finishShutdown();
    defer workers.beginShutdownAndDrain(0);
    var backend = try dvui.backend.initWindow(.{ .io = io.io(), .org = "debpalash", .app = "Opal-wallpaper-fixture", .persist_window_geometry = false, .size = .{ .w = 320, .h = 200 }, .vsync = false, .title = "Opal isolated wallpaper fixture", .hidden = true });
    defer backend.deinit();
    var temp: [1024]u8 = undefined;
    var path_buf: [1400]u8 = undefined;
    const path_text = try std.fmt.bufPrint(&path_buf, "{s}/opal-wallpaper-fixture-{d}.mp4", .{ io.tmpDir(&temp), io.milliTimestamp() });
    path_buf[path_text.len] = 0;
    const path = path_buf[0..path_text.len :0];
    defer io.cwdDeleteFile(path) catch {};
    var output: [2048]u8 = undefined;
    const result = @import("../core/bounded_process.zig").run(&.{ "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=black:s=64x64:r=10", "-t", "0.3", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-y", path }, &output, .{ .timeout_ms = 15_000 });
    if (!result.ok()) return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(c_int, 1), opal_wallpaper_start(path, 1));
    defer opal_wallpaper_stop();
    try std.testing.expectEqual(@as(c_int, 1), opal_wallpaper_test_desktop());
    var ready = false;
    for (0..1000) |_| {
        native.api.opal_browser_test_pump();
        const status = opal_wallpaper_status();
        try std.testing.expect(status >= 0);
        if (status == 1) {
            ready = true;
            break;
        }
    }
    try std.testing.expect(ready);
    try std.testing.expectEqual(@as(c_int, 1), opal_wallpaper_test_desktop());
    opal_wallpaper_stop();
    try std.testing.expectEqual(@as(c_int, -1), opal_wallpaper_status());
}
