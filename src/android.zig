const std = @import("std");
const dvui = @import("dvui");
// SDL's Java/C bootstrap calls the exported SDL_main below. A C declaration
// prevents std.start from creating a second entry point while satisfying
// DVUI's App interface.
pub extern "c" fn main(argc: c_int, argv: [*][*:0]u8) c_int;

// To be a dvui App:
// * declare "dvui_app"
// * expose the backend's main function
// * use the backend's log function
pub const dvui_app: dvui.App = .{ .config = .{ .startFn = appOptions }, .frameFn = appFrame, .initFn = appInit, .deinitFn = appDeinit };
extern fn opal_android_prepare_environment() void;
fn appOptions() dvui.App.StartOptions {
    return .{ .org = "debpalash", .app = "Opal", .size = .{ .w = 400, .h = 700 }, .min_size = .{ .w = 250, .h = 350 }, .title = "Opal", .persist_window_geometry = false };
}

// NOTE: this is a shared lib, so zig's start.zig never runs and never builds
// the std.process.Init dvui.App.main needs. SDLActivity's native thread calls
// this exported symbol; hand-build the same minimal Init here.
export fn SDL_main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    return runDvuiMain(argc, argv) catch |err| {
        std.log.err("SDL_main failed: {t}", .{err});
        return 1;
    };
}

// All user-entered media URLs use the same validated rule as desktop links.
export fn opal_android_valid_media_url(raw: [*:0]const u8) callconv(.c) bool {
    return @import("services/ios_media_pure.zig").mediaLink(std.mem.span(raw)) != null;
}

export fn opal_android_open_media(raw: [*:0]const u8) callconv(.c) bool {
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

export fn opal_android_player_probe(time: *f64, video: *bool) callconv(.c) bool {
    const state = @import("core/state.zig");
    if (state.app.active_player_idx >= state.app.players.items.len) return false;
    const p = state.app.players.items[state.app.active_player_idx];
    time.* = p.last_seen_pos;
    video.* = p.texture != null;
    return p.last_seen_pos >= 1 and p.texture != null;
}

/// Polled from Java (onPause/onResume): true while a torrent is live and
/// unpaused or an HTTP download is active/queued. Both sources lock internally.
export fn opal_android_active_transfers() callconv(.c) bool {
    const state = @import("core/state.zig");
    const c = @import("core/c.zig");
    const pure = @import("mobile/android_pure.zig");
    var live: usize = 0;
    const ses = state.torrentSession();
    if (ses != null) {
        const n = c.mpv.torrent_count(ses);
        var id: c_int = 0;
        while (id < n) : (id += 1) {
            if (c.mpv.torrent_is_alive(ses, id) == 0) continue;
            // Seeding-only torrents don't keep the foreground service alive.
            var pbuf: [1024]u8 = undefined;
            pbuf[0] = 0;
            var progress: f32 = 0;
            var rate: c_int = 0;
            var seeds: c_int = 0;
            const rc = c.mpv.torrent_poll(ses, id, -1, &pbuf, 1024, &progress, &rate, &seeds);
            const paused = c.mpv.torrent_is_paused(ses, id) != 0;
            if (pure.torrentKeepsAwake(paused, rc >= 0 and pbuf[0] != 0, progress)) live += 1;
        }
    }
    const agg = @import("services/download_engine.zig").activeAndQueued();
    return pure.hasActiveTransfers(live, agg.active, agg.queued);
}

extern "c" var environ: ?[*:null]?[*:0]u8;

/// Zig's threaded Io cancels blocked syscalls by sending SIGIO to the worker
/// thread and relies on a do-nothing handler that Threaded.init installs with
/// std.posix.sigaction. On aarch64 Android that goes through libc with Zig's
/// glibc-shaped Sigaction (handler first), but bionic's LP64 struct sigaction
/// starts with sa_flags — so bionic reads a null handler and installs SIG_DFL.
/// /proc/<pid>/status showed SIGIO never caught and the first cancellation
/// killed the app ("status=29", ~2 s after launch). Use the raw rt_sigaction
/// syscall (kernel layout) instead, after the Io exists so its broken install
/// cannot run later and reset ours. SIGPIPE likewise (closed sockets).
fn ignoreSignal(_: std.os.linux.SIG) callconv(.c) void {}
fn installSignalHandlers() void {
    _ = @import("core/io_global.zig").io();
    const linux = std.os.linux;
    const act: linux.Sigaction = .{
        .handler = .{ .handler = ignoreSignal },
        .mask = linux.sigemptyset(),
        .flags = linux.SA.RESTART,
    };
    _ = linux.sigaction(.IO, &act, null);
    _ = linux.sigaction(.PIPE, &act, null);
}

fn runDvuiMain(argc: c_int, argv: [*][*:0]u8) !u8 {
    opal_android_prepare_environment();
    installSignalHandlers();
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

extern fn opal_android_log(bytes: [*]const u8, len: usize) void;
pub const panic = std.debug.FullPanic(androidPanic);
fn androidPanic(message: []const u8, _: ?usize) noreturn {
    opal_android_log(message.ptr, message.len);
    std.c.abort();
}
fn androidLog(comptime _: std.log.Level, comptime _: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    var buffer: [2048]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch "Opal log truncated";
    opal_android_log(text.ptr, text.len);
}
pub const std_options: std.Options = .{
    .logFn = androidLog,
};

const shell = @import("ui/ios_frame.zig");
const sdl = @import("core/c.zig").sdl;
/// Android may kill a backgrounded app without a deinit. SDL delivers these
/// events on the main (SDL) thread between frames, so the desktop close-path
/// saves are safe here.
fn lifecycleWatch(_: ?*anyopaque, event: [*c]sdl.SDL_Event) callconv(.c) bool {
    switch (event.*.type) {
        sdl.SDL_EVENT_WILL_ENTER_BACKGROUND, sdl.SDL_EVENT_TERMINATING => persist(),
        sdl.SDL_EVENT_KEY_DOWN => if (event.*.key.key == sdl.SDLK_AC_BACK and !event.*.key.repeat) {
            @import("mobile/android_pure.zig").back_pending.store(true, .release);
            @import("core/state.zig").wakeUi();
        },
        else => {},
    }
    return true;
}
pub fn appInit(win: *dvui.Window) !void {
    _ = sdl.SDL_AddEventWatch(lifecycleWatch, null);
    @import("core/state.zig").app.dvui_win = win;
    // Immersive fullscreen: dvui creates a windowed SDL window, so SDLActivity's
    // setWindowStyle(false) re-showed the status/navigation bars over our own
    // hideBars(). A fullscreen SDL window makes SDL apply immersive-sticky and
    // LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS, so the app owns the status-bar area;
    // the cutout safe insets still keep content clear of the camera hole.
    _ = sdl.SDL_SetWindowFullscreen(@ptrCast(win.backend.impl.window), true);
    shell.init();
    // Core init brings up the threaded Io and native libs; re-assert afterwards.
    installSignalHandlers();
}
pub fn appDeinit(win: *dvui.Window) void {
    _ = win;
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
