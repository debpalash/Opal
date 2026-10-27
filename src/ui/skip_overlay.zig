//! "Skip intro" / "Skip credits" / "Next episode" button over the video.
//!
//! Shown while the play head sits inside a skip segment from ANY source
//! (Anime-Skip, chapter titles, local fingerprints — services/skip_segments).
//! Stays visible while the transport controls auto-hide, like a streaming
//! service's skip button. Themed via components.iconActionButton (lucide
//! icon, no glyphs in the label). The decision itself is
//! skip_policy_pure.decide; the click is executed on the owner thread by
//! skip_segments.tick().

const dvui = @import("dvui");
const icons = @import("icons");
const state = @import("../core/state.zig");
const components = @import("components.zig");
const skip_segments = @import("../services/skip_segments.zig");
const policy = @import("../services/skip_policy_pure.zig");

pub fn render() void {
    if (state.app.active_player_idx >= state.app.players.items.len) return;
    const p = state.app.players.items[state.app.active_player_idx];
    if (p.provider != .mpv or p.is_loading) return;
    const cur = skip_segments.current() orelse return;
    const d = cur.decision;

    var anchor = dvui.overlay(@src(), .{ .expand = .both });
    defer anchor.deinit();
    // Bottom-right, above the transport bar.
    var slot = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .gravity_x = 0.97,
        .gravity_y = 0.80,
    });
    defer slot.deinit();
    const icon = if (d.action == .next_episode)
        icons.tvg.lucide.@"skip-forward"
    else
        icons.tvg.lucide.@"fast-forward";
    if (components.iconActionButton(@src(), icon, policy.buttonLabel(d), .primary, 0)) {
        skip_segments.requestSkip();
    }
}
