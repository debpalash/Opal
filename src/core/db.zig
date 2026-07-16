const std = @import("std");
const paths = @import("paths.zig");
const ai_memory = @import("../services/ai_memory.zig");

// ══════════════════════════════════════════════════════════
// SQLite3 C Bindings
// ══════════════════════════════════════════════════════════

pub const c = @cImport({
    @cInclude("sqlite3.h");
    @cInclude("core/sqlite/sqlite-vec.h");
});

pub const Sqlite3 = c.sqlite3;
pub const Stmt = c.sqlite3_stmt;

var db_handle: ?*Sqlite3 = null;
var initialized: bool = false;

// ══════════════════════════════════════════════════════════
// Lifecycle
// ══════════════════════════════════════════════════════════

pub fn init() void {
    if (initialized) return;

    // Ensure config dir exists
    var dir_buf: [512]u8 = undefined;
    const dir = paths.configDir(&dir_buf);
    @import("io_global.zig").cwdMakePath(dir) catch {};

    // Register sqlite-vec extension automatically for every new DB connection
    _ = c.sqlite3_auto_extension(@ptrCast(&c.sqlite3_vec_init));

    // Open database
    var path_buf: [512]u8 = undefined;
    const db_path = paths.zigzagDbFile(&path_buf);

    var cpath_buf: [512]u8 = undefined;
    const cpath = std.fmt.bufPrintZ(&cpath_buf, "{s}", .{db_path}) catch return;

    // SQLITE_OPEN_FULLMUTEX = serialized threading mode: SQLite takes its own
    // mutex on every API call, making this ONE shared connection safe to use
    // from the UI thread and the background init/load + jellyfin/tmdb workers
    // concurrently. Plain sqlite3_open() inherits the library's compile-time
    // default (multi-thread on macOS's libsqlite3), where two threads on one
    // connection corrupt its internals → segfault in sqlite3Prepare. That's
    // the "Opal quit unexpectedly" crash on file-open launch, where the
    // worker's createTables races the first home.render query (2026-07-03).
    const open_flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
    if (c.sqlite3_open_v2(cpath.ptr, &db_handle, open_flags, null) != c.SQLITE_OK) {
        db_handle = null;
        return;
    }

    // Register sqlite-vec on THIS connection too. The auto_extension above is
    // a silent no-op on Apple's libsqlite3 ("process-global auto extensions
    // are not supported on Apple platforms"), which left every vec0 CREATE
    // TABLE failing quietly — no vec_aimemory, no vec_taste. sqlite-vec is
    // compiled with -DSQLITE_CORE (build.zig) so the direct call is safe.
    _ = c.sqlite3_vec_init(db_handle, null, null);

    // Performance tuning
    exec("PRAGMA journal_mode=WAL");
    exec("PRAGMA synchronous=NORMAL");
    exec("PRAGMA cache_size=-8000"); // 8MB
    exec("PRAGMA temp_store=MEMORY");
    exec("PRAGMA mmap_size=268435456"); // 256MB mmap

    // ── Create all tables ──
    createTables();
    initialized = true;
}

pub fn deinit() void {
    if (db_handle) |d| {
        // v2 auto-finalizes any leaked prepared statements, preventing SQLITE_BUSY
        _ = c.sqlite3_close_v2(d);
        db_handle = null;
    }
    initialized = false;
}

pub fn get() ?*Sqlite3 {
    return db_handle;
}

// ══════════════════════════════════════════════════════════
// Schema
// ══════════════════════════════════════════════════════════

fn createTables() void {
    // Config (key-value settings)
    exec(
        \\CREATE TABLE IF NOT EXISTS config (
        \\  key TEXT PRIMARY KEY,
        \\  value TEXT NOT NULL DEFAULT ''
        \\)
    );

    // Search history
    exec(
        \\CREATE TABLE IF NOT EXISTS search_history (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  query TEXT NOT NULL UNIQUE,
        \\  searched_at INTEGER DEFAULT (strftime('%s','now'))
        \\)
    );

    // Download history
    exec(
        \\CREATE TABLE IF NOT EXISTS download_history (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  name TEXT NOT NULL,
        \\  link TEXT DEFAULT '',
        \\  downloaded_at INTEGER DEFAULT (strftime('%s','now'))
        \\)
    );

    // Watch history (playback resume positions)
    exec(
        \\CREATE TABLE IF NOT EXISTS watch_history (
        \\  name TEXT PRIMARY KEY,
        \\  percent REAL DEFAULT 0,
        \\  position_secs REAL DEFAULT 0,
        \\  duration_secs REAL DEFAULT 0,
        \\  link TEXT DEFAULT '',
        \\  updated_at INTEGER DEFAULT (strftime('%s','now'))
        \\)
    );

    // Migration: add position_secs if missing
    exec("ALTER TABLE watch_history ADD COLUMN position_secs REAL DEFAULT 0");
    exec("ALTER TABLE watch_history ADD COLUMN duration_secs REAL DEFAULT 0");

    // Total Recall: scene memories store a playback position alongside the
    // aimemory row. Idempotent — exec() swallows the duplicate-column error
    // just like the watch_history migrations above.
    exec("ALTER TABLE aimemory ADD COLUMN position_secs REAL DEFAULT 0");

    // TMDB items
    exec(
        \\CREATE TABLE IF NOT EXISTS tmdb_items (
        \\  id INTEGER PRIMARY KEY,
        \\  title TEXT NOT NULL DEFAULT '',
        \\  year TEXT DEFAULT '',
        \\  release_date TEXT DEFAULT '',
        \\  rating REAL DEFAULT 0,
        \\  overview TEXT DEFAULT '',
        \\  media_type TEXT DEFAULT 'movie',
        \\  genre_text TEXT DEFAULT '',
        \\  poster_path TEXT DEFAULT '',
        \\  created_at INTEGER DEFAULT (strftime('%s','now'))
        \\)
    );

    // TMDB user lists (favorites, watchlist, watching)
    exec(
        \\CREATE TABLE IF NOT EXISTS tmdb_lists (
        \\  item_id INTEGER NOT NULL,
        \\  list_name TEXT NOT NULL,
        \\  added_at INTEGER DEFAULT (strftime('%s','now')),
        \\  PRIMARY KEY (item_id, list_name)
        \\)
    );

    // TMDB poster cache
    exec(
        \\CREATE TABLE IF NOT EXISTS poster_cache (
        \\  item_id INTEGER PRIMARY KEY,
        \\  jpeg_data BLOB,
        \\  width INTEGER DEFAULT 0,
        \\  height INTEGER DEFAULT 0,
        \\  cached_at INTEGER DEFAULT (strftime('%s','now'))
        \\)
    );
    // Supports the periodic prune's `ORDER BY cached_at DESC LIMIT 5000`
    // subquery (poster.zig cacheStore) — avoids a full-table sort under cache_lock.
    exec("CREATE INDEX IF NOT EXISTS idx_poster_cached_at ON poster_cache(cached_at)");

    // In-app browser bookmarks (Browse › Web star button)
    exec(
        \\CREATE TABLE IF NOT EXISTS browser_bookmarks (
        \\  url TEXT PRIMARY KEY,
        \\  title TEXT,
        \\  added_at INTEGER DEFAULT (strftime('%s','now'))
        \\)
    );

    // Vector DB extensions for RAG Memory
    exec(
        \\CREATE TABLE IF NOT EXISTS aimemory (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  role TEXT,
        \\  content TEXT,
        \\  context_type TEXT, -- 'chat' or 'media'
        \\  media_title TEXT,
        \\  timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    );

    exec(
        \\CREATE VIRTUAL TABLE IF NOT EXISTS vec_aimemory USING vec0(
        \\  id INTEGER PRIMARY KEY,
        \\  embedding float[768]
        \\)
    );

    // ── Local taste engine (services/activity.zig) ──
    // Event log: what the user played/finished/abandoned/searched/queued.
    // Local-only; rows are droppable via Settings "Clear taste data".
    exec(
        \\CREATE TABLE IF NOT EXISTS activity_log (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  ts INTEGER DEFAULT (strftime('%s','now')),
        \\  kind TEXT NOT NULL,
        \\  title TEXT NOT NULL DEFAULT '',
        \\  key TEXT DEFAULT '',
        \\  genre TEXT DEFAULT '',
        \\  season_hint INTEGER DEFAULT 0,
        \\  percent_watched REAL DEFAULT 0
        \\)
    );
    exec("CREATE INDEX IF NOT EXISTS idx_activity_ts ON activity_log(ts DESC)");

    // Item identity for the taste vectors — vec_taste shares its rowid
    // (the aimemory/vec_aimemory pattern above), keyed by the activity key.
    exec(
        \\CREATE TABLE IF NOT EXISTS taste_items (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  key TEXT UNIQUE NOT NULL,
        \\  title TEXT DEFAULT '',
        \\  genre TEXT DEFAULT ''
        \\)
    );

    // 128 must match taste_pure.DIM (deterministic token-hash featurizer).
    exec(
        \\CREATE VIRTUAL TABLE IF NOT EXISTS vec_taste USING vec0(
        \\  id INTEGER PRIMARY KEY,
        \\  embedding float[128]
        \\)
    );

    // Indexes
    exec("CREATE INDEX IF NOT EXISTS idx_search_at ON search_history(searched_at DESC)");
    exec("CREATE INDEX IF NOT EXISTS idx_dl_at ON download_history(downloaded_at DESC)");
    exec("CREATE INDEX IF NOT EXISTS idx_watch_at ON watch_history(updated_at DESC)");
    exec("CREATE INDEX IF NOT EXISTS idx_lists_name ON tmdb_lists(list_name)");

    // ── Cross-Session Memory ──

    // Conversation log — persists important exchanges across sessions
    exec(
        \\CREATE TABLE IF NOT EXISTS conversation_log (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  role TEXT NOT NULL,
        \\  content TEXT NOT NULL,
        \\  session_id TEXT,
        \\  created_at INTEGER DEFAULT (strftime('%s','now'))
        \\)
    );
    exec("CREATE INDEX IF NOT EXISTS idx_convo_at ON conversation_log(created_at DESC)");

    // User preferences — learned from behavior
    exec(
        \\CREATE TABLE IF NOT EXISTS user_preferences (
        \\  key TEXT PRIMARY KEY,
        \\  value TEXT NOT NULL,
        \\  weight REAL DEFAULT 1.0,
        \\  updated_at INTEGER DEFAULT (strftime('%s','now'))
        \\)
    );

    // Watch sessions — detailed tracking for completion/abandon patterns
    exec(
        \\CREATE TABLE IF NOT EXISTS watch_sessions (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  title TEXT NOT NULL,
        \\  genre TEXT DEFAULT '',
        \\  duration_secs REAL DEFAULT 0,
        \\  watched_secs REAL DEFAULT 0,
        \\  completed BOOLEAN DEFAULT 0,
        \\  source TEXT DEFAULT '',
        \\  started_at INTEGER DEFAULT (strftime('%s','now')),
        \\  ended_at INTEGER
        \\)
    );
    exec("CREATE INDEX IF NOT EXISTS idx_wsess_at ON watch_sessions(started_at DESC)");

    // AI chat — persist starred messages so pins survive restart.
    // role: 0=user, 1=assistant, 2=system. Only starred rows saved.
    const ai_chat_schema =
        \\CREATE TABLE IF NOT EXISTS ai_chat_starred (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  role INTEGER NOT NULL,
        \\  text TEXT NOT NULL,
        \\  created_at INTEGER DEFAULT (strftime('%s','now'))
        \\)
    ;
    exec(ai_chat_schema);
    exec("CREATE INDEX IF NOT EXISTS idx_ai_chat_starred_at ON ai_chat_starred(created_at DESC)");

    // ── Anime episode tracking ──

    // Per-episode watched flags, keyed by (mal_id, episode).
    exec(
        \\CREATE TABLE IF NOT EXISTS anime_watched (
        \\  mal_id TEXT NOT NULL,
        \\  episode INTEGER NOT NULL,
        \\  watched INTEGER DEFAULT 1,
        \\  updated_at INTEGER,
        \\  PRIMARY KEY (mal_id, episode)
        \\)
    );

    // Continue-watching rail: one row per series, most-recent first.
    exec(
        \\CREATE TABLE IF NOT EXISTS anime_continue (
        \\  mal_id TEXT PRIMARY KEY,
        \\  title TEXT,
        \\  poster_url TEXT,
        \\  last_episode INTEGER,
        \\  total_episodes INTEGER,
        \\  updated_at INTEGER
        \\)
    );
    exec("CREATE INDEX IF NOT EXISTS idx_anime_continue_at ON anime_continue(updated_at DESC)");

    // ── TV-show episode tracking ──

    // Per-episode watched flags, keyed by (tmdb_id, season, episode).
    exec(
        \\CREATE TABLE IF NOT EXISTS tv_watched (
        \\  tmdb_id INTEGER NOT NULL,
        \\  season INTEGER NOT NULL,
        \\  episode INTEGER NOT NULL,
        \\  watched INTEGER DEFAULT 1,
        \\  updated_at INTEGER,
        \\  PRIMARY KEY (tmdb_id, season, episode)
        \\)
    );

    // Continue-watching rail: one row per series, most-recent first.
    //
    // DEPRECATED — superseded by tv_shows. It stored the LAST WATCHED episode,
    // which every consumer then had to turn into "what's next" on its own, and
    // none of them agreed. Nothing reads or writes it any more; it is kept only
    // so the one-time carry-over below can run, and because dropping a user's
    // table is irreversible.
    exec(
        \\CREATE TABLE IF NOT EXISTS tv_continue (
        \\  tmdb_id INTEGER PRIMARY KEY,
        \\  name TEXT,
        \\  poster_path TEXT,
        \\  season INTEGER,
        \\  episode INTEGER,
        \\  updated_at INTEGER
        \\)
    );
    exec("CREATE INDEX IF NOT EXISTS idx_tv_continue_at ON tv_continue(updated_at DESC)");

    // Per-episode resume position. tv_watched's PK (tmdb_id, season, episode) IS
    // episode identity, so this is the one place a mid-episode position can live
    // without colliding with anything. (watch_history keys on a torrent display
    // name OR a URL depending on which of its two writers got there first — the
    // TV path deliberately does not depend on it.)
    // Idempotent — exec() swallows the duplicate-column error on re-run.
    exec("ALTER TABLE tv_watched ADD COLUMN position_secs REAL DEFAULT 0");
    exec("ALTER TABLE tv_watched ADD COLUMN duration_secs REAL DEFAULT 0");

    // One row per tracked show. `tracked` is the explicit Track/Untrack flag;
    // untracking never deletes tv_watched rows, so re-tracking restores progress.
    exec(
        \\CREATE TABLE IF NOT EXISTS tv_shows (
        \\  tmdb_id INTEGER PRIMARY KEY,
        \\  name TEXT,
        \\  poster_path TEXT,
        \\  tracked INTEGER DEFAULT 1,
        \\  status TEXT DEFAULT '',
        \\  last_aired_season INTEGER DEFAULT 0,
        \\  last_aired_episode INTEGER DEFAULT 0,
        \\  next_season INTEGER DEFAULT 0,
        \\  next_episode INTEGER DEFAULT 0,
        \\  next_air_epoch INTEGER DEFAULT 0,
        \\  next_name TEXT DEFAULT '',
        \\  added_at INTEGER,
        \\  updated_at INTEGER
        \\)
    );
    exec("CREATE INDEX IF NOT EXISTS idx_tv_shows_at ON tv_shows(updated_at DESC)");

    // The season map — episode counts per season. Without this, "next up" cannot
    // cross a season boundary, because nothing knows that S01 ends at episode 10.
    exec(
        \\CREATE TABLE IF NOT EXISTS tv_seasons (
        \\  tmdb_id INTEGER NOT NULL,
        \\  season INTEGER NOT NULL,
        \\  episode_count INTEGER DEFAULT 0,
        \\  PRIMARY KEY (tmdb_id, season)
        \\)
    );

    // User-set library status, for EVERY kind of trackable content (tv / anime /
    // movie) rather than a column on tv_shows — anime keys off a MAL id and a
    // movie off its name, so a TV-only column could never hold them.
    //
    // This is the status the USER chose by hand; it always beats the derived one.
    // The two legitimately disagree: a show you abandoned still has a next
    // episode, and one you've declared Completed shouldn't nag you forever
    // because TMDB added a special.
    exec(
        \\CREATE TABLE IF NOT EXISTS library_status (
        \\  kind TEXT NOT NULL,
        \\  item_id TEXT NOT NULL,
        \\  status TEXT NOT NULL,
        \\  updated_at INTEGER,
        \\  PRIMARY KEY (kind, item_id)
        \\)
    );

    // Carry existing continue-watching shows into tv_shows, once. OR IGNORE makes
    // it idempotent and keeps a real tv_shows row from being clobbered by the
    // stale tv_continue one. No data is at risk: watched history lives in
    // tv_watched and is untouched by this.
    exec(
        \\INSERT OR IGNORE INTO tv_shows(tmdb_id, name, poster_path, tracked, added_at, updated_at)
        \\SELECT tmdb_id, name, poster_path, 1, updated_at, updated_at FROM tv_continue
    );
}

// ══════════════════════════════════════════════════════════
// Helpers (exported for other modules)
// ══════════════════════════════════════════════════════════

pub fn exec(sql: [*:0]const u8) void {
    const d = db_handle orelse return;
    _ = c.sqlite3_exec(d, sql, null, null, null);
}

pub fn prepare(sql: []const u8) ?*Stmt {
    const d = db_handle orelse return null;
    var stmt: ?*Stmt = null;
    if (c.sqlite3_prepare_v2(d, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) return null;
    return stmt;
}

pub fn finalize(stmt: ?*Stmt) void {
    _ = c.sqlite3_finalize(stmt);
}

pub fn step(stmt: ?*Stmt) c_int {
    return c.sqlite3_step(stmt);
}

pub fn bindInt(stmt: ?*Stmt, col: c_int, val: i32) void {
    _ = c.sqlite3_bind_int(stmt, col, val);
}

pub fn bindInt64(stmt: ?*Stmt, col: c_int, val: i64) void {
    _ = c.sqlite3_bind_int64(stmt, col, val);
}

pub fn bindDouble(stmt: ?*Stmt, col: c_int, val: f64) void {
    _ = c.sqlite3_bind_double(stmt, col, val);
}

fn getTransient() c.sqlite3_destructor_type {
    @setRuntimeSafety(false);
    var transient_ptr_int: usize = std.math.maxInt(usize);
    transient_ptr_int += 0;
    return @ptrFromInt(transient_ptr_int);
}

pub fn bindText(stmt: ?*Stmt, col: c_int, text: []const u8) void {
    _ = c.sqlite3_bind_text(stmt, col, text.ptr, @intCast(text.len), getTransient());
}

pub fn bindBlob(stmt: ?*Stmt, col: c_int, data: []const u8) void {
    _ = c.sqlite3_bind_blob(stmt, col, data.ptr, @intCast(data.len), getTransient());
}

pub fn columnInt(stmt: ?*Stmt, col: c_int) i32 {
    return c.sqlite3_column_int(stmt, col);
}

/// Read a 64-bit column. Required for anything written by `bindInt64` — notably
/// millisecond timestamps, which are ~1.75e12 and would silently truncate to
/// garbage through `columnInt`'s i32.
pub fn columnInt64(stmt: ?*Stmt, col: c_int) i64 {
    return c.sqlite3_column_int64(stmt, col);
}

pub fn columnDouble(stmt: ?*Stmt, col: c_int) f64 {
    return c.sqlite3_column_double(stmt, col);
}

pub fn columnText(stmt: ?*Stmt, col: c_int) ?[]const u8 {
    const ptr = c.sqlite3_column_text(stmt, col);
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    if (ptr == null or len == 0) return null;
    return @as([*]const u8, @ptrCast(ptr))[0..len];
}

pub fn columnBlob(stmt: ?*Stmt, col: c_int) ?[]const u8 {
    const ptr = c.sqlite3_column_blob(stmt, col);
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    if (ptr == null or len == 0) return null;
    return @as([*]const u8, @ptrCast(ptr))[0..len];
}

/// Copy a TEXT column into a fixed-size buffer + length field.
pub fn copyColumn(stmt: ?*Stmt, col: c_int, dest: []u8, len_ptr: *usize) void {
    if (columnText(stmt, col)) |txt| {
        const copy_len = @min(txt.len, dest.len - 1);
        @memcpy(dest[0..copy_len], txt[0..copy_len]);
        len_ptr.* = copy_len;
    }
}

pub fn insertMemory(role: []const u8, content: []const u8, context_type: []const u8, media_title: []const u8, embed: []const f32) void {
    const d = db_handle orelse return;

    // 1. Insert Text Memory
    const stmt = prepare("INSERT INTO aimemory(role, content, context_type, media_title) VALUES(?, ?, ?, ?)");
    if (stmt == null) return;
    defer finalize(stmt);

    bindText(stmt, 1, role);
    bindText(stmt, 2, content);
    bindText(stmt, 3, context_type);
    bindText(stmt, 4, media_title);

    if (step(stmt) != c.SQLITE_DONE) return;

    const rowid = c.sqlite3_last_insert_rowid(d);

    // 2. Insert Vector Memory
    const vec_stmt = prepare("INSERT INTO vec_aimemory(rowid, embedding) VALUES(?, ?)");
    if (vec_stmt == null) return;
    defer finalize(vec_stmt);

    bindInt64(vec_stmt, 1, rowid);

    // Cast []const f32 into []const u8 for BLOB binding
    const embed_bytes = std.mem.sliceAsBytes(embed);
    bindBlob(vec_stmt, 2, embed_bytes);

    _ = step(vec_stmt);
}

pub fn retrieveMemory(allocator: std.mem.Allocator, embed: []const f32, limit: i32) ?[]u8 {
    _ = db_handle orelse return null;

    const sql =
        \\SELECT rowid, distance
        \\FROM vec_aimemory
        \\WHERE embedding MATCH ? AND k = ?
        \\ORDER BY distance ASC
    ;
    const stmt = prepare(sql) orelse return null;
    defer finalize(stmt);

    const embed_bytes = std.mem.sliceAsBytes(embed);
    bindBlob(stmt, 1, embed_bytes);
    bindInt(stmt, 2, limit);

    var buf: [8192]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    const writer = &fbs;

    // Prepare metadata statement ONCE before the loop (was per-row before)
    const md_stmt = prepare("SELECT role, content, context_type, media_title, timestamp FROM aimemory WHERE id = ?");
    if (md_stmt == null) return null;
    defer finalize(md_stmt);

    var count: usize = 0;
    while (step(stmt) == c.SQLITE_ROW) {
        const rowid = columnInt(stmt, 0);

        // Reuse pre-prepared metadata statement
        _ = c.sqlite3_reset(md_stmt);
        bindInt(md_stmt, 1, rowid);
        if (step(md_stmt) == c.SQLITE_ROW) {
            const role = columnText(md_stmt, 0) orelse "system";
            const content = columnText(md_stmt, 1) orelse "";
            const ctype = columnText(md_stmt, 2) orelse "chat";
            const title = columnText(md_stmt, 3) orelse "";
            const ts = columnText(md_stmt, 4) orelse "";

            if (std.mem.eql(u8, ctype, "media")) {
                writer.print("[{s}] System: Started Playing context: {s}\n", .{ ts, title }) catch {};
            } else {
                writer.print("[{s}] {s}: {s}\n", .{ ts, role, content }) catch {};
            }
            count += 1;
        }
    }

    if (count == 0) {
        return null;
    }
    return allocator.dupe(u8, fbs.buffered()) catch null;
}

// ══════════════════════════════════════════════════════════
// Total Recall — scene memories (timestamped, spoiler-clamped)
// ══════════════════════════════════════════════════════════

pub const SceneHit = struct {
    title: [256]u8 = std.mem.zeroes([256]u8),
    title_len: usize = 0,
    position_secs: f64 = 0,
};

/// Persist a single scene memory. Mirrors insertMemory but stamps
/// context_type="scene", media_title=title and the new position_secs column.
/// When `embed` is non-null and well-formed it is also written to vec_aimemory
/// (rowid-linked) for cosine recall; when null the aimemory row is still
/// inserted so the keyword/LIKE fallback in retrieveScene can find it.
pub fn insertSceneMemory(title: []const u8, content: []const u8, position_secs: f64, embed: ?[]const f32) void {
    const d = db_handle orelse return;

    // 1. Insert text memory (always — this is what FTS/keyword fallback hits).
    const stmt = prepare("INSERT INTO aimemory(role, content, context_type, media_title, position_secs) VALUES(?, ?, ?, ?, ?)");
    if (stmt == null) return;
    defer finalize(stmt);

    bindText(stmt, 1, "scene");
    bindText(stmt, 2, content);
    bindText(stmt, 3, "scene");
    bindText(stmt, 4, title);
    bindDouble(stmt, 5, position_secs);

    if (step(stmt) != c.SQLITE_DONE) return;

    const rowid = c.sqlite3_last_insert_rowid(d);

    // 2. Insert vector memory only when an embedding was supplied.
    const e = embed orelse return;
    if (e.len == 0) return;

    const vec_stmt = prepare("INSERT INTO vec_aimemory(rowid, embedding) VALUES(?, ?)");
    if (vec_stmt == null) return;
    defer finalize(vec_stmt);

    bindInt64(vec_stmt, 1, rowid);
    const embed_bytes = std.mem.sliceAsBytes(e);
    bindBlob(vec_stmt, 2, embed_bytes);

    _ = step(vec_stmt);
}

/// Vector (or keyword) search over scene memories with a spoiler clamp:
/// rows of the CURRENTLY-WATCHED title are only eligible up to current_pos;
/// rows of OTHER titles are unrestricted. Returns the single best hit or null.
///
/// When `embed` is non-null we run a vec0 cosine KNN and apply the clamp in
/// Zig (vec0 MATCH queries can't carry arbitrary JOIN predicates reliably).
/// When `embed` is null we fall back to a LIKE keyword match over content with
/// the same clamp.
pub fn retrieveScene(embed: ?[]const f32, query_text: []const u8, current_title: []const u8, current_pos: f64) ?SceneHit {
    _ = db_handle orelse return null;

    if (embed) |e| {
        if (e.len != 0) {
            // KNN over the vector store; fetch a generous candidate set so that
            // clamped-out near neighbours don't starve a valid further hit.
            const sql =
                \\SELECT v.rowid, v.distance
                \\FROM vec_aimemory v
                \\WHERE v.embedding MATCH ? AND k = ?
                \\ORDER BY v.distance ASC
            ;
            const stmt = prepare(sql) orelse return null;
            defer finalize(stmt);

            const embed_bytes = std.mem.sliceAsBytes(e);
            bindBlob(stmt, 1, embed_bytes);
            bindInt(stmt, 2, 32);

            // Per-candidate metadata lookup, restricted to scene rows.
            const md_stmt = prepare("SELECT media_title, position_secs FROM aimemory WHERE id = ? AND context_type = 'scene'");
            if (md_stmt == null) return null;
            defer finalize(md_stmt);

            while (step(stmt) == c.SQLITE_ROW) {
                const rowid = columnInt(stmt, 0);
                _ = c.sqlite3_reset(md_stmt);
                bindInt(md_stmt, 1, rowid);
                if (step(md_stmt) != c.SQLITE_ROW) continue;

                const mtitle = columnText(md_stmt, 0) orelse "";
                const pos = columnDouble(md_stmt, 1);

                // Spoiler clamp: same-title rows must be at-or-before current_pos.
                if (current_title.len != 0 and std.mem.eql(u8, mtitle, current_title) and pos > current_pos) continue;

                // Candidates already arrive in ascending distance order, so the
                // first one that survives the clamp is the best hit.
                var hit = SceneHit{ .position_secs = pos };
                const copy_len = @min(mtitle.len, hit.title.len - 1);
                @memcpy(hit.title[0..copy_len], mtitle[0..copy_len]);
                hit.title_len = copy_len;
                return hit;
            }
            return null;
        }
    }

    // ── Keyword / LIKE fallback (mandatory) ──
    if (query_text.len == 0) return null;

    // Build "%query%" pattern in a fixed buffer (no allocator dependency).
    var pat_buf: [512]u8 = undefined;
    const q = query_text[0..@min(query_text.len, pat_buf.len - 2)];
    pat_buf[0] = '%';
    @memcpy(pat_buf[1 .. 1 + q.len], q);
    pat_buf[1 + q.len] = '%';
    const pattern = pat_buf[0 .. q.len + 2];

    // Clamp inline in SQL: same-title rows constrained to <= current_pos,
    // other titles unrestricted. Best = most recent matching scene.
    const sql =
        \\SELECT media_title, position_secs
        \\FROM aimemory
        \\WHERE context_type = 'scene'
        \\  AND content LIKE ?
        \\  AND (media_title <> ? OR position_secs <= ?)
        \\ORDER BY id DESC
        \\LIMIT 1
    ;
    const stmt = prepare(sql) orelse return null;
    defer finalize(stmt);

    bindText(stmt, 1, pattern);
    bindText(stmt, 2, current_title);
    bindDouble(stmt, 3, current_pos);

    if (step(stmt) != c.SQLITE_ROW) return null;

    const mtitle = columnText(stmt, 0) orelse "";
    const pos = columnDouble(stmt, 1);

    var hit = SceneHit{ .position_secs = pos };
    const copy_len = @min(mtitle.len, hit.title.len - 1);
    @memcpy(hit.title[0..copy_len], mtitle[0..copy_len]);
    hit.title_len = copy_len;
    return hit;
}

// ══════════════════════════════════════════════════════════
// Taste Receipts — For-You rail over the existing embeddings
// ══════════════════════════════════════════════════════════

/// Copy a single stored embedding (by aimemory rowid) out of vec_aimemory into
/// `out`. Returns false when the row is missing or the blob is shorter than a
/// full EMBED_DIM vector. Mirrors retrieveMemory's vec0 access + sliceAsBytes
/// usage; all sqlite handle access stays here.
pub fn getEmbeddingBlob(rowid: i64, out: *[ai_memory.EMBED_DIM]f32) bool {
    _ = db_handle orelse return false;

    const stmt = prepare("SELECT embedding FROM vec_aimemory WHERE rowid = ?") orelse return false;
    defer finalize(stmt);

    bindInt64(stmt, 1, rowid);
    if (step(stmt) != c.SQLITE_ROW) return false;

    const blob = columnBlob(stmt, 0) orelse return false;
    const want_bytes = ai_memory.EMBED_DIM * @sizeOf(f32);
    if (blob.len < want_bytes) return false;

    // Byte-wise copy: the sqlite BLOB pointer carries no f32 alignment
    // guarantee, so reinterpreting it as []f32 directly would be UB.
    const out_bytes = std.mem.sliceAsBytes(out[0..ai_memory.EMBED_DIM]);
    @memcpy(out_bytes, blob[0..want_bytes]);
    return true;
}

/// A lightweight projection of one aimemory row used to build the taste vector.
pub const AiMemRow = struct {
    id: i64 = 0,
    is_scene: bool = false,
    title: [128]u8 = std.mem.zeroes([128]u8),
    title_len: usize = 0,
    age_days: f64 = 0,
};

// Snapshot of aimemory rows for iteration. Rebuilt on each aiMemRowCount() so
// callers see a stable count/index pairing without holding a sqlite cursor
// across the (single-threaded recommendations worker) walk.
var aimem_rows: [512]AiMemRow = undefined;
var aimem_rows_len: usize = 0;

/// Refresh + return the number of aimemory rows available for taste-vector
/// computation. Newest rows first; capped at the snapshot buffer size.
pub fn aiMemRowCount() usize {
    aimem_rows_len = 0;
    _ = db_handle orelse return 0;

    // age_days from the DATETIME timestamp; is_scene from context_type.
    const sql =
        \\SELECT id, context_type,
        \\       (julianday('now') - julianday(timestamp)) AS age_days
        \\FROM aimemory
        \\WHERE id IN (SELECT rowid FROM vec_aimemory)
        \\ORDER BY id DESC
        \\LIMIT 512
    ;
    const stmt = prepare(sql) orelse return 0;
    defer finalize(stmt);

    while (step(stmt) == c.SQLITE_ROW and aimem_rows_len < aimem_rows.len) {
        var row = AiMemRow{};
        row.id = c.sqlite3_column_int64(stmt, 0);
        const ctype = columnText(stmt, 1) orelse "";
        row.is_scene = std.mem.eql(u8, ctype, "scene");
        var age = columnDouble(stmt, 2);
        if (age < 0 or std.math.isNan(age)) age = 0;
        row.age_days = age;
        aimem_rows[aimem_rows_len] = row;
        aimem_rows_len += 1;
    }
    return aimem_rows_len;
}

/// Fetch the idx-th row from the most recent aiMemRowCount() snapshot.
pub fn aiMemRowAt(idx: usize, out: *AiMemRow) bool {
    if (idx >= aimem_rows_len) return false;
    out.* = aimem_rows[idx];
    return true;
}

/// True when any watch_history row exists for `title` (case-sensitive exact
/// match on the stored name). Used to exclude already-seen titles from the rail.
pub fn isWatched(title: []const u8) bool {
    if (title.len == 0) return false;
    _ = db_handle orelse return false;

    const stmt = prepare("SELECT 1 FROM watch_history WHERE name = ? LIMIT 1") orelse return false;
    defer finalize(stmt);

    bindText(stmt, 1, title);
    return step(stmt) == c.SQLITE_ROW;
}

pub const SeedHit = struct {
    title: [128]u8 = std.mem.zeroes([128]u8),
    title_len: usize = 0,
    reason: [256]u8 = std.mem.zeroes([256]u8),
    reason_len: usize = 0,
    score: f64 = 0,
};

// Internal accumulator: one entry per unique media_title, keeping the closest
// (smallest-distance) scene candidate for that title.
const SeedAccum = struct {
    title: [128]u8 = std.mem.zeroes([128]u8),
    title_len: usize = 0,
    content: [512]u8 = std.mem.zeroes([512]u8),
    content_len: usize = 0,
    distance: f64 = 0,
};

/// KNN over scene embeddings by the taste vector, grouped per media_title.
///
/// For each unique title (excluding the currently-playing one and anything in
/// watch_history) we keep the closest scene and synthesise a spoiler-clamped
/// "Because you watched the … in <title>" receipt. Same-title rows relative to
/// `current_title` are clamped to <= `current_pos` (mirrors retrieveScene), so
/// a future scene of the current title can never leak into a receipt. Returns
/// the number of SeedHits written into `out`.
pub fn seedTitlesByTaste(taste: []const f32, current_title: []const u8, current_pos: f64, out: []SeedHit) usize {
    if (out.len == 0) return 0;
    if (taste.len == 0) return 0;
    _ = db_handle orelse return 0;

    const sql =
        \\SELECT v.rowid, v.distance
        \\FROM vec_aimemory v
        \\WHERE v.embedding MATCH ? AND k = ?
        \\ORDER BY v.distance ASC
    ;
    const stmt = prepare(sql) orelse return 0;
    defer finalize(stmt);

    const taste_bytes = std.mem.sliceAsBytes(taste);
    bindBlob(stmt, 1, taste_bytes);
    bindInt(stmt, 2, 50);

    // Per-candidate metadata, restricted to scene rows (carries the clamp pos).
    const md_stmt = prepare("SELECT media_title, content, position_secs FROM aimemory WHERE id = ? AND context_type = 'scene'") orelse return 0;
    defer finalize(md_stmt);

    // Group candidates by title; closest distance wins. Bounded by out.len.
    var accum: [64]SeedAccum = undefined;
    var accum_len: usize = 0;
    const accum_cap = @min(out.len, accum.len);

    while (step(stmt) == c.SQLITE_ROW) {
        const rowid = columnInt(stmt, 0);
        const distance = columnDouble(stmt, 1);

        _ = c.sqlite3_reset(md_stmt);
        bindInt(md_stmt, 1, rowid);
        if (step(md_stmt) != c.SQLITE_ROW) continue;

        const mtitle = columnText(md_stmt, 0) orelse "";
        const content = columnText(md_stmt, 1) orelse "";
        const pos = columnDouble(md_stmt, 2);
        if (mtitle.len == 0) continue;

        // Spoiler clamp: same-title rows must be at-or-before current_pos.
        if (current_title.len != 0 and std.mem.eql(u8, mtitle, current_title)) {
            if (pos > current_pos) continue;
            // Don't surface the currently-playing title in its own rail.
            continue;
        }

        // Exclude already-watched titles.
        if (isWatched(mtitle)) continue;

        // Have we already recorded this title? (candidates arrive ascending,
        // so the first occurrence is already the closest — just skip dupes.)
        var seen = false;
        for (accum[0..accum_len]) |a| {
            if (std.mem.eql(u8, a.title[0..a.title_len], mtitle)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;

        if (accum_len >= accum_cap) break;

        var a = SeedAccum{ .distance = distance };
        const t_len = @min(mtitle.len, a.title.len - 1);
        @memcpy(a.title[0..t_len], mtitle[0..t_len]);
        a.title_len = t_len;
        const c_len = @min(content.len, a.content.len - 1);
        @memcpy(a.content[0..c_len], content[0..c_len]);
        a.content_len = c_len;
        accum[accum_len] = a;
        accum_len += 1;
    }

    // Materialise SeedHits with cosine-ish score + a "because" receipt.
    var n: usize = 0;
    for (accum[0..accum_len]) |a| {
        if (n >= out.len) break;
        var hit = SeedHit{};
        @memcpy(hit.title[0..a.title_len], a.title[0..a.title_len]);
        hit.title_len = a.title_len;

        // distance -> score in (0, 1]; robust to either cosine-distance or L2.
        hit.score = 1.0 / (1.0 + a.distance);

        // Build a spoiler-safe receipt. The scene content is already clamped
        // (other titles unrestricted; current title excluded above), so a short
        // snippet of it is safe to surface as the "because".
        const snippet = trimScene(a.content[0..a.content_len]);
        var fbs = std.Io.Writer.fixed(&hit.reason);
        if (snippet.len != 0) {
            fbs.print("Because you watched the {s} in {s}", .{ snippet, a.title[0..a.title_len] }) catch {};
        } else {
            fbs.print("Because of a scene you loved in {s}", .{a.title[0..a.title_len]}) catch {};
        }
        hit.reason_len = fbs.buffered().len;

        out[n] = hit;
        n += 1;
    }
    return n;
}

/// Reduce a scene-content blob to a short, single-line snippet suitable for an
/// inline "because" receipt. Collapses whitespace and caps length.
fn trimScene(content: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    // Stop at the first sentence/line break for a tidy clause.
    var end: usize = trimmed.len;
    for (trimmed, 0..) |ch, i| {
        if (ch == '\n' or ch == '\r' or ch == '.') {
            end = i;
            break;
        }
    }
    var clause = trimmed[0..end];
    if (clause.len > 80) clause = clause[0..80];
    return std.mem.trim(u8, clause, " \t\r\n");
}

// ══════════════════════════════════════════════════════════
// Anime episode tracking
// ══════════════════════════════════════════════════════════

const logs = @import("logs.zig");
const io_global = @import("io_global.zig");

/// Mark a single episode of `mal_id` as watched / un-watched. Upserts into
/// anime_watched keyed by (mal_id, episode); `watched==false` stores 0 rather
/// than deleting so a re-toggle keeps the same row. Stamps updated_at (ms).
pub fn animeMarkWatched(mal_id: []const u8, episode: u32, watched: bool) void {
    _ = db_handle orelse return;

    const sql =
        \\INSERT INTO anime_watched(mal_id, episode, watched, updated_at)
        \\VALUES(?, ?, ?, ?)
        \\ON CONFLICT(mal_id, episode) DO UPDATE SET
        \\  watched = excluded.watched,
        \\  updated_at = excluded.updated_at
    ;
    const stmt = prepare(sql) orelse {
        logs.pushLog("error", "anime", "animeMarkWatched: prepare failed", true);
        return;
    };
    defer finalize(stmt);

    bindText(stmt, 1, mal_id);
    bindInt(stmt, 2, @intCast(@as(i64, episode)));
    bindInt(stmt, 3, if (watched) 1 else 0);
    bindInt64(stmt, 4, io_global.milliTimestamp());

    if (step(stmt) != c.SQLITE_DONE) {
        logs.pushLog("error", "anime", "animeMarkWatched: step failed", true);
    }
}

/// Load watched flags for `mal_id` into `out`, setting out[episode-1]=true for
/// every watched row. Bounds-safe: episodes < 1 or whose index >= out.len are
/// ignored. Does not clear `out` (caller zeroes it); only sets trues.
pub fn animeLoadWatched(mal_id: []const u8, out: []bool) void {
    if (out.len == 0) return;
    _ = db_handle orelse return;

    const stmt = prepare("SELECT episode FROM anime_watched WHERE mal_id = ? AND watched <> 0") orelse {
        logs.pushLog("error", "anime", "animeLoadWatched: prepare failed", true);
        return;
    };
    defer finalize(stmt);

    bindText(stmt, 1, mal_id);

    while (step(stmt) == c.SQLITE_ROW) {
        const ep = columnInt(stmt, 0);
        if (ep < 1) continue;
        const idx: usize = @intCast(ep - 1);
        if (idx >= out.len) continue;
        out[idx] = true;
    }
}

/// Upsert a continue-watching entry keyed by `mal_id`, stamping updated_at (ms)
/// so the most-recently-touched series sorts first in animeGetContinue.
pub fn animeUpsertContinue(mal_id: []const u8, title: []const u8, poster_url: []const u8, last_episode: u16, total_episodes: u16) void {
    _ = db_handle orelse return;

    const sql =
        \\INSERT INTO anime_continue(mal_id, title, poster_url, last_episode, total_episodes, updated_at)
        \\VALUES(?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(mal_id) DO UPDATE SET
        \\  title = excluded.title,
        \\  poster_url = excluded.poster_url,
        \\  last_episode = excluded.last_episode,
        \\  total_episodes = excluded.total_episodes,
        \\  updated_at = excluded.updated_at
    ;
    const stmt = prepare(sql) orelse {
        logs.pushLog("error", "anime", "animeUpsertContinue: prepare failed", true);
        return;
    };
    defer finalize(stmt);

    bindText(stmt, 1, mal_id);
    bindText(stmt, 2, title);
    bindText(stmt, 3, poster_url);
    bindInt(stmt, 4, @intCast(@as(i64, last_episode)));
    bindInt(stmt, 5, @intCast(@as(i64, total_episodes)));
    bindInt64(stmt, 6, io_global.milliTimestamp());

    if (step(stmt) != c.SQLITE_DONE) {
        logs.pushLog("error", "anime", "animeUpsertContinue: step failed", true);
    }
}

/// Fill `out` with the most-recently-updated continue-watching entries (newest
/// first), up to out.len rows. Each fixed buffer is filled with a clamped
/// @memcpy; the lazy poster_* UI fields are left untouched. Returns the number
/// of rows written.
pub fn animeGetContinue(out: []@import("state.zig").ContinueItem) usize {
    if (out.len == 0) return 0;
    _ = db_handle orelse return 0;

    const stmt = prepare(
        \\SELECT mal_id, title, poster_url, last_episode, total_episodes
        \\FROM anime_continue
        \\ORDER BY updated_at DESC
        \\LIMIT ?
    ) orelse {
        logs.pushLog("error", "anime", "animeGetContinue: prepare failed", true);
        return 0;
    };
    defer finalize(stmt);

    bindInt(stmt, 1, @intCast(out.len));

    var n: usize = 0;
    while (n < out.len and step(stmt) == c.SQLITE_ROW) {
        const item = &out[n];

        if (columnText(stmt, 0)) |s| {
            const len = @min(s.len, item.mal_id.len);
            @memcpy(item.mal_id[0..len], s[0..len]);
            item.mal_id_len = len;
        }
        if (columnText(stmt, 1)) |s| {
            const len = @min(s.len, item.title.len);
            @memcpy(item.title[0..len], s[0..len]);
            item.title_len = len;
        }
        if (columnText(stmt, 2)) |s| {
            const len = @min(s.len, item.poster_url.len);
            @memcpy(item.poster_url[0..len], s[0..len]);
            item.poster_url_len = len;
        }
        item.last_episode = @intCast(columnInt(stmt, 3));
        item.total_episodes = @intCast(columnInt(stmt, 4));

        n += 1;
    }
    return n;
}

/// Mark a single (season, episode) of `tmdb_id` as watched / un-watched. Upserts
/// into tv_watched keyed by (tmdb_id, season, episode); `watched==false` stores 0
/// rather than deleting so a re-toggle keeps the same row. Stamps updated_at (ms).
pub fn tvMarkWatched(tmdb_id: i32, season: u32, episode: u32, watched: bool) void {
    _ = db_handle orelse return;

    const sql =
        \\INSERT INTO tv_watched(tmdb_id, season, episode, watched, updated_at)
        \\VALUES(?, ?, ?, ?, ?)
        \\ON CONFLICT(tmdb_id, season, episode) DO UPDATE SET
        \\  watched = excluded.watched,
        \\  updated_at = excluded.updated_at
    ;
    const stmt = prepare(sql) orelse {
        logs.pushLog("error", "tv", "tvMarkWatched: prepare failed", true);
        return;
    };
    defer finalize(stmt);

    bindInt(stmt, 1, @intCast(@as(i64, tmdb_id)));
    bindInt(stmt, 2, @intCast(@as(i64, season)));
    bindInt(stmt, 3, @intCast(@as(i64, episode)));
    bindInt(stmt, 4, if (watched) 1 else 0);
    bindInt64(stmt, 5, io_global.milliTimestamp());

    if (step(stmt) != c.SQLITE_DONE) {
        logs.pushLog("error", "tv", "tvMarkWatched: step failed", true);
    }
}

/// Load watched flags for (`tmdb_id`, `season`) into `out`, setting
/// out[episode-1]=true for every watched row. Bounds-safe: episodes < 1 or whose
/// index >= out.len are ignored. Does not clear `out` (caller zeroes it); only
/// sets trues.
pub fn tvLoadWatched(tmdb_id: i32, season: u32, out: []bool) void {
    if (out.len == 0) return;
    _ = db_handle orelse return;

    const stmt = prepare("SELECT episode FROM tv_watched WHERE tmdb_id = ? AND season = ? AND watched <> 0") orelse {
        logs.pushLog("error", "tv", "tvLoadWatched: prepare failed", true);
        return;
    };
    defer finalize(stmt);

    bindInt(stmt, 1, @intCast(@as(i64, tmdb_id)));
    bindInt(stmt, 2, @intCast(@as(i64, season)));

    while (step(stmt) == c.SQLITE_ROW) {
        const ep = columnInt(stmt, 0);
        if (ep < 1) continue;
        const idx: usize = @intCast(ep - 1);
        if (idx >= out.len) continue;
        out[idx] = true;
    }
}

/// Upsert a continue-watching entry keyed by `tmdb_id`, stamping updated_at (ms)
/// so the most-recently-touched series sorts first in tvGetContinue.
pub fn tvUpsertContinue(tmdb_id: i32, name: []const u8, poster_path: []const u8, season: u32, episode: u32) void {
    _ = db_handle orelse return;

    const sql =
        \\INSERT INTO tv_continue(tmdb_id, name, poster_path, season, episode, updated_at)
        \\VALUES(?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(tmdb_id) DO UPDATE SET
        \\  name = excluded.name,
        \\  poster_path = excluded.poster_path,
        \\  season = excluded.season,
        \\  episode = excluded.episode,
        \\  updated_at = excluded.updated_at
    ;
    const stmt = prepare(sql) orelse {
        logs.pushLog("error", "tv", "tvUpsertContinue: prepare failed", true);
        return;
    };
    defer finalize(stmt);

    bindInt(stmt, 1, @intCast(@as(i64, tmdb_id)));
    bindText(stmt, 2, name);
    bindText(stmt, 3, poster_path);
    bindInt(stmt, 4, @intCast(@as(i64, season)));
    bindInt(stmt, 5, @intCast(@as(i64, episode)));
    bindInt64(stmt, 6, io_global.milliTimestamp());

    if (step(stmt) != c.SQLITE_DONE) {
        logs.pushLog("error", "tv", "tvUpsertContinue: step failed", true);
    }
}

/// Fill `out` with the most-recently-updated TV continue-watching entries
/// (newest first), up to out.len rows. Each fixed buffer is filled with a
/// clamped @memcpy. Returns the number of rows written.
pub fn tvGetContinue(out: []@import("state.zig").TvContinueItem) usize {
    if (out.len == 0) return 0;
    _ = db_handle orelse return 0;

    const stmt = prepare(
        \\SELECT tmdb_id, name, poster_path, season, episode
        \\FROM tv_continue
        \\ORDER BY updated_at DESC
        \\LIMIT ?
    ) orelse {
        logs.pushLog("error", "tv", "tvGetContinue: prepare failed", true);
        return 0;
    };
    defer finalize(stmt);

    bindInt(stmt, 1, @intCast(out.len));

    var n: usize = 0;
    while (n < out.len and step(stmt) == c.SQLITE_ROW) {
        const item = &out[n];

        item.tmdb_id = @intCast(columnInt(stmt, 0));
        if (columnText(stmt, 1)) |s| {
            const len = @min(s.len, item.name.len);
            @memcpy(item.name[0..len], s[0..len]);
            item.name_len = len;
        }
        if (columnText(stmt, 2)) |s| {
            const len = @min(s.len, item.poster_path.len);
            @memcpy(item.poster_path[0..len], s[0..len]);
            item.poster_path_len = len;
        }
        item.season = @intCast(columnInt(stmt, 3));
        item.episode = @intCast(columnInt(stmt, 4));

        n += 1;
    }
    return n;
}

// ══════════════════════════════════════════════════════════
// TV library — tracked shows, the season map, per-episode resume
//
// Typed in terms of `services/tv_pure.zig`, which is a zero-import leaf module
// (std only). Depending on it from core creates no cycle, and the alternative —
// redefining Season/Ep here — would give us two definitions of episode identity
// that can drift apart. Drifting definitions of "next episode" are the precise
// bug this whole subsystem exists to kill.
// ══════════════════════════════════════════════════════════

const tv_pure = @import("../services/tv_pure.zig");

/// Upsert a show's metadata. Does NOT touch `tracked` — see tvSetTracked. A
/// metadata refresh must never silently re-track a show the user untracked.
pub fn tvUpsertShow(
    tmdb_id: i32,
    name: []const u8,
    poster_path: []const u8,
    status: []const u8,
    last_aired: tv_pure.Ep,
    next: tv_pure.Ep,
    next_air_epoch: i64,
    next_name: []const u8,
) void {
    _ = db_handle orelse return;

    const sql =
        \\INSERT INTO tv_shows(tmdb_id, name, poster_path, status,
        \\  last_aired_season, last_aired_episode, next_season, next_episode,
        \\  next_air_epoch, next_name, added_at, updated_at)
        \\VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(tmdb_id) DO UPDATE SET
        \\  name = excluded.name,
        \\  poster_path = excluded.poster_path,
        \\  status = excluded.status,
        \\  last_aired_season = excluded.last_aired_season,
        \\  last_aired_episode = excluded.last_aired_episode,
        \\  next_season = excluded.next_season,
        \\  next_episode = excluded.next_episode,
        \\  next_air_epoch = excluded.next_air_epoch,
        \\  next_name = excluded.next_name
    ;
    const stmt = prepare(sql) orelse {
        logs.pushLog("error", "tv", "tvUpsertShow: prepare failed", true);
        return;
    };
    defer finalize(stmt);

    const now = io_global.milliTimestamp();
    bindInt(stmt, 1, @intCast(@as(i64, tmdb_id)));
    bindText(stmt, 2, name);
    bindText(stmt, 3, poster_path);
    bindText(stmt, 4, status);
    bindInt(stmt, 5, @intCast(@as(i64, last_aired.season)));
    bindInt(stmt, 6, @intCast(@as(i64, last_aired.episode)));
    bindInt(stmt, 7, @intCast(@as(i64, next.season)));
    bindInt(stmt, 8, @intCast(@as(i64, next.episode)));
    bindInt64(stmt, 9, next_air_epoch);
    bindText(stmt, 10, next_name);
    bindInt64(stmt, 11, now);
    bindInt64(stmt, 12, now);

    if (step(stmt) != c.SQLITE_DONE) logs.pushLog("error", "tv", "tvUpsertShow: step failed", true);
}

/// Auto-track: called when an episode is actually watched. Creates the show row
/// if absent and bumps `updated_at` (which drives "most recently watched first"),
/// but does NOT resurrect `tracked` on an existing row — see tvSetTracked.
pub fn tvTouchShow(tmdb_id: i32, name: []const u8, poster_path: []const u8) void {
    _ = db_handle orelse return;

    const sql =
        \\INSERT INTO tv_shows(tmdb_id, name, poster_path, tracked, added_at, updated_at)
        \\VALUES(?, ?, ?, 1, ?, ?)
        \\ON CONFLICT(tmdb_id) DO UPDATE SET
        \\  name = excluded.name,
        \\  poster_path = excluded.poster_path,
        \\  updated_at = excluded.updated_at
    ;
    const stmt = prepare(sql) orelse {
        logs.pushLog("error", "tv", "tvTouchShow: prepare failed", true);
        return;
    };
    defer finalize(stmt);

    const now = io_global.milliTimestamp();
    bindInt(stmt, 1, @intCast(@as(i64, tmdb_id)));
    bindText(stmt, 2, name);
    bindText(stmt, 3, poster_path);
    bindInt64(stmt, 4, now);
    bindInt64(stmt, 5, now);

    if (step(stmt) != c.SQLITE_DONE) logs.pushLog("error", "tv", "tvTouchShow: step failed", true);
}

/// Explicit Track / Untrack.
///
/// Untracking flips a flag and NOTHING else. It must never delete tv_watched
/// rows: an accidental untrack would otherwise silently destroy the user's watch
/// history, and re-tracking has to restore progress exactly.
pub fn tvSetTracked(tmdb_id: i32, tracked: bool) void {
    _ = db_handle orelse return;

    const stmt = prepare("UPDATE tv_shows SET tracked = ?, updated_at = ? WHERE tmdb_id = ?") orelse {
        logs.pushLog("error", "tv", "tvSetTracked: prepare failed", true);
        return;
    };
    defer finalize(stmt);

    bindInt(stmt, 1, if (tracked) 1 else 0);
    bindInt64(stmt, 2, io_global.milliTimestamp());
    bindInt(stmt, 3, @intCast(@as(i64, tmdb_id)));

    if (step(stmt) != c.SQLITE_DONE) logs.pushLog("error", "tv", "tvSetTracked: step failed", true);
}

pub fn tvIsTracked(tmdb_id: i32) bool {
    _ = db_handle orelse return false;
    const stmt = prepare("SELECT tracked FROM tv_shows WHERE tmdb_id = ?") orelse return false;
    defer finalize(stmt);
    bindInt(stmt, 1, @intCast(@as(i64, tmdb_id)));
    if (step(stmt) != c.SQLITE_ROW) return false;
    return columnInt(stmt, 0) != 0;
}

/// A tracked show as stored. The derived fields (next-up, progress, status) are
/// NOT stored — they are computed by tv_pure from the season map + watched rows,
/// so there is exactly one place that decides them.
pub const TvShowRow = struct {
    tmdb_id: i32 = 0,
    name: [128]u8 = std.mem.zeroes([128]u8),
    name_len: usize = 0,
    poster_path: [64]u8 = std.mem.zeroes([64]u8),
    poster_path_len: usize = 0,
    ended: bool = false,
    last_aired: tv_pure.Ep = .{},
    next_air_epoch: i64 = 0,
    updated_at: i64 = 0,
};

/// Fill `out` with tracked shows, most-recent activity first. Untracked shows are
/// excluded but their rows (and their watched history) remain.
pub fn tvGetShows(out: []TvShowRow) usize {
    if (out.len == 0) return 0;
    _ = db_handle orelse return 0;

    const stmt = prepare(
        \\SELECT tmdb_id, name, poster_path, status,
        \\  last_aired_season, last_aired_episode, next_air_epoch, updated_at
        \\FROM tv_shows WHERE tracked <> 0
        \\ORDER BY updated_at DESC
        \\LIMIT ?
    ) orelse {
        logs.pushLog("error", "tv", "tvGetShows: prepare failed", true);
        return 0;
    };
    defer finalize(stmt);
    bindInt(stmt, 1, @intCast(out.len));

    var n: usize = 0;
    while (n < out.len and step(stmt) == c.SQLITE_ROW) {
        const row = &out[n];
        row.* = .{};
        row.tmdb_id = @intCast(columnInt(stmt, 0));
        if (columnText(stmt, 1)) |s| {
            const len = @min(s.len, row.name.len);
            @memcpy(row.name[0..len], s[0..len]);
            row.name_len = len;
        }
        if (columnText(stmt, 2)) |s| {
            const len = @min(s.len, row.poster_path.len);
            @memcpy(row.poster_path[0..len], s[0..len]);
            row.poster_path_len = len;
        }
        // TMDB series status: "Ended" / "Canceled" both mean no more episodes,
        // ever — the only way to tell "Completed" from "Caught up".
        if (columnText(stmt, 3)) |s| {
            row.ended = std.mem.eql(u8, s, "Ended") or std.mem.eql(u8, s, "Canceled");
        }
        row.last_aired = .{
            .season = @intCast(columnInt(stmt, 4)),
            .episode = @intCast(columnInt(stmt, 5)),
        };
        row.next_air_epoch = columnInt64(stmt, 6);
        row.updated_at = columnInt64(stmt, 7);
        n += 1;
    }
    return n;
}

/// Replace the season map for a show. Upsert rather than DELETE-then-INSERT: a
/// season count only ever grows, and a failed mid-refresh delete would leave the
/// show with no map at all (which reads as "0/0, nothing to watch").
pub fn tvUpsertSeasons(tmdb_id: i32, seasons: []const tv_pure.Season) void {
    _ = db_handle orelse return;

    const sql =
        \\INSERT INTO tv_seasons(tmdb_id, season, episode_count) VALUES(?, ?, ?)
        \\ON CONFLICT(tmdb_id, season) DO UPDATE SET episode_count = excluded.episode_count
    ;
    for (seasons) |s| {
        const stmt = prepare(sql) orelse continue;
        defer finalize(stmt);
        bindInt(stmt, 1, @intCast(@as(i64, tmdb_id)));
        bindInt(stmt, 2, @intCast(@as(i64, s.number)));
        bindInt(stmt, 3, @intCast(@as(i64, s.episode_count)));
        _ = step(stmt);
    }
}

pub fn tvLoadSeasons(tmdb_id: i32, out: []tv_pure.Season) usize {
    if (out.len == 0) return 0;
    _ = db_handle orelse return 0;

    const stmt = prepare("SELECT season, episode_count FROM tv_seasons WHERE tmdb_id = ? ORDER BY season ASC LIMIT ?") orelse return 0;
    defer finalize(stmt);
    bindInt(stmt, 1, @intCast(@as(i64, tmdb_id)));
    bindInt(stmt, 2, @intCast(out.len));

    var n: usize = 0;
    while (n < out.len and step(stmt) == c.SQLITE_ROW) {
        out[n] = .{
            .number = @intCast(columnInt(stmt, 0)),
            .episode_count = @intCast(@max(0, columnInt(stmt, 1))),
        };
        n += 1;
    }
    return n;
}

/// Every watched episode of a show, across ALL seasons. This is what makes
/// cross-season next-up possible — the old path only ever loaded the currently
/// open season's flags, so it could not see past a season boundary.
pub fn tvLoadWatchedAll(tmdb_id: i32, out: []tv_pure.Ep) usize {
    if (out.len == 0) return 0;
    _ = db_handle orelse return 0;

    const stmt = prepare(
        \\SELECT season, episode FROM tv_watched
        \\WHERE tmdb_id = ? AND watched <> 0
        \\ORDER BY season ASC, episode ASC LIMIT ?
    ) orelse return 0;
    defer finalize(stmt);
    bindInt(stmt, 1, @intCast(@as(i64, tmdb_id)));
    bindInt(stmt, 2, @intCast(out.len));

    var n: usize = 0;
    while (n < out.len and step(stmt) == c.SQLITE_ROW) {
        out[n] = .{
            .season = @intCast(columnInt(stmt, 0)),
            .episode = @intCast(columnInt(stmt, 1)),
        };
        n += 1;
    }
    return n;
}

/// Save a mid-episode resume position. Creates the row with watched = 0 when the
/// episode has not been marked watched yet — "in progress" is a real state, and
/// it must not imply "watched".
pub fn tvSavePosition(tmdb_id: i32, season: i32, episode: i32, position: f64, duration: f64) void {
    _ = db_handle orelse return;
    if (episode < 1 or season < 0) return;

    const sql =
        \\INSERT INTO tv_watched(tmdb_id, season, episode, watched, position_secs, duration_secs, updated_at)
        \\VALUES(?, ?, ?, 0, ?, ?, ?)
        \\ON CONFLICT(tmdb_id, season, episode) DO UPDATE SET
        \\  position_secs = excluded.position_secs,
        \\  duration_secs = excluded.duration_secs,
        \\  updated_at = excluded.updated_at
    ;
    const stmt = prepare(sql) orelse return;
    defer finalize(stmt);

    bindInt(stmt, 1, @intCast(@as(i64, tmdb_id)));
    bindInt(stmt, 2, @intCast(@as(i64, season)));
    bindInt(stmt, 3, @intCast(@as(i64, episode)));
    bindDouble(stmt, 4, position);
    bindDouble(stmt, 5, duration);
    bindInt64(stmt, 6, io_global.milliTimestamp());
    _ = step(stmt);
}

// ── User-set library status (any kind) ──

/// Set (or clear) the user's hand-picked status. An empty `status` DELETES the
/// row, which returns the item to auto-derived — clearing must not leave a stale
/// "" row behind that reads as a status.
pub fn librarySetStatus(kind: []const u8, item_id: []const u8, status: []const u8) void {
    _ = db_handle orelse return;
    if (item_id.len == 0) return;

    if (status.len == 0) {
        const del = prepare("DELETE FROM library_status WHERE kind = ? AND item_id = ?") orelse return;
        defer finalize(del);
        bindText(del, 1, kind);
        bindText(del, 2, item_id);
        _ = step(del);
        return;
    }

    const stmt = prepare(
        \\INSERT INTO library_status(kind, item_id, status, updated_at)
        \\VALUES(?, ?, ?, ?)
        \\ON CONFLICT(kind, item_id) DO UPDATE SET
        \\  status = excluded.status,
        \\  updated_at = excluded.updated_at
    ) orelse {
        logs.pushLog("error", "tv", "librarySetStatus: prepare failed", true);
        return;
    };
    defer finalize(stmt);
    bindText(stmt, 1, kind);
    bindText(stmt, 2, item_id);
    bindText(stmt, 3, status);
    bindInt64(stmt, 4, io_global.milliTimestamp());
    _ = step(stmt);
}

/// Copy the user's status for one item into `buf`. Empty slice when unset.
pub fn libraryGetStatus(kind: []const u8, item_id: []const u8, buf: []u8) []const u8 {
    _ = db_handle orelse return "";
    if (item_id.len == 0 or buf.len == 0) return "";

    const stmt = prepare("SELECT status FROM library_status WHERE kind = ? AND item_id = ?") orelse return "";
    defer finalize(stmt);
    bindText(stmt, 1, kind);
    bindText(stmt, 2, item_id);
    if (step(stmt) != c.SQLITE_ROW) return "";
    const s = columnText(stmt, 0) orelse return "";
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

/// Resume position (seconds) for one episode, 0 when there is none.
///
/// Returns 0 once the episode is essentially finished (>= 95% watched), matching
/// the convention the rest of the app uses — otherwise finishing an episode would
/// leave it "resumable" at the credits forever.
pub fn tvGetPosition(tmdb_id: i32, season: i32, episode: i32) f64 {
    _ = db_handle orelse return 0;

    const stmt = prepare("SELECT position_secs, duration_secs FROM tv_watched WHERE tmdb_id = ? AND season = ? AND episode = ?") orelse return 0;
    defer finalize(stmt);
    bindInt(stmt, 1, @intCast(@as(i64, tmdb_id)));
    bindInt(stmt, 2, @intCast(@as(i64, season)));
    bindInt(stmt, 3, @intCast(@as(i64, episode)));

    if (step(stmt) != c.SQLITE_ROW) return 0;
    const pos = columnDouble(stmt, 0);
    const dur = columnDouble(stmt, 1);
    if (dur > 5 and pos / dur >= 0.95) return 0;
    return pos;
}
