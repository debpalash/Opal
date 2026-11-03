//! Owned WebKit browser context. Credentials never enter logs or shared caches.
const std = @import("std");
const builtin = @import("builtin");
const state = @import("../core/state.zig");
const io = @import("../core/io_global.zig");
pub const supported = builtin.os.tag == .macos and !@import("build_options").headless;
pub const api = struct {
    pub extern fn opal_browser_integration_configure(directory: [*:0]const u8, cache: [*:0]const u8) void;
    pub extern fn opal_browser_integration_status(out: [*]u8, cap: usize) c_int;
    pub extern fn opal_browser_icon_revision() u64;
    pub extern fn opal_browser_icon_copy(url: [*:0]const u8, out: [*]u8, cap: usize) usize;
    pub extern fn opal_browser_media_take(out: [*]u8, cap: usize) usize;
    pub extern fn opal_browser_comic_take(out: [*]u8, cap: usize) usize;
    pub extern fn opal_browser_media_config(token: u64, agent: [*:0]const u8, out: [*]u8, cap: usize) usize;
    pub extern fn opal_browser_media_retain(token: u64) void;
    pub extern fn opal_browser_media_release(token: u64) void;
    pub extern fn opal_browser_media_fetch(token: u64, url: [*:0]const u8, headers: [*:0]const u8, range: [*:0]const u8, out: [*]u8, cap: usize, status: *c_int) usize;
    pub extern fn opal_browser_integration_shutdown() void;
};
var ready = false;
var error_reported = false;
var pending: ?@import("browser_handoff_pure.zig").Handoff = null;
var pending_comic: ?@import("comic_handoff_pure.zig").Target = null;
pub fn tick() void {
    if (comptime !supported or builtin.is_test) return;
    prepare();
    var status_message: [256]u8 = undefined;
    const status = api.opal_browser_integration_status(&status_message, status_message.len);
    if (status < 0 and !error_reported) {
        error_reported = true;
        state.showToast("Browser media integration could not start. Close and reopen the browser to retry.");
    }
    if (status == 2) error_reported = false;
    var comic_buffer: [8192]u8 = undefined;
    const comic_count = api.opal_browser_comic_take(&comic_buffer, comic_buffer.len);
    if (comic_count > 0) {
        var target: @import("comic_handoff_pure.zig").Target = undefined;
        if (@import("comic_handoff_pure.zig").parse(@import("../core/alloc.zig").allocator, comic_buffer[0..comic_count], &target)) {
            if (pending) |old| release(old.session);
            pending = null;
            pending_comic = target;
        }
    }
    if (pending_comic != null and state.app.config_loaded.load(.acquire)) {
        @import("comics.zig").openFromBrowser(pending_comic.?);
        pending_comic = null;
    }
    var buffer: [65536]u8 = undefined;
    const count = api.opal_browser_media_take(&buffer, buffer.len);
    if (count > 0) {
        pending_comic = null;
        var handoff: @import("browser_handoff_pure.zig").Handoff = undefined;
        if (@import("browser_handoff_pure.zig").parse(@import("../core/alloc.zig").allocator, buffer[0..count], &handoff)) {
            if (pending) |old| release(old.session);
            pending = handoff;
        } else {
            // Native messages always carry the leased session, even when a
            // future incompatible payload cannot be decoded by this version.
            const value = std.json.parseFromSlice(std.json.Value, @import("../core/alloc.zig").allocator, buffer[0..count], .{}) catch return;
            defer value.deinit();
            if (value.value == .object) if (value.value.object.get("session")) |token| if (token == .integer and token.integer > 0) release(@intCast(token.integer));
        }
    }
    if (pending == null or !state.app.config_loaded.load(.acquire) or !state.app.player_prewarm_ready.load(.acquire) or @import("../player/player.zig").warmPlayerPreparing()) return;
    const handoff = &pending.?;
    defer {
        release(handoff.session);
        pending = null;
    }
    @import("browser.zig").playDirect(.{ .url = handoff.url.text(), .title = handoff.title.text(), .resume_position_secs = handoff.transport.time, .user_agent = handoff.user_agent.text(), .browser_handoff = true });
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    const p = state.app.players.items[state.app.active_player_idx];
    if (!std.mem.eql(u8, p.current_url[0..p.current_url_len], handoff.url.text())) return;
    p.browser_transport = handoff.transport;
    // Zero/subsecond page positions are explicit too; ordinary history must
    // never replace them with a previous visit's resume point.
    p.provider_resume_position = handoff.transport.time;
    p.restore_session_position = null;
    p.youtube_streams.native_session = handoff.session;
    if (handoff.captured) p.commitYoutubeStreams(handoff.streams) else {
        var ua: [513:0]u8 = @splat(0);
        @memcpy(ua[0..handoff.user_agent.len], handoff.user_agent.text());
        var config: [2048:0]u8 = @splat(0);
        const n = api.opal_browser_media_config(handoff.session, &ua, &config, config.len);
        if (n == 0 or !@import("youtube_player.zig").resolveBrowserAsync(handoff.url.text(), p, p.load_serial, handoff.session, config[0..n], handoff.user_agent.text())) p.failBrowserHandoff();
    }
}
pub fn prepare() void {
    if (comptime !supported or builtin.is_test) return;
    if (ready) return;
    var directory: [2048:0]u8 = @splat(0);
    if (state.resourceRoot()) |root| {
        _ = std.fmt.bufPrint(&directory, "{s}/browser-integration", .{root}) catch return;
    } else {
        _ = io.cwdRealPathFile("assets/browser-integration", &directory) catch return;
    }
    var cache_buf: [2048]u8 = undefined;
    var cache: [2048:0]u8 = @splat(0);
    const path = @import("../core/paths.zig").cacheFile(&cache_buf, "browser-icons");
    if (path.len >= cache.len) return;
    @memcpy(cache[0..path.len], path);
    api.opal_browser_integration_configure(&directory, &cache);
    ready = true;
}
pub fn iconRevision() u64 {
    if (comptime supported) return api.opal_browser_icon_revision();
    return 0;
}
pub fn icon(url: []const u8, buffer: []u8) []const u8 {
    if (comptime !supported) return "";
    var value: [2048:0]u8 = @splat(0);
    if (url.len >= value.len) return "";
    @memcpy(value[0..url.len], url);
    return buffer[0..api.opal_browser_icon_copy(&value, buffer.ptr, buffer.len)];
}
pub fn retain(token: u64) void {
    if (comptime supported) if (token != 0) api.opal_browser_media_retain(token);
}
pub fn release(token: u64) void {
    if (comptime supported) if (token != 0) api.opal_browser_media_release(token);
}
pub fn shutdown() void {
    if (pending) |handoff| release(handoff.session);
    pending = null;
    if (comptime supported) api.opal_browser_integration_shutdown();
}
