//! Stable tab identities; page engines own the live documents and history.
const std = @import("std");
pub const max_tabs = 32;
pub const Text = struct {
    bytes: [2048:0]u8 = @splat(0),
    len: usize = 0,
    pub fn set(self: *@This(), value: []const u8) void {
        var n = @min(value.len, self.bytes.len - 1);
        if (n < value.len) while (n > 0 and value[n] & 0xc0 == 0x80) {
            n -= 1;
        };
        @memcpy(self.bytes[0..n], value[0..n]);
        self.bytes[n] = 0;
        self.len = n;
    }
    pub fn text(self: *const @This()) []const u8 {
        return self.bytes[0..self.len];
    }
};
pub const Tab = struct {
    id: u32 = 0,
    url: Text = .{},
    title: Text = .{},
    last_visit: Text = .{},
    loading: bool = false,
    pinned: bool = false,
    pub fn recordVisit(self: *@This(), url: []const u8) bool {
        if (std.mem.eql(u8, url, self.last_visit.text())) return false;
        self.last_visit.set(url);
        return true;
    }
};
pub const Model = struct {
    items: [max_tabs]Tab = @splat(.{}),
    count: usize = 0,
    active: usize = 0,
    next_id: u32 = 1,
    pub fn index(self: *const @This(), id: u32) ?usize {
        for (self.items[0..self.count], 0..) |tab, i| if (tab.id == id) return i;
        return null;
    }
    pub fn create(self: *@This()) ?u32 {
        if (self.count == max_tabs) return null;
        while (self.next_id == 0 or self.index(self.next_id) != null) self.next_id +%= 1;
        const id = self.next_id;
        self.next_id +%= 1;
        self.items[self.count] = .{ .id = id };
        self.items[self.count].url.set("about:blank");
        self.active = self.count;
        self.count += 1;
        return id;
    }
    pub fn select(self: *@This(), id: u32) bool {
        self.active = self.index(id) orelse return false;
        return true;
    }
    pub fn close(self: *@This(), id: u32) bool {
        const i = self.index(id) orelse return false;
        if (self.items[i].pinned) return false;
        if (i < self.active) self.active -= 1;
        var n = i;
        while (n + 1 < self.count) : (n += 1) self.items[n] = self.items[n + 1];
        self.count -= 1;
        if (self.count == 0) {
            _ = self.create();
        } else self.active = @min(self.active, self.count - 1);
        return true;
    }
    pub fn pin(self: *@This(), id: u32, pinned: bool) bool {
        const i = self.index(id) orelse return false;
        const selected = self.current().id;
        self.items[i].pinned = pinned;
        // Stable partition keeps both groups in their existing order.
        var target: usize = 0;
        for (0..self.count) |n| {
            if (!self.items[n].pinned) continue;
            var j = n;
            while (j > target) : (j -= 1) std.mem.swap(Tab, &self.items[j], &self.items[j - 1]);
            target += 1;
        }
        _ = self.select(selected);
        return true;
    }
    pub fn cycle(self: *@This(), backwards: bool) void {
        if (self.count == 0) return;
        self.active = if (backwards) (self.active + self.count - 1) % self.count else (self.active + 1) % self.count;
    }
    pub fn current(self: *@This()) *Tab {
        return &self.items[self.active];
    }
};
test "closing inactive tabs preserves selected identity and last close creates a fresh page" {
    var model: Model = .{};
    const first = model.create().?;
    const second = model.create().?;
    const third = model.create().?;
    try std.testing.expect(model.close(first));
    try std.testing.expectEqual(third, model.current().id);
    try std.testing.expect(model.close(third));
    try std.testing.expectEqual(second, model.current().id);
    try std.testing.expect(model.close(second));
    try std.testing.expectEqual(@as(usize, 1), model.count);
    try std.testing.expect(model.current().id != second);
    try std.testing.expectEqualStrings("about:blank", model.current().url.text());
}
test "tab capacity cycling and wrapped identities remain bounded and unique" {
    var model: Model = .{};
    for (0..max_tabs) |_| _ = model.create().?;
    try std.testing.expect(model.create() == null);
    model.cycle(false);
    try std.testing.expectEqual(@as(usize, 0), model.active);
    model.cycle(true);
    try std.testing.expectEqual(max_tabs - 1, model.active);
    _ = model.close(2);
    model.next_id = 0;
    try std.testing.expectEqual(@as(u32, 2), model.create().?);
    try std.testing.expect(!model.select(99));
    try std.testing.expect(!model.close(99));
}
test "twenty browser tabs retain unique identities through repeated switching" {
    var model: Model = .{};
    for (0..20) |_| try std.testing.expect(model.create() != null);
    try std.testing.expectEqual(@as(usize, 20), model.count);
    for (0..200) |i| {
        model.cycle(i % 3 == 0);
        try std.testing.expect(model.current().id != 0);
        for (model.items[0..model.count], 0..) |tab, j| {
            for (model.items[j + 1 .. model.count]) |other| try std.testing.expect(tab.id != other.id);
        }
    }
}
test "tab activation does not duplicate visits but real navigation does" {
    var model: Model = .{};
    const a = model.create().?;
    try std.testing.expect(model.current().recordVisit("https://a.test/"));
    const b = model.create().?;
    try std.testing.expect(model.current().recordVisit("https://b.test/"));
    for (0..30) |_| {
        try std.testing.expect(model.select(a));
        try std.testing.expect(!model.current().recordVisit("https://a.test/"));
        try std.testing.expect(model.select(b));
        try std.testing.expect(!model.current().recordVisit("https://b.test/"));
    }
    try std.testing.expect(model.current().recordVisit("https://b.test/next"));
    try std.testing.expect(model.current().recordVisit("https://b.test/"));
}
test "pinned tabs stay first retain selection and resist accidental closing" {
    var model: Model = .{};
    const a = model.create().?;
    const b = model.create().?;
    const c = model.create().?;
    try std.testing.expect(model.pin(b, true));
    try std.testing.expectEqual(b, model.items[0].id);
    try std.testing.expectEqual(c, model.current().id);
    try std.testing.expect(!model.close(b));
    try std.testing.expect(model.pin(c, true));
    try std.testing.expectEqual(c, model.current().id);
    try std.testing.expect(model.pin(b, false));
    try std.testing.expectEqual(c, model.items[0].id);
    try std.testing.expectEqual(c, model.current().id);
    try std.testing.expect(model.close(b));
    try std.testing.expect(model.select(a));
}
