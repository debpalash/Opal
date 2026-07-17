//! Pure (io-free, state-free) helpers for the executable content-plugin system,
//! unit-testable via `zig build test`. `plugins.zig` routes through these so the
//! tested logic IS the shipped logic (no drift).

const std = @import("std");

/// The `scheme://host` origin of an http(s) URL (no trailing slash), or null for
/// a non-http URL or one with an empty host.
pub fn originOf(url: []const u8) ?[]const u8 {
    const schemes = [_][]const u8{ "https://", "http://" };
    for (schemes) |s| {
        if (std.mem.startsWith(u8, url, s)) {
            const rest = url[s.len..];
            const host_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
            if (host_end == 0) return null; // "https:///path" — no host
            return url[0 .. s.len + host_end];
        }
    }
    return null;
}

/// Build a `Referer:` curl header for a manga page-image fetch. Prefers the
/// plugin's own `referer` (from its resolve JSON) when non-empty; otherwise
/// derives the origin (`scheme://host/`) of the image URL itself. Returns null
/// when neither yields a usable value (non-http image URL + no plugin referer),
/// so the caller can omit the header entirely.
///
/// This replaced a hardcoded `Referer: https://coffeemanga.io/` that was sent
/// for EVERY content-plugin manga fetch, 403'ing images from any other site.
pub fn refererHeader(plugin_referer: []const u8, image_url: []const u8, buf: []u8) ?[]const u8 {
    if (plugin_referer.len > 0) {
        return std.fmt.bufPrint(buf, "Referer: {s}", .{plugin_referer}) catch null;
    }
    const origin = originOf(image_url) orelse return null;
    return std.fmt.bufPrint(buf, "Referer: {s}/", .{origin}) catch null;
}

// ── Sandbox invocation decision ──────────────────────────────────────────────

pub const RunMode = enum { sandbox_lua, direct };

/// Decide how to invoke a content-plugin executable.
///
/// A Lua script is sandboxed (prelude nils dangerous globals) UNLESS the plugin
/// declares `allow_unsafe` AND the user has separately trusted it (a user-created
/// marker file). This is the key hardening: previously `allow_unsafe` alone —
/// which the plugin sets in its own manifest — disabled the sandbox, so a
/// malicious plugin could self-declare its way out. Trust now requires a user
/// action the plugin can't forge.
///
/// Non-Lua/native executables can't be prelude-sandboxed, so they always run
/// direct — callers must warn (see `untrustedNative`) when the user hasn't
/// trusted them, since they run with the app's full privileges.
pub fn runMode(is_lua: bool, manifest_allow_unsafe: bool, user_trusted: bool) RunMode {
    if (is_lua and !(manifest_allow_unsafe and user_trusted)) return .sandbox_lua;
    return .direct;
}

/// True when a native/non-Lua plugin is about to run with no sandbox and no user
/// trust marker — the caller should surface a prominent warning.
pub fn untrustedNative(is_lua: bool, user_trusted: bool) bool {
    return !is_lua and !user_trusted;
}

test "runMode sandboxes Lua unless user-trusted + manifest allow_unsafe" {
    // Plain Lua → sandbox.
    try std.testing.expectEqual(RunMode.sandbox_lua, runMode(true, false, false));
    // allow_unsafe alone (plugin self-declared) must NOT escape the sandbox.
    try std.testing.expectEqual(RunMode.sandbox_lua, runMode(true, true, false));
    // User trust alone (no manifest opt-in) still sandboxes.
    try std.testing.expectEqual(RunMode.sandbox_lua, runMode(true, false, true));
    // Both → direct (the only escape).
    try std.testing.expectEqual(RunMode.direct, runMode(true, true, true));
    // Native always runs direct (can't be prelude-sandboxed).
    try std.testing.expectEqual(RunMode.direct, runMode(false, false, false));
}

test "untrustedNative flags only unsandboxed, untrusted native code" {
    try std.testing.expect(untrustedNative(false, false)); // native, untrusted → warn
    try std.testing.expect(!untrustedNative(false, true)); // native, trusted → ok
    try std.testing.expect(!untrustedNative(true, false)); // lua is sandboxed, not "native"
}

test "originOf extracts scheme+host, rejects non-http / empty host" {
    try std.testing.expectEqualStrings("https://mangadex.org", originOf("https://mangadex.org/img/1.jpg").?);
    try std.testing.expectEqualStrings("http://x.co", originOf("http://x.co/a/b").?);
    try std.testing.expectEqualStrings("https://cdn.example:8443", originOf("https://cdn.example:8443/p.jpg").?);
    try std.testing.expect(originOf("ftp://x.co/a") == null);
    try std.testing.expect(originOf("https:///nohost") == null);
    try std.testing.expect(originOf("not a url") == null);
}

test "refererHeader prefers plugin referer, falls back to image origin" {
    var buf: [600]u8 = undefined;
    // Plugin-supplied referer wins.
    try std.testing.expectEqualStrings(
        "Referer: https://site.example/read/",
        refererHeader("https://site.example/read/", "https://cdn.other.net/1.jpg", &buf).?,
    );
    // No plugin referer → derive from the image's own origin (the coffeemanga fix).
    try std.testing.expectEqualStrings(
        "Referer: https://cdn.other.net/",
        refererHeader("", "https://cdn.other.net/1.jpg", &buf).?,
    );
    // Nothing usable → null so the caller omits the header.
    try std.testing.expect(refererHeader("", "data:image/png;base64,AAAA", &buf) == null);
}

// ── Source-plugin catalog: category grouping + search filter ──────────────────
//
// The available-source list grew past ~45 entries (25 torrent + 20 stremio +
// anime/comics/metadata). A flat unsorted list of identical rows is unusable at
// that size, so the Plugins page groups by category and filters by a query +
// installed-only toggle. That routing decision lives here so it's testable.

pub const Category = enum {
    torrent,
    stremio,
    anime,
    comics,
    metadata,
    other,

    /// Fixed display order, most-used first. Lower sorts earlier.
    pub fn order(self: Category) u8 {
        return switch (self) {
            .torrent => 0,
            .stremio => 1,
            .anime => 2,
            .comics => 3,
            .metadata => 4,
            .other => 5,
        };
    }

    pub fn label(self: Category) []const u8 {
        return switch (self) {
            .torrent => "Torrent indexers",
            .stremio => "Stremio add-ons",
            .anime => "Anime",
            .comics => "Comics & Manga",
            .metadata => "Metadata",
            .other => "Other",
        };
    }
};

/// Map a plugin's `type` string (from the manifest) to a display category.
/// Unknown/blank types fall into `.other` so nothing is ever dropped from view.
pub fn categoryOf(kind: []const u8) Category {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(kind, "torrent")) return .torrent;
    if (eq(kind, "stremio")) return .stremio;
    if (eq(kind, "anime")) return .anime;
    if (eq(kind, "comics") or eq(kind, "manga")) return .comics;
    if (eq(kind, "metadata")) return .metadata;
    return .other;
}

/// Categories in display order — callers iterate this so the ordering lives in
/// one tested place (not re-sorted at each call site).
pub const ordered_categories = [_]Category{ .torrent, .stremio, .anime, .comics, .metadata, .other };

/// Case-insensitive substring test. Empty needle matches everything (a blank
/// search box shows the full list).
pub fn containsFold(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    outer: while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) continue :outer;
        }
        return true;
    }
    return false;
}

/// Does a plugin pass the current filter? A row shows when the query matches its
/// name OR its kind, AND (installed-only is off OR the row is installed).
pub fn matches(name: []const u8, kind: []const u8, query: []const u8, installed_only: bool, is_installed: bool) bool {
    if (installed_only and !is_installed) return false;
    return containsFold(name, query) or containsFold(kind, query);
}

test "categoryOf maps known kinds, folds manga into comics, keeps unknowns" {
    try std.testing.expectEqual(Category.torrent, categoryOf("torrent"));
    try std.testing.expectEqual(Category.stremio, categoryOf("stremio"));
    try std.testing.expectEqual(Category.anime, categoryOf("anime"));
    try std.testing.expectEqual(Category.comics, categoryOf("comics"));
    try std.testing.expectEqual(Category.comics, categoryOf("manga"));
    try std.testing.expectEqual(Category.metadata, categoryOf("metadata"));
    try std.testing.expectEqual(Category.torrent, categoryOf("Torrent")); // case-insensitive
    try std.testing.expectEqual(Category.other, categoryOf("weirdnewtype"));
    try std.testing.expectEqual(Category.other, categoryOf(""));
}

test "ordered_categories is the strictly-sorted, complete set" {
    var prev: i32 = -1;
    var seen = [_]bool{false} ** ordered_categories.len;
    for (ordered_categories) |c| {
        const o = @as(i32, c.order());
        try std.testing.expect(o > prev); // strictly increasing
        prev = o;
        seen[@intFromEnum(c)] = true;
    }
    for (seen) |s| try std.testing.expect(s); // every category present
}

test "containsFold: empty matches, case-insensitive, needle-longer guard" {
    try std.testing.expect(containsFold("The Pirate Bay", ""));
    try std.testing.expect(containsFold("The Pirate Bay", "pirate"));
    try std.testing.expect(containsFold("The Pirate Bay", "BAY"));
    try std.testing.expect(!containsFold("The Pirate Bay", "yts"));
    try std.testing.expect(!containsFold("ab", "abc"));
}

test "matches: installed-only gate + name/kind query" {
    try std.testing.expect(matches("EZTV", "torrent", "", false, false)); // blank → all
    try std.testing.expect(!matches("EZTV", "torrent", "", true, false)); // installed-only hides
    try std.testing.expect(matches("EZTV", "torrent", "", true, true));
    try std.testing.expect(matches("EZTV", "torrent", "torr", false, false)); // matches on kind
    try std.testing.expect(!matches("EZTV", "torrent", "anime", false, false)); // no match hides
}
