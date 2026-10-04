//! Operation registry and MCP server core for agent-native Opal.
//!
//! Every operation an agent may perform is declared once in `ops` below: a
//! stable name, a typed parameter list, a permission tier, and the Opal HTTP
//! API route it maps to. Everything agents see is generated from that table —
//! the MCP `tools/list` schemas, argument validation, the request target, the
//! policy decision and the audit line — so adding an operation is one table
//! entry and it is immediately safe to expose.
//!
//! This module is PURE (std only): the transport that actually reaches a
//! running Opal is injected as a `Caller`, so the whole protocol, validation
//! and policy surface unit-tests standalone. The stdio shim lives in
//! `src/mcp_main.zig`.
//!
//! Safety stance (docs/next-level-research.md): never expose raw mpv commands,
//! arbitrary shell options, provider secrets or unrestricted host paths. The
//! registry therefore only names routes whose server-side handlers already
//! validate their input, accepts only typed/bounded arguments, and refuses
//! URLs that are not http(s) or magnet links.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// ── Tiers and policy ────────────────────────────────────────────────────

/// Ordered by blast radius. A policy permits everything up to `max_tier`.
pub const Tier = enum(u8) {
    /// Observes state; may start a search but never changes the library.
    read,
    /// Controls what is playing or queued right now.
    playback,
    /// Changes persistent state (downloads, settings).
    write,
    /// Spends bandwidth/disk/compute: starts downloads, opens magnets.
    spend,
    /// Removes data. Needs an explicit policy opt-in AND `confirm: true`.
    destructive,

    pub fn id(self: Tier) []const u8 {
        return @tagName(self);
    }
};

pub const Policy = struct {
    /// Highest tier executed without a policy change. Destructive operations
    /// additionally require `allow_destructive`.
    max_tier: Tier = .spend,
    allow_destructive: bool = false,
};

pub const Verdict = enum {
    allow,
    /// Tier above the policy ceiling; the user must widen the policy.
    tier_blocked,
    /// Destructive and the call did not pass `confirm: true`.
    needs_confirm,
};

pub fn check(policy: Policy, op: *const Op, is_confirmed: bool) Verdict {
    if (op.tier == .destructive) {
        if (!policy.allow_destructive) return .tier_blocked;
        if (!is_confirmed) return .needs_confirm;
        return .allow;
    }
    if (@intFromEnum(op.tier) > @intFromEnum(policy.max_tier)) return .tier_blocked;
    return .allow;
}

// ── Operation declarations ──────────────────────────────────────────────

pub const Method = enum { GET, POST };

pub const Kind = enum { string, integer, number, boolean, choice };

pub const Param = struct {
    name: []const u8,
    kind: Kind,
    desc: []const u8,
    required: bool = false,
    /// Query key sent to Opal when it differs from the agent-facing name.
    wire: ?[]const u8 = null,
    choices: []const []const u8 = &.{},
    min: f64 = -std.math.inf(f64),
    max: f64 = std.math.inf(f64),
    max_len: usize = 512,
    /// The value must be an http(s) URL or a magnet link, never a path.
    url: bool = false,

    fn key(self: Param) []const u8 {
        return self.wire orelse self.name;
    }
};

pub const Fixed = struct { key: []const u8, value: []const u8 };

pub const Op = struct {
    name: []const u8,
    summary: []const u8,
    tier: Tier,
    method: Method,
    /// Route under /api on the running Opal.
    path: []const u8,
    params: []const Param = &.{},
    fixed: []const Fixed = &.{},
};

const idx_param = Param{ .name = "index", .kind = .integer, .desc = "Zero-based position, as listed.", .required = true, .wire = "idx", .min = 0, .max = 9999 };

const wanted_id = Param{ .name = "id", .kind = .integer, .desc = "Item id from wanted_list.", .required = true, .min = 1, .max = 9007199254740991 };
const wanted_kinds = [_][]const u8{ "movie", "episode" };

const library_filters = [_][]const u8{ "all", "watching", "caught_up", "unstarted", "completed", "dropped" };
const library_kinds = [_][]const u8{ "all", "tv", "anime", "movie" };
const library_sorts = [_][]const u8{ "smart", "recent", "title", "progress" };

const queue_actions = [_][]const u8{ "play", "remove", "move-up", "move-down", "previous", "next", "toggle-shuffle", "cycle-repeat", "clear-played" };

/// The whole agent-visible surface. Names are MCP tool names (a-z, 0-9, _).
pub const ops = [_]Op{
    // ── Observe ──
    .{ .name = "status", .summary = "What is playing now: title, position, duration, pause state, volume.", .tier = .read, .method = .GET, .path = "/status" },
    .{
        .name = "search",
        .summary = "Search every enabled source (torrents, YouTube, anime, comics, Jellyfin, live TV, music, ...). Results arrive asynchronously: call search_results next, repeating until it reports loading=false. The response has a top-level generation, and each result has a key; pass both to search_play / search_queue. Results marked playable=false or queueable=false cannot be used with those.",
        .tier = .read,
        .method = .GET,
        .path = "/unified_search",
        .params = &.{.{ .name = "query", .kind = .string, .desc = "What to look for: a title, a person, a topic.", .required = true, .wire = "q", .max_len = 255 }},
    },
    .{ .name = "search_results", .summary = "Current unified search results and per-source status, without starting a new search.", .tier = .read, .method = .GET, .path = "/unified_search" },
    .{ .name = "queue_list", .summary = "The playback queue with item indexes.", .tier = .read, .method = .GET, .path = "/queue" },
    .{ .name = "downloads_list", .summary = "Active and finished downloads with the index and token that download actions need.", .tier = .read, .method = .GET, .path = "/downloads" },
    .{ .name = "history_list", .summary = "Recently watched items.", .tier = .read, .method = .GET, .path = "/history" },
    .{
        .name = "library_list",
        .summary = "The user's tracked shows, anime and movies with watch progress. Filter by status or kind; page with offset and limit.",
        .tier = .read,
        .method = .GET,
        .path = "/library",
        .params = &.{
            .{ .name = "filter", .kind = .choice, .desc = "Watch status. Default all.", .choices = &library_filters },
            .{ .name = "kind", .kind = .choice, .desc = "Kind of title. Default all.", .choices = &library_kinds },
            .{ .name = "sort", .kind = .choice, .desc = "Order. Default smart (what to watch next first).", .choices = &library_sorts },
            .{ .name = "offset", .kind = .integer, .desc = "Skip this many items.", .min = 0, .max = 100000 },
            .{ .name = "limit", .kind = .integer, .desc = "Items to return, 1-200. Default 48.", .min = 1, .max = 200 },
        },
    },
    .{ .name = "calendar_list", .summary = "Coming up: the next episode and air date of each tracked show, and whether the latest one is available to stream.", .tier = .read, .method = .GET, .path = "/calendar" },
    .{ .name = "collections_list", .summary = "The user's named collections (playlists) with item counts.", .tier = .read, .method = .GET, .path = "/collections" },
    .{ .name = "recommendations", .summary = "Personalised recommendations from the viewing history.", .tier = .read, .method = .GET, .path = "/recommendations" },

    // ── Playback ──
    .{
        .name = "search_play",
        .summary = "Play a result from the latest search. Use the generation and key exactly as search_results returned them; a stale generation is rejected.",
        .tier = .playback,
        .method = .POST,
        .path = "/unified_search/play",
        .params = &.{
            .{ .name = "generation", .kind = .integer, .desc = "Search generation from search_results.", .required = true, .min = 0, .max = 4294967295 },
            .{ .name = "key", .kind = .string, .desc = "Result key (hex) from search_results.", .required = true, .max_len = 16 },
        },
    },
    .{
        .name = "search_queue",
        .summary = "Add a result from the latest search to the queue.",
        .tier = .playback,
        .method = .POST,
        .path = "/unified_search/queue",
        .params = &.{
            .{ .name = "generation", .kind = .integer, .desc = "Search generation from search_results.", .required = true, .min = 0, .max = 4294967295 },
            .{ .name = "key", .kind = .string, .desc = "Result key (hex) from search_results.", .required = true, .max_len = 16 },
        },
    },
    .{ .name = "player_toggle", .summary = "Pause or resume the active player.", .tier = .playback, .method = .POST, .path = "/toggle" },
    .{
        .name = "player_seek",
        .summary = "Seek the active player to an absolute position.",
        .tier = .playback,
        .method = .POST,
        .path = "/player/action",
        .fixed = &.{.{ .key = "action", .value = "seek" }},
        .params = &.{.{ .name = "seconds", .kind = .number, .desc = "Position in seconds.", .required = true, .wire = "value", .min = 0, .max = 2592000 }},
    },
    .{
        .name = "player_speed",
        .summary = "Set playback speed.",
        .tier = .playback,
        .method = .POST,
        .path = "/player/action",
        .fixed = &.{.{ .key = "action", .value = "speed" }},
        .params = &.{.{ .name = "speed", .kind = .number, .desc = "Multiplier, 0.25 to 4.", .required = true, .wire = "value", .min = 0.25, .max = 4 }},
    },
    .{
        .name = "player_volume",
        .summary = "Set volume.",
        .tier = .playback,
        .method = .POST,
        .path = "/volume",
        .params = &.{.{ .name = "volume", .kind = .number, .desc = "Percent, 0 to 150.", .required = true, .wire = "v", .min = 0, .max = 150 }},
    },
    .{ .name = "player_next", .summary = "Skip to the next playlist item.", .tier = .playback, .method = .POST, .path = "/player/action", .fixed = &.{.{ .key = "action", .value = "playlist-next" }} },
    .{ .name = "player_previous", .summary = "Go back to the previous playlist item.", .tier = .playback, .method = .POST, .path = "/player/action", .fixed = &.{.{ .key = "action", .value = "playlist-previous" }} },
    .{ .name = "subtitles_search", .summary = "Search subtitles for the current video. Then call subtitles_download.", .tier = .playback, .method = .POST, .path = "/player/action", .fixed = &.{.{ .key = "action", .value = "subtitle-search" }} },
    .{
        .name = "subtitles_download",
        .summary = "Download and apply a subtitle found by subtitles_search.",
        .tier = .playback,
        .method = .POST,
        .path = "/player/action",
        .fixed = &.{.{ .key = "action", .value = "subtitle-download" }},
        .params = &.{.{ .name = "index", .kind = .integer, .desc = "Result index from the subtitle search.", .required = true, .wire = "value", .min = 0, .max = 14 }},
    },
    .{
        .name = "queue_action",
        .summary = "Act on the playback queue. play, remove, move-up and move-down need an index from queue_list.",
        .tier = .playback,
        .method = .POST,
        .path = "/queue/action",
        .params = &.{
            .{ .name = "action", .kind = .choice, .desc = "What to do.", .required = true, .choices = &queue_actions },
            .{ .name = "index", .kind = .integer, .desc = "Queue item index, for item actions.", .wire = "idx", .min = 0, .max = 9999 },
        },
    },

    // ── Persistent changes ──
    .{
        .name = "subtitles_generate",
        .summary = "Generate subtitles for the current video with the local speech model (slow, uses CPU).",
        .tier = .write,
        .method = .POST,
        .path = "/player/action",
        .fixed = &.{.{ .key = "action", .value = "subtitle-generate" }},
    },
    .{
        .name = "downloads_pause",
        .summary = "Pause a download. Pass the index and token from downloads_list.",
        .tier = .write,
        .method = .POST,
        .path = "/downloads/action",
        .fixed = &.{.{ .key = "action", .value = "pause" }},
        .params = &.{ idx_param, .{ .name = "token", .kind = .integer, .desc = "Token from downloads_list; guards against a changed list.", .required = true, .min = 0, .max = 4294967295 } },
    },
    .{
        .name = "downloads_resume",
        .summary = "Resume a paused download. Pass the index and token from downloads_list.",
        .tier = .write,
        .method = .POST,
        .path = "/downloads/action",
        .fixed = &.{.{ .key = "action", .value = "resume" }},
        .params = &.{ idx_param, .{ .name = "token", .kind = .integer, .desc = "Token from downloads_list; guards against a changed list.", .required = true, .min = 0, .max = 4294967295 } },
    },

    .{ .name = "wanted_list", .summary = "The wanted list: titles Opal keeps searching for and downloads automatically, with each item's status (wanted, downloading, fulfilled, paused), attempts and next check time.", .tier = .read, .method = .GET, .path = "/wanted" },
    .{
        .name = "wanted_add",
        .summary = "Add a movie or one episode to the wanted list. Opal searches the torrent sources on a backoff schedule (30 minutes, doubling to daily) and downloads the best release that fits the quality range, then marks it fulfilled. Qualities: 1=480p, 2=720p, 3=1080p, 4=2160p.",
        .tier = .write,
        .method = .POST,
        .path = "/wanted/add",
        .params = &.{
            .{ .name = "kind", .kind = .choice, .desc = "movie, or episode for a single TV episode.", .required = true, .choices = &wanted_kinds },
            .{ .name = "title", .kind = .string, .desc = "The title, e.g. \"The Matrix\" or \"Severance\".", .required = true, .max_len = 150 },
            .{ .name = "year", .kind = .integer, .desc = "Release year for movies; strongly recommended to avoid sequels and remakes.", .min = 1888, .max = 2200 },
            .{ .name = "season", .kind = .integer, .desc = "Season number (episodes).", .min = 1, .max = 999 },
            .{ .name = "episode", .kind = .integer, .desc = "Episode number (episodes).", .min = 1, .max = 9999 },
            .{ .name = "min_quality", .kind = .integer, .desc = "Lowest acceptable quality, 1-4. Default 2.", .min = 1, .max = 4 },
            .{ .name = "prefer_quality", .kind = .integer, .desc = "Quality to aim for, within min and max. Default 3.", .min = 1, .max = 4 },
            .{ .name = "max_quality", .kind = .integer, .desc = "Highest acceptable quality, 1-4. Default 4.", .min = 1, .max = 4 },
        },
    },
    .{
        .name = "wanted_follow",
        .summary = "Turn on or off automatic downloads of the newest aired episode of every tracked TV show. Only the newest episode per show is queued, never the back catalogue.",
        .tier = .write,
        .method = .POST,
        .path = "/wanted/follow",
        .params = &.{.{ .name = "enabled", .kind = .boolean, .desc = "true to follow tracked shows, false to stop.", .required = true }},
    },
    .{ .name = "wanted_pause", .summary = "Stop searching for a wanted item until it is resumed.", .tier = .write, .method = .POST, .path = "/wanted/pause", .params = &.{wanted_id} },
    .{ .name = "wanted_resume", .summary = "Resume a paused wanted item, or re-arm one whose download was removed so it searches again.", .tier = .write, .method = .POST, .path = "/wanted/resume", .params = &.{wanted_id} },
    .{ .name = "wanted_remove", .summary = "Remove an item from the wanted list. Files already downloaded are kept.", .tier = .write, .method = .POST, .path = "/wanted/remove", .params = &.{wanted_id} },

    // ── Spends bandwidth, disk or compute ──
    .{
        .name = "play_url",
        .summary = "Open an http(s) URL or magnet link in the player. A magnet starts a torrent download. Local file paths are refused.",
        .tier = .spend,
        .method = .POST,
        .path = "/load",
        .params = &.{.{ .name = "url", .kind = .string, .desc = "http(s) URL or magnet link.", .required = true, .max_len = 2048, .url = true }},
    },
    .{
        .name = "downloads_add_url",
        .summary = "Download an http(s) URL into the download folder.",
        .tier = .spend,
        .method = .POST,
        .path = "/download/url",
        .params = &.{.{ .name = "url", .kind = .string, .desc = "http(s) URL of the file.", .required = true, .max_len = 2048, .url = true }},
    },

    .{ .name = "wanted_check", .summary = "Search for a wanted item right now instead of waiting for its schedule. If a release fits, it starts downloading.", .tier = .spend, .method = .POST, .path = "/wanted/check", .params = &.{wanted_id} },

    // ── Destructive: policy opt-in AND confirm:true ──
    .{ .name = "queue_clear", .summary = "Empty the playback queue.", .tier = .destructive, .method = .POST, .path = "/queue/action", .fixed = &.{ .{ .key = "action", .value = "clear" }, .{ .key = "confirm", .value = "1" } } },
    .{
        .name = "downloads_cancel",
        .summary = "Cancel a download and discard its partial data. Pass the index and token from downloads_list.",
        .tier = .destructive,
        .method = .POST,
        .path = "/downloads/action",
        .fixed = &.{ .{ .key = "action", .value = "cancel" }, .{ .key = "confirm", .value = "1" } },
        .params = &.{ idx_param, .{ .name = "token", .kind = .integer, .desc = "Token from downloads_list; guards against a changed list.", .required = true, .min = 0, .max = 4294967295 } },
    },
};

/// Read-only state exposed as MCP resources (subscribe-friendly snapshots).
pub const Resource = struct { uri: []const u8, name: []const u8, desc: []const u8, path: []const u8 };

pub const resources = [_]Resource{
    .{ .uri = "opal://status", .name = "Now playing", .desc = "Current playback state.", .path = "/status" },
    .{ .uri = "opal://queue", .name = "Queue", .desc = "The playback queue.", .path = "/queue" },
    .{ .uri = "opal://downloads", .name = "Downloads", .desc = "Active and finished downloads.", .path = "/downloads" },
    .{ .uri = "opal://history", .name = "Watch history", .desc = "Recently watched items.", .path = "/history" },
    .{ .uri = "opal://wanted", .name = "Wanted list", .desc = "What Opal is searching for and downloading automatically.", .path = "/wanted" },
};

pub fn findOp(name: []const u8) ?*const Op {
    for (&ops) |*op| {
        if (std.mem.eql(u8, op.name, name)) return op;
    }
    return null;
}

// ── Argument validation and request building ────────────────────────────

pub const ArgError = error{ MissingArgument, InvalidArgument, UnknownArgument };

/// Human-readable reason for a rejected call, returned to the agent.
pub const Diag = struct {
    buf: [160]u8 = undefined,
    len: usize = 0,

    fn set(self: *Diag, comptime fmt: []const u8, args: anytype) void {
        const out = std.fmt.bufPrint(&self.buf, fmt, args) catch {
            self.len = self.buf.len;
            return;
        };
        self.len = out.len;
    }

    pub fn message(self: *const Diag) []const u8 {
        return self.buf[0..self.len];
    }
};

pub fn isSafeUrl(s: []const u8) bool {
    if (s.len == 0) return false;
    const ok_scheme = std.ascii.startsWithIgnoreCase(s, "https://") or
        std.ascii.startsWithIgnoreCase(s, "http://") or
        std.ascii.startsWithIgnoreCase(s, "magnet:?");
    if (!ok_scheme) return false;
    for (s) |ch| if (ch <= 0x20 or ch == 0x7f) return false;
    return true;
}

fn percentEncode(w: *Writer, s: []const u8) Writer.Error!void {
    const hex = "0123456789ABCDEF";
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try w.writeByte(ch);
        } else {
            try w.writeAll(&.{ '%', hex[ch >> 4], hex[ch & 0x0f] });
        }
    }
}

fn argValue(args: ?std.json.ObjectMap, name: []const u8) ?std.json.Value {
    const map = args orelse return null;
    const v = map.get(name) orelse return null;
    return if (v == .null) null else v;
}

/// Validate `args` against `op.params`. Unknown arguments are rejected (an
/// agent that invents a parameter is told so instead of being silently
/// ignored); `confirm` is allowed only on destructive operations.
pub fn validate(op: *const Op, args: ?std.json.ObjectMap, diag: *Diag) ArgError!void {
    if (args) |map| {
        var it = map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (op.tier == .destructive and std.mem.eql(u8, key, "confirm")) continue;
            var known = false;
            for (op.params) |p| {
                if (std.mem.eql(u8, p.name, key)) known = true;
            }
            if (!known) {
                diag.set("unknown argument '{s}' for {s}", .{ key, op.name });
                return error.UnknownArgument;
            }
        }
    }
    for (op.params) |p| {
        const v = argValue(args, p.name) orelse {
            if (p.required) {
                diag.set("missing required argument '{s}'", .{p.name});
                return error.MissingArgument;
            }
            continue;
        };
        switch (p.kind) {
            .string, .choice => {
                if (v != .string) {
                    diag.set("'{s}' must be a string", .{p.name});
                    return error.InvalidArgument;
                }
                if (v.string.len == 0 and p.required) {
                    diag.set("'{s}' must not be empty", .{p.name});
                    return error.InvalidArgument;
                }
                if (v.string.len > p.max_len) {
                    diag.set("'{s}' is longer than {d} bytes", .{ p.name, p.max_len });
                    return error.InvalidArgument;
                }
                if (p.kind == .choice) {
                    var found = false;
                    for (p.choices) |c| {
                        if (std.mem.eql(u8, c, v.string)) found = true;
                    }
                    if (!found) {
                        diag.set("'{s}' is not an allowed value", .{p.name});
                        return error.InvalidArgument;
                    }
                }
                if (p.url and !isSafeUrl(v.string)) {
                    diag.set("'{s}' must be an http(s) URL or magnet link", .{p.name});
                    return error.InvalidArgument;
                }
                for (v.string) |ch| {
                    if (ch < 0x20 or ch == 0x7f) {
                        diag.set("'{s}' contains control characters", .{p.name});
                        return error.InvalidArgument;
                    }
                }
            },
            .integer, .number => {
                const n: f64 = switch (v) {
                    .integer => |i| @floatFromInt(i),
                    .float => |f| if (p.kind == .number and std.math.isFinite(f)) f else {
                        diag.set("'{s}' must be an integer", .{p.name});
                        return error.InvalidArgument;
                    },
                    else => {
                        diag.set("'{s}' must be a number", .{p.name});
                        return error.InvalidArgument;
                    },
                };
                if (n < p.min or n > p.max) {
                    diag.set("'{s}' is out of range", .{p.name});
                    return error.InvalidArgument;
                }
            },
            .boolean => if (v != .bool) {
                diag.set("'{s}' must be true or false", .{p.name});
                return error.InvalidArgument;
            },
        }
    }
}

/// True when a destructive call carries `confirm: true`.
pub fn hasConfirm(args: ?std.json.ObjectMap) bool {
    const v = argValue(args, "confirm") orelse return false;
    return v == .bool and v.bool;
}

/// Write the request target (`/api/path?k=v&...`) for a validated call.
pub fn writeTarget(op: *const Op, args: ?std.json.ObjectMap, w: *Writer) Writer.Error!void {
    try w.writeAll("/api");
    try w.writeAll(op.path);
    var first = true;
    for (op.fixed) |f| {
        try w.writeByte(if (first) '?' else '&');
        first = false;
        try w.writeAll(f.key);
        try w.writeByte('=');
        try percentEncode(w, f.value);
    }
    for (op.params) |p| {
        const v = argValue(args, p.name) orelse continue;
        try w.writeByte(if (first) '?' else '&');
        first = false;
        try w.writeAll(p.key());
        try w.writeByte('=');
        switch (v) {
            .string => |s| try percentEncode(w, s),
            .integer => |i| try w.print("{d}", .{i}),
            .float => |f| try w.print("{d}", .{f}),
            .bool => |b| try w.writeAll(if (b) "1" else "0"),
            else => {},
        }
    }
}

// ── MCP tool descriptors ────────────────────────────────────────────────

fn kindName(k: Kind) []const u8 {
    return switch (k) {
        .string, .choice => "string",
        .integer => "integer",
        .number => "number",
        .boolean => "boolean",
    };
}

fn writeBoundNumber(s: *std.json.Stringify, n: f64) !void {
    if (n == @trunc(n) and @abs(n) < 1e15) {
        try s.write(@as(i64, @intFromFloat(n)));
    } else {
        try s.write(n);
    }
}

fn writeTool(s: *std.json.Stringify, op: *const Op) !void {
    try s.beginObject();
    try s.objectField("name");
    try s.write(op.name);
    try s.objectField("description");
    var desc_buf: [1024]u8 = undefined;
    const tier_note = switch (op.tier) {
        .read => "",
        .destructive => " [destructive: requires confirm=true]",
        else => " [changes state]",
    };
    try s.write(std.fmt.bufPrint(&desc_buf, "{s}{s}", .{ op.summary, tier_note }) catch op.summary);

    try s.objectField("inputSchema");
    try s.beginObject();
    try s.objectField("type");
    try s.write("object");
    try s.objectField("properties");
    try s.beginObject();
    for (op.params) |p| {
        try s.objectField(p.name);
        try s.beginObject();
        try s.objectField("type");
        try s.write(kindName(p.kind));
        try s.objectField("description");
        try s.write(p.desc);
        if (p.kind == .choice) {
            try s.objectField("enum");
            try s.write(p.choices);
        }
        if (p.kind == .integer or p.kind == .number) {
            if (std.math.isFinite(p.min)) {
                try s.objectField("minimum");
                try writeBoundNumber(s, p.min);
            }
            if (std.math.isFinite(p.max)) {
                try s.objectField("maximum");
                try writeBoundNumber(s, p.max);
            }
        }
        if (p.kind == .string) {
            try s.objectField("maxLength");
            try s.write(p.max_len);
        }
        try s.endObject();
    }
    if (op.tier == .destructive) {
        try s.objectField("confirm");
        try s.beginObject();
        try s.objectField("type");
        try s.write("boolean");
        try s.objectField("description");
        try s.write("Must be true. Confirms the user wants this data removed.");
        try s.endObject();
    }
    try s.endObject();
    try s.objectField("required");
    try s.beginArray();
    for (op.params) |p| if (p.required) try s.write(p.name);
    if (op.tier == .destructive) try s.write("confirm");
    try s.endArray();
    try s.objectField("additionalProperties");
    try s.write(false);
    try s.endObject();

    try s.objectField("annotations");
    try s.beginObject();
    try s.objectField("title");
    try s.write(op.name);
    try s.objectField("readOnlyHint");
    try s.write(op.tier == .read);
    try s.objectField("destructiveHint");
    try s.write(op.tier == .destructive);
    try s.objectField("openWorldHint");
    try s.write(op.tier == .spend or std.mem.eql(u8, op.name, "search"));
    try s.endObject();
    try s.endObject();
}

// ── JSON-RPC / MCP server ───────────────────────────────────────────────

pub const protocol_version = "2025-06-18";
pub const server_name = "opal";

pub const Response = struct { status: u16, body: []const u8 };

/// Reaches a running Opal. `body` is allocated from `a`.
pub const Caller = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, a: Allocator, method: Method, target: []const u8) anyerror!Response,
};

pub const Outcome = enum { ok, api_error, unreachable_, rejected, blocked };

pub const AuditEntry = struct {
    op: []const u8,
    tier: Tier,
    outcome: Outcome,
    /// Arguments as supplied (already sanitised by `writeAuditArgs`).
    args: ?std.json.ObjectMap,
};

pub const AuditSink = struct {
    ctx: *anyopaque,
    record: *const fn (ctx: *anyopaque, entry: AuditEntry) void,
};

pub const Server = struct {
    policy: Policy = .{},
    caller: Caller,
    audit: ?AuditSink = null,
    version: []const u8 = "0",

    /// Handle one newline-delimited JSON-RPC message, writing zero or one
    /// response line to `out` (none for notifications).
    pub fn handleLine(self: *Server, a: Allocator, line: []const u8, out: *Writer) !void {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return;
        var parsed = std.json.parseFromSlice(std.json.Value, a, trimmed, .{}) catch {
            return writeError(out, null, -32700, "parse error");
        };
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return writeError(out, null, -32600, "request must be an object");
        const id = root.object.get("id");
        const method_v = root.object.get("method") orelse return; // a response; we send no requests
        if (method_v != .string) return writeError(out, id, -32600, "method must be a string");
        const method = method_v.string;
        const params: ?std.json.ObjectMap = if (root.object.get("params")) |p| (if (p == .object) p.object else null) else null;

        // Notifications carry no id and never get a reply.
        if (id == null) return;

        if (std.mem.eql(u8, method, "initialize")) return self.initialize(id, params, out);
        if (std.mem.eql(u8, method, "ping")) return writeResult(out, id, "{}");
        if (std.mem.eql(u8, method, "tools/list")) return listTools(a, id, out);
        if (std.mem.eql(u8, method, "tools/call")) return self.callTool(a, id, params, out);
        if (std.mem.eql(u8, method, "resources/list")) return listResources(a, id, out);
        if (std.mem.eql(u8, method, "resources/read")) return self.readResource(a, id, params, out);
        if (std.mem.eql(u8, method, "prompts/list")) return writeResult(out, id, "{\"prompts\":[]}");
        return writeError(out, id, -32601, "method not found");
    }

    fn initialize(self: *Server, id: ?std.json.Value, params: ?std.json.ObjectMap, out: *Writer) !void {
        // Echo a protocol version the client offered when we know it; the
        // methods used here are stable across all of them.
        var version: []const u8 = protocol_version;
        if (params) |p| if (p.get("protocolVersion")) |v| if (v == .string) {
            const known = [_][]const u8{ "2024-11-05", "2025-03-26", "2025-06-18" };
            for (known) |k| if (std.mem.eql(u8, k, v.string)) {
                version = k;
            };
        };
        try beginResult(out, id);
        var s = std.json.Stringify{ .writer = out };
        try s.beginObject();
        try s.objectField("protocolVersion");
        try s.write(version);
        try s.objectField("capabilities");
        try s.beginObject();
        try s.objectField("tools");
        try s.beginObject();
        try s.endObject();
        try s.objectField("resources");
        try s.beginObject();
        try s.endObject();
        try s.endObject();
        try s.objectField("serverInfo");
        try s.beginObject();
        try s.objectField("name");
        try s.write(server_name);
        try s.objectField("version");
        try s.write(self.version);
        try s.endObject();
        try s.objectField("instructions");
        try s.write(
            "Opal is a media player and library. To watch something: search, poll search_results until " ++
                "loading is false, then search_play with the response generation and a result key. Prefer these tools " ++
                "over guessing URLs. Tools above the permission ceiling or marked destructive are refused " ++
                "unless the user enabled them.",
        );
        try s.endObject();
        try endResult(out);
    }

    fn callTool(self: *Server, a: Allocator, id: ?std.json.Value, params: ?std.json.ObjectMap, out: *Writer) !void {
        const p = params orelse return writeError(out, id, -32602, "missing params");
        const name_v = p.get("name") orelse return writeError(out, id, -32602, "missing tool name");
        if (name_v != .string) return writeError(out, id, -32602, "tool name must be a string");
        const op = findOp(name_v.string) orelse return writeError(out, id, -32602, "unknown tool");
        const args: ?std.json.ObjectMap = if (p.get("arguments")) |v| (if (v == .object) v.object else null) else null;

        var diag = Diag{};
        validate(op, args, &diag) catch {
            self.record(op, .rejected, args);
            return writeToolText(out, id, diag.message(), true);
        };
        switch (check(self.policy, op, hasConfirm(args))) {
            .allow => {},
            .tier_blocked => {
                self.record(op, .blocked, args);
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "{s} is a '{s}' operation, which the current policy does not allow. Ask the user to enable it (opal-mcp --allow {s}).", .{ op.name, op.tier.id(), if (op.tier == .destructive) "destructive" else op.tier.id() }) catch "blocked by policy";
                return writeToolText(out, id, msg, true);
            },
            .needs_confirm => {
                self.record(op, .blocked, args);
                return writeToolText(out, id, "this is destructive: pass confirm=true only after the user has explicitly agreed", true);
            },
        }

        var target_buf: [4096]u8 = undefined;
        var tw = Writer.fixed(&target_buf);
        writeTarget(op, args, &tw) catch {
            self.record(op, .rejected, args);
            return writeToolText(out, id, "request too large", true);
        };
        const resp = self.caller.call(self.caller.ctx, a, op.method, tw.buffered()) catch {
            self.record(op, .unreachable_, args);
            return writeToolText(out, id, "Opal is not reachable. Start Opal (windowed, or headless with OPAL_HEADLESS=1) and retry.", true);
        };
        defer a.free(resp.body);
        const failed = resp.status >= 400;
        self.record(op, if (failed) .api_error else .ok, args);
        return writeToolText(out, id, resp.body, failed);
    }

    fn readResource(self: *Server, a: Allocator, id: ?std.json.Value, params: ?std.json.ObjectMap, out: *Writer) !void {
        const p = params orelse return writeError(out, id, -32602, "missing params");
        const uri_v = p.get("uri") orelse return writeError(out, id, -32602, "missing uri");
        if (uri_v != .string) return writeError(out, id, -32602, "uri must be a string");
        for (resources) |r| {
            if (!std.mem.eql(u8, r.uri, uri_v.string)) continue;
            var target_buf: [128]u8 = undefined;
            const target = std.fmt.bufPrint(&target_buf, "/api{s}", .{r.path}) catch unreachable;
            const resp = self.caller.call(self.caller.ctx, a, .GET, target) catch {
                return writeError(out, id, -32002, "Opal is not reachable");
            };
            defer a.free(resp.body);
            if (resp.status >= 400) return writeError(out, id, -32002, "Opal returned an error");
            try beginResult(out, id);
            var s = std.json.Stringify{ .writer = out };
            try s.beginObject();
            try s.objectField("contents");
            try s.beginArray();
            try s.beginObject();
            try s.objectField("uri");
            try s.write(r.uri);
            try s.objectField("mimeType");
            try s.write("application/json");
            try s.objectField("text");
            try s.write(resp.body);
            try s.endObject();
            try s.endArray();
            try s.endObject();
            return endResult(out);
        }
        return writeError(out, id, -32002, "unknown resource");
    }

    fn record(self: *Server, op: *const Op, outcome: Outcome, args: ?std.json.ObjectMap) void {
        if (self.audit) |sink| sink.record(sink.ctx, .{ .op = op.name, .tier = op.tier, .outcome = outcome, .args = args });
    }
};

fn listTools(a: Allocator, id: ?std.json.Value, out: *Writer) !void {
    _ = a;
    try beginResult(out, id);
    var s = std.json.Stringify{ .writer = out };
    try s.beginObject();
    try s.objectField("tools");
    try s.beginArray();
    for (&ops) |*op| try writeTool(&s, op);
    try s.endArray();
    try s.endObject();
    try endResult(out);
}

fn listResources(a: Allocator, id: ?std.json.Value, out: *Writer) !void {
    _ = a;
    try beginResult(out, id);
    var s = std.json.Stringify{ .writer = out };
    try s.beginObject();
    try s.objectField("resources");
    try s.beginArray();
    for (resources) |r| {
        try s.beginObject();
        try s.objectField("uri");
        try s.write(r.uri);
        try s.objectField("name");
        try s.write(r.name);
        try s.objectField("description");
        try s.write(r.desc);
        try s.objectField("mimeType");
        try s.write("application/json");
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    try endResult(out);
}

fn writeId(out: *Writer, id: ?std.json.Value) !void {
    if (id) |v| {
        var s = std.json.Stringify{ .writer = out };
        try s.write(v);
    } else {
        try out.writeAll("null");
    }
}

fn beginResult(out: *Writer, id: ?std.json.Value) !void {
    try out.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(out, id);
    try out.writeAll(",\"result\":");
}

fn endResult(out: *Writer) !void {
    try out.writeAll("}\n");
}

fn writeResult(out: *Writer, id: ?std.json.Value, result_json: []const u8) !void {
    try beginResult(out, id);
    try out.writeAll(result_json);
    try endResult(out);
}

fn writeError(out: *Writer, id: ?std.json.Value, code: i32, message: []const u8) !void {
    try out.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(out, id);
    try out.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    var s = std.json.Stringify{ .writer = out };
    try s.write(message);
    try out.writeAll("}}\n");
}

fn writeToolText(out: *Writer, id: ?std.json.Value, text: []const u8, is_error: bool) !void {
    try beginResult(out, id);
    var s = std.json.Stringify{ .writer = out };
    try s.beginObject();
    try s.objectField("content");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("type");
    try s.write("text");
    try s.objectField("text");
    try s.write(text);
    try s.endObject();
    try s.endArray();
    try s.objectField("isError");
    try s.write(is_error);
    try s.endObject();
    try endResult(out);
}

// ── Audit ───────────────────────────────────────────────────────────────

/// One JSON line: time, operation, tier, outcome and sanitised arguments.
/// URLs lose their query/fragment (it can carry credentials) and any string is
/// truncated, so the log records what was asked without storing secrets.
pub fn writeAuditLine(w: *Writer, ts_ms: i64, entry: AuditEntry) !void {
    var s = std.json.Stringify{ .writer = w };
    try s.beginObject();
    try s.objectField("ts");
    try s.write(ts_ms);
    try s.objectField("op");
    try s.write(entry.op);
    try s.objectField("tier");
    try s.write(entry.tier.id());
    try s.objectField("outcome");
    try s.write(@tagName(entry.outcome));
    try s.objectField("args");
    try s.beginObject();
    if (entry.args) |map| {
        var it = map.iterator();
        while (it.next()) |kv| {
            try s.objectField(kv.key_ptr.*);
            switch (kv.value_ptr.*) {
                .string => |str| try s.write(sanitizeArg(str)),
                .integer, .float, .bool => try s.write(kv.value_ptr.*),
                else => try s.write("?"),
            }
        }
    }
    try s.endObject();
    try s.endObject();
    try w.writeByte('\n');
}

fn sanitizeArg(str: []const u8) []const u8 {
    var end = str.len;
    if (!std.ascii.startsWithIgnoreCase(str, "magnet:")) {
        if (std.mem.indexOfAny(u8, str, "?#")) |i| end = i;
    }
    return str[0..@min(end, 200)];
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

fn parseArgs(a: Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, json, .{});
}

test "every op name is a valid MCP tool name and unique" {
    for (ops, 0..) |op, i| {
        try testing.expect(op.name.len > 0 and op.name.len <= 64);
        for (op.name) |ch| try testing.expect(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_');
        for (ops[i + 1 ..]) |other| try testing.expect(!std.mem.eql(u8, op.name, other.name));
    }
}

test "destructive ops pass confirm=1 to the API and are never read-tier" {
    for (ops) |op| {
        const has_confirm = for (op.fixed) |f| {
            if (std.mem.eql(u8, f.key, "confirm")) break true;
        } else false;
        if (op.tier == .destructive) try testing.expect(has_confirm);
        if (has_confirm) try testing.expect(op.tier == .destructive);
    }
}

test "policy: default allows spend, blocks destructive until opted in and confirmed" {
    const p = Policy{};
    try testing.expectEqual(Verdict.allow, check(p, findOp("status").?, false));
    try testing.expectEqual(Verdict.allow, check(p, findOp("play_url").?, false));
    try testing.expectEqual(Verdict.tier_blocked, check(p, findOp("downloads_cancel").?, true));
    const opted = Policy{ .allow_destructive = true };
    try testing.expectEqual(Verdict.needs_confirm, check(opted, findOp("downloads_cancel").?, false));
    try testing.expectEqual(Verdict.allow, check(opted, findOp("downloads_cancel").?, true));
    const ro = Policy{ .max_tier = .read };
    try testing.expectEqual(Verdict.tier_blocked, check(ro, findOp("player_toggle").?, false));
    try testing.expectEqual(Verdict.allow, check(ro, findOp("queue_list").?, false));
}

test "url guard accepts http(s) and magnet, refuses paths and schemes" {
    try testing.expect(isSafeUrl("https://example.com/a.mkv"));
    try testing.expect(isSafeUrl("magnet:?xt=urn:btih:abc"));
    try testing.expect(!isSafeUrl("/etc/passwd"));
    try testing.expect(!isSafeUrl("file:///etc/passwd"));
    try testing.expect(!isSafeUrl("https://x.com/a b"));
    try testing.expect(!isSafeUrl(""));
}

test "validate rejects missing, unknown, mistyped and out-of-range arguments" {
    const a = testing.allocator;
    var diag = Diag{};
    const seek = findOp("player_seek").?;

    var p1 = try parseArgs(a, "{}");
    defer p1.deinit();
    try testing.expectError(error.MissingArgument, validate(seek, p1.value.object, &diag));

    var p2 = try parseArgs(a, "{\"seconds\":10,\"extra\":1}");
    defer p2.deinit();
    try testing.expectError(error.UnknownArgument, validate(seek, p2.value.object, &diag));

    var p3 = try parseArgs(a, "{\"seconds\":\"10\"}");
    defer p3.deinit();
    try testing.expectError(error.InvalidArgument, validate(seek, p3.value.object, &diag));

    var p4 = try parseArgs(a, "{\"seconds\":-1}");
    defer p4.deinit();
    try testing.expectError(error.InvalidArgument, validate(seek, p4.value.object, &diag));

    var p5 = try parseArgs(a, "{\"seconds\":12.5}");
    defer p5.deinit();
    try validate(seek, p5.value.object, &diag);

    // integers reject fractions
    const dl = findOp("downloads_pause").?;
    var p6 = try parseArgs(a, "{\"index\":1.5,\"token\":3}");
    defer p6.deinit();
    try testing.expectError(error.InvalidArgument, validate(dl, p6.value.object, &diag));

    // url ops refuse local paths
    var p7 = try parseArgs(a, "{\"url\":\"/home/me/secret.mkv\"}");
    defer p7.deinit();
    try testing.expectError(error.InvalidArgument, validate(findOp("play_url").?, p7.value.object, &diag));

    // choice
    var p8 = try parseArgs(a, "{\"action\":\"rm -rf\"}");
    defer p8.deinit();
    try testing.expectError(error.InvalidArgument, validate(findOp("queue_action").?, p8.value.object, &diag));
}

test "wanted_add maps to the wanted route and validates ranges" {
    const a = testing.allocator;
    var buf: [512]u8 = undefined;
    var diag = Diag{};
    const op = findOp("wanted_add").?;

    var ok = try parseArgs(a, "{\"kind\":\"movie\",\"title\":\"The Matrix\",\"year\":1999,\"min_quality\":2}");
    defer ok.deinit();
    try validate(op, ok.value.object, &diag);
    var w = Writer.fixed(&buf);
    try writeTarget(op, ok.value.object, &w);
    try testing.expectEqualStrings("/api/wanted/add?kind=movie&title=The%20Matrix&year=1999&min_quality=2", w.buffered());

    var bad_kind = try parseArgs(a, "{\"kind\":\"album\",\"title\":\"x\"}");
    defer bad_kind.deinit();
    try testing.expectError(error.InvalidArgument, validate(op, bad_kind.value.object, &diag));

    var bad_q = try parseArgs(a, "{\"kind\":\"movie\",\"title\":\"x\",\"max_quality\":9}");
    defer bad_q.deinit();
    try testing.expectError(error.InvalidArgument, validate(op, bad_q.value.object, &diag));

    try testing.expectEqual(Tier.write, op.tier);
    try testing.expectEqual(Tier.spend, findOp("wanted_check").?.tier);
}

test "writeTarget maps wire names, fixed pairs and percent-encodes" {
    const a = testing.allocator;
    var buf: [512]u8 = undefined;

    var w = Writer.fixed(&buf);
    var p1 = try parseArgs(a, "{\"query\":\"the matrix & more\"}");
    defer p1.deinit();
    try writeTarget(findOp("search").?, p1.value.object, &w);
    try testing.expectEqualStrings("/api/unified_search?q=the%20matrix%20%26%20more", w.buffered());

    var w2 = Writer.fixed(&buf);
    var p2 = try parseArgs(a, "{\"seconds\":90}");
    defer p2.deinit();
    try writeTarget(findOp("player_seek").?, p2.value.object, &w2);
    try testing.expectEqualStrings("/api/player/action?action=seek&value=90", w2.buffered());

    var w3 = Writer.fixed(&buf);
    var p3 = try parseArgs(a, "{\"index\":2,\"token\":77,\"confirm\":true}");
    defer p3.deinit();
    try writeTarget(findOp("downloads_cancel").?, p3.value.object, &w3);
    try testing.expectEqualStrings("/api/downloads/action?action=cancel&confirm=1&idx=2&token=77", w3.buffered());

    var w4 = Writer.fixed(&buf);
    try writeTarget(findOp("status").?, null, &w4);
    try testing.expectEqualStrings("/api/status", w4.buffered());
}

const FakeApi = struct {
    status: u16 = 200,
    body: []const u8 = "{\"ok\":true}",
    fail: bool = false,
    last_target: [256]u8 = undefined,
    last_len: usize = 0,
    calls: usize = 0,

    fn call(ctx: *anyopaque, a: Allocator, method: Method, tgt: []const u8) anyerror!Response {
        const self: *FakeApi = @ptrCast(@alignCast(ctx));
        _ = method;
        self.calls += 1;
        if (self.fail) return error.ConnectionRefused;
        self.last_len = @min(tgt.len, self.last_target.len);
        @memcpy(self.last_target[0..self.last_len], tgt[0..self.last_len]);
        return .{ .status = self.status, .body = try a.dupe(u8, self.body) };
    }

    fn caller(self: *FakeApi) Caller {
        return .{ .ctx = self, .call = call };
    }

    fn lastTarget(self: *const FakeApi) []const u8 {
        return self.last_target[0..self.last_len];
    }
};

fn rpc(server: *Server, line: []const u8, buf: []u8) ![]const u8 {
    var w = Writer.fixed(buf);
    try server.handleLine(testing.allocator, line, &w);
    return w.buffered();
}

test "initialize negotiates a known version and advertises tools and resources" {
    var api = FakeApi{};
    var server = Server{ .caller = api.caller() };
    var buf: [2048]u8 = undefined;
    const out = try rpc(&server, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\"}}", &buf);
    try testing.expect(std.mem.indexOf(u8, out, "\"protocolVersion\":\"2024-11-05\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"tools\":{}") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"resources\":{}") != null);
    try testing.expect(std.mem.endsWith(u8, out, "\n"));
}

test "notifications get no reply" {
    var api = FakeApi{};
    var server = Server{ .caller = api.caller() };
    var buf: [256]u8 = undefined;
    const out = try rpc(&server, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}", &buf);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "tools/list emits a schema for every op and parses as JSON" {
    var api = FakeApi{};
    var server = Server{ .caller = api.caller() };
    const buf = try testing.allocator.alloc(u8, 64 * 1024);
    defer testing.allocator.free(buf);
    const out = try rpc(&server, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}", buf);
    var parsed = try parseArgs(testing.allocator, out);
    defer parsed.deinit();
    const tools = parsed.value.object.get("result").?.object.get("tools").?.array;
    try testing.expectEqual(ops.len, tools.items.len);
    for (tools.items) |t| {
        const schema = t.object.get("inputSchema").?.object;
        try testing.expectEqualStrings("object", schema.get("type").?.string);
        try testing.expect(schema.get("required") != null);
        try testing.expect(t.object.get("annotations").?.object.get("readOnlyHint") != null);
    }
}

test "tools/call routes to the API with the validated target" {
    var api = FakeApi{ .body = "{\"results\":[]}" };
    var server = Server{ .caller = api.caller() };
    var buf: [1024]u8 = undefined;
    const out = try rpc(&server, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"search\",\"arguments\":{\"query\":\"dune\"}}}", &buf);
    try testing.expectEqualStrings("/api/unified_search?q=dune", api.lastTarget());
    try testing.expect(std.mem.indexOf(u8, out, "\"isError\":false") != null);
    try testing.expect(std.mem.indexOf(u8, out, "results") != null);
}

test "tools/call refuses bad arguments without touching the API" {
    var api = FakeApi{};
    var server = Server{ .caller = api.caller() };
    var buf: [1024]u8 = undefined;
    const out = try rpc(&server, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"play_url\",\"arguments\":{\"url\":\"/etc/shadow\"}}}", &buf);
    try testing.expectEqual(@as(usize, 0), api.calls);
    try testing.expect(std.mem.indexOf(u8, out, "\"isError\":true") != null);
}

test "destructive tools are blocked by default and need confirm when opted in" {
    var api = FakeApi{};
    var server = Server{ .caller = api.caller() };
    var buf: [1024]u8 = undefined;
    const line = "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"queue_clear\",\"arguments\":{\"confirm\":true}}}";
    var out = try rpc(&server, line, &buf);
    try testing.expectEqual(@as(usize, 0), api.calls);
    try testing.expect(std.mem.indexOf(u8, out, "does not allow") != null);

    server.policy.allow_destructive = true;
    out = try rpc(&server, "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"queue_clear\",\"arguments\":{\"confirm\":false}}}", &buf);
    try testing.expectEqual(@as(usize, 0), api.calls);
    try testing.expect(std.mem.indexOf(u8, out, "confirm=true") != null);

    out = try rpc(&server, line, &buf);
    try testing.expectEqual(@as(usize, 1), api.calls);
    try testing.expectEqualStrings("/api/queue/action?action=clear&confirm=1", api.lastTarget());
}

test "API errors and unreachable Opal become tool errors" {
    var api = FakeApi{ .status = 409, .body = "{\"error\":\"stale\"}" };
    var server = Server{ .caller = api.caller() };
    var buf: [1024]u8 = undefined;
    const line = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"search_play\",\"arguments\":{\"generation\":3,\"key\":\"ab12\"}}}";
    var out = try rpc(&server, line, &buf);
    try testing.expect(std.mem.indexOf(u8, out, "\"isError\":true") != null);
    try testing.expectEqualStrings("/api/unified_search/play?generation=3&key=ab12", api.lastTarget());

    api.fail = true;
    out = try rpc(&server, line, &buf);
    try testing.expect(std.mem.indexOf(u8, out, "not reachable") != null);
}

test "resources/read serves a snapshot and unknown uris error" {
    var api = FakeApi{ .body = "{\"playing\":false}" };
    var server = Server{ .caller = api.caller() };
    var buf: [1024]u8 = undefined;
    var out = try rpc(&server, "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"resources/read\",\"params\":{\"uri\":\"opal://status\"}}", &buf);
    try testing.expectEqualStrings("/api/status", api.lastTarget());
    try testing.expect(std.mem.indexOf(u8, out, "application/json") != null);
    out = try rpc(&server, "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"resources/read\",\"params\":{\"uri\":\"opal://secrets\"}}", &buf);
    try testing.expect(std.mem.indexOf(u8, out, "\"error\"") != null);
}

test "malformed input and unknown methods return JSON-RPC errors" {
    var api = FakeApi{};
    var server = Server{ .caller = api.caller() };
    var buf: [512]u8 = undefined;
    var out = try rpc(&server, "{not json", &buf);
    try testing.expect(std.mem.indexOf(u8, out, "-32700") != null);
    out = try rpc(&server, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"nope\"}", &buf);
    try testing.expect(std.mem.indexOf(u8, out, "-32601") != null);
}

test "audit line records the call and strips URL queries" {
    const a = testing.allocator;
    var parsed = try parseArgs(a, "{\"url\":\"https://x.com/f.mkv?token=SECRET\"}");
    defer parsed.deinit();
    var buf: [512]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeAuditLine(&w, 1700000000000, .{ .op = "downloads_add_url", .tier = .spend, .outcome = .ok, .args = parsed.value.object });
    const line = w.buffered();
    try testing.expect(std.mem.indexOf(u8, line, "\"op\":\"downloads_add_url\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"tier\":\"spend\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "SECRET") == null);
    try testing.expect(std.mem.indexOf(u8, line, "https://x.com/f.mkv") != null);
}
