const std = @import("std");

// ══════════════════════════════════════════════════════════
// Scrobble decisions (pure). core/scrobble_bus.zig feeds player progress
// samples and explicit watched marks through these functions and fans the
// resulting events out to the tracker sinks (Trakt, SIMKL, AniList).
//
// Rules:
//   - start / pause: emitted only after the observed play state has held for
//     `debounce_ms` (a quick preview, a seek flicker or a pause/resume flap
//     never reaches a tracker). The bus samples once per frame, so a pause
//     is reported while the position is frozen.
//   - watched: once per session, when the position AND the time actually
//     played both reach `watched_ratio` (80%) of the duration. Seeking to the
//     credits alone never marks anything watched.
//   - stop: when the session ends (media changes or playback closes) after a
//     start was reported and before the watched mark. A watched session is
//     complete: Trakt's own /scrobble/stop at >= 80% would add a second play
//     on top of the durable history entry.
//   - dedupe: a watched/unwatched mark equal to the last one sent for the same
//     media within `dedupe_window_ms` (6h) is dropped, so the 80% mark and the
//     later local-history commit (90%) never record two plays.
// ══════════════════════════════════════════════════════════

pub const Kind = enum(u8) { movie, episode, anime };

/// Tracker identity of what is playing. Sinks resolve IMDb ids themselves.
pub const Media = struct {
    kind: Kind,
    /// Movie TMDB id, or the show's TMDB id for an episode. Keyless catalog
    /// ids are signed hashes, so only zero is invalid.
    tmdb_id: i32 = 0,
    season: i32 = 0,
    episode: i32 = 0,
    anilist_id: i64 = 0,

    pub fn movie(tmdb_id: i32) Media {
        return .{ .kind = .movie, .tmdb_id = tmdb_id };
    }

    pub fn tvEpisode(show_tmdb_id: i32, season: i32, episode: i32) Media {
        return .{ .kind = .episode, .tmdb_id = show_tmdb_id, .season = season, .episode = episode };
    }

    pub fn anime(anilist_id: i64, episode: i32) Media {
        return .{ .kind = .anime, .anilist_id = anilist_id, .episode = episode };
    }

    pub fn valid(self: Media) bool {
        return switch (self.kind) {
            .movie => self.tmdb_id != 0,
            .episode => self.tmdb_id != 0 and self.episode > 0 and self.season >= 0,
            .anime => self.anilist_id > 0 and self.episode > 0,
        };
    }

    pub fn eql(a: Media, b: Media) bool {
        if (a.kind != b.kind) return false;
        return switch (a.kind) {
            .movie => a.tmdb_id == b.tmdb_id,
            .episode => a.tmdb_id == b.tmdb_id and a.season == b.season and a.episode == b.episode,
            .anime => a.anilist_id == b.anilist_id and a.episode == b.episode,
        };
    }
};

pub const Event = enum(u8) { start, pause, stop, watched, unwatched };

pub const Config = struct {
    debounce_ms: i64 = 3_000,
    watched_ratio: f64 = 0.8,
    dedupe_window_ms: i64 = 6 * 60 * 60 * 1000,
};

pub const Sample = struct {
    now_ms: i64,
    position: f64,
    duration: f64,
    paused: bool,
    /// Seconds actually advanced during real playback (seek-resistant).
    played_seconds: f64,
};

pub fn progressPercent(position: f64, duration: f64) f64 {
    if (!std.math.isFinite(position) or !std.math.isFinite(duration) or duration <= 0) return 0;
    return std.math.clamp(position / duration * 100.0, 0, 100);
}

pub fn watchedDue(position: f64, duration: f64, played: f64, ratio: f64) bool {
    if (!std.math.isFinite(position) or !std.math.isFinite(duration) or !std.math.isFinite(played)) return false;
    return duration > 0 and position >= duration * ratio and played >= duration * ratio;
}

const PlayState = enum(u8) { none, playing, paused };

/// Up to two events per step (e.g. a debounced start plus the watched mark).
pub const Emission = struct {
    events: [2]Event = undefined,
    len: u8 = 0,
    progress: f64 = 0,

    fn push(self: *Emission, e: Event) void {
        self.events[self.len] = e;
        self.len += 1;
    }

    pub fn slice(self: *const Emission) []const Event {
        return self.events[0..self.len];
    }
};

/// One playback session (one media item in one player).
pub const Session = struct {
    media: Media,
    observed: PlayState = .none,
    observed_since_ms: i64 = 0,
    reported: PlayState = .none,
    watched_sent: bool = false,
    last_progress: f64 = 0,

    pub fn begin(media: Media) Session {
        return .{ .media = media };
    }

    /// Feed one progress sample. Samples without a usable duration are ignored.
    pub fn step(self: *Session, in: Sample, config: Config) Emission {
        var out: Emission = .{};
        if (!std.math.isFinite(in.duration) or in.duration <= 0 or !std.math.isFinite(in.position)) return out;
        self.last_progress = progressPercent(in.position, in.duration);
        out.progress = self.last_progress;
        if (self.watched_sent) return out;

        const now_state: PlayState = if (in.paused) .paused else .playing;
        if (now_state != self.observed) {
            self.observed = now_state;
            self.observed_since_ms = in.now_ms;
        }
        if (self.observed != self.reported and in.now_ms - self.observed_since_ms >= config.debounce_ms) {
            switch (self.observed) {
                .playing => {
                    out.push(.start);
                    self.reported = .playing;
                },
                // A pause before any start is not worth reporting.
                .paused => if (self.reported == .playing) {
                    out.push(.pause);
                    self.reported = .paused;
                },
                .none => {},
            }
        }
        if (watchedDue(in.position, in.duration, in.played_seconds, config.watched_ratio)) {
            out.push(.watched);
            self.watched_sent = true;
        }
        return out;
    }

    /// End of session. Returns true when a `stop` must be reported.
    pub fn finish(self: *Session) bool {
        const due = !self.watched_sent and self.reported != .none;
        self.reported = .none;
        self.observed = .none;
        return due;
    }
};

/// Recently delivered watched/unwatched marks, for dedupe across sources.
pub const Dedupe = struct {
    const N = 32;
    const Entry = struct { media: Media, event: Event, at_ms: i64 };
    entries: [N]Entry = undefined,
    len: usize = 0,
    next: usize = 0,

    /// True if `event` for `media` should be delivered (and records it).
    /// Only watched/unwatched are deduped; live events always pass.
    pub fn admit(self: *Dedupe, media: Media, event: Event, now_ms: i64, window_ms: i64) bool {
        if (event != .watched and event != .unwatched) return true;
        var latest: ?*Entry = null;
        for (self.entries[0..self.len]) |*e| {
            if (!e.media.eql(media)) continue;
            if (latest == null or e.at_ms >= latest.?.at_ms) latest = e;
        }
        if (latest) |e| {
            if (e.event == event and now_ms - e.at_ms < window_ms) return false;
            e.event = event;
            e.at_ms = now_ms;
            return true;
        }
        self.entries[self.next] = .{ .media = media, .event = event, .at_ms = now_ms };
        self.next = (self.next + 1) % N;
        if (self.len < N) self.len += 1;
        return true;
    }
};

/// Which tracker consumes which event. Live events only make sense for Trakt
/// (SIMKL and AniList have no now-playing scrobble in this client); AniList
/// only knows anime, Trakt/SIMKL only TMDB/IMDb movies and episodes.
pub const Tracker = enum { trakt, simkl, anilist };

pub fn routes(tracker: Tracker, media: Media, event: Event) bool {
    return switch (tracker) {
        .trakt => media.kind != .anime,
        .simkl => media.kind != .anime and (event == .watched or event == .unwatched),
        .anilist => media.kind == .anime and event == .watched,
    };
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

const t = std.testing;
const cfg: Config = .{};

fn sample(now_ms: i64, pos: f64, paused: bool, played: f64) Sample {
    return .{ .now_ms = now_ms, .position = pos, .duration = 100, .paused = paused, .played_seconds = played };
}

test "start is debounced until playback holds" {
    var s = Session.begin(Media.movie(278));
    try t.expectEqual(@as(u8, 0), s.step(sample(0, 0, false, 0), cfg).len);
    try t.expectEqual(@as(u8, 0), s.step(sample(2_999, 3, false, 3), cfg).len);
    const e = s.step(sample(3_000, 3, false, 3), cfg);
    try t.expectEqualSlices(Event, &.{.start}, e.slice());
    try t.expectApproxEqAbs(@as(f64, 3), e.progress, 0.001);
    // No repeat start while still playing.
    try t.expectEqual(@as(u8, 0), s.step(sample(10_000, 10, false, 10), cfg).len);
}

test "a short preview never scrobbles" {
    var s = Session.begin(Media.movie(278));
    _ = s.step(sample(0, 0, false, 0), cfg);
    _ = s.step(sample(1_500, 1.5, false, 1.5), cfg);
    try t.expect(!s.finish());
}

test "pause/resume flapping inside the debounce window is collapsed" {
    var s = Session.begin(Media.movie(278));
    _ = s.step(sample(0, 0, false, 0), cfg);
    try t.expectEqualSlices(Event, &.{.start}, s.step(sample(3_000, 3, false, 3), cfg).slice());
    try t.expectEqual(@as(u8, 0), s.step(sample(4_000, 4, true, 4), cfg).len);
    try t.expectEqual(@as(u8, 0), s.step(sample(5_000, 4, false, 4), cfg).len);
    try t.expectEqual(@as(u8, 0), s.step(sample(9_000, 8, false, 8), cfg).len);
}

test "pause is reported once the paused state holds" {
    // The bus samples every frame; while paused the position is frozen.
    var s = Session.begin(Media.movie(278));
    _ = s.step(sample(0, 0, false, 0), cfg);
    _ = s.step(sample(3_000, 3, false, 3), cfg);
    try t.expectEqual(@as(u8, 0), s.step(sample(4_000, 4, true, 4), cfg).len);
    try t.expectEqual(@as(u8, 0), s.step(sample(6_999, 4, true, 4), cfg).len);
    try t.expectEqualSlices(Event, &.{.pause}, s.step(sample(7_000, 4, true, 4), cfg).slice());
    try t.expectEqual(@as(u8, 0), s.step(sample(20_000, 4, true, 4), cfg).len);
    // Resume is debounced like the first start.
    _ = s.step(sample(21_000, 4, false, 4), cfg);
    try t.expectEqualSlices(Event, &.{.start}, s.step(sample(24_000, 7, false, 7), cfg).slice());
}

test "watched fires once at the 80 percent mark" {
    var s = Session.begin(Media.tvEpisode(1399, 1, 2));
    _ = s.step(sample(0, 0, false, 0), cfg);
    _ = s.step(sample(3_000, 3, false, 3), cfg);
    try t.expectEqual(@as(u8, 0), s.step(sample(80_000, 79.9, false, 79.9), cfg).len);
    try t.expectEqualSlices(Event, &.{.watched}, s.step(sample(81_000, 80, false, 80), cfg).slice());
    try t.expectEqual(@as(u8, 0), s.step(sample(90_000, 90, false, 90), cfg).len);
    // A watched session is complete: no stop on top of the history entry.
    try t.expect(!s.finish());
}

test "seeking to the credits does not mark watched" {
    var s = Session.begin(Media.movie(278));
    _ = s.step(sample(0, 0, false, 0), cfg);
    const e = s.step(sample(3_000, 95, false, 5), cfg);
    try t.expectEqualSlices(Event, &.{.start}, e.slice());
    try t.expect(!s.watched_sent);
}

test "stop after a reported start below the threshold" {
    var s = Session.begin(Media.movie(278));
    _ = s.step(sample(0, 0, false, 0), cfg);
    _ = s.step(sample(3_000, 40, false, 40), cfg);
    try t.expect(s.finish());
    try t.expect(!s.finish());
}

test "samples without a duration are ignored" {
    var s = Session.begin(Media.movie(278));
    var bad = sample(0, 1, false, 1);
    bad.duration = 0;
    try t.expectEqual(@as(u8, 0), s.step(bad, cfg).len);
    bad.duration = std.math.nan(f64);
    try t.expectEqual(@as(u8, 0), s.step(bad, cfg).len);
}

test "dedupe drops a repeated watched mark inside the window" {
    var d: Dedupe = .{};
    const m = Media.tvEpisode(1399, 1, 2);
    try t.expect(d.admit(m, .watched, 0, cfg.dedupe_window_ms));
    // The 90% local commit 20 minutes after the 80% bus mark (a long movie).
    try t.expect(!d.admit(m, .watched, 1_200_000, cfg.dedupe_window_ms));
    // Another episode is independent.
    try t.expect(d.admit(Media.tvEpisode(1399, 1, 3), .watched, 1_200_000, cfg.dedupe_window_ms));
    // Toggling back and forth always delivers.
    try t.expect(d.admit(m, .unwatched, 1_300_000, cfg.dedupe_window_ms));
    try t.expect(d.admit(m, .watched, 1_400_000, cfg.dedupe_window_ms));
    // After the window a rewatch is delivered again.
    try t.expect(d.admit(m, .watched, 1_400_000 + cfg.dedupe_window_ms, cfg.dedupe_window_ms));
}

test "dedupe passes live events and survives ring wraparound" {
    var d: Dedupe = .{};
    try t.expect(d.admit(Media.movie(1), .start, 0, cfg.dedupe_window_ms));
    try t.expect(d.admit(Media.movie(1), .start, 0, cfg.dedupe_window_ms));
    var i: i32 = 0;
    while (i < 40) : (i += 1) try t.expect(d.admit(Media.movie(100 + i), .watched, 0, cfg.dedupe_window_ms));
    try t.expect(!d.admit(Media.movie(139), .watched, 1, cfg.dedupe_window_ms));
}

test "media identity and validity" {
    try t.expect(Media.movie(-77).valid()); // keyless hashed id
    try t.expect(!Media.movie(0).valid());
    try t.expect(!Media.tvEpisode(1399, 1, 0).valid());
    try t.expect(Media.tvEpisode(1399, 0, 1).valid()); // specials
    try t.expect(!Media.anime(0, 3).valid());
    try t.expect(Media.tvEpisode(1, 1, 2).eql(Media.tvEpisode(1, 1, 2)));
    try t.expect(!Media.tvEpisode(1, 1, 2).eql(Media.tvEpisode(1, 2, 2)));
    try t.expect(!Media.movie(5).eql(Media.tvEpisode(5, 0, 0)));
}

test "tracker routing" {
    const movie = Media.movie(278);
    const anime_ep = Media.anime(21, 4);
    try t.expect(routes(.trakt, movie, .start));
    try t.expect(routes(.trakt, movie, .watched));
    try t.expect(!routes(.simkl, movie, .start));
    try t.expect(routes(.simkl, movie, .unwatched));
    try t.expect(!routes(.anilist, movie, .watched));
    try t.expect(routes(.anilist, anime_ep, .watched));
    try t.expect(!routes(.anilist, anime_ep, .unwatched));
    try t.expect(!routes(.trakt, anime_ep, .watched));
    try t.expect(!routes(.simkl, anime_ep, .watched));
}

test "progress percent is clamped" {
    try t.expectEqual(@as(f64, 0), progressPercent(5, 0));
    try t.expectEqual(@as(f64, 100), progressPercent(120, 100));
    try t.expectApproxEqAbs(@as(f64, 42.5), progressPercent(42.5, 100), 0.0001);
}
