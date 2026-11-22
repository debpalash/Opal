//! Seek-aware piece deadlines: executor for torrent_deadline_pure.zig.
//!
//! Every seek path lands here with a byte offset: the stream proxy sees each
//! mpv range request (keyboard, chapter, remote and seekbar seeks), and the
//! native seekbar converts its percentage first. The last window applied per
//! torrent is remembered so a forward slide resets only the pieces that fell
//! behind the cursor, while a jump clears every stale deadline.
//!
//! Called from the UI thread (seekbar) and proxy connection threads, so the
//! window table is mutex-guarded and libtorrent is called outside the lock.

const std = @import("std");
const c = @import("../core/c.zig");
const sync = @import("../core/sync.zig");
const pure = @import("torrent_deadline_pure.zig");

const MAX_TRACKED = 16;

const Slot = struct {
    torrent_id: i32 = -1,
    file_idx: i32 = -1,
    window: ?pure.Window = null,
};

var lock: sync.Mutex = .{};
var slots: [MAX_TRACKED]Slot = @splat(.{});
var next_evict: usize = 0;

const CFG = pure.Config{};

fn previous(torrent_id: i32, file_idx: i32) ?pure.Window {
    lock.lock();
    defer lock.unlock();
    for (slots) |s| {
        if (s.torrent_id == torrent_id) return if (s.file_idx == file_idx) s.window else null;
    }
    return null;
}

fn remember(torrent_id: i32, file_idx: i32, win: ?pure.Window) void {
    lock.lock();
    defer lock.unlock();
    var free: ?usize = null;
    for (&slots, 0..) |*s, i| {
        if (s.torrent_id == torrent_id) {
            s.file_idx = file_idx;
            s.window = win;
            return;
        }
        if (s.torrent_id < 0 and free == null) free = i;
    }
    const k = free orelse blk: {
        const e = next_evict;
        next_evict = (next_evict + 1) % MAX_TRACKED;
        break :blk e;
    };
    slots[k] = .{ .torrent_id = torrent_id, .file_idx = file_idx, .window = win };
}

/// Drop the remembered window, e.g. when the torrent's stream closes. The next
/// seek is then treated as a jump and clears everything.
pub fn forget(torrent_id: i32) void {
    lock.lock();
    defer lock.unlock();
    for (&slots) |*s| {
        if (s.torrent_id == torrent_id) s.* = .{};
    }
}

fn geometry(ses: c.mpv.TorrentSession, torrent_id: i32, file_idx: i32) ?pure.Geometry {
    var off: c_longlong = 0;
    var size: c_longlong = 0;
    var piece: c_int = 0;
    var pieces: c_int = 0;
    if (c.mpv.torrent_get_piece_geometry(ses, torrent_id, file_idx, &off, &size, &piece, &pieces) != 0) return null;
    if (off < 0 or size <= 0 or piece <= 0 or pieces <= 0) return null;
    return .{
        .file_offset = @intCast(off),
        .file_size = @intCast(size),
        .piece_size = @intCast(piece),
        .num_pieces = @intCast(pieces),
    };
}

/// Reprioritise from a byte offset inside `file_idx`.
pub fn seekToByte(ses: c.mpv.TorrentSession, torrent_id: i32, file_idx: i32, byte_offset: i64) void {
    if (ses == null or torrent_id < 0 or file_idx < 0 or byte_offset < 0) return;
    // RAM streams keep their byte-budgeted window inside the wrapper.
    if (c.mpv.torrent_is_memory_only(ses, torrent_id) != 0) {
        c.mpv.torrent_set_seek_hint(ses, torrent_id, file_idx, byte_offset);
        return;
    }
    const g = geometry(ses, torrent_id, file_idx) orelse return;
    const p = pure.plan(g, @intCast(byte_offset), previous(torrent_id, file_idx), CFG) orelse return;
    if (p.mode == .none) return;
    apply(ses, torrent_id, file_idx, &p);
}

/// Seekbar entry point: map the percentage to a byte offset of the file.
pub fn seekToPercent(ses: c.mpv.TorrentSession, torrent_id: i32, file_idx: i32, pct: f64) void {
    if (ses == null or torrent_id < 0 or file_idx < 0) return;
    const g = geometry(ses, torrent_id, file_idx) orelse {
        // No metadata yet: nothing to map. RAM streams need no geometry here.
        if (c.mpv.torrent_is_memory_only(ses, torrent_id) != 0) c.mpv.torrent_seek_prioritize(ses, torrent_id, file_idx, pct);
        return;
    };
    seekToByte(ses, torrent_id, file_idx, @intCast(pure.percentToOffset(pct, g.file_size)));
}

fn apply(ses: c.mpv.TorrentSession, torrent_id: i32, file_idx: i32, p: *const pure.Plan) void {
    var set_pieces: [pure.MAX_SET]c_int = undefined;
    var set_deadlines: [pure.MAX_SET]c_int = undefined;
    for (p.sets(), 0..) |e, i| {
        set_pieces[i] = @intCast(e.piece);
        set_deadlines[i] = @intCast(e.deadline_ms);
    }
    var reset_pieces: [pure.MAX_RESET]c_int = undefined;
    for (p.resets(), 0..) |r, i| reset_pieces[i] = @intCast(r);
    const win = p.window orelse return;
    const applied = c.mpv.torrent_apply_piece_deadlines(
        ses,
        torrent_id,
        if (p.clearAll()) 1 else 0,
        &reset_pieces,
        @intCast(p.resets().len),
        &set_pieces,
        &set_deadlines,
        @intCast(p.sets().len),
        @intCast(win.target),
    );
    // A failed apply must not be remembered, or the next seek would slide
    // from a window libtorrent never received.
    remember(torrent_id, file_idx, if (applied >= 0) win else null);
}
