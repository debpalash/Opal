#!/usr/bin/env bash
# Current Homebrew FFmpeg has no Sonoma bottle; its x265 source dependency
# fails to assemble on the macos-14 runner. Build FFmpeg's native codecs and
# Apple hardware backends without that unused external encoder dependency.
set -euo pipefail

if [ "$(uname -s)" != Darwin ] || ! command -v brew >/dev/null; then
    echo 'This script requires macOS and Homebrew' >&2
    exit 1
fi
HOMEBREW_PREFIX=${HOMEBREW_PREFIX:-$(brew --prefix)}
FFMPEG_VERSION=7.1.5
FFMPEG_SHA256=de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

curl --fail --location --retry 3 --output "$WORK_DIR/ffmpeg.tar.xz" \
    "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
printf '%s  %s\n' "$FFMPEG_SHA256" "$WORK_DIR/ffmpeg.tar.xz" | shasum -a 256 --check -
tar -xf "$WORK_DIR/ffmpeg.tar.xz" -C "$WORK_DIR"

export MACOSX_DEPLOYMENT_TARGET=13.0
(
    cd "$WORK_DIR/ffmpeg-$FFMPEG_VERSION"
    ./configure --prefix="$HOMEBREW_PREFIX" --enable-shared --disable-static \
        --disable-programs --disable-doc --disable-autodetect \
        --enable-securetransport --enable-videotoolbox --enable-audiotoolbox
    make -j "$(sysctl -n hw.ncpu)"
    make install
)
test -f "$HOMEBREW_PREFIX/lib/libavcodec.dylib"
test -f "$HOMEBREW_PREFIX/lib/pkgconfig/libavcodec.pc"
