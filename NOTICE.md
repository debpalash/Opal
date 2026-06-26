# NOTICE

Opal ("Play everything"; binary and config directory named `zigzag`) is a native,
local-first media runtime. This file lists the third-party components Opal
links against, bundles, or downloads on demand, along with their licenses.

## License of Opal's own source

Opal's own source code is licensed under **GPL-3.0**. This copyleft choice is
driven primarily by Opal's linkage against **libmpv**, which is distributed
under the GPL by most platforms. Because the combined binary links GPL-covered
mpv, a permissive license for the whole work is not defensible, and GPL-3.0 is
the standard, compatible choice for an mpv-linked media application. This
decision can be revisited by the maintainer if the mpv linkage situation
changes (for example, switching to a strictly LGPL-built mpv or replacing the
playback backend).

## Third-party components

| Component | License | Notes |
| --- | --- | --- |
| mpv (libmpv) | GPLv2+ / LGPLv2.1+ (commonly GPL as distro-built) | Core video/audio playback via `linkSystemLibrary("mpv")`. GPL linkage is the dominant licensing constraint and the reason Opal ships under GPL-3.0. |
| libtorrent-rasterbar | BSD-3-Clause | Magnet/`.torrent` streaming, wrapped by `src/torrent_wrapper.cpp` → `libtorrent_wrapper.so` to isolate the C++ ABI. |
| dvui | MIT | Immediate-mode GUI (debpalash/dvui fork), vendored as a git dependency in `build.zig.zon`; uses the dvui_sdl2 backend. |
| onnxruntime | MIT | Local ML inference and the `ort/ocr_ort.c` PP-OCR pipeline via `linkSystemLibrary("onnxruntime")`. |
| SDL2 | zlib | Window/input/rendering backend; bundled (X11-only) on macOS, or system SDL2 (`-fsys=sdl2`) for Wayland. |
| sqlite3 | Public Domain | Local unified database at `~/.config/zigzag/zigzag.db` (watch history, AI memory, config, caches). |
| sqlite-vec | Apache-2.0 OR MIT (dual) | Vendored C in `src/core/sqlite/sqlite-vec.c`; `vec0` virtual table with `float[768]` embeddings for AI memory vector search. |
| zig-lib-icons (TVG icons) | MIT | UI icons, git dependency (nat3github/zig-lib-icons) in `build.zig.zon`. |
| whisper.cpp (ggml) | MIT | STT via `whisper-cli` + ggml models, downloaded from HuggingFace at runtime (not vendored). |
| sherpa-onnx (k2-fsa) | Apache-2.0 | Optional STT/TTS models (Whisper-tiny, Piper-VITS, Kokoro, streaming Zipformer), downloaded on demand from GitHub releases. |
| yt-dlp | Unlicense | YouTube and playlist extraction; system or auto-downloaded binary, used via mpv's ytdl-hook. |
| qBittorrent search engine plugins | MIT (some adapted from GPL qBittorrent plugins; original terms preserved — see `engines/LICENSE_NOTICE`) | Bundled Python scrapers in `engines/engines/*.py`, run via the `engines/nova2.py` subprocess harness. |
| streamlink | BSD-2-Clause | Live-stream HLS resolution (Twitch/Kick/etc.), invoked as an external Python tool via `scripts/streamlink_resolve.py`. |

## macOS system frameworks

On macOS, Opal links Apple system frameworks (CoreServices, AVFoundation,
Cocoa, and others) provided by the operating system under Apple's standard SDK
and platform license terms.

## Attribution

Each component remains under its own license and copyright. Refer to the
upstream projects for full license texts. Nothing in this NOTICE modifies the
terms under which those components are distributed.
