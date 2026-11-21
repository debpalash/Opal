//! Pure verification helpers for voice_setup.zig — pinned release digests and
//! pre-extraction `tar -tvjf` archive safety validation.

const std = @import("std");

pub const SHERPA_SIZE: u64 = 26_159_941;
pub const SHERPA_SHA256 = "d67b1a77ca252a4dbe0480255c61eeadc951708d15ac840c12308864496b134d";

pub const SILERO_SIZE: u64 = 643_854;
pub const SILERO_SHA256 = "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6";

fn hasUnsafePathPart(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or path[0] == '\\') return true;
    for (path) |ch| {
        if (ch < 0x20 or ch == 0x7f or ch == '\\') return true;
    }
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return true;
    }
    return false;
}

fn underRoot(path: []const u8, expected_root: []const u8) bool {
    if (std.mem.eql(u8, path, expected_root)) return true;
    if (path.len > expected_root.len and
        std.mem.startsWith(u8, path, expected_root) and
        path[expected_root.len] == '/')
    {
        return true;
    }
    return false;
}

/// Extract the entry name (and optional link target) from a BSD/GNU `tar -tv`
/// listing line. Format: `<mode> <links/owner> ... <time> <path>[ -> <target>]`.
fn parseTarVerboseLine(line: []const u8) ?struct { mode: u8, path: []const u8, link_target: ?[]const u8 } {
    if (line.len < 10) return null;
    const mode = line[0];
    // Skip leading whitespace-separated metadata columns:
    // BSD tar: mode links owner group size mon day time/year name... (8 cols)
    // GNU tar: mode owner/group size date time name... (5 cols)
    // Locate the first token that starts with a letter/dot/slash after col 4
    // by finding the date/time column (`HH:MM` or 4-digit year) — or simply
    // skip columns until after the time/year field.
    var i: usize = 0;
    var col: usize = 0;
    var path_start: ?usize = null;
    while (i < line.len) {
        while (i < line.len and line[i] == ' ') : (i += 1) {}
        if (i >= line.len) break;
        const tok_start = i;
        while (i < line.len and line[i] != ' ') : (i += 1) {}
        const tok = line[tok_start..i];
        col += 1;
        // GNU tar: col 5 is HH:MM (e.g. "12:34"); BSD tar: col 8 is HH:MM or YYYY.
        const is_time = (tok.len == 5 and tok[2] == ':' and std.ascii.isDigit(tok[0]) and std.ascii.isDigit(tok[4]));
        const is_year = (col == 8 and tok.len == 4 and std.ascii.isDigit(tok[0]) and std.ascii.isDigit(tok[3]));
        if ((col == 5 and is_time) or (col == 8 and (is_time or is_year))) {
            while (i < line.len and line[i] == ' ') : (i += 1) {}
            if (i < line.len) path_start = i;
            break;
        }
    }
    const start = path_start orelse return null;
    const rest = std.mem.trimEnd(u8, line[start..], "\r");
    if (rest.len == 0) return null;

    if (mode == 'l') {
        const sep = std.mem.indexOf(u8, rest, " -> ") orelse return null;
        return .{ .mode = mode, .path = rest[0..sep], .link_target = rest[sep + 4 ..] };
    }
    if (mode == 'h') {
        const sep = std.mem.indexOf(u8, rest, " link to ") orelse return null;
        return .{ .mode = mode, .path = rest[0..sep], .link_target = rest[sep + 9 ..] };
    }
    return .{ .mode = mode, .path = rest, .link_target = null };
}

/// Validate `tar -tvjf` output before extraction. Refuses empty listings,
/// absolute paths, `..` traversal, paths outside `expected_root`, device/fifo
/// nodes, and absolute or parent-escaping symlinks/hardlinks.
pub fn tarListingSafe(listing: []const u8, expected_root: []const u8) bool {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r");
        if (line.len == 0) continue;
        const entry = parseTarVerboseLine(line) orelse return false;
        switch (entry.mode) {
            '-', 'd', 'l', 'h' => {},
            else => return false,
        }
        const clean_path = if (std.mem.startsWith(u8, entry.path, "./")) entry.path[2..] else entry.path;
        if (hasUnsafePathPart(clean_path)) return false;
        if (!underRoot(clean_path, expected_root)) return false;
        if (entry.link_target) |target| {
            if (hasUnsafePathPart(target)) return false;
            if (entry.mode == 'h' and !underRoot(target, expected_root)) return false;
        }
        count += 1;
    }
    return count > 0;
}

test "tarListingSafe accepts valid sherpa bundle with relative dylib symlink" {
    const bsd =
        "drwxr-xr-x  0 runner staff       0 Jan  1  2026 sherpa-onnx-v1.13.3-osx-arm64-shared/\n" ++
        "-rwxr-xr-x  0 runner staff  123456 Jan  1 12:34 sherpa-onnx-v1.13.3-osx-arm64-shared/bin/sherpa-onnx-offline\n" ++
        "lrwxr-xr-x  0 runner staff       0 Jan  1 12:34 sherpa-onnx-v1.13.3-osx-arm64-shared/lib/libonnxruntime.dylib -> libonnxruntime.1.17.1.dylib\n";
    try std.testing.expect(tarListingSafe(bsd, "sherpa-onnx-v1.13.3-osx-arm64-shared"));

    const gnu =
        "drwxr-xr-x runner/staff 0 2026-01-01 12:34 sherpa-onnx-v1.13.3-osx-arm64-shared/\n" ++
        "-rwxr-xr-x runner/staff 123456 2026-01-01 12:34 sherpa-onnx-v1.13.3-osx-arm64-shared/bin/sherpa-onnx-offline\n" ++
        "lrwxr-xr-x runner/staff 0 2026-01-01 12:34 sherpa-onnx-v1.13.3-osx-arm64-shared/lib/liba.dylib -> liba.1.dylib\n";
    try std.testing.expect(tarListingSafe(gnu, "sherpa-onnx-v1.13.3-osx-arm64-shared"));
}

test "tarListingSafe rejects traversal, absolute paths, escaping symlinks and wrong roots" {
    const root = "sherpa-onnx-v1.13.3-osx-arm64-shared";
    try std.testing.expect(!tarListingSafe("", root));
    try std.testing.expect(!tarListingSafe(
        "-rw-r--r--  0 runner staff 10 Jan  1 12:34 sherpa-onnx-v1.13.3-osx-arm64-shared/../../.zshrc\n",
        root,
    ));
    try std.testing.expect(!tarListingSafe(
        "-rw-r--r--  0 runner staff 10 Jan  1 12:34 /etc/passwd\n",
        root,
    ));
    try std.testing.expect(!tarListingSafe(
        "lrwxr-xr-x  0 runner staff  0 Jan  1 12:34 sherpa-onnx-v1.13.3-osx-arm64-shared/bin/pwn -> /bin/sh\n",
        root,
    ));
    try std.testing.expect(!tarListingSafe(
        "lrwxr-xr-x  0 runner staff  0 Jan  1 12:34 sherpa-onnx-v1.13.3-osx-arm64-shared/bin/pwn -> ../../../.zshrc\n",
        root,
    ));
    try std.testing.expect(!tarListingSafe(
        "crw-r--r--  0 root   wheel  0 Jan  1 12:34 sherpa-onnx-v1.13.3-osx-arm64-shared/devnull\n",
        root,
    ));
    try std.testing.expect(!tarListingSafe(
        "-rw-r--r--  0 runner staff 10 Jan  1 12:34 other-dir/evil\n",
        root,
    ));
}
