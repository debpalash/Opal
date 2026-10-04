//! The last page a user shared from their browser, held in memory only.
//!
//! One page at a time, never written to disk: a new share replaces the old one,
//! Dismiss clears it, and quitting Opal forgets it. The rules (what is accepted,
//! what an agent may see) are in browser_page_pure.zig; this file owns the lock
//! and the memory, and is the one place that reads the global agents switch.
//!
//! Who reads what:
//!   * the Browser hub (UI thread) reads `uiView` and acts through `playFromUi`;
//!   * agents reach `writeContext` and `playForAgent` through routes that only the
//!     machine token and admin sessions pass (access_pure), and both refuse unless
//!     `pure.agentsMaySee`.

const std = @import("std");
const state = @import("../core/state.zig");
const io = @import("../core/io_global.zig");
const sync = @import("../core/sync.zig");
const alloc = @import("../core/alloc.zig").allocator;
const logs = @import("../core/logs.zig");
const link = @import("browser_link.zig");
const link_pure = @import("browser_link_pure.zig");
const pure = @import("browser_page_pure.zig");
const forwarded_open = @import("forwarded_open.zig");

var mutex: sync.Mutex = .{};
var arena: ?std.heap.ArenaAllocator = null;
var page: ?pure.Page = null;
var next_id: u32 = 0;
/// Set by the share route and cleared when the hub shows it, so the hub can pull
/// itself to the front of the user's attention exactly once per share.
var fresh: bool = false;

/// Store a share. The body is parsed straight into a new arena that then owns
/// the page; the previous page's arena is freed after the swap.
pub fn share(body: []const u8, link_id: i64) pure.ParseError!u32 {
    var a = std.heap.ArenaAllocator.init(alloc);
    errdefer a.deinit();
    const parsed = try pure.parseShare(a.allocator(), body);

    mutex.lock();
    defer mutex.unlock();
    if (arena) |*old| old.deinit();
    arena = a;
    next_id +%= 1;
    if (next_id == 0) next_id = 1;
    page = .{ .id = next_id, .shared_at = io.timestamp(), .link_id = link_id, .share = parsed };
    fresh = true;
    state.wakeUi();
    return next_id;
}

pub fn dismiss() void {
    mutex.lock();
    defer mutex.unlock();
    page = null;
    fresh = false;
    if (arena) |*old| old.deinit();
    arena = null;
}

/// True once after each new share.
pub fn takeFresh() bool {
    mutex.lock();
    defer mutex.unlock();
    const was = fresh;
    fresh = false;
    return was;
}

fn switchOn() bool {
    return state.app.browser_share_agents;
}

// ── Agents ─────────────────────────────────────────────────────────────────

pub const View = enum { status, page, candidates };

/// Write the JSON for one `GET /api/browser/context?view=`. Content views are
/// empty unless the user allowed it twice (the page's own box and the global switch).
pub fn writeContext(w: *std.Io.Writer, view: View) !void {
    const now = io.timestamp();
    var rows: [link_pure.MAX_LINKS]link.Link = undefined;
    const n = if (view == .status) link.list(&rows) else 0;

    mutex.lock();
    defer mutex.unlock();
    const p: ?*const pure.Page = if (page) |*pp| pp else null;
    switch (view) {
        .status => {
            var infos: [link_pure.MAX_LINKS]pure.LinkInfo = undefined;
            for (rows[0..n], 0..) |*r, i| infos[i] = .{ .id = r.id, .label = r.labelSlice(), .browser = r.browserSlice(), .last_seen = r.last_seen };
            try pure.writeStatus(w, infos[0..n], now, p, switchOn());
        },
        .page => if (pure.agentsMaySee(p, switchOn())) try pure.writePage(w, p.?) else try pure.writeEmpty(w, switchOn()),
        .candidates => if (pure.agentsMaySee(p, switchOn())) try pure.writeCandidates(w, p.?) else try pure.writeEmpty(w, switchOn()),
    }
}

pub const PlayError = error{ not_shared, stale, missing, busy };

pub const Played = struct {
    kind: link_pure.Kind,
    referer_sent: bool,
};

fn playLocked(p: *const pure.Page, page_id: u32, id: u32, queue_only: bool) PlayError!Played {
    const c = switch (pure.findCandidate(p, page_id, id)) {
        .ok => |c| c,
        .stale => return error.stale,
        .missing => return error.missing,
        .none => return error.not_shared,
    };
    if (queue_only and c.url.len > link_pure.MAX_QUEUE_URL) return error.missing;
    var hb: link_pure.HeaderBuf = .{};
    const headers = link_pure.playHeaders(c.*, p.share.url, &hb);
    var referer: []const u8 = "";
    var origin: []const u8 = "";
    for (headers) |h| {
        if (std.mem.eql(u8, h.name, "Referer")) referer = h.value;
        if (std.mem.eql(u8, h.name, "Origin")) origin = h.value;
    }
    if (!forwarded_open.pushBrowser(queue_only, c.url, p.share.title, "", referer, origin, c.ua)) return error.busy;
    return .{
        .kind = c.kind,
        .referer_sent = referer.len > 0 and !queue_only,
    };
}

/// An agent's request to play or queue a candidate by id. Refused unless the
/// page was shared with agents and the global switch is on; `page_id` must be
/// the one the agent read so a newer page cannot be played by an old id.
pub fn playForAgent(page_id: u32, id: u32, queue_only: bool) PlayError!Played {
    mutex.lock();
    defer mutex.unlock();
    const p: ?*const pure.Page = if (page) |*pp| pp else null;
    // Same answer as "nothing shared" so a refusal does not reveal whether a page exists.
    if (!pure.agentsMaySee(p, switchOn())) return error.not_shared;
    return playLocked(p.?, page_id, id, queue_only);
}

// ── The hub (UI thread) ────────────────────────────────────────────────────

pub const UI_MAX_CANDS = pure.MAX_CANDIDATES;

pub const UiCand = struct {
    id: u32 = 0,
    kind: link_pure.Kind = .other,
    label: [140]u8 = undefined,
    label_len: usize = 0,
    has_referer: bool = false,

    pub fn labelSlice(self: *const UiCand) []const u8 {
        return self.label[0..self.label_len];
    }
};

/// A copy of the shared page in fixed buffers, so the hub never holds the lock
/// while it draws and the row heights cannot depend on page content.
pub const UiView = struct {
    present: bool = false,
    page_id: u32 = 0,
    title: [link_pure.MAX_TITLE]u8 = undefined,
    title_len: usize = 0,
    /// scheme://host/path, no query: what the card shows as the address.
    where: [160]u8 = undefined,
    where_len: usize = 0,
    text_len: usize = 0,
    agents: bool = false,
    shared_at: i64 = 0,
    cands: [UI_MAX_CANDS]UiCand = undefined,
    cand_count: usize = 0,

    pub fn titleSlice(self: *const UiView) []const u8 {
        return self.title[0..self.title_len];
    }
    pub fn whereSlice(self: *const UiView) []const u8 {
        return self.where[0..self.where_len];
    }
};

fn copyClip(dst: []u8, src: []const u8) usize {
    var n = @min(src.len, dst.len);
    if (n < src.len) while (n > 0 and (src[n] & 0xC0) == 0x80) {
        n -= 1;
    };
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

pub fn uiView(out: *UiView) void {
    out.* = .{};
    mutex.lock();
    defer mutex.unlock();
    const p = page orelse return;
    out.present = true;
    out.page_id = p.id;
    out.title_len = copyClip(&out.title, p.share.title);
    var ubuf: [link_pure.MAX_PAGE_URL + 16]u8 = undefined;
    out.where_len = copyClip(&out.where, pure.urlNoQuery(p.share.url, &ubuf));
    out.text_len = p.share.text.len;
    out.agents = p.share.agents;
    out.shared_at = p.shared_at;
    out.cand_count = @min(p.share.candidates.len, UI_MAX_CANDS);
    for (p.share.candidates[0..out.cand_count], 0..) |c, i| {
        const parts = pure.splitUrl(c.url);
        var lb: [200]u8 = undefined;
        const label = std.fmt.bufPrint(&lb, "{s}{s}", .{ parts.host, parts.path }) catch parts.host;
        out.cands[i] = .{ .id = @intCast(i + 1), .kind = c.kind, .has_referer = c.referer.len > 0 };
        out.cands[i].label_len = copyClip(&out.cands[i].label, label);
    }
}

/// The user pressed Play or Queue on a candidate in the hub. The user's own
/// click needs neither the per-page box nor the agents switch.
pub fn playFromUi(page_id: u32, id: u32, queue_only: bool) PlayError!Played {
    mutex.lock();
    defer mutex.unlock();
    const p: ?*const pure.Page = if (page) |*pp| pp else null;
    const pp = p orelse return error.not_shared;
    return playLocked(pp, page_id, id, queue_only);
}

/// Copy the shared title (so the hub can offer it for editing). Empty when none.
pub fn copyTitle(out: []u8) usize {
    mutex.lock();
    defer mutex.unlock();
    const p = page orelse return 0;
    return copyClip(out, p.share.title);
}

/// Seed a shared page in tests and the offline render fixture without a request.
pub fn shareForTest(body: []const u8) !void {
    if (!@import("builtin").is_test) @compileError("test-only");
    _ = try share(body, 1);
}

pub fn logShared() void {
    logs.pushLog("info", "browser", "A page was shared from a paired browser", false);
}
