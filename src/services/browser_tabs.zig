//! The open-tab list a paired browser reports, held in memory only.
//!
//! Rules are in browser_tabs_pure.zig. This file owns the lock and the one place
//! that reads the user's switch (`state.app.browser_share_tabs`): with the switch
//! off a report is refused and any list already held is dropped, so flipping the
//! switch off ends sharing at once and flipping it on later never shows an old list.

const std = @import("std");
const state = @import("../core/state.zig");
const io = @import("../core/io_global.zig");
const sync = @import("../core/sync.zig");
const alloc = @import("../core/alloc.zig").allocator;
const pure = @import("browser_tabs_pure.zig");

var mutex: sync.Mutex = .{};
var list: pure.List = .{};

pub fn switchOn() bool {
    return state.app.browser_share_tabs;
}

fn clearLocked() void {
    list.len = 0;
    list.reported_at = 0;
}

pub const ReportError = pure.ParseError || error{SwitchOff};

/// The browser's report. Refused (and the held list dropped) while the user's
/// switch is off.
pub fn report(body: []const u8) ReportError!void {
    mutex.lock();
    defer mutex.unlock();
    if (!switchOn()) {
        clearLocked();
        return error.SwitchOff;
    }
    var next = pure.List{};
    try pure.parseReport(alloc, body, io.timestamp(), &next);
    list = next;
}

/// JSON for `GET /api/browser/context?view=tabs`.
pub fn writeContext(w: *std.Io.Writer) !void {
    mutex.lock();
    defer mutex.unlock();
    const now = io.timestamp();
    if (!switchOn()) {
        clearLocked();
        return pure.writeEmpty(w, false);
    }
    if (!pure.fresh(&list, now)) return pure.writeEmpty(w, true);
    return pure.writeTabs(w, &list, now);
}
