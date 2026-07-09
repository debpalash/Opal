//! Pure page-router state for the page-shell UI redesign.
//!
//! Holds the active route plus browser-style back/forward history as
//! fixed-size rings (no allocations — matches the project's state convention).
//! This module is intentionally pure (no io_global / dvui / state imports) so
//! it builds as a standalone `zig build test` target. The UI shell drives it;
//! `state.app.router` is an instance of `History`.

const std = @import("std");

/// Top-level pages. Maps the legacy 14 `DrawerTab`s into a small IA
/// (see docs/superpowers/specs/2026-06-23-page-shell-redesign-design.md).
pub const Route = enum {
    home,
    search,
    browse,
    downloads,
    queue,
    history,
    player,
    assistant,
    settings,
    system,
};

/// Max depth of each history ring. 32 covers any realistic session; older
/// entries fall off the bottom (oldest-evicted) rather than blocking nav.
pub const HISTORY_CAP = 32;

/// Browser-style navigation history: a current route plus back/forward stacks.
///
/// navigate(): push current → back, clear forward, set current.
/// goBack():   push current → forward, pop back → current.
/// goForward():push current → back,    pop forward → current.
pub const History = struct {
    current: Route = .home,
    back: [HISTORY_CAP]Route = undefined,
    back_len: usize = 0,
    fwd: [HISTORY_CAP]Route = undefined,
    fwd_len: usize = 0,

    /// Navigate to `r`. No-op (and does not touch history) if already there,
    /// so repeated clicks on the active nav item don't spam the back stack.
    pub fn navigate(self: *History, r: Route) void {
        if (r == self.current) return;
        pushCapped(&self.back, &self.back_len, self.current);
        self.fwd_len = 0; // new navigation invalidates the forward stack
        self.current = r;
    }

    pub fn canGoBack(self: *const History) bool {
        return self.back_len > 0;
    }

    pub fn canGoForward(self: *const History) bool {
        return self.fwd_len > 0;
    }

    pub fn goBack(self: *History) void {
        if (self.back_len == 0) return;
        pushCapped(&self.fwd, &self.fwd_len, self.current);
        self.back_len -= 1;
        self.current = self.back[self.back_len];
    }

    pub fn goForward(self: *History) void {
        if (self.fwd_len == 0) return;
        pushCapped(&self.back, &self.back_len, self.current);
        self.fwd_len -= 1;
        self.current = self.fwd[self.fwd_len];
    }

    /// Leave the Player route when the last player closes: return to the most
    /// recent NON-player page in the back stack, or Home if there is none, so the
    /// Player route is never left rendering an empty grid. No-op if not currently
    /// on Player. Clears the forward stack (the empty player isn't worth keeping).
    pub fn leavePlayer(self: *History) void {
        if (self.current != .player) return;
        self.fwd_len = 0;
        while (self.back_len > 0) {
            self.back_len -= 1;
            const r = self.back[self.back_len];
            if (r != .player) {
                self.current = r;
                return;
            }
        }
        self.current = .home;
    }
};

/// Push onto a fixed ring; when full, drop the oldest (shift down) so the
/// most-recent HISTORY_CAP entries are always retained.
fn pushCapped(buf: []Route, len: *usize, r: Route) void {
    if (len.* < buf.len) {
        buf[len.*] = r;
        len.* += 1;
        return;
    }
    // Full: shift left by one, append at the end.
    var i: usize = 1;
    while (i < buf.len) : (i += 1) buf[i - 1] = buf[i];
    buf[buf.len - 1] = r;
}

// ── Tests ──

test "navigate pushes back and clears forward" {
    var h: History = .{};
    try std.testing.expectEqual(Route.home, h.current);
    try std.testing.expect(!h.canGoBack());

    h.navigate(.search);
    try std.testing.expectEqual(Route.search, h.current);
    try std.testing.expect(h.canGoBack());
    try std.testing.expect(!h.canGoForward());

    h.navigate(.queue);
    try std.testing.expectEqual(Route.queue, h.current);
    try std.testing.expectEqual(@as(usize, 2), h.back_len);
}

test "navigate to current is a no-op" {
    var h: History = .{};
    h.navigate(.home);
    try std.testing.expectEqual(@as(usize, 0), h.back_len);
}

test "back and forward round-trip" {
    var h: History = .{};
    h.navigate(.search);
    h.navigate(.player);

    h.goBack();
    try std.testing.expectEqual(Route.search, h.current);
    try std.testing.expect(h.canGoForward());

    h.goBack();
    try std.testing.expectEqual(Route.home, h.current);
    try std.testing.expect(!h.canGoBack());

    h.goForward();
    try std.testing.expectEqual(Route.search, h.current);
    h.goForward();
    try std.testing.expectEqual(Route.player, h.current);
    try std.testing.expect(!h.canGoForward());
}

test "new navigation invalidates forward stack" {
    var h: History = .{};
    h.navigate(.search);
    h.navigate(.player);
    h.goBack(); // current = search, fwd = [player]
    try std.testing.expect(h.canGoForward());

    h.navigate(.settings); // should clear forward
    try std.testing.expect(!h.canGoForward());
    try std.testing.expectEqual(Route.settings, h.current);
}

test "leavePlayer returns to last non-player page or home" {
    // Typical: opened player from Search → closing returns to Search.
    var h: History = .{};
    h.navigate(.search);
    h.navigate(.player);
    h.leavePlayer();
    try std.testing.expectEqual(Route.search, h.current);
    try std.testing.expect(!h.canGoForward()); // forward stack cleared

    // Skips stacked player entries, lands on the nearest non-player page.
    var h2: History = .{};
    h2.navigate(.browse);
    h2.navigate(.player);
    h2.back[h2.back_len] = .player; // simulate a player entry buried in history
    h2.back_len += 1;
    h2.leavePlayer();
    try std.testing.expectEqual(Route.browse, h2.current);

    // No non-player history → Home.
    var h3: History = .{};
    h3.navigate(.player);
    h3.leavePlayer();
    try std.testing.expectEqual(Route.home, h3.current);

    // Not on Player → no-op.
    var h4: History = .{};
    h4.navigate(.settings);
    h4.leavePlayer();
    try std.testing.expectEqual(Route.settings, h4.current);
}

test "back stack caps without blocking navigation" {
    var h: History = .{};
    const seq = [_]Route{ .search, .browse, .downloads, .queue, .history, .player, .assistant, .settings, .system };
    // Far more navigations than HISTORY_CAP; must never overflow.
    var n: usize = 0;
    while (n < HISTORY_CAP * 3) : (n += 1) {
        h.navigate(seq[n % seq.len]);
    }
    try std.testing.expect(h.back_len <= HISTORY_CAP);
    // Still fully navigable.
    h.goBack();
    try std.testing.expect(h.canGoForward());
}
