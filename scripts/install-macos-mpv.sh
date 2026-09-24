#!/usr/bin/env bash
# Homebrew's current mpv has no Sonoma bottle and its VapourSynth dependency
# fails to build with the runner's Python. Build only libmpv from pinned source,
# against the runner's native FFmpeg, without that unused filter plugin.
set -euo pipefail

if [ "$(uname -s)" != Darwin ] || ! command -v brew >/dev/null; then
    echo 'This script requires macOS and Homebrew' >&2
    exit 1
fi
HOMEBREW_PREFIX=${HOMEBREW_PREFIX:-$(brew --prefix)}
MPV_VERSION=0.41.0
MPV_SHA256=ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

curl --fail --location --retry 3 --output "$WORK_DIR/mpv.tar.gz" \
    "https://github.com/mpv-player/mpv/archive/refs/tags/v${MPV_VERSION}.tar.gz"
printf '%s  %s\n' "$MPV_SHA256" "$WORK_DIR/mpv.tar.gz" | shasum -a 256 --check -
tar -xzf "$WORK_DIR/mpv.tar.gz" -C "$WORK_DIR"

export MACOSX_DEPLOYMENT_TARGET=13.0
meson setup "$WORK_DIR/build" "$WORK_DIR/mpv-$MPV_VERSION" \
    --prefix="$HOMEBREW_PREFIX" --wrap-mode=nodownload --buildtype=release \
    -Dcplayer=false -Dlibmpv=true -Dvapoursynth=disabled \
    -Dmanpage-build=disabled -Dbuild-date=false
meson compile -C "$WORK_DIR/build"
meson install -C "$WORK_DIR/build"
test -f "$HOMEBREW_PREFIX/include/mpv/client.h"
test -f "$HOMEBREW_PREFIX/lib/libmpv.dylib"
