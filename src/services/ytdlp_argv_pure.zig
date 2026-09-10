//! App-owned yt-dlp invocations. Never borrow browser sessions or user config.
//! Callers supply data, not extra flags; the URL always follows `--`.
const std = @import("std");

pub const Argv = [24][]const u8;
pub const Operation = union(enum) {
    playlist_json,
    search_json,
    thumbnail,
    youtube_listing: ?[]const u8,
    audio_download: struct { directory: []const u8, output_template: []const u8 },
};

pub const listing_template = "%(id)s\t%(title)s\t%(channel)s\t%(duration)s\t%(view_count)s\t%(upload_date)s\t%(channel_id)s";

pub fn build(binary: []const u8, target: []const u8, operation: Operation, proxy: []const u8, out: *Argv) []const []const u8 {
    var count: usize = 0;
    const append = struct {
        fn f(buf: *Argv, n: *usize, args: []const []const u8) void {
            for (args) |arg| {
                buf[n.*] = arg;
                n.* += 1;
            }
        }
    }.f;
    append(out, &count, &.{ binary, "--ignore-config", "--no-warnings" });
    switch (operation) {
        .playlist_json => append(out, &count, &.{ "--flat-playlist", "-j" }),
        .search_json => append(out, &count, &.{ "--flat-playlist", "--dump-json" }),
        .thumbnail => append(out, &count, &.{ "--no-playlist", "--get-thumbnail" }),
        .youtube_listing => |range| {
            append(out, &count, &.{ "--flat-playlist", "--print", listing_template, "--socket-timeout", "10" });
            if (range) |value| append(out, &count, &.{ "-I", value });
        },
        .audio_download => |audio| append(out, &count, &.{
            "-x", "--audio-format", "mp3", "--audio-quality", "0",
            "--embed-metadata", "--embed-thumbnail", "--no-playlist",
            "--paths", audio.directory, "-o", audio.output_template,
        }),
    }
    if (proxy.len > 0) append(out, &count, &.{ "--proxy", proxy });
    append(out, &count, &.{ "--", target });
    return out[0..count];
}

test "every invocation isolates config, preserves TLS, and treats target as data" {
    const operations = [_]Operation{
        .playlist_json, .search_json, .thumbnail,
        .{ .youtube_listing = null }, .{ .youtube_listing = "1:20" },
        // Fixture paths deliberately avoid /tmp: the portability suite greps
        // every source for '"/tmp/' (an unconditional write there is dead on
        // Windows) and cannot tell a test fixture from a real path.
        .{ .audio_download = .{ .directory = "/home/u/my music", .output_template = "track.%(ext)s" } },
    };
    for (operations) |operation| {
        var storage: Argv = undefined;
        const args = build("/opt/opal/fake yt-dlp", "--exec=untrusted", operation, "http://127.0.0.1:8080", &storage);
        try std.testing.expect(args.len <= storage.len);
        try std.testing.expectEqualStrings("--ignore-config", args[1]);
        try std.testing.expectEqualStrings("--", args[args.len - 2]);
        try std.testing.expectEqualStrings("--exec=untrusted", args[args.len - 1]);
        for (args[0 .. args.len - 1]) |arg| {
            try std.testing.expect(!std.mem.eql(u8, arg, "--no-check-certificates"));
            try std.testing.expect(!std.mem.eql(u8, arg, "--cookies-from-browser"));
            try std.testing.expect(!std.mem.eql(u8, arg, "--cookies"));
            try std.testing.expect(!std.mem.eql(u8, arg, "--config-locations"));
        }
    }
}

test "listing retains explicit pagination and the parser's exact template" {
    var storage: Argv = undefined;
    const args = build("yt-dlp", "ytsearch20:test", .{ .youtube_listing = "1:20" }, "", &storage);
    try std.testing.expectEqualStrings(listing_template, args[5]);
    try std.testing.expectEqualStrings("-I", args[8]);
    try std.testing.expectEqualStrings("1:20", args[9]);
}
