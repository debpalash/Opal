const std = @import("std");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const io_global = @import("../core/io_global.zig");

// ══════════════════════════════════════════════════════════
// SIMKL — simple watch tracking API (API key only, no OAuth)
// https://simkl.docs.apiary.io/
// ══════════════════════════════════════════════════════════

const SIMKL_API = "https://api.simkl.com";

pub var api_key: [128]u8 = std.mem.zeroes([128]u8);
pub var api_key_len: usize = 0;
pub var access_token: [256]u8 = std.mem.zeroes([256]u8);
pub var access_token_len: usize = 0;
pub var enabled: bool = false;

/// Checkin — mark something as watching now.
pub fn checkin(title: []const u8, media_type: []const u8) void {
    if (!enabled or access_token_len == 0 or api_key_len == 0) return;

    _ = std.Thread.spawn(.{}, struct {
        fn worker(t: []const u8, mt: []const u8) void {
            const alloc = @import("../core/alloc.zig").allocator;

            var esc: [256]u8 = undefined;
            var ei: usize = 0;
            for (t) |ch| {
                if (ei + 2 >= esc.len) break;
                if (ch == '"') { esc[ei] = '\\'; ei += 1; esc[ei] = '"'; ei += 1; }
                else { esc[ei] = ch; ei += 1; }
            }

            var json_buf: [512]u8 = undefined;
            const json = std.fmt.bufPrintZ(&json_buf,
                \\{{"movies":[{{"title":"{s}"}}],"shows":[{{"title":"{s}"}}]}}
            , .{ if (std.mem.eql(u8, mt, "movie")) esc[0..ei] else "", if (std.mem.eql(u8, mt, "show")) esc[0..ei] else "" }) catch return;

            var url_buf: [256]u8 = undefined;
            const url = std.fmt.bufPrintZ(&url_buf, "{s}/sync/history", .{SIMKL_API}) catch return;

            var auth_buf: [300]u8 = undefined;
            const auth = std.fmt.bufPrintZ(&auth_buf, "Authorization: Bearer {s}", .{access_token[0..access_token_len]}) catch return;

            var cid_buf: [200]u8 = undefined;
            const cid = std.fmt.bufPrintZ(&cid_buf, "simkl-api-key: {s}", .{api_key[0..api_key_len]}) catch return;

            var child = io_global.Child.init(&.{
                "curl", "-s", "-X", "POST", url,
                "-H", "Content-Type: application/json",
                "-H", cid,
                "-H", auth,
                "-d", json,
            }, alloc);
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Ignore;
            child.spawn() catch return;
            const result = child.wait() catch return;
            if (result.exited == 0) {
                logs.pushLog("info", "simkl", "SIMKL history synced", false);
            }
        }
    }.worker, .{ title, media_type }) catch {};
}

/// Add to watchlist
pub fn addToWatchlist(title: []const u8) void {
    if (!enabled or access_token_len == 0) return;

    _ = std.Thread.spawn(.{}, struct {
        fn worker(t: []const u8) void {
            const alloc = @import("../core/alloc.zig").allocator;

            var esc: [256]u8 = undefined;
            var ei: usize = 0;
            for (t) |ch| {
                if (ei + 2 >= esc.len) break;
                if (ch == '"') { esc[ei] = '\\'; ei += 1; esc[ei] = '"'; ei += 1; }
                else { esc[ei] = ch; ei += 1; }
            }

            var json_buf: [512]u8 = undefined;
            const json = std.fmt.bufPrintZ(&json_buf,
                \\{{"movies":[{{"title":"{s}"}}]}}
            , .{esc[0..ei]}) catch return;

            var url_buf: [256]u8 = undefined;
            const url = std.fmt.bufPrintZ(&url_buf, "{s}/sync/add-to-list", .{SIMKL_API}) catch return;

            var auth_buf: [300]u8 = undefined;
            const auth = std.fmt.bufPrintZ(&auth_buf, "Authorization: Bearer {s}", .{access_token[0..access_token_len]}) catch return;

            var cid_buf: [200]u8 = undefined;
            const cid = std.fmt.bufPrintZ(&cid_buf, "simkl-api-key: {s}", .{api_key[0..api_key_len]}) catch return;

            var child = io_global.Child.init(&.{
                "curl", "-s", "-X", "POST", url,
                "-H", "Content-Type: application/json",
                "-H", cid,
                "-H", auth,
                "-d", json,
            }, alloc);
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Ignore;
            child.spawn() catch return;
            _ = child.wait() catch {};
        }
    }.worker, .{title}) catch {};
}
