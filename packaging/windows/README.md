# Windows packaging

- `opal.wxs` — WiX 3 authoring for the MSI: product identity (the UpgradeCode is fixed forever — never regenerate it), per-machine install to `Program Files\Opal`, Start Menu shortcut, ARP metadata. The file payload is *not* listed here.
- `opal.ico` — multi-size (16–256px) icon rendered from `assets/logo.svg` (`rsvg-convert` per size, then `magick *.png opal.ico`). Regenerate only when the logo changes.

**DLL harvest** (see the `windows-x86_64` job in `.github/workflows/release.yml`): the job builds in MSYS2/UCRT64, copies `opal.exe` + the torrent wrapper into `staging/`, then runs `ldd` on each — ldd prints the full transitive DLL closure, and everything under `$MINGW_PREFIX` (`/ucrt64`) is copied in; Windows system DLLs are left out. The same `staging/` dir becomes both the portable zip and, via `heat.exe dir staging -cg OpalFiles`, the MSI's file fragment (`candle` + `light` link it against `opal.wxs`).

**Iterating locally on a Windows box**: install [MSYS2](https://www.msys2.org), open a *UCRT64* shell, `pacman -S mingw-w64-ucrt-x86_64-{gcc,SDL2,mpv,sqlite3,onnxruntime,libtorrent-rasterbar,pkgconf}`, put zig 0.16 on PATH, then `zig build -Doptimize=ReleaseSafe` and replay the workflow's staging/heat/candle/light steps verbatim (WiX 3.14 from wixtoolset.org if not preinstalled; note onnxruntime only exists for UCRT64/CLANG64, not MINGW64).
