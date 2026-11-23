//! Plugin permission policy: the manifest `require` allow-list, the one-time
//! user grant that unlocks it, and the Lua prelude that enforces it.
//!
//! A plugin "needs permission" when its manifest declares `require` modules or
//! `allow_unsafe = true`. Such a plugin stays disabled until the user grants the
//! exact permission set once; the grant is bound to the plugin id and the
//! canonical permission list, so an update that asks for more invalidates it.
//! Content approval (plugins_trust.zig) is a separate, earlier gate.

const std = @import("std");

pub const MAX_REQUIRES: usize = 16;
pub const MAX_MODULE_LEN: usize = 48;

/// Library roots that can never be allow-listed: each one reaches the
/// registry, native loaders, the filesystem, or process control.
const RESERVED_ROOTS = [_][]const u8{ "debug", "package", "ffi", "jit", "io", "os", "_G" };

pub const Requires = struct {
    names: [MAX_REQUIRES][MAX_MODULE_LEN]u8 = @splat(@splat(0)),
    lens: [MAX_REQUIRES]u8 = @splat(0),
    count: usize = 0,

    pub fn name(self: *const Requires, i: usize) []const u8 {
        return self.names[i][0..self.lens[i]];
    }

    pub fn allows(self: *const Requires, module: []const u8) bool {
        for (0..self.count) |i| if (std.mem.eql(u8, self.name(i), module)) return true;
        return false;
    }

    fn insertSorted(self: *Requires, module: []const u8) void {
        var at: usize = 0;
        while (at < self.count) : (at += 1) {
            switch (std.mem.order(u8, self.name(at), module)) {
                .eq => return,
                .gt => break,
                .lt => {},
            }
        }
        var i = self.count;
        while (i > at) : (i -= 1) {
            self.names[i] = self.names[i - 1];
            self.lens[i] = self.lens[i - 1];
        }
        @memcpy(self.names[at][0..module.len], module);
        self.lens[at] = @intCast(module.len);
        self.count += 1;
    }
};

/// `name` or `dotted.name`: identifier segments only, so the Lua path template
/// can only resolve inside the plugin directory, and no reserved library root.
pub fn validModuleName(module: []const u8) bool {
    if (module.len == 0 or module.len > MAX_MODULE_LEN) return false;
    var it = std.mem.splitScalar(u8, module, '.');
    var first = true;
    while (it.next()) |seg| {
        if (seg.len == 0 or std.ascii.isDigit(seg[0])) return false;
        for (seg) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
        if (first) {
            for (RESERVED_ROOTS) |root| if (std.mem.eql(u8, seg, root)) return false;
            first = false;
        }
    }
    return true;
}

pub const ManifestError = error{ InvalidManifest, InvalidRequire, TooManyRequires };

/// Parse the top-level `require` array. Absent means none. Any malformed or
/// reserved entry rejects the whole manifest (fail closed, never truncate).
pub fn parseRequires(a: std.mem.Allocator, json: []const u8) (ManifestError || std.mem.Allocator.Error)!Requires {
    const parsed = std.json.parseFromSlice(std.json.Value, a, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidManifest,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidManifest;
    var out: Requires = .{};
    const value = parsed.value.object.get("require") orelse return out;
    if (value != .array) return error.InvalidRequire;
    for (value.array.items) |item| {
        if (item != .string or !validModuleName(item.string)) return error.InvalidRequire;
        if (out.allows(item.string)) continue;
        if (out.count >= MAX_REQUIRES) return error.TooManyRequires;
        out.insertSorted(item.string);
    }
    return out;
}

pub fn needsGrant(requires: *const Requires, allow_unsafe: bool) bool {
    return requires.count > 0 or allow_unsafe;
}

/// Whether the native Plugins view should show the one-time grant prompt
/// for a plugin: it asks for something and the user hasn't granted it yet.
pub fn showGrantPrompt(requires: *const Requires, allow_unsafe: bool, granted: bool) bool {
    return needsGrant(requires, allow_unsafe) and !granted;
}

/// Whether the plugin may run at all as far as permissions go.
pub fn permitted(requires: *const Requires, allow_unsafe: bool, granted: bool) bool {
    return !needsGrant(requires, allow_unsafe) or granted;
}

fn hashLength(hash: *std.crypto.hash.sha2.Sha256, n: usize) void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, n, .little);
    hash.update(&len);
}

/// Grant identity: plugin id + unsafe flag + sorted module list. Length-prefixed
/// so no two distinct permission sets share a digest.
pub fn grantDigest(plugin_id: []const u8, allow_unsafe: bool, requires: *const Requires, out: *[32]u8) void {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("opal-plugin-grant-v1\x00");
    hashLength(&hash, plugin_id.len);
    hash.update(plugin_id);
    hash.update(if (allow_unsafe) "\x01" else "\x00");
    hashLength(&hash, requires.count);
    for (0..requires.count) |i| {
        hashLength(&hash, requires.name(i).len);
        hash.update(requires.name(i));
    }
    hash.final(out);
}

/// Human-readable permission summary, e.g. `require json, util.http; full access`.
pub fn describe(requires: *const Requires, allow_unsafe: bool, out: []u8) []const u8 {
    var w = std.Io.Writer.fixed(out);
    if (requires.count > 0) {
        w.writeAll("require ") catch return w.buffered();
        for (0..requires.count) |i| {
            if (i > 0) w.writeAll(", ") catch return w.buffered();
            w.writeAll(requires.name(i)) catch return w.buffered();
        }
    }
    if (allow_unsafe) {
        if (requires.count > 0) w.writeAll("; ") catch return w.buffered();
        w.writeAll("full access (no Lua sandbox)") catch return w.buffered();
    }
    return w.buffered();
}

// ── Lua prelude ──
// Runs before every sandboxed Lua plugin. Dangerous globals go first; the real
// `require` is captured as an upvalue, its search path pinned to the plugin
// directory with native (C) loaders removed, then replaced by a gate that only
// admits allow-listed names. `debug` is gone, so the upvalue is unreachable.

pub const PRELUDE_HEAD: []const u8 =
    \\os.execute=nil os.remove=nil os.rename=nil os.exit=nil os.tmpname=nil os.getenv=nil
    \\io.popen=nil io.open=nil io.input=nil io.output=nil io.lines=nil
    \\
;

pub const PRELUDE_TAIL: []const u8 =
    \\local __req=require
    \\if package then
    \\  package.loadlib=nil package.cpath="" package.path=__dir.."/?.lua" package.preload={}
    \\  local s=package.searchers or package.loaders
    \\  if s then for i=#s,3,-1 do s[i]=nil end end
    \\end
    \\package=nil debug=nil
    \\dofile=nil loadfile=nil loadstring=nil load=nil
    \\require=function(m) if type(m)=="string" and __allow[m] then return __req(m) end error("require denied: "..tostring(m)) end
    \\
;

/// A directory that is safe to splice into a Lua long string and a
/// `package.path` template (`;` separates templates, `?` is substituted).
pub fn preludeSafeDir(dir: []const u8) bool {
    const posix_abs = dir.len > 0 and dir[0] == '/';
    const drive_abs = dir.len >= 3 and std.ascii.isAlphabetic(dir[0]) and dir[1] == ':' and (dir[2] == '\\' or dir[2] == '/');
    if (!posix_abs and !drive_abs) return false;
    for (dir) |ch| switch (ch) {
        ']', '[', ';', '?', '\n', '\r', 0 => return false,
        else => {},
    };
    return true;
}

/// Build the per-plugin prelude. Null (caller must refuse to run) when the
/// directory cannot be embedded safely or the buffer is too small.
pub fn buildPrelude(out: []u8, plugin_dir: []const u8, requires: *const Requires) ?[]const u8 {
    if (!preludeSafeDir(plugin_dir)) return null;
    var w = std.Io.Writer.fixed(out);
    w.writeAll(PRELUDE_HEAD) catch return null;
    w.print("local __dir=[==[{s}]==]\nlocal __allow={{", .{plugin_dir}) catch return null;
    for (0..requires.count) |i| {
        const module = requires.name(i);
        if (!validModuleName(module)) return null;
        w.print("[\"{s}\"]=true,", .{module}) catch return null;
    }
    w.writeAll("}\n") catch return null;
    w.writeAll(PRELUDE_TAIL) catch return null;
    return w.buffered();
}

// ── Tests ──

const ta = std.testing.allocator;

test "require allow-list: absent is empty, entries sorted and deduplicated" {
    const none = try parseRequires(ta, "{\"name\":\"x\"}");
    try std.testing.expectEqual(@as(usize, 0), none.count);
    const r = try parseRequires(ta, "{\"require\":[\"util.http\",\"json\",\"json\"]}");
    try std.testing.expectEqual(@as(usize, 2), r.count);
    try std.testing.expectEqualStrings("json", r.name(0));
    try std.testing.expectEqualStrings("util.http", r.name(1));
    try std.testing.expect(r.allows("json"));
    try std.testing.expect(!r.allows("socket"));
}

test "require allow-list: nested key is not an allow-list" {
    const r = try parseRequires(ta, "{\"meta\":{\"require\":[\"socket\"]}}");
    try std.testing.expectEqual(@as(usize, 0), r.count);
}

test "require allow-list rejects reserved roots, traversal and wrong types" {
    const bad = [_][]const u8{
        "{\"require\":[\"debug\"]}",
        "{\"require\":[\"jit.util\"]}",
        "{\"require\":[\"ffi\"]}",
        "{\"require\":[\"os\"]}",
        "{\"require\":[\"package\"]}",
        "{\"require\":[\"../evil\"]}",
        "{\"require\":[\"a..b\"]}",
        "{\"require\":[\"a/b\"]}",
        "{\"require\":[\"\"]}",
        "{\"require\":[1]}",
        "{\"require\":\"json\"}",
        "{\"require\":[\"x]==]os.execute\"]}",
    };
    for (bad) |json| try std.testing.expectError(error.InvalidRequire, parseRequires(ta, json));
    try std.testing.expectError(error.InvalidManifest, parseRequires(ta, "[]"));
    try std.testing.expectError(error.InvalidManifest, parseRequires(ta, "{"));
}

test "require allow-list caps entries instead of truncating" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.writeAll("{\"require\":[");
    for (0..MAX_REQUIRES + 1) |i| try w.print("{s}\"m{d}\"", .{ if (i > 0) "," else "", i });
    try w.writeAll("]}");
    try std.testing.expectError(error.TooManyRequires, parseRequires(ta, w.buffered()));
}

test "plugins needing permissions stay disabled until granted" {
    const none: Requires = .{};
    const some = try parseRequires(ta, "{\"require\":[\"json\"]}");
    try std.testing.expect(permitted(&none, false, false));
    try std.testing.expect(!permitted(&some, false, false));
    try std.testing.expect(permitted(&some, false, true));
    // allow_unsafe is a permission too: it needs the one-time consent.
    try std.testing.expect(!permitted(&none, true, false));
    try std.testing.expect(permitted(&none, true, true));
}

test "grant digest binds id, unsafe flag and the exact module set" {
    const a = try parseRequires(ta, "{\"require\":[\"json\"]}");
    const b = try parseRequires(ta, "{\"require\":[\"json\",\"socket\"]}");
    const a2 = try parseRequires(ta, "{\"require\":[\"json\",\"json\"]}");
    var base: [32]u8 = undefined;
    var other: [32]u8 = undefined;
    grantDigest("alpha", false, &a, &base);
    grantDigest("alpha", false, &a2, &other);
    try std.testing.expectEqualSlices(u8, &base, &other);
    grantDigest("alpha", false, &b, &other);
    try std.testing.expect(!std.mem.eql(u8, &base, &other));
    grantDigest("alpha", true, &a, &other);
    try std.testing.expect(!std.mem.eql(u8, &base, &other));
    grantDigest("beta", false, &a, &other);
    try std.testing.expect(!std.mem.eql(u8, &base, &other));
}

test "prelude embeds only the allow-list and the plugin directory" {
    const r = try parseRequires(ta, "{\"require\":[\"json\",\"lib.util\"]}");
    var buf: [4096]u8 = undefined;
    const p = buildPrelude(&buf, "/home/u/.config/opal/plugins/demo", &r).?;
    try std.testing.expect(std.mem.startsWith(u8, p, PRELUDE_HEAD));
    try std.testing.expect(std.mem.endsWith(u8, p, PRELUDE_TAIL));
    try std.testing.expect(std.mem.indexOf(u8, p, "local __dir=[==[/home/u/.config/opal/plugins/demo]==]\nlocal __allow={[\"json\"]=true,[\"lib.util\"]=true,}\n") != null);
    // Native loaders and the debug library never survive the prelude.
    try std.testing.expect(std.mem.indexOf(u8, p, "package.cpath=\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "for i=#s,3,-1 do s[i]=nil end") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "package=nil debug=nil") != null);
    const empty: Requires = .{};
    const deny_all = buildPrelude(&buf, "/p", &empty).?;
    try std.testing.expect(std.mem.indexOf(u8, deny_all, "local __allow={}\n") != null);
}

test "prelude refuses directories that could escape the Lua string or path template" {
    const empty: Requires = .{};
    var buf: [4096]u8 = undefined;
    for ([_][]const u8{ "", "relative/dir", "/a]==]os.execute('x')", "/a;/tmp", "/a?", "/a\nb" }) |dir|
        try std.testing.expect(buildPrelude(&buf, dir, &empty) == null);
    try std.testing.expect(buildPrelude(&buf, "C:\\Users\\u\\opal\\plugins\\demo", &empty) != null);
    var tiny: [16]u8 = undefined;
    try std.testing.expect(buildPrelude(&tiny, "/p", &empty) == null);
}

test "describe lists modules and full access" {
    const r = try parseRequires(ta, "{\"require\":[\"json\",\"a.b\"]}");
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("require a.b, json; full access (no Lua sandbox)", describe(&r, true, &buf));
    const empty: Requires = .{};
    try std.testing.expectEqualStrings("", describe(&empty, false, &buf));
}

test "grant prompt shows only for ungranted plugins that ask for something" {
    const none = Requires{};
    try std.testing.expect(!showGrantPrompt(&none, false, false));
    try std.testing.expect(showGrantPrompt(&none, true, false));
    try std.testing.expect(!showGrantPrompt(&none, true, true));
    const one = try parseRequires(std.testing.allocator, "{\"require\":[\"json\"]}");
    try std.testing.expect(showGrantPrompt(&one, false, false));
    try std.testing.expect(!showGrantPrompt(&one, false, true));
}
