//! Android (arm64) composition: the shared Opal app in an SDL3 host, built as
//! libmain.so for SDLActivity. See docs/android.md.
const std = @import("std");
const dvui_build = @import("dvui");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const api = b.option(u32, "api", "Android API level (default 26)") orelse 26;
    const ndk = b.option([]const u8, "ndk", "Android NDK root (default $ANDROID_NDK_ROOT)") orelse
        b.graph.environ_map.get("ANDROID_NDK_ROOT") orelse @panic("Pass -Dndk=<NDK root> or set ANDROID_NDK_ROOT");
    const prefix = b.option([]const u8, "deps-prefix", "Native deps prefix with include/ and lib/") orelse ".zig-cache/android-native/prefix";
    const version = b.option([]const u8, "version", "App version string") orelse "0.0.0-android-dev";
    const unwind = b.option([]const u8, "unwind", "NDK libunwind.a (provides _Unwind_Resume to libmain.so)");
    const extra_includes = b.option([]const []const u8, "include", "Extra include dirs (local checks)") orelse &.{};

    const target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .android, .android_api_level = api });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    // NDK sysroot, found by host tag (darwin-x86_64 locally, linux-x86_64 in CI).
    const host_tag: []const u8 = switch (@import("builtin").os.tag) {
        .macos => "darwin-x86_64",
        .linux => "linux-x86_64",
        .windows => "windows-x86_64",
        else => @panic("unsupported build host"),
    };
    const sysroot = b.fmt("{s}/toolchains/llvm/prebuilt/{s}/sysroot", .{ ndk, host_tag });
    const inc_dir = b.fmt("{s}/usr/include", .{sysroot});
    const arch_inc = b.fmt("{s}/usr/include/aarch64-linux-android", .{sysroot});
    const libc_files = b.addWriteFiles();
    const libc_file = libc_files.add("android-libc.txt", b.fmt(
        \\include_dir={s}
        \\sys_include_dir={s}
        \\crt_dir={s}/usr/lib/aarch64-linux-android/{d}
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\gcc_dir={s}/usr/lib/aarch64-linux-android/{d}
        \\darwin_sdk_dir=
        \\
    , .{ inc_dir, arch_inc, sysroot, api, sysroot, api }));

    b.addSearchPrefix(prefix);
    const prefix_include: std.Build.LazyPath = .{ .cwd_relative = b.fmt("{s}/include", .{prefix}) };

    const dep = b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3, .android_include_path = @as(std.Build.LazyPath, .{ .cwd_relative = inc_dir }) });
    // Allow Zig to fetch SDL3 before asking DVUI for its published artifacts.
    if (b.graph.needed_lazy_dependencies.count() != 0) return;
    const dvui_sdl3 = dep.module("dvui_sdl3");
    const backend = dvui_sdl3.import_table.get("backend").?;
    backend.addIncludePath(prefix_include);
    addTranslatedInclude(b, backend.import_table.get("sdl3-c").?, prefix_include);
    // -fsys=sdl3 skips dvui's own NDK wiring for the SDL namespace; repeat it.
    const sdl_translate = translateStep(b, backend.import_table.get("sdl3-c").?);
    for ([_][]const u8{ arch_inc, inc_dir }) |dir| sdl_translate.addDirectoryArg2(.{ .cwd_relative = dir }, .{ .prefix = "-isystem" });
    for (bionic_macros(b, api)) |m| sdl_translate.addArg(m);

    // With -fsys=sdl3 the headers come from the deps prefix instead.
    const sdl3_include: ?std.Build.LazyPath = if (b.systemIntegrationOption("sdl3", .{})) null else dep.namedLazyPath("sdl3_include");

    const ctx: Ctx = .{ .b = b, .target = target, .optimize = optimize, .version = version, .dvui_sdl3 = dvui_sdl3, .sdl3_include = sdl3_include, .prefix_include = prefix_include, .extra_includes = extra_includes, .api = api, .arch_inc = arch_inc, .inc_dir = inc_dir };
    const mod = appModule(ctx);
    const check_mod = appModule(ctx);

    // Local compile gate: same module as a static library, no link step.
    const check_lib = b.addLibrary(.{ .name = "opal_android_check", .linkage = .static, .root_module = check_mod });
    check_lib.setLibCFile(libc_file);
    const check = b.step("check", "Compile the Android host without linking (local gate)");
    check.dependOn(&check_lib.step);

    // libmain.so for SDLActivity.
    const so = b.addLibrary(.{ .name = "main", .linkage = .dynamic, .root_module = mod });
    so.setLibCFile(libc_file);
    // addSearchPrefix appends /lib, so the NDK's per-API dir (log, android, m,
    // dl) and its unversioned dir (libc++_shared) need explicit library paths.
    so.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{prefix}) });
    so.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib/aarch64-linux-android/{d}", .{ sysroot, api }) });
    so.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib/aarch64-linux-android", .{sysroot}) });
    // NDK clang links libunwind.a into every .so; without it _Unwind_Resume is
    // unresolved and System.loadLibrary("main") fails at launch.
    if (unwind) |path| so.root_module.addObjectFile(.{ .cwd_relative = path });
    inline for (.{ "SDL3", "mpv", "avcodec", "sqlite3", "webp", "opal_torrent", "torrent-rasterbar", "ssl", "crypto", "c++_shared", "log", "android", "m", "dl" }) |name| {
        so.root_module.linkSystemLibrary(name, .{ .use_pkg_config = .no });
    }
    const so_step = b.step("so", "Build libmain.so into <prefix>/jniLibs/arm64-v8a");
    so_step.dependOn(&b.addInstallFileWithDir(so.getEmittedBin(), .{ .custom = "jniLibs/arm64-v8a" }, "libmain.so").step);
}

/// aro's translate-c cannot parse some bionic constructs; same workarounds as
/// dvui's addAndroidLibC (declarations only, so they are safe here).
fn bionic_macros(b: *std.Build, api: u32) []const []const u8 {
    const level = b.fmt("{d}", .{api});
    return b.allocator.dupe([]const u8, &.{
        b.fmt("-D__ANDROID_API__={s}", .{level}),
        b.fmt("-D__ANDROID_MIN_SDK_VERSION__={s}", .{level}),
        "-D__clang_analyzer__=1",
        "-DBIONIC_IOCTL_NO_SIGNEDNESS_OVERLOAD=1",
        "-D_Nullable=",
        "-D_Nonnull=",
        "-D_Null_unspecified=",
    }) catch @panic("OOM");
}

fn translateStep(b: *std.Build, module: *std.Build.Module) *std.Build.Step.Run {
    const generated = module.root_source_file.?.generated;
    const step = b.graph.generated_files.items[@backingInt(generated.index)];
    return step.cast(std.Build.Step.Run) orelse @panic("C bindings must be generated by a run step");
}

fn addTranslatedInclude(b: *std.Build, module: *std.Build.Module, include: std.Build.LazyPath) void {
    module.addIncludePath(include);
    const generated = module.root_source_file.?.generated;
    const step = b.graph.generated_files.items[@backingInt(generated.index)];
    const translate = step.cast(std.Build.Step.Run) orelse @panic("C bindings must be generated by a run step");
    translate.addDirectoryArg2(include, .{ .prefix = "-I" });
}

const Ctx = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    version: []const u8,
    dvui_sdl3: *std.Build.Module,
    sdl3_include: ?std.Build.LazyPath,
    prefix_include: std.Build.LazyPath,
    extra_includes: []const []const u8,
    api: u32,
    arch_inc: []const u8,
    inc_dir: []const u8,
};

/// The Opal app module. Built twice: the check target must not carry link
/// libraries (they only resolve for the real device link).
fn appModule(ctx: Ctx) *std.Build.Module {
    const b = ctx.b;
    const target = ctx.target;
    const optimize = ctx.optimize;
    const version = ctx.version;
    const dvui_sdl3 = ctx.dvui_sdl3;
    const sdl3_include = ctx.sdl3_include;
    const prefix_include = ctx.prefix_include;
    const extra_includes = ctx.extra_includes;
    const api = ctx.api;
    const arch_inc = ctx.arch_inc;
    const inc_dir = ctx.inc_dir;
    const mod = b.createModule(.{ .root_source_file = b.path("src/android.zig"), .target = target, .optimize = optimize, .link_libc = true });
    mod.addImport("dvui", dvui_sdl3);
    mod.addImport("icons", b.dependency("icons", .{}).module("icons"));

    const bindings: Translator = .init(b.dependency("translate_c", .{}), .{
        .name = "opal-native-c",
        .c_source_file = b.path("src/mobile/native_bindings_android.h"),
        .target = target,
        .optimize = optimize,
    });
    if (sdl3_include) |p| bindings.addIncludePath(p);
    bindings.addIncludePath(prefix_include);
    bindings.addIncludePath(b.path("src"));
    bindings.addIncludePath(b.path("ort"));
    for (bionic_macros(b, api)) |m| {
        const eq = std.mem.indexOfScalar(u8, m, '=').?;
        bindings.defineCMacro(m[2..eq], m[eq + 1 ..]);
    }
    bindings.addSystemIncludePath(.{ .cwd_relative = arch_inc });
    bindings.addSystemIncludePath(.{ .cwd_relative = inc_dir });
    for (extra_includes) |dir| bindings.addIncludePath(.{ .cwd_relative = dir });
    mod.addImport("opal-native-c", bindings.mod);

    const options = b.addOptions();
    options.addOption(bool, "headless", false);
    options.addOption([]const u8, "app_version", version);
    options.addOption([]const u8, "tmdb_default_token", "");
    options.addOption([]const u8, "omdb_default_key", "");
    mod.addOptions("build_options", options);
    const ocr_options = b.addOptions();
    ocr_options.addOption(bool, "has_ocr", false);
    mod.addOptions("ocr_build_options", ocr_options);
    inline for (.{ "repeat_pure", "fmt_compat", "enum_compat" }, .{ "repeat", "fmt", "reflect" }) |file, name| {
        mod.addImport("opal-" ++ name, b.createModule(.{ .root_source_file = b.path("src/core/" ++ file ++ ".zig"), .target = target, .optimize = optimize }));
    }

    if (sdl3_include) |p| mod.addIncludePath(p);
    mod.addIncludePath(prefix_include);
    mod.addIncludePath(b.path("src/core/sqlite"));
    mod.addIncludePath(b.path("src"));
    mod.addIncludePath(b.path("ort"));
    mod.addIncludePath(b.path("mobile/android/jni"));
    mod.addSystemIncludePath(.{ .cwd_relative = arch_inc });
    mod.addSystemIncludePath(.{ .cwd_relative = inc_dir });
    for (extra_includes) |dir| mod.addIncludePath(.{ .cwd_relative = dir });
    mod.addCSourceFile(.{ .file = b.path("src/core/sqlite/sqlite-vec.c"), .flags = &.{ "-DSQLITE_CORE", "-O2" } });
    mod.addCSourceFile(.{ .file = b.path("src/core/webp_decode.c"), .flags = &.{"-O2"} });
    mod.addCSourceFile(.{ .file = b.path("mobile/android/jni/opal_android.c"), .flags = &.{"-O2"} });
    // Embedded by agent_launch_pure.zig; the Settings tab code is still analyzed.
    mod.addAnonymousImport("skill_md", .{ .root_source_file = b.path("skills/opal-media/SKILL.md") });
    mod.addAnonymousImport("agent_workspace_md", .{ .root_source_file = b.path("skills/opal-media/AGENT_WORKSPACE.md") });
    return mod;
}
