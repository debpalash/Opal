//! Recall embedding client. Talks to the local OpenAI-compatible embeddings
//! endpoint (the llama-server ai_server.zig starts with `--embedding` on
//! :41593 where available). The dimension is whatever the model returns —
//! recall_index records it and rebuilds its vector tables when it changes.
//!
//! Degrades silently: when the endpoint does not answer, callers get `null`
//! and recall runs on FTS alone. A failure parks the endpoint for a minute so
//! a dead server does not add a timeout to every search.
//!
//! OPAL_EMBED_URL overrides the endpoint (tests point it at a fixture).

const std = @import("std");
const io = @import("../core/io_global.zig");
const reliable_fetch = @import("reliable_fetch.zig");
const alloc = @import("../core/alloc.zig").allocator;

pub const DEFAULT_URL = "http://127.0.0.1:41593/v1/embeddings";
pub const MAX_DIM: usize = 4096;
pub const MAX_BATCH: usize = 16;
const PARK_MS: i64 = 60_000;
const RESPONSE_CAP: usize = 1024 * 1024;

var parked_until_ms = std.atomic.Value(i64).init(0);

pub fn url() []const u8 {
    const override = io.getenv("OPAL_EMBED_URL") orelse return DEFAULT_URL;
    // Loopback only: embeddings carry the user's library and subtitle text.
    if (std.mem.startsWith(u8, override, "http://127.0.0.1:") or std.mem.startsWith(u8, override, "http://localhost:")) return override;
    return DEFAULT_URL;
}

/// True when the endpoint is not parked after a recent failure.
pub fn available() bool {
    return io.milliTimestamp() >= parked_until_ms.load(.acquire);
}

fn park() void {
    parked_until_ms.store(io.milliTimestamp() + PARK_MS, .release);
}

/// Embed up to MAX_BATCH texts. On success writes `texts.len * dim` floats to
/// `out` (row-major) and returns `dim`. Null on any failure (endpoint down,
/// malformed response, inconsistent dimensions, `out` too small).
pub fn embedBatch(texts: []const []const u8, out: []f32, timeout_secs: u32) ?usize {
    if (texts.len == 0 or texts.len > MAX_BATCH or !available()) return null;
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    body.writer.writeAll("{\"input\":") catch return null;
    std.json.Stringify.value(texts, .{}, &body.writer) catch return null;
    body.writer.writeAll("}") catch return null;

    const response = alloc.alloc(u8, RESPONSE_CAP) catch return null;
    defer alloc.free(response);
    var headers: [4096]u8 = undefined;
    const result = reliable_fetch.request(url(), response, &headers, .{
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        // Library and subtitle text: stdin, never argv.
        .secret_post_body = body.written(),
        .impersonate = false,
        .use_dpi_proxy = false,
        .follow_redirects = false,
        .timeout_secs = timeout_secs,
        .connect_timeout_secs = 2,
    });
    if (!result.ok()) {
        if (result.failure != .cancelled) park();
        return null;
    }
    const dim = parse(result.body, texts.len, out) orelse {
        park();
        return null;
    };
    return dim;
}

pub fn embedOne(text: []const u8, out: []f32, timeout_secs: u32) ?usize {
    return embedBatch(&.{text}, out, timeout_secs);
}

/// OpenAI shape: {"data":[{"embedding":[...],"index":i},...]}. llama.cpp's
/// native shape ([{"embedding":[[...]]}]) is accepted too.
fn parse(body: []const u8, expected: usize, out: []f32) ?usize {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return null;
    defer parsed.deinit();
    const rows = switch (parsed.value) {
        .object => |o| (o.get("data") orelse return null),
        .array => parsed.value,
        else => return null,
    };
    if (rows != .array or rows.array.items.len != expected) return null;
    var dim: usize = 0;
    for (rows.array.items, 0..) |row, i| {
        if (row != .object) return null;
        const at = if (row.object.get("index")) |v| (if (v == .integer and v.integer >= 0) @as(usize, @intCast(v.integer)) else i) else i;
        if (at >= expected) return null;
        var vec = row.object.get("embedding") orelse return null;
        if (vec == .array and vec.array.items.len == 1 and vec.array.items[0] == .array) vec = vec.array.items[0];
        if (vec != .array) return null;
        const n = vec.array.items.len;
        if (n == 0 or n > MAX_DIM) return null;
        if (dim == 0) dim = n else if (dim != n) return null;
        if ((at + 1) * dim > out.len) return null;
        for (vec.array.items, 0..) |v, k| {
            out[at * dim + k] = switch (v) {
                .float => @floatCast(v.float),
                .integer => @floatFromInt(v.integer),
                else => return null,
            };
        }
    }
    return if (dim == 0) null else dim;
}
