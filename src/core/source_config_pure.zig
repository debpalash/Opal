//! Pure (io-free) rules for the installed-source table — unit-testable via
//! `zig build test`. `source_config.zig` routes through these.
//!
//! Background, because the sizing constant here is not arbitrary:
//!
//! An installed source is one `<id>.json` file holding a flat string map, and
//! `reload()` flattens EVERY key of EVERY file into one fixed table — so the
//! table is sized in FIELDS, not in sources. A source with
//! `{"base": …, "api": …}` costs two slots, `torrentio` costs three.
//!
//! The table held 64 slots and dropped anything past that in silence. On a real
//! install (56 source files, 77 fields) that silently discarded 13 fields:
//! `has(id)` reported those sources as not installed, so the Plugins page kept
//! offering "Install" for a source whose file was already on disk — and worse,
//! `get(id, field)` returned null for them, so those sources were INERT at
//! runtime. Clicking Install wrote the file and changed nothing.

const std = @import("std");

/// Slots in the flattened field table.
///
/// Sized in FIELDS: the bundled manifest ships 64 sources, observed field counts
/// run 1-3 per source, and the browser extension can add more at will. 512 is
/// ~8 fields for every bundled source with room for user-added ones, at
/// roughly 300 KB of .bss — cheap next to silently disabling a source.
pub const MAX_ENTRIES = 512;

/// Filename limits. `id` is used directly as a filename stem, and `field`/`val`
/// are copied into fixed buffers.
pub const MAX_ID_LEN = 32;
pub const MAX_FIELD_LEN = 24;
pub const MAX_VAL_LEN = 512;

/// Whether a source id is safe to use as a filename.
///
/// Rejects path separators, `.` (which would allow `..` traversal and would
/// also break the ".json" stem split) and NUL. Shared by install and uninstall
/// so the two can never disagree about which ids are legal — they used to carry
/// separate copies of this loop.
pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > MAX_ID_LEN) return false;
    for (id) |ch| {
        if (ch == '/' or ch == '\\' or ch == '.' or ch == 0) return false;
        if (ch < 0x20 or ch == 0x7f) return false;
    }
    return true;
}

/// Whether a parsed field can be stored. A rejected field is a source silently
/// losing an endpoint, so callers must report the rejection rather than skip.
pub fn validField(field: []const u8, val: []const u8) bool {
    if (field.len == 0 or field.len > MAX_FIELD_LEN) return false;
    if (val.len == 0 or val.len > MAX_VAL_LEN) return false;
    return true;
}

/// Source id from a directory entry name, or null when the name is not an
/// installable source file.
pub fn idFromFileName(name: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, name, ".json")) return null;
    const id = name[0 .. name.len - ".json".len];
    if (!validId(id)) return null;
    return id;
}

/// How many fields did not fit. Non-zero means installed sources are inert —
/// the caller must log it, not swallow it.
pub fn overflowBy(needed: usize, cap: usize) usize {
    return if (needed > cap) needed - cap else 0;
}

// ══════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "the table holds every field a full install can produce" {
    // REGRESSION: the cap was 64 FIELDS while the bundled manifest ships 64
    // SOURCES averaging >1 field each. A measured install — 56 source files,
    // 77 fields — overflowed by 13, and those sources went inert with no
    // message anywhere.
    const measured_sources = 56;
    const measured_fields = 77;
    try expect(measured_fields > measured_sources); // fields, not sources
    try expectEqual(@as(usize, 13), overflowBy(measured_fields, 64));
    try expectEqual(@as(usize, 0), overflowBy(measured_fields, MAX_ENTRIES));

    // Every bundled source at the worst observed field count still fits, with
    // headroom for sources the browser extension adds later.
    const bundled_sources = 64;
    const worst_fields_per_source = 3;
    try expectEqual(@as(usize, 0), overflowBy(bundled_sources * worst_fields_per_source, MAX_ENTRIES));
    try expect(MAX_ENTRIES >= bundled_sources * worst_fields_per_source * 2);
}

test "overflowBy reports the shortfall, never wraps" {
    try expectEqual(@as(usize, 0), overflowBy(0, 64));
    try expectEqual(@as(usize, 0), overflowBy(64, 64)); // exactly full is fine
    try expectEqual(@as(usize, 1), overflowBy(65, 64));
    // Under-full must not underflow into a huge count.
    try expectEqual(@as(usize, 0), overflowBy(1, 64));
    try expectEqual(@as(usize, 100), overflowBy(100, 0));
}

test "validId rejects anything unsafe as a filename" {
    try expect(validId("1337x"));
    try expect(validId("thepiratebay-plus"));
    try expect(validId("a"));
    // Traversal and separators.
    try expect(!validId(".."));
    try expect(!validId("../../etc/passwd"));
    try expect(!validId("a/b"));
    try expect(!validId("a\\b"));
    // A dot is rejected outright — it would also break the ".json" stem split.
    try expect(!validId("my.source"));
    // Empty, over-long, NUL and control bytes.
    try expect(!validId(""));
    try expect(!validId("x" ** (MAX_ID_LEN + 1)));
    try expect(validId("x" ** MAX_ID_LEN));
    try expect(!validId("a\x00b"));
    try expect(!validId("a\nb"));
}

test "idFromFileName strips .json and applies the same id rules" {
    try expectEqualStrings("eztv", idFromFileName("eztv.json").?);
    try expectEqualStrings("thepiratebay-plus", idFromFileName("thepiratebay-plus.json").?);
    // Not a source file.
    try expect(idFromFileName("eztv") == null);
    try expect(idFromFileName("README.md") == null);
    try expect(idFromFileName(".json") == null); // empty stem
    // A stem that would be an unsafe id is rejected here too, so a hand-placed
    // file cannot smuggle one past install()'s check.
    try expect(idFromFileName("a/b.json") == null);
    try expect(idFromFileName("..json") == null);
}

test "validField mirrors the fixed buffers it feeds" {
    try expect(validField("base", "https://example.org"));
    try expect(!validField("", "x"));
    try expect(!validField("base", ""));
    try expect(!validField("f" ** (MAX_FIELD_LEN + 1), "x"));
    try expect(validField("f" ** MAX_FIELD_LEN, "x"));
    try expect(!validField("base", "v" ** (MAX_VAL_LEN + 1)));
    try expect(validField("base", "v" ** MAX_VAL_LEN));
}

// ── Installed-source versioning ───────────────────────────────────────────
//
// A source was installed once and then kept its endpoints forever. The bundled
// manifest carries a per-plugin `version`, and `plugin_repo` parsed it into
// `pl.version` — but nothing ever compared it against what was on disk, so
// there was no upgrade path at all.
//
// That is how dead domains survive a release. `yts.mx` lost its NS delegation
// at the .mx registry and `limetorrent.in` started serving a TheRarBg page;
// both were corrected in the manifest, and every existing install kept right on
// using the dead host, because the installed file overrides the manifest.
//
// The installed file now carries the manifest version it was written from,
// under this key. `versionNewer` decides whether to rewrite it.

/// Key holding the manifest version an installed source file was written from.
/// Leading underscore keeps it out of the endpoint namespace — no real endpoint
/// field starts with one, and `get(id, "base")` is unaffected.
pub const VERSION_KEY = "_v";

/// True when dotted-numeric `a` is a strictly newer version than `b`.
///
/// Compares segment by segment as integers, so 1.10.0 > 1.9.0 (a plain string
/// compare gets that backwards). A missing segment reads as 0, so 1.1 == 1.1.0.
/// A non-numeric or empty `b` — which is what an install predating versioning
/// looks like — is older than any valid `a`, so those get upgraded exactly once.
pub fn versionNewer(a: []const u8, b: []const u8) bool {
    if (a.len == 0) return false;
    var ai = std.mem.splitScalar(u8, a, '.');
    var bi = std.mem.splitScalar(u8, b, '.');
    var guard: usize = 0;
    while (guard < 8) : (guard += 1) {
        const as = ai.next();
        const bs = bi.next();
        if (as == null and bs == null) return false; // equal all the way down
        const av = std.fmt.parseInt(u32, as orelse "0", 10) catch 0;
        const bv = std.fmt.parseInt(u32, bs orelse "0", 10) catch 0;
        if (av != bv) return av > bv;
    }
    return false;
}

test "versionNewer: numeric segments, not string order" {
    try expect(versionNewer("1.1.0", "1.0.0"));
    try expect(!versionNewer("1.0.0", "1.1.0"));
    try expect(!versionNewer("1.0.0", "1.0.0"));
    // The case a lexicographic compare gets wrong.
    try expect(versionNewer("1.10.0", "1.9.0"));
    try expect(!versionNewer("1.9.0", "1.10.0"));
    // Missing segments read as zero.
    try expect(!versionNewer("1.1", "1.1.0"));
    try expect(versionNewer("1.1.1", "1.1"));
}

// ── Retired sources ───────────────────────────────────────────────────────
//
// Dropping a dead source from the shipped code only stops OFFERING it. The
// user's `<id>.json` stays on disk, and every loader that enumerates that
// directory keeps honouring it — `stremio.loadInstalledAddons()` reads the
// directory itself and accepts any file carrying a "stremio" field, so
// `cyberflix` (manifest 404) and `knightcrawler` (200 OK on a page titled
// "KnightCrawler is deprecated") stayed live add-ons in an existing profile
// long after both were removed from `addKnownAddons`. Measured 2026-07-30 in a
// real profile: two of the sixteen installed-addon slots, one of them handing
// the resolver a deprecation page under a 200. `kickass` was the same shape —
// the engine file was deleted, the install was not.
//
// `shouldRetire` is the guard against over-reach: a retirement applies only
// while the installed value still points at the host that died, so a user who
// re-pointed the id at their own instance keeps it.

pub const Retired = struct {
    id: []const u8,
    field: []const u8,
    /// Host substring that must still be present for the retirement to apply.
    /// Empty means retire regardless of endpoint — for an id whose CONSUMER is
    /// gone, where no endpoint can revive it (an engine absent from the build).
    host: []const u8,
    why: []const u8,
};

pub const RETIRED = [_]Retired{
    .{ .id = "kickass", .field = "base", .host = "", .why = "engine deleted (was a 14-byte 404 page)" },
    .{ .id = "cyberflix", .field = "stremio", .host = "cyberflix.elfhosted.com", .why = "addon manifest returns 404" },
    .{ .id = "knightcrawler", .field = "stremio", .host = "knightcrawler.elfhosted.com", .why = "deprecated upstream" },
};

/// Whether an installed source matching a RETIRED entry should be uninstalled.
/// `host` empty → yes (the consumer is gone). Otherwise only when the value on
/// disk still names the dead host.
pub fn shouldRetire(host: []const u8, installed_val: []const u8) bool {
    if (host.len == 0) return true;
    if (installed_val.len == 0) return false;
    return std.mem.indexOf(u8, installed_val, host) != null;
}

test "shouldRetire only fires on the host that actually died" {
    // The two measured cases.
    try expect(shouldRetire("cyberflix.elfhosted.com",
        "https://cyberflix.elfhosted.com/manifest.json"));
    try expect(shouldRetire("knightcrawler.elfhosted.com",
        "https://knightcrawler.elfhosted.com/manifest.json"));
    // A user who re-pointed the id at their own instance keeps it: same id,
    // different host. Retiring this would delete working user config.
    try expect(!shouldRetire("knightcrawler.elfhosted.com",
        "http://192.168.1.10:7000/manifest.json"));
    try expect(!shouldRetire("cyberflix.elfhosted.com",
        "https://cyberflix.example.net/manifest.json"));
    // A debrid-substituted URL still carries the host, so it must still match.
    try expect(shouldRetire("knightcrawler.elfhosted.com",
        "https://knightcrawler.elfhosted.com/realdebrid/ABC123/manifest.json"));
    // No value on disk for that field is NOT grounds to delete a keyed
    // retirement — the file may hold a different field entirely.
    try expect(!shouldRetire("cyberflix.elfhosted.com", ""));
    // Empty host = the consumer is gone; no endpoint can revive it.
    try expect(shouldRetire("", "https://kickasstorrents.to"));
    try expect(shouldRetire("", ""));
}

test "the retirement table is well-formed" {
    // Each id must be usable as a filename, or uninstallById silently no-ops
    // and the dead source lives on.
    for (RETIRED) |r| {
        try expect(validId(r.id));
        try expect(r.field.len > 0 and r.field.len <= MAX_FIELD_LEN);
        try expect(r.why.len > 0);
    }
    // No duplicate ids — a second entry for one id would be dead config.
    for (RETIRED, 0..) |a, i| {
        for (RETIRED[i + 1 ..]) |b| try expect(!std.mem.eql(u8, a.id, b.id));
    }
}

test "versionNewer: an install predating versioning is always upgraded" {
    // No _v key at all -> empty string. This is every source installed before
    // this change shipped, including the ones pinned to yts.mx.
    try expect(versionNewer("1.0.0", ""));
    try expect(versionNewer("1.1.0", ""));
    // Garbage parses as 0 rather than erroring, so it still upgrades.
    try expect(versionNewer("1.0.0", "not-a-version"));
    // But an empty manifest version never triggers a rewrite loop.
    try expect(!versionNewer("", "1.0.0"));
    try expect(!versionNewer("", ""));
}
