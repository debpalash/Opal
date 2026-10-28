//! Recall background indexer (ROADMAP 7.1).
//!
//! Folds the user's library into `recall_docs` + FTS5 `recall_fts` (+ vec0
//! `recall_vec` when an embedding model answers), and subtitle sidecars next to
//! local media into ~20–40 s `recall_moments` windows (+ FTS/vec).
//!
//! Sources: library_items (every vertical), local_media (the local folder
//! index) and tracked tv_shows, enriched from the tmdb_items cache. Rows are
//! re-written only when their content signature moves; rows whose source
//! vanished are swept at the end of a complete pass.
//!
//! Low priority by construction: one worker at a time, a private connection
//! (transactions never touch the shared UI connection), bounded batches with a
//! pause between them, a per-pass embedding budget, and an isQuitting check at
//! every batch boundary.

const std = @import("std");
const db = @import("../core/db.zig");
const io = @import("../core/io_global.zig");
const logs = @import("../core/logs.zig");
const state = @import("../core/state.zig");
const workers = @import("../core/workers.zig");
const alloc = @import("../core/alloc.zig").allocator;
const pure = @import("recall_pure.zig");
const embed = @import("recall_embed.zig");

const PASS_INTERVAL_MS: i64 = 10 * 60 * 1000;
const FIRST_PASS_DELAY_MS: i64 = 4_000;
const PAGE: usize = 64;
const BATCH_PAUSE_NS: u64 = 15 * std.time.ns_per_ms;
const EMBED_BUDGET: usize = 256; // docs + moments embedded per pass
const SIDECAR_EVERY: u32 = 6; // full sidecar rescan every Nth pass (~1 h)
const MAX_SUB_BYTES: usize = 2 * 1024 * 1024;
const MAX_CUES: usize = 4096;
const MAX_WINDOWS: usize = 1024;
const EMBED_TEXT_MAX: usize = 1500;

pub var running = std.atomic.Value(bool).init(false);
var refresh_requested = std.atomic.Value(bool).init(false);
/// Docs / moments currently in the index (published at the end of a pass).
pub var doc_count = std.atomic.Value(u64).init(0);
pub var moment_count = std.atomic.Value(u64).init(0);
// Owner-thread only (tick).
var next_pass_ms: i64 = 0;
// Worker-only.
var pass_number: u32 = 0;

/// Ask for a pass soon (after a library scan, a new subtitle, …).
pub fn requestRefresh() void {
    refresh_requested.store(true, .release);
}

/// Owner-loop pump (appFrame / headless serve loop). Starts a pass when one is
/// due; never blocks.
pub fn tick() void {
    if (!state.app.config_loaded.load(.acquire) or workers.isQuitting()) return;
    if (running.load(.acquire)) return;
    const now = io.milliTimestamp();
    if (next_pass_ms == 0) {
        next_pass_ms = now + FIRST_PASS_DELAY_MS;
        return;
    }
    const forced = refresh_requested.load(.acquire);
    if (!forced and now < next_pass_ms) return;
    refresh_requested.store(false, .release);
    next_pass_ms = now + PASS_INTERVAL_MS;
    if (workers.spawnLegacy(passWorker, .{})) |thread| workers.release(thread) else |_| {}
}

// ── Private connection ──────────────────────────────────────────────────────

const Conn = struct {
    handle: *db.Sqlite3,
    in_tx: bool = false,

    fn open() ?Conn {
        var dbpath: [512]u8 = undefined;
        var cpath: [512]u8 = undefined;
        const path = @import("../core/paths.zig").zigzagDbFile(&dbpath);
        const zpath = std.fmt.bufPrintZ(&cpath, "{s}", .{path}) catch return null;
        var handle: ?*db.Sqlite3 = null;
        if (db.c.sqlite3_open_v2(zpath.ptr, &handle, db.c.SQLITE_OPEN_READWRITE | db.c.SQLITE_OPEN_FULLMUTEX, null) != db.c.SQLITE_OK) {
            if (handle) |h| _ = db.c.sqlite3_close_v2(h);
            return null;
        }
        const h = handle orelse return null;
        // vec0 lives in the vendored sqlite-vec, registered per connection.
        _ = db.c.sqlite3_vec_init(h, null, null);
        _ = db.c.sqlite3_busy_timeout(h, 2000);
        _ = db.c.sqlite3_exec(h, "PRAGMA foreign_keys=ON", null, null, null);
        return .{ .handle = h };
    }

    fn close(self: *Conn) void {
        if (self.in_tx) self.commit();
        _ = db.c.sqlite3_close_v2(self.handle);
    }

    fn prep(self: *Conn, sql: []const u8) ?*db.Stmt {
        var stmt: ?*db.Stmt = null;
        if (db.c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt, null) != db.c.SQLITE_OK) {
            if (stmt) |s| _ = db.c.sqlite3_finalize(s);
            return null;
        }
        return stmt;
    }

    fn exec(self: *Conn, sql: [*:0]const u8) bool {
        return db.c.sqlite3_exec(self.handle, sql, null, null, null) == db.c.SQLITE_OK;
    }

    fn begin(self: *Conn) void {
        if (!self.in_tx) self.in_tx = self.exec("BEGIN IMMEDIATE");
    }

    fn commit(self: *Conn) void {
        if (!self.in_tx) return;
        if (!self.exec("COMMIT")) _ = self.exec("ROLLBACK");
        self.in_tx = false;
    }

    fn tableExists(self: *Conn, name: []const u8) bool {
        const stmt = self.prep("SELECT 1 FROM sqlite_master WHERE name=?1") orelse return false;
        defer db.finalize(stmt);
        db.bindText(stmt, 1, name);
        return db.step(stmt) == db.c.SQLITE_ROW;
    }

    fn execId2(self: *Conn, sql: []const u8, a: i64, b: i64) void {
        const stmt = self.prep(sql) orelse return;
        defer db.finalize(stmt);
        db.bindInt64(stmt, 1, a);
        db.bindInt64(stmt, 2, b);
        _ = db.step(stmt);
    }

    /// Run a one-parameter statement, ignoring failure (optional tables).
    fn execId(self: *Conn, sql: []const u8, id: i64) void {
        const stmt = self.prep(sql) orelse return;
        defer db.finalize(stmt);
        db.bindInt64(stmt, 1, id);
        _ = db.step(stmt);
    }
};

// ── Meta / vector tables ────────────────────────────────────────────────────

pub fn metaInt(key: []const u8) i64 {
    const stmt = db.prepare("SELECT value FROM recall_meta WHERE key=?1") orelse return 0;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, key);
    if (db.step(stmt) != db.c.SQLITE_ROW) return 0;
    const v = db.columnText(stmt, 0) orelse return 0;
    return std.fmt.parseInt(i64, v, 10) catch 0;
}

fn setMeta(conn: *Conn, key: []const u8, value: i64) void {
    const stmt = conn.prep("INSERT INTO recall_meta(key,value) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value") orelse return;
    defer db.finalize(stmt);
    var buf: [24]u8 = undefined;
    db.bindText(stmt, 1, key);
    db.bindText(stmt, 2, std.fmt.bufPrint(&buf, "{d}", .{value}) catch "0");
    _ = db.step(stmt);
}

fn readMeta(conn: *Conn, key: []const u8) i64 {
    const stmt = conn.prep("SELECT value FROM recall_meta WHERE key=?1") orelse return 0;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, key);
    if (db.step(stmt) != db.c.SQLITE_ROW) return 0;
    const v = db.columnText(stmt, 0) orelse return 0;
    return std.fmt.parseInt(i64, v, 10) catch 0;
}

/// (Re)create the vec0 tables for `dim`. A model change drops every vector
/// and marks all rows for re-embedding.
fn ensureVecTables(conn: *Conn, dim: usize) bool {
    const current = readMeta(conn, "embed_dim");
    if (current == @as(i64, @intCast(dim)) and conn.tableExists("recall_vec") and conn.tableExists("recall_moments_vec")) return true;
    _ = conn.exec("DROP TABLE IF EXISTS recall_vec");
    _ = conn.exec("DROP TABLE IF EXISTS recall_moments_vec");
    var sql: [192]u8 = undefined;
    const a = std.fmt.bufPrintZ(&sql, "CREATE VIRTUAL TABLE recall_vec USING vec0(embedding float[{d}] distance_metric=cosine)", .{dim}) catch return false;
    if (!conn.exec(a.ptr)) return false;
    const b = std.fmt.bufPrintZ(&sql, "CREATE VIRTUAL TABLE recall_moments_vec USING vec0(embedding float[{d}] distance_metric=cosine)", .{dim}) catch return false;
    if (!conn.exec(b.ptr)) return false;
    _ = conn.exec("UPDATE recall_docs SET embedded=0");
    _ = conn.exec("UPDATE recall_moments SET embedded=0");
    setMeta(conn, "embed_dim", @intCast(dim));
    if (current != 0) logs.pushLog("info", "recall", "Embedding model changed; rebuilding the recall vector index", false);
    return true;
}

// ── Doc rows ────────────────────────────────────────────────────────────────

const Row = struct {
    source: []const u8 = "",
    key: [160]u8 = undefined,
    key_len: usize = 0,
    kind: pure.Kind = .other,
    title: [256]u8 = undefined,
    title_len: usize = 0,
    body: [1536]u8 = undefined,
    body_len: usize = 0,
    year: u16 = 0,
    runtime: u32 = 0,
    lib_kind: [16]u8 = undefined,
    lib_kind_len: usize = 0,
    lib_id: [1024]u8 = undefined,
    lib_id_len: usize = 0,
    link: [1024]u8 = undefined,
    link_len: usize = 0,
    poster: [384]u8 = undefined,
    poster_len: usize = 0,

    fn set(buf: []u8, len: *usize, value: []const u8) void {
        const clean = pure.sanitizeUtf8(value, buf);
        len.* = clean.len;
    }
    fn setKey(self: *Row, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.key, fmt, args) catch "";
        self.key_len = s.len;
    }
    fn setPoster(self: *Row, raw: []const u8) void {
        // TMDB poster paths are relative; store an absolute, displayable URL.
        if (raw.len > 0 and raw[0] == '/') {
            const s = std.fmt.bufPrint(&self.poster, "https://image.tmdb.org/t/p/w185{s}", .{raw}) catch "";
            self.poster_len = s.len;
        } else if (std.mem.startsWith(u8, raw, "https://") or std.mem.startsWith(u8, raw, "http://")) {
            set(&self.poster, &self.poster_len, raw);
        } else self.poster_len = 0;
    }
    fn setBody(self: *Row, overview: []const u8, genres: []const u8) void {
        var w = std.Io.Writer.fixed(&self.body);
        w.writeAll(genres) catch {};
        if (genres.len > 0 and overview.len > 0) w.writeAll(". ") catch {};
        w.writeAll(overview) catch {};
        var tmp: [1536]u8 = undefined;
        const n = w.end;
        @memcpy(tmp[0..n], self.body[0..n]);
        set(&self.body, &self.body_len, tmp[0..n]);
    }

    fn sig(self: *const Row) i64 {
        var h = std.hash.Wyhash.init(0x7265_6361_6c6c);
        h.update(@tagName(self.kind));
        h.update(self.title[0..self.title_len]);
        h.update(self.body[0..self.body_len]);
        h.update(std.mem.asBytes(&self.year));
        h.update(std.mem.asBytes(&self.runtime));
        h.update(self.link[0..self.link_len]);
        h.update(self.poster[0..self.poster_len]);
        return @bitCast(h.final());
    }
};

fn colText(stmt: ?*db.Stmt, col: c_int) []const u8 {
    return db.columnText(stmt, col) orelse "";
}

fn parseYear(text: []const u8) u16 {
    if (text.len >= 4) {
        const y = std.fmt.parseInt(u16, text[0..4], 10) catch return 0;
        if (y >= 1900 and y <= 2099) return y;
    }
    return 0;
}

const Upserted = struct { id: i64, changed: bool, subs_sig: i64 };

fn upsertDoc(conn: *Conn, row: *const Row, token: i64) ?Upserted {
    const key = row.key[0..row.key_len];
    if (key.len == 0) return null;
    const sig = row.sig();
    const find = conn.prep("SELECT id,sig,subs_sig FROM recall_docs WHERE source=?1 AND source_key=?2") orelse return null;
    db.bindText(find, 1, row.source);
    db.bindText(find, 2, key);
    var existing: ?Upserted = null;
    var old_sig: i64 = 0;
    if (db.step(find) == db.c.SQLITE_ROW) {
        existing = .{ .id = db.columnInt64(find, 0), .changed = false, .subs_sig = db.columnInt64(find, 2) };
        old_sig = db.columnInt64(find, 1);
    }
    db.finalize(find);

    if (existing) |e| {
        if (old_sig == sig) {
            conn.execId2("UPDATE recall_docs SET seen=?2 WHERE id=?1", e.id, token);
            return e;
        }
    }
    const title = row.title[0..row.title_len];
    const body = row.body[0..row.body_len];
    const sql = if (existing != null)
        "UPDATE recall_docs SET kind=?3,title=?4,body=?5,year=?6,runtime_secs=?7,lib_kind=?8,lib_id=?9,link=?10,poster=?11,sig=?12,seen=?13,embedded=0 WHERE source=?1 AND source_key=?2 RETURNING id"
    else
        "INSERT INTO recall_docs(source,source_key,kind,title,body,year,runtime_secs,lib_kind,lib_id,link,poster,sig,seen) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13) RETURNING id";
    const stmt = conn.prep(sql) orelse return null;
    db.bindText(stmt, 1, row.source);
    db.bindText(stmt, 2, key);
    db.bindText(stmt, 3, @tagName(row.kind));
    db.bindText(stmt, 4, title);
    db.bindText(stmt, 5, body);
    db.bindInt64(stmt, 6, row.year);
    db.bindInt64(stmt, 7, row.runtime);
    db.bindText(stmt, 8, row.lib_kind[0..row.lib_kind_len]);
    db.bindText(stmt, 9, row.lib_id[0..row.lib_id_len]);
    db.bindText(stmt, 10, row.link[0..row.link_len]);
    db.bindText(stmt, 11, row.poster[0..row.poster_len]);
    db.bindInt64(stmt, 12, sig);
    db.bindInt64(stmt, 13, token);
    const ok = db.step(stmt) == db.c.SQLITE_ROW;
    const id = if (ok) db.columnInt64(stmt, 0) else 0;
    db.finalize(stmt);
    if (!ok or id <= 0) return null;

    // FTS + vector rows follow the doc's content.
    conn.execId("DELETE FROM recall_fts WHERE rowid=?1", id);
    conn.execId("DELETE FROM recall_vec WHERE rowid=?1", id);
    if (conn.prep("INSERT INTO recall_fts(rowid,title,body) VALUES(?1,?2,?3)")) |fts| {
        db.bindInt64(fts, 1, id);
        db.bindText(fts, 2, title);
        db.bindText(fts, 3, body);
        _ = db.step(fts);
        db.finalize(fts);
    }
    return .{ .id = id, .changed = true, .subs_sig = if (existing) |e| e.subs_sig else 0 };
}

fn deleteMoments(conn: *Conn, doc_id: i64) void {
    if (conn.prep("SELECT id FROM recall_moments WHERE doc_id=?1")) |stmt| {
        db.bindInt64(stmt, 1, doc_id);
        // Collect first: deleting while stepping the same table is legal but
        // the vec0/FTS deletes are separate statements anyway.
        var ids: [256]i64 = undefined;
        while (true) {
            var n: usize = 0;
            while (n < ids.len and db.step(stmt) == db.c.SQLITE_ROW) : (n += 1) ids[n] = db.columnInt64(stmt, 0);
            for (ids[0..n]) |mid| {
                conn.execId("DELETE FROM recall_moments_fts WHERE rowid=?1", mid);
                conn.execId("DELETE FROM recall_moments_vec WHERE rowid=?1", mid);
            }
            if (n < ids.len) break;
        }
        db.finalize(stmt);
    }
    conn.execId("DELETE FROM recall_moments WHERE doc_id=?1", doc_id);
}

fn deleteDoc(conn: *Conn, id: i64) void {
    deleteMoments(conn, id);
    conn.execId("DELETE FROM recall_fts WHERE rowid=?1", id);
    conn.execId("DELETE FROM recall_vec WHERE rowid=?1", id);
    conn.execId("DELETE FROM recall_docs WHERE id=?1", id);
}

// ── Subtitle sidecars → moments ─────────────────────────────────────────────

fn isAbsolute(path: []const u8) bool {
    return path.len > 1 and (path[0] == '/' or (path.len > 2 and path[1] == ':' and (path[2] == '\\' or path[2] == '/')));
}

const Sidecar = struct {
    path: [1280]u8 = undefined,
    path_len: usize = 0,
    sig: i64 = 0,
    rank: u8 = 255,
};

/// Best subtitle sidecar for a media file: plain `stem.srt` first, then an
/// English tag, then the generated `.auto.srt`, then any other language.
fn findSidecar(media_path: []const u8) ?Sidecar {
    if (!isAbsolute(media_path)) return null;
    const slash = std.mem.lastIndexOfAny(u8, media_path, "/\\") orelse return null;
    const dir_path = media_path[0..slash];
    const base = media_path[slash + 1 ..];
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
    const stem = base[0..dot];
    if (stem.len == 0) return null;
    var dir = io.openDirAbsolute(if (dir_path.len == 0) "/" else dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io.io());
    var it = dir.iterate();
    var best: ?Sidecar = null;
    var seen: usize = 0;
    while (seen < 4000) : (seen += 1) {
        const entry = (it.next(io.io()) catch break) orelse break;
        if (entry.kind != .file) continue;
        const tag = pure.sidecarLang(stem, entry.name) orelse continue;
        const rank: u8 = if (tag.len == 0 and std.mem.indexOf(u8, entry.name[stem.len..], ".auto.") == null)
            0
        else if (std.ascii.eqlIgnoreCase(tag, "en") or std.ascii.eqlIgnoreCase(tag, "eng"))
            1
        else if (tag.len == 0)
            2
        else
            3;
        if (best != null and best.?.rank <= rank) continue;
        var sc = Sidecar{ .rank = rank };
        const p = std.fmt.bufPrint(&sc.path, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        sc.path_len = p.len;
        best = sc;
    }
    var sc = best orelse return null;
    const file = io.openFileAbsolute(sc.path[0..sc.path_len], .{}) catch return null;
    defer file.close(io.io());
    const st = file.stat(io.io()) catch return null;
    var h = std.hash.Wyhash.init(0x7375_6273);
    h.update(sc.path[0..sc.path_len]);
    h.update(std.mem.asBytes(&st.size));
    const mtime: i128 = st.mtime.nanoseconds;
    h.update(std.mem.asBytes(&mtime));
    sc.sig = @bitCast(h.final());
    if (sc.sig == 0) sc.sig = 1;
    return sc;
}

/// Re-chunk a doc's subtitle into moments when the sidecar changed (or vanished).
/// Returns the number of moments written.
fn syncMoments(conn: *Conn, doc_id: i64, old_sig: i64, media_path: []const u8) usize {
    const sc = findSidecar(media_path) orelse {
        if (old_sig != 0) {
            deleteMoments(conn, doc_id);
            conn.execId2("UPDATE recall_docs SET subs_sig=?2 WHERE id=?1", doc_id, 0);
        }
        return 0;
    };
    if (sc.sig == old_sig) return 0;
    deleteMoments(conn, doc_id);
    conn.execId2("UPDATE recall_docs SET subs_sig=?2 WHERE id=?1", doc_id, sc.sig);

    const file = io.openFileAbsolute(sc.path[0..sc.path_len], .{}) catch return 0;
    defer file.close(io.io());
    const raw = io.readToEndAlloc(file, alloc, MAX_SUB_BYTES) catch return 0;
    defer alloc.free(raw);
    const text = alloc.alloc(u8, raw.len) catch return 0;
    defer alloc.free(text);
    const clean = pure.sanitizeUtf8(raw, text);
    const cues = alloc.alloc(pure.Cue, MAX_CUES) catch return 0;
    defer alloc.free(cues);
    const windows = alloc.alloc(pure.Window, MAX_WINDOWS) catch return 0;
    defer alloc.free(windows);
    const cue_n = pure.parseCues(clean, cues);
    const win_n = pure.chunk(cues[0..cue_n], .{}, windows);
    const ins = conn.prep("INSERT INTO recall_moments(doc_id,start_ms,end_ms,text) VALUES(?1,?2,?3,?4) RETURNING id") orelse return 0;
    defer db.finalize(ins);
    const fts = conn.prep("INSERT INTO recall_moments_fts(rowid,text) VALUES(?1,?2)");
    defer if (fts) |s| db.finalize(s);
    var buf = alloc.alloc(u8, 8192) catch return 0;
    defer alloc.free(buf);
    var written: usize = 0;
    for (windows[0..win_n]) |win| {
        const body = pure.windowText(cues[0..cue_n], win, buf[0..]);
        if (body.len == 0) continue;
        db.reset(ins);
        db.bindInt64(ins, 1, doc_id);
        db.bindInt64(ins, 2, win.start_ms);
        db.bindInt64(ins, 3, win.end_ms);
        db.bindText(ins, 4, body);
        if (db.step(ins) != db.c.SQLITE_ROW) continue;
        const mid = db.columnInt64(ins, 0);
        _ = db.step(ins);
        if (fts) |s| {
            db.reset(s);
            db.bindInt64(s, 1, mid);
            db.bindText(s, 2, body);
            _ = db.step(s);
        }
        written += 1;
    }
    return written;
}

// ── Sources ─────────────────────────────────────────────────────────────────

const Source = enum { library, local, tv };

const library_sql =
    "SELECT li.rowid, li.kind, li.item_id, li.title, li.poster, li.duration_secs, li.deep_link, " ++
    "IFNULL(t.overview,''), IFNULL(t.year,''), IFNULL(t.genre_text,'') " ++
    "FROM library_items li LEFT JOIN tmdb_items t ON li.kind IN ('movie','tv') AND li.item_id GLOB '[0-9]*' " ++
    "AND t.id = CAST(li.item_id AS INTEGER) AND t.media_type = CASE li.kind WHEN 'tv' THEN 'tv' ELSE 'movie' END " ++
    "WHERE li.rowid > ?1 AND IFNULL(li.deleted,0)=0 AND li.kind NOT IN ('search') AND li.item_id <> '' " ++
    // A watched local file is indexed once, as its local_media doc.
    "AND NOT (li.kind='watch' AND EXISTS(SELECT 1 FROM local_media m WHERE m.path=li.item_id)) " ++
    "ORDER BY li.rowid LIMIT ?2";

const local_sql =
    "SELECT m.rowid, m.path, COALESCE(NULLIF(m.display_title,''),m.title), IFNULL(m.media_kind,''), " ++
    "IFNULL((SELECT w.duration_secs FROM watch_history w WHERE w.file_key=m.path LIMIT 1),0) " ++
    "FROM local_media m WHERE m.rowid > ?1 ORDER BY m.rowid LIMIT ?2";

const tv_sql =
    "SELECT s.tmdb_id, s.tmdb_id, IFNULL(s.name,''), IFNULL(s.poster_path,''), " ++
    "IFNULL(t.overview,''), IFNULL(t.year,''), IFNULL(t.genre_text,'') " ++
    "FROM tv_shows s LEFT JOIN tmdb_items t ON t.id=s.tmdb_id AND t.media_type='tv' " ++
    "WHERE s.tmdb_id > ?1 AND s.tracked=1 AND IFNULL(s.name,'') <> '' " ++
    "AND NOT EXISTS(SELECT 1 FROM library_items li WHERE li.kind='tv' AND li.item_id=CAST(s.tmdb_id AS TEXT) AND IFNULL(li.deleted,0)=0) " ++
    "ORDER BY s.tmdb_id LIMIT ?2";

fn localKind(media_kind: []const u8, path: []const u8) pure.Kind {
    if (std.mem.eql(u8, media_kind, "movie")) return .movie;
    if (std.mem.eql(u8, media_kind, "tv")) return .show;
    if (std.mem.eql(u8, media_kind, "music")) return .music;
    if (std.mem.eql(u8, media_kind, "audiobook")) return .book;
    if (std.mem.eql(u8, media_kind, "other")) return .other;
    return pure.kindFromFilename(path);
}

/// Read one page of `src` after `cursor` into `rows`. Returns the count and
/// advances `cursor`; null on a query failure (the pass is then incomplete).
fn readPage(conn: *Conn, src: Source, cursor: *i64, rows: []Row) ?usize {
    const sql = switch (src) {
        .library => library_sql,
        .local => local_sql,
        .tv => tv_sql,
    };
    const stmt = conn.prep(sql) orelse return null;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, cursor.*);
    db.bindInt64(stmt, 2, @intCast(rows.len));
    var n: usize = 0;
    while (n < rows.len) {
        const rc = db.step(stmt);
        if (rc == db.c.SQLITE_DONE) break;
        if (rc != db.c.SQLITE_ROW) return null;
        cursor.* = db.columnInt64(stmt, 0);
        const r = &rows[n];
        r.* = .{};
        switch (src) {
            .library => {
                const kind = colText(stmt, 1);
                const item_id = colText(stmt, 2);
                const title = colText(stmt, 3);
                r.source = "library";
                r.setKey("{s}:{s}", .{ kind, item_id[0..@min(item_id.len, 140)] });
                r.kind = pure.kindFromLibrary(kind, if (title.len > 0) title else item_id);
                Row.set(&r.title, &r.title_len, title);
                r.setPoster(colText(stmt, 4));
                const dur = db.columnDouble(stmt, 5);
                r.runtime = if (dur > 0 and dur < 1e7) @intFromFloat(dur) else 0;
                Row.set(&r.link, &r.link_len, colText(stmt, 6));
                r.setBody(colText(stmt, 7), colText(stmt, 9));
                r.year = parseYear(colText(stmt, 8));
                if (r.year == 0) r.year = pure.yearFromName(if (std.mem.eql(u8, kind, "watch")) item_id else title);
                Row.set(&r.lib_kind, &r.lib_kind_len, kind);
                Row.set(&r.lib_id, &r.lib_id_len, item_id);
            },
            .local => {
                const path = colText(stmt, 1);
                r.source = "local";
                r.setKey("{d}", .{cursor.*});
                Row.set(&r.title, &r.title_len, colText(stmt, 2));
                r.kind = localKind(colText(stmt, 3), path);
                const base = if (std.mem.lastIndexOfAny(u8, path, "/\\")) |s| path[s + 1 ..] else path;
                r.year = pure.yearFromName(base);
                const dur = db.columnDouble(stmt, 4);
                r.runtime = if (dur > 0 and dur < 1e7) @intFromFloat(dur) else 0;
                Row.set(&r.lib_kind, &r.lib_kind_len, "watch");
                Row.set(&r.lib_id, &r.lib_id_len, path);
                Row.set(&r.link, &r.link_len, path);
            },
            .tv => {
                const id = db.columnInt64(stmt, 1);
                r.source = "tv";
                r.setKey("{d}", .{id});
                r.kind = .show;
                Row.set(&r.title, &r.title_len, colText(stmt, 2));
                r.setPoster(colText(stmt, 3));
                r.setBody(colText(stmt, 4), colText(stmt, 6));
                r.year = parseYear(colText(stmt, 5));
                Row.set(&r.lib_kind, &r.lib_kind_len, "tv");
                const idtxt = std.fmt.bufPrint(&r.lib_id, "{d}", .{id}) catch "";
                r.lib_id_len = idtxt.len;
            },
        }
        n += 1;
    }
    return n;
}

const PassStats = struct { docs: usize = 0, changed: usize = 0, moments: usize = 0, complete: bool = true };

fn syncSource(conn: *Conn, src: Source, token: i64, sidecars: bool, rows: []Row, stats: *PassStats) void {
    var cursor: i64 = std.math.minInt(i64);
    while (!workers.isQuitting()) {
        const n = readPage(conn, src, &cursor, rows) orelse {
            stats.complete = false;
            return;
        };
        if (n == 0) return;
        conn.begin();
        for (rows[0..n]) |*row| {
            const up = upsertDoc(conn, row, token) orelse continue;
            stats.docs += 1;
            if (up.changed) stats.changed += 1;
            const link = row.link[0..row.link_len];
            if ((up.changed or sidecars) and isAbsolute(link)) stats.moments += syncMoments(conn, up.id, up.subs_sig, link);
        }
        conn.commit();
        if (n < rows.len) return;
        io.sleep(BATCH_PAUSE_NS);
    }
    stats.complete = false;
}

fn sweep(conn: *Conn, token: i64) usize {
    var removed: usize = 0;
    while (!workers.isQuitting()) {
        const stmt = conn.prep("SELECT id FROM recall_docs WHERE seen<>?1 LIMIT 128") orelse return removed;
        db.bindInt64(stmt, 1, token);
        var ids: [128]i64 = undefined;
        var n: usize = 0;
        while (n < ids.len and db.step(stmt) == db.c.SQLITE_ROW) : (n += 1) ids[n] = db.columnInt64(stmt, 0);
        db.finalize(stmt);
        if (n == 0) break;
        conn.begin();
        for (ids[0..n]) |id| deleteDoc(conn, id);
        conn.commit();
        removed += n;
    }
    return removed;
}

// ── Embedding ───────────────────────────────────────────────────────────────

fn docEmbedText(stmt: ?*db.Stmt, out: []u8) []const u8 {
    var w = std.Io.Writer.fixed(out);
    w.writeAll(colText(stmt, 1)) catch {};
    const year = db.columnInt64(stmt, 3);
    if (year > 0) w.print(" ({d})", .{year}) catch {};
    w.print(". {s}. ", .{colText(stmt, 2)}) catch {};
    w.writeAll(colText(stmt, 4)) catch {};
    return w.buffered();
}

/// Embed pending docs then moments within the per-pass budget. Returns how
/// many rows were embedded; stops at the first endpoint failure.
fn embedPending(conn: *Conn) usize {
    if (!embed.available()) return 0;
    const vecs = alloc.alloc(f32, embed.MAX_BATCH * embed.MAX_DIM) catch return 0;
    defer alloc.free(vecs);
    const texts_buf = alloc.alloc(u8, embed.MAX_BATCH * EMBED_TEXT_MAX) catch return 0;
    defer alloc.free(texts_buf);
    var done: usize = 0;
    var tables_ready = false;
    inline for (.{ false, true }) |moments| {
        while (done < EMBED_BUDGET and !workers.isQuitting()) {
            const sql = if (moments)
                "SELECT id, text, '', 0, '' FROM recall_moments WHERE embedded=0 ORDER BY id LIMIT ?1"
            else
                "SELECT id, title, kind, year, body FROM recall_docs WHERE embedded=0 ORDER BY id LIMIT ?1";
            const stmt = conn.prep(sql) orelse break;
            db.bindInt64(stmt, 1, embed.MAX_BATCH);
            var ids: [embed.MAX_BATCH]i64 = undefined;
            var texts: [embed.MAX_BATCH][]const u8 = undefined;
            var n: usize = 0;
            while (n < embed.MAX_BATCH and db.step(stmt) == db.c.SQLITE_ROW) : (n += 1) {
                ids[n] = db.columnInt64(stmt, 0);
                const slot = texts_buf[n * EMBED_TEXT_MAX .. (n + 1) * EMBED_TEXT_MAX];
                var compose: [4096]u8 = undefined;
                const full = if (moments) colText(stmt, 1) else docEmbedText(stmt, &compose);
                // Never cut a UTF-8 sequence at the slot boundary.
                const cut = pure.utf8Prefix(full, slot.len);
                @memcpy(slot[0..cut.len], cut);
                const t = slot[0..cut.len];
                texts[n] = if (t.len == 0) " " else t;
            }
            db.finalize(stmt);
            if (n == 0) break;
            const dim = embed.embedBatch(texts[0..n], vecs, 30) orelse return done;
            if (!tables_ready) {
                if (!ensureVecTables(conn, dim)) return done;
                tables_ready = true;
            }
            const vec_sql = if (moments) "INSERT INTO recall_moments_vec(rowid, embedding) VALUES(?1, ?2)" else "INSERT INTO recall_vec(rowid, embedding) VALUES(?1, ?2)";
            const del_sql = if (moments) "DELETE FROM recall_moments_vec WHERE rowid=?1" else "DELETE FROM recall_vec WHERE rowid=?1";
            const mark_sql = if (moments) "UPDATE recall_moments SET embedded=1 WHERE id=?1" else "UPDATE recall_docs SET embedded=1 WHERE id=?1";
            conn.begin();
            const ins = conn.prep(vec_sql) orelse {
                conn.commit();
                return done;
            };
            for (0..n) |k| {
                conn.execId(del_sql, ids[k]);
                db.reset(ins);
                db.bindInt64(ins, 1, ids[k]);
                db.bindBlob(ins, 2, std.mem.sliceAsBytes(vecs[k * dim .. (k + 1) * dim]));
                if (db.step(ins) == db.c.SQLITE_DONE) conn.execId(mark_sql, ids[k]);
            }
            db.finalize(ins);
            conn.commit();
            done += n;
            io.sleep(BATCH_PAUSE_NS * 3);
        }
    }
    return done;
}

// ── Pass ────────────────────────────────────────────────────────────────────

fn publishCounts(conn: *Conn) void {
    if (conn.prep("SELECT (SELECT count(*) FROM recall_docs),(SELECT count(*) FROM recall_moments)")) |stmt| {
        if (db.step(stmt) == db.c.SQLITE_ROW) {
            doc_count.store(@intCast(@max(0, db.columnInt64(stmt, 0))), .release);
            moment_count.store(@intCast(@max(0, db.columnInt64(stmt, 1))), .release);
        }
        db.finalize(stmt);
    }
}

fn passWorker() void {
    if (running.swap(true, .acq_rel)) return;
    defer running.store(false, .release);
    var conn = Conn.open() orelse return;
    defer conn.close();
    if (!conn.tableExists("recall_docs")) return;

    const rows = alloc.alloc(Row, PAGE) catch return;
    defer alloc.free(rows);
    const token = io.milliTimestamp();
    const sidecars = pass_number % SIDECAR_EVERY == 0;
    pass_number +%= 1;
    var stats = PassStats{};
    for ([_]Source{ .library, .local, .tv }) |src| {
        if (workers.isQuitting()) return;
        syncSource(&conn, src, token, sidecars, rows, &stats);
    }
    var removed: usize = 0;
    if (stats.complete and !workers.isQuitting()) removed = sweep(&conn, token);
    const embedded = embedPending(&conn);
    publishCounts(&conn);
    if (stats.changed > 0 or removed > 0 or stats.moments > 0 or embedded > 0) {
        var msg: [160]u8 = undefined;
        logs.pushLog("info", "recall", std.fmt.bufPrint(&msg, "Recall index: {d} items ({d} updated, {d} removed), {d} new moments, {d} embedded", .{ stats.docs, stats.changed, removed, stats.moments, embedded }) catch "Recall index updated", false);
    }
}
