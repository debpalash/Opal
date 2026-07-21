//! Mihon / Tachiyomi extension-repo support — PURE, unit-tested.
//!
//! Sits on top of the Suwayomi engine (manga_suwayomi_pure.zig): where that
//! module reads/searches through an already-installed source, THIS module owns
//! extension DISCOVERY + INSTALL — the pieces that let a user find and add
//! extensions from Opal instead of the Suwayomi WebUI.
//!
//! A Mihon extension repository publishes one catalog file, `index.min.json`, a
//! flat JSON array of extensions. Mihon/Suwayomi register the repo URL and then
//! install individual extensions from that catalog. See https://wotaku.wiki/ext/mihon.
//!
//! index.min.json element (verified against keiyoushi):
//!   { "name":"Tachiyomi: AHottie", "pkg":"eu.kanade.tachiyomi.extension.all.ahottie",
//!     "apk":"tachiyomi-all.ahottie-v1.4.3.apk", "lang":"all", "code":3,
//!     "version":"1.4.3", "nsfw":1,
//!     "sources":[{"name":"AHottie","lang":"all","id":"6289…","baseUrl":"https://ahottie.top"}] }
//!
//! Suwayomi extension REST endpoints this module builds URLs for:
//!   GET /api/v1/extension/list                — installed + available extensions
//!   GET /api/v1/extension/install/{pkgName}   — install by package name
//!   GET /api/v1/extension/uninstall/{pkgName}
//!   GET /api/v1/extension/update/{pkgName}
//!   GET /api/v1/extension/icon/{apkName}
//!
//! This module owns only URL building + JSON extraction (no fetch/state); the
//! shipped requests are the tested requests. Self-contained (its own tiny JSON
//! helpers + gates) so it has no import cycle with manga_suwayomi_pure, which
//! re-exports it as `suwayomi.repo`.

const std = @import("std");

// ── Curated repositories (from wotaku.wiki/ext/mihon) ──
// `kind` distinguishes manga (Mihon) from anime (Aniyomi) catalogs; both share
// the index.min.json shape. These are surfaced to the user to register on their
// Suwayomi server ("Extension repos").

pub const Repo = struct { name: []const u8, kind: []const u8, url: []const u8 };

pub const REPOS = [_]Repo{
    .{ .name = "Keiyoushi", .kind = "manga", .url = "https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.min.json" },
    .{ .name = "Yuzono (manga)", .kind = "manga", .url = "https://raw.githubusercontent.com/yuzono/manga-repo/repo/index.min.json" },
    .{ .name = "Suwayomi", .kind = "manga", .url = "https://raw.githubusercontent.com/Suwayomi/tachiyomi-extension/repo/index.min.json" },
    .{ .name = "Yuzono (anime)", .kind = "anime", .url = "https://raw.githubusercontent.com/yuzono/anime-repo/repo/index.min.json" },
    .{ .name = "Secozzi (anime)", .kind = "anime", .url = "https://raw.githubusercontent.com/Secozzi/aniyomi-extensions/refs/heads/repo/index.min.json" },
};

pub const INDEX_FILE = "index.min.json";

// ── Security gates ──
// pkg/apk names are interpolated straight into request paths, so they must be
// tightly constrained — anything with `/`, `?`, `..` or whitespace could escape
// the endpoint.

/// A Suwayomi/Mihon base origin we can prefix onto `/api/...`. Mirrors the gate
/// in manga_suwayomi_pure so the two engines agree on what a valid server is.
pub fn isValidBase(base: []const u8) bool {
    return (std.mem.startsWith(u8, base, "http://") or std.mem.startsWith(u8, base, "https://")) and
        base.len > 8 and base.len < 512 and
        std.mem.indexOfScalar(u8, base, ' ') == null;
}

fn trimBase(base: []const u8) []const u8 {
    return std.mem.trimEnd(u8, base, "/");
}

/// A Java package name: `eu.kanade.tachiyomi.extension.all.ahottie`. Only
/// `[A-Za-z0-9._]`, at least one dot, no leading/trailing dot, no `..`.
pub fn isPkgName(s: []const u8) bool {
    if (s.len == 0 or s.len > 255) return false;
    if (s[0] == '.' or s[s.len - 1] == '.') return false;
    var has_dot = false;
    for (s, 0..) |c, i| {
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '_' or c == '.';
        if (!ok) return false;
        if (c == '.') {
            has_dot = true;
            if (i + 1 < s.len and s[i + 1] == '.') return false;
        }
    }
    return has_dot;
}

/// An APK filename: `tachiyomi-all.ahottie-v1.4.3.apk`. `[A-Za-z0-9._-]`, must
/// end in `.apk`, no path separators.
pub fn isApkName(s: []const u8) bool {
    if (s.len < 5 or s.len > 255) return false;
    if (!std.mem.endsWith(u8, s, ".apk")) return false;
    for (s) |c| {
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '_' or c == '.' or c == '-';
        if (!ok) return false;
    }
    if (std.mem.indexOf(u8, s, "..") != null) return false;
    return true;
}

// ── Repo index URL handling ──

/// A fetchable repo catalog URL: http(s), no spaces, ends in `index.min.json`.
pub fn isValidIndexUrl(url: []const u8) bool {
    return (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://")) and
        url.len > 20 and url.len < 512 and
        std.mem.indexOfScalar(u8, url, ' ') == null and
        std.mem.endsWith(u8, url, INDEX_FILE);
}

/// Normalize a user-entered repo location into its `index.min.json` URL.
/// Accepts the full catalog URL as-is, or a repo/branch base (trailing slash
/// optional) onto which `/index.min.json` is appended. Returns null if the
/// result isn't a valid http(s) index URL.
pub fn normalizeRepoIndexUrl(out: []u8, input: []const u8) ?[]const u8 {
    if (input.len == 0) return null;
    if (!std.mem.startsWith(u8, input, "http://") and !std.mem.startsWith(u8, input, "https://")) return null;
    if (std.mem.indexOfScalar(u8, input, ' ') != null) return null;

    const built = if (std.mem.endsWith(u8, input, INDEX_FILE))
        (std.fmt.bufPrint(out, "{s}", .{input}) catch return null)
    else
        (std.fmt.bufPrint(out, "{s}/{s}", .{ std.mem.trimEnd(u8, input, "/"), INDEX_FILE }) catch return null);

    return if (isValidIndexUrl(built)) built else null;
}

// ── Suwayomi extension endpoint builders ──

/// `<base>/api/v1/extension/list` — installed + available extensions.
pub fn buildExtensionListUrl(out: []u8, base: []const u8) ?[]const u8 {
    if (!isValidBase(base)) return null;
    return std.fmt.bufPrint(out, "{s}/api/v1/extension/list", .{trimBase(base)}) catch null;
}

/// `<base>/api/v1/extension/install/{pkg}`.
pub fn buildInstallUrl(out: []u8, base: []const u8, pkg: []const u8) ?[]const u8 {
    if (!isValidBase(base) or !isPkgName(pkg)) return null;
    return std.fmt.bufPrint(out, "{s}/api/v1/extension/install/{s}", .{ trimBase(base), pkg }) catch null;
}

/// `<base>/api/v1/extension/uninstall/{pkg}`.
pub fn buildUninstallUrl(out: []u8, base: []const u8, pkg: []const u8) ?[]const u8 {
    if (!isValidBase(base) or !isPkgName(pkg)) return null;
    return std.fmt.bufPrint(out, "{s}/api/v1/extension/uninstall/{s}", .{ trimBase(base), pkg }) catch null;
}

/// `<base>/api/v1/extension/update/{pkg}`.
pub fn buildUpdateUrl(out: []u8, base: []const u8, pkg: []const u8) ?[]const u8 {
    if (!isValidBase(base) or !isPkgName(pkg)) return null;
    return std.fmt.bufPrint(out, "{s}/api/v1/extension/update/{s}", .{ trimBase(base), pkg }) catch null;
}

/// `<base>/api/v1/extension/icon/{apkName}`.
pub fn buildIconUrl(out: []u8, base: []const u8, apk: []const u8) ?[]const u8 {
    if (!isValidBase(base) or !isApkName(apk)) return null;
    return std.fmt.bufPrint(out, "{s}/api/v1/extension/icon/{s}", .{ trimBase(base), apk }) catch null;
}

// ── JSON extraction (self-contained tiny helpers; index.min.json is flat) ──

/// Read a JSON string field `"key":"…"` from `scope` into `dst` (bytes written,
/// 0 if absent). Stops at the first unescaped quote. Bounds-safe.
pub fn jsonStr(scope: []const u8, key: []const u8, dst: []u8) usize {
    const at = std.mem.indexOf(u8, scope, key) orelse return 0;
    var i = at + key.len;
    var out: usize = 0;
    while (i < scope.len and out < dst.len) : (i += 1) {
        const c = scope[i];
        if (c == '\\' and i + 1 < scope.len) {
            dst[out] = scope[i + 1];
            out += 1;
            i += 1;
            continue;
        }
        if (c == '"') break;
        dst[out] = c;
        out += 1;
    }
    return out;
}

/// Read an integer JSON field `"key":<int>` from `scope` (null if absent).
pub fn jsonInt(scope: []const u8, key: []const u8) ?i64 {
    const at = std.mem.indexOf(u8, scope, key) orelse return null;
    var i = at + key.len;
    while (i < scope.len and (scope[i] == ' ' or scope[i] == ':')) i += 1;
    var end = i;
    if (end < scope.len and scope[end] == '-') end += 1;
    while (end < scope.len and scope[end] >= '0' and scope[end] <= '9') end += 1;
    if (end == i) return null;
    return std.fmt.parseInt(i64, scope[i..end], 10) catch null;
}

/// Count non-overlapping occurrences of `needle` in `hay`.
fn countOf(hay: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var n: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, hay, pos, needle)) |at| {
        n += 1;
        pos = at + needle.len;
    }
    return n;
}

/// One ingested extension row (browsable catalog entry).
pub const Extension = struct {
    name: []const u8, // extension display name
    pkg: []const u8, // package id (install key)
    apk: []const u8, // apk filename (icon key)
    lang: []const u8, // extension language ("all", "en", …)
    version: []const u8,
    nsfw: bool,
    source_count: usize, // number of sources the extension provides
    source_id: []const u8, // first source's numeric id (as text)
    source_name: []const u8, // first source's display name
    source_base: []const u8, // first source's baseUrl
};

/// Iterate the top-level extension array of an index.min.json, yielding each
/// complete `{…}` object slice (nested `sources` objects included). Tracks brace
/// depth and skips braces inside JSON strings, so — unlike a marker split — the
/// leading `name` field (which precedes `pkg`) stays inside its object.
/// Bounds-safe.
pub const ExtIter = struct {
    json: []const u8,
    pos: usize = 0,

    pub fn next(self: *ExtIter) ?[]const u8 {
        var i = self.pos;
        while (i < self.json.len and self.json[i] != '{') i += 1;
        if (i >= self.json.len) return null;
        const start = i;
        var depth: usize = 0;
        var in_str = false;
        while (i < self.json.len) : (i += 1) {
            const c = self.json[i];
            if (in_str) {
                if (c == '\\') {
                    i += 1; // skip the escaped char (loop adds the other +1)
                    continue;
                }
                if (c == '"') in_str = false;
                continue;
            }
            switch (c) {
                '"' => in_str = true,
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) {
                        self.pos = i + 1;
                        return self.json[start .. i + 1];
                    }
                },
                else => {},
            }
        }
        return null; // unterminated object
    }
};

/// Parse one extension object slice into caller buffers. Extension-level fields
/// (`name`,`pkg`,`apk`,`lang`,`version`,`nsfw`) precede the `sources` array, so
/// their first match is unambiguous; source fields are read from inside the
/// `"sources"` scope so we grab the FIRST source, not the extension name again.
/// Returns null when there's no valid pkg.
pub fn parseExtension(
    obj: []const u8,
    name_buf: []u8,
    pkg_buf: []u8,
    apk_buf: []u8,
    lang_buf: []u8,
    ver_buf: []u8,
    sid_buf: []u8,
    sname_buf: []u8,
    sbase_buf: []u8,
) ?Extension {
    const pn = jsonStr(obj, "\"pkg\":\"", pkg_buf);
    if (pn == 0 or !isPkgName(pkg_buf[0..pn])) return null;

    const nn = jsonStr(obj, "\"name\":\"", name_buf);
    const an = jsonStr(obj, "\"apk\":\"", apk_buf);
    const ln = jsonStr(obj, "\"lang\":\"", lang_buf);
    const vn = jsonStr(obj, "\"version\":\"", ver_buf);
    const nsfw = (jsonInt(obj, "\"nsfw\":") orelse 0) == 1;

    // Confine source reads to the sources array so we don't re-read ext-level
    // "name"/"lang". `id` in index.min.json is a JSON string.
    const src_scope = if (std.mem.indexOf(u8, obj, "\"sources\"")) |s| obj[s..] else obj[obj.len..];
    const sc = countOf(src_scope, "\"baseUrl\"");
    const sidn = jsonStr(src_scope, "\"id\":\"", sid_buf);
    const snn = jsonStr(src_scope, "\"name\":\"", sname_buf);
    const sbn = jsonStr(src_scope, "\"baseUrl\":\"", sbase_buf);

    return .{
        .name = name_buf[0..nn],
        .pkg = pkg_buf[0..pn],
        .apk = apk_buf[0..an],
        .lang = lang_buf[0..ln],
        .version = ver_buf[0..vn],
        .nsfw = nsfw,
        .source_count = sc,
        .source_id = sid_buf[0..sidn],
        .source_name = sname_buf[0..snn],
        .source_base = sbase_buf[0..sbn],
    };
}

// ── Server-side repo registration (GraphQL) ──
// Suwayomi will only install an extension whose repo it KNOWS. The panel fetches
// the catalog client-side for browsing, but before an install can work the repo
// must be in the server's `extensionRepos` setting. These build the GraphQL to
// read the current repos, set the merged list, and refresh the extension list.

/// `<base>/api/graphql`.
pub fn buildGraphqlUrl(out: []u8, base: []const u8) ?[]const u8 {
    if (!isValidBase(base)) return null;
    return std.fmt.bufPrint(out, "{s}/api/graphql", .{trimBase(base)}) catch null;
}

/// Query the server's current extension repos.
pub const GQL_GET_REPOS = "{\"query\":\"query{settings{extensionRepos}}\"}";
/// Refresh the available-extension list after the repo set changed.
pub const GQL_FETCH_EXTENSIONS = "{\"query\":\"mutation{fetchExtensions(input:{}){clientMutationId}}\"}";

/// Extract the `extensionRepos` URL array from a settings query response into
/// `dst` slices (backed by `scratch`). Returns how many were read (capped by
/// dst.len / scratch space). Bounds-safe; tolerant of whitespace.
pub fn extractRepos(json: []const u8, dst: [][]const u8, scratch: []u8) usize {
    const at = std.mem.indexOf(u8, json, "\"extensionRepos\"") orelse return 0;
    const lb = std.mem.indexOfScalarPos(u8, json, at, '[') orelse return 0;
    var i = lb + 1;
    var n: usize = 0;
    var w: usize = 0;
    while (i < json.len and n < dst.len) {
        // Next string or end of array.
        while (i < json.len and json[i] != '"' and json[i] != ']') i += 1;
        if (i >= json.len or json[i] == ']') break;
        i += 1; // past opening quote
        const start = w;
        while (i < json.len and json[i] != '"' and w < scratch.len) : (i += 1) {
            scratch[w] = json[i];
            w += 1;
        }
        if (i < json.len and json[i] == '"') i += 1; // past closing quote
        dst[n] = scratch[start..w];
        n += 1;
    }
    return n;
}

/// Whether `url` is already among `repos`.
pub fn reposContain(repos: []const []const u8, url: []const u8) bool {
    for (repos) |r| if (std.mem.eql(u8, r, url)) return true;
    return false;
}

/// Build the setSettings mutation body that sets `extensionRepos` to `repos`
/// (JSON string array, each URL escaped for `"`/`\`). Null if it won't fit.
pub fn buildSetReposBody(out: []u8, repos: []const []const u8) ?[]const u8 {
    var w: usize = 0;
    const pre = "{\"query\":\"mutation{setSettings(input:{settings:{extensionRepos:[";
    const post = "]}}){settings{extensionRepos}}}\"}";
    appendRaw(out, &w, pre) orelse return null;
    for (repos, 0..) |r, i| {
        if (i > 0) appendRaw(out, &w, ",") orelse return null;
        // A GraphQL string literal inside a JSON string: the URL needs its quote
        // as \\\" (JSON-escaped backslash + escaped quote) — but repo URLs never
        // contain quotes/backslashes (validated by isValidIndexUrl), so a bare
        // \" wrapper is safe. Reject anything unexpected to stay safe.
        if (std.mem.indexOfScalar(u8, r, '"') != null or std.mem.indexOfScalar(u8, r, '\\') != null) return null;
        appendRaw(out, &w, "\\\"") orelse return null;
        appendRaw(out, &w, r) orelse return null;
        appendRaw(out, &w, "\\\"") orelse return null;
    }
    appendRaw(out, &w, post) orelse return null;
    return out[0..w];
}

fn appendRaw(out: []u8, w: *usize, s: []const u8) ?void {
    if (w.* + s.len > out.len) return null;
    @memcpy(out[w.*..][0..s.len], s);
    w.* += s.len;
    return {};
}

// ── Suwayomi extension/list parsing (installed-state) ──
// The GET /api/v1/extension/list response is a JSON array of objects, one per
// extension the server knows about, each carrying `"pkgName"` and an
// `"installed"` bool. We iterate it (ExtIter is shape-agnostic) to learn which
// catalog packages are already installed, so the panel shows Install vs Remove.

/// The `pkgName` of one extension/list object.
pub fn listObjPkg(obj: []const u8, dst: []u8) usize {
    return jsonStr(obj, "\"pkgName\":\"", dst);
}

/// Whether one extension/list object is installed (`"installed":true`).
pub fn listObjInstalled(obj: []const u8) bool {
    return std.mem.indexOf(u8, obj, "\"installed\":true") != null;
}

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

test "graphql url + repo-registration bodies" {
    var b: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "http://localhost:4567/api/graphql",
        buildGraphqlUrl(&b, "http://localhost:4567/").?,
    );
    // Merge: read current repos, add a new one only if absent, build the set body.
    const settings = "{\"data\":{\"settings\":{\"extensionRepos\":[\"https://a/index.min.json\",\"https://b/index.min.json\"]}}}";
    var slots: [8][]const u8 = undefined;
    var scratch: [512]u8 = undefined;
    const n = extractRepos(settings, &slots, &scratch);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("https://a/index.min.json", slots[0]);
    try std.testing.expectEqualStrings("https://b/index.min.json", slots[1]);
    try std.testing.expect(reposContain(slots[0..n], "https://a/index.min.json"));
    try std.testing.expect(!reposContain(slots[0..n], "https://c/index.min.json"));

    var body: [512]u8 = undefined;
    const set = buildSetReposBody(&body, slots[0..n]).?;
    try std.testing.expectEqualStrings(
        "{\"query\":\"mutation{setSettings(input:{settings:{extensionRepos:[\\\"https://a/index.min.json\\\",\\\"https://b/index.min.json\\\"]}}){settings{extensionRepos}}}\"}",
        set,
    );
}

test "extractRepos handles an empty array" {
    var slots: [4][]const u8 = undefined;
    var scratch: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), extractRepos("{\"settings\":{\"extensionRepos\":[]}}", &slots, &scratch));
    try std.testing.expectEqual(@as(usize, 0), extractRepos("{\"settings\":{}}", &slots, &scratch));
}

test "extension/list installed-state parsing" {
    const list =
        \\[{"name":"AHottie","pkgName":"eu.kanade.tachiyomi.extension.all.ahottie","installed":true,"hasUpdate":false},
        \\{"name":"Foo","pkgName":"eu.kanade.tachiyomi.extension.en.foo","installed":false}]
    ;
    var it = ExtIter{ .json = list };
    var pb: [256]u8 = undefined;

    const o0 = it.next().?;
    try std.testing.expectEqualStrings("eu.kanade.tachiyomi.extension.all.ahottie", pb[0..listObjPkg(o0, &pb)]);
    try std.testing.expect(listObjInstalled(o0));

    const o1 = it.next().?;
    try std.testing.expectEqualStrings("eu.kanade.tachiyomi.extension.en.foo", pb[0..listObjPkg(o1, &pb)]);
    try std.testing.expect(!listObjInstalled(o1));

    try std.testing.expect(it.next() == null);
}

test "curated repo table is well-formed http index urls" {
    try std.testing.expect(REPOS.len >= 4);
    for (REPOS) |r| {
        try std.testing.expect(r.name.len > 0);
        try std.testing.expect(std.mem.eql(u8, r.kind, "manga") or std.mem.eql(u8, r.kind, "anime"));
        try std.testing.expect(isValidIndexUrl(r.url));
    }
    // keiyoushi is the canonical manga repo.
    try std.testing.expectEqualStrings("https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.min.json", REPOS[0].url);
}

test "security gates reject path-escapes" {
    try std.testing.expect(isValidBase("http://localhost:4567"));
    try std.testing.expect(!isValidBase("localhost:4567"));

    try std.testing.expect(isPkgName("eu.kanade.tachiyomi.extension.all.ahottie"));
    try std.testing.expect(!isPkgName("no_dot"));
    try std.testing.expect(!isPkgName("a/../b"));
    try std.testing.expect(!isPkgName(".leading"));
    try std.testing.expect(!isPkgName("a..b"));
    try std.testing.expect(!isPkgName("has space"));

    try std.testing.expect(isApkName("tachiyomi-all.ahottie-v1.4.3.apk"));
    try std.testing.expect(!isApkName("x.apk/../y"));
    try std.testing.expect(!isApkName("noext"));
    try std.testing.expect(!isApkName("a..b.apk"));
}

test "normalizeRepoIndexUrl accepts full url or appends index.min.json" {
    var b: [512]u8 = undefined;
    const full = "https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.min.json";
    try std.testing.expectEqualStrings(full, normalizeRepoIndexUrl(&b, full).?);
    try std.testing.expectEqualStrings(full, normalizeRepoIndexUrl(&b, "https://raw.githubusercontent.com/keiyoushi/extensions/repo").?);
    try std.testing.expectEqualStrings(full, normalizeRepoIndexUrl(&b, "https://raw.githubusercontent.com/keiyoushi/extensions/repo/").?);
    try std.testing.expect(normalizeRepoIndexUrl(&b, "ftp://x/repo") == null);
    try std.testing.expect(normalizeRepoIndexUrl(&b, "") == null);
    try std.testing.expect(normalizeRepoIndexUrl(&b, "https://x/ repo") == null);
}

test "extension endpoint url builders (trim trailing slash + gate ids)" {
    var b: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "http://localhost:4567/api/v1/extension/list",
        buildExtensionListUrl(&b, "http://localhost:4567/").?,
    );
    try std.testing.expectEqualStrings(
        "http://localhost:4567/api/v1/extension/install/eu.kanade.tachiyomi.extension.all.ahottie",
        buildInstallUrl(&b, "http://localhost:4567", "eu.kanade.tachiyomi.extension.all.ahottie").?,
    );
    try std.testing.expectEqualStrings(
        "http://localhost:4567/api/v1/extension/uninstall/eu.kanade.tachiyomi.extension.en.foo",
        buildUninstallUrl(&b, "http://localhost:4567", "eu.kanade.tachiyomi.extension.en.foo").?,
    );
    try std.testing.expectEqualStrings(
        "http://localhost:4567/api/v1/extension/icon/tachiyomi-all.ahottie-v1.4.3.apk",
        buildIconUrl(&b, "http://localhost:4567", "tachiyomi-all.ahottie-v1.4.3.apk").?,
    );
    // Gates.
    try std.testing.expect(buildInstallUrl(&b, "http://x", "a/../b") == null);
    try std.testing.expect(buildIconUrl(&b, "http://x", "evil") == null);
    try std.testing.expect(buildExtensionListUrl(&b, "nope") == null);
}

test "parse index.min.json extensions (multi-source + nsfw)" {
    const json =
        \\[{"name":"Tachiyomi: AHottie","pkg":"eu.kanade.tachiyomi.extension.all.ahottie",
        \\"apk":"tachiyomi-all.ahottie-v1.4.3.apk","lang":"all","code":3,"version":"1.4.3","nsfw":1,
        \\"sources":[{"name":"AHottie","lang":"all","id":"6289731484943315811","baseUrl":"https://ahottie.top"}]},
        \\{"name":"Tachiyomi: MangaBundle","pkg":"eu.kanade.tachiyomi.extension.en.bundle",
        \\"apk":"tachiyomi-en.bundle-v2.0.0.apk","lang":"en","code":1,"version":"2.0.0","nsfw":0,
        \\"sources":[{"name":"SrcA","lang":"en","id":"111","baseUrl":"https://a.example"},
        \\{"name":"SrcB","lang":"en","id":"222","baseUrl":"https://b.example"}]}]
    ;
    var it = ExtIter{ .json = json };
    var nb: [128]u8 = undefined;
    var pb: [256]u8 = undefined;
    var ab: [256]u8 = undefined;
    var lb: [16]u8 = undefined;
    var vb: [32]u8 = undefined;
    var sib: [32]u8 = undefined;
    var snb: [128]u8 = undefined;
    var sbb: [256]u8 = undefined;

    const e0 = parseExtension(it.next().?, &nb, &pb, &ab, &lb, &vb, &sib, &snb, &sbb).?;
    try std.testing.expectEqualStrings("Tachiyomi: AHottie", e0.name);
    try std.testing.expectEqualStrings("eu.kanade.tachiyomi.extension.all.ahottie", e0.pkg);
    try std.testing.expectEqualStrings("tachiyomi-all.ahottie-v1.4.3.apk", e0.apk);
    try std.testing.expectEqualStrings("all", e0.lang);
    try std.testing.expectEqualStrings("1.4.3", e0.version);
    try std.testing.expect(e0.nsfw);
    try std.testing.expectEqual(@as(usize, 1), e0.source_count);
    try std.testing.expectEqualStrings("6289731484943315811", e0.source_id);
    try std.testing.expectEqualStrings("AHottie", e0.source_name);
    try std.testing.expectEqualStrings("https://ahottie.top", e0.source_base);

    const e1 = parseExtension(it.next().?, &nb, &pb, &ab, &lb, &vb, &sib, &snb, &sbb).?;
    try std.testing.expectEqualStrings("Tachiyomi: MangaBundle", e1.name);
    try std.testing.expect(!e1.nsfw);
    try std.testing.expectEqual(@as(usize, 2), e1.source_count);
    try std.testing.expectEqualStrings("111", e1.source_id);
    try std.testing.expectEqualStrings("SrcA", e1.source_name);
    try std.testing.expectEqualStrings("https://a.example", e1.source_base);

    try std.testing.expect(it.next() == null);
}
