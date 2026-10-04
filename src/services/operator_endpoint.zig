//! endpoint_repair: a source stopped answering, the agent found where it lives
//! now. The answer is only ever PROPOSED; the user approves it before any
//! configuration changes.
//!
//! Flow: source_request counts consecutive failures per source and calls
//! `requestRepair` once a streak is long enough. The agent answers with a new
//! base address; `handle` validates it, probes it (a bounded GET with no
//! credentials and no redirects followed) and stores a proposal. `approve`,
//! reached only from a human decision (the UI or POST /api/operator/approve),
//! writes the address into the source configuration and keeps every other field.
//! The decision logic is in operator_endpoint_pure.zig and unit tested there.

const std = @import("std");
const alloc = @import("../core/alloc.zig").allocator;
const io = @import("../core/io_global.zig");
const logs = @import("../core/logs.zig");
const state = @import("../core/state.zig");
const source_config = @import("../core/source_config.zig");
const source_config_pure = @import("../core/source_config_pure.zig");
const fetch = @import("reliable_fetch.zig");
const plugin_repo = @import("plugin_repo.zig");
const operator = @import("operator.zig");
const pure = @import("operator_pure.zig");
const ep = @import("operator_endpoint_pure.zig");

// ── Trigger ─────────────────────────────────────────────────────────────

/// The manifest `type` of an installed source ("torrent", "anime", ...), copied
/// into `out`; empty when the catalog does not know the id.
fn sourceKind(id: []const u8, out: []u8) []const u8 {
    const list = alloc.alloc(plugin_repo.Plugin, plugin_repo.MAX) catch return "";
    defer alloc.free(list);
    const n = plugin_repo.snapshotCopy(list);
    for (list[0..n]) |*p| {
        if (!std.mem.eql(u8, p.idSlice(), id)) continue;
        const kind = p.kindSlice();
        const len = @min(kind.len, out.len);
        @memcpy(out[0..len], kind[0..len]);
        return out[0..len];
    }
    return "";
}

/// `id` keeps failing at `base`: ask the operator where it lives now. Does
/// nothing unless the operator is on and the user has this source installed.
/// Only the scheme and host of `base` and a few failure facts are put in the
/// context; no other configuration field is ever read here.
pub fn requestRepair(id: []const u8, base: []const u8, streak: ep.Streak) void {
    if (!state.app.operator_enabled or state.app.incognito_mode) return;
    if (!source_config_pure.validId(id) or !source_config.has(id)) return;
    var kind_buf: [24]u8 = undefined;
    var ctx_buf: [1024]u8 = undefined;
    const ctx = ep.buildContext(&ctx_buf, .{
        .id = id,
        .kind = sourceKind(id, &kind_buf),
        .status = streak.last_status,
        .failure = streak.last_failure,
        .count = streak.count,
        .span_ms = streak.last_ms - streak.first_ms,
    }, &.{.{ .name = "base", .value = base }}) orelse return;
    switch (operator.request(.endpoint_repair, id, ctx)) {
        .queued => logs.pushLog("info", "operator", "A failing source was handed to the background operator", false),
        else => {},
    }
}

// ── Probe ───────────────────────────────────────────────────────────────

const PROBE_BODY = 512 * 1024;

/// One bounded GET of `base`: short timeout, no credentials, no cookies, no
/// custom headers, redirects NOT followed (a redirect only counts when its target
/// is a public host), response size capped.
fn probeNetwork(base: []const u8) ep.Probe {
    const body = alloc.alloc(u8, PROBE_BODY) catch return .{ .ok = false, .reason = "out of memory" };
    defer alloc.free(body);
    var headers: [8 * 1024]u8 = undefined;
    var url_buf: [260]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/", .{base}) catch return .{ .ok = false, .reason = "address too long" };
    const r = fetch.request(url, body, &headers, .{
        .timeout_secs = 8,
        .follow_redirects = false,
    });
    // A redirect or a big landing page still proves the address answers: the
    // status is what matters, so an empty or oversized body is not a failure.
    const answered = switch (r.failure) {
        .none, .empty, .truncated => true,
        else => false,
    };
    return ep.judgeProbe(answered, r.status, r.headers);
}

// ── Handler ─────────────────────────────────────────────────────────────

/// `key` is the source id. Validate and probe `result_json`, then report
/// `proposed` (waiting for the user) or `failed`.
pub fn handle(key: []const u8, result_json: []const u8) pure.Handled {
    if (!source_config_pure.validId(key)) return pure.Handled.make(.failed, "Bad source id", .{});
    var base_buf: [source_config_pure.MAX_VAL_LEN]u8 = undefined;
    const current = source_config.copyValue(key, "base", &base_buf);
    return ep.decide(alloc, current, result_json, probeNetwork);
}

// ── Approval ────────────────────────────────────────────────────────────

/// The user approved the proposal stored for `key`: write it into the source
/// configuration. False when it could not be applied (the source is gone, the
/// stored answer no longer validates, or the file could not be written).
pub fn approve(key: []const u8, result_json: []const u8) bool {
    if (!source_config_pure.validId(key)) return false;
    // Never trust the stored text: it must still be a usable, confident answer.
    var base_buf: [source_config_pure.MAX_VAL_LEN]u8 = undefined;
    const current = source_config.copyValue(key, "base", &base_buf) orelse return false;
    const answer = switch (ep.validate(alloc, current, result_json)) {
        .ok => |a| a,
        .bad => return false,
    };

    // Merge into the file itself rather than the flattened table: the file keeps
    // list-valued fields (mirrors) and sealed credentials exactly as written, and
    // install() protects any secret that is not sealed yet.
    var dir_buf: [600]u8 = undefined;
    var fp_buf: [700]u8 = undefined;
    const fp = std.fmt.bufPrint(&fp_buf, "{s}/{s}.json", .{ source_config.sourcesDir(&dir_buf), key }) catch return false;
    const body = io.cwdReadFileAlloc(fp, alloc, 64 * 1024) catch return false;
    defer alloc.free(body);
    const merged = ep.setStringField(alloc, body, "base", answer.base(), true) orelse return false;
    defer {
        std.crypto.secureZero(u8, merged);
        alloc.free(merged);
    }
    if (!source_config.install(key, merged)) return false;

    var msg: [200]u8 = undefined;
    var host_buf: [200]u8 = undefined;
    logs.pushLog("info", "operator", std.fmt.bufPrint(&msg, "Source {s} now uses {s}", .{ key, ep.hostOnly(answer.base(), &host_buf) orelse "the new address" }) catch "A source address was updated", false);
    return true;
}
