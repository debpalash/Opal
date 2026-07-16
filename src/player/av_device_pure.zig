//! Pure (no-IO) parser for mpv's `audio-device-list` property. mpv returns the
//! node list as a JSON array of objects: `[{"name":"auto","description":
//! "Autoselect device"}, ...]`. This module extracts name/description pairs
//! into fixed-size buffers (see CLAUDE.md: fixed buffers, not slices) so the
//! device picker (ui/pickers.zig) and the Settings Playback list share the
//! SAME parsing — and so it is unit-testable without crossing the mpv /
//! io_global boundary (CLAUDE.md *_pure discipline).
//!
//! The parser is deliberately forgiving: truncated JSON, oversized values and
//! unknown keys must never crash — worst case we surface fewer devices.

const std = @import("std");

/// More outputs than any sane machine exposes; extras are silently dropped.
pub const max_devices = 32;
pub const name_cap = 128;
pub const desc_cap = 160;

pub const AudioDevice = struct {
    name: [name_cap]u8 = [_]u8{0} ** name_cap,
    name_len: usize = 0,
    desc: [desc_cap]u8 = [_]u8{0} ** desc_cap,
    desc_len: usize = 0,

    pub fn nameSlice(self: *const AudioDevice) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn descSlice(self: *const AudioDevice) []const u8 {
        return self.desc[0..self.desc_len];
    }
    /// What a row should show: the human description, or the raw device name
    /// when mpv gave no description.
    pub fn label(self: *const AudioDevice) []const u8 {
        return if (self.desc_len > 0) self.descSlice() else self.nameSlice();
    }
};

const StringScan = struct { end: usize, len: usize, closed: bool };

/// Scan a JSON string starting just AFTER its opening quote. Unescapes
/// `\"` `\\` `\/` (and maps `\n` `\t` `\r`); `\uXXXX` is skipped (device
/// labels are effectively ASCII — losing an exotic codepoint beats crashing).
/// Output truncates at `out.len` but scanning continues to the closing quote
/// so the caller's cursor stays in sync. `closed == false` means the input
/// ended mid-string (truncated JSON).
fn scanString(json: []const u8, start: usize, out: []u8) StringScan {
    var i = start;
    var n: usize = 0;
    while (i < json.len) {
        const ch = json[i];
        if (ch == '"') return .{ .end = i, .len = n, .closed = true };
        if (ch == '\\') {
            if (i + 1 >= json.len) break; // dangling escape at end of input
            const esc = json[i + 1];
            if (esc == 'u') {
                i = @min(json.len, i + 6); // backslash + u + 4 hex digits
                continue;
            }
            const mapped: u8 = switch (esc) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                else => esc, // covers \" \\ \/ — copy the escaped char itself
            };
            if (n < out.len) {
                out[n] = mapped;
                n += 1;
            }
            i += 2;
            continue;
        }
        if (n < out.len) {
            out[n] = ch;
            n += 1;
        }
        i += 1;
    }
    return .{ .end = json.len, .len = n, .closed = false };
}

/// Parse mpv's `audio-device-list` JSON into `out`. Returns the number of
/// devices written (an entry needs at least a "name"). Never allocates,
/// never panics on malformed/truncated input — committed entries survive.
pub fn parseAudioDevices(json: []const u8, out: []AudioDevice) usize {
    var count: usize = 0;
    var cur: AudioDevice = .{};
    var in_obj = false;
    var have_name = false;
    var key_buf: [24]u8 = undefined;
    var key_len: usize = 0;
    var expecting_value = false; // saw `"key":` — next string is its value
    var discard: [1]u8 = undefined; // sink for values of keys we ignore

    var i: usize = 0;
    while (i < json.len) : (i += 1) {
        switch (json[i]) {
            '{' => {
                in_obj = true;
                cur = .{};
                have_name = false;
                key_len = 0;
                expecting_value = false;
            },
            '}' => {
                if (in_obj and have_name) {
                    if (count >= out.len) return count;
                    out[count] = cur;
                    count += 1;
                }
                in_obj = false;
            },
            ':' => {
                if (key_len > 0) expecting_value = true;
            },
            ',' => {
                key_len = 0;
                expecting_value = false;
            },
            '"' => {
                if (!in_obj) {
                    // Stray top-level string — skip it wholesale.
                    const s = scanString(json, i + 1, discard[0..0]);
                    if (!s.closed) return count;
                    i = s.end;
                } else if (!expecting_value) {
                    const s = scanString(json, i + 1, key_buf[0..]);
                    if (!s.closed) return count;
                    key_len = s.len;
                    i = s.end;
                } else {
                    const key = key_buf[0..key_len];
                    if (std.mem.eql(u8, key, "name")) {
                        const s = scanString(json, i + 1, cur.name[0..]);
                        if (!s.closed) return count;
                        cur.name_len = s.len;
                        have_name = true;
                        i = s.end;
                    } else if (std.mem.eql(u8, key, "description")) {
                        const s = scanString(json, i + 1, cur.desc[0..]);
                        if (!s.closed) return count;
                        cur.desc_len = s.len;
                        i = s.end;
                    } else {
                        const s = scanString(json, i + 1, discard[0..0]);
                        if (!s.closed) return count;
                        i = s.end;
                    }
                    expecting_value = false;
                    key_len = 0;
                }
            },
            else => {},
        }
    }
    return count;
}

// ── Tests ──

test "parses typical mpv output including the auto entry" {
    const json =
        \\[{"name":"auto","description":"Autoselect device"},{"name":"coreaudio","description":"Default (coreaudio)"},{"name":"coreaudio/AppleUSBAudioEngine:1a2b","description":"MacBook Pro Speakers"}]
    ;
    var devs: [max_devices]AudioDevice = undefined;
    const n = parseAudioDevices(json, &devs);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("auto", devs[0].nameSlice());
    try std.testing.expectEqualStrings("Autoselect device", devs[0].descSlice());
    try std.testing.expectEqualStrings("coreaudio", devs[1].nameSlice());
    try std.testing.expectEqualStrings("coreaudio/AppleUSBAudioEngine:1a2b", devs[2].nameSlice());
    try std.testing.expectEqualStrings("MacBook Pro Speakers", devs[2].descSlice());
    try std.testing.expectEqualStrings("MacBook Pro Speakers", devs[2].label());
}

test "handles escaped quotes and backslashes in coreaudio descriptions" {
    const json =
        \\[{"name":"coreaudio/x","description":"John\"s \"Studio\" DAC \\ HDMI"}]
    ;
    var devs: [4]AudioDevice = undefined;
    const n = parseAudioDevices(json, &devs);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("John\"s \"Studio\" DAC \\ HDMI", devs[0].descSlice());
}

test "key order does not matter and unknown keys are ignored" {
    const json =
        \\[{"description":"Headphones","vendor":"acme","name":"alsa/hw:0,3"}]
    ;
    var devs: [4]AudioDevice = undefined;
    const n = parseAudioDevices(json, &devs);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("alsa/hw:0,3", devs[0].nameSlice());
    try std.testing.expectEqualStrings("Headphones", devs[0].descSlice());
}

test "empty list and empty/garbage input yield zero devices" {
    var devs: [4]AudioDevice = undefined;
    try std.testing.expectEqual(@as(usize, 0), parseAudioDevices("[]", &devs));
    try std.testing.expectEqual(@as(usize, 0), parseAudioDevices("", &devs));
    try std.testing.expectEqual(@as(usize, 0), parseAudioDevices("not json at all", &devs));
    // Entry without a name is dropped, not committed half-empty.
    try std.testing.expectEqual(@as(usize, 0), parseAudioDevices(
        \\[{"description":"nameless"}]
    , &devs));
}

test "truncated JSON must not crash and keeps committed entries" {
    var devs: [4]AudioDevice = undefined;
    // Cut mid-value: first entry already committed, second dropped.
    const cut_mid_string =
        \\[{"name":"auto","description":"Autoselect device"},{"name":"coreaudio","description":"MacBook P
    ;
    try std.testing.expectEqual(@as(usize, 1), parseAudioDevices(cut_mid_string, &devs));
    try std.testing.expectEqualStrings("auto", devs[0].nameSlice());
    // Cut mid-object before the closing brace: entry not committed.
    const cut_mid_object =
        \\[{"name":"auto","description":"Autoselect device"
    ;
    try std.testing.expectEqual(@as(usize, 0), parseAudioDevices(cut_mid_object, &devs));
    // Dangling escape at the very end.
    try std.testing.expectEqual(@as(usize, 0), parseAudioDevices(
        \\[{"name":"a\
    , &devs));
}

test "overflow clamps: more devices than capacity, overlong values truncate" {
    var two: [2]AudioDevice = undefined;
    const json =
        \\[{"name":"a","description":"A"},{"name":"b","description":"B"},{"name":"c","description":"C"}]
    ;
    try std.testing.expectEqual(@as(usize, 2), parseAudioDevices(json, &two));
    try std.testing.expectEqualStrings("b", two[1].nameSlice());

    // A name longer than name_cap truncates but the entry (and any entry
    // after it) still parses cleanly.
    var big: [512]u8 = undefined;
    var pos: usize = 0;
    const head = "[{\"name\":\"";
    @memcpy(big[pos..][0..head.len], head);
    pos += head.len;
    @memset(big[pos..][0 .. name_cap + 40], 'x');
    pos += name_cap + 40;
    const tail = "\",\"description\":\"long\"},{\"name\":\"tail\"}]";
    @memcpy(big[pos..][0..tail.len], tail);
    pos += tail.len;
    var devs: [4]AudioDevice = undefined;
    const n = parseAudioDevices(big[0..pos], &devs);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(usize, name_cap), devs[0].name_len);
    try std.testing.expectEqualStrings("tail", devs[1].nameSlice());
}
