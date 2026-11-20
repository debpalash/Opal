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
PATCH1_URL='https://github.com/paullouisageneau/libdatachannel/commit/69bee9a719bccd151a67d2582f7be4abc0c29612.patch?full_index=1'
PATCH1_SHA256=5fe1826d62ec87a1a7f31a9b843a0a66fc538db9f1c50c99c144ac023d25ee3a
PATCH2_URL='https://github.com/arvidn/libtorrent/commit/cebad24950bfbbe7a097a9e25b0756b75a618e4c.patch?full_index=1'
PATCH2_SHA256=ac9450841360efead8001ed4b83631e675959f0eef8730591c8d37f8a208433c
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
    fetch "$PATCH1_URL" "$WORK_DIR/0001.patch" "$PATCH1_SHA256"
    fetch "$PATCH2_URL" "$WORK_DIR/0002.patch" "$PATCH2_SHA256"
    tar -xzf "$tarball" -C "$WORK_DIR"
    local src="$WORK_DIR/libtorrent-rasterbar-$LT_VERSION"
    patch -Np1 -d "$src/deps/libdatachannel" -i "$WORK_DIR/0001.patch"
    patch -Np1 -d "$src" -i "$WORK_DIR/0002.patch"
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
