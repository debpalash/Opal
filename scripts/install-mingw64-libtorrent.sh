#!/usr/bin/env bash
# MSYS2 dropped libtorrent-rasterbar from the MINGW64 repo index (2026-11-20;
# it now ships only for UCRT64/CLANG64). Opal needs the MSVCRT build, so
# install the last MINGW64 package, pinned by SHA-256. It was built
# 2026-11-15 against the current MINGW64 OpenSSL 4 (libssl-4-x64.dll) and
# Boost, so its dependencies still resolve from the rolling repo.
set -euo pipefail

if [ "${MSYSTEM:-}" != MINGW64 ] || [ "${MINGW_PREFIX:-}" != /mingw64 ]; then
    echo 'This script requires the MSYS2 MINGW64 environment' >&2
    exit 1
fi

PKG=mingw-w64-x86_64-libtorrent-rasterbar-2.1.2-3-any.pkg.tar.zst
PKG_SHA256=7596336f33394ed57bd842b7c28b43083d7df7c8676d2a2e1d8854c8bd20c37d
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

curl --fail --location --retry 3 --output "$WORK_DIR/$PKG" \
    "https://repo.msys2.org/mingw/mingw64/$PKG"
printf '%s  %s\n' "$PKG_SHA256" "$WORK_DIR/$PKG" | sha256sum --check -
pacman -U --noconfirm --needed "$WORK_DIR/$PKG"
test -f "$MINGW_PREFIX/bin/libtorrent-rasterbar.dll"
