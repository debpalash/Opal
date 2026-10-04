//! Pure rules for the endpoint_repair operator job: when a source counts as
//! failing, what the agent is told about it, how a proposed address is judged
//! (with the network probe injected), and how one field is merged into a source
//! configuration. No IO here, so all of it is unit tested.
//!
//! The context is sent to a third-party agent. It is therefore built from a
//! fixed set of facts and never from a whole configuration: only the scheme and
//! host of the base address ever leave the app.

const std = @import("std");
const op = @import("operator_pure.zig");

// ── Failure streaks ─────────────────────────────────────────────────────

/// Mirrors reliable_fetch.Failure so this file stays dependency free.
pub const Failure = enum { none, invalid_input, spawn, transport, malformed_response, truncated, empty, cancelled, timed_out };

/// This many consecutive counted failures before the operator is asked. Five is
/// enough to rule out one flaky request or one bad search while still reacting
/// within a day of real use; the operator's own 24 hour cooldown per source
/// bounds how often the question can repeat.
pub const THRESHOLD: u16 = 5;
/// The failures must also span this long, so five retries inside one search do
/// not count as five separate observations.
pub const MIN_SPAN_MS: i64 = 2 * 60 * 1000;

pub const Outcome = enum { success, failure, ignore };

/// How one finished request affects the streak. Cancellations, local problems
/// (cannot spawn curl, truncated buffer, bad arguments), rate limiting,
/// authentication and body validation problems say nothing about the address
/// being gone, so they neither count nor reset.
pub fn classify(failure: Failure, status: u16) Outcome {
    switch (failure) {
        .none => {},
        .transport, .timed_out => return .failure,
        else => return .ignore,
    }
    if (status >= 200 and status < 400) return .success;
    if (status == 401 or status == 408 or status == 429 or status < 200) return .ignore;
    return .failure; // 403, 404, 410, 451, 5xx, Cloudflare 52x
}

pub const Streak = struct {
    count: u16 = 0,
    first_ms: i64 = 0,
    last_ms: i64 = 0,
    last_status: u16 = 0,
    last_failure: Failure = .none,
    /// At least one failure in the streak was a real HTTP answer (not only
    /// "could not connect").
    http_seen: bool = false,
};

/// Fold one request into `s`. Returns true when the operator should be asked now
/// (the streak is then reset so the next ask needs a fresh streak).
/// `net_ok_ms` is when ANY source last succeeded: a streak made only of connect
/// failures with no success anywhere since it began looks like the user being
/// offline, not a moved source.
pub fn record(s: *Streak, outcome: Outcome, failure: Failure, status: u16, now_ms: i64, net_ok_ms: i64) ?Streak {
    switch (outcome) {
        .ignore => return null,
        .success => {
            s.* = .{};
            return null;
        },
        .failure => {},
    }
    if (s.count == 0) s.first_ms = now_ms;
    if (s.count < std.math.maxInt(u16)) s.count += 1;
    s.last_status = status;
    s.last_failure = failure;
    s.last_ms = now_ms;
    if (status >= 400) s.http_seen = true;
    if (s.count < THRESHOLD or now_ms - s.first_ms < MIN_SPAN_MS) return null;
    if (!s.http_seen and net_ok_ms < s.first_ms) return null;
    const snapshot = s.*;
    s.* = .{};
    return snapshot;
}

/// `record` as a yes/no, for tests.
fn asks(s: *Streak, outcome: Outcome, failure: Failure, status: u16, now_ms: i64, net_ok_ms: i64) bool {
    return record(s, outcome, failure, status, now_ms, net_ok_ms) != null;
}

// ── Context for the agent ───────────────────────────────────────────────

/// Scheme and host (and an explicit port) of `url`; credentials, path, query and
/// fragment are dropped. Null when it is not an http(s) address with a host.
pub fn hostOnly(url: []const u8, out: []u8) ?[]const u8 {
    if (url.len == 0 or url.len > 2048) return null;
    for (url) |ch| if (ch <= 0x20 or ch == 0x7f) return null;
    const uri = std.Uri.parse(url) catch return null;
    if (!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http")) return null;
    const host_comp = uri.host orelse return null;
    var host_buf: [256]u8 = undefined;
    const host = host_comp.toRaw(&host_buf) catch return null;
    if (host.len == 0) return null;
    return (if (uri.port) |p|
        std.fmt.bufPrint(out, "{s}://{s}:{d}", .{ uri.scheme, host, p })
    else
        std.fmt.bufPrint(out, "{s}://{s}", .{ uri.scheme, host })) catch null;
}

/// What a source is used for, from the plugin manifest's `type`.
pub fn purpose(kind: []const u8) []const u8 {
    const table = [_]struct { []const u8, []const u8 }{
        .{ "torrent", "a torrent index used to search for releases" },
        .{ "anime", "an anime catalogue and episode source" },
        .{ "comics", "a comics and manga source" },
        .{ "novels", "a novels source" },
        .{ "music", "a music source" },
        .{ "podcasts", "a podcast directory" },
        .{ "radio", "a radio station directory" },
        .{ "iptv", "a live TV channel list" },
        .{ "stremio", "a Stremio-style add-on" },
        .{ "suwayomi", "a Suwayomi manga server" },
    };
    for (table) |row| if (std.mem.eql(u8, row[0], kind)) return row[1];
    return "an online media source";
}

fn failureText(f: Failure) []const u8 {
    return switch (f) {
        .transport => "could not connect or the connection broke",
        .timed_out => "timed out",
        .none => "answered with an error status",
        else => "failed",
    };
}

fn safeWord(s: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    for (s) |ch| {
        if (n == out.len) break;
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') {
            out[n] = ch;
            n += 1;
        }
    }
    return out[0..n];
}

pub const Field = struct { name: []const u8, value: []const u8 };

pub const Facts = struct {
    id: []const u8,
    /// Manifest type ("torrent", "anime", ...) or empty when unknown.
    kind: []const u8 = "",
    status: u16 = 0,
    failure: Failure = .none,
    count: u16 = 0,
    span_ms: i64 = 0,
};

/// The context text for the agent. Only `base` is read from `fields`; every other
/// configuration field (keys, tokens, cookies, user names, mirrors) is ignored.
/// `base` is reduced to scheme and host. Null when there is no usable base.
pub fn buildContext(buf: []u8, facts: Facts, fields: []const Field) ?[]const u8 {
    var base_raw: ?[]const u8 = null;
    for (fields) |f| if (std.mem.eql(u8, f.name, "base")) {
        base_raw = f.value;
    };
    var host_buf: [300]u8 = undefined;
    const host = hostOnly(base_raw orelse return null, &host_buf) orelse return null;
    var id_buf: [64]u8 = undefined;
    var kind_buf: [24]u8 = undefined;
    const id = safeWord(facts.id, &id_buf);
    if (id.len == 0) return null;
    const kind = safeWord(facts.kind, &kind_buf);

    var w = std.Io.Writer.fixed(buf);
    w.print("Source id: {s}\n", .{id}) catch return null;
    w.print("Source type: {s}\n", .{if (kind.len > 0) kind else "unknown"}) catch return null;
    w.print("Used for: {s}\n", .{purpose(kind)}) catch return null;
    w.print("Current address (scheme and host only): {s}\n", .{host}) catch return null;
    if (facts.status >= 100) {
        w.print("Last failure: HTTP status {d}\n", .{facts.status}) catch return null;
    } else {
        w.print("Last failure: {s}\n", .{failureText(facts.failure)}) catch return null;
    }
    w.print("Consecutive failures: {d} over about {d} minutes\n", .{ facts.count, @divTrunc(@max(facts.span_ms, 0), 60_000) }) catch return null;
    return w.buffered();
}

// ── Judging a proposal ──────────────────────────────────────────────────

pub const Probe = struct {
    ok: bool,
    status: u16 = 0,
    /// Short phrase shown to the user, e.g. "no answer" or "HTTP 404".
    reason: []const u8 = "",
};

/// Contact `base` (an already validated public http(s) address). Injected so the
/// decision logic is tested without a network.
pub const ProbeFn = *const fn (base: []const u8) Probe;

pub const MIN_CONFIDENCE: f32 = 0.5;

fn sameBase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, a, "/ \t"), std.mem.trimEnd(u8, b, "/ \t"));
}

/// Validate an answer without touching the network: a usable public address,
/// confident enough, and different from the current one.
pub fn validate(allocator: std.mem.Allocator, current_base: []const u8, result_json: []const u8) union(enum) { ok: op.Endpoint, bad: []const u8 } {
    const ep = op.parseEndpoint(allocator, result_json) orelse return .{ .bad = "No usable address in the answer" };
    if (ep.confidence < MIN_CONFIDENCE) return .{ .bad = "The agent was not confident it found the new address" };
    if (sameBase(ep.base(), current_base)) return .{ .bad = "The agent found no address other than the current one" };
    return .{ .ok = ep };
}

fn clip(s: []const u8, max: usize, out: []u8) []const u8 {
    if (s.len <= max) return s;
    const keep = max -| 3;
    @memcpy(out[0..keep], s[0..keep]);
    @memcpy(out[keep..][0..3], "...");
    return out[0..max];
}

/// Decide what to do with the agent's answer. `current_base` is the source's
/// configured base (null when the source has none any more).
pub fn decide(allocator: std.mem.Allocator, current_base: ?[]const u8, result_json: []const u8, probe: ProbeFn) op.Handled {
    const current = current_base orelse return op.Handled.make(.failed, "The source has no base address configured", .{});
    const ep = switch (validate(allocator, current, result_json)) {
        .ok => |e| e,
        .bad => |why| return op.Handled.make(.failed, "{s}", .{why}),
    };
    var old_buf: [300]u8 = undefined;
    var old_clip: [64]u8 = undefined;
    var new_clip: [96]u8 = undefined;
    const old_full = hostOnly(current, &old_buf) orelse current;
    const old_text = clip(stripScheme(old_full), 40, &old_clip);
    const new_text = clip(ep.base(), 70, &new_clip);

    const p = probe(ep.base());
    if (!p.ok) {
        var reason_clip: [48]u8 = undefined;
        return op.Handled.make(.failed, "{s} did not answer a check ({s})", .{ new_text, clip(if (p.reason.len > 0) p.reason else "no answer", 40, &reason_clip) });
    }
    return op.Handled.make(.proposed, "{s} may have moved to {s} (checked: reachable)", .{ old_text, new_text });
}

fn stripScheme(url: []const u8) []const u8 {
    const i = std.mem.indexOf(u8, url, "://") orelse return url;
    return url[i + 3 ..];
}

// ── Probe response policy ───────────────────────────────────────────────

/// A redirect is only acceptable when it does not lead to a private host. The
/// probe never follows redirects itself; this inspects where one points.
pub fn redirectAllowed(headers: []const u8) bool {
    var lines = std.mem.splitScalar(u8, headers, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len < 9 or !std.ascii.eqlIgnoreCase(line[0..9], "location:")) continue;
        const value = std.mem.trim(u8, line[9..], " \t");
        if (!std.ascii.startsWithIgnoreCase(value, "http://") and !std.ascii.startsWithIgnoreCase(value, "https://")) return true; // relative or scheme-less stays on the same host
        const uri = std.Uri.parse(value) catch return false;
        const host_comp = uri.host orelse return false;
        var host_buf: [256]u8 = undefined;
        const host = host_comp.toRaw(&host_buf) catch return false;
        if (!op.publicHost(host)) return false;
    }
    return true;
}

/// Turn the facts of one probe request into a verdict.
pub fn judgeProbe(failure_ok_or_truncated: bool, status: u16, headers: []const u8) Probe {
    if (!failure_ok_or_truncated or status == 0) return .{ .ok = false, .reason = "no connection" };
    if (status < 200 or status >= 400) return .{ .ok = false, .status = status, .reason = "HTTP error status" };
    if (status >= 300 and !redirectAllowed(headers)) return .{ .ok = false, .status = status, .reason = "redirects to a private address" };
    return .{ .ok = true, .status = status };
}

// ── Config merge ────────────────────────────────────────────────────────

/// Return `json_obj` (a JSON object) with `field` set to the string `value`.
/// Every other key keeps its value and position, whatever its type, so
/// credentials (sealed or plain), arrays and unknown keys pass through
/// untouched. Null when it is not an object, or when `require_existing` and the
/// field is not there. Caller frees the result.
pub fn setStringField(allocator: std.mem.Allocator, json_obj: []const u8, field: []const u8, value: []const u8, require_existing: bool) ?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_obj, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const existing = parsed.value.object.getPtr(field);
    if (existing) |slot| {
        slot.* = .{ .string = value };
    } else {
        if (require_existing) return null;
        const arena = parsed.arena.allocator();
        const key = arena.dupe(u8, field) catch return null;
        parsed.value.object.put(arena, key, .{ .string = value }) catch return null;
    }
    return std.json.Stringify.valueAlloc(allocator, parsed.value, .{}) catch null;
}

// ── Tests ───────────────────────────────────────────────────────────────

const T = std.testing;

test "classify counts address-looking failures only" {
    try T.expectEqual(Outcome.failure, classify(.transport, 0));
    try T.expectEqual(Outcome.failure, classify(.timed_out, 0));
    try T.expectEqual(Outcome.failure, classify(.none, 404));
    try T.expectEqual(Outcome.failure, classify(.none, 503));
    try T.expectEqual(Outcome.failure, classify(.none, 403));
    try T.expectEqual(Outcome.success, classify(.none, 200));
    try T.expectEqual(Outcome.success, classify(.none, 302));
    try T.expectEqual(Outcome.ignore, classify(.cancelled, 0));
    try T.expectEqual(Outcome.ignore, classify(.invalid_input, 0));
    try T.expectEqual(Outcome.ignore, classify(.spawn, 0));
    try T.expectEqual(Outcome.ignore, classify(.truncated, 200));
    try T.expectEqual(Outcome.ignore, classify(.malformed_response, 200));
    try T.expectEqual(Outcome.ignore, classify(.none, 429));
    try T.expectEqual(Outcome.ignore, classify(.none, 401));
}

test "five spaced HTTP failures ask once and reset" {
    var s = Streak{};
    var asked: u32 = 0;
    var t: i64 = 1000;
    for (0..4) |_| {
        if (asks(&s, .failure, .none, 404, t, 0)) asked += 1;
        t += 60_000;
    }
    try T.expectEqual(@as(u32, 0), asked);
    try T.expect(asks(&s, .failure, .none, 404, t, 0));
    try T.expectEqual(@as(u16, 0), s.count);
    try T.expect(!asks(&s, .failure, .none, 404, t + 1, 0)); // fresh streak
}

test "a burst inside one search does not count as a streak" {
    var s = Streak{};
    for (0..20) |i| try T.expect(!asks(&s, .failure, .none, 503, 5000 + @as(i64, @intCast(i)), 0));
    // Still failing two minutes later: now it asks.
    try T.expect(asks(&s, .failure, .none, 503, 5000 + MIN_SPAN_MS, 0));
}

test "a success, but not a cancellation, resets the streak" {
    var s = Streak{};
    for (0..4) |i| _ = asks(&s, .failure, .none, 404, @as(i64, @intCast(i)) * 60_000, 0);
    try T.expect(!asks(&s, .ignore, .cancelled, 0, 300_000, 0));
    try T.expectEqual(@as(u16, 4), s.count);
    _ = asks(&s, .success, .none, 200, 310_000, 0);
    try T.expectEqual(@as(u16, 0), s.count);
}

test "connect failures while offline everywhere never ask, but do once another source works" {
    var s = Streak{};
    var asked = false;
    for (0..8) |i| {
        if (asks(&s, .failure, .transport, 0, 1_000 + @as(i64, @intCast(i)) * 60_000, 0)) asked = true;
    }
    try T.expect(!asked);
    // Another source succeeded after the streak began.
    try T.expect(asks(&s, .failure, .transport, 0, 600_000, 590_000));
}

test "hostOnly drops credentials, path, query and fragment" {
    var buf: [128]u8 = undefined;
    try T.expectEqualStrings("https://idx.example.org", hostOnly("https://user:pw@idx.example.org/api/v1?apikey=abc#x", &buf).?);
    try T.expectEqualStrings("http://idx.example.org:8080", hostOnly("http://idx.example.org:8080/a", &buf).?);
    try T.expect(hostOnly("ftp://idx.example.org", &buf) == null);
    try T.expect(hostOnly("not a url", &buf) == null);
    try T.expect(hostOnly("", &buf) == null);
}

test "the context built from a config with secrets does not contain them" {
    const fields = [_]Field{
        .{ .name = "base", .value = "https://user:hunter2@bxx.example/search?apikey=SEKRET-KEY&token=TOK#frag" },
        .{ .name = "api", .value = "API-VALUE-123" },
        .{ .name = "apikey", .value = "SEKRET-KEY-2" },
        .{ .name = "token", .value = "TOK-456" },
        .{ .name = "user", .value = "alice-the-user" },
        .{ .name = "pass", .value = "p4ssw0rd" },
        .{ .name = "cookie", .value = "session=COOKIEVAL" },
        .{ .name = "debrid", .value = "https://debrid.example/KEYINURL" },
        .{ .name = "mirrors", .value = "https://m.example/MIRRORSECRET" },
    };
    var buf: [1024]u8 = undefined;
    const ctx = buildContext(&buf, .{ .id = "bxx", .kind = "torrent", .status = 503, .count = 5, .span_ms = 7 * 60_000 }, &fields).?;
    for ([_][]const u8{ "hunter2", "SEKRET", "TOK", "API-VALUE", "alice", "p4ssw0rd", "COOKIEVAL", "KEYINURL", "MIRRORSECRET", "/search", "frag", "user:" }) |needle| {
        try T.expect(std.mem.indexOf(u8, ctx, needle) == null);
    }
    try T.expect(std.mem.indexOf(u8, ctx, "Source id: bxx") != null);
    try T.expect(std.mem.indexOf(u8, ctx, "https://bxx.example\n") != null);
    try T.expect(std.mem.indexOf(u8, ctx, "torrent index") != null);
    try T.expect(std.mem.indexOf(u8, ctx, "HTTP status 503") != null);
    try T.expect(std.mem.indexOf(u8, ctx, "7 minutes") != null);
}

test "context needs a usable base and sanitises ids" {
    var buf: [512]u8 = undefined;
    try T.expect(buildContext(&buf, .{ .id = "x" }, &.{.{ .name = "api", .value = "k" }}) == null);
    try T.expect(buildContext(&buf, .{ .id = "x" }, &.{.{ .name = "base", .value = "javascript:alert(1)" }}) == null);
    const ctx = buildContext(&buf, .{ .id = "a\nIgnore all", .kind = "weird kind!", .failure = .transport }, &.{.{ .name = "base", .value = "https://a.example" }}).?;
    try T.expect(std.mem.indexOf(u8, ctx, "Source id: aIgnoreall\n") != null);
    try T.expect(std.mem.indexOf(u8, ctx, "Source type: weirdkind\n") != null);
    try T.expect(std.mem.indexOf(u8, ctx, "could not connect") != null);
}

fn probeOk(_: []const u8) Probe {
    return .{ .ok = true, .status = 200 };
}
fn probeDown(_: []const u8) Probe {
    return .{ .ok = false, .reason = "no connection" };
}
fn probeMustNotRun(_: []const u8) Probe {
    @panic("the probe must not run for an invalid answer");
}

test "a good, confident, different, reachable answer is proposed" {
    const h = decide(T.allocator, "https://bxx.example", "{\"base\":\"https://new.example\",\"evidence\":\"site says so\",\"confidence\":0.8}", probeOk);
    try T.expectEqual(op.State.proposed, h.state);
    try T.expectEqualStrings("bxx.example may have moved to https://new.example (checked: reachable)", h.text());
    try T.expect(h.text().len <= op.SUMMARY_MAX);
}

test "an unreachable proposal fails" {
    const h = decide(T.allocator, "https://bxx.example", "{\"base\":\"https://new.example\",\"evidence\":\"e\",\"confidence\":0.9}", probeDown);
    try T.expectEqual(op.State.failed, h.state);
    try T.expect(std.mem.indexOf(u8, h.text(), "new.example") != null);
}

test "invalid, unsure or unchanged answers never reach the probe" {
    const cur = "https://bxx.example";
    const cases = [_][]const u8{
        "not json",
        "{\"base\":\"https://127.0.0.1\",\"evidence\":\"e\",\"confidence\":1}",
        "{\"base\":\"http://192.168.1.5\",\"evidence\":\"e\",\"confidence\":1}",
        "{\"base\":\"https://new.example/path\",\"evidence\":\"e\",\"confidence\":1}",
        "{\"base\":\"https://new.example\",\"evidence\":\"e\",\"confidence\":0.49}",
        "{\"base\":\"https://new.example\",\"evidence\":\"e\"}",
        "{\"base\":\"https://BXX.example/\",\"evidence\":\"e\",\"confidence\":1}",
    };
    for (cases) |c| try T.expectEqual(op.State.failed, decide(T.allocator, cur, c, probeMustNotRun).state);
    // Source without a base.
    try T.expectEqual(op.State.failed, decide(T.allocator, null, cases[4], probeMustNotRun).state);
}

test "a long address still yields a summary within the limit" {
    var json_buf: [400]u8 = undefined;
    const long_host = "a" ++ "bcdefghij" ** 18 ++ ".example.org";
    const json = std.fmt.bufPrint(&json_buf, "{{\"base\":\"https://{s}\",\"evidence\":\"e\",\"confidence\":1}}", .{long_host}) catch unreachable;
    const h = decide(T.allocator, "https://" ++ "x" ** 120 ++ ".example", json, probeOk);
    try T.expectEqual(op.State.proposed, h.state);
    try T.expect(h.text().len > 0 and h.text().len <= op.SUMMARY_MAX);
    try T.expect(std.mem.endsWith(u8, h.text(), "(checked: reachable)"));
}

test "probe policy: status range and redirect targets" {
    try T.expect(judgeProbe(true, 200, "").ok);
    try T.expect(judgeProbe(true, 301, "HTTP/1.1 301\r\nLocation: https://other.example/x\r\n").ok);
    try T.expect(judgeProbe(true, 302, "HTTP/1.1 302\r\nlocation: /login\r\n").ok);
    try T.expect(!judgeProbe(true, 302, "HTTP/1.1 302\r\nLocation: http://127.0.0.1:8080/\r\n").ok);
    try T.expect(!judgeProbe(true, 302, "HTTP/1.1 302\r\nLocation: http://192.168.0.1/\r\n").ok);
    try T.expect(!judgeProbe(true, 404, "").ok);
    try T.expect(!judgeProbe(true, 500, "").ok);
    try T.expect(!judgeProbe(true, 0, "").ok);
    try T.expect(!judgeProbe(false, 200, "").ok);
}

test "merging a field keeps every other field and escapes correctly" {
    const src =
        \\{"base":"https://old.example","apikey":"s3cret","user":"bob \"b\"","mirrors":["https://m1.example","https://m2.example"],"n":3,"extra":"line\nbreak"}
    ;
    const out = setStringField(T.allocator, src, "base", "https://new.example", true).?;
    defer T.allocator.free(out);
    var parsed = try std.json.parseFromSlice(std.json.Value, T.allocator, out, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try T.expectEqualStrings("https://new.example", o.get("base").?.string);
    try T.expectEqualStrings("s3cret", o.get("apikey").?.string);
    try T.expectEqualStrings("bob \"b\"", o.get("user").?.string);
    try T.expectEqual(@as(usize, 2), o.get("mirrors").?.array.items.len);
    try T.expectEqual(@as(i64, 3), o.get("n").?.integer);
    try T.expectEqualStrings("line\nbreak", o.get("extra").?.string);
    try T.expectEqual(@as(usize, 6), o.count());
    // Order is preserved: base is still first.
    try T.expect(std.mem.startsWith(u8, out, "{\"base\":\"https://new.example\""));
}

test "merging escapes a hostile value and honours require_existing" {
    const out = setStringField(T.allocator, "{\"base\":\"a\"}", "base", "x\",\"apikey\":\"evil", true).?;
    defer T.allocator.free(out);
    var parsed = try std.json.parseFromSlice(std.json.Value, T.allocator, out, .{});
    defer parsed.deinit();
    try T.expectEqual(@as(usize, 1), parsed.value.object.count());
    try T.expectEqualStrings("x\",\"apikey\":\"evil", parsed.value.object.get("base").?.string);

    try T.expect(setStringField(T.allocator, "{\"api\":\"k\"}", "base", "https://n.example", true) == null);
    const added = setStringField(T.allocator, "{\"api\":\"k\"}", "base", "https://n.example", false).?;
    defer T.allocator.free(added);
    try T.expect(std.mem.indexOf(u8, added, "\"api\":\"k\"") != null);
    try T.expect(setStringField(T.allocator, "[1]", "base", "x", false) == null);
    try T.expect(setStringField(T.allocator, "nope", "base", "x", false) == null);
}
