//! Mirror failover for installed sources.
//!
//! A source that supplies `mirrors` alongside `base` gets ordered failover: try
//! the base, and on a connection failure / non-2xx / challenge page try the next
//! host. The host that answered is remembered for the rest of the session and
//! tried first next time — that is the whole health model. There is deliberately
//! NO background prober: probing costs a request per host per source on every
//! launch, and the search itself is a perfectly good probe.
//!
//! Selection, rotation and block detection live in the tested
//! `mirrors_pure.zig`; this file only adds the config lookup, the last-good
//! table and the fetch loop.

const std = @import("std");
const http = @import("http.zig");
const logs = @import("logs.zig");
const source_config = @import("source_config.zig");
const pure = @import("mirrors_pure.zig");

/// Last-good host index per source id, for this process only.
const Slot = struct {
    id: [32]u8 = std.mem.zeroes([32]u8),
    id_len: usize = 0,
    idx: usize = 0,
};
var slots: [32]Slot = [_]Slot{.{}} ** 32;
var slot_count: usize = 0;
var mutex: @import("sync.zig").Mutex = .{};

fn lastGood(id: []const u8) usize {
    mutex.lock();
    defer mutex.unlock();
    for (slots[0..slot_count]) |*s| {
        if (std.mem.eql(u8, s.id[0..s.id_len], id)) return s.idx;
    }
    return 0;
}

fn markGood(id: []const u8, idx: usize) void {
    if (id.len == 0 or id.len > 32) return;
    mutex.lock();
    defer mutex.unlock();
    for (slots[0..slot_count]) |*s| {
        if (std.mem.eql(u8, s.id[0..s.id_len], id)) {
            s.idx = idx;
            return;
        }
    }
    if (slot_count >= slots.len) return;
    var s = &slots[slot_count];
    @memcpy(s.id[0..id.len], id);
    s.id_len = id.len;
    s.idx = idx;
    slot_count += 1;
}

/// Copy `<id>.base` and `<id>.mirrors` out of the source table into caller
/// storage (the table's slices are invalidated by the next `reload()`), then
/// resolve them to an ordered candidate list. Returns the count; `out` slices
/// point into `store`. 0 = source not installed → caller stays inert.
pub fn candidatesFor(id: []const u8, store: []u8, out: [][]const u8) usize {
    const base = source_config.get(id, "base") orelse "";
    const spec = source_config.get(id, "mirrors") orelse "";
    if (base.len + spec.len + 1 > store.len) return 0;
    @memcpy(store[0..base.len], base);
    @memcpy(store[base.len..][0..spec.len], spec);
    return pure.candidates(store[0..base.len], store[base.len..][0..spec.len], out);
}

/// Fetch from `id`'s hosts in failover order. `buildUrl` turns one host origin
/// into the full request URL (it gets a scratch buffer to format into and
/// returns null to skip that host). Returns the first body that is neither a
/// failure nor a challenge page, or null when every host failed.
pub fn fetch(
    id: []const u8,
    buf: []u8,
    opts: http.HttpOptions,
    ctx: anytype,
    comptime buildUrl: fn (@TypeOf(ctx), base: []const u8, url_buf: []u8) ?[]const u8,
) ?[]const u8 {
    var store: [1024]u8 = undefined;
    var hosts: [pure.MAX_CANDIDATES][]const u8 = undefined;
    const n = candidatesFor(id, &store, &hosts);
    if (n == 0) return null;

    const start = lastGood(id);
    var attempt: usize = 0;
    while (attempt < n) : (attempt += 1) {
        const i = pure.attemptIndex(n, start, attempt);
        var url_buf: [1024]u8 = undefined;
        const url = buildUrl(ctx, hosts[i], &url_buf) orelse continue;
        const body = http.fetch(url, buf, opts);
        if (!pure.shouldFailover(body)) {
            markGood(id, i);
            return body;
        }
        if (n > 1 and attempt + 1 < n) {
            var lb: [160]u8 = undefined;
            logs.pushLog("warn", "sources", std.fmt.bufPrint(
                &lb,
                "{s}: {s} unreachable — trying the next mirror",
                .{ id, hosts[i] },
            ) catch "source host unreachable — trying the next mirror", false);
        }
    }
    return null;
}
