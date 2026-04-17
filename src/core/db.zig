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
