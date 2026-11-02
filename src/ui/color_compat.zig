const dvui = @import("dvui");
pub fn wrap(value: anytype) ?dvui.ColorOrGradient {
    const T = @TypeOf(value);
    if (T == @TypeOf(null)) return null;
    if (@typeInfo(T) == .optional) {
        if (value) |v| return wrap(v);
        return null;
    }
    if (T == dvui.ColorOrGradient) return value;
    if (T == @TypeOf(.white)) return .{ .color = @field(dvui.Color, @tagName(value)) };
    if (T == dvui.Color) return .{ .color = value };
    return .{ .color = .{ .r = value.r, .g = value.g, .b = value.b, .a = if (@hasField(T, "a")) value.a else 255 } };
}
