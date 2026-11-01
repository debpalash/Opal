const EnumField = struct { name: [:0]const u8, value: comptime_int };
const StructField = struct { name: [:0]const u8, type: type, default_value_ptr: ?*const anyopaque, is_comptime: bool };
fn Field(comptime T: type) type {
    return switch (@typeInfo(T)) { .@"enum" => EnumField, .@"struct" => StructField, else => @compileError("unsupported reflection type") };
}
pub fn fields(comptime T: type) []const Field(T) {
    const values = comptime blk: {
        const info = @typeInfo(T);
        const names = switch (info) { .@"enum" => |e| e.field_names, .@"struct" => |s| s.field_names, else => unreachable };
        var out: [names.len]Field(T) = undefined;
        for (names, 0..) |name, i| out[i] = switch (info) {
            .@"enum" => |e| .{ .name = name, .value = e.field_values[i] },
            .@"struct" => |s| .{ .name = name, .type = s.field_types[i], .default_value_ptr = s.field_attrs[i].default_value_ptr, .is_comptime = s.field_attrs[i].@"comptime" },
            else => unreachable,
        };
        break :blk out;
    };
    return &values;
}
