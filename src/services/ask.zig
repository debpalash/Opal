//! Ask Opal: the in-app assistant powered by the coding agent the user already has.
//!
//! When the user switched it on (Settings > Agent Access) and Claude Code or Codex
//! is installed, assistant-style omnibox inputs go here instead of the local model.
//! The agent runs headless in a scratch directory with Opal's own tools under the
//! restricted policy in `ask_pure.zig`, and answers with schema-validated JSON:
//! text, up to five proposed actions and some catalog cards. The agent never starts
//! a download or touches the wanted list; those come back as `actions`, which the UI
//! shows as buttons. `runAction` is what a click calls, so the click is the consent.
//!
//! Cost: each ask reserves its cap in the operator's job table up front (kind `ask`,
//! so the operator's daily limit counts it with no change to the operator) and is
//! settled to what the agent reported. The question and the answer are never stored
//! there, only the amount.

const std = @import("std");
const db = @import("../core/db.zig");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const io_g = @import("../core/io_global.zig");
const paths = @import("../core/paths.zig");
const sync = @import("../core/sync.zig");
const workers = @import("../core/workers.zig");
const bounded = @import("../core/bounded_process.zig");
const alloc = @import("../core/alloc.zig").allocator;
const launch = @import("agent_launch.zig");
const setup = @import("agent_setup_pure.zig");
const operator = @import("operator.zig");
const remote = @import("remote.zig");
const ai_chat = @import("ai_chat.zig");
const pure = @import("ask_pure.zig");

pub const Agent = pure.Agent;

pub const Status = enum { idle, working, done, failed, cancelled };
pub const ActionState = enum { ready, done, failed };

/// The latest ask. Read and written under `lock()`; the UI draws from it.
pub const Turn = struct {
    status: Status = .idle,
    agent: Agent = .claude,
    /// Increments per ask; a click carries the one it was drawn for.
    seq: u32 = 0,
    /// Index of the assistant message in the chat transcript.
    msg_index: usize = 0,
    started_ms: i64 = 0,
    answer: pure.Answer = .{},
    /// Why it failed, or what the agent said (already cleaned).
    note: pure.Text(280) = .{},
    cost_cents: u32 = 0,
    action_state: [pure.MAX_ACTIONS]ActionState = [_]ActionState{.ready} ** pure.MAX_ACTIONS,
};

var turn: Turn = .{};
var turn_mutex: sync.Mutex = .{};
var busy = std.atomic.Value(bool).init(false);
var cancel_gen = std.atomic.Value(u32).init(0);

pub fn lock() *Turn {
    turn_mutex.lock();
    return &turn;
}

pub fn unlock() void {
    turn_mutex.unlock();
}

pub fn isWorking() bool {
    return busy.load(.acquire);
}

/// Stop the run in progress. The agent process tree is terminated; what it may
/// have spent stays charged.
pub fn cancel() void {
    if (!busy.load(.acquire)) return;
    _ = cancel_gen.fetchAdd(1, .acq_rel);
    state.wakeUi();
}

// ── Entry ───────────────────────────────────────────────────────────────

pub fn installedAgent() ?Agent {
    return pure.pickAgent(launch.onPath("claude"), launch.onPath("codex"));
}

/// Which assistant answers this input right now.
pub fn currentRoute() pure.Route {
    return pure.route(state.app.ask_enabled, installedAgent());
}

fn agentTag(agent: Agent) u8 {
    return switch (agent) {
        .claude => 1,
        .codex => 2,
    };
}

/// Route an assistant-style input (`>` prefix, `?` suffix or the Ask button).
/// True when Ask Opal took it (including refusals it explained in the chat);
/// false when the caller should hand it to the local assistant. Never both.
pub fn tryRoute(input: []const u8) bool {
    if (currentRoute() != .ask) return false;
    const agent = installedAgent() orelse return false;
    var qbuf: [pure.QUESTION_MAX]u8 = undefined;
    const question = pure.cleanQuestion(&qbuf, input) orelse return true;
    start(agent, question);
    return true;
}

/// The Ask button: like `tryRoute`, but with the mode off it says how to turn it
/// on instead of falling back to the local model (the user pressed Ask).
pub fn askButton(input: []const u8) void {
    if (!state.app.ask_enabled) {
        state.showToast("Turn on Ask Opal in Settings > Agent Access");
        return;
    }
    if (installedAgent() == null) {
        state.showToast("Ask Opal needs Claude Code or Codex on your PATH");
        return;
    }
    _ = tryRoute(input);
}

fn pushMessages(question: []const u8, agent: Agent) ?usize {
    const chat = ai_chat;
    if (chat.message_count + 2 > chat.MAX_MESSAGES) {
        state.showToast("This chat is full: start a new chat");
        return null;
    }
    const u = &chat.messages[chat.message_count];
    u.* = .{ .role = .user };
    const n = @min(question.len, chat.MAX_MSG_LEN);
    @memcpy(u.text[0..n], question[0..n]);
    u.text_len = n;
    chat.message_count += 1;
    const idx = chat.message_count;
    chat.messages[idx] = .{ .role = .assistant, .text_len = 0, .via = agentTag(agent) };
    chat.message_count += 1;
    return idx;
}

/// Put `text` into the assistant message of the turn, if that message is still ours.
fn setMessageText(idx: usize, text: []const u8) void {
    if (idx >= ai_chat.message_count) return;
    const m = &ai_chat.messages[idx];
    if (m.via == 0) return; // the chat was cleared and the slot reused
    const n = @min(text.len, ai_chat.MAX_MSG_LEN);
    @memcpy(m.text[0..n], text[0..n]);
    m.text_len = n;
}

const Ctx = struct {
    question: [pure.QUESTION_MAX]u8,
    question_len: usize,
    agent: Agent,
    seq: u32,
    msg_index: usize,
    ledger_id: i64,
    port: u16,
    fast: bool,
    today: [16]u8,
    today_len: usize,
    epoch: u32,
};

fn refuse(agent: Agent, question: []const u8, why: []const u8) void {
    const idx = pushMessages(question, agent) orelse return;
    const t = lock();
    defer unlock();
    t.seq +%= 1;
    t.status = .failed;
    t.agent = agent;
    t.msg_index = idx;
    t.answer = .{};
    t.note.set(why);
    t.cost_cents = 0;
    setMessageText(idx, why);
    state.wakeUi();
}

fn start(agent: Agent, question: []const u8) void {
    if (busy.load(.acquire)) {
        state.showToast("Ask Opal is still working on the last question");
        return;
    }
    if (!remote.isRunning()) {
        refuse(agent, question, "Ask Opal controls the app through its local API. Turn on \"Allow coding agents\" in Settings > Agent Access (this computer only is fine), then ask again.");
        return;
    }
    const spent = operator.spentTodayCents();
    if (pure.gate(spent, state.app.operator_daily_cents) == .over_budget) {
        var a: [16]u8 = undefined;
        var b: [16]u8 = undefined;
        var msg: [200]u8 = undefined;
        const text = std.fmt.bufPrint(&msg, "Today's agent budget is used up ({s} of {s}, shared with the background operator). Raise the limit in the Agents page or try tomorrow.", .{ pure.costText(&a, spent), pure.costText(&b, state.app.operator_daily_cents) }) catch "Today's agent budget is used up.";
        refuse(agent, question, text);
        return;
    }
    const ledger_id = reserve(agent) orelse {
        refuse(agent, question, "Could not record the spend, so nothing was run.");
        return;
    };
    if (busy.swap(true, .acq_rel)) {
        settle(ledger_id, false, 0, "busy");
        return;
    }
    const idx = pushMessages(question, agent) orelse {
        settle(ledger_id, false, 0, "chat full");
        busy.store(false, .release);
        return;
    };

    var ctx = Ctx{
        .question = undefined,
        .question_len = question.len,
        .agent = agent,
        .seq = 0,
        .msg_index = idx,
        .ledger_id = ledger_id,
        .port = remote.port,
        .fast = state.app.ask_fast,
        .today = undefined,
        .today_len = 0,
        .epoch = cancel_gen.load(.acquire),
    };
    @memcpy(ctx.question[0..question.len], question);
    const today = pure.dateText(&ctx.today, io_g.milliTimestamp());
    ctx.today_len = today.len;

    {
        const t = lock();
        defer unlock();
        t.seq +%= 1;
        ctx.seq = t.seq;
        t.status = .working;
        t.agent = agent;
        t.msg_index = idx;
        t.started_ms = io_g.milliTimestamp();
        t.answer = .{};
        t.note = .{};
        t.cost_cents = 0;
        t.action_state = [_]ActionState{.ready} ** pure.MAX_ACTIONS;
    }
    state.wakeUi();

    const th = workers.spawnLegacy(run, .{ctx}) catch {
        finishTurn(&ctx, .failed, null, "Could not start the worker.", 0);
        busy.store(false, .release);
        return;
    };
    workers.release(th);
}

// ── Spend ledger (the operator's job table) ─────────────────────────────

fn day(ms: i64) i64 {
    return @divFloor(ms, 24 * 60 * 60 * 1000);
}

/// Reserve the whole cap against today's shared limit. Null when it cannot be recorded.
fn reserve(agent: Agent) ?i64 {
    if (operator.spentTodayCents() == 0 and db.get() == null) return null;
    const now = io_g.milliTimestamp();
    const stmt = db.prepare("INSERT INTO operator_jobs(kind,key,state,agent,cost_cents,created_ms,day) VALUES('ask','ask','running',?1,?2,?3,?4)") orelse return null;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, agent.binary());
    db.bindInt(stmt, 2, @intCast(pure.BUDGET_CENTS));
    db.bindInt64(stmt, 3, now);
    db.bindInt64(stmt, 4, day(now));
    if (db.step(stmt) != db.c.SQLITE_DONE) return null;
    return db.c.sqlite3_last_insert_rowid(db.get());
}

/// Replace the reservation with what the run cost. Only the amount and a short
/// outcome word are stored, never the question or the answer.
fn settle(id: i64, ok: bool, cents: u32, summary: []const u8) void {
    const stmt = db.prepare("UPDATE operator_jobs SET state=?1, summary=?2, cost_cents=?3, finished_ms=?4 WHERE id=?5") orelse return;
    defer db.finalize(stmt);
    db.bindText(stmt, 1, if (ok) "applied" else "failed");
    db.bindText(stmt, 2, summary);
    db.bindInt(stmt, 3, @intCast(cents));
    db.bindInt64(stmt, 4, io_g.milliTimestamp());
    db.bindInt64(stmt, 5, id);
    _ = db.step(stmt);
}

// ── opal-mcp capabilities ───────────────────────────────────────────────

var preset_checked = std.atomic.Value(bool).init(false);
var preset_ok = std.atomic.Value(bool).init(false);

/// Does this `opal-mcp` know `--preset`? Older builds exit on an unknown flag, which
/// would leave the agent with no tools, so the flag is only passed when `--help`
/// mentions it. Asked once per run of the app.
fn presetSupported(mcp_bin: []const u8) bool {
    if (preset_checked.load(.acquire)) return preset_ok.load(.acquire);
    var out: [4096]u8 = undefined;
    const argv = [_][]const u8{ "sh", "-c", "exec \"$0\" --help 2>&1", mcp_bin };
    const result = bounded.run(&argv, &out, .{ .timeout_ms = 3000 });
    const text = result.output;
    preset_ok.store(std.mem.indexOf(u8, text, "--preset") != null, .release);
    preset_checked.store(true, .release);
    return preset_ok.load(.acquire);
}

// ── The run ─────────────────────────────────────────────────────────────

fn finishTurn(ctx: *const Ctx, status: Status, answer: ?*const pure.Answer, note: []const u8, cost_cents: u32) void {
    {
        const t = lock();
        defer unlock();
        if (t.seq == ctx.seq) {
            t.status = status;
            t.cost_cents = cost_cents;
            t.note.set(note);
            if (answer) |a| t.answer = a.* else t.answer = .{};
        }
    }
    // The transcript keeps the text, so history reads naturally after the buttons are gone.
    if (answer) |a| {
        setMessageText(ctx.msg_index, a.text.slice());
    } else {
        setMessageText(ctx.msg_index, note);
    }
    state.wakeUi();
}

const FailKind = enum { not_installed, no_mcp, setup, spawn, agent, timeout, cancelled };

fn failText(kind: FailKind) []const u8 {
    return switch (kind) {
        .not_installed => "The coding agent is not installed (not on PATH).",
        .no_mcp => "opal-mcp was not found next to Opal, so the agent cannot reach the app's tools.",
        .setup => "Could not prepare the scratch folder for the agent.",
        .spawn => "Could not start the agent.",
        .agent => "The agent did not finish (not signed in, out of credit, or an error).",
        .timeout => "The agent took too long (3 minutes) and was stopped.",
        .cancelled => "Cancelled.",
    };
}

fn run(ctx: Ctx) void {
    defer busy.store(false, .release);
    const question = ctx.question[0..ctx.question_len];
    const today = ctx.today[0..ctx.today_len];

    const fail = struct {
        fn go(c: *const Ctx, kind: FailKind, cents: u32) void {
            settle(c.ledger_id, false, cents, @tagName(kind));
            finishTurn(c, if (kind == .cancelled) .cancelled else .failed, null, failText(kind), cents);
            logs.pushLog("warn", "ask", "An Ask Opal request did not finish", false);
        }
    }.go;

    if (!launch.onPath(ctx.agent.binary())) return fail(&ctx, .not_installed, 0);

    // Scratch directory: the agent runs here, never in the user's data.
    var cfg_buf: [512]u8 = undefined;
    const cfg = paths.configDir(&cfg_buf);
    var dir_buf: [600]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buf, "{s}/ask", .{cfg}) catch return fail(&ctx, .setup, 0);
    io_g.cwdMakePath(dir) catch return fail(&ctx, .setup, 0);

    var exe_buf: [512]u8 = undefined;
    const exe_dir = io_g.selfExeDirPath(&exe_buf) catch return fail(&ctx, .no_mcp, 0);
    var mcp_buf: [600]u8 = undefined;
    const mcp_bin = setup.mcpBinaryPath(&mcp_buf, exe_dir, @import("builtin").os.tag == .windows) orelse return fail(&ctx, .no_mcp, 0);
    io_g.cwdAccess(mcp_bin, .{}) catch return fail(&ctx, .no_mcp, 0);

    var token_buf: [600]u8 = undefined;
    const token_file = std.fmt.bufPrint(&token_buf, "{s}/api.token", .{cfg}) catch return fail(&ctx, .setup, 0);
    var cfg_path_buf: [700]u8 = undefined;
    const mcp_config = std.fmt.bufPrint(&cfg_path_buf, "{s}/mcp.json", .{dir}) catch return fail(&ctx, .setup, 0);
    var schema_path_buf: [700]u8 = undefined;
    const schema_file = std.fmt.bufPrint(&schema_path_buf, "{s}/schema.json", .{dir}) catch return fail(&ctx, .setup, 0);
    var out_path_buf: [700]u8 = undefined;
    const out_file = std.fmt.bufPrint(&out_path_buf, "{s}/out-{d}.txt", .{ dir, ctx.seq }) catch return fail(&ctx, .setup, 0);

    switch (ctx.agent) {
        .claude => {
            var json_buf: [4096]u8 = undefined;
            const body = pure.mcpConfigJson(&json_buf, mcp_bin, ctx.port, token_file, presetSupported(mcp_bin)) orelse return fail(&ctx, .setup, 0);
            io_g.cwdWriteFile(.{ .sub_path = mcp_config, .data = body }) catch return fail(&ctx, .setup, 0);
        },
        .codex => io_g.cwdWriteFile(.{ .sub_path = schema_file, .data = pure.schema }) catch return fail(&ctx, .setup, 0),
    }
    defer if (ctx.agent == .codex) {
        io_g.cwdDeleteFile(out_file) catch {};
    };

    var argv: pure.Argv = .{};
    const cmd = pure.buildArgv(&argv, ctx.agent, question, today, .{
        .mcp_bin = mcp_bin,
        .mcp_config = mcp_config,
        .token_file = token_file,
        .schema_file = schema_file,
        .out_file = out_file,
        .preset = presetSupported(mcp_bin),
        .fast = ctx.fast,
    }, ctx.port) orelse return fail(&ctx, .setup, 0);

    const output = alloc.alloc(u8, 512 * 1024) catch return fail(&ctx, .setup, 0);
    defer alloc.free(output);
    var got: usize = 0;
    // The argv goes straight to the program: no shell, the question is one element.
    var process = bounded.StreamProcess.init(cmd, .{
        .timeout_ms = pure.TIMEOUT_MS,
        .terminate_grace_ms = 2000,
        .max_output_bytes = output.len,
        .cwd = dir,
        .cancel_epoch = .{ .epoch32 = .{ .value = &cancel_gen, .expected = ctx.epoch } },
        .cancel_flag = workers.quittingSignal(),
    });
    process.start() catch return fail(&ctx, .spawn, 0);
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
    // A stopped run may still have spent money: charge the whole cap.
    if (result.cancelled) return fail(&ctx, .cancelled, pure.BUDGET_CENTS);
    if (result.timed_out) return fail(&ctx, .timeout, pure.BUDGET_CENTS);

    var answer: pure.Answer = .{};
    var parsed: pure.Parsed = .{};
    switch (ctx.agent) {
        .claude => parsed = pure.parseClaude(alloc, output[0..got], &answer),
        .codex => {
            var file_buf: [64 * 1024]u8 = undefined;
            var len: usize = 0;
            if (io_g.cwdOpenFile(out_file, .{})) |f| {
                defer f.close(io_g.io());
                len = io_g.readAll(f, &file_buf) catch 0;
            } else |_| {}
            parsed = pure.parseCodex(alloc, file_buf[0..len], &answer);
        },
    }
    const cost = pure.chargeCents(ctx.agent, parsed.cost_cents, parsed.cost_known);

    // The agent reports errors in the envelope with a non-zero exit; say what it said.
    if (parsed.problem != .none) {
        var msg: [320]u8 = undefined;
        const text = if (parsed.problem == .agent_error and parsed.note.len > 0)
            std.fmt.bufPrint(&msg, "{s} It said: {s}", .{ parsed.problem.message(), parsed.note.slice() }) catch parsed.problem.message()
        else if (!result.ok() and parsed.problem == .malformed)
            failText(.agent)
        else
            parsed.problem.message();
        settle(ctx.ledger_id, false, cost, @tagName(parsed.problem));
        finishTurn(&ctx, .failed, null, text, cost);
        logs.pushLog("warn", "ask", "An Ask Opal answer was discarded", false);
        return;
    }
    var usage_buf: [160]u8 = undefined;
    const usage = pure.usageText(&usage_buf, &parsed);
    settle(ctx.ledger_id, true, cost, if (answer.plain) "answered (text only)" else usage);
    logs.pushLog("info", "ask", usage, false);
    finishTurn(&ctx, .done, &answer, "", cost);
    logs.pushLog("info", "ask", "Ask Opal answered", false);
}

// ── Clicks on actions ───────────────────────────────────────────────────

pub const ClickResult = enum { done, failed, stale };

fn setActionState(seq: u32, idx: usize, st: ActionState) void {
    const t = lock();
    defer unlock();
    if (t.seq == seq and idx < pure.MAX_ACTIONS) t.action_state[idx] = st;
}

/// Run action `idx` of the turn `seq`. Called from the UI thread on a click and
/// nowhere else: the click is the user's consent for a spend action. The stored
/// action is validated once more first.
pub fn runAction(seq: u32, idx: usize) ClickResult {
    var act: pure.Action = undefined;
    {
        const t = lock();
        defer unlock();
        if (t.seq != seq or t.status != .done or idx >= t.answer.action_count) return .stale;
        if (t.action_state[idx] == .done) return .stale;
        act = t.answer.actions[idx];
    }
    if (!pure.stillValid(&act)) {
        setActionState(seq, idx, .failed);
        state.showToast("Opal will not run that action");
        return .failed;
    }
    const result = execute(&act);
    setActionState(seq, idx, if (result == .done) .done else .failed);
    return result;
}

fn execute(act: *const pure.Action) ClickResult {
    switch (act.kind) {
        .play, .queue => {
            // The app's own search resolves it; the user picks the result.
            const search = @import("search.zig");
            search.submitQuery(act.text.slice());
            state.app.router.navigate(.search);
            state.showToast(if (act.kind == .play) "Searching: pick a result to play" else "Searching: pick a result to queue");
            return .done;
        },
        .open => {
            @import("browser.zig").loadContent(act.url.slice());
            return .done;
        },
        .wanted_add => {
            const wanted = @import("wanted.zig");
            const req = wanted.AddRequest{
                .kind = if (act.season != 0) .episode else .movie,
                .title = act.text.slice(),
                .year = act.year,
                .season = act.season,
                .episode = act.episode,
            };
            switch (wanted.add(req)) {
                .added => {
                    state.showToast("Added to Wanted");
                    return .done;
                },
                .exists => {
                    state.showToast("Already on your Wanted list");
                    return .done;
                },
                .full => {
                    state.showToast("Your Wanted list is full");
                    return .failed;
                },
                .invalid, .unavailable => {
                    state.showToast("Could not add it to Wanted");
                    return .failed;
                },
            }
        },
        .download => {
            const url = act.url.slice();
            if (std.ascii.startsWithIgnoreCase(url, "magnet:")) {
                // The same entry a pasted magnet takes: the torrent engine.
                @import("browser.zig").loadContent(url);
                state.showToast("Starting the torrent");
                return .done;
            }
            if (@import("downloads.zig").startUrl(url)) {
                state.showToast("Download started");
                return .done;
            }
            state.showToast("Could not start that download");
            return .failed;
        },
    }
}

// ── Test hooks (never reachable from the app) ───────────────────────────

/// Native tests put a finished turn on screen without running an agent.
pub fn setTurnForTest(status: Status, agent: Agent, answer: ?*const pure.Answer, note: []const u8, cost_cents: u32) void {
    const idx = pushMessages("Test question", agent) orelse return;
    const t = lock();
    defer unlock();
    t.seq +%= 1;
    t.status = status;
    t.agent = agent;
    t.msg_index = idx;
    t.started_ms = io_g.milliTimestamp();
    t.answer = if (answer) |a| a.* else .{};
    t.note.set(note);
    t.cost_cents = cost_cents;
    t.action_state = [_]ActionState{.ready} ** pure.MAX_ACTIONS;
    if (answer) |a| setMessageText(idx, a.text.slice()) else setMessageText(idx, note);
}
