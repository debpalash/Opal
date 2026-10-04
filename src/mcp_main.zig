//! `opal-mcp`: a Model Context Protocol server (stdio) for a running Opal.
//!
//! Coding agents (Claude Code, Codex, Gemini CLI, ...) launch this binary and
//! talk newline-delimited JSON-RPC over stdin/stdout. Every call is validated
//! and policed by `services/ops_pure.zig`, then forwarded to the Opal HTTP API
//! on loopback with the machine bearer token. It deliberately links nothing but
//! std: no GUI, no libmpv, no libtorrent — it can never become a second player.
//!
//! stdout carries protocol messages only; diagnostics go to stderr.
//!
//!   opal-mcp [--allow TIER] [--read-only] [--deny-prefix NAME] [--port N]
//!
//! TIER is one of read, playback, write, spend (default), destructive. Naming
//! `destructive` still requires each call to pass `confirm: true`. `--deny-prefix`
//! hides every tool whose name starts with NAME and refuses calls to it.
//! Environment: OPAL_API_TOKEN, OPAL_API_TOKEN_FILE, OPAL_PORT, OPAL_MCP_AUDIT=0.

const std = @import("std");
const builtin = @import("builtin");
const ops = @import("services/ops_pure.zig");

const version = "2.0.0-dev";

const Bridge = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    client: std.http.Client,
    base: []const u8,
    auth: []const u8,
    audit_path: ?[]const u8,

    fn call(ctx: *anyopaque, a: std.mem.Allocator, method: ops.Method, target: []const u8) anyerror!ops.Response {
        const self: *Bridge = @ptrCast(@alignCast(ctx));
        const url = try std.fmt.allocPrint(a, "{s}{s}", .{ self.base, target });
        defer a.free(url);
        var body: std.Io.Writer.Allocating = .init(a);
        errdefer body.deinit();
        const result = try self.client.fetch(.{
            .location = .{ .url = url },
            .method = switch (method) {
                .GET => .GET,
                .POST => .POST,
            },
            // The API reads its arguments from the query string; a bodiless POST
            // still needs an explicit empty payload so a length is sent.
            .payload = if (method == .POST) "" else null,
            // Opal's API server answers one request per connection; pooling would
            // reuse a socket it has already closed and fail every second call.
            .keep_alive = false,
            .headers = .{ .authorization = .{ .override = self.auth } },
            .response_writer = &body.writer,
        });
        return .{ .status = @intFromEnum(result.status), .body = try body.toOwnedSlice() };
    }

    fn record(ctx: *anyopaque, entry: ops.AuditEntry) void {
        const self: *Bridge = @ptrCast(@alignCast(ctx));
        const path = self.audit_path orelse return;
        var line: [2048]u8 = undefined;
        var w = std.Io.Writer.fixed(&line);
        const now = std.Io.Clock.real.now(self.io).toMilliseconds();
        ops.writeAuditLine(&w, now, entry) catch return;
        const file = std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = false }) catch return;
        defer file.close(self.io);
        const end = file.length(self.io) catch return;
        file.writePositionalAll(self.io, w.buffered(), end) catch return;
    }
};

fn tierFromName(name: []const u8) ?ops.Tier {
    return std.meta.stringToEnum(ops.Tier, name);
}

fn configDir(a: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (builtin.os.tag == .windows) {
        const base = env.get("APPDATA") orelse return error.NoConfigDir;
        return std.fmt.allocPrint(a, "{s}/opal", .{base});
    }
    if (env.get("XDG_CONFIG_HOME")) |xdg| return std.fmt.allocPrint(a, "{s}/opal", .{xdg});
    const home = env.get("HOME") orelse return error.NoConfigDir;
    return std.fmt.allocPrint(a, "{s}/.config/opal", .{home});
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("opal-mcp: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;

    var policy = ops.Policy{};
    var port: u16 = 41595;
    if (env.get("OPAL_PORT")) |p| port = std.fmt.parseInt(u16, p, 10) catch fail("OPAL_PORT is not a port number", .{});

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--allow")) {
            const v = args.next() orelse fail("--allow needs a tier", .{});
            if (std.mem.eql(u8, v, "destructive")) {
                policy.max_tier = .spend;
                policy.allow_destructive = true;
            } else policy.max_tier = tierFromName(v) orelse fail("unknown tier '{s}'", .{v});
        } else if (std.mem.eql(u8, arg, "--read-only")) {
            policy.max_tier = .read;
        } else if (std.mem.eql(u8, arg, "--deny-prefix")) {
            const v = args.next() orelse fail("--deny-prefix needs a tool name prefix", .{});
            if (!ops.validDenyPrefix(v)) fail("bad --deny-prefix '{s}': use 1-64 characters of a-z, 0-9 and _", .{v});
            policy.deny_prefix = try gpa.dupe(u8, v);
        } else if (std.mem.eql(u8, arg, "--port")) {
            const v = args.next() orelse fail("--port needs a number", .{});
            port = std.fmt.parseInt(u16, v, 10) catch fail("bad port '{s}'", .{v});
        } else if (std.mem.eql(u8, arg, "--openapi")) {
            // Print the OpenAPI document for the agent API. Needs no running Opal.
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            @import("services/openapi_pure.zig").write(gpa, &out.writer) catch |err| fail("could not build the OpenAPI document: {s}", .{@errorName(err)});
            var stdout_buf: [4096]u8 = undefined;
            var stdout = std.Io.File.stdout().writer(init.io, &stdout_buf);
            stdout.interface.writeAll(out.written()) catch {};
            stdout.interface.flush() catch {};
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("opal-mcp {s}\n", .{version});
            return;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                "opal-mcp {s}: MCP server for a running Opal\n\n" ++
                    "  --allow TIER   highest tier to run: read, playback, write, spend (default), destructive\n" ++
                    "  --read-only    same as --allow read\n" ++
                    "  --deny-prefix NAME  hide and refuse every tool whose name starts with NAME (e.g. agent_task)\n" ++
                    "  --port N       Opal API port (default 41595, or OPAL_PORT)\n" ++
                    "  --openapi      print the OpenAPI description of the agent API and exit\n\n" ++
                    "Token: OPAL_API_TOKEN, else OPAL_API_TOKEN_FILE, else <config>/opal/api.token.\n" ++
                    "Audit log: <config>/opal/mcp-audit.jsonl (disable with OPAL_MCP_AUDIT=0).\n",
                .{version},
            );
            return;
        } else fail("unknown argument '{s}' (try --help)", .{arg});
    }

    const cfg = configDir(gpa, env) catch fail("cannot locate the config directory; set OPAL_API_TOKEN", .{});
    defer gpa.free(cfg);

    // The token is looked up on every start, not cached across restarts: Opal
    // can rotate it, and a stale credential must fail loudly, not silently.
    var token_owned: ?[]u8 = null;
    defer if (token_owned) |t| gpa.free(t);
    const token: []const u8 = blk: {
        if (env.get("OPAL_API_TOKEN")) |t| break :blk std.mem.trim(u8, t, " \t\r\n");
        const path = if (env.get("OPAL_API_TOKEN_FILE")) |f| try gpa.dupe(u8, f) else try std.fmt.allocPrint(gpa, "{s}/api.token", .{cfg});
        defer gpa.free(path);
        const raw = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256)) catch
            fail("cannot read the API token at {s}. Start Opal once so it creates it, or set OPAL_API_TOKEN.", .{path});
        token_owned = raw;
        break :blk std.mem.trim(u8, raw, " \t\r\n");
    };
    if (token.len == 0) fail("the API token is empty", .{});

    const auth = try std.fmt.allocPrint(gpa, "Bearer {s}", .{token});
    defer gpa.free(auth);
    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{port});
    defer gpa.free(base);
    const audit_on = if (env.get("OPAL_MCP_AUDIT")) |v| !std.mem.eql(u8, v, "0") else true;
    const audit_path: ?[]u8 = if (audit_on) try std.fmt.allocPrint(gpa, "{s}/mcp-audit.jsonl", .{cfg}) else null;
    defer if (audit_path) |p| gpa.free(p);
    if (audit_path != null) std.Io.Dir.cwd().createDirPath(io, cfg) catch {};

    var bridge = Bridge{
        .io = io,
        .gpa = gpa,
        .client = .{ .allocator = gpa, .io = io },
        .base = base,
        .auth = auth,
        .audit_path = audit_path,
    };
    defer bridge.client.deinit();

    var server = ops.Server{
        .policy = policy,
        .caller = .{ .ctx = &bridge, .call = Bridge.call },
        .audit = .{ .ctx = &bridge, .record = Bridge.record },
        .version = version,
    };

    var in_buf: [256 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &in_buf);
    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);

    while (true) {
        const line = stdin.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                try stdout.interface.writeAll("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"message too large\"}}\n");
                try stdout.interface.flush();
                return;
            },
            error.ReadFailed => return,
        } orelse return;

        var reply: std.Io.Writer.Allocating = .init(gpa);
        defer reply.deinit();
        server.handleLine(gpa, line, &reply.writer) catch |err| {
            std.debug.print("opal-mcp: internal error: {s}\n", .{@errorName(err)});
            continue;
        };
        if (reply.written().len == 0) continue;
        try stdout.interface.writeAll(reply.written());
        try stdout.interface.flush();
    }
}
