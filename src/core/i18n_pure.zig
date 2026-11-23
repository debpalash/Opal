//! UI string table: compile-time keys, per-locale tables, locale negotiation,
//! plural and format helpers. Pure (no Io, no allocation) so the shipped lookup
//! is the tested lookup. Runtime state lives in `i18n.zig`.
//!
//! `locales/en.zig` is the source of truth: `Key` is derived from its fields,
//! so English always has every key. Every other locale is partial; a key it
//! lacks falls back along its tag chain (`pt-BR` -> `pt` -> `en`). A locale
//! that names a key English does not have is a compile error.
const std = @import("std");

const en_strings = @import("locales/en.zig").strings;

pub const Key = std.meta.FieldEnum(@TypeOf(en_strings));
pub const key_count = @typeInfo(Key).@"enum".field_names.len;

pub const LocaleDef = struct {
    tag: []const u8,
    /// Autonym shown in the picker. Never translated.
    name: []const u8,
    strings: Table,
};

/// One slot per key; `null` means "not translated here".
pub const Table = [key_count]?[]const u8;

/// Shipping locales. Index 0 must be English (the final fallback).
pub const locales = [_]LocaleDef{
    .{ .tag = "en", .name = "English", .strings = table(en_strings) },
    .{ .tag = "es", .name = "Español", .strings = table(@import("locales/es.zig").strings) },
};
pub const locale_count = locales.len;

/// Fully resolved per-locale tables: every slot is filled at compile time by
/// walking the fallback chain, so `t()` is one array index per call.
pub const resolved: [locale_count][key_count][]const u8 = blk: {
    @setEvalBranchQuota(200_000);
    var tags: [locale_count][]const u8 = undefined;
    var tables: [locale_count]*const Table = undefined;
    for (locales, 0..) |l, i| {
        tags[i] = l.tag;
        tables[i] = &l.strings;
    }
    var out: [locale_count][key_count][]const u8 = undefined;
    for (0..locale_count) |li| {
        var chain_buf: [max_chain]usize = undefined;
        const chain = localeChain(&tags, locales[li].tag, &chain_buf);
        for (0..key_count) |ki| out[li][ki] = lookup(&tables, chain, @enumFromInt(ki));
    }
    break :blk out;
};

comptime {
    if (!std.mem.eql(u8, locales[0].tag, "en")) @compileError("locales[0] must be English");
}

/// Build a table from a locale's anonymous struct of strings. Unknown keys are
/// a compile error, so no locale can carry keys English lacks.
pub fn table(comptime strings: anytype) Table {
    @setEvalBranchQuota(200_000);
    var out: Table = @splat(null);
    for (@typeInfo(@TypeOf(strings)).@"struct".field_names) |name| {
        if (!@hasField(@TypeOf(en_strings), name))
            @compileError("locale key '" ++ name ++ "' is not in locales/en.zig");
        const key: Key = @field(Key, name);
        out[@intFromEnum(key)] = @field(strings, name);
    }
    return out;
}

/// First table in `chain` (indices into `tables`) that has `key`; English
/// (`tables[0]`) is the last resort. English is complete by construction, so
/// the empty-string branch only guards a hand-built test table.
pub fn lookup(tables: []const *const Table, chain: []const usize, key: Key) []const u8 {
    for (chain) |i| if (tables[i][@intFromEnum(key)]) |s| return s;
    return tables[0][@intFromEnum(key)] orelse "";
}

pub const max_chain = 4;

/// Indices of `available` tags to consult for `tag`, most specific first,
/// always ending in English (index 0). `pt-BR` -> [pt-BR?, pt?, en].
pub fn localeChain(available: []const []const u8, tag: []const u8, out: *[max_chain]usize) []const usize {
    var n: usize = 0;
    var cur = tag;
    while (cur.len > 0 and n < max_chain - 1) {
        if (indexOf(available, cur)) |i| {
            if (i != 0) {
                out[n] = i;
                n += 1;
            }
        }
        const dash = std.mem.lastIndexOfScalar(u8, cur, '-') orelse break;
        cur = cur[0..dash];
    }
    out[n] = 0;
    return out[0 .. n + 1];
}

fn indexOf(available: []const []const u8, tag: []const u8) ?usize {
    for (available, 0..) |a, i| if (std.ascii.eqlIgnoreCase(a, tag)) return i;
    return null;
}

/// Normalize a POSIX locale (`pt_BR.UTF-8@euro`) or BCP 47 tag (`pt-br`) to
/// `pt-BR`. `C`/`POSIX`/empty/garbage normalize to "" (meaning English).
pub fn normalize(raw: []const u8, buf: []u8) []const u8 {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.indexOfAny(u8, s, ".@:")) |cut| s = s[0..cut];
    if (s.len == 0 or s.len > buf.len or std.mem.eql(u8, s, "C") or std.ascii.eqlIgnoreCase(s, "POSIX")) return "";
    var seg: usize = 0;
    var seg_start: usize = 0;
    for (s, 0..) |ch, i| {
        if (ch == '_' or ch == '-') {
            if (i == seg_start) return "";
            buf[i] = '-';
            seg += 1;
            seg_start = i + 1;
            continue;
        }
        if (!std.ascii.isAlphanumeric(ch)) return "";
        // Language lowercase; a 2-letter region uppercase; scripts/variants as-is lowercase.
        const seg_len = (std.mem.indexOfAnyPos(u8, s, seg_start, "-_") orelse s.len) - seg_start;
        buf[i] = if (seg > 0 and seg_len == 2) std.ascii.toUpper(ch) else std.ascii.toLower(ch);
    }
    if (seg_start == s.len) return "";
    return buf[0..s.len];
}

/// Pick a shipping locale for a raw preference (config value, LANG, or a
/// browser's Accept-Language/`navigator.language`). Returns an index into
/// `available`; 0 (English) when nothing matches.
pub fn negotiate(available: []const []const u8, raw: []const u8) usize {
    var buf: [32]u8 = undefined;
    // Accept-Language lists: take the first entry, drop any q-value.
    const first = std.mem.sliceTo(std.mem.sliceTo(raw, ','), ';');
    const tag = normalize(first, &buf);
    var chain_buf: [max_chain]usize = undefined;
    return localeChain(available, tag, &chain_buf)[0];
}

/// The system locale source: the first of LC_ALL / LC_MESSAGES / LANG that
/// names a real locale, else the platform preference (macOS AppleLanguages,
/// e.g. "es-ES"; apps launched from Finder have no LANG). `C`/`POSIX`/empty
/// env values count as unset so a bare `LANG=C` shell still follows the OS.
pub fn pickSystemLocale(env: []const ?[]const u8, platform: []const u8) []const u8 {
    var buf: [32]u8 = undefined;
    for (env) |maybe| if (maybe) |v| {
        if (normalize(v, &buf).len > 0) return v;
    };
    return platform;
}

pub fn shippingTags() [locale_count][]const u8 {
    var out: [locale_count][]const u8 = undefined;
    for (locales, 0..) |l, i| out[i] = l.tag;
    return out;
}

pub const Plural = enum { one, other };

/// CLDR cardinal category for the languages we ship or are likely to ship.
/// Unknown languages use the English rule.
pub fn pluralCategory(tag: []const u8, n: u64) Plural {
    const lang = std.mem.sliceTo(tag, '-');
    const no_plural = [_][]const u8{ "ja", "zh", "ko", "vi", "th", "id" };
    for (no_plural) |l| if (std.ascii.eqlIgnoreCase(lang, l)) return .other;
    const zero_is_one = [_][]const u8{ "fr", "pt" };
    for (zero_is_one) |l| if (std.ascii.eqlIgnoreCase(lang, l)) return if (n <= 1) .one else .other;
    return if (n == 1) .one else .other;
}

/// Substitute `{0}`..`{9}` with `args` into `buf`. Unknown or out-of-range
/// placeholders are copied literally; output truncates at `buf.len`.
pub fn format(buf: []u8, template: []const u8, args: []const []const u8) []const u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < template.len and w < buf.len) {
        if (template[i] == '{' and i + 2 < template.len and template[i + 2] == '}' and std.ascii.isDigit(template[i + 1])) {
            const arg = template[i + 1] - '0';
            if (arg < args.len) {
                const n = @min(args[arg].len, buf.len - w);
                @memcpy(buf[w..][0..n], args[arg][0..n]);
                w += n;
                i += 3;
                continue;
            }
        }
        buf[w] = template[i];
        w += 1;
        i += 1;
    }
    return buf[0..w];
}

// ── tests ──────────────────────────────────────────────────────────────

fn testTable(comptime strings: anytype) Table {
    return comptime table(strings);
}

test "missing key falls back to English" {
    const en = testTable(.{ .nav_search = "Search", .nav_queue = "Queue" });
    const es = testTable(.{ .nav_search = "Buscar" });
    const tables = [_]*const Table{ &en, &es };
    var chain_buf: [max_chain]usize = undefined;
    const chain = localeChain(&.{ "en", "es" }, "es", &chain_buf);
    try std.testing.expectEqualStrings("Buscar", lookup(&tables, chain, .nav_search));
    try std.testing.expectEqualStrings("Queue", lookup(&tables, chain, .nav_queue));
}

test "pt-BR falls back to pt and then en" {
    const en = testTable(.{ .nav_search = "Search", .nav_queue = "Queue", .nav_history = "History" });
    const pt = testTable(.{ .nav_search = "Pesquisar", .nav_queue = "Fila" });
    const pt_br = testTable(.{ .nav_search = "Buscar" });
    const tables = [_]*const Table{ &en, &pt, &pt_br };
    const tags = [_][]const u8{ "en", "pt", "pt-BR" };
    var chain_buf: [max_chain]usize = undefined;
    const chain = localeChain(&tags, "pt-BR", &chain_buf);
    try std.testing.expectEqualSlices(usize, &.{ 2, 1, 0 }, chain);
    try std.testing.expectEqualStrings("Buscar", lookup(&tables, chain, .nav_search));
    try std.testing.expectEqualStrings("Fila", lookup(&tables, chain, .nav_queue));
    try std.testing.expectEqualStrings("History", lookup(&tables, chain, .nav_history));
    // Without a pt-BR table, pt-BR negotiates to pt; without pt, to en.
    try std.testing.expectEqual(@as(usize, 1), negotiate(&.{ "en", "pt" }, "pt_BR.UTF-8"));
    try std.testing.expectEqual(@as(usize, 0), negotiate(&.{ "en", "es" }, "pt-BR"));
}

test "locale negotiation normalizes POSIX and browser tags" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("pt-BR", normalize("pt_BR.UTF-8", &buf));
    try std.testing.expectEqualStrings("es-ES", normalize("es_es@euro", &buf));
    try std.testing.expectEqualStrings("zh-hant-TW", normalize("zh-Hant-TW", &buf));
    try std.testing.expectEqualStrings("", normalize("C.UTF-8", &buf));
    try std.testing.expectEqualStrings("", normalize("POSIX", &buf));
    try std.testing.expectEqualStrings("", normalize("en_", &buf));
    try std.testing.expectEqualStrings("", normalize("../x", &buf));
    const tags = shippingTags();
    try std.testing.expectEqual(@as(usize, 1), negotiate(&tags, "es-MX,es;q=0.9,en;q=0.5"));
    try std.testing.expectEqual(@as(usize, 1), negotiate(&tags, "ES"));
    try std.testing.expectEqual(@as(usize, 0), negotiate(&tags, "fr_FR.UTF-8"));
    try std.testing.expectEqual(@as(usize, 0), negotiate(&tags, ""));
}

test "macOS Finder launch with no LANG follows the platform language" {
    const tags = shippingTags();
    // Finder launch: no env at all.
    try std.testing.expectEqualStrings("es-ES", pickSystemLocale(&.{ null, null, null }, "es-ES"));
    try std.testing.expectEqual(@as(usize, 1), negotiate(&tags, pickSystemLocale(&.{ null, null, null }, "es-ES")));
    // LANG=C / empty LC_ALL do not mask the OS preference.
    try std.testing.expectEqualStrings("es-419", pickSystemLocale(&.{ "", null, "C.UTF-8" }, "es-419"));
    // A real env locale wins over the platform, in LC_ALL > LC_MESSAGES > LANG order.
    try std.testing.expectEqualStrings("pt_BR.UTF-8", pickSystemLocale(&.{ null, "pt_BR.UTF-8", "es_ES.UTF-8" }, "es"));
    try std.testing.expectEqualStrings("en_US.UTF-8", pickSystemLocale(&.{ "en_US.UTF-8", "es_ES", null }, "es"));
    // Nothing anywhere: English.
    try std.testing.expectEqual(@as(usize, 0), negotiate(&tags, pickSystemLocale(&.{ null, null, null }, "")));
}

test "shipping tables resolve every key and Spanish overrides English" {
    for (resolved) |tbl| for (tbl) |s| try std.testing.expect(s.len > 0);
    try std.testing.expectEqualStrings("Search", resolved[0][@intFromEnum(Key.nav_search)]);
    try std.testing.expectEqualStrings("Buscar", resolved[1][@intFromEnum(Key.nav_search)]);
    // Brand-free chrome strings must all be translated in Spanish.
    var translated: usize = 0;
    for (locales[1].strings) |s| translated += @intFromBool(s != null);
    try std.testing.expectEqual(key_count, translated);
}

test "plural categories follow CLDR for shipped and fallback languages" {
    try std.testing.expectEqual(Plural.one, pluralCategory("en", 1));
    try std.testing.expectEqual(Plural.other, pluralCategory("en", 0));
    try std.testing.expectEqual(Plural.other, pluralCategory("es-MX", 2));
    try std.testing.expectEqual(Plural.one, pluralCategory("pt-BR", 0));
    try std.testing.expectEqual(Plural.one, pluralCategory("fr", 1));
    try std.testing.expectEqual(Plural.other, pluralCategory("ja", 1));
}

test "format substitutes positional args and truncates safely" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("3 of 7", format(&buf, "{0} of {1}", &.{ "3", "7" }));
    try std.testing.expectEqualStrings("{1} x", format(&buf, "{1} {0}", &.{"x"}));
    try std.testing.expectEqualStrings("{a}", format(&buf, "{a}", &.{"x"}));
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqualStrings("abcd", format(&tiny, "{0}", &.{"abcdef"}));
}
