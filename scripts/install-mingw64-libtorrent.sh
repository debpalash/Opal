#!/usr/bin/env bash
# MSYS2 dropped libtorrent-rasterbar from the MINGW64 repo index (2026-11-20;
# it now ships only for UCRT64/CLANG64). Opal needs the MSVCRT build, so
# install the last MINGW64 package, pinned by SHA-256. It was built
# 2026-11-15 against the current MINGW64 OpenSSL 4 (libssl-4-x64.dll) and
# Boost, so its dependencies still resolve from the rolling repo.
#
# If that orphaned file is pruned from the mirror (or
# OPAL_LIBTORRENT_FROM_SOURCE=1), build the same 2.1.2 from the upstream
# release with MSYS2's own recipe (PKGBUILD patches and CMake flags), pinned
# by SHA-256 like libmpv in install-mingw64-mpv.sh.
set -euo pipefail

if [ "${MSYSTEM:-}" != MINGW64 ] || [ "${MINGW_PREFIX:-}" != /mingw64 ]; then
    echo 'This script requires the MSYS2 MINGW64 environment' >&2
    exit 1
fi

PKG=mingw-w64-x86_64-libtorrent-rasterbar-2.1.2-3-any.pkg.tar.zst
PKG_SHA256=7596336f33394ed57bd842b7c28b43083d7df7c8676d2a2e1d8854c8bd20c37d
LT_VERSION=2.1.2
LT_SHA256=3362546d9cd71b9e49ee6cac7d3f1f914ce9cdb217c86b63d5b22cbed0334dbc
# MSYS2's two upstream build fixes (one #include each), vendored: GitHub's
# commit .patch URLs return 503 to CI often enough to break the fallback.
PATCH_DIR="$(cd "$(dirname "$0")" && pwd)/patches/libtorrent"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

fetch() { # url out sha256
    curl --fail --location --retry 3 --silent --show-error --output "$2" "$1" &&
        printf '%s  %s\n' "$3" "$2" | sha256sum --check --quiet -
}

install_package() {
    fetch "https://repo.msys2.org/mingw/mingw64/$PKG" "$WORK_DIR/$PKG" "$PKG_SHA256" || return 1
    pacman -U --noconfirm --needed "$WORK_DIR/$PKG"
}

build_from_source() {
    echo "Building libtorrent-rasterbar $LT_VERSION from source"
    pacman -S --noconfirm --needed mingw-w64-x86_64-cmake mingw-w64-x86_64-ninja
    local tarball="$WORK_DIR/libtorrent.tar.gz"
    fetch "https://github.com/arvidn/libtorrent/releases/download/v${LT_VERSION}/libtorrent-rasterbar-${LT_VERSION}.tar.gz" "$tarball" "$LT_SHA256"
    tar -xzf "$tarball" -C "$WORK_DIR"
    local src="$WORK_DIR/libtorrent-rasterbar-$LT_VERSION"
    patch -Np1 -d "$src/deps/libdatachannel" -i "$PATCH_DIR/0001-libdatachannel-include-algorithm.patch"
    patch -Np1 -d "$src" -i "$PATCH_DIR/0002-include-iterator.patch"
    MSYS2_ARG_CONV_EXCL="-DCMAKE_INSTALL_PREFIX=" cmake -Wno-dev -G Ninja \
        -S "$src" -B "$WORK_DIR/build" \
        -DCMAKE_INSTALL_PREFIX="$MINGW_PREFIX" -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON -Dbuild_tests=OFF -Dbuild_examples=OFF -Dbuild_tools=OFF
    cmake --build "$WORK_DIR/build"
    cmake --install "$WORK_DIR/build"
}

if [ "${OPAL_LIBTORRENT_FROM_SOURCE:-0}" = 1 ] || ! install_package; then
    build_from_source
fi
test -f "$MINGW_PREFIX/bin/libtorrent-rasterbar.dll"
