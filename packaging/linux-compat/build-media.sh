#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/build-common.sh"
# Account creation uses INSERT ... RETURNING (SQLite >=3.35). Focal's stock
# SQLite 3.31 can launch the app but cannot create or log in to accounts.
fetch sqlite-3.53.4 https://www.sqlite.org/2026/sqlite-autoconf-3530400.tar.gz 0e9483900e92cd5de8fd48d16bf9200145a61f7fd5be542a5ac81d8a9516eb9c
(
    cd "$WORK/sqlite-autoconf-3530400"
    ./configure --prefix="$PREFIX" --disable-static --fts5 --disable-readline
    make -j "$JOBS"
    make install
)
fetch openssl-3.6.4 https://github.com/openssl/openssl/archive/refs/tags/openssl-3.6.4.tar.gz c6b94124bb76ac5f8aa80de121e0f922a93d3bbf1be478bd50ebc36a30dc1db1
(
    cd "$WORK/openssl-openssl-3.6.4"
    ./Configure linux-x86_64 shared --prefix="$PREFIX" --libdir=lib --openssldir=/usr/lib/ssl
    make -j "$JOBS"
    make install_sw
)
# dav1d changes SONAME between Focal, Jammy and Debian 12. Keep it private
# so the same compatibility package can decode AV1 on all three distributions.
fetch dav1d-1.5.4 https://github.com/videolan/dav1d/archive/refs/tags/1.5.4.tar.gz a1d5b63d2d38ec9bd03acf643caa51fa22edd1e89c5a109c4807717216bbec07
meson setup "$WORK/dav1d-build" "$WORK/dav1d-1.5.4" \
    --prefix="$PREFIX" --libdir=lib --buildtype=release --wrap-mode=nodownload \
    -Ddefault_library=shared -Denable_tools=false -Denable_tests=false
meson compile -C "$WORK/dav1d-build" -j "$JOBS"
meson install -C "$WORK/dav1d-build"
fetch ffmpeg-7.1.5 https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n7.1.5.tar.gz e3963a50831c985933e1a625ed566ec4c7adb5c012c34fa9f84438e1d61bdacc
(
    cd "$WORK/FFmpeg-n7.1.5"
    ./configure --prefix="$PREFIX" --enable-shared --disable-static --disable-doc \
        --disable-autodetect --enable-openssl --enable-version3 --enable-libdav1d \
        --extra-cflags="-I$PREFIX/include" --extra-ldflags="-L$PREFIX/lib"
    make -j "$JOBS"
    make install
)
rm -rf "$WORK"
