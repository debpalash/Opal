//! What an idle torrent player pane says while it has no video to draw.
//!
//! A torrent refused at metadata time (an executable inside, or no playable
//! file) leaves `selected_file_idx == -2` and is stopped, but the pane still
//! holds its torrent id. The old placeholder only looked at readiness, so a
//! refused torrent read "Buffering first video parts..." forever (2026-11-27:
//! a fake "S01E01 … .exe" opened directly sat there with nothing coming).

const std = @import("std");

pub const Kind = enum { refused, metadata, buffering_first, audio, buffering };

pub const Pane = struct {
    kind: Kind,
    text: []const u8,
    hint: []const u8,
};

/// `refused`: the player's terminal "nothing to open" marker
/// (`selected_file_idx == -2`). It wins over every readiness flag, because a
/// refused torrent never becomes ready.
pub fn torrentPane(refused: bool, ready: bool, has_metadata: bool, audio_only: bool) Pane {
    if (refused) return .{
        .kind = .refused,
        .text = "This torrent was not opened",
        .hint = "It holds an executable or no playable video. Pick another source.",
    };
    if (!ready) return if (has_metadata)
        .{ .kind = .buffering_first, .text = "Buffering first video parts...", .hint = "" }
    else
        .{ .kind = .metadata, .text = "Loading torrent metadata...", .hint = "" };
    return if (audio_only)
        .{ .kind = .audio, .text = "Audio stream playing", .hint = "" }
    else
        .{ .kind = .buffering, .text = "Buffering video stream...", .hint = "" };
}

/// The player marks a refused torrent with this file index.
pub const REFUSED_FILE_IDX: i32 = -2;

pub fn isRefused(selected_file_idx: i32) bool {
    return selected_file_idx == REFUSED_FILE_IDX;
}

test "refused torrent never reads as buffering (fake .exe episode regression)" {
    // Metadata arrived (that is how the executable was seen) and the torrent
    // will never be ready: the old pane said "Buffering first video parts...".
    const p = torrentPane(isRefused(-2), false, true, false);
    try std.testing.expectEqual(Kind.refused, p.kind);
    try std.testing.expect(std.mem.indexOf(u8, p.text, "Buffering") == null);
    try std.testing.expect(p.hint.len > 0);
    // Refusal wins even over stale readiness flags.
    try std.testing.expectEqual(Kind.refused, torrentPane(true, true, true, true).kind);
}

test "loading states are unchanged for torrents that were not refused" {
    try std.testing.expect(!isRefused(-1));
    try std.testing.expect(!isRefused(0));
    try std.testing.expectEqualStrings("Loading torrent metadata...", torrentPane(false, false, false, false).text);
    try std.testing.expectEqualStrings("Buffering first video parts...", torrentPane(false, false, true, false).text);
    try std.testing.expectEqualStrings("Audio stream playing", torrentPane(false, true, true, true).text);
    try std.testing.expectEqualStrings("Buffering video stream...", torrentPane(false, true, true, false).text);
}
