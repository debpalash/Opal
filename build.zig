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
        // Native Now Playing card + hardware media keys (MPNowPlayingInfoCenter
        // / MPRemoteCommandCenter) — see src/macos/media_remote.m and its Zig
        // side src/player/media_remote.zig.
        exe.root_module.addCSourceFile(.{
            .file = b.path("src/macos/media_remote.m"),
            .flags = &[_][]const u8{ "-fobjc-arc", "-O2" },
        });
        exe.root_module.linkFramework("MediaPlayer", .{});
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
    // pkg-config supplies the TLS-backend defines the wrapper needs: since
    // libtorrent-rasterbar 2.0.13, config.hpp enables TORRENT_USE_RTC (WebRTC)
    // and hard-errors unless TORRENT_USE_OPENSSL/GNUTLS is also defined to match
    // how libtorrent was built. pkg-config --cflags emits the right -D flags
    // (and --libs the matching -lssl/-lcrypto); we keep -I{prefix}/include for
    // boost and a trailing -ltorrent-rasterbar as an empty-pkg-config fallback.
    const compile_cmd = if (target.result.os.tag == .macos)
        b.fmt("if [ ! -f libtorrent_wrapper.so ] || [ src/torrent_wrapper.cpp -nt libtorrent_wrapper.so ]; then echo 'Compiling C++ torrent wrapper...'; g++ -std=c++17 -O3 -shared -fPIC -I{s}/include $(pkg-config --cflags libtorrent-rasterbar 2>/dev/null) -L{s}/lib src/torrent_wrapper.cpp -o libtorrent_wrapper.so $(pkg-config --libs libtorrent-rasterbar 2>/dev/null) -ltorrent-rasterbar; fi", .{ brew_prefix, brew_prefix })
    else if (is_windows)
        b.fmt("if [ ! -f torrent_wrapper.dll ] || [ src/torrent_wrapper.cpp -nt torrent_wrapper.dll ]; then echo 'Compiling C++ torrent wrapper...'; g++ -std=c++17 -O3 -shared -I{s}/include -L{s}/lib src/torrent_wrapper.cpp -o torrent_wrapper.dll -ltorrent-rasterbar -lws2_32 -liphlpapi -lcrypt32; fi", .{ mingw_prefix, mingw_prefix })
    else
        // -Wl,-soname is REQUIRED: without it the .so has no SONAME, so the
        // linker records the ABSOLUTE build path (/src/libtorrent_wrapper.so)
        // as the exe's DT_NEEDED — which breaks the moment the binary runs
        // anywhere but the build dir (the Docker runtime stage failed exactly
        // this way). With a SONAME the NEEDED is just the name, resolved via
        // rpath / ldconfig (/usr/local/lib) wherever it's installed.
        "if [ ! -f libtorrent_wrapper.so ] || [ src/torrent_wrapper.cpp -nt libtorrent_wrapper.so ]; then echo 'Compiling C++ torrent wrapper...'; g++ -std=c++17 -O3 -shared -fPIC -Wl,-soname,libtorrent_wrapper.so $(pkg-config --cflags libtorrent-rasterbar 2>/dev/null) src/torrent_wrapper.cpp -o libtorrent_wrapper.so $(pkg-config --libs libtorrent-rasterbar 2>/dev/null) -ltorrent-rasterbar; fi";

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

    // OCR via ONNX Runtime (PP-OCR pipeline) — optional, gated by -Docr.
    // Default off: onnxruntime isn't a standard Arch/Debian package and the
    // manga/video frame OCR features are only used by a subset of users.
    // Build with `-Docr=true` to enable (requires `onnxruntime` installed:
    // Arch: `pacman -S onnxruntime-cpu`, macOS: `brew install onnxruntime`).
    const enable_ocr = b.option(bool, "ocr", "Enable OCR via ONNX Runtime (default: auto-detect)") orelse false;
    if (enable_ocr) {
        exe.root_module.addCSourceFile(.{
            .file = b.path("ort/ocr_ort.c"),
            .flags = &[_][]const u8{ "-O2", "-Wno-unused-result" },
        });
        exe.root_module.addIncludePath(b.path("ort"));
        exe.root_module.addLibraryPath(b.path("ort"));
        if (is_windows) {
            // ONNXRUNTIME_DIR: root of a vendored Microsoft onnxruntime release
            // (github.com/microsoft/onnxruntime, onnxruntime-win-x64-<ver>.zip —
            // include/*.h + lib/onnxruntime.{lib,dll}). MSYS2 has no onnxruntime
            // package for the MINGW64 environment, and the UCRT64 one links a
            // different CRT than zig's x86_64-windows-gnu output — mixing them is
            // what produced the "entry point strtod could not be located" launch
            // failure in v0.1.0 (issue #3). The MS build is MSVC-compiled but
            // exposes a pure C ABI, and its onnxruntime.lib is a plain COFF
            // import lib that zig's lld links fine from the gnu target.
            if (b.graph.environ_map.get("ONNXRUNTIME_DIR")) |ort_dir| {
                exe.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{ort_dir}) });
                exe.root_module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/onnxruntime.lib", .{ort_dir}) });
            } else {
                // No vendored dir: fall back to a MinGW-built import lib under
                // MINGW_PREFIX for anyone who has one (see the mpv/sqlite3 note
                // above on why .dll.a needs addObjectFile).
                exe.root_module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libonnxruntime.dll.a", .{mingw_prefix}) });
            }
        } else {
            exe.root_module.linkSystemLibrary("onnxruntime", .{});
            exe.root_module.addRPath(b.path("ort"));
        }
    }
    // Surface OCR availability to the app source via `@import("ocr_build_options")`.
    const ocr_build_options = b.addOptions();
    ocr_build_options.addOption(bool, "has_ocr", enable_ocr);
    exe.root_module.addOptions("ocr_build_options", ocr_build_options);

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

    // Control-bar drop-ups: anchored-above / right-aligned / clamp-to-window
    // placement math + the click-outside hit test (ui/pickers.zig routes every
    // popover through it).
    const test_dropup_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ui/dropup_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_dropup_pure).step);

    // Audio EQ preset → af spec, video-filter clamp, download-limit sanitize —
    // the persist-and-replay mapping shared by settings.zig + player.zig init.
    const test_av_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/player/av_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_av_pure).step);

    // YouTube browse: suggestion-JSON parse, channel-URL validation, duration/
    // view-count formatting — youtube.zig routes through these.
    const test_youtube_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/youtube_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_youtube_pure).step);

    // Winamp-style audio visualisers: the mpv lavfi-complex filter graph. Pure
    // because a theme colour is spliced into an ffmpeg graph — it must be
    // validated, not interpolated — and because every style has to keep
    // `asplit [ao]` or the visualiser silently costs you the audio.
    const test_visualizer_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/player/visualizer_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_visualizer_pure).step);

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

    // `lists` anime source plugin: anime-airing.json → anime index rows.
    const test_anime_lists_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/anime_lists_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_anime_lists_pure).step);

    // AniList metadata parsing (Page.media[] iterator + malformed-JSON regression).
    const test_anilist_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/anilist_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_anilist_pure).step);

    // Podcasts: iTunes JSON + podcast RSS episode parsing (malformed regressions).
    const test_podcasts_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/podcasts_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_podcasts_pure).step);

    // Internet Radio: RadioBrowser station-search JSON parsing (numeric fields +
    // url_resolved/url fallback + malformed-JSON regressions).
    const test_radio_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/radio_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_radio_pure).step);

    // Jellyfin image-proxy URL building + item-id validation (SSRF/injection
    // gate for the web /api/jellyfin/poster proxy).
    const test_jellyfin_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/jellyfin_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_jellyfin_pure).step);

    // Unified Downloads list: the merge/dedup identity ladder. A finished torrent
    // exists in all three sources at once (seeding + on disk + in history), so the
    // list must fold it into ONE row — while NEVER collapsing two different
    // releases that share a title (a wrong merge mis-attributes pause/delete).
    const test_transfers_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/transfers_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_transfers_pure).step);

    // Comics sources — MangaDex URL building + allocation-free JSON scanning.
    // The ids land straight in a request path, so isValidId() is a security gate;
    // the parsers must also survive a truncated body and must never confuse
    // `"data"` with `"dataSaver"` (wrong image set) or an author relationship
    // with `cover_art` (wrong cover).
    const test_comics_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/comics_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_comics_pure).step);

    // TV tracking engine — the single definition of "what do I watch next?".
    // Next-up must cross season boundaries, return the GAP rather than the
    // frontier, and clamp to what has actually aired (TMDB's episode_count
    // counts announced episodes, so an unclamped search invents a phantom
    // episode that Resume would then hunt for on an indexer).
    const test_tv_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/tv_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_tv_pure).step);

    // Resource meters: thresholds, clamping and formatting. A NaN reaching a bar's
    // width draws a garbage rect; a divide-by-zero on a machine reporting 0 total
    // RAM must not become an infinite bar; and a media player DECODING VIDEO must
    // not light the meter red, or people learn to ignore it.
    const test_sysmon_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/sysmon_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_sysmon_pure).step);

    // Torrent streaming readiness: WHAT each container makes the demuxer read
    // before it can open a file. An MKV's Cues + Tags sit at EOF, so a 33%-
    // downloaded file never starts unless the tail is fetched too — head progress
    // is irrelevant. MP4 needs its moov (which +faststart puts at the front, so no
    // tail at all); AVI needs idx1; MPEG-TS needs nothing.
    const test_container_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/player/container_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_container_pure).step);

    // EZTV release calendar: feed-URL building + a STRING-AWARE parse of the
    // get-torrents payload (a '}' or an escaped '"' inside a release title must
    // not split the object and mis-pair fields across torrents — same class of
    // bug as the FROM/HotD id corruption), plus the live relative-time label
    // that the render site recomputes from the stored epoch every frame.
    const test_eztv_calendar_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/eztv_calendar_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_eztv_calendar_pure).step);

    // Onboarding wizard paging — Back/Next saturate at both ends and a stale
    // replayed index can't dead-end the tour (the modal is GUI-only; this is
    // the pure decision logic it routes through).
    const test_onboarding_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ui/onboarding_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_onboarding_pure).step);

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

    // Internet Archive JSON parsing: advancedsearch docs[] iteration
    // (order-independent id/title/year) + metadata files[] best-video pick +
    // a malformed-JSON regression case.
    const test_archive_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/archive_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_archive_pure).step);

    // NASA images-api JSON parsing: search items[] iteration (asset href/title/
    // year, pagination-link exclusion) + collection.json best-mp4 pick +
    // malformed-JSON regression. Reuses archive_pure's field extractors.
    const test_nasa_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/nasa_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_nasa_pure).step);

    // Wikimedia Commons JSON parsing: query.pages{} iteration (title/url/mime/
    // size/duration, File: prefix strip, descriptionurl disambiguation) +
    // malformed-JSON regression. Reuses archive_pure's field extractors.
    const test_commons_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/commons_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_commons_pure).step);

    // Wikipedia trivia lookup: disambiguated-title building + JSON extract
    // parsing (rejects disambiguation pages / too-short extracts).
    const test_wikipedia_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/wikipedia_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_wikipedia_pure).step);

    // Device-aware display scale: DPI-tier → default ui_scale + clamp bounds.
    const test_scale_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/scale_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_scale_pure).step);

    // Media file classification: playable vs executable/archive (torrent
    // file auto-selection safety).
    const test_media_ext = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/media_ext.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_media_ext).step);

    // Browser media streaming: HTTP Range parsing, content types, SRT→VTT.
    const test_remote_stream_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/remote_stream_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_remote_stream_pure).step);

    // TV calendar: air-date math, countdown labels, TMDB next-episode parse,
    // EZTV availability extraction.
    const test_tv_calendar_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/tv_calendar_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_tv_calendar_pure).step);

    // TVmaze keyless enrichment: show-id extraction, next-episode + episode
    // air-date parsing (nested _links objects), airs-label formatting,
    // malformed-JSON regression.
    const test_tvmaze_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/tvmaze_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_tvmaze_pure).step);

    // OMDb ratings enrichment: real IMDb / RT / Metacritic parse from the OMDb
    // body (Ratings[] source matching, Metacritic "88/100" → "88", N/A → absent),
    // IMDb-id extraction + normalization, scores/details formatting, and a
    // malformed-JSON + missing-fields regression.
    const test_omdb_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/omdb_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_omdb_pure).step);

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

    // Torznab/Prowlarr/Jackett XML item parsing: order-independent torznab:attr
    // extraction, magnet/enclosure/link selection, malformed-XML regression.
    const test_torznab_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/services/torznab_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_torznab_pure).step);

    // macOS media-key bridge: remote-command decode + Control Center seek
    // clamp + Now Playing playback rate (media_remote.zig routes the polled
    // commands through these).
    const test_media_remote_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/player/media_remote_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_media_remote_pure).step);

    // mpv audio-device-list JSON parsing (audio output picker): escaped
    // quotes, truncated input, capacity clamps. ui/pickers.zig and the
    // Settings Playback device list both route through this parser.
    const test_av_device_pure = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/player/av_device_pure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(test_av_device_pure).step);

    // voice_backend.zig imports ../core/io_global which crosses the
    // src/ module boundary — skip its standalone test for now. The
    // interface/dispatch logic is covered indirectly when the main
    // exe builds + runs.
}
