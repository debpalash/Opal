//! Scheduled agent tasks: prompts a coding agent runs on a timer, unattended.
//!
//! Running an agent spends the user's own subscription or API credit, so nothing
//! runs until the user flips the master switch (Settings → Agent Access), and
//! every task has a daily run cap, a per-run timeout and (Claude Code) a hard
//! dollar budget. The agent gets Opal's tools through the same `opal-mcp` and
//! policy as an interactive one, so a scheduled run cannot do more than a chat.
//!
//! `tick()` is called from the shared frame/headless loops, is self-throttled,
//! and runs at most one task at a time on a worker thread. Schedule math and the
//! headless argv live in `agent_tasks_pure.zig`.

const std = @import("std");
const db = @import("../core/db.zig");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const io_g = @import("../core/io_global.zig");
const workers = @import("../core/workers.zig");
const bounded = @import("../core/bounded_process.zig");
const launch = @import("agent_launch.zig");
const pure = @import("agent_tasks_pure.zig");
const setup = @import("agent_setup_pure.zig");

pub const Agent = pure.Agent;
const TICK_INTERVAL_MS: i64 = 30 * 1000;
const SUMMARY_MAX: usize = 400;

var table_ready = std.atomic.Value(bool).init(false);
var busy = std.atomic.Value(bool).init(false);
var running_id = std.atomic.Value(i64).init(0);
var last_tick_ms: i64 = 0;

fn ensureTable() bool {
    if (table_ready.load(.acquire)) return true;
    if (db.get() == null) return false;
    db.exec(
        "CREATE TABLE IF NOT EXISTS agent_tasks(" ++
            "id INTEGER PRIMARY KEY AUTOINCREMENT," ++
            "name TEXT NOT NULL UNIQUE COLLATE NOCASE," ++
            "prompt TEXT NOT NULL," ++
            "agent TEXT NOT NULL DEFAULT 'claude'," ++
            "interval_min INTEGER NOT NULL DEFAULT 1440," ++
            "max_runs_per_day INTEGER NOT NULL DEFAULT 2," ++
            "budget_cents INTEGER NOT NULL DEFAULT 50," ++
            "enabled INTEGER NOT NULL DEFAULT 1," ++
            "created_ms INTEGER NOT NULL DEFAULT 0," ++
            "last_run_ms INTEGER NOT NULL DEFAULT 0," ++
            "day INTEGER NOT NULL DEFAULT 0," ++
            "runs_today INTEGER NOT NULL DEFAULT 0," ++
            "total_runs INTEGER NOT NULL DEFAULT 0," ++
            "last_outcome TEXT NOT NULL DEFAULT ''," ++
            "last_summary TEXT NOT NULL DEFAULT '')",
    );
    table_ready.store(true, .release);
    return true;
}

// ── Public operations (API / agents / UI) ───────────────────────────────

pub const AddRequest = struct {
    name: []const u8,
    prompt: []const u8,
    agent: Agent = .claude,
    interval_min: u32 = 1440,
    max_runs_per_day: u32 = 2,
    budget_cents: u32 = 50,
    /// Tasks added over the HTTP API (agents, web remote) start paused: a person
    /// reviews and enables them in the UI. The UI itself adds enabled ones.
    enabled: bool = true,
};

pub const AddResult = union(enum) {
    added: i64,
    exists: i64,
    invalid: []const u8,
    full,
    unavailable,
};

pub fn add(req: AddRequest) AddResult {
    const name = std.mem.trim(u8, req.name, " \t\r\n");
    if (!pure.validName(name)) return .{ .invalid = "name must be 1-60 characters without control characters" };
    if (!pure.validPrompt(req.prompt)) return .{ .invalid = "prompt must be 1-2000 characters" };
    if (!pure.validInterval(req.interval_min)) return .{ .invalid = "interval_min must be 15 to 10080" };
    if (!pure.validRunsPerDay(req.max_runs_per_day)) return .{ .invalid = "max_runs_per_day must be 1 to 24" };
    if (!pure.validBudget(req.budget_cents)) return .{ .invalid = "budget_cents must be 5 to 1000" };
    if (!ensureTable()) return .unavailable;

    if (findId(name)) |id| return .{ .exists = id };
    if (countTasks() >= pure.MAX_TASKS) return .full;

    const stmt = db.prepare(
        "INSERT INTO agent_tasks(name,prompt,agent,interval_min,max_runs_per_day,budget_cents,created_ms,enabled) VALUES(?1,?2,?3,?4,?5,?6,?7,?8)",
    ) orelse return .unavailable;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, name);
    db.bindText(stmt, 2, req.prompt);
    db.bindText(stmt, 3, req.agent.binary());
    db.bindInt(stmt, 4, @intCast(req.interval_min));
    db.bindInt(stmt, 5, @intCast(req.max_runs_per_day));
    db.bindInt(stmt, 6, @intCast(req.budget_cents));
    db.bindInt64(stmt, 7, io_g.milliTimestamp());
    db.bindInt(stmt, 8, if (req.enabled) 1 else 0);
    if (db.step(stmt) != db.c.SQLITE_DONE) return .unavailable;
    const id: i64 = db.c.sqlite3_last_insert_rowid(db.get());
    logs.pushLog("info", "agents", "Added a scheduled agent task", false);
    state.wakeUi();
    return .{ .added = id };
}

fn findId(name: []const u8) ?i64 {
    const stmt = db.prepare("SELECT id FROM agent_tasks WHERE name=?1") orelse return null;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, name);
    if (db.step(stmt) == db.c.SQLITE_ROW) return db.columnInt64(stmt, 0);
    return null;
}

fn countTasks() usize {
    const stmt = db.prepare("SELECT COUNT(*) FROM agent_tasks") orelse return 0;
    defer db.finalize(stmt);
    if (db.step(stmt) == db.c.SQLITE_ROW) return @intCast(@max(0, db.columnInt(stmt, 0)));
    return 0;
}

fn changed() bool {
    return db.c.sqlite3_changes(db.get()) > 0;
}

/// False when no such task exists.
pub fn remove(id: i64) bool {
    if (!ensureTable()) return false;
    const stmt = db.prepare("DELETE FROM agent_tasks WHERE id=?1") orelse return false;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, id);
    return db.step(stmt) == db.c.SQLITE_DONE and changed();
}

pub fn setEnabled(id: i64, on: bool) bool {
    if (!ensureTable()) return false;
    const stmt = db.prepare("UPDATE agent_tasks SET enabled=?1 WHERE id=?2") orelse return false;
    defer db.finalize(stmt);
    db.bindInt(stmt, 1, if (on) 1 else 0);
    db.bindInt64(stmt, 2, id);
    const ok = db.step(stmt) == db.c.SQLITE_DONE and changed();
    if (ok) state.wakeUi();
    return ok;
}

pub const RunNowResult = enum { queued, no_such_task, switch_off, capped, paused, unavailable };

/// Make the task due on the next tick. A manual run still counts against the
/// daily cap, so a script or agent cannot loop it into a bill.
pub fn runNow(id: i64) RunNowResult {
    if (!state.app.agent_tasks_enabled) return .switch_off;
    if (!ensureTable()) return .unavailable;
    const sched = loadSchedule(id) orelse return .no_such_task;
    const now = io_g.milliTimestamp();
    // A paused task stays paused: running it is not a way to re-enable it.
    if (!sched.enabled) return .paused;
    var probe = sched;
    probe.last_run_ms = 0;
    if (!pure.isDue(probe, now) or runsTodayAll(now) >= pure.GLOBAL_RUNS_PER_DAY) return .capped;
    const stmt = db.prepare("UPDATE agent_tasks SET last_run_ms=0 WHERE id=?1") orelse return .unavailable;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, id);
    if (db.step(stmt) != db.c.SQLITE_DONE) return .unavailable;
    last_tick_ms = 0;
    state.wakeUi();
    return .queued;
}

pub fn setMasterEnabled(on: bool) void {
    state.app.agent_tasks_enabled = on;
    last_tick_ms = 0;
    state.markConfigDirty();
}

/// Runs started today across every task, so many small caps cannot add up to an
/// unbounded bill (tasks can be re-created, each with a fresh per-task count).
fn runsTodayAll(now: i64) u32 {
    const stmt = db.prepare("SELECT COALESCE(SUM(runs_today),0) FROM agent_tasks WHERE day=?1") orelse return 0;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, pure.dayIndex(now));
    if (db.step(stmt) == db.c.SQLITE_ROW) return @intCast(@max(0, db.columnInt(stmt, 0)));
    return 0;
}

fn loadSchedule(id: i64) ?pure.Schedule {
    const stmt = db.prepare("SELECT enabled, interval_min, max_runs_per_day, last_run_ms, day, runs_today FROM agent_tasks WHERE id=?1") orelse return null;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, id);
    if (db.step(stmt) != db.c.SQLITE_ROW) return null;
    return readSchedule(stmt, 0);
}

fn readSchedule(stmt: ?*db.Stmt, first: c_int) pure.Schedule {
    return .{
        .enabled = db.columnInt(stmt, first) != 0,
        .interval_min = @intCast(@max(0, db.columnInt(stmt, first + 1))),
        .max_runs_per_day = @intCast(@max(0, db.columnInt(stmt, first + 2))),
        .last_run_ms = db.columnInt64(stmt, first + 3),
        .day = db.columnInt64(stmt, first + 4),
        .runs_today = @intCast(@max(0, db.columnInt(stmt, first + 5))),
    };
}

/// Write `{"enabled":bool,"running":id,"tasks":[...]}`.
pub fn writeListJson(w: *std.Io.Writer) !void {
    const now = io_g.milliTimestamp();
    var s = std.json.Stringify{ .writer = w };
    try s.beginObject();
    try s.objectField("enabled");
    try s.write(state.app.agent_tasks_enabled);
    try s.objectField("running");
    try s.write(running_id.load(.acquire));
    try s.objectField("tasks");
    try s.beginArray();
    if (ensureTable()) {
        const stmt = db.prepare(
            "SELECT id, name, prompt, agent, enabled, interval_min, max_runs_per_day, last_run_ms, day, runs_today, " ++
                "budget_cents, total_runs, last_outcome, last_summary FROM agent_tasks ORDER BY id",
        );
        if (stmt) |st| {
            defer db.finalize(st);
            while (db.step(st) == db.c.SQLITE_ROW) {
                const sched = readSchedule(st, 4);
                try s.beginObject();
                try s.objectField("id");
                try s.write(db.columnInt64(st, 0));
                try s.objectField("name");
                try s.write(db.columnText(st, 1) orelse "");
                try s.objectField("prompt");
                try s.write(db.columnText(st, 2) orelse "");
                try s.objectField("agent");
                try s.write(db.columnText(st, 3) orelse "claude");
                try s.objectField("enabled");
                try s.write(sched.enabled);
                try s.objectField("interval_min");
                try s.write(sched.interval_min);
                try s.objectField("max_runs_per_day");
                try s.write(sched.max_runs_per_day);
                try s.objectField("budget_cents");
                try s.write(db.columnInt(st, 10));
                try s.objectField("runs_today");
                try s.write(if (sched.day == pure.dayIndex(now)) sched.runs_today else 0);
                try s.objectField("total_runs");
                try s.write(db.columnInt(st, 11));
                try s.objectField("last_run_ms");
                try s.write(sched.last_run_ms);
                try s.objectField("next_run_ms");
                try s.write(if (state.app.agent_tasks_enabled) pure.nextRunMs(sched, now) else 0);
                try s.objectField("last_outcome");
                try s.write(db.columnText(st, 12) orelse "");
                try s.objectField("last_summary");
                try s.write(db.columnText(st, 13) orelse "");
                try s.endObject();
            }
        }
    }
    try s.endArray();
    try s.endObject();
}

// ── Scheduler ───────────────────────────────────────────────────────────

const Job = struct {
    id: i64 = 0,
    agent: Agent = .claude,
    budget_cents: u32 = 50,
    prompt: [pure.PROMPT_MAX]u8 = undefined,
    prompt_len: usize = 0,
};

/// Call from the shared frame/headless loop. Self-throttled and cheap when idle.
pub fn tick() void {
    if (!state.app.agent_tasks_enabled) return;
    const now = io_g.milliTimestamp();
    if (last_tick_ms != 0 and now - last_tick_ms < TICK_INTERVAL_MS) return;
    last_tick_ms = now;
    if (state.app.incognito_mode or busy.load(.acquire) or !ensureTable()) return;

    if (runsTodayAll(now) >= pure.GLOBAL_RUNS_PER_DAY) return;
    const job = nextDue(now) orelse return;
    if (busy.swap(true, .acq_rel)) return;
    const th = workers.spawnLegacy(runJob, .{job}) catch {
        busy.store(false, .release);
        return;
    };
    workers.release(th);
}

fn nextDue(now: i64) ?Job {
    const stmt = db.prepare(
        "SELECT enabled, interval_min, max_runs_per_day, last_run_ms, day, runs_today, id, agent, budget_cents, prompt " ++
            "FROM agent_tasks WHERE enabled=1 ORDER BY last_run_ms, id",
    ) orelse return null;
    defer db.finalize(stmt);
    while (db.step(stmt) == db.c.SQLITE_ROW) {
        if (!pure.isDue(readSchedule(stmt, 0), now)) continue;
        var job = Job{ .id = db.columnInt64(stmt, 6) };
        job.agent = Agent.parse(db.columnText(stmt, 7) orelse "") orelse continue;
        job.budget_cents = @intCast(@max(0, db.columnInt(stmt, 8)));
        const prompt = db.columnText(stmt, 9) orelse continue;
        if (prompt.len > job.prompt.len) continue;
        @memcpy(job.prompt[0..prompt.len], prompt);
        job.prompt_len = prompt.len;
        return job;
    }
    return null;
}

/// Count the run before it starts, so a crash or a failing agent still spends
/// the daily allowance instead of retrying every 30 seconds.
fn markStarted(id: i64, now: i64) void {
    const stmt = db.prepare(
        "UPDATE agent_tasks SET last_run_ms=?1, runs_today=CASE WHEN day=?2 THEN runs_today+1 ELSE 1 END, " ++
            "day=?2, total_runs=total_runs+1, last_outcome='running', last_summary='' WHERE id=?3",
    ) orelse return;
    defer db.finalize(stmt);
    db.bindInt64(stmt, 1, now);
    db.bindInt64(stmt, 2, pure.dayIndex(now));
    db.bindInt64(stmt, 3, id);
    _ = db.step(stmt);
}

fn markFinished(id: i64, outcome: pure.Outcome, summary: []const u8) void {
    const stmt = db.prepare("UPDATE agent_tasks SET last_outcome=?1, last_summary=?2 WHERE id=?3") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, outcome.id());
    db.bindText(stmt, 2, summary);
    db.bindInt64(stmt, 3, id);
    _ = db.step(stmt);
    state.wakeUi();
}

fn runJob(job: Job) void {
    defer busy.store(false, .release);
    running_id.store(job.id, .release);
    defer running_id.store(0, .release);

    markStarted(job.id, io_g.milliTimestamp());
    var summary: [SUMMARY_MAX]u8 = undefined;
    var n: usize = 0;
    const outcome = execute(&job, &summary, &n);
    markFinished(job.id, outcome, summary[0..n]);
    logs.pushLog(if (outcome == .ok) "info" else "warn", "agents", if (outcome == .ok) "A scheduled agent task finished" else "A scheduled agent task did not finish cleanly", false);
}

fn execute(job: *const Job, summary: *[SUMMARY_MAX]u8, summary_len: *usize) pure.Outcome {
    if (!launch.onPath(job.agent.binary())) {
        summary_len.* = copyInto(summary, "The agent is not installed (not on PATH).");
        return .not_installed;
    }
    var ws: launch.Workspace = .{};
    if (launch.prepareWorkspace(&ws) != .started) {
        summary_len.* = copyInto(summary, "Could not prepare the agent workspace.");
        return .failed;
    }

    // Unattended runs get a config that starts opal-mcp without the scheduling
    // tools, so a prompt-injected run cannot create, run or remove tasks.
    var cfg_buf: [700]u8 = undefined;
    const cfg_path = std.fmt.bufPrint(&cfg_buf, "{s}/.mcp-scheduled.json", .{ws.path()}) catch {
        summary_len.* = copyInto(summary, "Could not prepare the agent workspace.");
        return .failed;
    };
    var cfg_json: [900]u8 = undefined;
    const cfg_body = setup.jsonConfigWithArgs(&cfg_json, ws.mcpPath(), &.{ "--deny-prefix", "agent_task" }) orelse {
        summary_len.* = copyInto(summary, "Could not prepare the agent workspace.");
        return .failed;
    };
    io_g.cwdWriteFile(.{ .sub_path = cfg_path, .data = cfg_body }) catch {
        summary_len.* = copyInto(summary, "Could not prepare the agent workspace.");
        return .failed;
    };

    var built: pure.Argv = .{};
    const agent_argv = pure.buildArgv(&built, job.agent, job.prompt[0..job.prompt_len], ws.mcpPath(), ws.tokenFile(), cfg_path, job.budget_cents) orelse {
        summary_len.* = copyInto(summary, "The task could not be turned into a command.");
        return .failed;
    };

    // `sh -c 'exec "$@" 2>&1'` runs the agent with stderr merged into stdout so a
    // failure reason (not logged in, out of credit) reaches the summary. The
    // agent's argv rides in "$@", never through shell parsing.
    var argv: [24][]const u8 = undefined;
    const head = [_][]const u8{ "sh", "-c", "exec \"$@\" 2>&1", "sh" };
    @memcpy(argv[0..head.len], &head);
    @memcpy(argv[head.len .. head.len + agent_argv.len], agent_argv);
    const total = head.len + agent_argv.len;

    var process = bounded.StreamProcess.init(argv[0..total], .{
        .timeout_ms = pure.TIMEOUT_MS,
        .terminate_grace_ms = 2000,
        .max_output_bytes = 8 * 1024 * 1024,
        .cwd = ws.path(),
        .cancel_flag = workers.quittingSignal(),
    });
    process.start() catch {
        summary_len.* = copyInto(summary, "Could not start the agent.");
        return .failed;
    };

    // Keep only the last few KB of output; the closing line is the report.
    var window: [4096]u8 = undefined;
    var window_len: usize = 0;
    if (process.stdout()) |stdout| {
        var chunk: [1024]u8 = undefined;
        while (true) {
            const got = io_g.read(stdout, &chunk) catch {
                process.requestStop();
                break;
            };
            if (got == 0) break;
            if (window_len + got > window.len) {
                const drop = window_len + got - window.len;
                std.mem.copyForwards(u8, window[0 .. window_len - drop], window[drop..window_len]);
                window_len -= drop;
            }
            @memcpy(window[window_len .. window_len + got], chunk[0..got]);
            window_len += got;
            if (!process.noteOutput(got)) break;
        }
    }
    const result = process.finish();
    summary_len.* = copyInto(summary, pure.tail(window[0..window_len], SUMMARY_MAX));
    if (result.timed_out) return .timed_out;
    return if (result.ok()) .ok else .failed;
}

fn copyInto(dst: *[SUMMARY_MAX]u8, text: []const u8) usize {
    const n = @min(text.len, dst.len);
    @memcpy(dst[0..n], text[0..n]);
    return n;
}
