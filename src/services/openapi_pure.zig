//! OpenAPI 3.1 description of the agent-facing HTTP API, generated from the
//! operation registry so the spec, the MCP tools and the docs cannot drift.
//!
//! `docs/openapi.json` is this output; a test fails when the committed file is
//! stale (regenerate with `opal-mcp --openapi > docs/openapi.json`).
//!
//! Several registry operations share one route and differ only in a fixed
//! `action=` query value (for example `/library/action`). OpenAPI cannot hold
//! two operations on one path and method, so those keep the fixed pairs in the
//! path key (`/library/action?action=status`), a convention most tooling
//! tolerates; the pairs are also listed under `x-opal-fixed`. When an operation
//! still collides (`search` and `search_results` read one route, with and
//! without `q`), the later one gets `#<operationId>` appended; the fragment is
//! never sent to the server.

const std = @import("std");
const ops = @import("ops_pure.zig");

fn isFixedConfirm(f: ops.Fixed) bool {
    return std.mem.eql(u8, f.key, "confirm");
}

fn writePathKey(w: *std.Io.Writer, op: *const ops.Op) !void {
    try w.writeAll(op.path);
    var first = true;
    for (op.fixed) |f| {
        if (isFixedConfirm(f)) continue;
        try w.writeAll(if (first) "?" else "&");
        first = false;
        try w.print("{s}={s}", .{ f.key, f.value });
    }
}

fn writeParam(s: *std.json.Stringify, p: ops.Param) !void {
    try s.beginObject();
    try s.objectField("name");
    try s.write(p.key());
    try s.objectField("in");
    try s.write("query");
    try s.objectField("required");
    try s.write(p.required);
    try s.objectField("description");
    try s.write(p.desc);
    try s.objectField("schema");
    try s.beginObject();
    switch (p.kind) {
        .boolean => {
            // The registry sends 1/0; the API also accepts true/false on most routes.
            try s.objectField("type");
            try s.write("string");
            try s.objectField("enum");
            try s.write([_][]const u8{ "1", "0" });
        },
        else => {
            try s.objectField("type");
            try s.write(ops.kindName(p.kind));
            if (p.kind == .choice) {
                try s.objectField("enum");
                try s.write(p.choices);
            }
            if (p.kind == .integer or p.kind == .number) {
                if (std.math.isFinite(p.min)) {
                    try s.objectField("minimum");
                    try ops.writeBoundNumber(s, p.min);
                }
                if (std.math.isFinite(p.max)) {
                    try s.objectField("maximum");
                    try ops.writeBoundNumber(s, p.max);
                }
            }
            if (p.kind == .string) {
                try s.objectField("maxLength");
                try s.write(p.max_len);
            }
        },
    }
    try s.endObject();
    try s.endObject();
}

fn writeOperation(s: *std.json.Stringify, op: *const ops.Op) !void {
    try s.beginObject();
    try s.objectField("operationId");
    try s.write(op.name);
    try s.objectField("summary");
    try s.write(op.summary);
    try s.objectField("tags");
    try s.write([_][]const u8{op.tier.id()});
    try s.objectField("x-opal-tier");
    try s.write(op.tier.id());
    if (op.fixed.len > 0) {
        try s.objectField("x-opal-fixed");
        try s.beginObject();
        for (op.fixed) |f| {
            try s.objectField(f.key);
            try s.write(f.value);
        }
        try s.endObject();
    }
    try s.objectField("parameters");
    try s.beginArray();
    for (op.params) |p| try writeParam(s, p);
    try s.endArray();
    try s.objectField("responses");
    try s.beginObject();
    try s.objectField("200");
    try s.beginObject();
    try s.objectField("description");
    try s.write("JSON result");
    try s.endObject();
    try s.objectField("401");
    try s.beginObject();
    try s.objectField("description");
    try s.write("Missing or wrong bearer token");
    try s.endObject();
    try s.endObject();
    try s.endObject();
}

/// The whole document, pretty-printed with a trailing newline.
pub fn write(allocator: std.mem.Allocator, w: *std.Io.Writer) !void {
    var s = std.json.Stringify{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("openapi");
    try s.write("3.1.0");
    try s.objectField("info");
    try s.beginObject();
    try s.objectField("title");
    try s.write("Opal local API (agent surface)");
    try s.objectField("version");
    try s.write("1");
    try s.objectField("description");
    try s.write("The operations Opal exposes to coding agents. Generated from the operation registry; each operation is also an MCP tool in opal-mcp. Every route is under /api on the loopback port and needs the bearer token in <config>/opal/api.token.");
    try s.endObject();
    try s.objectField("servers");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("url");
    try s.write("http://127.0.0.1:41595/api");
    try s.endObject();
    try s.endArray();
    try s.objectField("security");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("bearer");
    try s.beginArray();
    try s.endArray();
    try s.endObject();
    try s.endArray();
    try s.objectField("components");
    try s.beginObject();
    try s.objectField("securitySchemes");
    try s.beginObject();
    try s.objectField("bearer");
    try s.beginObject();
    try s.objectField("type");
    try s.write("http");
    try s.objectField("scheme");
    try s.write("bearer");
    try s.endObject();
    try s.endObject();
    try s.endObject();

    // Group operations by path key, keeping registry order, one method each.
    var keys: std.ArrayList([]u8) = .empty;
    defer {
        for (keys.items) |k| allocator.free(k);
        keys.deinit(allocator);
    }
    for (&ops.ops, 0..) |*op, i| {
        var buf: std.Io.Writer.Allocating = .init(allocator);
        defer buf.deinit();
        try writePathKey(&buf.writer, op);
        for (ops.ops[0..i], keys.items) |*earlier, earlier_key| {
            if (earlier.method == op.method and std.mem.eql(u8, earlier_key, buf.written())) {
                try buf.writer.print("#{s}", .{op.name});
                break;
            }
        }
        try keys.append(allocator, try allocator.dupe(u8, buf.written()));
    }
    try s.objectField("paths");
    try s.beginObject();
    for (keys.items, 0..) |key, i| {
        for (keys.items[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier, key)) break;
        } else {
            try s.objectField(key);
            try s.beginObject();
            var used = [_]bool{ false, false };
            for (&ops.ops, keys.items) |*op, other_key| {
                if (!std.mem.eql(u8, other_key, key)) continue;
                const slot: usize = if (op.method == .GET) 0 else 1;
                // Two operations on one path key and method would overwrite each other.
                if (used[slot]) return error.DuplicateOperation;
                used[slot] = true;
                try s.objectField(if (op.method == .GET) "get" else "post");
                try writeOperation(&s, op);
            }
            try s.endObject();
        }
    }
    try s.endObject();
    try s.endObject();
    try w.writeAll("\n");
}

test "every operation appears exactly once with its tier and parameters" {
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try write(a, &out.writer);

    var parsed = try std.json.parseFromSlice(std.json.Value, a, out.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("3.1.0", root.get("openapi").?.string);

    var seen: usize = 0;
    var it = root.get("paths").?.object.iterator();
    while (it.next()) |entry| {
        var methods = entry.value_ptr.object.iterator();
        while (methods.next()) |m| {
            seen += 1;
            const op = m.value_ptr.object;
            try std.testing.expect(ops.findOp(op.get("operationId").?.string) != null);
        }
    }
    try std.testing.expectEqual(ops.ops.len, seen);

    const info = ops.findOp("library_mark_watched").?;
    const node = root.get("paths").?.object.get("/library/action?action=watched").?.object.get("post").?.object;
    try std.testing.expectEqualStrings("write", node.get("x-opal-tier").?.string);
    try std.testing.expectEqual(info.params.len, node.get("parameters").?.array.items.len);
    // The wire name, not the agent-facing name.
    const last = node.get("parameters").?.array.items[info.params.len - 1].object;
    try std.testing.expectEqualStrings("value", last.get("name").?.string);
}

test "destructive operations do not leak confirm into the path key" {
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try write(a, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "confirm=") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "/queue/action?action=clear") != null);
}

test "the committed docs/openapi.json is current" {
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try write(a, &out.writer);
    const committed = @embedFile("openapi_json");
    try std.testing.expectEqualStrings(committed, out.written());
}
