//! UI-position restore across restarts — the pure decision layer.
//!
//! A restart (dev.sh rebuild, quit + relaunch) should land the user back where
//! they were, like a website hot reload: same page, same search text, same
//! Settings section, same TV detail, same scroll. `ui/ui_restore.zig` captures
//! the live state into a `Snapshot`, persists it with `encode`, and on launch
//! routes the stored text through `decode` + `plan`; every validation and
//! staleness rule lives here so the shipped logic is the tested logic.
//!
//! Policy (least surprising for real users):
//! - Always: the page (route + Browse source), the Settings section and the
//!   search text. Those are cheap, local, and match how browsers reopen tabs.
//! - Only when fresh (a dev.sh reload, or the snapshot is < STALE_SECS old):
//!   re-running the search, reopening the TV detail (network fetches) and the
//!   scroll offset. Yesterday's scroll position or detail page is noise.
//! - A stale Search page is not restored (it would show an empty result list);
//!   its query text still is.
//! - Never: the Player route (playback has its own resume prompt), or anything
//!   at all when the launch already has somewhere to go (file argument,
//!   something navigated first), during onboarding, or in incognito.
//!
//! No io_global / dvui / state imports: built as a standalone test target.

const std = @import("std");

pub const VERSION = "1";
/// Detail/scroll/search re-run expire after this many seconds without a dev
/// reload. Ten minutes covers a quick quit-and-relaunch or a crash.
pub const STALE_SECS: i64 = 10 * 60;
/// Upper bound for a stored scroll offset (layout units). Anything larger is a
/// corrupt value, not a real list.
pub const MAX_SCROLL: f32 = 1_000_000;
/// Free-text fields (search query, show name) are capped to this many bytes.
pub const MAX_TEXT: usize = 256;
/// Encoded snapshots never exceed this; the file/buffer can be sized to it.
pub const MAX_ENCODED: usize = 1024;

/// Routes that are never restored. `player` needs a live player; the resume
/// banner owns that path.
const NEVER_RESTORE = [_][]const u8{"player"};

/// Which retained scroll area a snapshot's offset belongs to.
pub const ScrollTarget = enum { none, search_results, tmdb_gallery, tv_episodes };

pub const Snapshot = struct {
    saved_at: i64 = 0,
    route: []const u8 = "",
    browse: []const u8 = "",
    settings: []const u8 = "",
    tv_id: i32 = 0,
    scroll_y: f32 = 0,
    tv_name: []const u8 = "",
    query: []const u8 = "",
};

/// The scroll area that is on screen for a route. Used for both capture and
/// restore so the offset is always re-applied to the list it was read from.
pub fn scrollTargetFor(route: []const u8, browse: []const u8, detail_open: bool) ScrollTarget {
    if (std.mem.eql(u8, route, "search")) return .search_results;
    if (std.mem.eql(u8, route, "browse") and std.mem.eql(u8, browse, "TMDB"))
        return if (detail_open) .tv_episodes else .tmdb_gallery;
    return .none;
}

/// A TMDB id worth asking the API about.
pub fn validTmdbId(id: i32) bool {
    return id > 0 and id < 100_000_000;
}

/// Finite, positive and in range — or null (nothing to restore).
pub fn validScroll(y: f32) ?f32 {
    if (!std.math.isFinite(y) or y <= 0 or y > MAX_SCROLL) return null;
    return y;
}

/// Copy `raw` into `out` with tabs/newlines/control bytes turned into spaces,
/// trimmed and capped to MAX_TEXT (and to `out.len`) on a UTF-8 boundary.
pub fn sanitizeText(raw: []const u8, out: []u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    var n = @min(trimmed.len, @min(MAX_TEXT, out.len));
    while (n > 0 and n < trimmed.len and (trimmed[n] & 0xC0) == 0x80) n -= 1;
    for (trimmed[0..n], 0..) |c, i| out[i] = if (c < 0x20 or c == 0x7f) ' ' else c;
    return std.mem.trimEnd(u8, out[0..n], " ");
}

/// Serialise as one tab-separated line:
/// `VERSION saved_at route browse settings tv_id scroll_y tv_name query`.
/// Free text goes last and is sanitised, so it can't break the framing.
/// Returns an empty slice if `buf` is too small.
pub fn encode(s: Snapshot, buf: []u8) []const u8 {
    var name_buf: [MAX_TEXT]u8 = undefined;
    var query_buf: [MAX_TEXT]u8 = undefined;
    const name = sanitizeText(s.tv_name, &name_buf);
    const query = sanitizeText(s.query, &query_buf);
    const y = validScroll(s.scroll_y) orelse 0;
    return std.fmt.bufPrint(buf, "{s}\t{d}\t{s}\t{s}\t{s}\t{d}\t{d:.1}\t{s}\t{s}", .{
        VERSION, s.saved_at, tagField(s.route), tagField(s.browse), tagField(s.settings), s.tv_id, y, name, query,
    }) catch "";
}

/// Enum tag names are identifiers; anything else is dropped rather than
/// written (keeps the framing intact even if a caller passes garbage).
fn tagField(tag: []const u8) []const u8 {
    if (tag.len > 32) return "";
    for (tag) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return "";
    return tag;
}

/// Parse an `encode`d line. Null on a version mismatch or malformed framing;
/// individual bad fields degrade to their defaults (validated later by plan).
/// Returned slices point into `raw`.
pub fn decode(raw_in: []const u8) ?Snapshot {
    const raw = std.mem.trimEnd(u8, raw_in, "\r\n");
    if (raw.len == 0 or raw.len > MAX_ENCODED) return null;
    var it = std.mem.splitScalar(u8, raw, '\t');
    if (!std.mem.eql(u8, it.next() orelse return null, VERSION)) return null;
    var s: Snapshot = .{};
    s.saved_at = std.fmt.parseInt(i64, it.next() orelse return null, 10) catch 0;
    s.route = tagField(it.next() orelse return null);
    s.browse = tagField(it.next() orelse return null);
    s.settings = tagField(it.next() orelse return null);
    s.tv_id = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch 0;
    s.scroll_y = validScroll(std.fmt.parseFloat(f32, it.next() orelse return null) catch 0) orelse 0;
    s.tv_name = it.next() orelse return null;
    // Query is the tail: a tab can't appear in it (sanitised on encode), but
    // take the remainder anyway so a hand-edited file degrades gracefully.
    s.query = it.rest();
    if (s.tv_name.len > MAX_TEXT) s.tv_name = s.tv_name[0..MAX_TEXT];
    if (s.query.len > MAX_TEXT) s.query = s.query[0..MAX_TEXT];
    return s;
}

/// Launch-time facts the caller gathers from live state.
pub const Env = struct {
    now: i64,
    /// dev.sh relaunch (OPAL_DEV_RELOAD=1): always treat as fresh.
    dev_reload: bool = false,
    /// Launched to open something (file/URL argument) — that wins.
    launched_with_target: bool = false,
    /// Something already navigated away from the cold-start Home page.
    already_navigated: bool = false,
    onboarding: bool = false,
    incognito: bool = false,
};

/// True when the expensive/volatile parts (search re-run, detail, scroll)
/// should come back too.
pub fn isFresh(saved_at: i64, env: Env) bool {
    if (env.dev_reload) return true;
    if (saved_at <= 0 or env.now < saved_at) return false; // unknown or clock went back
    return env.now - saved_at <= STALE_SECS;
}

pub fn Plan(comptime Route: type, comptime Browse: type, comptime Settings: type) type {
    return struct {
        route: ?Route = null,
        browse: ?Browse = null,
        settings: ?Settings = null,
        /// Search text to put back in the field (empty = leave it alone).
        query: []const u8 = "",
        /// Also run the search (only when restoring the Search page fresh).
        rerun_search: bool = false,
        /// TV detail to reopen (0 = none).
        tv_id: i32 = 0,
        tv_name: []const u8 = "",
        scroll_target: ScrollTarget = .none,
        scroll_y: f32 = 0,

        pub fn isEmpty(self: @This()) bool {
            return self.route == null and self.browse == null and self.settings == null and
                self.query.len == 0 and self.tv_id == 0 and self.scroll_target == .none;
        }
    };
}

/// Parse an enum tag, rejecting unknown or never-restored values.
pub fn parseTag(comptime E: type, tag: []const u8) ?E {
    if (tag.len == 0) return null;
    for (NEVER_RESTORE) |deny| if (std.mem.eql(u8, tag, deny)) return null;
    return std.meta.stringToEnum(E, tag);
}

/// Decide what to restore. `Route`/`Browse`/`Settings` are the app's enums
/// (router.Route, state.DrawerTab, state.SettingsTab); only their tag names
/// are inspected, so stale or renamed values just drop out.
pub fn plan(comptime Route: type, comptime Browse: type, comptime Settings: type, s: Snapshot, env: Env) Plan(Route, Browse, Settings) {
    var p: Plan(Route, Browse, Settings) = .{};
    if (env.launched_with_target or env.already_navigated or env.onboarding or env.incognito) return p;
    const fresh = isFresh(s.saved_at, env);

    p.settings = parseTag(Settings, s.settings);
    p.query = std.mem.trim(u8, s.query, " ");

    const route = parseTag(Route, s.route);
    const route_tag: []const u8 = if (route) |r| @tagName(r) else "";
    const is_search = std.mem.eql(u8, route_tag, "search");
    const is_browse = std.mem.eql(u8, route_tag, "browse");
    const is_home = std.mem.eql(u8, route_tag, "home");

    if (is_search and (!fresh or p.query.len == 0)) {
        // Nothing to show on a stale/empty Search page; keep the text only.
    } else if (!is_home) {
        p.route = route;
    }
    p.rerun_search = is_search and p.route != null;

    if (is_browse) {
        p.browse = parseTag(Browse, s.browse);
        if (p.browse == null) p.route = null; // a Browse page needs its source
    }
    const browse_tag: []const u8 = if (p.browse) |b| @tagName(b) else "";

    if (fresh and p.route != null and is_browse and std.mem.eql(u8, browse_tag, "TMDB") and validTmdbId(s.tv_id)) {
        p.tv_id = s.tv_id;
        p.tv_name = s.tv_name;
    }

    if (fresh and p.route != null) {
        if (validScroll(s.scroll_y)) |y| {
            p.scroll_target = scrollTargetFor(route_tag, browse_tag, p.tv_id != 0);
            p.scroll_y = if (p.scroll_target == .none) 0 else y;
        }
    }
    return p;
}

/// Apply a pending scroll once the list is tall enough to hold it. Content
/// streams in over several frames (search results, TMDB pages), and dvui
/// clamps an offset past the end, so applying on frame one would land at 0.
/// Returns the offset to set (and the restore is then done) or null to wait.
/// After `expired`, settles for the furthest reachable offset.
pub fn scrollStep(target: f32, scroll_max: f32, expired: bool) ?f32 {
    if (!std.math.isFinite(target) or target <= 0) return 0;
    const max = if (std.math.isFinite(scroll_max)) @max(scroll_max, 0) else 0;
    if (max + 0.5 >= target) return target;
    if (expired) return max;
    return null;
}

/// Persist the snapshot now? On any change, and at least once a minute so
/// the quit-time staleness check stays accurate after a crash.
pub fn shouldPersist(changed: bool, now: i64, last_write: i64) bool {
    if (changed) return true;
    return last_write == 0 or now - last_write >= 60;
}

// ── Tests ──

const TRoute = enum { home, search, browse, player, settings, watching };
const TBrowse = enum { TMDB, YouTube, Anime };
const TSettings = enum { General, Playback, About };
const TPlan = Plan(TRoute, TBrowse, TSettings);

fn planOf(s: Snapshot, env: Env) TPlan {
    return plan(TRoute, TBrowse, TSettings, s, env);
}

test "encode/decode round-trips every field" {
    var buf: [MAX_ENCODED]u8 = undefined;
    const line = encode(.{ .saved_at = 1700000000, .route = "browse", .browse = "TMDB", .settings = "Playback", .tv_id = 1399, .scroll_y = 812.25, .tv_name = "Game of Thrones", .query = "house of the dragon s02" }, &buf);
    const s = decode(line).?;
    try std.testing.expectEqual(@as(i64, 1700000000), s.saved_at);
    try std.testing.expectEqualStrings("browse", s.route);
    try std.testing.expectEqualStrings("TMDB", s.browse);
    try std.testing.expectEqualStrings("Playback", s.settings);
    try std.testing.expectEqual(@as(i32, 1399), s.tv_id);
    try std.testing.expectApproxEqAbs(@as(f32, 812.2), s.scroll_y, 0.11);
    try std.testing.expectEqualStrings("Game of Thrones", s.tv_name);
    try std.testing.expectEqualStrings("house of the dragon s02", s.query);
}

test "encode sanitises tabs and newlines out of free text" {
    var buf: [MAX_ENCODED]u8 = undefined;
    const line = encode(.{ .route = "search", .tv_name = "a\tb", .query = "x\ty\nz" }, &buf);
    try std.testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);
    const s = decode(line).?;
    try std.testing.expectEqualStrings("a b", s.tv_name);
    try std.testing.expectEqualStrings("x y z", s.query);
}

test "encode drops non-identifier tags and caps text on a UTF-8 boundary" {
    var buf: [MAX_ENCODED]u8 = undefined;
    var long_buf: [400]u8 = undefined; // 200 two-byte codepoints
    var i: usize = 0;
    while (i < long_buf.len) : (i += 2) @memcpy(long_buf[i..][0..2], "é");
    const long: []const u8 = &long_buf;
    const line = encode(.{ .route = "bro\twse", .query = long }, &buf);
    const s = decode(line).?;
    try std.testing.expectEqualStrings("", s.route);
    try std.testing.expect(s.query.len <= MAX_TEXT);
    try std.testing.expect(std.unicode.utf8ValidateSlice(s.query));
}

test "decode rejects wrong version, empty and truncated input" {
    try std.testing.expect(decode("") == null);
    try std.testing.expect(decode("2\t0\thome\t\t\t0\t0\t\t") == null);
    try std.testing.expect(decode("1\t0\thome") == null);
    try std.testing.expect(decode("garbage") == null);
}

test "decode degrades bad numbers to defaults" {
    const s = decode("1\tnope\tsearch\t\tGeneral\tx\tnan\t\tdune").?;
    try std.testing.expectEqual(@as(i64, 0), s.saved_at);
    try std.testing.expectEqual(@as(i32, 0), s.tv_id);
    try std.testing.expectEqual(@as(f32, 0), s.scroll_y);
    try std.testing.expectEqualStrings("dune", s.query);
}

test "isFresh: dev reload always, otherwise within STALE_SECS, never on clock skew" {
    try std.testing.expect(isFresh(0, .{ .now = 5, .dev_reload = true }));
    try std.testing.expect(isFresh(1000, .{ .now = 1000 + STALE_SECS }));
    try std.testing.expect(!isFresh(1000, .{ .now = 1001 + STALE_SECS }));
    try std.testing.expect(!isFresh(2000, .{ .now = 1000 }));
    try std.testing.expect(!isFresh(0, .{ .now = 1000 }));
}

test "fresh browse snapshot restores page, detail and episode scroll" {
    const p = planOf(.{ .saved_at = 100, .route = "browse", .browse = "TMDB", .settings = "About", .tv_id = 1399, .tv_name = "GoT", .scroll_y = 400, .query = "q" }, .{ .now = 160 });
    try std.testing.expectEqual(TRoute.browse, p.route.?);
    try std.testing.expectEqual(TBrowse.TMDB, p.browse.?);
    try std.testing.expectEqual(TSettings.About, p.settings.?);
    try std.testing.expectEqual(@as(i32, 1399), p.tv_id);
    try std.testing.expectEqualStrings("GoT", p.tv_name);
    try std.testing.expectEqual(ScrollTarget.tv_episodes, p.scroll_target);
    try std.testing.expectEqual(@as(f32, 400), p.scroll_y);
    try std.testing.expectEqualStrings("q", p.query);
    try std.testing.expect(!p.rerun_search);
}

test "stale browse snapshot restores page only — no detail, no scroll" {
    const p = planOf(.{ .saved_at = 100, .route = "browse", .browse = "TMDB", .tv_id = 1399, .scroll_y = 400 }, .{ .now = 100 + STALE_SECS + 1 });
    try std.testing.expectEqual(TRoute.browse, p.route.?);
    try std.testing.expectEqual(@as(i32, 0), p.tv_id);
    try std.testing.expectEqual(ScrollTarget.none, p.scroll_target);
}

test "dev reload makes an old snapshot fresh" {
    const p = planOf(.{ .saved_at = 1, .route = "browse", .browse = "TMDB", .tv_id = 7, .scroll_y = 50 }, .{ .now = 1_000_000, .dev_reload = true });
    try std.testing.expectEqual(@as(i32, 7), p.tv_id);
    try std.testing.expectEqual(ScrollTarget.tv_episodes, p.scroll_target);
}

test "fresh search page re-runs the query and restores result scroll" {
    const p = planOf(.{ .saved_at = 100, .route = "search", .query = "  dune  ", .scroll_y = 900 }, .{ .now = 101 });
    try std.testing.expectEqual(TRoute.search, p.route.?);
    try std.testing.expect(p.rerun_search);
    try std.testing.expectEqualStrings("dune", p.query);
    try std.testing.expectEqual(ScrollTarget.search_results, p.scroll_target);
}

test "stale search page keeps the text but stays on Home" {
    const p = planOf(.{ .saved_at = 100, .route = "search", .query = "dune", .scroll_y = 900 }, .{ .now = 100 + STALE_SECS + 1 });
    try std.testing.expect(p.route == null);
    try std.testing.expect(!p.rerun_search);
    try std.testing.expectEqualStrings("dune", p.query);
    try std.testing.expectEqual(ScrollTarget.none, p.scroll_target);
}

test "search page with an empty query is not restored" {
    const p = planOf(.{ .saved_at = 100, .route = "search", .query = "" }, .{ .now = 100 });
    try std.testing.expect(p.route == null);
    try std.testing.expect(!p.rerun_search);
}

test "player route and unknown tags are never restored" {
    const p = planOf(.{ .saved_at = 100, .route = "player", .settings = "Nope", .browse = "TMDB" }, .{ .now = 100 });
    try std.testing.expect(p.route == null);
    try std.testing.expect(p.settings == null);
    try std.testing.expect(p.browse == null);
    try std.testing.expect(planOf(.{ .route = "removed_page" }, .{ .now = 1 }).route == null);
}

test "browse without a valid source is dropped" {
    const p = planOf(.{ .saved_at = 100, .route = "browse", .browse = "Gone" }, .{ .now = 100 });
    try std.testing.expect(p.route == null);
}

test "invalid tv ids are not reopened" {
    for ([_]i32{ 0, -5, 200_000_000 }) |id| {
        const p = planOf(.{ .saved_at = 100, .route = "browse", .browse = "TMDB", .tv_id = id }, .{ .now = 100 });
        try std.testing.expectEqual(@as(i32, 0), p.tv_id);
    }
}

test "detail only reopens on the TMDB browse page" {
    const p = planOf(.{ .saved_at = 100, .route = "browse", .browse = "YouTube", .tv_id = 1399, .scroll_y = 10 }, .{ .now = 100 });
    try std.testing.expectEqual(@as(i32, 0), p.tv_id);
    try std.testing.expectEqual(ScrollTarget.none, p.scroll_target);
}

test "home route is a no-op route but settings and query still restore" {
    const p = planOf(.{ .saved_at = 100, .route = "home", .settings = "Playback", .query = "x" }, .{ .now = 100 });
    try std.testing.expect(p.route == null);
    try std.testing.expectEqual(TSettings.Playback, p.settings.?);
    try std.testing.expectEqualStrings("x", p.query);
}

test "launch target, prior navigation, onboarding and incognito block everything" {
    const s: Snapshot = .{ .saved_at = 100, .route = "browse", .browse = "TMDB", .settings = "About", .query = "q", .tv_id = 1 };
    try std.testing.expect(planOf(s, .{ .now = 100, .launched_with_target = true }).isEmpty());
    try std.testing.expect(planOf(s, .{ .now = 100, .already_navigated = true }).isEmpty());
    try std.testing.expect(planOf(s, .{ .now = 100, .onboarding = true }).isEmpty());
    try std.testing.expect(planOf(s, .{ .now = 100, .incognito = true }).isEmpty());
    try std.testing.expect(!planOf(s, .{ .now = 100 }).isEmpty());
}

test "scrollTargetFor maps route + source + detail to one list" {
    try std.testing.expectEqual(ScrollTarget.search_results, scrollTargetFor("search", "", false));
    try std.testing.expectEqual(ScrollTarget.tmdb_gallery, scrollTargetFor("browse", "TMDB", false));
    try std.testing.expectEqual(ScrollTarget.tv_episodes, scrollTargetFor("browse", "TMDB", true));
    try std.testing.expectEqual(ScrollTarget.none, scrollTargetFor("browse", "YouTube", false));
    try std.testing.expectEqual(ScrollTarget.none, scrollTargetFor("settings", "", false));
}

test "validScroll rejects non-finite, non-positive and absurd offsets" {
    try std.testing.expect(validScroll(std.math.nan(f32)) == null);
    try std.testing.expect(validScroll(std.math.inf(f32)) == null);
    try std.testing.expect(validScroll(0) == null);
    try std.testing.expect(validScroll(-3) == null);
    try std.testing.expect(validScroll(MAX_SCROLL + 1) == null);
    try std.testing.expectEqual(@as(f32, 12), validScroll(12).?);
}

test "scrollStep waits for content, then applies; settles on expiry" {
    try std.testing.expect(scrollStep(500, 0, false) == null);
    try std.testing.expect(scrollStep(500, 200, false) == null);
    try std.testing.expectEqual(@as(f32, 500), scrollStep(500, 800, false).?);
    try std.testing.expectEqual(@as(f32, 500), scrollStep(500, 499.8, false).?);
    try std.testing.expectEqual(@as(f32, 200), scrollStep(500, 200, true).?);
    try std.testing.expectEqual(@as(f32, 0), scrollStep(500, -1, true).?);
    try std.testing.expectEqual(@as(f32, 0), scrollStep(0, 100, false).?);
}

test "shouldPersist: on change, first write, and once a minute" {
    try std.testing.expect(shouldPersist(true, 10, 9));
    try std.testing.expect(shouldPersist(false, 10, 0));
    try std.testing.expect(!shouldPersist(false, 69, 10));
    try std.testing.expect(shouldPersist(false, 70, 10));
}
