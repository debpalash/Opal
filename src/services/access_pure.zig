//! Pure logic for the Web UI access-control page (web/index.html › Setup ›
//! Access, backed by `/api/access/*` in remote.zig).
//!
//! Everything here is decision logic with no `io_global` / `db` / `state`
//! reach, so it unit-tests standalone — see the cross-boundary note in
//! CLAUDE.md. The routes call straight into these functions so the tested
//! logic is the shipped logic.

const std = @import("std");
const auth = @import("auth_pure.zig");

// ── Caller capabilities ────────────────────────────────────────────────

/// Authentication identifies more than "allowed or denied". The machine
/// credential is a recovery/administration capability; a browser login is a
/// user session and must never be silently promoted to that capability.
pub const Principal = enum {
    machine,
    session,
};

pub const Capability = enum {
    view_access,
    change_own_password,
    revoke_sessions,
    reset_any_password,
    reveal_machine_token,
    rotate_machine_token,
    change_binding,
};

pub fn allows(principal: Principal, capability: Capability) bool {
    return switch (capability) {
        .view_access, .revoke_sessions => true,
        .change_own_password => principal == .session,
        .reset_any_password,
        .reveal_machine_token,
        .rotate_machine_token,
        .change_binding,
        => principal == .machine,
    };
}

// ── Bind mode ──────────────────────────────────────────────────────────────

/// Which interfaces the web server listens on.
///
/// `lan` (0.0.0.0) is the historical, and still default, behaviour — the whole
/// point of Web Remote is reaching Opal from a phone. `loopback` (127.0.0.1)
/// is for people who only ever drive it from the same machine and do not want
/// the JSON API answering on their network at all.
pub const BindMode = enum {
    lan,
    loopback,

    pub fn address(self: BindMode) []const u8 {
        return switch (self) {
            .lan => "0.0.0.0",
            .loopback => "127.0.0.1",
        };
    }

    pub fn id(self: BindMode) []const u8 {
        return @tagName(self);
    }
};

/// Parse a bind mode from an API/config string. Unknown values fall back to
/// `.lan` rather than erroring: a corrupt config must not silently make the
/// server unreachable from the phone it was set up for.
pub fn bindModeFromString(s: []const u8) BindMode {
    if (std.mem.eql(u8, s, "loopback")) return .loopback;
    return .lan;
}

/// Ports Opal will bind. Below 1024 needs root on POSIX and would fail at
/// listen() with no useful feedback, so it's rejected up front.
pub fn validPort(p: u32) bool {
    return p >= 1024 and p <= 65535;
}

/// Parse + validate a port from a query/body string. Null if not a number or
/// out of the allowed range.
pub fn parsePort(s: []const u8) ?u16 {
    const n = std.fmt.parseInt(u32, std.mem.trim(u8, s, " \t\r\n"), 10) catch return null;
    if (!validPort(n)) return null;
    return @intCast(n);
}

// ── Token display ──────────────────────────────────────────────────────────

/// Mask an API token for display: first 4 and last 4 characters, elided
/// middle. Short tokens are fully masked rather than partially revealed —
/// showing 8 of 10 characters is worse than showing none.
pub fn maskToken(token: []const u8, buf: []u8) []const u8 {
    if (token.len < 12) return "••••••••";
    return std.fmt.bufPrint(buf, "{s}••••••••{s}", .{ token[0..4], token[token.len - 4 ..] }) catch "••••••••";
}

// ── Password change ────────────────────────────────────────────────────────

/// Why a password change was refused. `.ok` means the request is well-formed —
/// it says nothing about whether `current` actually matches, which only the
/// store can answer.
pub const PasswordVerdict = enum {
    ok,
    too_short,
    mismatch,
    same_as_current,

    /// User-facing message, also the JSON `error` string on the route.
    pub fn message(self: PasswordVerdict) []const u8 {
        return switch (self) {
            .ok => "",
            .too_short => "password must be at least 8 characters",
            .mismatch => "new password and confirmation do not match",
            .same_as_current => "new password must differ from the current one",
        };
    }
};

/// Validate a password-change request's shape. Ordering matters: length is
/// checked before equality so a too-short password reports the actionable
/// problem rather than "same as current" when a user retypes the old one.
pub fn checkPasswordChange(current: []const u8, new_pw: []const u8, confirm: []const u8) PasswordVerdict {
    if (!auth.validPassword(new_pw)) return .too_short;
    if (!std.mem.eql(u8, new_pw, confirm)) return .mismatch;
    if (std.mem.eql(u8, new_pw, current)) return .same_as_current;
    return .ok;
}

// ── Tests ──

test "bindMode: address mapping" {
    try std.testing.expectEqualStrings("0.0.0.0", BindMode.lan.address());
    try std.testing.expectEqualStrings("127.0.0.1", BindMode.loopback.address());
}

test "bindModeFromString: known values, and unknown falls back to lan" {
    try std.testing.expectEqual(BindMode.loopback, bindModeFromString("loopback"));
    try std.testing.expectEqual(BindMode.lan, bindModeFromString("lan"));
    // A corrupt/legacy config must not strand the phone that uses this.
    try std.testing.expectEqual(BindMode.lan, bindModeFromString(""));
    try std.testing.expectEqual(BindMode.lan, bindModeFromString("LOOPBACK"));
    try std.testing.expectEqual(BindMode.lan, bindModeFromString("garbage"));
}

test "validPort: privileged and out-of-range rejected" {
    try std.testing.expect(validPort(41595));
    try std.testing.expect(validPort(1024));
    try std.testing.expect(validPort(65535));
    try std.testing.expect(!validPort(1023));
    try std.testing.expect(!validPort(80));
    try std.testing.expect(!validPort(0));
    try std.testing.expect(!validPort(65536));
}

test "parsePort: trims, rejects junk and out-of-range" {
    try std.testing.expectEqual(@as(?u16, 41595), parsePort("41595"));
    try std.testing.expectEqual(@as(?u16, 8080), parsePort("  8080 \n"));
    try std.testing.expectEqual(@as(?u16, null), parsePort("80"));
    try std.testing.expectEqual(@as(?u16, null), parsePort("abc"));
    try std.testing.expectEqual(@as(?u16, null), parsePort(""));
    try std.testing.expectEqual(@as(?u16, null), parsePort("99999"));
    try std.testing.expectEqual(@as(?u16, null), parsePort("-1"));
}

test "maskToken: reveals only the outer 4 characters" {
    var buf: [64]u8 = undefined;
    const masked = maskToken("0123456789abcdef0123456789abcdef", &buf);
    try std.testing.expectEqualStrings("0123••••••••cdef", masked);
}

test "maskToken: short tokens are fully masked, never partially revealed" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("••••••••", maskToken("short", &buf));
    try std.testing.expectEqualStrings("••••••••", maskToken("", &buf));
    // 11 chars — one under the threshold; revealing 8 of 11 would be worse
    // than revealing none.
    try std.testing.expectEqualStrings("••••••••", maskToken("0123456789a", &buf));
}

test "checkPasswordChange: happy path" {
    try std.testing.expectEqual(PasswordVerdict.ok, checkPasswordChange("oldpassword", "newpassword", "newpassword"));
}

test "checkPasswordChange: too short beats every other complaint" {
    // Also mismatched AND same-as-current, but length is the actionable one.
    try std.testing.expectEqual(PasswordVerdict.too_short, checkPasswordChange("short", "short", "nope"));
    try std.testing.expectEqual(PasswordVerdict.too_short, checkPasswordChange("oldpassword", "1234567", "1234567"));
}

test "checkPasswordChange: confirmation must match" {
    try std.testing.expectEqual(PasswordVerdict.mismatch, checkPasswordChange("oldpassword", "newpassword", "newpassw0rd"));
}

test "checkPasswordChange: reusing the current password is refused" {
    try std.testing.expectEqual(PasswordVerdict.same_as_current, checkPasswordChange("samepassword", "samepassword", "samepassword"));
}

test "PasswordVerdict: every non-ok verdict has a message" {
    for ([_]PasswordVerdict{ .too_short, .mismatch, .same_as_current }) |v| {
        try std.testing.expect(v.message().len > 0);
    }
    try std.testing.expectEqualStrings("", PasswordVerdict.ok.message());
}

test "session capability never includes machine recovery or network authority" {
    try std.testing.expect(allows(.session, .view_access));
    try std.testing.expect(allows(.session, .change_own_password));
    try std.testing.expect(allows(.session, .revoke_sessions));
    try std.testing.expect(!allows(.session, .reset_any_password));
    try std.testing.expect(!allows(.session, .reveal_machine_token));
    try std.testing.expect(!allows(.session, .rotate_machine_token));
    try std.testing.expect(!allows(.session, .change_binding));
}

test "machine credential carries only the intended recovery capabilities" {
    try std.testing.expect(allows(.machine, .view_access));
    try std.testing.expect(allows(.machine, .reset_any_password));
    try std.testing.expect(allows(.machine, .reveal_machine_token));
    try std.testing.expect(allows(.machine, .rotate_machine_token));
    try std.testing.expect(allows(.machine, .change_binding));
    try std.testing.expect(allows(.machine, .revoke_sessions));
    try std.testing.expect(!allows(.machine, .change_own_password));
}
