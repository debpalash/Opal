//! One-shot (non-streaming) OpenAI-compatible chat completion — the pure
//! request-body builder and response decoder shared by subtitle translation
//! and episode recaps.
const std = @import("std");

pub const Request = struct {
    model: []const u8,
    system: []const u8,
    user: []const u8,
    max_tokens: u32 = 512,
    temperature: f32 = 0.2,
};

/// Serialize the chat-completions body. Strings are JSON-escaped by std.
pub fn writeBody(w: *std.Io.Writer, r: Request) !void {
    try w.writeAll("{\"model\":");
    try std.json.Stringify.encodeJsonString(r.model, .{}, w);
    try w.writeAll(",\"messages\":[{\"role\":\"system\",\"content\":");
    try std.json.Stringify.encodeJsonString(r.system, .{}, w);
    try w.writeAll("},{\"role\":\"user\",\"content\":");
    try std.json.Stringify.encodeJsonString(r.user, .{}, w);
    try w.print("}}],\"max_tokens\":{d},\"temperature\":{d:.2},\"stream\":false}}", .{ r.max_tokens, r.temperature });
}

pub const DecodeError = error{ InvalidResponse, EmptyContent, OutOfMemory };

/// Extract choices[0].message.content (owned by `alloc`). Reasoning models'
/// leading "<think>…</think>" block is stripped.
pub fn decodeContent(alloc: std.mem.Allocator, body: []const u8) DecodeError![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidResponse,
    };
    const choices = switch (root.get("choices") orelse return error.InvalidResponse) {
        .array => |a| a,
        else => return error.InvalidResponse,
    };
    if (choices.items.len == 0) return error.InvalidResponse;
    const first = switch (choices.items[0]) {
        .object => |o| o,
        else => return error.InvalidResponse,
    };
    const message = switch (first.get("message") orelse return error.InvalidResponse) {
        .object => |o| o,
        else => return error.InvalidResponse,
    };
    const content = switch (message.get("content") orelse return error.EmptyContent) {
        .string => |s| s,
        else => return error.EmptyContent,
    };
    const cleaned = std.mem.trim(u8, stripThink(content), " \t\r\n");
    if (cleaned.len == 0) return error.EmptyContent;
    return alloc.dupe(u8, cleaned);
}

pub fn stripThink(s: []const u8) []const u8 {
    const t = std.mem.trimStart(u8, s, " \t\r\n");
    if (!std.mem.startsWith(u8, t, "<think>")) return s;
    const close = std.mem.indexOf(u8, t, "</think>") orelse return s;
    return t[close + "</think>".len ..];
}

const testing = std.testing;

test "body escapes prompt text and disables streaming" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeBody(&aw.writer, .{ .model = "m", .system = "sys \"q\"", .user = "line1\nline2", .max_tokens = 64 });
    const out = aw.written();
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const msgs = parsed.value.object.get("messages").?.array;
    try testing.expectEqualStrings("sys \"q\"", msgs.items[0].object.get("content").?.string);
    try testing.expectEqualStrings("line1\nline2", msgs.items[1].object.get("content").?.string);
    try testing.expectEqual(false, parsed.value.object.get("stream").?.bool);
    try testing.expectEqual(@as(i64, 64), parsed.value.object.get("max_tokens").?.integer);
}

test "decode content, strip think block, reject malformed" {
    const ok = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"<think>hmm</think>\\n 1: Hola \"}}]}";
    const got = try decodeContent(testing.allocator, ok);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("1: Hola", got);
    try testing.expectError(error.InvalidResponse, decodeContent(testing.allocator, "<html>502</html>"));
    try testing.expectError(error.InvalidResponse, decodeContent(testing.allocator, "{\"choices\":[]}"));
    try testing.expectError(error.EmptyContent, decodeContent(testing.allocator, "{\"choices\":[{\"message\":{\"content\":\"  \"}}]}"));
    try testing.expectError(error.EmptyContent, decodeContent(testing.allocator, "{\"choices\":[{\"message\":{\"content\":null}}]}"));
}
