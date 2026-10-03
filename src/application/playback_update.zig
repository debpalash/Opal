//! Owner-thread playback progression shared by desktop and headless hosts.
//! Both hosts call this before presenting state. Never drain a resolver only
//! from a widget: its result must progress even with no window or selected tab.
const state = @import("../core/state.zig");

pub fn tick() void {
    state.players_mutex.lock();
    defer state.players_mutex.unlock();
    @import("../services/streamlink.zig").drainResolved();
    @import("../services/youtube_player.zig").drainResolved();
    @import("../player/player.zig").updateTorrentBackgroundTasks();
    @import("../services/jellyfin.zig").drainTranscodeRecovery();
    @import("../services/tmdb.zig").checkEpisodeStartup();
    @import("../services/tmdb.zig").applyPendingDetail();
    @import("../services/anime.zig").applyPendingEpisodes();
    @import("../services/anime.zig").applyPendingPlayback();
    @import("../services/anime_skip.zig").tick();
    @import("../services/audiobookshelf.zig").tick();
    @import("../services/podcasts.zig").tickNowPlaying();
}
