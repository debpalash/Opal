const std = @import("std");
const paths = @import("paths.zig");

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

    if (c.sqlite3_open(cpath.ptr, &db_handle) != c.SQLITE_OK) {
        db_handle = null;
        return;
    }

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
                writer.print("[{s}] System: Started Playing context: {s}\n", .{ts, title}) catch {};
            } else {
                writer.print("[{s}] {s}: {s}\n", .{ts, role, content}) catch {};
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
