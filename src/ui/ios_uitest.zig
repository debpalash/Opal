//! Headless Simulator UI/feature walk (`--ui-test`). Drives the SHARED desktop
//! pages through the same state calls their buttons make, checks real state,
//! and prints `OPAL_UITEST_SHOT <name>` so scripts/ios-uitest.py captures a
//! screenshot. One line per check: `OPAL_UITEST <name> pass|fail <detail>`.
const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const io = @import("../core/io_global.zig");
const pure = @import("ios_uitest_pure.zig");

var step: usize = 0;
var started_ms: i64 = 0;
var step_ms: i64 = 0;
var entered = false;
var failures: usize = 0;
var done_logged = false;

const Step = struct {
    name: []const u8,
    /// Runs once when the step starts.
    enter: *const fn () void,
    /// Polled each frame; true once the step's condition holds.
    ready: *const fn () bool,
    timeout_ms: i64,
};

const steps = [_]Step{
    .{ .name = "onboarding", .enter = enterOnboarding, .ready = sourcesInstalled, .timeout_ms = 5_000 },
    .{ .name = "home", .enter = enterHome, .ready = catalogLoaded, .timeout_ms = 25_000 },
    .{ .name = "movies", .enter = enterMovies, .ready = catalogLoaded, .timeout_ms = 20_000 },
    .{ .name = "tv_catalog", .enter = enterTvCatalog, .ready = tvCatalogLoaded, .timeout_ms = 20_000 },
    .{ .name = "vq_detail", .enter = enterVisionQuest, .ready = vqSeasonsLoaded, .timeout_ms = 25_000 },
    .{ .name = "vq_play", .enter = enterOpenShowPlay, .ready = mediaPlaying, .timeout_ms = 150_000 },
    .{ .name = "tv_episodes", .enter = enterTvDetail, .ready = seasonsLoaded, .timeout_ms = 25_000 },
    .{ .name = "tv_play", .enter = enterTvPlay, .ready = mediaPlaying, .timeout_ms = 120_000 },
    .{ .name = "find_sources", .enter = enterFindSources, .ready = sourcesFound, .timeout_ms = 45_000 },
    .{ .name = "movie_torrent", .enter = enterMovieTorrent, .ready = torrentPlaying, .timeout_ms = 90_000 },
    .{ .name = "downloads", .enter = enterDownloads, .ready = always, .timeout_ms = 1_000 },
    .{ .name = "comics", .enter = enterComics, .ready = comicCovers, .timeout_ms = 25_000 },
    .{ .name = "settings", .enter = enterSettings, .ready = always, .timeout_ms = 1_000 },
    .{ .name = "landscape", .enter = enterLandscape, .ready = isLandscape, .timeout_ms = 5_000 },
    .{ .name = "portrait", .enter = enterPortrait, .ready = isPortrait, .timeout_ms = 5_000 },
    .{ .name = "browser", .enter = enterBrowser, .ready = pageLoaded, .timeout_ms = 20_000 },
    .{ .name = "radio", .enter = enterRadio, .ready = radioLoaded, .timeout_ms = 25_000 },
    .{ .name = "radio_play", .enter = enterRadioPlay, .ready = onPlayer, .timeout_ms = 10_000 },
    .{ .name = "radio_back", .enter = tapBack, .ready = leftPlayer, .timeout_ms = 5_000 },
    .{ .name = "player_file", .enter = enterPlayerFile, .ready = playing, .timeout_ms = 20_000 },
    .{ .name = "player_torrent", .enter = enterTorrent, .ready = torrentStarted, .timeout_ms = 60_000 },
};

pub fn tick() void {
    const now = io.milliTimestamp();
    if (started_ms == 0) started_ms = now;
    const only = io.getenv("OPAL_UITEST_ONLY") orelse "";
    while (step < steps.len and !entered and !pure.selected(steps[step].name, only)) step += 1;
    if (step >= steps.len) {
        if (!done_logged) log("OPAL_UITEST_DONE failures={d}", .{failures});
        done_logged = true;
        return;
    }
    // Let first-launch startup (DB, config, torrent session) settle.
    if (now - started_ms < 2_000) return keepAwake();
    const s = steps[step];
    // Hold the previous page so the host's screenshot captures it.
    if (!entered and step > 0 and now - step_ms < 1_200) return keepAwake();
    if (!entered) {
        entered = true;
        step_ms = now;
        s.enter();
    }
    const elapsed = now - step_ms;
    const ok = s.ready();
    switch (pure.decide(ok, elapsed, s.timeout_ms, 1_500)) {
        .wait => {},
        .pass, .fail => |verdict| {
            if (verdict == .fail) failures += 1;
            var detail_buf: [768]u8 = undefined;
            log("OPAL_UITEST {s} {s} {s} ms={d}", .{ s.name, @tagName(verdict), detail(s.name, &detail_buf), elapsed });
            log("OPAL_UITEST_SHOT {s}", .{s.name});
            step += 1;
            entered = false;
            step_ms = now;
        },
    }
    keepAwake();
}

fn keepAwake() void {
    // Polling without input: request the next frame.
    dvui.refresh(null, @src(), null);
}

fn log(comptime fmt: []const u8, args: anytype) void {
    std.log.info(fmt, args);
}

fn always() bool {
    return true;
}

/// Selected file, its size and how much of the start / first 8 MB / tail is local.
fn gateInfo(p: anytype, buf: []u8) []const u8 {
    if (p.current_torrent_id < 0 or p.selected_file_idx < 0) return "file=unselected ";
    const ses = state.torrentSession();
    const mpvc = @import("../core/c.zig").mpv;
    const size = mpvc.torrent_get_file_size(ses, p.current_torrent_id, p.selected_file_idx);
    const tail_off = if (size > (8 << 20)) size - (8 << 20) else 0;
    return std.fmt.bufPrint(buf, "file={d}/{d} size={d}MB start1={d}% head8={d}% tail8={d}% fileprog={d:.3} ", .{
        p.selected_file_idx,
        mpvc.torrent_get_file_count(ses, p.current_torrent_id),
        @divTrunc(size, 1 << 20),
        mpvc.torrent_range_progress(ses, p.current_torrent_id, p.selected_file_idx, 0, 1 << 20),
        mpvc.torrent_range_progress(ses, p.current_torrent_id, p.selected_file_idx, 0, 8 << 20),
        mpvc.torrent_range_progress(ses, p.current_torrent_id, p.selected_file_idx, tail_off, size - tail_off),
        mpvc.torrent_get_file_progress(ses, p.current_torrent_id, p.selected_file_idx),
    }) catch "";
}

fn detail(name: []const u8, buf: []u8) []const u8 {
    const t = &state.app.tmdb;
    if (std.mem.eql(u8, name, "tv_episodes")) return std.fmt.bufPrint(buf, "seasons={d} episodes={d}", .{ t.tv_seasons.len, t.tv_episodes.len }) catch "";
    if (std.mem.eql(u8, name, "comics")) return std.fmt.bufPrint(buf, "covers={d}", .{@import("../services/comics.zig").coversReady()}) catch "";
    if (std.mem.startsWith(u8, name, "radio")) return std.fmt.bufPrint(buf, "route={s} left_once={} stations={d} back=({d:.0},{d:.0} {d:.0}x{d:.0})", .{ @tagName(state.app.router.current), left_once, state.app.radio.result_count, @import("ios_frame.zig").back_button_rect.x, @import("ios_frame.zig").back_button_rect.y, @import("ios_frame.zig").back_button_rect.w, @import("ios_frame.zig").back_button_rect.h }) catch "";
    if (std.mem.eql(u8, name, "browser")) {
        const b = &state.app.browser;
        return std.fmt.bufPrint(buf, "title=\"{s}\" loading={}", .{ b.title[0..@min(b.title_len, b.title.len)], b.is_loading.load(.acquire) }) catch "";
    }
    if (std.mem.eql(u8, name, "find_sources")) return std.fmt.bufPrint(buf, "sources={d}", .{@import("../services/resolver.zig").resultCount()}) catch "";
    if ((std.mem.eql(u8, name, "tv_play") or std.mem.eql(u8, name, "vq_play")) and state.app.router.current != .player) {
        // Why smart-play declined: the top candidates as its picker sees them.
        const resolver = @import("../services/resolver.zig");
        const rank = @import("../services/resolver_rank.zig");
        const count = resolver.resultCount();
        const head: []const u8 = std.fmt.bufPrint(buf, "eztv={t} torznab={t} stremio={t} torrent={t} yts={t} plugins={t} n={d} ", .{ resolver.status_eztv.load(.acquire), resolver.status_torznab.load(.acquire), resolver.status_stremio.load(.acquire), resolver.status_torrent.load(.acquire), resolver.status_yts.load(.acquire), resolver.status_plugins.load(.acquire), count }) catch "";
        var w: usize = head.len;
        resolver.results_mutex.lock();
        defer resolver.results_mutex.unlock();
        for (resolver.results[0..@min(count, 8)]) |it| {
            const line = std.fmt.bufPrint(buf[w..], "[{t} m={d} s={d} same={} {s}] ", .{ it.source, it.match_pct, it.seeds, rank.sameSeries(it.name[0..it.name_len], if (std.mem.eql(u8, name, "vq_play")) "visionquest s01e01" else "breaking bad s01e01"), it.name[0..@min(it.name_len, 40)] }) catch break;
            w += line.len;
        }
        return buf[0..w];
    }
    if ((std.mem.eql(u8, name, "tv_play") or std.mem.eql(u8, name, "vq_play")) and state.app.active_player_idx < state.app.players.items.len) {
        const p = state.app.players.items[state.app.active_player_idx];
        var st: [256]u8 = undefined;
        st[0] = 0;
        if (p.current_torrent_id >= 0) _ = @import("../core/c.zig").mpv.torrent_debug_status(state.torrentSession(), p.current_torrent_id, &st, st.len);
        var gate_buf: [200]u8 = undefined;
        return std.fmt.bufPrint(buf, "\"{s}\" pos={d:.1} dur={d:.0} ready={} loading={} cache_pause={} torrent={d} {s}url={s} {s}", .{ if (std.mem.eql(u8, name, "vq_play")) t.tv_name[0..@min(t.tv_name_len, t.tv_name.len)] else "Breaking Bad S01E01", p.last_seen_pos, p.cached_duration, p.torrent_is_ready, p.is_loading, p.cached_paused_for_cache, p.current_torrent_id, gateInfo(p, &gate_buf), p.current_url[0..@min(p.current_url_len, 48)], std.mem.sliceTo(&st, 0) }) catch "";
    }
    if (std.mem.eql(u8, name, "movie_torrent") and movie_pick_len == 0) return "no magnet among the movie's sources";
    if ((std.mem.eql(u8, name, "player_torrent") or std.mem.eql(u8, name, "movie_torrent")) and state.app.active_player_idx < state.app.players.items.len) {
        const p = state.app.players.items[state.app.active_player_idx];
        var st: [256]u8 = undefined;
        st[0] = 0;
        if (p.current_torrent_id >= 0) _ = @import("../core/c.zig").mpv.torrent_debug_status(state.torrentSession(), p.current_torrent_id, &st, st.len);
        const pick = if (std.mem.eql(u8, name, "movie_torrent")) movie_pick[0..movie_pick_len] else "Sintel";
        var gate_buf: [200]u8 = undefined;
        const gate = gateInfo(p, &gate_buf);
        return std.fmt.bufPrint(buf, "\"{s}\" seeds={d} pos={d:.1} dur={d:.0} ready={} torrent={d} {s}{s}", .{ pick, movie_pick_seeds, p.last_seen_pos, p.cached_duration, p.torrent_is_ready, p.current_torrent_id, gate, std.mem.sliceTo(&st, 0) }) catch "";
    }
    if (std.mem.startsWith(u8, name, "player")) {
        if (state.app.active_player_idx < state.app.players.items.len) {
            const p = state.app.players.items[state.app.active_player_idx];
            return std.fmt.bufPrint(buf, "pos={d:.1} dur={d:.0} texture={} torrent={d}", .{ p.last_seen_pos, p.cached_duration, p.texture != null, p.current_torrent_id }) catch "";
        }
        return "no-player";
    }
    return std.fmt.bufPrint(buf, "route={s} results={d}", .{ @tagName(state.app.router.current), t.results.items.len }) catch "";
}

// ── Steps: each mirrors what the corresponding desktop control does ──

/// The welcome dialog's "Install starter sources", then dismiss it — what a
/// first-run user does before searching.
fn enterOnboarding() void {
    _ = @import("../services/plugin_repo.zig").installStarterPack();
    state.app.onboarded = true;
    state.markConfigDirty();
}
fn sourcesInstalled() bool {
    const sc = @import("../core/source_config.zig");
    return sc.has("yts") and sc.has("apibay");
}
fn enterHome() void {
    state.app.router.navigate(.home);
}
fn catalogLoaded() bool {
    return state.app.tmdb.results.items.len > 0 and !state.app.tmdb.is_loading.load(.acquire);
}
fn enterMovies() void {
    state.app.tmdb.media_filter = .movie;
    state.app.tmdb.view = .Trending;
    state.navigateToTabNow(.TMDB);
    @import("../services/tmdb_api.zig").fetchCurrentView(false);
}
fn enterTvCatalog() void {
    state.app.tmdb.media_filter = .tv;
    state.app.tmdb.page = 1;
    @import("../services/tmdb_api.zig").fetchCurrentView(false);
}
fn firstOfType(tv: bool) ?*state.TmdbItem {
    for (state.app.tmdb.results.items) |*item| {
        const mt = item.media_type[0..@min(item.media_type_len, item.media_type.len)];
        if (std.mem.eql(u8, mt, "tv") == tv) return item;
    }
    return null;
}
fn tvCatalogLoaded() bool {
    return catalogLoaded() and firstOfType(true) != null;
}
/// The show the user had on screen: open VisionQuest from the TV catalog
/// (same call as tapping its card) and play its first listed episode.
fn findTitle(needle: []const u8) ?*state.TmdbItem {
    for (state.app.tmdb.results.items) |*item| {
        const title = item.title[0..@min(item.title_len, item.title.len)];
        if (std.ascii.findIgnoreCase(title, needle) != null) return item;
    }
    return null;
}
fn enterVisionQuest() void {
    if (findTitle("VisionQuest")) |item| @import("../services/tmdb.zig").openOrSearch(item);
}
fn vqSeasonsLoaded() bool {
    const t = &state.app.tmdb;
    return seasonsLoaded() and std.ascii.findIgnoreCase(t.tv_name[0..@min(t.tv_name_len, t.tv_name.len)], "VisionQuest") != null;
}
fn enterOpenShowPlay() void {
    const t = &state.app.tmdb;
    if (t.tv_season_count == 0 or t.tv_episode_count == 0) return;
    const season = t.tv_seasons[@min(t.tv_sel_season, t.tv_season_count - 1)].season_number;
    @import("../services/tmdb.zig").playEpisodeOf(t.tv_id, t.tv_name[0..@min(t.tv_name_len, t.tv_name.len)], t.tv_poster_path[0..@min(t.tv_poster_path_len, t.tv_poster_path.len)], season, t.tv_episodes[0].episode_number, "");
}
fn enterTvDetail() void {
    if (firstOfType(true)) |item| @import("../services/tmdb.zig").openOrSearch(item);
}
fn seasonsLoaded() bool {
    const t = &state.app.tmdb;
    return t.tv_detail_open and !t.tv_seasons_loading and t.tv_seasons.len > 0;
}
/// The episode list's Play: resolve sources for the show's first listed
/// episode and play the best one (torrent or stream).
fn enterTvPlay() void {
    // A long-running show with a deep swarm (TMDB 1396), so the check measures
    // Opal's episode pipeline rather than whether a brand-new show has releases.
    @import("../services/tmdb.zig").playEpisodeOf(1396, "Breaking Bad", "", 1, 1, "");
}
/// Real playback of a long item: frames, a running clock, a feature-length
/// duration (not the 12 s bundled clip).
fn mediaPlaying() bool {
    if (state.app.active_player_idx >= state.app.players.items.len) return false;
    const p = state.app.players.items[state.app.active_player_idx];
    return p.cached_duration > 60 and p.texture != null and p.last_seen_pos > 0.5;
}
fn enterFindSources() void {
    const tmdb = @import("../services/tmdb.zig");
    tmdb.closeTvDetail();
    state.app.tmdb.media_filter = .movie;
    // A movie card's "Find sources" runs the universal search for it.
    if (firstOfType(false)) |item| tmdb.openOrSearch(item) else {
        // Same as typing in the omnibox and pressing Enter.
        @import("../services/search.zig").submitQuery("Night of the Living Dead 1968");
        state.app.router.navigate(.search);
    }
}
fn sourcesFound() bool {
    return @import("../services/resolver.zig").resultCount() > 0;
}
/// "Find sources" → play: the best-seeded magnet among the movie's sources,
/// through the same resolver play path a source row's Play button uses.
var movie_pick: [96]u8 = undefined;
var movie_pick_len: usize = 0;
var movie_pick_seeds: u16 = 0;
fn enterMovieTorrent() void {
    const resolver = @import("../services/resolver.zig");
    var best: ?resolver.ResolvedItem = null;
    const count = resolver.resultCount(); // takes results_mutex itself
    resolver.results_mutex.lock();
    for (resolver.results[0..@min(count, resolver.results.len)]) |item| {
        const url = item.url[0..item.url_len];
        if (!std.mem.startsWith(u8, url, "magnet:?")) continue;
        if (best == null or item.seeds > best.?.seeds) best = item;
    }
    resolver.results_mutex.unlock();
    const item = best orelse return;
    movie_pick_len = @min(item.name_len, movie_pick.len);
    @memcpy(movie_pick[0..movie_pick_len], item.name[0..movie_pick_len]);
    movie_pick_seeds = item.seeds;
    resolver.playResolvedItem(&item);
}
fn torrentPlaying() bool {
    if (state.app.active_player_idx >= state.app.players.items.len) return false;
    const p = state.app.players.items[state.app.active_player_idx];
    return p.current_torrent_id >= 0 and p.torrent_is_ready and p.cached_duration > 60 and p.texture != null and p.last_seen_pos > 0.5;
}
fn enterDownloads() void {
    state.app.router.navigate(.downloads);
}
fn enterComics() void {
    state.navigateToTabNow(.Comics);
}
fn comicCovers() bool {
    return @import("../services/comics.zig").coversReady() > 0;
}
fn enterSettings() void {
    state.app.router.navigate(.settings);
}
extern fn opal_ios_set_landscape(landscape: bool) void;
fn enterLandscape() void {
    state.app.router.navigate(.home);
    opal_ios_set_landscape(true);
}
fn isLandscape() bool {
    const r = dvui.windowRect();
    return r.w > r.h;
}
fn enterPortrait() void {
    opal_ios_set_landscape(false);
}
fn isPortrait() bool {
    const r = dvui.windowRect();
    return r.h > r.w;
}
fn enterBrowser() void {
    state.navigateToTabNow(.Web);
    @import("../services/browser.zig").navigate("https://example.com/");
}
/// The WKWebView finished example.com: title synced and loading cleared
/// (route alone passed with a blank "New tab" in the screenshot).
fn pageLoaded() bool {
    const b = &state.app.browser;
    const title = b.title[0..@min(b.title_len, b.title.len)];
    return !b.is_loading.load(.acquire) and std.mem.indexOf(u8, title, "Example") != null;
}
fn enterRadio() void {
    state.navigateToTabNow(.Radio);
}
fn radioLoaded() bool {
    return state.app.radio.result_count > 0;
}
fn enterRadioPlay() void {
    @import("../services/radio.zig").playStation(0);
}
fn onPlayer() bool {
    return state.app.router.current == .player;
}
/// A real touch (SDL finger events → dvui touch0) on the player's Back
/// control: press now, release on the next poll.
var tap_pending_release = false;
fn tapAt(action: dvui.Event.Mouse.Action) void {
    const r = @import("ios_frame.zig").back_button_rect;
    const px = dvui.windowRectPixels();
    if (r.w <= 0 or px.w <= 0) return;
    _ = dvui.currentWindow().addEventPointer(.{ .button = .touch0, .action = action, .xynorm = .{ .x = (r.x + r.w / 2) / px.w, .y = (r.y + r.h / 2) / px.h } }) catch {};
}
fn tapBack() void {
    tapAt(.press);
    tap_pending_release = true;
}
/// Passes only if the tap left the player AND nothing re-opened it during
/// the settle window (decide() polls after 1.5 s).
fn leftPlayer() bool {
    if (tap_pending_release) {
        tap_pending_release = false;
        tapAt(.release);
    }
    if (state.app.router.current != .player) left_once = true;
    return state.app.router.current != .player;
}
var left_once = false;
extern fn opal_ios_open_demo() void;
fn enterPlayerFile() void {
    opal_ios_open_demo();
}
fn playing() bool {
    if (state.app.active_player_idx >= state.app.players.items.len) return false;
    const p = state.app.players.items[state.app.active_player_idx];
    return p.last_seen_pos >= 1 and p.texture != null;
}
/// Blender's public-domain Sintel torrent (WebTorrent test fixture).
const TEST_MAGNET = "magnet:?xt=urn:btih:08ada5a7a6183aae1e09d831df6748d566095a10&dn=Sintel&tr=udp%3A%2F%2Fexplodie.org%3A6969&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337&tr=wss%3A%2F%2Ftracker.webtorrent.dev";
fn enterTorrent() void {
    @import("../services/browser.zig").loadContent(TEST_MAGNET);
}
fn torrentStarted() bool {
    if (state.app.active_player_idx >= state.app.players.items.len) return false;
    const p = state.app.players.items[state.app.active_player_idx];
    // Ready = metadata resolved and the stream handed to mpv (not the previous file).
    // Sintel runs ~15 min; the bundled clip 12 s — a long duration plus a
    // presented frame proves the torrent stream itself is playing.
    return p.current_torrent_id >= 0 and p.torrent_is_ready and p.cached_duration > 60 and p.texture != null and p.last_seen_pos > 0.5;
}
