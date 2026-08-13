//! Typed media-load command planning.
//!
//! mpv's `loadfile` command accepts a per-file options map.  Every request uses
//! that map so queued entries retain their own HTTP identity until playback.
//! Replace additionally clears the player context's persistent options first,
//! preventing an older raw/global configuration from leaking into the new
//! file.  Append never mutates those options because doing so would alter the
//! stream that is playing while the queue entry is being added.

const std = @import("std");
const http_headers = @import("http_headers_pure.zig");

pub const HttpHeader = http_headers.HttpHeader;

pub const Mode = enum {
    replace,
    append,

    pub fn mpvArg(self: Mode) [:0]const u8 {
        return switch (self) {
            .replace => "replace",
            .append => "append",
        };
    }
};

pub const browser_user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) " ++
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

pub const Request = struct {
    url: []const u8,
    mode: Mode = .replace,
    user_agent: []const u8 = "",
    headers: []const HttpHeader = &.{},
};

/// HTTP options attached to one mpv playlist entry by `loadfile`.  Values are
/// always explicit, including the defaults, so an appended entry cannot later
/// inherit whatever happens to be configured on the player context.
pub const FileOptions = struct {
    user_agent: []const u8,
    header_fields: []const u8,
};

/// Send one request to a command sink.  The sink interface is deliberately
/// tiny: `setOption(name, value)` and `loadFile(url, mode, file_options)`.
/// Returning false means no command was emitted (currently only an empty URL).
pub fn dispatch(sink: anytype, request: Request) bool {
    if (request.url.len == 0) return false;

    // A replace sheds any persistent state left by legacy/raw command paths.
    // Append must not touch it: these options affect the currently-playing
    // entry, not merely the new playlist item.
    if (request.mode == .replace) {
        sink.setOption("user-agent", "libmpv");
        sink.setOption("http-header-fields", "");
    }

    // Header-gated hosts historically received a browser UA when the caller
    // supplied only Referer/Origin.  Preserve that behavior without allowing a
    // prior request's custom UA to become the implicit default.
    const effective_ua = if (request.user_agent.len > 0)
        request.user_agent
    else if (request.headers.len > 0)
        browser_user_agent
    else
        "";
    var joined: [2048]u8 = undefined;
    const fields = http_headers.buildHeaderFields(request.headers, &joined);

    sink.loadFile(request.url, request.mode, .{
        .user_agent = if (effective_ua.len > 0) effective_ua else "libmpv",
        .header_fields = fields,
    });
    return true;
}

const EventKind = enum { set_option, load_file };

const FakeEvent = struct {
    kind: EventKind,
    name: [32]u8 = undefined,
    name_len: usize = 0,
    value: [256]u8 = undefined,
    value_len: usize = 0,
    mode: Mode = .replace,
    user_agent: [256]u8 = undefined,
    user_agent_len: usize = 0,
    header_fields: [256]u8 = undefined,
    header_fields_len: usize = 0,

    fn nameSlice(self: *const FakeEvent) []const u8 {
        return self.name[0..self.name_len];
    }

    fn valueSlice(self: *const FakeEvent) []const u8 {
        return self.value[0..self.value_len];
    }

    fn userAgentSlice(self: *const FakeEvent) []const u8 {
        return self.user_agent[0..self.user_agent_len];
    }

    fn headerFieldsSlice(self: *const FakeEvent) []const u8 {
        return self.header_fields[0..self.header_fields_len];
    }
};

const FakeSink = struct {
    events: [16]FakeEvent = undefined,
    len: usize = 0,

    fn setOption(self: *FakeSink, name: []const u8, value: []const u8) void {
        var event: FakeEvent = .{ .kind = .set_option };
        event.name_len = @min(name.len, event.name.len);
        event.value_len = @min(value.len, event.value.len);
        @memcpy(event.name[0..event.name_len], name[0..event.name_len]);
        @memcpy(event.value[0..event.value_len], value[0..event.value_len]);
        self.events[self.len] = event;
        self.len += 1;
    }

    fn loadFile(self: *FakeSink, url: []const u8, mode: Mode, options: FileOptions) void {
        var event: FakeEvent = .{ .kind = .load_file, .mode = mode };
        event.value_len = @min(url.len, event.value.len);
        @memcpy(event.value[0..event.value_len], url[0..event.value_len]);
        event.user_agent_len = @min(options.user_agent.len, event.user_agent.len);
        @memcpy(event.user_agent[0..event.user_agent_len], options.user_agent[0..event.user_agent_len]);
        event.header_fields_len = @min(options.header_fields.len, event.header_fields.len);
        @memcpy(event.header_fields[0..event.header_fields_len], options.header_fields[0..event.header_fields_len]);
        self.events[self.len] = event;
        self.len += 1;
    }
};

test "dispatch clears persistent HTTP state before applying a request" {
    const headers = [_]HttpHeader{
        .{ .name = "Referer", .value = "https://embed.example/watch" },
        .{ .name = "Cookie", .value = "session=private" },
    };
    var sink: FakeSink = .{};

    try std.testing.expect(dispatch(&sink, .{
        .url = "https://cdn.example/video.m3u8",
        .user_agent = "Host-Specific-UA",
        .headers = &headers,
    }));

    try std.testing.expectEqual(@as(usize, 3), sink.len);
    try std.testing.expectEqual(EventKind.set_option, sink.events[0].kind);
    try std.testing.expectEqualStrings("user-agent", sink.events[0].nameSlice());
    try std.testing.expectEqualStrings("libmpv", sink.events[0].valueSlice());
    try std.testing.expectEqualStrings("http-header-fields", sink.events[1].nameSlice());
    try std.testing.expectEqualStrings("", sink.events[1].valueSlice());
    try std.testing.expectEqual(EventKind.load_file, sink.events[2].kind);
    try std.testing.expectEqualStrings("Host-Specific-UA", sink.events[2].userAgentSlice());
    try std.testing.expectEqualStrings(
        "Referer: https://embed.example/watch,Cookie: session=private",
        sink.events[2].headerFieldsSlice(),
    );
    try std.testing.expectEqual(Mode.replace, sink.events[2].mode);
}

test "unrelated plain load cannot inherit credentials from the prior host" {
    const private_headers = [_]HttpHeader{
        .{ .name = "Cookie", .value = "auth=secret" },
        .{ .name = "Referer", .value = "https://private.example/" },
    };
    var sink: FakeSink = .{};
    try std.testing.expect(dispatch(&sink, .{
        .url = "https://private.example/one.m3u8",
        .user_agent = "Private-UA",
        .headers = &private_headers,
    }));

    sink.len = 0;
    try std.testing.expect(dispatch(&sink, .{
        .url = "https://unrelated.example/two.mp4",
    }));

    try std.testing.expectEqual(@as(usize, 3), sink.len);
    try std.testing.expectEqualStrings("user-agent", sink.events[0].nameSlice());
    try std.testing.expectEqualStrings("libmpv", sink.events[0].valueSlice());
    try std.testing.expectEqualStrings("http-header-fields", sink.events[1].nameSlice());
    try std.testing.expectEqualStrings("", sink.events[1].valueSlice());
    try std.testing.expectEqual(EventKind.load_file, sink.events[2].kind);
    try std.testing.expectEqualStrings("https://unrelated.example/two.mp4", sink.events[2].valueSlice());
    try std.testing.expectEqualStrings("libmpv", sink.events[2].userAgentSlice());
    try std.testing.expectEqualStrings("", sink.events[2].headerFieldsSlice());
}

test "append attaches entry options without mutating the current global options" {
    const headers = [_]HttpHeader{.{ .name = "Cookie", .value = "queued=credential" }};
    var sink: FakeSink = .{};

    // Model an authenticated stream already playing. A global set during
    // append would change this current stream immediately.
    sink.setOption("user-agent", "Current-Authenticated-UA");
    sink.setOption("http-header-fields", "Cookie: current=credential");
    const events_before_append = sink.len;

    try std.testing.expect(dispatch(&sink, .{
        .url = "https://music.example/next.webm",
        .mode = .append,
        .user_agent = "Queued-UA",
        .headers = &headers,
    }));

    // Exactly one append event: no setOption call was allowed to mutate the
    // currently playing authenticated stream.
    try std.testing.expectEqual(events_before_append + 1, sink.len);
    const queued = &sink.events[events_before_append];
    try std.testing.expectEqual(EventKind.load_file, queued.kind);
    try std.testing.expectEqual(Mode.append, queued.mode);
    try std.testing.expectEqualStrings("Queued-UA", queued.userAgentSlice());
    try std.testing.expectEqualStrings("Cookie: queued=credential", queued.headerFieldsSlice());

    try std.testing.expectEqualStrings("Current-Authenticated-UA", sink.events[0].valueSlice());
    try std.testing.expectEqualStrings("Cookie: current=credential", sink.events[1].valueSlice());
}

test "headers without an explicit UA receive a fresh browser UA" {
    const headers = [_]HttpHeader{.{ .name = "Referer", .value = "https://embed.example/" }};
    var sink: FakeSink = .{};
    try std.testing.expect(dispatch(&sink, .{
        .url = "https://cdn.example/video.mp4",
        .headers = &headers,
    }));

    try std.testing.expectEqualStrings(browser_user_agent, sink.events[2].userAgentSlice());
    try std.testing.expectEqualStrings("Referer: https://embed.example/", sink.events[2].headerFieldsSlice());
}
