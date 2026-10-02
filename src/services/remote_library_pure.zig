//! Revision-scoped Watching projection. Polling copies only the requested page.
const std = @import("std");
const model = @import("tv_pure.zig");

pub const Sort = enum { smart, recent, title, progress };
pub const Selection = struct {
    filter: model.Filter = .all,
    kind: model.KindFilter = .all,
    sort: Sort = .smart,
};
pub const Page = struct { count: usize, total: usize, catalog_total: usize, offset: usize };

fn progress(row: *const model.Row) f32 {
    return if (row.prog.total > 0) row.prog.fraction() else row.pct / 100.0;
}
fn lessThan(sort: Sort, a: model.Row, b: model.Row) bool {
    return switch (sort) {
        .smart => model.lessThan(&a, &b),
        .recent => if (a.updated_at != b.updated_at) a.updated_at > b.updated_at else std.mem.lessThan(u8, a.nameSlice(), b.nameSlice()),
        .title => std.ascii.lessThanIgnoreCase(a.nameSlice(), b.nameSlice()),
        .progress => if (progress(&a) != progress(&b)) progress(&a) > progress(&b) else std.mem.lessThan(u8, a.nameSlice(), b.nameSlice()),
    };
}

pub const Projection = struct {
    rows: [model.MAX_SHOWS]model.Row = undefined,
    count: usize = 0,
    catalog_total: usize = 0,
    revision: u32 = 0,
    selection: Selection = .{},
    valid: bool = false,

    pub fn matches(self: *const Projection, revision: u32, selection: Selection) bool {
        return self.valid and self.revision == revision and std.meta.eql(self.selection, selection);
    }
    pub fn rebuild(self: *Projection, rows: []const model.Row, revision: u32, selection: Selection) void {
        self.count = 0;
        self.catalog_total = rows.len;
        self.revision = revision;
        self.selection = selection;
        for (rows) |row| {
            if (!model.matchesFilter(&row, selection.filter) or !model.matchesKind(&row, selection.kind)) continue;
            if (self.count == self.rows.len) break;
            self.rows[self.count] = row;
            self.count += 1;
        }
        std.mem.sort(model.Row, self.rows[0..self.count], selection.sort, lessThan);
        self.valid = true;
    }
    pub fn page(self: *const Projection, offset: usize, out: []model.Row) Page {
        const start = @min(offset, self.count);
        const count = @min(out.len, self.count - start);
        @memcpy(out[0..count], self.rows[start..][0..count]);
        return .{ .count = count, .total = self.count, .catalog_total = self.catalog_total, .offset = start };
    }
};

/// Token scopes the revision to the exact request. Changing a page or selector
/// cannot accidentally suppress its response using another page's token.
pub fn version(revision: u32, selection: Selection, offset: usize, limit: usize, out: []u8) ?[]const u8 {
    return std.fmt.bufPrint(out, "{d}:{s}:{s}:{s}:{d}:{d}", .{ revision, @tagName(selection.filter), @tagName(selection.kind), @tagName(selection.sort), offset, limit }) catch null;
}

/// JSON escaping can expand each byte to six bytes. Capacity follows the
/// public projection, not sizeof(Row), which includes unrelated binary state.
pub fn jsonCapacity(count: usize) usize {
    const row: model.Row = .{};
    return 1024 + count * ((row.name.len + row.id.len + row.poster_url.len) * 6 + 512);
}

test "Watching projection caches only the same revision and selector, pages actual filtered rows" {
    const cache = try std.testing.allocator.create(Projection);
    defer std.testing.allocator.destroy(cache);
    cache.* = .{};
    var rows: [3]model.Row = .{ .{}, .{}, .{} };
    const names = [_][]const u8{ "Zebra", "alpha", "Beta" };
    for (&rows, names) |*row, name| {
        @memcpy(row.name[0..name.len], name);
        row.name_len = name.len;
    }
    cache.rebuild(&rows, 7, .{ .sort = .title });
    try std.testing.expect(cache.matches(7, .{ .sort = .title }));
    try std.testing.expect(!cache.matches(8, .{ .sort = .title }));
    try std.testing.expect(!cache.matches(7, .{ .sort = .recent }));
    var out: [1]model.Row = undefined;
    const page = cache.page(1, &out);
    try std.testing.expectEqualStrings("Beta", out[0].nameSlice());
    try std.testing.expectEqual(@as(usize, 3), page.total);
    try std.testing.expectEqual(@as(usize, 1), page.count);
    try std.testing.expectEqual(@as(usize, 0), cache.page(99, &out).count);
}

test "Watching response version scopes filters and page identity" {
    var a: [128]u8 = undefined;
    var b: [128]u8 = undefined;
    const first = version(9, .{}, 0, 48, &a).?;
    try std.testing.expect(!std.mem.eql(u8, first, version(9, .{}, 48, 48, &b).?));
    try std.testing.expect(!std.mem.eql(u8, first, version(10, .{}, 0, 48, &b).?));
    try std.testing.expect(!std.mem.eql(u8, first, version(9, .{ .sort = .title }, 0, 48, &b).?));
}

test "Watching cached projection preserves metadata, actual filters, and empty totals" {
    const cache = try std.testing.allocator.create(Projection);
    defer std.testing.allocator.destroy(cache);
    cache.* = .{};
    var rows: [3]model.Row = .{
        .{ .kind = .movie, .user = .watching, .status = .watching, .pct = 30 },
        .{ .kind = .tv, .user = .watching, .status = .watching, .tmdb_id = 42, .has_next = true, .next = .{ .season = 2, .episode = 3 } },
        .{ .kind = .tv, .user = .completed, .status = .completed },
    };
    rows[1].setName("Tracked show");
    rows[1].setPosterUrl("https://images.example/show.jpg");
    cache.rebuild(&rows, 4, .{ .filter = .watching, .kind = .tv });
    rows[1].tmdb_id = 0;
    var out: [2]model.Row = undefined;
    const page = cache.page(0, &out);
    try std.testing.expectEqual(@as(usize, 1), page.count);
    try std.testing.expectEqual(@as(usize, 1), page.total);
    try std.testing.expectEqual(@as(usize, 3), page.catalog_total);
    try std.testing.expectEqual(@as(i32, 42), out[0].tmdb_id);
    try std.testing.expectEqualStrings("Tracked show", out[0].nameSlice());
    try std.testing.expectEqualStrings("https://images.example/show.jpg", out[0].poster_url[0..out[0].poster_url_len]);
    try std.testing.expectEqual(@as(i32, 3), out[0].next.episode);
    cache.rebuild(&.{}, 5, .{});
    try std.testing.expectEqual(@as(usize, 0), cache.page(0, &out).total);
}
