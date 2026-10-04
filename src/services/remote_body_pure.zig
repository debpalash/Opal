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

/// Largest body a gated route may send by default. Matches browser_link_pure.MAX_BODY.
pub const GROW_MAX_BODY: usize = 64 * 1024;
/// The one route that may send more: a paired browser answering a fetch job with
/// the page text (browser_fetch_pure.MAX_RESULT, 2 MB).
pub const GROW_MAX_RESULT: usize = 2 * 1024 * 1024;

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
/// Content-Length, `gate_max` the largest body the route-specific gate approved
/// (0 = the route did not ask to grow).
pub fn plan(buf_len: usize, header_end: usize, body_len: usize, gate_max: usize) Plan {
    const head = std.math.add(usize, header_end, 4) catch return .too_large;
    const total = std.math.add(usize, head, body_len) catch return .too_large;
    if (total <= buf_len) return .fits;
    if (gate_max == 0) return .too_large;
    if (body_len > @min(gate_max, GROW_MAX_RESULT)) return .too_large;
    return .grow;
}

test "a request that fits the fixed buffer is unchanged, gated or not" {
    try std.testing.expectEqual(Plan.fits, plan(4096, 200, 100, 0));
    try std.testing.expectEqual(Plan.fits, plan(4096, 200, 100, GROW_MAX_BODY));
    // Equality is valid: head 204 + body 3892 == 4096.
    try std.testing.expectEqual(Plan.fits, plan(4096, 200, 3892, 0));
}

test "an ungated oversized request is refused" {
    try std.testing.expectEqual(Plan.too_large, plan(4096, 200, 3893, 0));
    try std.testing.expectEqual(Plan.too_large, plan(4096, 200, 60_000, 0));
}

test "a gated route may grow up to the cap and no further" {
    try std.testing.expectEqual(Plan.grow, plan(4096, 200, 3893, GROW_MAX_BODY));
    try std.testing.expectEqual(Plan.grow, plan(4096, 200, GROW_MAX_BODY, GROW_MAX_BODY));
    try std.testing.expectEqual(Plan.too_large, plan(4096, 200, GROW_MAX_BODY + 1, GROW_MAX_BODY));
}

test "overflowing lengths are refused, not wrapped" {
    try std.testing.expectEqual(Plan.too_large, plan(4096, 200, std.math.maxInt(usize), GROW_MAX_BODY));
    try std.testing.expectEqual(Plan.too_large, plan(4096, std.math.maxInt(usize), 10, GROW_MAX_BODY));
}

test "the result route may grow to 2 MB, and no gate can raise the ceiling past that" {
    try std.testing.expectEqual(Plan.grow, plan(4096, 200, GROW_MAX_RESULT, GROW_MAX_RESULT));
    try std.testing.expectEqual(Plan.too_large, plan(4096, 200, GROW_MAX_RESULT + 1, GROW_MAX_RESULT));
    try std.testing.expectEqual(Plan.too_large, plan(4096, 200, GROW_MAX_RESULT + 1, std.math.maxInt(usize)));
    // A route that asked for 64 KB does not get 2 MB.
    try std.testing.expectEqual(Plan.too_large, plan(4096, 200, GROW_MAX_BODY + 1, GROW_MAX_BODY));
}
