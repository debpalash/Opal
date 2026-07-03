const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const headless = b.option(bool, "headless", "Build headless server (no SDL/X11 link)") orelse false;

    // Expose the headless flag to the app as a `build_options` import.
    const build_options = b.addOptions();
    build_options.addOption(bool, "headless", headless);

    const exe = b.addExecutable(.{
        .name = "opal",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.use_llvm = true;

    // System SDL2 integration. On Wayland compositors (COSMIC DE, etc.) the bundled SDL2
    // only has X11 support (runs under XWayland) and window title updates are ignored.
    // Build with: zig build -fsys=sdl2
    // This uses the system's sdl2-compat (SDL3) with native Wayland support.
    _ = b.systemIntegrationOption("sdl2", .{});
    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
    });

    // Homebrew prefix for macOS lib/include paths. Apple Silicon installs to
    // /opt/homebrew (default); Intel macs use /usr/local. `brew shellenv`
    // exports HOMEBREW_PREFIX, so honor it when set.
    const brew_prefix = b.graph.environ_map.get("HOMEBREW_PREFIX") orelse "/opt/homebrew";

    // MSYS2 MINGW64 prefix for Windows lib/include paths. MSYS2 exports
    // MINGW_PREFIX inside a MINGW64 shell (e.g. C:/msys64/mingw64); honor it
    // when set, analogous to HOMEBREW_PREFIX on macOS.
    const mingw_prefix = b.graph.environ_map.get("MINGW_PREFIX") orelse "C:/msys64/mingw64";

    const is_windows = target.result.os.tag == .windows;

    if (target.result.os.tag == .macos) {
        exe.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{brew_prefix}) });
        exe.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{brew_prefix}) });
    } else if (is_windows) {
        // Windows (MinGW/MSYS2): headers + import libs from the MINGW64 prefix.
        // dvui's bundled SDL2 supplies the SDL symbols (like macOS), so only
        // SDL2 *headers* are needed from mingw64 (mingw-w64-SDL2 package).
        exe.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{mingw_prefix}) });
        exe.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{mingw_prefix}) });
        // Aro (zig 0.16's translate-c) predefines _FORTIFY_SOURCE=2 for
        // optimized builds; the MinGW fortify inline wrappers it then pulls
        // from <wchar.h> translate into Zig that fails AstGen ("unused local
        // constant"), breaking every @cImport in ReleaseSafe/ReleaseFast.
        // Force fortify off for every module that @cImports windows headers:
        // ours, dvui's (tinyfiledialogs), and dvui's sdl backend (SDL.h).
        exe.root_module.addCMacro("_FORTIFY_SOURCE", "0");
        const dvui_mod = dvui_dep.module("dvui_sdl2");
        dvui_mod.addCMacro("_FORTIFY_SOURCE", "0");
        if (dvui_mod.import_table.get("backend")) |backend_mod| {
            backend_mod.addCMacro("_FORTIFY_SOURCE", "0");
        }
    } else {
        // Non-macOS: link system SDL2. On macOS, dvui's bundled SDL2 is used
        // (avoids duplicate-class ObjC warnings when both static + dyn SDL2 load).
        // headless (-Dheadless, non-macOS) would skip this SDL2 link, but
        // main/player/grid still import dvui unconditionally this cycle.
        // headless: full dvui/SDL removal is follow-up; keep linked so the binary still runs.
        exe.root_module.linkSystemLibrary("SDL2", .{});
    }

    // Add dvui_sdl2 which is a fully bundled standalone backend.
    // headless: full dvui/SDL removal is follow-up; keep linked so the binary still runs.
    exe.root_module.addImport("dvui", dvui_dep.module("dvui_sdl2"));

    // Expose -Dheadless to the app code via @import("build_options").
    exe.root_module.addImport("build_options", build_options.createModule());

    // Fetch and bind TVG Icons library
    const icons_dep = b.dependency("icons", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("icons", icons_dep.module("icons"));

    // Link MPV and SQLite.
    // Windows: zig's -l search for windows-gnu only tries `{name}.dll`,
    // `{name}.lib` and `lib{name}.a` — it never finds MinGW `lib{name}.dll.a`
    // import libs, so pass those explicitly as linker objects.
    if (is_windows) {
        exe.root_module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libmpv.dll.a", .{mingw_prefix}) });
        exe.root_module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libsqlite3.dll.a", .{mingw_prefix}) });
    } else {
        exe.root_module.linkSystemLibrary("mpv", .{});
        exe.root_module.linkSystemLibrary("sqlite3", .{});
    }

    // SQLite Vector DB
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/core/sqlite/sqlite-vec.c"),
        .flags = &[_][]const u8{ "-O3", "-fomit-frame-pointer" },
    });

    // Libtorrent & C++ Linkage (Dynamic Shared Object isolating GCC C++ ABIs)
    // Checking modification times avoids recompiling the heavy C++ wrapper on every `zig build` iteration.
    // Windows note: zig's windows-gnu -l search tries `torrent_wrapper.dll`
    // first and MinGW-flavored lld links directly against a DLL, so name the
    // artifact `torrent_wrapper.dll` (no `lib` prefix). MSYS2 has sh + g++.
    const compile_cmd = if (target.result.os.tag == .macos)
        b.fmt("if [ ! -f libtorrent_wrapper.so ] || [ src/torrent_wrapper.cpp -nt libtorrent_wrapper.so ]; then echo 'Compiling C++ torrent wrapper...'; g++ -std=c++17 -O3 -shared -fPIC -I{s}/include -L{s}/lib src/torrent_wrapper.cpp -o libtorrent_wrapper.so -ltorrent-rasterbar; fi", .{ brew_prefix, brew_prefix })
    else if (is_windows)
        b.fmt("if [ ! -f torrent_wrapper.dll ] || [ src/torrent_wrapper.cpp -nt torrent_wrapper.dll ]; then echo 'Compiling C++ torrent wrapper...'; g++ -std=c++17 -O3 -shared -I{s}/include -L{s}/lib src/torrent_wrapper.cpp -o torrent_wrapper.dll -ltorrent-rasterbar -lws2_32 -liphlpapi -lcrypt32; fi", .{ mingw_prefix, mingw_prefix })
    else
        "if [ ! -f libtorrent_wrapper.so ] || [ src/torrent_wrapper.cpp -nt libtorrent_wrapper.so ]; then echo 'Compiling C++ torrent wrapper...'; g++ -std=c++17 -O3 -shared -fPIC src/torrent_wrapper.cpp -o libtorrent_wrapper.so -ltorrent-rasterbar; fi";

    // Only invoke the host g++ when it can actually produce a wrapper for the
    // target (native builds). Cross-compiling (e.g. windows from macOS for a
    // semantic-analysis check) would otherwise emit a host-ABI object under the
    // target's expected name and confuse the link.
    if (b.graph.host.result.os.tag == target.result.os.tag) {
        const compile_wrapper = b.addSystemCommand(&.{ "sh", "-c", compile_cmd });
        exe.step.dependOn(&compile_wrapper.step);
    }

    exe.root_module.addLibraryPath(b.path("."));
    exe.root_module.linkSystemLibrary("torrent_wrapper", .{});
    // rpath is ELF/Mach-O only; PE resolves DLLs next to the exe at runtime.
    if (!is_windows) {
        exe.root_module.addRPath(b.path(".")); // Ensure the binary can find the locally compiled wrapper
    }
    // Packaged-install layouts (deb/rpm/.run/tarball): let the installed
    // binary find libtorrent_wrapper.so relative to itself — next to the
    // binary (tarball) or in ../lib/opal (/usr/bin + /usr/lib/opal).
    if (target.result.os.tag != .macos and !is_windows) {
        exe.root_module.addRPathSpecial("$ORIGIN");
        exe.root_module.addRPathSpecial("$ORIGIN/../lib/opal");
    }
    // For .app bundles: let the binary find libtorrent_wrapper.so in
    // Contents/Frameworks/ when launched via Finder/NSWorkspace (CWD=/).
    if (target.result.os.tag == .macos) {
        exe.root_module.addRPathSpecial("@executable_path/../Frameworks");
        // Reserve enough header space so install_name_tool can rewrite LC_LOAD_DYLIB
        // entries after the bundle is laid out (scripts/build-app.sh).
        exe.headerpad_max_install_names = true;
    }

    // OCR via ONNX Runtime (PP-OCR pipeline)
    exe.root_module.addCSourceFile(.{
        .file = b.path("ort/ocr_ort.c"),
        .flags = &[_][]const u8{ "-O2", "-Wno-unused-result" },
    });
    exe.root_module.addIncludePath(b.path("ort"));
    exe.root_module.addLibraryPath(b.path("ort"));
    if (is_windows) {
        // MinGW import lib (see the mpv/sqlite3 note above).
        exe.root_module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libonnxruntime.dll.a", .{mingw_prefix}) });
    } else {
        exe.root_module.linkSystemLibrary("onnxruntime", .{});
        exe.root_module.addRPath(b.path("ort"));
    }

    exe.root_module.addIncludePath(b.path("src"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
    // ── Fast build: use `zig build -Doptimize=ReleaseSafe` ──
    // Note: a separate exe with different optimize level causes UBSan
    // linker mismatch with dvui's bundled SDL2, so we use the standard
    // -Doptimize flag instead.

    // ── Unit Tests (pure Zig modules only) ──
    const test_step = b.step("test", "Run unit tests");

    const test_m3u = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/player/m3u.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_m3u).step);

    const test_paths = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/paths.zig"),
            .target = target,
            .optimize = optimize,
            // paths.zig uses std.c (getenv); Linux requires explicit libc.
            .link_libc = true,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_paths).step);

    const test_text = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/text.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_text).step);

    const test_voice = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/voice_filter.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_voice).step);

    const test_plugins_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/plugins_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_plugins_pure).step);

    const test_deps = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/deps_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_deps).step);

    const test_env = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/env.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_env).step);

    const test_workers = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/workers.zig"),
            .target = target,
            .optimize = optimize,
            // workers.zig pulls std.c; Linux requires explicit libc.
            .link_libc = true,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_workers).step);

    const test_chrome = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ui/chrome_autohide.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_chrome).step);

    const test_resume = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/player/resume_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_resume).step);

    // Keyless subtitle providers: media-name → query/show/season/episode parse.
    const test_subs_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/subtitles_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_subs_pure).step);

    // Anime NSFW filter: Jikan rating classification + sfw query param.
    const test_anime_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/anime_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_anime_pure).step);

    // Workspace name sanitization (path-traversal / separator neutralization).
    const test_workspace_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ui/workspace_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_workspace_pure).step);

    // Deferred-navigation slot encode/decode (u4 saturating-add regression).
    const test_nav_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/nav_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_nav_pure).step);

    const test_intent = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/ai_intent_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_intent).step);

    const test_rank = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/resolver_rank.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_rank).step);

    // TMDB pure string helpers: string-aware results splitter (FROM/HotD id-corruption
    // regression) + HTTPS→HTTP fallback rewrite.
    const test_tmdb_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/tmdb_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_tmdb_pure).step);

    // Browser pure helpers: smart address bar (host vs search heuristic),
    // query percent-encoding, keypress-vs-text forwarding (double-type
    // regression), content routing.
    const test_browser_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/browser_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_browser_pure).step);

    // JSON string unescaping (yt-dlp titles rendered "You’ve" raw).
    const test_json_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/json_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_json_pure).step);

    // Home console display helpers (hex-hash watch-history names).
    const test_home_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ui/home_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_home_pure).step);

    // Pipeline test imports ai_intent_pure + resolver_rank siblings.
    const test_pipeline = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/ai_pipeline_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_pipeline).step);

    const test_search = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/search_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_search).step);

    // Pure page-router (Route + back/forward history rings).
    const test_router = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/router.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_router).step);

    // Pure headless-mode detection (env precedence + OS gating).
    const test_headless = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/headless_detect.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_headless).step);

    // voice_backend.zig imports ../core/io_global which crosses the
    // src/ module boundary — skip its standalone test for now. The
    // interface/dispatch logic is covered indirectly when the main
    // exe builds + runs.
}
