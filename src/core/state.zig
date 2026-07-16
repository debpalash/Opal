const std = @import("std");
const dvui = @import("dvui");
const c = @import("c.zig");
const player = @import("../player/player.zig");
const paths = @import("paths.zig");
const MediaPlayer = player.MediaPlayer;
const thumbnail = @import("../player/thumbnail.zig");
const subtitles_mod = @import("../player/subtitles.zig");
const podcasts_pure = @import("../services/podcasts_pure.zig");
const radio_pure = @import("../services/radio_pure.zig");

// ══════════════════════════════════════════════════════════
// Type Definitions
// ══════════════════════════════════════════════════════════

pub const GridMode = enum { auto, cols_1, cols_2, cols_3, cols_4 };
pub const ContentProvider = enum { mpv, comic_viewer };
pub const VideoFillMode = enum { fit, cover };
pub const DrawerTab = enum { Search, Downloads, TMDB, YouTube, Queue, Comics, Anime, Podcasts, Radio, History, RSS, Jellyfin, Plex, Plugins, Logs, Settings, AI, Web };
pub const SettingsTab = enum { General, Playback, Network, Subtitles, Storage, Scripts, AI, LangLearn, FileAssoc, About };
pub const TmdbView = enum { Trending, Search, Favorites, Watchlist, Watching };
pub const TmdbCategory = enum { trending, now_playing, top_rated, upcoming, popular };
pub const TmdbMediaFilter = enum { all, movie, tv };
pub const TmdbTimeWindow = enum { day, week };

pub const MAX_SEARCH_HISTORY: usize = 50;
pub const MAX_QUERY_LEN: usize = 256;
pub const MAX_DL_HISTORY: usize = 100;
pub const MAX_DL_NAME_LEN: usize = 256;
pub const MAX_DL_LINK_LEN: usize = 4096;

pub const AnimeResult = struct {
    id: [64]u8 = std.mem.zeroes([64]u8),
    id_len: usize = 0,
    name: [128]u8 = std.mem.zeroes([128]u8),
    name_len: usize = 0,
    episodes: u16 = 0,

    score: f32 = 0.0,
    overview: [512]u8 = std.mem.zeroes([512]u8),
    overview_len: usize = 0,
    poster_url: [128]u8 = std.mem.zeroes([128]u8),
    poster_url_len: usize = 0,

    // UI state
    expanded: bool = false,
    poster_fetching: bool = false,
    // Failure latch (mirrors TmdbItem): a completed fetch that produced no
    // pixels marks poster_failed so the grid stops re-spawning a worker every
    // frame. poster_attempted distinguishes "never tried" from "tried & failed".
    poster_attempted: bool = false,
    poster_failed: bool = false,
    poster_pixels: ?[]u8 = null,
    poster_w: u32 = 0,
    poster_h: u32 = 0,
    poster_tex: ?dvui.Texture = null,
};

/// Anime browse modes (Netflix-style mode toolbar).
pub const AnimeMode = enum { trending, seasonal, calendar, search, mylist };

/// Seasonal-mode selector: this season, a specific cour, or upcoming.
pub const AnimeSeasonSel = enum { now, winter, spring, summer, fall, upcoming };

/// One franchise relation (Sequel/Prequel/Side Story/…) for the detail rail.
pub const AnimeRelation = struct {
    mal_id: [16]u8 = std.mem.zeroes([16]u8),
    mal_id_len: usize = 0,
    name: [128]u8 = std.mem.zeroes([128]u8),
    name_len: usize = 0,
    rel_type: [24]u8 = std.mem.zeroes([24]u8), // "Sequel","Prequel","Side Story"…
    rel_type_len: usize = 0,
};

/// One Continue-Watching entry (resume the next episode of a series).
pub const ContinueItem = struct {
    mal_id: [16]u8 = std.mem.zeroes([16]u8),
    mal_id_len: usize = 0,
    title: [128]u8 = std.mem.zeroes([128]u8),
    title_len: usize = 0,
    poster_url: [128]u8 = std.mem.zeroes([128]u8),
    poster_url_len: usize = 0,
    last_episode: u16 = 0,
    total_episodes: u16 = 0,
    // Lazy poster (same pattern as AnimeResult).
    poster_fetching: bool = false,
    // Failure-latch: a worker that ran but produced no pixels marks poster_failed
    // so the renderer stops re-spawning a fetch every frame (thread/alloc storm).
    // poster_attempted distinguishes "never tried" from "tried & failed".
    poster_attempted: bool = false,
    poster_failed: bool = false,
    poster_pixels: ?[]u8 = null,
    poster_w: u32 = 0,
    poster_h: u32 = 0,
    poster_tex: ?dvui.Texture = null,
};

pub const BrowserLink = struct {
    url: [512]u8 = std.mem.zeroes([512]u8),
    url_len: usize = 0,
    text: [128]u8 = std.mem.zeroes([128]u8),
    text_len: usize = 0,
};

/// One TV season (from TMDB /tv/{id} → seasons[]).
pub const TvSeason = struct {
    season_number: i32 = 0,
    name: [64]u8 = std.mem.zeroes([64]u8),
    name_len: usize = 0,
    episode_count: u16 = 0,
    air_date: [12]u8 = std.mem.zeroes([12]u8),
    air_date_len: usize = 0,
    poster_path: [64]u8 = std.mem.zeroes([64]u8),
    poster_path_len: usize = 0,
};

/// One TV episode (from TMDB /tv/{id}/season/{n} → episodes[]).
pub const TvEpisode = struct {
    episode_number: i32 = 0,
    name: [128]u8 = std.mem.zeroes([128]u8),
    name_len: usize = 0,
    overview: [512]u8 = std.mem.zeroes([512]u8),
    overview_len: usize = 0,
    air_date: [12]u8 = std.mem.zeroes([12]u8),
    air_date_len: usize = 0,
    still_path: [80]u8 = std.mem.zeroes([80]u8),
    still_path_len: usize = 0,
    vote_average: f32 = 0,
    runtime: u16 = 0,
    // Episode still image (lazy-loaded from TMDB image CDN on demand)
    still_fetching: bool = false,
    still_attempted: bool = false,
    still_pixels: ?[]u8 = null,
    still_w: u32 = 0,
    still_h: u32 = 0,
    still_tex: ?dvui.Texture = null,
};

/// One TV Continue-Watching entry (resume the next episode of a series).
pub const TvContinueItem = struct {
    tmdb_id: i32 = 0,
    name: [128]u8 = std.mem.zeroes([128]u8),
    name_len: usize = 0,
    poster_path: [64]u8 = std.mem.zeroes([64]u8),
    poster_path_len: usize = 0,
    season: u16 = 0,
    episode: u16 = 0,
};

pub const TmdbItem = struct {
    id: i32 = 0,
    title: [128]u8 = std.mem.zeroes([128]u8),
    title_len: usize = 0,
    year: [8]u8 = std.mem.zeroes([8]u8),
    year_len: usize = 0,
    release_date: [16]u8 = std.mem.zeroes([16]u8),
    release_date_len: usize = 0,
    rating: f32 = 0,
    overview: [512]u8 = std.mem.zeroes([512]u8),
    overview_len: usize = 0,
    media_type: [8]u8 = std.mem.zeroes([8]u8),
    media_type_len: usize = 0,
    genre_text: [64]u8 = std.mem.zeroes([64]u8),
    genre_text_len: usize = 0,
    poster_path: [64]u8 = std.mem.zeroes([64]u8),
    poster_path_len: usize = 0,
    poster_fetching: bool = false,
    // Failure latch: a fetch that completed (fetching true→false) without
    // producing pixels marks poster_failed so the renderer stops re-spawning a
    // worker every frame (thread/alloc storm). poster_attempted distinguishes
    // "never tried" from "tried and failed".
    poster_attempted: bool = false,
    poster_failed: bool = false,
    poster_pixels: ?[]u8 = null,
    poster_w: u32 = 0,
    poster_h: u32 = 0,
    poster_tex: ?dvui.Texture = null,
    expanded: bool = false,
};

pub const JfView = enum { Libraries, Browse, Search, Resume };

pub const JfItem = struct {
    id: [64]u8 = std.mem.zeroes([64]u8),
    id_len: usize = 0,
    name: [256]u8 = std.mem.zeroes([256]u8),
    name_len: usize = 0,
    media_type: [32]u8 = std.mem.zeroes([32]u8),
    media_type_len: usize = 0,
    year: u16 = 0,
    overview: [512]u8 = std.mem.zeroes([512]u8),
    overview_len: usize = 0,
    is_folder: bool = false,
    has_subtitles: bool = false,
    // Item carries a Primary image (parsed from ImageTags) — lets the web
    // companion render a poster card vs. a text-only fallback row.
    has_image: bool = false,
    runtime_ticks: i64 = 0,
    played_ticks: i64 = 0,
    poster_fetching: bool = false,
    // Failure latch (mirrors TmdbItem): a fetch that completed without
    // producing pixels marks poster_failed so the renderer stops re-spawning a
    // worker every frame. poster_attempted distinguishes "never tried" from
    // "tried and failed".
    poster_attempted: bool = false,
    poster_failed: bool = false,
    poster_pixels: ?[]u8 = null,
    poster_w: u32 = 0,
    poster_h: u32 = 0,
    poster_tex: ?dvui.Texture = null,
    expanded: bool = false,
};

pub const JfLibrary = struct {
    id: [64]u8 = std.mem.zeroes([64]u8),
    id_len: usize = 0,
    name: [64]u8 = std.mem.zeroes([64]u8),
    name_len: usize = 0,
    collection_type: [32]u8 = std.mem.zeroes([32]u8),
    collection_type_len: usize = 0,
};

pub const JfNavEntry = struct {
    parent_id: [64]u8 = std.mem.zeroes([64]u8),
    parent_id_len: usize = 0,
    name: [128]u8 = std.mem.zeroes([128]u8),
    name_len: usize = 0,
};

pub const YtItem = struct {
    video_id: [32]u8 = std.mem.zeroes([32]u8),
    video_id_len: usize = 0,
    title: [128]u8 = std.mem.zeroes([128]u8),
    title_len: usize = 0,
    uploader: [64]u8 = std.mem.zeroes([64]u8),
    uploader_len: usize = 0,
    // "UC…" id — powers the clickable channel → channel-videos view.
    channel_id: [32]u8 = std.mem.zeroes([32]u8),
    channel_id_len: usize = 0,
    duration: i64 = 0,
    views: i64 = 0,
    thumbnail_url: [512]u8 = std.mem.zeroes([512]u8),
    thumbnail_url_len: usize = 0,
    thumb_fetching: bool = false,
    // Failure-latch: a thumb worker that ran but produced no pixels (404 /
    // undecodable) marks thumb_failed so the grid stops re-spawning a full
    // HTTP+DB worker every frame. thumb_attempted = "tried" vs "never tried".
    thumb_attempted: bool = false,
    thumb_failed: bool = false,
    thumb_pixels: ?[]u8 = null,
    thumb_w: u32 = 0,
    thumb_h: u32 = 0,
    thumb_tex: ?dvui.Texture = null,
};

// ══════════════════════════════════════════════════════════
// Structured Application State (Phase 2b)
// ══════════════════════════════════════════════════════════

fn initVoiceBuf() [16]u8 {
    var buf: [16]u8 = std.mem.zeroes([16]u8);
    @memcpy(buf[0..4], "Luna");
    return buf;
}

fn initTranslateLangBuf() [8]u8 {
    var buf: [8]u8 = std.mem.zeroes([8]u8);
    @memcpy(buf[0..2], "es");
    return buf;
}

pub const AppState = struct {
    // ── UI ──
    incognito_mode: bool = false,
    // Compact-first default (the type ramp is already dense; a >1× scale
    // over-magnifies and overflows the top-nav row so the omnibox + right-side
    // action icons clip off the window edge). Users who want larger chrome can
    // raise it in Settings › General › UI Scale.
    ui_scale: f32 = 1.0,
    // When true (the default), ui_scale is DERIVED from the display's DPI each
    // launch via scale_pure.deviceScale (compact on high-DPI, readable on
    // standard-DPI) instead of using a saved fixed value. Picking a specific
    // scale in Settings sets this false so the manual choice sticks. See
    // main.zig's first-frame application and config load/save.
    ui_scale_auto: bool = true,
    // Set true once config.load() has run, so the first frame can safely
    // decide whether to apply the auto device scale (config load is async on
    // the init worker; without this the device scale could race the saved
    // ui_scale/ui_scale_auto values).
    // Release/acquire atomic: the detached config worker stores `true` AFTER it
    // has applied every saved pref (incl. tmdb.api_key bytes+len), so a UI/worker
    // thread that loads `true` with .acquire is guaranteed to see the fully
    // published key — fixes both the fire-before-ready race and the torn key read
    // that left the first-launch Trending fetch permanently empty.
    config_loaded: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    grid_mode: GridMode = .auto,
    seek_sync: bool = false,
    // Hardware video decoding (VideoToolbox/VAAPI/D3D11 via mpv "auto-safe").
    // ON by default — software decode was the main CPU eater during playback;
    // auto-safe falls back to software per-codec when hw fails, so there's no
    // compatibility downside. Persisted as "hwdec2" (legacy "hwdec" rows were
    // auto-persisted 0 and are deliberately ignored — apfel-migration pattern).
    hwdec_enabled: bool = true,
    show_cell_overlay: bool = true,
    hovered_cell_idx: ?usize = null,
    video_fill_mode: VideoFillMode = .fit,
    cheatsheet_open: bool = false,
    media_info_open: bool = false,
    stats_overlay_open: bool = false,
    sub_picker_open: bool = false,
    playlist_drawer_open: bool = false,
    last_mouse_x: f32 = 0,
    last_mouse_y: f32 = 0,
    last_mouse_move_ms: i64 = 0,
    magnet_buf: [2048]u8 = std.mem.zeroes([2048]u8),
    drawer_open: bool = false,
    drawer_tab: DrawerTab = .Search,
    drawer_width_px: f32 = 640.0,

    // ── Page-shell redesign (see ui/shell.zig) ──
    // The new website-like page router is the default UI. Set OPAL_PAGE_SHELL=0
    // to fall back to the legacy header+grid+drawer layout.
    page_shell_enabled: bool = true,
    router: @import("router.zig").History = .{},
    // In-page sub-navigation for the shell's Browse / Library / System routes.
    browse_source: DrawerTab = .TMDB,
    library_tab: DrawerTab = .Queue,
    system_tab: DrawerTab = .Logs,

    // dvui window handle — set once in appInit. Stored here so worker
    // threads (e.g. the mpv render-update callback) can wake the UI loop
    // via dvui.refresh(win, @src(), null) from any thread.
    dvui_win: ?*dvui.Window = null,

    // Headless server mode: when true, the app runs without a window/display.
    // mpv stays fully active for audio + control, but no render context is
    // created and no pixel buffer is allocated. Default false → windowed mode
    // is byte-identical to before.
    is_headless: bool = false,

    // Window geometry persistence
    win_x: i32 = 0,
    win_y: i32 = 0,
    win_w: i32 = 1440,
    win_h: i32 = 800,
    win_restore_pending: bool = false,
    is_drawer_resizing: bool = false,
    drawer_expanded: bool = false,
    drawer_saved_width: f32 = 640.0,
    rss_show_add: bool = false,
    dragging_magnet_buf: [4096]u8 = std.mem.zeroes([4096]u8),
    dragging_magnet_len: usize = 0,
    last_clicked_search_idx: usize = 99999,
    last_clicked_time: i64 = 0,
    nsfw_filter_enabled: bool = true,
    // "Personalized suggestions (local-only)" — gates the activity/taste
    // engine (services/activity.zig): recording AND the Home "For You" row.
    taste_enabled: bool = true,
    universal_search: bool = true, // Default to universal mode (the king feature)
    nsfw_confirm_pending: bool = false,
    nsfw_confirm_link_buf: [4096]u8 = std.mem.zeroes([4096]u8),
    nsfw_confirm_link_len: usize = 0,
    nsfw_confirm_name_buf: [256]u8 = std.mem.zeroes([256]u8),
    nsfw_confirm_name_len: usize = 0,
    settings_open: bool = false,
    settings_tab: SettingsTab = .General,
    deps_modal_open: bool = false,
    deps_modal_checked: bool = false,
    toast_buf: [128]u8 = std.mem.zeroes([128]u8),
    toast_len: usize = 0,
    toast_expire: i64 = 0, // wall-clock ms deadline (milliTimestamp), NOT seconds
    toast_type: ToastType = .info,
    // Monotonic per-toast id. Keys the toast fade-in's AnimateWidget id so each
    // new toast re-triggers the fade — toast_expire has only 1s granularity, so
    // two toasts in the same second would otherwise collide and the 2nd wouldn't
    // fade (see footer.renderToast).
    toast_seq: u64 = 0,
    config_dirty: bool = false,
    last_config_save: i64 = 0,
    // ── Usage metrics (Home dashboard) ──
    usage_seconds_total: i64 = 0, // persisted lifetime seconds in-app
    usage_last_tick: i64 = 0, // last accrual timestamp (in-memory)
    session_start_s: i64 = 0, // this session's launch timestamp (in-memory)
    proxy_url: [128]u8 = std.mem.zeroes([128]u8), // e.g. "socks5://127.0.0.1:1080"
    proxy_url_len: usize = 0,

    // ── Workspace UI ──
    ws_save_open: bool = false,
    ws_load_open: bool = false,
    ws_name_input: [64]u8 = std.mem.zeroes([64]u8),
    ws_names: [16][64]u8 = std.mem.zeroes([16][64]u8),
    ws_name_lens: [16]usize = std.mem.zeroes([16]usize),
    ws_count: usize = 0,

    // ── Player ──
    players: std.ArrayListUnmanaged(*MediaPlayer) = .empty,
    active_player_idx: usize = 0,
    fullscreen_player_idx: ?usize = null,
    pending_remove_player_idx: i32 = -1,
    auto_advance: bool = true,
    // ── M3U playlist playback behavior (drawer Playlist tab) ──
    // Advance decisions route through player/playlist_pure.zig
    // (nextIndex/prevIndex). Persisted as config keys like auto_advance.
    playlist_repeat: @import("../player/playlist_pure.zig").RepeatMode = .off,
    playlist_shuffle: bool = false,

    // ── Recently closed players (Ctrl+Shift+T undo stack) ──
    closed_urls: [16][2048]u8 = std.mem.zeroes([16][2048]u8),
    closed_url_lens: [16]usize = std.mem.zeroes([16]usize),
    closed_count: usize = 0,

    // ── Session restore: URLs loaded in players at last exit ──
    session_restore_urls: [16][2048]u8 = std.mem.zeroes([16][2048]u8),
    session_restore_lens: [16]usize = std.mem.zeroes([16]usize),
    session_restore_count: usize = 0,
    session_restore_done: bool = false,

    // ── Pending TV watch commit ──
    // Armed when the user launches an episode; committed (DB + Trakt +
    // Continue-Watching upsert + in-memory flag) only after playback actually
    // progresses past the threshold (tmdb_pure.tvWatchCommitDue, ~2min) —
    // clicking ▶ alone no longer marks anything watched. Written by the UI
    // thread on arm; read + committed from the player event thread (bool
    // flip-gated, same convention as the worker-written watched flags).
    pending_watch: struct {
        armed: bool = false,
        committed: bool = false,
        tmdb_id: i32 = 0,
        season: i32 = 0,
        episode: i32 = 0,
        name: [128]u8 = std.mem.zeroes([128]u8),
        name_len: usize = 0,
        poster_path: [64]u8 = std.mem.zeroes([64]u8),
        poster_path_len: usize = 0,
    } = .{},

    /// Which episode the player is currently playing, for the whole playback.
    ///
    /// Distinct from `pending_watch`, which is *consumed* at the 2-minute watch
    /// commit and so cannot carry this. The player needs the binding to persist
    /// for the entire session in order to save a per-episode resume position into
    /// tv_watched (keyed by tmdb_id+season+episode — real episode identity, unlike
    /// watch_history, whose `name` PK holds a torrent display name or a URL
    /// depending on which of its two writers got there first).
    ///
    /// The binding is to a specific stream URL, not just "an episode is playing".
    /// `armed` is set when an episode is launched; the next file the player loads
    /// claims it and copies its URL into `url`, at which point `active` is true.
    /// Save/resume then only fire when the player's current URL MATCHES.
    ///
    /// Without that URL guard, playing an episode and then playing a movie would
    /// write the movie's position into the episode's resume row and then resume
    /// the movie at the episode's timestamp — the binding has to end when the
    /// media does.
    playing_episode: struct {
        armed: bool = false,
        active: bool = false,
        tmdb_id: i32 = 0,
        season: i32 = 0,
        episode: i32 = 0,
        url: [4096]u8 = std.mem.zeroes([4096]u8),
        url_len: usize = 0,

        pub fn matches(self: *const @This(), url: []const u8) bool {
            return self.active and self.url_len > 0 and
                std.mem.eql(u8, self.url[0..self.url_len], url);
        }
    } = .{},

    // First-run onboarding: false until the wizard finishes (or an existing
    // install is grandfathered — see config.zig load).
    onboarded: bool = false,

    // ── "Resume last played?" launch prompt (replaces silent session restore) ──
    init_history_loaded: bool = false, // set on the init worker after watch.load()
    resume_prompt_checked: bool = false, // one-shot: armed once watch history loads
    resume_prompt_active: bool = false, // banner currently shown
    resume_prompt_link: [2048]u8 = std.mem.zeroes([2048]u8), // URL/magnet/path to reopen
    resume_prompt_link_len: usize = 0,
    resume_prompt_label: [128]u8 = std.mem.zeroes([128]u8), // cleaned title for the banner
    resume_prompt_label_len: usize = 0,
    resume_prompt_pct: u8 = 0, // saved progress (0–100)
    resume_prompt_pos_secs: f64 = 0, // exact saved position; 0 = percent-only legacy row
    eq_preset: usize = 0,
    // Video color filters — persisted i32 in mpv's -100..100 range. Replayed at
    // player init (player.zig) so they survive restart / apply to new files;
    // written by the Settings ± buttons and clamped via av_pure.clampVideoFilter.
    vf_brightness: i32 = 0,
    vf_contrast: i32 = 0,
    vf_saturation: i32 = 0,
    vf_gamma: i32 = 0,
    // Mutable: the drawer's move-up/move-down reorder swaps entries in place.
    playlist: ?*@import("../player/m3u.zig").M3UPlaylist = null,
    thumb_state: thumbnail.ThumbnailState = thumbnail.ThumbnailState.init(),
    sub_engine: subtitles_mod.SubtitleEngine = subtitles_mod.SubtitleEngine.init(),

    // ── Torrent / Downloads ──
    // Written once by the detached torrent_init() worker after a 5-10s DHT
    // bootstrap, read every frame by the UI + remote threads. Atomic with
    // acquire/release ordering — access via state.torrentSession() /
    // state.setTorrentSession() (never touch the field directly).
    torrent_ses: std.atomic.Value(c.mpv.TorrentSession) = std.atomic.Value(c.mpv.TorrentSession).init(null),
    pending_magnet_tid: i32 = -1,
    pending_magnet_player_idx: usize = 0,
    pending_source_url: [2048]u8 = std.mem.zeroes([2048]u8),
    pending_source_url_len: usize = 0,
    dropped_file_path: [2048]u8 = std.mem.zeroes([2048]u8),
    dropped_file_len: usize = 0,
    dropped_file_ready: bool = false,
    dropped_file_lock: @import("sync.zig").Mutex = .{},
    // Path/URL forwarded by a second `opal <file>` launch (remote /api/open,
    // written on an API connection thread). appFrame consumes it on the UI
    // thread via browser.loadContent — the same route a direct CLI open takes.
    remote_open_path: [2048]u8 = std.mem.zeroes([2048]u8),
    remote_open_len: usize = 0,
    remote_open_ready: bool = false,
    remote_open_lock: @import("sync.zig").Mutex = .{},
    pending_has_metadata: bool = false,
    pending_files_selection: [2048]bool = std.mem.zeroes([2048]bool),
    download_rate_limit: i32 = 0,
    // ── HTTP downloader (services/download_engine.zig) ──
    /// Connections per HTTP download (segmented Range requests). Clamped 1..8.
    http_dl_segments: u32 = 4,
    /// Simultaneous HTTP downloads; the rest queue FIFO. Clamped 1..8.
    http_dl_max_concurrent: u32 = 3,
    save_path_buf: [256]u8 = std.mem.zeroes([256]u8),
    save_path_len: usize = 0,

    // Stashed right before a TMDB-linked play (movie search or TV episode)
    // kicks off a torrent resolve, so whichever call site next sets a
    // player's current_torrent_id (see search.zig's addMagnetToEngine) can
    // copy it onto that player's loading_* fields for the poster+trivia
    // loading screen. Cleared once consumed so it can't leak onto an
    // unrelated later magnet (e.g. a raw drag-dropped torrent).
    pending_play_title: [128]u8 = std.mem.zeroes([128]u8),
    pending_play_title_len: usize = 0,
    pending_play_poster_path: [64]u8 = std.mem.zeroes([64]u8),
    pending_play_poster_path_len: usize = 0,
    pending_play_overview: [400]u8 = std.mem.zeroes([400]u8),
    pending_play_overview_len: usize = 0,
    pending_play_is_tv: bool = false,

    // Directory that holds bundled runtime resources (engines/, scripts/, …).
    // Empty = use the current working directory (dev: launched from project
    // root). Set at startup to the macOS bundle's Resources dir when the app is
    // launched from /Applications (CWD is "/" there, so relative paths fail).
    resource_root: [1024]u8 = std.mem.zeroes([1024]u8),
    resource_root_len: usize = 0,
    ytdl_format_idx: usize = 1,
    sub_lang_buf: [8]u8 = [_]u8{ 'e', 'n', 'g', 0, 0, 0, 0, 0 },
    sub_lang_len: usize = 3,

    // ── Search & Download History ──
    search_history_buf: [MAX_SEARCH_HISTORY][MAX_QUERY_LEN]u8 = std.mem.zeroes([MAX_SEARCH_HISTORY][MAX_QUERY_LEN]u8),
    search_history_len: [MAX_SEARCH_HISTORY]usize = std.mem.zeroes([MAX_SEARCH_HISTORY]usize),
    search_history_count: usize = 0,
    dl_history_names: [MAX_DL_HISTORY][MAX_DL_NAME_LEN]u8 = std.mem.zeroes([MAX_DL_HISTORY][MAX_DL_NAME_LEN]u8),
    dl_history_name_lens: [MAX_DL_HISTORY]usize = std.mem.zeroes([MAX_DL_HISTORY]usize),
    dl_history_links: [MAX_DL_HISTORY][MAX_DL_LINK_LEN]u8 = std.mem.zeroes([MAX_DL_HISTORY][MAX_DL_LINK_LEN]u8),
    dl_history_link_lens: [MAX_DL_HISTORY]usize = std.mem.zeroes([MAX_DL_HISTORY]usize),
    dl_history_count: usize = 0,

    // ── TMDB ──
    tmdb: struct {
        view: TmdbView = .Trending,
        category: TmdbCategory = .trending,
        media_filter: TmdbMediaFilter = .all,
        time_window: TmdbTimeWindow = .week,
        // Index into tmdb_pure.GENRES (0 = All genres → category endpoints;
        // otherwise browse goes through /discover with with_genres).
        genre_idx: usize = 0,
        // Discover sort (genre mode only): tag for tmdb_pure.discoverSortParam
        // — 0=popularity, 1=rating, 2=newest.
        discover_sort: u8 = 0,
        last_fetch_s: i64 = 0, // SWR cache timestamp (Trending view)
        page: u32 = 1,
        total_pages: u32 = 1,
        // `results` is UI-THREAD-OWNED: only the UI thread mutates it (the
        // frame-start apply in tmdb_api.applyPendingResults + shutdown deinit).
        // Fetch workers stage into `pending_results` under `results_mutex`;
        // the worker used to clear/append `results` directly, which raced the
        // render loop iterating it → renderCatalogRail out-of-bounds panic
        // (crash reports 2026-07-03). Non-UI READERS (remote HTTP thread,
        // ai_intent worker) must hold `results_mutex` too — the apply mutates
        // under that same lock.
        results: std.ArrayListUnmanaged(TmdbItem) = .empty,
        pending_results: std.ArrayListUnmanaged(TmdbItem) = .empty,
        pending_append: bool = false,
        pending_total_pages: u32 = 1,
        pending_ready: bool = false,
        results_mutex: @import("sync.zig").Mutex = .{},
        favorites: std.ArrayListUnmanaged(TmdbItem) = .empty,
        watchlist: std.ArrayListUnmanaged(TmdbItem) = .empty,
        watching: std.ArrayListUnmanaged(TmdbItem) = .empty,
        search_buf: [256]u8 = std.mem.zeroes([256]u8),
        // Atomic: written by detached fetch workers, read by UI/remote/ai threads
        // (matches yt.is_loading / jellyfin loaders). A plain bool here is a data race.
        is_loading: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        thread: ?std.Thread = null,
        api_key: [256]u8 = std.mem.zeroes([256]u8),
        api_key_len: usize = 0,
        loaded_once: bool = false,
        // Gallery card target width (px) — user-cyclable compact/normal/large/xl.
        card_w: f32 = 124,

        // ── TV seasons/episodes detail (Netflix-style drill-down) ──
        // Opened by clicking a media_type=="tv" card. seasons from /tv/{id};
        // episodes from /tv/{id}/season/{n}; episode → resolver play; watched
        // flags persisted via db tv_watched.
        tv_detail_open: bool = false,
        tv_id: i32 = 0,
        tv_name: [128]u8 = std.mem.zeroes([128]u8),
        tv_name_len: usize = 0,
        tv_poster_path: [64]u8 = std.mem.zeroes([64]u8),
        tv_poster_path_len: usize = 0,
        tv_seasons: [40]TvSeason = std.mem.zeroes([40]TvSeason),
        tv_season_count: usize = 0,
        tv_sel_season: usize = 0, // index into tv_seasons
        tv_seasons_loading: bool = false,
        tv_episodes: [120]TvEpisode = std.mem.zeroes([120]TvEpisode),
        tv_episode_count: usize = 0,
        tv_episodes_loading: bool = false,
        // episode N of the selected season → tv_episode_watched[N-1].
        tv_episode_watched: [120]bool = std.mem.zeroes([120]bool),
    } = .{},

    // ── OpenSubtitles ──
    opensub_api_key: [128]u8 = std.mem.zeroes([128]u8),
    opensub_api_key_len: usize = 0,

    // ── OMDb (omdbapi.com) ratings enrichment ──
    // User-supplied free key (omdbapi.com, 1k/day). Empty → the OMDb worker is
    // fully inert (no fetch). Persisted like tmdb/opensub keys; see config.zig.
    omdb_api_key: [128]u8 = std.mem.zeroes([128]u8),
    omdb_api_key_len: usize = 0,

    // ── Subdl (api.subdl.com) subtitle provider ──
    // User-supplied FREE per-user key (subdl.com → panel → API). Empty → the
    // Subdl provider is fully inert (no fetch). Persisted like the other keys;
    // see config.zig. Downloads arrive as ZIP archives (extracted in-process).
    subdl_api_key: [128]u8 = std.mem.zeroes([128]u8),
    subdl_api_key_len: usize = 0,
    // Auto-download subtitles when a video starts and none are present
    // (embedded or sidecar). Needs opensub_api_key; no-ops silently without it.
    auto_download_subs: bool = true,
    sub_search_buf: [256]u8 = std.mem.zeroes([256]u8),

    // ── MPV Scripts ──
    scripts_scanned: bool = false,
    script_names: [32][128]u8 = std.mem.zeroes([32][128]u8),
    script_name_lens: [32]usize = std.mem.zeroes([32]usize),
    script_paths: [32][512]u8 = std.mem.zeroes([32][512]u8),
    script_path_lens: [32]usize = std.mem.zeroes([32]usize),
    script_enabled: [32]bool = [_]bool{true} ** 32,
    script_count: usize = 0,

    // ── YouTube ──
    yt: struct {
        search_buf: [256]u8 = std.mem.zeroes([256]u8),
        results: std.ArrayListUnmanaged(YtItem) = .empty,
        is_loading: std.atomic.Value(bool) = .init(false),
        thread: ?std.Thread = null,
        loaded_once: bool = false,
        last_fetch_s: i64 = 0, // SWR cache timestamp
    } = .{},
    sponsorblock_enabled: bool = true,
    deband_enabled: bool = true,
    video_scaler: u8 = 0, // 0=ewa_lanczossharp, 1=bilinear, 2=spline36
    // Web Remote JSON API (:41595). OFF by default — nothing should listen on
    // app start unless the user opted in (Settings › Scripts › Web Remote
    // Control). Persisted, so an explicit enable sticks across launches. The
    // OpalMenubar helper and web/ UI need this on to reach the app.
    web_remote_enabled: bool = false,
    party_host_ip_buf: [46]u8 = std.mem.zeroes([46]u8),

    // ── Comics ──
    comic: struct {
        search_buf: [256]u8 = std.mem.zeroes([256]u8),
        url_buf: [512]u8 = std.mem.zeroes([512]u8),
        url_len: usize = 0,
        is_loading: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        // Deferred comic-load request from the remote API thread. loadComic()
        // frees page textures via dvui (UI-thread-only), so the remote thread sets
        // this and the UI thread drains it at frame top (cf. pending_remove_player_idx).
        pending_load_url: [512]u8 = std.mem.zeroes([512]u8),
        pending_load_len: usize = 0,
        pending_load: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        thread: ?std.Thread = null,
        page_urls: [128][512]u8 = std.mem.zeroes([128][512]u8),
        page_url_lens: [128]usize = std.mem.zeroes([128]usize),
        page_count: usize = 0,
        page_pixels: [128]?[]u8 = [_]?[]u8{null} ** 128,
        page_widths: [128]u32 = std.mem.zeroes([128]u32),
        page_heights: [128]u32 = std.mem.zeroes([128]u32),
        page_textures: [128]?dvui.Texture = [_]?dvui.Texture{null} ** 128,
        title: [256]u8 = std.mem.zeroes([256]u8),
        title_len: usize = 0,
        next_url: [512]u8 = std.mem.zeroes([512]u8),
        next_url_len: usize = 0,
        prev_url: [512]u8 = std.mem.zeroes([512]u8),
        prev_url_len: usize = 0,
        // Referer header a content-plugin's resolve response supplied for page
        // image fetches (some manga CDNs 403 without it). Empty → the fetch
        // worker derives the referer from each image URL's own origin. Replaced
        // a hardcoded coffeemanga.io referer that broke every other source.
        referer: [512]u8 = std.mem.zeroes([512]u8),
        referer_len: usize = 0,
        view_mode: enum { scroll, single_page } = .scroll,
        current_page: usize = 0,
        dl_progress: std.atomic.Value(usize) = std.atomic.Value(usize).init(0), // images downloaded (atomic: written by ≤8 concurrent workers)
        // ── Download cancellation (UAF guard) ──
        // loadComic/closeComic bump `dl_gen` to invalidate in-flight page
        // download workers spawned for a PREVIOUS comic; `dl_in_flight` counts
        // active download writers so freeComicPages can wait for them to drain
        // before freeing page_pixels. See services/comics.zig.
        dl_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        dl_in_flight: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        // ── Comic Narration (OCR + TTS) ──
        ocr_texts: [128][4096]u8 = std.mem.zeroes([128][4096]u8),
        ocr_lens: [128]usize = std.mem.zeroes([128]usize),
        ocr_done: [128]bool = [_]bool{false} ** 128,
        narrating: bool = false,
        narrate_page: usize = 0,
        show_ocr_overlay: bool = false, // show OCR text overlay on current page
        scroll_to_page: bool = false, // signal render to scroll to comic_current_page
        ocr_thread: ?std.Thread = null,
        narrate_thread: ?std.Thread = null,
    } = .{},

    // ── Anime ──
    anime: struct {
        search_buf: [256]u8 = std.mem.zeroes([256]u8),
        // Atomic like the tmdb/yt/jf loaders: read by the UI + remote API threads,
        // written by detached fetch workers. A plain bool here is a data race.
        is_loading: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        last_fetch_s: i64 = 0, // SWR cache timestamp (trending)
        thread: ?std.Thread = null,
        results: [100]AnimeResult = std.mem.zeroes([100]AnimeResult),
        result_count: usize = 0,
        selected_idx: ?usize = null,
        episodes: [512]u8 = std.mem.zeroes([512]u8),
        episodes_len: usize = 0,
        episode_list: [200][8]u8 = std.mem.zeroes([200][8]u8),
        episode_list_lens: [200]usize = std.mem.zeroes([200]usize),
        episode_titles: [200][80]u8 = std.mem.zeroes([200][80]u8),
        episode_title_lens: [200]usize = std.mem.zeroes([200]usize),
        episode_aired: [200][12]u8 = std.mem.zeroes([200][12]u8),
        episode_aired_lens: [200]usize = std.mem.zeroes([200]usize),
        episode_scores: [200]f32 = std.mem.zeroes([200]f32),
        episode_filler: [200]bool = std.mem.zeroes([200]bool),
        episode_count: usize = 0,
        episodes_loading: bool = false,
        stream_loading: bool = false,

        // ── Netflix/Apple-TV+ browse: modes, seasons, calendar, tracking ──
        // The card grid (results[]) is reused by every grid mode; each mode just
        // fetches differently. See services/anime.zig.
        mode: AnimeMode = .trending,
        season_sel: AnimeSeasonSel = .now, // Seasonal mode selector
        season_year: u16 = 2026, // year for winter/spring/summer/fall
        cal_day: u8 = 0, // Calendar mode: 0=all, 1=Mon … 7=Sun
        // Per-result broadcast string ("Mondays at 01:00 (JST)") for Calendar.
        broadcast: [100][40]u8 = std.mem.zeroes([100][40]u8),
        broadcast_lens: [100]usize = std.mem.zeroes([100]usize),
        // Detail view: "Seasons & Related" rail (Jikan relations).
        relations: [16]AnimeRelation = std.mem.zeroes([16]AnimeRelation),
        relation_count: usize = 0,
        relations_loading: bool = false,
        // Tracking: per-episode watched flags for the selected anime (loaded
        // from db when episodes load); episode N → episode_watched[N-1].
        episode_watched: [200]bool = std.mem.zeroes([200]bool),
        // Continue-Watching rail (My List mode), loaded from db.
        continue_items: [12]ContinueItem = std.mem.zeroes([12]ContinueItem),
        continue_count: usize = 0,
        continue_loaded: bool = false,
    } = .{},

    // ── Podcasts (iTunes Search API → RSS episodes → audio via mpv) ──
    // Structural sibling of `anime`: search → show → episode list → play. All
    // parsing lives in services/podcasts_pure.zig; fetch workers publish here
    // under podcasts.zig's parse_mutex. See services/podcasts.zig.
    podcasts: struct {
        search_buf: [256]u8 = std.mem.zeroes([256]u8),
        // Atomic like the anime/jf loaders: read by the UI + remote API threads,
        // written by detached fetch workers. A plain bool here is a data race.
        is_loading: std.atomic.Value(bool) = .init(false),
        episodes_loading: std.atomic.Value(bool) = .init(false),
        fetch_error: bool = false,
        // True while results[] holds the once-per-session popular chart rather
        // than a user search — drives the grid heading only. Plain bool like
        // fetch_error (written by the UI/remote thread that starts the fetch).
        showing_popular: bool = false,
        results: [50]podcasts_pure.Podcast = std.mem.zeroes([50]podcasts_pure.Podcast),
        result_count: usize = 0,
        selected_idx: ?usize = null,
        // Selected show's name, snapshot for the episode-view header (results[]
        // may be reordered by a fresh search while episodes are open).
        selected_name: [160]u8 = std.mem.zeroes([160]u8),
        selected_name_len: usize = 0,
        episodes: [200]podcasts_pure.Episode = std.mem.zeroes([200]podcasts_pure.Episode),
        episode_count: usize = 0,
    } = .{},

    // ── Internet Radio (RadioBrowser API → audio stream via mpv) ──
    // One level shallower than `podcasts`: search → station list → play. All
    // parsing lives in services/radio_pure.zig; the fetch worker publishes here
    // under radio.zig's parse_mutex. See services/radio.zig.
    radio: struct {
        search_buf: [256]u8 = std.mem.zeroes([256]u8),
        // Atomic like the podcasts/anime loaders: read by the UI + remote API
        // threads, written by the detached fetch worker. A plain bool is a race.
        is_loading: std.atomic.Value(bool) = .init(false),
        fetch_error: bool = false,
        // True while results[] holds the once-per-session most-voted stations
        // rather than a user search — drives the grid heading only.
        showing_popular: bool = false,
        results: [30]radio_pure.Station = std.mem.zeroes([30]radio_pure.Station),
        result_count: usize = 0,
    } = .{},

    // ── Browser (global singleton — the in-app web browser lives in the
    //     Browse › Web tab now, independent of any MediaPlayer) ──
    browser: struct {
        url_buf: [2048]u8 = std.mem.zeroes([2048]u8),
        url_len: usize = 0,
        is_loading: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        thread: ?std.Thread = null,
        title: [256]u8 = std.mem.zeroes([256]u8),
        title_len: usize = 0,
        content: ?[]u8 = null, // stripped text content
        links: [128]BrowserLink = std.mem.zeroes([128]BrowserLink),
        link_count: usize = 0,
        history: [32][2048]u8 = std.mem.zeroes([32][2048]u8),
        history_lens: [32]usize = std.mem.zeroes([32]usize),
        history_count: usize = 0,
        history_pos: usize = 0,
    } = .{},

    // ── Language Learning ──
    lang_learn_enabled: bool = false,
    tts_voice_buf: [16]u8 = initVoiceBuf(),
    tts_voice_len: usize = 4,
    tts_speed: f32 = 1.0,
    tts_server_ok: bool = false,
    tts_health_check_time: i64 = 0,
    translate_enabled: bool = false,
    translate_lang_buf: [8]u8 = initTranslateLangBuf(),
    translate_lang_len: usize = 2,
    asr_enabled: bool = false,
    // Live-ASR (experimental): transcribe PLAYBACK audio for un-subtitled
    // content. OFF by default — needs an audio loopback device (see live_asr.zig).
    live_asr_enabled: bool = false,
    asr_text_buf: [1024]u8 = std.mem.zeroes([1024]u8),
    asr_text_len: usize = 0,
    asr_busy: bool = false,
    asr_last_pos: f64 = -1.0,
    dubbing_enabled: bool = false,
    dub_busy: bool = false,

    // ── Jellyfin ──
    jf: struct {
        server_url: [256]u8 = std.mem.zeroes([256]u8),
        server_url_len: usize = 0,
        token: [256]u8 = std.mem.zeroes([256]u8),
        token_len: usize = 0,
        user_id: [64]u8 = std.mem.zeroes([64]u8),
        user_id_len: usize = 0,
        connected: bool = false,
        is_loading: std.atomic.Value(bool) = .init(false),
        thread: ?std.Thread = null,
        view: JfView = .Libraries,
        items: [64]JfItem = std.mem.zeroes([64]JfItem),
        item_count: usize = 0,
        libraries: [16]JfLibrary = std.mem.zeroes([16]JfLibrary),
        library_count: usize = 0,
        search_buf: [256]u8 = std.mem.zeroes([256]u8),
        parent_id: [64]u8 = std.mem.zeroes([64]u8),
        parent_id_len: usize = 0,
        parent_name: [128]u8 = std.mem.zeroes([128]u8),
        parent_name_len: usize = 0,
        login_user_buf: [128]u8 = std.mem.zeroes([128]u8),
        login_pass_buf: [128]u8 = std.mem.zeroes([128]u8),
        login_error: [128]u8 = std.mem.zeroes([128]u8),
        login_error_len: usize = 0,
        resume_items: [16]JfItem = std.mem.zeroes([16]JfItem),
        resume_count: usize = 0,
        resume_loaded: std.atomic.Value(bool) = .init(false),
        nav_stack: [8]JfNavEntry = std.mem.zeroes([8]JfNavEntry),
        nav_depth: usize = 0,
    } = .{},
    dub_last_hash: u64 = 0,
};

/// The single global application state instance.
pub var app: AppState = .{};

/// Atomic accessors for the torrent session pointer (see AppState.torrent_ses).
/// The detached init worker publishes the session with setTorrentSession();
/// every reader (UI + remote threads) loads it with torrentSession().
pub fn torrentSession() c.mpv.TorrentSession {
    return app.torrent_ses.load(.acquire);
}
pub fn setTorrentSession(s: c.mpv.TorrentSession) void {
    app.torrent_ses.store(s, .release);
}

/// Re-apply the persisted download rate limit to the torrent session, but only
/// once BOTH the session AND a positive saved limit are ready. The session
/// (torrent_init worker) and the config (config load worker) come up on
/// independent threads, so this is called idempotently from both edges —
/// whichever finishes last actually applies the cap. A fresh torrent_init()
/// session defaults to unlimited, so without this the saved limit stayed
/// inactive until the user re-touched the control.
pub fn applyDownloadLimitIfReady() void {
    const lim = @import("../player/av_pure.zig").sanitizeDownloadLimit(app.download_rate_limit);
    if (lim <= 0) return;
    const ses = torrentSession();
    if (ses == null) return;
    c.mpv.torrent_set_download_limit(ses, lim);
}

/// Serializes player teardown (UI thread frees players at frame top) against the
/// remote API server thread, which captures a *MediaPlayer and drives mpv on it.
/// Without this the remote thread can dereference a freed player → use-after-free.
/// Both the UI teardown (orderedRemove + deinit) and the remote player-dispatch
/// hold this.
pub var players_mutex: @import("sync.zig").Mutex = .{};

// ══════════════════════════════════════════════════════════
// Utility Functions
// ══════════════════════════════════════════════════════════

/// Load TMDB token from the environment ($OPAL_TMDB_TOKEN, $TMDB_API_TOKEN,
/// or legacy $ZIGZAG_TMDB_TOKEN), or fall back to .env file.
pub fn loadTmdbTokenFromEnv() void {
    // 1. Try env vars first (new name, generic name, legacy name).
    const env_names = [_][*:0]const u8{ "OPAL_TMDB_TOKEN", "TMDB_API_TOKEN", "ZIGZAG_TMDB_TOKEN" };
    for (env_names) |name| {
        if (if (std.c.getenv(name)) |raw| std.mem.span(raw) else null) |token| {
            if (token.len > 0) {
                const len = @min(token.len, app.tmdb.api_key.len);
                @memcpy(app.tmdb.api_key[0..len], token[0..len]);
                app.tmdb.api_key_len = len;
                return;
            }
        }
    }
    // 2. Fall back to .env file in cwd
    loadTmdbFromDotEnv();
}

fn readFileAll(dir_path: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    const io = @import("io_global.zig").io();
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return null;
    defer dir.close(io);
    const file = dir.openFile(io, name, .{}) catch return null;
    defer file.close(io);
    const n = file.readPositionalAll(io, buf, 0) catch return null;
    return buf[0..n];
}

fn loadTmdbFromDotEnv() void {
    // Search order: cwd (dev: `zig build run`) → ~/.config/opal (bundle / installed).
    // First hit wins; later locations are fallbacks.
    var buf: [4096]u8 = undefined;
    var cfg_buf: [512]u8 = undefined;
    const cfg_dir = paths.configDir(&cfg_buf);

    const content = blk: {
        // Try cwd first
        if (readFileAll(".", ".env", &buf)) |bytes| break :blk bytes;
        // Then ~/.config/opal/.env
        if (readFileAll(cfg_dir, ".env", &buf)) |bytes| break :blk bytes;
        return;
    };

    const env = @import("env.zig");

    // TMDB — only if not already set from process env
    if (app.tmdb.api_key_len == 0) {
        const keys = [_][]const u8{ "TMDB_API_TOKEN=", "OPAL_TMDB_TOKEN=", "ZIGZAG_TMDB_TOKEN=" };
        for (keys) |key| {
            if (env.findValue(content, key)) |token| {
                const len = @min(token.len, app.tmdb.api_key.len);
                @memcpy(app.tmdb.api_key[0..len], token[0..len]);
                app.tmdb.api_key_len = len;
                break;
            }
        }
    }

    // OpenSubtitles key — same pattern
    if (app.opensub_api_key_len == 0) {
        if (env.findValue(content, "OPENSUB_API_KEY=")) |token| {
            const len = @min(token.len, app.opensub_api_key.len);
            @memcpy(app.opensub_api_key[0..len], token[0..len]);
            app.opensub_api_key_len = len;
        }
    }
}

/// Initialize download path from $HOME (called at runtime in appInit).
pub fn initPaths() void {
    var tmp: [256]u8 = undefined;
    const default = paths.defaultSavePath(&tmp);
    const len = @min(default.len, app.save_path_buf.len);
    @memcpy(app.save_path_buf[0..len], default[0..len]);
    app.save_path_len = len;
}

/// Get null-terminated save path for C API calls.
pub fn getSavePath() [*c]const u8 {
    // Clamp: if save_path_len == buf.len, writing the NUL at [save_path_len]
    // would be one byte past the end (buffer overflow).
    const i = @min(app.save_path_len, app.save_path_buf.len - 1);
    app.save_path_buf[i] = 0;
    return @ptrCast(&app.save_path_buf);
}

/// Directory holding bundled runtime resources (engines/, scripts/, …), or null
/// to use the current working directory. Set once at startup. Used as the child
/// working directory for `python3 engines/nova2.py` and similar relative spawns
/// so streaming works from a /Applications launch (CWD "/") as well as dev.
pub fn resourceRoot() ?[]const u8 {
    if (app.resource_root_len == 0) return null;
    return app.resource_root[0..app.resource_root_len];
}

/// Stash context for a TMDB-linked play (movie search or TV episode) right
/// before it kicks off a torrent resolve. Consumed by addMagnetToEngine
/// (search.zig) when the resolved torrent actually attaches to a player, so
/// the loading screen can show this title's poster + a trivia blurb instead
/// of a bare hourglass. Overwrites any previous unconsumed stash.
pub fn stashPendingPlay(title: []const u8, poster_path: []const u8, overview: []const u8, is_tv: bool) void {
    app.pending_play_title_len = @min(title.len, app.pending_play_title.len);
    @memcpy(app.pending_play_title[0..app.pending_play_title_len], title[0..app.pending_play_title_len]);
    app.pending_play_poster_path_len = @min(poster_path.len, app.pending_play_poster_path.len);
    @memcpy(app.pending_play_poster_path[0..app.pending_play_poster_path_len], poster_path[0..app.pending_play_poster_path_len]);
    app.pending_play_overview_len = @min(overview.len, app.pending_play_overview.len);
    @memcpy(app.pending_play_overview[0..app.pending_play_overview_len], overview[0..app.pending_play_overview_len]);
    app.pending_play_is_tv = is_tv;
}

/// Show a toast notification for 3 seconds.
pub const ToastType = enum(u8) {
    info,
    success,
    warning,
    err,
};

pub fn showToast(msg: []const u8) void {
    showToastTyped(msg, .info);
}

pub fn showToastTyped(msg: []const u8, toast_type: ToastType) void {
    const copy_len = @min(msg.len, app.toast_buf.len - 1);
    @memcpy(app.toast_buf[0..copy_len], msg[0..copy_len]);
    app.toast_len = copy_len;
    app.toast_expire = @import("io_global.zig").milliTimestamp() + 3500; // ms — fine-grained so the toast can fade out
    app.toast_seq +%= 1;
    // Auto-detect type from common emoji prefixes if caller used .info
    if (toast_type == .info and copy_len >= 2) {
        const txt = app.toast_buf[0..copy_len];
        if (std.mem.startsWith(u8, txt, "\xe2\x9c\x93") or // ✓
            std.mem.startsWith(u8, txt, "\xf0\x9f\x93\xb8") or // 📸
            std.mem.startsWith(u8, txt, "\xe2\x9c\x85")) // ✅
        {
            app.toast_type = .success;
        } else if (std.mem.startsWith(u8, txt, "\xe2\x9a\xa0") or // ⚠
            std.mem.startsWith(u8, txt, "\xf0\x9f\x95\xb6")) // 🕶
        {
            app.toast_type = .warning;
        } else if (std.mem.indexOf(u8, txt, "ailed") != null or
            std.mem.indexOf(u8, txt, "rror") != null)
        {
            app.toast_type = .err;
        } else {
            app.toast_type = .info;
        }
    } else {
        app.toast_type = toast_type;
    }
}

pub fn markConfigDirty() void {
    app.config_dirty = true;
}

/// Wake the UI thread so a state change made off-frame (worker completion,
/// deferred navigation) renders now instead of after the next mouse move.
/// Safe from any thread — dvui.refresh with an explicit window routes through
/// the backend. No-op before appInit stores the window.
pub fn wakeUi() void {
    if (app.dvui_win) |w| dvui.refresh(w, @src(), null);
}

/// Deferred cross-thread navigation. router.History.navigate() is a multi-step
/// non-atomic mutation on arrays the UI thread reads every frame; AI tools and
/// resolver callbacks used to call it directly from worker threads — a race
/// that could publish back_len before the back[] store and hand the render
/// switch an undefined Route byte. Workers now enqueue the tab here (single
/// atomic store) and appFrame applies it on the UI thread.
/// Encoding: 0 = none, else @intFromEnum(tab) + 1.
pub var pending_nav: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

/// Navigate to the page that hosts a given legacy DrawerTab — from ANY thread.
/// The actual router mutation is deferred to the next appFrame on the UI
/// thread (applyPendingNav); wakeUi() makes that frame happen immediately.
pub fn navigateToTab(tab: DrawerTab) void {
    pending_nav.store(@import("nav_pure.zig").encode(DrawerTab, tab), .release);
    wakeUi();
}

/// Consume a deferred navigateToTab request. Call once per frame from
/// appFrame, before rendering.
pub fn applyPendingNav() void {
    const v = pending_nav.swap(0, .acq_rel);
    if (v == 0) return;
    const tab = @import("nav_pure.zig").decode(DrawerTab, v) orelse return; // corrupted — drop rather than crash
    navigateToTabNow(tab);
}

/// Navigate to the page that hosts a given legacy DrawerTab. Updates BOTH the
/// new page router (+ the relevant Browse/Library/System sub-tab) and the
/// legacy drawer state, so navigation works whether or not page_shell is on.
/// UI THREAD ONLY — off-thread callers must use navigateToTab().
pub fn navigateToTabNow(tab: DrawerTab) void {
    app.drawer_tab = tab; // legacy drawer
    app.drawer_open = true;
    switch (tab) {
        .Search => app.router.navigate(.search),
        .TMDB => app.router.navigate(.home),
        .YouTube => {
            app.browse_source = .YouTube;
            app.router.navigate(.browse);
        },
        .Anime => {
            app.browse_source = .Anime;
            app.router.navigate(.browse);
        },
        .Podcasts => {
            app.browse_source = .Podcasts;
            app.router.navigate(.browse);
        },
        .Radio => {
            app.browse_source = .Radio;
            app.router.navigate(.browse);
        },
        .Comics => {
            app.browse_source = .Comics;
            app.router.navigate(.browse);
        },
        .Web => {
            app.browse_source = .Web;
            app.router.navigate(.browse);
        },
        .RSS => {
            app.browse_source = .RSS;
            app.router.navigate(.browse);
        },
        .Queue => app.router.navigate(.queue),
        .History => app.router.navigate(.history),
        .Downloads => app.router.navigate(.downloads),
        .Jellyfin => {
            app.browse_source = .Jellyfin;
            app.router.navigate(.browse);
        },
        .Plex => {
            app.browse_source = .Plex;
            app.router.navigate(.browse);
        },
        .Plugins => {
            app.system_tab = .Plugins;
            app.router.navigate(.system);
        },
        .Logs => {
            app.system_tab = .Logs;
            app.router.navigate(.system);
        },
        .Settings => app.router.navigate(.settings),
        .AI => app.router.navigate(.assistant),
    }
}

/// Reveal the player: switch to the Player route (shell) and close the legacy
/// drawer so the grid is visible. Call from every playback entry point.
pub fn gotoPlayer() void {
    app.drawer_open = false;
    app.router.navigate(.player);
}

/// Push a URL onto the recently-closed stack (ring buffer, max 16).
pub fn pushClosedUrl(url: []const u8) void {
    if (url.len == 0) return;
    const slot = app.closed_count % 16;
    const copy_len = @min(url.len, 2048);
    @memcpy(app.closed_urls[slot][0..copy_len], url[0..copy_len]);
    app.closed_url_lens[slot] = copy_len;
    app.closed_count += 1;
}

/// Pop the most recently closed URL. Returns the slice, or null if empty.
pub fn popClosedUrl(buf: *[2048]u8) ?[]const u8 {
    if (app.closed_count == 0) return null;
    app.closed_count -= 1;
    const slot = app.closed_count % 16;
    const len = app.closed_url_lens[slot];
    if (len == 0) return null;
    @memcpy(buf[0..len], app.closed_urls[slot][0..len]);
    app.closed_url_lens[slot] = 0;
    return buf[0..len];
}
