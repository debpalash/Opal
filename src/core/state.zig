const std = @import("std");
const dvui = @import("dvui");
const c = @import("c.zig");
const player = @import("../player/player.zig");
const paths = @import("paths.zig");
const MediaPlayer = player.MediaPlayer;
const thumbnail = @import("../player/thumbnail.zig");
const subtitles_mod = @import("../player/subtitles.zig");

// ══════════════════════════════════════════════════════════
// Type Definitions
// ══════════════════════════════════════════════════════════

pub const GridMode = enum { auto, cols_1, cols_2, cols_3, cols_4 };
pub const ContentProvider = enum { mpv, comic_viewer };
pub const VideoFillMode = enum { fit, cover };
pub const DrawerTab = enum { Search, Downloads, TMDB, YouTube, Queue, Comics, Anime, History, RSS, Jellyfin, Plugins, Logs, Settings, AI, Web };
pub const SettingsTab = enum { General, Playback, Network, Subtitles, Storage, Scripts, LangLearn, FileAssoc };
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
    runtime_ticks: i64 = 0,
    played_ticks: i64 = 0,
    poster_fetching: bool = false,
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
    duration: i64 = 0,
    views: i64 = 0,
    thumbnail_url: [512]u8 = std.mem.zeroes([512]u8),
    thumbnail_url_len: usize = 0,
    thumb_fetching: bool = false,
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
    ui_scale: f32 = 1.3,
    grid_mode: GridMode = .auto,
    seek_sync: bool = false,
    hwdec_enabled: bool = false,
    overlay_hide_timer: i64 = 0,
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
    toast_expire: i64 = 0,
    toast_type: ToastType = .info,
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

    // ── Recently closed players (Ctrl+Shift+T undo stack) ──
    closed_urls: [16][2048]u8 = std.mem.zeroes([16][2048]u8),
    closed_url_lens: [16]usize = std.mem.zeroes([16]usize),
    closed_count: usize = 0,

    // ── Session restore: URLs loaded in players at last exit ──
    session_restore_urls: [16][2048]u8 = std.mem.zeroes([16][2048]u8),
    session_restore_lens: [16]usize = std.mem.zeroes([16]usize),
    session_restore_count: usize = 0,
    session_restore_done: bool = false,
    eq_preset: usize = 0,
    playlist: ?*const @import("../player/m3u.zig").M3UPlaylist = null,
    thumb_state: thumbnail.ThumbnailState = thumbnail.ThumbnailState.init(),
    sub_engine: subtitles_mod.SubtitleEngine = subtitles_mod.SubtitleEngine.init(),

    // ── Torrent / Downloads ──
    torrent_ses: c.mpv.TorrentSession = null,
    pending_magnet_tid: i32 = -1,
    pending_magnet_player_idx: usize = 0,
    pending_source_url: [2048]u8 = std.mem.zeroes([2048]u8),
    pending_source_url_len: usize = 0,
    dropped_file_path: [2048]u8 = std.mem.zeroes([2048]u8),
    dropped_file_len: usize = 0,
    dropped_file_ready: bool = false,
    dropped_file_lock: @import("sync.zig").Mutex = .{},
    pending_has_metadata: bool = false,
    pending_files_selection: [2048]bool = std.mem.zeroes([2048]bool),
    download_rate_limit: i32 = 0,
    save_path_buf: [256]u8 = std.mem.zeroes([256]u8),
    save_path_len: usize = 0,
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
        last_fetch_s: i64 = 0, // SWR cache timestamp (Trending view)
        page: u32 = 1,
        total_pages: u32 = 1,
        results: std.ArrayListUnmanaged(TmdbItem) = .empty,
        favorites: std.ArrayListUnmanaged(TmdbItem) = .empty,
        watchlist: std.ArrayListUnmanaged(TmdbItem) = .empty,
        watching: std.ArrayListUnmanaged(TmdbItem) = .empty,
        search_buf: [256]u8 = std.mem.zeroes([256]u8),
        is_loading: bool = false,
        thread: ?std.Thread = null,
        api_key: [256]u8 = std.mem.zeroes([256]u8),
        api_key_len: usize = 0,
        loaded_once: bool = false,
        // Gallery card target width (px) — user-cyclable compact/normal/large/xl.
        card_w: f32 = 124,
    } = .{},

    // ── OpenSubtitles ──
    opensub_api_key: [128]u8 = std.mem.zeroes([128]u8),
    opensub_api_key_len: usize = 0,
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
    web_remote_enabled: bool = true,
    party_host_ip_buf: [46]u8 = std.mem.zeroes([46]u8),

    // ── Comics ──
    comic: struct {
        search_buf: [256]u8 = std.mem.zeroes([256]u8),
        url_buf: [512]u8 = std.mem.zeroes([512]u8),
        url_len: usize = 0,
        is_loading: bool = false,
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
        view_mode: enum { scroll, single_page } = .scroll,
        current_page: usize = 0,
        dl_progress: usize = 0, // number of images downloaded so far

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
        is_loading: bool = false,
        last_fetch_s: i64 = 0, // SWR cache timestamp (trending)
        thread: ?std.Thread = null,
        results: [32]AnimeResult = std.mem.zeroes([32]AnimeResult),
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
        broadcast: [32][40]u8 = std.mem.zeroes([32][40]u8),
        broadcast_lens: [32]usize = std.mem.zeroes([32]usize),
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

    // ── Browser (global singleton — the in-app web browser lives in the
    //     Browse › Web tab now, independent of any MediaPlayer) ──
    browser: struct {
        url_buf: [2048]u8 = std.mem.zeroes([2048]u8),
        url_len: usize = 0,
        is_loading: bool = false,
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

// ══════════════════════════════════════════════════════════
// Utility Functions
// ══════════════════════════════════════════════════════════

/// Load TMDB token from $ZIGZAG_TMDB_TOKEN env, or fall back to .env file.
pub fn loadTmdbTokenFromEnv() void {
    // 1. Try env var first
    if (if (std.c.getenv("ZIGZAG_TMDB_TOKEN")) |raw| std.mem.span(raw) else null) |token| {
        if (token.len > 0) {
            const len = @min(token.len, app.tmdb.api_key.len);
            @memcpy(app.tmdb.api_key[0..len], token[0..len]);
            app.tmdb.api_key_len = len;
            return;
        }
    }
    // Also check TMDB_API_TOKEN
    if (if (std.c.getenv("TMDB_API_TOKEN")) |raw| std.mem.span(raw) else null) |token| {
        if (token.len > 0) {
            const len = @min(token.len, app.tmdb.api_key.len);
            @memcpy(app.tmdb.api_key[0..len], token[0..len]);
            app.tmdb.api_key_len = len;
            return;
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
    // Search order: cwd (dev: `zig build run`) → ~/.config/zigzag (bundle / installed).
    // First hit wins; later locations are fallbacks.
    var buf: [4096]u8 = undefined;
    var cfg_buf: [512]u8 = undefined;
    const cfg_dir = paths.configDir(&cfg_buf);

    const content = blk: {
        // Try cwd first
        if (readFileAll(".", ".env", &buf)) |bytes| break :blk bytes;
        // Then ~/.config/zigzag/.env
        if (readFileAll(cfg_dir, ".env", &buf)) |bytes| break :blk bytes;
        return;
    };

    const env = @import("env.zig");

    // TMDB — only if not already set from process env
    if (app.tmdb.api_key_len == 0) {
        const keys = [_][]const u8{ "TMDB_API_TOKEN=", "ZIGZAG_TMDB_TOKEN=" };
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
    app.save_path_buf[app.save_path_len] = 0;
    return @ptrCast(&app.save_path_buf);
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
    app.toast_expire = @import("io_global.zig").timestamp() + 3;
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

/// Navigate to the page that hosts a given legacy DrawerTab. Updates BOTH the
/// new page router (+ the relevant Browse/Library/System sub-tab) and the
/// legacy drawer state, so navigation works whether or not page_shell is on.
/// Safe to call from any thread (enum/usize writes; UI reads are per-frame).
pub fn navigateToTab(tab: DrawerTab) void {
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
        .Queue => {
            app.library_tab = .Queue;
            app.router.navigate(.library);
        },
        .History => {
            app.library_tab = .History;
            app.router.navigate(.library);
        },
        .Downloads => {
            app.library_tab = .Downloads;
            app.router.navigate(.library);
        },
        .Jellyfin => {
            app.browse_source = .Jellyfin;
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
