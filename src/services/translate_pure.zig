//! Subtitle translation — pure batching, prompt format and robust parsing of
//! the model's reply back onto cues. Anything the model gets wrong (missing,
//! extra, merged or renumbered lines, code fences, chatter) degrades to the
//! ORIGINAL cue text for the affected lines, never to a blank subtitle.
const std = @import("std");

pub const Lang = struct { code: []const u8, name: []const u8 };

/// Target languages offered in Settings (ISO 639-1 → English name the model
/// is prompted with).
pub const languages = [_]Lang{
    .{ .code = "en", .name = "English" },    .{ .code = "es", .name = "Spanish" },
    .{ .code = "fr", .name = "French" },     .{ .code = "de", .name = "German" },
    .{ .code = "pt", .name = "Portuguese" }, .{ .code = "it", .name = "Italian" },
    .{ .code = "ru", .name = "Russian" },    .{ .code = "zh", .name = "Chinese (Simplified)" },
    .{ .code = "ja", .name = "Japanese" },   .{ .code = "ko", .name = "Korean" },
    .{ .code = "hi", .name = "Hindi" },      .{ .code = "ar", .name = "Arabic" },
    .{ .code = "tr", .name = "Turkish" },    .{ .code = "nl", .name = "Dutch" },
    .{ .code = "pl", .name = "Polish" },     .{ .code = "id", .name = "Indonesian" },
};

pub fn langName(code: []const u8) ?[]const u8 {
    for (languages) |l| if (std.ascii.eqlIgnoreCase(l.code, code)) return l.name;
    return null;
}

pub const system_prompt =
    "You are a professional subtitle translator. Translate each numbered subtitle line faithfully and naturally, " ++
    "keeping names, tone and brevity. Never merge, split, skip or reorder lines. Output ONLY the translated lines, " ++
    "each as \"N: translation\" with the same number N as its input line. No notes, no explanations.";

/// Cue line breaks travel as " / " so each cue stays on one numbered line.
pub const break_token = " / ";

pub const max_batch_items = 24;
pub const max_batch_chars = 2400;

/// End index (exclusive) of the batch starting at `start`.
pub fn nextBatchEnd(texts: []const []const u8, start: usize) usize {
    var end = start;
    var chars: usize = 0;
    while (end < texts.len and end - start < max_batch_items) : (end += 1) {
        chars += texts[end].len + 6;
        if (end > start and chars > max_batch_chars) break;
    }
    return end;
}

/// User message for one batch.
pub fn writeBatchPrompt(w: *std.Io.Writer, texts: []const []const u8, target_name: []const u8) !void {
    try w.print("Translate these {d} subtitle lines into {s}. Reply with exactly {d} lines, \"N: translation\".\n\n", .{ texts.len, target_name, texts.len });
    for (texts, 0..) |t, i| {
        try w.print("{d}: ", .{i + 1});
        var it = std.mem.splitScalar(u8, std.mem.trim(u8, t, " \r\n"), '\n');
        var first = true;
        while (it.next()) |part| {
            const p = std.mem.trim(u8, part, " \r\t");
            if (p.len == 0) continue;
            if (!first) try w.writeAll(break_token);
            try w.writeAll(p);
            first = false;
        }
        try w.writeByte('\n');
    }
}

/// Parse a leading "N:", "N.", "N)", "N -", "[N]" or "(N)" marker.
fn leadingNumber(line: []const u8) ?struct { n: usize, rest: []const u8 } {
    var s = line;
    var bracket: u8 = 0;
    if (s.len > 0 and (s[0] == '[' or s[0] == '(')) {
        bracket = if (s[0] == '[') ']' else ')';
        s = s[1..];
    }
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i == 0 or i > 5) return null;
    const n = std.fmt.parseInt(usize, s[0..i], 10) catch return null;
    var rest = s[i..];
    if (bracket != 0) {
        if (rest.len == 0 or rest[0] != bracket) return null;
        rest = rest[1..];
    } else {
        if (rest.len == 0) return null;
        switch (rest[0]) {
            ':', '.', ')' => rest = rest[1..],
            ' ' => {
                const r2 = std.mem.trimStart(u8, rest, " ");
                if (r2.len == 0 or !(r2[0] == '-' or r2[0] == ':')) return null;
                rest = r2[1..];
            },
            '-' => rest = rest[1..],
            else => return null,
        }
    }
    if (rest.len > 0 and rest[0] != ' ' and rest[0] != '\t' and bracket == 0) return null;
    return .{ .n = n, .rest = std.mem.trim(u8, rest, " \t") };
}

/// Find an inline " N: " for the next expected number (merged lines).
fn findInlineNumber(text: []const u8, n: usize) ?struct { at: usize, rest_at: usize } {
    var nb: [12]u8 = undefined;
    const needle = std.fmt.bufPrint(&nb, " {d}:", .{n}) catch return null;
    const at = std.mem.indexOf(u8, text, needle) orelse return null;
    return .{ .at = at, .rest_at = at + needle.len };
}

fn stripQuotes(s_in: []const u8) []const u8 {
    var s = std.mem.trim(u8, s_in, " \t");
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') s = s[1 .. s.len - 1];
    return std.mem.trim(u8, s, " \t");
}

/// Map the model reply onto `out` (one slot per input line; slices point into
/// `reply`). Slots the reply doesn't cover stay null. Returns how many were
/// filled.
pub fn parseReply(reply: []const u8, out: []?[]const u8) usize {
    for (out) |*o| o.* = null;
    var filled: usize = 0;
    var plain_lines: usize = 0;
    var lines = std.mem.splitScalar(u8, reply, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "```")) continue;
        // List bullets in front of the number.
        if (line.len > 2 and (line[0] == '-' or line[0] == '*') and line[1] == ' ') line = std.mem.trimStart(u8, line[2..], " ");
        const lead = leadingNumber(line) orelse {
            plain_lines += 1;
            continue;
        };
        var n = lead.n;
        var rest = lead.rest;
        // Split merged lines: "3: foo 4: bar".
        while (true) {
            var piece = rest;
            var next: ?[]const u8 = null;
            if (findInlineNumber(rest, n + 1)) |hit| {
                piece = rest[0..hit.at];
                next = rest[hit.rest_at..];
            }
            if (n >= 1 and n <= out.len and out[n - 1] == null) {
                const t = stripQuotes(piece);
                if (t.len > 0) {
                    out[n - 1] = t;
                    filled += 1;
                }
            }
            if (next) |nx| {
                n += 1;
                rest = nx;
            } else break;
        }
    }
    // No numbering at all but the right number of lines → positional.
    if (filled == 0 and plain_lines == out.len) {
        var it = std.mem.splitScalar(u8, reply, '\n');
        var i: usize = 0;
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or std.mem.startsWith(u8, line, "```")) continue;
            if (i < out.len) out[i] = stripQuotes(line);
            i += 1;
        }
        filled = out.len;
    }
    return filled;
}

/// Final cue text: the translation with " / " restored to line breaks, or the
/// original when the model gave nothing usable. Written into `buf`.
pub fn resolveLine(original: []const u8, translated: ?[]const u8, buf: []u8) []const u8 {
    const t = translated orelse return original;
    if (t.len == 0) return original;
    var n: usize = 0;
    var i: usize = 0;
    while (i < t.len) {
        if (std.mem.startsWith(u8, t[i..], break_token)) {
            if (n >= buf.len) break;
            buf[n] = '\n';
            n += 1;
            i += break_token.len;
            continue;
        }
        if (n >= buf.len) break;
        buf[n] = t[i];
        n += 1;
        i += 1;
    }
    // Overflowed: never end inside a UTF-8 sequence (drop the last code point).
    if (i < t.len) {
        while (n > 0 and (buf[n - 1] & 0xC0) == 0x80) n -= 1;
        if (n > 0 and buf[n - 1] >= 0xC0) n -= 1;
    }
    return buf[0..n];
}

/// "<base>.<lang>.srt" for a subtitle source name (path or title).
pub fn outputName(source: []const u8, lang: []const u8, buf: []u8) []const u8 {
    var base = source;
    if (std.mem.lastIndexOfAny(u8, base, "/\\")) |s| base = base[s + 1 ..];
    if (std.mem.indexOfScalar(u8, base, '?')) |q| base = base[0..q];
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |d| {
        if (d > 0 and base.len - d <= 5) base = base[0..d];
    }
    var clean: [96]u8 = undefined;
    var n: usize = 0;
    for (base) |ch| {
        if (n >= clean.len) break;
        clean[n] = if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.') ch else '_';
        n += 1;
    }
    const stem = if (n == 0) "subtitles" else clean[0..n];
    return std.fmt.bufPrint(buf, "{s}.{s}.srt", .{ stem, lang }) catch "subtitles.srt";
}

const testing = std.testing;

test "batches cap item count and size" {
    var texts: [60][]const u8 = undefined;
    for (&texts) |*t| t.* = "short line";
    try testing.expectEqual(@as(usize, 24), nextBatchEnd(&texts, 0));
    try testing.expectEqual(@as(usize, 60), nextBatchEnd(&texts, 48));
    const big = "x" ** 2000;
    const mixed = [_][]const u8{ big, big, "a" };
    try testing.expectEqual(@as(usize, 1), nextBatchEnd(&mixed, 0));
}

test "prompt numbers lines and flattens cue breaks" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeBatchPrompt(&aw.writer, &.{ "Hello", "Two\nlines" }, "Spanish");
    try testing.expect(std.mem.indexOf(u8, aw.written(), "into Spanish. Reply with exactly 2 lines") != null);
    try testing.expect(std.mem.endsWith(u8, aw.written(), "1: Hello\n2: Two / lines\n"));
}

test "clean reply maps 1:1" {
    var out: [3]?[]const u8 = undefined;
    try testing.expectEqual(@as(usize, 3), parseReply("1: Hola\n2: Dos / líneas\n3: Adiós", &out));
    try testing.expectEqualStrings("Hola", out[0].?);
    try testing.expectEqualStrings("Dos / líneas", out[1].?);
}

test "code fences, bullets, chatter and odd numbering are tolerated" {
    var out: [3]?[]const u8 = undefined;
    const reply = "Sure! Here are the translations:\n```\n- 1. \"Hola\"\n2) Dos\n[3] Tres\n```\nHope this helps.";
    try testing.expectEqual(@as(usize, 3), parseReply(reply, &out));
    try testing.expectEqualStrings("Hola", out[0].?);
    try testing.expectEqualStrings("Dos", out[1].?);
    try testing.expectEqualStrings("Tres", out[2].?);
}

test "missing and extra lines fall back to the original" {
    var out: [3]?[]const u8 = undefined;
    _ = parseReply("1: Uno\n3: Tres\n4: Cuatro\n7: Siete", &out);
    try testing.expect(out[1] == null);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Two", resolveLine("Two", out[1], &buf));
    try testing.expectEqualStrings("Tres", resolveLine("Three", out[2], &buf));
}

test "merged lines are split on the next number" {
    var out: [4]?[]const u8 = undefined;
    try testing.expectEqual(@as(usize, 4), parseReply("1: Uno 2: Dos 3: Tres\n4: Cuatro", &out));
    try testing.expectEqualStrings("Uno", out[0].?);
    try testing.expectEqualStrings("Dos", out[1].?);
    try testing.expectEqualStrings("Tres", out[2].?);
}

test "duplicate numbers keep the first; numbers in the text are not markers" {
    var out: [2]?[]const u8 = undefined;
    _ = parseReply("1: Tengo 2 gatos\n1: otra\n2: Vale", &out);
    try testing.expectEqualStrings("Tengo 2 gatos", out[0].?);
    try testing.expectEqualStrings("Vale", out[1].?);
}

test "unnumbered reply with the exact line count maps positionally" {
    var out: [2]?[]const u8 = undefined;
    try testing.expectEqual(@as(usize, 2), parseReply("Hola\nAdiós\n", &out));
    try testing.expectEqualStrings("Adiós", out[1].?);
    var out3: [3]?[]const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), parseReply("Hola\nAdiós\n", &out3));
}

test "garbage reply leaves every line on the original" {
    var out: [2]?[]const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), parseReply("I cannot help with that.", &out));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Hello", resolveLine("Hello", out[0], &buf));
}

test "break token restores cue line breaks" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Dos\nlíneas", resolveLine("x", "Dos / líneas", &buf));
}

test "output name is <base>.<lang>.srt" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("Movie.2024.es.srt", outputName("/m/Movie.2024.mkv", "es", &buf));
    try testing.expectEqualStrings("live.fr.srt", outputName("live.srt", "fr", &buf));
    try testing.expectEqualStrings("subtitles.de.srt", outputName("", "de", &buf));
    try testing.expectEqualStrings("index.en.srt", outputName("https://x/y/index.m3u8?token=1", "en", &buf));
}

test "language table lookups" {
    try testing.expectEqualStrings("Japanese", langName("ja").?);
    try testing.expect(langName("xx") == null);
}
