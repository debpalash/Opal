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
    admin_session,
    session,
    /// A paired browser (Opal Connect). It holds a token that can do almost
    /// nothing: see `browser_routes`. Unlike the others it is allowlisted, not
    /// denylisted, so a route added later is closed to it until someone lists it.
    browser,
};

pub const Capability = enum {
    view_access,
    change_own_password,
    revoke_sessions,
    reset_any_password,
    reveal_machine_token,
    rotate_machine_token,
    change_binding,
    manage_users,
    administer_host,
    approve_executable,
};

pub fn allows(principal: Principal, capability: Capability) bool {
    // A paired browser holds no capability at all; its few routes are matched
    // by `browserRouteAllowed`, never by this table.
    if (principal == .browser) return false;
    return switch (capability) {
        .view_access, .revoke_sessions => true,
        .change_own_password => principal != .machine,
        .manage_users, .administer_host => principal == .machine or principal == .admin_session,
        .approve_executable,
        .reset_any_password,
        .reveal_machine_token,
        .rotate_machine_token,
        .change_binding,
        => principal == .machine,
    };
}

pub fn isSession(principal: Principal) bool {
    return principal == .session or principal == .admin_session;
}

// ── Bind mode ──────────────────────────────────────────────────────────────

/// Loopback is the safe default. LAN HTTP requires an explicit configuration.
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

/// Invalid or missing configuration fails closed to loopback.
pub fn bindModeFromString(s: []const u8) BindMode {
    if (std.mem.eql(u8, s, "lan")) return .lan;
    return .loopback;
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

test "bindModeFromString: known values, and unknown fails closed to loopback" {
    try std.testing.expectEqual(BindMode.loopback, bindModeFromString("loopback"));
    try std.testing.expectEqual(BindMode.lan, bindModeFromString("lan"));
    // Missing or invalid configuration must not expose a network listener.
    try std.testing.expectEqual(BindMode.loopback, bindModeFromString(""));
    try std.testing.expectEqual(BindMode.loopback, bindModeFromString("LOOPBACK"));
    try std.testing.expectEqual(BindMode.loopback, bindModeFromString("garbage"));
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
    try std.testing.expect(!allows(.session, .manage_users));
}

test "admin sessions manage accounts without gaining machine recovery powers" {
    try std.testing.expect(allows(.admin_session, .change_own_password));
    try std.testing.expect(allows(.admin_session, .manage_users));
    try std.testing.expect(!allows(.admin_session, .reset_any_password));
    try std.testing.expect(!allows(.admin_session, .reveal_machine_token));
    try std.testing.expect(!allows(.admin_session, .change_binding));
}

test "machine credential carries only the intended recovery capabilities" {
    try std.testing.expect(allows(.machine, .view_access));
    try std.testing.expect(allows(.machine, .reset_any_password));
    try std.testing.expect(allows(.machine, .reveal_machine_token));
    try std.testing.expect(allows(.machine, .rotate_machine_token));
    try std.testing.expect(allows(.machine, .change_binding));
    try std.testing.expect(allows(.machine, .revoke_sessions));
    try std.testing.expect(allows(.machine, .manage_users));
    try std.testing.expect(!allows(.machine, .change_own_password));
}

/// Central authorization before feature dispatch. Parameters are decoded by
/// the HTTP adapter; handlers never decide privilege from a confirmation flag.
pub fn routeCapability(path: []const u8, method: []const u8, action: []const u8) ?Capability {
    if (std.mem.eql(u8, path, "/plugins") and !std.mem.eql(u8, method, "GET")) {
        if (std.mem.eql(u8, action, "approve-exec") or std.mem.eql(u8, action, "revoke-exec")) return .approve_executable;
        return .administer_host;
    }
    const host_routes = [_][]const u8{
        "/setup/sources",        "/setup/tmdb",     "/settings",            "/settings/toggle",
        "/source/add",           "/source/config",  "/livetv/sources",      "/rss/manage",
        "/local-library/action", "/jellyfin/login", "/jellyfin/disconnect", "/abs/login",
        "/abs/logout",           "/opds/connect",   "/opds/disconnect",     "/plex/connect",
        "/plex/disconnect",      "/suwayomi",       "/sync-accounts",       "/trakt",
        "/webui",                "/logs/clear",
        // Scheduled agent runs spend the host's agent credit and act on its behalf.
        "/agent/tasks",          "/agent/tasks/add", "/agent/tasks/enable", "/agent/tasks/remove",
        "/agent/tasks/run",
        // The operator's jobs and the decisions on its proposals belong to the host user.
        "/operator",             "/operator/approve",  "/operator/reject",
        // Who is paired, and removing one. A browser token may only unpair itself
        // (see `browser_routes`); listing and revoking others is the host's.
        "/browser/links",        "/browser/revoke",
        // What agents may read of the shared page, and playing one of its streams by id.
        // Host administration (machine token, admin session); a paired browser holds
        // neither, and a plain web session is not the host.
        "/browser/context",      "/browser/play",
        // Fetching a page through the user's browser spends their cookies' reach;
        // the extension's per-origin allow list is the second gate.
        "/browser/fetch",
    };
    for (host_routes) |route| if (std.mem.eql(u8, path, route)) return .administer_host;
    return null;
}

/// Everything a paired browser may call, by `/api`-relative path and method.
/// This list IS the browser principal's whole authority.
///   /status           read now-playing, so the panel can show connection state
///   /browser/me       who am I (label), a token check that moves nothing
///   /browser/media    hand a detected stream to the player or the queue
///   /browser/page     share the page the user is on (the user pressed the button)
///   /browser/tabs     report the open tabs (refused unless the user's switch in Opal is on)
///   /browser/revoke   unpair this browser (itself only; the handler ignores any id)
///   GET  /browser/jobs        long-poll for a page Opal wants fetched (see `browserRouteAllowed`)
///   POST /browser/jobs/<id>   answer that job (digits only; the job must be this browser's)
/// `/browser/pair` is unauthenticated and never reaches this check.
pub const browser_routes = [_]struct { path: []const u8, method: []const u8 }{
    .{ .path = "/status", .method = "GET" },
    .{ .path = "/browser/me", .method = "GET" },
    .{ .path = "/browser/media", .method = "POST" },
    .{ .path = "/browser/page", .method = "POST" },
    .{ .path = "/browser/tabs", .method = "POST" },
    .{ .path = "/browser/revoke", .method = "POST" },
};

/// `/browser/jobs/<id>`: a decimal job id and nothing else (no sign, no slash,
/// no query, at most ten digits), so the prefix opens exactly one route.
pub fn browserJobResultId(path: []const u8) ?u32 {
    const prefix = "/browser/jobs/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    if (rest.len == 0 or rest.len > 10) return null;
    for (rest) |ch| if (ch < '0' or ch > '9') return null;
    return std.fmt.parseInt(u32, rest, 10) catch null;
}

pub fn browserRouteAllowed(path: []const u8, method: []const u8) bool {
    for (browser_routes) |r| {
        if (std.mem.eql(u8, path, r.path) and std.mem.eql(u8, method, r.method)) return true;
    }
    if (std.mem.eql(u8, path, "/browser/jobs")) return std.mem.eql(u8, method, "GET");
    if (browserJobResultId(path) != null) return std.mem.eql(u8, method, "POST");
    return false;
}

/// Routes that exist only for a paired browser's own token. Another caller
/// (the machine token, a web session) has no business posting "media from my
/// browser", so they are refused rather than treated as unlisted-means-open.
fn browserOnlyRoute(path: []const u8) bool {
    return std.mem.eql(u8, path, "/browser/media") or std.mem.eql(u8, path, "/browser/me") or std.mem.eql(u8, path, "/browser/page") or
        std.mem.eql(u8, path, "/browser/tabs") or std.mem.eql(u8, path, "/browser/jobs") or browserJobResultId(path) != null;
}

pub fn allowsRoute(principal: Principal, path: []const u8, method: []const u8, action: []const u8) bool {
    if (principal == .browser) return browserRouteAllowed(path, method);
    if (browserOnlyRoute(path)) return false;
    const capability = routeCapability(path, method, action) orelse return true;
    return allows(principal, capability);
}

test "route privilege matrix protects host administration and executable trust" {
    for ([_]Principal{ .machine, .admin_session, .session }) |principal| {
        try std.testing.expectEqual(principal == .machine, allowsRoute(principal, "/plugins", "POST", "approve-exec"));
        try std.testing.expectEqual(principal == .machine, allowsRoute(principal, "/plugins", "POST", "revoke-exec"));
        try std.testing.expectEqual(principal != .session, allowsRoute(principal, "/plugins", "POST", "install"));
        try std.testing.expectEqual(principal != .session, allowsRoute(principal, "/local-library/action", "POST", "add-root"));
        try std.testing.expectEqual(principal != .session, allowsRoute(principal, "/jellyfin/login", "POST", ""));
        try std.testing.expectEqual(principal != .session, allowsRoute(principal, "/setup/tmdb", "GET", ""));
        for ([_][]const u8{ "/agent/tasks", "/agent/tasks/add", "/agent/tasks/enable", "/agent/tasks/remove", "/agent/tasks/run" }) |route| {
            try std.testing.expectEqual(principal != .session, allowsRoute(principal, route, "POST", ""));
        }
        for ([_][]const u8{ "/operator", "/operator/approve", "/operator/reject" }) |route| {
            try std.testing.expectEqual(principal != .session, allowsRoute(principal, route, "POST", ""));
        }
        try std.testing.expect(allowsRoute(principal, "/plugins", "GET", ""));
        try std.testing.expect(allowsRoute(principal, "/status", "GET", ""));
        try std.testing.expect(allowsRoute(principal, "/jellyfin/play", "POST", ""));
    }
}

// ── Paired browser principal ───────────────────────────────────────────────

test "a paired browser holds no capability" {
    inline for (@typeInfo(Capability).@"enum".fields) |f| {
        try std.testing.expect(!allows(.browser, @field(Capability, f.name)));
    }
    try std.testing.expect(!isSession(.browser));
}

test "browser allowlist is exactly the six documented routes" {
    try std.testing.expectEqual(@as(usize, 6), browser_routes.len);
    try std.testing.expect(allowsRoute(.browser, "/browser/tabs", "POST", ""));
    try std.testing.expect(!allowsRoute(.browser, "/browser/tabs", "GET", ""));
    for ([_]Principal{ .machine, .admin_session, .session }) |p| try std.testing.expect(!allowsRoute(p, "/browser/tabs", "POST", ""));
    try std.testing.expect(allowsRoute(.browser, "/browser/page", "POST", ""));
    try std.testing.expect(!allowsRoute(.browser, "/browser/page", "GET", ""));
    try std.testing.expect(allowsRoute(.browser, "/status", "GET", ""));
    try std.testing.expect(allowsRoute(.browser, "/browser/me", "GET", ""));
    try std.testing.expect(allowsRoute(.browser, "/browser/media", "POST", ""));
    try std.testing.expect(allowsRoute(.browser, "/browser/revoke", "POST", ""));
    // The method is part of the grant.
    try std.testing.expect(!allowsRoute(.browser, "/status", "POST", ""));
    try std.testing.expect(!allowsRoute(.browser, "/browser/media", "GET", ""));
    try std.testing.expect(!allowsRoute(.browser, "/browser/me", "POST", ""));
    try std.testing.expect(!allowsRoute(.browser, "/browser/revoke", "GET", ""));
}

test "browser links and revoke belong to the host; media and me to the browser" {
    for ([_]Principal{ .machine, .admin_session }) |p| {
        try std.testing.expect(allowsRoute(p, "/browser/links", "GET", ""));
        try std.testing.expect(allowsRoute(p, "/browser/revoke", "POST", ""));
    }
    try std.testing.expect(!allowsRoute(.session, "/browser/links", "GET", ""));
    try std.testing.expect(!allowsRoute(.session, "/browser/revoke", "POST", ""));
    // Not even the machine token posts media "from a browser".
    for ([_]Principal{ .machine, .admin_session, .session }) |p| {
        try std.testing.expect(!allowsRoute(p, "/browser/media", "POST", ""));
        try std.testing.expect(!allowsRoute(p, "/browser/me", "GET", ""));
    }
}

test "the page share is the browser's alone; what agents read is the host's alone" {
    // A browser shares; nobody else posts "from a browser".
    for ([_]Principal{ .machine, .admin_session, .session }) |p| {
        try std.testing.expect(!allowsRoute(p, "/browser/page", "POST", ""));
    }
    // Agents (machine token) and web admins read the context and play by id; a plain
    // web session is not the host, and a paired browser never reads back what it shared.
    for ([_][]const u8{ "/browser/context", "/browser/play" }) |route| {
        try std.testing.expect(allowsRoute(.machine, route, "GET", ""));
        try std.testing.expect(allowsRoute(.admin_session, route, "POST", ""));
        try std.testing.expect(!allowsRoute(.session, route, "GET", ""));
        try std.testing.expect(!allowsRoute(.browser, route, "GET", ""));
        try std.testing.expect(!allowsRoute(.browser, route, "POST", ""));
    }
}

test "the job queue routes are the browser's alone, and the id route opens digits only" {
    try std.testing.expect(allowsRoute(.browser, "/browser/jobs", "GET", ""));
    try std.testing.expect(!allowsRoute(.browser, "/browser/jobs", "POST", ""));
    try std.testing.expect(allowsRoute(.browser, "/browser/jobs/12", "POST", ""));
    try std.testing.expect(!allowsRoute(.browser, "/browser/jobs/12", "GET", ""));
    try std.testing.expect(!allowsRoute(.browser, "/browser/jobs/12", "DELETE", ""));
    for ([_][]const u8{ "/browser/jobs/", "/browser/jobs/abc", "/browser/jobs/-1", "/browser/jobs/1/x", "/browser/jobs/1?x=1", "/browser/jobs/../fetch", "/browser/jobs/99999999999", "/browser/jobs/1 ", "/browser/jobsx", "/browser/jobs/0x10" }) |bad| {
        try std.testing.expect(!allowsRoute(.browser, bad, "POST", ""));
        try std.testing.expect(!allowsRoute(.browser, bad, "GET", ""));
    }
    // Nobody else answers a browser's job or polls for one.
    for ([_]Principal{ .machine, .admin_session, .session }) |p| {
        try std.testing.expect(!allowsRoute(p, "/browser/jobs", "GET", ""));
        try std.testing.expect(!allowsRoute(p, "/browser/jobs/12", "POST", ""));
    }
    // Queuing a fetch is the host's; a browser can never queue work for itself.
    for ([_]Principal{ .machine, .admin_session }) |p| try std.testing.expect(allowsRoute(p, "/browser/fetch", "POST", ""));
    try std.testing.expect(!allowsRoute(.session, "/browser/fetch", "POST", ""));
    try std.testing.expect(!allowsRoute(.browser, "/browser/fetch", "POST", ""));
    try std.testing.expect(!allowsRoute(.browser, "/browser/fetch", "GET", ""));
}

test "every other route is denied to a paired browser, by name" {
    // The sensitive families, plus the playback and library routes that look
    // harmless: none is on the allowlist.
    const denied = [_][]const u8{
        "/settings",            "/settings/toggle",      "/setup",                "/setup/sources",      "/setup/tmdb",
        "/plugins",             "/plugins/install",      "/downloads",            "/downloads/action",   "/downloads/play",
        "/download/url",        "/wanted",               "/wanted/add",           "/wanted/check",       "/agent/tasks",
        "/agent/tasks/add",     "/agent/tasks/enable",   "/agent/tasks/remove",   "/agent/tasks/run",    "/operator",
        "/operator/approve",    "/operator/reject",      "/open",                 "/ingest",             "/load",
        "/player",              "/player/action",        "/queue",                "/queue/action",       "/unified_search",
        "/unified_search/play", "/unified_search/queue", "/search",               "/library",            "/library/action",
        "/collections",         "/torrents",             "/torrent/files",        "/cast/start",         "/cast/scan",
        "/party",               "/source/add",           "/source/config",        "/rss",                "/rss/manage",
        "/livetv",              "/livetv/sources",       "/local-library/action", "/jellyfin/login",     "/plex/connect",
        "/sync-accounts",       "/trakt",                "/webui",                "/logs",               "/logs/clear",
        "/access/status",       "/access/users",         "/access/token/rotate",  "/auth/login",         "/scrape",
        "/host",                "/history",              "/ai",                   "/music",              "/home",
        "/browser/pair",        "/browser/links",        "/browser",              "/browser/",           "/browser/media/",
        "/browser/mediax",      "/browser/ws",           "/browser/pagex",        "/browser/context",    "/browser/fetch",
        "/browser/play",        "/browser/page/",        "/browser/context/",
        "/health",              "/events",               "/stream",               "/status/",            "",
        "/",
    };
    for (denied) |path| {
        for ([_][]const u8{ "GET", "POST", "PUT", "DELETE", "" }) |method| {
            try std.testing.expect(!allowsRoute(.browser, path, method, ""));
            try std.testing.expect(!allowsRoute(.browser, path, method, "approve-exec"));
        }
    }
}

test "every documented agent route is denied to a paired browser except GET /status" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, @embedFile("openapi_json"), .{});
    defer parsed.deinit();
    const paths = parsed.value.object.get("paths").?.object;
    var checked: usize = 0;
    var it = paths.iterator();
    while (it.next()) |entry| {
        // Keys carry query/fragment decorations such as "/plugins?action=install".
        const key = entry.key_ptr.*;
        const end = std.mem.indexOfAny(u8, key, "?#") orelse key.len;
        const route = key[0..end];
        for ([_][]const u8{ "GET", "POST" }) |method| {
            const expected = std.mem.eql(u8, route, "/status") and std.mem.eql(u8, method, "GET");
            try std.testing.expectEqual(expected, allowsRoute(.browser, route, method, ""));
        }
        checked += 1;
    }
    // Guards against the test silently iterating nothing.
    try std.testing.expect(checked > 50);
}
