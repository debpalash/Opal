const bus = @import("../core/scrobble_bus.zig");
const db = @import("../core/db.zig");
const trakt = @import("trakt.zig");
const simkl = @import("simkl.zig");
const anilist = @import("anilist.zig");

// ══════════════════════════════════════════════════════════
// Tracker sinks for core/scrobble_bus.zig. This is the only module that
// turns bus events into Trakt / SIMKL / AniList calls; routing (which tracker
// takes which event) is scrobble_pure.routes, applied by the bus.
// ══════════════════════════════════════════════════════════

/// Register every tracker sink. Called once at startup after the services
/// load their credentials (main.zig).
pub fn install() void {
    bus.registerSink(.{ .tracker = .trakt, .deliver = deliverTrakt });
    bus.registerSink(.{ .tracker = .simkl, .deliver = deliverSimkl });
    bus.registerSink(.{ .tracker = .anilist, .deliver = deliverAnilist });
}

/// Remembered IMDb id: a keyless catalog id is a hash of it, so trackers are
/// told the IMDb id instead of an unrelated TMDB id.
fn imdbFor(media: bus.Media, buf: *[16]u8) []const u8 {
    return switch (media.kind) {
        .movie => db.movieImdbId(media.tmdb_id, buf),
        .episode => db.tvImdbId(media.tmdb_id, buf),
        .anime => "",
    };
}

fn deliverTrakt(d: bus.Delivery) void {
    var imdb_buf: [16]u8 = undefined;
    const imdb = imdbFor(d.media, &imdb_buf);
    const m = d.media;
    switch (d.event) {
        .watched => if (m.kind == .movie) trakt.markWatchedMovie(m.tmdb_id, imdb) else trakt.markWatchedEpisode(m.tmdb_id, imdb, m.season, m.episode),
        .unwatched => if (m.kind == .movie) trakt.markUnwatchedMovie(m.tmdb_id, imdb) else trakt.markUnwatchedEpisode(m.tmdb_id, imdb, m.season, m.episode),
        .start, .pause, .stop => {
            if (!trakt.isConnected()) return;
            var body: [320]u8 = undefined;
            const season: i32 = if (m.kind == .movie) -1 else m.season;
            const episode: i32 = if (m.kind == .movie) -1 else m.episode;
            const payload = @import("keyless_tv_pure.zig").liveScrobblePayload(m.tmdb_id, imdb, season, episode, d.progress, &body) orelse return;
            const action: trakt.LiveAction = switch (d.event) {
                .start => .start,
                .pause => .pause,
                else => .stop,
            };
            trakt.scrobbleLive(action, payload);
        },
    }
}

fn deliverSimkl(d: bus.Delivery) void {
    var imdb_buf: [16]u8 = undefined;
    const imdb = imdbFor(d.media, &imdb_buf);
    const m = d.media;
    switch (d.event) {
        .watched => if (m.kind == .movie) simkl.markWatchedMovie(m.tmdb_id, imdb) else simkl.markWatchedEpisode(m.tmdb_id, imdb, m.season, m.episode),
        .unwatched => if (m.kind == .movie) simkl.markUnwatchedMovie(m.tmdb_id, imdb) else simkl.markUnwatchedEpisode(m.tmdb_id, imdb, m.season, m.episode),
        else => {},
    }
}

fn deliverAnilist(d: bus.Delivery) void {
    if (d.event == .watched and d.media.kind == .anime) anilist.updateProgress(d.media.anilist_id, d.media.episode);
}
