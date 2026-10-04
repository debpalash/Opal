//! The background operator: jobs Opal hands to a coding agent behind the scenes.
//!
//! Code anywhere in the app calls `request(kind, key, context)` when it hits a
//! problem fixed logic cannot solve. If the user switched the operator on and the
//! job passes the gate (cooldown per key, queue length, daily spend), it is stored
//! in `operator_jobs`. `tick()` (from the shared frame/headless loops) starts one
//! job at a time on a worker: the agent runs headless in a scratch directory with
//! no Opal tools, only the context in the prompt, and answers with JSON that the
//! CLI itself validates against the kind's schema. The answer is then validated
//! again here and handed to the kind's handler, which either applies it or leaves
//! it as a proposal for the user. Policy and parsing are in `operator_pure.zig`.

const std = @import("std");
const db = @import("../core/db.zig");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const io_g = @import("../core/io_global.zig");
const paths = @import("../core/paths.zig");
const workers = @import("../core/workers.zig");
const bounded = @import("../core/bounded_process.zig");
const alloc = @import("../core/alloc.zig").allocator;
const launch = @import("agent_launch.zig");
const pure = @import("operator_pure.zig");
const match_help = @import("operator_match_help.zig");
const endpoint = @import("operator_endpoint.zig");
const local_names = @import("operator_local_names.zig");

pub const Kind = pure.Kind;
const TICK_INTERVAL_MS: i64 = 15 * 1000;
const TIMEOUT_MS: i64 = 5 * 60 * 1000;
pub const MAX_CONTEXT = 3000;
const MAX_OUTPUT = 256 * 1024;
const MAX_RESULT_STORED = 4000;

var table_ready = std.atomic.Value(bool).init(false);
var busy = std.atomic.Value(bool).init(false);
var running_id = std.atomic.Value(i64).init(0);
var last_tick_ms: i64 = 0;

fn ensureTable() bool {
    if (table_ready.load(.acquire)) return true;
    if (db.get() == null) return false;
    db.exec(
        "CREATE TABLE IF NOT EXISTS operator_jobs(" ++
            "id INTEGER PRIMARY KEY AUTOINCREMENT," ++
            "kind TEXT NOT NULL," ++
            "key TEXT NOT NULL," ++
            "state TEXT NOT NULL DEFAULT 'queued'," ++
            "context TEXT NOT NULL DEFAULT ''," ++
            "result TEXT NOT NULL DEFAULT ''," ++
            "summary TEXT NOT NULL DEFAULT ''," ++
            "agent TEXT NOT NULL DEFAULT ''," ++
            "cost_cents INTEGER NOT NULL DEFAULT 0," ++
            "created_ms INTEGER NOT NULL DEFAULT 0," ++
            "finished_ms INTEGER NOT NULL DEFAULT 0," ++
            "day INTEGER NOT NULL DEFAULT 0)",
    );
    db.exec("CREATE INDEX IF NOT EXISTS operator_jobs_key ON operator_jobs(kind, key, created_ms)");
    // A job left `running` by a crash or a hard quit would count against the queue
    // forever. Its reserved cost stays charged: it may have spent money.
    db.exec("UPDATE operator_jobs SET state='failed', summary='Interrupted', finished_ms=0 WHERE state='running'");
    table_ready.store(true, .release);
    return true;
}

pub fn setEnabled(on: bool) void {
    state.app.operator_enabled = on;
    last_tick_ms = 0;
    state.markConfigDirty();
}

fn limits() pure.Limits {
    return .{ .daily_cents = state.app.operator_daily_cents };
}

// ── Requests ────────────────────────────────────────────────────────────

pub const RequestResult = enum { queued, disabled, cooling_down, queue_full, over_budget, invalid, unavailable };

fn scalarInt(sql: [:0]const u8, bind_a: ?[]const u8, bind_b: ?[]const u8, bind_day: ?i64) i64 {
    const stmt = db.prepare(sql) orelse return 0;
    defer db.finalize(stmt);
    var col: c_int = 1;
    if (bind_a) |a| {
        db.bindText(stmt, col, a);
        col += 1;
    }
    if (bind_b) |b| {
        db.bindText(stmt, col, b);
        col += 1;
    }
    if (bind_day) |d| db.bindInt64(stmt, col, d);
    if (db.step(stmt) == db.c.SQLITE_ROW) return db.columnInt64(stmt, 0);
    return 0;
}

/// Ask the operator to look into something. Cheap and safe to call from any
/// thread whenever a trigger condition holds; the gate decides whether anything
/// happens. `key` identifies the subject (a wanted item id, a source id), and the
/// same kind+key is not asked again within the kind's cooldown. `context` is plain
/// text describing the problem; it reaches the agent as untrusted data.
pub fn request(kind: Kind, key: []const u8, context: []const u8) RequestResult {
    if (key.len == 0 or key.len > 64 or context.len == 0 or context.len > MAX_CONTEXT) return .invalid;
    if (!state.app.operator_enabled) return .disabled;
    if (state.app.incognito_mode) return .disabled;
    if (!ensureTable()) return .unavailable;

    const now = io_g.milliTimestamp();
    const last = scalarInt("SELECT COALESCE(MAX(created_ms),0) FROM operator_jobs WHERE kind=?1 AND key=?2", kind.id(), key, null);
    const queued: u32 = @intCast(@max(0, scalarInt("SELECT COUNT(*) FROM operator_jobs WHERE state IN ('queued','running')", null, null, null)));
    const spent: u32 = @intCast(@max(0, scalarInt("SELECT COALESCE(SUM(cost_cents),0) FROM operator_jobs WHERE day=?1", null, null, pure_day(now))));
    switch (pure.gate(true, kind, last, now, queued, spent, limits())) {
        .ok => {},
        .disabled => return .disabled,
        .cooling_down => return .cooling_down,
        .queue_full => return .queue_full,
        .over_budget => return .over_budget,
    }

    const stmt = db.prepare("INSERT INTO operator_jobs(kind,key,context,created_ms,day,cost_cents) VALUES(?1,?2,?3,?4,?5,?6)") orelse return .unavailable;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, kind.id());
    db.bindText(stmt, 2, key);
    db.bindText(stmt, 3, context);
    db.bindInt64(stmt, 4, now);
    db.bindInt64(stmt, 5, pure_day(now));
    // The whole budget is reserved up front, so queued and running jobs count
    // against the daily limit. The final cost replaces it when the job ends.
    db.bindInt(stmt, 6, @intCast(pure.spec(kind).budget_cents));
    if (db.step(stmt) != db.c.SQLITE_DONE) return .unavailable;
    last_tick_ms = 0;
    state.wakeUi();
    return .queued;
}

fn pure_day(ms: i64) i64 {
    return @divFloor(ms, 24 * 60 * 60 * 1000);
}

// ── Scheduler ───────────────────────────────────────────────────────────

const Job = struct {
    id: i64 = 0,
    kind: Kind = .match_help,
    key: [64]u8 = undefined,
    key_len: usize = 0,
    context: [MAX_CONTEXT]u8 = undefined,
    context_len: usize = 0,
};

pub fn tick() void {
    if (!state.app.operator_enabled) return;
    const now = io_g.milliTimestamp();
    if (last_tick_ms != 0 and now - last_tick_ms < TICK_INTERVAL_MS) return;
    last_tick_ms = now;
    if (state.app.incognito_mode or busy.load(.acquire) or !ensureTable()) return;

    const job = nextQueued() orelse return;
    if (busy.swap(true, .acq_rel)) return;
    const th = workers.spawnLegacy(runJob, .{job}) catch {
        busy.store(false, .release);
        return;
    };
    workers.release(th);
}

fn nextQueued() ?Job {
    const stmt = db.prepare("SELECT id, kind, key, context FROM operator_jobs WHERE state='queued' ORDER BY id LIMIT 1") orelse return null;
    defer db.finalize(stmt);
    if (db.step(stmt) != db.c.SQLITE_ROW) return null;
    var job = Job{ .id = db.columnInt64(stmt, 0) };
    job.kind = Kind.parse(db.columnText(stmt, 1) orelse "") orelse {
        finish(job.id, .failed, "Unknown job kind", "", "", 0);
        return null;
    };
    const key = db.columnText(stmt, 2) orelse "";
    const ctx = db.columnText(stmt, 3) orelse "";
    if (key.len > job.key.len or ctx.len > job.context.len) {
        finish(job.id, .failed, "Job too large", "", "", 0);
        return null;
    }
    @memcpy(job.key[0..key.len], key);
    job.key_len = key.len;
    @memcpy(job.context[0..ctx.len], ctx);
    job.context_len = ctx.len;
    return job;
}

fn markRunning(id: i64, agent: []const u8) void {
    const stmt = db.prepare("UPDATE operator_jobs SET state='running', agent=?1 WHERE id=?2") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, agent);
    db.bindInt64(stmt, 2, id);
    _ = db.step(stmt);
}

fn finish(id: i64, st: pure.State, summary: []const u8, result: []const u8, agent: []const u8, cost_cents: u32) void {
    const stmt = db.prepare("UPDATE operator_jobs SET state=?1, summary=?2, result=?3, cost_cents=?4, finished_ms=?5, agent=CASE WHEN ?6<>'' THEN ?6 ELSE agent END WHERE id=?7") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, st.id());
    db.bindText(stmt, 2, summary);
    db.bindText(stmt, 3, result[0..@min(result.len, MAX_RESULT_STORED)]);
    db.bindInt(stmt, 4, @intCast(cost_cents));
    db.bindInt64(stmt, 5, io_g.milliTimestamp());
    db.bindText(stmt, 6, agent);
    db.bindInt64(stmt, 7, id);
    _ = db.step(stmt);
    state.wakeUi();
}

fn pickAgent(kind: Kind) ?pure.Agent {
    // Claude Code first (structured output and web tools are verified there);
    // Codex otherwise. A web kind runs on Codex with --search.
    _ = kind;
    if (launch.onPath("claude")) return .claude;
    if (launch.onPath("codex")) return .codex;
    return null;
}

/// End a job that never reached the agent: nothing was spent.
fn bail(job: Job, agent: []const u8, why: []const u8) void {
    finish(job.id, .failed, why, "", agent, 0);
}

fn runJob(job: Job) void {
    defer busy.store(false, .release);
    running_id.store(job.id, .release);
    defer running_id.store(0, .release);

    const agent = pickAgent(job.kind) orelse {
        finish(job.id, .failed, "No coding agent is installed (claude or codex on PATH)", "", "", 0);
        return;
    };
    markRunning(job.id, agent.binary());

    var prompt_buf: [MAX_CONTEXT + 2048]u8 = undefined;
    const prompt = pure.buildPrompt(&prompt_buf, job.kind, job.context[0..job.context_len]) orelse {
        finish(job.id, .failed, "Could not build the prompt", "", agent.binary(), 0);
        return;
    };

    // Scratch directory: the agent runs here, not in the user's data.
    var cfg_buf: [512]u8 = undefined;
    var dir_buf: [600]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buf, "{s}/operator", .{paths.configDir(&cfg_buf)}) catch return bail(job, agent.binary(), "The configuration path is too long");
    io_g.cwdMakePath(dir) catch {
        finish(job.id, .failed, "Could not create the scratch directory", "", agent.binary(), 0);
        return;
    };
    var schema_path: [700]u8 = undefined;
    var out_path: [700]u8 = undefined;
    const schema_file = std.fmt.bufPrint(&schema_path, "{s}/schema-{d}.json", .{ dir, job.id }) catch return bail(job, agent.binary(), "The configuration path is too long");
    const out_file = std.fmt.bufPrint(&out_path, "{s}/out-{d}.txt", .{ dir, job.id }) catch return bail(job, agent.binary(), "The configuration path is too long");
    if (agent == .codex) io_g.cwdWriteFile(.{ .sub_path = schema_file, .data = pure.spec(job.kind).schema }) catch {
        finish(job.id, .failed, "Could not write the schema file", "", agent.binary(), 0);
        return;
    };
    defer if (agent == .codex) {
        io_g.cwdDeleteFile(schema_file) catch {};
        io_g.cwdDeleteFile(out_file) catch {};
    };

    var argv: pure.Argv = .{};
    const cmd = pure.buildArgv(&argv, agent, job.kind, prompt, schema_file, out_file) orelse {
        finish(job.id, .failed, "Could not build the command", "", agent.binary(), 0);
        return;
    };

    const output = alloc.alloc(u8, MAX_OUTPUT) catch return bail(job, agent.binary(), "Out of memory");
    defer alloc.free(output);
    var got: usize = 0;
    var process = bounded.StreamProcess.init(cmd, .{
        .timeout_ms = TIMEOUT_MS,
        .terminate_grace_ms = 2000,
        .max_output_bytes = MAX_OUTPUT,
        .cwd = dir,
        .cancel_flag = workers.quittingSignal(),
    });
    process.start() catch {
        finish(job.id, .failed, "Could not start the agent", "", agent.binary(), 0);
        return;
    };
    if (process.stdout()) |stdout| {
        while (got < output.len) {
            const n = io_g.read(stdout, output[got..]) catch {
                process.requestStop();
                break;
            };
            if (n == 0) break;
            got += n;
            if (!process.noteOutput(n)) break;
        }
    }
    const result = process.finish();
    if (result.timed_out) {
        finish(job.id, .failed, "The agent took too long", "", agent.binary(), pure.spec(job.kind).budget_cents);
        return;
    }
    if (!result.ok()) {
        finish(job.id, .failed, "The agent did not finish (not signed in, out of credit, or an error)", "", agent.binary(), pure.spec(job.kind).budget_cents);
        return;
    }

    var reply: ?pure.Reply = null;
    switch (agent) {
        .claude => reply = pure.parseClaudeEnvelope(alloc, output[0..got]),
        .codex => {
            var file_buf: [64 * 1024]u8 = undefined;
            if (io_g.cwdOpenFile(out_file, .{})) |f| {
                defer f.close(io_g.io());
                const n = io_g.readAll(f, &file_buf) catch 0;
                reply = pure.parseBareObject(alloc, file_buf[0..n]);
            } else |_| {}
        },
    }
    const answer = reply orelse {
        finish(job.id, .failed, "The agent's answer was not valid", "", agent.binary(), pure.spec(job.kind).budget_cents);
        return;
    };
    defer alloc.free(answer.json);

    const key = job.key[0..job.key_len];
    const handled = switch (job.kind) {
        .match_help => match_help.handle(key, answer.json),
        .endpoint_repair => endpoint.handle(key, answer.json),
        .local_names => local_names.handle(key, answer.json),
    };
    // Claude reports what it spent; Codex does not, so it is charged the full budget.
    const cost = if (agent == .claude and answer.cost_cents > 0) answer.cost_cents else pure.spec(job.kind).budget_cents;
    finish(job.id, handled.state, handled.text(), answer.json, agent.binary(), cost);
    logs.pushLog(if (handled.state == .failed) "warn" else "info", "operator", if (handled.state == .failed) "A background job could not be used" else "A background job finished", false);
}

// ── User decisions on proposals ─────────────────────────────────────────

pub const DecideResult = enum { ok, no_such_job, not_proposed, failed, unavailable };

/// Approve a proposed job: the kind's handler applies it.
pub fn approve(id: i64) DecideResult {
    if (!ensureTable()) return .unavailable;
    const stmt = db.prepare("SELECT kind, key, state, result FROM operator_jobs WHERE id=?1") orelse return .unavailable;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, id);
    if (db.step(stmt) != db.c.SQLITE_ROW) return .no_such_job;
    const kind = Kind.parse(db.columnText(stmt, 0) orelse "") orelse return .failed;
    const st = pure.State.parse(db.columnText(stmt, 2) orelse "") orelse return .failed;
    if (st != .proposed) return .not_proposed;
    var key_buf: [64]u8 = undefined;
    var res_buf: [MAX_RESULT_STORED]u8 = undefined;
    const key = db.columnText(stmt, 1) orelse "";
    const res = db.columnText(stmt, 3) orelse "";
    if (key.len > key_buf.len or res.len > res_buf.len) return .failed;
    @memcpy(key_buf[0..key.len], key);
    @memcpy(res_buf[0..res.len], res);
    const ok = switch (kind) {
        .match_help => false, // applies itself, never proposed
        .local_names => false, // applies itself, never proposed
        .endpoint_repair => endpoint.approve(key_buf[0..key.len], res_buf[0..res.len]),
    };
    if (!ok) return .failed;
    setState(id, .applied);
    return .ok;
}

pub fn reject(id: i64) DecideResult {
    if (!ensureTable()) return .unavailable;
    const stmt = db.prepare("UPDATE operator_jobs SET state='rejected', finished_ms=?1 WHERE id=?2 AND state='proposed'") orelse return .unavailable;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, io_g.milliTimestamp());
    db.bindInt64(stmt, 2, id);
    if (db.step(stmt) != db.c.SQLITE_DONE) return .unavailable;
    if (db.c.sqlite3_changes(db.get()) == 0) return .not_proposed;
    state.wakeUi();
    return .ok;
}

fn setState(id: i64, st: pure.State) void {
    const stmt = db.prepare("UPDATE operator_jobs SET state=?1, finished_ms=?2 WHERE id=?3") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, st.id());
    db.bindInt64(stmt, 2, io_g.milliTimestamp());
    db.bindInt64(stmt, 3, id);
    _ = db.step(stmt);
    state.wakeUi();
}

// ── Listing ─────────────────────────────────────────────────────────────

pub fn spentTodayCents() u32 {
    if (!ensureTable()) return 0;
    return @intCast(@max(0, scalarInt("SELECT COALESCE(SUM(cost_cents),0) FROM operator_jobs WHERE day=?1", null, null, pure_day(io_g.milliTimestamp()))));
}

/// Write `{"enabled":bool,"daily_cents":n,"spent_cents":n,"running":id,"jobs":[...]}`
/// with the newest 100 jobs. Contexts are not included (they may hold titles the
/// user typed); results and summaries are.
pub fn writeListJson(w: *std.Io.Writer) !void {
    var s = std.json.Stringify{ .writer = w };
    try s.beginObject();
    try s.objectField("enabled");
    try s.write(state.app.operator_enabled);
    try s.objectField("daily_cents");
    try s.write(state.app.operator_daily_cents);
    try s.objectField("spent_cents");
    try s.write(spentTodayCents());
    try s.objectField("running");
    try s.write(running_id.load(.acquire));
    try s.objectField("jobs");
    try s.beginArray();
    if (ensureTable()) {
        if (db.prepare("SELECT id, kind, key, state, summary, result, agent, cost_cents, created_ms, finished_ms FROM operator_jobs ORDER BY id DESC LIMIT 100")) |st| {
            defer db.finalize(st);
            while (db.step(st) == db.c.SQLITE_ROW) {
                try s.beginObject();
                try s.objectField("id");
                try s.write(db.columnInt64(st, 0));
                try s.objectField("kind");
                try s.write(db.columnText(st, 1) orelse "");
                try s.objectField("title");
                try s.write(if (Kind.parse(db.columnText(st, 1) orelse "")) |k| pure.spec(k).title else "");
                try s.objectField("key");
                try s.write(db.columnText(st, 2) orelse "");
                try s.objectField("state");
                try s.write(db.columnText(st, 3) orelse "");
                try s.objectField("summary");
                try s.write(db.columnText(st, 4) orelse "");
                try s.objectField("result");
                try s.write(db.columnText(st, 5) orelse "");
                try s.objectField("agent");
                try s.write(db.columnText(st, 6) orelse "");
                try s.objectField("cost_cents");
                try s.write(db.columnInt(st, 7));
                try s.objectField("created_ms");
                try s.write(db.columnInt64(st, 8));
                try s.objectField("finished_ms");
                try s.write(db.columnInt64(st, 9));
                try s.endObject();
            }
        }
    }
    try s.endArray();
    try s.endObject();
}

/// One job for the UI. Fixed buffers so a snapshot needs no allocation. Neither
/// the context nor the stored answer is copied: the list shows what happened and
/// what is proposed (the summary), never the raw data sent to the agent.
pub const Row = struct {
    id: i64 = 0,
    kind: Kind = .match_help,
    state: pure.State = .queued,
    key: [64]u8 = std.mem.zeroes([64]u8),
    key_len: usize = 0,
    summary: [240]u8 = std.mem.zeroes([240]u8),
    summary_len: usize = 0,
    agent: [16]u8 = std.mem.zeroes([16]u8),
    agent_len: usize = 0,
    cost_cents: u32 = 0,
    created_ms: i64 = 0,
    finished_ms: i64 = 0,

    pub fn title(self: *const Row) []const u8 {
        return pure.spec(self.kind).title;
    }
};

fn copyInto(dst: []u8, text: []const u8) usize {
    const n = @min(text.len, dst.len);
    @memcpy(dst[0..n], text[0..n]);
    return n;
}

/// The jobs waiting for the user first, then the rest, newest first, up to
/// `out.len`. Returns how many rows were written.
pub fn snapshot(out: []Row) usize {
    if (out.len == 0 or !ensureTable()) return 0;
    const stmt = db.prepare(
        "SELECT id, kind, key, state, summary, agent, cost_cents, created_ms, finished_ms FROM operator_jobs " ++
            "ORDER BY (state='proposed') DESC, id DESC LIMIT ?1",
    ) orelse return 0;
    defer db.finalize(stmt);
    db.bindInt(stmt, 1, @intCast(@min(out.len, 200)));
    var n: usize = 0;
    while (n < out.len and db.step(stmt) == db.c.SQLITE_ROW) {
        var r = Row{};
        r.id = db.columnInt64(stmt, 0);
        r.kind = Kind.parse(db.columnText(stmt, 1) orelse "") orelse continue;
        r.key_len = copyInto(&r.key, db.columnText(stmt, 2) orelse "");
        r.state = pure.State.parse(db.columnText(stmt, 3) orelse "") orelse continue;
        r.summary_len = copyInto(&r.summary, db.columnText(stmt, 4) orelse "");
        r.agent_len = copyInto(&r.agent, db.columnText(stmt, 5) orelse "");
        r.cost_cents = @intCast(@max(0, db.columnInt(stmt, 6)));
        r.created_ms = db.columnInt64(stmt, 7);
        r.finished_ms = db.columnInt64(stmt, 8);
        out[n] = r;
        n += 1;
    }
    return n;
}
