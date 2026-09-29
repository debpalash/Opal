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
fetch libplacebo-6.338.2 https://github.com/haasn/libplacebo/archive/refs/tags/v6.338.2.tar.gz 2f1e624e09d72a8c9db70f910f7560e764a1c126dae42acc5b3bcef836a7aec6
meson setup "$WORK/placebo-build" "$WORK/libplacebo-6.338.2" \
    --prefix="$PREFIX" --libdir=lib --buildtype=release --wrap-mode=nodownload \
    -Dvulkan=disabled -Dopengl=disabled -Dglslang=disabled -Dshaderc=disabled \
    -Ddemos=false -Dtests=false
meson compile -C "$WORK/placebo-build" -j "$JOBS"
meson install -C "$WORK/placebo-build"
fetch mpv-0.41.0 https://github.com/mpv-player/mpv/archive/refs/tags/v0.41.0.tar.gz ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209
meson setup "$WORK/mpv-build" "$WORK/mpv-0.41.0" \
    --prefix="$PREFIX" --libdir=lib --buildtype=release --wrap-mode=nodownload \
    -Dcplayer=false -Dlibmpv=true -Dvapoursynth=disabled \
    -Dmanpage-build=disabled -Dbuild-date=false -Dlua=luajit \
    -Dgl=disabled -Dvulkan=disabled -Ddrm=disabled -Dwayland=disabled -Dx11=disabled
meson compile -C "$WORK/mpv-build" -j "$JOBS"
meson install -C "$WORK/mpv-build"
fetch libtorrent-2.0.11 https://github.com/arvidn/libtorrent/archive/refs/tags/v2.0.11.tar.gz a317b4b4352bf1b846072dfacee30cd0afccf1ebc04a84273f1ecba930acb802
cmake -S "$WORK/libtorrent-2.0.11" -B "$WORK/torrent-build" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -Dpython-bindings=OFF \
    -DOPENSSL_ROOT_DIR="$PREFIX"
cmake --build "$WORK/torrent-build" -j "$JOBS"
cmake --install "$WORK/torrent-build"
fetch sdl-2.30.12 https://github.com/libsdl-org/SDL/archive/refs/tags/release-2.30.12.tar.gz 560da2e54dd8af933e35bd08fb1b6cf80d4f6938c67710fecf13b7e9bdd6c47e
(
    cd "$WORK/SDL-release-2.30.12"
    ./configure --prefix="$PREFIX" --disable-static --disable-video-wayland \
        --disable-video-kmsdrm --disable-video-offscreen --disable-video-vulkan
    make -j "$JOBS"
    make install
)
rm -rf "$WORK"
