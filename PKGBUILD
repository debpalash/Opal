# Maintainer: pal
pkgname=zigzag
pkgver=0.1.0
pkgrel=1
pkgdesc="All-in-one media suite — torrent streaming, video player, manga reader, cam grid, AI assistant"
arch=('x86_64')
url="https://github.com/pal/zigzag"
license=('MIT')
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
provides=('zigzag')
conflicts=('zigzag')

# For local builds — override with actual git source for AUR publishing
source=()
sha256sums=()

# ── Build from local source (for local installs) ──
# When publishing to AUR, replace this with proper git source

build() {
    cd "${startdir}"

    # 1. Compile the C++ torrent wrapper shared library
    echo "==> Compiling libtorrent_wrapper.so..."
    g++ -std=c++17 -O3 -shared -fPIC \
        src/torrent_wrapper.cpp \
        -o libtorrent_wrapper.so \
        -ltorrent-rasterbar

    # 2. Build the Zig binary
    echo "==> Building zigzag with zig build..."
    zig build -Doptimize=ReleaseSafe 2>&1 || true
    # The "error: warning(link)" from LLD is cosmetic — binary is produced
    
    if [ ! -f zig-out/bin/zigzag ]; then
        echo "ERROR: zig build failed — no binary produced"
        return 1
    fi
}

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
    install -Dm755 camoufox_bridge.py "${instdir}/camoufox_bridge.py"

    # ── Launcher script (sets up library paths) ──
    install -dm755 "${bindir}"
    cat > "${pkgdir}/usr/bin/zigzag" << 'LAUNCHER'
#!/bin/bash
# ZigZag launcher — sets library paths for bundled .so files
export LD_LIBRARY_PATH="/opt/zigzag${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export ZIGZAG_HOME="/opt/zigzag"

# Ensure user config directory
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/zigzag"

exec /opt/zigzag/zigzag "$@"
LAUNCHER
    chmod 755 "${pkgdir}/usr/bin/zigzag"

    # ── Desktop entry ──
    install -Dm644 /dev/stdin "${pkgdir}/usr/share/applications/zigzag.desktop" << 'DESKTOP'
[Desktop Entry]
Type=Application
Name=ZigZag
GenericName=Media Suite
Comment=All-in-one media suite — torrent streaming, video player, manga reader
Exec=zigzag
Icon=zigzag
Terminal=false
Categories=AudioVideo;Video;Player;
Keywords=media;torrent;streaming;video;manga;
StartupNotify=true
StartupWMClass=zigzag
DESKTOP

    # ── Icon (generate a simple SVG) ──
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
    install -Dm644 /dev/stdin "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE" << 'LICENSE'
MIT License

Copyright (c) 2024-2026 ZigZag Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
LICENSE
}
