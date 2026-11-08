//! Touch auto-hide for the collapsed sidebar rail (iOS). The rail gives its
//! width back to the content while the user reads, and returns the moment
//! they look for navigation — the same contract as Safari's toolbars:
//!  • finger drags UP (content scrolls down)  → hide after `threshold` pt;
//!  • finger drags DOWN (content scrolls up)  → show after `threshold` pt;
//!  • a touch that starts at the left edge    → show (edge reveal);
//!  • any route change                        → show (new page, re-orient).
//! Opposite motion resets the accumulator so jitter never toggles it.
const std = @import("std");

pub const threshold: f32 = 28;
/// Left-edge strip (pt) whose touch brings the rail back.
pub const edge: f32 = 20;

pub const State = struct {
    visible: bool = true,
    drag: f32 = 0,
};

pub const Input = union(enum) {
    /// Finger down at x (pt from the left edge of the shell).
    press: f32,
    /// Finger moved vertically by dy (pt; positive = down).
    motion: f32,
    route_changed,
};

pub fn update(s: *State, input: Input) void {
    switch (input) {
        .press => |x| {
            s.drag = 0;
            if (x <= edge) s.visible = true;
        },
        .motion => |dy| {
            if ((s.drag > 0 and dy < 0) or (s.drag < 0 and dy > 0)) s.drag = 0;
            s.drag += dy;
            if (s.drag <= -threshold) {
                s.visible = false;
                s.drag = 0;
            } else if (s.drag >= threshold) {
                s.visible = true;
                s.drag = 0;
            }
        },
        .route_changed => {
            s.visible = true;
            s.drag = 0;
        },
    }
}

test "reading (scrolling down) hides the rail; scrolling back up shows it" {
    var s: State = .{};
    update(&s, .{ .press = 200 });
    update(&s, .{ .motion = -10 });
    try std.testing.expect(s.visible); // below threshold: a tap's wobble
    update(&s, .{ .motion = -25 });
    try std.testing.expect(!s.visible);
    update(&s, .{ .press = 200 });
    update(&s, .{ .motion = 30 });
    try std.testing.expect(s.visible);
}

test "jitter in alternating directions never toggles the rail" {
    var s: State = .{};
    for (0..20) |i| update(&s, .{ .motion = if (i % 2 == 0) -20 else 20 });
    try std.testing.expect(s.visible);
}

test "left-edge touch and navigation bring a hidden rail back" {
    var s: State = .{ .visible = false };
    update(&s, .{ .press = 200 });
    try std.testing.expect(!s.visible);
    update(&s, .{ .press = 8 });
    try std.testing.expect(s.visible);
    s.visible = false;
    update(&s, .route_changed);
    try std.testing.expect(s.visible);
}
