const std = @import("std");
const dvui = @import("dvui");
// SDL's C bootstrap owns main. A C declaration prevents std.start from
// creating a second entry point while satisfying DVUI's App interface.
pub extern "c" fn main(argc: c_int, argv: [*][*:0]u8) c_int;

// To be a dvui App:
// * declare "dvui_app"
// * expose the backend's main function
// * use the backend's log function
pub const dvui_app: dvui.App = .{ .config = .{ .startFn = appOptions }, .frameFn = appFrame, .initFn = appInit, .deinitFn = appDeinit };
extern fn opal_ios_metadata() void;
extern fn opal_ios_prepare_environment() void;
fn appOptions() dvui.App.StartOptions {
    opal_ios_metadata();
    return .{ .org = "debpalash", .app = "Opal", .size = .{ .w = 400, .h = 700 }, .min_size = .{ .w = 250, .h = 350 }, .title = "Opal", .persist_window_geometry = false };
}

// NOTE: this is a static lib (like the Android example), so zig's start.zig never runs and
// never builds the std.process.Init dvui.App.main needs. Xcode's main.c has the real C main()
// and calls this exported symbol; hand-build the same minimal Init here.
export fn opal_ios_main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    return runDvuiMain(argc, argv) catch |err| {
        std.log.err("opal_ios_main failed: {t}", .{err});
        return 1;
    };
}

// All user-entered media URLs use the same validated rule as desktop links.
export fn opal_ios_valid_media_url(raw: [*:0]const u8) callconv(.c) bool {
    return @import("services/ios_media_pure.zig").mediaLink(std.mem.span(raw)) != null;
}

export fn opal_ios_open_media(raw: [*:0]const u8) callconv(.c) bool {
    // The frame hands this to the desktop open path, which creates a player
    // on demand and routes magnets/.torrent/comics/playlists like a drop.
    const state = @import("core/state.zig");
    const path = std.mem.span(raw);
    if (path.len == 0 or path.len >= state.app.dropped_file_path.len) return false;
    state.app.dropped_file_lock.lock();
    @memcpy(state.app.dropped_file_path[0..path.len], path);
    state.app.dropped_file_path[path.len] = 0;
    state.app.dropped_file_len = path.len;
    state.app.dropped_file_ready.store(true, .release);
    state.app.dropped_file_lock.unlock();
    state.wakeUi();
    return true;
}

export fn opal_ios_player_probe(time: *f64, video: *bool) callconv(.c) bool {
    const state = @import("core/state.zig");
    if (state.app.active_player_idx >= state.app.players.items.len) return false;
    const p = state.app.players.items[state.app.active_player_idx];
    time.* = p.last_seen_pos;
    video.* = p.texture != null;
    return p.last_seen_pos >= 1 and p.texture != null;
}

extern "c" var environ: ?[*:null]?[*:0]u8;

fn runDvuiMain(argc: c_int, argv: [*][*:0]u8) !u8 {
    opal_ios_prepare_environment();
    const gpa = @import("core/alloc.zig").allocator;

    var arena_allocator: std.heap.ArenaAllocator = .init(gpa);
    defer arena_allocator.deinit();

    const args_vector: std.process.Args.Vector = argv[0..@intCast(argc)];
    var empty_environment = [_:null]?[*:0]u8{};
    const environ_block: std.process.Environ.Block = .{ .slice = std.mem.span(environ orelse &empty_environment) };

    var environ_map = try std.process.Environ.createMap(.{ .block = environ_block }, gpa);
    defer environ_map.deinit();

    const preopens = try std.process.Preopens.init(arena_allocator.allocator());

    return dvui.App.main(.{
        .minimal = .{ .args = .{ .vector = args_vector }, .environ = .{ .block = environ_block } },
        .arena = &arena_allocator,
        .gpa = gpa,
        .io = @import("core/io_global.zig").io(),
        .environ_map = &environ_map,
        .preopens = preopens,
    });
}

extern fn opal_ios_log(bytes: [*]const u8, len: usize) void;
pub const panic = std.debug.FullPanic(iosPanic);
fn iosPanic(message: []const u8, _: ?usize) noreturn {
    opal_ios_log(message.ptr, message.len);
    std.c.abort();
}
fn iosLog(comptime _: std.log.Level, comptime _: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    var buffer: [2048]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch "Opal log truncated";
    opal_ios_log(text.ptr, text.len);
}
pub const std_options: std.Options = .{
    .logFn = iosLog,
};

const shell = @import("ui/ios_frame.zig");
pub fn appInit(win: *dvui.Window) !void {
    @import("core/state.zig").app.dvui_win = win;
    shell.init();
}
pub fn appDeinit(win: *dvui.Window) void {
    _ = win;
    persist();
}

/// iOS terminates suspended apps without a deinit. UIKit posts the background
/// notification on the main (SDL/UI) thread between frames, so the same
/// desktop close-path saves are safe here.
export fn opal_ios_background() callconv(.c) void {
    persist();
}
fn persist() void {
    const config = @import("core/config.zig");
    config.captureCloseSession();
    config.save();
}
pub fn appFrame() !dvui.App.Result {
    return shell.frame();
}
