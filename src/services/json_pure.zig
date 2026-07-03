//! Pure JSON string unescaping — no io, no state.
//!
//! Scraper/CLI JSON (yt-dlp dumps, API bodies) is sliced with lightweight
//! extractors that return the RAW string bytes; titles containing ’
//! (apostrophe), \" or \n rendered literally in the UI ("You’ve").
//! Run extracted display strings through jsonUnescape before storing.

const std = @import("std");

/// Decode JSON string escapes into `out`: \" \\ \/ \n \t \r \b \f and
/// \uXXXX (including UTF-16 surrogate pairs) → UTF-8. Unknown escapes and
/// truncated sequences are dropped rather than passed through. Returns a
/// slice of `out`; truncates safely if `out` is too small.
pub fn jsonUnescape(input: []const u8, out: []u8) []const u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        const ch = input[i];
        if (ch != '\\') {
            if (w >= out.len) break;
            out[w] = ch;
            w += 1;
            i += 1;
            continue;
        }
        if (i + 1 >= input.len) break;
        const esc = input[i + 1];
        i += 2;
        switch (esc) {
            '"', '\\', '/' => {
                if (w >= out.len) break;
                out[w] = esc;
                w += 1;
            },
            'n' => {
                if (w >= out.len) break;
                out[w] = '\n';
                w += 1;
            },
            't' => {
                if (w >= out.len) break;
                out[w] = '\t';
                w += 1;
            },
            'r' => {
                if (w >= out.len) break;
                out[w] = '\r';
                w += 1;
            },
            'b', 'f' => {
                if (w >= out.len) break;
                out[w] = ' ';
                w += 1;
            },
            'u' => {
                if (i + 4 > input.len) break;
                var cp: u21 = std.fmt.parseInt(u16, input[i .. i + 4], 16) catch {
                    i += 4;
                    continue;
                };
                i += 4;
                // UTF-16 surrogate pair → combine into one codepoint.
                if (cp >= 0xD800 and cp <= 0xDBFF and i + 6 <= input.len and
                    input[i] == '\\' and input[i + 1] == 'u')
                {
                    if (std.fmt.parseInt(u16, input[i + 2 .. i + 6], 16)) |lo| {
                        if (lo >= 0xDC00 and lo <= 0xDFFF) {
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                            i += 6;
                        }
                    } else |_| {}
                }
                if (cp >= 0xD800 and cp <= 0xDFFF) continue; // lone surrogate — drop
                var enc: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &enc) catch continue;
                if (w + n > out.len) break;
                @memcpy(out[w .. w + n], enc[0..n]);
                w += n;
            },
            else => {}, // unknown escape — drop
        }
    }
    return out[0..w];
}

test "jsonUnescape decodes basic escapes" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("plain text", jsonUnescape("plain text", &buf));
    try std.testing.expectEqualStrings("a\"b\\c/d", jsonUnescape("a\\\"b\\\\c\\/d", &buf));
    try std.testing.expectEqualStrings("line\nbreak\ttab", jsonUnescape("line\\nbreak\\ttab", &buf));
}

test "jsonUnescape decodes unicode escapes" {
    var buf: [128]u8 = undefined;
    // The exact case from the yt-dlp title bug: You’ve → You’ve.
    try std.testing.expectEqualStrings("You’ve", jsonUnescape("You\\u2019ve", &buf));
    try std.testing.expectEqualStrings("café", jsonUnescape("caf\\u00e9", &buf));
    // Surrogate pair → single codepoint (U+1F3AC, spelled in bytes — no
    // emoji literals in src per UI standards).
    try std.testing.expectEqualStrings("\xf0\x9f\x8e\xac", jsonUnescape("\\ud83c\\udfac", &buf));
}

test "jsonUnescape handles malformed input safely" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("x", jsonUnescape("x\\", &buf)); // trailing backslash
    try std.testing.expectEqualStrings("a", jsonUnescape("a\\u12b", &buf)); // truncated \u — stops cleanly
    try std.testing.expectEqualStrings("", jsonUnescape("\\uZZZZ", &buf)); // bad hex — dropped
    // Lone high surrogate — dropped, following text kept.
    try std.testing.expectEqualStrings("ok", jsonUnescape("\\ud800ok", &buf));
}

test "jsonUnescape truncates at output capacity" {
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqualStrings("abcd", jsonUnescape("abcdef", &tiny));
}
