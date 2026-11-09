//! Test root for src/mobile/android_pure.zig (it imports across src/ subdirs,
//! so its module root must be src/).
test {
    _ = @import("mobile/android_pure.zig");
    _ = @import("core/platform_pure.zig");
}
