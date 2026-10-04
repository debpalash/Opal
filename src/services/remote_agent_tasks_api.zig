//! Scheduled agent task routes: prompts a coding agent runs on a timer.
//!
//!   GET  /agent/tasks                           the tasks, the master switch and what is running
//!   POST /agent/tasks/add?name=&prompt=&agent=claude|codex&interval_min=&max_runs_per_day=&budget_cents=
//!   POST /agent/tasks/remove?id=
//!   POST /agent/tasks/run?id=                   run on the next tick (counts toward the daily cap)
//!
//! The master switch is deliberately NOT exposed here: only the user, in
//! Settings, can allow unattended agent runs. Neither is there a route to enable
//! or resume a task: the token any agent with a shell can read would let it
//! switch on what it just added; enabling happens in the desktop UI. Parameters may come in the query
//! or a form body, so a long prompt is not limited by the request line.

const std = @import("std");
const wire = @import("remote_http.zig");
const tasks = @import("agent_tasks.zig");
const pure = @import("agent_tasks_pure.zig");
const alloc = @import("../core/alloc.zig").allocator;

pub fn handle(stream: std.Io.net.Stream, method: []const u8, path: []const u8, query: []const u8, body: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "/agent/tasks")) return false;
    if (std.mem.eql(u8, path, "/agent/tasks")) {
        if (wire.requireMethod(stream, method, "GET")) list(stream);
        return true;
    }
    if (std.mem.eql(u8, path, "/agent/tasks/add")) {
        if (wire.requireMethod(stream, method, "POST")) add(stream, query, body);
        return true;
    }
    inline for (.{ "remove", "run" }) |verb| {
        if (std.mem.eql(u8, path, "/agent/tasks/" ++ verb)) {
            if (wire.requireMethod(stream, method, "POST")) byId(stream, query, body, verb);
            return true;
        }
    }
    return false;
}

fn list(stream: std.Io.net.Stream) void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    tasks.writeListJson(&out.writer) catch {
        wire.sendJsonStatus(stream, "503 Service Unavailable", "{\"error\":\"agent tasks unavailable\"}");
        return;
    };
    wire.sendJson(stream, out.written());
}

fn bad(stream: std.Io.net.Stream, why: []const u8) void {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.writeAll("{\"error\":") catch {};
    var s = std.json.Stringify{ .writer = &w };
    s.write(why) catch {};
    w.writeAll("}") catch {};
    wire.sendJsonStatus(stream, "400 Bad Request", w.buffered());
}

fn uintParam(body: []const u8, query: []const u8, key: []const u8, default: u32) ?u32 {
    var buf: [16]u8 = undefined;
    const raw = wire.formParam(body, query, key, &buf) orelse return default;
    return std.fmt.parseInt(u32, raw, 10) catch null;
}

fn add(stream: std.Io.net.Stream, query: []const u8, body: []const u8) void {
    var name_buf: [128]u8 = undefined;
    const name = wire.formParam(body, query, "name", &name_buf) orelse "";
    var prompt_buf: [pure.PROMPT_MAX + 1]u8 = undefined;
    const prompt = wire.formParam(body, query, "prompt", &prompt_buf) orelse "";
    var agent_buf: [16]u8 = undefined;
    const agent_raw = wire.formParam(body, query, "agent", &agent_buf) orelse "claude";
    const agent = pure.Agent.parse(agent_raw) orelse return bad(stream, "agent must be claude or codex");

    const req = tasks.AddRequest{
        .name = name,
        .prompt = prompt,
        .agent = agent,
        .interval_min = uintParam(body, query, "interval_min", 1440) orelse return bad(stream, "invalid interval_min"),
        .max_runs_per_day = uintParam(body, query, "max_runs_per_day", 2) orelse return bad(stream, "invalid max_runs_per_day"),
        .budget_cents = uintParam(body, query, "budget_cents", 50) orelse return bad(stream, "invalid budget_cents"),
        // Over HTTP a task starts paused; the user enables it in the Agents page.
        .enabled = false,
    };
    var buf: [192]u8 = undefined;
    switch (tasks.add(req)) {
        .added => |id| wire.sendJson(stream, std.fmt.bufPrint(&buf, "{{\"ok\":true,\"id\":{d},\"paused\":true,\"next\":\"Ask the user to review and enable it in the Agents page (Tasks).\"}}", .{id}) catch "{\"ok\":true}"),
        .exists => |id| wire.sendJsonStatus(stream, "409 Conflict", std.fmt.bufPrint(&buf, "{{\"error\":\"a task with that name exists\",\"id\":{d}}}", .{id}) catch "{\"error\":\"exists\"}"),
        .invalid => |why| bad(stream, why),
        .full => wire.sendJsonStatus(stream, "409 Conflict", "{\"error\":\"too many tasks\"}"),
        .unavailable => wire.sendJsonStatus(stream, "503 Service Unavailable", "{\"error\":\"database not ready\"}"),
    }
}

fn byId(stream: std.Io.net.Stream, query: []const u8, body: []const u8, comptime verb: []const u8) void {
    var id_buf: [24]u8 = undefined;
    const id = std.fmt.parseInt(i64, wire.formParam(body, query, "id", &id_buf) orelse "", 10) catch {
        wire.sendJsonStatus(stream, "400 Bad Request", "{\"error\":\"id required\"}");
        return;
    };
    if (comptime std.mem.eql(u8, verb, "run")) {
        switch (tasks.runNow(id)) {
            .queued => wire.sendJson(stream, "{\"ok\":true}"),
            .no_such_task => wire.sendJsonStatus(stream, "404 Not Found", "{\"error\":\"no such task\"}"),
            .switch_off => wire.sendJsonStatus(stream, "409 Conflict", "{\"error\":\"scheduled agent tasks are switched off; the user enables them in Settings > Agent Access\"}"),
            .capped => wire.sendJsonStatus(stream, "429 Too Many Requests", "{\"error\":\"the task reached its daily run cap\"}"),
            .paused => wire.sendJsonStatus(stream, "409 Conflict", "{\"error\":\"the task is paused; the user enables it in the Agents page\"}"),
            .unavailable => wire.sendJsonStatus(stream, "503 Service Unavailable", "{\"error\":\"database not ready\"}"),
        }
        return;
    }
    // Only `remove` is left here.
    if (tasks.remove(id)) {
        wire.sendJson(stream, "{\"ok\":true}");
    } else {
        wire.sendJsonStatus(stream, "404 Not Found", "{\"error\":\"no such task\"}");
    }
}
