//! Remote JSON projection of the shared media identity (media_identity_pure).
//!
//! Every row the web UI can act on carries one `"identity"` object in the
//! canonical shape, so the browser groups, labels, and guards selections with
//! the same rules the native app uses instead of re-deriving them in JS.

const std = @import("std");
const mi = @import("media_identity_pure.zig");
const wire = @import("remote_http.zig");
const resolver = @import("resolver.zig");
const state = @import("../core/state.zig");

/// Typed catalog fields (kept for existing clients) plus the identity object.
pub fn writeSearchRow(w: *std.Io.Writer, item: *const resolver.ResolvedItem) !void {
    if (item.source == .tmdb and item.catalog_id != 0) {
        try w.writeAll(",\"media\":\"");
        wire.writeJsonString(w, item.catalog_kind[0..@min(item.catalog_kind_len, item.catalog_kind.len)]);
        try w.print("\",\"id\":{d},\"imdb\":\"", .{item.catalog_id});
        wire.writeJsonString(w, item.catalog_imdb[0..@min(item.catalog_imdb_len, item.catalog_imdb.len)]);
        try w.writeAll("\"");
    }
    try w.writeAll(",\"identity\":");
    try mi.writeJson(w, resolver.identityCard(item));
}

/// A downloaded file: the browser can stream it from /stream (subject to
/// codec support), and a desktop host can open it too — two real targets.
pub fn fileCard(name: []const u8) mi.Card {
    return .{
        .identity = .{ .kind = .other, .local = std.hash.Wyhash.hash(0x66696c65, name) },
        .targets = .{ .here = mi.hereFor(name), .opal = !state.app.is_headless },
    };
}

pub fn writeFile(w: *std.Io.Writer, name: []const u8, is_dir: bool) !void {
    if (is_dir) return;
    try w.writeAll(",\"identity\":");
    try mi.writeJson(w, fileCard(name));
}
