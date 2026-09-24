#!/usr/bin/env bash
# MSYS2 no longer publishes MINGW64 mpv (2026-09-20); build libmpv against
# the *current* MINGW64 FFmpeg/CRT instead of mixing UCRT64 DLLs or installing
# an archived mpv whose FFmpeg SONAMEs no longer exist in the rolling repo.
set -euo pipefail

if [ "${MSYSTEM:-}" != MINGW64 ] || [ "${MINGW_PREFIX:-}" != /mingw64 ]; then
    echo 'This script requires the MSYS2 MINGW64 environment' >&2
    exit 1
fi

MPV_VERSION=0.41.0
MPV_SHA256=ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

curl --fail --location --retry 3 --output "$WORK_DIR/mpv.tar.gz" \
    "https://github.com/mpv-player/mpv/archive/refs/tags/v${MPV_VERSION}.tar.gz"
printf '%s  %s\n' "$MPV_SHA256" "$WORK_DIR/mpv.tar.gz" | sha256sum --check -
tar -xzf "$WORK_DIR/mpv.tar.gz" -C "$WORK_DIR"

# Meson runs as native MinGW Python, not MSYS Python: its install prefix must
# be a Windows path. Passing /mingw64 literally installs under the wrong root.
native_prefix=$(cygpath -m "$MINGW_PREFIX")
# The DLL and import library both land under /mingw64. The app uses libmpv,
# not mpv.exe; skip the CLI, docs and VapourSynth, but keep the normal Windows
# audio/video outputs. Meson must not download fallback dependencies.
meson setup "$WORK_DIR/build" "$WORK_DIR/mpv-$MPV_VERSION" \
    --prefix="$native_prefix" --wrap-mode=nodownload --buildtype=release \
    -Dcplayer=false -Dlibmpv=true -Dvapoursynth=disabled \
    -Dmanpage-build=disabled -Dbuild-date=false
meson compile -C "$WORK_DIR/build"
meson install -C "$WORK_DIR/build"
test -f "$MINGW_PREFIX/include/mpv/client.h"
test -f "$MINGW_PREFIX/lib/libmpv.dll.a"
test -f "$MINGW_PREFIX/bin/libmpv-2.dll"
