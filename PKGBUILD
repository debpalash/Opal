# Maintainer: pal
pkgname=opal
pkgver=0.1.1
pkgrel=1
pkgdesc="All-in-one media suite — torrent streaming, video player, manga reader, cam grid, AI assistant"
arch=('x86_64')
url="https://github.com/debpalash/Opal"
license=('GPL-3.0-only')
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
makedepends=(
    'zig>=0.15.2'
    'gcc'
    'git'
)
optdepends=(
    'streamlink: live stream resolution'
    'python-camoufox: stealth browser scraping'
    'onnxruntime: OCR bubble detection'
)
conflicts=('zigzag')
replaces=('zigzag')

# For local builds — override with actual git source for AUR publishing
source=()
sha256sums=()

# ── Build from local source (for local installs) ──
# When publishing to AUR, replace source=() with a git tag/tarball.
# OCR (onnxruntime-cpu) is OFF by default — optdepends line above lists the
# extra runtime dep; build with `zig build -Docr=true` to enable it.

build() {
    cd "${startdir}"

    # 1. Compile the C++ torrent wrapper shared library
    echo "==> Compiling libtorrent_wrapper.so..."
    g++ -std=c++17 -O3 -shared -fPIC \
        src/torrent_wrapper.cpp \
        -o libtorrent_wrapper.so \
        -ltorrent-rasterbar

    # 2. Build the Zig binary. `-fsys=sdl2` links the SYSTEM SDL2 (sdl2-compat
    #    / SDL3) instead of dvui's bundled static SDL2 — the bundled one has
    #    archive members that trip LLD's "neither ET_REL nor LLVM bitcode"
    #    warnings into errors under zig 0.16, blocking the build entirely.
    echo "==> Building opal (ReleaseSafe) with system SDL2..."
    zig build -fsys=sdl2 -Doptimize=ReleaseSafe

    if [ ! -f zig-out/bin/opal ]; then
        echo "ERROR: zig build failed — no binary produced"
        return 1
    fi
}

package() {
    cd "${startdir}"

    local instdir="${pkgdir}/opt/opal"
    local bindir="${pkgdir}/usr/bin"

    # ── Core binary ──
    install -Dm755 zig-out/bin/opal "${instdir}/opal"

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

    # ── Launcher script (sets up library paths, hints at deps self-repair) ──
    install -dm755 "${bindir}"
    cat > "${pkgdir}/usr/bin/opal" << 'LAUNCHER'
#!/bin/bash
# Opal launcher — auto-detect missing system libs and point users to the
# bundled repair script, then run the app.
export OPAL_HOME="/opt/opal"
export LD_LIBRARY_PATH="/opt/opal${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="/opt/opal:$PATH"

# Ensure user config directory
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/opal"

# Probe for missing runtime libs/bins (one-shot, ~5ms).
missing=0
ld_cache="$(ldconfig -p 2>/dev/null || true)"
for soname in libSDL2-2.0.so.0 libmpv.so.2 libsqlite3.so.0 libtorrent-rasterbar.so.2.0; do
    if [[ "$ld_cache" != *"$soname"* ]]; then missing=1; break; fi
done
if [[ "$missing" -eq 0 ]]; then
    for bin in mpv ffmpeg yt-dlp curl; do
        command -v "$bin" >/dev/null 2>&1 || { missing=1; break; }
    done
fi
if [[ "$missing" -eq 1 ]]; then
    echo "Opal: missing system libraries/binary detected." >&2
    echo "  Repair with: sudo /opt/opal/install-deps.sh" >&2
    echo "  Or install manually — see PKGBUILD optdepends/depends list." >&2
fi

exec /opt/opal/opal "$@"
LAUNCHER
    chmod 755 "${pkgdir}/usr/bin/opal"

    # ── Desktop entry ──
    install -Dm644 /dev/stdin "${pkgdir}/usr/share/applications/opal.desktop" << 'DESKTOP'
[Desktop Entry]
Type=Application
Name=Opal
GenericName=Media Suite
Comment=All-in-one media suite — torrent streaming, video player, manga reader
Exec=opal
Icon=opal
Terminal=false
Categories=AudioVideo;Video;Player;
Keywords=media;torrent;streaming;video;manga;
StartupNotify=true
StartupWMClass=opal
DESKTOP

    # ── Icon (the opal mark — assets/logo.svg) ──
    install -Dm644 assets/logo.svg "${pkgdir}/usr/share/icons/hicolor/scalable/apps/opal.svg"

    # ── License (GPL-3.0 — ship the repo's actual LICENSE, not an embedded copy) ──
    install -Dm644 LICENSE "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
}
