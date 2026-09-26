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

/// Logical owner of a replace load. This prevents a direct file opened after a
/// playlist/torrent/queue item from inheriting the previous owner's advance
/// behavior while allowing resolver/recovery commits to retain it.
pub const Origin = enum(u8) { direct, playlist, queue, torrent };

pub const browser_user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) " ++
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

pub const Request = struct {
    url: []const u8,
    /// Optional second URL for the same logical item. The player tries this
    /// exactly once only when the primary fails before FILE_LOADED. It shares
    /// the request's identity, headers and resume point.
    fallback_url: []const u8 = "",
    mode: Mode = .replace,
    origin: Origin = .direct,
    queue_item_id: i64 = -1,
    /// Stable, credential-free identity used for progress and local memory.
    /// Empty derives one from `url` at the player boundary.
    history_identity: []const u8 = "",
    /// Credential-free deep link that can reconstruct the live URL after a
    /// restart. Empty keeps only public/local URLs restoreable.
    restore_target: []const u8 = "",
    /// Provider-authoritative resume point. Applied once after FILE_LOADED;
    /// null lets ordinary local watch history decide.
    resume_position_secs: ?f64 = null,
    user_agent: []const u8 = "",
    headers: []const HttpHeader = &.{},
    /// Internal retry seam: already sanitized by buildHeaderFields on the
    /// original request. Normal callers should pass `headers` instead.
    prepared_header_fields: []const u8 = "",
    /// Optional external audio stream paired with a video-only URL.
    audio_file: []const u8 = "",
    /// Display title for transport controls when `url` is an opaque proxy URL.
    media_title: []const u8 = "",
    /// This request is served by Opal's bounded torrent loopback proxy.
    loopback_stream: bool = false,
};

test "replace loads default to direct ownership and no queue identity" {
    const request: Request = .{ .url = "movie.mkv" };
    try std.testing.expectEqual(Origin.direct, request.origin);
    try std.testing.expectEqual(@as(i64, -1), request.queue_item_id);
}

pub fn shouldArmFallback(primary: []const u8, fallback: []const u8, mode: Mode) bool {
    return mode == .replace and fallback.len > 0 and
        !std.mem.eql(u8, primary, fallback);
}

test "fallback is replace-only and must differ from the primary" {
    try std.testing.expect(shouldArmFallback("https://a/one", "https://a/two", .replace));
    try std.testing.expect(!shouldArmFallback("https://a/one", "https://a/one", .replace));
    try std.testing.expect(!shouldArmFallback("https://a/one", "", .replace));
    try std.testing.expect(!shouldArmFallback("https://a/one", "https://a/two", .append));
}

pub fn saneResumePosition(value: ?f64) ?f64 {
    const position = value orelse return null;
    if (!std.math.isFinite(position) or position < 1 or position > 315_576_000) return null;
    return position;
}

test "provider resume positions reject invalid and absurd values" {
    try std.testing.expect(saneResumePosition(null) == null);
    try std.testing.expect(saneResumePosition(std.math.nan(f64)) == null);
    try std.testing.expect(saneResumePosition(-1) == null);
    try std.testing.expectEqual(@as(f64, 123.5), saneResumePosition(123.5).?);
}

/// True when a periodic watch-history save must be SKIPPED because mpv is
/// parked at the end of a still-incomplete torrent, not because the user
/// watched anything.
///
/// mpv reports percent-pos 100 at EOF even when 9% is on disk (a Black
/// Panther 2160p sat at "2:41:18/2:41:18" with 8.9% downloaded). The 5s saver
/// used to record that as percent=100/position=duration — a poisoned row that
/// marks an unwatched movie fully watched and can never resume correctly.
/// Complete torrents (and genuine finishes, which go through
/// saveCurrentPositionFinal) are unaffected: only an incomplete torrent parked
/// at/near the end is refused.
pub fn skipEofParkedSave(torrent_incomplete: bool, percent_pos: f64, pos_secs: f64, dur_secs: f64) bool {
    if (!torrent_incomplete) return false;
    if (std.math.isFinite(percent_pos) and percent_pos >= 99.0) return true;
    if (std.math.isFinite(pos_secs) and std.math.isFinite(dur_secs) and dur_secs > 0 and
        pos_secs >= 0.99 * dur_secs) return true;
    return false;
}

test "eof-parked saves are skipped only for incomplete torrents at the end" {
    // The observed poisoning: EOF-parked, 8.9% on disk.
    try std.testing.expect(skipEofParkedSave(true, 100.0, 9678.0, 9678.0));
    try std.testing.expect(skipEofParkedSave(true, 99.5, 100.0, 200.0));
    try std.testing.expect(skipEofParkedSave(true, 50.0, 992.0, 1000.0)); // pos >= 99% dur
    // Mid-stream positions on an incomplete torrent are still worth saving.
    try std.testing.expect(!skipEofParkedSave(true, 50.0, 500.0, 1000.0));
    try std.testing.expect(!skipEofParkedSave(true, 96.0, 960.0, 1000.0)); // near end, not parked
    try std.testing.expect(!skipEofParkedSave(true, 3.0, 120.0, 0.0)); // unknown duration
    // Complete torrents (and non-torrents) always save: a 100% row is truthful.
    try std.testing.expect(!skipEofParkedSave(false, 100.0, 9678.0, 9678.0));
    // NaN properties (mpv unavailable) never count as parked.
    try std.testing.expect(!skipEofParkedSave(true, std.math.nan(f64), std.math.nan(f64), std.math.nan(f64)));
}

/// Resume point for an EOF reload on a still-incomplete torrent.
///
/// mpv EOFs when the proxy's 15s piece wait expires mid-body (ffmpeg reads a
/// truncated body as end-of-file, it has no reconnect path), and the reload
/// used to restart from 0 whenever percent-pos was unusable at EOF (>= 99.9,
/// <= 0.1, NaN) — every stall visibly threw playback back to the beginning.
/// Returns a seconds resume when the caller should override, null to keep the
/// existing percent-pos path. last_good_secs is the newest non-EOF-parked
/// position the saver recorded, so a stall resumes where it stalled.
pub fn eofReloadResumeSecs(cur_pct_usable: bool, last_good_secs: f64) ?f64 {
    if (cur_pct_usable) return null;
    return saneResumePosition(last_good_secs);
}

test "eof reload resumes at last good position when percent is unusable" {
    try std.testing.expect(eofReloadResumeSecs(true, 500.0) == null); // percent path handles it
    try std.testing.expectEqual(@as(f64, 500.0), eofReloadResumeSecs(false, 500.0).?);
    try std.testing.expect(eofReloadResumeSecs(false, 0.0) == null); // nothing good yet: from start
    try std.testing.expect(eofReloadResumeSecs(false, std.math.nan(f64)) == null);
}

/// mpv 0.38.0 (client API 2.3) inserted an `<index>` argument into `loadfile`
/// between `<flags>` and `<options>`. Passing five arguments to an older
/// libmpv makes it read our `-1` index as the options map and reject the
/// command with "argument options has incompatible type" — the file never
/// loads and the UI sits on "Opening stream" (issue #47, Ubuntu 22.04 ships
/// mpv 0.34). Choose the argument shape from the RUNTIME client API version
/// (`mpv_client_api_version()`), never the headers we compiled against.
pub const loadfile_index_api_version: u32 = (2 << 16) | 3; // MPV_MAKE_VERSION(2, 3)

pub fn loadfileHasIndexArg(runtime_api_version: u32) bool {
    return runtime_api_version >= loadfile_index_api_version;
}

/// Oldest libmpv the load path is written for (mpv 0.34 = client API 2.0):
/// below this `loadfile` has no per-file options map at all.
pub const min_supported_api_version: u32 = (2 << 16) | 0;

test "loadfile index argument only on mpv 0.38+ (client API 2.3+)" {
    try std.testing.expect(!loadfileHasIndexArg((1 << 16) | 109)); // mpv 0.33
    try std.testing.expect(!loadfileHasIndexArg((2 << 16) | 0)); // mpv 0.34/0.35
    try std.testing.expect(!loadfileHasIndexArg((2 << 16) | 2)); // mpv 0.37
    try std.testing.expect(loadfileHasIndexArg((2 << 16) | 3)); // mpv 0.38
    try std.testing.expect(loadfileHasIndexArg((2 << 16) | 5)); // mpv 0.40/0.41
    try std.testing.expect(loadfileHasIndexArg((3 << 16) | 0)); // future major
}

/// HTTP options attached to one mpv playlist entry by `loadfile`.  Values are
/// always explicit, including the defaults, so an appended entry cannot later
/// inherit whatever happens to be configured on the player context.
pub const FileOptions = struct {
    user_agent: []const u8,
    header_fields: []const u8,
    cache_pause_initial: [:0]const u8,
    network_timeout: [:0]const u8,
    audio_file: []const u8,
    media_title: []const u8,
};

/// Begin ordinary local and network playback as soon as the demuxer has a
/// frame. The initial cache gate remains only for Opal's torrent proxy: that
/// endpoint can block while pieces arrive and needs the protected runway.
/// mpv's normal cache-pause still handles a later network underrun.
pub fn cachePauseInitial(url: []const u8, loopback_stream: bool) [:0]const u8 {
    _ = url;
    return if (loopback_stream) "yes" else "no";
}

pub fn networkTimeout(loopback_stream: bool) [:0]const u8 {
    // The proxy itself abandons a no-progress piece wait at 15 seconds. Give
    // that reconnect path five seconds to close before mpv's own backstop fires.
    return if (loopback_stream) "20" else "15";
}

pub fn effectiveUserAgent(request: Request) []const u8 {
    if (request.user_agent.len > 0) return request.user_agent;
    if (request.headers.len > 0 or request.prepared_header_fields.len > 0) return browser_user_agent;
    return "libmpv";
}

pub fn resolvedHeaderFields(request: Request, out: []u8) []const u8 {
    if (request.prepared_header_fields.len > 0) {
        const prepared = request.prepared_header_fields;
        if (prepared.len > out.len or std.mem.indexOfAny(u8, prepared, "\r\n\x00") != null) return "";
        @memcpy(out[0..prepared.len], prepared);
        return out[0..prepared.len];
    }
    return http_headers.buildHeaderFields(request.headers, out);
}

test "local media bypasses initial cache gate" {
    try std.testing.expectEqualStrings("no", cachePauseInitial("D:\\Media\\movie.mkv", false));
    try std.testing.expectEqualStrings("no", cachePauseInitial("FILE:///D:/Media/movie.mkv", false));
    try std.testing.expectEqualStrings("no", cachePauseInitial("https://cdn.example/movie.mkv", false));
    try std.testing.expectEqualStrings("yes", cachePauseInitial("http://127.0.0.1/torrent", true));
}

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
    var joined: [2048]u8 = undefined;
    const fields = resolvedHeaderFields(request, &joined);

    sink.loadFile(request.url, request.mode, .{
        .user_agent = effectiveUserAgent(request),
        .header_fields = fields,
        .cache_pause_initial = cachePauseInitial(request.url, request.loopback_stream),
        .network_timeout = networkTimeout(request.loopback_stream),
        .audio_file = request.audio_file,
        .media_title = request.media_title,
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
    network_timeout: [8]u8 = undefined,
    network_timeout_len: usize = 0,

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

    fn networkTimeoutSlice(self: *const FakeEvent) []const u8 {
        return self.network_timeout[0..self.network_timeout_len];
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
        event.network_timeout_len = @min(options.network_timeout.len, event.network_timeout.len);
        @memcpy(event.network_timeout[0..event.network_timeout_len], options.network_timeout[0..event.network_timeout_len]);
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

test "torrent loopback retains a finite defense-in-depth timeout" {
    var sink: FakeSink = .{};
    try std.testing.expect(dispatch(&sink, .{ .url = "https://www.youtube.com/watch?v=x" }));
    try std.testing.expectEqualStrings("15", sink.events[2].networkTimeoutSlice());

    sink.len = 0;
    try std.testing.expect(dispatch(&sink, .{
        .url = "http://127.0.0.1:49152/stream/token",
        .loopback_stream = true,
    }));
    try std.testing.expectEqualStrings("20", sink.events[2].networkTimeoutSlice());
}

test "prepared retry headers preserve sanitized identity and reject injection" {
    var sink: FakeSink = .{};
    try std.testing.expect(dispatch(&sink, .{
        .url = "https://cdn.example/signed",
        .user_agent = "Original-UA",
        .prepared_header_fields = "Referer: https://embed.example,Cookie: safe=1",
    }));
    try std.testing.expectEqualStrings("Original-UA", sink.events[2].userAgentSlice());
    try std.testing.expectEqualStrings("Referer: https://embed.example,Cookie: safe=1", sink.events[2].headerFieldsSlice());

    sink.len = 0;
    try std.testing.expect(dispatch(&sink, .{
        .url = "https://cdn.example/bad",
        .prepared_header_fields = "Referer: good\r\nInjected: bad",
    }));
    try std.testing.expectEqualStrings("", sink.events[2].headerFieldsSlice());
}
