//! Preferences belong to the UI after config_loaded. Downloads own their paths.
const std = @import("std");
const builtin = @import("builtin");
const state = @import("../core/state.zig");
const alloc = @import("../core/alloc.zig").allocator;
const io = @import("../core/io_global.zig");
const workers = @import("../core/workers.zig");
pub const pure = @import("browser_privacy_pure.zig");
pub const supported = builtin.os.tag == .macos and !@import("build_options").headless;
pub var prefs: pure.Prefs = .{};
var revision: std.atomic.Value(u32) = .init(1);
var applied_revision: u32 = 0;
var applied_generation: u32 = 0;
var signatures: [8]u64 = @splat(0);
pub const api = struct {
    pub extern fn opal_extensions_supported() c_int;
    pub extern fn opal_extensions_ready() c_int;
    pub extern fn opal_extensions_generation() c_uint;
    pub extern fn opal_extensions_configure(json: [*:0]const u8, script: [*:0]const u8, reload: c_int) void;
    pub extern fn opal_extension_load(slot: c_int, path: [*:0]const u8) void;
    pub extern fn opal_extension_unload(slot: c_int) void;
    pub extern fn opal_extension_status(slot: c_int, name: [*]u8, name_cap: usize, message: [*]u8, cap: usize) c_int;
    pub extern fn opal_extension_action(slot: c_int, options: c_int) void;
    pub extern fn opal_extension_pick() void;
    pub extern fn opal_extension_take_error(out: [*]u8, cap: usize) usize;
    pub extern fn opal_browser_proxy_supported() c_int;
    pub extern fn opal_extension_take_import(path: [*]u8, cap: usize, name: [*]u8, name_cap: usize) usize;
    pub extern fn opal_extensions_test_eval(js: [*:0]const u8) void;
    pub extern fn opal_extensions_test_result(out: [*]u8, cap: usize) c_int;
};
pub const ubol_version = "2026.1026.1812";
pub const ubol_url = "https://github.com/uBlockOrigin/uBOL-home/releases/download/" ++ ubol_version ++ "/uBOLite_" ++ ubol_version ++ ".safari.zip";
pub const ubol_sha256 = "f56b42e7e753143b1da4f64e12baf67724d48cef055eb46f9d49eddb4665f5b3";
pub const Download = enum(u8) { idle, downloading, ready, failed };
var download_state: std.atomic.Value(Download) = .init(.idle);
pub fn downloadStatus() Download {
    return download_state.load(.acquire);
}
pub fn extensionsAvailable() bool {
    if (comptime !supported) return false;
    return api.opal_extensions_supported() != 0;
}
pub fn changed() void {
    _ = revision.fetchAdd(1, .acq_rel);
    state.markConfigDirty();
    state.wakeUi();
}
pub fn restore(json: []const u8) void {
    pure.decode(alloc, json, &prefs) catch return;
    _ = revision.fetchAdd(1, .acq_rel);
}
pub fn encoded(out: []u8) ?[]const u8 {
    return pure.encode(&prefs, out, false);
}
fn packagePath(out: []u8) ?[]const u8 {
    var base: [512]u8 = undefined;
    return std.fmt.bufPrint(out, "{s}/browser-extensions/ubol-" ++ ubol_version ++ ".zip", .{@import("../core/paths.zig").configDir(&base)}) catch null;
}
pub fn installUbol() void {
    if (!extensionsAvailable() or download_state.cmpxchgStrong(.idle, .downloading, .acq_rel, .acquire) != null) return;
    workers.spawn(download, .{}) catch download_state.store(.failed, .release);
}
pub fn retryUbol() void {
    if (downloadStatus() == .failed) download_state.store(.idle, .release);
    installUbol();
}
fn download() void {
    var outcome: Download = .failed;
    defer {
        download_state.store(outcome, .release);
        state.wakeUi();
    }
    var path_buf: [1024]u8 = undefined;
    const path = packagePath(&path_buf) orelse return;
    io.cwdMakePath(std.fs.path.dirname(path) orelse return) catch return;
    var temporary: [1100]u8 = undefined;
    const temp = std.fmt.bufPrint(&temporary, "{s}.installing", .{path}) catch return;
    defer io.cwdDeleteFile(temp) catch {};
    const result = @import("reliable_fetch.zig").download(ubol_url, temp, .{ .timeout_secs = 90, .connect_timeout_secs = 10, .max_filesize = 16 * 1024 * 1024, .https_only = true, .impersonate = false });
    if (!result.ok() or workers.isQuitting()) return;
    const bytes = io.cwdReadFileAlloc(temp, alloc, 16 * 1024 * 1024) catch return;
    defer alloc.free(bytes);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const hex = std.fmt.bytesToHex(hash, .lower);
    if (!std.mem.eql(u8, &hex, ubol_sha256)) return;
    io.renameAbsolute(temp, path) catch return;
    outcome = .ready;
}
pub fn tick() void {
    if (comptime !supported) return;
    const loaded = state.app.config_loaded.load(.acquire) or builtin.is_test;
    // Startup configuration may still be written by its owned loader thread.
    if (!loaded) {
        const defaults: pure.Prefs = .{};
        var json_buf: [32768:0]u8 = @splat(0);
        const text = pure.encode(&defaults, &json_buf, false) orelse return;
        json_buf[text.len] = 0;
        api.opal_extensions_configure(&json_buf, @embedFile("browser_canvas_guard.js"), 0);
        return;
    }
    if (download_state.cmpxchgStrong(.ready, .idle, .acq_rel, .acquire) == null) {
        prefs.ubol_installed = true;
        prefs.ubol_enabled = true;
        signatures[0] = 0;
        changed();
    }
    var error_buf: [256]u8 = undefined;
    const error_len = api.opal_extension_take_error(&error_buf, error_buf.len);
    if (error_len > 0) state.showToast(error_buf[0..error_len]);
    var path_buf: [1025:0]u8 = @splat(0);
    var name_buf: [97]u8 = @splat(0);
    const imported_len = api.opal_extension_take_import(&path_buf, path_buf.len, &name_buf, name_buf.len);
    if (imported_len > 0) {
        if (prefs.extension_count == 7) state.showToast("Remove an extension before adding another") else {
            const row = &prefs.extensions[prefs.extension_count];
            row.* = .{};
            row.path.set(path_buf[0..imported_len]);
            row.name.set(std.mem.sliceTo(&name_buf, 0));
            prefs.extension_count += 1;
            changed();
        }
    }
    const gen = api.opal_extensions_generation();
    const rev = revision.load(.acquire);
    if (gen != applied_generation) signatures = @splat(0);
    if (rev != applied_revision or gen != applied_generation) {
        var buffer: [32768:0]u8 = @splat(0);
        defer @memset(&buffer, 0);
        const text = pure.encode(&prefs, &buffer, true) orelse return;
        buffer[text.len] = 0;
        api.opal_extensions_configure(&buffer, @embedFile("browser_canvas_guard.js"), @intFromBool(applied_revision != 0 and gen == applied_generation));
        applied_revision = rev;
        applied_generation = gen;
    }
    if (!extensionsAvailable() or api.opal_extensions_ready() == 0) return;
    const private = state.app.incognito_mode;
    const package = packagePath(&path_buf) orelse return;
    path_buf[package.len] = 0;
    reconcile(0, package, prefs.ubol_installed and prefs.ubol_enabled and (!private or prefs.ubol_private));
    for (0..7) |i| {
        const row = &prefs.extensions[i];
        reconcile(i + 1, row.path.text(), i < prefs.extension_count and row.enabled and (!private or row.private));
    }
}
fn reconcile(slot: usize, path: []const u8, enabled: bool) void {
    const signature = if (enabled) std.hash.Wyhash.hash(1, path) | 1 else 0;
    if (signatures[slot] == signature) return;
    signatures[slot] = signature;
    if (!enabled) {
        api.opal_extension_unload(@intCast(slot));
        return;
    }
    var buf: [1025:0]u8 = @splat(0);
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    api.opal_extension_load(@intCast(slot), &buf);
}
pub const Status = struct { code: c_int = 0, name: [97]u8 = @splat(0), message: [256]u8 = @splat(0) };
pub fn extensionStatus(slot: usize) Status {
    var result: Status = .{};
    if (comptime supported) result.code = api.opal_extension_status(@intCast(slot), &result.name, result.name.len, &result.message, result.message.len);
    return result;
}
pub fn reloadExtension(slot: usize) void {
    if (slot >= 8) return;
    signatures[slot] = 0;
    changed();
}
pub fn removeExtension(index: usize) void {
    if (index >= prefs.extension_count) return;
    for (index..prefs.extension_count - 1) |i| prefs.extensions[i] = prefs.extensions[i + 1];
    prefs.extension_count -= 1;
    prefs.extensions[prefs.extension_count] = .{};
    changed();
}
