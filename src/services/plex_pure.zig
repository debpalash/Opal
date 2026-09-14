//! Pure decision logic for the Plex tab — no I/O, no dvui, no globals, so it can
//! be unit-tested. `plex.zig` routes through these so the tested logic is the
//! shipped logic.

const std = @import("std");

/// How long to wait before re-attempting a section load that failed. Short
/// enough that a user who fixes their wifi sees the library without a restart,
/// long enough that a persistent failure doesn't spawn a request per frame.
pub const SECTIONS_RETRY_S: i64 = 15;

pub fn authRejected(status_code: u16) bool {
    return status_code == 401 or status_code == 403;
}

/// Plex media-part paths come from server metadata and are appended to the
/// selected server origin. Keep the persisted deep link path-only and reject
/// traversal/query/control injection before reconstruction.
pub fn validPartPath(path: []const u8) bool {
    if (path.len < 2 or path.len > 256 or path[0] != '/') return false;
    if (std.mem.indexOf(u8, path, "..") != null) return false;
    for (path) |ch| if (ch == '?' or ch == '#' or ch == '\r' or ch == '\n' or ch == 0) return false;
    return true;
}

pub fn validRatingKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 32) return false;
    for (key) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

pub const VersionSelection = struct {
    primary: ?usize = null,
    fallback: ?usize = null,
};

/// Choose at most two distinct playable media versions in server order.
/// Callers pass the first Part path from each Media row; later parts in one
/// row are split-file continuations and deliberately never enter this list.
pub fn selectVersionParts(parts: []const []const u8) VersionSelection {
    var out: VersionSelection = .{};
    for (parts, 0..) |part, idx| {
        if (!validPartPath(part)) continue;
        if (out.primary == null) {
            out.primary = idx;
            continue;
        }
        if (!std.mem.eql(u8, part, parts[out.primary.?])) {
            out.fallback = idx;
            break;
        }
    }
    return out;
}

fn safeToken(value: []const u8, max_len: usize) bool {
    if (value.len == 0 or value.len > max_len) return false;
    for (value) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '.' and ch != '_') return false;
    return true;
}

/// Credential-free HLS recovery URL for Plex's universal transcoder. The
/// X-Plex-Token remains in the player's HTTP headers and is never serialized
/// into this URL. This is used only after all direct media versions fail.
pub fn transcodeUrl(server: []const u8, rating_key: []const u8, session: []const u8, client_id: []const u8, app_version: []const u8, out: []u8) ?[]const u8 {
    if (server.len == 0 or !validRatingKey(rating_key) or
        !safeToken(session, 64) or !safeToken(client_id, 64) or !safeToken(app_version, 32)) return null;
    return std.fmt.bufPrint(
        out,
        "{s}/video/:/transcode/universal/start.m3u8?path=%2Flibrary%2Fmetadata%2F{s}&mediaIndex=0&partIndex=0&protocol=hls&hasMDE=1&fastSeek=1&directPlay=0&directStream=0&videoResolution=1920x1080&maxVideoBitrate=20000&videoQuality=100&subtitles=auto&session={s}&X-Plex-Client-Identifier={s}&X-Plex-Client-Profile-Name=Chrome&X-Plex-Product=Opal&X-Plex-Version={s}&X-Plex-Platform=Chrome",
        .{ server, rating_key, session, client_id, app_version },
    ) catch null;
}

pub const DeepLink = struct {
    rating_key: []const u8,
    part: []const u8,
};

/// Stable, credential-free Plex identity. The rating key drives timeline
/// reporting while the media-part path reconstructs direct playback.
pub fn buildDeepLink(rating_key: []const u8, part: []const u8, buf: []u8) ?[]const u8 {
    if (!validRatingKey(rating_key) or !validPartPath(part)) return null;
    return std.fmt.bufPrint(buf, "opal://plex/item/{s}/part{s}", .{ rating_key, part }) catch null;
}

pub fn parseDeepLink(link: []const u8) ?DeepLink {
    const prefix = "opal://plex/item/";
    if (!std.mem.startsWith(u8, link, prefix)) return null;
    const tail = link[prefix.len..];
    const marker = std.mem.indexOf(u8, tail, "/part/") orelse return null;
    const rating_key = tail[0..marker];
    const part = tail[marker + "/part".len ..];
    if (!validRatingKey(rating_key) or !validPartPath(part)) return null;
    return .{ .rating_key = rating_key, .part = part };
}

/// Should the Plex tab kick off a `/library/sections` fetch this frame?
///
/// The bug this exists for: `init()` restores a persisted token and stamps
/// `conn_state = .connected`, but only `connect()` (the first-run PIN flow) ever
/// called `fetchSectionsSync()`. So on every relaunch `renderContent()` saw
/// `isConnected() == true`, skipped the sign-in panel, drew the "Plex · <server>"
/// header — and then drew zero section tabs and zero rows, forever. A restored
/// session had a permanently blank library.
///
/// `loaded_once` latches on a SUCCESSFUL fetch — not before it, and not on
/// "section_count > 0". Both alternatives are wrong:
///   - Latching before success turns one transient failure (wifi still coming up
///     at launch, server asleep) into a blank tab for the whole run — the same
///     class of bug this fixes. So the caller latches only after a fetch parses.
///   - Latching on "we have sections" looks equivalent but silently breaks a
///     server with ZERO libraries: the fetch succeeds, returns an empty list,
///     and a count-based check would keep firing a /library/sections request every
///     SECTIONS_RETRY_S seconds forever. An empty library is a successful load.
/// Until that latch, `last_attempt_s` + the backoff give a failed load a retry
/// without spawning a worker per frame.
pub fn shouldFetchSections(
    connected: bool,
    loaded_once: bool,
    loading: bool,
    last_attempt_s: i64,
    now_s: i64,
) bool {
    if (!connected) return false;
    if (loaded_once) return false; // a fetch already succeeded (even if empty)
    if (loading) return false; // a worker is in flight; don't stack another
    if (last_attempt_s == 0) return true; // never tried
    return now_s - last_attempt_s >= SECTIONS_RETRY_S;
}

/// May a completed worker publish its results into shared state?
///
/// The identity check `section_idx == active_section` is necessary but NOT
/// sufficient: a section index cannot distinguish "still the same fetch" from
/// "the same section was re-opened while this fetch was in flight". The A→B→A
/// interleaving that defeats it:
///
///   1. In section 0 at the bottom, `loadMore()` spawns W1 = fetchWindow(0, 50);
///      it blocks in httpGet.
///   2. User clicks section 1 → active_section = 1.
///   3. User clicks section 0 again → active_section = 0, and the fresh load
///      resets item_count = 0, current_start = 0.
///   4. W1 returns. `0 == 0` passes, so it appends a stale window-50 page into
///      the freshly-reset list → duplicated/misordered rows and a corrupted
///      current_start, so a page of items is silently skipped or repeated.
///
/// A monotonic generation bumped on every switch/reload closes it: the worker
/// captures the generation before spawning and re-checks it here, so a fetch
/// issued under a superseded view is dropped even when the index matches again.
pub fn workerMayPublish(
    captured_section: usize,
    captured_gen: u64,
    current_section: usize,
    current_gen: u64,
) bool {
    return captured_section == current_section and captured_gen == current_gen;
}

// ── tests ────────────────────────────────────────────────────────────────────

test "regression: restored token with no sections triggers a fetch (blank-tab-on-restart)" {
    // The exact relaunch state: init() restored the token (connected) but nothing
    // ever called fetchSections, so section_count == 0 and no attempt was made.
    try std.testing.expect(shouldFetchSections(true, false, false, 0, 1000));
}

test "auth rejection is distinct from provider and transport failures" {
    try std.testing.expect(authRejected(401));
    try std.testing.expect(authRejected(403));
    try std.testing.expect(!authRejected(0));
    try std.testing.expect(!authRejected(404));
    try std.testing.expect(!authRejected(500));
}

test "Plex part deep links stay path-only" {
    try std.testing.expect(validPartPath("/library/parts/45/file.mkv"));
    try std.testing.expect(!validPartPath("library/parts/45"));
    try std.testing.expect(!validPartPath("/library/../secret"));
    try std.testing.expect(!validPartPath("/part?X-Plex-Token=stolen"));
}

test "Plex version selection skips unusable and duplicate parts" {
    const candidates = [_][]const u8{
        "",
        "../bad",
        "/library/parts/10/movie.mkv",
        "/library/parts/10/movie.mkv",
        "/library/parts/20/movie.mp4",
    };
    const selected = selectVersionParts(&candidates);
    try std.testing.expectEqual(@as(?usize, 2), selected.primary);
    try std.testing.expectEqual(@as(?usize, 4), selected.fallback);
    try std.testing.expect(selectVersionParts(&[_][]const u8{"bad"}).primary == null);
}

test "Plex transcode recovery URL is bounded and credential-free" {
    var out: [1024]u8 = undefined;
    const url = transcodeUrl("https://plex.example", "1234", "abc123", "client-1", "0.8.1", &out).?;
    try std.testing.expect(std.mem.startsWith(u8, url, "https://plex.example/video/:/transcode/universal/start.m3u8?"));
    try std.testing.expect(std.mem.indexOf(u8, url, "path=%2Flibrary%2Fmetadata%2F1234") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "directPlay=0&directStream=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "hasMDE=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "X-Plex-Client-Profile-Name=Chrome") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "X-Plex-Token") == null);
    try std.testing.expect(transcodeUrl("https://plex.example", "12/x", "s", "c", "1", &out) == null);
}

test "tracked Plex deep links round-trip rating key and media path" {
    var buf: [384]u8 = undefined;
    const link = buildDeepLink("12345", "/library/parts/45/file.mkv", &buf).?;
    const parsed = parseDeepLink(link).?;
    try std.testing.expectEqualStrings("12345", parsed.rating_key);
    try std.testing.expectEqualStrings("/library/parts/45/file.mkv", parsed.part);
    try std.testing.expect(parseDeepLink("opal://plex/item/12x/part/library/parts/1/a.mkv") == null);
    try std.testing.expect(buildDeepLink("12", "/library/../secret", &buf) == null);
}

test "shouldFetchSections: no fetch when disconnected" {
    try std.testing.expect(!shouldFetchSections(false, false, false, 0, 1000));
}

test "shouldFetchSections: a successful load stops the trigger" {
    try std.testing.expect(!shouldFetchSections(true, true, false, 0, 1000));
}

test "regression: a server with ZERO libraries must not poll forever" {
    // A successful fetch that returns an empty section list IS a load. Latching
    // on "section_count > 0" instead of "the fetch succeeded" would leave this
    // firing a /library/sections request every SECTIONS_RETRY_S for the whole run.
    const loaded_once = true; // fetch succeeded; it just had nothing in it
    try std.testing.expect(!shouldFetchSections(true, loaded_once, false, 1000, 1000 + 10_000));
}

test "shouldFetchSections: no stacking while a worker is in flight" {
    try std.testing.expect(!shouldFetchSections(true, false, true, 0, 1000));
}

test "shouldFetchSections: a failed attempt retries only after the backoff" {
    // Attempt stamped at t=1000. Must not re-fire every frame...
    try std.testing.expect(!shouldFetchSections(true, false, false, 1000, 1000));
    try std.testing.expect(!shouldFetchSections(true, false, false, 1000, 1000 + SECTIONS_RETRY_S - 1));
    // ...but must recover on its own once the backoff elapses (no restart needed).
    try std.testing.expect(shouldFetchSections(true, false, false, 1000, 1000 + SECTIONS_RETRY_S));
    try std.testing.expect(shouldFetchSections(true, false, false, 1000, 1000 + 600));
}

test "shouldFetchSections: a backwards clock can't wedge the retry permanently" {
    // now < last_attempt (NTP step / suspend). Must not fire a burst, and must
    // not latch forever either — the next in-window tick behaves normally.
    try std.testing.expect(!shouldFetchSections(true, false, false, 5000, 1000));
}

test "regression: A→B→A section switch is rejected by the generation guard" {
    // 1. Section 0 open at the bottom; loadMore() spawns W1 = window(start=50)
    //    under gen 7. It blocks in httpGet.
    const w1_section: usize = 0;
    const w1_gen: u64 = 7;
    // 2. User clicks section 1 → active_section = 1, gen bumps to 8.
    try std.testing.expect(!workerMayPublish(w1_section, w1_gen, 1, 8));
    // 3. User clicks section 0 again → active_section = 0, gen bumps to 9, and
    //    the reload resets item_count / current_start.
    const active: usize = 0;
    const gen_now: u64 = 9;
    // 4. W1 returns. Its SECTION still matches — the old section-only guard
    //    passed here and appended a stale window onto the freshly reset list.
    try std.testing.expect(w1_section == active); // the old guard passed…
    try std.testing.expect(!workerMayPublish(w1_section, w1_gen, active, gen_now)); // …the generation drops it
}

test "regression: the reload's own worker still publishes after A→B→A" {
    // The guard must not be so strict it drops the LIVE worker: W3 is the
    // section-0 reload itself (gen 9) and must be allowed to publish.
    try std.testing.expect(workerMayPublish(0, 9, 0, 9));
}

test "workerMayPublish: the in-flight fetch for the live view publishes" {
    try std.testing.expect(workerMayPublish(0, 7, 0, 7));
}

test "workerMayPublish: a plain mid-fetch switch to another section is rejected" {
    try std.testing.expect(!workerMayPublish(0, 7, 1, 8));
}

test "workerMayPublish: same generation but a different section is rejected" {
    // Defensive: generation alone isn't the whole identity either.
    try std.testing.expect(!workerMayPublish(0, 7, 1, 7));
}
