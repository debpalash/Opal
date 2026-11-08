//! Shared iOS composition for physical devices and the arm64 Simulator.
const std = @import("std");
const dvui_build = @import("dvui");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const simulator = b.option(bool, "simulator", "Build for the arm64 iOS Simulator") orelse false;
    const native_cache = if (simulator) ".zig-cache/ios-native-simulator" else ".zig-cache/ios-native";
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .aarch64, .os_tag = .ios, .abi = if (simulator) .simulator else .none, .os_version_min = .{ .semver = .{ .major = 17, .minor = 0, .patch = 0 } } } });
    if (target.result.os.tag != .ios or (target.result.abi == .simulator) != simulator) @panic("iOS target does not match the requested device/Simulator build");
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    const sdk = b.option([]const u8, "sdk-root", "iphoneos SDK from xcrun --sdk iphoneos --show-sdk-path") orelse @panic("Pass -Dsdk-root=<iphoneos SDK>");
    const includes: std.Build.LazyPath = .{ .cwd_relative = b.fmt("{s}/usr/include", .{sdk}) };
    const frameworks: std.Build.LazyPath = .{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) };
    const libraries: std.Build.LazyPath = .{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) };
    const dep = b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3, .system_include_path = includes, .system_framework_path = frameworks, .library_path = libraries });
    // Allow Zig to fetch SDL3 before asking DVUI for its published artifacts.
    if (b.graph.needed_lazy_dependencies.count() != 0) return;
    const mod = b.createModule(.{ .root_source_file = b.path("src/ios.zig"), .target = target, .optimize = optimize, .link_libc = true });
    mod.addImport("dvui", dep.module("dvui_sdl3"));
    mod.addImport("icons", b.dependency("icons", .{}).module("icons"));
    const bindings: Translator = .init(b.dependency("translate_c", .{}), .{
        .name = "opal-native-c",
        .c_source_file = b.path("src/mobile/native_bindings.h"),
        .target = target,
        .optimize = optimize,
    });
    bindings.addIncludePath(dep.namedLazyPath("sdl3_include"));
    bindings.addIncludePath(b.path(b.fmt("{s}/frameworks/Libmpv-GPL/Libmpv.framework/Headers", .{native_cache})));
    bindings.addIncludePath(b.path("src"));
    bindings.addIncludePath(b.path("ort"));
    bindings.addSystemIncludePath(includes);
    mod.addImport("opal-native-c", bindings.mod);
    const options = b.addOptions();
    options.addOption(bool, "headless", false);
    options.addOption([]const u8, "app_version", "0.9.3-ios-dev");
    options.addOption([]const u8, "tmdb_default_token", "");
    options.addOption([]const u8, "omdb_default_key", "");
    mod.addOptions("build_options", options);
    const ocr_options = b.addOptions();
    ocr_options.addOption(bool, "has_ocr", false);
    mod.addOptions("ocr_build_options", ocr_options);
    inline for (.{ "repeat_pure", "fmt_compat", "enum_compat" }, .{ "repeat", "fmt", "reflect" }) |file, name| {
        mod.addImport("opal-" ++ name, b.createModule(.{ .root_source_file = b.path("src/core/" ++ file ++ ".zig"), .target = target, .optimize = optimize }));
    }
    mod.addIncludePath(dep.namedLazyPath("sdl3_include"));
    mod.addSystemIncludePath(includes);
    mod.addIncludePath(b.path(b.fmt("{s}/frameworks/Libmpv-GPL/Libmpv.framework/Headers", .{native_cache})));
    mod.addIncludePath(b.path("src/core/sqlite"));
    mod.addCSourceFile(.{ .file = b.path("src/core/sqlite/sqlite-vec.c"), .flags = &.{ "-DSQLITE_CORE", "-O2" } });
    const lib = b.addLibrary(.{ .name = "opal_ios", .root_module = mod });
    lib.bundle_compiler_rt = true;
    lib.bundle_ubsan_rt = false;
    lib.root_module.strip = true;
    const step = b.step("lib", "Build Opal and SDL3 static libraries for an iPhone/iPad");
    alignedLibrary(b, lib, "libopal_ios.a", step);
    alignedLibrary(b, dep.artifact("SDL3"), "libSDL3.a", step);
    step.dependOn(&b.addInstallDirectory(.{ .source_dir = dep.namedLazyPath("sdl3_include"), .install_dir = .prefix, .install_subdir = "include" }).step);
    b.default_step.dependOn(step);
}
fn alignedLibrary(b: *std.Build, lib: *std.Build.Step.Compile, name: []const u8, step: *std.Build.Step) void {
    const ar = b.addSystemCommand(&.{ b.graph.zig_exe, "ar", "qcLs", "--format=darwin" });
    const output = ar.addOutputFileArg(name);
    ar.addArtifactArg(lib);
    step.dependOn(&b.addInstallLibFile(output, name).step);
}
