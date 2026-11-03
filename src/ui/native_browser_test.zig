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
extern fn opal_browser_test_page_width() f64;
extern fn opal_browser_test_clip_width() f64;
extern fn opal_extensions_test_tab_count() c_int;
extern fn opal_browser_test_metadata_reads() u64;
extern fn opal_browser_test_presentation_writes() u64;
extern fn opal_extensions_test_settings_applications() u64;
extern fn opal_browser_test_focus() void;
extern fn opal_browser_test_key(text: [*:0]const u8, code: c_ushort, command: c_int, repeat: c_int) void;
extern fn opal_app_menu_test_new_tab() void;
extern fn opal_app_menu_test_close() void;
var profile_prepared = false;
fn prepareProfile() !void {
    if (profile_prepared) return;
    {
        const home = @import("../core/paths.zig").homeDir();
        var path: [4096]u8 = undefined;
        for ([_][]const u8{ "Library/Caches", "Library/WebKit", "config", "cache", "data" }) |suffix| {
            try std.Io.Dir.cwd().createDirPath(io.io(), try std.fmt.bufPrint(&path, "{s}/{s}", .{ home, suffix }));
        }
    }
    profile_prepared = true;
}
const TabServer = struct {
    stopping: std.atomic.Value(bool) = .init(false),
    fn serve(listener: *std.Io.net.Server, self: *@This()) void {
        while (!self.stopping.load(.acquire)) {
            const stream = listener.accept(io.io()) catch return;
            defer stream.close(io.io());
            if (self.stopping.load(.acquire)) return;
            var ready = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            if ((std.posix.poll(&ready, 1000) catch continue) == 0) continue;
            var incoming: [4096]u8 = undefined;
            var reader = stream.reader(io.io(), &incoming);
            const request = reader.interface.takeDelimiterInclusive('\n') catch continue;
            const second = std.mem.indexOf(u8, request, "/second") != null;
            const next = std.mem.indexOf(u8, request, "/b ") != null;
            while (true) {
                const line = reader.interface.takeDelimiterInclusive('\n') catch break;
                if (std.mem.eql(u8, line, "\r\n")) break;
            }
            const body = if (second) "<title>Second tab</title><input id='entry' value='second tab'>" else if (next) "<title>First B</title><p>Separate navigation</p>" else "<title>First A</title><input id='entry' value='original'><iframe srcdoc='<p>Frame ready</p>'></iframe>";
            var outgoing: [2048]u8 = undefined;
            var writer = stream.writer(io.io(), &outgoing);
            writer.interface.print("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {d}\r\nCache-Control: max-age=60\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch continue;
            writer.interface.flush() catch {};
        }
    }
};
fn ownedNavigate(port: u16, path: []const u8, title: []const u8) !void {
    var url: [128:0]u8 = @splat(0);
    _ = try std.fmt.bufPrint(&url, "http://127.0.0.1:{d}/{s}", .{ port, path });
    native.api.opal_browser_navigate(&url);
    try pageTitle(title);
}
fn pageTitle(wanted: []const u8) !void {
    var url: [2048]u8 = @splat(0);
    var title: [256]u8 = @splat(0);
    var err: [256]u8 = @splat(0);
    var loading: c_int = 0;
    var found: c_int = 0;
    for (0..1000) |_| {
        native.api.opal_browser_test_pump();
        _ = native.api.opal_browser_poll(&url, url.len, &title, title.len, &err, err.len, &loading, &found);
        // Owned documents publish their title as the readiness marker. WebKit
        // may keep its network-loading bit set in an occluded test window.
        if (std.mem.eql(u8, std.mem.sliceTo(&title, 0), wanted)) return;
    }
    std.debug.print("Tab fixture expected {s}, received {s}; error={s}\n", .{ wanted, std.mem.sliceTo(&title, 0), std.mem.sliceTo(&err, 0) });
    return error.Timeout;
}
fn pageScript(script: [*:0]const u8, out: []u8) ![]const u8 {
    const api = @import("../services/browser_privacy.zig").api;
    api.opal_extensions_test_eval(script);
    for (0..1000) |_| {
        native.api.opal_browser_test_pump();
        if (api.opal_extensions_test_result(out.ptr, out.len) != 0) return std.mem.sliceTo(out, 0);
    }
    return error.Timeout;
}
fn frame(window: *dvui.Window, index: usize, show: bool) !void {
    try prepareProfile();
    try window.begin(@as(i128, @intCast(index + 1)) * 16_666_667);
    @import("native_browser.zig").beginFrame();
    if (show) @import("../services/browser.zig").renderContent();
    @import("native_browser.zig").endFrame();
    _ = try window.end(.{});
}
test "Native embedded browser keyboard types each character once and returns focus to Opal" {
    const browser = @import("../services/browser.zig");
    const c = @import("../core/c.zig").sdl;
    browser.resetTabsForTest();
    defer browser.resetTabsForTest();
    var backend = try dvui.backend.initWindow(.{ .io = io.io(), .org = "debpalash", .app = "Opal-keyboard-regression", .persist_window_geometry = false, .size = .{ .w = 800, .h = 500 }, .vsync = false, .title = "Opal keyboard regression", .hidden = true });
    defer backend.deinit();
    var window = try dvui.Window.init(@src(), alloc, backend.backend(), .{});
    defer window.deinit();
    theme.markUiThread();
    var original_filter: c.SDL_EventFilter = null;
    var original_userdata: ?*anyopaque = null;
    _ = c.SDL_GetEventFilter(&original_filter, &original_userdata);
    for (0..8) |i| try frame(&window, i, true);
    native.api.opal_browser_test_html("<title>Typing ready</title><input id='entry' style='width:300px;height:80px'>");
    try pageTitle("Typing ready");
    opal_browser_test_focus();
    opal_browser_test_key("l", 37, 1, 0);
    native.api.opal_browser_test_pump();
    try frame(&window, 8, true);
    try std.testing.expect(c.SDL_IsTextInputActive() != 0);
    opal_browser_test_focus();
    var out: [256]u8 = undefined;
    _ = try pageScript("document.querySelector('#entry').focus();'focused'", &out);
    try frame(&window, 9, true);
    c.SDL_FlushEvents(c.SDL_KEYDOWN, c.SDL_TEXTINPUT);
    opal_browser_test_key("a", 0, 0, 0);
    try std.testing.expectEqualStrings("a", try pageScript("document.querySelector('#entry').value", &out));
    try std.testing.expect(c.SDL_IsTextInputActive() == 0);
    try std.testing.expect(c.SDL_HasEvent(c.SDL_KEYDOWN) == 0);
    opal_browser_test_key("a", 0, 0, 1);
    try std.testing.expectEqualStrings("aa", try pageScript("document.querySelector('#entry').value", &out));
    opal_browser_test_key("l", 37, 1, 0);
    native.api.opal_browser_test_pump();
    try frame(&window, 10, true);
    try std.testing.expect(c.SDL_IsTextInputActive() != 0);
    browser.resetTabsForTest();
    var restored_filter: c.SDL_EventFilter = null;
    var restored_userdata: ?*anyopaque = null;
    _ = c.SDL_GetEventFilter(&restored_filter, &restored_userdata);
    try std.testing.expect(original_filter == restored_filter);
    try std.testing.expect(original_userdata == restored_userdata);
}
test "Native embedded browser keyboard menu actions wake without mirrored SDL keys" {
    try @import("../macos/app_menu.zig").verifyWakeForTest();
}
test "Native embedded browser opens directly with sharing above the page in a modal" {
    const hub = @import("browser_hub.zig");
    const browser = @import("../services/browser.zig");
    const old_route = state.app.router;
    const old_source = state.app.browse_source;
    state.app.router.current = .browse;
    state.app.browse_source = .Web;
    defer {
        state.app.router = old_route;
        state.app.browse_source = old_source;
    }
    hub.setRenderFixtureForTest(.{});
    defer hub.setRenderFixtureForTest(null);
    browser.resetTabsForTest();
    defer browser.resetTabsForTest();
    var backend = try dvui.backend.initWindow(.{ .io = io.io(), .org = "debpalash", .app = "Opal-browser-workspace-modal", .persist_window_geometry = false, .size = .{ .w = 1000, .h = 780 }, .vsync = false, .title = "Opal browser workspace regression", .hidden = true });
    defer backend.deinit();
    var window = try dvui.Window.init(@src(), alloc, backend.backend(), .{});
    defer window.deinit();
    const Fixture = struct {
        fn draw(w: *dvui.Window, index: usize, escape: bool) !void {
            try prepareProfile();
            try w.begin(@as(i128, @intCast(index + 1)) * 16_666_667);
            errdefer _ = w.end(.{}) catch null;
            @import("components.zig").beginFrame();
            @import("native_browser.zig").beginFrame();
            if (escape) _ = try w.addEventKey(.{ .code = .escape, .action = .down, .mod = .none });
            hub.render();
            @import("native_browser.zig").endFrame();
            _ = try w.end(.{});
        }
    };
    theme.markUiThread();
    for (0..8) |i| try Fixture.draw(&window, i, false);
    try std.testing.expect(hub.browsing() and browser.isStartPage());
    try std.testing.expectEqual(@as(f32, 0), hub.workspace_modal_for_test.h);
    native.api.opal_browser_test_html("<title>Workspace background</title><input>");
    try pageTitle("Workspace background");
    try Fixture.draw(&window, 8, false);
    try std.testing.expectEqual(@as(c_int, 1), opal_browser_test_visible());
    hub.openWorkspace();
    for (9..17) |i| try Fixture.draw(&window, i, false);
    try std.testing.expect(hub.workspace_modal_for_test.h > 0);
    try std.testing.expectEqual(@as(c_int, 0), opal_browser_test_visible());
    try Fixture.draw(&window, 17, true);
    try Fixture.draw(&window, 18, false);
    try std.testing.expectEqual(@as(f32, 0), hub.workspace_modal_for_test.h);
    try std.testing.expectEqual(@as(c_int, 1), opal_browser_test_visible());
    hub.openWorkspace();
    browser.requestBridgeView();
    try Fixture.draw(&window, 19, false);
    try std.testing.expectEqual(@as(f32, 0), hub.workspace_modal_for_test.h);
}
test "Native embedded browser security measures owned traffic and removes tracking cookies" {
    const privacy = @import("../services/browser_privacy.zig");
    const browser = @import("../services/browser.zig");
    const old_private = state.app.incognito_mode;
    state.app.incognito_mode = true;
    defer state.app.incognito_mode = old_private;
    browser.resetTabsForTest();
    defer browser.resetTabsForTest();
    var backend = try dvui.backend.initWindow(.{ .io = io.io(), .org = "debpalash", .app = "Opal-shield-regression", .persist_window_geometry = false, .size = .{ .w = 800, .h = 600 }, .vsync = false, .title = "Opal privacy regression", .hidden = true });
    defer backend.deinit();
    var window = try dvui.Window.init(@src(), alloc, backend.backend(), .{});
    defer window.deinit();
    theme.markUiThread();
    for (0..8) |i| try frame(&window, i, true);
    try std.testing.expectEqual(@as(usize, 0), browser.recentsForStart().len);
    privacy.api.opal_extensions_security_configure(@embedFile("../services/browser_security.js"));
    privacy.api.opal_extensions_configure("{\"canvas\":false,\"proxy_mode\":\"system\",\"block_ads\":true,\"block_trackers\":true,\"clean_tracking_cookies\":true}", "", 0);
    defer privacy.api.opal_extensions_configure("{\"canvas\":true,\"proxy_mode\":\"system\"}", @embedFile("../services/browser_canvas_guard.js"), 0);
    for (0..500) |_| {
        native.api.opal_browser_test_pump();
        if (privacy.api.opal_security_rules_ready() != 0) break;
    }
    try std.testing.expect(privacy.api.opal_security_rules_ready() != 0);
    privacy.resetStats();
    var server = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io.io(), .{ .reuse_address = true });
    defer server.deinit(io.io());
    var fixture: TabServer = .{};
    var response = try io.io().concurrent(TabServer.serve, .{ &server, &fixture });
    defer {
        fixture.stopping.store(true, .release);
        if (server.socket.address.connect(io.io(), .{ .mode = .stream })) |connection| connection.close(io.io()) else |_| {}
        _ = response.cancel(io.io());
    }
    try ownedNavigate(server.socket.address.getPort(), "a", "First A");
    var out: [256]u8 = undefined;
    _ = try pageScript("document.cookie='_ga=tracking;path=/';document.cookie='sessionid=keep;path=/';let ad=new Image();ad.src='https://pagead2.googlesyndication.com/opal-native-fixture.gif';document.body.append(ad);'set'", &out);
    for (0..800) |_| {
        native.api.opal_browser_test_pump();
        const stats = privacy.stats();
        if (stats.bytes > 0 and stats.ads > 0 and stats.cookies > 0) break;
    }
    const stats = privacy.stats();
    try std.testing.expect(stats.bytes > 0);
    try std.testing.expect(stats.ads > 0);
    try std.testing.expect(stats.cookies > 0);
    try std.testing.expectEqualStrings("1", try pageScript("!document.cookie.includes('_ga=') && document.cookie.includes('sessionid=keep')", &out));
    privacy.resetStats();
    try std.testing.expectEqual(@as(u64, 0), privacy.stats().cookies);
}
test "Native embedded browser security pool verifies the proxy route and expires leases" {
    const privacy = @import("../services/browser_privacy.zig");
    const Fixture = struct {
        seen: std.atomic.Value(bool) = .init(false),
        fn serve(listener: *std.Io.net.Server, self: *@This()) void {
            const stream = listener.accept(io.io()) catch return;
            defer stream.close(io.io());
            var ready = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            if ((std.posix.poll(&ready, 1500) catch return) == 0) return;
            var input: [4096]u8 = undefined;
            var reader = stream.reader(io.io(), &input);
            const line = reader.interface.takeDelimiterInclusive('\n') catch return;
            self.seen.store(std.mem.startsWith(u8, line, "CONNECT example.com:443 "), .release);
            var output: [256]u8 = undefined;
            var writer = stream.writer(io.io(), &output);
            writer.interface.writeAll("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch return;
            writer.interface.flush() catch {};
        }
    };
    try prepareProfile();
    var server = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io.io(), .{ .reuse_address = true });
    defer server.deinit(io.io());
    var fixture: Fixture = .{};
    var response = try io.io().concurrent(Fixture.serve, .{ &server, &fixture });
    defer {
        if (server.socket.address.connect(io.io(), .{ .mode = .stream })) |connection| connection.close(io.io()) else |_| {}
        _ = response.cancel(io.io());
    }
    var config: [1024:0]u8 = @splat(0);
    _ = try std.fmt.bufPrint(&config, "{{\"proxy_mode\":\"pool\",\"profiles\":[{{\"kind\":\"http\",\"host\":\"127.0.0.1\",\"port\":{d}}},{{\"kind\":\"http\",\"host\":\"127.0.0.1\",\"port\":9}}]}}", .{server.socket.address.getPort()});
    privacy.api.opal_extensions_configure(&config, "", 0);
    defer privacy.api.opal_extensions_configure("{\"proxy_mode\":\"system\"}", "", 0);
    privacy.api.opal_security_pool_scan();
    for (0..1200) |_| {
        native.api.opal_browser_test_pump();
        if (privacy.api.opal_security_pool_health(0) != 1 and privacy.api.opal_security_pool_health(1) != 1) break;
    }
    try std.testing.expect(fixture.seen.load(.acquire));
    try std.testing.expectEqual(@as(c_int, -1), privacy.api.opal_security_pool_health(0));
    try std.testing.expectEqual(@as(c_int, 0), privacy.api.opal_security_pool_count());
    privacy.api.opal_security_test_pool_lease(0, 60);
    privacy.api.opal_security_test_pool_lease(1, 60);
    try std.testing.expectEqual(@as(c_int, 0), privacy.api.opal_security_pool_selected());
    privacy.api.opal_security_pool_rotate();
    try std.testing.expectEqual(@as(c_int, 1), privacy.api.opal_security_pool_selected());
    privacy.api.opal_security_test_pool_lease(0, -1);
    privacy.api.opal_security_test_pool_lease(1, -1);
    try std.testing.expectEqual(@as(c_int, -1), privacy.api.opal_security_pool_selected());
    try std.testing.expectEqual(@as(c_int, 0), privacy.api.opal_security_pool_count());
}
test "Native embedded browser security starts and stops the real Tor daemon without blocking UI" {
    const privacy = @import("../services/browser_privacy.zig");
    try prepareProfile();
    var base: [1024]u8 = undefined;
    var directory: [2048:0]u8 = @splat(0);
    _ = try std.fmt.bufPrint(&directory, "{s}/opal-tor-fixture-{d}", .{ io.tmpDir(&base), io.milliTimestamp() });
    defer io.cwdDeleteTree(std.mem.sliceTo(&directory, 0)) catch {};
    defer privacy.shutdown();
    privacy.api.opal_security_tick(&directory, 1);
    if (privacy.api.opal_security_tor_pid() == 0) return error.SkipZigTest;
    try std.testing.expectEqual(@as(c_int, 1), privacy.api.opal_security_tor_status());
    // Bootstrap is asynchronous. Until it completes, the browser uses a closed
    // local port, rather than a foreign listener or an unverified route.
    try std.testing.expectEqual(@as(c_int, 9), privacy.api.opal_security_tor_port());
    var listening = false;
    for (0..500) |_| {
        native.api.opal_browser_test_pump();
        listening = privacy.api.opal_security_test_tor_listener() != 0;
        if (listening) break;
    }
    try std.testing.expect(listening);
    privacy.api.opal_security_tick(&directory, 0);
    try std.testing.expectEqual(@as(c_int, 0), privacy.api.opal_security_tor_status());
    try std.testing.expectEqual(@as(c_int, 0), privacy.api.opal_security_tor_pid());
}
test "Native embedded browser keyboard command tab shortcuts are owned by the macOS menu" {
    const browser = @import("../services/browser.zig");
    browser.resetTabsForTest();
    defer browser.resetTabsForTest();
    const old_router = state.app.router;
    const old_source = state.app.browse_source;
    defer {
        state.app.router = old_router;
        state.app.browse_source = old_source;
    }
    var backend = try dvui.backend.initWindow(.{ .io = io.io(), .org = "debpalash", .app = "Opal-menu-keyboard-regression", .persist_window_geometry = false, .size = .{ .w = 800, .h = 500 }, .vsync = false, .title = "Opal native menu routing", .hidden = true });
    defer backend.deinit();
    var window = try dvui.Window.init(@src(), alloc, backend.backend(), .{});
    defer window.deinit();
    const old_close_requested = @import("titlebar.zig").close_requested;
    @import("titlebar.zig").close_requested = false;
    defer @import("titlebar.zig").close_requested = old_close_requested;
    for (0..8) |i| try frame(&window, i, true);
    opal_app_menu_test_new_tab();
    @import("../macos/app_menu.zig").frameTick();
    try std.testing.expectEqual(@as(usize, 2), browser.tabsView().count);
    for ([_]dvui.enums.Key{ .t, .w }, 0..) |code, i| {
        try window.begin(@as(i128, @intCast(i + 9)) * 16_666_667);
        errdefer _ = window.end(.{}) catch null;
        _ = try window.addEventKey(.{ .code = code, .action = .down, .mod = .lcommand });
        @import("input.zig").processGlobalInputs();
        @import("browser_tabs.zig").handleShortcuts();
        try std.testing.expect(!@import("titlebar.zig").close_requested);
        try std.testing.expectEqual(@as(usize, 2), browser.tabsView().count);
        _ = try window.end(.{});
    }
    // The native action runs before the mirrored key reaches global input.
    // Closing the last tab creates another new tab and leaves Opal running.
    for (0..2) |i| {
        opal_app_menu_test_close();
        @import("../macos/app_menu.zig").frameTick();
        try window.begin(@as(i128, @intCast(i + 12)) * 16_666_667);
        errdefer _ = window.end(.{}) catch null;
        _ = try window.addEventKey(.{ .code = .w, .action = .down, .mod = .lcommand });
        @import("input.zig").processGlobalInputs();
        @import("browser_tabs.zig").handleShortcuts();
        try std.testing.expectEqual(@as(usize, 1), browser.tabsView().count);
        try std.testing.expect(!@import("titlebar.zig").close_requested);
        _ = try window.end(.{});
    }
    browser.newTab("");
    try window.begin(15 * 16_666_667);
    errdefer _ = window.end(.{}) catch null;
    _ = try window.addEventKey(.{ .code = .w, .action = .down, .mod = .lcontrol });
    @import("input.zig").processGlobalInputs();
    @import("browser_tabs.zig").handleShortcuts();
    try std.testing.expectEqual(@as(usize, 1), browser.tabsView().count);
    try std.testing.expect(!@import("titlebar.zig").close_requested);
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
    // Blank tabs use Opal's native dashboard, with the WebKit child hidden.
    try std.testing.expectEqual(@as(c_int, 0), opal_browser_test_visible());
    try std.testing.expect(@import("browser_start.zig").rendered_for_test);
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
    // Hover navigation crops the native child instead of resizing/reflowing it.
    const width_before = opal_browser_test_page_width();
    native.api.opal_browser_occlude_left(native.viewport.x + native.viewport.w * 0.25);
    native.endFrame(true, 0, true);
    try std.testing.expectApproxEqAbs(width_before, opal_browser_test_page_width(), 0.1);
    try std.testing.expectApproxEqAbs(width_before * 0.75, opal_browser_test_clip_width(), 0.1);
    native.api.opal_browser_occlude_left(0);
    native.endFrame(true, 0, true);
    try std.testing.expectApproxEqAbs(width_before, opal_browser_test_clip_width(), 0.1);
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

test "Native embedded browser aligns address controls above tabs and hover leaves content fixed" {
    const shell = @import("shell.zig");
    const browser = @import("../services/browser.zig");
    const workers = @import("../core/workers.zig");
    workers.init();
    workers.beginShutdownAndDrain(0);
    defer workers.finishShutdown();
    const old_route = state.app.router.current;
    const old_source = state.app.browse_source;
    const old_scale = state.app.ui_scale;
    defer {
        state.app.router.current = old_route;
        state.app.browse_source = old_source;
        state.app.ui_scale = old_scale;
        shell.setSidebarFixtureForTest(null);
        browser.resetTabsForTest();
    }
    state.app.router.current = .browse;
    state.app.browse_source = .Web;
    state.app.ui_scale = 1;
    theme.markUiThread();
    const Size = struct { width: f32, scale: f32 = 1 };
    for ([_]Size{ .{ .width = 1280 }, .{ .width = 800 }, .{ .width = 640 }, .{ .width = 375 }, .{ .width = 1280, .scale = 1.5 } }) |size| {
        browser.resetTabsForTest();
        const width = size.width;
        state.app.ui_scale = size.scale;
        var backend = try dvui.backend.initWindow(.{ .io = io.io(), .org = "debpalash", .app = "Opal-browser-layout-fixture", .persist_window_geometry = false, .size = .{ .w = width, .h = 720 }, .vsync = false, .title = "Opal compact browser fixture", .hidden = true });
        defer backend.deinit();
        var window = try dvui.Window.init(@src(), alloc, backend.backend(), .{});
        defer window.deinit();
        defer native.deinit();
        shell.setSidebarFixtureForTest(false);
        browser.requestBridgeView();
        var before: @TypeOf(native.viewport) = .{};
        var selected_new: u32 = 0;
        for (0..25) |index| {
            if (index == 2) {
                native.api.opal_browser_test_html("<title>Layout document</title><p>Viewport fixture</p>");
                try pageTitle("Layout document");
            }
            try window.begin(@as(i128, @intCast(index + 1)) * 16_666_667);
            @import("native_browser.zig").beginFrame();
            if (index == 0) _ = try window.addEventMouseMotion(.{ .pt = .{ .x = dvui.windowRectPixels().w - 10, .y = dvui.windowRectPixels().h - 10 } });
            if (index == 6 and width >= 400) {
                const rail = shell.sidebarBoundsForTest().sidebar;
                _ = try window.addEventMouseMotion(.{ .pt = .{ .x = rail.x + 16, .y = rail.y + 16 } });
            }
            const tab_ui = @import("browser_tabs.zig");
            if (index == 13 or index == 17 or index == 21) {
                const bounds = if (index == 13) tab_ui.new_bounds_for_test else tab_ui.close_bounds_for_test[0];
                _ = try window.addEventMouseMotion(.{ .pt = bounds.center() });
                _ = try window.addEventMouseButton(.left, .press);
                _ = try window.addEventMouseButton(.left, .release);
            }
            var scaled = dvui.scale(@src(), .{ .scale = &state.app.ui_scale }, .{ .expand = .both });
            try shell.render();
            scaled.deinit();
            @import("native_browser.zig").endFrame();
            const scale = dvui.windowNaturalScale();
            const address = browser.addressBoundsForTest();
            const more = shell.moreBoundsForTest();
            const available = dvui.windowRectPixels();
            if (index >= 8) {
                const tabs = browser.tabsView();
                for (0..tabs.count) |n| {
                    const r = tab_ui.tab_bounds_for_test[n];
                    const title = tab_ui.title_bounds_for_test[n];
                    const close = tab_ui.close_bounds_for_test[n];
                    try std.testing.expect(title.y >= r.y and title.y + title.h <= r.y + r.h);
                    try std.testing.expectApproxEqAbs(title.center().y, close.center().y, 1);
                }
            }
            _ = try window.end(.{});
            if (index == 5) before = native.viewport;
            if (index == 16) {
                const tabs = browser.tabsView();
                try std.testing.expectEqual(@as(usize, 2), tabs.count);
                selected_new = tabs.items[tabs.active].id;
            }
            if (index == 20) {
                const tabs = browser.tabsView();
                try std.testing.expectEqual(@as(usize, 1), tabs.count);
                try std.testing.expectEqual(selected_new, tabs.items[tabs.active].id);
            }
            if (index == 24) {
                const tabs = browser.tabsView();
                try std.testing.expectEqual(@as(usize, 1), tabs.count);
                try std.testing.expect(tabs.items[tabs.active].id != selected_new);
                try std.testing.expectEqual(@as(c_int, 1), opal_extensions_test_tab_count());
            }
            if (index >= 8) {
                try std.testing.expect(native.viewport.y <= 96 * scale * size.scale);
                try std.testing.expect(address.w >= 32 * scale);
                try std.testing.expect(more.w > 0 and more.x + more.w <= available.w + 1);
                try std.testing.expect(address.x + address.w <= more.x);
                try std.testing.expectApproxEqAbs(more.center().y, address.center().y, 1);
                try std.testing.expectApproxEqAbs(before.x, native.viewport.x, 1);
                try std.testing.expectApproxEqAbs(before.w, native.viewport.w, 1);
                try std.testing.expectEqual(@as(c_int, if (browser.isStartPage()) 0 else 1), opal_browser_test_visible());
                if (width >= 400 and index < 13) {
                    try std.testing.expect(opal_browser_test_clip_width() < opal_browser_test_page_width());
                    try std.testing.expectApproxEqAbs(208 * scale * size.scale, shell.sidebarBoundsForTest().sidebar.w, 1);
                }
            }
        }
    }
    if (io.getenv("OPAL_NATIVE_CAPTURE_DIR") != null) {
        const Preview = struct {
            fn setup() !void {
                browser.resetTabsForTest();
                state.app.ui_scale = 1;
                shell.setSidebarFixtureForTest(false);
                browser.newTab("");
                browser.newTab("");
                native.focus_address = false;
            }
            fn draw() !void {
                @import("native_browser.zig").beginFrame();
                try shell.render();
                @import("native_browser.zig").endFrame();
            }
            fn cleanup() void {
                browser.resetTabsForTest();
            }
        };
        for ([_]u32{ 1280, 640, 375 }) |width| try @import("native_capture.zig").capture(width, 220, "browser-tabs-aligned", Preview.setup, Preview.draw, Preview.cleanup);
    }
}
extern fn opal_wallpaper_status() c_int;
test "Native embedded browser performance avoids unchanged layout metadata and protection resets" {
    const browser = @import("../services/browser.zig");
    browser.resetTabsForTest();
    defer browser.resetTabsForTest();
    var backend = try dvui.backend.initWindow(.{ .io = io.io(), .org = "debpalash", .app = "Opal-browser-performance", .persist_window_geometry = false, .size = .{ .w = 1100, .h = 720 }, .vsync = false, .title = "Opal browser performance", .hidden = true });
    defer backend.deinit();
    var window = try dvui.Window.init(@src(), alloc, backend.backend(), .{});
    defer window.deinit();
    theme.markUiThread();
    @import("../services/browser_privacy.zig").api.opal_extensions_configure("{\"canvas\":true,\"proxy_mode\":\"system\",\"canvas_exceptions\":[]}", @embedFile("../services/browser_canvas_guard.js"), 0);
    for (0..8) |i| try frame(&window, i, true);
    browser.refreshTabs();
    const reads = opal_browser_test_metadata_reads();
    for (0..100) |_| browser.refreshTabs();
    try std.testing.expectEqual(reads, opal_browser_test_metadata_reads());
    native.endFrame(true, 0, true);
    const writes = opal_browser_test_presentation_writes();
    for (0..100) |_| native.endFrame(true, 0, true);
    try std.testing.expectEqual(writes, opal_browser_test_presentation_writes());
    browser.newTab("");
    try frame(&window, 8, true);
    const applications = opal_extensions_test_settings_applications();
    for (0..40) |_| browser.cycleTab(false);
    try std.testing.expectEqual(applications, opal_extensions_test_settings_applications());
    native.api.opal_browser_test_html("<title>Stable page</title>");
    try pageTitle("Stable page");
    native.api.opal_browser_test_html("<title>Fresh metadata</title>");
    try pageTitle("Fresh metadata");
    browser.refreshTabs();
    try std.testing.expectEqualStrings("Fresh metadata", browser.tabsView().items[browser.tabsView().active].title.text());
}
test "Native embedded browser performance twenty heavy documents survive seeded interactions" {
    const browser = @import("../services/browser.zig");
    browser.resetTabsForTest();
    defer browser.resetTabsForTest();
    var backend = try dvui.backend.initWindow(.{ .io = io.io(), .org = "debpalash", .app = "Opal-browser-twenty-tabs", .persist_window_geometry = false, .size = .{ .w = 1280, .h = 800 }, .vsync = false, .title = "Opal twenty-tab benchmark", .hidden = true });
    defer backend.deinit();
    var window = try dvui.Window.init(@src(), alloc, backend.backend(), .{});
    defer window.deinit();
    theme.markUiThread();
    const old_private = state.app.incognito_mode;
    state.app.incognito_mode = true;
    defer state.app.incognito_mode = old_private;
    for (0..20) |i| {
        browser.newTab("");
        try frame(&window, i, true);
        native.api.opal_browser_test_html("<title>Preparing benchmark</title><input id='entry'><main></main><canvas width='960' height='540'></canvas><script>let m=document.querySelector('main');for(let i=0;i<1500;i++){let p=document.createElement('p');p.textContent='Benchmark card '+i;m.appendChild(p)}let c=document.querySelector('canvas').getContext('2d');for(let i=0;i<2000;i++){c.fillStyle=`hsl(${i%360} 60% 40%)`;c.fillRect(i%960,i%540,60,40)}document.title='Heavy benchmark';</script>");
        try pageTitle("Heavy benchmark");
        var script: [128:0]u8 = @splat(0);
        _ = try std.fmt.bufPrint(&script, "document.querySelector('#entry').value='{d}'", .{i});
        var out: [128]u8 = undefined;
        _ = try pageScript(&script, &out);
    }
    try std.testing.expectEqual(@as(usize, 20), browser.tabsView().count);
    try std.testing.expectEqual(@as(c_int, 20), opal_extensions_test_tab_count());
    var random = std.Random.DefaultPrng.init(0x0a1_20261103);
    var timings: [120]i64 = undefined;
    for (&timings, 0..) |*elapsed, i| {
        const before = window.backend.nanoTime();
        const slot = random.random().uintLessThan(usize, 20);
        const id = browser.tabsView().items[slot].id;
        browser.selectTab(id);
        switch (random.random().uintLessThan(u8, 5)) {
            0 => native.zoom(1.25),
            1 => native.zoom(1),
            2 => native.find("Benchmark", false),
            3 => native.read(),
            else => {},
        }
        try frame(&window, 20 + i, true);
        browser.refreshTabs();
        elapsed.* = @intCast(window.backend.nanoTime() - before);
        var out: [128]u8 = undefined;
        var expected: [16]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "{d}", .{slot}), try pageScript("document.querySelector('#entry').value", &out));
    }
    std.mem.sort(i64, &timings, {}, std.sort.asc(i64));
    std.debug.print("Twenty-tab benchmark: 120 seeded switch/zoom/find/reader interactions, frame p95={d}ms max={d}ms\n", .{ @divTrunc(timings[113], std.time.ns_per_ms), @divTrunc(timings[119], std.time.ns_per_ms) });
    try std.testing.expect(timings[119] < 500 * std.time.ns_per_ms);
}
test "Native embedded browser performance tab switching never writes visits or loses zoom" {
    const browser = @import("../services/browser.zig");
    browser.resetTabsForTest();
    defer browser.resetTabsForTest();
    var backend = try dvui.backend.initWindow(.{ .io = io.io(), .org = "debpalash", .app = "Opal-browser-switch-regression", .persist_window_geometry = false, .size = .{ .w = 1100, .h = 720 }, .vsync = false, .title = "Opal tab switch regression", .hidden = true });
    defer backend.deinit();
    var window = try dvui.Window.init(@src(), alloc, backend.backend(), .{});
    defer window.deinit();
    theme.markUiThread();
    var server = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io.io(), .{ .reuse_address = true });
    defer server.deinit(io.io());
    var fixture: TabServer = .{};
    var response = try io.io().concurrent(TabServer.serve, .{ &server, &fixture });
    defer {
        fixture.stopping.store(true, .release);
        if (server.socket.address.connect(io.io(), .{ .mode = .stream })) |connection| connection.close(io.io()) else |_| {}
        _ = response.cancel(io.io());
    }
    for (0..2) |i| {
        var url: [128]u8 = undefined;
        browser.newTab(try std.fmt.bufPrint(&url, "http://127.0.0.1:{d}/{s}", .{ server.socket.address.getPort(), if (i == 0) "a" else "second" }));
        try frame(&window, i, true);
        try pageTitle(if (i == 0) "First A" else "Second tab");
        try frame(&window, i + 2, true);
        native.zoom(if (i == 0) 1.5 else 0.75);
    }
    // pageTitle polls the native mailbox while waiting; let the real toolbar
    // consume each page's current state before measuring repeat activations.
    for (0..2) |i| {
        browser.cycleTab(false);
        try frame(&window, i + 4, true);
    }
    for (0..2) |i| {
        browser.selectTab(browser.tabsView().items[i].id);
        try frame(&window, i + 6, true);
        native.zoom(if (i == 0) 1.5 else 0.75);
    }
    const visits = browser.visitCountForTest();
    for (0..12) |i| {
        browser.cycleTab(false);
        try frame(&window, i + 4, true);
    }
    try std.testing.expectEqual(visits, browser.visitCountForTest());
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), browser.zoomForTest(), 0.001);
    browser.cycleTab(false);
    try frame(&window, 16, true);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), browser.zoomForTest(), 0.001);
}
test "Native embedded browser tabs retain documents independent history and extension identity" {
    var backend = try dvui.backend.initWindow(.{ .io = io.io(), .org = "debpalash", .app = "Opal-live-tabs-fixture", .persist_window_geometry = false, .size = .{ .w = 800, .h = 600 }, .vsync = false, .title = "Opal isolated live tabs", .hidden = true });
    defer backend.deinit();
    var window = try dvui.Window.init(@src(), alloc, backend.backend(), .{});
    defer window.deinit();
    defer native.deinit();
    theme.markUiThread();
    for (0..8) |i| try frame(&window, i, true);
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io.io(), .{ .reuse_address = true });
    defer server.deinit(io.io());
    var fixture: TabServer = .{};
    var response = try io.io().concurrent(TabServer.serve, .{ &server, &fixture });
    defer {
        fixture.stopping.store(true, .release);
        if (server.socket.address.connect(io.io(), .{ .mode = .stream })) |connection| connection.close(io.io()) else |_| {}
        _ = response.cancel(io.io());
    }
    const port = server.socket.address.getPort();
    try ownedNavigate(port, "a", "First A");
    var result: [256]u8 = undefined;
    try std.testing.expectEqualStrings("edited first tab", try pageScript("document.querySelector('#entry').value='edited first tab'", &result));
    try std.testing.expectEqualStrings("Frame ready", try pageScript("document.querySelector('iframe').contentDocument.body.textContent", &result));
    try ownedNavigate(port, "b", "First B");
    native.command(0);
    try pageTitle("First A");
    _ = try pageScript("document.cookie='shared=value; path=/'; document.querySelector('#entry').value='edited first tab'", &result);
    try std.testing.expect(native.selectTab(2));
    native.endFrame(true, 0, true);
    try ownedNavigate(port, "second", "Second tab");
    try std.testing.expectEqualStrings("1", try pageScript("document.cookie.includes('shared=value')", &result));
    try std.testing.expectEqual(@as(c_int, 2), opal_extensions_test_tab_count());
    try std.testing.expect(native.selectTab(1));
    native.endFrame(true, 0, true);
    try pageTitle("First A");
    try std.testing.expectEqualStrings("edited first tab", try pageScript("document.querySelector('#entry').value", &result));
    native.command(1);
    try pageTitle("First B");
    try std.testing.expect(native.selectTab(2));
    native.endFrame(true, 0, true);
    try pageTitle("Second tab");
    try std.testing.expectEqualStrings("second tab", try pageScript("document.querySelector('#entry').value", &result));
    try std.testing.expect(native.selectTab(1));
    native.closeTab(2);
    try std.testing.expectEqual(@as(c_int, 1), opal_extensions_test_tab_count());
    try pageTitle("First B");
}
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
