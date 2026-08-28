//! Pure helpers for Opal's zero-key Cinemeta movie/series catalog fallback.

const std = @import("std");

/// Split the top-level objects in Cinemeta's `metas` array without treating
/// braces inside JSON strings as structure.
pub fn splitMetaObjects(body: []const u8, out: [][]const u8) usize {
    const key = "\"metas\":[";
    const start = std.mem.indexOf(u8, body, key) orelse return 0;
    var i = start + key.len;
    var depth: i32 = 0;
    var object_start: ?usize = null;
    var in_string = false;
    var escaped = false;
    var count: usize = 0;

    while (i < body.len and count < out.len) : (i += 1) {
        const c = body[i];
        if (in_string) {
            if (escaped) escaped = false else if (c == '\\') escaped = true else if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{' => {
                if (depth == 0) object_start = i;
                depth += 1;
            },
            '}' => {
                depth -= 1;
                if (depth == 0) if (object_start) |s| {
                    out[count] = body[s .. i + 1];
                    count += 1;
                    object_start = null;
                };
            },
            ']' => if (depth == 0) break,
            else => {},
        }
    }
    return count;
}

/// Stable positive card/list id when a Cinemeta record has no TMDB id.
pub fn stableId(imdb_id: []const u8) i32 {
    const hash = std.hash.Wyhash.hash(0, imdb_id);
    return @intCast((hash % 2_147_483_646) + 1);
}

test "splitMetaObjects ignores braces in descriptions" {
    const body = "{\"metas\":[{\"id\":\"tt1\",\"description\":\"x } y\"},{\"id\":\"tt2\"}]}";
    var out: [4][]const u8 = undefined;
    const n = splitMetaObjects(body, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expect(std.mem.indexOf(u8, out[0], "tt1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out[1], "tt2") != null);
}

test "stableId is positive and deterministic" {
    try std.testing.expect(stableId("tt0944947") > 0);
    try std.testing.expectEqual(stableId("tt0944947"), stableId("tt0944947"));
    try std.testing.expect(stableId("tt0944947") != stableId("tt0903747"));
}
