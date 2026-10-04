//! Decides how much request body the remote HTTP server will buffer.
//!
//! Every request normally has to fit one 4096-byte stack buffer (head and body
//! together). That is right for the control API and wrong for exactly one
//! route: a paired browser posting a tokenized HLS URL plus its Referer, which
//! can exceed 4 KB on its own. This module is the single rule for letting a
//! request outgrow the buffer, kept pure so the limits are tested.
//!
//! The head is still read into the fixed buffer and is still capped by it; only
//! the BODY may spill into a heap buffer, only when the route's gate approved
//! the already-read head (which includes authenticating the caller, so an
//! anonymous client cannot make the server allocate), and only up to
//! `GROW_MAX_BODY`.

const std = @import("std");

/// Largest body a gated route may send. Matches browser_link_pure.MAX_BODY.
pub const GROW_MAX_BODY: usize = 64 * 1024;

pub const Plan = enum {
    /// Head and body fit the fixed buffer: today's behaviour.
    fits,
    /// Allocate `head + 4 + body` bytes and keep reading.
    grow,
    /// Refuse: over the cap, or the route did not ask to grow.
    too_large,
};

/// `buf_len` is the fixed buffer size, `header_end` the offset of the blank
/// line (so the head is `header_end + 4` bytes), `body_len` the declared
/// Content-Length, `gate_ok` whether the route-specific gate approved growth.
pub fn plan(buf_len: usize, header_end: usize, body_len: usize, gate_ok: bool) Plan {
    const head = std.math.add(usize, header_end, 4) catch return .too_large;
    const total = std.math.add(usize, head, body_len) catch return .too_large;
    if (total <= buf_len) return .fits;
    if (!gate_ok) return .too_large;
    if (body_len > GROW_MAX_BODY) return .too_large;
    return .grow;
}

test "a request that fits the fixed buffer is unchanged, gated or not" {
    try std.testing.expectEqual(Plan.fits, plan(4096, 200, 100, false));
    try std.testing.expectEqual(Plan.fits, plan(4096, 200, 100, true));
    // Equality is valid: head 204 + body 3892 == 4096.
    try std.testing.expectEqual(Plan.fits, plan(4096, 200, 3892, false));
}

test "an ungated oversized request is refused" {
    try std.testing.expectEqual(Plan.too_large, plan(4096, 200, 3893, false));
    try std.testing.expectEqual(Plan.too_large, plan(4096, 200, 60_000, false));
}

test "a gated route may grow up to the cap and no further" {
    try std.testing.expectEqual(Plan.grow, plan(4096, 200, 3893, true));
    try std.testing.expectEqual(Plan.grow, plan(4096, 200, GROW_MAX_BODY, true));
    try std.testing.expectEqual(Plan.too_large, plan(4096, 200, GROW_MAX_BODY + 1, true));
}

test "overflowing lengths are refused, not wrapped" {
    try std.testing.expectEqual(Plan.too_large, plan(4096, 200, std.math.maxInt(usize), true));
    try std.testing.expectEqual(Plan.too_large, plan(4096, std.math.maxInt(usize), 10, true));
}
