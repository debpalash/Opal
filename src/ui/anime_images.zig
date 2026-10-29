//! UI-owned bounded Anime artwork cache. In-flight slots cannot be recycled.
const std = @import("std");
const dvui = @import("dvui");
const poster = @import("../core/poster.zig");
const Slot = struct {
    url: [1024]u8 = undefined,
    len: usize = 0,
    used: u64 = 0,
    active: bool = false,
    attempted: bool = false,
    done: std.atomic.Value(bool) = .init(false),
    fetching: bool = false,
    pixels: ?[]u8 = null,
    w: u32 = 0,
    h: u32 = 0,
    texture: ?dvui.Texture = null,
};
var slots: [64]Slot = @splat(.{});
var tick: u64 = 0;
fn settle(slot: *Slot) void {
    if (slot.active and slot.done.load(.acquire)) slot.active = false;
}
pub fn get(url: []const u8) ?dvui.Texture {
    return request(url, true);
}
pub fn prefetch(url: []const u8) void {
    _ = request(url, false);
}
pub fn failed(url: []const u8) bool {
    for (&slots) |*slot| {
        if (!std.mem.eql(u8, slot.url[0..slot.len], url)) continue;
        settle(slot);
        return slot.attempted and !slot.active and slot.texture == null and slot.pixels == null;
    }
    return false;
}
fn request(url: []const u8, upload: bool) ?dvui.Texture {
    if (url.len == 0 or url.len > 1024) return null;
    tick +%= 1;
    var chosen: ?*Slot = null;
    for (&slots) |*slot| {
        settle(slot);
        if (std.mem.eql(u8, slot.url[0..slot.len], url)) {
            chosen = slot;
            break;
        }
    }
    if (chosen == null) {
        for (&slots) |*slot| {
            if (slot.active) continue;
            if (chosen == null or slot.used < chosen.?.used) chosen = slot;
        }
        const slot = chosen orelse return null;
        poster.deinitPoster(&slot.pixels, &slot.texture);
        slot.* = .{};
        @memcpy(slot.url[0..url.len], url);
        slot.len = url.len;
    }
    const slot = chosen.?;
    slot.used = tick;
    if (slot.active) return null;
    if (!slot.attempted) {
        slot.done.store(false, .release);
        slot.active = poster.fetchAsyncPublished(url, &slot.pixels, &slot.w, &slot.h, &slot.fetching, &slot.done);
        slot.attempted = slot.active;
        return null;
    }
    if (upload) _ = poster.uploadIfReady(&slot.pixels, slot.w, slot.h, &slot.texture);
    return slot.texture;
}
/// After the worker barrier, on the UI thread before window destruction.
pub fn deinit() void {
    for (&slots) |*slot| {
        settle(slot);
        if (slot.active) continue;
        poster.deinitPoster(&slot.pixels, &slot.texture);
        slot.* = .{};
    }
}

pub fn seedForTest(url: []const u8, texture: dvui.Texture) void {
    if (!@import("builtin").is_test) @compileError("test only");
    for (&slots) |*slot| {
        if (slot.len != 0) continue;
        @memcpy(slot.url[0..url.len], url);
        slot.len = url.len;
        slot.attempted = true;
        slot.texture = texture;
        return;
    }
}
