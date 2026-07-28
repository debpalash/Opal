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
