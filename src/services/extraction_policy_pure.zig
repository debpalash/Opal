//! Extraction order and outcome for a scraper page fetch. Pure: no state, no io.
//!
//! The order is fixed and the same every time:
//!   1. plain HTTP (always)
//!   2. the user's paired browser (only with the browser opt-in)
//!   3. the anti-detect browser engine (only with the opt-in and an installed engine)
//!
//! A browser of either kind is reached only when the user has opted in
//! (`extraction_browser_opt_in`, default off). Without the opt-in a challenge
//! page ends the fetch with `.blocked_opt_in_required`, so a caller can show
//! why the source came back empty instead of silently starting a browser.
//! scrape_fetch.zig executes exactly the plan this module returns.

const std = @import("std");

pub const Tier = enum {
    plain,
    paired_browser,
    antidetect_browser,

    pub fn isBrowser(self: Tier) bool {
        return self != .plain;
    }
};

pub const Outcome = enum {
    /// Content returned by the tier recorded alongside.
    ok,
    /// The URL failed validation or is a private-network target.
    refused_target,
    cancelled,
    /// No response at all (DNS, connect, timeout).
    unreachable_host,
    /// A non-2xx response that is not a challenge page.
    http_error,
    /// A challenge page, and the user has not opted in to browser fallback.
    blocked_opt_in_required,
    /// A challenge page, opted in, but no browser tier is available.
    blocked_no_browser,
    /// A challenge page, and every browser tier tried also failed.
    blocked_browser_failed,

    pub fn label(self: Outcome) []const u8 {
        return @tagName(self);
    }
};

/// What the runtime knows about the browser tiers at the moment of a block.
pub const Availability = struct {
    opted_in: bool = false,
    paired_connected: bool = false,
    engine_ready: bool = false,
};

pub const Plan = struct {
    tiers: [2]Tier = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Plan) []const Tier {
        return self.tiers[0..self.len];
    }
};

/// Browser tiers to try after a blocked plain fetch, in order. Empty without
/// the opt-in, whatever is installed or connected.
pub fn browserTiers(avail: Availability) Plan {
    var plan: Plan = .{};
    if (!avail.opted_in) return plan;
    if (avail.paired_connected) {
        plan.tiers[plan.len] = .paired_browser;
        plan.len += 1;
    }
    if (avail.engine_ready) {
        plan.tiers[plan.len] = .antidetect_browser;
        plan.len += 1;
    }
    return plan;
}

/// May this tier run? The single gate every browser launch goes through.
pub fn mayUse(tier: Tier, avail: Availability) bool {
    for (browserTiers(avail).slice()) |t| {
        if (t == tier) return true;
    }
    return tier == .plain;
}

/// Pre-warming the anti-detect engine starts a browser process, so it follows
/// the same rule as a fallback fetch.
pub fn shouldPrewarm(avail: Availability) bool {
    return mayUse(.antidetect_browser, avail);
}

pub const PlainResponse = struct {
    /// Transport finished and returned a 2xx status.
    succeeded: bool,
    status: u16,
    /// scrape_fetch_pure.needsBrowser for this response.
    challenge: bool,
};

pub const PlainVerdict = enum { content, challenge, http_error, unreachable_host };

pub fn classifyPlain(r: PlainResponse) PlainVerdict {
    if (r.challenge) return .challenge;
    // An empty 2xx page is an answer ("nothing here"), not a failure.
    if (r.succeeded) return .content;
    if (r.status == 0) return .unreachable_host;
    return .http_error;
}

/// Outcome after the plain fetch was blocked and `tried` browser tiers failed.
pub fn blockedOutcome(avail: Availability, tried: usize) Outcome {
    if (!avail.opted_in) return .blocked_opt_in_required;
    if (tried == 0) return .blocked_no_browser;
    return .blocked_browser_failed;
}

/// A browser answer counts only when it is real content, not another
/// challenge or an error document.
pub fn browserAnswerUsable(status: u16, body_len: usize, challenge: bool) bool {
    return status < 400 and body_len > 0 and !challenge;
}

// ── Tests ──

test "no opt-in: no browser tier, whatever is installed or connected" {
    const avail: Availability = .{ .opted_in = false, .paired_connected = true, .engine_ready = true };
    try std.testing.expectEqual(@as(usize, 0), browserTiers(avail).slice().len);
    try std.testing.expect(!mayUse(.paired_browser, avail));
    try std.testing.expect(!mayUse(.antidetect_browser, avail));
    try std.testing.expect(mayUse(.plain, avail));
    try std.testing.expect(!shouldPrewarm(avail));
    try std.testing.expectEqual(Outcome.blocked_opt_in_required, blockedOutcome(avail, 0));
}

test "default availability is private" {
    const avail: Availability = .{};
    try std.testing.expect(!avail.opted_in);
    try std.testing.expectEqual(@as(usize, 0), browserTiers(avail).slice().len);
}

test "opt-in order is paired browser then anti-detect engine" {
    const both = browserTiers(.{ .opted_in = true, .paired_connected = true, .engine_ready = true });
    try std.testing.expectEqualSlices(Tier, &.{ .paired_browser, .antidetect_browser }, both.slice());
    const engine_only = browserTiers(.{ .opted_in = true, .engine_ready = true });
    try std.testing.expectEqualSlices(Tier, &.{.antidetect_browser}, engine_only.slice());
    const paired_only = browserTiers(.{ .opted_in = true, .paired_connected = true });
    try std.testing.expectEqualSlices(Tier, &.{.paired_browser}, paired_only.slice());
    try std.testing.expect(shouldPrewarm(.{ .opted_in = true, .engine_ready = true }));
    try std.testing.expect(!shouldPrewarm(.{ .opted_in = true, .paired_connected = true }));
}

test "blocked outcomes are distinct and typed" {
    try std.testing.expectEqual(Outcome.blocked_no_browser, blockedOutcome(.{ .opted_in = true }, 0));
    try std.testing.expectEqual(Outcome.blocked_browser_failed, blockedOutcome(.{ .opted_in = true, .engine_ready = true }, 1));
    try std.testing.expectEqualStrings("blocked_opt_in_required", Outcome.blocked_opt_in_required.label());
}

test "plain classification: challenge wins over status, error bodies are not content" {
    try std.testing.expectEqual(PlainVerdict.content, classifyPlain(.{ .succeeded = true, .status = 200, .challenge = false }));
    try std.testing.expectEqual(PlainVerdict.challenge, classifyPlain(.{ .succeeded = false, .status = 403, .challenge = true }));
    try std.testing.expectEqual(PlainVerdict.challenge, classifyPlain(.{ .succeeded = true, .status = 200, .challenge = true }));
    try std.testing.expectEqual(PlainVerdict.http_error, classifyPlain(.{ .succeeded = false, .status = 404, .challenge = false }));
    try std.testing.expectEqual(PlainVerdict.content, classifyPlain(.{ .succeeded = true, .status = 204, .challenge = false }));
    try std.testing.expectEqual(PlainVerdict.unreachable_host, classifyPlain(.{ .succeeded = false, .status = 0, .challenge = false }));
}

test "browser answers: a second challenge or an error page is not content" {
    try std.testing.expect(browserAnswerUsable(200, 10, false));
    try std.testing.expect(!browserAnswerUsable(200, 10, true));
    try std.testing.expect(!browserAnswerUsable(503, 10, false));
    try std.testing.expect(!browserAnswerUsable(200, 0, false));
}
