//! Owned HTTP and real WebKit fixtures: canvas, DNR extensions and proxy routing.
const std = @import("std");
const dvui = @import("dvui");
const io = @import("../core/io_global.zig");
const native = @import("../services/native_browser.zig");
const privacy = @import("../services/browser_privacy.zig");
fn wake() callconv(.c) void {}
fn attach(window: ?*anyopaque) !void {
    try std.testing.expectEqual(@as(c_int, 1), native.api.opal_browser_attach(window, 1, wake));
    native.api.opal_browser_present(0, 0, 600, 400, 600, 400, 1, 0, 1);
}
fn configure(json: [*:0]const u8) void {
    privacy.api.opal_extensions_configure(json, @embedFile("../services/browser_canvas_guard.js"), 0);
}
fn evaluate(js: [*:0]const u8, out: []u8) ![]const u8 {
    privacy.api.opal_extensions_test_eval(js);
    for (0..1000) |_| {
        native.api.opal_browser_test_pump();
        if (privacy.api.opal_extensions_test_result(out.ptr, out.len) != 0) return std.mem.sliceTo(out, 0);
    }
    return error.Timeout;
}
fn waitTitle(expected: []const u8) !void {
    var url: [2048]u8 = undefined;
    var title: [256]u8 = undefined;
    var err: [256]u8 = undefined;
    var loading: c_int = 0;
    var found: c_int = 0;
    for (0..1500) |_| {
        native.api.opal_browser_test_pump();
        _ = native.api.opal_browser_poll(&url, url.len, &title, title.len, &err, err.len, &loading, &found);
        if (loading == 0 and std.mem.eql(u8, std.mem.sliceTo(&title, 0), expected)) return;
    }
    return error.Timeout;
}
fn backend() !dvui.backend {
    return dvui.backend.initWindow(.{ .io = io.io(), .org = "debpalash", .app = "Opal-protections-fixture", .persist_window_geometry = false, .size = .{ .w = 600, .h = 400 }, .vsync = false, .title = "Opal isolated browser protections", .hidden = true });
}
fn stopServer(listener: *std.Io.net.Server, task: *std.Io.Future(void), fixture: ?*Fixture) void {
    // An explicit wake connection is needed: cancellation/shutdown alone can
    // leave Darwin's accept asleep after WebKit changes process signal state.
    if (fixture) |owned| {
        owned.stopping.store(true, .release);
        const handle = owned.active.load(.acquire);
        if (handle >= 0) {
            var socket = listener.socket;
            socket.handle = handle;
            const stream: std.Io.net.Stream = .{ .socket = socket };
            stream.shutdown(io.io(), .both) catch {};
        }
    }
    native.deinit();
    if (listener.socket.address.connect(io.io(), .{ .mode = .stream })) |connection| connection.close(io.io()) else |_| {}
    _ = task.cancel(io.io());
}
const Fixture = struct {
    stopping: std.atomic.Value(bool) = .init(false),
    active: std.atomic.Value(i32) = .init(-1),
    count: std.atomic.Value(u32) = .init(0),
    images: std.atomic.Value(u32) = .init(0),
    const svg = "<svg xmlns='http://www.w3.org/2000/svg' width='1' height='1'><rect width='1' height='1'/></svg>";
    const html = "<html><head><title>Loading fixture</title></head><body><img src='/opal-ad/pixel.ar/ads/ad.svg' onload=\"document.title='Image allowed ' + location.pathname\" onerror=\"document.title='Image blocked ' + location.pathname\"></body></html>";
    fn serve(listener: *std.Io.net.Server, self: *@This()) void {
        while (!self.stopping.load(.acquire)) {
            const stream = listener.accept(io.io()) catch return;
            defer stream.close(io.io());
            self.active.store(stream.socket.handle, .release);
            defer self.active.store(-1, .release);
            var incoming: [4096]u8 = undefined;
            var reader = stream.reader(io.io(), &incoming);
            const first = reader.interface.takeDelimiterInclusive('\n') catch continue;
            const image = std.mem.indexOf(u8, first, ".svg") != null;
            while (true) {
                const line = reader.interface.takeDelimiterInclusive('\n') catch break;
                if (std.mem.eql(u8, line, "\r\n")) break;
            }
            _ = self.count.fetchAdd(1, .acq_rel);
            if (image) _ = self.images.fetchAdd(1, .acq_rel);
            const body = if (image) svg else html;
            var outgoing: [2048]u8 = undefined;
            var writer = stream.writer(io.io(), &outgoing);
            writer.interface.print("HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n{s}", .{ if (image) "image/svg+xml" else "text/html", body.len, body }) catch continue;
            writer.interface.flush() catch {};
        }
    }
};
fn navigate(port: u16, path: []const u8, expected: []const u8) !void {
    var url: [256:0]u8 = @splat(0);
    _ = try std.fmt.bufPrint(&url, "http://127.0.0.1:{d}/{s}", .{ port, path });
    native.api.opal_browser_navigate(&url);
    var title: [256]u8 = undefined;
    const wanted = try std.fmt.bufPrint(&title, "{s} /{s}", .{ expected, path });
    try waitTitle(wanted);
}
fn waitExtension(slot: usize) !void {
    for (0..3000) |_| {
        native.api.opal_browser_test_pump();
        const status = privacy.extensionStatus(slot);
        if (status.code < 0) return error.ExtensionFailed;
        if (status.code == 2) return;
    }
    return error.Timeout;
}
test "Native browser protections block canvas readback and preserve trusted editors" {
    var window = try backend();
    defer window.deinit();
    configure("{\"canvas\":true,\"proxy_mode\":\"system\",\"canvas_exceptions\":[]}");
    try attach(@ptrCast(window.window));
    defer native.deinit();
    native.api.opal_browser_test_html("<html><head><title>Canvas protected</title></head><body><canvas></canvas></body></html>");
    try waitTitle("Canvas protected");
    var result: [256]u8 = undefined;
    const script = "(()=>{let c=document.querySelector('canvas');c.getContext('2d').fillRect(0,0,2,2);try{c.toDataURL();return 'unprotected'}catch(e){return e.name}})()";
    try std.testing.expectEqualStrings("SecurityError", try evaluate(script, &result));
    try std.testing.expectEqualStrings("1", try evaluate("navigator.userAgent.includes('Version/') && navigator.userAgent.includes('Safari/')", &result));
    configure("{\"canvas\":true,\"proxy_mode\":\"system\",\"canvas_exceptions\":[\"opal.invalid\"]}");
    native.api.opal_browser_test_html("<html><head><title>Canvas allowed</title></head><body><canvas></canvas></body></html>");
    try waitTitle("Canvas allowed");
    try std.testing.expectEqualStrings("unprotected", try evaluate(script, &result));
}
test "Native browser protections load actual extensions and block owned ad requests" {
    var window = try backend();
    defer window.deinit();
    configure("{\"canvas\":true,\"proxy_mode\":\"system\",\"canvas_exceptions\":[]}");
    try attach(@ptrCast(window.window));
    defer native.deinit();
    var dir_buf: [1024]u8 = undefined;
    var tmp: [768]u8 = undefined;
    const directory = try std.fmt.bufPrint(&dir_buf, "{s}/opal-extension-fixture-{d}", .{ io.tmpDir(&tmp), io.milliTimestamp() });
    try io.cwdMakePath(directory);
    defer io.cwdDeleteTree(directory) catch {};
    var file_buf: [1200]u8 = undefined;
    const manifest = try std.fmt.bufPrint(&file_buf, "{s}/manifest.json", .{directory});
    try io.cwdWriteFile(.{ .sub_path = manifest, .data = "{\"manifest_version\":3,\"name\":\"Owned blocker\",\"description\":\"Owned network filtering fixture\",\"version\":\"1.0\",\"permissions\":[\"declarativeNetRequest\"],\"host_permissions\":[\"<all_urls>\"],\"declarative_net_request\":{\"rule_resources\":[{\"id\":\"owned\",\"enabled\":true,\"path\":\"rules.json\"}]},\"content_scripts\":[{\"matches\":[\"<all_urls>\"],\"js\":[\"content.js\"],\"run_at\":\"document_end\"}]}" });
    const rules = try std.fmt.bufPrint(&file_buf, "{s}/rules.json", .{directory});
    try io.cwdWriteFile(.{ .sub_path = rules, .data = "[{\"id\":1,\"priority\":1,\"action\":{\"type\":\"block\"},\"condition\":{\"urlFilter\":\"/opal-ad/\",\"resourceTypes\":[\"image\"]}}]" });
    const content = try std.fmt.bufPrint(&file_buf, "{s}/content.js", .{directory});
    try io.cwdWriteFile(.{ .sub_path = content, .data = "document.documentElement.dataset.opalExtension = 'active';" });
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io.io(), .{ .reuse_address = true });
    defer server.deinit(io.io());
    var fixture: Fixture = .{};
    var response = try io.io().concurrent(Fixture.serve, .{ &server, &fixture });
    defer stopServer(&server, &response, &fixture);
    try navigate(server.socket.address.getPort(), "baseline", "Image allowed");
    const before = fixture.images.load(.acquire);
    var path: [1025:0]u8 = @splat(0);
    @memcpy(path[0..directory.len], directory);
    privacy.api.opal_extension_load(1, &path);
    try waitExtension(1);
    try navigate(server.socket.address.getPort(), "blocked", "Image blocked");
    try std.testing.expectEqual(before, fixture.images.load(.acquire));
    var result: [256]u8 = undefined;
    try std.testing.expectEqualStrings("active", try evaluate("document.documentElement.dataset.opalExtension", &result));
    privacy.api.opal_extension_unload(1);
    try navigate(server.socket.address.getPort(), "disabled", "Image allowed");
}
test "Native browser protections official uBlock Lite blocks a real EasyList match" {
    const package = io.getenv("OPAL_UBOL_TEST_PACKAGE") orelse return error.SkipZigTest;
    var window = try backend();
    defer window.deinit();
    configure("{\"canvas\":true,\"proxy_mode\":\"system\",\"canvas_exceptions\":[]}");
    try attach(@ptrCast(window.window));
    defer native.deinit();
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io.io(), .{ .reuse_address = true });
    defer server.deinit(io.io());
    var fixture: Fixture = .{};
    var response = try io.io().concurrent(Fixture.serve, .{ &server, &fixture });
    defer stopServer(&server, &response, &fixture);
    try navigate(server.socket.address.getPort(), "baseline", "Image allowed");
    const before = fixture.images.load(.acquire);
    var path: [1025:0]u8 = @splat(0);
    if (package.len >= path.len) return error.PathTooLong;
    @memcpy(path[0..package.len], package);
    privacy.api.opal_extension_load(0, &path);
    try waitExtension(0);
    _ = before;
    // WebKit compiles large static lists asynchronously. Probe new owned pages
    // until filtering takes effect, then assert the blocked request never lands.
    var blocked = false;
    for (0..40) |attempt| {
        var url: [256:0]u8 = @splat(0);
        _ = try std.fmt.bufPrint(&url, "http://127.0.0.1:{d}/ubol-{d}", .{ server.socket.address.getPort(), attempt });
        var allowed_title_buf: [256]u8 = undefined;
        var blocked_title_buf: [256]u8 = undefined;
        const allowed_title = try std.fmt.bufPrint(&allowed_title_buf, "Image allowed /ubol-{d}", .{attempt});
        const blocked_title = try std.fmt.bufPrint(&blocked_title_buf, "Image blocked /ubol-{d}", .{attempt});
        const count_before = fixture.images.load(.acquire);
        native.api.opal_browser_navigate(&url);
        var current_url: [2048]u8 = undefined;
        var title: [256]u8 = undefined;
        var err: [256]u8 = undefined;
        var loading: c_int = 0;
        var found: c_int = 0;
        for (0..1500) |_| {
            native.api.opal_browser_test_pump();
            _ = native.api.opal_browser_poll(&current_url, current_url.len, &title, title.len, &err, err.len, &loading, &found);
            const text = std.mem.sliceTo(&title, 0);
            if (loading == 0 and std.mem.eql(u8, text, blocked_title)) {
                blocked = true;
                break;
            }
            if (loading == 0 and std.mem.eql(u8, text, allowed_title)) break;
        }
        if (blocked) {
            try std.testing.expectEqual(count_before, fixture.images.load(.acquire));
            break;
        }
        for (0..25) |_| native.api.opal_browser_test_pump();
    }
    try std.testing.expect(blocked);
    privacy.api.opal_extension_unload(0);
    try navigate(server.socket.address.getPort(), "disabled", "Image allowed");
}
test "Native browser protections route requests through the selected HTTP proxy" {
    const Proxy = struct {
        seen: std.atomic.Value(bool) = .init(false),
        fn serve(listener: *std.Io.net.Server, self: *@This()) void {
            const stream = listener.accept(io.io()) catch return;
            defer stream.close(io.io());
            var incoming: [4096]u8 = undefined;
            var reader = stream.reader(io.io(), &incoming);
            const first = reader.interface.takeDelimiterInclusive('\n') catch return;
            const connect = std.mem.startsWith(u8, first, "CONNECT ");
            while (true) {
                const line = reader.interface.takeDelimiterInclusive('\n') catch return;
                if (std.mem.eql(u8, line, "\r\n")) break;
            }
            var outgoing: [2048]u8 = undefined;
            var writer = stream.writer(io.io(), &outgoing);
            if (connect) {
                writer.interface.writeAll("HTTP/1.1 200 Connection Established\r\n\r\n") catch return;
                writer.interface.flush() catch return;
                _ = reader.interface.takeDelimiterInclusive('\n') catch return;
                while (true) {
                    const line = reader.interface.takeDelimiterInclusive('\n') catch return;
                    if (std.mem.eql(u8, line, "\r\n")) break;
                }
            }
            self.seen.store(true, .release);
            const body = "<html><head><title>Proxy delivered</title></head><body>Owned proxy</body></html>";
            writer.interface.print("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch return;
            writer.interface.flush() catch {};
        }
    };
    var window = try backend();
    defer window.deinit();
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io.io(), .{ .reuse_address = true });
    defer server.deinit(io.io());
    var fixture: Proxy = .{};
    var response = try io.io().concurrent(Proxy.serve, .{ &server, &fixture });
    defer stopServer(&server, &response, null);
    var json: [1024:0]u8 = @splat(0);
    _ = try std.fmt.bufPrint(&json, "{{\"canvas\":true,\"proxy_mode\":\"http\",\"active_profile\":0,\"profiles\":[{{\"kind\":\"http\",\"host\":\"127.0.0.1\",\"port\":{d}}}]}}", .{server.socket.address.getPort()});
    configure(&json);
    try attach(@ptrCast(window.window));
    defer native.deinit();
    native.api.opal_browser_navigate("http://opal-proxy.invalid/owned");
    try waitTitle("Proxy delivered");
    try std.testing.expect(fixture.seen.load(.acquire));
}
test "Native browser protections do not leak directly when the chosen proxy is down" {
    const Origin = struct {
        leaked: std.atomic.Value(bool) = .init(false),
        fn serve(listener: *std.Io.net.Server, self: *@This()) void {
            const stream = listener.accept(io.io()) catch return;
            defer stream.close(io.io());
            var incoming: [2048]u8 = undefined;
            var reader = stream.reader(io.io(), &incoming);
            const line = reader.interface.takeDelimiterInclusive('\n') catch return;
            if (std.mem.indexOf(u8, line, "/leak") != null) self.leaked.store(true, .release);
            var out: [512]u8 = undefined;
            var writer = stream.writer(io.io(), &out);
            writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 32\r\nConnection: close\r\n\r\n<title>Unexpected direct</title>") catch return;
            writer.interface.flush() catch {};
        }
    };
    var window = try backend();
    defer window.deinit();
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var origin = try address.listen(io.io(), .{ .reuse_address = true });
    defer origin.deinit(io.io());
    var fixture: Origin = .{};
    var response = try io.io().concurrent(Origin.serve, .{ &origin, &fixture });
    defer stopServer(&origin, &response, null);
    var unavailable = try address.listen(io.io(), .{ .reuse_address = true });
    const proxy_port = unavailable.socket.address.getPort();
    unavailable.deinit(io.io());
    var json: [1024:0]u8 = @splat(0);
    _ = try std.fmt.bufPrint(&json, "{{\"canvas\":true,\"proxy_mode\":\"http\",\"active_profile\":0,\"profiles\":[{{\"kind\":\"http\",\"host\":\"127.0.0.1\",\"port\":{d}}}]}}", .{proxy_port});
    configure(&json);
    try attach(@ptrCast(window.window));
    defer native.deinit();
    var target: [256:0]u8 = @splat(0);
    _ = try std.fmt.bufPrint(&target, "http://127.0.0.1:{d}/leak", .{origin.socket.address.getPort()});
    native.api.opal_browser_navigate(&target);
    var url: [2048]u8 = undefined;
    var title: [256]u8 = undefined;
    var err: [256]u8 = undefined;
    var loading: c_int = 0;
    var found: c_int = 0;
    var failed = false;
    for (0..1500) |_| {
        native.api.opal_browser_test_pump();
        _ = native.api.opal_browser_poll(&url, url.len, &title, title.len, &err, err.len, &loading, &found);
        if (err[0] != 0 and loading == 0) {
            failed = true;
            break;
        }
    }
    try std.testing.expect(failed);
    try std.testing.expect(!fixture.leaked.load(.acquire));
}

var panel_section: usize = 0;
fn setupPanel() !void {
    const prefs = &privacy.prefs;
    prefs.* = .{};
    prefs.ubol_installed = true;
    prefs.profile_count = 1;
    prefs.profiles[0].name.set("Local SOCKS");
    prefs.profiles[0].host.set("127.0.0.1");
    prefs.profiles[0].kind = .socks5;
    prefs.profiles[0].port = 1080;
    prefs.profiles[0].password.set("fixture-secret");
    @import("browser_privacy.zig").setPanelForTest(panel_section, panel_section == 2);
}
fn drawPanel() !void {
    var root = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .color_fill = .{ .color = @import("theme.zig").colors.bg_app } });
    defer root.deinit();
    const components = @import("components.zig");
    components.clearToggleBoundsForTest();
    @import("browser_privacy.zig").render(.panel);
    if (panel_section == 0) {
        const rows = components.toggleBoundsForTest();
        if (rows.len >= 2 and rows[0].row.h > 0 and rows[1].row.h > 0) {
            try std.testing.expect(rows[1].row.y >= rows[0].row.y + rows[0].row.h - 1);
        }
    }
}
fn cleanupPanel() void {
    @import("browser_privacy.zig").setPanelForTest(null, false);
}
test "Native browser protections themed extension privacy and proxy panels" {
    const before = privacy.prefs;
    defer privacy.prefs = before;
    for (0..3) |section| {
        panel_section = section;
        for ([_][2]u32{ .{ 1000, 780 }, .{ 640, 780 }, .{ 375, 780 }, .{ 320, 780 } }) |size| {
            const names = [_][]const u8{ "browser-extensions", "browser-canvas-protection", "browser-proxy-manager" };
            try @import("native_capture.zig").capture(size[0], size[1], names[section], setupPanel, drawPanel, cleanupPanel);
        }
    }
}
extern fn opal_browser_proxy_guard_ready() c_int;
test "Native browser protections also block loopback subresource bypass" {
    var window = try backend();
    defer window.deinit();
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var origin = try address.listen(io.io(), .{ .reuse_address = true });
    defer origin.deinit(io.io());
    var fixture: Fixture = .{};
    var response = try io.io().concurrent(Fixture.serve, .{ &origin, &fixture });
    defer stopServer(&origin, &response, &fixture);
    configure("{\"canvas\":true,\"proxy_mode\":\"http\",\"active_profile\":0,\"profiles\":[{\"kind\":\"http\",\"host\":\"127.0.0.1\",\"port\":1}]}");
    try attach(@ptrCast(window.window));
    defer native.deinit();
    for (0..1500) |_| {
        native.api.opal_browser_test_pump();
        if (opal_browser_proxy_guard_ready() != 0) break;
    }
    try std.testing.expectEqual(@as(c_int, 1), opal_browser_proxy_guard_ready());
    var html: [1024:0]u8 = @splat(0);
    _ = try std.fmt.bufPrint(&html, "<html><head><title>Loading subresource</title></head><body><img src='http://127.0.0.1:{d}/leak.svg' onload=\"document.title='Local leaked'\" onerror=\"document.title='Local blocked'\"></body></html>", .{origin.socket.address.getPort()});
    native.api.opal_browser_test_html(&html);
    try waitTitle("Local blocked");
    try std.testing.expectEqual(@as(u32, 0), fixture.images.load(.acquire));
}
