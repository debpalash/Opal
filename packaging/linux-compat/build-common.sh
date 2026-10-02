#!/usr/bin/env bash
# Pinned, checksum-verified media dependencies built against glibc 2.31.
set -euo pipefail
PREFIX=/opt/opal-runtime
SOURCES=/opt/opal-sources
WORK=/tmp/opal-runtime-build
mkdir -p "$PREFIX" "$SOURCES" "$WORK"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export LD_LIBRARY_PATH="$PREFIX/lib"
export PATH="$PREFIX/bin:$PATH"
export CFLAGS='-O2 -march=x86-64'
export CXXFLAGS='-O2 -march=x86-64'
export LDFLAGS="-L$PREFIX/lib -Wl,-rpath,$PREFIX/lib"
JOBS=$(nproc)
fetch() {
    curl --fail --location --retry 3 "$2" -o "$SOURCES/$1.tar.gz"
    printf '%s  %s\n' "$3" "$SOURCES/$1.tar.gz" | sha256sum --check -
    tar -xf "$SOURCES/$1.tar.gz" -C "$WORK"
    printf '%s %s\n' "$1" "$2" >> "$SOURCES/SOURCES.txt"
}
