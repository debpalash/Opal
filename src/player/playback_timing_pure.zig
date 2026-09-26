/// Orders trigger-to-play milestones across mpv's event and render threads.
/// A render notification can belong to the previous file, so a frame is only
/// eligible after FILE_LOADED has identified the new load.
pub const FrameGate = struct {
    load_generation: u64 = 0,
    loaded_generation: u64 = 0,
    framed_generation: u64 = 0,

    pub fn loadIssued(self: *FrameGate) void {
        self.load_generation +%= 1;
        if (self.load_generation == 0) self.load_generation = 1;
        self.loaded_generation = 0;
        self.framed_generation = 0;
    }

    pub fn fileLoaded(self: *FrameGate) void {
        if (self.load_generation != 0) self.loaded_generation = self.load_generation;
    }

    pub fn acceptFirstFrame(self: *FrameGate) bool {
        if (self.load_generation == 0 or self.loaded_generation != self.load_generation or self.framed_generation == self.load_generation) return false;
        self.framed_generation = self.load_generation;
        return true;
    }

    pub fn reset(self: *FrameGate) void {
        self.* = .{};
    }
};

/// Torrent readiness and read-ahead maintenance crosses into libtorrent's
/// session thread. Ten updates per second react quickly enough for startup and
/// seeking while leaving the UI event loop free to service player controls.
pub const TORRENT_MAINTENANCE_MS: i64 = 100;

pub fn torrentMaintenanceDue(now_ms: i64, last_ms: i64) bool {
    return last_ms == 0 or now_ms < last_ms or now_ms - last_ms >= TORRENT_MAINTENANCE_MS;
}

const std = @import("std");

test "stale render notifications cannot become the new load first frame" {
    var gate: FrameGate = .{};
    try std.testing.expect(!gate.acceptFirstFrame());
    gate.loadIssued();
    try std.testing.expect(!gate.acceptFirstFrame());
    gate.fileLoaded();
    try std.testing.expect(gate.acceptFirstFrame());
    try std.testing.expect(!gate.acceptFirstFrame());
}

test "replacement load requires its own file-loaded event" {
    var gate: FrameGate = .{};
    gate.loadIssued();
    gate.fileLoaded();
    try std.testing.expect(gate.acceptFirstFrame());

    gate.loadIssued();
    try std.testing.expect(!gate.acceptFirstFrame());
    gate.fileLoaded();
    try std.testing.expect(gate.acceptFirstFrame());
    gate.reset();
    try std.testing.expect(!gate.acceptFirstFrame());
}

test "torrent maintenance is bounded without stalling after clock reset" {
    try std.testing.expect(torrentMaintenanceDue(1_000, 0));
    try std.testing.expect(!torrentMaintenanceDue(1_099, 1_000));
    try std.testing.expect(torrentMaintenanceDue(1_100, 1_000));
    try std.testing.expect(torrentMaintenanceDue(50, 1_000));
}
