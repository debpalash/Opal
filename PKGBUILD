# Maintainer: pal <pal@users.noreply.github.com>
# Opal — packaging name `zigzag` (the compiled binary); AUR search uses `zigzag`.
#
# Build from a clean checkout:
#   makepkg -f                 # local build (uses THIS directory as source)
# AUR publish:
#   - bump pkgver, run updpkgsums, push to ssh://aur@aur.archlinux.org/zigzag.git

pkgname=zigzag
pkgver=0.1.0
pkgrel=1
pkgdesc="All-in-one media suite — torrent streaming, video player, manga reader, cam grid, AI assistant"
arch=('x86_64')
url="https://github.com/debpalash/Opal"
license=('MIT')

# ── Runtime deps (must be present to RUN the app) ────────────────────────
depends=(
    'mpv'
    'sdl2'
    'sqlite'
    'libtorrent-rasterbar'
    'curl'
    'python'
    'python-pip'
    'ffmpeg'
    'yt-dlp'
)
# ── Build deps ───────────────────────────────────────────────────────────
makedepends=(
    'zig>=0.15.2'
    'gcc'
    'git'
)
# ── Optional features ────────────────────────────────────────────────────
optdepends=(
    'streamlink: live stream resolution'
    'python-camoufox: stealth browser scraping (pip install camoufox)'
    'onnxruntime: OCR bubble detection (-Docr=true build flag)'
)
provides=('zigzag')
conflicts=('zigzag')

# ── Sources ──────────────────────────────────────────────────────────────
# For AUR publishing: pull from the release tag/tarball of the project.
# Local builds: replace source=() with empty and run makepkg from the repo
# root (so $startdir == repo root).
_source_remote=(
    "${pkgname}::git+${url}#tag=v${pkgver}"
    'dvui-sdl-zig0.16.patch::file://scripts/patches/dvui-sdl-zig0.16.patch'
)
# Auto-detect: empty source=() means "build from local directory" (startdir
# layout). When publishing to AUR, swap to _source_remote.
if [[ -f "src/main.zig" ]]; then
    source=()
    sha256sums=()
else
    source=("${_source_remote[@]}")
    # sha256sums filled in by `updpkgsums` / `makepkg -g`
    sha256sums=('SKIP' 'SKIP')
fi

# ── Prepare: apply Zig 0.16 / dvui compat patch to the vendored dependency
# This runs AFTER `zig build` has fetched the dvui dep into zig-pkg/, AND on
# fresh source. We do the fetch lazily in build() below and re-apply the patch.
prepare() {
    cd "${startdir}"
    # Bring the patch into the build dir if AUR fetched it separately
    if [[ -f "${srcdir}/dvui-sdl-zig0.16.patch" ]]; then
        cp "${srcdir}/dvui-sdl-zig0.16.patch" scripts/patches/dvui-sdl-zig0.16.patch 2>/dev/null || true
    fi
}

# ── Build: compile C++ wrapper, fetch Zig deps, apply patch, build binary ──
build() {
    cd "${startdir}"

    # 1. Compile the C++ libtorrent wrapper shared library
    echo "==> Compiling libtorrent_wrapper.so..."
    g++ -std=c++17 -O3 -shared -fPIC \
        src/torrent_wrapper.cpp \
        -o libtorrent_wrapper.so \
        -ltorrent-rasterbar

    # 2. Fetch Zig dependencies (first invocation fails compile against
    #    unpatched dvui — that's expected; we just need the dep extracted).
    echo "==> Fetching Zig deps (initial compile may fail — that's OK)..."
    zig build -fsys=sdl2 -Doptimize=ReleaseSafe 2>&1 || true

    # 3. Apply vendored dvui patches (Zig 0.16 compatibility)
    echo "==> Applying vendored patches..."
    if [[ -x scripts/apply-patches.sh ]]; then
        ./scripts/apply-patches.sh
    fi

    # 4. Build the actual binary with the patched dependency
    echo "==> Building zigzag (ReleaseSafe) with system SDL2..."
    zig build -fsys=sdl2 -Doptimize=ReleaseSafe 2>&1 | tee /tmp/opal-build.log
    # Filter LLD "warning(link)" which Zig 0.16 escalates to an error
    # when using the bundled static SDL2 — -fsys=sdl2 avoids this entirely.
    if ! [[ -f zig-out/bin/zigzag ]]; then
        echo "ERROR: zig build failed — no binary produced"
        return 1
    fi
}

# ── Package: install binary, libs, scripts, desktop entry ─────────────────
package() {
    cd "${startdir}"

    local instdir="${pkgdir}/opt/zigzag"
    local bindir="${pkgdir}/usr/bin"

    # ── Core binary ──
    install -Dm755 zig-out/bin/zigzag "${instdir}/zigzag"

    # ── Shared libraries ──
    install -Dm755 libtorrent_wrapper.so "${instdir}/libtorrent_wrapper.so"

    # ── ORT (OCR support — headers + C source for runtime compilation) ──
    install -dm755 "${instdir}/ort"
    install -Dm644 ort/ocr_ort.c   "${instdir}/ort/ocr_ort.c"
    install -Dm644 ort/ocr_ort.h   "${instdir}/ort/ocr_ort.h"

    # ── Camoufox bridge (stealth browser) ──
    install -Dm755 scripts/camoufox_bridge.py "${instdir}/camoufox_bridge.py"

    # ── Dep installer (lets users repair missing runtime deps post-install) ──
    install -Dm755 scripts/install-deps.sh "${instdir}/install-deps.sh"

    # ── Launcher script (sets up library paths, auto-installs missing deps)──
    install -dm755 "${bindir}"
    cat > "${pkgdir}/usr/bin/zigzag" << 'LAUNCHER'
#!/bin/bash
# ZigZag launcher — auto-repair missing runtime deps, then run.
export ZIGZAG_HOME="/opt/zigzag"
export LD_LIBRARY_PATH="/opt/zigzag${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="/opt/zigzag:$PATH"

# Ensure user config dir
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/zigzag"

# If a runtime lib/binary is missing, give the user a one-shot helper.
missing=0
for soname in libSDL2-2.0.so.0 libmpv.so.2 libsqlite3.so.0 libtorrent-rasterbar.so.2.0; do
    if ! ldconfig -p 2>/dev/null | grep -q "$soname"; then missing=1; break; fi
done
for bin in mpv ffmpeg yt-dlp curl; do
    command -v "$bin" >/dev/null 2>&1 || { missing=1; break; }
done
if [[ "$missing" -eq 1 ]]; then
    echo "ZigZag: missing system libraries/binary detected." >&2
    echo "  Run: sudo /opt/zigzag/install-deps.sh" >&2
    echo "  Or if missing persists, report at https://github.com/debpalash/Opal/issues" >&2
fi

exec /opt/zigzag/zigzag "$@"
LAUNCHER
    chmod 755 "${pkgdir}/usr/bin/zigzag"

    # ── Desktop entry ──
    install -Dm644 /dev/stdin "${pkgdir}/usr/share/applications/zigzag.desktop" << 'DESKTOP'
[Desktop Entry]
Type=Application
Name=ZigZag
GenericName=Media Suite
Comment=All-in-one media suite — torrent streaming, video player, manga reader, AI assistant
Exec=zigzag
Icon=zigzag
Terminal=false
Categories=AudioVideo;Video;Player;
Keywords=media;torrent;streaming;video;manga;
StartupNotify=true
StartupWMClass=zigzag
DESKTOP

    # ── Icon (SVG) ──
    install -Dm644 /dev/stdin "${pkgdir}/usr/share/icons/hicolor/scalable/apps/zigzag.svg" << 'ICON'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#0e0e14"/>
      <stop offset="100%" stop-color="#1c1c26"/>
    </linearGradient>
    <linearGradient id="accent" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#468caa"/>
      <stop offset="100%" stop-color="#5fa0b9"/>
    </linearGradient>
  </defs>
  <rect width="128" height="128" rx="24" fill="url(#bg)"/>
  <path d="M32 38 L96 38 L56 64 L96 64 L32 90 L72 64 L32 64 Z"
        fill="url(#accent)" opacity="0.95"/>
</svg>
ICON

    # ── License ──
    install -Dm644 LICENSE "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
}