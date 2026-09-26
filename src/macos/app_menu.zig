//! Native macOS menu actions. Objective-C only queues small action codes;
//! application state is changed here on the UI thread during appFrame.

const builtin = @import("builtin");
const c = @import("../core/c.zig");
const state = @import("../core/state.zig");

const enabled = builtin.os.tag == .macos and !@import("build_options").headless;

extern fn opal_app_menu_init() void;
extern fn opal_app_menu_poll() c_int;

pub fn init() void {
    if (enabled) opal_app_menu_init();
}

pub fn frameTick() void {
    if (!enabled) return;
    var budget: u8 = 8;
    while (budget > 0) : (budget -= 1) {
        switch (opal_app_menu_poll()) {
            0 => return,
            1 => @import("../ui/ui.zig").triggerFileOpen(),
            2 => state.app.router.navigate(.settings),
            3 => state.app.router.navigate(.home),
            4 => state.app.router.navigate(.search),
            5 => state.app.router.navigate(.browse),
            6 => if (activePlayer()) |p| p.togglePause(),
            7 => seekRelative(-10),
            8 => seekRelative(10),
            9 => {
                if (state.app.players.items.len > 0) {
                    state.app.fullscreen_player_idx = if (state.app.fullscreen_player_idx == null)
                        state.app.active_player_idx
                    else
                        null;
                }
            },
            else => {},
        }
        state.wakeUi();
    }
}

fn activePlayer() ?*@import("../player/player.zig").MediaPlayer {
    if (state.app.active_player_idx >= state.app.players.items.len) return null;
    return state.app.players.items[state.app.active_player_idx];
}

fn seekRelative(seconds: i8) void {
    const p = activePlayer() orelse return;
    var buf: [32]u8 = undefined;
    const cmd = @import("std").fmt.bufPrintZ(&buf, "seek {d}", .{seconds}) catch return;
    _ = c.mpv.mpv_command_string(p.mpv_ctx, cmd.ptr);
}
