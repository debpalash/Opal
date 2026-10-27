//! Recall (ROADMAP 7.1) — query API over the recall index.
//!
//!   search(query, out)   library docs + subtitle moments for a natural-language
//!                        query: parse constraints (recall_pure.parse), gather
//!                        BM25 (FTS5, LIKE fallback) and cosine (vec0) rankings,
//!                        fuse them (recall_pure.fuse), build snippets.
//!   play(target)         start a doc or a moment through the shared playback
//!                        seam (browser.playDirect), a moment at its second.
//!   submit / snapshot    the desktop universal-search worker seam.
//!
//! Everything degrades: no FTS5 → LIKE, no embedding model → keywords only,
//! empty index → empty sections. Runs on worker / HTTP threads; the UI thread
//! only calls submit/snapshot.

const std = @import("std");
const db = @import("../core/db.zig");
const sync = @import("../core/sync.zig");
const state = @import("../core/state.zig");
const workers = @import("../core/workers.zig");
const alloc = @import("../core/alloc.zig").allocator;
const pure = @import("recall_pure.zig");
const embed = @import("recall_embed.zig");
const index = @import("recall_index.zig");

pub const MAX_DOCS = 12;
pub const MAX_MOMENTS = 8;
const CANDIDATES = 320;
const FTS_LIMIT = 100;
const VEC_LIMIT = 60;
const MOMENT_POOL = 60;

pub const Doc = struct {
    id: i64 = 0,
    source: [8]u8 = std.mem.zeroes([8]u8),
    source_len: usize = 0,
    kind: pure.Kind = .other,
    title: [200]u8 = std.mem.zeroes([200]u8),
    title_len: usize = 0,
    year: u16 = 0,
    runtime_secs: u32 = 0,
    percent: f32 = 0,
    favorite: bool = false,
    poster: [384]u8 = std.mem.zeroes([384]u8),
    poster_len: usize = 0,
    snippet: [220]u8 = std.mem.zeroes([220]u8),
    snippet_len: usize = 0,
    playable: bool = false,
    score: f64 = 0,

    pub fn titleText(self: *const Doc) []const u8 {
        return self.title[0..self.title_len];
    }
    pub fn snippetText(self: *const Doc) []const u8 {
        return self.snippet[0..self.snippet_len];
    }
    pub fn posterUrl(self: *const Doc) []const u8 {
        return self.poster[0..self.poster_len];
    }
};

pub const Moment = struct {
    id: i64 = 0,
    doc_id: i64 = 0,
    kind: pure.Kind = .other,
    title: [200]u8 = std.mem.zeroes([200]u8),
    title_len: usize = 0,
    start_secs: f64 = 0,
    end_secs: f64 = 0,
    snippet: [260]u8 = std.mem.zeroes([260]u8),
    snippet_len: usize = 0,
    score: f64 = 0,

    pub fn titleText(self: *const Moment) []const u8 {
        return self.title[0..self.title_len];
    }
    pub fn snippetText(self: *const Moment) []const u8 {
        return self.snippet[0..self.snippet_len];
    }
};

pub const Results = struct {
    parsed: pure.Parsed = .{},
    docs: [MAX_DOCS]Doc = @splat(.{}),
    doc_count: usize = 0,
    moments: [MAX_MOMENTS]Moment = @splat(.{}),
    moment_count: usize = 0,
    /// Search terms actually used (lowercase), for highlighting.
    term_buf: [256]u8 = std.mem.zeroes([256]u8),
    terms: [pure.MAX_TERMS][]const u8 = @splat(""),
    term_count: usize = 0,
    vectors: bool = false,
    fts: bool = false,
    indexed_docs: u64 = 0,
    indexed_moments: u64 = 0,

    pub fn termList(self: *const Results) []const []const u8 {
        return self.terms[0..self.term_count];
    }
};

pub const Options = struct {
    embed_timeout_secs: u32 = 4,
    moments: bool = true,
};

fn copy(dst: []u8, len: *usize, src: []const u8) void {
    const s = pure.utf8Prefix(src, dst.len);
    @memcpy(dst[0..s.len], s);
    len.* = s.len;
}

fn colText(stmt: ?*db.Stmt, col: c_int) []const u8 {
    return db.columnText(stmt, col) orelse "";
}

// ── Candidate gathering ─────────────────────────────────────────────────────

const Pool = struct {
    items: []pure.Candidate,
    len: usize = 0,

    fn find(self: *Pool, id: i64) ?*pure.Candidate {
        for (self.items[0..self.len]) |*c| if (c.id == id) return c;
        return null;
    }
    fn add(self: *Pool, id: i64) ?*pure.Candidate {
        if (self.find(id)) |c| return c;
        if (self.len >= self.items.len) return null;
        self.items[self.len] = .{ .id = id };
        self.len += 1;
        return &self.items[self.len - 1];
    }
};

fn ftsAvailable() bool {
    return db.tableExists("recall_fts");
}

/// BM25 (title weighted ×10) ranking, or a LIKE scoring fallback without FTS5.
fn gatherText(pool: *Pool, table: enum { docs, moments }, fts_on: bool, text: []const u8, terms: []const []const u8, limit: usize, exclude: i64) void {
    if (terms.len == 0) return;
    var rank: u32 = 0;
    if (fts_on) {
        var qbuf: [512]u8 = undefined;
        const match = pure.ftsQuery(text, &qbuf);
        if (match.len == 0) return;
        const sql = switch (table) {
            .docs => "SELECT rowid FROM recall_fts WHERE recall_fts MATCH ?1 ORDER BY bm25(recall_fts, 10.0, 1.0) LIMIT ?2",
            .moments => "SELECT rowid FROM recall_moments_fts WHERE recall_moments_fts MATCH ?1 ORDER BY bm25(recall_moments_fts) LIMIT ?2",
        };
        const stmt = db.prepare(sql) orelse return;
        defer db.finalize(stmt);
        db.bindText(stmt, 1, match);
        db.bindInt64(stmt, 2, @intCast(limit));
        while (db.step(stmt) == db.c.SQLITE_ROW) {
            const id = db.columnInt64(stmt, 0);
            if (id == exclude) continue;
            rank += 1;
            if (pool.add(id)) |c| {
                if (c.fts_rank == 0) c.fts_rank = rank;
            }
        }
        return;
    }
    // LIKE fallback: score = Σ title hits ×3 + body hits.
    var sql_buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&sql_buf);
    const n = @min(terms.len, pure.MAX_TERMS);
    w.writeAll(if (table == .docs) "SELECT id, (" else "SELECT id, (") catch return;
    for (0..n) |k| {
        if (k > 0) w.writeAll("+") catch return;
        if (table == .docs)
            w.print("(instr(lower(title),?{d})>0)*3+(instr(lower(body),?{d})>0)", .{ k + 1, k + 1 }) catch return
        else
            w.print("(instr(lower(text),?{d})>0)", .{k + 1}) catch return;
    }
    w.print(") AS s FROM {s} WHERE s>0 ORDER BY s DESC, id LIMIT {d}", .{ if (table == .docs) "recall_docs" else "recall_moments", limit }) catch return;
    const stmt = db.prepare(w.buffered()) orelse return;
    defer db.finalize(stmt);
    for (0..n) |k| db.bindText(stmt, @intCast(k + 1), terms[k]);
    while (db.step(stmt) == db.c.SQLITE_ROW) {
        const id = db.columnInt64(stmt, 0);
        if (id == exclude) continue;
        rank += 1;
        if (pool.add(id)) |c| {
            if (c.fts_rank == 0) c.fts_rank = rank;
        }
    }
}

fn gatherVector(pool: *Pool, table: enum { docs, moments }, vec: []const f32, limit: usize, exclude: i64) void {
    const sql = switch (table) {
        .docs => "SELECT rowid FROM recall_vec WHERE embedding MATCH ?1 AND k = ?2 ORDER BY distance",
        .moments => "SELECT rowid FROM recall_moments_vec WHERE embedding MATCH ?1 AND k = ?2 ORDER BY distance",
    };
    const stmt = db.prepare(sql) orelse return;
    defer db.finalize(stmt);
    db.bindBlob(stmt, 1, std.mem.sliceAsBytes(vec));
    db.bindInt64(stmt, 2, @intCast(limit));
    var rank: u32 = 0;
    while (db.step(stmt) == db.c.SQLITE_ROW) {
        const id = db.columnInt64(stmt, 0);
        if (id == exclude) continue;
        rank += 1;
        if (pool.add(id)) |c| {
            if (c.vec_rank == 0) c.vec_rank = rank;
        }
    }
}

const meta_sql =
    "SELECT d.kind, d.year, d.runtime_secs, d.lang, IFNULL(li.percent,0), IFNULL(li.is_favorite,0), " ++
    "IFNULL(li.updated_at,0), IFNULL(li.duration_secs,0) FROM recall_docs d " ++
    "LEFT JOIN library_items li ON li.kind=d.lib_kind AND li.item_id=d.lib_id AND IFNULL(li.deleted,0)=0 WHERE d.id=?1";

/// Fill a candidate's filter/boost fields from its doc (and library state).
fn fillMeta(stmt: ?*db.Stmt, doc_id: i64, cand: *pure.Candidate) bool {
    db.reset(stmt);
    db.bindInt64(stmt, 1, doc_id);
    if (db.step(stmt) != db.c.SQLITE_ROW) return false;
    cand.kind = pure.kindFromName(colText(stmt, 0));
    cand.year = @intCast(std.math.clamp(db.columnInt64(stmt, 1), 0, 9999));
    var runtime = db.columnInt64(stmt, 2);
    if (runtime <= 0) runtime = @intFromFloat(std.math.clamp(db.columnDouble(stmt, 7), 0, 1e7));
    cand.runtime_secs = @intCast(std.math.clamp(runtime, 0, std.math.maxInt(u32)));
    const lang = colText(stmt, 3);
    cand.lang_len = @min(lang.len, cand.lang.len);
    @memcpy(cand.lang[0..cand.lang_len], lang[0..cand.lang_len]);
    cand.percent = @floatCast(db.columnDouble(stmt, 4));
    cand.favorite = db.columnInt64(stmt, 5) != 0;
    cand.updated_at = db.columnInt64(stmt, 6);
    return true;
}

// ── Like-seed ────────────────────────────────────────────────────────────────

const Seed = struct { id: i64 = 0, body: [512]u8 = undefined, body_len: usize = 0 };

/// The library item a "like <title>" query refers to: best title match.
fn findSeed(title: []const u8, fts_on: bool) ?Seed {
    var tb: [256]u8 = undefined;
    var tl: [pure.MAX_TERMS][]const u8 = undefined;
    const n = pure.terms(title, &tb, &tl);
    if (n == 0) return null;
    var items: [16]pure.Candidate = undefined;
    var pool = Pool{ .items = &items };
    gatherText(&pool, .docs, fts_on, title, tl[0..n], 16, 0);
    if (pool.len == 0) return null;
    var best: ?*pure.Candidate = null;
    for (pool.items[0..pool.len]) |*c| if (best == null or c.fts_rank < best.?.fts_rank) {
        best = c;
    };
    var seed = Seed{ .id = best.?.id };
    const stmt = db.prepare("SELECT body FROM recall_docs WHERE id=?1") orelse return seed;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, seed.id);
    if (db.step(stmt) == db.c.SQLITE_ROW) copy(&seed.body, &seed.body_len, colText(stmt, 0));
    return seed;
}

fn storedVector(table: []const u8, id: i64, out: []f32) ?usize {
    var sql: [96]u8 = undefined;
    const q = std.fmt.bufPrint(&sql, "SELECT embedding FROM {s} WHERE rowid=?1", .{table}) catch return null;
    const stmt = db.prepare(q) orelse return null;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, id);
    if (db.step(stmt) != db.c.SQLITE_ROW) return null;
    const blob = db.columnBlob(stmt, 0) orelse return null;
    const dim = blob.len / @sizeOf(f32);
    if (dim == 0 or dim > out.len) return null;
    @memcpy(std.mem.sliceAsBytes(out[0..dim]), blob[0 .. dim * @sizeOf(f32)]);
    return dim;
}

// ── Search ──────────────────────────────────────────────────────────────────

pub fn search(query_raw: []const u8, out: *Results, opts: Options) void {
    out.* = .{};
    const query = std.mem.trim(u8, query_raw, " \t\r\n");
    if (query.len == 0 or query.len > 500) return;
    out.parsed = pure.parse(query);
    const c = &out.parsed.constraints;
    out.indexed_docs = index.doc_count.load(.acquire);
    out.indexed_moments = index.moment_count.load(.acquire);
    if (!db.tableExists("recall_docs")) return;
    out.fts = ftsAvailable();

    const fts_on = out.fts;
    var seed: ?Seed = null;
    if (c.like_len > 0) seed = findSeed(c.likeTitle(), fts_on);
    const exclude: i64 = if (seed) |s| s.id else 0;

    // Text to search: the residual, else what the "like" seed is about.
    var text = out.parsed.text();
    if (text.len == 0) if (seed) |*s| {
        text = s.body[0..s.body_len];
    };
    out.term_count = pure.terms(text, &out.term_buf, &out.terms);

    // Query vector: the seed's stored embedding, else embed the text.
    const dim_stored: usize = @intCast(@max(0, index.metaInt("embed_dim")));
    var qvec_buf: ?[]f32 = null;
    defer if (qvec_buf) |b| alloc.free(b);
    var qvec: []const f32 = &.{};
    if (dim_stored > 0 and dim_stored <= embed.MAX_DIM and db.tableExists("recall_vec")) {
        if (alloc.alloc(f32, embed.MAX_DIM)) |b| {
            qvec_buf = b;
            if (seed != null and out.parsed.text().len == 0) {
                if (storedVector("recall_vec", exclude, b)) |d| if (d == dim_stored) {
                    qvec = b[0..d];
                };
            }
            if (qvec.len == 0 and text.len > 0 and embed.available()) {
                if (embed.embedOne(text, b, opts.embed_timeout_secs)) |d| if (d == dim_stored) {
                    qvec = b[0..d];
                };
            }
        } else |_| {}
    }
    out.vectors = qvec.len > 0;

    const items = alloc.alloc(pure.Candidate, CANDIDATES) catch return;
    defer alloc.free(items);
    const meta = db.prepare(meta_sql) orelse return;
    defer db.finalize(meta);
    const now = @import("../core/io_global.zig").timestamp();

    // ── Docs ──
    {
        var pool = Pool{ .items = items };
        gatherText(&pool, .docs, fts_on, text, out.termList(), FTS_LIMIT, exclude);
        if (qvec.len > 0) gatherVector(&pool, .docs, qvec, VEC_LIMIT, exclude);
        const browse = out.term_count == 0 and qvec.len == 0;
        if (browse and c.active()) {
            // Constraint-only query ("unwatched movies under 2 hours"): rank the
            // newest docs by state alone.
            if (db.prepare("SELECT id FROM recall_docs ORDER BY id DESC LIMIT ?1")) |stmt| {
                defer db.finalize(stmt);
                db.bindInt64(stmt, 1, CANDIDATES);
                while (db.step(stmt) == db.c.SQLITE_ROW) {
                    const id = db.columnInt64(stmt, 0);
                    if (id != exclude) _ = pool.add(id);
                }
            }
        }
        var live: usize = 0;
        for (pool.items[0..pool.len]) |cand_in| {
            var cand = cand_in;
            if (!fillMeta(meta, cand.id, &cand)) continue;
            items[live] = cand;
            live += 1;
        }
        const kept = pure.fuse(items[0..live], c, now, browse);
        loadDocs(out, items[0..@min(kept, MAX_DOCS)]);
    }

    // ── Moments ──
    if (opts.moments and (out.term_count > 0 or qvec.len > 0) and out.parsed.text().len > 0) {
        var pool = Pool{ .items = items };
        gatherText(&pool, .moments, fts_on and db.tableExists("recall_moments_fts"), text, out.termList(), MOMENT_POOL, 0);
        if (qvec.len > 0 and db.tableExists("recall_moments_vec")) gatherVector(&pool, .moments, qvec, VEC_LIMIT, 0);
        const parent = db.prepare("SELECT doc_id, text FROM recall_moments WHERE id=?1") orelse return;
        defer db.finalize(parent);
        var live: usize = 0;
        for (pool.items[0..pool.len]) |cand_in| {
            var cand = cand_in;
            db.reset(parent);
            db.bindInt64(parent, 1, cand.id);
            if (db.step(parent) != db.c.SQLITE_ROW) continue;
            const doc_id = db.columnInt64(parent, 0);
            const hits = pure.termHits(colText(parent, 1), out.termList());
            if (!pure.momentRelevant(hits, out.term_count, cand.vec_rank > 0 and cand.vec_rank <= 10)) continue;
            if (!fillMeta(meta, doc_id, &cand)) continue;
            items[live] = cand;
            live += 1;
        }
        const kept = pure.fuse(items[0..live], c, now, false);
        loadMoments(out, items[0..@min(kept, MAX_MOMENTS)]);
    }
}

fn loadDocs(out: *Results, ranked: []const pure.Candidate) void {
    const stmt = db.prepare("SELECT source, kind, title, year, poster, body, link<>'' OR source='tv' FROM recall_docs WHERE id=?1") orelse return;
    defer db.finalize(stmt);
    for (ranked) |cand| {
        db.reset(stmt);
        db.bindInt64(stmt, 1, cand.id);
        if (db.step(stmt) != db.c.SQLITE_ROW) continue;
        const d = &out.docs[out.doc_count];
        d.* = .{ .id = cand.id, .kind = cand.kind, .year = cand.year, .runtime_secs = cand.runtime_secs, .percent = cand.percent, .favorite = cand.favorite, .score = cand.score };
        copy(&d.source, &d.source_len, colText(stmt, 0));
        copy(&d.title, &d.title_len, colText(stmt, 2));
        copy(&d.poster, &d.poster_len, colText(stmt, 4));
        var ranges: [8]pure.Range = undefined;
        const snip = pure.snippet(colText(stmt, 5), out.termList(), 180, &d.snippet, &ranges);
        d.snippet_len = snip.text.len;
        d.playable = db.columnInt64(stmt, 6) != 0;
        out.doc_count += 1;
    }
}

fn loadMoments(out: *Results, ranked: []const pure.Candidate) void {
    const stmt = db.prepare("SELECT m.doc_id, m.start_ms, m.end_ms, m.text, d.title, d.kind FROM recall_moments m JOIN recall_docs d ON d.id=m.doc_id WHERE m.id=?1") orelse return;
    defer db.finalize(stmt);
    for (ranked) |cand| {
        db.reset(stmt);
        db.bindInt64(stmt, 1, cand.id);
        if (db.step(stmt) != db.c.SQLITE_ROW) continue;
        const m = &out.moments[out.moment_count];
        m.* = .{ .id = cand.id, .doc_id = db.columnInt64(stmt, 0), .score = cand.score };
        m.start_secs = @as(f64, @floatFromInt(db.columnInt64(stmt, 1))) / 1000.0;
        m.end_secs = @as(f64, @floatFromInt(db.columnInt64(stmt, 2))) / 1000.0;
        var ranges: [8]pure.Range = undefined;
        const snip = pure.snippet(colText(stmt, 3), out.termList(), 220, &m.snippet, &ranges);
        m.snippet_len = snip.text.len;
        copy(&m.title, &m.title_len, colText(stmt, 4));
        m.kind = pure.kindFromName(colText(stmt, 5));
        out.moment_count += 1;
    }
}

// ── Playback ────────────────────────────────────────────────────────────────

pub const Target = struct {
    doc_id: i64 = 0,
    source: [8]u8 = std.mem.zeroes([8]u8),
    source_len: usize = 0,
    lib_kind: [16]u8 = std.mem.zeroes([16]u8),
    lib_kind_len: usize = 0,
    lib_id: [160]u8 = std.mem.zeroes([160]u8),
    lib_id_len: usize = 0,
    link: [1024]u8 = std.mem.zeroes([1024]u8),
    link_len: usize = 0,
    title: [200]u8 = std.mem.zeroes([200]u8),
    title_len: usize = 0,
    poster: [384]u8 = std.mem.zeroes([384]u8),
    poster_len: usize = 0,
    /// Moment start; null plays from the item's own resume point.
    start_secs: ?f64 = null,

    pub fn sourceText(self: *const Target) []const u8 {
        return self.source[0..self.source_len];
    }
    pub fn linkText(self: *const Target) []const u8 {
        return self.link[0..self.link_len];
    }
    pub fn titleText(self: *const Target) []const u8 {
        return self.title[0..self.title_len];
    }
    pub fn libKind(self: *const Target) []const u8 {
        return self.lib_kind[0..self.lib_kind_len];
    }
    pub fn libId(self: *const Target) []const u8 {
        return self.lib_id[0..self.lib_id_len];
    }
};

/// Resolve a doc (moment_id = 0) or a moment to what playback needs.
pub fn target(doc_id_in: i64, moment_id: i64) ?Target {
    var t = Target{};
    var doc_id = doc_id_in;
    if (moment_id > 0) {
        const m = db.prepare("SELECT doc_id, start_ms FROM recall_moments WHERE id=?1") orelse return null;
        defer db.finalize(m);
        db.bindInt64(m, 1, moment_id);
        if (db.step(m) != db.c.SQLITE_ROW) return null;
        doc_id = db.columnInt64(m, 0);
        t.start_secs = @as(f64, @floatFromInt(db.columnInt64(m, 1))) / 1000.0;
    }
    if (doc_id <= 0) return null;
    const stmt = db.prepare("SELECT source, lib_kind, lib_id, link, title, poster FROM recall_docs WHERE id=?1") orelse return null;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, doc_id);
    if (db.step(stmt) != db.c.SQLITE_ROW) return null;
    t.doc_id = doc_id;
    copy(&t.source, &t.source_len, colText(stmt, 0));
    copy(&t.lib_kind, &t.lib_kind_len, colText(stmt, 1));
    copy(&t.lib_id, &t.lib_id_len, colText(stmt, 2));
    const link = colText(stmt, 3);
    if (link.len > t.link.len) return null; // never play a truncated path
    copy(&t.link, &t.link_len, link);
    copy(&t.title, &t.title_len, colText(stmt, 4));
    copy(&t.poster, &t.poster_len, colText(stmt, 5));
    return t;
}

fn isDirectMedia(link: []const u8) bool {
    if (link.len == 0) return false;
    if (link[0] == '/' or (link.len > 2 and link[1] == ':')) return true;
    const schemes = [_][]const u8{ "http://", "https://", "magnet:", "file://" };
    for (schemes) |s| if (std.mem.startsWith(u8, link, s)) return true;
    return false;
}

/// Kinds whose deep link is itself a playable media URL (see home.openLibItem).
fn directKind(lib_kind: []const u8) bool {
    const kinds = [_][]const u8{ "watch", "movie", "iptv", "radio", "music", "" };
    for (kinds) |k| if (std.mem.eql(u8, lib_kind, k)) return true;
    return false;
}

/// Start playback when the target is a file or stream URL; a moment starts at
/// its second through the player's exact-second resume path. Returns false
/// when the item needs its vertical's own opener (anime, podcast, comics, …),
/// which only the desktop UI can route. Safe from any thread: playDirect
/// defers to the owner loop when called off it.
pub fn play(t: *const Target) bool {
    const link = t.linkText();
    if (!isDirectMedia(link)) return false;
    if (std.mem.eql(u8, t.sourceText(), "library") and !directKind(t.libKind())) return false;
    @import("browser.zig").playDirect(.{
        .url = link,
        .title = t.titleText(),
        .art_url = t.poster[0..t.poster_len],
        .resume_position_secs = t.start_secs,
    });
    return true;
}

// ── Desktop worker seam ─────────────────────────────────────────────────────

var ui_mutex: sync.Mutex = .{};
var ui_results: Results = .{};
var ui_query: [512]u8 = undefined;
var ui_query_len: usize = 0;
var ui_ready = false;
var ui_generation = std.atomic.Value(u64).init(0);
var ui_busy = std.atomic.Value(bool).init(false);
// Pending request, copied before the worker starts (guarded by ui_mutex).
var pending_query: [512]u8 = undefined;
var pending_len: usize = 0;
var pending_generation: u64 = 0;

/// UI thread: start recall for a universal-search query. Bare titles clear the
/// sections (wantsRecall); a newer query supersedes an in-flight one.
pub fn submit(query_raw: []const u8) void {
    const query = std.mem.trim(u8, query_raw, " \t\r\n");
    const gen = ui_generation.fetchAdd(1, .acq_rel) + 1;
    const parsed = pure.parse(query);
    ui_mutex.lock();
    ui_ready = false;
    ui_query_len = 0;
    if (query.len == 0 or query.len > pending_query.len or !pure.wantsRecall(&parsed)) {
        pending_len = 0;
        ui_mutex.unlock();
        return;
    }
    @memcpy(pending_query[0..query.len], query);
    pending_len = query.len;
    pending_generation = gen;
    ui_mutex.unlock();
    if (ui_busy.swap(true, .acq_rel)) return; // the running worker picks it up
    workers.spawn(uiWorker, .{}) catch ui_busy.store(false, .release);
}

/// UI thread: hide the sections (search cleared).
pub fn clear() void {
    _ = ui_generation.fetchAdd(1, .acq_rel);
    ui_mutex.lock();
    ui_ready = false;
    pending_len = 0;
    ui_mutex.unlock();
}

fn uiWorker() void {
    const results = alloc.create(Results) catch {
        ui_busy.store(false, .release);
        return;
    };
    defer alloc.destroy(results);
    var query: [512]u8 = undefined;
    while (!workers.isQuitting()) {
        ui_mutex.lock();
        const len = pending_len;
        const gen = pending_generation;
        @memcpy(query[0..len], pending_query[0..len]);
        pending_len = 0;
        ui_mutex.unlock();
        if (len == 0) break;
        search(query[0..len], results, .{});
        ui_mutex.lock();
        if (gen == ui_generation.load(.acquire)) {
            ui_results = results.*;
            fixTerms(&ui_results);
            @memcpy(ui_query[0..len], query[0..len]);
            ui_query_len = len;
            ui_ready = true;
        }
        ui_mutex.unlock();
        state.wakeUi();
    }
    ui_busy.store(false, .release);
    // A submit that raced the exit above (saw busy=true) would otherwise wait
    // for the next query; respawn once if work is pending.
    ui_mutex.lock();
    const again = pending_len > 0;
    ui_mutex.unlock();
    if (again and !workers.isQuitting() and !ui_busy.swap(true, .acq_rel)) {
        workers.spawn(uiWorker, .{}) catch ui_busy.store(false, .release);
    }
}

/// `terms` are slices into the struct's own term_buf; re-point them after a copy.
fn fixTerms(r: *Results) void {
    var off: usize = 0;
    for (r.terms[0..r.term_count]) |*t| {
        const n = t.len;
        t.* = r.term_buf[off .. off + n];
        off += n;
    }
}

/// UI thread: copy the published results for `query` (exact match) into `out`.
pub fn snapshot(query: []const u8, out: *Results) bool {
    ui_mutex.lock();
    defer ui_mutex.unlock();
    if (!ui_ready or !std.mem.eql(u8, ui_query[0..ui_query_len], std.mem.trim(u8, query, " \t\r\n"))) return false;
    out.* = ui_results;
    fixTerms(out);
    return true;
}
